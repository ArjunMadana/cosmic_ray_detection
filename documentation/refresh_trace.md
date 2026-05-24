# `ext_refresh_tick` Trace

Last updated: 2026-05-24

The refresh source is controlled by `detector_fsm.refresh_tick_out`, which is selected through the GUI with `R<n>\n`.

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
assign refresh_tick = ext_refresh_tick;
```

The internal MIG refresh timer remains present in generated code, but its tick is not used after the patch. This lets firmware select `OFF`, `SLOW`, `NORM`, or `FAST` through UART.

## Hook

The patch is maintained by:

```text
tools/expose_device_temp.tcl
```

The file name is historical; the script now patches both `device_temp_0` and `ext_refresh_tick`.
