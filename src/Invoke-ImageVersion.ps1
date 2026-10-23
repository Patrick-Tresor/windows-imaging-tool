<#
.SYNOPSIS
    Keeps a copy of a golden image as a version, or rolls the image back to an earlier version.
.DESCRIPTION
    Runs on the admin PC. The console's Images > Versions... dialog runs it in its own window, since copying
    an image can take a while. Versions live in Images\Previous\<name>_<yyyyMMdd-HHmm>\ (see ImageVersions.psm1).

    Keep:     copies the current image to a new version (a snapshot before you change something).
    Rollback: moves the current image to a new version, then copies the chosen version back as the current
              image. The chosen version stays in Previous, so answer files pinned to it keep working, and the
              image you rolled away from can be restored the same way.
.EXAMPLE
    .\src\Invoke-ImageVersion.ps1 -ImagePath D:\DeployShare\Images\Win11-Enterprise.wim -Action Keep -Note 'Before October updates'
.EXAMPLE
    .\src\Invoke-ImageVersion.ps1 -ImagePath D:\DeployShare\Images\Win11-Enterprise.wim -Action Rollback -Version 20261022-1530
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ImagePath,
    [Parameter(Mandatory)][ValidateSet('Keep', 'Rollback')][string]$Action,
    [string]$Version,       # Rollback: the version to restore
    [string]$Note,          # Keep: shown next to the version in the console
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force

$name = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
$imagesDir = Split-Path $ImagePath -Parent
$contentRoot = Split-Path $imagesDir -Parent
$logDir = if ((Split-Path $imagesDir -Leaf) -eq 'Images' -and (Test-Path (Join-Path $contentRoot 'Logs'))) { Join-Path $contentRoot 'Logs' } else { $env:TEMP }
$logPath = Join-Path $env:TEMP 'Invoke-ImageVersion.log'
Set-Content -Path $logPath -Value $null
# DeployCommon logs to X:\ (WinPE) by default; point it at a local file.
& (Get-Module DeployCommon) { param($p) $script:LogPath = $p } $logPath

$status = 'FAILED'
try {
    if ($Action -eq 'Keep') {
        Write-DeployLog "Keeping a copy of $(Split-Path $ImagePath -Leaf)"
        $v = Save-ImageVersion -ImagePath $ImagePath -Reason 'Kept a copy' -Note $Note
        Write-DeployLog "Saved as version $($v.Version) in $($v.Folder)"
    } else {
        $target = Get-ImageVersions -ImagePath $ImagePath | Where-Object Version -eq $Version
        if (-not $target) { throw "Version $Version of $(Split-Path $ImagePath -Leaf) was not found in $imagesDir\Previous." }
        Write-DeployLog "Rolling $(Split-Path $ImagePath -Leaf) back to version $Version ($($target.Reason), $($target.SizeGB) GB)"
        if (-not $NoPrompt -and (Read-Host 'Type YES to roll back') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
        $old = Restore-ImageVersion -ImagePath $ImagePath -Version $Version
        if ($old) { Write-DeployLog "The image that was current is kept as version $($old.Version)" }
        Write-DeployLog "Rolled back. Answer files without a version deploy $Version from now on."
    }
    $pruned = @(Invoke-ImageVersionRetention -ContentRoot $contentRoot -ImageName (Split-Path $ImagePath -Leaf))
    if ($pruned) { Write-DeployLog "Deleted older versions beyond versionsToKeep: $(($pruned.Version) -join ', ')" }
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    Write-DeployLog 'Nothing was changed: the current image is as it was.' -Level WARN
}
finally {
    if ($status -ne 'CANCELLED') {
        Copy-Item $logPath (Join-Path $logDir ("VERSION-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
