# DRAM Dosimeter — Implementation Plan

## Executive summary

Three changes are needed, in priority order:

1. **Controllable refresh rate** — route `refresh_tick` out of the MIG as an externally driven input so the FSM can set the refresh period at runtime
2. **Fix address mapping** — the FSM currently increments AXI addresses by 1 instead of 4, meaning it only tests ~25% of DRAM (and redundantly writes the rest)
3. **Error location reporting** — capture and print the first error address each scan cycle
4. **Fix the 3-loop hang bug** — the FSM stops printing after ~3 iterations due to a likely state-machine sequencing issue

---

## Phase 1: Controllable refresh (primary goal)

### Current state

In `mig_7series_v4_2_rank_common.v`, line 158–159:

```verilog
//  assign refresh_tick = refresh_tick_lcl;   // ← original (auto-refresh ~7.8 µs)
    assign refresh_tick = 1'b0;               // ← current (refresh disabled)
```

Auto-refresh is fully disabled. The internal refresh timer still runs, but its output is ignored. This is why you see bit flips at all — without refresh, every cell that can't hold its charge for the full hold period will flip.

### Approach: bring `refresh_tick` up as an external input

Rather than toggling the internal timer on/off, we make `refresh_tick` a port that the FSM drives directly. This gives full control over refresh timing without touching the MIG's internal timer logic at all.

**Why this approach (vs. alternatives):**

| Approach | Pros | Cons |
|----------|------|------|
| **A. External refresh_tick input (recommended)** | Full period control at runtime; minimal MIG surgery; clean separation of concerns | Must trace port through ~3 levels of MIG hierarchy |
| B. Toggle `refresh_tick` between `1'b0` and `refresh_tick_lcl` via a mux | Only two states (on/off); simple | No intermediate refresh rates; binary rather than continuous control |
| C. Use MIG's `app_ref_req` interface | No MIG source changes needed | `app_ref_req` isn't exposed on the AXI wrapper in the block design; getting it out requires similar hierarchy surgery anyway, plus it goes through the MIG's request arbitration which adds unpredictable latency |
| D. Parameterize `REFRESH_TIMER_DIV` at compile time | No RTL changes at runtime | Requires re-synthesis for every refresh rate; useless for an interactive experiment |

### Implementation steps

#### Step 1.1: Modify `rank_common.v`

Add a new input port and wire it:

```verilog
input ext_refresh_tick,          // NEW: external refresh tick input
...
// Replace the hardwired assignment:
//  assign refresh_tick = 1'b0;
    assign refresh_tick = ext_refresh_tick;
```

That's the only change in this file. The internal timer logic (`refresh_timer` generate block) can stay — it just won't be used.

#### Step 1.2: Trace the port up through the MIG hierarchy

The MIG IP is a deep hierarchy. The signal path from `rank_common` up to the top-level MIG wrapper is approximately:

```
rank_common
  → rank_mach (instantiates rank_common)
    → col_mach or mc (instantiates rank_mach)
      → memc_ui_top_std (top-level MIG controller)
        → mig_7series_0 (the IP wrapper in the block design)
```

At each level, you need to:
1. Add `ext_refresh_tick` as an input port
2. Pass it down to the child instantiation

**Practical approach**: In Vivado, search the MIG IP source directory for where `rank_common` is instantiated (likely in `rank_mach.v`). Then search for where `rank_mach` is instantiated, and so on up the chain. At each level, add the port and the wire. Typically 3–4 files need editing.

Once it reaches the top-level MIG wrapper, it becomes a port on the IP block in the block design.

#### Step 1.3: Expose the port on the block design

Two options:
- **Option A (cleaner)**: Add the port to the MIG IP's top-level wrapper, then in the Vivado block design, "Make External" on the new pin so it appears on the BD wrapper. This is the proper way.
- **Option B (faster)**: Bypass the block design entirely — edit `cosmic_bd_wrapper.v` manually to add the port and wire it through to the MIG instance. Less maintainable but avoids re-running the block design automation.

#### Step 1.4: Add refresh timer to the FSM

Add a programmable refresh tick generator in `detector_fsm.v`:

```verilog
// Refresh rate control (active during all states)
reg [31:0] refresh_counter;
reg        refresh_tick_out;   // → ext_refresh_tick
reg [31:0] refresh_period;     // selected via switches
reg [1:0]  refresh_sel;

localparam REF_OFF      = 32'h0;           // no refresh
localparam REF_SLOW     = 32'd15_000_000;  // ~100 ms  (150M * 0.1)
localparam REF_NORMAL   = 32'd1_170;       // ~7.8 µs  (150M * 7.8e-6)
localparam REF_FAST     = 32'd585;         // ~3.9 µs  (half normal)

always @(posedge clk) begin
    if (rst) begin
        refresh_counter  <= 0;
        refresh_tick_out <= 0;
        refresh_period   <= REF_OFF;
        refresh_sel      <= 0;
    end else begin
        // Switch selection (directly active, no edge detect needed)
        // sw0 and sw1 encode 2-bit refresh rate selection
        refresh_sel <= {sw1, sw0};
        case (refresh_sel)
            2'd0: refresh_period <= REF_OFF;
            2'd1: refresh_period <= REF_SLOW;
            2'd2: refresh_period <= REF_NORMAL;
            2'd3: refresh_period <= REF_FAST;
        endcase

        // Generate tick pulse
        refresh_tick_out <= 0;  // default: single-cycle pulse
        if (refresh_period != 0) begin
            if (refresh_counter >= refresh_period) begin
                refresh_counter  <= 0;
                refresh_tick_out <= 1;
            end else begin
                refresh_counter <= refresh_counter + 1;
            end
        end
    end
end
```

