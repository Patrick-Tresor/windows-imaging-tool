# Data layer for the admin console: reads and writes the content root (Images, Drivers, config, Logs).
# No UI code here, so it can be tested without Windows.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Join-ContentPath {
    # Catalog paths use backslashes (they are read in WinPE); normalize so the module also runs in tests off Windows.
    param([string]$Root, [string]$Child)
    Join-Path $Root ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
}

function Get-ConsoleConfigPath {
    $base = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME '.config' }
    Join-ContentPath $base 'ImagingConsole\console.json'
}

function Get-ConsoleConfig {
    $path = Get-ConsoleConfigPath
    if (Test-Path $path) { return Get-Content -Raw $path | ConvertFrom-Json }
    [pscustomobject]@{ contentRoot = '' }
}

function Save-ConsoleConfig {
    param([Parameter(Mandatory)]$Config)
    $path = Get-ConsoleConfigPath
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    $Config | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
}

function Initialize-ContentRoot {
    # Creates the folder layout and seeds config files from the repo defaults without overwriting existing ones.
    param([Parameter(Mandatory)][string]$Path)
    foreach ($dir in 'Images', 'Drivers', 'config', 'Logs') {
        New-Item -ItemType Directory -Path (Join-Path $Path $dir) -Force | Out-Null
    }
    foreach ($file in 'driver-catalog.json', 'deploy-settings.json', 'unattend.xml') {
        $dest = Join-ContentPath $Path "config\$file"
        if (-not (Test-Path $dest)) { Copy-Item (Join-ContentPath $script:RepoRoot "config\$file") $dest }
    }
}

function Test-ContentRoot {
    param([string]$Path)
    $Path -and (Test-Path (Join-Path $Path 'Images')) -and (Test-Path (Join-ContentPath $Path 'config\driver-catalog.json'))
}

#region Images

function Get-ImageList {
    param([Parameter(Mandatory)][string]$ContentRoot)
    $dir = Join-Path $ContentRoot 'Images'
    # Split images: list only the first part (Name.swm); Name2.swm, Name3.swm... belong to it.
    $files = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.wim' -or ($_.Extension -eq '.swm' -and $_.BaseName -notmatch '\d+$') }
    foreach ($f in $files) {
        $parts = if ($f.Extension -eq '.swm') { @(Get-ChildItem -Path $dir -Filter "$($f.BaseName)*.swm") } else { @($f) }
        $indexes = ''
        if (Get-Command Get-WindowsImage -ErrorAction SilentlyContinue) {
            try {
                $indexes = (Get-WindowsImage -ImagePath $f.FullName -ErrorAction Stop |
                    ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" }) -join '; '
            } catch { $indexes = '(could not read image)' }
        }
        [pscustomobject]@{
            Name     = $f.Name
            SizeGB   = [Math]::Round((($parts | Measure-Object Length -Sum).Sum) / 1GB, 2)
            Parts    = $parts.Count
            Modified = $f.LastWriteTime
            Indexes  = $indexes
            FullName = $f.FullName
        }
    }
}

#endregion

#region Driver catalog

function Get-DriverCatalog {
    param([Parameter(Mandatory)][string]$ContentRoot)
    Get-Content -Raw (Join-ContentPath $ContentRoot 'config\driver-catalog.json') | ConvertFrom-Json
}

function Get-DriverCatalogRows {
    # Flattens catalog entries into uniform rows for a grid, with a status column showing whether the folder is populated.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $catalog = Get-DriverCatalog -ContentRoot $ContentRoot
    foreach ($e in $catalog.entries) {
        $status = 'Inbox drivers only'
        if ($e.path) {
            $full = Join-ContentPath $ContentRoot "Drivers\$($e.path)"
            $infs = @(Get-ChildItem -Path $full -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue).Count
            $status = if (-not (Test-Path $full)) { 'Missing folder' } elseif ($infs -eq 0) { 'No .inf files' } else { "$infs drivers" }
        }
        [pscustomobject]@{
            Maker        = $e.maker
            Model        = $e.model
            Sku          = $e.sku
            MachineType  = $e.machineType
            ModelPattern = $e.modelPattern
            Path         = $e.path
            Status       = $status
        }
    }
}

function Save-DriverCatalog {
    # Writes grid rows back, dropping empty match fields so the JSON stays readable. Keeps fallbacks and comment.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows
    )
    $catalog = Get-DriverCatalog -ContentRoot $ContentRoot
    $entries = foreach ($r in $Rows) {
        if (-not $r.Maker) { continue }
        $e = [ordered]@{ maker = $r.Maker }
        foreach ($k in 'sku', 'machineType', 'model', 'modelPattern') {
            $v = $r.$k
            if ($v) { $e[$k] = "$v".Trim() }
        }
        if ($e.Count -eq 1) { throw "Entry for $($r.Maker) needs at least one of SKU, machine type, model or model pattern." }
        $e['path'] = if ($r.Path) { "$($r.Path)".Trim() } else { $null }
        [pscustomobject]$e
    }
    $catalog.entries = @($entries)
    $catalog | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-ContentPath $ContentRoot 'config\driver-catalog.json') -Encoding utf8
}

