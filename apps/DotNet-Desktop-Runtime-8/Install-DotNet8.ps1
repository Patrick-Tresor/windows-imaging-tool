<#
.SYNOPSIS
    Downloads the latest .NET 8 Desktop Runtime (x64) from Microsoft and installs it silently.
.DESCRIPTION
    Runs at first boot as SYSTEM (FirstBoot.ps1, from this application's folder). Dell Command | Update 5 needs it.
    The download is Microsoft's link to the newest .NET 8 Desktop Runtime installer, so no installer is kept here.
    Offline: put windowsdesktop-runtime-8.*-win-x64.exe in this folder and that file is used instead.
    Log: C:\Windows\Temp\DotNet8-install.log (this script) and DotNet8-setup.log (the installer).
    Exit code: the installer's (0, or 3010 when a restart is needed), or 1 when nothing could be downloaded.
#>
$ErrorActionPreference = 'Stop'
$url = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'
$log = "$env:WINDIR\Temp\DotNet8-install.log"
function Write-Log([string]$Message) { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) }

$installer = Get-ChildItem -Path $PSScriptRoot -Filter 'windowsdesktop-runtime-8.*-win-x64.exe' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
if ($installer) {
    Write-Log "Using $installer from the application folder"
} else {
    $installer = Join-Path $env:WINDIR 'Temp\windowsdesktop-runtime-8-win-x64.exe'
    # Windows PowerShell 5.1 does not always offer TLS 1.2 on its own.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    # The network can take a minute after setup: try for about five minutes.
    $done = $false
    for ($i = 1; $i -le 10 -and -not $done; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
            $done = $true
            Write-Log "Downloaded $url ($([Math]::Round((Get-Item $installer).Length / 1MB, 1)) MB)"
        } catch {
            Write-Log "Download attempt $i failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 30
        }
    }
    if (-not $done) { Write-Log "Could not download $url; .NET 8 not installed"; exit 1 }
}

$setupLog = "$env:WINDIR\Temp\DotNet8-setup.log"
$p = Start-Process -FilePath $installer -ArgumentList "/install /quiet /norestart /log `"$setupLog`"" -Wait -PassThru
Write-Log "Installer exit $($p.ExitCode)"
if ($installer -like "$env:WINDIR\Temp\*") { Remove-Item $installer -Force -ErrorAction SilentlyContinue }
exit $p.ExitCode
