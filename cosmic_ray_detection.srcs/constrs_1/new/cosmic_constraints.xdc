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

# UART text formatting is slow-control logic.  The FSM waits two UI clocks
# after changing the print selector/index before capturing uart_data, and the
# UART transmitter then keeps ready low for an entire byte time.
set uart_print_sources [get_cells -hier -quiet -regexp {.*u_fsm/(print_idx|print_kind)_reg.*}]
set uart_print_dests   [get_cells -hier -quiet -regexp {.*u_fsm/uart_data_reg.*}]
if {[llength $uart_print_sources] > 0 && [llength $uart_print_dests] > 0} {
    set_multicycle_path -setup 2 -from $uart_print_sources -to $uart_print_dests
    set_multicycle_path -hold 1 -from $uart_print_sources -to $uart_print_dests
}

set uart_print_end_sources [get_cells -hier -quiet -regexp {.*u_fsm/(print_idx|print_len)_reg.*}]
set uart_print_end_dests   [get_cells -hier -quiet -regexp {.*u_fsm/state_reg.*}]
if {[llength $uart_print_end_sources] > 0 && [llength $uart_print_end_dests] > 0} {
    set_multicycle_path -setup 2 -from $uart_print_end_sources -to $uart_print_end_dests
    set_multicycle_path -hold 1 -from $uart_print_end_sources -to $uart_print_end_dests
}
