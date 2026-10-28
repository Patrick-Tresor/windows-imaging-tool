<#
.SYNOPSIS
    Captures a reference VM's disk to a WIM on the admin PC. Hyper-V and VMware Workstation VMs can be fully hands-free; other VM software takes a shut-down disk file.
.DESCRIPTION
    Runs on the admin PC (elevated, with DISM). Two ways to give it the disk:

    -VMName (Hyper-V): if the VM's Windows has not been sysprepped yet, the script takes a checkpoint, writes a
    one-time boot command into the VM's disk offline (Windows Setup runs Prepare-Reference.ps1 as SYSTEM on the
    next boot, and sysprep shuts the VM down), starts the VM and waits for it to shut down, removes the boot
    command again, and captures the disk with the VM off. Afterwards it rolls the VM back to the checkpoint.
    A VM whose Windows is already sysprepped is not started.

    -VmxPath (VMware Workstation Pro, hands-free): the VM must be shut down, not sysprepped yet, and have VMware
    Tools and the capture agent installed (run VMwareCaptureAgent.ps1 -Install in it once). The script takes a
    snapshot, starts the VM with vmrun, and asks the agent through a VMware guest variable to run
    Prepare-Reference.ps1; sysprep shuts the VM down. Then it reads the VM's current disk (the snapshot chain) into
    a temporary VHD with qemu-img, removes the agent's leftovers from that copy, captures it, and reverts the VM to
    the snapshot. No password, network or capture ISO is needed. Needs vmrun.exe (part of VMware Workstation Pro)
    and qemu-img.exe on this PC, and free space for a copy of the whole disk. Fully encrypted VMs are not
    supported; a VM whose encryption only covers its TPM is read from its disk files. vmrun can only open an
    encrypted VM (every VM with a virtual TPM) with its encryption password: give it with -VmxPassword, or the
    script asks for it.

    -DiskPath (any VM software): the VM must already be shut down and its Windows already sysprepped. The file
    can be a VHD or VHDX, which is mounted directly, or a VMDK, VDI, qcow2 or raw disk, which is converted to a
    temporary VHD first with qemu-img or VirtualBox (whichever is installed). The script does not change the
    VM, its disk file, or its snapshots. Prepare the VM by hand first: boot it, run Prepare-Reference.ps1, and
    shut it down.

    The image goes to the Images folder of the content root, as Capture-GoldenImage.ps1 does. With -NewVersion
    an existing image of the same name is replaced only once the capture has succeeded, and the old one is kept
    as a version in Images\Previous\ (see ImageVersions.psm1).

    Untested on Windows: the Setup\CmdLine boot hook and sysprep run that way, the checkpoint rollback, every
    -DiskPath conversion, and the whole -VmxPath route (vmrun, the guest agent, qemu-img on a snapshot chain).
.EXAMPLE
    .\src\Capture-VMImage.ps1 -VMName Win11-Ref -Name Win11-24H2-Enterprise -ContentRoot D:\DeployShare
.EXAMPLE
    .\src\Capture-VMImage.ps1 -VmxPath 'D:\VMware\Staff\Staff.vmx' -Name Win11-Staff -ContentRoot D:\DeployShare
.EXAMPLE
    .\src\Capture-VMImage.ps1 -DiskPath 'D:\VMware\Win11-Ref\Win11-Ref.vmdk' -Name Win11-24H2 -ContentRoot D:\DeployShare
