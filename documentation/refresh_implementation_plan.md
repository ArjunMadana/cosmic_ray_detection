# Refresh Implementation Plan

Last updated: 2026-05-24

Refresh control is implemented through the GUI and UART only. The old physical-control plan is obsolete.

## Firmware

`detector_fsm` owns the refresh selector:

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

`UI_CLK_HZ` is `166_666_667`.

## Generated BD/MIG Patch

`tools/expose_device_temp.tcl` patches the generated hierarchy so `refresh_tick_out` reaches MIG:

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

The patched `rank_common` assignment is:

```verilog
assign refresh_tick = ext_refresh_tick;
```

## GUI

The GUI exposes refresh as a dropdown next to hold and pattern controls. On Start it sends:

```text
H<n>\n
P<n>\n
R<n>\n
G
```

Replay tracks `REFRESH` records and redraws the raw, denoised, and raster tabs with the same pipeline as live data.

## Validation

- Use the Python parser test for `REFRESH`.
- Run `detector_fsm_tb.v` in Vivado/xsim.
- On hardware, compare flip counts across `OFF`, `SLOW`, `NORM`, and `FAST`.
