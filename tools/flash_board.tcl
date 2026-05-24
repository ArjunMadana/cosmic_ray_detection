# flash_board.tcl - Writes bitstream to onboard SPI flash on the Arty S7-25.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/flash_board.tcl
#
# After flashing, power-cycle the board. It will auto-load the bitstream from
# flash on subsequent power-ups.

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
set mcsfile  [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.mcs"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and Generate Bitstream first."
    return
}

puts "Generating .mcs from: $bitfile"

# W25Q128JV-compatible 128 Mb = 16 MB quad-SPI configuration image.
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bitfile" \
    -file $mcsfile -force

puts "Programming SPI flash with: $mcsfile"
puts "This takes about 2 minutes. Do not unplug the board."

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

set flash_parts [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}]
if {[llength $flash_parts] == 0} {
    puts "ERROR: Flash part not found. Run: get_cfgmem_parts {w25q128*} to find the correct name."
    close_hw_target
    disconnect_hw_server
    return
}

set flash [create_hw_cfgmem -hw_device $device [lindex $flash_parts 0]]

set_property PROGRAM.ADDRESS_RANGE          {use_file}       $flash
set_property PROGRAM.FILES                  [list $mcsfile]  $flash
set_property PROGRAM.PRM_FILE               {}               $flash
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}      $flash
set_property PROGRAM.BLANK_CHECK            0                $flash
set_property PROGRAM.ERASE                  1                $flash
set_property PROGRAM.CFG_PROGRAM            1                $flash
set_property PROGRAM.VERIFY                 1                $flash
set_property PROGRAM.CHECKSUM               0                $flash

program_hw_cfgmem $flash

puts ""
puts "Flash programming complete."
puts "Power-cycle the board to boot from flash."
puts "The board will send READY over UART once MIG calibration completes."

close_hw_target
disconnect_hw_server
