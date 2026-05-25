# Implementation Plan

Last updated: 2026-05-25

## Implemented

- Removed physical experiment controls from the active firmware path.
- Added UART refresh command `R<n>\n`.
- Kept UART commands `H<n>\n`, `P<n>\n`, `G`, and `X`.
- Added GUI refresh selection and Start sequencing: `H`, `P`, `R`, `G`.
- Enabled Reset Board immediately after connection.
- Restored firmware timing to `UI_CLK_HZ = 150_000_000` after hardware UART bytes matched the older working divider assumption rather than the generated BD metadata.
- Added address capture overflow reporting.
- Added cycle diagnostics for first-read and pattern-change investigation.
- Added standalone diagnostic runner `tools/run_diagnostics.py` for live UART sweeps and JSONL replay classification.
- Removed divider/modulo hold-time formatting from the UART print path after routed timing showed `uart_data` setup violations.
- Removed the `H<n>` seconds-to-cycles DSP multiply from the firmware control path; hold timing now counts UI-clock ticks into elapsed seconds.
- Staged scan mismatches before writing the address-capture buffer after routed timing showed SmartConnect read-response paths driving distributed RAM write enables.
- Staged address streaming through a dedicated word register after routed timing showed the address-buffer read path feeding the shared report register.
- Split UART text formatting into `uart_reporter.v` so the detector FSM now requests complete messages instead of carrying the byte formatter, UART byte index, and line-end logic in the AXI control state machine.
- Converted address capture to a synchronous block-RAM inference template after asynchronous streaming reads caused Vivado to infer the 4096x28 buffer as flip-flops.
- Replaced `uart_tx.v` with a conventional immediate-start UART transmitter after a timing-clean flashed build still produced deterministic non-ASCII bytes on the only real USB serial port.
- Lowered UART to `115200` and added a pre-FSM `BOOT` banner so hardware UART bring-up can be isolated from detector/MIG behavior.
- Routed replayed FLIP records through the same background, rare-event, raster, temperature, and clustering logic as live data.
- Updated batch programming scripts to open the project when no Vivado project is already open.
- Added Python parser/storage tests.
- Added `detector_fsm_tb.v` for AXI coverage and pattern-latch testing.
- Added `D3=VERIFY` pre-hold verification and `VDIAG` reporting to separate fill/write failures from hold/refresh/scan failures.
- Switched the generated-BD hook to a MIG-internal-refresh production baseline: `R<n>` is accepted/logged, but `rank_common.refresh_tick` uses `refresh_tick_lcl`.
- Replaced FILL/FILL2 with a strict single-outstanding AXI write sequencer and added `AW`, `W`, and `B` handshake counters to `DIAG`.
- Removed the temporary `D<n>`, `DIAG`, and `VDIAG` hardware paths after the strict write sequencer fixed the VERIFY run. Current firmware emits only production telemetry.

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
| `BOOT` | UART boot banner before detector FSM release |
| `READY` | Calibration complete and waiting |
| `INTERVAL:NNNNs` | Accepted hold seconds |
| `PATTERN:XX` | Accepted pattern |
| `REFRESH:<OFF|SLOW|NORM|FAST>` | Accepted refresh mode |
| `ADDRS:NNNN OVF:X` | Buffered address count and overflow flag |
| `HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX` | Cycle result |
| `TEMP:XXX` | Raw XADC temperature code |

## First-Read Investigation Outcome

The first-read/pattern-change spike was a firmware write-sequencing bug, not a physical effect. The old fill loop could reissue the same address while waiting for delayed AXI `B` responses, then advance once per response and skip later addresses. The production FSM keeps the fix: FILL/FILL2 issue one write at a time, latch the issued address, wait for AW, wait for W, wait for B, then advance.

The temporary VERIFY/DIAG hardware confirmed the fix on 2026-05-25 (`data/diagnostics/diagnostic_live_20260525_131823.*`): all 15 VERIFY cycles were clean with `VC=0` and `AW=W=B=0x02000000`. Those temporary hardware paths have now been removed to reduce the active FSM.

