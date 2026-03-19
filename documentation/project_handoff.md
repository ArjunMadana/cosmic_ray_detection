# DRAM Dosimeter — Project Handoff for Claude Code

## Project overview

DRAM-based cosmic ray / radiation detector on a Digilent Arty S7-25 (Spartan-7). Uses DDR3 bit flips as a dosimetry mechanism — write a known pattern to all of DRAM, wait, read it back, count mismatches. Elevated bit-flip rates above baseline indicate radiation exposure.

**Board:** Digilent Arty S7-25, Spartan-7 XC7S25, MT41K128M16JT DDR3 (256 MB)

**Architecture:**
- Vivado block design with MIG 7 Series (DDR3 controller), AXI SmartConnect, Clocking Wizard
- `cosmic_top.v` — top module, wraps the block design and instantiates two custom modules
- `detector_fsm.v` — main FSM: WAIT_INIT → FILL → HOLD → SCAN → REPORT → SETTLE → loops
- `uart_tx.v` — 115200 baud UART transmitter on `ui_clk` (83.333 MHz from MIG, NOT 150 MHz)
- `rank_common.v` through 11 levels of MIG hierarchy — modified to accept external refresh tick

**Vivado project location:** `C:/_CAMSIN/cosmic_ray_detection/`

## What we built and changed

### Phase 1: Address mapping fix (DONE)
- FSM was incrementing AXI address by 1 instead of 4 (byte-addressed bus, 32-bit transfers)
- Each word was being written/read 4 times, only covering ~4 MB of 256 MB DRAM
- **Fix:** Changed `addr + 1` to `addr + 4` in both FILL and SCAN states
- Changed boundary checks from `MEM_SIZE - 1` to `MEM_SIZE - 4`
- `MEM_SIZE = 28'h1000000` (16 MB) — covers 4M unique 32-bit words

### Phase 2: SETTLE state for hang fix (DONE, but hang persists)
- Added SETTLE state between REPORT and FILL to drain in-flight AXI responses
- Initial version was 1-cycle unconditional transition — still hung after ~14-30 prints
- Updated to wait on `!bvalid && !rvalid` — improved but **hang still occurs**
- Current SETTLE:
```verilog
SETTLE: begin
    awvalid     <= 0;
    wvalid      <= 0;
    arvalid     <= 0;
    if (!bvalid && !rvalid) begin
        addr        <= 0;
        hit_counter <= 0;
        state       <= FILL;
    end
end
```
- **The hang is the #1 remaining bug.** It gets further now (~30 loops) but still eventually stops.
- Hypothesis: flipping switches mid-cycle may be a trigger, or there's a deeper AXI handshake issue

### Phase 3: Controllable refresh rate (DONE)
- `refresh_tick` signal routed from `detector_fsm.v` through 11 levels of MIG hierarchy down to `rank_common.v`
- `rank_common.v` line 162: `assign refresh_tick = ext_refresh_tick;` (was `= 1'b0`)
- FSM generates single-cycle refresh tick pulses at programmable period
- Two slide switches select refresh rate:
  - `{sw1, sw0} = 00` → OFF (no refresh, original behavior)
  - `{sw1, sw0} = 01` → ~100 ms period (REF_SLOW = 15,000,000 cycles)
  - `{sw1, sw0} = 10` → ~7.8 µs period (REF_NORMAL = 1,170 cycles) — DDR3 standard
  - `{sw1, sw0} = 11` → ~3.9 µs period (REF_FAST = 585 cycles)
- **Verified working on hardware** — switches OFF gives ~750 flips/5s, REF_NORMAL gives near-zero

### Signal chain for ext_refresh_tick (all files modified):
```
detector_fsm.v (refresh_tick_out)
  → cosmic_top.v (wire refresh_tick_out)
    → cosmic_bd_wrapper.v (ext_refresh_tick)
      → cosmic_bd.v (ext_refresh_tick)
        → cosmic_bd_mig_7series_0_2.v (IP top, Level 7)
          → cosmic_bd_mig_7series_0_2_mig.v (Level 6)
            → mig_7series_v4_2_memc_ui_top_axi.v (Level 5)
              → mig_7series_v4_2_mem_intfc.v (Level 4)
                → mig_7series_v4_2_mc.v (Level 3)
                  → mig_7series_v4_2_rank_mach.v (Level 2)
                    → mig_7series_v4_2_rank_common.v (Level 1)
```

