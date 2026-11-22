# Unknown models report: PCs that were deployed without an exact driver pack, read from the dashboard's status
# records (Status\<id>.json, which Deploy-Image.ps1 writes with the driver match), and the vendor pack that would
# fix each model. No UI code here, so it can be tested without Windows.

Import-Module (Join-Path $PSScriptRoot 'ConsoleData.psm1')
Import-Module (Join-Path $PSScriptRoot 'DriverPacks.psm1')
# Same matching as the deploy, so a model drops off the report as soon as the catalog covers it.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeployCommon.psm1') -Function Find-DriverCatalogMatch
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeployStatus.psm1') -Function Get-StatusFolder

function Get-DriverReportDir {
    # Where the deployment records are: the dashboard's status folder.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $settings = try { Get-DeploySettings -ContentRoot $ContentRoot } catch { $null }
    Get-StatusFolder -ContentRoot $ContentRoot -Settings $settings
}

function Get-DriverReportRecords {
    # One record per deployed PC (its newest deployment), from the status records. Older tool versions wrote
    # Reports\Drivers\<serial>.json instead; those are still read, and a newer status record of the same PC wins.
    # Cancelled deployments and records without a driver match are left out. Unreadable files are skipped.
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$StatusFolder)
    if (-not $StatusFolder) { $StatusFolder = Get-DriverReportDir $ContentRoot }
    $all = @(
        foreach ($f in Get-ChildItem -Path $StatusFolder -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $s = Get-Content -Raw $f.FullName | ConvertFrom-Json } catch { Write-Warning "Skipping $($f.Name): $($_.Exception.Message)"; continue }
            if (-not $s.PSObject.Properties['driverStatus'] -or -not $s.driverStatus -or $s.state -eq 'Cancelled') { continue }
            $when = try { ([datetime]$s.started).ToString('yyyy-MM-dd HH:mm') } catch { '' }
            [pscustomobject]@{
                serial = $s.serial; computerName = $s.computerName; maker = $s.maker; model = $s.model
                sku = $s.sku; machineType = $s.machineType; driverStatus = $s.driverStatus; date = $when
            }
        }
        foreach ($f in Get-ChildItem -Path (Join-ContentPath $ContentRoot 'Reports\Drivers') -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { Get-Content -Raw $f.FullName | ConvertFrom-Json } catch { Write-Warning "Skipping $($f.Name): $($_.Exception.Message)" }
        }
    )
    $all | Group-Object { if ($_.serial) { "$($_.serial)" } else { "$($_.maker)|$($_.model)" } } |
        ForEach-Object { $_.Group | Sort-Object date -Descending | Select-Object -First 1 }
}

function Get-UnknownModels {
    <#
    .SYNOPSIS
        Models that got a maker fallback, no drivers, or a missing driver folder, re-checked against the current
        catalog and library, grouped by maker, model and SKU / machine type, most PCs first.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot)
    $catalog = Get-DriverCatalog -ContentRoot $ContentRoot
    $driverRoot = Join-Path $ContentRoot 'Drivers'
    $open = foreach ($r in Get-DriverReportRecords -ContentRoot $ContentRoot) {
        $id = [pscustomobject]@{ Maker = $r.maker; Model = $r.model; Sku = $r.sku; MachineType = $r.machineType }
        $m = Find-DriverCatalogMatch -Identity $id -Catalog $catalog
        $now = $m.Status
        if ($now -eq 'Matched' -and -not (Test-Path (Join-ContentPath $driverRoot $m.Path))) { $now = 'MissingFolder' }
        if ($now -in 'Matched', 'InboxOnly') { continue }   # fixed since that deployment
        $r | Add-Member -NotePropertyName CurrentStatus -NotePropertyValue $now -Force -PassThru
    }

    $open | Group-Object { "$($_.maker)|$($_.model)|$($_.sku)|$($_.machineType)" } | ForEach-Object {
        $pcs = @($_.Group | Sort-Object date -Descending)
        $first = $pcs[0]
        [pscustomobject]@{
            Maker       = $first.maker
            Model       = $first.model
            Sku         = $first.sku
            MachineType = $first.machineType
            Ids         = (@($first.sku, $first.machineType) | Where-Object { $_ }) -join ' '
            PCs         = $pcs.Count
            Computers   = (@($pcs | ForEach-Object { if ($_.computerName) { $_.computerName } else { $_.serial } }) -join ', ')
            LastSeen    = $first.date
            Drivers     = switch ($first.CurrentStatus) {
                              'Fallback'      { 'Maker fallback' }
                              'MissingFolder' { 'Folder missing' }
                              default         { 'Inbox only' }
                          }
            Serials     = @($pcs.serial)
        }
    } | Sort-Object @{ e = 'PCs'; Descending = $true }, Maker, Model
}

