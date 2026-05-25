# `ext_refresh_tick` Trace

Last updated: 2026-05-25

Production baseline note: `detector_fsm.refresh_tick_out` is still routed through the generated hierarchy, but MIG `rank_common` uses its internal `refresh_tick_lcl`. `R<n>\n` is accepted/logged and does not control MIG refresh in this baseline.

## Signal Path

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

## Final MIG Patch

In `mig_7series_v4_2_rank_common.v`:

```verilog
input ext_refresh_tick;
output wire refresh_tick;
assign refresh_tick = refresh_tick_lcl;
```

The internal MIG refresh timer is intentionally used in this baseline while normal experiment correctness and the graphing interface are stabilized.

## Hook

The patch is maintained by:

```text
tools/expose_device_temp.tcl
```

The file name is historical; the script now patches `device_temp_0` and preserves `ext_refresh_tick` routing while leaving MIG refresh internal for the baseline build.
