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

proc open_first_hw_target {} {
    set targets {}
    for {set attempt 0} {$attempt < 5} {incr attempt} {
        catch {refresh_hw_server}
        after 1000
        if {[catch {set targets [get_hw_targets]}]} {
            set targets {}
        }
        if {[llength $targets] != 0} {
            break
        }
        puts "Waiting for hardware target..."
    }
    if {[llength $targets] == 0} {
        puts "ERROR: No hardware targets reported by hw_server."
        puts "Check that the board is powered, the USB cable is connected, and Windows has finished enumerating the Digilent device."
        disconnect_hw_server
        return -code error
    }

    set target [lindex $targets 0]
    puts "Opening hw_target: $target"
    open_hw_target $target
}

if {[catch {ensure_project_open}]} {
    return
}

set proj_dir [get_property DIRECTORY [current_project]]
set bitfile  [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]
set ltxfile  [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.ltx"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and generate bitstream first."
    return
}

puts "Programming device with: $bitfile"

open_hw_manager
connect_hw_server -allow_non_jtag
open_first_hw_target

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
if {[file exists $ltxfile]} {
    puts "Using debug probes file: $ltxfile"
    set_property PROBES.FILE $ltxfile $device
}
set_property BSCAN_SWITCH_USER_MASK 1 $device
program_hw_devices $device

puts "Done. Board is running new bitstream."
close_hw_target
disconnect_hw_server
