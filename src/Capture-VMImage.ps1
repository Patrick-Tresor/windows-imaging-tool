<#
.SYNOPSIS
    Captures a shut-down reference VM's disk file to a WIM on the admin PC (VMware, VirtualBox and others).
.DESCRIPTION
    Runs on the admin PC (elevated, with DISM). The VM must already be shut down and its Windows already
    sysprepped: boot it, run Prepare-Reference.ps1 in it, and let sysprep shut it down. The file can be a VHD or
    VHDX, which is mounted directly, or a VMDK, VDI, qcow2 or raw disk, which is converted to a temporary VHD first
    with qemu-img or VirtualBox (whichever is installed). A VMware disk with snapshots is read at its newest
    snapshot. The script does not change the VM, its disk file, or its snapshots.

    -CheckOnly only reads the disk and reports, in the JSON file -ResultPath, which Windows is on it and whether
    sysprep has run (the capture wizard's Check the disk page). A VMDK is copied to a temporary VHD for that; the
    copy is kept, and the capture reuses it with -ReuseConvertedDisk while the VM's disk files are unchanged.
    -ProgressFile writes each step for the console's progress window (src\BuildSteps.psm1).

    -SysprepAtDeploy captures a VM that was only shut down (shutdown /s /t 0), not sysprepped: each PC it is
    deployed to then runs sysprep at its first start (src\SysprepAtDeploy.psm1). A VM that was hibernated by
    Fast Startup is refused, since its disk is not a clean copy.

    The image goes to the Images folder of the content root, as Capture-GoldenImage.ps1 does. With -NewVersion
    an existing image of the same name is replaced only once the capture has succeeded, and the old one is kept
    as a version in Images\Previous\ (see ImageVersions.psm1).
.EXAMPLE
    .\src\Capture-VMImage.ps1 -DiskPath 'D:\VMware\Win11-Ref\Win11-Ref.vmdk' -Name Win11-24H2 -ContentRoot D:\DeployShare
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiskPath,
    [string]$Name,
    [string]$ContentRoot,
    [string]$Description,
    [ValidateSet('fast', 'max')][string]$Compression = 'max',
    [int]$SplitSizeMB = 0,       # e.g. 3800 to fit a FAT32 USB; 0 = no split
    [switch]$NewVersion,         # replace an existing image, keeping the old one as a version
    [switch]$NoPrompt,
    [switch]$CheckOnly,          # only read the disk and write what was found to -ResultPath
    [string]$ResultPath,
    [string]$ReuseConvertedDisk, # a temporary VHD the check made; used when the disk has not changed since
    [string]$ProgressFile,       # step-by-step progress for the console's window
    [switch]$SysprepAtDeploy,    # capture a VM that was not sysprepped; each PC runs sysprep at its first start
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VMwareVM.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CaptureCheck.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SysprepAtDeploy.psm1') -Force

$logPath = if ($LogPath) { $LogPath } elseif ($CheckOnly) { Join-Path $env:TEMP 'Capture-VMImage-check.log' } else { Join-Path $env:TEMP 'Capture-VMImage.log' }
$logParent = Split-Path -Parent $logPath
if ($logParent -and -not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
Set-Content -Path $logPath -Value $null
# DeployCommon logs to X:\ (WinPE) by default; point it at a local file.
& (Get-Module DeployCommon) { param($p) $script:LogPath = $p } $logPath

function Mount-VMDisks {
    # Mounts the virtual disks and gives their partitions drive letters until the Windows one is found.
    # Returns the Windows root (e.g. E:\, or nothing) and what Dismount-VMDisks must undo.
    param([Parameter(Mandatory)][string[]]$Paths)
    $mount = [pscustomobject]@{ Root = $null; Mounted = @(); Assigned = @() }
    try {
        foreach ($path in $Paths) {
            # Mount-DiskImage is in every Windows 10/11 and mounts a VHD or VHDX read-only.
            $diskNumber = (Mount-DiskImage -ImagePath $path -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop | Get-Disk).Number
            $mount.Mounted += $path
            # GPT data partitions are Basic; MBR ones (BIOS VMs) are IFS.
            foreach ($part in @(Get-Partition -DiskNumber $diskNumber | Where-Object { $_.Type -in 'Basic', 'IFS' })) {
                Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber -AssignDriveLetter
                $letter = (Get-Partition -DiskNumber $diskNumber -PartitionNumber $part.PartitionNumber).DriveLetter
                if (-not $letter) { continue }
                $root = "$($letter):\"
                $mount.Assigned += [pscustomobject]@{ Disk = $diskNumber; Partition = $part.PartitionNumber; Path = $root }
                if (Test-Path (Join-Path $root 'Windows\System32\config\SYSTEM')) { $mount.Root = $root; break }
            }
            if ($mount.Root) { break }
        }
    }
    catch {
        Dismount-VMDisks $mount
        throw
    }
    $mount
}

function Dismount-VMDisks {
    # Removes the drive letters Mount-VMDisks gave out first, since a disk with letters in use cannot be dismounted.
    param([Parameter(Mandatory)]$Mount)
    foreach ($a in $Mount.Assigned) { Remove-PartitionAccessPath -DiskNumber $a.Disk -PartitionNumber $a.Partition -AccessPath $a.Path -ErrorAction SilentlyContinue }
    foreach ($m in $Mount.Mounted) { Dismount-DiskImage -ImagePath $m -ErrorAction SilentlyContinue | Out-Null }
}

function Test-Generalized {
    # True when the Windows at $Root has been sysprepped (generalized, resealed to OOBE).
    param([Parameter(Mandatory)][string]$Root)
    $setupState = Join-Path $Root 'Windows\Setup\State\State.ini'
    (Test-Path $setupState) -and [bool](Select-String -Path $setupState -Pattern 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Quiet)
}

function Test-NeedsConversion([string]$Path) { [IO.Path]::GetExtension($Path) -notin '.vhd', '.vhdx' }

function Get-DiskForCapture {
    # The VHD to mount for a disk file. Other formats are converted to $TempPath, which the caller deletes.
    # OnProgress gets the conversion's percent (or $null) every few seconds.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$TempPath, [scriptblock]$OnProgress = { })
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Disk file not found: $Path" }
    $conversion = Get-DiskConversionCommand -SourcePath $Path -DestinationPath $TempPath -QemuImg (Find-QemuImg) -VBoxManage (Find-VBoxManage)
    if (-not $conversion) { return [pscustomobject]@{ Path = $Path; Temp = $null } }
    Write-DeployLog "Converting $(Split-Path $Path -Leaf) to a temporary VHD. This copies the whole disk, so it needs free space."
    Invoke-NativeWithProgress -FilePath $conversion.FilePath -ArgumentList $conversion.ArgumentList -OnProgress $OnProgress
    Clear-MountBlockingAttributes -Path $TempPath
    [pscustomobject]@{ Path = $TempPath; Temp = $TempPath }
}

function Get-OfflineWindowsInfo {
    # Name, version and size of the Windows at $Root (a mounted disk), read from a copy of its SOFTWARE hive so the
    # disk itself stays untouched. The build also comes from ntoskrnl.exe, for when the hive cannot be loaded.
    param([Parameter(Mandatory)][string]$Root)
    $build = 0
    $kernel = Join-Path $Root 'Windows\System32\ntoskrnl.exe'
    if (Test-Path -LiteralPath $kernel) { $build = [Diagnostics.FileVersionInfo]::GetVersionInfo($kernel).FileBuildPart }
    $values = @{}
    $copy = Join-Path $env:TEMP ("capture-hive-{0}" -f [guid]::NewGuid().ToString('N'))
    $key = 'HKLM\ImagingToolCapture'
    try {
        New-Item -ItemType Directory -Path $copy -Force | Out-Null
        # The .LOG1/.LOG2 files carry the last changes when Windows was shut down without flushing the hive.
        Get-ChildItem -LiteralPath (Join-Path $Root 'Windows\System32\config') -Filter 'SOFTWARE*' -File -Force |
            Where-Object { $_.Name -match '^SOFTWARE(\.LOG\d?)?$' } | Copy-Item -Destination $copy
        & reg.exe load $key (Join-Path $copy 'SOFTWARE') 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try { $values = ConvertFrom-RegQuery -Lines @(& reg.exe query "$key\Microsoft\Windows NT\CurrentVersion" 2>$null) }
            finally {
                for ($i = 0; $i -lt 5; $i++) {
                    & reg.exe unload $key 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { break }
                    Start-Sleep -Milliseconds 500
                }
            }
        } else { Write-DeployLog 'Could not load the disk''s registry to read the Windows edition; showing the build only.' -Level WARN }
    } catch {
        Write-DeployLog "Could not read the Windows edition: $($_.Exception.Message)" -Level WARN
    } finally {
        Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($values.CurrentBuild -match '^\d+$') { $build = [int]$values.CurrentBuild }
    $drive = New-Object IO.DriveInfo($Root)
    [pscustomobject]@{
        Name       = Get-WindowsDisplayName -ProductName $values.ProductName -DisplayVersion $values.DisplayVersion -Build $build
        Build      = $build
        TotalBytes = [double]$drive.TotalSize
        UsedBytes  = [double]($drive.TotalSize - $drive.TotalFreeSpace)
    }
}

function Clear-MountBlockingAttributes {
    # Windows mounts a VHD only when the file itself is not sparse, compressed or encrypted (0xC03A001A). qemu-img
    # writes a sparse file, and a TEMP folder can be compressed, so undo both. The VHD keeps its own format.
    param([Parameter(Mandatory)][string]$Path)
    $attributes = (Get-Item -LiteralPath $Path).Attributes
    if ($attributes -band [IO.FileAttributes]::SparseFile) { Invoke-Native -FilePath 'fsutil.exe' -ArgumentList @('sparse', 'setflag', $Path, '0') }
    if ($attributes -band [IO.FileAttributes]::Compressed) { Invoke-Native -FilePath 'compact.exe' -ArgumentList @('/u', '/q', $Path) }
    $attributes = (Get-Item -LiteralPath $Path).Attributes
    foreach ($flag in 'SparseFile', 'Compressed', 'Encrypted') {
        if ($attributes -band [IO.FileAttributes]$flag) {
            throw "Windows cannot mount $Path because the file is marked $flag. Set TEMP to a folder on a plain NTFS drive and run this again."
        }
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (mounting disks and DISM need administrator rights).' }

if ($CheckOnly) {
    # Read the disk and report; the wizard reads -ResultPath twice a second. The VM and its disk are not changed.
    if (-not $ResultPath) { throw '-CheckOnly needs -ResultPath.' }
    $check = [ordered]@{
        state = 'running'; step = 'start'; percent = -1; detail = 'Starting the check...'; error = ''
        readPath = ''; convertedPath = ''; windowsName = ''; build = 0; usedBytes = 0; totalBytes = 0
        imageState = ''; generalized = $false; hibernated = $false; lastError = ''; log = $logPath
    }
    Write-CaptureCheckResult -Path $ResultPath -Result $check
    $mount = $null
    try {
        if (-not (Test-Path -LiteralPath $DiskPath -PathType Leaf)) { throw "Disk file not found: $DiskPath" }
        $DiskPath = (Resolve-Path -LiteralPath $DiskPath).ProviderPath
        if (Test-VMwareFolderInUse -Folder (Split-Path -Parent $DiskPath)) { throw 'VMware still has the VM open. Shut it down, then click Check again.' }
        $read = Resolve-VmdkCurrentDisk -Path $DiskPath
        $check.readPath = $read
        Write-DeployLog "Checking $read"
        if (Test-NeedsConversion $read) {
            $check.step = 'convert'
            $check.convertedPath = Join-Path $env:TEMP ("capture-check-{0}.vhd" -f [guid]::NewGuid().ToString('N'))
            $check.detail = 'Copying the VM''s disk to read it (the capture reuses this copy)'
            Write-CaptureCheckResult -Path $ResultPath -Result $check
            $disk = Get-DiskForCapture -Path $read -TempPath $check.convertedPath -OnProgress {
                param($pct)
                $check.percent = if ($null -ne $pct) { [int]$pct } else { -1 }
                Write-CaptureCheckResult -Path $ResultPath -Result $check
            }
        } else {
            $disk = [pscustomobject]@{ Path = $read; Temp = $null }
        }
        $check.step = 'read'; $check.percent = -1; $check.detail = 'Reading Windows on the disk'
        Write-CaptureCheckResult -Path $ResultPath -Result $check
        $mount = Mount-VMDisks -Paths @($disk.Path)
        if (-not $mount.Root) { throw 'No Windows found on the disk. If BitLocker is on in the VM, turn it off there (manage-bde -off C:), wait until it is decrypted, and check again.' }
        $info = Get-OfflineWindowsInfo -Root $mount.Root
        $offline = Get-OfflineImageState -Root $mount.Root
        $check.windowsName = $info.Name; $check.build = $info.Build
        $check.usedBytes = $info.UsedBytes; $check.totalBytes = $info.TotalBytes
        $check.imageState = "$($offline.ImageState)"; $check.lastError = "$($offline.LastError)"
        $check.generalized = Test-Generalized -Root $mount.Root
        $check.hibernated = Test-HibernatedWindows -Root $mount.Root
        Write-DeployLog "Found $($info.Name), $(Format-DiskSize $info.UsedBytes) used; generalized: $($check.generalized) ($($check.imageState)); hibernated: $($check.hibernated)"
        $check.state = 'done'; $check.detail = ''
    }
    catch {
        Write-DeployLog $_.Exception.Message -Level ERROR
        $check.state = 'failed'
        $check.error = (@("$($_.Exception.Message)" -split "`r?`n" | Where-Object { $_.Trim() })[0])
    }
    finally {
        if ($mount) { Dismount-VMDisks $mount }
        # The copy is kept for the capture when the disk could be read and the wizard was not closed meanwhile. A disk
        # that is not sysprepped can still be captured with sysprep on each PC; the wizard deletes an unused copy.
        $keep = $check.convertedPath -and $check.state -eq 'done' -and -not (Test-Path -LiteralPath "$ResultPath.cancel")
        if ($check.convertedPath) {
            if ($keep) { Save-ConvertedDiskSource -ConvertedPath $check.convertedPath -SourcePath $check.readPath }
            else { Remove-ConvertedDisk $check.convertedPath; $check.convertedPath = '' }
        }
        Remove-Item -LiteralPath "$ResultPath.cancel" -Force -ErrorAction SilentlyContinue
        Write-CaptureCheckResult -Path $ResultPath -Result $check
    }
    if ($check.state -ne 'done') { exit 1 }
    exit 0
}

if (-not $Name) { throw '-Name is required.' }
if (-not $ContentRoot) { throw '-ContentRoot is required.' }
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$imagesDir = Join-Path $ContentRoot 'Images'
$logDir = Join-Path $ContentRoot 'Logs'
$status = 'FAILED'
$staging = $null
$swapping = $false
$tempDisk = $null     # a converted VHD made by this run; deleted in finally
$mount = $null        # the mounted virtual disks; dismounted in finally

Start-BuildProgress -Path $ProgressFile -Title "Capturing $Name" -LogPath $logPath -Steps @(
    , @('convert', 'Copying the VM''s disk')
    , @('read', 'Reading Windows on the disk')
    , @('capture', 'Capturing the image')
    , @('split', 'Splitting into 3.8 GB parts')
    , @('save', 'Saving to the Images folder')
)

try {
    $existing = @((Join-Path $imagesDir "$Name.wim"), (Join-Path $imagesDir "$Name.swm")) | Where-Object { Test-Path $_ }
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $imagesDir. Pick another name, or capture it as a new version."
    }

    if (-not (Test-Path -LiteralPath $DiskPath -PathType Leaf)) { throw "Disk file not found: $DiskPath" }
    $DiskPath = (Resolve-Path -LiteralPath $DiskPath).ProviderPath
    if (Test-VMwareFolderInUse -Folder (Split-Path -Parent $DiskPath)) {
        throw "VMware has the VM in $(Split-Path -Parent $DiskPath) open (there are .lck folders next to it). Shut the VM down, or close it in VMware Workstation, and run this again."
    }
    # A VMware disk with snapshots on top holds the VM as it was at the first snapshot; the newest delta is now.
    $current = Resolve-VmdkCurrentDisk -Path $DiskPath
    if ($current -ne $DiskPath) {
        Write-DeployLog "$(Split-Path -Leaf $DiskPath) has snapshots on top of it, so reading $(Split-Path -Leaf $current), the VM's current disk." -Level WARN
        $DiskPath = $current
    }
    if (-not $NoPrompt -and (Read-Host "Type YES to capture $(Split-Path $DiskPath -Leaf) (its VM must be shut down)") -ne 'YES') {
        Write-DeployLog 'Cancelled by operator' -Level WARN
        $status = 'CANCELLED'
        Stop-BuildProgress -Message 'Cancelled'
        return
    }
    if ($ReuseConvertedDisk -and (Test-ConvertedDiskReusable -ConvertedPath $ReuseConvertedDisk -SourcePath $DiskPath)) {
        Write-DeployLog "Reusing $ReuseConvertedDisk, the copy the disk check made (the disk has not changed since)."
        $disk = [pscustomobject]@{ Path = $ReuseConvertedDisk; Temp = $ReuseConvertedDisk }
        Complete-BuildStep 'convert' -State reused -Detail 'Copied during the disk check'
    } else {
        if ($ReuseConvertedDisk) {
            Write-DeployLog 'The VM''s disk changed after the check, so it is copied again.' -Level WARN
            Remove-ConvertedDisk $ReuseConvertedDisk
        }
        if (Test-NeedsConversion $DiskPath) {
            Start-BuildStep 'convert' -Detail (Split-Path -Leaf $DiskPath)
            $tempPath = Join-Path $env:TEMP ("capture-{0}.vhd" -f [guid]::NewGuid().ToString('N'))
            $tempDisk = $tempPath   # deleted in finally, even when the conversion fails halfway
            $disk = Get-DiskForCapture -Path $DiskPath -TempPath $tempPath -OnProgress {
                param($pct) Set-BuildStepProgress 'convert' -Percent $(if ($null -ne $pct) { $pct } else { -1 })
            }
            Complete-BuildStep 'convert'
        } else {
            $disk = [pscustomobject]@{ Path = $DiskPath; Temp = $null }
            Complete-BuildStep 'convert' -State skipped -Detail 'VHD and VHDX disks are read in place'
        }
    }
    $tempDisk = $disk.Temp
    $paths = @($disk.Path)

    # The capture reads the disk with the VM off.
    Start-BuildStep 'read'
    $mount = Mount-VMDisks -Paths $paths
    if (-not $mount.Root) { throw 'No Windows install found on the disk. If BitLocker is on in the VM, turn it off there (manage-bde -off C:), wait until it is decrypted, and capture again.' }
    $windowsRoot = $mount.Root
    if (-not (Test-Generalized -Root $windowsRoot)) {
        $state = Get-OfflineImageState -Root $windowsRoot
        if (-not $SysprepAtDeploy) {
            $why = if ($state.LastError) { " Last sysprep error on this disk: $($state.LastError)" } else { '' }
            throw "Windows on this disk was not generalized (ImageState $($state.ImageState)). Boot the VM, run Prepare-Reference.ps1 in it as administrator, let sysprep shut the VM down, and run this again (or capture with -SysprepAtDeploy).$why"
        }
        if (Test-HibernatedWindows -Root $windowsRoot) {
            throw 'Windows on this disk was hibernated by Fast Startup, not shut down. Start the VM, run shutdown /s /t 0 in it, and capture again.'
        }
        Write-DeployLog "Windows on this disk was not sysprepped ($($state.ImageState)): each PC deployed from this image runs sysprep at its first start." -Level WARN
    }
    Complete-BuildStep 'read' -Detail $(try { (Get-OfflineWindowsInfo -Root $windowsRoot).Name } catch { '' })

    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    # The capture goes to a staging folder first, so a failed capture leaves the current image alone.
    $staging = Join-Path $imagesDir ".capture-$Name"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $wim = Join-Path $staging "$Name.wim"

    Write-DeployLog "Capturing the disk ($windowsRoot) to $imagesDir."
    $captureArgs = @('/Capture-Image', "/ImageFile:$wim", "/CaptureDir:$windowsRoot", "/Name:$Name",
        "/Compress:$Compression", '/CheckIntegrity', '/Verify')
    if ($Description) { $captureArgs += "/Description:$Description" }
    Start-BuildStep 'capture'
    Invoke-NativeWithProgress -FilePath 'dism.exe' -ArgumentList $captureArgs -OnProgress {
        param($pct) Set-BuildStepProgress 'capture' -Percent $(if ($null -ne $pct) { $pct } else { -1 })
    }
    Complete-BuildStep 'capture' -Detail "$(Format-DiskSize (Get-Item -LiteralPath $wim).Length)"

    if ($SplitSizeMB -gt 0) {
        Start-BuildStep 'split'
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
            '/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $staging "$Name.swm")", "/FileSize:$SplitSizeMB")
        Remove-Item $wim
        Complete-BuildStep 'split'
    }
    Start-BuildStep 'save'

    if ($existing) {
        $swapping = $true
        foreach ($old in $existing) {
            $v = Save-ImageVersion -ImagePath $old -Move -Reason 'Replaced by a new capture'
            Write-DeployLog "Kept the previous $(Split-Path $old -Leaf) as version $($v.Version)"
        }
    }
    Get-ChildItem -LiteralPath $staging -File | Move-Item -Destination $imagesDir
    Remove-Item -LiteralPath $staging -Recurse -Force
    $newLeaf = if ($SplitSizeMB -gt 0) { "$Name.swm" } else { "$Name.wim" }
    if ($existing) {
        if ($existing | Where-Object { (Split-Path $_ -Leaf) -ne $newLeaf }) {
            Write-DeployLog "The new version is $newLeaf but the old one was $(($existing | ForEach-Object { Split-Path $_ -Leaf }) -join ', '). Point answer files at Images\$newLeaf." -Level WARN
        }
        try {
            $pruned = @(Invoke-ImageVersionRetention -ContentRoot $ContentRoot -ImagePath (Join-Path $imagesDir $newLeaf))
            if ($pruned) { Write-DeployLog "Deleted older versions beyond the keep limit: $(($pruned.Version) -join ', ')" }
        } catch { Write-DeployLog "Could not apply the keep limit: $($_.Exception.Message)" -Level WARN }
    }

    Write-DeployLog "Captured the disk to $imagesDir\$newLeaf"
    Complete-BuildStep 'save' -Detail "Images\$newLeaf"
    $status = 'OK'
    Stop-BuildProgress
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    Stop-BuildProgress -Message $_.Exception.Message
    if ($swapping) { Write-DeployLog "Failed while replacing the old image. The new capture is in $staging and the old one in $imagesDir\Previous." -Level WARN }
}
finally {
    # Release the disk before the temporary copy's deletion, which needs it free.
    if ($mount) { Dismount-VMDisks $mount }
    if ($tempDisk) { Remove-ConvertedDisk $tempDisk }
    # The check's copy is used once: reused above, or stale, or never reached because the capture failed earlier.
    if ($ReuseConvertedDisk) { Remove-ConvertedDisk $ReuseConvertedDisk }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
