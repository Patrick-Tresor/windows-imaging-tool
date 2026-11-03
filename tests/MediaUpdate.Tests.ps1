# Plain-PowerShell tests for updating a USB stick in place (Get-MediaUpdatePlan, Remove-StaleMediaFiles) and for
# the WinPE Copy logs button (Get-LogCopyTarget, Copy-DeployLogs).
# Run: pwsh -File tests/MediaUpdate.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployWizard.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function New-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Text -NoNewline
}

$base = Join-Path ([IO.Path]::GetTempPath()) ("imaging-update-" + [guid]::NewGuid())
$src = Join-Path $base 'src'; $stick = Join-Path $base 'stick'
try {
    New-File (Join-Path $src 'Images/Win11.wim') 'image-v1'
    New-File (Join-Path $src 'AnswerFiles/Staff.xml') '<a/>'
    New-File (Join-Path $src 'Drivers/Dell/5521/a.inf') 'drv'
    New-File (Join-Path $src 'config/deploy-settings.json') '{}'
    $plan = Get-MediaCopyPlan -ContentRoot $src -Folders 'Drivers', 'config' -Files 'AnswerFiles\Staff.xml', 'Images\Win11.wim'
    New-Item -ItemType Directory -Path $stick -Force | Out-Null

    # An empty stick: everything is copied.
    $u = Get-MediaUpdatePlan -Plan $plan -Destination $stick
    Assert-Equal $u.Copy.FileCount 4 'empty stick: every file'
    [void](Copy-MediaContent -Plan $u.Copy -Destination $stick -Quiet)

    # Copied once: nothing to do (the copy keeps the modified time).
    $u = Get-MediaUpdatePlan -Plan $plan -Destination $stick
    Assert-Equal "$($u.Copy.FileCount)|$($u.Unchanged)|$(@($u.Stale).Count)" '0|4|0' 'up to date: nothing copied, nothing deleted'

    # A new image (different size), a dropped driver pack, old password files and the Logs folder on the stick.
    New-File (Join-Path $src 'Images/Win11.wim') 'image-v2-longer'
    New-File (Join-Path $stick 'Drivers/HP/Old/b.inf') 'old'
    New-File (Join-Path $stick 'config/secrets/join.txt') 'pw'
    New-File (Join-Path $stick 'Drivers/_WinPE/Dell/iaStorVD.inf') 'pe'
    New-File (Join-Path $stick 'Logs/PC1/Deploy.log') 'log'
    $plan = Get-MediaCopyPlan -ContentRoot $src -Folders 'Drivers', 'config' -Files 'AnswerFiles\Staff.xml', 'Images\Win11.wim'
    $u = Get-MediaUpdatePlan -Plan $plan -Destination $stick
    Assert-Equal ($u.Copy.Items.Relative -join ';') 'Images\Win11.wim' 'changed image: only it is copied'
    Assert-Equal (@($u.Stale.Relative | Sort-Object) -join ';') 'config\secrets\join.txt;Drivers\HP\Old\b.inf' 'dropped pack and old password files are deleted'
    Assert-Equal $u.NeededBytes ([int64](15 - 8 - 3 - 2)) 'room needed: copied minus replaced minus deleted'
    Remove-StaleMediaFiles -UpdatePlan $u -Destination $stick
    [void](Copy-MediaContent -Plan $u.Copy -Destination $stick -Quiet)
    Assert-Equal (Test-Path (Join-Path $stick 'Drivers/HP')) $false 'empty folders removed'
    Assert-Equal (Test-Path (Join-Path $stick 'Logs/PC1/Deploy.log')) $true 'Logs kept'
    Assert-Equal (Test-Path (Join-Path $stick 'Drivers/_WinPE/Dell/iaStorVD.inf')) $true 'WinPE drivers kept'
    Assert-Equal (Get-Content -Raw (Join-Path $stick 'Images/Win11.wim')) 'image-v2-longer' 'new image on the stick'

    # Copy logs: to the DEPLOY volume first, then the share, then another removable volume.
    $vols = @([pscustomobject]@{ DriveLetter = 'E'; FileSystemLabel = 'DATA'; DriveType = 'Removable' },
              [pscustomobject]@{ DriveLetter = 'D'; FileSystemLabel = 'DEPLOY'; DriveType = 'Removable' })
    Assert-Equal (Get-LogCopyTarget -Volumes $vols) 'D:\Logs' 'logs go to the DEPLOY stick'
    if (-not (Test-Path -LiteralPath 'Z:\')) {
        Assert-Equal (Get-LogCopyTarget -Volumes @($vols[0])) 'E:\Logs' 'else another USB stick'
        Assert-Equal ($null -eq (Get-LogCopyTarget -Volumes @([pscustomobject]@{ DriveLetter = 'X'; FileSystemLabel = ''; DriveType = 'Fixed' }))) $true 'nowhere: nothing'
    }
    $logs = Join-Path $base 'pe'
    New-File (Join-Path $logs 'Temp/Deploy.log') 'a'
    New-File (Join-Path $logs 'Panther/setupact.log') 'b'
    $r = Copy-DeployLogs -Serial 'ABC 123' -Destination (Join-Path $base 'out') -Sources @((Join-Path $logs 'Temp/*.log'), (Join-Path $logs 'Panther/setupact.log'), (Join-Path $logs 'missing/*.log'))
    Assert-Equal $r.Count 2 'copy logs: every log found'
    Assert-Equal ((Split-Path $r.Path -Leaf) -like 'ABC_123-*') $true 'copy logs: folder named by serial and time'
}
finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

# The build: an update never erases.
$build = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($build -match '(?s)if \(-not \$UpdateOnly\) \{.*Reset-UsbDisk') $true 'Reset-UsbDisk only when not updating'

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All media update checks passed' -ForegroundColor Green
