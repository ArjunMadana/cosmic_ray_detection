# DRAM Dosimeter — GUI Logger & Live Plotter

Tkinter GUI that reads the Arty S7-25 UART output, plots bit-flip counts live, and saves every session to CSV and JSONL.  No CLI arguments needed for normal use.

---

## Install

```bash
pip install pyserial matplotlib
# or:
pip install -r tools/requirements.txt
```

---

## Usage

```bash
# Open the GUI (normal use)
python tools/uart_logger.py

# Replay a saved session without hardware
python tools/uart_logger.py --replay data/baseline_20260403_142200.jsonl
```

---

## GUI layout

```
┌─ Connection ──────────────────────────────────────────────────┐
│ Port [COM3 ▼] [↺]  Baud [115200]  [Connect] [Disconnect]     │
│ Output dir [data/] […]                                        │
├─ Experiment ──────────────────────────────────────────────────┤
│ Name [baseline          ]  Description [Room temp, OFF      ] │
├─ Live plot ───────────────────────────────────────────────────┤
│                                                               │
│    flip count vs elapsed time (scatter + line)                │
│    color = hold time  |  vertical lines = refresh changes     │
│    yellow dashed lines = your notes                           │
│                                                               │
├─ Status bar ──────────────────────────────────────────────────┤
│ Iter: 12  Flips: 529,417  Hold: 5 s  Refresh: OFF  Elapsed:… │
├─ Controls ────────────────────────────────────────────────────┤
│ Hold time (s): [____] [Send to board]                         │
│ Alert if flips > [______] [Set]   Plot last [200] points [Set]│
├─ Annotation / Note ───────────────────────────────────────────┤
│ [________________________________________] [Add Note]          │
├─ Log ─────────────────────────────────────────────────────────┤
│ 14:22:05  #   1  flips=   529,417  hold=5s  refresh=OFF       │
│ 14:22:10  [NOTE] Started warming memory                       │
│ ...                                                           │
└───────────────────────────────────────────────────────────────┘
```

---

## Workflow

1. **Launch** — `python tools/uart_logger.py`
2. **Fill in** Name and Description (stored in the file header)
3. **Select port** from the dropdown (click ↺ to refresh the list)
4. **Connect** — the board starts being logged immediately
5. **Select hold, pattern, and refresh** in the GUI, then click Start. The GUI sends `H`, `P`, `R`, then `G`; physical switches/buttons are not part of the active control path.
6. **Add notes** — type anything in the Annotation box and press Enter.  Notes get a timestamp and appear as yellow dashed lines on the plot and in the JSONL file.  Useful for recording: "tilted board 45°", "started heating lamp", "changed refresh rate", etc.
7. **Disconnect** — saves files and prints a session summary in the log.

---

## Output files

Both files are written to *Output dir* (default `data/`) named `{name}_{YYYYMMDD_HHMMSS}.*`.

### CSV  
One row per SCAN cycle.  First three lines are `#`-prefixed metadata (loadable with `pd.read_csv(..., comment='#')`).

```
# experiment: baseline
# description: Room temp, refresh OFF
# start_time: 2026-04-03T14:22:00+00:00
timestamp,iteration,hold_s,refresh_rate,pattern,flip_count,addr_overflow,temp_c,experiment
```

### JSONL  
Every event in order. FLIP records include captured address arrays when available. Replay also understands captures where `ADDRS` and address records appear separately before the FLIP result.

Address-based graphing is conservative: raw flip counts are always plotted, but the de-noised and raster tabs only consume complete, non-overflowed address captures.

---

## Changing hold time from the GUI

Type seconds in the *Hold time* field and click Start or Send. The board responds with `INTERVAL:NNNNs` and uses the new hold time from the next cycle boundary. Board buttons are not used for experiment control.

---

## Alert threshold

Set *Alert if flips >* N. Any FLIP record above the threshold is highlighted red in the log and shown as a horizontal dashed line on the plot.

---

## UART message reference

| Message | Example | Trigger |
|---|---|---|
| FLIP result | `HOLD:0005s PAT:AA FLIPS:00000ABC` | End of every SCAN cycle |
| Address header | `ADDRS:0002 OVF:0` | Before each FLIP result |
| Refresh change | `REFRESH:OFF` / `SLOW` / `NORM` / `FAST` | GUI command accepted |
| Pattern change | `PATTERN:AA` | GUI command accepted |
| Interval change | `INTERVAL:0060s` | GUI command accepted |
| Temperature | `TEMP:7A3` | After each FLIP result |

| Command (laptop → board) | Example | Effect |
|---|---|---|
| Hold time | `H60\n` | Sets hold to 60 s |
