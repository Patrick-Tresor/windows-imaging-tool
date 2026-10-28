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

Export-ModuleMember -Function Get-UsbTargetDisk, Reset-UsbDisk
