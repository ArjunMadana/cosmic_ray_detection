# Implementation Plan

Last updated: 2026-05-24

## Implemented

- Removed physical experiment controls from the active firmware path.
- Added UART refresh command `R<n>\n`.
- Kept UART commands `H<n>\n`, `P<n>\n`, `G`, and `X`.
- Added GUI refresh selection and Start sequencing: `H`, `P`, `R`, `G`.
- Enabled Reset Board immediately after connection.
- Standardized firmware timing on `UI_CLK_HZ = 166_666_667`.
- Added address capture overflow reporting.
- Added cycle diagnostics for first-read and pattern-change investigation.
- Added standalone diagnostic runner `tools/run_diagnostics.py` for live UART sweeps and JSONL replay classification.
- Routed replayed FLIP records through the same background, rare-event, raster, temperature, and clustering logic as live data.
- Updated batch programming scripts to open the project when no Vivado project is already open.
- Added Python parser/storage tests.
- Added `detector_fsm_tb.v` for AXI coverage and pattern-latch testing.

## UART Protocol

PC to board:

| Command | Meaning |
|---------|---------|
| `H<n>\n` | Set hold seconds, 1-9999 |
| `P<n>\n` | Set pattern: `0=FF`, `1=00`, `2=55`, `3=AA` |
| `R<n>\n` | Set refresh: `0=OFF`, `1=SLOW`, `2=NORM`, `3=FAST` |
| `G` | Start cycling |
| `X` | Abort current cycle and return to `WAIT_GO` |

Board to PC:

| Message | Meaning |
|---------|---------|
| `READY` | Calibration complete and waiting |
| `INTERVAL:NNNNs` | Accepted hold seconds |
| `PATTERN:XX` | Accepted pattern |
| `REFRESH:<OFF|SLOW|NORM|FAST>` | Accepted refresh mode |
| `ADDRS:NNNN OVF:X` | Buffered address count and overflow flag |
| `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX` | Cycle result |
| `TEMP:XXX` | Raw XADC temperature code |
| `DIAG:...` | Fill/scan coverage and first mismatch details |

## First-Read Investigation

The design does not discard first-cycle data. Large first-read or pattern-change counts are treated as a bug until the diagnostic counters identify the failing stage.

Diagnostic expectations for full-memory hardware runs:

- `F1 == MEM_SIZE / 4`
- `F2 == MEM_SIZE / 4`
- `SC == MEM_SIZE / 4`
- `BERR == 0`
- `RERR == 0`
- `BAD/GOT/EXP` are `X` when there are no mismatches

If a first-cycle spike remains, use the first nonzero or incomplete diagnostic field to separate AXI write coverage, AXI read coverage, response errors, and data mismatch behavior.

## Automated Diagnostic Runner

Use replay mode on old captures to confirm whether the file has enough information to localize the bug:

```bash
python -B tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
```

Old captures without `DIAG` are classified as `NO_DIAG`: they can confirm the first-read symptom and address-list truncation, but cannot prove whether the fault occurred in FILL, FILL2, SCAN, AXI responses, or pattern latching.

Use live mode after programming the diagnostic firmware:

```bash
python -B tools/run_diagnostics.py --port auto --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

The runner sends `X`, waits for `READY`, then runs `H`, `P`, `R`, `G` sequences. It writes a raw JSONL capture, a CSV summary, and a Markdown report under `data/diagnostics`.

Classification tags:

- `WRITE_COVERAGE_FILL1` / `WRITE_COVERAGE_FILL2`: a fill pass did not receive the expected number of write responses.
- `READ_COVERAGE_SCAN`: scan did not receive the expected number of read responses.
- `AXI_WRITE_RESP` / `AXI_READ_RESP`: MIG returned a non-OK AXI response.
- `PREVIOUS_PATTERN_DATA`: first mismatch still equals the previous pattern after a pattern change.
- `EXPECTED_PATTERN_MISMATCH`: compare expected data does not match the active pattern.
- `ADDR_OVERFLOW`, `ADDR_STREAM_TRUNCATED`, `ADDR_COUNT_MISMATCH`: address capture is incomplete or inconsistent.
- `DATA_MISMATCH_WITH_CLEAN_BUS`: fill/scan coverage and AXI responses were clean, but mismatches remain.

## Remaining Hardware Acceptance

- Connect after the board is already powered; Reset Board must recover `READY`.
- Start with GUI-selected hold, pattern, and refresh; the first cycle must reflect those exact settings.
- Switch pattern from the GUI; `DIAG` must show complete FILL/FILL2/SCAN coverage.
- Confirm refresh selector measurably changes flip counts after `ext_refresh_tick` synthesis.
