<#
.SYNOPSIS
    Captures a Hyper-V reference VM to a WIM on the admin PC, with no manual sysprep and no password.
.DESCRIPTION
    Runs on the admin PC (elevated, with Hyper-V and DISM).

    If the VM's Windows has not been sysprepped yet, the script:
      1. takes a checkpoint of the VM, so it can be rolled back afterwards;
      2. writes a one-time boot command into the VM's disk, offline: Windows Setup runs
         Prepare-Reference.ps1 as SYSTEM on the next boot, and sysprep shuts the VM down;
      3. starts the VM and waits for it to shut down;
      4. removes that boot command and script again, so the image does not carry them.
    A VM whose Windows is already sysprepped is not started, because booting it would run Windows setup again.

    The script then mounts the VM's virtual disks read-only, captures the Windows partition with DISM, and
    dismounts them. Finally it rolls the VM back to the checkpoint, so the reference can be used again. The
    image goes to the Images folder of the content root, as Capture-GoldenImage.ps1 does. With -NewVersion an
    existing image of the same name is replaced only once the capture has succeeded, and the old one is kept
    as a version in Images\Previous\ (see ImageVersions.psm1).

    Untested on Windows: the Setup\CmdLine boot hook, sysprep run that way, and the checkpoint rollback.
.EXAMPLE
    .\src\Capture-VMImage.ps1 -VMName Win11-Ref -Name Win11-24H2-Enterprise -ContentRoot D:\DeployShare
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
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

$logPath = Join-Path $env:TEMP 'Capture-VMImage.log'
Set-Content -Path $logPath -Value $null
# DeployCommon logs to X:\ (WinPE) by default; point it at a local file.
& (Get-Module DeployCommon) { param($p) $script:LogPath = $p } $logPath

function Mount-VMDisks {
    # Mounts the virtual disks and gives their partitions drive letters until the Windows one is found.
    # Returns the Windows root (e.g. E:\) and what Dismount-VMDisks must undo.
    param([Parameter(Mandatory)][string[]]$Paths, [switch]$ReadWrite)
    $mount = [pscustomobject]@{ Root = $null; Mounted = @(); Assigned = @() }
    try {
        foreach ($path in $Paths) {
            $vhd = Mount-VHD -Path $path -ReadOnly:(-not $ReadWrite) -PassThru
            $mount.Mounted += $path
            foreach ($part in @(Get-Partition -DiskNumber $vhd.DiskNumber | Where-Object Type -eq 'Basic')) {
                Add-PartitionAccessPath -DiskNumber $vhd.DiskNumber -PartitionNumber $part.PartitionNumber -AssignDriveLetter
                $letter = (Get-Partition -DiskNumber $vhd.DiskNumber -PartitionNumber $part.PartitionNumber).DriveLetter
                if (-not $letter) { continue }
                $root = "$($letter):\"
                $mount.Assigned += [pscustomobject]@{ Disk = $vhd.DiskNumber; Partition = $part.PartitionNumber; Path = $root }
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
    foreach ($path in $Mount.Mounted) { Dismount-VHD -Path $path -ErrorAction SilentlyContinue }
}

function Test-Generalized {
    # True when the Windows at $Root has been sysprepped (generalized, resealed to OOBE).
    param([Parameter(Mandatory)][string]$Root)
    $setupState = Join-Path $Root 'Windows\Setup\State\State.ini'
    (Test-Path $setupState) -and [bool](Select-String -Path $setupState -Pattern 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Quiet)
}

function Edit-OfflineSetupKey {
    # Loads the SYSTEM hive of the Windows at $Root as HKLM\OFFSYS, runs $Edit on its Setup key, and unloads it.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$Edit)
    $hive = Join-Path $Root 'Windows\System32\config\SYSTEM'
    Invoke-Native -FilePath 'reg.exe' -ArgumentList @('load', 'HKLM\OFFSYS', $hive)
    try {
        & $Edit 'HKLM:\OFFSYS\Setup'
    }
    finally {
        # Registry handles must be released before the hive can be unloaded.
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        Invoke-Native -FilePath 'reg.exe' -ArgumentList @('unload', 'HKLM\OFFSYS')
    }
}

function Set-SysprepOnBoot {
    # Copies Prepare-Reference.ps1 into the Windows at $Root and has Windows Setup run it on the next boot, as SYSTEM.
    param([Parameter(Mandatory)][string]$Root)
    $scripts = Join-Path $Root 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Prepare-Reference.ps1') -Destination $scripts -Force
    Edit-OfflineSetupKey -Root $Root -Edit {
        param($Key)
        New-Item -Path $Key -Force | Out-Null
        Set-ItemProperty -Path $Key -Name 'SetupType' -Value 2
        Set-ItemProperty -Path $Key -Name 'CmdLine' -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Prepare-Reference.ps1'
    }
}

function Clear-SysprepOnBoot {
    # Removes the boot-time command and the script, so the captured image does not run them on a deployed PC.
    param([Parameter(Mandatory)][string]$Root)
    Edit-OfflineSetupKey -Root $Root -Edit {
        param($Key)
        Remove-ItemProperty -Path $Key -Name 'CmdLine' -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $Key -Name 'SetupType' -Value 0
        if ((Get-ItemProperty -Path $Key -Name 'CmdLine' -ErrorAction SilentlyContinue).CmdLine) { throw 'Could not remove the boot-time command from the VM disk.' }
    }
    Remove-Item -LiteralPath (Join-Path $Root 'Windows\Setup\Scripts\Prepare-Reference.ps1') -Force -ErrorAction SilentlyContinue
}

function Wait-VMOff {
    # Waits for the VM to shut down, which sysprep does when it finishes.
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-VM -Name $VMName).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) { throw "$VMName is still running $Minutes minutes after the boot-time sysprep. It did not finish; check the VM." }
        Start-Sleep -Seconds 15
    }
}

