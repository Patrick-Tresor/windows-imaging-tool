@echo off
wpeinit

powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Deploy-Image.ps1
rem 3: the WinPE password was not given; the PC is shutting down, so no command prompt.
if errorlevel 3 goto :eof
if errorlevel 1 (
    echo.
    echo Deployment failed. Log: X:\Windows\Temp\Deploy.log
    cmd.exe
)
