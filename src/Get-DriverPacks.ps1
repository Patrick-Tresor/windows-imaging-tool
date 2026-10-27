<#
.SYNOPSIS
    Downloads Dell, HP and Lenovo driver packs from the vendors' catalogs into the driver library.
.DESCRIPTION
    Reads each vendor's driver pack catalog (Dell DriverPackCatalog.cab, HP HPClientDriverPackCatalog.cab,
    Lenovo catalogv2.xml), picks the newest x64 pack for each model, downloads it, checks its hash and
    signature, extracts it to <ContentRoot>\Drivers\<Maker>\<Model> and adds catalog entries for its SKUs
    or machine types and model name. The admin console's Download from vendor... button runs this with -JobFile.
.EXAMPLE
    .\Get-DriverPacks.ps1 -ContentRoot D:\Deploy -Maker Dell -List -Model 'Latitude 54*'
.EXAMPLE
    .\Get-DriverPacks.ps1 -ContentRoot D:\Deploy -Maker Lenovo -Os 'Windows 11' -Model 'ThinkPad T14 Gen 4', 'ThinkPad X1 Carbon Gen 12'
#>
[CmdletBinding(DefaultParameterSetName = 'Model')]
param(
    [Parameter(Mandatory)][string]$ContentRoot,
    [Parameter(Mandatory, ParameterSetName = 'Model')][ValidateSet('Dell', 'HP', 'Lenovo')][string]$Maker,
    [Parameter(ParameterSetName = 'Model')][string[]]$Model = '*',
    [Parameter(ParameterSetName = 'Model')][ValidateSet('Windows 10', 'Windows 11')][string]$Os = 'Windows 11',
    [Parameter(ParameterSetName = 'Model')][switch]$List,
    # Written by the console: a JSON array of packs as returned by Get-VendorDriverPacks.
    [Parameter(Mandatory, ParameterSetName = 'Job')][string]$JobFile,
    [switch]$RefreshCatalog,
    [switch]$KeepDownload
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\DriverPacks.psm1') -Force
if (-not (Test-ContentRoot $ContentRoot)) { throw "$ContentRoot is not a content root. Create it in the console first." }

if ($JobFile) {
    $packs = @(Get-Content -Raw $JobFile | ConvertFrom-Json)
} else {
    Write-Host "Reading the $Maker catalog..."
    $packs = @(Get-VendorDriverPacks -Maker $Maker -Os $Os -Refresh:$RefreshCatalog |
        Where-Object { $p = $_; @($Model | Where-Object { $p.Model -like $_ }).Count })
    if ($List) {
        $packs | Add-DriverPackLibraryStatus -ContentRoot $ContentRoot |
            Format-Table Model, Release, Version, Released, SizeMB, @{ n = 'SKUs / types'; e = { ($_.Skus + $_.MachineTypes) -join ' ' } }, Installed -AutoSize
        return
    }
}
if (-not $packs) { Write-Warning 'No matching driver packs.'; return }

$failed = 0
$i = 0
foreach ($p in $packs) {
    $i++
    Write-Host "`n[$i/$($packs.Count)] $($p.Maker) $($p.Model), $($p.Os) $($p.Release) $($p.Version)" -ForegroundColor Cyan
    try {
        $r = Install-VendorDriverPack -ContentRoot $ContentRoot -Pack $p -KeepDownload:$KeepDownload
        Write-Host "OK: $($r.InfCount) drivers in Drivers\$($r.Path), $($r.Entries) catalog entries" -ForegroundColor Green
    } catch {
        $failed++
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}
if ($JobFile) { Remove-Item $JobFile -Force -ErrorAction SilentlyContinue }
Write-Host "`nDone: $($packs.Count - $failed) installed, $failed failed. Click Refresh on the console's Driver Library tab."
if ($failed) { exit 1 }
