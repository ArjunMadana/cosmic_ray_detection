# program_board.tcl — Programs the Arty S7-25 via JTAG without opening the Vivado GUI.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/program_board.tcl
#
# Or add a shortcut / batch file that runs that command.

set bitfile [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and generate bitstream first."
    exit 1
}

puts "Programming device with: $bitfile"

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

set device [lindex [get_hw_devices] 0]
if {$device eq ""} {
    puts "ERROR: No JTAG device found. Check USB cable."
    exit 1
}

current_hw_device $device
refresh_hw_device $device

set_property PROGRAM.FILE $bitfile $device
program_hw_devices $device

puts "Done. Board is running new bitstream."
close_hw_target
disconnect_hw_server
