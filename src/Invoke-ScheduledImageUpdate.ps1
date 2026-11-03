<#
.SYNOPSIS
    The monthly image update, run each day by the scheduled task Register-ImageUpdateSchedule creates.
.DESCRIPTION
    Does nothing until Patch Tuesday plus daysAfterPatchTuesday (config\image-update-schedule.json), then, once per
    month, applies to each listed image the update files in the Updates folder it has not had yet, with
    Update-OfflineImage.ps1 (the previous version is kept in Images\Previous, so a bad month rolls back on the
    Images tab). Put the month's .msu files from the Microsoft Update Catalog in Updates\ (or Updates\<image name>\
    for an image that needs other files) before that day. Logs: SERVICE-*.log on the Deployment Logs tab.
.EXAMPLE
    .\src\Invoke-ScheduledImageUpdate.ps1 -ContentRoot D:\DeployShare -Force
    Runs now, whatever the date.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContentRoot,
    [switch]$Force,
    [datetime]$Now = (Get-Date)
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageUpdateSchedule.psm1') -Force

$s = Get-ImageUpdateSchedule -ContentRoot $ContentRoot
if (-not $s.enabled -and -not $Force) { Write-Host 'The monthly image update is off.'; return }
if (-not $Force -and -not (Test-ImageUpdateDue -Now $Now -DaysAfter ([int]$s.daysAfterPatchTuesday) -LastRun $s.lastRun)) {
    Write-Host "Not due yet (Patch Tuesday this month: $((Get-PatchTuesday -Year $Now.Year -Month $Now.Month).ToString('yyyy-MM-dd')); last run: $($s.lastRun))."
    return
}

$failed = 0
foreach ($img in @($s.images)) {
    $path = Join-Path $ContentRoot $img
    if (-not (Test-Path -LiteralPath $path)) { Write-Warning "Image $img is not in $ContentRoot."; $failed++; continue }
    $pending = @(Get-PendingImageUpdates -ContentRoot $ContentRoot -ImagePath $path -UpdateFolder $s.updateFolder)
    if (-not $pending) { Write-Host "$($img): no new update files."; continue }
    Write-Host "$($img): $(($pending | ForEach-Object Name) -join ', ')"
    $updateArgs = @{ ImagePath = $path; PackagePath = @($pending | ForEach-Object FullName); NoPrompt = $true }
    if ($s.cleanup) { $updateArgs.Cleanup = $true }
    $global:LASTEXITCODE = 0
    try { & (Join-Path $PSScriptRoot 'Update-OfflineImage.ps1') @updateArgs } catch { Write-Warning "$($img): $($_.Exception.Message)"; $failed++; continue }
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
# Marked done even when an image failed: the log says why, and the next run is next month (or -Force).
$s.lastRun = $Now.ToString('yyyy-MM')
Save-ImageUpdateSchedule -ContentRoot $ContentRoot -Schedule $s
if ($failed) { exit 1 }
