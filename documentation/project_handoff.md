# Project Handoff

Last updated: 2026-05-24

## Current Control Model

The detector is now controlled only through the Python GUI over UART. Physical switches and push buttons are no longer part of the active experiment workflow.

The GUI sends settings on Start in this order:

1. `H<n>\n` for hold seconds.
2. `P<n>\n` for pattern.
3. `R<n>\n` for refresh mode.
4. `G` to start the detector loop.

`X` resets the board-side FSM back to `WAIT_GO`. The GUI enables Reset Board immediately after the serial connection is opened, even before `READY`, so an already-running board can be recovered.

## Source Of Truth

- Firmware clock: `UI_CLK_HZ = 166_666_667`.
- UART baud: `921600`.
- Patterns: `0=FF`, `1=00`, `2=55`, `3=AA`.
- Refresh: `0=OFF`, `1=SLOW`, `2=NORM`, `3=FAST`.
- Vivado patch hook: `tools/expose_device_temp.tcl`.

## Firmware Flow

```text
WAIT_INIT -> READY -> WAIT_GO -> FILL -> FILL2 -> HOLD -> SCAN
          -> ADDRS -> REPORT -> TEMP -> DIAG -> SETTLE -> FILL
```

`P<n>` is latched into `pattern_sel` immediately, but `fill_pattern_sel` is only updated at the next fill boundary. A pattern command during a scan must not affect the in-progress scan.

## Diagnostics

Every cycle emits:

```text
DIAG:F1:XXXXXXXX F2:XXXXXXXX SC:XXXXXXXX BERR:XXXXXXXX RERR:XXXXXXXX BAD:XXXXXXX GOT:XXXXXXXX EXP:XXXXXXXX OVF:X
```

Fields:

- `F1`: accepted write responses in first fill pass.
- `F2`: accepted write responses in second fill pass.
- `SC`: accepted read responses in scan.
- `BERR`: non-OK AXI write responses.
- `RERR`: non-OK AXI read responses.
- `BAD/GOT/EXP`: first mismatch address, observed word, and expected word, or `X` when no mismatch was seen.
- `OVF`: address capture overflow flag.

The GUI stores all records in JSONL and marks FLIP rows with `addr_overflow` when the address capture buffer overflowed.

## Generated Vivado Patch

The generated BD files do not naturally expose MIG `device_temp` or route the custom refresh tick. The pre-synthesis hook patches:

- `cosmic_bd_wrapper.v`
- `cosmic_bd.v`
- `cosmic_bd_mig_7series_0_2.v`
- `cosmic_bd_mig_7series_0_2_mig.v`
- `mig_7series_v4_2_memc_ui_top_axi.v`
- `mig_7series_v4_2_mem_intfc.v`
- `mig_7series_v4_2_mc.v`
- `mig_7series_v4_2_rank_mach.v`
- `mig_7series_v4_2_rank_common.v`

The final patched behavior is `rank_common.refresh_tick = ext_refresh_tick`.

## Verification Status

Completed locally:

- Python parser/storage tests pass with `python -B -m unittest tools.test_uart_logger_parser`.
- Python syntax check passes with bytecode disabled.
- `xvlog` compiled `detector_fsm.v` and `detector_fsm_tb.v`.
- `xsim detector_fsm_tb_sim -runall` passed and printed `detector_fsm_tb PASS`.

Not completed in this environment:

- Hardware acceptance, because no board is attached to this session.
