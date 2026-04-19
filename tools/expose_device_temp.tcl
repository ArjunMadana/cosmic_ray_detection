# expose_device_temp.tcl
#
# Threads two signals through the Vivado-generated block design wrapper:
#   device_temp_0  [11:0] output  — on-chip die temperature from MIG XADC
#   ext_refresh_tick       input  — external DRAM refresh tick from FSM
#
# These ports are not accessible via the BD GUI or make_bd_pins_external
# because the MIG IP does not expose them in its BD interface definition.
# This script edits the generated Verilog files directly instead.
#
# MUST BE RE-RUN whenever you call "generate_target" or "make_wrapper" on
# the cosmic_bd block design, as those commands overwrite the edited files.
#
# Usage (Vivado TCL console, project open):
#   source {c:/_CAMSIN/cosmic_ray_detection/tools/expose_device_temp.tcl}
#
# Usage (batch, from project root):
#   vivado -mode batch -source tools/expose_device_temp.tcl

# ---------------------------------------------------------------------------
# Locate the generated files
# ---------------------------------------------------------------------------

# Derive project root from the open project, so this works regardless of
# Vivado's current working directory (which defaults to AppData, not the project).
set proj_dir [get_property DIRECTORY [current_project]]
set bd_root  [file normalize "$proj_dir/cosmic_ray_detection.gen/sources_1/bd/cosmic_bd"]
set synth_v  "$bd_root/synth/cosmic_bd.v"
set wrapper  "$bd_root/hdl/cosmic_bd_wrapper.v"

foreach f [list $synth_v $wrapper] {
    if {![file exists $f]} {
        puts "ERROR: File not found: $f"
        puts "Run 'generate_target all \[get_files cosmic_bd.bd\]' in Vivado first."
        return
    }
}

# ---------------------------------------------------------------------------
# Helper: read / write file
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Patch cosmic_bd.v (synthesis netlist)
# ---------------------------------------------------------------------------

puts "Patching $synth_v ..."
set txt [read_file $synth_v]

# 1. Add ports to the module port list (after init_calib_complete_0)
if {![string match "*device_temp_0*" $txt]} {
    regsub {(    init_calib_complete_0,)} $txt \
        "    device_temp_0,\n    ext_refresh_tick,\n\\1" txt
    puts "  Added device_temp_0 and ext_refresh_tick to port list."
} else {
    puts "  Port list already patched."
}

# 2. Add port direction declarations (after the last S00_AXI wvalid line)
# Use string first (exact substring) not string match (glob) — glob misparses [11:0] as a char class.
if {[string first "output \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  output init_calib_complete_0;)} $txt \
        "  output \[11:0\]device_temp_0;\n  input ext_refresh_tick;\n\\1" txt
    puts "  Added port declarations."
} else {
    puts "  Port declarations already present."
}

# 3. Add wire declaration for MIG device_temp signal
if {![string match "*mig_7series_0_device_temp*" $txt]} {
    regsub {(  wire mig_7series_0_init_calib_complete;)} $txt \
        "  wire \[11:0\]mig_7series_0_device_temp;\n\\1" txt
    puts "  Added wire mig_7series_0_device_temp."
} else {
    puts "  Wire already declared."
}

# 4. Add assign for device_temp_0 output
if {![string match "*assign device_temp_0*" $txt]} {
    regsub {(  assign init_calib_complete_0 = mig_7series_0_init_calib_complete;)} $txt \
        "  assign device_temp_0 = mig_7series_0_device_temp;\n\\1" txt
    puts "  Added assign device_temp_0."
} else {
    puts "  Assign already present."
}

# 5. Connect ports in MIG instantiation (before sys_clk_i)
if {![string match "*.device_temp(mig_7series_0_device_temp)*" $txt]} {
    regsub {(        \.sys_clk_i\(clk_wiz_0_clk_out1\))} $txt \
        "        .device_temp(mig_7series_0_device_temp),\n        .ext_refresh_tick(ext_refresh_tick),\n\\1" txt
    puts "  Connected device_temp and ext_refresh_tick in MIG instance."
} else {
    puts "  MIG instance already connected."
}

write_file $synth_v $txt
puts "Wrote $synth_v"

# ---------------------------------------------------------------------------
# Patch cosmic_bd_wrapper.v
# ---------------------------------------------------------------------------

puts "\nPatching $wrapper ..."
set txt [read_file $wrapper]

# 1. Add to port list
if {![string match "*device_temp_0*" $txt]} {
    regsub {(    init_calib_complete_0,)} $txt \
        "    device_temp_0,\n    ext_refresh_tick,\n\\1" txt
    puts "  Added device_temp_0 and ext_refresh_tick to port list."
} else {
    puts "  Port list already patched."
}

# 2. Add port direction declarations
if {[string first "output \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  output init_calib_complete_0;)} $txt \
        "  output \[11:0\]device_temp_0;\n  input ext_refresh_tick;\n\\1" txt
    puts "  Added port declarations."
} else {
    puts "  Port declarations already present."
}

# 3. Add wire declarations (after the existing 'wire ui_clk_0;' line)
if {[string first "wire \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  wire ui_clk_0;)} $txt \
        "\\1\n  wire \[11:0\]device_temp_0;\n  wire ext_refresh_tick;" txt
    puts "  Added wire declarations."
} else {
    puts "  Wires already declared."
}

# 4. Connect in cosmic_bd instantiation (before .init_calib_complete_0)
if {![string match "*.device_temp_0(device_temp_0)*" $txt]} {
    regsub {(        \.init_calib_complete_0\(init_calib_complete_0\))} $txt \
        "        .device_temp_0(device_temp_0),\n        .ext_refresh_tick(ext_refresh_tick),\n\\1" txt
    puts "  Connected ports in cosmic_bd instance."
} else {
    puts "  cosmic_bd instance already connected."
}

write_file $wrapper $txt
puts "Wrote $wrapper"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

puts ""
puts "Done. Both generated files are patched."
puts "cosmic_bd_wrapper.v now exposes: device_temp_0\[11:0\] and ext_refresh_tick"
puts ""
puts "NOTE: Re-run this script if you ever call generate_target or make_wrapper"
puts "      on the cosmic_bd block design."
