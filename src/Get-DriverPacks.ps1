<#
.SYNOPSIS
    Downloads Dell, HP and Lenovo driver packs into the driver library, for the admin console.
.DESCRIPTION
    The console (Find a model online, Unknown models...) picks the packs from the vendors' catalogs and writes them
    to a job file; this script runs hidden, downloads each pack, checks its hash and signature, extracts it to
    <ContentRoot>\Drivers\<Maker>\<Model> and adds catalog entries for its SKUs or machine types and model name.
    Progress goes to ProgressFile, shown as a card in the console's Progress window.
#>
param(
    [Parameter(Mandatory)][string]$ContentRoot,
    # Written by the console: a JSON array of packs as returned by Get-VendorDriverPacks.
    [Parameter(Mandatory)][string]$JobFile,
    [switch]$KeepDownload,
    # The progress list reads ProgressFile (one row per pack, with the download percent) and its Open log button
    # shows LogPath.
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\DriverPacks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force
if ($LogPath) {
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
    try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { $LogPath = $null }
}
if (-not (Test-ContentRoot $ContentRoot)) { throw "$ContentRoot is not a content root. Create it in the console first." }

$packs = @(Get-Content -Raw $JobFile | ConvertFrom-Json)
if (-not $packs) {
    if ($ProgressFile) { Start-BuildProgress -Path $ProgressFile -Title 'Downloading driver packs' -Steps @() -LogPath $LogPath; Stop-BuildProgress -Message 'No matching driver packs.' }
    Write-Warning 'No matching driver packs.'; return
}

# One progress row per pack: the download percent, then checking, extracting and adding it to the library.
$steps = @(for ($n = 1; $n -le $packs.Count; $n++) { , @("pack$n", (Format-DriverPackName $packs[$n - 1])) })
$title = if ($packs.Count -eq 1) { "Downloading the $(Format-DriverPackName $packs[0]) driver pack" } else { "Downloading $($packs.Count) driver packs" }
Start-BuildProgress -Path $ProgressFile -Title $title -Steps $steps -LogPath $LogPath
$script:step = $null
$script:sizeText = ''
$onStage = {
    param($stage, $pct)
    switch ($stage) {
        'download' { Set-BuildStepProgress $script:step -Percent $pct -Detail "Downloading$($script:sizeText)" }
        'check'    { Set-BuildStepProgress $script:step -Detail 'Checking the file (hash and vendor signature)' }
        'extract'  { Set-BuildStepProgress $script:step -Detail 'Extracting the drivers' }
        'register' { Set-BuildStepProgress $script:step -Detail 'Adding it to the driver library' }
    }
}

$failed = 0
$i = 0
try {
    foreach ($p in $packs) {
        $i++
        $script:step = "pack$i"
        $script:sizeText = if ($p.SizeMB) { " $($p.SizeMB) MB" } else { '' }
        Write-Host "`n[$i/$($packs.Count)] $($p.Maker) $($p.Model), $($p.Os) $($p.Release) $($p.Version)" -ForegroundColor Cyan
        Start-BuildStep $script:step -Detail 'Starting'
        try {
            $r = Install-VendorDriverPack -ContentRoot $ContentRoot -Pack $p -KeepDownload:$KeepDownload -OnStage $onStage
            Write-Host "OK: $($r.InfCount) drivers in Drivers\$($r.Path), $($r.Entries) catalog entries" -ForegroundColor Green
            Complete-BuildStep $script:step -Detail "$($r.InfCount) drivers in Drivers\$($r.Path)"
        } catch {
            $failed++
            Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Complete-BuildStep $script:step -State failed -Detail (@("$($_.Exception.Message)" -split "`r?`n")[0])
        }
    }
    if ($failed) { Stop-BuildProgress -Message $(if ($packs.Count -eq 1) { 'The download failed, see the row below.' } else { "$failed of $($packs.Count) packs failed, see the rows below." }) }
    else { Stop-BuildProgress }
} catch {
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    Remove-Item $JobFile -Force -ErrorAction SilentlyContinue
    if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
}
Write-Host "`nDone: $($packs.Count - $failed) installed, $failed failed. Click Refresh on the console's Driver Library tab."
if ($failed) { exit 1 }
