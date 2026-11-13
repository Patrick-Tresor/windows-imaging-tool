# Plain-PowerShell tests for the capture wizard's Check the disk page (src/CaptureCheck.psm1): the quick checks on
# a VM's disk file, reusing the check's copy of the disk, reading the Windows version, and what the page shows.
# Run: powershell -File tests\CaptureCheck.Tests.ps1; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/CaptureCheck.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Get-Row($List, $Id) { @($List.Rows | Where-Object Id -eq $Id)[0] }
$tick = [string][char]0x2713; $cross = [string][char]0x2717; $wait = [string][char]0x25CB

Assert-Equal (Format-DiskSize 20508000000) '19.1 GB' 'size in GB with a dot'
Assert-Equal (Format-DiskSize 104857600) '100 MB' 'size under 1 GB in MB'

Assert-Equal (Get-WindowsDisplayName -ProductName 'Windows 10 Pro' -DisplayVersion '24H2' -Build 26100) 'Windows 11 Pro 24H2 (build 26100)' 'Windows 11 still called Windows 10 in the registry'
Assert-Equal (Get-WindowsDisplayName -ProductName 'Windows 10 Enterprise' -DisplayVersion '22H2' -Build 19045) 'Windows 10 Enterprise 22H2 (build 19045)' 'Windows 10 keeps its name'
Assert-Equal (Get-WindowsDisplayName -Build 22631) 'Windows (build 22631)' 'no registry values: the build only'

$reg = ConvertFrom-RegQuery -Lines @(
    '', 'HKEY_LOCAL_MACHINE\ImagingToolCapture\Microsoft\Windows NT\CurrentVersion'
    '    ProductName    REG_SZ    Windows 10 Pro'
    '    DisplayVersion    REG_SZ    24H2'
    '    CurrentBuild    REG_SZ    26100'
    '    InstallDate    REG_DWORD    0x67000000'
)
Assert-Equal $reg.ProductName 'Windows 10 Pro' 'reg query: value with spaces'
Assert-Equal $reg.CurrentBuild '26100' 'reg query: build'
Assert-Equal $reg.InstallDate '0x67000000' 'reg query: dword'

