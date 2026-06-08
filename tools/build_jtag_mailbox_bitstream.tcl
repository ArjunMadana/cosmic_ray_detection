# build_jtag_mailbox_bitstream.tcl - Rebuilds the detector bitstream with JTAG mailbox support.

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

source [file normalize "tools/create_jtag_vio_ip.tcl"]
ensure_project_open

source [file normalize "tools/expose_device_temp.tcl"]

puts "Resetting implementation runs for JTAG mailbox build..."
reset_run synth_1
reset_run impl_1

puts "Launching implementation through bitstream..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {[string first "Complete" $synth_status] < 0} {
    puts "ERROR: synth_1 did not complete."
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $status"
if {[string first "Complete" $status] < 0} {
    puts "ERROR: impl_1 did not complete."
    exit 1
}

open_run impl_1
set proj_dir [get_property DIRECTORY [current_project]]
set ltxfile [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.ltx"]
write_debug_probes -force $ltxfile
puts "Wrote debug probes: $ltxfile"
