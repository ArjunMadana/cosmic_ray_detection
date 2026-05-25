"""
uart_logger.py — DRAM Dosimeter GUI Logger & Live Plotter

Tkinter GUI: no CLI arguments needed for normal use.
Usage:
    python tools/uart_logger.py                       # open GUI
    python tools/uart_logger.py --replay FILE.jsonl   # replay saved session
"""

import argparse
import csv
import json
import queue
import re
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

import warnings
import matplotlib
matplotlib.use('TkAgg')
warnings.filterwarnings('ignore', message='No artists with labels')
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure

try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FLIP_RE      = re.compile(r'HOLD:(\d+)s PAT:([0-9A-Fa-f]{2}) FLIPS:([0-9A-Fa-f]{8})')
TEMP_RE      = re.compile(r'TEMP:([0-9A-Fa-f]{3})')
REFRESH_RE   = re.compile(r'REFRESH:(OFF|SLOW|NORM|FAST)')
INTV_RE      = re.compile(r'INTERVAL:(\d+)s')
PATTERN_RE   = re.compile(r'PATTERN:(FF|00|55|AA)')
READY_RE     = re.compile(r'^READY$')
BOOT_RE      = re.compile(r'^BOOT$')
ADDRS_HDR_RE = re.compile(r'^ADDRS:([0-9A-Fa-f]{4})(?:\s+OVF:([01]))?$')
ADDR_LINE_RE = re.compile(r'^([0-9A-Fa-f]{7})$')
DIAG_RE      = re.compile(
    r'DIAG:F1:([0-9A-Fa-f]{8}) F2:([0-9A-Fa-f]{8}) SC:([0-9A-Fa-f]{8}) '
    r'BERR:([0-9A-Fa-f]{8}) RERR:([0-9A-Fa-f]{8})'
    r'(?: AW:([0-9A-Fa-f]{8}) W:([0-9A-Fa-f]{8}) B:([0-9A-Fa-f]{8}))? '
    r'BAD:([0-9A-Fa-fX]{7}) GOT:([0-9A-Fa-fX]{8}) EXP:([0-9A-Fa-fX]{8}) OVF:([01])')
VDIAG_RE     = re.compile(
    r'VDIAG:VC:([0-9A-Fa-f]{8}) VBAD:([0-9A-Fa-fX]{7}) '
    r'VGOT:([0-9A-Fa-fX]{8}) VEXP:([0-9A-Fa-fX]{8})')

HOLD_COLORS = {5: '#4CAF50', 10: '#2196F3', 20: '#FF9800', 30: '#F44736'}
REFRESH_LABEL = {'OFF': 'Refresh OFF', 'SLOW': 'Slow (~100ms)',
                 'NORM': 'Normal (~7.8µs)', 'FAST': 'Fast (~3.9µs)'}
PATTERN_LABEL = {'FF': '0xFFFFFFFF', '00': '0x00000000',
                 '55': '0x55555555', 'AA': '0xAAAAAAAA'}
REFRESH_TO_CMD = {'OFF': '0', 'SLOW': '1', 'NORM': '2', 'FAST': '3'}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def find_arty_port():
    """Return the most likely COM port for the Arty S7 UART interface, or None."""
    if not SERIAL_AVAILABLE:
        return None
    # FT2232H (VID=0x0403, PID=0x6010) creates two ports; UART is on interface B (higher)
    candidates = [p for p in serial.tools.list_ports.comports()
                  if p.vid == 0x0403 and p.pid == 0x6010]
    if candidates:
        return sorted(candidates, key=lambda p: p.device)[-1].device
    return None

# ---------------------------------------------------------------------------
# Serial reader thread
# ---------------------------------------------------------------------------

class SerialReader(threading.Thread):
    def __init__(self, port, baud, q, stop_event):
        super().__init__(daemon=True)
        self.port, self.baud = port, baud
        self.q, self.stop = q, stop_event
        self._ser = None

    def run(self):
        while not self.stop.is_set():
            try:
                self._ser = serial.Serial(self.port, self.baud, timeout=1)
                self.q.put(('STATUS', f'Connected to {self.port} @ {self.baud}'))
                while not self.stop.is_set():
                    raw = self._ser.readline()
                    if raw:
                        self.q.put(('DATA', (time.time(), raw)))
            except Exception as e:
                self.q.put(('STATUS', f'Serial error: {e} — retrying in 3 s…'))
                if self._ser and self._ser.is_open:
                    self._ser.close()
                time.sleep(3)

    def write(self, data: bytes) -> bool:
        if self._ser and self._ser.is_open:
            try:
                self._ser.write(data)
                self._ser.flush()
                return True
            except Exception:
                return False
        return False

    def close(self):
        self.stop.set()
        if self._ser and self._ser.is_open:
            self._ser.close()

# ---------------------------------------------------------------------------
# Message parser
# ---------------------------------------------------------------------------

def parse_line(raw_bytes, ts_unix):
    try:
        line = raw_bytes.decode('ascii', errors='replace').strip()
    except Exception:
        return None
    ts = datetime.fromtimestamp(ts_unix, tz=timezone.utc).isoformat()
    m = FLIP_RE.search(line)
    if m:
        return {'type': 'FLIP', 'timestamp': ts, 'ts_unix': ts_unix,
                'hold_s': int(m.group(1)), 'pattern': m.group(2).upper(),
                'flip_count': int(m.group(3), 16), 'raw': line}
    m = REFRESH_RE.search(line)
    if m:
        return {'type': 'REFRESH', 'timestamp': ts, 'ts_unix': ts_unix,
                'refresh_rate': m.group(1), 'raw': line}
    m = INTV_RE.search(line)
    if m:
        return {'type': 'INTERVAL', 'timestamp': ts, 'ts_unix': ts_unix,
                'hold_s': int(m.group(1)), 'raw': line}
    m = PATTERN_RE.search(line)
    if m:
        return {'type': 'PATTERN', 'timestamp': ts, 'ts_unix': ts_unix,
                'pattern': m.group(1).upper(), 'raw': line}
    if READY_RE.search(line):
        return {'type': 'READY', 'timestamp': ts, 'ts_unix': ts_unix, 'raw': line}
    if BOOT_RE.search(line):
        return {'type': 'BOOT', 'timestamp': ts, 'ts_unix': ts_unix, 'raw': line}
    m = ADDRS_HDR_RE.match(line)
    if m:
        return {'type': 'ADDRS_HDR', 'timestamp': ts, 'ts_unix': ts_unix,
                'count': int(m.group(1), 16),
                'addr_overflow': m.group(2) == '1', 'raw': line}
    m = TEMP_RE.search(line)
    if m:
        raw_code = int(m.group(1), 16)
        temp_c = raw_code * 503.975 / 4096 - 273.15
        return {'type': 'TEMP', 'timestamp': ts, 'ts_unix': ts_unix,
                'raw_code': raw_code, 'temp_c': round(temp_c, 1), 'raw': line}
    m = DIAG_RE.search(line)
    if m:
        def hex_or_none(value):
            return None if 'X' in value.upper() else int(value, 16)
        return {'type': 'DIAG', 'timestamp': ts, 'ts_unix': ts_unix,
                'fill1_count': int(m.group(1), 16),
                'fill2_count': int(m.group(2), 16),
                'scan_count': int(m.group(3), 16),
                'bresp_errors': int(m.group(4), 16),
                'rresp_errors': int(m.group(5), 16),
                'aw_count': int(m.group(6), 16) if m.group(6) is not None else None,
                'w_count': int(m.group(7), 16) if m.group(7) is not None else None,
                'b_count': int(m.group(8), 16) if m.group(8) is not None else None,
                'first_bad_addr': hex_or_none(m.group(9)),
                'first_bad_got': hex_or_none(m.group(10)),
                'first_bad_exp': hex_or_none(m.group(11)),
                'addr_overflow': m.group(12) == '1',
                'raw': line}
    m = VDIAG_RE.search(line)
    if m:
        def hex_or_none(value):
            return None if 'X' in value.upper() else int(value, 16)
        return {'type': 'VDIAG', 'timestamp': ts, 'ts_unix': ts_unix,
                'verify_count': int(m.group(1), 16),
                'verify_bad_addr': hex_or_none(m.group(2)),
                'verify_got': hex_or_none(m.group(3)),
                'verify_exp': hex_or_none(m.group(4)),
                'raw': line}
    return None

