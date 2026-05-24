"""
Automated UART diagnostics for the DRAM dosimeter.

Live mode programs a sequence of hold/pattern/refresh settings, records the
board stream, and classifies each cycle from DIAG plus FLIP/ADDRS data.

Replay mode classifies an existing JSONL capture without touching hardware:
    python tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
"""

import argparse
import csv
import json
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False


BAUD = 921600
EXPECTED_WORDS = 0x01000000
CYCLE_TIMEOUT_S = 120.0
DIAG_AFTER_FLIP_TIMEOUT_S = 12.0

PATTERN_TO_CMD = {"FF": "0", "00": "1", "55": "2", "AA": "3"}
PATTERN_WORD = {
    "FF": 0xFFFFFFFF,
    "00": 0x00000000,
    "55": 0x55555555,
    "AA": 0xAAAAAAAA,
}
REFRESH_TO_CMD = {"OFF": "0", "SLOW": "1", "NORM": "2", "FAST": "3"}

FLIP_RE = re.compile(r"HOLD:(\d+)s PAT:([0-9A-Fa-f]{2}) FLIPS:([0-9A-Fa-f]{8})")
TEMP_RE = re.compile(r"TEMP:([0-9A-Fa-f]{3})")
REFRESH_RE = re.compile(r"REFRESH:(OFF|SLOW|NORM|FAST)")
INTV_RE = re.compile(r"INTERVAL:(\d+)s")
PATTERN_RE = re.compile(r"PATTERN:(FF|00|55|AA)")
READY_RE = re.compile(r"^READY$")
ADDRS_HDR_RE = re.compile(r"^ADDRS:([0-9A-Fa-f]{4})(?:\s+OVF:([01]))?$")
ADDR_LINE_RE = re.compile(r"^([0-9A-Fa-f]{7})$")
DIAG_RE = re.compile(
    r"DIAG:F1:([0-9A-Fa-f]{8}) F2:([0-9A-Fa-f]{8}) SC:([0-9A-Fa-f]{8}) "
    r"BERR:([0-9A-Fa-f]{8}) RERR:([0-9A-Fa-f]{8}) BAD:([0-9A-Fa-fX]{7}) "
    r"GOT:([0-9A-Fa-fX]{8}) EXP:([0-9A-Fa-fX]{8}) OVF:([01])"
)


def utc_now():
    return datetime.now(timezone.utc)


def iso_from_ts(ts_unix):
    return datetime.fromtimestamp(ts_unix, tz=timezone.utc).isoformat()


