<#
.SYNOPSIS
    Reimages running PCs over the network: for each one, queues a job on the deployment share, starts WinPE from
    the PC's own disk, and waits until its deploy has started.
.DESCRIPTION
    Run by the console's Computers tab (hidden, with its progress in a progress window), or by hand on an admin PC.
    For each PC (RemoteReimage.psm1):
      1. Reads it over PowerShell remoting: the name it answers with, BIOS serial, UUID, firmware, free space.
         A PC that is off, has no WinRM, answers with another name, starts in legacy BIOS mode or has a serial many
         PCs share is skipped, with nothing changed on it.
      2. Writes Reimage\<serial>.json on the share: the answer file, and the name and OU to keep.
      3. Copies the network boot image to C:\_ImagingBoot, adds a one-time boot entry for it, suspends BitLocker
         for one restart, and restarts the PC after a warning.
      4. Waits until WinPE on that PC has taken the job (Reimage\Started). From there the deploy shows on the
         Dashboard like any other.
    Needs admin rights on the PCs over PowerShell remoting (WinRM), and a deployment share (deploy-settings.json
    share.path) that WinPE maps.
.EXAMPLE
    .\src\Start-RemoteReimage.ps1 -ContentRoot \\server\Deploy -BootWim D:\Deploy\Boot\boot.wim -AnswerFile Staff-W11 -Computers PC01.corp.local,PC02.corp.local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContentRoot,     # the deployment share WinPE maps (jobs go there)
    [Parameter(Mandatory)][string]$BootWim,         # the network boot image to start on each PC
    [Parameter(Mandatory)][string]$AnswerFile,
    [string]$TargetsFile,           # JSON from the console: [{ name, address, ou }]; deleted once read
    [string[]]$Computers,           # or names/addresses (the answer file's OU and the PC's own name are kept)
    [switch]$KeepNames,             # each PC keeps its name
    [switch]$KeepOU,                # each PC joins back into the OU it is in now (from TargetsFile)
    [string]$CredentialFile,        # Export-Clixml of a PSCredential for remoting (only this user can read it); deleted once read
    [int]$RestartDelay = 60,        # seconds of warning for anyone logged on
    [int]$TimeoutMinutes = 20,      # how long to wait for each PC to start its deploy
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force

if ($LogPath) {
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
    try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { $LogPath = $null }
}

$credential = $null
if ($CredentialFile) {
    try { $credential = Import-Clixml -LiteralPath $CredentialFile } finally { Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue }
}
$targets = @()
if ($TargetsFile) {
    try { $targets = @(Get-Content -Raw -LiteralPath $TargetsFile | ConvertFrom-Json) } finally { Remove-Item -LiteralPath $TargetsFile -Force -ErrorAction SilentlyContinue }
}
# From the console (powershell -File) a list arrives as one comma-separated string.
foreach ($c in @($Computers | ForEach-Object { "$_" -split ',' } | ForEach-Object Trim | Where-Object { $_ })) {
    $targets += [pscustomobject]@{ name = ($c -split '\.')[0].ToUpperInvariant(); address = $c; ou = '' }
}
if (-not $targets) { throw 'No computers to reimage.' }

$pcs = @(for ($i = 0; $i -lt $targets.Count; $i++) {
    $t = $targets[$i]
    [pscustomobject]@{
        Id = "pc$i"; Name = "$($t.name)".ToUpperInvariant(); Address = $(if ($t.address) { "$($t.address)" } else { "$($t.name)" }); OU = "$($t.ou)"
        State = 'Pending'; Serial = $null; RequestedAt = $null; RestartAt = $null; BootEntry = $null
    }
})
Start-BuildProgress -Path $ProgressFile -Title "Reimaging $($pcs.Count) PC$(if ($pcs.Count -ne 1) { 's' }) with $AnswerFile" -LogPath $LogPath -Steps @($pcs | ForEach-Object { , @($_.Id, $_.Name) })
Write-Host "Reimaging $($pcs.Count) PC(s) with answer file $AnswerFile from $ContentRoot" -ForegroundColor Cyan

