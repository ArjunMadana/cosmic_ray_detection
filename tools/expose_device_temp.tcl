# expose_device_temp.tcl
#
# Exposes the MIG XADC die temperature through the Vivado-generated BD wrapper:
#   device_temp_0  [11:0]  output  — on-chip die temperature from MIG XADC
#
# The MIG IP does not expose device_temp in its BD interface definition, so
# this script edits the two generated Verilog files directly after each
# generate_target call.  It is registered as a pre-synthesis hook in synth_1
# so it runs automatically — you do not need to call it manually.
#
# If you need to run it manually (Vivado TCL console, project open):
#   source {c:/_CAMSIN/cosmic_ray_detection/tools/expose_device_temp.tcl}

# ---------------------------------------------------------------------------
# Locate the generated files
# ---------------------------------------------------------------------------

# Derive project root from the open project — works regardless of Vivado's CWD.
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

# 1. Add device_temp_0 to the module port list
if {![string match "*device_temp_0*" $txt]} {
    regsub {(    init_calib_complete_0,)} $txt \
        "    device_temp_0,\n\\1" txt
    puts "  Added device_temp_0 to port list."
} else {
    puts "  Port list already patched."
}

# 2. Add port direction declaration
# Use string first (exact substring) — string match glob misparses [11:0] as a char class.
if {[string first "output \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  output init_calib_complete_0;)} $txt \
        "  output \[11:0\]device_temp_0;\n\\1" txt
    puts "  Added port declaration."
} else {
    puts "  Port declaration already present."
}

# 3. Add wire for the MIG device_temp signal
if {![string match "*mig_7series_0_device_temp*" $txt]} {
    regsub {(  wire mig_7series_0_init_calib_complete;)} $txt \
        "  wire \[11:0\]mig_7series_0_device_temp;\n\\1" txt
    puts "  Added wire mig_7series_0_device_temp."
} else {
    puts "  Wire already declared."
}

# 4. Assign device_temp_0 from the internal wire
if {![string match "*assign device_temp_0*" $txt]} {
    regsub {(  assign init_calib_complete_0 = mig_7series_0_init_calib_complete;)} $txt \
        "  assign device_temp_0 = mig_7series_0_device_temp;\n\\1" txt
    puts "  Added assign device_temp_0."
} else {
    puts "  Assign already present."
}

# 5. Connect .device_temp in the MIG instantiation
if {![string match "*.device_temp(mig_7series_0_device_temp)*" $txt]} {
    regsub {(        \.sys_clk_i\(clk_wiz_0_clk_out1\))} $txt \
        "        .device_temp(mig_7series_0_device_temp),\n\\1" txt
    puts "  Connected .device_temp in MIG instance."
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

# 1. Add device_temp_0 to the module port list
if {![string match "*device_temp_0*" $txt]} {
    regsub {(    init_calib_complete_0,)} $txt \
        "    device_temp_0,\n\\1" txt
    puts "  Added device_temp_0 to port list."
} else {
    puts "  Port list already patched."
}

# 2. Add port direction declaration
if {[string first "output \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  output init_calib_complete_0;)} $txt \
        "  output \[11:0\]device_temp_0;\n\\1" txt
    puts "  Added port declaration."
} else {
    puts "  Port declaration already present."
}

# 3. Add wire declaration
if {[string first "wire \[11:0\]device_temp_0" $txt] < 0} {
    regsub {(  wire ui_clk_0;)} $txt \
        "\\1\n  wire \[11:0\]device_temp_0;" txt
    puts "  Added wire declaration."
} else {
    puts "  Wire already declared."
}

# 4. Connect .device_temp_0 in the cosmic_bd instantiation
if {![string match "*.device_temp_0(device_temp_0)*" $txt]} {
    regsub {(        \.init_calib_complete_0\(init_calib_complete_0\))} $txt \
        "        .device_temp_0(device_temp_0),\n\\1" txt
    puts "  Connected .device_temp_0 in cosmic_bd instance."
} else {
    puts "  cosmic_bd instance already connected."
}

write_file $wrapper $txt
puts "Wrote $wrapper"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

puts ""
puts "Done. cosmic_bd_wrapper.v now exposes: device_temp_0\[11:0\]"
puts "NOTE: This script re-runs automatically before each synthesis via the"
puts "      STEPS.SYNTH_DESIGN.TCL.PRE hook registered in synth_1."
