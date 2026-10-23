# Data layer for the admin console: reads and writes the content root (Images, Drivers, config, Logs).
# No UI code here, so it can be tested without Windows.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AnswerFile.psm1') -Force

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
    foreach ($dir in 'Images', 'Drivers', 'config', 'config\secrets', 'Logs', 'Tools', 'AnswerFiles', 'Applications', 'Computers', 'Reimage') {
        New-Item -ItemType Directory -Path (Join-ContentPath $Path $dir) -Force | Out-Null
    }
    foreach ($file in 'driver-catalog.json', 'deploy-settings.json') {
        $dest = Join-ContentPath $Path "config\$file"
        if (-not (Test-Path $dest)) { Copy-Item (Join-ContentPath $script:RepoRoot "config\$file") $dest }
    }
    $sample = Join-ContentPath $Path 'AnswerFiles\Default.xml'
    if (-not @(Get-ChildItem (Join-Path $Path 'AnswerFiles') -Filter *.xml).Count) {
        Copy-Item (Join-ContentPath $script:RepoRoot 'config\answer-files\Default.xml') $sample
    }
    Update-ContentTools -ContentRoot $Path
}

function Update-ContentTools {
    # Tools\ holds scripts run on the reference machine from the share, so it is always refreshed from the repo.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $dest = Join-Path $ContentRoot 'Tools'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item (Join-ContentPath $script:RepoRoot 'src\Prepare-Reference.ps1') $dest -Force
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

#region Capture

function Test-ImageName {
    # Same rule Capture-GoldenImage.ps1 enforces in WinPE, checked early so the wizard fails before building media.
    param([string]$Name)
    $Name -match '^[A-Za-z0-9._-]+$'
}

function New-CaptureConfig {
    # Writes config\capture.json. Media built with it boots straight into Capture-GoldenImage.ps1.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [ValidateSet('fast', 'max')][string]$Compression = 'max',
        [switch]$SplitForFat32,
        [switch]$Unattended
    )
    if (-not (Test-ImageName $Name)) { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $images = Join-Path $ContentRoot 'Images'
    if ((Test-Path (Join-Path $images "$Name.wim")) -or (Test-Path (Join-Path $images "$Name.swm"))) {
        throw "An image named $Name already exists. Pick another name."
    }
    $cfg = [ordered]@{
        name             = $Name
        description      = $Description
        compression      = $Compression
        splitSizeMB      = if ($SplitForFat32) { 3800 } else { 0 }
        noPrompt         = [bool]$Unattended
        shutdownWhenDone = [bool]$Unattended
    }
    $path = Join-ContentPath $ContentRoot 'config\capture.json'
    [pscustomobject]$cfg | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
    $path
}

function Get-CaptureReadiness {
    # Problems that would make a capture fail in WinPE, for the wizard's summary page.
    # Network captures (ISO for a VM) need the share; USB captures write to the stick's DEPLOY volume.
    param([Parameter(Mandatory)][string]$ContentRoot, [ValidateSet('Network', 'Usb')][string]$Destination)
    $issues = @()
    if ($Destination -eq 'Network') {
        $share = (Get-DeploySettings -ContentRoot $ContentRoot).share.path
        if (-not $share) { $issues += 'No network share is set in Deploy Settings, so WinPE has nowhere to save the image.' }
        elseif ($share -notmatch '^\\\\[^\\]+\\.+') { $issues += "The share '$share' is not a \\server\share path." }
    }
    $issues
}

function Get-ReferenceVMs {
    # Hyper-V VMs that can be captured: generation 2 only, since deploys are UEFI.
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return @() }
    @(Get-VM | ForEach-Object {
        [pscustomobject]@{
            Name       = $_.Name
            State      = "$($_.State)"
            Generation = $_.Generation
            Usable     = $_.Generation -eq 2
            Label      = '{0}  ({1}, gen {2})' -f $_.Name, $_.State, $_.Generation
        }
    })
}

#endregion

#region Answer files

function Get-AnswerFilePath {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Name)
    Join-ContentPath $ContentRoot "AnswerFiles\$Name.xml"
}