def parse_line(line, ts_unix=None):
    if isinstance(line, bytes):
        line = line.decode("ascii", errors="replace")
    line = str(line).strip()
    if not line:
        return None
    if ts_unix is None:
        ts_unix = time.time()
    ts = iso_from_ts(ts_unix)

    m = FLIP_RE.search(line)
    if m:
        return {
            "type": "FLIP",
            "timestamp": ts,
            "ts_unix": ts_unix,
            "hold_s": int(m.group(1)),
            "pattern": m.group(2).upper(),
            "flip_count": int(m.group(3), 16),
            "raw": line,
        }
    m = TEMP_RE.search(line)
    if m:
        raw_code = int(m.group(1), 16)
        temp_c = raw_code * 503.975 / 4096 - 273.15
        return {
            "type": "TEMP",
            "timestamp": ts,
            "ts_unix": ts_unix,
            "raw_code": raw_code,
            "temp_c": round(temp_c, 1),
            "raw": line,
        }
    m = REFRESH_RE.search(line)
    if m:
        return {"type": "REFRESH", "timestamp": ts, "ts_unix": ts_unix,
                "refresh_rate": m.group(1), "raw": line}
    m = INTV_RE.search(line)
    if m:
        return {"type": "INTERVAL", "timestamp": ts, "ts_unix": ts_unix,
                "hold_s": int(m.group(1)), "raw": line}
    m = PATTERN_RE.search(line)
    if m:
        return {"type": "PATTERN", "timestamp": ts, "ts_unix": ts_unix,
                "pattern": m.group(1).upper(), "raw": line}
    if READY_RE.search(line):
        return {"type": "READY", "timestamp": ts, "ts_unix": ts_unix, "raw": line}
    m = ADDRS_HDR_RE.match(line)
    if m:
        return {
            "type": "ADDRS_HDR",
            "timestamp": ts,
            "ts_unix": ts_unix,
            "count": int(m.group(1), 16),
            "addr_overflow": m.group(2) == "1",
            "raw": line,
        }
    m = DIAG_RE.search(line)
    if m:
        def hex_or_none(value):
            return None if "X" in value.upper() else int(value, 16)
        return {
            "type": "DIAG",
            "timestamp": ts,
            "ts_unix": ts_unix,
            "fill1_count": int(m.group(1), 16),
            "fill2_count": int(m.group(2), 16),
            "scan_count": int(m.group(3), 16),
            "bresp_errors": int(m.group(4), 16),
            "rresp_errors": int(m.group(5), 16),
            "first_bad_addr": hex_or_none(m.group(6)),
            "first_bad_got": hex_or_none(m.group(7)),
            "first_bad_exp": hex_or_none(m.group(8)),
            "addr_overflow": m.group(9) == "1",
            "raw": line,
        }
    m = ADDR_LINE_RE.match(line)
    if m:
        return {"type": "ADDR", "timestamp": ts, "ts_unix": ts_unix,
                "addr": int(m.group(1), 16), "raw": line}
    return {"type": "RAW", "timestamp": ts, "ts_unix": ts_unix, "raw": line}


@dataclass
class Cycle:
    index: int
    requested_pattern: str = ""
    requested_refresh: str = ""
    requested_hold_s: int = 0
    flip: dict | None = None
    diag: dict | None = None
    temp: dict | None = None
    addr_header: dict | None = None
    addrs: list[int] = field(default_factory=list)
    records: list[dict] = field(default_factory=list)

    def pattern(self):
        if self.flip:
            return self.flip.get("pattern")
        return self.requested_pattern

    def flip_count(self):
        return 0 if not self.flip else self.flip.get("flip_count", 0)

    def addr_overflow(self):
        return bool(
            (self.addr_header and self.addr_header.get("addr_overflow"))
            or (self.flip and self.flip.get("addr_overflow"))
            or (self.diag and self.diag.get("addr_overflow"))
        )


def expected_pattern_word(pattern):
    return PATTERN_WORD.get((pattern or "").upper())


def classify_cycle(cycle, expected_words=EXPECTED_WORDS, previous_pattern=None):
    tags = []
    diag = cycle.diag
    flip = cycle.flip or {}
    pattern = cycle.pattern()
    current_word = expected_pattern_word(pattern)
    previous_word = expected_pattern_word(previous_pattern)

    if diag is None:
        tags.append("NO_DIAG")
    else:
        if diag["fill1_count"] != expected_words:
            tags.append("WRITE_COVERAGE_FILL1")
        if diag["fill2_count"] != expected_words:
            tags.append("WRITE_COVERAGE_FILL2")
        if diag["scan_count"] != expected_words:
            tags.append("READ_COVERAGE_SCAN")
        if diag["bresp_errors"]:
            tags.append("AXI_WRITE_RESP")
        if diag["rresp_errors"]:
            tags.append("AXI_READ_RESP")
        if diag["first_bad_exp"] is not None and current_word is not None:
            if diag["first_bad_exp"] != current_word:
                tags.append("EXPECTED_PATTERN_MISMATCH")
        if (
            diag["first_bad_got"] is not None
            and previous_word is not None
            and current_word is not None
            and diag["first_bad_got"] == previous_word
            and diag["first_bad_exp"] == current_word
            and previous_word != current_word
        ):
            tags.append("PREVIOUS_PATTERN_DATA")

    if cycle.addr_overflow():
        tags.append("ADDR_OVERFLOW")

    if cycle.addr_header and flip:
        header_count = cycle.addr_header.get("count", 0)
        addr_len = len(cycle.addrs)
        if header_count != addr_len:
            tags.append("ADDR_STREAM_TRUNCATED")
        if flip.get("flip_count", 0) != addr_len and not cycle.addr_overflow():
            tags.append("ADDR_COUNT_MISMATCH")

    hard_faults = {
        "WRITE_COVERAGE_FILL1",
        "WRITE_COVERAGE_FILL2",
        "READ_COVERAGE_SCAN",
        "AXI_WRITE_RESP",
        "AXI_READ_RESP",
        "EXPECTED_PATTERN_MISMATCH",
        "PREVIOUS_PATTERN_DATA",
    }
    if not tags and cycle.flip_count() == 0:
        tags.append("CLEAN")
    elif diag is not None and cycle.flip_count() > 0 and not any(t in tags for t in hard_faults):
        tags.append("DATA_MISMATCH_WITH_CLEAN_BUS")
    return tags


