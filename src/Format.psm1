# Sizes as people read them, for the console, the media build and the capture: one formatter instead of one per
# module. Always a dot, whatever the PC's language, so logs read the same everywhere. PowerShell 5.1 compatible.
# Durations use Format-Duration in DeployStatus.psm1, which also runs on deployed PCs (no Format.psm1 there).

function Format-ByteSize {
    # 500 -> '500 bytes', 1536 -> '1.5 KB', 734003200 -> '700 MB', 20508000000 -> '19.1 GB'.
    param([double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $Bytes = [Math]::Max(0, $Bytes)
    if ($Bytes -ge 1GB) { return [string]::Format($inv, '{0:0.0} GB', $Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return [string]::Format($inv, '{0:0} MB', $Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return [string]::Format($inv, '{0:0.0} KB', $Bytes / 1KB) }
    "$([int64]$Bytes) bytes"
}

Export-ModuleMember -Function Format-ByteSize