$dir = Join-Path ([IO.Path]::GetTempPath()) ("imaging-check-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $missing = Get-CaptureDiskChecklist -DiskPath (Join-Path $dir 'none.vmdk')
    Assert-Equal $missing.Passed $false 'a missing disk does not pass'
    Assert-Equal (@($missing.Rows).Count) 1 'a missing disk stops at the first line'

    $empty = Get-CaptureDiskChecklist -DiskPath ''
    Assert-Equal $empty.Passed $false 'no disk chosen does not pass'

    # A VHDX is read in place: no reader, no free space needed.
    $vhdx = Join-Path $dir 'Ref.vhdx'
    [IO.File]::WriteAllBytes($vhdx, [byte[]](1..64))
    $list = Get-CaptureDiskChecklist -DiskPath $vhdx
    Assert-Equal $list.Passed $true 'a VHDX on a local drive passes'
    Assert-Equal (@($list.Rows | ForEach-Object Id) -join ',') 'file,local,off,reader' 'VHDX lines'
    Assert-Equal $list.ReadPath ([IO.Path]::GetFullPath($vhdx)) 'a VHDX is read as it is'

    # A VMware disk with a snapshot on top: the newest delta is read, and the copy needs a reader and space.
    $vm = Join-Path $dir 'VM'
    New-Item -ItemType Directory -Path $vm | Out-Null
    $base = Join-Path $vm 'Ref.vmdk'
    $delta = Join-Path $vm 'Ref-000001.vmdk'
    Set-Content -LiteralPath $base -Value "# Disk DescriptorFile`nversion=1`nparentCID=ffffffff`ncreateType=`"monolithicSparse`"" -Encoding Ascii
    Set-Content -LiteralPath $delta -Value "# Disk DescriptorFile`nversion=1`nparentFileNameHint=`"Ref.vmdk`"`ncreateType=`"monolithicSparse`"" -Encoding Ascii

    $noReader = Get-CaptureDiskChecklist -DiskPath $base
    Assert-Equal $noReader.Passed $false 'a VMDK without qemu-img or VirtualBox does not pass'
    Assert-Equal (Get-Row $noReader 'reader').Ok $false 'the disk reader line has a cross'
    Assert-Equal ((Get-Row $noReader 'snapshots').Detail -like '*Ref-000001.vmdk*') $true 'the snapshot line names the newest delta'
    Assert-Equal (Split-Path -Leaf $noReader.ReadPath) 'Ref-000001.vmdk' 'the newest delta is read'

    $ok = Get-CaptureDiskChecklist -DiskPath $base -QemuImg 'C:\qemu\qemu-img.exe' -TempDir $dir
    Assert-Equal $ok.Passed $true 'a VMDK with qemu-img and space passes'
    Assert-Equal (@($ok.Rows | ForEach-Object Id) -join ',') 'file,local,off,snapshots,reader,space' 'VMDK lines'
    Assert-Equal ((Get-Row $ok 'reader').Detail -like 'qemu-img*') $true 'the reader line names qemu-img'

    New-Item -ItemType Directory -Path (Join-Path $vm 'Ref.vmdk.lck') | Out-Null
    $running = Get-CaptureDiskChecklist -DiskPath $base -QemuImg 'C:\qemu\qemu-img.exe' -TempDir $dir
    Assert-Equal (Get-Row $running 'off').Ok $false 'VMware lock folders: the VM is not shut down'
    Assert-Equal $running.Passed $false 'a running VM does not pass'
    Remove-Item -LiteralPath (Join-Path $vm 'Ref.vmdk.lck') -Recurse -Force

    # The check's copy is reused only while the disk files are unchanged.
    $copy = Join-Path $dir 'capture-check-1.vhd'
    [IO.File]::WriteAllBytes($copy, [byte[]](1..16))
    Assert-Equal (Test-ConvertedDiskReusable -ConvertedPath $copy -SourcePath $delta) $false 'a copy without its note is not reused'
    Save-ConvertedDiskSource -ConvertedPath $copy -SourcePath $delta
    Assert-Equal (Test-ConvertedDiskReusable -ConvertedPath $copy -SourcePath $delta) $true 'an unchanged disk reuses the copy'
    Assert-Equal (Test-ConvertedDiskReusable -ConvertedPath $copy -SourcePath $base) $false 'another disk does not reuse the copy'
    Add-Content -LiteralPath $delta -Value 'changed'
    Assert-Equal (Test-ConvertedDiskReusable -ConvertedPath $copy -SourcePath $delta) $false 'the VM ran since: the copy is not reused'
    Remove-ConvertedDisk $copy
    Assert-Equal ((Test-Path -LiteralPath $copy) -or (Test-Path -LiteralPath "$copy.source")) $false 'the copy and its note are deleted'
    Remove-ConvertedDisk ''   # nothing to delete is fine

    # The result file the check writes, read back as the wizard does.
    $resultPath = Join-Path $dir 'result.json'
    Assert-Equal (Read-CaptureCheckResult -Path $resultPath) $null 'no result file yet'
    Write-CaptureCheckResult -Path $resultPath -Result ([ordered]@{ state = 'running'; step = 'convert'; percent = 37; detail = 'Copying the disk'; convertedPath = $copy })
    $r = Read-CaptureCheckResult -Path $resultPath
    Assert-Equal $r.percent 37 'result file read back'
    Assert-Equal (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count) 0 'no temporary result file left'

    # What the page shows.
    $view = Get-CaptureCheckView -Checklist $noReader -Result $null
    Assert-Equal $view.Passed $false 'view: a failed checklist does not pass'
    Assert-Equal (@($view.Rows)[-1].Mark) $wait 'view: Windows waits for the checklist'
    Assert-Equal $view.Busy $false 'view: nothing is read while the checklist fails'
    Assert-Equal ((Get-Row $view 'reader').Mark) $cross 'view: a failed line has a cross'

    $view = Get-CaptureCheckView -Checklist $ok -Result $r
    Assert-Equal $view.Busy $true 'view: busy while the disk is copied'
    Assert-Equal $view.Percent 37 'view: the copy percent drives the bar'
    Assert-Equal ((Get-Row $view 'windows').Detail) 'Copying the disk (37%)' 'view: the running step and its percent'
    Assert-Equal ((Get-Row $view 'file').Mark) $tick 'view: a passed line has a tick'

    $failed = [pscustomobject]@{ state = 'failed'; error = 'No Windows found on the disk.' }
    $view = Get-CaptureCheckView -Checklist $ok -Result $failed
    Assert-Equal ((Get-Row $view 'windows').Detail) 'No Windows found on the disk.' 'view: the check error'
    Assert-Equal $view.Passed $false 'view: a failed check does not pass'

    $notGeneralized = [pscustomobject]@{ state = 'done'; windowsName = 'Windows 11 Pro 24H2 (build 26100)'; usedBytes = 20508000000; totalBytes = 128000000000
        generalized = $false; imageState = 'IMAGE_STATE_COMPLETE'; lastError = '' }
    $view = Get-CaptureCheckView -Checklist $ok -Result $notGeneralized
    Assert-Equal ((Get-Row $view 'windows').Detail) 'Windows 11 Pro 24H2 (build 26100), 19.1 GB used of 119.2 GB' 'view: Windows name and size'
    Assert-Equal ((Get-Row $view 'sysprep').Mark) $cross 'view: not generalized has a cross'
    Assert-Equal ((Get-Row $view 'sysprep').Detail -like 'Not generalized (IMAGE_STATE_COMPLETE)*') $true 'view: says why'
    Assert-Equal $view.Passed $false 'view: not generalized does not pass'

    # Sysprep on each PC: a disk that was only shut down passes; one Fast Startup hibernated does not.
    $view = Get-CaptureCheckView -Checklist $ok -Result $notGeneralized -SysprepAtDeploy
    Assert-Equal $view.Passed $true 'view: sysprep on each PC lets a not-sysprepped disk through'
    Assert-Equal ((Get-Row $view 'sysprep').Mark) $tick 'view: sysprep on each PC has a tick'
    Assert-Equal ((Get-Row $view 'sysprep').Name) 'Not sysprepped: each PC runs sysprep' 'view: sysprep on each PC says so'
    $hibernated = $notGeneralized.PSObject.Copy()
    $hibernated | Add-Member -NotePropertyName hibernated -NotePropertyValue $true -Force
    $view = Get-CaptureCheckView -Checklist $ok -Result $hibernated -SysprepAtDeploy
    Assert-Equal $view.Passed $false 'view: a hibernated disk does not pass'
    Assert-Equal ((Get-Row $view 'sysprep').Detail -like '*shutdown /s /t 0*') $true 'view: a hibernated disk says how to shut down fully'

    $notGeneralized.generalized = $true
    $view = Get-CaptureCheckView -Checklist $ok -Result $notGeneralized
    Assert-Equal $view.Passed $true 'view: generalized Windows passes'
    Assert-Equal (@($view.Rows | Where-Object { $_.Mark -ne $tick }).Count) 0 'view: every line has a tick'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Assert-Equal (Test-SlowImageTarget -DriveType Fixed -BusType NVMe) $false 'slow target: internal NVMe disk'
Assert-Equal (Test-SlowImageTarget -DriveType Fixed -BusType SATA) $false 'slow target: internal SATA disk'
Assert-Equal (Test-SlowImageTarget -DriveType Fixed -BusType USB) $true 'slow target: USB disk Windows calls Fixed'
Assert-Equal (Test-SlowImageTarget -DriveType Removable) $true 'slow target: USB stick'
Assert-Equal (Test-SlowImageTarget -DriveType Network) $true 'slow target: network share'

$captureText = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Capture-VMImage.ps1')
Assert-Equal ($captureText -match "'/Verify'") $false 'capture does not read the whole image back with /Verify'

# No script changes Microsoft Defender's settings. The build and the capture used to add temporary exclusions; on
# 2026-11-13 Defender blocked CaptureCheck.psm1 as malicious for that code, and the console could not start.
$src = Join-Path $repo 'src'
$touching = @(Get-ChildItem -LiteralPath $src -Recurse -File -Include *.ps1, *.psm1 |
    Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match '(?i)\b(Add|Set|Remove)-MpPreference\b|-Exclusion(Path|Process|Extension)\b' } | ForEach-Object Name)
Assert-Equal ($touching -join ', ') '' 'no script adds or removes Defender exclusions'

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All capture check tests passed.' -ForegroundColor Green