# ---------------------------------------------------------------------------
# Data store
# ---------------------------------------------------------------------------

class DataStore:
    CSV_FIELDS = ['timestamp', 'iteration', 'hold_s', 'refresh_rate', 'pattern',
                  'flip_count', 'addr_overflow', 'temp_c', 'experiment']

    def __init__(self, output_dir, name, description, start_time_iso):
        self.name = name
        self.description = description
        self.records = []       # FLIP rows (include ts_unix for plotting)
        self.notes   = []       # NOTE records
        self.refresh_rate = 'OFF'
        self.pattern      = 'FF'
        self.temp_c       = None
        self.iteration = 0

        Path(output_dir).mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        base  = Path(output_dir) / f'{name}_{stamp}'
        self.csv_path   = base.with_suffix('.csv')
        self.jsonl_path = base.with_suffix('.jsonl')

        with open(self.csv_path, 'w', newline='') as f:
            f.write(f'# experiment: {name}\n')
            f.write(f'# description: {description}\n')
            f.write(f'# start_time: {start_time_iso}\n')
            csv.DictWriter(f, fieldnames=self.CSV_FIELDS).writeheader()

        self._csv_file   = open(self.csv_path,   'a', newline='', buffering=1)
        self._csv_writer = csv.DictWriter(self._csv_file, fieldnames=self.CSV_FIELDS)
        self._jsonl_file = open(self.jsonl_path, 'a', buffering=1)

    def ingest(self, record):
        self._jsonl_file.write(json.dumps(record) + '\n')
        if record['type'] == 'REFRESH':
            self.refresh_rate = record['refresh_rate']
            return False
        if record['type'] == 'PATTERN':
            self.pattern = record['pattern']
            return False
        if record['type'] == 'TEMP':
            self.temp_c = record['temp_c']
            return False
        if record['type'] == 'FLIP':
            self.iteration += 1
            row = {
                'timestamp':    record['timestamp'],
                'ts_unix':      record['ts_unix'],
                'iteration':    self.iteration,
                'hold_s':       record['hold_s'],
                'refresh_rate': self.refresh_rate,
                'pattern':      record.get('pattern', self.pattern),
                'flip_count':   record['flip_count'],
                'addr_overflow': record.get('addr_overflow', False),
                'temp_c':       self.temp_c,
                'experiment':   self.name,
            }
            self._csv_writer.writerow({k: v for k, v in row.items() if k in self.CSV_FIELDS})
            self.records.append(row)
            return True
        return False

    def add_note(self, text):
        ts_unix = time.time()
        ts = datetime.fromtimestamp(ts_unix, tz=timezone.utc).isoformat()
        record = {'type': 'NOTE', 'timestamp': ts, 'ts_unix': ts_unix, 'text': text}
        self._jsonl_file.write(json.dumps(record) + '\n')
        self.notes.append(record)
        return record

    def close(self):
        self._csv_file.close()
        self._jsonl_file.close()

    def summary(self):
        if not self.records:
            return 'No FLIP records captured.'
        counts = [r['flip_count'] for r in self.records]
        mean = sum(counts) / len(counts)
        return (f'  Iterations : {self.iteration}\n'
                f'  Flip mean  : {mean:.1f}  min: {min(counts)}  max: {max(counts)}\n'
                f'  CSV   → {self.csv_path}\n'
                f'  JSONL → {self.jsonl_path}')

# ---------------------------------------------------------------------------
# Hang detector
# ---------------------------------------------------------------------------

class HangDetector:
    MULT = 2.5
    def __init__(self):
        self._expected_s = 5
        self._last = time.time()
    def reset(self, hold_s):
        self._expected_s = hold_s
        self._last = time.time()
    def update_hold(self, hold_s):
        self._expected_s = hold_s
    def is_hung(self):
        return time.time() - self._last > self._expected_s * self.MULT + 60
    def seconds_since(self):
        return int(time.time() - self._last)

# ---------------------------------------------------------------------------
# GUI application
# ---------------------------------------------------------------------------
# Background model
# ---------------------------------------------------------------------------

class BackgroundModel:
    def __init__(self, hot_threshold=0.5, rare_threshold=0.1, min_cycles=20):
        self._counts        = {}   # addr -> number of cycles it has flipped
        self._n_cycles      = 0
        self.hot_threshold  = hot_threshold
        self.rare_threshold = rare_threshold
        self.min_cycles     = min_cycles

    def update(self, addrs: list):
        self._n_cycles += 1
        for a in addrs:
            self._counts[a] = self._counts.get(a, 0) + 1

    @property
    def ready(self):
        return self._n_cycles >= self.min_cycles

    @property
    def n_cycles(self):
        return self._n_cycles

    @property
    def n_hot(self):
        if not self.ready:
            return 0
        return sum(1 for c in self._counts.values()
                   if c / self._n_cycles >= self.hot_threshold)

    def classify(self, addrs: list):
        """Returns (hot_pixels, rare_events) lists."""
        if not self.ready:
            return list(addrs), []
        hot, rare = [], []
        for a in addrs:
            rate = self._counts.get(a, 0) / self._n_cycles
            (hot if rate >= self.hot_threshold else rare).append(a)
        return hot, rare

    def find_clusters(self, addrs: list, window=1000, min_size=3):
        """Find groups of >= min_size addresses within a window of each other."""
        if len(addrs) < min_size:
            return []
        s = sorted(addrs)
        clusters, i = [], 0
        while i < len(s):
            j = i
            while j < len(s) and s[j] - s[i] <= window:
                j += 1
            if j - i >= min_size:
                clusters.append({
                    'start': s[i], 'end': s[j - 1],
                    'count': j - i, 'addrs': s[i:j],
                })
            i += 1
        return clusters

# ---------------------------------------------------------------------------