function Import-DriverPack {
    # Copies a driver folder, or expands a CAB, into Drivers\<Maker>\<Model> and adds a catalog entry.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Maker,
        [Parameter(Mandatory)][string]$Model,
        [string]$Sku,
        [string]$MachineType
    )
    $safeModel = $Model -replace '[\\/:*?"<>|]', '_'
    $relative = "$Maker\$safeModel"
    $dest = Join-ContentPath $ContentRoot "Drivers\$relative"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if (Test-Path $Source -PathType Container) {
        Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force
    } elseif ($Source -like '*.cab') {
        & expand.exe $Source -F:* $dest | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "expand.exe failed on $Source" }
    } elseif ($Source -like '*.zip') {
        Expand-Archive -Path $Source -DestinationPath $dest -Force
    } else {
        throw 'Unsupported source. Use a folder, .cab or .zip. Extract vendor .exe packs first (HP: /e /s /f <folder>, Lenovo: /VERYSILENT /EXTRACT=YES /DIR=<folder>).'
    }

    $infs = @(Get-ChildItem -Path $dest -Filter *.inf -Recurse -File).Count
    if ($infs -eq 0) { Write-Warning "No .inf files found in $dest. The pack may still be compressed." }

    $rows = @(Get-DriverCatalogRows -ContentRoot $ContentRoot) + [pscustomobject]@{
        Maker = $Maker; Model = $Model; Sku = $Sku; MachineType = $MachineType; ModelPattern = $null; Path = $relative
    }
    Save-DriverCatalog -ContentRoot $ContentRoot -Rows $rows
    [pscustomobject]@{ Path = $relative; InfCount = $infs }
}

#endregion

#region Settings and logs

function Get-DeploySettings {
    param([Parameter(Mandatory)][string]$ContentRoot)
    Get-Content -Raw (Join-ContentPath $ContentRoot 'config\deploy-settings.json') | ConvertFrom-Json
}

function Save-DeploySettings {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Settings)
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-ContentPath $ContentRoot 'config\deploy-settings.json') -Encoding utf8
}

function Get-DeploymentLogs {
    # Log names are <serial>_<yyyyMMdd-HHmm>_<OK|FAILED>.log, written by Deploy-Image.ps1.
    param([Parameter(Mandatory)][string]$ContentRoot)
    Get-ChildItem -Path (Join-Path $ContentRoot 'Logs') -Filter *.log -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $serial, $stamp, $status = $_.BaseName -split '_', 3
            $when = [datetime]::MinValue
            [void][datetime]::TryParseExact($stamp, 'yyyyMMdd-HHmm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)
            [pscustomobject]@{
                Serial   = $serial
                When     = if ($when -ne [datetime]::MinValue) { $when } else { $_.LastWriteTime }
                Status   = $status
                FullName = $_.FullName
            }
        }
}

#endregion

Export-ModuleMember -Function Get-ConsoleConfig, Save-ConsoleConfig, Initialize-ContentRoot, Test-ContentRoot,
    Get-ImageList, Get-DriverCatalog, Get-DriverCatalogRows, Save-DriverCatalog, Import-DriverPack,
    Get-DeploySettings, Save-DeploySettings, Get-DeploymentLogs
