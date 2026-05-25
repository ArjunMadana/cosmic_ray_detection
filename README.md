# DRAM Dosimeter - Cosmic Ray Detector

Uses the on-board DDR3 DRAM on an Arty S7-25 as a particle detector. The FPGA fills memory with a known pattern, waits for a GUI-selected hold period, scans for bit flips, and streams results over USB-UART to the Python GUI.

## Hardware

| Item | Value |
|------|-------|
| Board | Digilent Arty S7-25 |
| FPGA | Xilinx Spartan-7 XC7S25 |
| Memory | DDR3 through MIG 7-series IP |
| UART | 115200 8N1 over USB-JTAG FTDI |
| Tool | Vivado 2023.1 |
| Firmware timing clock | `UI_CLK_HZ = 150 MHz` |

## Quickstart

1. Open `cosmic_ray_detection.xpr` in Vivado 2023.1.
2. Generate bitstream.
3. Program volatile bitstream with `source {tools/program_board.tcl}`, or flash persistently with `source {tools/flash_board.tcl}` / `flash_board.bat`.
4. Run the GUI:

```bash
pip install -r tools/requirements.txt
python tools/uart_logger.py
```

Connect to the board COM port at `115200`. The board sends a low-level `BOOT` banner first, then `READY` after DDR3 calibration. Select hold, pattern, and refresh in the GUI, then click Start. The GUI sends `H`, `P`, `R`, then `G`; the firmware does not use physical switches or buttons for experiment control.

If persistent flashing fails, check `flash_board.log`. The message `Failure to set flash parameters` occurs after MCS generation and points to the SPI flash programmer setup, not the bitstream build.

For an automated production sanity run without the GUI:

```bash
python -B tools/run_diagnostics.py --port auto --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

To sweep refresh selections:

```bash
python -B tools/run_diagnostics.py --port COM3 --baud 115200 --hold 1 --refresh OFF,SLOW,NORM,FAST --patterns FF,00,55,AA,FF --cycles 2
```

To classify an existing capture:

```bash
python -B tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
```

If both status LEDs are on but the diagnostic runner times out waiting for `READY`, inspect raw UART traffic:

```bash
python -B tools/run_diagnostics.py --port COM3 --probe --probe-send-reset --verbose-raw
```

If raw bytes are present but unreadable, scan common baud rates:

```bash
python -B tools/run_diagnostics.py --port COM3 --scan-baud --probe-seconds 5
```

## Control Model

Experiment control is UART-only:

| Command | Direction | Meaning |
|---------|-----------|---------|
| `H<n>\n` | PC to board | Hold time in seconds, 1-9999 |
| `P<n>\n` | PC to board | Pattern: `0=FF`, `1=00`, `2=55`, `3=AA` |
| `R<n>\n` | PC to board | Refresh: `0=OFF`, `1=SLOW`, `2=NORM`, `3=FAST` |
| `G` | PC to board | Start cycling from `WAIT_GO` |
| `X` | PC to board | Abort current cycle and return to `WAIT_GO` |
| `BOOT` | Board to PC | UART boot banner before the detector FSM is released |
| `READY` | Board to PC | Board is calibrated and waiting for `G` |
| `INTERVAL:NNNNs` | Board to PC | Accepted hold setting |
| `PATTERN:XX` | Board to PC | Accepted pattern setting |
| `REFRESH:<mode>` | Board to PC | Accepted refresh setting |
| `ADDRS:NNNN OVF:X` | Board to PC | Captured address count and overflow flag |
| `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX` | Board to PC | Cycle result |
| `TEMP:XXX` | Board to PC | Raw MIG XADC temperature code |

## Firmware Flow

```text
WAIT_GO -> FILL -> FILL2 -> HOLD -> SCAN -> ADDRS -> REPORT -> TEMP -> SETTLE -> FILL
```

`FILL` and `FILL2` both write the full memory range through a strict single-outstanding AXI sequencer: latch address/data, wait for AW, wait for W, wait for B, then advance. `SCAN` compares against the latched fill pattern, so `P<n>` commands issued mid-cycle affect the next fill/scan cycle, not the in-progress scan.

## Generated Vivado Patch

`tools/expose_device_temp.tcl` is registered as the `synth_1` pre-synthesis hook. It patches generated BD/MIG Verilog so:

- `device_temp_0[11:0]` reaches `cosmic_top`.
- Diagnostic baseline: `ext_refresh_tick` is still plumbed through the generated hierarchy, but MIG `rank_common.refresh_tick` uses its internal `refresh_tick_lcl`.

In this baseline build, `R<n>` commands are still accepted and logged, but they do not control MIG refresh. GUI-controlled MIG refresh remains deferred while the production data path and graphing interface are stabilized.

Verify the hook in Vivado if the project moves:

```tcl
get_property STEPS.SYNTH_DESIGN.TCL.PRE [get_runs synth_1]
```

If needed, re-register it:

```tcl
set_property STEPS.SYNTH_DESIGN.TCL.PRE \
    {c:/_CAMSIN/cosmic_ray_detection/tools/expose_device_temp.tcl} \
    [get_runs synth_1]
save_project
```

## Tests

Parser tests:

```bash
python -B -m unittest tools.test_uart_logger_parser tools.test_run_diagnostics
```

The HDL testbench is at `cosmic_ray_detection.srcs/sim_1/new/detector_fsm_tb.v`. It uses a small AXI memory model to check full FILL/FILL2/SCAN coverage, randomized ready/valid stalls, and pattern changes during scans.

## Python Tooling Notes

The GUI logs raw cycle results even when address capture is incomplete, but the de-noised and raster tabs only consume address lists when `flip_count == len(addrs)` and `OVF:0`. Incomplete or overflowed address captures are preserved in JSONL and flagged in the log instead of being folded into the background model.

`tools/run_diagnostics.py` defaults to production telemetry. Legacy `DIAG`/`VDIAG` records are still parsed for replay, but `--diag-modes` is ignored in live mode unless `--expect-diag` is set for an older diagnostic bitstream.
