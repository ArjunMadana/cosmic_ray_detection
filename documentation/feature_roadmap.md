# Feature Roadmap — DRAM Dosimeter
*Last updated: 2026-04-04 (Feature 1 complete, Features 2 and 4 redesigned)*

This document is broken into self-contained feature tasks that can each be delegated to a separate Claude chat.  Each task has its own context, exact files to read, and a precise implementation spec so agents don't waste time re-exploring.

---

## Project snapshot (read this first)

**Board:** Digilent Arty S7-25 (Spartan-7 XC7S25, 256 MB MT41K128M16JT DDR3)  
**ui_clk:** 150 MHz (confirmed — uart_tx.v uses CLK_FREQ=150_000_000 and baud works)  
**UART:** 921600 8N1 over USB-JTAG FTDI (COM3 typically).  TX=R12, RX=V12 (bank 14).  Updated from 115200 as part of Feature 2 to support address streaming bandwidth.  CLKS_PER_BIT = 150_000_000 / 921_600 = 163 (fits in 8 bits, 0.15% baud error).  **No effect on ui_clk** — clock is MIG PLL, independent of UART parameters.  
**AXI bus:** 32-bit data, 28-bit byte address.  Stepping by +4 covers one 32-bit word.  
**Current MEM_SIZE:** 0x4000000 = 64 MB (25% of physical DRAM).

### FSM state machine (detector_fsm.v)

```
                                           ← X (reset) from any state ←
                                          ↓                             ↑
WAIT_INIT → [PRINT_READY → WAIT_GO] → FILL → FILL2 → HOLD → SCAN → [STREAM_ADDRS] → REPORT → SETTLE → FILL (loop)
                                                         ↕
                                           PRINT_REF / PRINT_INT / PRINT_PAT  (return to HOLD)
```

- `PRINT_READY` and `WAIT_GO` are added by Feature 5 (not yet implemented — currently WAIT_INIT goes directly to FILL)
- `STREAM_ADDRS` is added by Feature 2 (not yet implemented — currently SCAN goes directly to REPORT)
- `X` command (Feature 5) transitions from any state back to PRINT_READY

- **FILL / FILL2:** writes `active_pattern` to every address 0→MEM_SIZE-4 step 4 — twice per cycle to ensure all cells are written before the hold starts
- **HOLD:** counts `hold_cycles_sel` clock cycles before proceeding
- **SCAN:** reads every address, increments `hit_counter` on `rdata != active_pattern`
- **STREAM_ADDRS** *(Feature 2):* streams buffered flip addresses over UART before the summary line
- **REPORT:** sends `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX\r\n` (33 bytes) over UART TX
- **SETTLE:** waits for AXI to drain before re-entering FILL

### UART command interface (already implemented)

The FSM accepts single-letter ASCII commands over UART RX (`H<N>\n` for hold time).  Pattern is in the `rx_valid` block around line 183 of detector_fsm.v.  Extend this block for new commands.

### UART printing pattern (already implemented)

Print states (`PRINT_REF`, `PRINT_INT`) use a `report_idx` counter with one `uart_data` assignment per index.  Reuse this exact pattern for any new print states.  The `uart_valid` handshake: set `uart_valid=1` while `report_idx < N`, then clear it and transition state on `report_idx == N`.

### Python GUI (tools/uart_logger.py)

Tkinter + matplotlib.  Key classes: `SerialReader` (thread), `DataStore` (CSV+JSONL), `DosimeterApp` (GUI).  UART messages are parsed in `parse_line()` using regexes at the top of the file.  New UART messages need a new regex + handling in `_handle_record()`.  New GUI controls go in `_build_ui()`, row 4 (controls strip).

Maintenance note: the raw flip-count plot uses one persistent secondary y-axis (`self._ax_temp`) for the temperature overlay.  Reuse and clear that axis on redraws; do not call `ax.twinx()` inside `_redraw()`, because it stacks duplicate right-side axes and temperature traces.

---

## Feature 1 — Selectable memory pattern (single mode) ✅ COMPLETE

**Goal:** Let the user pick which 32-bit pattern to write/verify: `0xFFFFFFFF`, `0x00000000`, `0x55555555`, `0xAAAAAAAA`.  Default stays `0xFFFFFFFF`.  The active pattern is reported in every REPORT line so data is self-labeling.

**Why:** `0xFFFFFFFF` only detects 1→0 bit decay.  `0x00000000` only detects 0→1 decay.  Checkerboard patterns (`0x55`/`0xAA`) detect both and stress adjacent cells.  Running all four patterns in sequence (separate experiments) reveals whether the Arty S7's DRAM has a dominant decay polarity.

