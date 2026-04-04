# DRAM Dosimeter — UART Logger & Live Plotter

Reads the Arty S7-25 UART output, plots bit-flip counts in real time, and saves every session to CSV and JSONL.

---

## Install

```bash
pip install pyserial matplotlib
# or using the requirements file:
pip install -r tools/requirements.txt
```

---

## Quick start

```bash
# Live capture from board (prompted for name & description)
python tools/uart_logger.py

# With CLI flags (no prompts)
python tools/uart_logger.py --port COM3 --name baseline --description "Room temp, refresh OFF"

# Replay a previous session (no board needed)
python tools/uart_logger.py --replay data/baseline_20260403_142200.jsonl
```

---

## All options

| Flag | Default | Description |
|---|---|---|
| `--port` | `COM3` | Serial port the board is connected to |
| `--baud` | `115200` | Baud rate (matches FPGA firmware) |
| `--name` | *(prompted)* | Short experiment name (spaces → underscores) |
| `--description` | *(prompted)* | Free-text description stored in file header |
| `--output-dir` | `data/` | Directory for saved files |
| `--window` | `200` | Number of recent points shown in the rolling plot |
| `--alert-threshold N` | off | Print a WARNING when `flip_count > N` |
| `--ymax N` | auto | Pin the Y-axis maximum (useful for comparing sessions) |
| `--replay FILE` | — | Re-plot a `.jsonl` file without hardware |

`--port` and `--replay` are mutually exclusive.

---

## Output files

Both files are written to `--output-dir` (default `data/`) with the pattern `{name}_{YYYYMMDD_HHMMSS}.*`.

### CSV (`.csv`)

Human-readable, one row per SCAN cycle.

```
# experiment: baseline
# description: Room temp, refresh OFF
# start_time: 2026-04-03T14:22:00+00:00
timestamp,iteration,hold_s,refresh_rate,flip_count,experiment
2026-04-03T14:22:10+00:00,1,5,OFF,2748,baseline
2026-04-03T14:22:16+00:00,2,5,OFF,2751,baseline
...
```

Fields:
- `timestamp` — ISO-8601 UTC wall-clock time the message arrived
- `iteration` — sequential scan cycle number
- `hold_s` — hold duration selected on board (5 / 10 / 20 / 30)
- `refresh_rate` — DRAM refresh setting active at time of scan (OFF / SLOW / NORM / FAST)
- `flip_count` — number of bit mismatches found in the 16 MB scan

### JSONL (`.jsonl`)

Lossless — every parsed message (FLIP, REFRESH, INTERVAL) is stored. Used by `--replay`.

---

## Live plot features

- **Scatter plot** colored by hold time (green=5s, blue=10s, orange=20s, red=30s)
- **Rolling window** of the last `--window` points (default 200)
- **Refresh-rate change markers** — vertical dashed lines annotated with the new rate
- **Alert threshold line** — horizontal red dashed line when `--alert-threshold` is set
- **Stats sidebar** — live mean, std-dev, min, max of the visible window
- **Title bar** — shows current iteration count and active refresh rate

---

## Hang detection

If no FLIP message arrives within `2.5 × hold_time + 60 s`, a warning is printed:

```
[WARN] No FLIP message in 375s (expected ~5s hold). Board may be hung.
```

This matches the known FSM hang bug where the board stops printing after ~14–30 iterations.

---

## Workflow example

```bash
# 1. Start a named session
python tools/uart_logger.py --port COM3 --name cosmic_test_01 \
    --description "SW0=0 SW1=0 (refresh OFF), 5s hold, 20°C ambient"

# 2. Change switches/buttons on board; logger tracks REFRESH and INTERVAL messages automatically.

# 3. Ctrl-C when done — summary printed, files saved.

# 4. Later, re-examine:
python tools/uart_logger.py --replay data/cosmic_test_01_20260403_142200.jsonl
```

---

## Changing hold time from the laptop

While the logger is running, type a number of seconds and press Enter:

```
45
[cmd] Sent H45 — board will confirm with INTERVAL:0045s
```

The board responds with `INTERVAL:0045s` confirming the change, then uses the new hold time from the next cycle onward.  Range: **1–9999 seconds**.  Physical buttons still work as a fallback and override any laptop-set value.

---

## UART message reference

Messages the FPGA sends (firmware: `detector_fsm.v`):

| Message | Example | Trigger |
|---|---|---|
| FLIP result | `HOLD:0005s FLIPS:00000ABC` | End of every SCAN cycle |
| Refresh change | `REFRESH:OFF` / `SLOW` / `NORM` / `FAST` | SW0/SW1 toggled |
| Interval change | `INTERVAL:0045s` | Button pressed or laptop command |

Messages the laptop sends (firmware: `uart_rx.v` + `detector_fsm.v`):

| Message | Example | Effect |
|---|---|---|
| Hold time command | `H45\n` | Sets hold to 45 s |
