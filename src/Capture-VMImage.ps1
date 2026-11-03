<#
.SYNOPSIS
    Captures a shut-down reference VM's disk file to a WIM on the admin PC (VMware, VirtualBox and others).
.DESCRIPTION
    Runs on the admin PC (elevated, with DISM). The VM must already be shut down and its Windows already
    sysprepped: boot it, run Prepare-Reference.ps1 in it, and let sysprep shut it down. The file can be a VHD or
    VHDX, which is mounted directly, or a VMDK, VDI, qcow2 or raw disk, which is converted to a temporary VHD first
    with qemu-img or VirtualBox (whichever is installed). A VMware disk with snapshots is read at its newest
    snapshot. The script does not change the VM, its disk file, or its snapshots.

    The image goes to the Images folder of the content root, as Capture-GoldenImage.ps1 does. With -NewVersion
    an existing image of the same name is replaced only once the capture has succeeded, and the old one is kept
    as a version in Images\Previous\ (see ImageVersions.psm1).
.EXAMPLE
    .\src\Capture-VMImage.ps1 -DiskPath 'D:\VMware\Win11-Ref\Win11-Ref.vmdk' -Name Win11-24H2 -ContentRoot D:\DeployShare
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DiskPath,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ContentRoot,
    [string]$Description,
    [ValidateSet('fast', 'max')][string]$Compression = 'max',
    [int]$SplitSizeMB = 0,       # e.g. 3800 to fit a FAT32 USB; 0 = no split
    [switch]$NewVersion,         # replace an existing image, keeping the old one as a version
    [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VMwareVM.psm1') -Force

$logPath = Join-Path $env:TEMP 'Capture-VMImage.log'
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

function Get-DiskForCapture {
    # The VHD to mount for a disk file. Other formats are converted to a temporary VHD, which the caller deletes.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Disk file not found: $Path" }
    $qemu = Find-QemuImg
    $vbox = (Get-Command VBoxManage.exe -ErrorAction SilentlyContinue).Source
    if (-not $vbox -and (Test-Path (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'))) {
        $vbox = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
    }
    $temp = Join-Path $env:TEMP ("capture-{0}.vhd" -f [guid]::NewGuid().ToString('N'))
    $conversion = Get-DiskConversionCommand -SourcePath $Path -DestinationPath $temp -QemuImg $qemu -VBoxManage $vbox
    if (-not $conversion) { return [pscustomobject]@{ Path = $Path; Temp = $null } }
    Write-DeployLog "Converting $(Split-Path $Path -Leaf) to a temporary VHD. This copies the whole disk, so it needs free space."
    Invoke-Native -FilePath $conversion.FilePath -ArgumentList $conversion.ArgumentList
    Clear-MountBlockingAttributes -Path $temp
    [pscustomobject]@{ Path = $temp; Temp = $temp }
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
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$imagesDir = Join-Path $ContentRoot 'Images'
$logDir = Join-Path $ContentRoot 'Logs'
$status = 'FAILED'
$staging = $null
$swapping = $false
$tempDisk = $null     # a converted VHD made by this run; deleted in finally
$mount = $null        # the mounted virtual disks; dismounted in finally

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
        return
    }
    $disk = Get-DiskForCapture -Path $DiskPath
    $tempDisk = $disk.Temp
    $paths = @($disk.Path)

    # The capture reads the disk with the VM off.
    $mount = Mount-VMDisks -Paths $paths
    if (-not $mount.Root) { throw 'No Windows install found on the disk. If BitLocker is on in the VM, turn it off there (manage-bde -off C:), wait until it is decrypted, and capture again.' }
    $windowsRoot = $mount.Root
    if (-not (Test-Generalized -Root $windowsRoot)) {
        $state = Get-OfflineImageState -Root $windowsRoot
        $why = if ($state.LastError) { " Last sysprep error on this disk: $($state.LastError)" } else { '' }
        throw "Windows on this disk was not generalized (ImageState $($state.ImageState)). Boot the VM, run Prepare-Reference.ps1 in it as administrator, let sysprep shut the VM down, and run this again.$why"
    }

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
    Invoke-Native -FilePath 'dism.exe' -ArgumentList $captureArgs

    if ($SplitSizeMB -gt 0) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
            '/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $staging "$Name.swm")", "/FileSize:$SplitSizeMB")
        Remove-Item $wim
    }

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
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    if ($swapping) { Write-DeployLog "Failed while replacing the old image. The new capture is in $staging and the old one in $imagesDir\Previous." -Level WARN }
}
finally {
    # Release the disk before the temporary copy's deletion, which needs it free.
    if ($mount) { Dismount-VMDisks $mount }
    if ($tempDisk) { Remove-Item -LiteralPath $tempDisk -Force -ErrorAction SilentlyContinue }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
