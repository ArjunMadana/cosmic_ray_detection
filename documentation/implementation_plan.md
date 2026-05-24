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

## Remaining Hardware Acceptance

- Connect after the board is already powered; Reset Board must recover `READY`.
- Start with GUI-selected hold, pattern, and refresh; the first cycle must reflect those exact settings.
- Switch pattern from the GUI; `DIAG` must show complete FILL/FILL2/SCAN coverage.
- Confirm refresh selector measurably changes flip counts after `ext_refresh_tick` synthesis.
