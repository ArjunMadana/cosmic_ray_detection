# System clock - R2, bank 34, shared with DDR3
set_property PACKAGE_PIN F14 [get_ports sys_clock]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clock]

# Optional top-level reset is currently unused.
#set_property PACKAGE_PIN G15 [get_ports reset]
#set_property IOSTANDARD LVCMOS33 [get_ports reset]

# LEDs - bank 15, LVCMOS33
set_property PACKAGE_PIN E18 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led0]
set_property PACKAGE_PIN F13 [get_ports led1]
set_property IOSTANDARD LVCMOS33 [get_ports led1]

# UART TX - R12, bank 14, LVCMOS33 (FPGA -> host)
set_property PACKAGE_PIN R12 [get_ports uart_txd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_txd]

# UART RX - V12, bank 14, LVCMOS33 (host -> FPGA via FTDI)
set_property PACKAGE_PIN V12 [get_ports uart_rxd]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rxd]
set_property PULLUP true [get_ports uart_rxd]

set_property INTERNAL_VREF 0.675 [get_iobanks 34]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets u_bd/cosmic_bd_i/clk_wiz_0/inst/clk_in1_cosmic_bd_clk_wiz_0_0]

set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
