# flash_board.tcl — Writes bitstream to onboard SPI flash (W25Q128JV) on Arty S7-25.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/flash_board.tcl
#
# Only needed after a firmware rebuild.  For rapid dev iteration, use
# program_board.tcl (volatile JTAG) instead — it's faster but lost on power cycle.
#
# After flashing, power-cycle the board.  It will auto-load the bitstream
# from flash on every subsequent power-up without needing JTAG.

set bitfile [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]
set mcsfile [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.mcs"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and Generate Bitstream first."
    exit 1
}

puts "Generating .mcs from: $bitfile"

# W25Q128JV is 128 Mb = 16 MB, quad SPI
write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bitfile" \
    -file $mcsfile -force

puts "Programming SPI flash with: $mcsfile"
puts "(This takes ~2 minutes — do not unplug the board)"

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

# Get or create the SPI flash cfgmem object
# The Arty S7-25 uses a Winbond W25Q128JV (compatible with s25fl128sxxxxxx0)
set flash_parts [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}]
if {[llength $flash_parts] == 0} {
    puts "ERROR: Flash part s25fl128sxxxxxx0 not found in Vivado library."
    puts "Try: get_cfgmem_parts {w25q128*} in Vivado Tcl console to find the correct part name."
    exit 1
}

set flash [create_hw_cfgmem -hw_device $device [lindex $flash_parts 0]]

# PROGRAM.ADDRESS_RANGE and PROGRAM.FILES (as a list) are required by Vivado 2023.1.
# BLANK_CHECK 0: skip blank check — flash already has previous bitstream.
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
puts "The board will send READY over UART once MIG calibration completes (~5 seconds)."

close_hw_target
disconnect_hw_server