## Automated Diagnostic Runner

Use replay mode on old captures to confirm whether the file has enough information to localize the bug:

```bash
python -B tools/run_diagnostics.py --replay data/experiment_20260424_104838.jsonl
```

Old captures without `DIAG` are classified as `NO_DIAG`: they can confirm the first-read symptom and address-list truncation, but cannot prove whether the fault occurred in FILL, FILL2, SCAN, AXI responses, or pattern latching.

Use live mode after programming the production firmware:

```bash
python -B tools/run_diagnostics.py --port auto --hold 1 --refresh NORM --patterns FF,00,55,AA,FF --cycles 3
```

The runner sends `X`, waits for `READY`, then runs `H`, `P`, `R`, `G` sequences. It writes a raw JSONL capture, a CSV summary, and a Markdown report under `data/diagnostics`. It still understands older `DIAG`/`VDIAG` records for replay, but current firmware does not emit them.

Classification tags:

- `WRITE_COVERAGE_FILL1` / `WRITE_COVERAGE_FILL2`: a fill pass did not receive the expected number of write responses.
- `READ_COVERAGE_SCAN`: scan did not receive the expected number of read responses.
- `AXI_WRITE_RESP` / `AXI_READ_RESP`: MIG returned a non-OK AXI response.
- `WRITE_AW_COVERAGE` / `WRITE_W_COVERAGE` / `WRITE_B_COVERAGE`: a write channel did not receive the expected number of handshakes across both fill passes.
- `WRITE_CHANNEL_IMBALANCE`: `AW`, `W`, and `B` counts disagree.
- `PREVIOUS_PATTERN_DATA`: first mismatch still equals the previous pattern after a pattern change.
- `EXPECTED_PATTERN_MISMATCH`: compare expected data does not match the active pattern.
- `ADDR_OVERFLOW`, `ADDR_STREAM_TRUNCATED`, `ADDR_COUNT_MISMATCH`: address capture is incomplete or inconsistent.
- `ADDR_STREAM_BAD_FIRST`: the first streamed address does not match `DIAG BAD`.
- `FILL_VERIFY_FAILED`: `D3=VERIFY` found bad data immediately after `FILL2`.
- `VERIFY_PREVIOUS_PATTERN`: pre-hold verify read the previous pattern.
- `HOLD_OR_SCAN_FAILED`: pre-hold verify was clean, but the measured scan found mismatches.
- `DATA_MISMATCH_WITH_CLEAN_BUS`: fill/scan coverage and AXI responses were clean, but mismatches remain.

## Remaining Hardware Acceptance

- UART bring-up is fixed at `115200`.
- Live diagnostics on 2026-05-25 show complete FILL/FILL2/SCAN coverage and zero AXI response errors.
- The 2026-05-25 `NORMAL,WAIT,DUMMY` run still showed previous-pattern data. `WAIT` helped only some transitions and `DUMMY` did not clear the symptom.
- The 2026-05-25 `VERIFY` and refresh-sweep runs showed `VDIAG` failures before `HOLD`, with `FAST` much worse. Rebuild the MIG-internal-refresh baseline next to isolate the custom refresh override.
- The 2026-05-25 MIG-internal-refresh baseline still showed pre-hold `FILL_VERIFY_FAILED` in 11 of 15 cycles, so custom refresh override is not the whole cause.
- The 2026-05-25 strict single-outstanding AXI write build (`data/diagnostics/diagnostic_live_20260525_131823.*`) fixed the VERIFY run: all 15 cycles were clean, `AW=W=B=0x02000000`, and `VC=0`.
- Next hardware step: run the production sanity sequence with the same pattern list and confirm all reported `FLIPS` values stay at zero.
- Address streaming should be rechecked with production firmware when real flips are present; the previous `ADDR_STREAM_BAD_FIRST` signal came from diagnostic firmware.
- Refresh selector measurement and MIG refresh-control restoration are deferred until the graphing interface and production baseline are stable.
