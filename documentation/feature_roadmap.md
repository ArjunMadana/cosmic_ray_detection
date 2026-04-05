# Feature Roadmap — DRAM Dosimeter
*Last updated: 2026-04-04 (Feature 1 complete)*

This document is broken into self-contained feature tasks that can each be delegated to a separate Claude chat.  Each task has its own context, exact files to read, and a precise implementation spec so agents don't waste time re-exploring.

---

## Project snapshot (read this first)

**Board:** Digilent Arty S7-25 (Spartan-7 XC7S25, 256 MB MT41K128M16JT DDR3)  
**ui_clk:** 150 MHz (confirmed — uart_tx.v uses CLK_FREQ=150_000_000 and baud works)  
**UART:** 115200 8N1 over USB-JTAG FTDI (COM3 typically).  TX=R12, RX=V12 (bank 14).  
**AXI bus:** 32-bit data, 28-bit byte address.  Stepping by +4 covers one 32-bit word.  
**Current MEM_SIZE:** 0x4000000 = 64 MB (25% of physical DRAM).

### FSM state machine (detector_fsm.v)

```
WAIT_INIT → FILL → FILL2 → HOLD → SCAN → REPORT → SETTLE → FILL (loop)
                              ↕         
                    PRINT_REF / PRINT_INT / PRINT_PAT  (interrupt states, return to HOLD)
```

- **FILL / FILL2:** writes `active_pattern` to every address 0→MEM_SIZE-4 step 4 — twice per cycle to ensure all cells are written before the hold starts
- **HOLD:** counts `hold_cycles_sel` clock cycles before proceeding
- **SCAN:** reads every address, increments `hit_counter` on `rdata != active_pattern`
- **REPORT:** sends `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX\r\n` (33 bytes) over UART TX
- **SETTLE:** waits for AXI to drain before re-entering FILL

### UART command interface (already implemented)

The FSM accepts single-letter ASCII commands over UART RX (`H<N>\n` for hold time).  Pattern is in the `rx_valid` block around line 183 of detector_fsm.v.  Extend this block for new commands.

### UART printing pattern (already implemented)

Print states (`PRINT_REF`, `PRINT_INT`) use a `report_idx` counter with one `uart_data` assignment per index.  Reuse this exact pattern for any new print states.  The `uart_valid` handshake: set `uart_valid=1` while `report_idx < N`, then clear it and transition state on `report_idx == N`.

### Python GUI (tools/uart_logger.py)

Tkinter + matplotlib.  Key classes: `SerialReader` (thread), `DataStore` (CSV+JSONL), `DosimeterApp` (GUI).  UART messages are parsed in `parse_line()` using regexes at the top of the file.  New UART messages need a new regex + handling in `_handle_record()`.  New GUI controls go in `_build_ui()`, row 4 (controls strip).

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

## Feature 2 — First + last error address reporting

**Goal:** During SCAN, track the address of the first flip and the address of the last flip.  Report both in the REPORT message.  This enables distinguishing cosmic ray events (tight address cluster = nearby cells) from thermal decay (spread across the full address range).

**Why:** A cosmic ray hitting DRAM deposits charge along an ionization track spanning a few adjacent rows.  Thermal decay is uniformly distributed.  If first and last error addresses are close together (small spread), the flips likely have a common spatial cause.  If spread is near MEM_SIZE, it's diffuse thermal noise.

### Files to read before starting

1. `cosmic_ray_detection.srcs/sources_1/new/detector_fsm.v` — full file, especially SCAN state (~lines 262-279) and REPORT state (~lines 283-329)
2. `tools/uart_logger.py` — `parse_line()`, `DataStore`, `_build_ui()`, `_redraw()`

### Firmware changes (detector_fsm.v)

1. **Add registers** to the declaration block:
   ```verilog
   reg [27:0] first_error_addr;
   reg [27:0] last_error_addr;
   reg        error_found;
   ```

2. **Reset** all three in the reset block.

3. **In SCAN state**, on transition to SCAN (when `hold_counter` expires in HOLD):
   ```verilog
   error_found <= 0;
   ```

4. **Inside SCAN**, when `rdata != active_pattern` (or `PATTERN` if Feature 1 not done yet):
   ```verilog
   if (!error_found) begin
       first_error_addr <= addr;
       error_found      <= 1;
   end
   last_error_addr <= addr;  // always update
   hit_counter     <= hit_counter + 1;
   ```

