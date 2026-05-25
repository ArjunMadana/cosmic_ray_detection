# Feature Roadmap

Last updated: 2026-05-25

## Current Baseline

- UI-only experiment control over UART.
- GUI controls hold, pattern, refresh, start, and reset.
- Firmware timing uses `UI_CLK_HZ = 150 MHz`.
- UART runs at `115200` baud while hardware UART bring-up is being isolated.
- A `BOOT` banner is emitted before the detector FSM is released, so UART pin/framing can be separated from detector/MIG behavior.
- Address streaming captures up to 4096 addresses and reports overflow.
- Replay uses the same analysis path as live data.
- The first-read/pattern-change bug is fixed by strict single-outstanding AXI writes.
- Temporary diagnostic hardware modes were removed from the production FSM.
- Current baseline leaves MIG on internal refresh; `R<n>` is accepted/logged but not applied to MIG until refresh-control restoration is revisited.

## Implemented Features

### UART Control

Commands: `H`, `P`, `R`, `G`, `X`.

Board acknowledgements and telemetry: `READY`, `INTERVAL`, `PATTERN`, `REFRESH`, `ADDRS`, `HOLD`, `TEMP`.

### GUI

- Refresh dropdown added beside hold and pattern controls.
- Start sends `H`, `P`, `R`, then `G`.
- Reset Board is enabled immediately after serial connection.
- Start remains disabled until `READY`.
- Replay redraws raw, denoised, and raster tabs.

### Tooling

- `tools/program_board.tcl` opens `cosmic_ray_detection.xpr` in batch mode if needed.
- `tools/flash_board.tcl` generates MCS and programs flash in batch mode.
- `flash_board.bat` invokes the full flash workflow.
- `tools/make_mcs.tcl` remains an MCS-only helper.

## Next Hardware Work

1. Build bitstream with the production FSM cleanup.
2. Run hardware acceptance:
   - Connect to an already-powered board.
   - Use Reset Board to recover `READY`.
   - Start with chosen hold/pattern/refresh and confirm first-cycle settings.
   - Change pattern during operation and confirm `FLIPS:00000000` remains stable.
   - Run a short refresh sweep once normal operation is clean.

## Completed Validation

- `python -B -m unittest tools.test_uart_logger_parser`
- Python AST syntax check for `tools/uart_logger.py` and parser tests.
- `xvlog` compile of `detector_fsm.v` and `detector_fsm_tb.v`.
- `xsim detector_fsm_tb_sim -runall` with `detector_fsm_tb PASS`.

## Future Ideas

- Add hardware-side build-time version reporting.
- Add an automated Vivado batch simulation target for `detector_fsm_tb`.
