@echo off
echo Programming SPI flash from the current bitstream...
echo Output saved to flash_board.log
echo.
"C:\Xilinx\Vivado\2023.1\bin\vivado.bat" -mode batch -source tools/flash_board.tcl > flash_board.log 2>&1
echo.
if errorlevel 1 (
    echo Flash script failed. Check flash_board.log for the Vivado error.
) else (
    echo Flash programming completed. Check flash_board.log for details.
    echo Power-cycle the board after a successful flash.
)
echo.
pause
