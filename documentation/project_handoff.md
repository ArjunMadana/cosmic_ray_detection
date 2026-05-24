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

`tools/run_diagnostics.py` can automate the investigation without using the GUI:

```bash
python -B tools/run_diagnostics.py --port auto --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

It resets with `X`, waits for `READY`, sends `H`, `P`, `R`, and `G`, then writes raw JSONL plus CSV/Markdown summaries under `data/diagnostics`. Replay mode classifies existing captures:

```bash
python -B tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
```

The 2026-04-24 capture predates `DIAG`, so it can show the first-read spike but is classified as `NO_DIAG` for root-cause localization.

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

## Flashing Notes

`tools/flash_board.tcl` generates `cosmic_top.mcs` from the current implementation bitstream, creates the Arty S7 SPI cfgmem object, binds it to the FPGA device with `PROGRAM.HW_CFGMEM`, loads Vivado's temporary flash programmer bitstream when required, and then runs `program_hw_cfgmem`.

If `flash_board.log` reports `Flash Programming Unsuccessful: Failure to set flash parameters`, retry with the updated script. The bitstream-to-MCS step can still succeed even when the later SPI programmer setup fails.

## Verification Status

Completed locally:

- Python parser/storage tests pass with `python -B -m unittest tools.test_uart_logger_parser`.
- Diagnostic runner tests pass with `python -B -m unittest tools.test_run_diagnostics`.
- Python syntax check passes with bytecode disabled.
- `xvlog` compiled `detector_fsm.v` and `detector_fsm_tb.v`.
- `xsim detector_fsm_tb_sim -runall` passed and printed `detector_fsm_tb PASS`.

Not completed in this environment:

- Hardware acceptance, because no board is attached to this session.
