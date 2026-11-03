# Prepares the USB stick New-DeploymentMedia.ps1 -Target Usb writes to. PowerShell 5.1 compatible.

# Returns the disk if it is safe to erase: on USB, and not the disk Windows boots or runs from.
function Get-UsbTargetDisk {
    param([Parameter(Mandatory)][int]$DiskNumber)
    $disk = Get-Disk -Number $DiskNumber
    if ($disk.BusType -ne 'USB') { throw "Disk $DiskNumber is $($disk.BusType), not USB. Refusing to erase it." }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $DiskNumber ($($disk.FriendlyName)) holds the running Windows or its boot partition. Refusing to erase it." }
    $disk
}

# Erases the disk and leaves it empty with an MBR partition table, whatever state it was in.
# Clear-Disk keeps the partition style on most sticks, so Initialize-Disk only runs on a RAW disk;
# a stick that was GPT is switched to MBR with Set-Disk instead.
function Reset-UsbDisk {
    param([Parameter(Mandatory)][int]$DiskNumber)
    $disk = Get-UsbTargetDisk -DiskNumber $DiskNumber
    if ($disk.IsOffline) { Set-Disk -Number $DiskNumber -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $DiskNumber -IsReadOnly $false }
    if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false }
    $style = (Get-Disk -Number $DiskNumber).PartitionStyle
    if ($style -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle MBR }
    elseif ($style -ne 'MBR') { Set-Disk -Number $DiskNumber -PartitionStyle MBR }
}

function Get-UsbStickVolumes {
    <#
    .SYNOPSIS
        The WINPE (FAT32) and DEPLOY (NTFS) partitions of a stick this tool built, with drive letters (one is
        assigned when Windows gave none), for updating it in place. Throws when the stick is not one of ours.
    #>
    param([Parameter(Mandatory)][int]$DiskNumber)
    $null = Get-UsbTargetDisk -DiskNumber $DiskNumber
    $found = @{}
    foreach ($p in @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue)) {
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        if (-not $v -or $v.FileSystemLabel -notin 'WINPE', 'DEPLOY') { continue }
        if (-not $p.DriveLetter -or $p.DriveLetter -eq [char]0) {
            $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
            $p = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber
        }
        $found[$v.FileSystemLabel] = [pscustomobject]@{ Letter = "$($p.DriveLetter)"; Partition = $p; FreeBytes = [int64]$v.SizeRemaining; SizeBytes = [int64]$v.Size }
    }
    if (-not $found.WINPE -or -not $found.DEPLOY) {
        throw "USB disk $DiskNumber has no WINPE and DEPLOY partitions, so it was not built by this tool. Build it without Update (that erases it)."
    }
    [pscustomobject]@{ Boot = $found.WINPE; Data = $found.DEPLOY }
}

Export-ModuleMember -Function Get-UsbTargetDisk, Reset-UsbDisk, Get-UsbStickVolumes
