"""
uart_logger.py — DRAM Dosimeter UART Data Logger & Live Plotter

Reads structured UART output from the Arty S7-25 cosmic ray detector,
parses flip-count records, saves to CSV/JSONL, and plots live.

Usage:
    python uart_logger.py --port COM3 --name "baseline" --description "Room temp test"
    python uart_logger.py --replay data/baseline_20260403_142200.jsonl
"""

import argparse
import csv
import json
import os
import queue
import re
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt
import matplotlib.animation as animation

try:
    import serial
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FLIP_RE    = re.compile(r'HOLD:(\d+)s FLIPS:([0-9A-Fa-f]{8})')
REFRESH_RE = re.compile(r'REFRESH:(OFF|SLOW|NORM|FAST)')
INTV_RE    = re.compile(r'INTERVAL:(\d+)s')

HOLD_COLORS = {5: '#4CAF50', 10: '#2196F3', 20: '#FF9800', 30: '#F44336'}
REFRESH_LABEL = {'OFF': 'Refresh OFF', 'SLOW': 'Slow (~100ms)',
                 'NORM': 'Normal (~7.8µs)', 'FAST': 'Fast (~3.9µs)'}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description='DRAM Dosimeter UART Logger')
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--port', default='COM3', help='Serial port (default: COM3)')
    mode.add_argument('--replay', metavar='FILE', help='Replay from .jsonl file (no hardware needed)')

    p.add_argument('--baud', type=int, default=115200)
    p.add_argument('--name', help='Experiment name')
    p.add_argument('--description', help='Experiment description')
    p.add_argument('--output-dir', default='data', help='Directory for output files (default: data/)')
    p.add_argument('--window', type=int, default=200, help='Rolling plot window (# of points, default: 200)')
    p.add_argument('--alert-threshold', type=int, default=None,
                   metavar='N', help='Warn if flip_count exceeds N')
    p.add_argument('--ymax', type=int, default=None, help='Fix Y-axis max for plot comparisons')
    return p.parse_args()


def prompt_experiment(args):
    """Interactively fill in name/description if not provided via CLI."""
    if not args.name:
        args.name = input('Experiment name: ').strip() or 'unnamed'
    if not args.description:
        args.description = input('Description (press Enter to skip): ').strip()
    args.name = args.name.replace(' ', '_')


# ---------------------------------------------------------------------------
# Serial reader thread
# ---------------------------------------------------------------------------

class SerialReader(threading.Thread):
    """Reads lines from the serial port and pushes them to a queue."""

    def __init__(self, port, baud, line_queue, stop_event):
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self.q = line_queue
        self.stop = stop_event
        self._ser = None

    def run(self):
        while not self.stop.is_set():
            try:
                self._ser = serial.Serial(self.port, self.baud, timeout=1)
                print(f'[serial] Connected to {self.port} @ {self.baud}', flush=True)
                while not self.stop.is_set():
                    raw = self._ser.readline()
                    if raw:
                        self.q.put((time.time(), raw))
            except serial.SerialException as e:
                print(f'[serial] {e} — retrying in 3s…', flush=True)
                if self._ser and self._ser.is_open:
                    self._ser.close()
                time.sleep(3)

    def close(self):
        self.stop.set()
        if self._ser and self._ser.is_open:
            self._ser.close()


# ---------------------------------------------------------------------------
# Message parser
# ---------------------------------------------------------------------------

def parse_line(raw_bytes, ts_unix):
    """Return a dict describing the message, or None if unrecognised."""
    try:
        line = raw_bytes.decode('ascii', errors='replace').strip()
    except Exception:
        return None

    ts = datetime.fromtimestamp(ts_unix, tz=timezone.utc).isoformat()

    m = FLIP_RE.search(line)
    if m:
        return {'type': 'FLIP', 'timestamp': ts, 'ts_unix': ts_unix,
                'hold_s': int(m.group(1)), 'flip_count': int(m.group(2), 16),
                'raw': line}

    m = REFRESH_RE.search(line)
    if m:
        return {'type': 'REFRESH', 'timestamp': ts, 'ts_unix': ts_unix,
                'refresh_rate': m.group(1), 'raw': line}

    m = INTV_RE.search(line)
    if m:
        return {'type': 'INTERVAL', 'timestamp': ts, 'ts_unix': ts_unix,
                'hold_s': int(m.group(1)), 'raw': line}

    return None


# ---------------------------------------------------------------------------
# Data store
# ---------------------------------------------------------------------------

