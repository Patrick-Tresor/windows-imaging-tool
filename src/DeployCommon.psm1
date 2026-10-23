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

function Resolve-DriverPack {
    # Picks the most specific catalog entry for this PC. Returns a full path, or $null for inbox drivers only.
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$DriverRoot
    )
    $catalog = Get-Content -Raw -Path $CatalogPath | ConvertFrom-Json
    $mine = @($catalog.entries | Where-Object { $_.maker -eq $Identity.Maker })

    $match =
        ($mine | Where-Object { $_.sku -and $_.sku -eq $Identity.Sku } | Select-Object -First 1)
    if (-not $match) { $match = $mine | Where-Object { $_.machineType -and $_.machineType -eq $Identity.MachineType } | Select-Object -First 1 }
    if (-not $match) { $match = $mine | Where-Object { $_.model -and $_.model -eq $Identity.Model } | Select-Object -First 1 }
    if (-not $match) { $match = $mine | Where-Object { $_.modelPattern -and $Identity.Model -like $_.modelPattern } | Select-Object -First 1 }

    $relative = $null
    if ($match) {
        $relative = $match.path
        Write-DeployLog "Driver catalog match: $relative"
    } elseif ($catalog.fallbacks.PSObject.Properties[$Identity.Maker]) {
        $relative = $catalog.fallbacks.($Identity.Maker)
        Write-DeployLog "No exact driver pack for '$($Identity.Model)'; using maker fallback $relative" -Level WARN
    } else {
        Write-DeployLog "No driver pack for $($Identity.Maker) '$($Identity.Model)'; Windows inbox drivers only" -Level WARN
    }

    if (-not $relative) { return $null }
    $full = Join-Path $DriverRoot $relative
    if (-not (Test-Path $full)) {
        Write-DeployLog "Driver folder missing: $full" -Level WARN
        return $null
    }
    $full
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

    $cred = Get-ShareCredential -SettingsPath $SettingsPath
    Mount-NetworkShare -LocalName 'Z:' -RemoteName $settings.share.path -User $cred.User -Password $cred.Password
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

function Get-ShareCredential {
    # The share account from deploy-settings.json. The password file sits next to config\ on the media (X:\Deploy).
    param([Parameter(Mandatory)][string]$SettingsPath)
    $settings = Get-Content -Raw $SettingsPath | ConvertFrom-Json
    $password = $null
    if ($settings.share.user -and $settings.share.passwordFile) {
        $pwFile = Join-Path (Split-Path $SettingsPath -Parent | Split-Path -Parent) $settings.share.passwordFile
        if (Test-Path $pwFile) { $password = (Get-Content -Raw $pwFile).Trim() }
    }
    [pscustomobject]@{ User = $settings.share.user; Password = $password }
}

function Get-MulticastPlan {
    # Decides whether this deploy downloads the image by WDS multicast, and what to ask the server for.
    # Returns $null for a unicast deploy (multicast off, USB content, image outside the content root, split image),
    # otherwise the server, namespace and the image path relative to the content root (the namespace's folder).
    param(
        $Settings,                                  # deploy-settings.json object
        [Parameter(Mandatory)][string]$ContentRoot, # Z:\ for the share, D:\ for USB
        [Parameter(Mandatory)][string]$ImagePath,
        [bool]$IsNetworkRoot = $true
    )
    $mc = $Settings.multicast
    if (-not $mc -or -not $mc.enabled -or -not $IsNetworkRoot) { return $null }
    if ($ImagePath -like '*.swm') { return $null }
    $root = $ContentRoot.TrimEnd('\', '/') + '\'
    $image = $ImagePath -replace '/', '\'
    if (-not $image.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    # The transport server is the WDS server; failing that, the server that hosts the share.
    $server = "$($mc.server)".Trim()
    if (-not $server) { $server = "$($Settings.wds.server)".Trim() }
    if (-not $server -and "$($Settings.share.path)" -match '^\\\\([^\\]+)\\') { $server = $Matches[1] }
    if (-not $server) { return $null }
    [pscustomobject]@{
        Server     = $server
        Namespace  = $(if ("$($mc.namespace)".Trim()) { "$($mc.namespace)".Trim() } else { 'ImagingTool' })
        SourceFile = $image.Substring($root.Length)
        Fallback   = $(if ($null -eq $mc.fallback) { $true } else { [bool]$mc.fallback })
    }
}

function Receive-MulticastImage {
    # Downloads one file from a WDS multicast namespace with wdsmcast.exe (the WDS transport client in WinPE).
    # With a scheduled session it waits here until enough PCs have joined or the start time comes.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Destination,
        [string]$User,
        [string]$Password
    )
    $exe = @("$env:SystemRoot\System32\wdsmcast.exe", (Join-Path $PSScriptRoot 'Tools\wdsmcast.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw 'wdsmcast.exe is not in this WinPE image.' }
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    $mcArgs = @('/Transfer-File', "/Server:$($Plan.Server)", "/Namespace:$($Plan.Namespace)",
        "/SourceFile:$($Plan.SourceFile)", "/DestinationFile:$Destination")
    if ($User) {
        $mcArgs += "/Username:$User"   # DOMAIN\user
        if ($Password) { $mcArgs += "/Password:$Password" }
    }
    # Log the command without the password; leave the console attached so the progress shows.
    Write-DeployLog "Multicast: $($Plan.SourceFile) from $($Plan.Server) namespace $($Plan.Namespace) to $Destination"
    & $exe @mcArgs
    if ($LASTEXITCODE -ne 0) { throw "wdsmcast exited with code $LASTEXITCODE" }
    if (-not (Test-Path $Destination)) { throw "wdsmcast finished but $Destination is missing" }
    $Destination
}

Export-ModuleMember -Function Write-DeployLog, Invoke-Native, Get-HardwareIdentity, Test-UefiBoot, Resolve-DriverPack, Find-ContentRoot, Mount-NetworkShare,
    Get-ShareCredential, Get-MulticastPlan, Receive-MulticastImage
