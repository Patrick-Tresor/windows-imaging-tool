@echo off
rem Double-click to open the imaging console. It asks for admin rights.
rem start: this window closes at once, and PowerShell runs with its console window hidden, so only the console shows.
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0src\Console\ImagingConsole.ps1" -HideConsole
