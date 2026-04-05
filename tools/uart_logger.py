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

FLIP_RE    = re.compile(r'HOLD:(\d+)s PAT:([0-9A-Fa-f]{2}) FLIPS:([0-9A-Fa-f]{8})')
REFRESH_RE = re.compile(r'REFRESH:(OFF|SLOW|NORM|FAST)')
INTV_RE    = re.compile(r'INTERVAL:(\d+)s')
PATTERN_RE = re.compile(r'PATTERN:(FF|00|55|AA)')
READY_RE   = re.compile(r'^READY$')

HOLD_COLORS = {5: '#4CAF50', 10: '#2196F3', 20: '#FF9800', 30: '#F44736'}
REFRESH_LABEL = {'OFF': 'Refresh OFF', 'SLOW': 'Slow (~100ms)',
                 'NORM': 'Normal (~7.8µs)', 'FAST': 'Fast (~3.9µs)'}
PATTERN_LABEL = {'FF': '0xFFFFFFFF', '00': '0x00000000',
                 '55': '0x55555555', 'AA': '0xAAAAAAAA'}

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
    return None

# ---------------------------------------------------------------------------
# Data store
# ---------------------------------------------------------------------------

class DataStore:
    CSV_FIELDS = ['timestamp', 'iteration', 'hold_s', 'refresh_rate', 'pattern', 'flip_count', 'experiment']

    def __init__(self, output_dir, name, description, start_time_iso):
        self.name = name
        self.description = description
        self.records = []       # FLIP rows (include ts_unix for plotting)
        self.notes   = []       # NOTE records
        self.refresh_rate = 'OFF'
        self.pattern      = 'FF'
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
        self._connected   = False
        self._board_ready = False  # True after READY received from board
        self._running     = False  # True after Start clicked and G sent

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
        self._baud_var = tk.StringVar(value='921600')
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

        # ── Row 2: live plot ───────────────────────────────────────────────
        pf = ttk.Frame(self.root)
        pf.grid(row=2, column=0, sticky='nsew', padx=6, pady=4)
        pf.columnconfigure(0, weight=1)
        pf.rowconfigure(0, weight=1)

        self._fig = Figure(figsize=(10, 4), tight_layout=True)
        self._ax  = self._fig.add_subplot(111)
        self._canvas = FigureCanvasTkAgg(self._fig, master=pf)
        self._canvas.get_tk_widget().grid(row=0, column=0, sticky='nsew')
        self._draw_empty_plot()

        # ── Row 3: status bar ──────────────────────────────────────────────
        sf = ttk.Frame(self.root, relief='sunken', borderwidth=1)
        sf.grid(row=3, column=0, sticky='ew', padx=6)

        self._slabels = {}
        for key, text in [('iter', 'Iter: —'), ('flips', 'Flips: —'),
                          ('hold', 'Hold: —'), ('refresh', 'Refresh: —'),
                          ('elapsed', 'Elapsed: —'), ('hang', '')]:
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
        self._ax.set_xlabel('Time (s)')
        self._ax.set_ylabel('Bit Flips')
        self._ax.set_title('No data')
        self._canvas.draw_idle()

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
        self._reset_btn.config(state='disabled')
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
        self._hang = HangDetector()

        # Send initial conditions before Go so first cycle uses GUI values
        hold_val = self._hold_var.get().strip()
        if hold_val.isdigit() and 1 <= int(hold_val) <= 9999:
            self._reader.write(f'H{hold_val}\n'.encode('ascii'))
        pat_val = self._pattern_var.get()
        pat_idx = {'0xFFFFFFFF': '0', '0x00000000': '1',
                   '0x55555555': '2', '0xAAAAAAAA': '3'}.get(pat_val, '0')
        self._reader.write(f'P{pat_idx}\n'.encode('ascii'))
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
        self._reset_btn.config(state='disabled')
        self._log_append('Waiting for READY…', 'status')

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
            self._log_append('── Board READY — configure settings and click ▶ Start', 'status')
            return

        elif record['type'] == 'REFRESH':
            label = REFRESH_LABEL.get(record['refresh_rate'], record['refresh_rate'])
            self._ref_events.append((record['ts_unix'], label))
            self._log_append(f"Refresh rate → {record['refresh_rate']}", 'refresh')

        elif record['type'] == 'PATTERN':
            label = PATTERN_LABEL.get(record['pattern'], record['pattern'])
            self._pat_events.append((record['ts_unix'], label))
            self._log_append(f"Pattern → {label}", 'interval')

        elif record['type'] == 'INTERVAL':
            self._log_append(f"Hold interval → {record['hold_s']} s", 'interval')
            self._hang.update_hold(record['hold_s'])

        elif record['type'] == 'FLIP':
            self._hang.reset(record['hold_s'])

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
            self._log_append(
                f"[{record['timestamp'][11:19]}] #{self._store.iteration:>4}  "
                f"flips={fc:>10,}  hold={record['hold_s']}s  "
                f"refresh={self._store.refresh_rate}", tag)
            if is_alert:
                self._log_append(f'  ⚠ {fc:,} exceeds alert threshold {self._alert:,}', 'alert')

    def _update_plot(self):
        try:
            if self._store and self._store.records:
                self._redraw()
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
                    else:
                        self._store.ingest(record)

        except Exception as e:
            self._log_append(f'Replay error: {e}', 'alert')
            return

        self._log_append(f'Replay complete.\n{self._store.summary()}', 'status')
        self._redraw()
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