class DataStore:
    """Accumulates records and writes CSV + JSONL files."""

    CSV_FIELDS = ['timestamp', 'iteration', 'hold_s', 'refresh_rate', 'flip_count', 'experiment']

    def __init__(self, output_dir, name, description, start_time_iso):
        self.name = name
        self.description = description
        self.records = []          # FLIP records only
        self.refresh_rate = 'OFF'  # track current state
        self.iteration = 0

        Path(output_dir).mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        base = Path(output_dir) / f'{name}_{stamp}'
        self._csv_path = base.with_suffix('.csv')
        self._jsonl_path = base.with_suffix('.jsonl')

        # Write CSV header
        with open(self._csv_path, 'w', newline='') as f:
            f.write(f'# experiment: {name}\n')
            f.write(f'# description: {description}\n')
            f.write(f'# start_time: {start_time_iso}\n')
            writer = csv.DictWriter(f, fieldnames=self.CSV_FIELDS)
            writer.writeheader()
        self._csv_file = open(self._csv_path, 'a', newline='', buffering=1)
        self._csv_writer = csv.DictWriter(self._csv_file, fieldnames=self.CSV_FIELDS)

        self._jsonl_file = open(self._jsonl_path, 'a', buffering=1)

        print(f'[store] Saving to {self._csv_path}', flush=True)

    def ingest(self, record):
        """Process a parsed record. Returns True if it was a FLIP record."""
        # Always write JSONL for all record types
        self._jsonl_file.write(json.dumps(record) + '\n')

        if record['type'] == 'REFRESH':
            self.refresh_rate = record['refresh_rate']
            return False

        if record['type'] == 'FLIP':
            self.iteration += 1
            row = {
                'timestamp':    record['timestamp'],
                'ts_unix':      record['ts_unix'],
                'iteration':    self.iteration,
                'hold_s':       record['hold_s'],
                'refresh_rate': self.refresh_rate,
                'flip_count':   record['flip_count'],
                'experiment':   self.name,
            }
            self._csv_writer.writerow({k: v for k, v in row.items() if k in self.CSV_FIELDS})
            self.records.append(row)
            return True

        return False

    def close(self):
        self._csv_file.close()
        self._jsonl_file.close()

    def summary(self):
        if not self.records:
            return 'No FLIP records captured.'
        counts = [r['flip_count'] for r in self.records]
        return (f'  Iterations : {self.iteration}\n'
                f'  Flip mean  : {sum(counts)/len(counts):.1f}\n'
                f'  Flip min   : {min(counts)}\n'
                f'  Flip max   : {max(counts)}\n'
                f'  CSV        : {self._csv_path}\n'
                f'  JSONL      : {self._jsonl_path}')


# ---------------------------------------------------------------------------
# Live plotter
# ---------------------------------------------------------------------------

