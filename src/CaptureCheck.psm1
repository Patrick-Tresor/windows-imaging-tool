# The checks the capture wizard runs on a VM's disk file before capturing it (Check the disk page), and the
# helpers Capture-VMImage.ps1 -CheckOnly uses to report what it found: which Windows is on the disk, how big it is,
# and whether sysprep has run. The check copies a VMDK, VDI or qcow2 disk to a temporary VHD to read it; that copy
# is kept and reused by the capture, as long as the VM's disk files have not changed since.
# PowerShell 5.1 compatible. Only Get-CaptureDiskChecklist touches the disk files; the rest is plain data.

Import-Module (Join-Path $PSScriptRoot 'VMwareVM.psm1')

function Find-VBoxManage {
    # VirtualBox's VBoxManage converts VMDK and VDI disks when qemu-img is not installed.
    $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:ProgramFiles) {
        $path = [IO.Path]::Combine($env:ProgramFiles, 'Oracle', 'VirtualBox', 'VBoxManage.exe')
        if ([IO.File]::Exists($path)) { return $path }
    }
}

function Format-DiskSize {
    # 20508000000 -> '19.1 GB' (always a dot, whatever the PC's language).
    param([double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1GB) { return [string]::Format($inv, '{0:0.0} GB', $Bytes / 1GB) }
    [string]::Format($inv, '{0:0} MB', [Math]::Max(0, $Bytes) / 1MB)
}

function Get-DiskSourceFiles {
    # The files that make up a disk: for a VMDK every .vmdk in its folder (the snapshot chain and its -s001 extents
    # all change when the VM runs), for other formats the file itself.
    param([Parameter(Mandatory)][string]$Path)
    $ext = [IO.Path]::GetExtension($Path)
    if ($ext -ieq '.vmdk') {
        $folder = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        return @([IO.Directory]::GetFiles($folder, '*.vmdk') | Sort-Object)
    }
    @([IO.Path]::GetFullPath($Path))
}

function Get-DiskSourceSignature {
    # Name, size and last write time of each file of the disk: when any of them changes, the VM has run since.
    param([Parameter(Mandatory)][string]$Path)
    $lines = foreach ($f in Get-DiskSourceFiles -Path $Path) {
        $info = New-Object IO.FileInfo($f)
        '{0}|{1}|{2}' -f $info.Name.ToLowerInvariant(), $info.Length, $info.LastWriteTimeUtc.Ticks
    }
    "$([IO.Path]::GetFullPath($Path).ToLowerInvariant())`n$(@($lines) -join "`n")"
}

function Save-ConvertedDiskSource {
    # Notes which disk a temporary VHD was copied from, next to it (<vhd>.source), for Test-ConvertedDiskReusable.
    param([Parameter(Mandatory)][string]$ConvertedPath, [Parameter(Mandatory)][string]$SourcePath)
    [IO.File]::WriteAllText("$ConvertedPath.source", (Get-DiskSourceSignature -Path $SourcePath), (New-Object Text.UTF8Encoding($false)))
}

function Test-ConvertedDiskReusable {
    # True when the temporary VHD exists and the disk it was copied from has not changed since.
    param([Parameter(Mandatory)][string]$ConvertedPath, [Parameter(Mandatory)][string]$SourcePath)
    if (-not [IO.File]::Exists($ConvertedPath) -or -not [IO.File]::Exists("$ConvertedPath.source")) { return $false }
    try { [IO.File]::ReadAllText("$ConvertedPath.source") -ceq (Get-DiskSourceSignature -Path $SourcePath) } catch { $false }
}

function Remove-ConvertedDisk {
    # Deletes a temporary VHD and its .source note. Never fails.
    param([string]$ConvertedPath)
    if (-not $ConvertedPath) { return }
    foreach ($f in $ConvertedPath, "$ConvertedPath.source") {
        try { if ([IO.File]::Exists($f)) { [IO.File]::Delete($f) } } catch { }
    }
}

function New-CheckRow([string]$Id, [string]$Name, $Ok, [string]$Detail) {
    [pscustomobject]@{ Id = $Id; Name = $Name; Ok = $Ok; Detail = $Detail }
}

function Get-CaptureDiskChecklist {
    <#
    .SYNOPSIS
        The quick checks on a VM's disk file, before anything is read from it: one row per check with Ok $true or
        $false and a short detail. ReadPath is the disk file that will be read (a VMware disk's newest snapshot).
        Passed is true when every row is Ok.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DiskPath,
        [string]$TempDir = [IO.Path]::GetTempPath(),
        [string]$QemuImg,
        [string]$VBoxManage
    )
    $rows = New-Object Collections.ArrayList
    $result = { param($read) [pscustomobject]@{ ReadPath = $read; Rows = @($rows); Passed = -not @($rows | Where-Object { $_.Ok -ne $true }).Count } }

    if (-not $DiskPath -or -not [IO.File]::Exists($DiskPath)) {
        [void]$rows.Add((New-CheckRow 'file' 'Disk file' $false 'Not found. Go back to the first page and choose the VM''s disk file again.'))
        return (& $result $null)
    }
    $full = [IO.Path]::GetFullPath($DiskPath)
    $folder = [IO.Path]::GetDirectoryName($full)
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    [void]$rows.Add((New-CheckRow 'file' 'Disk file' $true ([IO.Path]::GetFileName($full))))

    $network = $full.StartsWith('\\')
    $driveText = ''
    if (-not $network) {
        try {
            $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($full))
            $network = $drive.DriveType -eq [IO.DriveType]::Network
            $driveText = "Drive $($drive.Name.TrimEnd('\'))"
        } catch { }
    }
    [void]$rows.Add($(if ($network) {
        New-CheckRow 'local' 'On a drive in this PC' $false 'The disk is on a network drive. Copy the VM''s folder to a drive in this PC first: reading it over the network is slow and can break.'
    } else {
        New-CheckRow 'local' 'On a drive in this PC' $true $(if ($driveText) { $driveText } else { 'Local drive' })
    }))

    [void]$rows.Add($(if (Test-VMwareFolderInUse -Folder $folder) {
        New-CheckRow 'off' 'VM shut down' $false 'VMware still has the VM open (lock folders next to the disk). Let sysprep shut it down, or close it in VMware Workstation.'
    } else {
        New-CheckRow 'off' 'VM shut down' $true 'No VMware lock folders next to the disk.'
    }))

    $read = $full
    if ($ext -eq '.vmdk') {
        try {
            $read = Resolve-VmdkCurrentDisk -Path $full
            [void]$rows.Add($(if ($read -ne $full) {
                New-CheckRow 'snapshots' 'Snapshots' $true "The disk has snapshots, so the newest one is read: $([IO.Path]::GetFileName($read))."
            } else {
                New-CheckRow 'snapshots' 'Snapshots' $true 'No snapshots on top of this disk.'
            }))
        } catch {
            [void]$rows.Add((New-CheckRow 'snapshots' 'Snapshots' $false "Could not read the snapshot chain: $($_.Exception.Message)"))
        }
    }

    if ($ext -in '.vhd', '.vhdx') {
        [void]$rows.Add((New-CheckRow 'reader' 'Disk reader' $true 'VHD and VHDX disks are read in place, without a copy.'))
        return (& $result $read)
    }
    $reader = if ($QemuImg) { "qemu-img ($QemuImg)" } elseif ($VBoxManage -and $ext -in '.vmdk', '.vdi') { "VirtualBox ($VBoxManage)" }
    [void]$rows.Add($(if ($reader) {
        New-CheckRow 'reader' 'Disk reader' $true "$reader copies the disk to a temporary VHD that Windows can read."
    } else {
        New-CheckRow 'reader' 'Disk reader' $false 'qemu-img.exe is missing: install QEMU for Windows and add its folder to PATH.'
    }))

    # The temporary VHD holds what the disk files hold, so their total size is a safe guess.
    $need = [double]0
    foreach ($f in Get-DiskSourceFiles -Path $full) { $need += (New-Object IO.FileInfo($f)).Length }
    try {
        $tempDrive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($TempDir)))
        $free = [double]$tempDrive.AvailableFreeSpace
        $where = $tempDrive.Name.TrimEnd('\')
        [void]$rows.Add($(if ($free -ge $need + 2GB) {
            New-CheckRow 'space' 'Space for the temporary copy' $true "Needs about $(Format-DiskSize $need); $(Format-DiskSize $free) free on $where."
        } else {
            New-CheckRow 'space' 'Space for the temporary copy' $false "Needs about $(Format-DiskSize ($need + 2GB)) but only $(Format-DiskSize $free) is free on $where. Free some space, or set TEMP to a bigger drive."
        }))
    } catch {
        [void]$rows.Add((New-CheckRow 'space' 'Space for the temporary copy' $true "Needs about $(Format-DiskSize $need); could not read the free space."))
    }
    & $result $read
}

function ConvertFrom-RegQuery {
    # The values of a reg.exe query listing ("    ProductName    REG_SZ    Windows 10 Pro"), by name.
    param([AllowEmptyString()][string[]]$Lines)
    $values = @{}
    foreach ($line in $Lines) {
        if ($line -match '^\s+(\S+)\s+REG_\w+\s+(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    $values
}

function Get-WindowsDisplayName {
    # 'Windows 11 Pro 24H2 (build 26100)'. Windows 11 still says "Windows 10" in ProductName, so the build decides.
    param([string]$ProductName, [string]$DisplayVersion, [int]$Build)
    $name = if ($ProductName) { $ProductName.Trim() } else { 'Windows' }
    if ($Build -ge 22000) { $name = $name -replace '^Windows 10\b', 'Windows 11' }
    if ($DisplayVersion) { $name += " $($DisplayVersion.Trim())" }
    if ($Build -gt 0) { $name += " (build $Build)" }
    $name
}

function Write-CaptureCheckResult {
    # Saves what Capture-VMImage.ps1 -CheckOnly found so far; a temporary file swapped in, so the wizard never
    # reads half of it.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Result)
    try {
        $tmp = "$Path.tmp"
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Result -Depth 3), (New-Object Text.UTF8Encoding($false)))
        for ($try = 0; $try -lt 5; $try++) {
            try {
                if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
                [IO.File]::Move($tmp, $Path)
                break
            } catch { Start-Sleep -Milliseconds 50 }
        }
    } catch { }
}

function Read-CaptureCheckResult {
    # The check's result file, or $null while it is missing or being swapped.
    param([string]$Path)
    if (-not $Path) { return $null }
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch { $null }
}

function Get-CaptureCheckView {
    <#
    .SYNOPSIS
        What the Check the disk page shows: the checklist rows, then Windows on the disk and Sysprep, each with a
        tick, a cross or a circle (waiting). Passed is true when the capture may start. Busy and Percent drive the
        progress bar while the disk is read. $Result is Read-CaptureCheckResult's, or $null before the check ran.
    #>
    param([Parameter(Mandatory)]$Checklist, $Result)
    $tick = [string][char]0x2713; $cross = [string][char]0x2717; $wait = [string][char]0x25CB
    $view = { param($ok, $id, $name, $detail)
        [pscustomobject]@{
            Id = $id; Name = $name; Detail = $detail
            Mark  = $(if ($ok -eq $true) { $tick } elseif ($ok -eq $false) { $cross } else { $wait })
            Color = $(if ($ok -eq $true) { '#2E9E5B' } elseif ($ok -eq $false) { '#C4314B' } else { '#9CA3AF' })
        }
    }
    $rows = New-Object Collections.ArrayList
    foreach ($r in @($Checklist.Rows)) { [void]$rows.Add((& $view $r.Ok $r.Id $r.Name $r.Detail)) }
    $busy = $false; $percent = -1; $passed = $false

    if (-not $Checklist.Passed) {
        [void]$rows.Add((& $view $null 'windows' 'Windows on the disk' 'Read once every line above has a tick.'))
    } elseif (-not $Result -or "$($Result.state)" -eq 'running') {
        $busy = $true
        $percent = if ($Result -and [int]$Result.percent -ge 0) { [int]$Result.percent } else { -1 }
        $detail = if ($Result -and $Result.detail) { "$($Result.detail)" } else { 'Starting the check...' }
        if ($percent -ge 0) { $detail += " ($percent%)" }
        [void]$rows.Add((& $view $null 'windows' 'Windows on the disk' $detail))
    } elseif ("$($Result.state)" -ne 'done') {
        [void]$rows.Add((& $view $false 'windows' 'Windows on the disk' $(if ($Result.error) { "$($Result.error)" } else { 'The check stopped.' })))
    } else {
        $size = if ([double]$Result.totalBytes -gt 0) { ", $(Format-DiskSize ([double]$Result.usedBytes)) used of $(Format-DiskSize ([double]$Result.totalBytes))" } else { '' }
        [void]$rows.Add((& $view $true 'windows' 'Windows on the disk' "$($Result.windowsName)$size"))
        if ($Result.generalized -eq $true) {
            [void]$rows.Add((& $view $true 'sysprep' 'Sysprep has run (generalized)' 'Ready to capture.'))
            $passed = $true
        } else {
            $why = "Not generalized ($(if ($Result.imageState) { $Result.imageState } else { 'no sysprep state' })). Boot the VM, run the prepare command, let sysprep shut it down, then click Check again."
            if ($Result.lastError) { $why += " Last sysprep error: $($Result.lastError)" }
            [void]$rows.Add((& $view $false 'sysprep' 'Sysprep has run (generalized)' $why))
        }
    }
    [pscustomobject]@{ Rows = @($rows); Passed = $passed; Busy = $busy; Percent = $percent }
}

Export-ModuleMember -Function Find-VBoxManage, Format-DiskSize, Get-DiskSourceFiles, Get-DiskSourceSignature, Save-ConvertedDiskSource,
    Test-ConvertedDiskReusable, Remove-ConvertedDisk, Get-CaptureDiskChecklist, ConvertFrom-RegQuery, Get-WindowsDisplayName,
    Write-CaptureCheckResult, Read-CaptureCheckResult, Get-CaptureCheckView
