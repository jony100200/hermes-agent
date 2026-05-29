@echo off
:: Change directory to the folder containing this batch file
cd /d "%~dp0"
call "desktop-ui\launcher\launch-hermes-ui.bat" %*