function Get-AnswerFileIssues {
    # Validation plus what Deploy-Image.ps1 would trip over on this content root: missing image,
    # applications or password files. Paths outside the content root (extra shares) are not checked.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Answer)
    $a = $Answer
    @(Test-AnswerFile $a)
    $local = { param($p) $p -and -not [IO.Path]::IsPathRooted($p) -and -not $p.StartsWith('\\') -and $p -notmatch '^[A-Za-z]:' }
    if ((& $local $a.ImageFile) -and -not (Test-Path (Join-ContentPath $ContentRoot $a.ImageFile))) { "Image $($a.ImageFile) is not in the content root." }
    if (& $local $a.AppLocation) {
        foreach ($app in $a.Applications) {
            if (-not (Test-Path (Join-ContentPath $ContentRoot "$($a.AppLocation)\$app\app.json"))) { "Application $app has no $($a.AppLocation)\$app\app.json." }
        }
    }
    $secrets = @()
    if ($a.Membership -eq 'Domain') { $secrets += $a.JoinPasswordFile }
    if ($a.EnableAdministrator) { $secrets += $a.AdminPasswordFile }
    $secrets += @($a.Shares | ForEach-Object PasswordFile)
    foreach ($f in $secrets | Where-Object { $_ }) {
        if (-not (Test-Path (Join-ContentPath $ContentRoot $f))) { "Password file $f is missing." }
    }
}

function Get-AnswerFileRows {
    param([Parameter(Mandatory)][string]$ContentRoot)
    $default = (Get-DeploySettings -ContentRoot $ContentRoot).defaultAnswerFile
    Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ IsDefault = ''; Name = $_.BaseName; Mode = ''; Image = ''; Apps = ''; Joins = ''; Status = ''; Issues = @(); FullName = $_.FullName }
        if ($_.BaseName -eq $default) { $row.IsDefault = 'Yes' }
        try {
            $a = Read-AnswerFile -Path $_.FullName -SkipValidation
            $issues = @(Get-AnswerFileIssues -ContentRoot $ContentRoot -Answer $a)
            $row.Mode   = $a.Mode
            $row.Image  = $a.ImageFile
            $row.Apps   = $a.Applications.Count
            $row.Joins  = if ($a.Membership -eq 'Domain') { $a.Domain } else { "Workgroup $($a.Workgroup)" }
            $row.Issues = $issues
            $row.Status = if ($issues) { "$($issues.Count) problem(s)" } else { 'Ready' }
        } catch {
            $row.Status = 'Unreadable'
            $row.Issues = @($_.Exception.Message)
        }
        [pscustomobject]$row
    }
}

function New-AnswerFileFromSample {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Answer file name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $dest = Get-AnswerFilePath -ContentRoot $ContentRoot -Name $Name
    if (Test-Path $dest) { throw "An answer file named $Name already exists." }
    Copy-Item (Join-ContentPath $script:RepoRoot 'config\answer-files\Default.xml') $dest
    $dest
}

function Import-SmartDeployAnswerFile {
    # Converts a SmartDeploy deploy wizard XML into AnswerFiles\<name>.xml. Returns the notes to show the user.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Path, [string]$Name)
    $result = ConvertFrom-SmartDeployAnswerFile -Path $Path
    if (-not $Name) { $Name = $result.Answer.Name -replace '[^A-Za-z0-9._-]', '_' }
    $dest = Get-AnswerFilePath -ContentRoot $ContentRoot -Name $Name
    if (Test-Path $dest) { throw "An answer file named $Name already exists. Rename or delete it first." }
    Export-AnswerFile -Answer $result.Answer -Path $dest
    [pscustomobject]@{ Name = $Name; Path = $dest; Notes = $result.Notes }
}

function Get-NewAnswer {
    # A fresh answer object for the editor: the repo sample's defaults, with password files named after it.
    param([Parameter(Mandatory)][string]$Name)
    $a = Read-AnswerFile -Path (Join-ContentPath $script:RepoRoot 'config\answer-files\Default.xml') -SkipValidation
    $a.Name = $Name
    $a.Path = $null
    $a.JoinPasswordFile = "config\secrets\$Name-join.txt"
    $a.AdminPasswordFile = "config\secrets\$Name-admin.txt"
    $a
}

function Test-SecretFile {
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$RelativePath)
    [bool]($RelativePath -and (Test-Path (Join-ContentPath $ContentRoot $RelativePath)))
}

function Save-SecretFile {
    # Writes one password to its own file under the content root. See the README on who can read it.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string]$Value)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '\.\.') { throw "Password file '$RelativePath' must be a path inside the content root." }
    $path = Join-ContentPath $ContentRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Set-Content -Path $path -Value $Value -NoNewline -Encoding utf8
}