Key design decisions:
- **Refresh runs in ALL states** (FILL, HOLD, SCAN, REPORT), not just HOLD. This is important because: during FILL and SCAN you're actively accessing DRAM, and the MIG interleaves refresh commands with your AXI traffic anyway. The experiment controls the *rate* of refresh; whether the FSM is idle or not is orthogonal.
- **Switches select refresh rate**, buttons select hold time — fully orthogonal controls.
- **`REF_OFF` (period=0) disables the counter** entirely, equivalent to the current `refresh_tick = 1'b0`.

#### Step 1.5: Wire it in `cosmic_top.v`

```verilog
wire refresh_tick_out;  // from FSM to MIG

// Add to FSM instantiation:
.refresh_tick_out (refresh_tick_out),

// Add to BD wrapper instantiation:
.ext_refresh_tick (refresh_tick_out),
```

Add `sw1` as a new top-level input (or repurpose one of the buttons).

#### Step 1.6: Update UART report format

Change the output to include refresh setting:

```
05s:R0:0000058A\r\n
```

Where `R0`–`R3` encodes the refresh preset. This makes the data self-documenting.

### Experimental value

With this, you can run a full matrix:

| Refresh | Hold 5s | Hold 10s | Hold 20s | Hold 30s |
|---------|---------|----------|----------|----------|
| OFF     | baseline| baseline | baseline | baseline |
| ~100ms  | ?       | ?        | ?        | ?        |
| ~7.8µs  | ~0      | ~0       | ~0       | ~0       |
| ~3.9µs  | ~0      | ~0       | ~0       | ~0       |

The "OFF → 100ms" transition should show a dramatic drop in bit flips (only cells with retention < 100ms still fail). The "100ms → 7.8µs" transition should bring flips to near-zero. Under radiation, the OFF row will show elevated counts while the 7.8µs row stays near-zero — **that delta is your detection signal**.

---

## Phase 2: Fix address mapping

### The bug

In `detector_fsm.v`, the FSM increments `addr` by 1 for each AXI write:

```verilog
addr <= addr + 1;  // line 158 (FILL) and 188 (SCAN)
```

But AXI uses **byte addressing** and the bus width is 32 bits (4 bytes). With `awsize = 3'b010` (4-byte transfer) in `cosmic_top.v` line 133, each AXI write covers addresses `[addr, addr+3]`. So incrementing by 1 means:

- Write 0: bytes 0–3
- Write 1: bytes 1–4 (overlaps!)
- Write 2: bytes 2–5 (overlaps!)
- Write 3: bytes 3–6 (overlaps!)
- Write 4: bytes 4–7 (finally a new aligned word)

In practice, the MIG likely ignores the low 2 bits (aligns down), so writes to addresses 0, 1, 2, 3 all hit the same 4-byte word. This means:
- **You're writing each word 4 times** (wasted time)
- **You're only testing 1/4 of the address space** you think you are
- **MEM_SIZE = 0x1000000 (16M) × 4 bytes = 64MB**, but with 4× redundancy you're really only covering ~16MB of the 256MB DRAM

### The fix

```verilog
// In FILL:
addr <= addr + 4;   // step by 4 bytes (one 32-bit word)

// In SCAN:
addr <= addr + 4;

// Adjust MEM_SIZE to the actual byte address range:
parameter MEM_SIZE = 28'h1000000  // 16M bytes = 16MB (safe starting point)
// For full 256MB: MEM_SIZE = 28'h0FFFFFFC (last aligned address)
```

**This also affects the Arty S7-25's actual DRAM size.** The MT41K128M16JT has 128M × 16-bit = 2 Gbit = 256 MB. With a 16-bit data bus and 2:1 ratio for DDR3 on the MIG, the effective AXI address space is 28 bits → 256 MB.

Current effective coverage: ~4 MB (16M addresses ÷ 4 redundancy, × 1 byte per unique word = 4MB).
After fix with MEM_SIZE=16MB: 4× more coverage.
With MEM_SIZE pushed to full range: 256 MB coverage (but FILL will take ~6.8 seconds).

**Recommendation**: Start with MEM_SIZE = 28'h1000000 (16 MB) but with correct 4-byte stepping. This gives honest coverage of 4M words = 16 MB. Then optionally increase to test more of the DRAM.

