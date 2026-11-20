# End-to-end test of a whole deployment: Deploy-Image.ps1 from start to finish, then FirstBoot.ps1, as on a PC.
#
# Everything runs for real (answer file, naming list, driver matching, unattend, first boot plan, staging, status,
# logs, applications, post-deploy checks, the result) except what needs WinPE and a disk to erase: the hardware,
# diskpart, DISM, bcdboot and BootNext are replaced by stand-ins that record what they were asked to do.
# X:, W: and S: are folders under TEMP (subst), so the scripts' fixed WinPE paths work.
#
# It changes the PC it runs on (files in C:\Windows\Temp and C:\ProgramData\ImagingTool, drive letters while it runs),
# so it only runs on the CI runner, or where IMAGING_E2E=1 is set. Run: powershell -File tests/DeployEndToEnd.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$onWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
if (-not $onWindows -or -not ($env:GITHUB_ACTIONS -eq 'true' -or $env:IMAGING_E2E -eq '1')) {
    Write-Host 'SKIP end-to-end deploy test: it runs on the CI runner, or with IMAGING_E2E=1 (it writes to C:\Windows\Temp and uses X:, W:, S:).' -ForegroundColor Yellow
    Complete-Tests 'Skipped.'
}
$letters = 'X', 'W', 'S'
$taken = @($letters | Where-Object { [IO.Directory]::Exists("${_}:\") })
if ($taken) {
    Write-Host "SKIP end-to-end deploy test: drive letter(s) $($taken -join ', ') in use." -ForegroundColor Yellow
    Complete-Tests 'Skipped.'
}

$shell = (Get-Process -Id $PID).Path
$base = Join-Path ([IO.Path]::GetTempPath()) ('E2E-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $base 'Content'          # the stick's DEPLOY partition / the share
$pe = Join-Path $base 'X'                  # WinPE's X:
$win = Join-Path $base 'W'                 # the new Windows partition
$sys = Join-Path $base 'S'                 # the EFI partition
$calls = Join-Path $base 'native-calls.txt'
$appMarker = Join-Path $env:WINDIR 'Temp\e2e-app-installed.txt'
$resultFile = Join-Path $env:WINDIR 'Temp\DeployResult.txt'
$serial = 'E2E' + (Get-Random -Minimum 10000 -Maximum 99999)

try {
    foreach ($d in $root, "$pe\Windows\Temp", $win, $sys) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    foreach ($l in $letters) {
        & subst.exe "${l}:" (Join-Path $base $l) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "subst ${l}: failed" }
    }
    Remove-Item -LiteralPath $appMarker, $resultFile -Force -ErrorAction SilentlyContinue

    # The tool as the media build puts it in WinPE: X:\Deploy with its config.
    Copy-Item (Join-Path $repo 'src') 'X:\Deploy' -Recurse
    New-Item -ItemType Directory -Path 'X:\Deploy\config' -Force | Out-Null
    '{ "commit": "e2e1234", "date": "2026-11-20T10:00:00Z", "built": "2026-11-20 10:05", "target": "Usb" }' | Set-Content 'X:\Deploy\config\tool-version.json'

    # The content: settings, answer file, image, driver pack, application, naming list.
    foreach ($d in 'config', 'AnswerFiles', 'Images', 'Drivers\Dell\Latitude 5521', 'Applications\E2E-App', 'Logs') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
    $settings = Get-Content -Raw (Join-Path $repo 'config\deploy-settings.json') | ConvertFrom-Json
    $settings.share.path = ''; $settings.share.user = ''; $settings.defaultAnswerFile = 'E2E'
    $settings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'config\deploy-settings.json')
    Copy-Item (Join-Path $root 'config\deploy-settings.json') 'X:\Deploy\config\deploy-settings.json'
    $xml = Get-Content -Raw (Join-Path $repo 'config\answer-files\Default.xml')
    $xml = $xml -replace '<file>Images\\Win11-Enterprise\.wim</file>', '<file>Images\E2E.wim</file>' `
                -replace '<windows11Check>Block</windows11Check>', '<windows11Check>Off</windows11Check>' `
                -replace '<!-- <application order="1">Dell-Command-Update</application> -->', '<application order="1">E2E-App</application>' `
                -replace '<disableSystemRestore>true</disableSystemRestore>', '<disableSystemRestore>false</disableSystemRestore>' `
                -replace '<reboot>true</reboot>', '<reboot>false</reboot>'
    Set-Content -Path (Join-Path $root 'AnswerFiles\E2E.xml') -Value $xml -Encoding utf8
    Set-Content -Path (Join-Path $root 'Images\E2E.wim') -Value 'not a real image: DISM is a stand-in here'
    '{ "entries": [ { "maker": "Dell", "model": "Latitude 5521", "path": "Dell\\Latitude 5521" } ], "fallbacks": {} }' |
        Set-Content (Join-Path $root 'config\driver-catalog.json')
    Set-Content -Path (Join-Path $root 'Drivers\Dell\Latitude 5521\e2e.inf') -Value '[Version]'
    @{ command = "echo installed> `"$appMarker`"" } | ConvertTo-Json | Set-Content (Join-Path $root 'Applications\E2E-App\app.json')
    "`"Serial`",`"ComputerName`",`"OU`",`"AnswerFile`",`"Notes`"`r`n`"$serial`",`"E2E-PC01`",`"`",`"E2E`",`"`"" | Set-Content (Join-Path $root 'config\naming-list.csv')

    # Stand-ins for the hardware and the native tools, dot-sourced into Deploy-Image.ps1 after its own functions.
    $hooks = Join-Path $base 'hooks.ps1'
    @'
function Set-DeployConsole { }
function Start-ProgressWindow { $false }
function Find-ContentRoot { $env:E2E_ROOT }
function Get-ContentDiskNumber { }   # a network share: no disk (no output, as the real one)
function Get-HardwareIdentity { [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5521'; MachineType = $null; Sku = '0A20'; Serial = $env:E2E_SERIAL; IsUefi = $true } }
function Get-Disk { param([int]$Number = -1)
    $d = [pscustomobject]@{ Number = 0; FriendlyName = 'E2E NVMe SSD'; Size = 256GB; BusType = 'NVMe'; PartitionStyle = 'GPT'; Model = 'E2E NVMe SSD' }
    if ($Number -ge 0 -and $Number -ne 0) { return }
    $d }
function Add-E2ECall([string]$Text) { Add-Content -Path $env:E2E_CALLS -Value $Text }
function Invoke-Native { param([string]$FilePath, [string[]]$ArgumentList, [switch]$NoThrow) Add-E2ECall ("$([IO.Path]::GetFileName($FilePath)) $($ArgumentList -join ' ')"); 0 }
function Invoke-NativeWithProgress { param([string]$FilePath, [string[]]$ArgumentList, [scriptblock]$OnProgress)
    Add-E2ECall ("$([IO.Path]::GetFileName($FilePath)) $($ArgumentList -join ' ')")
    if ($ArgumentList -contains '/Apply-Image' -and ($ArgumentList -match '^/ApplyDir:W:\\$')) {
        # A generalized Windows: what the reference PC's sysprep leaves.
        foreach ($d in 'W:\Windows\System32', 'W:\Windows\Temp', 'W:\Windows\Setup\State') { [void][IO.Directory]::CreateDirectory($d) }
        [IO.File]::WriteAllText('W:\Windows\Setup\State\State.ini', "[State]`r`nImageState=IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`r`n")
        & $OnProgress 50; & $OnProgress 100
    } elseif ($ArgumentList -contains '/Add-Driver') {
        & $OnProgress 100 ([pscustomobject]@{ Done = 1; Total = 1; Percent = 100 })
    } elseif ($OnProgress) { & $OnProgress 100 }
    0 }
function Set-WindowsBootNext { param([string]$SystemDrive) Add-E2ECall "bootnext $SystemDrive"; [pscustomobject]@{ Ok = $true; Message = 'BootNext set (test stand-in)' } }
'@ | Set-Content -Path $hooks -Encoding ascii
    $deployScript = 'X:\Deploy\Deploy-Image.ps1'
    $text = [IO.File]::ReadAllText($deployScript)
    $marker = [regex]::Match($text, '(?m)^Unlock-DeployMedia\s*$')
    Assert-Equal $marker.Success $true 'Deploy-Image.ps1 still calls Unlock-DeployMedia after its functions (where the stand-ins go in)'
    [IO.File]::WriteAllText($deployScript, $text.Insert($marker.Index, ". '$hooks'`r`n"))

    # 1. WinPE: the deploy.
    $env:E2E_ROOT = $root; $env:E2E_SERIAL = $serial; $env:E2E_CALLS = $calls
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File $deployScript -SettingsPath 'X:\Deploy\config\deploy-settings.json' -NoPrompt 2>&1
    $exit = $LASTEXITCODE
    $deployLog = if (Test-Path 'X:\Windows\Temp\Deploy.log') { Get-Content -Raw 'X:\Windows\Temp\Deploy.log' } else { '' }
    if ($exit -ne 0) { Write-Host ($out | Out-String); Write-Host $deployLog }
    Assert-Equal $exit 0 'Deploy-Image.ps1 finishes with exit code 0'
    Assert-Equal ($deployLog -match 'Imaging tool version e2e1234') $true 'Deploy.log starts with the tool version'
    Assert-Equal ($deployLog -match "Naming list entry for serial $serial") $true 'the naming list entry is used'
    Assert-Equal ($deployLog -match 'Deployment finished') $true 'Deploy.log ends with Deployment finished'

    $native = if (Test-Path $calls) { @(Get-Content $calls) } else { @() }
    Assert-Equal (@($native | Where-Object { $_ -like 'diskpart.exe /s *' }).Count) 1 'the disk is partitioned once'
    Assert-Equal (@($native | Where-Object { $_ -like "dism.exe /Apply-Image /ImageFile:$root\Images\E2E.wim /Index:1 /ApplyDir:W:\*" }).Count) 1 'the answer file''s image is applied to W:'
    Assert-Equal (@($native | Where-Object { $_ -like 'dism.exe *Add-Driver*Latitude 5521*' }).Count) 1 'the Latitude 5521 driver pack is injected'
    Assert-Equal (@($native | Where-Object { $_ -like 'bcdboot.exe W:\Windows /s S: /f UEFI' }).Count) 1 'boot files written for UEFI'
    $order = @($native | ForEach-Object { ($_ -split ' ')[0] + $(if ($_ -match '/(Apply-Image|Add-Driver)') { " $($Matches[1])" }) })
    Assert-Equal ($order -join ', ') 'diskpart.exe, dism.exe Apply-Image, dism.exe Add-Driver, bcdboot.exe, bootnext' 'partition, apply, drivers, boot files, BootNext, in that order'

    $unattend = Get-Content -Raw 'W:\Windows\Panther\unattend.xml'
    Assert-Equal ($unattend -match '<ComputerName>E2E-PC01</ComputerName>') $true 'unattend.xml names the PC from the naming list'
    Assert-Equal ($unattend -match '<JoinWorkgroup>WORKGROUP</JoinWorkgroup>') $true 'unattend.xml joins the workgroup'
    $fb = Get-Content -Raw 'W:\Temp\firstboot.json' | ConvertFrom-Json
    Assert-Equal (@($fb.applications | ForEach-Object name) -join ',') 'E2E-App' 'first boot installs the answer file''s application'
    Assert-Equal $fb.deploy.driversAdded 1 'first boot plan knows how many drivers were added'
    Assert-Equal $fb.deploy.computerName 'E2E-PC01' 'first boot plan has the computer name'
    foreach ($f in 'FirstBoot.ps1', 'DeployStatus.psm1', 'PostDeployChecks.psm1', 'AppPack.psm1', 'FirstBootState.psm1', 'Apps\E2E-App\app.json', 'deployed.json') {
        Assert-Equal (Test-Path (Join-Path 'W:\Temp' $f)) $true "staged: C:\Temp\$f"
    }
    Assert-Equal ((Get-Content -Raw 'W:\Windows\Setup\Scripts\SetupComplete.cmd') -match 'C:\\Temp\\FirstBoot\.ps1') $true 'SetupComplete.cmd starts first boot'
    Assert-Equal (Test-Path 'W:\ProgramData\ImagingTool\Clear-UnattendPasswords.ps1') $true 'the unattend password cleanup is staged'
    Assert-Equal (@(Get-ChildItem (Join-Path $root 'Logs') -Filter "${serial}_*_OK.log").Count) 1 'Deploy.log copied to the content root''s Logs as OK'

    $statusFile = @(Get-ChildItem (Join-Path $root 'Status') -Filter *.json)[0]
    Assert-Equal ([bool]$statusFile) $true 'the deployment reported to the Status folder'
    $status = Get-Content -Raw $statusFile.FullName | ConvertFrom-Json
    Assert-Equal "$($status.computerName)|$($status.driverPack)|$($status.driversAdded)" 'E2E-PC01|Dell\Latitude 5521|1' 'status record: name, driver pack, drivers added'
    Assert-Equal ($status.toolVersion -like 'e2e1234*') $true 'status record carries the tool version'

    # 2. First boot on the new Windows, reporting to the same Status folder (the share at first boot).
    $fb | Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{ folder = (Join-Path $root 'Status'); id = $status.id }) -Force
    $fb | ConvertTo-Json -Depth 8 | Set-Content 'W:\Temp\firstboot.json' -Encoding utf8
    $out = & $shell -NoProfile -ExecutionPolicy Bypass -File 'W:\Temp\FirstBoot.ps1' 2>&1
    $fbLog = if (Test-Path "$env:WINDIR\Temp\FirstBoot.log") { Get-Content -Raw "$env:WINDIR\Temp\FirstBoot.log" } else { '' }
    Assert-Equal (Test-Path $appMarker) $true 'first boot installed the application'
    if (-not (Test-Path $resultFile)) { Write-Host ($out | Out-String); Write-Host $fbLog }
    Assert-Equal (Test-Path $resultFile) $true 'first boot wrote DeployResult.txt'
    $result = if (Test-Path $resultFile) { Get-Content -Raw $resultFile } else { '' }
    Assert-Equal ($result -match '(?m)^E2E-PC01 \(Dell Latitude 5521\) - ') $true 'the result names the PC'
    Assert-Equal ($result -match 'Drivers\s+Dell\\Latitude 5521, 1 driver\(s\) added') $true 'the result has the driver pack and count'
    Assert-Equal ($result -match 'OK\s+Applications\s+1 of 1 installed') $true 'the result has the application'
    Assert-Equal ($result -match 'Tool version\s+e2e1234') $true 'the result has the tool version'

    Import-Module (Join-Path $repo 'src\DeployStatus.psm1') -Force
    $row = @(Get-DeploymentStatus -Folder (Join-Path $root 'Status'))[0]
    Assert-Equal "$($row.Percent)|$($row.Step)" '100|Deployment complete' 'the dashboard shows the deployment complete'
    Assert-Equal ($row.State -in 'Succeeded', 'Warning') $true 'the dashboard state is Succeeded or Warning (this CI PC is not E2E-PC01, so the name check fails)'
    Assert-Equal ([bool]$row.Result) $true 'the dashboard row has a result'
    Assert-Equal ($row.ResultText -match 'Applications\s+1 of 1 installed') $true 'the dashboard result lists the application'
}
finally {
    foreach ($l in $letters) { & subst.exe "${l}:" /D 2>&1 | Out-Null }
    Remove-Item Env:E2E_ROOT, Env:E2E_SERIAL, Env:E2E_CALLS -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 6   # first boot's cleanup runs 5 s after it ends
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $appMarker -Force -ErrorAction SilentlyContinue
}

Complete-Tests