function Save-AnswerFromEditor {
    <#
    .SYNOPSIS
        Saves an answer object edited in the console. Passwords typed in the editor are written to the answer's
        password files (named after the answer file when it has none). Throws with the problems if it can't be deployed.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Answer,
        [string]$JoinPassword,
        [string]$AdminPassword,
        [hashtable]$SharePasswords = @{},   # local name (Y:) -> password
        [switch]$IsNew
    )
    $a = $Answer
    if ($a.Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Answer file name '$($a.Name)' may only contain letters, digits, dot, dash and underscore." }
    $dest = Get-AnswerFilePath -ContentRoot $ContentRoot -Name $a.Name
    if ($IsNew -and (Test-Path $dest)) { throw "An answer file named $($a.Name) already exists." }

    if (-not $a.JoinPasswordFile) { $a.JoinPasswordFile = "config\secrets\$($a.Name)-join.txt" }
    if (-not $a.AdminPasswordFile) { $a.AdminPasswordFile = "config\secrets\$($a.Name)-admin.txt" }
    foreach ($sh in $a.Shares) {
        if (-not $sh.PasswordFile -and $sh.Username) { $sh.PasswordFile = "config\secrets\$($a.Name)-share-$($sh.LocalName.TrimEnd(':').ToLowerInvariant()).txt" }
    }

    $problems = @(Test-AnswerFile $a)
    if ($problems) { throw "Can't save yet:`n - " + ($problems -join "`n - ") }

    if ($JoinPassword) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.JoinPasswordFile -Value $JoinPassword }
    if ($AdminPassword) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.AdminPasswordFile -Value $AdminPassword }
    foreach ($sh in $a.Shares) {
        $pw = $SharePasswords[$sh.LocalName]
        if ($pw) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $sh.PasswordFile -Value $pw }
    }
    Export-AnswerFile -Answer $a -Path $dest
    $dest
}

function Get-ApplicationList {
    # Applications\<name>\app.json folders, for the editor's application picker.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $root = Join-Path $ContentRoot 'Applications'
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $cmd = $null; $status = 'Ready'
        try { $cmd = (Get-AppDefinition -AppRoot $root -Name $_.Name).command } catch { $status = $_.Exception.Message }
        [pscustomobject]@{ Name = $_.Name; Command = $cmd; Status = $status }
    }
}

function New-Application {
    # Creates Applications\<name>: copies the installer (a file, or a folder's contents) and writes app.json.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Command,
        [int[]]$SuccessCodes = @(0, 3010)
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Application name '$Name' may only contain letters, digits, dot, dash and underscore." }
    if (-not (Test-Path $Source)) { throw "Installer not found: $Source" }
    $dest = Join-ContentPath $ContentRoot "Applications\$Name"
    if (Test-Path $dest) { throw "An application named $Name already exists." }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if (Test-Path $Source -PathType Container) { Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force }
    else { Copy-Item -Path $Source -Destination $dest }
    [pscustomobject]@{ command = $Command; successCodes = $SuccessCodes } | ConvertTo-Json | Set-Content (Join-Path $dest 'app.json') -Encoding utf8
    $dest
}

function Get-ImageUsage {
    # Image file name -> names of the answer files that deploy it, for the Images tab.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $usage = @{}
    foreach ($f in Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
        try { $a = Read-AnswerFile -Path $f.FullName -SkipValidation } catch { continue }
        $leaf = Split-Path ($a.ImageFile -replace '\\', '/') -Leaf
        if (-not $usage.ContainsKey($leaf)) { $usage[$leaf] = @() }
        $usage[$leaf] += $f.BaseName
    }
    $usage
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
    # Log names are <serial>_<yyyyMMdd-HHmm>_<OK|FAILED>.log (Deploy-Image.ps1) or CAPTURE-<name>_... (Capture-GoldenImage.ps1).
    param([Parameter(Mandatory)][string]$ContentRoot)
    Get-ChildItem -Path (Join-Path $ContentRoot 'Logs') -Filter *.log -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            # Split from the right: capture logs are CAPTURE-<image name>, and image names may contain underscores.
            $serial, $stamp, $status = $_.BaseName, '', ''
            if ($_.BaseName -match '^(.*)_(\d{8}-\d{4})_([A-Z]+)$') { $serial, $stamp, $status = $Matches[1], $Matches[2], $Matches[3] }
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
    Get-DeploySettings, Save-DeploySettings, Get-DeploymentLogs,
    Update-ContentTools, Test-ImageName, New-CaptureConfig, Get-CaptureReadiness, Get-ReferenceVMs,
    Get-AnswerFilePath, Get-AnswerFileIssues, Get-AnswerFileRows, New-AnswerFileFromSample, Import-SmartDeployAnswerFile, Get-ImageUsage,
    Get-NewAnswer, Test-SecretFile, Save-SecretFile, Save-AnswerFromEditor, Get-ApplicationList, New-Application
