# Windows 11 hardware readiness, checked in WinPE before the disk is wiped: TPM 2.0, UEFI and Secure Boot,
# a supported CPU, 4 GB of memory and a 64 GB disk. Setup applied with DISM does not enforce these, so a
# Windows 11 image lands on an unsupported PC without complaint and then misses feature updates.
# Get-Win11ReadinessFacts reads the hardware; everything else is pure so it can be tested off Windows.
# PowerShell 5.1 compatible (WinPE-WMI, WinPE-SecureStartup, WinPE-DismCmdlets).

$script:Modes = 'Block', 'Warn', 'Off'

function Get-CpuWin11Support {
    <#
    .SYNOPSIS
        Supported, Unsupported or Unknown, from the processor name. Follows Microsoft's lists: Intel 8th
        generation Core and later, AMD Zen+ (Ryzen 2000 desktop) and later. Unknown never blocks a deploy.
    #>
    param([string]$Name, [string]$Manufacturer)
    $n = ($Name -replace '\((R|TM)\)', '' -replace '\s+', ' ').Trim()
    $isIntel = $Manufacturer -match 'Intel' -or $n -match '^Intel'
    $isAmd = $Manufacturer -match 'AMD' -or $n -match '^AMD'

    if ($isIntel) {
        if ($n -match 'Core Ultra|Core [3579] \d{3}') { return 'Supported' }       # 2023+ branding
        if ($n -match 'Core ?2 |Core Duo|Core Solo|Atom|Pentium (4|D|M)\b') { return 'Unsupported' }
        if ($n -match 'Core i[3579]-(\d{3,5})') {
            $num = $Matches[1]
            # i7-920 = 1st gen, i5-8250U = 8th, i7-1165G7 = 11th (4-digit mobile), i9-13900K = 13th.
            $gen = if ($num.Length -eq 3) { 1 }
                   elseif ($num.Length -eq 5 -or $num.StartsWith('1')) { [int]$num.Substring(0, 2) }
                   else { [int]$num.Substring(0, 1) }
            if ($gen -ge 8) { return 'Supported' } else { return 'Unsupported' }
        }
        if ($n -match '\b(Intel )?(Processor )?N[12]\d{2}\b') { return 'Supported' }  # N100, N200 (Alder Lake-N)
        return 'Unknown'    # Xeon, Pentium, Celeron: some generations are on the list, some are not
    }
    if ($isAmd) {
        if ($n -match 'Ryzen AI') { return 'Supported' }
        if ($n -match 'Threadripper (PRO )?(\d)\d{3}') { if ([int]$Matches[2] -ge 2) { return 'Supported' } else { return 'Unsupported' } }
        if ($n -match 'Ryzen [3579]( PRO)? (\d)\d{3}([A-Z]*)') {
            $series = [int]$Matches[2]; $suffix = $Matches[3]
            if ($series -ge 3) { return 'Supported' }
            if ($series -eq 2 -and $suffix -notmatch 'G|U|H') { return 'Supported' }  # 2000 APUs are Zen 1
            return 'Unsupported'
        }
        if ($n -match '\b(A\d{1,2}|E\d|FX|Phenom|Athlon (II|64|X2))[- ]') { return 'Unsupported' }
        return 'Unknown'    # Athlon, EPYC
    }
    'Unknown'
}