5. **Latch addresses** when transitioning to REPORT:
   ```verilog
   // Already have: report_shift <= hit_counter;
   // Add two more shift registers or print them inline
   ```
   Simplest approach: add `reg [27:0] report_first_addr` and `reg [27:0] report_last_addr`, latched at the SCAN→REPORT transition alongside `report_shift`.

6. **Extend REPORT format**:
   ```
   HOLD:NNNNs FLIPS:XXXXXXXX FIRST:XXXXXXX LAST:XXXXXXX\r\n
   ```
   - `FIRST:` + 7 hex digits (28-bit address) = 13 chars
   - ` LAST:` + 7 hex digits = 13 chars
   - Total new length: 27 + 1 + 13 + 1 + 13 = **55 bytes** (or 56 with the trailing fields)
   - If Feature 1 is implemented first: `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX FIRST:XXXXXXX LAST:XXXXXXX\r\n` = 61 bytes

   Print 7 hex digits using the same nibble-shift technique as the existing 8-digit FLIPS field.  Use a second shift register for each address.

   If no errors were found (`hit_counter == 0`), print `FIRST:0000000 LAST:0000000`.

7. **Update `report_idx` bound** in the REPORT state to match the new message length.

### Python changes (tools/uart_logger.py)

1. **Update `FLIP_RE`** to capture the two new fields:
   ```python
   FLIP_RE = re.compile(
       r'HOLD:(\d+)s FLIPS:([0-9A-Fa-f]{8})'
       r' FIRST:([0-9A-Fa-f]{7}) LAST:([0-9A-Fa-f]{7})'
   )
   ```
   (Adjust if Feature 1 is merged — include `PAT:XX` group.)

2. **Update `parse_line()`** to extract `first_addr` and `last_addr` (integers, convert with `int(..., 16)`).  Add `addr_spread = last_addr - first_addr`.

3. **Update `DataStore`** CSV fields: add `first_addr`, `last_addr`, `addr_spread`.

4. **Add spread plot to GUI**: in `_redraw()`, add a second subplot (or a twin Y axis) showing `addr_spread` over time alongside flip count.  Color points by spread magnitude — low spread (< 1% of MEM_SIZE) in a bright color as potential cosmic ray events.

5. **Add an alert** for "possible cosmic ray" in `_handle_record()`: if `flip_count > 0` and `addr_spread < threshold` (e.g. < 0x10000 = 64 KB out of 64 MB), log it in yellow: `[POSSIBLE SEU] spread=0xXXXX`.

### Verification

- SCAN with all-ones pattern and no refresh → verify FIRST/LAST addresses are printed in the terminal
- Force a high flip count (short hold, slow refresh) → spread should be near MEM_SIZE
- Verify CSV has all three new columns

---

## Feature 3 — Dual pattern mode

**Goal:** Write `0x55555555` to addresses `0x0000000–(MEM_SIZE/2 - 4)` and `0xAAAAAAAA` to `(MEM_SIZE/2)–(MEM_SIZE - 4)` in a single FILL/SCAN cycle.  This tests both polarities every cycle without requiring separate experiments.

**Prerequisite:** Feature 1 must be completed first.  The `active_pattern` wire and `pattern_sel` register must already exist.

**Why:** `0x55` and `0xAA` are bitwise inverses.  A cell that decays from 1→0 will show up in both halves (where `0x55` has 1s at even bits, `0xAA` has 1s at odd bits).  If both halves show similar flip rates, decay is polarity-symmetric.  If one half shows significantly more, the chip has a preferred decay direction.

### Files to read before starting

1. `cosmic_ray_detection.srcs/sources_1/new/detector_fsm.v` — full file, especially FILL (~lines 223-241), SCAN (~lines 262-279), REPORT state, and any changes introduced by Feature 1
2. `tools/uart_logger.py` — controls strip in `_build_ui()`, `_handle_record()`, `DataStore`

### Firmware changes (detector_fsm.v)

1. **Add** `reg dual_mode` (default 0) to declarations and reset block.

2. **Add** UART command `D<0-1>\n` to the RX parser (same pattern as `P` command from Feature 1).  On `\n`: set `dual_mode`, set `dual_changed` flag (→ PRINT_DUAL state, similar to PRINT_PAT).

