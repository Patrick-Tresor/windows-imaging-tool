@echo off
rem Double-click to open the imaging console. It asks for admin rights.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0src\Console\ImagingConsole.ps1"