#>
[CmdletBinding(DefaultParameterSetName = 'HyperV')]
param(
    [Parameter(Mandatory, ParameterSetName = 'HyperV')][string]$VMName,
    [Parameter(Mandatory, ParameterSetName = 'Disk')][string]$DiskPath,
    [Parameter(Mandatory, ParameterSetName = 'VMware')][string]$VmxPath,
    [Parameter(ParameterSetName = 'VMware')][securestring]$VmxPassword,   # the VM's encryption password, when it is encrypted
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
    param([Parameter(Mandatory)][string[]]$Paths, [switch]$ReadWrite)
    $mount = [pscustomobject]@{ Root = $null; Mounted = @(); Assigned = @() }
    try {
        foreach ($path in $Paths) {
            # Mount-VHD needs Hyper-V; Mount-DiskImage is in every Windows 10/11 and mounts a VHD or VHDX too.
            if (Get-Command Mount-VHD -ErrorAction SilentlyContinue) {
                $diskNumber = (Mount-VHD -Path $path -ReadOnly:(-not $ReadWrite) -PassThru).DiskNumber
                $mount.Mounted += [pscustomobject]@{ Path = $path; HyperV = $true }
            }
            else {
                $access = if ($ReadWrite) { 'ReadWrite' } else { 'ReadOnly' }
                $diskNumber = (Mount-DiskImage -ImagePath $path -Access $access -NoDriveLetter -PassThru -ErrorAction Stop | Get-Disk).Number
                $mount.Mounted += [pscustomobject]@{ Path = $path; HyperV = $false }
            }
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
    foreach ($m in $Mount.Mounted) {
        if ($m.HyperV) { Dismount-VHD -Path $m.Path -ErrorAction SilentlyContinue }
        else { Dismount-DiskImage -ImagePath $m.Path -ErrorAction SilentlyContinue | Out-Null }
    }
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

function Invoke-Vmrun {
    # Runs vmrun on the VM at $VmxPath (or on none with -NoVmx) and returns its output lines.
    param([Parameter(Mandatory)][string]$Command, [string[]]$Arguments = @(), [switch]$NoVmx, [switch]$AllowFailure)
    $vmx = if ($NoVmx) { $null } else { $VmxPath }
    $argList = New-VmrunArguments -Command $Command -VmxPath $vmx -Arguments $Arguments -Password $(if ($vmx) { $script:VmrunPassword })
    $out = @(& $script:Vmrun @argList 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        if (Test-VmrunWrongPassword $out) {
            throw ("VMware could not open the VM: its encryption password is missing or wrong (vmrun: $(($out -join ' ').Trim())). " +
                'Windows 11 VMs are encrypted for their virtual TPM. Use the password you typed when you created the VM or turned on its TPM. ' +
                'If Workstation never asked you for one, it made one up and keeps it to itself; see the README for what to do then.')
        }
        throw "vmrun $Command failed: $(($out -join ' ').Trim())"
    }
    $out
}

function Test-VMwareRunning {
    Test-VmxInList -VmxPath $VmxPath -RunningPaths (ConvertFrom-VmrunList (Invoke-Vmrun list -NoVmx))
}

function Wait-VMwareAgent {
    # Waits for the agent in the VM to answer the capture request, or for the VM to go off. Throws when neither
    # happens in time, naming the likely reason.
    param([Parameter(Mandatory)][int]$Minutes)
    $vars = Get-VMwareCaptureVariables
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        if (-not (Test-VMwareRunning)) {
            Write-DeployLog 'The VM went off before the capture agent in it answered, so sysprep probably did not run. Is the agent installed (VMwareCaptureAgent.ps1 -Install)?' -Level WARN
            return
        }
        $state = "$(Invoke-Vmrun readVariable -Arguments @('guestVar', $vars.State) -AllowFailure)".Trim()
        if ($state -in 'started', 'failed') { Write-DeployLog "The capture agent in the VM answered: $state."; return }
        if ((Get-Date) -gt $deadline) {
            $tools = "$(Invoke-Vmrun checkToolsState -AllowFailure)".Trim()
            if ($tools -ne 'running') { throw "VMware Tools is not running in the VM (vmrun says '$tools'), so the capture could not start. Install VMware Tools and the capture agent in the VM." }
            throw 'The capture agent in the VM did not answer. Boot the VM, run VMwareCaptureAgent.ps1 -Install in it from an elevated PowerShell window, shut it down, and capture again.'
        }
        Start-Sleep -Seconds 10
    }
}

function Wait-VMwareOff {
    param([Parameter(Mandatory)][int]$Minutes)
    $deadline = (Get-Date).AddMinutes($Minutes)
    while (Test-VMwareRunning) {
        if ((Get-Date) -gt $deadline) { throw "The VM is still running $Minutes minutes after sysprep was started. It did not finish; check the VM." }
        Start-Sleep -Seconds 15
    }
}

function Get-VMwareCaptureDisk {
    # Copies the VM's current disk (its snapshot chain) to a temporary VHD, finds Windows on it, removes the capture
    # agent's leftovers from the copy, and reports whether Windows was generalized. The caller deletes Temp.
    # A readable .vmx names the current disks. An encrypted one does not, but the delta files the snapshot of this
    # run created are the disks the VM has written to since.
    $paths = Get-VmxDiskPaths -VmxPath $VmxPath
    if ($null -eq $paths -and $script:SnapshotDeltas) { $paths = @($script:SnapshotDeltas) }
    if (-not $paths) { $paths = Get-VmdkLeafPaths -Folder (Split-Path -Parent $VmxPath) }
    if (-not $paths) { throw "No virtual disk found for $(Split-Path -Leaf $VmxPath)." }
    foreach ($path in $paths) {
        $written = (Get-Item -LiteralPath $path).LastWriteTime
        Write-DeployLog "Reading $(Split-Path -Leaf $path) (last written $($written.ToString('yyyy-MM-dd HH:mm:ss')))."
        if ($script:VMStarted -and $written -lt $script:VMStarted) {
            Write-DeployLog "$(Split-Path -Leaf $path) was not written while the VM ran, so it may not be the disk the VM used." -Level WARN
        }
        $disk = Get-DiskForCapture -Path $path
        $found = $null
        try {
            $m = Mount-VMDisks -Paths @($disk.Path) -ReadWrite
            try {
                if ($m.Root) {
                    $agentDir = Join-Path $m.Root 'Windows\Temp\ImagingTool'
                    $agentLog = Join-Path $agentDir 'capture-agent.log'
                    $found = [pscustomobject]@{
                        Path     = $disk.Path
                        Source   = $path
                        Temp     = $disk.Temp
                        State    = Get-OfflineImageState -Root $m.Root
                        AgentLog = @(if (Test-Path -LiteralPath $agentLog) { Get-Content -LiteralPath $agentLog })
                    }
                    Remove-Item -LiteralPath $agentDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            finally { Dismount-VMDisks $m }
        }
        finally {
            if (-not $found -and $disk.Temp) { Remove-Item -LiteralPath $disk.Temp -Force -ErrorAction SilentlyContinue }
        }
        if ($found) { return $found }
    }
    throw "No Windows install found on the disks of $(Split-Path -Leaf $VmxPath)."
}

function Restore-VMwareSnapshot {
    # Reverts the VM to the snapshot taken before the capture and deletes the snapshot, as for Hyper-V.
    param([Parameter(Mandatory)][string]$Name)
    try {
        if (Test-VMwareRunning) { Invoke-Vmrun stop -Arguments @('hard') | Out-Null }
        Invoke-Vmrun revertToSnapshot -Arguments @($Name) | Out-Null
        Write-DeployLog "Reverted the VM to the snapshot from before the capture."
    }
    catch {
        Write-DeployLog "Could not revert the VM to snapshot '$Name': $($_.Exception.Message). In VMware Workstation open VM > Snapshot > Snapshot Manager, pick '$Name' and click Go To, then delete it." -Level WARN
        return
    }
    # Right after a revert VMware can still hold the VM's files for a moment, so deleting the snapshot is retried.
    for ($try = 1; ; $try++) {
        try {
            Invoke-Vmrun deleteSnapshot -Arguments @($Name) | Out-Null
            Write-DeployLog "Deleted snapshot '$Name'."
            return
        }
        catch {
            # An earlier try, or VMware itself, can already have deleted it.
            if ($_.Exception.Message -match 'does not exist') { Write-DeployLog "Deleted snapshot '$Name'."; return }
            if ($try -ge 4) {
                Write-DeployLog "The VM is back as it was, but snapshot '$Name' could not be deleted: $($_.Exception.Message). Delete it in VMware Workstation (VM > Snapshot > Snapshot Manager); it only takes disk space." -Level WARN
                return
            }
            Start-Sleep -Seconds 15
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
$checkpoint = $null   # set only when this run changes a Hyper-V VM; rolled back in finally
$snapshot = $null     # the same for a VMware VM
$tempDisk = $null     # a converted VHD made by this run; deleted in finally
$mount = $null        # the mounted virtual disks; dismounted in finally

try {
    $existing = @((Join-Path $imagesDir "$Name.wim"), (Join-Path $imagesDir "$Name.swm")) | Where-Object { Test-Path $_ }
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $imagesDir. Pick another name, or capture it as a new version."
    }

    if ($PSCmdlet.ParameterSetName -eq 'Disk') {
        if (-not $NoPrompt -and (Read-Host "Type YES to capture $(Split-Path $DiskPath -Leaf) (its VM must be shut down)") -ne 'YES') {
            Write-DeployLog 'Cancelled by operator' -Level WARN
            $status = 'CANCELLED'
            return
        }
        $disk = Get-DiskForCapture -Path $DiskPath
        $tempDisk = $disk.Temp
        $paths = @($disk.Path)
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'VMware') {
        $script:Vmrun = Find-Vmrun
        if (-not $script:Vmrun) { throw 'vmrun.exe was not found. It comes with VMware Workstation Pro 17 or later; install that on this PC.' }
        if (-not (Find-QemuImg)) { throw 'qemu-img.exe was not found. Install QEMU for Windows (it includes qemu-img) and add its folder to PATH; it reads the VMware disk.' }
        if (-not (Test-Path -LiteralPath $VmxPath -PathType Leaf)) { throw "VM file not found: $VmxPath" }
        $VmxPath = (Resolve-Path -LiteralPath $VmxPath).ProviderPath
        $vmLabel = [IO.Path]::GetFileNameWithoutExtension($VmxPath)
        if (Test-VMwareRunning) { throw "$vmLabel is running. Shut it down first; this script starts it itself." }
        $script:VmrunPassword = $null
        if (Test-VmxEncrypted -VmxPath $VmxPath) {
            if (-not $VmxPassword) {
                if ($NoPrompt) { Write-Host "$vmLabel is encrypted (Windows 11 VMs are, for their virtual TPM), so VMware needs its encryption password." }
                $VmxPassword = Read-Host "Encryption password of $vmLabel" -AsSecureString
            }
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmxPassword)
            try { $script:VmrunPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            # Opens the VM without changing it, so a wrong password stops here, before the snapshot.
            Invoke-Vmrun listSnapshots | Out-Null
            Write-DeployLog "The encryption password of $vmLabel works."
        }
        if (-not $NoPrompt -and (Read-Host "Type YES to sysprep and capture $vmLabel (it is reverted to a snapshot afterwards)") -ne 'YES') {
            Write-DeployLog 'Cancelled by operator' -Level WARN
            $status = 'CANCELLED'
            return
        }

        $snapshotName = "Before capture of $Name $(Get-Date -Format 'yyyyMMdd-HHmm')"
        $vmFolder = Split-Path -Parent $VmxPath
        $disksBefore = @(Get-VmdkDescriptorPaths -Folder $vmFolder)
        Invoke-Vmrun snapshot -Arguments @($snapshotName) | Out-Null
        $snapshot = $snapshotName
        Write-DeployLog "Took snapshot '$snapshot'. The VM is reverted to it after the capture."
        $script:SnapshotDeltas = @(Get-VmdkDescriptorPaths -Folder $vmFolder | Where-Object { $disksBefore -notcontains $_ } | Sort-Object)
        if ($script:SnapshotDeltas) { Write-DeployLog "The VM now writes to $(($script:SnapshotDeltas | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')." }
        $script:VMStarted = Get-Date

        Write-DeployLog "Starting $vmLabel. The capture agent in the VM runs Prepare-Reference.ps1, and sysprep shuts the VM down when it is done."
        Invoke-Vmrun start -Arguments @('nogui') | Out-Null
        Invoke-Vmrun writeVariable -Arguments @('guestVar', (Get-VMwareCaptureVariables).Request, 'sysprep') | Out-Null
        Wait-VMwareAgent -Minutes 15
        Wait-VMwareOff -Minutes 60
        Write-DeployLog "$vmLabel is off. Copying its disk to a temporary VHD with qemu-img (the whole disk, so it takes a while)."

        $disk = Get-VMwareCaptureDisk
        $tempDisk = $disk.Temp
        $paths = @($disk.Path)
        if (-not $disk.State.Generalized) {
            foreach ($line in $disk.AgentLog) { Write-DeployLog "  agent: $line" }
            # The agent's log is from this run; the sysprep error line can be from an earlier one.
            $why = if ($disk.AgentLog) { " The capture agent's log says: $($disk.AgentLog[-1])" }
                   else { " The capture agent left no log on $(Split-Path -Leaf $disk.Source), so it did not run, or this is not the disk the VM used." }
            if ($disk.State.LastError) { $why += " Last sysprep error on this disk (it may be from an earlier run): $($disk.State.LastError)" }
            throw "Windows on $vmLabel was not generalized (ImageState $($disk.State.ImageState)).$why"
        }
    }
    else {
        $vm = Get-VM -Name $VMName
        if ($vm.State -ne 'Off') { throw "VM $VMName is $($vm.State). Shut it down first; this script starts it itself when it needs to." }
        if ($vm.Generation -ne 2) { throw "VM $VMName is generation $($vm.Generation). Only generation 2 (UEFI) VMs are supported." }
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
    }

    # The capture reads the disk with the VM off.
    $mount = Mount-VMDisks -Paths $paths
    if (-not $mount.Root) { throw 'No Windows install found on the disk.' }
    $windowsRoot = $mount.Root
    if (-not (Test-Generalized -Root $windowsRoot)) {
        if ($PSCmdlet.ParameterSetName -eq 'Disk') {
            throw 'Windows on this disk was not generalized. Boot the VM once, run Prepare-Reference.ps1 in it, shut the VM down, and run this again.'
        }
        throw "Windows on $(if ($VmxPath) { $vmLabel } else { $VMName }) was not generalized. Prepare-Reference.ps1 did not run or did not finish; check the VM and run this again."
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
    # Release the disk before the rollback and the temporary copy's deletion, which need it free.
    if ($mount) { Dismount-VMDisks $mount }
    if ($checkpoint) { Restore-PreCaptureCheckpoint -VMName $VMName -Name $checkpoint }
    if ($snapshot) { Restore-VMwareSnapshot -Name $snapshot }
    if ($tempDisk) { Remove-Item -LiteralPath $tempDisk -Force -ErrorAction SilentlyContinue }
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and -not $swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($status -ne 'CANCELLED') {
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item $logPath (Join-Path $logDir ("CAPTURE-VM-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'FAILED') { exit 1 }
