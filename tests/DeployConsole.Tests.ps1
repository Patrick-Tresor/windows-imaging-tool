# Tests for the WinPE deploy console and DISM progress: wrapping long lines to the window, reading how far DISM is
# (image apply bar, driver count), and keeping progress bar redraws out of the log.
# Run: powershell -File tests/DeployConsole.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force
Import-Module (Join-Path $repo 'src/DeployProgress.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Wrapping.
$short = @(Format-ConsoleText -Text '12:00:01 Partitioning disk 0' -Width 80)
Assert-Equal $short.Count 1 'a short line stays one line'
$long = '12:00:01 ERROR: The Windows 11 check failed because the disk is smaller than 64 GB and the answer file blocks deployment'
$wrapped = @(Format-ConsoleText -Text $long -Width 40)
Assert-Equal (@($wrapped | Where-Object { $_.Length -gt 40 }).Count) 0 'no wrapped line is wider than the window'
Assert-Equal (($wrapped | ForEach-Object { $_.Trim() }) -join ' ') $long 'wrapping keeps every word'
Assert-Equal ($wrapped[1].StartsWith('         ')) $true 'continuation lines are indented'
$path = 'X:\' + ('a' * 120)
$split = @(Format-ConsoleText -Text $path -Width 50)
Assert-Equal (@($split | Where-Object { $_.Length -gt 50 }).Count) 0 'a word longer than the window is broken'
Assert-Equal (($split | ForEach-Object { $_.Trim() }) -join '') $path 'a broken word keeps every character'
Assert-Equal (@(Format-ConsoleText -Text '' -Width 50).Count) 1 'an empty line stays one line'
Set-DeployConsole   # no real console here: must not throw

# DISM progress.
$apply = "Deployment Image Servicing and Management tool`r`nVersion: 10.0.26100.1`r`n`r`nApplying image`r`n" +
    "[==                         4.0%                           ]`r`n[==========                 45.0%                          ]`r`n"
$p = Get-NativeProgress -Text $apply
Assert-Equal "$($p.Percent)|$($p.Total)" '45|' 'apply progress is the last bar value'
$redraw = "[=====    20.0%    ]`r[=======   31.5%   ]"
Assert-Equal (Get-NativeProgress -Text $redraw).Percent 31 'a bar redrawn with CR reads its last value'
Assert-Equal (Get-NativeProgress -Text 'Applying image') '' 'no progress before the first bar'
Assert-Equal (Get-NativeProgress -Text '') '' 'no output, no progress'
Assert-Equal (Get-NativeProgress -Text "    (12.03/100%)`r    (45.50/100%)`r").Percent 45 'qemu-img progress reads the percent, not the 100'
Assert-Equal (Get-NativeProgress -Text "0%...10%...20%...30%").Percent 30 'VBoxManage progress reads its last value'

$drivers = "Searching for driver packages to install...`r`nFound 76 driver package(s) to install.`r`n" +
    "Installing 1 of 76 - E:\Drivers\Dell\Latitude 5521\a.inf: The driver package was successfully installed.`r`n" +
    "Installing 39 of 76 - E:\Drivers\Dell\Latitude 5521\b.inf: The driver package was successfully installed.`r`n"
$d = Get-NativeProgress -Text $drivers
Assert-Equal "$($d.Done)|$($d.Total)|$($d.Percent)" '38|76|50' 'driver progress counts the drivers done'

# Log lines.
$out = $apply + "[==========================100.0%==========================]`r`nThe operation completed successfully.`r`n"
$kept = @(Get-NativeLogLines -Text $out)
Assert-Equal (@($kept | Where-Object { $_ -match '%' }).Count) 0 'progress bars stay out of the log'
Assert-Equal $kept[-1] 'The operation completed successfully.' 'result line is kept'
Assert-Equal (@($kept | Where-Object { -not $_.Trim() }).Count) 0 'blank lines are dropped'
Assert-Equal (@(Get-NativeLogLines -Text $drivers) | Where-Object { $_ -like 'Installing 39 of 76*' }).Count 1 'driver lines are kept'

# The progress window comes to the front when the deploy starts working and when it ends, not on every tick.
$waiting = [pscustomobject]@{ Busy = $false; Finished = $false }
$busy = [pscustomobject]@{ Busy = $true; Finished = $false }
$done = [pscustomobject]@{ Busy = $false; Finished = $true }
Assert-Equal (Test-ProgressRaise -Previous $null -Current $waiting) $true 'raised when first shown'
Assert-Equal (Test-ProgressRaise -Previous $waiting -Current $busy) $true 'raised when the wizard closes and the deploy runs'
Assert-Equal (Test-ProgressRaise -Previous $busy -Current $busy) $false 'not raised on every tick'
Assert-Equal (Test-ProgressRaise -Previous $busy -Current $done) $true 'raised when the deploy ends'
Assert-Equal (Test-ProgressRaise -Previous $done -Current $done) $false 'not raised again after the end'

# Deploy-Image.ps1 uses the progress reader for driver injection too, and nothing reads DISM output with
# File.ReadAllText, which fails while cmd still writes the file.
$deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deploy -match "Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList \(Get-AddDriverArgs") $true 'driver injection reports progress'
Assert-Equal ($deploy -match 'Set-DeployConsole') $true 'deploy sets up the console'
$common = Get-Content -Raw (Join-Path $repo 'src/DeployCommon.psm1')
Assert-Equal ($common -match 'ReadAllText\(\$out\)') $false 'DISM output is read with FileShare.ReadWrite'

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All deploy console tests passed.' -ForegroundColor Green
