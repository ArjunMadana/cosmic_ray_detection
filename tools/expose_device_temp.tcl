# generated_bd_patch.tcl
#
# Vivado pre-synthesis hook for generated files under cosmic_bd.
#
# Patches generated Verilog after block-design generation so the top-level
# design can use MIG-internal signals that are not exposed by the BD:
#   device_temp_0[11:0]  - MIG XADC die temperature output
#
# Baseline mode, 2026-05-25:
#   ext_refresh_tick is still plumbed through the generated hierarchy so
#   cosmic_top does not need a structural change, but rank_common uses MIG's
#   internal refresh_tick_lcl. This isolates the write/verify bug from the
#   custom refresh override.
#
# This file keeps the historical name because cosmic_ray_detection.xpr already
# points its synth_1 pre-hook at tools/expose_device_temp.tcl.

proc ensure_project_open {} {
    if {[catch {current_project}]} {
        set xpr [file normalize "cosmic_ray_detection.xpr"]
        if {![file exists $xpr]} {
            puts "ERROR: No project is open and cosmic_ray_detection.xpr was not found."
            return -code error
        }
        open_project $xpr
    }
}

proc read_file {path} {
    set fh [open $path r]
    set content [read $fh]
    close $fh
    return $content
}

proc write_file {path content} {
    set fh [open $path w]
    puts -nonewline $fh $content
    close $fh
}

proc replace_once {var_name old new label} {
    upvar $var_name txt
    if {[string first $new $txt] >= 0} {
        puts "  $label already patched."
        return
    }
    set pos [string first $old $txt]
    if {$pos < 0} {
        puts "WARNING: Could not find patch anchor for $label."
        return
    }
    set txt [string replace $txt $pos [expr {$pos + [string length $old] - 1}] $new]
    puts "  Patched $label."
}

proc replace_once_if_missing {var_name guard old new label} {
    upvar $var_name txt
    if {[string first $guard $txt] >= 0} {
        puts "  $label already patched."
        return
    }
    replace_once txt $old $new $label
}

proc force_replace {var_name old new label} {
    upvar $var_name txt
    set pos [string first $old $txt]
    if {$pos < 0} {
        if {[string first $new $txt] >= 0} {
            puts "  $label already set."
        } else {
            puts "WARNING: Could not find patch anchor for $label."
        }
        return
    }
    set txt [string replace $txt $pos [expr {$pos + [string length $old] - 1}] $new]
    puts "  Patched $label."
}

proc patch_file {path script_body} {
    if {![file exists $path]} {
        puts "ERROR: File not found: $path"
        return
    }
    puts ""
    puts "Patching $path ..."
    set txt [read_file $path]
    eval $script_body
    write_file $path $txt
}

if {[catch {ensure_project_open}]} {
    return
}

set script_dir [file dirname [file normalize [info script]]]
set proj_dir    [file dirname $script_dir]
set bd_root     [file normalize "$proj_dir/cosmic_ray_detection.gen/sources_1/bd/cosmic_bd"]
set synth_v  "$bd_root/synth/cosmic_bd.v"
set wrapper  "$bd_root/hdl/cosmic_bd_wrapper.v"
set mig_root "$bd_root/ip/cosmic_bd_mig_7series_0_2/cosmic_bd_mig_7series_0_2/user_design/rtl"

set mig_top     "$mig_root/cosmic_bd_mig_7series_0_2.v"
set mig_core    "$mig_root/cosmic_bd_mig_7series_0_2_mig.v"
set memc_top    "$mig_root/ip_top/mig_7series_v4_2_memc_ui_top_axi.v"
set mem_intfc   "$mig_root/ip_top/mig_7series_v4_2_mem_intfc.v"
set mc          "$mig_root/controller/mig_7series_v4_2_mc.v"
set rank_mach   "$mig_root/controller/mig_7series_v4_2_rank_mach.v"
set rank_common "$mig_root/controller/mig_7series_v4_2_rank_common.v"

