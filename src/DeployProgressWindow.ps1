<#
.SYNOPSIS
    The progress window on the screen of a PC being deployed. Deploy-Image.ps1 starts it in its own process.
.DESCRIPTION
    Shows hardware, what is being deployed, the current step and a progress bar, the end of the log, then the
    result with Restart, Shut down, View log and Command prompt. See DeployProgress.psm1.
.EXAMPLE
    powershell.exe -STA -WindowStyle Hidden -File X:\Deploy\DeployProgressWindow.ps1 -ProgressPath X:\Windows\Temp\DeployProgress.json -DeployProcessId 1234
#>
param(
    [Parameter(Mandatory)][string]$ProgressPath,
    [string]$LogPath = 'X:\Windows\Temp\Deploy.log',
    [int]$DeployProcessId
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployProgress.psm1') -Force
Show-DeployProgressWindow -ProgressPath $ProgressPath -LogPath $LogPath -DeployProcessId $DeployProcessId
