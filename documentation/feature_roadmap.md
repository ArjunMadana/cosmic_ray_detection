# Feature Roadmap

Last updated: 2026-05-24

## Current Baseline

- UI-only experiment control over UART.
- GUI controls hold, pattern, refresh, start, and reset.
- Firmware clock source is `ui_clk_0 = 166.666667 MHz`.
- UART runs at `921600` baud.
- Address streaming captures up to 4096 addresses and reports overflow.
- Replay uses the same analysis path as live data.
- Cycle diagnostics are emitted and persisted for first-read investigation.

## Implemented Features

### UART Control

Commands: `H`, `P`, `R`, `G`, `X`.

Board acknowledgements and telemetry: `READY`, `INTERVAL`, `PATTERN`, `REFRESH`, `ADDRS`, `HOLD`, `TEMP`, `DIAG`.

### GUI

- Refresh dropdown added beside hold and pattern controls.
- Start sends `H`, `P`, `R`, then `G`.
- Reset Board is enabled immediately after serial connection.
- Start remains disabled until `READY`.
- Replay redraws raw, denoised, and raster tabs.

### Diagnostics

The first-read/pattern-change spike is not hidden as warmup. Firmware emits FILL1, FILL2, SCAN, AXI error, first mismatch, and address-overflow data every cycle.

### Tooling

- `tools/program_board.tcl` opens `cosmic_ray_detection.xpr` in batch mode if needed.
- `tools/flash_board.tcl` generates MCS and programs flash in batch mode.
- `flash_board.bat` invokes the full flash workflow.
- `tools/make_mcs.tcl` remains an MCS-only helper.

## Next Hardware Work

1. Build bitstream and confirm the generated BD hook patches `ext_refresh_tick`.
2. Run hardware acceptance:
   - Connect to an already-powered board.
   - Use Reset Board to recover `READY`.
   - Start with chosen hold/pattern/refresh and confirm first-cycle settings.
   - Change pattern during operation and inspect `DIAG`.
   - Sweep refresh modes and confirm measurable flip-count changes.

## Completed Validation

- `python -B -m unittest tools.test_uart_logger_parser`
- Python AST syntax check for `tools/uart_logger.py` and parser tests.
- `xvlog` compile of `detector_fsm.v` and `detector_fsm_tb.v`.
- `xsim detector_fsm_tb_sim -runall` with `detector_fsm_tb PASS`.

## Future Ideas

- Add a GUI diagnostics tab for `DIAG` records.
- Add hardware-side build-time version reporting.
- Add an automated Vivado batch simulation target for `detector_fsm_tb`.
