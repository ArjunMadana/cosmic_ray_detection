# make_mcs.tcl — Converts bitstream to .mcs for SPI flash programming.
#
# Usage (from the project root):
#   vivado -mode batch -source tools/make_mcs.tcl
#
# After this, use the Vivado Hardware Manager GUI to program the flash:
#   Right-click xc7s25 > Add Configuration Memory Device
#   Part: s25fl128sxxxxxx0-spi-x1_x2_x4
#   MCS:  cosmic_ray_detection.runs/impl_1/cosmic_top.mcs

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
puts "Now program via Hardware Manager GUI (see flash_board.bat for steps)."
