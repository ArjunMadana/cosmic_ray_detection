# DRAM Dosimeter - Cosmic Ray Detector

Uses the on-board DDR3 DRAM on an Arty S7-25 as a particle detector. The FPGA fills memory with a known pattern, waits for a GUI-selected hold period, scans for bit flips, and streams results over USB-UART to the Python GUI.

## Hardware

| Item | Value |
|------|-------|
| Board | Digilent Arty S7-25 |
| FPGA | Xilinx Spartan-7 XC7S25 |
| Memory | DDR3 through MIG 7-series IP |
| UART | 921600 8N1 over USB-JTAG FTDI |
| Tool | Vivado 2023.1 |
| Firmware clock | `ui_clk_0 = 166.666667 MHz` |

## Quickstart

1. Open `cosmic_ray_detection.xpr` in Vivado 2023.1.
2. Generate bitstream.
3. Program volatile bitstream with `source {tools/program_board.tcl}`, or flash persistently with `source {tools/flash_board.tcl}` / `flash_board.bat`.
4. Run the GUI:

```bash
pip install -r tools/requirements.txt
python tools/uart_logger.py
```

Connect to the board COM port. The board sends `READY` after DDR3 calibration. Select hold, pattern, and refresh in the GUI, then click Start. The GUI sends `H`, `P`, `R`, then `G`; the firmware does not use physical switches or buttons for experiment control.

## Control Model

Experiment control is UART-only:

| Command | Direction | Meaning |
|---------|-----------|---------|
| `H<n>\n` | PC to board | Hold time in seconds, 1-9999 |
| `P<n>\n` | PC to board | Pattern: `0=FF`, `1=00`, `2=55`, `3=AA` |
| `R<n>\n` | PC to board | Refresh: `0=OFF`, `1=SLOW`, `2=NORM`, `3=FAST` |
| `G` | PC to board | Start cycling from `WAIT_GO` |
| `X` | PC to board | Abort current cycle and return to `WAIT_GO` |
| `READY` | Board to PC | Board is calibrated and waiting for `G` |
| `INTERVAL:NNNNs` | Board to PC | Accepted hold setting |
| `PATTERN:XX` | Board to PC | Accepted pattern setting |
| `REFRESH:<mode>` | Board to PC | Accepted refresh setting |
| `ADDRS:NNNN OVF:X` | Board to PC | Captured address count and overflow flag |
| `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX` | Board to PC | Cycle result |
| `TEMP:XXX` | Board to PC | Raw MIG XADC temperature code |
| `DIAG:...` | Board to PC | Fill/scan coverage and first-mismatch diagnostics |

`DIAG` format:

```text
DIAG:F1:XXXXXXXX F2:XXXXXXXX SC:XXXXXXXX BERR:XXXXXXXX RERR:XXXXXXXX BAD:XXXXXXX GOT:XXXXXXXX EXP:XXXXXXXX OVF:X
```

## Firmware Flow

```text
WAIT_GO -> FILL -> FILL2 -> HOLD -> SCAN -> ADDRS -> REPORT -> TEMP -> DIAG -> SETTLE -> FILL
```

`FILL` and `FILL2` both write the full memory range. `SCAN` compares against the latched fill pattern, so `P<n>` commands issued mid-cycle affect the next fill/scan cycle, not the in-progress scan.

## Generated Vivado Patch

`tools/expose_device_temp.tcl` is registered as the `synth_1` pre-synthesis hook. It patches generated BD/MIG Verilog so:

- `device_temp_0[11:0]` reaches `cosmic_top`.
- `ext_refresh_tick` reaches MIG `rank_common.refresh_tick`.

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
python -B -m unittest tools.test_uart_logger_parser
```

The HDL testbench is at `cosmic_ray_detection.srcs/sim_1/new/detector_fsm_tb.v`. It uses a small AXI memory model to check full FILL/FILL2/SCAN coverage, randomized ready/valid stalls, and pattern changes during scans.
