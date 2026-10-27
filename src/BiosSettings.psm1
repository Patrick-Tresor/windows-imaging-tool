# BIOS/UEFI settings for Dell, HP and Lenovo, applied in WinPE before the disk is wiped, so that firmware
# changes (TPM on, Secure Boot) take effect on the reboot into the new Windows. PowerShell 5.1 compatible.
#   Dell:   Dell Command | Configure (cctk.exe). Copy its WinPE x64 folder to <content root>\<toolsRoot>\Dell.
#   HP:     the firmware's WMI interface (root\HP\InstrumentedBIOS). No tool needed.
#   Lenovo: the firmware's WMI interface (root\wmi Lenovo_SetBiosSetting). No tool needed.
# Setting names and values differ by maker and sometimes by model: check them on one PC first
# (Dell: cctk.exe -H; HP: Get-CimInstance -Namespace root\HP\InstrumentedBIOS HP_BIOSEnumeration;
#  Lenovo: Get-CimInstance -Namespace root\wmi Lenovo_BiosSetting).

function Get-BiosPreset {
    # Common settings for a Windows 11 fleet: TPM and Secure Boot on, virtualization on (VBS, Hyper-V).
    param([Parameter(Mandatory)][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Maker)
    $pairs = switch ($Maker) {
        'Dell'   { @(('SecureBoot', 'Enabled'), ('TpmSecurity', 'Enabled'), ('TpmActivation', 'Enabled'),
                     ('Virtualization', 'Enabled'), ('VtForDirectIo', 'Enabled')) }
        'HP'     { @(('Secure Boot', 'Enable'), ('TPM State', 'Enable'), ('TPM Device', 'Available'),
                     ('Virtualization Technology (VTx)', 'Enable'), ('Virtualization Technology for Directed I/O (VTd)', 'Enable')) }
        'Lenovo' { @(('SecureBoot', 'Enable'), ('SecurityChip', 'Enable'),
                     ('VirtualizationTechnology', 'Enable'), ('VTdFeature', 'Enable')) }
    }
    foreach ($p in $pairs) { [pscustomobject]@{ Maker = $Maker; Name = $p[0]; Value = $p[1] } }
}

function Get-CctkArgument {
    # Dell: one cctk.exe call sets everything. --ValSetupPwd is the current BIOS admin (setup) password.
    param([Parameter(Mandatory)][object[]]$Settings, [string]$Password)
    $cctkArgs = @($Settings | ForEach-Object { "--$($_.Name)=$($_.Value)" })
    if ($Password) { $cctkArgs += "--ValSetupPwd=$Password" }
    $cctkArgs
}

function Get-LenovoSettingString {
    # Lenovo_SetBiosSetting takes "Name,Value" or "Name,Value,password,ascii,us" when a supervisor password is set.
    param([Parameter(Mandatory)]$Setting, [string]$Password)
    if ($Password) { "$($Setting.Name),$($Setting.Value),$Password,ascii,us" } else { "$($Setting.Name),$($Setting.Value)" }
}

function Get-HpPasswordValue {
    # HP_BIOSSettingInterface wants the password prefixed with its encoding; an empty password is still "<utf-16/>".
    param([string]$Password)
    "<utf-16/>$Password"
}

function Hide-Password([string]$Text, [string]$Password) {
    if ($Password) { $Text.Replace($Password, '********') } else { $Text }
}

function Set-DellBios {
    param([object[]]$Settings, [string]$Password, [string]$ToolsDir)
    $dir = Join-Path $ToolsDir 'Dell'
    $cctk = Join-Path $dir 'cctk.exe'
    if (-not (Test-Path $cctk)) { throw "Dell Command | Configure not found: $cctk. Copy its WinPE x64 folder there." }
    # In WinPE cctk needs Dell's HAPI driver loaded first; the WinPE folder ships it.
    $hapi = Join-Path $dir 'HAPI\hapint64.exe'
    if (Test-Path $hapi) { & $hapi -i -k C-C-T-K -p "$dir\HAPI\" 2>&1 | Out-Null }

    $cctkArgs = Get-CctkArgument -Settings $Settings -Password $Password
    Write-DeployLog (Hide-Password "> $cctk $($cctkArgs -join ' ')" $Password)
    $out = & $cctk @cctkArgs 2>&1 | ForEach-Object { Hide-Password "$_" $Password }
    $out | ForEach-Object { Write-DeployLog "  $_" }
    $code = $LASTEXITCODE
    foreach ($s in $Settings) {
        [pscustomobject]@{ Maker = 'Dell'; Name = $s.Name; Value = $s.Value; Ok = $code -eq 0; Detail = if ($code -eq 0) { 'OK' } else { "cctk exit code $code" } }
    }
}

function Set-HpBios {
    param([object[]]$Settings, [string]$Password)
    $iface = Get-CimInstance -Namespace root\HP\InstrumentedBIOS -ClassName HP_BIOSSettingInterface -ErrorAction Stop
    $codes = @{ 0 = 'OK'; 1 = 'Not supported'; 2 = 'Unspecified error'; 3 = 'Timeout'; 4 = 'Failed'; 5 = 'Invalid parameter'; 6 = 'Access denied (BIOS password?)' }
    foreach ($s in $Settings) {
        $r = Invoke-CimMethod -InputObject $iface -MethodName SetBIOSSetting -Arguments @{
            Name = $s.Name; Value = $s.Value; Password = (Get-HpPasswordValue $Password) }
        $rc = [int]$r.Return
        [pscustomobject]@{ Maker = 'HP'; Name = $s.Name; Value = $s.Value; Ok = $rc -eq 0
                           Detail = if ($codes.ContainsKey($rc)) { $codes[$rc] } else { "Return code $rc" } }
    }
}

function Set-LenovoBios {
    param([object[]]$Settings, [string]$Password)
    $set = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SetBiosSetting -ErrorAction Stop
    $results = foreach ($s in $Settings) {
        $r = Invoke-CimMethod -InputObject $set -MethodName SetBiosSetting -Arguments @{ parameter = (Get-LenovoSettingString $s $Password) }
        [pscustomobject]@{ Maker = 'Lenovo'; Name = $s.Name; Value = $s.Value; Ok = $r.return -eq 'Success'; Detail = "$($r.return)" }
    }
    # Nothing is kept until the changes are saved, once for all of them.
    if ($results | Where-Object Ok) {
        $save = Get-CimInstance -Namespace root\wmi -ClassName Lenovo_SaveBiosSettings -ErrorAction Stop
        $param = if ($Password) { "$Password,ascii,us" } else { '' }
        $r = Invoke-CimMethod -InputObject $save -MethodName SaveBiosSettings -Arguments @{ parameter = $param }
        if ($r.return -ne 'Success') {
            foreach ($x in $results) { $x.Ok = $false; $x.Detail = "Save failed: $($r.return)" }
        }
    }
    $results
}

function Set-BiosSettings {
    <#
    .SYNOPSIS
        Applies the answer file's BIOS settings for this PC's maker. Returns one result per setting
        (Maker, Name, Value, Ok, Detail). Throws when the maker's tool or WMI interface is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$Maker,       # Get-HardwareIdentity's Maker: Dell, HP or Lenovo
        [Parameter(Mandatory)][object[]]$Settings,  # the answer file's settings, all makers
        [string]$Password,
        [string]$ToolsDir
    )
    $mine = @($Settings | Where-Object Maker -eq $Maker)
    if (-not $mine) { Write-DeployLog "No BIOS settings for $Maker in this answer file"; return @() }
    Write-DeployLog "Applying $($mine.Count) BIOS setting(s) for $Maker"
    $results = switch ($Maker) {
        'Dell'   { Set-DellBios -Settings $mine -Password $Password -ToolsDir $ToolsDir }
        'HP'     { Set-HpBios -Settings $mine -Password $Password }
        'Lenovo' { Set-LenovoBios -Settings $mine -Password $Password }
    }
    foreach ($r in $results) {
        Write-DeployLog ("BIOS {0} = {1}: {2}" -f $r.Name, $r.Value, $r.Detail) -Level $(if ($r.Ok) { 'INFO' } else { 'WARN' })
    }
    $results
}

Export-ModuleMember -Function Get-BiosPreset, Get-CctkArgument, Get-LenovoSettingString, Get-HpPasswordValue, Set-BiosSettings
