# make_mcs.tcl - Converts bitstream to .mcs for SPI flash programming.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/make_mcs.tcl
#
# This only creates the image. To generate and program flash in one batch run,
# use tools/flash_board.tcl or flash_board.bat.

set bitfile [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.bit"]
set mcsfile [file normalize "cosmic_ray_detection.runs/impl_1/cosmic_top.mcs"]

if {![file exists $bitfile]} {
    puts "ERROR: Bitfile not found: $bitfile"
    puts "Run implementation and Generate Bitstream first."
    exit 1
}

puts "Generating .mcs from: $bitfile"

write_cfgmem -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bitfile" \
    -file $mcsfile -force

puts ""
puts "MCS written to: $mcsfile"
puts "To program flash in batch mode, run: vivado -mode batch -source tools/flash_board.tcl"
