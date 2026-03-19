# Refresh Control Implementation — Exact Edit Guide

## Overview

At every level, two edits:
1. **Add `input ext_refresh_tick` to the module's port list**
2. **Add `.ext_refresh_tick(ext_refresh_tick)` to the child module's instantiation**

Work bottom-up (Level 1 → Level 7), then BD wrapper, then cosmic_top + detector_fsm.

---

## Level 1 — `mig_7series_v4_2_rank_common.v`

### Edit 1A: Add input port

Find this block (around line 93–95, the Inputs section of the `/*AUTOARG*/` port list):

```verilog
  // Inputs
  clk, rst, init_calib_complete, app_ref_req, app_zq_req, app_sr_req,
  insert_maint_r1, refresh_request, maint_wip_r, slot_0_present, slot_1_present,
  periodic_rd_request, periodic_rd_ack_r
  );
```

**Change to** (add `ext_refresh_tick` to the input list):

```verilog
  // Inputs
  clk, rst, init_calib_complete, app_ref_req, app_zq_req, app_sr_req,
  insert_maint_r1, refresh_request, maint_wip_r, slot_0_present, slot_1_present,
  periodic_rd_request, periodic_rd_ack_r,
  ext_refresh_tick
  );
```

Then below `input clk;` / `input rst;` (around line 105–106), add:

```verilog
  input ext_refresh_tick;
```

### Edit 1B: Use the external tick

Find line 158–159:

```verilog
  output wire refresh_tick;
//  assign refresh_tick = refresh_tick_lcl;
  assign refresh_tick = 1'b0;
```

**Change to:**

```verilog
  output wire refresh_tick;
//  assign refresh_tick = refresh_tick_lcl;
//  assign refresh_tick = 1'b0;
  assign refresh_tick = ext_refresh_tick;
```

---

## Level 2 — `mig_7series_v4_2_rank_mach.v`

### Edit 2A: Add input port

Find the `/*AUTOARG*/` port list (line 94–104). The Inputs section:

```verilog
  // Inputs
  wr_this_rank_r, slot_1_present, slot_0_present, sending_row,
  sending_col, rst, rd_this_rank_r, rank_busy_r, periodic_rd_ack_r,
  maint_wip_r, insert_maint_r1, init_calib_complete, clk, app_zq_req,
  app_sr_req, app_ref_req, app_periodic_rd_req, act_this_rank_r
  );
```

**Change to:**

```verilog
  // Inputs
  wr_this_rank_r, slot_1_present, slot_0_present, sending_row,
  sending_col, rst, rd_this_rank_r, rank_busy_r, periodic_rd_ack_r,
  maint_wip_r, insert_maint_r1, init_calib_complete, clk, app_zq_req,
  app_sr_req, app_ref_req, app_periodic_rd_req, act_this_rank_r,
  ext_refresh_tick
  );
```

Then in the `/*AUTOINPUT*/` section (around line 106–127), add anywhere among the inputs:

```verilog
  input                 ext_refresh_tick;   // To rank_common0 of rank_common.v
```

### Edit 2B: Wire to `rank_common0` instantiation

Find the `rank_common0` instantiation (line 225–255). At the end of its Inputs section, find:

```verilog
     .periodic_rd_request               (periodic_rd_request[RANKS-1:0]),
     .periodic_rd_ack_r                 (periodic_rd_ack_r));
```

**Change to:**

```verilog
     .periodic_rd_request               (periodic_rd_request[RANKS-1:0]),
     .periodic_rd_ack_r                 (periodic_rd_ack_r),
     .ext_refresh_tick                  (ext_refresh_tick));
```

---

## Level 3 — `mig_7series_v4_2_mc.v`

### Edit 3A: Add input port

Find the end of the module's port list (around line 244–249):

```verilog
    input [6*RANKS-1:0]                       calib_rd_data_offset,
    input [6*RANKS-1:0]                       calib_rd_data_offset_1,
    input [6*RANKS-1:0]                       calib_rd_data_offset_2

  );
```

**Change to:**

```verilog
    input [6*RANKS-1:0]                       calib_rd_data_offset,
    input [6*RANKS-1:0]                       calib_rd_data_offset_1,
    input [6*RANKS-1:0]                       calib_rd_data_offset_2,

    input                                     ext_refresh_tick

  );
```

### Edit 3B: Wire to `rank_mach0` instantiation

Find the end of `rank_mach0` inputs (around line 618–621):

```verilog
        .slot_0_present       (slot_0_present[7:0]),
        .slot_1_present       (slot_1_present[7:0]),
        .wr_this_rank_r       (wr_this_rank_r[RANK_BM_BV_WIDTH-1:0])
      );
```

**Change to:**

