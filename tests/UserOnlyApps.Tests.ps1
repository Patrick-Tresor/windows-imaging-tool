# Plain-PowerShell tests for Get-UserOnlyApps in Prepare-Reference.ps1: -RemoveUserApps must never remove the
# Microsoft Store or the packages it needs. Run: pwsh -File tests/UserOnlyApps.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'src/Prepare-Reference.ps1'

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

# The script needs admin rights and runs sysprep, so load only the function.
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
foreach ($fnName in 'Get-UserOnlyApps', 'Get-UpdatedInboxApps', 'Get-StoreProblem') {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

function New-App($Name, $Version, [switch]$Framework, [switch]$NonRemovable, $Signature = 'Store') {
    [pscustomobject]@{ Name = $Name; PackageFullName = "${Name}_${Version}_x64__8wekyb3d8bbwe"
        IsFramework = [bool]$Framework; NonRemovable = [bool]$NonRemovable; SignatureKind = $Signature }
}
function New-Prov($Name, $Version) { [pscustomobject]@{ DisplayName = $Name; PackageName = "${Name}_${Version}_x64__8wekyb3d8bbwe" } }

$installed = @(
    (New-App 'Microsoft.WindowsStore' '22410.1401.6.0'),          # the Store updated itself after provisioning
    (New-App 'Microsoft.StorePurchaseApp' '22408.1401.1.0'),
    (New-App 'Microsoft.DesktopAppInstaller' '1.24.25200.0'),
    (New-App 'Microsoft.UI.Xaml.2.8' '8.2310.30001.0'),
    (New-App 'Microsoft.BingWeather' '4.53.1.0'),                 # provisioned, same version
    (New-App 'SpotifyAB.SpotifyMusic' '1.250.0.0'),               # installed for one user only
    (New-App 'Microsoft.WindowsNotepad' '11.2410.21.0'),          # provisioned, then updated by the Store
    (New-App 'Microsoft.VCLibs.140.00' '14.0.33519.0' -Framework),
    (New-App 'Microsoft.Windows.ShellExperienceHost' '10.0.0.0' -NonRemovable),
    (New-App 'Contoso.LineOfBusiness' '1.0.0.0' -Signature 'Developer')
)
$provisioned = @(
    (New-Prov 'Microsoft.WindowsStore' '22305.1401.4.0'),
    (New-Prov 'Microsoft.BingWeather' '4.53.1.0'),
    (New-Prov 'Microsoft.WindowsNotepad' '11.2302.16.0')
)

$found = @(Get-UserOnlyApps -Installed $installed -Provisioned $provisioned)
Assert-Equal (($found.Name | Sort-Object) -join ',') 'SpotifyAB.SpotifyMusic' 'only the user-only app is returned'
Assert-Equal (@($found | Where-Object Name -like 'Microsoft.WindowsStore').Count) 0 'an updated Microsoft Store is never returned for removal'
Assert-Equal (@(Get-UserOnlyApps -Installed @() -Provisioned $provisioned).Count) 0 'nothing installed returns nothing'
Assert-Equal (@($found | Where-Object Name -eq 'Microsoft.WindowsNotepad').Count) 0 'a Windows app the Store updated is never returned for removal'

$updated = @(Get-UpdatedInboxApps -Installed $installed -Provisioned $provisioned)
Assert-Equal (($updated.Name | Sort-Object) -join ',') 'Microsoft.WindowsNotepad,Microsoft.WindowsStore' 'updated Windows apps are reported'

Assert-Equal "$(Get-StoreProblem -Installed $installed -Provisioned $provisioned)" '' 'a provisioned Store is no problem'
$noStore = @($provisioned | Where-Object DisplayName -ne 'Microsoft.WindowsStore')
$msg = "$(Get-StoreProblem -Installed $installed -Provisioned $noStore)"
Assert-Equal ($msg -like '*installed for a user*not provisioned*') $true 'a Store installed only for a user (wsreset -i) is a problem'
$msg = "$(Get-StoreProblem -Installed @() -Provisioned $noStore)"
Assert-Equal ($msg -like '*not installed or provisioned*') $true 'a Store that is gone is a problem'

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
