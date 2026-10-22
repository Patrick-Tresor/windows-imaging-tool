# Plain-PowerShell tests for the console data layer and driver matching. Run: pwsh -File tests/ConsoleData.Tests.ps1
# Works on Windows and Linux; exits non-zero on the first failing group.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-test-" + [guid]::NewGuid())
& $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root
    Assert-Equal (Test-ContentRoot $root) $true 'content root is created and recognized'

    # Seed a driver folder and import a second pack from a folder.
    $src = Join-Path $root 'src-pack'
    New-Item -ItemType Directory -Path (Join-Path $src 'net') -Force | Out-Null
    Set-Content (Join-Path $src 'net/e1d.inf') '[Version]'
    $result = Import-DriverPack -ContentRoot $root -Source $src -Maker 'HP' -Model 'ProBook 450 G10' -Sku '8B41'
    Assert-Equal $result.InfCount 1 'import copies the .inf files'
    Assert-Equal $result.Path 'HP\ProBook 450 G10' 'import returns the catalog-relative path'

    $rows = @(Get-DriverCatalogRows -ContentRoot $root)
    $hp = $rows | Where-Object Sku -eq '8B41'
    Assert-Equal $hp.Status '1 drivers' 'catalog row shows the driver count'
    Assert-Equal (($rows | Where-Object Model -eq 'Latitude 5440').Status) 'Missing folder' 'catalog row flags a missing folder'

    # Saving drops empty fields and keeps fallbacks.
    Save-DriverCatalog -ContentRoot $root -Rows ($rows | Where-Object Maker -ne 'Dell')
    $catalog = Get-DriverCatalog -ContentRoot $root
    Assert-Equal (@($catalog.entries | Where-Object maker -eq 'Dell').Count) 0 'removed rows are dropped on save'
    Assert-Equal ($catalog.fallbacks.HP) 'HP\_Generic WinPE-Storage-Net' 'fallbacks survive a save'
    Assert-Equal ($null -eq ($catalog.entries | Where-Object sku -eq '8B41').PSObject.Properties['modelPattern']) $true 'empty match fields are not written'

    $threw = $false
    try { Save-DriverCatalog -ContentRoot $root -Rows @([pscustomobject]@{ Maker = 'Acer'; Path = 'Acer\X' }) } catch { $threw = $true }
    Assert-Equal $threw $true 'an entry with nothing to match on is rejected'

    # The imported pack is what the deploy script would pick for that PC.
    $hw = [pscustomobject]@{ Maker = 'HP'; Model = 'HP ProBook 450 15.6 inch G10'; MachineType = $null; Sku = '8B41' }
    $pack = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config/driver-catalog.json') -DriverRoot (Join-Path $root 'Drivers') 6>$null
    Assert-Equal ([IO.Path]::GetFileName($pack)) 'ProBook 450 G10' 'deploy matches the imported pack by SKU'

    # Images: split parts count as one image.
    Set-Content (Join-Path $root 'Images/Win11.wim') 'x'
    Set-Content (Join-Path $root 'Images/Big.swm') 'x'
    Set-Content (Join-Path $root 'Images/Big2.swm') 'x'
    $images = @(Get-ImageList -ContentRoot $root)
    Assert-Equal ($images.Name -join ',') 'Big.swm,Win11.wim' 'image list hides extra .swm parts'
    Assert-Equal (($images | Where-Object Name -eq 'Big.swm').Parts) 2 'split image counts its parts'

    # Logs: name parsing.
    Set-Content (Join-Path $root 'Logs/ABC123_20261022-1530_OK.log') 'done'
    $log = Get-DeploymentLogs -ContentRoot $root | Select-Object -First 1
    Assert-Equal "$($log.Serial)|$($log.Status)|$($log.When.ToString('yyyy-MM-dd HH:mm'))" 'ABC123|OK|2026-10-22 15:30' 'log name is parsed'

    # Settings round-trip.
    $s = Get-DeploySettings -ContentRoot $root
    $s.defaultImage = 'Win11.wim'
    Save-DeploySettings -ContentRoot $root -Settings $s
    Assert-Equal (Get-DeploySettings -ContentRoot $root).defaultImage 'Win11.wim' 'settings round-trip'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
