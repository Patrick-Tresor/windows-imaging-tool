<#
.SYNOPSIS
    Rolls a golden image back to an earlier version.
.DESCRIPTION
    Runs on the admin PC. The console's Images > Versions... dialog runs it hidden, with its steps as a card in the
    Progress window (-ProgressFile), since copying an image can take a while. Versions live in
    Images\Previous\<name>_<yyyyMMdd-HHmm>\ (see ImageVersions.psm1).

    Moves the current image to a new version, then copies the chosen version back as the current image. The
    chosen version stays in Previous, so answer files pinned to it keep working, and the image you rolled away
    from can be restored the same way. (Versions are kept automatically when a capture or an offline update
    replaces an image; there is no separate "keep a copy".)
.EXAMPLE
    .\src\Invoke-ImageVersion.ps1 -ImagePath D:\DeployShare\Images\Win11-Enterprise.wim -Action Rollback -Version 20261022-1530
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImagePath,
    [ValidateSet('Rollback')][string]$Action = 'Rollback',
    [Parameter(Mandatory)][string]$Version,   # the version to restore
    [switch]$NoPrompt,
    [string]$ProgressFile,  # step-by-step progress for the console's Progress window
    [string]$LogPath        # default: Invoke-ImageVersion.log in TEMP
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force

$name = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
$imagesDir = Split-Path $ImagePath -Parent
$contentRoot = Split-Path $imagesDir -Parent
$logDir = if ((Split-Path $imagesDir -Leaf) -eq 'Images' -and (Test-Path (Join-Path $contentRoot 'Logs'))) { Join-Path $contentRoot 'Logs' } else { $env:TEMP }
$logPath = if ($LogPath) { $LogPath } else { Join-Path $env:TEMP 'Invoke-ImageVersion.log' }
Set-DeployLogPath -Path $logPath -New
Start-BuildProgress -Path $ProgressFile -Title "Rolling $name back" -LogPath $logPath `
    -Steps @(@('run', "Rolling back to $Version"), @('prune', 'Deleting versions beyond the keep limit'))

$status = 'FAILED'
try {
    Start-BuildStep 'run'
    $target = Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $Version
    if (-not $target) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) was not found in $imagesDir\Previous." }
    Write-DeployLog "Rolling $(Split-Path $ImagePath -Leaf) back to version $Version ($($target.Reason), $($target.SizeGB) GB)"
    if (-not $NoPrompt -and (Read-Host 'Type YES to roll back') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
    if (-not (Test-ImageHardLinks -Path $imagesDir)) { Write-DeployLog "$imagesDir can't make hard links, so the rollback copies $($target.SizeGB) GB." -Level WARN }
    $old = Restore-ImageVersion -ImagePath $ImagePath -Version $Version
    if ($old) { Write-DeployLog "The image that was current is kept as version $($old.Version)" }
    Write-DeployLog "Rolled back. Answer files without a version deploy $Version from now on."
    Complete-BuildStep 'run'
    Start-BuildStep 'prune'
    $pruned = @(Invoke-ImageVersionRetention -ContentRoot $contentRoot -ImagePath $ImagePath -Protect @($Version | Where-Object { $_ }))
    if ($pruned) { Write-DeployLog "Deleted older versions beyond the keep limit: $(($pruned.Version) -join ', ')" }
    Complete-BuildStep 'prune' -State $(if ($pruned) { 'done' } else { 'skipped' }) -Detail $(if ($pruned) { ($pruned.Version) -join ', ' } else { '' })
    Stop-BuildProgress
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    Stop-BuildProgress -Message $_.Exception.Message
    Write-DeployLog 'Nothing was changed: the current image is as it was.' -Level WARN
}
finally {
    if ($status -ne 'CANCELLED') {
        Copy-Item $logPath (Join-Path $logDir ("VERSION-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
