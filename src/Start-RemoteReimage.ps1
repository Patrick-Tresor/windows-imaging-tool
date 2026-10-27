<#
.SYNOPSIS
    Reimages PCs remotely: queues a job for each, wakes the ones that are off, and restarts the running
    ones into a one-time network (PXE) boot. Waits until each PC has started its deploy.
.DESCRIPTION
    Run from the console's Remote Reimage tab, or by hand on an admin PC. For each PC:
      1. Writes Reimage\<MAC>.json on the content root. Deploy-Image.ps1 in WinPE takes it, uses its answer
         file without asking (after the answer file's countdown) and deletes it.
      2. Optionally prestages the PC in WDS with no F12 prompt, and removes that once the deploy starts.
      3. PC running Windows (WinRM answers): sets the firmware's next boot to the network entry with
         bcdedit and restarts it.
         PC off: sends Wake-on-LAN. If the PC boots from the network first it goes straight to WinPE;
         if it starts Windows instead, it is restarted into PXE as soon as WinRM answers.
    Needs admin rights on the PCs over PowerShell remoting, and on the WDS server for the no-prompt step.
    Writes Logs\REIMAGE_<time>_<OK|FAILED>.log on the content root.
.EXAMPLE
    .\src\Start-RemoteReimage.ps1 -ContentRoot \\server\Deploy -Mac 00155D0A1B2C,00155D0A1B2D -AnswerFile Lab-W11 -KeepNames -SkipPxePrompt
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContentRoot,
    [Parameter(Mandatory)][string[]]$Mac,
    [Parameter(Mandatory)][string]$AnswerFile,
    [switch]$KeepNames,             # each PC keeps the name it has in the computer list
    [switch]$SkipPxePrompt,         # prestage the PCs in WDS so they boot without F12
    [int]$RestartDelay = 60,        # seconds of warning for anyone logged on
    [int]$TimeoutMinutes = 20,      # how long to wait for each PC to start its deploy
    [int]$ExpiresHours = 12
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
# From the console (powershell -File) a list arrives as one comma-separated string.
$Mac = @($Mac | ForEach-Object { $_ -split ',' } | ForEach-Object Trim | Where-Object { $_ })

$started = Get-Date
$logDir = Join-Path $ContentRoot 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $env:TEMP ("REIMAGE_{0:yyyyMMdd-HHmm}.log" -f $started)
function Write-Log([string]$Message, [string]$Color = 'Gray') {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line
    Write-Host $line -ForegroundColor $Color
}

$settings = Get-Content -Raw (Join-Path $ContentRoot 'config\deploy-settings.json') | ConvertFrom-Json
$wdsServer = Get-WdsServerName $settings
$wakePort = if ($settings.remote -and $settings.remote.wakePort) { [int]$settings.remote.wakePort } else { 9 }

# One state object per PC; the loop below moves each one to Started or Failed.
$pcs = foreach ($m in $Mac) {
    $pc = Get-KnownComputer -ContentRoot $ContentRoot -Mac $m
    if (-not $pc) { Write-Log "Unknown PC ${m}: add it on the Remote Reimage tab first." 'Red'; continue }
    [pscustomobject]@{
        Pc = $pc; Name = $pc.name; Address = $(if ($pc.address) { $pc.address } else { $pc.name })
        State = 'Queued'; Detail = ''; Restarted = $false; LastWake = [datetime]::MinValue; Prestaged = $false
    }
}
$pcs = @($pcs)
Write-Log "Reimaging $($pcs.Count) PC(s) with answer file $AnswerFile" 'Cyan'

foreach ($p in $pcs) {
    try {
        $job = New-ReimageJob -ContentRoot $ContentRoot -Mac $p.Pc.mac -AnswerFile $AnswerFile `
            -ComputerName $(if ($KeepNames) { $p.Name } else { '' }) -ExpiresHours $ExpiresHours
        Write-Log "$($p.Name): job queued until $($job.expiresAt)"
    } catch { $p.State = 'Failed'; $p.Detail = $_.Exception.Message; Write-Log "$($p.Name): $($p.Detail)" 'Red'; continue }

    if ($SkipPxePrompt) {
        try {
            Set-WdsNoPrompt -Server $wdsServer -Mac $p.Pc.mac -Name $p.Name
            $p.Prestaged = $true
            Write-Log "$($p.Name): prestaged in WDS$(if ($wdsServer) { " on $wdsServer" }) with no F12 prompt"
        } catch { Write-Log "$($p.Name): could not prestage in WDS, someone may need to press F12: $($_.Exception.Message)" 'Yellow' }
    }
}

function Start-PxeBoot($p) {
    try {
        $r = Invoke-PxeRestart -ComputerName $p.Address -DelaySeconds $RestartDelay
        [void](Update-KnownComputerFromInfo -ContentRoot $ContentRoot -Info $r.Info -Existing $p.Pc)
        $p.Restarted = $true; $p.State = 'Restarting'
        Write-Log "$($p.Name): next boot set to network entry $($r.BootEntry); restarting in $RestartDelay s"
    } catch {
        $p.State = 'Failed'; $p.Detail = $_.Exception.Message
        Write-Log "$($p.Name): $($p.Detail)" 'Red'
    }
}

$deadline = (Get-Date).AddMinutes($TimeoutMinutes + [math]::Ceiling($RestartDelay / 60))
do {
    $waiting = @($pcs | Where-Object { $_.State -in 'Queued', 'Waking', 'Restarting' })
    if (-not $waiting) { break }

    foreach ($p in $waiting) {
        if (Get-StartedJob -ContentRoot $ContentRoot -Mac $p.Pc.mac -Since $started) {
            $p.State = 'Started'
            Write-Log "$($p.Name): deploy started" 'Green'
            if ($p.Prestaged) {
                try { Set-WdsNoPrompt -Server $wdsServer -Mac $p.Pc.mac -Remove } catch { Write-Log "$($p.Name): could not remove the WDS prestage: $($_.Exception.Message)" 'Yellow' }
            }
        }
    }

    $up = Test-WinRMReachable -ComputerName @($pcs | Where-Object { $_.State -in 'Queued', 'Waking' } | ForEach-Object Address)
    foreach ($p in $pcs | Where-Object { $_.State -in 'Queued', 'Waking' }) {
        if ($up[$p.Address]) { Start-PxeBoot $p; continue }
        # Off, or still booting: wake it, and again every 3 minutes in case a packet was lost.
        if ((Get-Date) - $p.LastWake -gt [timespan]::FromMinutes(3)) {
            try {
                Send-WakeOnLan -Computer $p.Pc -Port $wakePort
                Write-Log "$($p.Name): Wake-on-LAN sent to $($p.Pc.mac)$(if ($p.Pc.relay) { " (also through $($p.Pc.relay))" })"
            } catch { Write-Log "$($p.Name): Wake-on-LAN failed: $($_.Exception.Message)" 'Yellow' }
            $p.LastWake = Get-Date
            $p.State = 'Waking'
        }
    }
    Start-Sleep -Seconds 15
} while ((Get-Date) -lt $deadline)

foreach ($p in $pcs | Where-Object { $_.State -in 'Queued', 'Waking', 'Restarting' }) {
    $p.Detail = switch ($p.State) {
        'Restarting' { 'restarted but never started the deploy: check its PXE boot (F12 prompt, network boot disabled, WDS)' }
        default      { 'never answered: check Wake-on-LAN in its BIOS and that it is plugged into the network' }
    }
    $p.State = 'Failed'
    Write-Log "$($p.Name): $($p.Detail). The job stays queued until it expires; cancel it in the console." 'Red'
    if ($p.Prestaged) { try { Set-WdsNoPrompt -Server $wdsServer -Mac $p.Pc.mac -Remove } catch { } }
}

Write-Log ''
$pcs | Format-Table @{ n = 'PC'; e = { $_.Name } }, @{ n = 'MAC'; e = { $_.Pc.mac } }, State, Detail -AutoSize | Out-String -Width 200 |
    ForEach-Object { Write-Host $_; Add-Content -Path $logPath -Value $_ }
$result = if (@($pcs | Where-Object State -ne 'Started').Count) { 'FAILED' } else { 'OK' }
Copy-Item $logPath (Join-Path $logDir ("REIMAGE_{0:yyyyMMdd-HHmm}_{1}.log" -f $started, $result)) -ErrorAction SilentlyContinue
Write-Log "Done: $(@($pcs | Where-Object State -eq 'Started').Count) of $($pcs.Count) started. Results show on the Deployment Logs tab." 'Cyan'
if ($result -ne 'OK') { exit 1 }