function Find-VendorPackForModel {
    # The vendor pack for a reported model: by SKU (Dell system ID, HP platform ID), Lenovo machine type, then model name.
    param([Parameter(Mandatory)]$Model, [object[]]$Packs)
    $mine = @($Packs | Where-Object Maker -eq $Model.Maker)
    $sku = "$($Model.Sku)".Trim().ToUpperInvariant()
    $type = "$($Model.MachineType)".Trim().ToUpperInvariant()
    $hit = $null
    if ($sku) { $hit = $mine | Where-Object { $_.Skus -contains $sku } | Select-Object -First 1 }
    if (-not $hit -and $type) { $hit = $mine | Where-Object { $_.MachineTypes -contains $type } | Select-Object -First 1 }
    if (-not $hit -and $Model.Model) { $hit = $mine | Where-Object { $_.Model -eq "$($Model.Model)".Trim() } | Select-Object -First 1 }
    $hit
}

function Add-UnknownModelPacks {
    <#
    .SYNOPSIS
        Adds Pack (the vendor pack, or $null) and PackText to each unknown model row. Reads each vendor
        catalog once. -CatalogPaths (maker -> XML path) skips the download, for tests and offline use.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [hashtable]$CatalogPaths = @{},
        [switch]$Refresh
    )
    $packs = @{}
    $errors = @{}
    foreach ($maker in @($Models.Maker | Select-Object -Unique)) {
        if ($maker -notin 'Dell', 'HP', 'Lenovo') { continue }
        try {
            $packs[$maker] = @(Get-VendorDriverPacks -Maker $maker -CatalogPath $CatalogPaths[$maker] -Refresh:$Refresh)
        } catch { $errors[$maker] = $_.Exception.Message }
    }
    foreach ($m in $Models) {
        $pack = $null
        $text = if ($m.Maker -notin 'Dell', 'HP', 'Lenovo') { "No vendor catalog for $($m.Maker); import a pack by hand" }
                elseif ($errors[$m.Maker]) { "Could not read the $($m.Maker) catalog: $($errors[$m.Maker])" }
                else {
                    $pack = Find-VendorPackForModel -Model $m -Packs $packs[$m.Maker]
                    if ($pack) { ('{0} {1} {2}, {3} MB' -f $pack.Model, $pack.Release, $pack.Version, $pack.SizeMB) -replace '\s+', ' ' }
                    else { "Not in the $($m.Maker) catalog" }
                }
        $m | Add-Member -NotePropertyName Pack -NotePropertyValue $pack -Force
        $m | Add-Member -NotePropertyName PackText -NotePropertyValue $text -Force -PassThru
    }
}

function Set-UnknownModelInbox {
    # Marks a model as needing no pack (e.g. a VM): a catalog entry with no folder, so it leaves the report
    # and future deploys use Windows inbox drivers without a warning. Keyed on the most exact value reported.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Model)
    $row = [pscustomobject]@{ Maker = $Model.Maker; Sku = $null; MachineType = $null; Model = $null; ModelPattern = $null; Path = $null }
    if ($Model.Sku) { $row.Sku = $Model.Sku } elseif ($Model.MachineType) { $row.MachineType = $Model.MachineType } else { $row.Model = $Model.Model }
    # First, so it wins over a looser model or pattern entry.
    Save-DriverCatalog -ContentRoot $ContentRoot -Rows @(@($row) + @(Get-DriverCatalogRows -ContentRoot $ContentRoot))
}

Export-ModuleMember -Function Get-DriverReportDir, Get-DriverReportRecords, Get-UnknownModels, Find-VendorPackForModel,
    Add-UnknownModelPacks, Set-UnknownModelInbox
