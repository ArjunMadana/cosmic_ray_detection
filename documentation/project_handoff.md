# Project Handoff

Last updated: 2026-05-25

## Current Control Model

The detector is now controlled only through the Python GUI over UART. Physical switches and push buttons are no longer part of the active experiment workflow.

The GUI sends settings on Start in this order:

1. `H<n>\n` for hold seconds.
2. `P<n>\n` for pattern.
3. `R<n>\n` for refresh mode.
4. `G` to start the detector loop.

`X` resets the board-side FSM back to `WAIT_GO`. The GUI enables Reset Board immediately after the serial connection is opened, even before `READY`, so an already-running board can be recovered.

## Source Of Truth

- Firmware timing clock: `UI_CLK_HZ = 150_000_000`.
- UART baud: `115200`.
- Patterns: `0=FF`, `1=00`, `2=55`, `3=AA`.
- Refresh: `0=OFF`, `1=SLOW`, `2=NORM`, `3=FAST`.
- Vivado patch hook: `tools/expose_device_temp.tcl`.

## Firmware Flow

```text
WAIT_INIT -> READY -> WAIT_GO -> FILL -> FILL2 -> HOLD -> SCAN
          -> ADDRS -> REPORT -> TEMP -> SETTLE -> FILL
```

`P<n>` is latched into `pattern_sel` immediately, but `fill_pattern_sel` is only updated at the next fill boundary. A pattern command during a scan must not affect the in-progress scan.

## Production Telemetry

Every cycle emits:

```text
ADDRS:NNNN OVF:X
<zero or more 7-hex-digit address lines>
HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX
TEMP:XXX
```

The GUI stores all records in JSONL and marks FLIP rows with `addr_overflow` when the address capture buffer overflowed. The diagnostic-only `D<n>`, `DIAG`, and `VDIAG` firmware paths were removed after the write-sequencer fix was proven on hardware, so the active FSM is now the normal experiment path only.

`tools/run_diagnostics.py` can automate the investigation without using the GUI:

```bash
python -B tools/run_diagnostics.py --port auto --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

It resets with `X`, waits for `READY`, sends `H`, `P`, `R`, and `G`, then writes raw JSONL plus CSV/Markdown summaries under `data/diagnostics`. It still understands older `DIAG`/`VDIAG` captures for replay, but current production firmware does not emit those lines. Replay mode classifies existing captures:

```bash
python -B tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
```

The 2026-04-24 capture predates `DIAG`, so it can show the first-read spike but cannot localize the old firmware fault by itself.

If the board LEDs indicate calibration completed but `READY` is not seen, use raw UART probe mode:

```bash
python -B tools/run_diagnostics.py --port COM3 --probe --probe-send-reset --verbose-raw
```

The probe prints received bytes in hex and ASCII while periodically sending `X`.

If bytes are present but unreadable, scan likely baud rates:

```bash
python -B tools/run_diagnostics.py --port COM3 --scan-baud --probe-seconds 5
```

The scan includes common rates plus non-standard rates around 1.04 Mbaud because the observed unreadable `READY` bytes match a baud-ratio error in that range.

If no scanned baud produces readable ASCII while both status LEDs are on, inspect the routed timing report before chasing baud settings. A routed build with `WNS < 0` can corrupt UART-visible behavior even though DDR calibration succeeds. Current timing fixes in source: the firmware stores hold-time BCD digits when `H<n>` is parsed instead of formatting with divider/modulo logic during UART printing, hold timing counts elapsed seconds instead of multiplying seconds into cycles in one clock, scan mismatches are staged for one cycle before writing the address-capture buffer so SmartConnect read-response paths do not directly drive distributed RAM write enables, address capture uses a synchronous block-RAM inference template, FILL/FILL2 use a strict single-outstanding AXI write sequencer, and UART text formatting is split into `uart_reporter.v` so the detector FSM requests complete messages instead of carrying the byte formatter and line-end logic in the AXI control state machine. `detector_fsm.v` includes `uart_reporter.v` directly so synthesis sees it even if Vivado regenerates the run Tcl from a stale open project file set.

After the 2026-05-24 timing-clean build and successful flash, Windows listed only one real USB serial interface for the board:

```text
COM3 USB VID:PID=0403:6010 SER=210352BF9942B
```

That makes a wrong COM port unlikely. The current routed clock-utilization report shows the large detector/FSM load in the MIG UI domain, but the hardware UART byte pattern after the `BOOT` isolation build matches the older working firmware's 150 MHz UART divider assumption, not the generated BD `166666667` metadata. `UI_CLK_HZ` is therefore set back to `150_000_000` for firmware timing and UART divisors. `uart_tx.v` remains a conventional immediate-start state machine: idle high, start bit driven in the accept cycle, eight LSB-first data bits, one stop bit, and `ready` reasserted only after the stop bit is complete.

The follow-up hardware isolation build lowers UART to `115200` and emits `BOOT` before the detector FSM is released. `BOOT` is generated by `uart_boot_banner.v`, routed through its own `uart_tx`, and muxed onto `uart_txd` until complete. The detector FSM reset now stays asserted until both DDR calibration and the boot banner are complete, so a readable `BOOT` followed by no `READY` points at the detector/MIG path, while unreadable `BOOT` points below the detector FSM at the UART pin/framing/clock path.

The May 25 diagnostic sequence isolated the first-read/pattern-change bug to the fill write path. The root cause was the old write loop reissuing the same address while waiting for delayed `B` responses. The fixed source keeps the strict single-outstanding write sequencer and removes the temporary `D<n>`, `DIAG`, and `VDIAG` hardware paths.

## Generated Vivado Patch

The generated BD files do not naturally expose MIG `device_temp`. The pre-synthesis hook currently builds the production baseline:

- `cosmic_bd_wrapper.v`
- `cosmic_bd.v`
- `cosmic_bd_mig_7series_0_2.v`
- `cosmic_bd_mig_7series_0_2_mig.v`
- `mig_7series_v4_2_memc_ui_top_axi.v`
- `mig_7series_v4_2_mem_intfc.v`
- `mig_7series_v4_2_mc.v`
- `mig_7series_v4_2_rank_mach.v`
- `mig_7series_v4_2_rank_common.v`

Baseline behavior: `ext_refresh_tick` is still plumbed through the hierarchy so `cosmic_top` remains structurally unchanged, but `rank_common.refresh_tick = refresh_tick_lcl`. `R<n>` commands are accepted/logged but do not control MIG refresh in this build. This keeps the production cleanup focused on the proven write-sequencer fix; refresh-control restoration is deferred.

Latest hardware result before this baseline change:

- `data/diagnostics/diagnostic_live_20260525_121322.*`: `VERIFY` at `NORM` showed `FILL_VERIFY_FAILED` before `HOLD`.
- `data/diagnostics/diagnostic_live_20260525_121656.*`: refresh sweep showed `OFF`, `SLOW`, `NORM`, and `FAST` all can fail before `HOLD`; `FAST` was much worse.
- `data/diagnostics/diagnostic_live_20260525_125418.*`: MIG-internal-refresh baseline still showed `FILL_VERIFY_FAILED` before `HOLD` in 11 of 15 cycles. This means the custom refresh override is not the whole cause; proceed to strict single-outstanding AXI write sequencing.
- `data/diagnostics/diagnostic_live_20260525_131823.*`: strict single-outstanding AXI write sequencing fixed the VERIFY run. All 15 cycles were `CLEAN`, including pattern transitions. `F1=F2=SC=0x01000000`, `AW=W=B=0x02000000`, `BERR=RERR=0`, `VC=0`, and `FLIPS=0`.

Current source after production cleanup:

- FILL/FILL2 now issue one AXI write at a time: latch address/data, wait for AW handshake, wait for W handshake, wait for B response, then advance to the next word.
- Temporary diagnostic hardware modes and telemetry were removed from the active FSM.
- The next hardware run should validate normal operation with the fixed write sequencer:

```bash
python -B tools/run_diagnostics.py --port COM3 --baud 115200 --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

## Flashing Notes

`tools/flash_board.tcl` generates `cosmic_top.mcs` from the current implementation bitstream, creates the Arty S7 SPI cfgmem object, reads the resulting `PROGRAM.HW_CFGMEM` object from the FPGA device, loads Vivado's temporary flash programmer bitstream, and then runs `program_hw_cfgmem`.

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