3. **Modify FILL state**: when `dual_mode == 1`, select pattern based on address:
   ```verilog
   wdata <= (dual_mode && addr >= (MEM_SIZE >> 1)) ? 32'hAAAAAAAA : 32'h55555555;
   // Note: when dual_mode=0, use active_pattern from Feature 1 as normal
   wdata <= dual_mode ? ((addr >= (MEM_SIZE >> 1)) ? 32'hAAAAAAAA : 32'h55555555)
                      : active_pattern;
   ```

4. **Modify SCAN state**: compare against the same address-dependent pattern:
   ```verilog
   wire [31:0] expected = dual_mode
       ? ((addr >= (MEM_SIZE >> 1)) ? 32'hAAAAAAAA : 32'h55555555)
       : active_pattern;
   // Then: if (rdata != expected) hit_counter <= hit_counter + 1;
   ```
   Note: `wire` inside an `always` block isn't valid — instead compute it as a combinational assign outside the block or use a `reg` updated each cycle.

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

## Feature 4 — Flip count histogram / distribution view in GUI

**Goal:** Add a second plot tab or subplot showing the *distribution* of flip counts across all iterations, as a histogram.  This is the primary tool for distinguishing thermal baseline noise from outlier events (cosmic rays / SEUs).

**No firmware changes required.**  This is pure Python/GUI work.

**Why:** Thermal decay produces a tight, roughly Gaussian flip-count distribution from cycle to cycle.  A cosmic ray hit in one cycle produces a single outlier point far above the mean.  The histogram makes this visually obvious in a way the time-series plot does not.

### Files to read before starting

1. `tools/uart_logger.py` — full file, especially `DosimeterApp`, `_build_ui()`, `_redraw()`, `LivePlotter` (if still present), `DataStore.records`

### Python changes (tools/uart_logger.py)

1. **Convert the single-plot layout to a notebook (ttk.Notebook)** with two tabs:
   - Tab 1: existing time-series scatter plot (unchanged)
   - Tab 2: histogram view

2. **Tab 2 — histogram**:
   - X axis: flip count (binned)
   - Y axis: frequency (number of cycles in each bin)
   - Overlay a vertical dashed red line at mean + 3σ (statistical outlier threshold)
   - Any cycle whose flip count exceeds mean + 3σ is a candidate cosmic ray event — mark those bars a different color (e.g. orange)
   - Display mean, std, and outlier count as text in the plot

3. **Update `_update_plot()`** to redraw both tabs.

4. **Add an "Outliers" section to the log**: whenever a new FLIP record arrives and its flip count exceeds mean + 3σ (computed over all prior records), append a highlighted log line: `[OUTLIER] iter=N flips=X (mean+3σ threshold: Y)`.  This is only meaningful after at least ~20 cycles of data.

5. **Bin count**: auto-scale to `min(50, len(records)//3)` bins, minimum 10 bins.

### Verification

- Run for 30+ cycles, then switch to histogram tab
- Distribution should be roughly bell-shaped
- Manually set a very long hold time for one cycle (creates an outlier) → that bar should appear orange and a log line should fire
- Replay `.jsonl` → histogram reconstructs correctly

---

## Notes for all agents

### How UART print states work (reuse this pattern exactly)

All print states use `report_idx` as a byte counter.  Key rules:
- `report_idx` is incremented at the start of each ready cycle: `report_idx <= report_idx + 1`
- `uart_valid <= 1` while `report_idx < N` (N = total bytes in message)
- On `report_idx == N`, clear `uart_valid` and transition state
- The `else begin uart_valid <= 0; end` branch runs when `uart_ready` is low — it clears valid but does NOT advance the index, so the same byte is re-presented next cycle.  This is intentional — `uart_ready` will go high when the TX shift register is free.

### State encoding

Currently uses 5-bit `state` (`reg [4:0]`).  Assigned values: `WAIT_INIT`=0, `FILL`=1, `HOLD`=2, `SCAN`=3, `REPORT`=4, `SETTLE`=5, `PRINT_REF`=6, `PRINT_INT`=7, `PRINT_PAT`=8, `FILL2`=9.  Next available value is 10.  The 5-bit register supports up to 31 states so there is plenty of headroom.

### Rebuilding after firmware changes

After any change to `.v` files: in Vivado, **right-click Synthesis → Reset Runs** (and Implementation), then run Generate Bitstream.  Incremental synthesis silently reuses stale results — always reset before rebuilding.

### UART message compatibility

The Python parser uses regex, so new fields appended to the end of a message are backwards-compatible.  Fields inserted in the middle (like `PAT:XX` in Feature 1) require updating the regex in `parse_line()` at the top of `uart_logger.py`.