### What was implemented

All firmware and Python changes described below were completed.  Key decisions and findings during implementation:

- **`fill_pattern_sel` latch** — `pattern_sel` (user-facing) is decoupled from `fill_pattern_sel` (latched at FILL entry).  This prevents a mid-cycle pattern change from corrupting the SCAN comparison.  Both FILL passes and SCAN use `active_pattern = f(fill_pattern_sel)`.  REPORT uses `fill_pattern_sel` for the `PAT:XX` field (note: early implementation incorrectly used `pattern_sel` here — fixed).

- **Double-FILL (FILL2 state)** — Investigation with experimental data revealed that ~530K words (~3.17% of 16M) failed on the first cycle with any new pattern, including the very first cycle after power-on.  This was traced to incomplete writes on the first FILL pass: cells hold their previous value (random after MIG calibration, or the old pattern after a switch) and fail SCAN.  Fix: added `FILL2` state, an identical second write pass.  After the fix the first-cycle spike dropped from ~530K to ~5–8K (residual genuine DRAM effect), and the very-first-cycle count dropped to 0.

- **Possible future improvement:** Triple-FILL to further reduce the residual first-cycle spike.  Alternatively, only do the double-write on pattern changes (not every cycle), since steady-state cycles don't need it.  Neither was implemented as the current residual is small and the user is not switching patterns frequently.

- **`PRINT_PAT` state** — Sends `PATTERN:XX\r\n` as an in-band acknowledgment when a `P` command is received during HOLD.  Returns to HOLD after printing.

- **`report_idx` width** — Widened from `reg [4:0]` to `reg [5:0]` after the longer REPORT format (33 bytes) caused the counter to wrap at 31, producing an infinite REPORT loop.

- **State register** — Widened from `reg [3:0]` to `reg [4:0]` to accommodate `FILL2 = 4'd9`.

### UART format (current)

```
HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX\r\n   (33 bytes)
PATTERN:XX\r\n                          (12 bytes, sent on P command acknowledgment)
```

### Python (tools/uart_logger.py)

All changes complete: `FLIP_RE` updated, `PATTERN_RE` added, `pattern` field in CSV, pattern selector Combobox + Send button in GUI, `_pat_events` drawn as teal dash-dot vertical lines in the plot.

---

## Feature 2 — Flip address streaming

**Goal:** Buffer every flip address into a BRAM FIFO during SCAN, then stream all addresses over UART after SCAN completes.  Python collects addresses per cycle and stores them in JSONL.  This is the data collection foundation for Feature 4 (background subtraction + cluster detection) — no analysis is done here.

**Why first/last address was rejected:** At 30s+ hold times with thousands of thermal flips, first and last address always span nearly the full 64 MB and carry no useful information.  Full address streaming lets Python do proper cluster analysis: a cosmic ray deposits charge along a localized ionization track, flipping cells with nearby addresses.  Even at 1,500 thermal flips/cycle, a cluster of 8 flips within a 1,000-word window is statistically improbable by chance and is a strong candidate event.

### Step 0 — Baud rate update (do this first)

At 115200 baud, 1,500 addresses × 9 bytes each = 13,500 bytes → ~13 seconds of transmission per cycle, which is unacceptable.  At 921600 baud the same transmission takes ~150 ms.

**Files to change:**

1. `cosmic_ray_detection.srcs/sources_1/new/uart_tx.v` — change `BAUD_RATE` default parameter (or the derived `CLKS_PER_BIT` constant) from 115200 to 921600.
2. `cosmic_ray_detection.srcs/sources_1/new/uart_rx.v` — same change.
3. `cosmic_ray_detection.srcs/sources_1/new/cosmic_top.v` — verify `CLK_FREQ=150_000_000` is still passed at both instantiation sites.  No other changes needed — both modules derive `CLKS_PER_BIT = CLK_FREQ / BAUD_RATE` internally.  At 921600 baud, `CLKS_PER_BIT = 163`, which fits in 8 bits — no counter width change needed.
4. `tools/uart_logger.py` — change `baudrate=115200` to `baudrate=921600` wherever `serial.Serial` is opened.

**Note:** changing the baud rate has no effect on ui_clk.  The 150 MHz clock is generated by the MIG PLL and is completely independent of UART counter values.

### Files to read before starting

