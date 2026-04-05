@echo off
echo Generating .mcs from bitstream...
echo Output saved to flash_board.log
echo.
"C:\Xilinx\Vivado\2023.1\bin\vivado.bat" -mode batch -source tools/make_mcs.tcl > flash_board.log 2>&1
echo.
echo MCS generation complete.
echo.
echo ── Next: program via Vivado Hardware Manager ──────────────────────────
echo  1. Open Hardware Manager ^> Open Target ^> Auto Connect
echo  2. Right-click xc7s25 ^> Add Configuration Memory Device
echo  3. Select: s25fl128sxxxxxx0-spi-x1_x2_x4
echo  4. When prompted, set MCS file to:
echo     cosmic_ray_detection.runs\impl_1\cosmic_top.mcs
echo  5. Click OK and wait ~2 minutes
echo ────────────────────────────────────────────────────────────────────────
echo.
pause
