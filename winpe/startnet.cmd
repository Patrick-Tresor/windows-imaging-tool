@echo off
wpeinit

rem Capture media (built by the console's capture wizard) carries capture.json; deploy media does not.
if exist X:\Deploy\config\capture.json (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Capture-GoldenImage.ps1 -ConfigPath X:\Deploy\config\capture.json
    if errorlevel 1 (
        echo.
        echo Capture failed. Log: X:\Windows\Temp\Deploy.log
        cmd.exe
    )
    goto :eof
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\Deploy\Deploy-Image.ps1
if errorlevel 1 (
    echo.
    echo Deployment failed. Log: X:\Windows\Temp\Deploy.log
    cmd.exe
)