### Pin assignments (cosmic_constraints.xdc):
- SW0 = H14 (refresh bit 0)
- SW1 = H18 (refresh bit 1)
- BTN0 = K16 (10s hold)
- BTN1 = J16 (20s hold)
- BTN2 = H15 (30s hold)
- BTN3 = G15 (5s hold / default)
- UART TX = R12
- LED0 = E18 (calib_complete indicator)
- LED1 = F13 (FSM active indicator)
- sys_clock = F14

## Current FSM states
```
WAIT_INIT (0) → FILL (1) → HOLD (2) → SCAN (3) → REPORT (4) → SETTLE (5) → FILL...
```

## Current UART output format
```
05s:XXXXXXXX\r\n
```
Where `05` / `10` / `20` / `30` is the hold time in seconds, XXXXXXXX is the hex flip count.

## Known issues and concerns

### 1. Hang bug (HIGH PRIORITY)
- FSM stops printing after ~14-30 iterations
- Improved by SETTLE state but not eliminated
- Switching switches mid-run may trigger it
- **Root cause theories:**
  - AXI response still in flight when FILL starts despite bvalid/rvalid check
  - FILL state might issue a write before the previous bvalid is properly consumed
  - The `bready <= 1` is always asserted — if MIG pulses bvalid for exactly 1 cycle and it coincides with the SETTLE→FILL transition, the bvalid check might miss it
  - Possible: `rvalid` or `bvalid` gets stuck high after many iterations
- **Debugging ideas:**
  - Add a watchdog counter — if any state takes > N cycles, force reset to FILL
  - Add LED indicators for current state (encode state[2:0] on RGB LEDs)
  - Log the state the FSM was in when it hung (use LEDs or additional UART output)
  - Use an ILA (Integrated Logic Analyzer) core in Vivado to capture the AXI signals

### 2. Low flip counts with partial refresh (MEDIUM PRIORITY)
- With SW0 only (100ms refresh), seeing only 1-5 flips per 5s scan
- User expected more flips at 100ms refresh interval
- **This is actually expected:** REF_SLOW = 15M cycles ≈ 100ms. The MIG issues a refresh to ALL rows every time refresh_tick fires. DDR3 has 8192 rows, and at 100ms interval each row gets refreshed every 100ms. Only cells with retention time < 100ms will fail. At room temperature, very few cells are that weak.
- **If more granularity is desired:** add intermediate refresh rates (500ms, 1s, 2s, 5s) to see the retention distribution curve more clearly
- **Alternative explanation to investigate:** the `refresh_tick` might need to be a specific pulse width or timing relationship that we're not matching. Verify by checking that REF_NORMAL (7.8µs) actually produces zero flips consistently — if it does, the mechanism is correct.

### 3. UART format doesn't show refresh setting (LOW PRIORITY)
- Currently impossible to tell from UART output which refresh rate was active
- Planned format: `05s:R0:XXXXXXXX\r\n` where R0-R3 is the refresh preset
- Not yet implemented

### 4. Switch changes not visible in output (LOW PRIORITY)
- User wants to see when switches are flipped
- Could print a status line when switch state changes
- Or just include refresh setting in every output line (see #3)

### 5. Error location reporting (LOW PRIORITY, professor requested)
- Print address of first error in each scan
- Or full memory dump mode
- Not yet implemented
- Planned: capture `first_error_addr` during SCAN, print in REPORT

### 6. Unexpectedly low flip counts (NEEDS INVESTIGATION)
- With refresh off (both switches down), seeing ~750 flips per "5s" scan of 4M words
- Previous runs (before address fix) showed ~1400 flips at "10s" hold
- Possible causes:
  a) SCAN reads implicitly refresh DRAM rows — the row-activate during read
     restores charge to all cells in that row, so later reads in the same row
     see already-refreshed data. This is a fundamental issue with sequential
     scan-back and may require a different approach (random sampling, or
     reading only a subset of addresses)
  b) Pattern is 0x00000000 — only detects one polarity of bit decay.
     Switching to 0x55555555 or 0xAAAAAAAA tests both polarities and should
     show more flips. Testing with 0xFFFFFFFF and comparing to 0x00000000
     would reveal the asymmetry.
  c) Clock frequency mismatch — if ui_clk is 83 MHz, hold times are ~1.8x
     longer than labeled (5s label = 9s actual). This increases flips, so
     the true per-second rate is even lower than it appears.