class CaptureWriter:
    def __init__(self, out_dir, prefix, capture_jsonl=True):
        Path(out_dir).mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        base = Path(out_dir) / f"{prefix}_{stamp}"
        self.jsonl_path = base.with_suffix(".jsonl")
        self.csv_path = base.with_suffix(".csv")
        self.report_path = base.with_suffix(".md")
        self._jsonl = self.jsonl_path.open("w", encoding="utf-8", buffering=1) if capture_jsonl else None

    def write_record(self, record):
        if self._jsonl is not None:
            self._jsonl.write(json.dumps(record, separators=(",", ":")) + "\n")

    def close(self):
        if self._jsonl is not None:
            self._jsonl.close()


class CycleAssembler:
    def __init__(self):
        self.cycles = []
        self.current = None
        self.pending_addr_header = None
        self.pending_addrs = []

    def start_cycle(self, pattern="", refresh="", hold_s=0):
        self.current = Cycle(
            index=len(self.cycles) + 1,
            requested_pattern=pattern,
            requested_refresh=refresh,
            requested_hold_s=hold_s,
        )

    def ingest(self, record):
        completed = None
        rtype = record.get("type")
        if rtype == "ADDRS_HDR":
            self.pending_addr_header = record
            self.pending_addrs = []
            return None
        if rtype == "ADDR":
            if self.pending_addr_header:
                self.pending_addrs.append(record["addr"])
            return None
        if rtype == "FLIP":
            if self.current is not None and self.current.flip is not None and self.current.diag is None:
                completed = self.current
                self.cycles.append(self.current)
                self.current = None
            if self.current is None:
                self.start_cycle(pattern=record.get("pattern", ""))
            self.current.flip = record
            self.current.addr_header = self.pending_addr_header
            self.current.addrs = list(self.pending_addrs)
            if self.pending_addr_header:
                record["addrs"] = list(self.pending_addrs)
                record["addr_overflow"] = self.pending_addr_header.get("addr_overflow", False)
            self.pending_addr_header = None
            self.pending_addrs = []
        elif rtype == "TEMP" and self.current is not None:
            self.current.temp = record
        elif rtype == "DIAG" and self.current is not None:
            self.current.diag = record
            completed = self.current
            self.cycles.append(self.current)
            self.current = None
        if self.current is not None and rtype not in ("ADDRS_HDR", "ADDR"):
            self.current.records.append(record)
        return completed

    def flush_incomplete(self):
        if self.current is not None:
            self.cycles.append(self.current)
            self.current = None


def find_arty_port():
    if not SERIAL_AVAILABLE:
        return None
    candidates = [
        p for p in serial.tools.list_ports.comports()
        if p.vid == 0x0403 and p.pid == 0x6010
    ]
    if candidates:
        return sorted(candidates, key=lambda p: p.device)[-1].device
    return None


def read_serial_record(ser):
    raw = ser.readline()
    if not raw:
        return None
    return parse_line(raw)


