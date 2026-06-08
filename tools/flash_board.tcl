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

proc open_first_hw_target {} {
    set targets [get_hw_targets]
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
set mcsfile  [file normalize "$proj_dir/cosmic_ray_detection.runs/impl_1/cosmic_top.mcs"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and Generate Bitstream first."
    return
}

puts "Generating .mcs from: $bitfile"

# Arty S7 boards use a 128 Mb = 16 MB Spansion/Cypress Quad-SPI flash.
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bitfile" \
    -file $mcsfile -force

puts "Programming SPI flash with: $mcsfile"
puts "This takes about 2 minutes. Do not unplug the board."

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

set flash_part_patterns {
    {s25fl128sxxxxxx0-spi-x1_x2_x4}
    {s25fl127sxxxxxx0-spi-x1_x2_x4}
}
if {[info exists ::env(FLASH_PART)] && $::env(FLASH_PART) ne ""} {
    set flash_part_patterns [list $::env(FLASH_PART)]
}

set flash_parts {}
set flash_part_pattern ""
foreach pattern $flash_part_patterns {
    set matches [get_cfgmem_parts $pattern]
    if {[llength $matches] > 0} {
        set flash_parts $matches
        set flash_part_pattern $pattern
        break
    }
}

if {[llength $flash_parts] == 0} {
    puts "ERROR: Flash part not found."
    puts "Tried patterns: $flash_part_patterns"
    puts "Run: get_cfgmem_parts {*s25fl*} to find the correct name."
    close_hw_target
    disconnect_hw_server
    return
}

puts "Using cfgmem part pattern: $flash_part_pattern"
puts "Using cfgmem part: [lindex $flash_parts 0]"
create_hw_cfgmem -hw_device $device [lindex $flash_parts 0]
set flash [get_property PROGRAM.HW_CFGMEM $device]
if {$flash eq ""} {
    puts "ERROR: Failed to create SPI flash programming object."
    close_hw_target
    disconnect_hw_server
    return
}

set_property PROGRAM.ADDRESS_RANGE          {use_file}       $flash
set_property PROGRAM.FILES                  [list $mcsfile]  $flash
set_property PROGRAM.PRM_FILE               {}               $flash
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}      $flash
set_property PROGRAM.BLANK_CHECK            0                $flash
set_property PROGRAM.ERASE                  1                $flash
set_property PROGRAM.CFG_PROGRAM            1                $flash
set_property PROGRAM.VERIFY                 1                $flash
set_property PROGRAM.CHECKSUM               0                $flash

set program_result [catch {
    startgroup
    puts "Loading temporary flash programmer bitstream..."
    create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
    program_hw_devices $device
    refresh_hw_device $device

    program_hw_cfgmem -hw_cfgmem $flash
    endgroup
} program_error]

if {$program_result} {
    catch {endgroup}
    puts ""
    puts "ERROR: SPI flash programming failed."
    puts "ERROR: Selected cfgmem part: [lindex $flash_parts 0]"
    puts "If the log shows Mfg ID / Device ID values of 0, the temporary FPGA flash programmer could not read the SPI flash."
    puts "Power-cycle the board, close other Vivado/hw_server sessions, check the Arty S7 JP1 mode jumper, and retry."
    close_hw_target
    disconnect_hw_server
    return -code error $program_error
}

puts ""
puts "Flash programming complete."
puts "Power-cycle the board to boot from flash."
puts "The board will send READY over UART once MIG calibration completes."

close_hw_target
disconnect_hw_server
