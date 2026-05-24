import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from run_diagnostics import Cycle, classify_cycle, replay_jsonl


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
         bad=None, got=None, exp=None, overflow=False):
    return {
        "type": "DIAG",
        "fill1_count": fill1,
        "fill2_count": fill2,
        "scan_count": scan,
        "bresp_errors": berr,
        "rresp_errors": rerr,
        "first_bad_addr": bad,
        "first_bad_got": got,
        "first_bad_exp": exp,
        "addr_overflow": overflow,
    }


class DiagnosticClassificationTests(unittest.TestCase):
    def test_no_diag_is_symptom_only(self):
        cycle = Cycle(index=1, flip=flip(23, "FF"))
        self.assertIn("NO_DIAG", classify_cycle(cycle, EXPECTED))

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


if __name__ == "__main__":
    unittest.main()