1. `cosmic_ray_detection.srcs/sources_1/new/detector_fsm.v` — full file, especially SCAN state, REPORT state, and declaration block
2. `cosmic_ray_detection.srcs/sources_1/new/uart_tx.v` — find where baud rate / CLKS_PER_BIT is set
3. `cosmic_ray_detection.srcs/sources_1/new/uart_rx.v` — same
4. `cosmic_ray_detection.srcs/sources_1/new/cosmic_top.v` — both UART instantiation sites
5. `tools/uart_logger.py` — `parse_line()`, `SerialReader`, `DataStore`, `_handle_record()`

### Firmware changes (detector_fsm.v)

1. **Add BRAM address buffer** to the declaration block.  Vivado infers a 28-bit wide array as BRAM automatically:
   ```verilog
   reg [27:0] addr_buf [0:4095];  // 4096-entry buffer (~16 KB BRAM, well within 225 KB budget)
   reg [11:0] buf_wr_ptr;         // write pointer, incremented during SCAN
   reg [11:0] buf_rd_ptr;         // read pointer, incremented during STREAM_ADDRS
   reg [11:0] buf_count;          // total entries written this cycle
   ```
   Add `buf_wr_ptr <= 0; buf_rd_ptr <= 0; buf_count <= 0;` to the reset block.

2. **Add `STREAM_ADDRS` state** to localparams:
   ```verilog
   localparam STREAM_ADDRS = 4'd10;
   ```

3. **In HOLD → SCAN transition**, reset buffer pointers alongside `hit_counter`:
   ```verilog
   buf_wr_ptr <= 0;
   buf_count  <= 0;
   ```

4. **In SCAN state**, push each flip address to the buffer (silently drop if full — 4096 is sufficient for normal operation):
   ```verilog
   if (rdata != active_pattern) begin
       hit_counter <= hit_counter + 1;
       if (buf_count < 12'd4096) begin
           addr_buf[buf_wr_ptr] <= addr;
           buf_wr_ptr           <= buf_wr_ptr + 1;
           buf_count            <= buf_count + 1;
       end
   end
   ```

5. **Change SCAN → REPORT transition to SCAN → STREAM_ADDRS**:
   ```verilog
   if (addr >= MEM_SIZE - 4) begin
       state        <= STREAM_ADDRS;
       report_shift <= hit_counter;
       report_idx   <= 0;
       buf_rd_ptr   <= 0;
   end
   ```

6. **Add STREAM_ADDRS state**.  Output format: one header line followed by one address per line:
   ```
   ADDRS:NNNN\r\n     (11 bytes — 4 hex digits = count of addresses to follow, max FFF = 4095)
   XXXXXXX\r\n        (9 bytes per address — 7 hex digits + CRLF)
   ```
   Use `report_idx` as the byte counter for the header (same pattern as all other print states).  After the header is sent, iterate: load `addr_buf[buf_rd_ptr]` into a 28-bit shift register, send 7 nibbles, send CRLF, increment `buf_rd_ptr`.  When `buf_rd_ptr == buf_count`, transition to REPORT (which sends the summary line as normal).

   The `ADDRS:NNNN` header lets Python know exactly how many address lines to expect before the `HOLD:...` summary line arrives.

7. **State register**: already `reg [4:0]`, value 10 is fine.

### Python changes (tools/uart_logger.py)

1. **Add regexes**:
   ```python
   ADDRS_HDR_RE = re.compile(r'ADDRS:([0-9A-Fa-f]{4})')
   ADDR_LINE_RE = re.compile(r'^([0-9A-Fa-f]{7})$')
   ```

2. **Add parser state** to `SerialReader` (or wherever lines are dispatched):
   ```python
   self._addr_remaining = 0
   self._addr_buf = []
   ```
   In the line-dispatch loop: if `_addr_remaining > 0`, treat the line as an address, append `int(line.strip(), 16)` to `_addr_buf`, decrement `_addr_remaining`.  When it hits 0, store the completed list and wait for the next `ADDRS:` header or `HOLD:` summary.  If `ADDRS_HDR_RE` matches, set `_addr_remaining` and clear `_addr_buf`.

3. **Attach addresses to FLIP records in JSONL** (not CSV — too wide).  When the `HOLD:...` summary line arrives, bundle the most-recently-collected `_addr_buf` into the JSONL record:
   ```json
   {"type": "FLIP", "iteration": 42, "flip_count": 1503, "pattern": "FF", "addrs": [197664, 204812, ...], ...}
   ```

4. **No new GUI controls needed** for Feature 2.  The addresses are stored in JSONL for Feature 4 to consume.

### Verification