This is very likely what your professor means by "look into the address mapping" — how AXI byte addresses map to physical DRAM row/bank/column, and whether you're actually covering the memory you think you are.

---

## Phase 3: Error location reporting (lower priority)

### Approach

Capture the address of the first error found during each SCAN cycle, then print it in the UART report before the total count.

Changes to `detector_fsm.v`:

```verilog
reg [27:0] first_error_addr;
reg        first_error_found;

// In SCAN state, when an error is detected:
if (rdata != PATTERN) begin
    hit_counter <= hit_counter + 1;
    if (!first_error_found) begin
        first_error_addr  <= addr;
        first_error_found <= 1;
    end
end

// Reset at start of each SCAN:
// (in the HOLD → SCAN transition)
first_error_found <= 0;
```

Update REPORT to print: `05s:R0:@01A3B400:0000058A\r\n`
- `@01A3B400` = first error address (7 hex digits)
- Rest unchanged

The report format change increases the UART output from 14 to 24 characters per line, still trivially fast at 115200 baud (~2 ms total).

### Optional: full memory dump mode

A switch-activated mode where SCAN prints every error address. At 115200 baud, printing one address per line takes ~1 ms. With ~1400 errors per 10s scan, that's ~1.4 seconds of UART output — acceptable. This would be a separate SCAN_DUMP state that streams `ADDR:DATA\r\n` for every mismatch before entering the normal REPORT.

---

## Phase 4: Fix the 3-loop hang

### Diagnosis

After reviewing the FSM, I believe the hang is caused by a subtle issue in the REPORT → FILL transition. When `report_idx == 14` fires:

```verilog
uart_valid  <= 0;
state       <= FILL;
addr        <= 0;
hit_counter <= 0;
```

But `report_idx` is NOT reset here — it gets incremented to 15 and left there. When SCAN later transitions to REPORT, it does set `report_idx <= 0`, so this alone shouldn't cause a hang.

The more likely culprit is the **AXI handshake state** when re-entering FILL. The FSM's FILL state assumes `!awvalid && !wvalid` at entry. If a stale `bvalid` from the previous SCAN cycle is still pending (the MIG holds it for >1 cycle), the FSM might enter FILL, see `bvalid`, and advance `addr` before issuing its first write — corrupting the address sequence.

### Fix

Add explicit AXI signal resets at each state transition:

```verilog
// When entering FILL (from WAIT_INIT or REPORT):
awvalid <= 0;
wvalid  <= 0;
arvalid <= 0;
```

And add a 1-cycle settling state between REPORT and FILL to let any in-flight AXI responses drain:

```verilog
localparam SETTLE = 3'd5;  // new state

// In REPORT, transition to SETTLE instead of FILL:
state <= SETTLE;

// SETTLE: clear all AXI signals, wait one cycle
SETTLE: begin
    awvalid <= 0;
    wvalid  <= 0;
    arvalid <= 0;
    state   <= FILL;
    addr    <= 0;
end
```

This is low-risk and addresses the most probable cause.

---

## Implementation order

I recommend implementing in this order because each phase builds on clean foundations:

1. **Phase 2 (address mapping fix)** — Quick fix, immediately improves data quality, and you'll want correct coverage before running refresh experiments
2. **Phase 4 (3-loop bug fix)** — Add the SETTLE state so you can run long experiments without the hang
3. **Phase 1 (refresh control)** — The main feature, requires MIG hierarchy tracing
4. **Phase 3 (error locations)** — Straightforward addition once everything else is stable

**Estimated effort:**
- Phase 2: ~15 minutes (two line changes + parameter adjustment)
- Phase 4: ~30 minutes (add SETTLE state, reset AXI signals at transitions)
- Phase 1: ~2–3 hours (tracing MIG hierarchy, adding ports at each level, testing)
- Phase 3: ~1 hour (FSM changes + REPORT format extension)

---

## Files to modify

| File | Phase | Changes |
|------|-------|---------|
| `detector_fsm.v` | 1,2,3,4 | Address stepping, SETTLE state, refresh timer, error capture |
| `cosmic_top.v` | 1 | Wire `refresh_tick_out`, add `sw1` port |
| `cosmic_constraints.xdc` | 1 | Add `sw1` pin constraint |
| `mig_7series_v4_2_rank_common.v` | 1 | Change `refresh_tick` to use `ext_refresh_tick` input |
| MIG hierarchy files (3–4 files) | 1 | Add `ext_refresh_tick` port at each level |
| `cosmic_bd_wrapper.v` (or block design) | 1 | Expose `ext_refresh_tick` |

---

## Hardware requirements

- No new hardware needed
- SW0 is already wired (currently unused in FSM) → use for refresh rate bit 0
- SW1 (if available on the Arty S7-25) → refresh rate bit 1
  - If only one switch is available, use 1-bit selection: OFF vs NORMAL refresh
  - Or repurpose one button for refresh cycling