def raw_display(data):
    text = data.decode("ascii", errors="replace").replace("\r", "\\r").replace("\n", "\\n")
    hex_text = " ".join(f"{b:02X}" for b in data)
    return f"{hex_text}    {text}"


def probe_serial(args):
    if not SERIAL_AVAILABLE:
        raise SystemExit("pyserial is required for serial probing. Install tools/requirements.txt.")
    port = args.port
    if port == "auto":
        port = find_arty_port()
    if not port:
        raise SystemExit("No serial port found. Use --port COMx.")

    print(f"Probing {port} @ {args.baud} for {args.probe_seconds:g}s")
    print("Press the board PROG/power-cycle during this window if you want to catch boot text.")
    deadline = time.time() + args.probe_seconds
    next_reset = time.time()
    with serial.Serial(port, args.baud, timeout=0.2) as ser:
        ser.reset_input_buffer()
        while time.time() < deadline:
            if args.probe_send_reset and time.time() >= next_reset:
                ser.write(b"X")
                ser.flush()
                print("TX: X")
                next_reset = time.time() + args.probe_reset_interval
            raw = ser.readline()
            if raw:
                print(f"RX: {raw_display(raw)}")


def baud_scan(args):
    if not SERIAL_AVAILABLE:
        raise SystemExit("pyserial is required for baud scanning. Install tools/requirements.txt.")
    port = args.port
    if port == "auto":
        port = find_arty_port()
    if not port:
        raise SystemExit("No serial port found. Use --port COMx.")

    bauds = [int(b.strip(), 0) for b in args.baud_scan.split(",") if b.strip()]
    for baud in bauds:
        print(f"\n=== {port} @ {baud} ===")
        deadline = time.time() + args.probe_seconds
        next_reset = time.time()
        with serial.Serial(port, baud, timeout=0.2) as ser:
            ser.reset_input_buffer()
            saw_rx = False
            while time.time() < deadline:
                if time.time() >= next_reset:
                    ser.write(b"X")
                    ser.flush()
                    print("TX: X")
                    next_reset = time.time() + args.probe_reset_interval
                raw = ser.readline()
                if raw:
                    saw_rx = True
                    print(f"RX: {raw_display(raw)}")
        if not saw_rx:
            print("RX: <none>")


def write_serial(ser, text):
    ser.write(text.encode("ascii"))
    ser.flush()


def wait_for_ready(ser, writer, timeout_s, echo_raw=False):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        raw = ser.readline()
        if not raw:
            continue
        if echo_raw:
            print(f"RX: {raw_display(raw)}")
        record = parse_line(raw)
        if record is None:
            continue
        writer.write_record(record)
        if record.get("type") == "READY":
            return True
    return False


