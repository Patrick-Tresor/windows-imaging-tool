# Shared helpers for capture and deploy. Runs in WinPE (PowerShell 5.1, WinPE-PowerShell component).

$script:LogPath = 'X:\Windows\Temp\Deploy.log'

function Write-DeployLog {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $script:LogPath -Value $line
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Invoke-Native {
    # Runs an external tool, logs it, and throws on a non-zero exit code.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @())
    Write-DeployLog "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { Add-Content -Path $script:LogPath -Value "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE" }
}

function Get-HardwareIdentity {
    # Returns the values the driver catalog can match on.
    $cs   = Get-CimInstance Win32_ComputerSystem
    $csp  = Get-CimInstance Win32_ComputerSystemProduct
    $bios = Get-CimInstance Win32_BIOS
    $sku  = $null
    try { $sku = (Get-CimInstance -Namespace root\wmi -ClassName MS_SystemInformation -ErrorAction Stop).SystemSKU } catch { }

    $maker = switch -Wildcard ($cs.Manufacturer.Trim()) {
        'Dell*'            { 'Dell' }
        'HP' { 'HP' }
        'Hewlett*'         { 'HP' }
        'LENOVO'           { 'Lenovo' }
        default            { $cs.Manufacturer.Trim() }
    }

    $model = $cs.Model.Trim()
    $machineType = $null
    if ($maker -eq 'Lenovo') {
        # Lenovo puts the machine type (e.g. 21HDS0AB00) in Model and the friendly name in Version.
        $machineType = $model.Substring(0, [Math]::Min(4, $model.Length))
        $model = $csp.Version.Trim()
    }
    if ($maker -eq 'HP' -and $sku) {
        # HP's SystemSKU is the order number; the 4-char baseboard product is what driver catalogs use.
        $sku = (Get-CimInstance Win32_BaseBoard).Product.Trim()
    }

    [pscustomobject]@{
        Maker       = $maker
        Model       = $model
        MachineType = $machineType
        Sku         = if ($sku) { $sku.Trim() } else { $null }
        Serial      = $bios.SerialNumber.Trim()
        IsUefi      = Test-UefiBoot
    }
}

function Test-UefiBoot {
    # WinPE records the firmware type here: 1 = BIOS, 2 = UEFI.
    (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType -eq 2
}

function Find-DriverCatalogMatch {
    # The most specific catalog entry for a PC, without logging, so the console can re-check reported PCs.
    # Status: Matched, InboxOnly (an entry with no path), Fallback (maker fallback), None.
    param(
        [Parameter(Mandatory)]$Identity,
        [string]$CatalogPath,
        $Catalog   # the parsed catalog, instead of CatalogPath, when checking many PCs
    )
    $catalog = if ($Catalog) { $Catalog } else { Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json }
    $mine = @($catalog.entries | Where-Object { $_.maker -eq $Identity.Maker })

    $by = 'sku'
    $match = $mine | Where-Object { $_.sku -and $_.sku -eq $Identity.Sku } | Select-Object -First 1
    if (-not $match) { $by = 'machineType';  $match = $mine | Where-Object { $_.machineType -and $_.machineType -eq $Identity.MachineType } | Select-Object -First 1 }
    if (-not $match) { $by = 'model';        $match = $mine | Where-Object { $_.model -and $_.model -eq $Identity.Model } | Select-Object -First 1 }
    if (-not $match) { $by = 'modelPattern'; $match = $mine | Where-Object { $_.modelPattern -and $Identity.Model -like $_.modelPattern } | Select-Object -First 1 }

    if ($match) {
        $status = if ($match.path) { 'Matched' } else { 'InboxOnly' }
        return [pscustomobject]@{ Status = $status; MatchedBy = $by; Path = $match.path }
    }
    if ($catalog.fallbacks -and $catalog.fallbacks.PSObject.Properties[$Identity.Maker]) {
        return [pscustomobject]@{ Status = 'Fallback'; MatchedBy = 'fallback'; Path = $catalog.fallbacks.($Identity.Maker) }
    }
    [pscustomobject]@{ Status = 'None'; MatchedBy = $null; Path = $null }
}

function Resolve-DriverPack {
    # Picks the most specific catalog entry for this PC. Returns a full path, or $null for inbox drivers only.
    # -Detailed returns the Find-DriverCatalogMatch result with FullPath added (MissingFolder when it is not there).
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$DriverRoot,
        [switch]$Detailed
    )
    $m = Find-DriverCatalogMatch -Identity $Identity -CatalogPath $CatalogPath
    switch ($m.Status) {
        'Matched'   { Write-DeployLog "Driver catalog match: $($m.Path)" }
        'InboxOnly' { Write-DeployLog "Catalog says Windows inbox drivers only for '$($Identity.Model)'" }
        'Fallback'  { Write-DeployLog "No exact driver pack for '$($Identity.Model)'; using maker fallback $($m.Path)" -Level WARN }
        'None'      { Write-DeployLog "No driver pack for $($Identity.Maker) '$($Identity.Model)'; Windows inbox drivers only" -Level WARN }
    }

    $full = $null
    if ($m.Path) {
        $full = Join-Path $DriverRoot ($m.Path -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $full)) {
            Write-DeployLog "Driver folder missing: $full" -Level WARN
            $full = $null
            if ($m.Status -eq 'Matched') { $m.Status = 'MissingFolder' }
        }
    }
    if (-not $Detailed) { return $full }
    $m | Add-Member -NotePropertyName FullPath -NotePropertyValue $full -PassThru
}

