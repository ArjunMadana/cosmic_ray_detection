@echo off
cd /d "%~dp0"
"C:\Xilinx\Vivado\2023.1\bin\vivado.bat" -mode batch -source tools/build_jtag_mailbox_bitstream.tcl
