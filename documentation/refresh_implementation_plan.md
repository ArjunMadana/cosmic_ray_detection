# Refresh Implementation Plan

Last updated: 2026-05-25

Refresh control is implemented through the GUI and UART only. The old physical-control plan is obsolete.

Current production baseline: the generated-BD patch leaves MIG on its internal refresh generator. `R<n>` commands are accepted and logged, but they do not control MIG refresh until refresh-control restoration is revisited.

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

The GUI exposes refresh as a dropdown next to hold and pattern controls. On Start it sends:

```text
H<n>\n
P<n>\n
R<n>\n
G
```

The runner accepts comma-separated refresh sweeps, for example:

```bash
python -B tools/run_diagnostics.py --port COM3 --baud 115200 --hold 1 --refresh OFF,SLOW,NORM,FAST --patterns FF,00,55,AA,FF --cycles 2
```

Replay tracks `REFRESH` records and redraws the raw, denoised, and raster tabs with the same pipeline as live data.

## Validation

- Use the Python parser test for `REFRESH`.
- Run `detector_fsm_tb.v` in Vivado/xsim.
- On hardware, run the production sanity sequence at `NORM`, then a short refresh-selector sweep. In this baseline the selector is logged but MIG still uses its internal refresh timer.