class LivePlotter:
    def __init__(self, store, window, ymax, alert_threshold):
        self.store = store
        self.window = window
        self.ymax = ymax
        self.alert_threshold = alert_threshold

        matplotlib.use('TkAgg') if 'TkAgg' in matplotlib.rcsetup.all_backends else None
        self.fig, self.ax = plt.subplots(figsize=(12, 5))
        self.fig.canvas.manager.set_window_title('DRAM Dosimeter — Live')
        self.fig.tight_layout(rect=[0, 0, 0.78, 1])

        self._refresh_lines = []   # (ts_unix, label)
        self._last_refresh = None

        plt.ion()

    def _stats_text(self, counts):
        if not counts:
            return ''
        mean = sum(counts) / len(counts)
        variance = sum((c - mean) ** 2 for c in counts) / len(counts)
        std = variance ** 0.5
        return (f'n={len(counts)}\n'
                f'mean={mean:.0f}\n'
                f'std={std:.0f}\n'
                f'min={min(counts)}\n'
                f'max={max(counts)}')

    def update(self, _frame):
        records = self.store.records[-self.window:]
        if not records:
            return

        xs = [r['ts_unix'] for r in records]
        ys = [r['flip_count'] for r in records]
        hold_vals = [r['hold_s'] for r in records]

        self.ax.clear()

        # Scatter colored by hold time
        for hold_s, color in HOLD_COLORS.items():
            mask_x = [x for x, h in zip(xs, hold_vals) if h == hold_s]
            mask_y = [y for y, h in zip(ys, hold_vals) if h == hold_s]
            if mask_x:
                self.ax.scatter(mask_x, mask_y, color=color, s=18, zorder=3,
                                label=f'{hold_s}s hold')

        # Line connecting points
        self.ax.plot(xs, ys, color='#888', linewidth=0.8, zorder=2)

        # Alert threshold line
        if self.alert_threshold is not None:
            self.ax.axhline(self.alert_threshold, color='red', linestyle='--',
                            linewidth=1, label=f'Alert: {self.alert_threshold}')

        # Refresh rate change markers (within window)
        x_min = xs[0] if xs else 0
        for ts_u, label in self._refresh_lines:
            if ts_u >= x_min:
                self.ax.axvline(ts_u, color='purple', linestyle=':', linewidth=1.2, alpha=0.7)
                self.ax.text(ts_u, self.ax.get_ylim()[1] * 0.95, label,
                             fontsize=7, color='purple', rotation=90, va='top')

        # Axes
        self.ax.set_xlabel('Time (unix)')
        self.ax.set_ylabel('Bit Flips')
        self.ax.set_title(f'Experiment: {self.store.name}  |  '
                          f'Iteration: {self.store.iteration}  |  '
                          f'Refresh: {self.store.refresh_rate}')
        if self.ymax:
            self.ax.set_ylim(0, self.ymax)
        self.ax.legend(loc='upper left', fontsize=8)

        # Stats text box (right side)
        stats = self._stats_text(ys)
        self.fig.text(0.80, 0.5, stats, transform=self.fig.transFigure,
                      fontsize=9, verticalalignment='center',
                      bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

        self.fig.canvas.draw_idle()

    def register_refresh(self, ts_unix, rate):
        label = REFRESH_LABEL.get(rate, rate)
        self._refresh_lines.append((ts_unix, label))

    def start(self, interval_ms=1500):
        self._anim = animation.FuncAnimation(
            self.fig, self.update, interval=interval_ms, cache_frame_data=False)
        plt.show(block=False)


# ---------------------------------------------------------------------------
# Hang detector
# ---------------------------------------------------------------------------

class HangDetector:
    def __init__(self, hold_s=5, multiplier=2.5):
        self.multiplier = multiplier
        self._expected_s = hold_s
        self._last_flip_time = time.time()

    def update_hold(self, hold_s):
        self._expected_s = hold_s

    def tick(self):
        elapsed = time.time() - self._last_flip_time
        threshold = self._expected_s * self.multiplier + 60  # generous buffer for scan time
        if elapsed > threshold:
            print(f'\n[WARN] No FLIP message in {elapsed:.0f}s '
                  f'(expected ~{self._expected_s}s hold). Board may be hung.',
                  flush=True)

    def reset(self, hold_s):
        self._expected_s = hold_s
        self._last_flip_time = time.time()


# ---------------------------------------------------------------------------
# Replay mode
# ---------------------------------------------------------------------------

def replay(jsonl_path, store, plotter, args):
    """Feed a .jsonl file into the store and plotter as if it were live."""
    print(f'[replay] Reading {jsonl_path}', flush=True)
    plotter.start()
    with open(jsonl_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get('type') == 'REFRESH':
                plotter.register_refresh(record.get('ts_unix', 0), record['refresh_rate'])
            if store.ingest(record) and args.alert_threshold:
                if record['flip_count'] > args.alert_threshold:
                    print(f'[ALERT] flip_count={record["flip_count"]} > {args.alert_threshold}',
                          flush=True)
            time.sleep(0.05)  # slight delay so the animation can render
            plt.pause(0.01)

    print('\n[replay] Done. Close the plot window to exit.')
    plt.show(block=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    if not args.replay:
        if not SERIAL_AVAILABLE:
            sys.exit('[error] pyserial not installed. Run: pip install pyserial matplotlib')
        prompt_experiment(args)

    start_unix = time.time()
    start_iso = datetime.now(tz=timezone.utc).isoformat()
    store = DataStore(
        output_dir=args.output_dir,
        name=args.name or 'replay',
        description=args.description or '',
        start_time_iso=start_iso,
    )
    plotter = LivePlotter(store, args.window, args.ymax, args.alert_threshold)
    hang = HangDetector()

    # ---- Replay mode -------------------------------------------------------
    if args.replay:
        replay(args.replay, store, plotter, args)
        store.close()
        print('\n--- Session summary ---')
        print(store.summary())
        return

    # ---- Live mode ---------------------------------------------------------
    line_queue = queue.Queue()
    stop_event = threading.Event()
    reader = SerialReader(args.port, args.baud, line_queue, stop_event)
    reader.start()
    plotter.start()

    print(f'\n[logger] Listening on {args.port}. Press Ctrl-C to stop.\n', flush=True)

    try:
        while True:
            # Drain the queue
            while not line_queue.empty():
                ts_unix, raw = line_queue.get_nowait()
                record = parse_line(raw, ts_unix)
                if record is None:
                    continue

                # Hang detector bookkeeping
                if record['type'] == 'INTERVAL':
                    hang.update_hold(record['hold_s'])
                if record['type'] == 'FLIP':
                    hang.reset(record['hold_s'])

                # Alert check
                if record['type'] == 'FLIP' and args.alert_threshold:
                    if record['flip_count'] > args.alert_threshold:
                        print(f'\n[ALERT] flip_count={record["flip_count"]} '
                              f'> threshold {args.alert_threshold}', flush=True)

                # Plotter refresh annotation
                if record['type'] == 'REFRESH':
                    plotter.register_refresh(ts_unix, record['refresh_rate'])

                store.ingest(record)

                # Terminal status line
                if record['type'] == 'FLIP':
                    print(f'\r  Iter {store.iteration:>5}  |  '
                          f'Flips: {record["flip_count"]:>10,}  |  '
                          f'Hold: {record["hold_s"]}s  |  '
                          f'Refresh: {store.refresh_rate:<5}  |  '
                          f'Elapsed: {int(time.time() - start_unix)}s',
                          end='', flush=True)

            hang.tick()
            plt.pause(0.5)

    except KeyboardInterrupt:
        print('\n\n[logger] Shutting down…', flush=True)
    finally:
        reader.close()
        store.close()
        plt.close('all')
        print('\n--- Session summary ---')
        print(store.summary())


if __name__ == '__main__':
    main()