```verilog
        .slot_0_present       (slot_0_present[7:0]),
        .slot_1_present       (slot_1_present[7:0]),
        .wr_this_rank_r       (wr_this_rank_r[RANK_BM_BV_WIDTH-1:0]),
        .ext_refresh_tick     (ext_refresh_tick)
      );
```

---

## Level 4 — `mig_7series_v4_2_mem_intfc.v`

### Edit 4A: Add input port

Find the very end of the port list (around line 397–399):

```verilog
   ,output [1023:0]          dbg_poc

   );
```

**Change to:**

```verilog
   ,output [1023:0]          dbg_poc

   ,input                    ext_refresh_tick

   );
```

### Edit 4B: Wire to `mc0` instantiation

Find the end of `mc0` inputs (around line 653–655):

```verilog
      .fi_xor_we          (fi_xor_we),
      .fi_xor_wrdata          (fi_xor_wrdata),
      .use_addr               (use_addr));
```

**Change to:**

```verilog
      .fi_xor_we          (fi_xor_we),
      .fi_xor_wrdata          (fi_xor_wrdata),
      .use_addr               (use_addr),
      .ext_refresh_tick       (ext_refresh_tick));
```

---

## Level 5 — `mig_7series_v4_2_memc_ui_top_axi.v`

### Edit 5A: Add input port

Find the end of the port list (around line 474–477):

```verilog
   output [1023:0]                    dbg_poc

   );
```

**Change to:**

```verilog
   output [1023:0]                    dbg_poc,

   input                              ext_refresh_tick

   );
```

### Edit 5B: Wire to `mem_intfc0` instantiation

Find around line 791–793 (near the `fi_xor` lines, before the debug signals):

```verilog
      .fi_xor_we                (fi_xor_we),
      .fi_xor_wrdata            (fi_xor_wrdata),
```

**Change to:**

```verilog
      .fi_xor_we                (fi_xor_we),
      .fi_xor_wrdata            (fi_xor_wrdata),
      .ext_refresh_tick         (ext_refresh_tick),
```

(This adds it before the debug section. The comma is fine — the debug signals follow.)

---

## Level 6 — `cosmic_bd_mig_7series_0_2_mig.v`

**Note:** This file has extra blank lines between every line of code. Edit carefully.

### Edit 6A: Add input port

Find `sys_rst` at the end of the module's port list (around line 677):

```verilog
   input                                        sys_rst
```

**Change to:**

```verilog
   input                                        sys_rst,
   input                                        ext_refresh_tick
```

(Add comma after `sys_rst`, then the new port, then the existing closing paren/semicolon should follow on a later line.)

### Edit 6B: Wire to `u_memc_ui_top_axi` instantiation

Find around line 1280–1284:

```verilog
       .app_sr_req                       (1'b0),
       .app_sr_active                    (),
       .app_ref_req                      (1'b0),
       .app_ref_ack                      (),
       .app_zq_req                       (1'b0),
```

Add the new wire nearby. Find the end of that instantiation's inputs (search for the closing `);` of `u_memc_ui_top_axi`, around line 1352):

```verilog
       .init_calib_complete              (init_calib_complete),
```

Look for the last line before `);` and add there. The safest approach: find any line near the end and add before the closing `);`:

```verilog
       .ext_refresh_tick                 (ext_refresh_tick),
```

Add this line just before the `);` that closes the `u_memc_ui_top_axi` instantiation. Make sure the previous line has a comma.

---

## Level 7 — `cosmic_bd_mig_7series_0_2.v` (IP top-level)

### Edit 7A: Add input port

Find the end of the module port list. Search for where `sys_rst` appears as a port:

```verilog
   input        sys_rst
   );
```

**Change to:**

```verilog
   input        sys_rst,
   input        ext_refresh_tick
   );
```

### Edit 7B: Wire to `u_cosmic_bd_mig_7series_0_2_mig` instantiation (around line 157)

Find the instantiation of the `_mig` child. Search for the last port before `);`:

```verilog
      .sys_rst       (sys_rst)
   );
```

**Change to:**

```verilog
      .sys_rst       (sys_rst),
      .ext_refresh_tick (ext_refresh_tick)
   );
```

---

## Level 8 — `cosmic_bd_wrapper.v` (Block Design wrapper)

This file wraps the block design and instantiates `cosmic_bd_mig_7series_0_2`.

### Edit 8A: Add port to wrapper module

Find the module port list and add:

```verilog
   input ext_refresh_tick,
```

alongside the other MIG-related ports (like `init_calib_complete_0`, `ui_clk_0`, etc).

### Edit 8B: Wire to the MIG IP instance

Find where `cosmic_bd_mig_7series_0_2` is instantiated inside the wrapper (or inside the `cosmic_bd.v` that the wrapper calls). Add:

```verilog
      .ext_refresh_tick (ext_refresh_tick),
```