patch_file $synth_v {
    replace_once txt "    init_calib_complete_0," \
        "    device_temp_0,\n    init_calib_complete_0," \
        "cosmic_bd device_temp_0 port"
    replace_once txt "  output init_calib_complete_0;" \
        "  output [11:0]device_temp_0;\n  output init_calib_complete_0;" \
        "cosmic_bd device_temp_0 declaration"
    replace_once txt "  wire mig_7series_0_init_calib_complete;" \
        "  wire [11:0]mig_7series_0_device_temp;\n  wire mig_7series_0_init_calib_complete;" \
        "cosmic_bd device_temp wire"
    replace_once txt "  assign init_calib_complete_0 = mig_7series_0_init_calib_complete;" \
        "  assign device_temp_0 = mig_7series_0_device_temp;\n  assign init_calib_complete_0 = mig_7series_0_init_calib_complete;" \
        "cosmic_bd device_temp assign"
    replace_once txt "        .sys_clk_i(clk_wiz_0_clk_out1)," \
        "        .device_temp(mig_7series_0_device_temp),\n        .sys_clk_i(clk_wiz_0_clk_out1)," \
        "cosmic_bd MIG device_temp connection"
    replace_once txt "    device_temp_0,\n    init_calib_complete_0," \
        "    device_temp_0,\n    ext_refresh_tick,\n    init_calib_complete_0," \
        "cosmic_bd ext_refresh_tick port"
    replace_once txt "  output [11:0]device_temp_0;\n  output init_calib_complete_0;" \
        "  output [11:0]device_temp_0;\n  input ext_refresh_tick;\n  output init_calib_complete_0;" \
        "cosmic_bd ext_refresh_tick declaration"
    replace_once txt "        .device_temp(mig_7series_0_device_temp),\n        .sys_clk_i(clk_wiz_0_clk_out1)," \
        "        .device_temp(mig_7series_0_device_temp),\n        .ext_refresh_tick(ext_refresh_tick),\n        .sys_clk_i(clk_wiz_0_clk_out1)," \
        "cosmic_bd MIG ext_refresh_tick connection"
}

patch_file $wrapper {
    replace_once txt "    init_calib_complete_0," \
        "    device_temp_0,\n    init_calib_complete_0," \
        "wrapper device_temp_0 port"
    replace_once txt "  output init_calib_complete_0;" \
        "  output [11:0]device_temp_0;\n  output init_calib_complete_0;" \
        "wrapper device_temp_0 declaration"
    replace_once_if_missing txt "  wire [11:0]device_temp_0;" "  wire ui_clk_0;" \
        "  wire ui_clk_0;\n  wire [11:0]device_temp_0;" \
        "wrapper device_temp wire"
    replace_once txt "        .init_calib_complete_0(init_calib_complete_0)," \
        "        .device_temp_0(device_temp_0),\n        .init_calib_complete_0(init_calib_complete_0)," \
        "wrapper cosmic_bd device_temp connection"
    replace_once txt "    device_temp_0,\n    init_calib_complete_0," \
        "    device_temp_0,\n    ext_refresh_tick,\n    init_calib_complete_0," \
        "wrapper ext_refresh_tick port"
    replace_once txt "  output [11:0]device_temp_0;\n  output init_calib_complete_0;" \
        "  output [11:0]device_temp_0;\n  input ext_refresh_tick;\n  output init_calib_complete_0;" \
        "wrapper ext_refresh_tick declaration"
    replace_once_if_missing txt "  wire ext_refresh_tick;" "  wire ui_clk_0;" \
        "  wire ui_clk_0;\n  wire ext_refresh_tick;" \
        "wrapper ext_refresh_tick wire"
    replace_once txt "        .device_temp_0(device_temp_0),\n        .init_calib_complete_0(init_calib_complete_0)," \
        "        .device_temp_0(device_temp_0),\n        .ext_refresh_tick(ext_refresh_tick),\n        .init_calib_complete_0(init_calib_complete_0)," \
        "wrapper cosmic_bd ext_refresh_tick connection"
}

