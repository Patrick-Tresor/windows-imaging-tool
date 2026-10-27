# Plain-PowerShell tests for BIOS settings: presets, the commands each maker gets, and result handling with the
# firmware's WMI interfaces replaced by fakes. Run: pwsh -File tests/BiosSettings.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$bios = Import-Module (Join-Path $repo 'src/BiosSettings.psm1') -Force -PassThru

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# Presets.
Assert-Equal ((Get-BiosPreset -Maker Dell).Name -join ',') 'SecureBoot,TpmSecurity,TpmActivation,Virtualization,VtForDirectIo' 'Dell preset'
Assert-Equal ((Get-BiosPreset -Maker Lenovo | Where-Object Name -eq 'SecurityChip').Value) 'Enable' 'Lenovo preset turns the security chip on'
Assert-Equal (@(Get-BiosPreset -Maker HP | Where-Object Maker -ne 'HP').Count) 0 'presets are tagged with their maker'

# Commands.
$s = @([pscustomobject]@{ Maker = 'Dell'; Name = 'SecureBoot'; Value = 'Enabled' }, [pscustomobject]@{ Maker = 'Dell'; Name = 'WakeOnLan'; Value = 'LanOnly' })
Assert-Equal ((Get-CctkArgument -Settings $s) -join ' ') '--SecureBoot=Enabled --WakeOnLan=LanOnly' 'cctk arguments without a password'
Assert-Equal ((Get-CctkArgument -Settings $s -Password 'p w') -join ' ') '--SecureBoot=Enabled --WakeOnLan=LanOnly --ValSetupPwd=p w' 'cctk arguments with the setup password'
Assert-Equal (Get-LenovoSettingString $s[0]) 'SecureBoot,Enabled' 'Lenovo setting string'
Assert-Equal (Get-LenovoSettingString $s[0] -Password 'sup') 'SecureBoot,Enabled,sup,ascii,us' 'Lenovo setting string with the supervisor password'
Assert-Equal (Get-HpPasswordValue '') '<utf-16/>' 'HP empty password'
Assert-Equal (Get-HpPasswordValue 'abc') '<utf-16/>abc' 'HP password'

# Fakes for the firmware interfaces, defined inside the module so its calls reach them.
. $bios {
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:Log = [Collections.Generic.List[string]]::new()
    $script:LenovoSave = 'Success'
    function Write-DeployLog([string]$Message, [string]$Level = 'INFO') { $script:Log.Add("[$Level] $Message") }
    function Get-CimInstance { param($Namespace, $ClassName, $ErrorAction) [pscustomobject]@{ Class = $ClassName } }
    function Invoke-CimMethod {
        param($InputObject, $MethodName, $Arguments)
        $script:Calls.Add("$($InputObject.Class).$MethodName($(($Arguments.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'))")
        switch -CaseSensitive ($MethodName) {
            'SetBiosSetting'   { [pscustomobject]@{ return = if ($Arguments.parameter -like 'Bad*') { 'Invalid Parameter' } else { 'Success' } } }
            'SaveBiosSettings' { [pscustomobject]@{ return = $script:LenovoSave } }
            'SetBIOSSetting'   { [pscustomobject]@{ Return = if ($Arguments.Name -eq 'Locked') { 6 } else { 0 } } }
        }
    }
}

$all = @(
    [pscustomobject]@{ Maker = 'Lenovo'; Name = 'SecureBoot'; Value = 'Enable' },
    [pscustomobject]@{ Maker = 'Lenovo'; Name = 'BadName'; Value = 'Enable' },
    [pscustomobject]@{ Maker = 'HP'; Name = 'Secure Boot'; Value = 'Enable' },
    [pscustomobject]@{ Maker = 'HP'; Name = 'Locked'; Value = 'Enable' }
)
$r = @(Set-BiosSettings -Maker Lenovo -Settings $all -Password 'sup')
Assert-Equal (($r | ForEach-Object { "$($_.Name)=$($_.Ok)/$($_.Detail)" }) -join ';') 'SecureBoot=True/Success;BadName=False/Invalid Parameter' 'Lenovo: only its own settings, each with its result'
$calls = & $bios { $script:Calls }
Assert-Equal $calls[-1] 'Lenovo_SaveBiosSettings.SaveBiosSettings(parameter=sup,ascii,us)' 'Lenovo: changes are saved once with the password'

& $bios { $script:LenovoSave = 'Access Denied'; $script:Calls.Clear() }
$r = @(Set-BiosSettings -Maker Lenovo -Settings $all[0])
Assert-Equal "$($r[0].Ok)|$($r[0].Detail)" 'False|Save failed: Access Denied' 'Lenovo: a failed save fails every setting'
Assert-Equal (& $bios { $script:Calls[-1] }) 'Lenovo_SaveBiosSettings.SaveBiosSettings(parameter=)' 'Lenovo: saved with an empty password when none is set'

$r = @(Set-BiosSettings -Maker HP -Settings $all -Password 'pw')
Assert-Equal (($r | ForEach-Object { "$($_.Name)=$($_.Ok)/$($_.Detail)" }) -join ';') 'Secure Boot=True/OK;Locked=False/Access denied (BIOS password?)' 'HP: results with readable return codes'
Assert-Equal (& $bios { $script:Calls[-1] }) 'HP_BIOSSettingInterface.SetBIOSSetting(Name=Locked;Password=<utf-16/>pw;Value=Enable)' 'HP: password sent with its encoding prefix'

Assert-Equal @(Set-BiosSettings -Maker 'Microsoft Corporation' -Settings $all).Count 0 'other makers: nothing applied'
$err = try { Set-BiosSettings -Maker Dell -Settings @([pscustomobject]@{ Maker = 'Dell'; Name = 'SecureBoot'; Value = 'Enabled' }) -ToolsDir (Join-Path ([IO.Path]::GetTempPath()) 'no-such-dir'); '' } catch { $_.Exception.Message }
Assert-Equal ($err -like '*Dell Command | Configure not found*') $true 'Dell: a missing cctk.exe is reported'
Assert-Equal (@(& $bios { $script:Log } | Where-Object { $_ -like '*sup*' -or $_ -like '*pw*' }).Count) 0 'passwords never reach the log'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