class SweepWindow(tk.Toplevel):
    """Separate window for automated hold-time sweep experiments."""

    PLOT_MS = 2000

    def __init__(self, parent, app):
        super().__init__(parent)
        self.title('Interval Sweep')
        self.minsize(700, 600)
        self.protocol('WM_DELETE_WINDOW', self._on_close)

        self._app = app  # reference to DosimeterApp for sending H commands

        # Sweep state
        self._steps        = []
        self._step_idx     = 0
        self._iters_done   = 0
        self._iters_target = 1
        self._running      = False
        self._sweep_data   = {}   # hold_s -> {addr: count}
        self._sweep_counts = {}   # hold_s -> [flip_count, ...]

        self._build_ui()
        self.after(self.PLOT_MS, self._update_plots)

    def _build_ui(self):
        pad = {'padx': 4, 'pady': 2}

        # Config frame
        cf = ttk.LabelFrame(self, text='Sweep Configuration', padding=4)
        cf.pack(fill='x', padx=6, pady=(6, 0))

        ttk.Label(cf, text='Min hold (s):').grid(row=0, column=0, sticky='w', **pad)
        self._min_var = tk.StringVar(value='5')
        ttk.Entry(cf, textvariable=self._min_var, width=6).grid(row=0, column=1, **pad)

        ttk.Label(cf, text='Max hold (s):').grid(row=0, column=2, sticky='w', **pad)
        self._max_var = tk.StringVar(value='60')
        ttk.Entry(cf, textvariable=self._max_var, width=6).grid(row=0, column=3, **pad)

        ttk.Label(cf, text='Step (s):').grid(row=0, column=4, sticky='w', **pad)
        self._step_var = tk.StringVar(value='5')
        ttk.Entry(cf, textvariable=self._step_var, width=6).grid(row=0, column=5, **pad)

        ttk.Label(cf, text='Iterations/step:').grid(row=0, column=6, sticky='w', **pad)
        self._iters_var = tk.StringVar(value='20')
        ttk.Entry(cf, textvariable=self._iters_var, width=6).grid(row=0, column=7, **pad)

        self._run_btn  = ttk.Button(cf, text='▶ Run Sweep', command=self._start_sweep)
        self._stop_btn = ttk.Button(cf, text='■ Stop', command=self._stop_sweep, state='disabled')
        self._run_btn.grid(row=0, column=8, padx=(12, 2))
        self._stop_btn.grid(row=0, column=9, padx=2)

        # Progress label
        self._prog_var = tk.StringVar(value='Not running')
        ttk.Label(self, textvariable=self._prog_var, padding=(6, 2)).pack(anchor='w')

        # Plots frame
        pf = ttk.Frame(self)
        pf.pack(fill='both', expand=True, padx=6, pady=4)
        pf.columnconfigure(0, weight=1)
        pf.rowconfigure(0, weight=1)
        pf.rowconfigure(1, weight=1)

        self._fig = Figure(figsize=(9, 7), tight_layout=True)
        self._ax_bar, self._ax_heat = self._fig.subplots(2, 1)
        self._canvas_sw = FigureCanvasTkAgg(self._fig, master=pf)
        self._canvas_sw.get_tk_widget().grid(row=0, column=0, rowspan=2, sticky='nsew')
        self._draw_empty()

    def _draw_empty(self):
        for ax, title in [(self._ax_bar,  'Unique failing cells per hold time'),
                          (self._ax_heat, 'Address raster per hold time')]:
            ax.clear()
            ax.set_title(title)
        self._ax_bar.set_xlabel('Hold time (s)')
        self._ax_bar.set_ylabel('Unique failing addresses')
        self._ax_heat.set_xlabel('Address rank (compressed)')
        self._ax_heat.set_ylabel('Hold time (s)')
        self._canvas_sw.draw_idle()

    # ------------------------------------------------------------------
    # Sweep control
    # ------------------------------------------------------------------

    def _start_sweep(self):
        try:
            mn    = int(self._min_var.get())
            mx    = int(self._max_var.get())
            step  = int(self._step_var.get())
            iters = int(self._iters_var.get())
        except ValueError:
            messagebox.showwarning('Sweep', 'All fields must be integers.')
            return
        if mn < 1 or mx < mn or step < 1 or iters < 1:
            messagebox.showwarning('Sweep', 'Check values: min ≥ 1, max ≥ min, step ≥ 1, iters ≥ 1.')
            return
        if not self._app._running or not self._app._reader:
            messagebox.showwarning('Sweep', 'Start the main session first (▶ Start), then run the sweep.')
            return

        self._steps        = list(range(mn, mx + 1, step))
        self._step_idx     = 0
        self._iters_done   = 0
        self._iters_target = iters
        self._sweep_data   = {s: {} for s in self._steps}
        self._sweep_counts = {s: [] for s in self._steps}
        self._running      = True
        self._run_btn.config(state='disabled')
        self._stop_btn.config(state='normal')
        self._send_current_hold()
        self._update_progress()

    def _stop_sweep(self):
        self._running = False
        self._run_btn.config(state='normal')
        self._stop_btn.config(state='disabled')
        self._prog_var.set('Stopped.')
        self._save_csv()

    def _send_current_hold(self):
        hold = self._steps[self._step_idx]
        self._app._reader.write(f'H{hold}\n'.encode('ascii'))

    def _advance_step(self):
        self._step_idx += 1
        self._iters_done = 0
        if self._step_idx >= len(self._steps):
            self._running = False
            self._run_btn.config(state='normal')
            self._stop_btn.config(state='disabled')
            self._prog_var.set('Sweep complete.')
            self._save_csv()
        else:
            self._send_current_hold()
            self._update_progress()

    def _update_progress(self):
        if not self._running:
            return
        hold = self._steps[self._step_idx]
        self._prog_var.set(
            f'Step {self._step_idx + 1}/{len(self._steps)}  —  '
            f'hold={hold}s  —  iter {self._iters_done}/{self._iters_target}')

    # ------------------------------------------------------------------
    # Called by DosimeterApp on each FLIP record while sweep is running
    # ------------------------------------------------------------------

    def on_flip(self, record):
        hold = self._steps[self._step_idx]
        for addr in record.get('addrs', []):
            d = self._sweep_data[hold]
            d[addr] = d.get(addr, 0) + 1
        self._sweep_counts[hold].append(record['flip_count'])
        self._iters_done += 1
        self._update_progress()
        if self._iters_done >= self._iters_target:
            self._advance_step()

    # ------------------------------------------------------------------
    # Plot refresh
    # ------------------------------------------------------------------

    def _update_plots(self):
        try:
            completed = [s for s in self._steps if self._sweep_counts.get(s)]
            if completed:
                self._redraw(completed)
        except Exception:
            pass
        finally:
            self.after(self.PLOT_MS, self._update_plots)

    def _redraw(self, completed):
        # Bar chart — mean flip count per hold time
        ax = self._ax_bar
        ax.clear()
        means        = [sum(self._sweep_counts[s]) / max(len(self._sweep_counts[s]), 1)
                        for s in completed]
        bars = ax.bar([str(s) for s in completed], means, color='#2196F3', alpha=0.8)
        # Annotate each bar: iteration count + unique address count
        ymax = max(means) if any(m > 0 for m in means) else 1
        for bar, s, mean in zip(bars, completed, means):
            n_iter  = len(self._sweep_counts[s])
            n_addrs = len(self._sweep_data[s])
            ax.text(bar.get_x() + bar.get_width() / 2,
                    mean + ymax * 0.02,
                    f'{n_iter} iter\n{n_addrs:,} addr',
                    ha='center', va='bottom', fontsize=7, color='#ccc')
        ax.set_xlabel('Hold time (s)')
        ax.set_ylabel('Mean flip count')
        ax.set_title('Mean flip count per hold time  (annotated: iterations completed, unique failing addresses)')
        if not any(m > 0 for m in means):
            ax.text(0.5, 0.5, 'No flips yet — try longer hold times',
                    transform=ax.transAxes, ha='center', va='center',
                    fontsize=10, color='#888')

        # Scatter: failing address rank vs hold time
        # Each dot is one address that flipped at that hold time.
        # Dot brightness = how many times that address flipped across iterations.
        ax2 = self._ax_heat
        ax2.clear()
        ax2.set_title('Failing address raster by hold time')
        ax2.set_xlabel('Address rank (compressed — each dot = one unique failing cell)')
        ax2.set_ylabel('Hold time (s)')
        ax2.text(0.5, 0.98,
                 'Brighter dot = cell failed more often across iterations at that hold time.\n'
                 'Dots that appear at low hold times are the weakest cells.',
                 transform=ax2.transAxes, ha='center', va='top',
                 fontsize=7, color='#aaa')
        all_addrs = sorted({a for s in completed for a in self._sweep_data[s]})
        if all_addrs:
            rank = {a: i for i, a in enumerate(all_addrs)}
            xs, ys, cs = [], [], []
            for s in completed:
                for addr, cnt in self._sweep_data[s].items():
                    xs.append(rank[addr])
                    ys.append(s)
                    cs.append(cnt)
            max_c = max(cs) if cs else 1
            alphas = [min(1.0, 0.2 + 0.8 * c / max_c) for c in cs]
            for x, y, a in zip(xs, ys, alphas):
                ax2.scatter(x, y, c='#00D4FF', s=6, alpha=a, linewidths=0)
            ax2.set_xlabel(f'Address rank (compressed — {len(all_addrs):,} unique failing cells)')

        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self._fig.tight_layout()
        self._canvas_sw.draw_idle()

    # ------------------------------------------------------------------
    # Save results CSV
    # ------------------------------------------------------------------

    def _save_csv(self):
        if not any(self._sweep_counts.values()):
            return
        outdir = self._app._outdir_var.get() or 'data'
        stamp  = datetime.now().strftime('%Y%m%d_%H%M%S')
        name   = self._app._name_var.get().strip().replace(' ', '_') or 'sweep'
        path   = Path(outdir) / f'sweep_{name}_{stamp}.csv'
        try:
            Path(outdir).mkdir(parents=True, exist_ok=True)
            with open(path, 'w', newline='') as f:
                f.write(f'# sweep experiment: {name}\n')
                w = csv.DictWriter(f, fieldnames=['hold_s', 'unique_addrs',
                                                   'mean_flips', 'min_flips', 'max_flips'])
                w.writeheader()
                for s in self._steps:
                    counts = self._sweep_counts.get(s, [])
                    if counts:
                        w.writerow({'hold_s': s,
                                    'unique_addrs': len(self._sweep_data[s]),
                                    'mean_flips': round(sum(counts) / len(counts), 1),
                                    'min_flips': min(counts),
                                    'max_flips': max(counts)})
            self._prog_var.set(f'{self._prog_var.get()}  → {path}')
        except Exception as e:
            self._prog_var.set(f'CSV save error: {e}')

    def _on_close(self):
        self._running = False
        self._app._sweep_win = None
        self.destroy()


