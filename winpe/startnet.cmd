@echo off
wpeinit
powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Deploy-Image.ps1
if errorlevel 1 (
    echo.
    echo Deployment failed. Log: X:\Windows\Temp\Deploy.log
    cmd.exe
)
