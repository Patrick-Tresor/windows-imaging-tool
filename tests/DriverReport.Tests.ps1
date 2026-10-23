# Plain-PowerShell tests for the unknown models report: what the deploy records, how the console groups and
# re-checks it, and how it finds the vendor pack. Run: pwsh -File tests/DriverReport.Tests.ps1. No network.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/Console/DriverPacks.psm1') -Force
Import-Module (Join-Path $repo 'src/Console/DriverReport.psm1') -Force
$common = Import-Module (Join-Path $repo 'src/DeployCommon.psm1') -Force -PassThru
$fixtures = Join-Path $PSScriptRoot 'fixtures/driverpacks'

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

function New-Pc($Maker, $Model, $Sku, $MachineType, $Serial) {
    [pscustomobject]@{ Maker = $Maker; Model = $Model; Sku = $Sku; MachineType = $MachineType; Serial = $Serial }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("driverreport-test-" + [guid]::NewGuid())
& $common { param($p) $script:LogPath = $p } (Join-Path $root 'test.log')
try {
    Initialize-ContentRoot -Path $root
    $catalog = Join-Path $root 'config/driver-catalog.json'
    $drivers = Join-Path $root 'Drivers'
    New-Item -ItemType Directory -Path (Join-Path $drivers 'Dell/Latitude 5440') -Force | Out-Null

    # What the deploy decides, per kind of PC.
    $deploy = {
        param($Pc, $Name)
        $m = Resolve-DriverPack -Identity $Pc -CatalogPath $catalog -DriverRoot $drivers -Detailed 6>$null
        Write-DriverReport -ContentRoot $root -Identity $Pc -Match $m -ComputerName $Name -AnswerFile Default -Result OK
        $m
    }
    $ok      = & $deploy (New-Pc Dell 'Latitude 5440' '0B0B' $null 'SN-OK') 'PC-OK'
    $fb1     = & $deploy (New-Pc Dell 'Latitude 5540' '0B0C' $null 'SN-1') 'PC-1'
    $fb2     = & $deploy (New-Pc Dell 'Latitude 5540' '0B0C' $null 'SN-2') 'PC-2'
    $missing = & $deploy (New-Pc HP 'HP EliteBook 840 14 inch G9 Notebook PC' '8A86' $null 'SN-HP') 'PC-HP'
    $none    = & $deploy (New-Pc 'Acme' 'Box 1' $null $null 'To be filled by O.E.M.') $null
    $vm      = & $deploy (New-Pc 'Microsoft Corporation' 'Virtual Machine' $null $null 'SN-VM') 'PC-VM'

    Assert-Equal "$($ok.Status) $($ok.MatchedBy) $([bool]$ok.FullPath)" 'Matched sku True' 'deploy: exact match by SKU'
    Assert-Equal "$($fb1.Status) $([bool]$fb1.FullPath)" 'Fallback False' 'deploy: maker fallback (folder not there either)'
    Assert-Equal "$($missing.Status) $($missing.FullPath)" 'MissingFolder ' 'deploy: matched entry with no folder'
    Assert-Equal "$($none.Status)" 'None' 'deploy: unknown maker'
    Assert-Equal "$($vm.Status)" 'InboxOnly' 'deploy: entry with no path is inbox only, not a miss'
    $pack = Resolve-DriverPack -Identity (New-Pc Dell 'Latitude 5440' '0B0B' $null 'x') -CatalogPath $catalog -DriverRoot $drivers 6>$null
    Assert-Equal ([IO.Path]::GetFileName($pack)) 'Latitude 5440' 'deploy: without -Detailed it still returns the folder'

    $reports = Get-DriverReportDir $root
    Assert-Equal (@(Get-ChildItem $reports -Filter *.json).Count) 6 'one report file per PC'
    Assert-Equal (Test-Path (Join-Path $reports 'To_be_filled_by_O.E.M..json')) $true 'serial is made safe for a file name'
    $r = Get-Content -Raw (Join-Path $reports 'SN-1.json') | ConvertFrom-Json
    Assert-Equal "$($r.computerName)|$($r.driverStatus)|$($r.sku)|$($r.result)" 'PC-1|Fallback|0B0C|OK' 'report fields'

    # The report: grouped by model, most PCs first, matched and inbox-only PCs left out.
    $unknown = @(Get-UnknownModels -ContentRoot $root)
    Assert-Equal ($unknown.Model -join ',') 'Latitude 5540,Box 1,HP EliteBook 840 14 inch G9 Notebook PC' 'report: only unknown models, most PCs first'
    $u = $unknown[0]
    Assert-Equal "$($u.PCs)|$($u.Ids)|$($u.Drivers)" '2|0B0C|Maker fallback' 'report: two PCs of the same model are one row'
    Assert-Equal (($u.Computers -split ', ' | Sort-Object) -join ',') 'PC-1,PC-2' 'report: lists the computers'
    Assert-Equal (($unknown | Where-Object Maker -eq HP).Drivers) 'Folder missing' 'report: missing folder'
    Assert-Equal (($unknown | Where-Object Maker -eq Acme).Computers) 'To be filled by O.E.M.' 'report: serial when there is no name'

    # Vendor packs from the sample catalogs.
    $paths = @{ Dell = Join-Path $fixtures 'DriverPackCatalog.xml'; HP = Join-Path $fixtures 'HPClientDriverPackCatalog.xml' }
    $withPacks = @(Add-UnknownModelPacks -Models $unknown -Os 'Windows 11' -CatalogPaths $paths)
    $d = $withPacks | Where-Object Maker -eq Dell
    $dellPack = $d.Pack
    Assert-Equal "$($d.Pack.Model)|$($d.PackText)" 'Latitude 5540|Latitude 5540 A07, 1536 MB' 'packs: Dell found by SKU'
    Assert-Equal (($withPacks | Where-Object Maker -eq HP).Pack.Release) '24H2' 'packs: HP found by platform ID'
    Assert-Equal (($withPacks | Where-Object Maker -eq Acme).PackText) 'No vendor catalog for Acme; import a pack by hand' 'packs: other makers'
    $lenovo = [pscustomobject]@{ Maker = 'Lenovo'; Model = 'ThinkPad T14 Gen 4'; Sku = $null; MachineType = '21HE' }
    $lp = Find-VendorPackForModel -Model $lenovo -Packs @(Get-VendorDriverPacks -Maker Lenovo -CatalogPath (Join-Path $fixtures 'catalogv2.xml'))
    Assert-Equal $lp.Model 'ThinkPad T14 Gen 4' 'packs: Lenovo found by machine type'
    $byName = [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5540'; Sku = 'FFFF'; MachineType = $null }
    Assert-Equal (Find-VendorPackForModel -Model $byName -Packs @($dellPack)).Model 'Latitude 5540' 'packs: model name when the SKU is unknown'
    $bad = @(Add-UnknownModelPacks -Models @($u) -CatalogPaths @{ Dell = (Join-Path $root 'nope.xml') } 3>$null)
    Assert-Equal ($bad[0].PackText -like 'Could not read the Dell catalog*') $true 'packs: catalog errors are shown on the row'

    # Fixing a model takes it off the report: downloading its pack, or marking it inbox only.
    Register-DriverPack -ContentRoot $root -Pack $dellPack -Path 'Dell\Latitude 5540' | Out-Null
    Assert-Equal ((@(Get-UnknownModels -ContentRoot $root)).Model -contains 'Latitude 5540') $true 'report: registered but folder not extracted is still listed'
    New-Item -ItemType Directory -Path (Join-Path $drivers 'Dell/Latitude 5540') -Force | Out-Null
    Assert-Equal ((@(Get-UnknownModels -ContentRoot $root)).Model -contains 'Latitude 5540') $false 'report: downloaded pack clears the model'

    Set-UnknownModelInbox -ContentRoot $root -Model ($unknown | Where-Object Maker -eq Acme)
    $first = (Get-DriverCatalog -ContentRoot $root).entries[0]
    Assert-Equal "$($first.maker)|$($first.model)|$($first.path)" 'Acme|Box 1|' 'inbox: entry with no folder, first in the catalog'
    Assert-Equal ((@(Get-UnknownModels -ContentRoot $root)).Maker -join ',') 'HP' 'inbox: model leaves the report'
    Set-UnknownModelInbox -ContentRoot $root -Model ($unknown | Where-Object Maker -eq HP)
    Assert-Equal ((Get-DriverCatalog -ContentRoot $root).entries[0].sku) '8A86' 'inbox: keyed on the SKU when there is one'
    Assert-Equal @(Get-UnknownModels -ContentRoot $root).Count 0 'report: empty once everything is handled'
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