function Restore-PreCaptureCheckpoint {
    # Rolls the VM back to the checkpoint taken before the boot-time sysprep, so the reference can be used again.
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$Name)
    try {
        if ((Get-VM -Name $VMName).State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force }
        Restore-VMCheckpoint -VMName $VMName -Name $Name -Confirm:$false
        Remove-VMCheckpoint -VMName $VMName -Name $Name -Confirm:$false
        Write-DeployLog "Rolled $VMName back to the checkpoint from before the capture."
    }
    catch {
        Write-DeployLog "Could not roll $VMName back to '$Name': $($_.Exception.Message). Restore that checkpoint by hand." -Level WARN
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (Hyper-V and DISM need administrator rights).' }
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$imagesDir = Join-Path $ContentRoot 'Images'
$logDir = Join-Path $ContentRoot 'Logs'
$status = 'FAILED'
$staging = $null
$swapping = $false
$checkpoint = $null   # set only when this run changes the VM; rolled back in finally
$mount = $null        # the mounted virtual disks; dismounted in finally

try {
    $vm = Get-VM -Name $VMName
    if ($vm.State -ne 'Off') { throw "VM $VMName is $($vm.State). Shut it down first; this script starts it itself when it needs to." }
    if ($vm.Generation -ne 2) { throw "VM $VMName is generation $($vm.Generation). Only generation 2 (UEFI) VMs are supported." }
    $existing = @((Join-Path $imagesDir "$Name.wim"), (Join-Path $imagesDir "$Name.swm")) | Where-Object { Test-Path $_ }
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $imagesDir. Pick another name, or capture it as a new version."
    }
    $paths = @(Get-VMHardDiskDrive -VMName $VMName | ForEach-Object { $_.Path })
    if (-not $paths) { throw "VM $VMName has no virtual disk." }
    if (-not $NoPrompt -and (Read-Host "Type YES to capture the disk of $VMName") -ne 'YES') {
        Write-DeployLog 'Cancelled by operator' -Level WARN
        $status = 'CANCELLED'
        return
    }

    # Look at the disk before deciding whether to start the VM: booting a sysprepped Windows runs its setup again.
    $probe = Mount-VMDisks -Paths $paths
    try {
        if (-not $probe.Root) { throw "No Windows install found on the disks of $VMName." }
        $needsPrep = -not (Test-Generalized -Root $probe.Root)
    }
    finally { Dismount-VMDisks $probe }

    if ($needsPrep) {
        $checkpoint = "Before capture of $Name $(Get-Date -Format 'yyyyMMdd-HHmm')"
        Checkpoint-VM -Name $VMName -SnapshotName $checkpoint
        Write-DeployLog "Made checkpoint '$checkpoint'. The VM is rolled back to it after the capture."
        # Writes now go to a new disk file, so the disk paths have changed.
        $paths = @(Get-VMHardDiskDrive -VMName $VMName | ForEach-Object { $_.Path })

        $mount = Mount-VMDisks -Paths $paths -ReadWrite
        try {
            if (-not $mount.Root) { throw "No Windows install found on the disks of $VMName." }
            Set-SysprepOnBoot -Root $mount.Root
        }
        finally { Dismount-VMDisks $mount; $mount = $null }

        Write-DeployLog "Starting $VMName. Windows runs Prepare-Reference.ps1 at boot, and sysprep shuts the VM down when it is done."
        Start-VM -Name $VMName
        Wait-VMOff -VMName $VMName -Minutes 60
        Write-DeployLog "$VMName is off after the boot-time sysprep."

        # The boot-time command must not end up in the image.
        $mount = Mount-VMDisks -Paths $paths -ReadWrite
        try {
            if (-not $mount.Root) { throw "No Windows install found on the disks of $VMName." }
            Clear-SysprepOnBoot -Root $mount.Root
        }
        finally { Dismount-VMDisks $mount; $mount = $null }
    }
    else {
        Write-DeployLog "$VMName is already sysprepped, so the VM is not started."
    }

    # The capture reads the disk with the VM off.
    $mount = Mount-VMDisks -Paths $paths
    if (-not $mount.Root) { throw "No Windows install found on the disks of $VMName." }
    $windowsRoot = $mount.Root
    if (-not (Test-Generalized -Root $windowsRoot)) {
        throw "Windows on $VMName was not generalized. Prepare-Reference.ps1 did not run or did not finish; check the VM and run this again."
    }

    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    # The capture goes to a staging folder first, so a failed capture leaves the current image alone.
    $staging = Join-Path $imagesDir ".capture-$Name"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $wim = Join-Path $staging "$Name.wim"

    Write-DeployLog "Capturing the disk of $VMName ($windowsRoot) to $imagesDir."
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

    Write-DeployLog "Captured the disk of $VMName to $imagesDir\$newLeaf"
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    if ($swapping) { Write-DeployLog "Failed while replacing the old image. The new capture is in $staging and the old one in $imagesDir\Previous." -Level WARN }
}
finally {
    # Release the disk before the rollback, which needs it free.
    if ($mount) { Dismount-VMDisks $mount }
    if ($checkpoint) { Restore-PreCaptureCheckpoint -VMName $VMName -Name $checkpoint }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
