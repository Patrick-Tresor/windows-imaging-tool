<#
.SYNOPSIS
    Captures a sysprepped Hyper-V reference VM to a WIM on the admin PC, without starting the VM.
.DESCRIPTION
    Runs on the admin PC (elevated, with Hyper-V and DISM). Build and sysprep the reference VM first:
    start it once, run Prepare-Reference.ps1, and let sysprep shut the VM down. This script then mounts
    the VM's virtual disk read-only, captures its Windows partition with DISM, and dismounts the disk.
    The VM is never started for the capture.

    The image goes to the Images folder of the content root, as Capture-GoldenImage.ps1 does. With
    -NewVersion an existing image of the same name is replaced only once the capture has succeeded, and
    the old one is kept as a version in Images\Previous\ (see ImageVersions.psm1).
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

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated PowerShell (Hyper-V and DISM need administrator rights).' }
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$imagesDir = Join-Path $ContentRoot 'Images'
$logDir = Join-Path $ContentRoot 'Logs'
$status = 'FAILED'
$staging = $null
$swapping = $false
$mounted = @()    # virtual disk files mounted here; dismounted in finally
$assigned = @()   # partition access paths given out here; removed in finally, before the dismount

try {
    $vm = Get-VM -Name $VMName
    if ($vm.State -ne 'Off') { throw "VM $VMName is $($vm.State). Let sysprep shut it down (Prepare-Reference.ps1), then run this again." }
    if ($vm.Generation -ne 2) { throw "VM $VMName is generation $($vm.Generation). Only generation 2 (UEFI) VMs are supported." }
    $existing = @((Join-Path $imagesDir "$Name.wim"), (Join-Path $imagesDir "$Name.swm")) | Where-Object { Test-Path $_ }
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $imagesDir. Pick another name, or capture it as a new version."
    }
    $disks = @(Get-VMHardDiskDrive -VMName $VMName)
    if (-not $disks) { throw "VM $VMName has no virtual disk." }
    if (-not $NoPrompt -and (Read-Host "Type YES to capture the disk of $VMName (the VM stays off)") -ne 'YES') {
        Write-DeployLog 'Cancelled by operator' -Level WARN
        $status = 'CANCELLED'
        return
    }

    # Mount each virtual disk read-only and look for the partition that holds the sysprepped Windows.
    $windowsRoot = $null
    foreach ($disk in $disks) {
        $vhd = Mount-VHD -Path $disk.Path -ReadOnly -PassThru
        $mounted += $disk.Path
        foreach ($part in @(Get-Partition -DiskNumber $vhd.DiskNumber | Where-Object Type -eq 'Basic')) {
            Add-PartitionAccessPath -DiskNumber $vhd.DiskNumber -PartitionNumber $part.PartitionNumber -AssignDriveLetter
            $letter = (Get-Partition -DiskNumber $vhd.DiskNumber -PartitionNumber $part.PartitionNumber).DriveLetter
            if (-not $letter) { continue }
            $path = "$($letter):\"
            $assigned += [pscustomobject]@{ Disk = $vhd.DiskNumber; Partition = $part.PartitionNumber; Path = $path }
            if (Test-Path (Join-Path $path 'Windows\System32\config\SYSTEM')) { $windowsRoot = $path; break }
        }
        if ($windowsRoot) { break }
    }
    if (-not $windowsRoot) { throw "No Windows install found on the disks of $VMName." }

    # Refuse to capture an image that skipped sysprep, since it would not be hardware-independent.
    $setupState = Join-Path $windowsRoot 'Windows\Setup\State\State.ini'
    if (-not (Test-Path $setupState) -or -not (Select-String -Path $setupState -Pattern 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Quiet)) {
        throw "Windows on $VMName was not generalized. Run Prepare-Reference.ps1 in the VM, then run this again."
    }

    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    # The capture goes to a staging folder first, so a failed capture leaves the current image alone.
    $staging = Join-Path $imagesDir ".capture-$Name"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $wim = Join-Path $staging "$Name.wim"

    Write-DeployLog "Capturing the disk of $VMName ($windowsRoot) to $imagesDir. The VM is not started."
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
    # Release the drive letters first; the disk cannot be dismounted while they are in use.
    foreach ($a in $assigned) { Remove-PartitionAccessPath -DiskNumber $a.Disk -PartitionNumber $a.Partition -AccessPath $a.Path -ErrorAction SilentlyContinue }
    foreach ($path in $mounted) { Dismount-VHD -Path $path -ErrorAction SilentlyContinue }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