function Stop-Pc($p, [string]$Message) {
    $p.State = 'Failed'
    Write-Host "$($p.Name): $Message" -ForegroundColor Red
    Complete-BuildStep $p.Id -State failed -Detail (@("$Message" -split "`r?`n")[0])
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "Answer file $AnswerFile is not on $ContentRoot." }
    $up = Test-WinRMReachable -ComputerName @($pcs | ForEach-Object Address)

    # One PC at a time up to its restart: each copy of boot.wim is a few hundred MB.
    foreach ($p in $pcs) {
        Start-BuildStep $p.Id -Detail 'Reading the PC'
        if (-not $up[$p.Address]) { Stop-Pc $p "Not reachable over PowerShell remoting ($($p.Address)): it is off, or WinRM is not enabled on it"; continue }
        try {
            $info = Get-RemoteComputerInfo -ComputerName $p.Address -Credential $credential
            Write-Host "$($p.Name): $($info.Model), serial $($info.Serial), $($info.Firmware), BitLocker $($info.BitLocker)"
            $problems = @(Test-RemoteTarget -Info $info -ExpectedName $p.Name)
            if ($problems) { Stop-Pc $p "Not reimaged: $($problems[0])"; continue }
            $p.Serial = $info.Serial
            $queued = (New-ReimageJob -ContentRoot $ContentRoot -Serial $info.Serial -Uuid $info.Uuid -AnswerFile $AnswerFile `
                -ComputerName $(if ($KeepNames) { $p.Name } else { '' }) -OU $(if ($KeepOU) { $p.OU } else { '' }) -ExpiresHours ([Math]::Max(2, [Math]::Ceiling($TimeoutMinutes / 60) + 1)))
            # The console's own time stamp: the started job is matched by it, not by WinPE's clock.
            $p.RequestedAt = "$($queued.requestedAt)"
            Write-Host "$($p.Name): job queued$(if ($KeepNames) { ", keeps its name" })$(if ($KeepOU -and $p.OU) { ", joins $($p.OU)" })"
            $onStage = {
                param($stage)
                switch ($stage) {
                    'copy'      { Set-BuildStepProgress $p.Id -Percent 20 -Detail 'Copying WinPE to the PC' }
                    'bootentry' { Set-BuildStepProgress $p.Id -Percent 50 -Detail 'Adding the one-time boot entry' }
                    'restart'   { Set-BuildStepProgress $p.Id -Percent 60 -Detail "Restarting in $RestartDelay s" }
                }
            }
            try {
                $r = Invoke-LocalDiskBoot -ComputerName $p.Address -BootWim $BootWim -Credential $credential -DelaySeconds $RestartDelay -OnStage $onStage
            } catch {
                Remove-ReimageJob -ContentRoot $ContentRoot -Serial $info.Serial
                throw
            }
            $p.BootEntry = $r.BootEntry
            Write-Host "$($p.Name): next boot set to WinPE from its own disk (entry $($r.BootEntry)); restarting in $RestartDelay s"
            $p.State = 'Restarting'; $p.RestartAt = (Get-Date).AddSeconds($RestartDelay)
            Set-BuildStepProgress $p.Id -Percent 70 -Detail 'Restarting into WinPE'
        } catch { Stop-Pc $p $_.Exception.Message }
    }

    # Then wait for WinPE on each PC to take its job.
    while ($true) {
        $waiting = @($pcs | Where-Object State -eq 'Restarting')
        if (-not $waiting) { break }
        foreach ($p in $waiting) {
            if (Get-StartedJob -ContentRoot $ContentRoot -Serial $p.Serial -RequestedAt $p.RequestedAt) {
                $p.State = 'Started'
                Write-Host "$($p.Name): deploy started" -ForegroundColor Green
                Complete-BuildStep $p.Id -Detail 'Deploy started: follow it on the Dashboard'
            } elseif ((Get-Date) -gt $p.RestartAt.AddMinutes($TimeoutMinutes)) {
                Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial
                # Back in Windows (WinPE could not start, or nobody took the job)? Take WinPE off its disk now. If the
                # PC does not answer, its startup task does it at the next Windows start.
                $cleaned = try { Remove-LocalDiskBoot -ComputerName $p.Address -BootEntry $p.BootEntry -Credential $credential; $true } catch { $false }
                Stop-Pc $p ("WinPE did not start the deploy within $TimeoutMinutes min: check the PC's screen (network, share)" + $(if ($cleaned) { '. WinPE was removed from its disk.' } else { '' }))
            } elseif ((Get-Date) -gt $p.RestartAt) {
                Set-BuildStepProgress $p.Id -Percent 85 -Detail 'Waiting for WinPE to start the deploy'
            }
        }
        Start-Sleep -Seconds 5
    }

    $failed = @($pcs | Where-Object State -ne 'Started').Count
    Write-Host ''
    Write-Host "Done: $($pcs.Count - $failed) of $($pcs.Count) started." -ForegroundColor Cyan
    if ($failed) { Stop-BuildProgress -Message $(if ($pcs.Count -eq 1) { 'The PC was not reimaged, see the row below.' } else { "$failed of $($pcs.Count) PCs were not reimaged, see the rows below." }) }
    else { Stop-BuildProgress }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
}
if (@($pcs | Where-Object State -ne 'Started').Count) { exit 1 }