class DosimeterApp:
    POLL_MS = 400
    PLOT_MS = 1500

    def __init__(self, root, replay_file=None):
        self.root = root
        root.title('DRAM Dosimeter')
        root.minsize(960, 700)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(2, weight=1)   # plot row expands
        root.protocol('WM_DELETE_WINDOW', self._on_close)

        self._reader      = None
        self._store       = None
        self._hang        = HangDetector()
        self._q           = queue.Queue()
        self._stop        = threading.Event()
        self._start_unix  = None
        self._alert       = None
        self._window      = 200
        self._ref_events  = []   # (ts_unix, label) for vertical lines on plot
        self._pat_events  = []   # (ts_unix, label) for pattern-change markers
        self._sweep_win      = None   # SweepWindow instance (if open)
        self._temp_records   = []     # (ts_unix, temp_c) for plot overlay
        self._connected      = False
        self._board_ready    = False  # True after READY received from board
        self._running        = False  # True after Start clicked and G sent
        self._addr_remaining = 0      # address lines still expected from ADDRS header
        self._addr_buf       = []     # addresses collected for current cycle
        self._addr_overflow  = False
        self._bg             = BackgroundModel()
        self._rare_records   = []     # (iteration, rare_count, clusters) for de-noised plot
        self._raster_records = []     # (iteration, hot_addrs, rare_addrs) for raster

        self._build_ui()

        # Loops run continuously; they no-op when not connected
        root.after(self.POLL_MS, self._poll)
        root.after(self.PLOT_MS, self._update_plot)

        if replay_file:
            root.after(200, lambda: self._start_replay(replay_file))

    # -----------------------------------------------------------------------
    # UI construction
    # -----------------------------------------------------------------------

    def _build_ui(self):
        pad = {'padx': 4, 'pady': 2}

        # ── Row 0: connection ──────────────────────────────────────────────
        cf = ttk.LabelFrame(self.root, text='Connection', padding=4)
        cf.grid(row=0, column=0, sticky='ew', padx=6, pady=(6, 0))

        ttk.Label(cf, text='Port:').pack(side='left')
        self._port_var = tk.StringVar(value='COM3')
        self._port_cb  = ttk.Combobox(cf, textvariable=self._port_var, width=7)
        self._port_cb.pack(side='left', padx=(2, 0))
        ttk.Button(cf, text='↺', width=2, command=self._refresh_ports).pack(side='left', padx=2)

        ttk.Label(cf, text='Baud:').pack(side='left', padx=(8, 0))
        self._baud_var = tk.StringVar(value='115200')
        ttk.Entry(cf, textvariable=self._baud_var, width=7).pack(side='left', padx=2)

        ttk.Separator(cf, orient='vertical').pack(side='left', fill='y', padx=8)

        self._conn_btn  = ttk.Button(cf, text='Connect',      command=self._connect)
        self._disc_btn  = ttk.Button(cf, text='Disconnect',   command=self._disconnect, state='disabled')
        self._start_btn = ttk.Button(cf, text='▶ Start',      command=self._start,       state='disabled')
        self._reset_btn = ttk.Button(cf, text='↺ Reset Board',command=self._reset_board, state='disabled')
        self._conn_btn.pack(side='left', padx=2)
        self._disc_btn.pack(side='left', padx=2)
        ttk.Separator(cf, orient='vertical').pack(side='left', fill='y', padx=6)
        self._start_btn.pack(side='left', padx=2)
        self._reset_btn.pack(side='left', padx=2)
        ttk.Separator(cf, orient='vertical').pack(side='left', fill='y', padx=6)
        ttk.Button(cf, text='Sweep…', command=self._open_sweep).pack(side='left', padx=2)

        ttk.Separator(cf, orient='vertical').pack(side='left', fill='y', padx=8)

        ttk.Label(cf, text='Output dir:').pack(side='left')
        self._outdir_var = tk.StringVar(value='data')
        ttk.Entry(cf, textvariable=self._outdir_var, width=12).pack(side='left', padx=2)
        ttk.Button(cf, text='…', width=2, command=self._browse_dir).pack(side='left')

        # ── Row 1: experiment info ─────────────────────────────────────────
        ef = ttk.LabelFrame(self.root, text='Experiment', padding=4)
        ef.grid(row=1, column=0, sticky='ew', padx=6, pady=(4, 0))
        ef.columnconfigure(1, weight=1)
        ef.columnconfigure(3, weight=3)

        ttk.Label(ef, text='Name:').grid(row=0, column=0, sticky='w', **pad)
        self._name_var = tk.StringVar(value='experiment')
        ttk.Entry(ef, textvariable=self._name_var, width=20).grid(row=0, column=1, sticky='ew', **pad)

        ttk.Label(ef, text='Description:').grid(row=0, column=2, sticky='w', **pad)
        self._desc_var = tk.StringVar()
        ttk.Entry(ef, textvariable=self._desc_var).grid(row=0, column=3, sticky='ew', **pad)

        # ── Row 2: tabbed plots ────────────────────────────────────────────
        nb = ttk.Notebook(self.root)
        nb.grid(row=2, column=0, sticky='nsew', padx=6, pady=4)

        tab1 = ttk.Frame(nb)
        tab2 = ttk.Frame(nb)
        tab3 = ttk.Frame(nb)
        nb.add(tab1, text='Raw flip count')
        nb.add(tab2, text='De-noised (rare events)')
        nb.add(tab3, text='Address raster')
        for tab in (tab1, tab2, tab3):
            tab.columnconfigure(0, weight=1)
            tab.rowconfigure(0, weight=1)

        # Tab 1 — raw flip count (existing plot)
        self._fig = Figure(figsize=(10, 4), tight_layout=True)
        self._ax  = self._fig.add_subplot(111)
        self._ax_temp = self._ax.twinx()
        self._ax_temp.set_visible(False)
        self._canvas = FigureCanvasTkAgg(self._fig, master=tab1)
        self._canvas.get_tk_widget().grid(row=0, column=0, sticky='nsew')
        self._draw_empty_plot()

        # Tab 2 — de-noised rare event plot
        self._fig2 = Figure(figsize=(10, 4), tight_layout=True)
        self._ax2  = self._fig2.add_subplot(111)
        self._canvas2 = FigureCanvasTkAgg(self._fig2, master=tab2)
        self._canvas2.get_tk_widget().grid(row=0, column=0, sticky='nsew')
        self._draw_empty_denoised()

        # Tab 3 — address raster
        self._fig3 = Figure(figsize=(10, 4), tight_layout=True)
        self._ax3  = self._fig3.add_subplot(111)
        self._canvas3 = FigureCanvasTkAgg(self._fig3, master=tab3)
        self._canvas3.get_tk_widget().grid(row=0, column=0, sticky='nsew')
        self._draw_empty_raster()

        # ── Row 3: status bar ──────────────────────────────────────────────
        sf = ttk.Frame(self.root, relief='sunken', borderwidth=1)
        sf.grid(row=3, column=0, sticky='ew', padx=6)

        self._slabels = {}
        for key, text in [('iter', 'Iter: —'), ('flips', 'Flips: —'),
                          ('hold', 'Hold: —'), ('refresh', 'Refresh: —'),
                          ('elapsed', 'Elapsed: —'), ('temp', 'Temp: —'),
                          ('bg', 'BG: —'), ('hang', '')]:
            lbl = ttk.Label(sf, text=text, padding=(10, 2))
            lbl.pack(side='left')
            self._slabels[key] = lbl

        # ── Row 4: controls ────────────────────────────────────────────────
        ctrl = ttk.Frame(self.root, padding=(6, 2))
        ctrl.grid(row=4, column=0, sticky='ew')

        # Hold time
        ttk.Label(ctrl, text='Hold time (s):').pack(side='left')
        self._hold_var = tk.StringVar()
        hold_e = ttk.Entry(ctrl, textvariable=self._hold_var, width=6)
        hold_e.pack(side='left', padx=(2, 0))
        hold_e.bind('<Return>', lambda _: self._send_hold())
        ttk.Button(ctrl, text='Send', command=self._send_hold).pack(side='left', padx=(2, 14))

        # Pattern selector
        ttk.Separator(ctrl, orient='vertical').pack(side='left', fill='y', padx=6)
        ttk.Label(ctrl, text='Pattern:').pack(side='left')
        self._pattern_var = tk.StringVar(value='0xFFFFFFFF')
        pat_cb = ttk.Combobox(ctrl, textvariable=self._pattern_var, width=12, state='readonly',
                              values=['0xFFFFFFFF', '0x00000000', '0x55555555', '0xAAAAAAAA'])
        pat_cb.pack(side='left', padx=(2, 0))
        ttk.Button(ctrl, text='Send', command=self._send_pattern).pack(side='left', padx=(2, 14))

        # Refresh selector
        ttk.Separator(ctrl, orient='vertical').pack(side='left', fill='y', padx=6)
        ttk.Label(ctrl, text='Refresh:').pack(side='left')
        self._refresh_var = tk.StringVar(value='OFF')
        ref_cb = ttk.Combobox(ctrl, textvariable=self._refresh_var, width=5, state='readonly',
                              values=['OFF', 'SLOW', 'NORM', 'FAST'])
        ref_cb.pack(side='left', padx=(2, 0))
        ttk.Button(ctrl, text='Send', command=self._send_refresh).pack(side='left', padx=(2, 14))

        # Alert threshold
        ttk.Label(ctrl, text='Alert if flips >').pack(side='left')
        self._alert_var = tk.StringVar()
        alert_e = ttk.Entry(ctrl, textvariable=self._alert_var, width=8)
        alert_e.pack(side='left', padx=(2, 0))
        alert_e.bind('<Return>', lambda _: self._set_alert())
        ttk.Button(ctrl, text='Set', command=self._set_alert).pack(side='left', padx=(2, 14))

        # Plot window
        ttk.Label(ctrl, text='Plot last').pack(side='left')
        self._win_var = tk.StringVar(value='200')
        win_e = ttk.Entry(ctrl, textvariable=self._win_var, width=5)
        win_e.pack(side='left', padx=(2, 0))
        win_e.bind('<Return>', lambda _: self._set_window())
        ttk.Label(ctrl, text='points').pack(side='left', padx=(2, 2))
        ttk.Button(ctrl, text='Set', command=self._set_window).pack(side='left')

        # ── Row 5: note entry ──────────────────────────────────────────────
        nf = ttk.LabelFrame(self.root, text='Annotation / Note  (logged to JSONL with timestamp)', padding=4)
        nf.grid(row=5, column=0, sticky='ew', padx=6, pady=(0, 2))
        nf.columnconfigure(0, weight=1)

        self._note_var = tk.StringVar()
        note_e = ttk.Entry(nf, textvariable=self._note_var)
        note_e.grid(row=0, column=0, sticky='ew', padx=(0, 4))
        note_e.bind('<Return>', lambda _: self._add_note())
        ttk.Button(nf, text='Add Note', command=self._add_note).grid(row=0, column=1)

        # ── Row 6: log ─────────────────────────────────────────────────────
        lf = ttk.LabelFrame(self.root, text='Log', padding=2)
        lf.grid(row=6, column=0, sticky='nsew', padx=6, pady=(0, 6))
        lf.columnconfigure(0, weight=1)
        lf.rowconfigure(0, weight=1)
        self.root.rowconfigure(6, weight=0)

        self._log = tk.Text(lf, height=8, state='disabled',
                            font=('Courier', 9), bg='#1e1e1e', fg='#d4d4d4',
                            wrap='none', relief='flat')
        sb = ttk.Scrollbar(lf, command=self._log.yview)
        self._log.configure(yscrollcommand=sb.set)
        self._log.grid(row=0, column=0, sticky='nsew')
        sb.grid(row=0, column=1, sticky='ns')

        # Log tag colours (VS Code dark theme inspired)
        self._log.tag_configure('flip',     foreground='#4EC9B0')
        self._log.tag_configure('note',     foreground='#DCDCAA')
        self._log.tag_configure('refresh',  foreground='#C586C0')
        self._log.tag_configure('interval', foreground='#9CDCFE')
        self._log.tag_configure('status',   foreground='#808080', font=('Courier', 9, 'italic'))
        self._log.tag_configure('alert',    foreground='#F44747', font=('Courier', 9, 'bold'))

        self._refresh_ports()

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    def _refresh_ports(self):
        if not SERIAL_AVAILABLE:
            return
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self._port_cb['values'] = ports
        arty = find_arty_port()
        if arty:
            self._port_var.set(arty)
        elif ports and self._port_var.get() not in ports:
            self._port_var.set(ports[0])

    def _browse_dir(self):
        d = filedialog.askdirectory(initialdir=self._outdir_var.get() or '.')
        if d:
            self._outdir_var.set(d)

    def _log_append(self, text, tag='status'):
        w = self._log
        w.config(state='normal')
        for line in str(text).splitlines():
            w.insert('end', line + '\n', tag)
        # Keep last 300 lines
        lines = int(w.index('end-1c').split('.')[0])
        if lines > 300:
            w.delete('1.0', f'{lines - 300}.0')
        w.see('end')
        w.config(state='disabled')

    def _draw_empty_plot(self):
        self._ax.clear()
        self._ax_temp.clear()
        self._ax_temp.set_visible(False)
        self._ax.set_xlabel('Time (s)')
        self._ax.set_ylabel('Bit Flips')
        self._ax.set_title('No data')
        self._canvas.draw_idle()

    def _draw_empty_denoised(self):
        self._ax2.clear()
        self._ax2.set_xlabel('Iteration')
        self._ax2.set_ylabel('Rare flips')
        self._ax2.set_title('De-noised signal — waiting for background model')
        self._canvas2.draw_idle()

    def _draw_empty_raster(self):
        self._ax3.clear()
        self._ax3.set_xlabel('Address rank (compressed)')
        self._ax3.set_ylabel('Iteration')
        self._ax3.set_title('Address raster — waiting for data')
        self._canvas3.draw_idle()

    # -----------------------------------------------------------------------
    # Connection
    # -----------------------------------------------------------------------

    def _connect(self):
        if not SERIAL_AVAILABLE:
            messagebox.showerror('Missing dependency',
                                 'pyserial is not installed.\nRun: pip install pyserial')
            return
        self._board_ready = False
        self._running     = False
        self._stop  = threading.Event()
        self._q     = queue.Queue()
        self._reader = SerialReader(self._port_var.get(), int(self._baud_var.get()),
                                    self._q, self._stop)
        self._reader.start()
        self._connected = True
        self._conn_btn.config( state='disabled')
        self._disc_btn.config( state='normal')
        self._start_btn.config(state='disabled')
        self._reset_btn.config(state='normal')
        self._log_append(f'Connected to {self._port_var.get()} — waiting for board READY…', 'status')

    def _start(self):
        if not self._board_ready or not self._reader:
            return
        name = self._name_var.get().strip().replace(' ', '_') or 'unnamed'
        desc = self._desc_var.get().strip()
        self._start_unix = time.time()
        self._store = DataStore(
            output_dir=self._outdir_var.get() or 'data',
            name=name, description=desc,
            start_time_iso=datetime.now(tz=timezone.utc).isoformat())
        self._ref_events.clear()
        self._pat_events.clear()
        self._rare_records.clear()
        self._raster_records.clear()
        self._temp_records.clear()
        self._bg   = BackgroundModel()
        self._hang = HangDetector()

        # Send initial conditions before Go so first cycle uses GUI values
        hold_val = self._hold_var.get().strip()
        if hold_val.isdigit() and 1 <= int(hold_val) <= 9999:
            self._reader.write(f'H{hold_val}\n'.encode('ascii'))
        pat_val = self._pattern_var.get()
        pat_idx = {'0xFFFFFFFF': '0', '0x00000000': '1',
                   '0x55555555': '2', '0xAAAAAAAA': '3'}.get(pat_val, '0')
        self._reader.write(f'P{pat_idx}\n'.encode('ascii'))
        ref_idx = REFRESH_TO_CMD.get(self._refresh_var.get(), '0')
        self._reader.write(f'R{ref_idx}\n'.encode('ascii'))
        self._reader.write(b'G')

        self._running = True
        self._start_btn.config(state='disabled')
        self._reset_btn.config(state='normal')
        self._log_append(f'── Session started: {name}  {desc}', 'status')
        self._log_append(f'   CSV   → {self._store.csv_path}', 'status')
        self._log_append(f'   JSONL → {self._store.jsonl_path}', 'status')

    def _reset_board(self):
        """Send X to abort the current cycle and return board to WAIT_GO."""
        if self._reader:
            self._reader.write(b'X')
        if self._store:
            self._store.close()
            self._log_append('── Session paused — board returning to WAIT_GO', 'status')
            self._log_append(self._store.summary(), 'status')
            self._store = None
        self._running     = False
        self._board_ready = False
        self._start_btn.config(state='disabled')
        self._reset_btn.config(state='normal' if self._connected else 'disabled')
        self._log_append('Waiting for READY…', 'status')

    def _open_sweep(self):
        if self._sweep_win is None or not self._sweep_win.winfo_exists():
            self._sweep_win = SweepWindow(self.root, self)
        else:
            self._sweep_win.lift()

    def _disconnect(self):
        self._connected   = False
        self._board_ready = False
        self._running     = False
        if self._reader:
            self._reader.close()
            self._reader = None
        if self._store:
            summary = self._store.summary()
            self._store.close()
            self._store = None
            self._log_append('── Session ended', 'status')
            self._log_append(summary, 'status')
        self._conn_btn.config( state='normal')
        self._disc_btn.config( state='disabled')
        self._start_btn.config(state='disabled')
        self._reset_btn.config(state='disabled')

    # -----------------------------------------------------------------------
    # Event loops (always scheduled; no-op when idle)
    # -----------------------------------------------------------------------

    def _poll(self):
        try:
            if self._connected:
                while not self._q.empty():
                    kind, payload = self._q.get_nowait()
                    if kind == 'STATUS':
                        self._log_append(payload, 'status')
                    elif kind == 'DATA':
                        ts_unix, raw = payload
                        try:
                            line = raw.decode('ascii', errors='replace').strip()
                        except Exception:
                            continue
                        # Address body lines are collected before normal parsing
                        if self._addr_remaining > 0:
                            m = ADDR_LINE_RE.match(line)
                            if m:
                                self._addr_buf.append(int(m.group(1), 16))
                                self._addr_remaining -= 1
                                continue
                            else:
                                # Unexpected line mid-stream — fall through to parse
                                self._addr_remaining = 0
                        record = parse_line(raw, ts_unix)
                        if record:
                            self._handle_record(record)

                if self._hang.is_hung():
                    self._slabels['hang'].config(
                        text=f'⚠ No FLIP in {self._hang.seconds_since()} s')
                else:
                    self._slabels['hang'].config(text='')
        except Exception as e:
            self._log_append(f'Poll error: {e}', 'alert')
        finally:
            self.root.after(self.POLL_MS, self._poll)

    def _handle_record(self, record):
        if record['type'] == 'READY':
            self._board_ready = True
            self._start_btn.config(state='normal')
            self._reset_btn.config(state='normal' if self._connected else 'disabled')
            self._log_append('Board READY - configure settings and click Start', 'status')
            return

        if record['type'] == 'BOOT':
            self._log_append('Board BOOT banner received - waiting for READY', 'status')
            return

        elif record['type'] == 'ADDRS_HDR':
            self._addr_remaining = record['count']
            self._addr_buf       = []
            self._addr_overflow  = record.get('addr_overflow', False)
            return

        elif record['type'] == 'REFRESH':
            label = REFRESH_LABEL.get(record['refresh_rate'], record['refresh_rate'])
            self._ref_events.append((record['ts_unix'], label))
            self._log_append(f"Refresh rate → {record['refresh_rate']}", 'refresh')

        elif record['type'] == 'PATTERN':
            label = PATTERN_LABEL.get(record['pattern'], record['pattern'])
            self._pat_events.append((record['ts_unix'], label))
            self._log_append(f"Pattern → {label}", 'interval')

        elif record['type'] == 'TEMP':
            self._slabels['temp'].config(text=f"Temp: {record['temp_c']} °C")
            self._temp_records.append((record['ts_unix'], record['temp_c']))

        elif record['type'] == 'INTERVAL':
            self._log_append(f"Hold interval → {record['hold_s']} s", 'interval')
            self._hang.update_hold(record['hold_s'])

        elif record['type'] == 'DIAG':
            bad = record.get('first_bad_addr')
            bad_s = 'none' if bad is None else f'0x{bad:07X}'
            awb = ""
            if record.get('aw_count') is not None:
                awb = (
                    f" AW={record['aw_count']:,} W={record['w_count']:,} "
                    f"B={record['b_count']:,}"
                )
            self._log_append(
                f"[DIAG] F1={record['fill1_count']:,} F2={record['fill2_count']:,} "
                f"SC={record['scan_count']:,} BERR={record['bresp_errors']:,} "
                f"RERR={record['rresp_errors']:,}{awb} BAD={bad_s} "
                f"OVF={int(record.get('addr_overflow', False))}", 'status')

        elif record['type'] == 'VDIAG':
            bad = record.get('verify_bad_addr')
            bad_s = 'none' if bad is None else f'0x{bad:07X}'
            self._log_append(
                f"[VDIAG] VC={record['verify_count']:,} VBAD={bad_s}", 'status')

        elif record['type'] == 'FLIP':
            self._hang.reset(record['hold_s'])
            record['addrs'] = list(self._addr_buf)
            record['addr_overflow'] = self._addr_overflow
            self._addr_buf       = []
            self._addr_remaining = 0
            self._addr_overflow  = False
            addrs = record['addrs']
            self._bg.update(addrs)
            hot, rare = self._bg.classify(addrs)
            clusters  = self._bg.find_clusters(rare)
            iteration = self._store.iteration + 1 if self._store else 0
            if self._sweep_win and self._sweep_win._running:
                self._sweep_win.on_flip(record)
            self._rare_records.append((iteration, len(rare), clusters))
            self._raster_records.append((iteration, hot, rare))
            # Update BG status bar
            if self._bg.ready:
                self._slabels['bg'].config(
                    text=f'BG: ready  Hot: {self._bg.n_hot:,}')
            else:
                self._slabels['bg'].config(
                    text=f'BG: building ({self._bg.n_cycles}/{self._bg.min_cycles})')
            # Log cluster events
            for cl in clusters:
                span = cl['end'] - cl['start']
                self._log_append(
                    f"  [CLUSTER] iter={iteration}  rare={len(rare)}"
                    f"  cluster: {cl['count']} addrs"
                    f"  span=0x{span:05X}"
                    f"  (0x{cl['start']:07X}–0x{cl['end']:07X})", 'note')

        if self._store:
            self._store.ingest(record)

        if record['type'] == 'FLIP' and self._store:
            fc = record['flip_count']
            elapsed = int(time.time() - self._start_unix)
            self._slabels['iter'].config(    text=f"Iter: {self._store.iteration}")
            self._slabels['flips'].config(   text=f"Flips: {fc:,}")
            self._slabels['hold'].config(    text=f"Hold: {record['hold_s']} s")
            self._slabels['refresh'].config( text=f"Refresh: {self._store.refresh_rate}")
            self._slabels['elapsed'].config( text=f"Elapsed: {elapsed} s")

            is_alert = self._alert is not None and fc > self._alert
            tag = 'alert' if is_alert else 'flip'
            n_addrs = len(record.get('addrs', []))
            ovf_str = "  ADDR_OVF" if record.get('addr_overflow') else ""
            temp_str = f"  temp={self._store.temp_c}°C" if self._store.temp_c is not None else ""
            self._log_append(
                f"[{record['timestamp'][11:19]}] #{self._store.iteration:>4}  "
                f"flips={fc:>10,}  addrs={n_addrs:>5}  hold={record['hold_s']}s  "
                f"refresh={self._store.refresh_rate}{temp_str}{ovf_str}", tag)
            if fc != n_addrs:
                self._log_append(
                    f"  address count mismatch: flip_count={fc:,}, captured={n_addrs:,}",
                    'alert' if record.get('addr_overflow') else 'status')
            if is_alert:
                self._log_append(f'  ⚠ {fc:,} exceeds alert threshold {self._alert:,}', 'alert')

    def _update_plot(self):
        try:
            if self._store and self._store.records:
                self._redraw()
            if self._rare_records:
                self._redraw_denoised()
            if self._raster_records:
                self._redraw_raster()
        except Exception:
            pass
        finally:
            self.root.after(self.PLOT_MS, self._update_plot)

    def _redraw(self):
        records = self._store.records[-self._window:]
        start   = self._start_unix or records[0]['ts_unix']
        xs = [r['ts_unix'] - start for r in records]
        ys = [r['flip_count']      for r in records]
        hs = [r['hold_s']          for r in records]

        ax = self._ax
        ax.clear()
        ax_t = self._ax_temp
        ax_t.clear()
        ax_t.set_visible(False)

        for hold_s, color in HOLD_COLORS.items():
            mx = [x for x, h in zip(xs, hs) if h == hold_s]
            my = [y for y, h in zip(ys, hs) if h == hold_s]
            if mx:
                ax.scatter(mx, my, color=color, s=18, zorder=3, label=f'{hold_s} s hold')
        ax.plot(xs, ys, color='#888', linewidth=0.8, zorder=2)

        if self._alert is not None:
            ax.axhline(self._alert, color='#F44747', linestyle='--',
                       linewidth=1, label=f'Alert: {self._alert:,}')

        # Refresh-rate change markers
        x_min = xs[0] if xs else 0
        ymax  = ax.get_ylim()[1] or 1
        for ts_u, label in self._ref_events:
            rx = ts_u - start
            if rx >= x_min:
                ax.axvline(rx, color='#C586C0', linestyle=':', linewidth=1.2, alpha=0.7)
                ax.text(rx, ymax * 0.95, label, fontsize=7, color='#C586C0',
                        rotation=90, va='top')

        # Pattern-change markers (green)
        for ts_u, label in self._pat_events:
            px = ts_u - start
            if px >= x_min:
                ax.axvline(px, color='#4EC9B0', linestyle='-.', linewidth=1.2, alpha=0.8)
                ax.text(px, ymax * 0.75, label, fontsize=7, color='#4EC9B0',
                        rotation=90, va='top')

        # Note markers
        for note in self._store.notes:
            nx = note['ts_unix'] - start
            if nx >= x_min:
                ax.axvline(nx, color='#DCDCAA', linestyle='--', linewidth=1.0, alpha=0.8)
                ax.text(nx, ymax * 0.5, note['text'][:24],
                        fontsize=7, color='#DCDCAA', rotation=90, va='center')

        # Stats box
        if ys:
            mean = sum(ys) / len(ys)
            std  = (sum((y - mean) ** 2 for y in ys) / len(ys)) ** 0.5
            ax.text(0.99, 0.97,
                    f'n={len(ys)}\nmean={mean:.0f}\nstd={std:.0f}\nmin={min(ys)}\nmax={max(ys)}',
                    transform=ax.transAxes, fontsize=8, va='top', ha='right',
                    bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

        # Temperature overlay (secondary right axis)
        if self._temp_records and self._start_unix:
            t_start = records[0]['ts_unix']
            tx = [t - start for t, _ in self._temp_records if t >= t_start]
            ty = [c for t, c in self._temp_records if t >= t_start]
            if tx:
                ax_t.set_visible(True)
                ax_t.plot(tx, ty, color='#FF9800', linewidth=1.0,
                          linestyle='--', alpha=0.75, label='Temp °C')
                ax_t.set_ylabel('°C', color='#FF9800', fontsize=8)
                ax_t.tick_params(axis='y', labelcolor='#FF9800', labelsize=7)
                y_range = max(ty) - min(ty) if len(ty) > 1 else 1
                ax_t.set_ylim(min(ty) - y_range * 0.5, max(ty) + y_range * 2)

        ax.set_xlabel('Time (s)')
        ax.set_ylabel('Bit Flips')
        ax.set_title(
            f'{self._store.name}  |  Iter: {self._store.iteration}'
            f'  |  Refresh: {self._store.refresh_rate}')
        handles, labels = ax.get_legend_handles_labels()
        if handles:
            ax.legend(handles, labels, loc='upper left', fontsize=8)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self._fig.tight_layout()
        self._canvas.draw_idle()

    def _redraw_denoised(self):
        records = self._rare_records[-self._window:]
        xs = [r[0] for r in records]
        ys = [r[1] for r in records]

        ax = self._ax2
        ax.clear()

        ax.plot(xs, ys, color='#888', linewidth=0.8, zorder=2)
        ax.scatter(xs, ys, color='#2196F3', s=18, zorder=3)

        # Mark cluster events with red vertical lines
        for it, rare_count, clusters in records:
            if clusters:
                ax.axvline(it, color='#F44747', linestyle='--', linewidth=1.2, alpha=0.8)
                label = f'{len(clusters)} cluster{"s" if len(clusters) > 1 else ""}'
                ax.text(it, ax.get_ylim()[1] * 0.95 if ax.get_ylim()[1] else 1,
                        label, fontsize=7, color='#F44747', rotation=90, va='top')

        # Background status annotation
        if self._bg.ready:
            bg_text = f'Background: {self._bg.n_hot:,} hot pixels  |  Cycles: {self._bg.n_cycles}'
        else:
            bg_text = f'Building background… ({self._bg.n_cycles}/{self._bg.min_cycles} cycles)'
        ax.text(0.01, 0.97, bg_text, transform=ax.transAxes,
                fontsize=8, va='top', color='#9CDCFE',
                bbox=dict(boxstyle='round', facecolor='#1e1e1e', alpha=0.6))

        ax.set_xlabel('Iteration')
        ax.set_ylabel('Rare flips')
        ax.set_title('De-noised signal (thermal hot pixels removed)')
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self._fig2.tight_layout()
        self._canvas2.draw_idle()

    def _redraw_raster(self):
        # Build a compressed address axis: only addresses seen across all cycles get a rank.
        # Hot pixels → red, rare events → blue, so thermal stripes and anomalies are distinct.
        records = self._raster_records[-self._window:]

        # Collect all seen addresses and assign a rank
        all_addrs = sorted({a for _, hot, rare in records for a in hot + rare})
        if not all_addrs:
            return
        rank = {a: i for i, a in enumerate(all_addrs)}

        hot_x, hot_y, rare_x, rare_y = [], [], [], []
        for it, hot, rare in records:
            for a in hot:
                hot_x.append(rank[a])
                hot_y.append(it)
            for a in rare:
                rare_x.append(rank[a])
                rare_y.append(it)

        ax = self._ax3
        ax.clear()

        if hot_x:
            ax.scatter(hot_x, hot_y, c='#FF6B6B', s=3, alpha=0.7,
                       linewidths=0, label='Hot pixel', zorder=2)
        if rare_x:
            ax.scatter(rare_x, rare_y, c='#00D4FF', s=8, alpha=1.0,
                       linewidths=0, label='Rare event', zorder=3)

        ax.set_xlabel(f'Address rank (compressed — {len(all_addrs):,} unique addresses)')
        ax.set_ylabel('Iteration')
        ax.set_title('Address raster  —  red=thermal, blue=rare event')
        if hot_x or rare_x:
            ax.legend(loc='upper right', fontsize=8, markerscale=4)
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self._fig3.tight_layout()
        self._canvas3.draw_idle()

    # -----------------------------------------------------------------------
    # Controls
    # -----------------------------------------------------------------------

    def _send_hold(self):
        val = self._hold_var.get().strip()
        if not val.isdigit() or not (1 <= int(val) <= 9999):
            messagebox.showwarning('Hold time', 'Enter an integer between 1 and 9999')
            return
        if self._reader:
            cmd = f'H{val}\n'.encode('ascii')
            if self._reader.write(cmd):
                self._log_append(f'→ Sent hold = {val} s to board', 'interval')
            else:
                self._log_append('⚠ Not connected — command not sent', 'alert')
        else:
            self._log_append('⚠ Not connected', 'alert')
        self._hold_var.set('')

    def _send_pattern(self):
        val = self._pattern_var.get()
        idx = {'0xFFFFFFFF': '0', '0x00000000': '1',
               '0x55555555': '2', '0xAAAAAAAA': '3'}.get(val)
        if idx is None:
            return
        if self._reader:
            cmd = f'P{idx}\n'.encode('ascii')
            if self._reader.write(cmd):
                self._log_append(f'→ Sent pattern = {val} to board', 'interval')
            else:
                self._log_append('⚠ Not connected — command not sent', 'alert')
        else:
            self._log_append('⚠ Not connected', 'alert')

    def _send_refresh(self):
        val = self._refresh_var.get()
        idx = REFRESH_TO_CMD.get(val)
        if idx is None:
            return
        if self._reader:
            cmd = f'R{idx}\n'.encode('ascii')
            if self._reader.write(cmd):
                self._log_append(f'Sent refresh = {val} to board', 'refresh')
            else:
                self._log_append('Not connected - command not sent', 'alert')
        else:
            self._log_append('Not connected', 'alert')

    def _set_alert(self):
        val = self._alert_var.get().strip()
        if not val:
            self._alert = None
            self._log_append('Alert threshold cleared', 'status')
        elif val.isdigit():
            self._alert = int(val)
            self._log_append(f'Alert threshold → {self._alert:,} flips', 'status')
        else:
            messagebox.showwarning('Alert', 'Enter an integer, or leave blank to clear')

    def _set_window(self):
        val = self._win_var.get().strip()
        if val.isdigit() and int(val) > 0:
            self._window = int(val)

    def _add_note(self):
        text = self._note_var.get().strip()
        if not text:
            return
        if self._store:
            self._store.add_note(text)
            self._log_append(f'[NOTE] {text}', 'note')
        else:
            self._log_append(f'[NOTE] {text}  (not saved — no active session)', 'note')
        self._note_var.set('')

    # -----------------------------------------------------------------------
    # Replay
    # -----------------------------------------------------------------------

    def _start_replay(self, path):
        path = Path(path)
        if not path.exists():
            messagebox.showerror('Replay', f'File not found:\n{path}')
            return
        self._name_var.set(path.stem)
        self._desc_var.set('replay')
        self._start_unix = None
        self._store = DataStore(
            output_dir=str(path.parent),
            name=path.stem + '_replay',
            description='replay',
            start_time_iso=datetime.now(tz=timezone.utc).isoformat())
        self._ref_events.clear()
        self._pat_events.clear()
        self._rare_records.clear()
        self._raster_records.clear()
        self._temp_records.clear()
        self._bg = BackgroundModel()
        self._log_append(f'Replaying {path}', 'status')

        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if self._start_unix is None:
                        self._start_unix = record.get('ts_unix', time.time())

                    if record.get('type') == 'NOTE':
                        self._store.notes.append(record)
                        self._log_append(f'[NOTE] {record["text"]}', 'note')
                    elif record.get('type') == 'REFRESH':
                        label = REFRESH_LABEL.get(record.get('refresh_rate', ''), '')
                        self._ref_events.append((record['ts_unix'], label))
                        self._store.ingest(record)
                    elif record.get('type') == 'PATTERN':
                        label = PATTERN_LABEL.get(record.get('pattern', ''), '')
                        self._pat_events.append((record['ts_unix'], label))
                        self._store.ingest(record)
                    elif record.get('type') == 'TEMP':
                        self._temp_records.append((record['ts_unix'], record.get('temp_c')))
                        self._store.ingest(record)
                    elif record.get('type') == 'FLIP':
                        addrs = record.get('addrs', [])
                        self._bg.update(addrs)
                        hot, rare = self._bg.classify(addrs)
                        clusters = self._bg.find_clusters(rare)
                        iteration = self._store.iteration + 1
                        self._rare_records.append((iteration, len(rare), clusters))
                        self._raster_records.append((iteration, hot, rare))
                        self._store.ingest(record)
                    else:
                        self._store.ingest(record)

        except Exception as e:
            self._log_append(f'Replay error: {e}', 'alert')
            return

        self._log_append(f'Replay complete.\n{self._store.summary()}', 'status')
        self._redraw()
        if self._rare_records:
            self._redraw_denoised()
        if self._raster_records:
            self._redraw_raster()
        self._conn_btn.config(state='disabled')

    # -----------------------------------------------------------------------
    # Close
    # -----------------------------------------------------------------------

    def _on_close(self):
        self._disconnect()
        self.root.destroy()

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(description='DRAM Dosimeter GUI Logger')
    p.add_argument('--replay', metavar='FILE',
                   help='Replay a .jsonl file (no hardware needed)')
    args = p.parse_args()

    root = tk.Tk()
    DosimeterApp(root, replay_file=args.replay)
    root.mainloop()

if __name__ == '__main__':
    main()