function Write-DriverReport {
    # Records which drivers this PC got in <content root>\Reports\Drivers\<serial>.json, one file per PC, newest
    # deployment wins. The console's Unknown Models report lists the PCs that got no exact pack.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)]$Match,
        [string]$ComputerName,
        [string]$AnswerFile,
        [string]$Result
    )
    $dir = Join-Path (Join-Path $ContentRoot 'Reports') 'Drivers'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $serial = "$($Identity.Serial)" -replace '[\\/:*?"<>|\s]', '_'
    if (-not $serial.Trim('_')) { $serial = "$($Identity.Maker)-$($Identity.Model)" -replace '[\\/:*?"<>|\s]', '_' }
    [ordered]@{
        serial       = $Identity.Serial
        computerName = $ComputerName
        maker        = $Identity.Maker
        model        = $Identity.Model
        sku          = $Identity.Sku
        machineType  = $Identity.MachineType
        driverStatus = $Match.Status
        matchedBy    = $Match.MatchedBy
        driverPath   = $Match.Path
        answerFile   = $AnswerFile
        result       = $Result
        date         = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -Path (Join-Path $dir "$serial.json") -Encoding utf8
}

function Find-ContentRoot {
    # USB first: any volume labelled DEPLOY that holds an Images folder. Otherwise map the share from settings.
    param([string]$SettingsPath)
    foreach ($vol in Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq 'DEPLOY' }) {
        $root = "$($vol.DriveLetter):\"
        if (Test-Path (Join-Path $root 'Images')) { Write-DeployLog "Using USB content at $root"; return $root }
    }

    if (-not $SettingsPath -or -not (Test-Path $SettingsPath)) { throw 'No DEPLOY volume found and no settings file to locate a network share.' }
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    if (-not $settings.share.path) { throw 'No DEPLOY volume found and no share configured.' }

    Write-DeployLog "Waiting for network to reach $($settings.share.path)"
    Invoke-Native -FilePath 'wpeutil.exe' -ArgumentList @('WaitForNetwork')

    $password = $null
    if ($settings.share.user -and $settings.share.passwordFile) {
        $pwFile = Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $settings.share.passwordFile
        if (Test-Path $pwFile) { $password = (Get-Content -Raw $pwFile).Trim() }
    }
    Mount-NetworkShare -LocalName 'Z:' -RemoteName $settings.share.path -User $settings.share.user -Password $password
    Write-DeployLog "Using network content at Z:\"
    'Z:\'
}

function Mount-NetworkShare {
    # Maps a share with net use. With a user but no password, net use prompts for it on the console.
    param(
        [Parameter(Mandatory)][string]$LocalName,
        [Parameter(Mandatory)][string]$RemoteName,
        [string]$User,
        [string]$Password
    )
    $netArgs = @('use', $LocalName, $RemoteName)
    if ($User) { $netArgs += @("/user:$User", $(if ($Password) { $Password } else { '*' })) }
    # Log the command without the password.
    Write-DeployLog "Mapping $LocalName to $RemoteName$(if ($User) { " as $User" })"
    if ($User -and -not $Password) { & net.exe @netArgs }   # leave the console attached so the prompt shows
    else { & net.exe @netArgs 2>&1 | Out-Null }
    if ($LASTEXITCODE -ne 0) { throw "Could not map $RemoteName (net use exit code $LASTEXITCODE)." }
}

Export-ModuleMember -Function Write-DeployLog, Invoke-Native, Get-HardwareIdentity, Test-UefiBoot, Find-DriverCatalogMatch, Resolve-DriverPack, Write-DriverReport, Find-ContentRoot, Mount-NetworkShare
