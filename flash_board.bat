@echo off
echo Flashing bitstream to SPI flash on Arty S7-25...
echo This takes ~2 minutes. Do not unplug the board.
echo Output is also saved to flash_board.log
echo.
"C:\Xilinx\Vivado\2023.1\bin\vivado.bat" -mode batch -source tools/flash_board.tcl > flash_board.log 2>&1
echo.
echo Done. See flash_board.log for full output.
pause