patch_file $mig_top {
    if {[string first "input         ext_refresh_tick" $txt] >= 0 ||
        [string first "input wire    ext_refresh_tick" $txt] >= 0 ||
        [string first "input ext_refresh_tick" $txt] >= 0} {
        puts "  MIG top ext_refresh_tick input already patched."
    } elseif {[string first "  input         sys_clk_i," $txt] >= 0} {
        replace_once txt "  input         sys_clk_i," \
            "  input         sys_clk_i,\n  input         ext_refresh_tick," \
            "MIG top ext_refresh_tick input"
    } elseif {[string first "  input wire    sys_clk_i," $txt] >= 0} {
        replace_once txt "  input wire    sys_clk_i," \
            "  input wire    sys_clk_i,\n  input wire    ext_refresh_tick," \
            "MIG top ext_refresh_tick input"
    } elseif {[string first "  input sys_clk_i," $txt] >= 0} {
        replace_once txt "  input sys_clk_i," \
            "  input sys_clk_i,\n  input ext_refresh_tick," \
            "MIG top ext_refresh_tick input"
    } else {
        puts "ERROR: Could not patch MIG top ext_refresh_tick input. Inspect $mig_top around sys_clk_i."
        return -code error
    }

    replace_once_if_missing txt "    .ext_refresh_tick               (ext_refresh_tick)," \
        "    .ui_clk                         (ui_clk)," \
        "    .ext_refresh_tick               (ext_refresh_tick),\n    .ui_clk                         (ui_clk)," \
        "MIG top core ext_refresh_tick connection"
}

patch_file $mig_core {
    replace_once txt "   input                                        sys_clk_i," \
        "   input                                        sys_clk_i,\n   input                                        ext_refresh_tick," \
        "MIG core ext_refresh_tick input"
    replace_once txt "       .clk                              (clk)," \
        "       .ext_refresh_tick                 (ext_refresh_tick),\n       .clk                              (clk)," \
        "MIG core memc ext_refresh_tick connection"
}

patch_file $memc_top {
    replace_once txt "   input                              clk,\n   input                              clk_div2," \
        "   input                              clk,\n   input                              ext_refresh_tick,\n   input                              clk_div2," \
        "memc ext_refresh_tick input"
    replace_once txt "      .clk                              (clk)," \
        "      .ext_refresh_tick                 (ext_refresh_tick),\n      .clk                              (clk)," \
        "memc mem_intfc ext_refresh_tick connection"
}

patch_file $mem_intfc {
    replace_once txt "   input                  clk ,\n   input                  clk_div2," \
        "   input                  clk ,\n   input                  ext_refresh_tick,\n   input                  clk_div2," \
        "mem_intfc ext_refresh_tick input"
    replace_once txt "      .clk                    (clk)," \
        "      .ext_refresh_tick       (ext_refresh_tick),\n      .clk                    (clk)," \
        "mem_intfc mc ext_refresh_tick connection"
}

patch_file $mc {
    replace_once txt "    input                                     clk,\n    input                                     rst," \
        "    input                                     clk,\n    input                                     rst,\n    input                                     ext_refresh_tick," \
        "mc ext_refresh_tick input"
    replace_once txt "        .clk                  (clk)," \
        "        .ext_refresh_tick     (ext_refresh_tick),\n        .clk                  (clk)," \
        "mc rank_mach ext_refresh_tick connection"
}

patch_file $rank_mach {
    replace_once txt "  app_sr_req, app_ref_req, app_periodic_rd_req, act_this_rank_r" \
        "  app_sr_req, app_ref_req, app_periodic_rd_req, act_this_rank_r,\n  ext_refresh_tick" \
        "rank_mach AUTOARG ext_refresh_tick"
    replace_once txt "  input                 clk;" \
        "  input                 clk;\n  input                 ext_refresh_tick;" \
        "rank_mach ext_refresh_tick input"
    replace_once txt "     .maint_prescaler_tick_r            (maint_prescaler_tick_r)," \
        "     .ext_refresh_tick                 (ext_refresh_tick),\n     .maint_prescaler_tick_r            (maint_prescaler_tick_r)," \
        "rank_mach rank_common ext_refresh_tick connection"
}

patch_file $rank_common {
    replace_once txt "  periodic_rd_request, periodic_rd_ack_r" \
        "  periodic_rd_request, periodic_rd_ack_r, ext_refresh_tick" \
        "rank_common AUTOARG ext_refresh_tick"
    replace_once txt "  input rst;" \
        "  input rst;\n  input ext_refresh_tick;" \
        "rank_common ext_refresh_tick input"
    force_replace txt "  assign refresh_tick = refresh_tick_lcl;" \
        "  assign refresh_tick = ext_refresh_tick;" \
        "rank_common external refresh override"
}

puts ""
puts "Done. Generated BD exposes device_temp_0[11:0]."
puts "Retention mode: ext_refresh_tick drives MIG rank_common refresh_tick."