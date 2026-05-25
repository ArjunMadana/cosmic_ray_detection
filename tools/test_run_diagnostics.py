import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_diagnostics import (
    build_report,
    Cycle,
    classify_cycle,
    parse_diag_modes,
    parse_line,
    parse_refresh_modes,
    replay_jsonl,
)


EXPECTED = 16


def flip(count=0, pattern="AA", addrs=None, overflow=False):
    record = {
        "type": "FLIP",
        "hold_s": 1,
        "pattern": pattern,
        "flip_count": count,
        "addr_overflow": overflow,
    }
    if addrs is not None:
        record["addrs"] = addrs
    return record


def diag(fill1=EXPECTED, fill2=EXPECTED, scan=EXPECTED, berr=0, rerr=0,
         bad=None, got=None, exp=None, overflow=False, aw=None, w=None, b=None):
    return {
        "type": "DIAG",
        "fill1_count": fill1,
        "fill2_count": fill2,
        "scan_count": scan,
        "bresp_errors": berr,
        "rresp_errors": rerr,
        "aw_count": aw,
        "w_count": w,
        "b_count": b,
        "first_bad_addr": bad,
        "first_bad_got": got,
        "first_bad_exp": exp,
        "addr_overflow": overflow,
    }


def vdiag(count=0, bad=None, got=None, exp=None):
    return {
        "type": "VDIAG",
        "verify_count": count,
        "verify_bad_addr": bad,
        "verify_got": got,
        "verify_exp": exp,
    }


class DiagnosticClassificationTests(unittest.TestCase):
    def test_parse_diag_modes(self):
        self.assertEqual(parse_diag_modes("normal,wait,dummy,verify"),
                         ["NORMAL", "WAIT", "DUMMY", "VERIFY"])

    def test_parse_refresh_modes(self):
        self.assertEqual(parse_refresh_modes("off,norm"), ["OFF", "NORM"])

    def test_parse_boot_banner(self):
        record = parse_line("BOOT", 0)
        self.assertEqual(record["type"], "BOOT")

    def test_parse_vdiag(self):
        record = parse_line("VDIAG:VC:00000002 VBAD:000000C VGOT:FFFFFFFF VEXP:00000000", 0)
        self.assertEqual(record["type"], "VDIAG")
        self.assertEqual(record["verify_count"], 2)
        self.assertEqual(record["verify_bad_addr"], 0xC)
        self.assertEqual(record["verify_got"], 0xFFFFFFFF)

    def test_parse_diag_with_write_channel_counts(self):
        record = parse_line(
            "DIAG:F1:00000010 F2:00000010 SC:00000010 "
            "BERR:00000000 RERR:00000000 AW:00000020 W:00000020 B:00000020 "
            "BAD:XXXXXXX GOT:XXXXXXXX EXP:XXXXXXXX OVF:0",
            0,
        )
        self.assertEqual(record["type"], "DIAG")
        self.assertEqual(record["aw_count"], 32)
        self.assertEqual(record["w_count"], 32)
        self.assertEqual(record["b_count"], 32)

    def test_no_diag_is_symptom_only(self):
        cycle = Cycle(index=1, flip=flip(23, "FF"))
        self.assertIn("FLIPS_NO_DIAG", classify_cycle(cycle, EXPECTED))

    def test_zero_flips_without_diag_is_clean_for_production_firmware(self):
        cycle = Cycle(index=1, flip=flip(0, "FF"))
        self.assertEqual(classify_cycle(cycle, EXPECTED), ["CLEAN"])

    def test_clean_cycle(self):
        cycle = Cycle(index=1, flip=flip(0, "AA"), diag=diag())
        self.assertEqual(classify_cycle(cycle, EXPECTED), ["CLEAN"])

    def test_coverage_faults_are_explicit(self):
        cycle = Cycle(index=1, flip=flip(2, "AA"), diag=diag(fill1=15, fill2=14, scan=13))
        tags = classify_cycle(cycle, EXPECTED)
        self.assertIn("WRITE_COVERAGE_FILL1", tags)
        self.assertIn("WRITE_COVERAGE_FILL2", tags)
        self.assertIn("READ_COVERAGE_SCAN", tags)

    def test_axi_response_faults_are_explicit(self):
        cycle = Cycle(index=1, flip=flip(2, "AA"), diag=diag(berr=1, rerr=2))
        tags = classify_cycle(cycle, EXPECTED)
        self.assertIn("AXI_WRITE_RESP", tags)
        self.assertIn("AXI_READ_RESP", tags)

    def test_write_channel_faults_are_explicit(self):
        cycle = Cycle(index=1, flip=flip(2, "AA"), diag=diag(aw=32, w=31, b=32))
        tags = classify_cycle(cycle, EXPECTED)
        self.assertIn("WRITE_W_COVERAGE", tags)
        self.assertIn("WRITE_CHANNEL_IMBALANCE", tags)

    def test_previous_pattern_data_is_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(1, "00"),
            diag=diag(bad=0x10, got=0xFFFFFFFF, exp=0x00000000),
        )
        self.assertIn("PREVIOUS_PATTERN_DATA", classify_cycle(cycle, EXPECTED, "FF"))

    def test_expected_pattern_mismatch_is_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(1, "AA"),
            diag=diag(bad=0x10, got=0x55555555, exp=0x55555555),
        )
        self.assertIn("EXPECTED_PATTERN_MISMATCH", classify_cycle(cycle, EXPECTED))

    def test_address_stream_overflow_and_truncation_are_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(4, "AA"),
            diag=diag(overflow=True),
            addr_header={"type": "ADDRS_HDR", "count": 4, "addr_overflow": True},
            addrs=[0, 4],
        )
        tags = classify_cycle(cycle, EXPECTED)
        self.assertIn("ADDR_OVERFLOW", tags)
        self.assertIn("ADDR_STREAM_TRUNCATED", tags)

    def test_address_stream_bad_first_is_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(1, "AA"),
            diag=diag(bad=0x20, got=0x55555555, exp=0xAAAAAAAA),
            addr_header={"type": "ADDRS_HDR", "count": 1, "addr_overflow": False},
            addrs=[0],
        )
        self.assertIn("ADDR_STREAM_BAD_FIRST", classify_cycle(cycle, EXPECTED))

    def test_fill_verify_failed_is_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(1, "00"),
            diag=diag(bad=0x10, got=0xFFFFFFFF, exp=0),
            vdiag=vdiag(count=1, bad=0x10, got=0xFFFFFFFF, exp=0),
        )
        tags = classify_cycle(cycle, EXPECTED, "FF")
        self.assertIn("FILL_VERIFY_FAILED", tags)
        self.assertIn("VERIFY_PREVIOUS_PATTERN", tags)

    def test_hold_or_scan_failed_is_detected(self):
        cycle = Cycle(
            index=1,
            flip=flip(1, "AA"),
            diag=diag(bad=0x10, got=0x55555555, exp=0xAAAAAAAA),
            vdiag=vdiag(count=0),
        )
        self.assertIn("HOLD_OR_SCAN_FAILED", classify_cycle(cycle, EXPECTED, "55"))