def run_live(args):
    if not SERIAL_AVAILABLE:
        raise SystemExit("pyserial is required for live diagnostics. Install tools/requirements.txt.")
    port = args.port
    if port == "auto":
        port = find_arty_port()
    if not port:
        raise SystemExit("No serial port found. Use --port COMx.")

    writer = CaptureWriter(args.out, "diagnostic_live")
    assembler = CycleAssembler()
    completed_cycles = []
    print(f"Connecting to {port} @ {args.baud}")
    try:
        with serial.Serial(port, args.baud, timeout=1) as ser:
            ser.reset_input_buffer()
            ready = False
            for attempt in range(1, args.reset_retries + 1):
                if attempt == 1 and wait_for_ready(ser, writer, args.pre_reset_listen,
                                                   args.verbose_raw):
                    ready = True
                    break
                print(f"Sending X reset attempt {attempt}/{args.reset_retries}")
                write_serial(ser, "X")
                if wait_for_ready(ser, writer, args.ready_timeout, args.verbose_raw):
                    ready = True
                    break
            if not ready and not args.force_start:
                raise SystemExit("Timed out waiting for READY after reset. "
                                 "Run with --probe to inspect raw UART bytes, or "
                                 "--force-start to try H/P/R/G without READY.")
            if not ready:
                print("WARNING: proceeding without READY because --force-start was set.")

            previous_pattern = None
            for pattern in args.patterns:
                pattern = pattern.upper()
                if pattern not in PATTERN_TO_CMD:
                    raise SystemExit(f"Unsupported pattern {pattern}")
                print(f"Running pattern {pattern}, refresh {args.refresh}, {args.cycles} cycle(s)")
                write_serial(ser, f"H{args.hold}\n")
                write_serial(ser, f"P{PATTERN_TO_CMD[pattern]}\n")
                write_serial(ser, f"R{REFRESH_TO_CMD[args.refresh]}\n")
                write_serial(ser, "G")

                cycles_for_pattern = 0
                cycle_deadline = time.time() + args.cycle_timeout
                assembler.start_cycle(pattern=pattern, refresh=args.refresh, hold_s=args.hold)
                while cycles_for_pattern < args.cycles and time.time() < cycle_deadline:
                    record = read_serial_record(ser)
                    if record is None:
                        if assembler.current and assembler.current.flip:
                            age = time.time() - assembler.current.flip["ts_unix"]
                            if age > args.diag_after_flip_timeout:
                                assembler.flush_incomplete()
                                completed = assembler.cycles[-1]
                                completed_cycles.append((completed, previous_pattern))
                                cycles_for_pattern += 1
                                if cycles_for_pattern < args.cycles:
                                    assembler.start_cycle(pattern=pattern, refresh=args.refresh,
                                                          hold_s=args.hold)
                        continue
                    writer.write_record(record)
                    completed = assembler.ingest(record)
                    if completed is not None:
                        completed_cycles.append((completed, previous_pattern))
                        cycles_for_pattern += 1
                        previous_pattern = completed.pattern()
                        if cycles_for_pattern < args.cycles:
                            assembler.start_cycle(pattern=pattern, refresh=args.refresh,
                                                  hold_s=args.hold)
                        cycle_deadline = time.time() + args.cycle_timeout
                if cycles_for_pattern < args.cycles:
                    raise SystemExit(f"Timed out during pattern {pattern}.")
    finally:
        writer.close()

    write_summary_files(writer, completed_cycles, args.expected_words)
    print(f"Wrote {writer.jsonl_path}")
    print(f"Wrote {writer.csv_path}")
    print(f"Wrote {writer.report_path}")


def replay_jsonl(path):
    assembler = CycleAssembler()
    cycles = []
    previous_pattern = None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            record = parse_line(line)
        if not isinstance(record, dict):
            continue
        rtype = record.get("type")
        if rtype == "FLIP" and "addrs" in record and not assembler.pending_addr_header:
            assembler.pending_addr_header = {
                "type": "ADDRS_HDR",
                "count": len(record.get("addrs", [])),
                "addr_overflow": record.get("addr_overflow", False),
            }
            assembler.pending_addrs = list(record.get("addrs", []))
        completed = assembler.ingest(record)
        if completed is not None:
            cycles.append((completed, previous_pattern))
            previous_pattern = completed.pattern()
    assembler.flush_incomplete()
    for cycle in assembler.cycles[len(cycles):]:
        cycles.append((cycle, previous_pattern))
        previous_pattern = cycle.pattern()
    return cycles


def run_replay(args):
    cycles = replay_jsonl(args.replay)
    writer = CaptureWriter(args.out, "diagnostic_replay", capture_jsonl=False)
    writer.close()
    write_summary_files(writer, cycles, args.expected_words)
    print(f"Replayed {len(cycles)} cycle(s) from {args.replay}")
    print(f"Wrote {writer.csv_path}")
    print(f"Wrote {writer.report_path}")


def hex_or_x(value, width):
    if value is None:
        return "X"
    return f"{value:0{width}X}"