- Flash new bitstream.  Confirm baud rate works: REPORT lines still arrive and CSV records are correct.
- At 30s hold, terminal log should show `ADDRS:05DC` (or the actual count in hex), followed by 7-digit hex lines, then the `HOLD:...` summary.
- JSONL records contain `addrs` array with the correct count matching `flip_count`.
- Confirm overflow never triggers in normal operation (buf_count should stay well under 4096 at 30s hold).

---

## Feature 3 — Dual pattern mode

**Goal:** Write `0x55555555` to addresses `0x0000000–(MEM_SIZE/2 - 4)` and `0xAAAAAAAA` to `(MEM_SIZE/2)–(MEM_SIZE - 4)` in a single FILL/SCAN cycle.  This tests both polarities every cycle without requiring separate experiments.

**Prerequisite:** Feature 1 is already complete.  `active_pattern`, `pattern_sel`, and `fill_pattern_sel` all exist.  Feature 2's `STREAM_ADDRS` state and BRAM buffer are independent — Feature 3 can be implemented before or after Feature 2.

**Why:** `0x55` and `0xAA` are bitwise inverses.  A cell that decays from 1→0 will show up in both halves (where `0x55` has 1s at even bits, `0xAA` has 1s at odd bits).  If both halves show similar flip rates, decay is polarity-symmetric.  If one half shows significantly more, the chip has a preferred decay direction.

### Files to read before starting

1. `cosmic_ray_detection.srcs/sources_1/new/detector_fsm.v` — full file, especially the FILL, FILL2, SCAN, and REPORT states, and the declaration block
2. `tools/uart_logger.py` — controls strip in `_build_ui()`, `_handle_record()`, `DataStore`

### Firmware changes (detector_fsm.v)

1. **Add** `reg dual_mode` (default 0) to declarations and reset block.

2. **Add** UART command `D<0-1>\n` to the RX parser (same pattern as `P` command from Feature 1).  On `\n`: set `dual_mode`, set `dual_changed` flag.  Add `localparam PRINT_DUAL = 4'd11` and handle `dual_changed` in HOLD with the same priority chain (`btn_changed` → `sw_changed` → `pat_changed` → `dual_changed` → hold expiry), transitioning to PRINT_DUAL.  Output: `DUAL:ON\r\n` or `DUAL:OFF\r\n`, then return to HOLD.

3. **Modify both FILL and FILL2 states** identically — both passes must write the same address-dependent pattern when in dual mode:
   ```verilog
   wdata <= dual_mode ? ((addr >= (MEM_SIZE >> 1)) ? 32'hAAAAAAAA : 32'h55555555)
                      : active_pattern;
   ```

4. **Add a combinational wire outside the always block** for the expected read value, then use it in SCAN:
   ```verilog
   // Outside always block, near active_pattern declaration:
   wire [31:0] expected_pattern = dual_mode
       ? ((addr >= (MEM_SIZE >> 1)) ? 32'hAAAAAAAA : 32'h55555555)
       : active_pattern;
   ```
   In SCAN state, replace `rdata != active_pattern` with `rdata != expected_pattern`.  Also replace the wdata line in FILL and FILL2 with `active_pattern` → `expected_pattern` (which already handles dual mode via the ternary above).

5. **Add `hit_lo` and `hit_hi` counters** in dual mode (lower and upper half flip counts separately):
   ```verilog
   reg [31:0] hit_lo, hit_hi;  // only meaningful when dual_mode=1
   ```
   In SCAN: increment `hit_lo` if `addr < MEM_SIZE/2`, else `hit_hi`.

6. **Extend REPORT format** in dual mode:
   ```
   HOLD:NNNNs PAT:DU FLIPS:XXXXXXXX LO:XXXXXXXX HI:XXXXXXXX\r\n
   ```
   When `dual_mode=0`, format is unchanged from Feature 1.  Use `PAT:DU` to signal dual mode in the data.

### Python changes (tools/uart_logger.py)

1. **Add `DUAL_FLIP_RE`** to handle the extended dual-mode format (match `PAT:DU` and extract `LO`/`HI` counts).

2. **Add dual-mode CSV columns**: `flip_lo`, `flip_hi` (null when not in dual mode).

3. **Add dual mode toggle to GUI**: a checkbox `Dual pattern (0x55/0xAA)` next to the pattern selector from Feature 1.  Sends `D1\n` or `D0\n`.

4. **Add dual-mode plot**: when dual mode is active, plot `flip_lo` and `flip_hi` as separate series on the same axes (e.g. solid vs dashed line), so polarity asymmetry is immediately visible.

### Verification