class DiagnosticReplayTests(unittest.TestCase):
    def test_replay_without_diag_keeps_each_flip_as_a_cycle(self):
        rows = [
            {"type": "FLIP", "hold_s": 1, "pattern": "FF", "flip_count": 7},
            {"type": "FLIP", "hold_s": 1, "pattern": "00", "flip_count": 5},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "old.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            cycles = replay_jsonl(path)
        self.assertEqual(len(cycles), 2)
        self.assertEqual(cycles[0][0].flip_count(), 7)
        self.assertEqual(cycles[1][0].flip_count(), 5)

    def test_replay_uses_address_arrays_from_flip_records(self):
        rows = [
            {"type": "FLIP", "hold_s": 1, "pattern": "AA", "flip_count": 2,
             "addrs": [0, 4], "addr_overflow": False},
            diag(),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "with_addrs.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            cycles = replay_jsonl(path)
        self.assertEqual(len(cycles), 1)
        self.assertEqual(cycles[0][0].addrs, [0, 4])

    def test_replay_reconstructs_address_stream_before_flip(self):
        rows = [
            {"type": "ADDRS_HDR", "count": 2, "addr_overflow": False},
            {"type": "ADDR", "addr": 0},
            {"type": "ADDR", "addr": 4},
            {"type": "FLIP", "hold_s": 1, "pattern": "AA", "flip_count": 2},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "stream_addrs.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            cycles = replay_jsonl(path)
        self.assertEqual(len(cycles), 1)
        self.assertEqual(cycles[0][0].addrs, [0, 4])

    def test_production_report_omits_empty_legacy_columns(self):
        cycle = Cycle(
            index=1,
            requested_pattern="AA",
            requested_refresh="NORM",
            requested_hold_s=1,
            flip=flip(0, "AA"),
        )
        row = build_report([{
            "cycle": cycle.index,
            "pattern": cycle.pattern(),
            "previous_pattern": "",
            "hold_s": 1,
            "refresh": "NORM",
            "diag_mode": "NORMAL",
            "flip_count": cycle.flip_count(),
            "addr_count": 0,
            "addr_overflow": False,
            "fill1_count": "",
            "fill2_count": "",
            "scan_count": "",
            "bresp_errors": "",
            "rresp_errors": "",
            "aw_count": "",
            "w_count": "",
            "b_count": "",
            "first_bad_addr": "",
            "first_bad_got": "",
            "first_bad_exp": "",
            "verify_count": "",
            "verify_bad_addr": "",
            "verify_got": "",
            "verify_exp": "",
            "tags": "CLEAN",
        }], EXPECTED)
        self.assertIn("| Cycle | Pat | Prev | Hold | Refresh | Flips | Addrs | OVF | Tags |", row)
        self.assertNotIn("| Cycle | Mode | Pat |", row)

    def test_replay_attaches_vdiag_after_diag(self):
        rows = [
            {"type": "FLIP", "hold_s": 1, "pattern": "00", "flip_count": 1},
            diag(bad=0, got=0xFFFFFFFF, exp=0),
            vdiag(count=1, bad=0, got=0xFFFFFFFF, exp=0),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "with_vdiag.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
            cycles = replay_jsonl(path)
        self.assertEqual(len(cycles), 1)
        self.assertEqual(cycles[0][0].vdiag["verify_count"], 1)


if __name__ == "__main__":
    unittest.main()