- To investigate: run identical hold times with PATTERN=0x00, 0xFF, 0x55, 0xAA
  and compare. If 0x55 gives significantly more flips, it's the polarity issue.
  If counts are still low across all patterns, the read-refresh effect is likely
  dominant and a different scan strategy is needed.

## Important technical details

### Clock frequency
- `ui_clk` from MIG is 83.333 MHz (NOT 150 MHz)
- The MIG on Arty S7-25 with 3000ps tCK (333 MHz DDR) and nCK_PER_CLK=2 gives ui_clk = 333/4 = 83.33 MHz
- **All cycle count calculations must use 83.333 MHz:**
  - CYCLES_5S should be = 83,333,333 * 5 = 416,666,665
  - Current code uses 750,000,000 (based on 150 MHz assumption) — this means hold times are ~1.8x longer than labeled
  - REF_NORMAL = 1,170 cycles at 83 MHz = 14 µs (not 7.8 µs) — still works but is 2x slower than spec
  - **This should be verified and fixed** — check ui_clk frequency with a scope or XADC, or look at the MIG IP configuration in Vivado

### MIG configuration
- DDR3 part: MT41K128M16JT-15E (128M x 16-bit = 256 MB)
- tCK = 3000 ps (333 MHz DDR clock)
- nCK_PER_CLK = 2
- 16-bit data bus, AXI data width = 32 bits
- BANK_ROW_COLUMN address mapping
- AXI address width = 28 bits (byte-addressed, 256 MB range)

### DRAM address space
- Full range: 0x0000000 to 0x0FFFFFC (256 MB, 64M words)
- Current MEM_SIZE = 0x1000000 (16 MB, 4M words) — only tests 1/16 of DRAM
- Increasing MEM_SIZE increases FILL and SCAN time proportionally
- With addr+4 stepping, 4M words at ~1 AXI transaction per cycle takes ~48ms at 83 MHz

### Pattern
- Currently `PATTERN = 32'h00000000` (all zeros)
- Was previously `32'h55555555` (commented out, and `32'hFFFFFFFF` also commented)
- All-zeros means you're counting cells that flip FROM 0 TO 1 during retention
- Consider testing with multiple patterns (0x00, 0xFF, 0x55, 0xAA) to catch different failure modes

### Files modified from original Vivado IP
The MIG IP source files were edited in-place under the `.gen` directory. If the MIG IP is ever regenerated/reset in Vivado, these changes will be lost. The edited files are:
```
.gen/sources_1/bd/cosmic_bd/ip/cosmic_bd_mig_7series_0_2/cosmic_bd_mig_7series_0_2/user_design/rtl/
  controller/mig_7series_v4_2_rank_common.v
  controller/mig_7series_v4_2_rank_mach.v
  controller/mig_7series_v4_2_mc.v
  ip_top/mig_7series_v4_2_mem_intfc.v
  ip_top/mig_7series_v4_2_memc_ui_top_axi.v
  cosmic_bd_mig_7series_0_2_mig.v
  cosmic_bd_mig_7series_0_2.v
```
Also edited:
```
.gen/sources_1/bd/cosmic_bd/hdl/cosmic_bd.v
.gen/sources_1/bd/cosmic_bd/hdl/cosmic_bd_wrapper.v  (or in .srcs)
```

## Professor's requests (from original conversation)

1. ✅ **Controllable refresh rate** — done, orthogonal to read/write via switches
2. ⬜ **Print memory where errors occur** — not started, capture first_error_addr in SCAN
3. ⬜ **Address mapping investigation** — partially done (fixed the +1/+4 bug), but should explain how AXI byte addresses map to physical DRAM row/bank/column (BANK_ROW_COLUMN mapping means low bits are column, then row, then bank)

## Next steps (priority order)

1. **Fix the hang bug** — this blocks all useful data collection
2. **Fix clock frequency constants** — verify ui_clk is 83 MHz and update all CYCLES_* and REF_* localparams
3. **Add refresh rate to UART output** — trivial change to REPORT state
4. **Add first error address to output** — requires new reg + SCAN logic + REPORT extension
5. **Increase MEM_SIZE** to cover more DRAM — easy param change once hang is fixed
6. **Add intermediate refresh rates** — for better retention distribution curves
7. **XADC temperature logging** — normalize baseline against thermal drift