- Enable dual mode → log shows `PATTERN:DU`
- FLIP lines show `PAT:DU` with separate `LO`/`HI` counts
- Under refresh=OFF, LO and HI should be roughly equal (both test same number of cells)
- Disable dual mode → returns to normal single-pattern behavior

---

## Feature 4 — Background subtraction and cluster detection

**Goal:** Use the accumulated flip address data from Feature 2 to separate persistent thermal failures from rare events.  After enough cycles, classify each address as a hot pixel (thermal) or a rare event.  Within rare events, find spatial clusters — the cosmic ray signature.  Display the de-noised signal and flag candidate events in the GUI.

**Prerequisite:** Feature 2 must be complete.  Requires at least ~20 cycles of JSONL data with `addrs` arrays populated.

**No firmware changes required.**  This is pure Python/GUI work.

**Why this works:** Thermal weak cells fail consistently every cycle at the same addresses.  A cosmic ray flips cells that don't fail thermally — they appear at addresses with no prior flip history, often in tight spatial clusters (the ionization track spans physically adjacent cells, which map to nearby logical addresses within the same DRAM row).  Subtracting the known thermal background exposes these rare events even when the raw flip count is dominated by noise.

### Files to read before starting

1. `tools/uart_logger.py` — full file: `DataStore`, `DosimeterApp`, `_build_ui()`, `_redraw()`, `_handle_record()`

### Python changes (tools/uart_logger.py)

1. **Add `BackgroundModel` class** (can live in `uart_logger.py` or a small separate module):
   ```python
   class BackgroundModel:
       def __init__(self, hot_threshold=0.5, rare_threshold=0.1, min_cycles=20):
           self._counts = {}       # addr (int) -> number of cycles it has flipped
           self._n_cycles = 0
           self.hot_threshold  = hot_threshold   # flip rate >= this → hot pixel
           self.rare_threshold = rare_threshold  # flip rate <  this → rare event
           self.min_cycles     = min_cycles      # don't classify until this many cycles seen

       def update(self, addrs: list):
           self._n_cycles += 1
           for a in addrs:
               self._counts[a] = self._counts.get(a, 0) + 1

       @property
       def ready(self):
           return self._n_cycles >= self.min_cycles

       def classify(self, addrs: list) -> tuple:
           """Returns (hot_pixels, rare_events) for a single cycle's address list."""
           if not self.ready:
               return list(addrs), []
           hot, rare = [], []
           for a in addrs:
               rate = self._counts.get(a, 0) / self._n_cycles
               (hot if rate >= self.hot_threshold else rare).append(a)
           return hot, rare

       def find_clusters(self, addrs: list, window=1000, min_size=3) -> list:
           """Find groups of >= min_size addresses within a window of each other."""
           if len(addrs) < min_size:
               return []
           s = sorted(addrs)
           clusters, i = [], 0
           while i < len(s):
               j = i
               while j < len(s) and s[j] - s[i] <= window:
                   j += 1
               if j - i >= min_size:
                   clusters.append({
                       'start': s[i], 'end': s[j-1],
                       'count': j - i, 'addrs': s[i:j]
                   })
               i += 1
           return clusters
   ```

2. **Instantiate `BackgroundModel`** in `DosimeterApp.__init__`: `self._bg = BackgroundModel()`.

3. **In `_handle_record()`**, when a `FLIP` record arrives with an `addrs` field:
   - Call `self._bg.update(record['addrs'])`
   - Call `hot, rare = self._bg.classify(record['addrs'])`
   - Call `clusters = self._bg.find_clusters(rare)`
   - Store `len(rare)` and cluster list alongside the record for plotting
   - If any clusters found, log in yellow:
     ```
     [CLUSTER] iter=42  rare=8  cluster: 8 addrs  span=0x003F0  (0x1A3C00–0x1A3FF0)
     ```

4. **Add a second plot tab** (`ttk.Notebook` with two tabs):
   - **Tab 1:** existing time-series flip count plot (unchanged)
   - **Tab 2:** de-noised signal
     - X axis: iteration number
     - Y axis: rare flip count (total minus hot pixels)
     - Mark cluster events with a vertical red line and annotation
     - Text annotation: `Background: N hot pixels  |  Cycles: M`

5. **Add background model status** to the status bar: `BG: building (12/20)` while warming up, then `BG: ready  Hot: 1421` once active.

### Tuning parameters

The defaults (`hot_threshold=0.5`, `rare_threshold=0.1`, `window=1000`, `min_size=3`) are reasonable starting points but may need adjustment:
- **Longer hold times** → more hot pixels → may want to lower `hot_threshold`
- **Denser thermal baseline** → more random near-neighbors → increase `min_size` or decrease `window`
- **window=1000** corresponds to a 4 KB address range out of 64 MB — comparable to a few DRAM rows

