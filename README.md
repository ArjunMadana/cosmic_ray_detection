# DRAM Dosimeter — Cosmic Ray Detector

Uses the on-board DDR3 DRAM on an Arty S7-25 as a particle detector.  The FPGA fills memory with a known pattern, waits (the *hold* period), then scans for bit flips caused by ionizing radiation or thermal noise.  Results are streamed over USB-UART and logged by a Python GUI.

---

## Hardware

| Item | Value |
|------|-------|
| Board | Digilent Arty S7-25 |
| FPGA | Xilinx Spartan-7 XC7S25 |
| Memory | 512 MB DDR3 (via MIG 7-series IP) |
| Interface | USB-UART (115200 baud, built into the board) |
| Tool | Vivado 2023.1 |

---

## Quickstart

### 1. Open the project

Open `cosmic_ray_detection.xpr` in Vivado 2023.1.

### 2. Check the pre-synthesis hook (first time only)

The block design exposes two signals (`device_temp_0`, `ext_refresh_tick`) that Vivado's code generator does not know about.  A TCL script patches the generated files automatically before every synthesis run.  The hook is stored in the `.xpr` file, but **you must verify it on your machine** if the project has moved to a new path.

In the Vivado TCL console:

```tcl
get_property STEPS.SYNTH_DESIGN.TCL.PRE [get_runs synth_1]
```

If it prints nothing, or a path that no longer exists, re-register it:

```tcl
set_property STEPS.SYNTH_DESIGN.TCL.PRE \
    {<absolute-path-to-repo>/tools/expose_device_temp.tcl} \
    [get_runs synth_1]

add_files -fileset utils_1 -norecurse \
    {<absolute-path-to-repo>/tools/expose_device_temp.tcl}

# Save so the hook persists in the .xpr
save_project
```

Replace `<absolute-path-to-repo>` with the actual path on your machine (e.g. `c:/_CAMSIN/cosmic_ray_detection`).  You only need to do this once per machine.

### 3. Build

Flow Navigator → **Generate Bitstream**.  Synthesis + implementation run automatically (~20–30 min).

### 4. Flash

Volatile (lost on power cycle — good for quick testing):
```tcl
source {tools/program_board.tcl}
```

Persistent (survives power cycle, ~2 min):
```tcl
source {tools/flash_board.tcl}
```

Both scripts can be run from the Vivado TCL console with the project open.

### 5. Run the GUI

```bash
pip install -r tools/requirements.txt
python tools/uart_logger.py
```

Select the board's COM port, click **Connect**.  The board sends `READY` after DDR3 calibration (~5 s), then starts cycling automatically.

---

## How it works

```
FILL → FILL2 → HOLD → SCAN → REPORT → PRINT_TEMP → SETTLE → (repeat)
```

1. **FILL / FILL2** — Write a test pattern (0xFF, 0x00, 0x55, or 0xAA) to all of DDR3 twice.
2. **HOLD** — Wait for the configured hold time (default 5 s).  DRAM refresh is either disabled or slowed via SW0/SW1 to give particles time to cause flips.
3. **SCAN** — Read back every address.  Any word that doesn't match the pattern is counted and its address buffered.
4. **REPORT** — Stream results over UART: address list, flip count, hold time, pattern, and die temperature.
5. **SETTLE** — Wait for any in-flight AXI transactions, then start the next cycle.

### Refresh control (SW0 / SW1)

| SW1 | SW0 | Mode | Refresh period |
|-----|-----|------|---------------|
| 0 | 0 | OFF | None (DRAM degrades quickly) |
| 0 | 1 | SLOW | ~100 ms |
| 1 | 0 | NORM | ~7.8 µs (DDR3 spec) |
| 1 | 1 | FAST | ~3.9 µs |

### Buttons

| Button | Hold time |
|--------|-----------|
| BTN3 | 5 s (default) |
| BTN0 | 10 s |
| BTN1 | 20 s |
| BTN2 | 30 s |

Hold time can also be set from the GUI (any value 1–9999 s).

### On-chip temperature

Die temperature is read from the MIG's internal XADC and sent as `TEMP:XXX\r\n` (3 hex digits) after each cycle.  The GUI converts this and displays it in the status bar.  Conversion: `°C = raw × 503.975 / 4096 − 273.15`.

---

## UART protocol

All messages are ASCII, terminated with `\r\n`.

| Direction | Message | Example |
|-----------|---------|---------|
| Board → PC | Ready | `READY` |
| Board → PC | Address list header | `ADDRS:000F` |
| Board → PC | Flip address | `000A3F8` |
| Board → PC | Cycle result | `HOLD:0005s PAT:FF FLIPS:0000001A` |
| Board → PC | Temperature | `TEMP:6B2` |
| Board → PC | Refresh change | `REFRESH:OFF` |
| Board → PC | Interval change | `INTERVAL:0005s` |
| PC → Board | Start cycle | `G` |
| PC → Board | Set hold time | `H60\n` |
| PC → Board | Set pattern | `P2\n` (0=FF, 1=00, 2=55, 3=AA) |
| PC → Board | Reset | `X` |

---

## Project structure

```
cosmic_ray_detection.srcs/sources_1/new/
  cosmic_top.v          Top-level module — wires board I/O to block design + FSM
  detector_fsm.v        Main state machine (fill, hold, scan, report)

tools/
  uart_logger.py        Python GUI — connect, log, plot, sweep
  expose_device_temp.tcl  Pre-synthesis patch script (see Setup note above)
  program_board.tcl     JTAG-program volatile bitstream
  flash_board.tcl       Write bitstream to SPI flash
  make_mcs.tcl          Convert .bit → .mcs for flash

data/                   Output directory for CSV and JSONL logs
```

---

## Development notes

### Why `expose_device_temp.tcl` exists

The Spartan-7 has a single XADC hard block.  The MIG DDR3 IP uses it internally for temperature-compensated refresh.  Vivado does not expose the MIG's `device_temp[11:0]` output or its `ext_refresh_tick` input through the Block Design GUI — they exist in the MIG Verilog module but are absent from the IP's component interface definition.

The script directly patches two Vivado-generated files after each `generate_target` call:
- `cosmic_ray_detection.gen/.../synth/cosmic_bd.v`
- `cosmic_ray_detection.gen/.../hdl/cosmic_bd_wrapper.v`

It is idempotent (safe to run multiple times) and is registered as a pre-synthesis hook so it runs automatically before every synthesis run.  **If you ever call `generate_target` or `make_wrapper` manually in the TCL console, run the script again afterward** or just re-run Generate Bitstream, which will trigger the hook.

### Replay mode

The GUI can replay any saved session without a board connected:

```bash
python tools/uart_logger.py --replay data/myrun_20260419_140000.jsonl
```

Useful for checking plots and annotations offline.