function Get-Win11ReadinessFacts {
    # Reads the hardware in WinPE. A value is $null when it could not be read.
    param([int]$DiskNumber = 0, [bool]$IsUefi)

    $tpm = $null; $tpmError = $null
    try { $tpm = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop }
    catch { $tpmError = $_.Exception.Message }

    $secureBoot = $null
    if ($IsUefi) {
        try { $secureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
        catch {
            $v = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction SilentlyContinue).UEFISecureBootEnabled
            if ($null -ne $v) { $secureBoot = $v -eq 1 }
        }
    } else { $secureBoot = $false }

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $memBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
    if (-not $memBytes) { $memBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue

    [pscustomobject]@{
        IsUefi          = $IsUefi
        SecureBootOn    = $secureBoot
        TpmPresent      = [bool]$tpm
        TpmEnabled      = if ($tpm) { [bool]$tpm.IsEnabled_InitialValue } else { $null }
        TpmSpecVersion  = if ($tpm) { "$($tpm.SpecVersion)" } else { $null }
        TpmError        = $tpmError
        CpuName         = "$($cpu.Name)".Trim()
        CpuManufacturer = "$($cpu.Manufacturer)".Trim()
        CpuCores        = [int]$cpu.NumberOfCores
        CpuMHz          = [int]$cpu.MaxClockSpeed
        MemoryGB        = [math]::Round($memBytes / 1GB, 1)
        DiskGB          = if ($disk) { [math]::Round($disk.Size / 1GB) } else { $null }
    }
}

function Test-Win11Readiness {
    <#
    .SYNOPSIS
        One row per requirement: Check, Result (Pass, Warn, Fail) and Detail. Only Fail blocks a deploy.
    #>
    param([Parameter(Mandatory)]$Facts)
    $f = $Facts
    $row = { param($c, $r, $d) [pscustomobject]@{ Check = $c; Result = $r; Detail = $d } }

    # TPM: SpecVersion lists every version the chip supports, highest first ("2.0, 0, 1.59").
    if (-not $f.TpmPresent) {
        if ($f.TpmError -and $f.TpmError -notmatch 'not found|Invalid class|No instance') { & $row 'TPM 2.0' 'Warn' "Could not read the TPM: $($f.TpmError)" }
        else { & $row 'TPM 2.0' 'Fail' 'No TPM found. Turn on the TPM (PTT on Intel, fTPM on AMD) in the firmware settings.' }
    } elseif ("$($f.TpmSpecVersion)".Split(',')[0].Trim() -notmatch '^2\.') {
        & $row 'TPM 2.0' 'Fail' "TPM version $("$($f.TpmSpecVersion)".Split(',')[0].Trim()); Windows 11 needs 2.0. Some PCs can be switched to 2.0 with a firmware update."
    } elseif ($f.TpmEnabled -eq $false) {
        & $row 'TPM 2.0' 'Fail' 'TPM 2.0 is present but turned off. Turn it on in the firmware settings.'
    } else { & $row 'TPM 2.0' 'Pass' "TPM $("$($f.TpmSpecVersion)".Split(',')[0].Trim())" }

    if (-not $f.IsUefi) { & $row 'UEFI' 'Fail' 'Booted in legacy BIOS mode. Windows 11 needs UEFI: switch the firmware to UEFI and boot again.' }
    else { & $row 'UEFI' 'Pass' 'UEFI' }

    # Windows 11 needs a PC that can do Secure Boot, not one that has it on, so off is a warning.
    if ($f.IsUefi) {
        if ($f.SecureBootOn -eq $true) { & $row 'Secure Boot' 'Pass' 'On' }
        elseif ($f.SecureBootOn -eq $false) { & $row 'Secure Boot' 'Warn' 'Off. Supported but recommended: turn it on in the firmware settings.' }
        else { & $row 'Secure Boot' 'Warn' 'Could not read the Secure Boot state.' }
    }

    $support = Get-CpuWin11Support -Name $f.CpuName -Manufacturer $f.CpuManufacturer
    $cpuText = if ($f.CpuName) { $f.CpuName } else { 'unknown processor' }
    if ($f.CpuCores -and $f.CpuCores -lt 2) { & $row 'Processor' 'Fail' "$cpuText has $($f.CpuCores) core; Windows 11 needs 2." }
    elseif ($f.CpuMHz -and $f.CpuMHz -lt 1000) { & $row 'Processor' 'Fail' "$cpuText runs at $($f.CpuMHz) MHz; Windows 11 needs 1 GHz." }
    elseif ($support -eq 'Unsupported') { & $row 'Processor' 'Fail' "$cpuText is not on Microsoft's supported processor list (Intel 8th gen or AMD Ryzen 2000 and later)." }
    elseif ($support -eq 'Unknown') { & $row 'Processor' 'Warn' "$cpuText could not be matched; check it against Microsoft's supported processor list." }
    else { & $row 'Processor' 'Pass' $cpuText }

    # Installed memory reads a little under the module size on some PCs, hence 3.8.
    if ($null -eq $f.MemoryGB) { & $row 'Memory' 'Warn' 'Could not read the installed memory.' }
    elseif ($f.MemoryGB -lt 3.8) { & $row 'Memory' 'Fail' "$($f.MemoryGB) GB; Windows 11 needs 4 GB." }
    else { & $row 'Memory' 'Pass' "$($f.MemoryGB) GB" }

    if ($null -eq $f.DiskGB) { & $row 'Disk' 'Warn' 'Could not read the target disk size.' }
    elseif ($f.DiskGB -lt 64) { & $row 'Disk' 'Fail' "$($f.DiskGB) GB; Windows 11 needs 64 GB." }
    else { & $row 'Disk' 'Pass' "$($f.DiskGB) GB" }
}

function Test-Win11Image {
    <#
    .SYNOPSIS
        $true when the image is Windows 11 (build 22000 or later), $false for Windows 10, $null when unknown.
        Reads the image header with DISM; falls back to the edition and file names.
    #>
    param([Parameter(Mandatory)][string]$ImagePath, [int]$Index = 1, $ImageInfo)
    if (-not $ImageInfo) {
        try { $ImageInfo = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop } catch { }
    }
    if ($ImageInfo -and $ImageInfo.Version -match '^10\.0\.(\d+)') { return [int]$Matches[1] -ge 22000 }
    $names = "$($ImageInfo.ImageName) $([IO.Path]::GetFileName($ImagePath))"
    if ($names -match 'Windows ?11|Win ?11|W11') { return $true }
    if ($names -match 'Windows ?10|Win ?10|W10') { return $false }
    $null
}

function Get-Win11ReadinessDecision {
    <#
    .SYNOPSIS
        What Deploy-Image does with the results: Proceed, or Block when Mode is Block and a check failed.
        An image that is not known to be Windows 11 is still checked, but never blocked.
    #>
    param([Parameter(Mandatory)][string]$Mode, $IsWin11, [object[]]$Results = @(), [switch]$Override)
    $failed = @($Results | Where-Object Result -eq 'Fail')
    $warned = @($Results | Where-Object Result -eq 'Warn')
    $summary = if ($failed) { "NOT READY: $(($failed.Check) -join ', ')" }
               elseif ($warned) { "ready, with warnings: $(($warned.Check) -join ', ')" }
               else { 'ready' }
    $block = $Mode -eq 'Block' -and $IsWin11 -eq $true -and $failed.Count -gt 0 -and -not $Override
    [pscustomobject]@{ Action = $(if ($block) { 'Block' } else { 'Proceed' }); Summary = $summary; Failed = $failed.Count }
}

Export-ModuleMember -Function Get-CpuWin11Support, Get-Win11ReadinessFacts, Test-Win11Readiness, Test-Win11Image, Get-Win11ReadinessDecision