### Verification

- Run 25+ cycles at 30s hold.  Status bar should show `BG: ready  Hot: ~1400`.
- De-noised plot should hover near 0 each cycle.
- Increase hold to 120s for one cycle to generate extra flips → rare count spikes, cluster detection may or may not fire depending on DRAM layout.
- A genuine cosmic ray event should appear as a cycle with `rare > 0` and `clusters > 0` with a tight span.

---

## Feature 5 — SPI flash boot + controlled start

**Goal:** Store the bitstream in the board's onboard SPI flash so the FPGA loads itself on every power-up without Vivado.  The board boots into a `WAIT_GO` idle state, sends `READY\r\n`, and does nothing until Python sends a `G` command.  A `X` reset command returns the board to `WAIT_GO` from any state, allowing clean restarts between experiments.  The only time Vivado needs to be opened is after a firmware rebuild.

**Why SPI flash over Python-driven JTAG programming:**  JTAG-from-Python requires Vivado on PATH, adds 30–90 seconds of startup latency every session, and couples normal operation to the development toolchain.  SPI flash makes the board behave like a microcontroller — plug it in, it boots in ~3 seconds, and Python just waits for `READY`.  Recovery from a bad flash is a single JTAG reprogram, same as the current workflow.

### Boot flow

```
Board powers up / plugged in
      ↓
FPGA loads bitstream from SPI flash (~3–5 seconds)
      ↓
MIG calibration completes → PRINT_READY → sends READY\r\n → WAIT_GO
      ↓
Python opens serial port, receives READY → enables Start button
      ↓
User sets hold time and pattern in GUI → clicks Start
      ↓
Python sends H<N>\n, P<X>\n, then G
      ↓
Board: fill_pattern_sel latched, transitions WAIT_GO → FILL → normal loop
```

### Reset flow (between experiments)

```
Python sends X
      ↓
Board aborts current state, transitions to PRINT_READY → sends READY\r\n → WAIT_GO
      ↓
Python receives READY → re-enables Start button
      ↓
User adjusts settings, clicks Start again
```

### Files to read before starting

1. `cosmic_ray_detection.srcs/sources_1/new/detector_fsm.v` — full file, especially WAIT_INIT and the UART RX command block
2. `tools/program_board.tcl` — reference for the flash script structure
3. `tools/uart_logger.py` — `SerialReader`, `DosimeterApp._build_ui()`, connection/disconnect handling

### Part A — SPI flash programmer (new Tcl script)

Create `tools/flash_board.tcl`.  This is separate from `program_board.tcl` (which does volatile JTAG programming).  Flash programming is slower (~2 min) but persists across power cycles.

```tcl
# flash_board.tcl — Writes bitstream to SPI flash on Arty S7-25.
# Run: vivado -mode batch -source tools/flash_board.tcl
# Only needed after a firmware rebuild.

set bitfile  [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]
set mcsfile  [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.mcs"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found. Run Generate Bitstream first."
    exit 1
}

# Generate .mcs file for the W25Q128JV (128Mb = 16MB) on Arty S7
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bitfile" \
    -file $mcsfile -force

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices] 0]
current_hw_device $device
refresh_hw_device $device

# Find the SPI flash memory device
set flash [lindex [get_hw_cfgmem] 0]
if {$flash eq ""} {
    # Create the cfgmem object if not already present
    create_hw_cfgmem -hw_device $device \
        [lindex [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}] 0]
    set flash [lindex [get_hw_cfgmem] 0]
}

set_property PROGRAM.FILE      $mcsfile $flash
set_property PROGRAM.ADDRESS   0x0      $flash
set_property PROGRAM.BLANK_CHECK  1     $flash
set_property PROGRAM.ERASE        1     $flash
set_property PROGRAM.CFG_PROGRAM  1     $flash
set_property PROGRAM.VERIFY       1     $flash

program_hw_cfgmem $flash

puts "Flash programming complete. Power-cycle the board to boot from flash."
close_hw_target
disconnect_hw_server
```

**Note on flash part:** The Arty S7-25 uses a Spansion/Infineon S25FL128S.  The part string `s25fl128sxxxxxx0-spi-x1_x2_x4` is the Vivado library name.  If `get_hw_cfgmem` already returns a device (Vivado auto-detects it), skip the `create_hw_cfgmem` step.  Verify with `get_cfgmem_parts {s25fl*}` in the Vivado Tcl console if unsure.