**Important:** The BD wrapper may instantiate an intermediate `cosmic_bd` module. If so, you need to add the port at both levels:
1. `cosmic_bd_wrapper.v` → `cosmic_bd` instance
2. `cosmic_bd.v` → `cosmic_bd_mig_7series_0_2` instance

Search for `mig_7series_0_2` inside the wrapper to see the chain. If there's an intermediate `cosmic_bd.v`, you'll need to edit that too (same pattern: add port, wire through).

---

## Level 9 — `cosmic_top.v`

### Edit 9A: Add `sw1` input and wire

In the module port list, add a new switch input:

```verilog
    input  wire        sw1,
```

### Edit 9B: Add `ext_refresh_tick` wire

After the existing internal wire declarations:

```verilog
wire refresh_tick_out;   // from FSM to MIG via BD
```

### Edit 9C: Wire to BD wrapper

In the `cosmic_bd_wrapper u_bd` instantiation, add:

```verilog
        .ext_refresh_tick   (refresh_tick_out),
```

### Edit 9D: Wire to FSM

In the `detector_fsm u_fsm` instantiation, add:

```verilog
        .sw1            (sw1),
        .refresh_tick_out (refresh_tick_out),
```

---

## Level 10 — `detector_fsm.v`

### Edit 10A: Add ports

In the module port list, add:

```verilog
    input  wire        sw1,
    output reg         refresh_tick_out,
```

### Edit 10B: Add refresh timer logic

Add these localparams near the existing ones:

```verilog
localparam REF_OFF      = 32'h0;           // no refresh (current behavior)
localparam REF_SLOW     = 32'd15_000_000;  // ~100 ms at 150 MHz
localparam REF_NORMAL   = 32'd1_170;       // ~7.8 us (DDR3 spec)
localparam REF_FAST     = 32'd585;         // ~3.9 us (2x normal rate)
```

Add these regs near the existing ones:

```verilog
reg [31:0] refresh_counter;
reg [31:0] refresh_period;
reg [1:0]  refresh_sel;
```

### Edit 10C: Add refresh timer always block

Add this as a **separate always block** (outside the existing one), or integrate into the existing block. Separate is cleaner:

```verilog
// Refresh tick generator — runs independently of FSM state
always @(posedge clk) begin
    if (rst) begin
        refresh_counter  <= 0;
        refresh_tick_out <= 0;
        refresh_period   <= REF_OFF;
        refresh_sel      <= 0;
    end else begin
        refresh_sel <= {sw1, sw0};
        case (refresh_sel)
            2'd0: refresh_period <= REF_OFF;
            2'd1: refresh_period <= REF_SLOW;
            2'd2: refresh_period <= REF_NORMAL;
            2'd3: refresh_period <= REF_FAST;
        endcase

        refresh_tick_out <= 1'b0;  // default: single-cycle pulse
        if (refresh_period != 0) begin
            if (refresh_counter >= refresh_period) begin
                refresh_counter  <= 0;
                refresh_tick_out <= 1'b1;
            end else begin
                refresh_counter <= refresh_counter + 1;
            end
        end else begin
            refresh_counter <= 0;
        end
    end
end
```

---

## Level 11 — `cosmic_constraints.xdc`

Add the SW1 pin. On the Arty S7-25, the second switch should be on pin J14 (check your board schematic):

```xdc
set_property PACKAGE_PIN J14 [get_ports sw1]
set_property IOSTANDARD LVCMOS33 [get_ports sw1]
```

If your board doesn't have SW1, you can repurpose one of the buttons instead — just change the FSM to use a button edge for cycling through refresh rates.

---

## Verification checklist

After all edits, before synthesizing:

- [ ] Every file in the chain compiles without syntax errors
- [ ] Every `.ext_refresh_tick(ext_refresh_tick)` has matching commas (no trailing comma before `);`, no missing comma before it)
- [ ] `cosmic_bd_wrapper.v` successfully passes the signal from `cosmic_top` down to the MIG IP
- [ ] `sw0` and `sw1` are both connected in the constraints file
- [ ] The refresh timer's `REF_NORMAL` period (~1170 cycles at 150 MHz ≈ 7.8 µs) matches DDR3 tREFI/8192

## Quick smoke test

1. Program the board with both switches OFF (sw1=0, sw0=0 → REF_OFF) — should behave identically to before (no refresh, bit flips accumulate)
2. Flip sw0 ON (sw1=0, sw0=1 → REF_SLOW, ~100ms) — should see dramatically fewer flips
3. Flip sw1 ON (sw1=1, sw0=0 → REF_NORMAL, ~7.8µs) — should see near-zero flips
4. Both ON (sw1=1, sw0=1 → REF_FAST) — should also see near-zero flips

If step 1 matches your old data and step 3 drops to near-zero, the plumbing is correct.