def cycle_row(cycle, previous_pattern, expected_words):
    tags = classify_cycle(cycle, expected_words, previous_pattern)
    diag = cycle.diag or {}
    flip = cycle.flip or {}
    return {
        "cycle": cycle.index,
        "pattern": cycle.pattern() or "",
        "previous_pattern": previous_pattern or "",
        "hold_s": flip.get("hold_s", cycle.requested_hold_s),
        "refresh": cycle.requested_refresh,
        "flip_count": cycle.flip_count(),
        "addr_count": len(cycle.addrs),
        "addr_overflow": cycle.addr_overflow(),
        "fill1_count": diag.get("fill1_count", ""),
        "fill2_count": diag.get("fill2_count", ""),
        "scan_count": diag.get("scan_count", ""),
        "bresp_errors": diag.get("bresp_errors", ""),
        "rresp_errors": diag.get("rresp_errors", ""),
        "first_bad_addr": hex_or_x(diag.get("first_bad_addr"), 7) if diag else "",
        "first_bad_got": hex_or_x(diag.get("first_bad_got"), 8) if diag else "",
        "first_bad_exp": hex_or_x(diag.get("first_bad_exp"), 8) if diag else "",
        "tags": ";".join(tags),
    }


def write_summary_files(writer, cycles, expected_words):
    fieldnames = [
        "cycle", "pattern", "previous_pattern", "hold_s", "refresh", "flip_count",
        "addr_count", "addr_overflow", "fill1_count", "fill2_count", "scan_count",
        "bresp_errors", "rresp_errors", "first_bad_addr", "first_bad_got",
        "first_bad_exp", "tags",
    ]
    rows = [cycle_row(cycle, prev, expected_words) for cycle, prev in cycles]
    with writer.csv_path.open("w", encoding="utf-8", newline="") as f:
        csv.DictWriter(f, fieldnames=fieldnames).writeheader()
        csv.DictWriter(f, fieldnames=fieldnames).writerows(rows)
    writer.report_path.write_text(build_report(rows, expected_words), encoding="utf-8")


def build_report(rows, expected_words):
    now = utc_now().isoformat()
    tag_counts = {}
    for row in rows:
        for tag in row["tags"].split(";"):
            if tag:
                tag_counts[tag] = tag_counts.get(tag, 0) + 1

    lines = [
        "# DRAM Diagnostic Report",
        "",
        f"Generated: {now}",
        f"Expected FILL/SCAN words: {expected_words}",
        f"Cycles analyzed: {len(rows)}",
        "",
        "## Classification Counts",
        "",
    ]
    if tag_counts:
        for tag, count in sorted(tag_counts.items()):
            lines.append(f"- {tag}: {count}")
    else:
        lines.append("- No cycles classified.")

    lines += ["", "## Interpretation", ""]
    hard = [
        "WRITE_COVERAGE_FILL1", "WRITE_COVERAGE_FILL2", "READ_COVERAGE_SCAN",
        "AXI_WRITE_RESP", "AXI_READ_RESP", "EXPECTED_PATTERN_MISMATCH",
        "PREVIOUS_PATTERN_DATA",
    ]
    if tag_counts.get("NO_DIAG"):
        lines.append(
            "At least one cycle has no DIAG record. This can confirm the symptom "
            "from old captures, but it cannot locate the failing stage."
        )
    elif any(tag_counts.get(tag) for tag in hard):
        lines.append(
            "The first-read issue is localizable from DIAG: coverage, AXI response, "
            "or pattern-latch tags identify a firmware/control-path failure before "
            "physical effects should be considered."
        )
    elif tag_counts.get("DATA_MISMATCH_WITH_CLEAN_BUS"):
        lines.append(
            "DIAG reports complete FILL/FILL2/SCAN coverage and clean AXI responses, "
            "but data mismatches remain. At that point, vary hold and refresh to "
            "separate retention behavior from any uninstrumented compare-path issue."
        )
    elif tag_counts.get("CLEAN"):
        lines.append("All diagnostic cycles were clean.")
    else:
        lines.append("No decisive diagnostic class was produced.")

    lines += [
        "",
        "## Cycles",
        "",
        "| Cycle | Pat | Prev | Flips | Addrs | F1 | F2 | SC | BERR | RERR | BAD | GOT | EXP | Tags |",
        "|---:|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|:---:|:---:|:---:|:---|",
    ]
    for row in rows:
        lines.append(
            f"| {row['cycle']} | {row['pattern']} | {row['previous_pattern']} | "
            f"{row['flip_count']} | {row['addr_count']} | {row['fill1_count']} | "
            f"{row['fill2_count']} | {row['scan_count']} | {row['bresp_errors']} | "
            f"{row['rresp_errors']} | {row['first_bad_addr']} | {row['first_bad_got']} | "
            f"{row['first_bad_exp']} | {row['tags']} |"
        )
    lines.append("")
    return "\n".join(lines)