Also create `flash_board.bat` alongside the existing `program_board.bat`:
```bat
vivado -mode batch -source tools/flash_board.tcl
pause
```

### Part B — Firmware changes (detector_fsm.v)

1. **Add two new states**:
   ```verilog
   localparam PRINT_READY = 4'd12;
   localparam WAIT_GO     = 4'd13;
   ```

2. **Change WAIT_INIT transition** — go to PRINT_READY instead of FILL, and remove the `fill_pattern_sel` latch (it moves to WAIT_GO):
   ```verilog
   WAIT_INIT: begin
       if (calib_complete) begin
           state      <= PRINT_READY;
           report_idx <= 0;
       end
   end
   ```

3. **Add PRINT_READY state** — sends `READY\r\n` (7 bytes), then transitions to WAIT_GO:
   ```verilog
   PRINT_READY: begin
       if (uart_ready && !uart_valid) begin
           report_idx <= report_idx + 1;
           if (report_idx < 7) uart_valid <= 1;
           if      (report_idx == 0) uart_data <= "R";
           else if (report_idx == 1) uart_data <= "E";
           else if (report_idx == 2) uart_data <= "A";
           else if (report_idx == 3) uart_data <= "D";
           else if (report_idx == 4) uart_data <= "Y";
           else if (report_idx == 5) uart_data <= 8'h0D;
           else if (report_idx == 6) uart_data <= 8'h0A;
           else if (report_idx == 7) begin
               uart_valid <= 0;
               state      <= WAIT_GO;
           end
       end else begin
           uart_valid <= 0;
       end
   end
   ```

4. **Add WAIT_GO state** — idles, accepts H/P commands normally, starts on `go_flag`:
   ```verilog
   WAIT_GO: begin
       if (go_flag) begin
           go_flag          <= 0;
           fill_pattern_sel <= pattern_sel;
           addr             <= 0;
           state            <= FILL;
       end
   end
   ```

5. **Add `go_flag` and `reset_flag` registers** to the declaration block, both defaulting to 0 in the reset block.

6. **Add G and X command parsers** to the UART RX block (alongside H and P).  Both are single-byte commands — no accumulator needed:
   ```verilog
   if (rx_valid) begin
       if (rx_data == "G") go_flag    <= 1;
       if (rx_data == "X") reset_flag <= 1;
   end
   ```

7. **Handle `reset_flag` at the top of the FSM case statement**, before all state cases, so it fires from any state:
   ```verilog
   if (reset_flag) begin
       reset_flag  <= 0;
       go_flag     <= 0;
       hit_counter <= 0;
       addr        <= 0;
       awvalid     <= 0;
       wvalid      <= 0;
       arvalid     <= 0;
       report_idx  <= 0;
       state       <= PRINT_READY;
   end else begin
       case (state)
           // ... all existing state cases unchanged ...
       endcase
   end
   ```
   This cleanly interrupts any in-progress FILL, HOLD, SCAN, or REPORT and returns to the ready state.

8. **H and P commands already work in WAIT_GO** — the UART RX parser is state-independent.  No additional changes needed.

### Part C — Python changes (tools/uart_logger.py)

1. **Add `READY_RE` regex**:
   ```python
   READY_RE = re.compile(r'^READY$')
   ```

2. **Add COM port auto-detection** to pre-populate the port dropdown:
   ```python
   import serial.tools.list_ports

   def find_arty_port():
       # FT2232H on Arty S7: VID=0x0403 PID=0x6010, two ports — UART is interface B (higher)
       candidates = [p for p in serial.tools.list_ports.comports()
                     if p.vid == 0x0403 and p.pid == 0x6010]
       if candidates:
           return sorted(candidates, key=lambda p: p.device)[-1].device
       return None
   ```
   Call on startup and when the port dropdown is clicked to refresh.

3. **GUI state machine** — manage button enable/disable across these states:

   | State | Connect btn | Start btn | Stop/Reset btn | H/P controls |
   |---|---|---|---|---|
   | `DISCONNECTED` | enabled | disabled | disabled | disabled |
   | `WAITING_READY` | disabled | disabled | disabled | disabled |
   | `BOARD_READY` | disabled | enabled | enabled | enabled |
   | `RUNNING` | disabled | disabled | enabled | enabled |

4. **Handle `READY` in `_handle_record()`**:
   - Set internal state to `BOARD_READY`, update button states
   - Log: `[BOARD] Ready — MIG calibration complete`
   - Status bar: `"Board ready — set parameters and click Start"`

