import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from uart_logger import DataStore, parse_line


TS = 1_700_000_000.0


class ParserTests(unittest.TestCase):
    def test_refresh_record(self):
        record = parse_line(b"REFRESH:NORM\r\n", TS)
        self.assertEqual(record["type"], "REFRESH")
        self.assertEqual(record["refresh_rate"], "NORM")

    def test_boot_record(self):
        record = parse_line(b"BOOT\r\n", TS)
        self.assertEqual(record["type"], "BOOT")

    def test_addrs_header_with_overflow(self):
        record = parse_line(b"ADDRS:1000 OVF:1\r\n", TS)
        self.assertEqual(record["type"], "ADDRS_HDR")
        self.assertEqual(record["count"], 4096)
        self.assertTrue(record["addr_overflow"])

    def test_diag_record(self):
        record = parse_line(
            b"DIAG:F1:00000010 F2:00000010 SC:00000010 "
            b"BERR:00000000 RERR:00000001 BAD:000000C "
            b"GOT:DEADBEEF EXP:AAAAAAAA OVF:1\r\n",
            TS,
        )
        self.assertEqual(record["type"], "DIAG")
        self.assertEqual(record["fill1_count"], 16)
        self.assertEqual(record["fill2_count"], 16)
        self.assertEqual(record["scan_count"], 16)
        self.assertEqual(record["rresp_errors"], 1)
        self.assertEqual(record["first_bad_addr"], 0xC)
        self.assertEqual(record["first_bad_got"], 0xDEADBEEF)
        self.assertTrue(record["addr_overflow"])

    def test_diag_record_with_write_channel_counts(self):
        record = parse_line(
            b"DIAG:F1:00000010 F2:00000010 SC:00000010 "
            b"BERR:00000000 RERR:00000001 AW:00000020 W:00000020 B:00000020 "
            b"BAD:000000C GOT:DEADBEEF EXP:AAAAAAAA OVF:1\r\n",
            TS,
        )
        self.assertEqual(record["type"], "DIAG")
        self.assertEqual(record["aw_count"], 32)
        self.assertEqual(record["w_count"], 32)
        self.assertEqual(record["b_count"], 32)

    def test_vdiag_record(self):
        record = parse_line(
            b"VDIAG:VC:00000002 VBAD:000000C VGOT:DEADBEEF VEXP:AAAAAAAA\r\n",
            TS,
        )
        self.assertEqual(record["type"], "VDIAG")
        self.assertEqual(record["verify_count"], 2)
        self.assertEqual(record["verify_bad_addr"], 0xC)
        self.assertEqual(record["verify_got"], 0xDEADBEEF)
        self.assertEqual(record["verify_exp"], 0xAAAAAAAA)

    def test_hold_flip_record(self):
        record = parse_line(b"HOLD:0005s PAT:AA FLIPS:00000002\r\n", TS)
        self.assertEqual(record["type"], "FLIP")
        self.assertEqual(record["hold_s"], 5)
        self.assertEqual(record["pattern"], "AA")
        self.assertEqual(record["flip_count"], 2)

    def test_temp_record(self):
        record = parse_line(b"TEMP:800\r\n", TS)
        self.assertEqual(record["type"], "TEMP")
        self.assertEqual(record["raw_code"], 0x800)
        self.assertIsInstance(record["temp_c"], float)


class DataStoreTests(unittest.TestCase):
    def test_jsonl_preserves_replay_address_array(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = DataStore(tmp, "parser_test", "unit", "2026-05-24T00:00:00+00:00")
            record = {
                "type": "FLIP",
                "timestamp": "2026-05-24T00:00:00+00:00",
                "ts_unix": TS,
                "hold_s": 5,
                "pattern": "AA",
                "flip_count": 2,
                "addrs": [0, 4],
                "addr_overflow": True,
            }
            store.ingest(record)
            jsonl_path = Path(store.jsonl_path)
            store.close()

            saved = json.loads(jsonl_path.read_text().splitlines()[0])
            self.assertEqual(saved["addrs"], [0, 4])
            self.assertTrue(saved["addr_overflow"])


if __name__ == "__main__":
    unittest.main()
