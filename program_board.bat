@echo off
cd /d "%~dp0"
vivado -mode batch -source tools/program_board.tcl
pause
