# Project Handoff

Last updated: 2026-06-04

## Current Control Model

The detector is now controlled only through the Python GUI over UART. Physical switches and push buttons are no longer part of the active experiment workflow.

The GUI sends settings on Start in this order:

1. `H<n>\n` for hold seconds.
2. `P<n>\n` for pattern.
3. `G` to start the detector loop.

Refresh selection has been removed from the GUI for now. The production baseline keeps MIG on its internal refresh generator, and hold-time delay is the current manual exposure control.

`X` resets the board-side FSM back to `WAIT_GO`. The GUI enables Reset Board immediately after the serial connection is opened, even before `READY`, so an already-running board can be recovered.

## Source Of Truth

- Firmware timing clock: `UI_CLK_HZ = 150_000_000`.
- UART baud: `115200`.
- Patterns: `0=FF`, `1=00`, `2=55`, `3=AA`.
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
python -B tools/run_diagnostics.py --port auto --hold 1 --patterns FF,00,55,AA,FF --cycles 3
```

It resets with `X`, waits for `READY`, sends `H`, `P`, and `G`, then writes raw JSONL plus CSV/Markdown summaries under `data/diagnostics`. It still understands older `DIAG`/`VDIAG` captures for replay, but current production firmware does not emit those lines. Production reports now use a compact table unless legacy diagnostic records are present. Replay mode classifies existing captures:

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

Baseline behavior: `ext_refresh_tick` is still plumbed through the hierarchy so `cosmic_top` remains structurally unchanged, but `rank_common.refresh_tick = refresh_tick_lcl`. MIG uses internal refresh in this build. This keeps the production cleanup focused on the proven write-sequencer fix; refresh-control restoration is deferred.

Latest hardware result before this baseline change:

- `data/diagnostics/diagnostic_live_20260525_121322.*`: `VERIFY` at `NORM` showed `FILL_VERIFY_FAILED` before `HOLD`.
- `data/diagnostics/diagnostic_live_20260525_121656.*`: refresh sweep showed `OFF`, `SLOW`, `NORM`, and `FAST` all can fail before `HOLD`; `FAST` was much worse.
- `data/diagnostics/diagnostic_live_20260525_125418.*`: MIG-internal-refresh baseline still showed `FILL_VERIFY_FAILED` before `HOLD` in 11 of 15 cycles. This means the custom refresh override is not the whole cause; proceed to strict single-outstanding AXI write sequencing.
- `data/diagnostics/diagnostic_live_20260525_131823.*`: strict single-outstanding AXI write sequencing fixed the VERIFY run. All 15 cycles were `CLEAN`, including pattern transitions. `F1=F2=SC=0x01000000`, `AW=W=B=0x02000000`, `BERR=RERR=0`, `VC=0`, and `FLIPS=0`.
- `data/diagnostics/diagnostic_live_20260525_140429.*`: production-clean firmware sanity run passed. All 15 normal cycles were `CLEAN` with `FLIPS=0`, `ADDRS:0000 OVF:0`, and no `DIAG`/`VDIAG` output.

Current source after production cleanup:

- FILL/FILL2 now issue one AXI write at a time: latch address/data, wait for AW handshake, wait for W handshake, wait for B response, then advance to the next word.
- SCAN now issues one AXI read at a time: latch read address, wait for AR handshake, wait for R response, compare/capture the latched address, then advance. This fixes the `ADDRS` symptom where many streamed entries were all `0x0000000`.
- Temporary diagnostic hardware modes and telemetry were removed from the active FSM.

May 28 follow-up: `flash_board.log` shows `cosmic_top.mcs` was programmed and verified successfully at 14:32. The immediate run `data/experiment_20260528_143309.jsonl` still streamed complete address lists where every captured address was `0x0000000` despite nonzero flip counts. The synthesis log exposed the cause: `addr_buf_rd_data` had two procedural drivers, the intended address-buffer read block and a reset-block assignment to zero. Vivado preserved the constant driver and ignored the real read data, so UART address lines were forced to `0000000`. The reset-block assignment has been removed; rebuild before trusting address rasters again.
- Python GUI address analysis now skips incomplete or overflowed address lists instead of feeding them into the de-noised background model or raster plot. Replay rebuilds address arrays from either embedded `addrs` fields or separate `ADDRS`/address records.
- GUI CSV rows now wait for the following `TEMP` record when available, so `temp_c` corresponds to the just-reported cycle instead of the previous latest temperature sample.
- Normal operation with the fixed write sequencer has passed this command:

```bash
python -B tools/run_diagnostics.py --port COM3 --baud 115200 --hold 1 --patterns FF,00,55,AA,FF --cycles 3
```

Next work can shift to the graphing interface and longer-duration experiment UX.

## Flashing Notes

`tools/flash_board.tcl` generates `cosmic_top.mcs` from the current implementation bitstream, creates the Arty S7 SPI cfgmem object, reads the resulting `PROGRAM.HW_CFGMEM` object from the FPGA device, loads Vivado's temporary flash programmer bitstream, and then runs `program_hw_cfgmem`.

`program_board.bat` uses the full Vivado 2023.1 batch-file path for volatile JTAG programming, matching `flash_board.bat`. Use this first after any suspected board short or flash failure to confirm the FPGA/JTAG path still works before attempting persistent SPI flash programming again.

After volatile JTAG programming, do not press the board `PROG` button while probing UART. `PROG` clears the volatile FPGA configuration and reloads from flash if the board is in a flash-boot mode, which defeats the JTAG health check when flash is untrusted. Run the probe immediately after `program_board.bat` and let the tool send `X` resets over UART.

If `program_board.bat` succeeds and both firmware status LEDs are on, but `tools/run_diagnostics.py --scan-baud` still reports `RX: <none>` at every baud, use `uart_smoke_board.bat`. It builds and programs a standalone UART-only bitstream from `tools/uart_smoke_top.v` and `tools/uart_smoke.xdc`, without DDR/MIG or SPI flash. Expected result: LED0 blinks, LED1 flickers on transmitted bytes, and COM3 receives repeated `UART_SMOKE` lines at 115200 baud. If LED1 flickers but COM3 receives nothing, suspect the FPGA `uart_txd` pin, FTDI UART channel, or board trace between them.

If no external USB-UART adapter is available, use `uart_loopback_board.bat` as a narrower onboard test. It builds and programs `tools/uart_loopback_top.v`, which wires FPGA `uart_rxd` directly to `uart_txd`. With that bitstream loaded, `tools/run_diagnostics.py --port COM3 --probe --probe-send-reset --verbose-raw` should echo the tool's transmitted `X` bytes. Echoes mean the FTDI UART TX/RX pins and both FPGA UART pins still pass digital traffic; no echoes while LED1 flickers on sent bytes points at the FPGA-to-FTDI return path.

If any programming script reports `ERROR: No hardware targets reported by hw_server`, the build may have succeeded but the board was not visible to Vivado's hardware server. Unplug/replug the board, wait for Windows to show the Digilent USB device/COM port again, close other Vivado hardware sessions, and rerun the same batch file. This is distinct from the earlier SPI flash all-zero-ID failure.

June 4 flash retry note: a failed run reached `program_hw_cfgmem` but reported all-zero flash IDs (`Mfg ID : 0`, `Device ID : 0`) and did not print `Flash programming complete.` That means MCS generation and JTAG connection succeeded, but the temporary FPGA flash programmer could not read the SPI flash. The script now reports that as an explicit error and supports the documented Arty S7 flash variants (`s25fl128s...` and `s25fl127s...`). Retry after fully power-cycling the board, closing other Vivado/hw_server sessions, and checking the JP1 mode jumper. If the physical package marking is S25FL127S or another variant, set `FLASH_PART` to the exact Vivado cfgmem part name before running `flash_board.bat`.

If `flash_board.log` reports `Flash Programming Unsuccessful: Failure to set flash parameters`, retry with the updated script. The bitstream-to-MCS step can still succeed even when the later SPI programmer setup fails.

June 4 emergency UART-return workaround: the onboard FTDI-to-FPGA transmit path still appears to work, but FPGA-to-FTDI return data does not reach COM3. A temporary VIO mailbox was added so Vivado/JTAG can send the same command bytes (`X`, `H<n>\n`, `P<n>\n`, `G`) and capture the same firmware text telemetry. Use:

```bash
.\program_board.bat
.\run_jtag_diagnostics.bat 15 FF 1
```

The JTAG runner waits for `READY` before sending commands and writes captured text under `data/diagnostics/jtag_live_*.txt`. The JTAG mailbox is volatile like any other JTAG-programmed bitstream; pressing `PROG` or unplugging the loose USB cable reloads the old flash image and removes the VIO core, so rerun `program_board.bat` after any disconnect. The emergency `.bat` files no longer end with `pause`; if Vivado appears to run for a long time, check the bitstream/probes timestamps before rebuilding again.

The Python GUI now includes `JTAG` as a connection option. Selecting `JTAG` and clicking Connect marks the board ready without waiting for COM3 `READY`; clicking Start launches `run_jtag_diagnostics.bat` with the GUI hold time and pattern, then feeds captured text back through the same GUI parser/storage path. Reset Board terminates the active Vivado capture and leaves the JTAG transport ready for another Start. This is only a fallback for boards whose onboard UART return path is damaged; normal boards should continue using their COM port.

June 4 pause point: the JTAG telemetry byte corruption was fixed by registering the selected UART byte in `cosmic_top.v` before feeding `jtag_vio_mailbox`. After rebuilding with `build_jtag_mailbox_board.bat` and programming with `program_board.bat`, raw listen-only JTAG capture showed clean text:

```text
BOOT
READY
```

June 8 follow-up: the firmware parser/reporter path was checked in simulation with an explicit `H0005\n` command, and `detector_fsm_tb` now asserts the board responds with `INTERVAL:0005s`. The stale `INTERVAL:4405s` hardware result persisted after making the Tcl VIO data/sequence commit atomic. The later rebuild showed a deeper VIO visibility issue: Vivado could program the FPGA, but `refresh_hw_device` reported that the debug hub was not detected because the VIO/debug hub was clocked from MIG `ui_clk`.

The JTAG mailbox now uses a two-clock bridge. The first June 8 rebuild exported `jtag_clk_0` from the BD clock wizard's `clk_out2` path and drove the VIO core from that clock, while detector commands/telemetry crossed to and from the normal `ui_clk` domain. That build still programmed successfully but hardware manager reported `debug hub core was not detected`, so the mailbox clock was moved again to the 7-series `STARTUPE2.CFGMCLK` internal configuration clock. `cosmic_top.v` now instantiates `STARTUPE2`; `cosmic_constraints.xdc` declares `jtag_cfgmclk`; and the VIO core no longer depends on MIG calibration or the BD clock wizard. `tools/expose_device_temp.tcl` still patches generated BD files using its own script path instead of Vivado's run-directory `current_project` path and guards the existing `device_temp_0`/`ext_refresh_tick` edits so the hook can run repeatedly without duplicating ports. `tools/build_jtag_mailbox_bitstream.tcl` explicitly runs the generated-file patch hook before synthesis. `tools/run_jtag_diagnostics.tcl` uses a shorter 3-second post-program wait and sets the Digilent JTAG target frequency to 6 MHz.

Current June 8 hardware state: the JTAG build path now explicitly regenerates the VIO IP and reads the generated VIO implementation sources from the synthesis pre-hook, so `build_jtag_mailbox_board.bat` can produce a bitstream and `.ltx` with one VIO core again. A hardware run at 16:10 on 2026-06-08 successfully programmed the board and Hardware Manager found `hw_vio_1`, but returned text was byte-corrupted (`READY`/`INTERVAL` were mangled) and no `TEMP` record was captured. The mailbox telemetry path was then changed from independent multi-bit synchronizers to a held-data toggle/ack-toggle CDC handshake. A follow-up run using `STARTUPE2.CFGMCLK` programmed but did not detect the debug hub, so the VIO clock is being moved to the board `sys_clock` through a single top-level input buffer. `tools/expose_device_temp.tcl` now patches the generated clock wizard to remove its internal `IBUF` when the top-level buffer is used. The next required step is to rebuild and verify:

```bash
.\build_jtag_mailbox_board.bat
.\run_jtag_diagnostics.bat 5 FF 1 PROGRAM
```

The last attempted rebuild before this handoff failed because raw `sys_clock` was connected both to the clock wizard input buffer and to JTAG mailbox flops. That specific illegal connection has been patched by adding `u_sys_clock_ibuf` in `cosmic_top.v` and replacing the generated clock wizard input buffer with a direct assignment in the pre-synthesis hook. This latest patch has not yet been rebuilt in hardware.

## Verification Status

Completed locally:

- Python parser/storage tests pass with `python -B -m unittest tools.test_uart_logger_parser`.
- GUI source syntax was checked with `python -B -c "import ast, pathlib; ast.parse(pathlib.Path('tools/uart_logger.py').read_text(encoding='utf-8'))"` because Windows denied replacing an existing `tools/__pycache__` file during `py_compile`.
- Diagnostic runner tests pass with `python -B -m unittest tools.test_run_diagnostics`.
- Python syntax check passes with bytecode disabled.
- `xvlog` parsed the edited `jtag_vio_mailbox.v` and `cosmic_top.v`.
- `build_jtag_mailbox_board.bat` completed synthesis, implementation, bitstream generation, and `write_debug_probes` for both the BD-clock and later `STARTUPE2.CFGMCLK` JTAG mailbox builds.
- `xvlog` compiled `detector_fsm.v` and `detector_fsm_tb.v`.
- `xsim detector_fsm_tb_sim -runall` passed and printed `detector_fsm_tb PASS`.

Not completed in this environment:

- Hardware acceptance of the CFGMCLK build, because the board was not visible to Windows/Vivado after the rebuild.