def parse_patterns(value):
    patterns = [p.strip().upper() for p in value.split(",") if p.strip()]
    bad = [p for p in patterns if p not in PATTERN_TO_CMD]
    if bad:
        raise argparse.ArgumentTypeError(f"unsupported pattern(s): {','.join(bad)}")
    return patterns


def build_argparser():
    parser = argparse.ArgumentParser(description="Run or replay DRAM diagnostic captures.")
    parser.add_argument("--replay", help="Existing JSONL file to classify instead of using serial.")
    parser.add_argument("--out", default="data/diagnostics", help="Output directory.")
    parser.add_argument("--port", default="auto", help="Serial port, or auto.")
    parser.add_argument("--baud", type=int, default=BAUD)
    parser.add_argument("--hold", type=int, default=1)
    parser.add_argument("--refresh", choices=sorted(REFRESH_TO_CMD), default="NORM")
    parser.add_argument("--patterns", type=parse_patterns, default=parse_patterns("FF,00,55,AA,FF"))
    parser.add_argument("--cycles", type=int, default=3, help="Cycles per pattern in live mode.")
    parser.add_argument("--expected-words", type=lambda x: int(x, 0), default=EXPECTED_WORDS)
    parser.add_argument("--ready-timeout", type=float, default=30.0)
    parser.add_argument("--reset-retries", type=int, default=3)
    parser.add_argument("--pre-reset-listen", type=float, default=2.0)
    parser.add_argument("--cycle-timeout", type=float, default=CYCLE_TIMEOUT_S)
    parser.add_argument("--diag-after-flip-timeout", type=float, default=DIAG_AFTER_FLIP_TIMEOUT_S)
    parser.add_argument("--force-start", action="store_true",
                        help="Try H/P/R/G even if READY is not observed.")
    parser.add_argument("--verbose-raw", action="store_true",
                        help="Print raw serial lines while waiting for READY.")
    parser.add_argument("--probe", action="store_true",
                        help="Only print raw UART bytes; do not run diagnostics.")
    parser.add_argument("--probe-seconds", type=float, default=20.0)
    parser.add_argument("--probe-send-reset", action="store_true",
                        help="Send X periodically during --probe.")
    parser.add_argument("--probe-reset-interval", type=float, default=2.0)
    parser.add_argument("--baud-scan",
                        default=("115200,230400,460800,500000,921600,1000000,"
                                 "1020000,1030000,1040000,1041667,1050000,1060000"),
                        help="Comma-separated baud list used with --scan-baud.")
    parser.add_argument("--scan-baud", action="store_true",
                        help="Probe multiple baud rates and print raw UART bytes.")
    return parser


def main(argv=None):
    args = build_argparser().parse_args(argv)
    if args.cycles < 1:
        raise SystemExit("--cycles must be >= 1")
    if args.hold < 1:
        raise SystemExit("--hold must be >= 1")
    if args.scan_baud:
        baud_scan(args)
    elif args.probe:
        probe_serial(args)
    elif args.replay:
        run_replay(args)
    else:
        run_live(args)


if __name__ == "__main__":
    main()
