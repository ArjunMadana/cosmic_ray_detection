# program_board.tcl - Programs the Arty S7-25 via JTAG without opening the Vivado GUI.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/program_board.tcl

proc ensure_project_open {} {
    if {[catch {current_project}]} {
        set xpr [file normalize "cosmic_ray_detection.xpr"]
        if {![file exists $xpr]} {
            puts "ERROR: No project is open and cosmic_ray_detection.xpr was not found."
            puts "Run this script from the project root, or open the project first."
            return -code error
        }
        open_project $xpr
    }
}

if {[catch {ensure_project_open}]} {
    return
}

set proj_dir [get_property DIRECTORY [current_project]]
set bitfile  [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and generate bitstream first."
    return
}

puts "Programming device with: $bitfile"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices] 0]
if {$device eq ""} {
    puts "ERROR: No JTAG device found. Check USB cable."
    close_hw_target
    disconnect_hw_server
    return
}

current_hw_device $device
refresh_hw_device $device

set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device

puts "Done. Board is running new bitstream."
close_hw_target
disconnect_hw_server
