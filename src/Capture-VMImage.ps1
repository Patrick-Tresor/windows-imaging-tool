<#
.SYNOPSIS
    Captures a Hyper-V reference VM to a WIM on the admin PC. The VM is started only to run Prepare-Reference.ps1.
.DESCRIPTION
    Runs on the admin PC (elevated, with Hyper-V and DISM).

    If the VM's Windows has not been sysprepped yet, the script starts the VM once and runs
    Prepare-Reference.ps1 inside it over PowerShell Direct, using an administrator account you enter.
    Sysprep then shuts the VM down. A VM whose Windows is already sysprepped is not started, because
    booting it would run Windows setup again.

    The script then mounts the VM's virtual disks read-only, captures the Windows partition with DISM,
    and dismounts them. The image goes to the Images folder of the content root, as Capture-GoldenImage.ps1
    does. With -NewVersion an existing image of the same name is replaced only once the capture has
    succeeded, and the old one is kept as a version in Images\Previous\ (see ImageVersions.psm1).
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
    # Mounts the virtual disks read-only and gives their partitions drive letters until the Windows one is found.
    # Returns the Windows root (e.g. E:\, or nothing) and what Dismount-VMDisks must undo.
    param([Parameter(Mandatory)][string[]]$Paths)
    $mount = [pscustomobject]@{ Root = $null; Mounted = @(); Assigned = @() }
    try {
        foreach ($path in $Paths) {
            $vhd = Mount-VHD -Path $path -ReadOnly -PassThru
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

function Invoke-ReferencePrep {
    # Starts the VM, runs Prepare-Reference.ps1 inside it over PowerShell Direct, and waits for sysprep to shut it down.
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][pscredential]$Credential)
    $prepare = Join-Path $PSScriptRoot 'Prepare-Reference.ps1'
    Write-DeployLog "Starting $VMName once to run Prepare-Reference.ps1. Sysprep shuts it down when it is done."
    Start-VM -Name $VMName

    # PowerShell Direct answers once Windows has started and the credentials are accepted.
    $deadline = (Get-Date).AddMinutes(20)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) {
        try { $ready = [bool](Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop) }
        catch { Start-Sleep -Seconds 10 }
    }
    if (-not $ready) { throw "Could not reach $VMName over PowerShell Direct within 20 minutes. Check the administrator password and that Windows has started." }

    try { Invoke-Command -VMName $VMName -Credential $Credential -FilePath $prepare -ErrorAction Stop }
    catch { Write-DeployLog "The session in $VMName ended: $($_.Exception.Message). That is expected when sysprep shuts the VM down." -Level WARN }

    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-VM -Name $VMName).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) { throw "$VMName is still running 30 minutes after Prepare-Reference.ps1. It did not reach sysprep; check the VM." }
        Start-Sleep -Seconds 15
    }
    Write-DeployLog "$VMName is off after Prepare-Reference.ps1."
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
$mount = $null    # the mounted virtual disks; dismounted in finally

try {
    $vm = Get-VM -Name $VMName
    if ($vm.State -ne 'Off') { throw "VM $VMName is $($vm.State). Shut it down first; this script starts it only to run Prepare-Reference.ps1." }
    if ($vm.Generation -ne 2) { throw "VM $VMName is generation $($vm.Generation). Only generation 2 (UEFI) VMs are supported." }
    $existing = @((Join-Path $imagesDir "$Name.wim"), (Join-Path $imagesDir "$Name.swm")) | Where-Object { Test-Path $_ }
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $imagesDir. Pick another name, or capture it as a new version."
    }
    $disks = @(Get-VMHardDiskDrive -VMName $VMName)
    if (-not $disks) { throw "VM $VMName has no virtual disk." }
    $paths = @($disks | ForEach-Object { $_.Path })
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
        $credential = Get-Credential -Message "Administrator account in $VMName, used once to run Prepare-Reference.ps1"
        if (-not $credential) { throw 'No administrator credentials were given, so Prepare-Reference.ps1 cannot run.' }
        Invoke-ReferencePrep -VMName $VMName -Credential $credential
    }
    else {
        Write-DeployLog "$VMName is already sysprepped, so the VM is not started."
    }

    # The capture reads the disk with the VM off.
    $mount = Mount-VMDisks -Paths $paths
    if (-not $mount.Root) { throw "No Windows install found on the disks of $VMName." }
    $windowsRoot = $mount.Root
    if (-not (Test-Generalized -Root $windowsRoot)) {
        throw "Windows on $VMName was not generalized. Prepare-Reference.ps1 did not finish; run it in the VM and then run this again."
    }

    New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
    # The capture goes to a staging folder first, so a failed capture leaves the current image alone.
    $staging = Join-Path $imagesDir ".capture-$Name"
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $wim = Join-Path $staging "$Name.wim"

    Write-DeployLog "Capturing the disk of $VMName ($windowsRoot) to $imagesDir. The VM is not started for the capture."
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
    if ($mount) { Dismount-VMDisks $mount }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
