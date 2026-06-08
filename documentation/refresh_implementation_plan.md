# Refresh Implementation Plan

Last updated: 2026-05-25

Refresh control is deferred. The old physical-control plan is obsolete, and the GUI no longer exposes refresh controls in the production graphing UI.

Current production baseline: the generated-BD patch leaves MIG on its internal refresh generator until refresh-control restoration is revisited.

## Firmware

The previous `detector_fsm` refresh selector is dormant while MIG uses internal refresh:

| UART | Mode | Period source |
|------|------|---------------|
| `R0\n` | `OFF` | no external refresh ticks |
| `R1\n` | `SLOW` | `UI_CLK_HZ / 10` |
| `R2\n` | `NORM` | approximately 7.8 us |
| `R3\n` | `FAST` | approximately 3.9 us |

Accepted commands emit:

```text
REFRESH:OFF
REFRESH:SLOW
REFRESH:NORM
REFRESH:FAST
```

`UI_CLK_HZ` is `150_000_000`.

## Generated BD/MIG Patch

`tools/expose_device_temp.tcl` currently patches the generated hierarchy so `device_temp_0` reaches `cosmic_top` and `ext_refresh_tick` remains plumbed for structural compatibility:

```text
detector_fsm.refresh_tick_out
cosmic_top.refresh_tick_out
cosmic_bd_wrapper.ext_refresh_tick
cosmic_bd.ext_refresh_tick
cosmic_bd_mig_7series_0_2.ext_refresh_tick
cosmic_bd_mig_7series_0_2_mig.ext_refresh_tick
mig_7series_v4_2_memc_ui_top_axi.ext_refresh_tick
mig_7series_v4_2_mem_intfc.ext_refresh_tick
mig_7series_v4_2_mc.ext_refresh_tick
mig_7series_v4_2_rank_mach.ext_refresh_tick
mig_7series_v4_2_rank_common.ext_refresh_tick
```

The baseline `rank_common` assignment is:

```verilog
assign refresh_tick = refresh_tick_lcl;
```

This deliberately disables GUI-controlled MIG refresh for the production cleanup baseline. The write-correctness bug is fixed; restore refresh control only after designing a safer approach that does not interfere with active traffic.

## GUI

The GUI controls hold and pattern. On Start it sends:

```text
H<n>\n
P<n>\n
G
```

The runner ignores `--refresh` in live production mode and keeps MIG on internal refresh.

Replay tolerates older `REFRESH` records, but current graphing does not present refresh as an active experiment setting.

## Validation

- Use the Python parser test for `REFRESH`.
- Run `detector_fsm_tb.v` in Vivado/xsim.
- On hardware, run the production sanity sequence while MIG uses its internal refresh timer.
