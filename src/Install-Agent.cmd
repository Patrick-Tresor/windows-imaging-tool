@echo off
rem Installs the imaging agent on this PC, for a PC the console cannot reach.
rem Right-click this file, then Run as administrator. It runs Install-AgentHere.ps1 from the same folder.
net session >nul 2>&1
if errorlevel 1 (
    echo Run this as administrator: right-click Install-Agent.cmd, then Run as administrator.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AgentHere.ps1"
pause