5. **Start button** (disabled until `READY` received):
   - On click: send `H{hold_sec}\n`, send `P{pattern_idx}\n`, send `G` (no newline — single byte)
   - Transition GUI to `RUNNING` state

6. **Stop/Reset button** (replaces or supplements current controls):
   - On click: send `X` (single byte), transition GUI to `WAITING_READY`
   - Board will send `READY` again, re-enabling Start

7. **On serial connect**: immediately send nothing — just wait for `READY`.  If `READY` doesn't arrive within 10 seconds, show a warning: `"Board not responding. May need to power-cycle or flash the bitstream."`

### Verification

- Flash board with `flash_board.bat`, then power-cycle → board boots in ~3–5 seconds, `READY` appears in log without pressing anything in Vivado
- Start button activates, set hold=20s/pattern=AA, click Start → first FLIP record shows hold=20s, PAT=AA
- During a run, click Stop/Reset → `READY` re-appears, Start re-activates, new settings can be applied
- Unplug and replug without reflashing → still boots and sends `READY` automatically
- Run `program_board.bat` (JTAG) for rapid development iteration — works exactly as before but board will lose program on power cycle

---



### How UART print states work (reuse this pattern exactly)

All print states use `report_idx` as a byte counter.  Key rules:
- `report_idx` is incremented at the start of each ready cycle: `report_idx <= report_idx + 1`
- `uart_valid <= 1` while `report_idx < N` (N = total bytes in message)
- On `report_idx == N`, clear `uart_valid` and transition state
- The `else begin uart_valid <= 0; end` branch runs when `uart_ready` is low — it clears valid but does NOT advance the index, so the same byte is re-presented next cycle.  This is intentional — `uart_ready` will go high when the TX shift register is free.

### State encoding

Currently uses 5-bit `state` (`reg [4:0]`).  Assigned values:

| Value | Name | Status |
|---|---|---|
| 0 | `WAIT_INIT` | implemented |
| 1 | `FILL` | implemented |
| 2 | `HOLD` | implemented |
| 3 | `SCAN` | implemented |
| 4 | `REPORT` | implemented |
| 5 | `SETTLE` | implemented |
| 6 | `PRINT_REF` | implemented |
| 7 | `PRINT_INT` | implemented |
| 8 | `PRINT_PAT` | implemented |
| 9 | `FILL2` | implemented |
| 10 | `STREAM_ADDRS` | Feature 2 |
| 11 | `PRINT_DUAL` | Feature 3 |
| 12 | `PRINT_READY` | Feature 5 |
| 13 | `WAIT_GO` | Feature 5 |

Next available value after all planned features: 14.  The 5-bit register supports up to 31 states.

### Rebuilding after firmware changes

After any change to `.v` files: in Vivado, **right-click Synthesis → Reset Runs** (and Implementation), then run Generate Bitstream.  Incremental synthesis silently reuses stale results — always reset before rebuilding.

### SPI flash programming (Feature 5)

After rebuilding, the bitstream must be written to SPI flash rather than just JTAG-programmed.  This requires a separate Tcl script (`tools/flash_board.tcl`) that generates a `.mcs` file and writes it to the onboard W25Q128JV flash.  Takes ~2 minutes but only needed after rebuilds.  JTAG programming (`program_board.tcl`) remains available as a faster option during active development.

### Future improvement — JTAG bulk data readback

For very high flip counts (e.g. 120s hold with tens of thousands of flips), UART becomes a bottleneck even at 921600 baud.  An alternative architecture: after SCAN, the FPGA signals completion via UART (just the summary line), then Python reads the BRAM address buffer directly over JTAG using Vivado's `hw_server`.

Implementation outline:
- Name the BRAM buffer with a Vivado-accessible net name or instantiate it as a true `RAMB36` primitive
- Python connects to `hw_server` via `pyvivado` or the XSDB Tcl server (`localhost:3121`)
- After receiving the UART summary line, Python issues a JTAG memory read of the BRAM: `read_hw_mem` or equivalent Tcl command
- JTAG on FT2232H achieves ~1–2 MB/s, so 4096 entries × 4 bytes = 16 KB reads in ~10 ms regardless of flip count

This cleanly separates the communication planes: UART for low-bandwidth control and summary data, JTAG for bulk address payload.  Not worth implementing while UART at 921600 baud is sufficient, but revisit if hold times grow beyond 120s.

### UART message compatibility

The Python parser uses regex, so new fields appended to the end of a message are backwards-compatible.  Fields inserted in the middle (like `PAT:XX` in Feature 1) require updating the regex in `parse_line()` at the top of `uart_logger.py`.
