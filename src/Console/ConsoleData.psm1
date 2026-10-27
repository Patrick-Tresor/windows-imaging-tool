# Data layer for the admin console: reads and writes the content root (Images, Drivers, config, Logs).
# No UI code here, so it can be tested without Windows.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AnswerFile.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ImageVersions.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AppPack.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NamingList.psm1') -Force

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
    foreach ($dir in 'Images', 'Drivers', 'config', 'config\secrets', 'Logs', 'Tools', 'Tools\BIOS\Dell', 'AnswerFiles', 'Applications', 'Updates', 'Computers', 'Reimage') {
        New-Item -ItemType Directory -Path (Join-ContentPath $Path $dir) -Force | Out-Null
    }
    foreach ($file in 'driver-catalog.json', 'deploy-settings.json', 'naming-list.csv') {
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
        $last = @(Get-ImageServicingHistory -ImagePath $f.FullName) | Select-Object -Last 1
        [pscustomobject]@{
            Name     = $f.Name
            SizeGB   = [Math]::Round((($parts | Measure-Object Length -Sum).Sum) / 1GB, 2)
            Parts    = $parts.Count
            Modified = $f.LastWriteTime
            Indexes  = $indexes
            Versions = @(Get-ImageVersions -ImagePath $f.FullName).Count
            Updated  = if ($last) { '{0} ({1})' -f $last.date, ((@($last.packages | Where-Object result -eq 'Installed').package | Select-Object -Unique | ForEach-Object { Get-UpdateKB $_ }) -join ', ') } else { '' }
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
        [switch]$Unattended,
        [switch]$NewVersion   # replace an existing image of this name; the old one is kept as a version
    )
    if (-not (Test-ImageName $Name)) { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $images = Join-Path $ContentRoot 'Images'
    if (-not $NewVersion -and ((Test-Path (Join-Path $images "$Name.wim")) -or (Test-Path (Join-Path $images "$Name.swm")))) {
        throw "An image named $Name already exists. Pick another name, or capture it as a new version."
    }
    $cfg = [ordered]@{
        name             = $Name
        description      = $Description
        compression      = $Compression
        splitSizeMB      = if ($SplitForFat32) { 3800 } else { 0 }
        noPrompt         = [bool]$Unattended
        shutdownWhenDone = [bool]$Unattended
        newVersion       = [bool]$NewVersion
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
    # Hyper-V VMs that can be captured. Capture media boots both generation 2 (UEFI) and generation 1 (BIOS).
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return @() }
    @(Get-VM | ForEach-Object {
        [pscustomobject]@{
            Name       = $_.Name
            State      = "$($_.State)"
            Generation = $_.Generation
            Usable     = $_.Generation -in 1, 2
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
    if ((& $local $a.ImageFile) -and $a.ImageVersion -and (Test-ImageVersionName $a.ImageVersion)) {
        try { Get-ImageVersionPath -ImagePath (Join-ContentPath $ContentRoot $a.ImageFile) -Version $a.ImageVersion | Out-Null }
        catch { "Version $($a.ImageVersion) of $($a.ImageFile) is no longer in Images\Previous." }
    }
    elseif ((& $local $a.ImageFile) -and -not (Test-Path (Join-ContentPath $ContentRoot $a.ImageFile))) { "Image $($a.ImageFile) is not in the content root." }
    if (& $local $a.AppLocation) {
        foreach ($app in $a.Applications) {
            $appRoot = Join-ContentPath $ContentRoot $a.AppLocation
            if (-not (Test-Path (Join-ContentPath $ContentRoot "$($a.AppLocation)\$app\app.json"))) { "Application $app has no $($a.AppLocation)\$app\app.json."; continue }
            try {
                $def = Read-AppPack -AppRoot $appRoot -Name $app
                foreach ($p in Test-AppPack -Definition $def -Folder (Join-Path $appRoot $app) | Where-Object { $_ -notlike 'Warning:*' }) { "Application ${app}: $p" }
            } catch { "Application ${app}: $($_.Exception.Message)" }
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
            $row.Image  = if ($a.ImageVersion) { "$($a.ImageFile) (version $($a.ImageVersion))" } else { $a.ImageFile }
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
    $a.BitLocker.PinFile = "config\secrets\$Name-bitlocker-pin.txt"
    $a.Bios.PasswordFile = $null
    $a.UserDataKeyFile = "config\secrets\$Name-usmt.txt"
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
        [string]$BiosPassword,
        [string]$BitLockerPin,
        [string]$UserDataKey,               # encryption key for a Share user data store
        [switch]$IsNew
    )
    $a = $Answer
    if ($a.Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Answer file name '$($a.Name)' may only contain letters, digits, dot, dash and underscore." }
    $dest = Get-AnswerFilePath -ContentRoot $ContentRoot -Name $a.Name
    if ($IsNew -and (Test-Path $dest)) { throw "An answer file named $($a.Name) already exists." }

    if (-not $a.JoinPasswordFile) { $a.JoinPasswordFile = "config\secrets\$($a.Name)-join.txt" }
    if (-not $a.AdminPasswordFile) { $a.AdminPasswordFile = "config\secrets\$($a.Name)-admin.txt" }
    if ($BiosPassword -and -not $a.Bios.PasswordFile) { $a.Bios.PasswordFile = "config\secrets\$($a.Name)-bios.txt" }
    if (-not $a.BitLocker.PinFile) { $a.BitLocker.PinFile = "config\secrets\$($a.Name)-bitlocker-pin.txt" }
    if ($BitLockerPin -and $BitLockerPin -notmatch '^\d{6,20}$') { throw 'The BitLocker startup PIN must be 6 to 20 digits.' }
    if (-not $a.UserDataKeyFile) { $a.UserDataKeyFile = "config\secrets\$($a.Name)-usmt.txt" }
    foreach ($sh in $a.Shares) {
        if (-not $sh.PasswordFile -and $sh.Username) { $sh.PasswordFile = "config\secrets\$($a.Name)-share-$($sh.LocalName.TrimEnd(':').ToLowerInvariant()).txt" }
    }

    $problems = @(Test-AnswerFile $a)
    if ($problems) { throw "Can't save yet:`n - " + ($problems -join "`n - ") }

    if ($JoinPassword) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.JoinPasswordFile -Value $JoinPassword }
    if ($AdminPassword) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.AdminPasswordFile -Value $AdminPassword }
    if ($BiosPassword) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.Bios.PasswordFile -Value $BiosPassword }
    if ($BitLockerPin) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.BitLocker.PinFile -Value $BitLockerPin }
    if ($UserDataKey) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $a.UserDataKeyFile -Value $UserDataKey }
    foreach ($sh in $a.Shares) {
        $pw = $SharePasswords[$sh.LocalName]
        if ($pw) { Save-SecretFile -ContentRoot $ContentRoot -RelativePath $sh.PasswordFile -Value $pw }
    }
    Export-AnswerFile -Answer $a -Path $dest
    $dest
}

function Get-ApplicationUsage {
    # Application name -> names of the answer files that install it.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $usage = @{}
    foreach ($f in Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
        try { $a = Read-AnswerFile -Path $f.FullName -SkipValidation } catch { continue }
        foreach ($n in $a.Applications) {
            if (-not $usage.ContainsKey($n)) { $usage[$n] = @() }
            $usage[$n] += $f.BaseName
        }
    }
    $usage
}

function Get-ApplicationList {
    # Applications\<name>\app.json folders, for the Applications tab and the answer file editor's picker.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $root = Join-Path $ContentRoot 'Applications'
    $usage = Get-ApplicationUsage -ContentRoot $ContentRoot
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ Name = $_.Name; DisplayName = ''; Version = ''; Type = ''; Command = $null; Detection = ''; For = 'All PCs'
                           UsedBy = if ($usage.ContainsKey($_.Name)) { $usage[$_.Name] -join ', ' } else { '' }
                           Status = 'Ready'; Issues = @(); Definition = $null; FullName = $_.FullName }
        try {
            $d = Read-AppPack -AppRoot $root -Name $_.Name
            $row.Definition = $d
            $row.DisplayName = $d.displayName; $row.Version = $d.version; $row.Type = $d.installerType; $row.Command = $d.command
            $row.Detection = if ($d.detection.rules) { (@($d.detection.rules | ForEach-Object { "$($_.type) $($_.target)" }) -join " $($d.detection.match) ") } else { 'none' }
            $for = @($d.requirements.makers) + @($d.requirements.models)
            if ($for) { $row.For = $for -join ', ' }
            $row.Issues = @(Test-AppPack -Definition $d -Folder $_.FullName)
            $errors = @($row.Issues | Where-Object { $_ -notlike 'Warning:*' })
            $row.Status = if ($errors) { "$($errors.Count) problem(s)" } elseif ($row.Issues) { 'Ready (no detection)' } else { 'Ready' }
        } catch { $row.Status = $_.Exception.Message; $row.Issues = @($_.Exception.Message) }
        [pscustomobject]$row
    }
}

function New-Application {
    # Creates Applications\<name>: copies the installer (a file, or a folder's contents) and writes app.json.
    # The simple form (-Command, -SuccessCodes) or a full -Definition from the application pack builder.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [string]$Command,
        [int[]]$SuccessCodes = @(0, 3010),
        $Definition
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Application name '$Name' may only contain letters, digits, dot, dash and underscore." }
    if (-not $Definition) {
        $leaf = if (Test-Path $Source -PathType Leaf) { Split-Path $Source -Leaf } else { '' }
        $Definition = ConvertTo-AppDefinition -Name $Name -Json ([pscustomobject]@{ command = $Command; successCodes = $SuccessCodes; installer = $leaf })
    }
    $Definition.name = $Name
    Save-AppPack -AppRoot (Join-Path $ContentRoot 'Applications') -Definition $Definition -Source $Source
}

function Save-Application {
    # Saves an edited definition over Applications\<name>; -Source adds or replaces installer files.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Definition, [string]$Source)
    Save-AppPack -AppRoot (Join-Path $ContentRoot 'Applications') -Definition $Definition -Source $Source -Overwrite
}

function Remove-Application {
    # Deletes Applications\<name>. Refuses while an answer file still installs it.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Name)
    $usage = Get-ApplicationUsage -ContentRoot $ContentRoot
    if ($usage.ContainsKey($Name)) { throw "$Name is still in these answer files: $($usage[$Name] -join ', '). Remove it from them first." }
    $dir = Join-Path (Join-Path $ContentRoot 'Applications') $Name
    if (-not (Test-Path (Join-Path $dir 'app.json'))) { throw "$Name is not an application folder." }
    Remove-Item $dir -Recurse -Force
}

function Get-ImageUsage {
    # Image file name -> names of the answer files that deploy it, for the Images tab.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $usage = @{}
    foreach ($f in Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
        try { $a = Read-AnswerFile -Path $f.FullName -SkipValidation } catch { continue }
        $leaf = Split-Path ($a.ImageFile -replace '\\', '/') -Leaf
        if (-not $usage.ContainsKey($leaf)) { $usage[$leaf] = @() }
        $usage[$leaf] += if ($a.ImageVersion) { "$($f.BaseName) (version $($a.ImageVersion))" } else { $f.BaseName }
    }
    $usage
}

#endregion

#region Image versions

function Get-ImageVersionRows {
    # The current image and its archived versions, for the console's Versions dialog and the answer file editor.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImageName)
    $path = Join-ContentPath $ContentRoot "Images\$ImageName"
    $usage = Get-ImageVersionUsage -ContentRoot $ContentRoot -ImageName $ImageName
    $pinnedBy = { param($v) if ($usage.ContainsKey($v)) { $usage[$v] -join ', ' } else { '' } }
    $parts = @(Get-ImagePartFiles -ImagePath $path)
    if ($parts) {
        [pscustomobject]@{
            Version   = ''
            Label     = 'Current'
            Date      = $parts[0].LastWriteTime
            Reason    = 'In use by answer files without a version'
            Note      = ''
            SizeGB    = [Math]::Round((($parts | Measure-Object Length -Sum).Sum) / 1GB, 2)
            UsedBy    = & $pinnedBy ''
            ImagePath = $path
        }
    }
    foreach ($v in Get-ImageVersions -ImagePath $path) {
        [pscustomobject]@{
            Version   = $v.Version
            Label     = $v.Version
            Date      = $v.Archived
            Reason    = $v.Reason
            Note      = $v.Note
            SizeGB    = $v.SizeGB
            UsedBy    = & $pinnedBy $v.Version
            ImagePath = $v.ImagePath
        }
    }
}

function Remove-ImageVersions {
    # Deletes archived versions, refusing any that an answer file is pinned to.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$ImageName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Version
    )
    $usage = Get-ImageVersionUsage -ContentRoot $ContentRoot -ImageName $ImageName
    $pinned = @($Version | Where-Object { $_ -and $usage.ContainsKey($_) })
    if ($pinned) {
        throw ("Answer files still use {0}: {1}. Change them first." -f ($pinned -join ', '), (($pinned | ForEach-Object { $usage[$_] }) -join ', '))
    }
    $path = Join-ContentPath $ContentRoot "Images\$ImageName"
    foreach ($v in $Version | Where-Object { $_ }) { Remove-ImageVersion -ImagePath $path -Version $v }
}

function Get-ImageVersionsToDelete {
    # Versions older than the newest -Keep that no answer file uses, for "Delete older versions".
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImageName, [Parameter(Mandatory)][int]$Keep)
    $usage = Get-ImageVersionUsage -ContentRoot $ContentRoot -ImageName $ImageName
    Get-ImageVersionsToPrune -ImagePath (Join-ContentPath $ContentRoot "Images\$ImageName") -Keep $Keep -Pinned @($usage.Keys)
}

function Get-ImageEditions {
    # "index: name" for each edition in an image file, e.g. for the editor's list when a version is pinned.
    param([Parameter(Mandatory)][string]$ImagePath)
    @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop | ForEach-Object { "$($_.ImageIndex): $($_.ImageName)" })
}

function Get-ImageVersionArguments {
    # Command line for Invoke-ImageVersion.ps1 (keep a copy, or roll back), run by the console in its own window
    # because copying an image can take minutes.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$ImageName,
        [Parameter(Mandatory)][ValidateSet('Keep', 'Rollback')][string]$Action,
        [string]$Version,
        [string]$Note
    )
    if ($Action -eq 'Rollback' -and -not (Test-ImageVersionName $Version)) { throw 'Select an earlier version to roll back to.' }
    $q = { param($v) '"' + ($v -replace '"', "'") + '"' }
    $cmd = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (& $q $ScriptPath),
        '-ImagePath', (& $q (Join-ContentPath $ContentRoot "Images\$ImageName")), '-Action', $Action, '-NoPrompt')
    if ($Version) { $cmd += @('-Version', $Version) }
    if ($Note) { $cmd += @('-Note', (& $q $Note)) }
    $cmd
}

#endregion

#region Image updates

function Get-UpdateKB {
    # KB number from a Microsoft Update Catalog file name, e.g. windows11.0-kb5044284-x64_<hash>.msu -> KB5044284.
    param([string]$FileName)
    if ($FileName -match '(?i)kb(\d{6,8})') { "KB$($Matches[1])" } else { '' }
}

function Get-UpdatePackageRows {
    # .msu and .cab files from the given files and folders, in a sensible default order:
    # Windows updates (SSU, cumulative), then .NET (catalog names contain "ndp"), then anything else; oldest KB first in each.
    # Standalone SSUs can carry a higher KB than the cumulative update they go with, so the console lets the order be changed.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path)
    $files = foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) { Get-ChildItem -LiteralPath $p -File | Where-Object Extension -in '.msu', '.cab' }
        elseif (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p }
    }
    $files | Sort-Object FullName -Unique | ForEach-Object {
        $kb = Get-UpdateKB $_.Name
        $kind = if ($_.Name -match '(?i)ndp\d|dotnet|\.net') { '.NET' } elseif ($_.Name -match '(?i)^windows\d') { 'Windows' } else { 'Other' }
        [pscustomobject]@{
            Name     = $_.Name
            KB       = $kb
            Kind     = $kind
            SizeMB   = [Math]::Round($_.Length / 1MB)
            FullName = $_.FullName
            Order    = @{ 'Windows' = 0; '.NET' = 1; 'Other' = 2 }[$kind]
            KBNumber = if ($kb) { [int]$kb.Substring(2) } else { [int]::MaxValue }
        }
    } | Sort-Object Order, KBNumber, Name | Select-Object Name, KB, Kind, SizeMB, FullName
}

function Get-ImageServicingHistoryPath {
    # Images\<name>.updates.json, next to the image (split images use the first part's name).
    param([Parameter(Mandatory)][string]$ImagePath)
    Join-Path (Split-Path $ImagePath -Parent) ([IO.Path]::GetFileNameWithoutExtension($ImagePath) + '.updates.json')
}

function Get-ImageServicingHistory {
    param([Parameter(Mandatory)][string]$ImagePath)
    $path = Get-ImageServicingHistoryPath -ImagePath $ImagePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    @((Get-Content -Raw -LiteralPath $path | ConvertFrom-Json).history)
}

function Add-ImageServicingRecord {
    # Called by Update-OfflineImage.ps1 after a successful update, so the Images tab shows what each image contains.
    param(
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [string[]]$Builds = @(),
        [switch]$Cleanup,
        [switch]$ResetBase,
        [datetime]$Date = (Get-Date)
    )
    $history = @(Get-ImageServicingHistory -ImagePath $ImagePath)
    $history += [pscustomobject]@{
        date      = $Date.ToString('yyyy-MM-dd HH:mm')
        builds    = @($Builds)
        cleanup   = [bool]$Cleanup
        resetBase = [bool]$ResetBase
        packages  = @($Results | ForEach-Object { [pscustomobject]@{ index = $_.index; package = $_.package; result = $_.result } })
    }
    [pscustomobject]@{ history = $history } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Get-ImageServicingHistoryPath -ImagePath $ImagePath) -Encoding utf8
}

function Get-ImageUpdateArguments {
    # Command line for Update-OfflineImage.ps1, run by the console in its own window.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ImagePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Packages,
        [int[]]$Index,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [switch]$NoBackup
    )
    if (-not $Packages) { throw 'Add at least one update package (.msu or .cab).' }
    if ($ResetBase -and -not $Cleanup) { throw 'Reset base needs component cleanup turned on.' }
    $quote = { param($v) "'" + ($v -replace "'", "''") + "'" }
    $cmd = "& $(& $quote $ScriptPath) -ImagePath $(& $quote $ImagePath) -PackagePath " + (($Packages | ForEach-Object { & $quote $_ }) -join ',')
    if ($Index) { $cmd += " -Index $($Index -join ',')" }
    if ($Cleanup) { $cmd += ' -Cleanup' }
    if ($ResetBase) { $cmd += ' -ResetBase' }
    if ($NoBackup) { $cmd += ' -NoBackup' }
    $cmd += ' -NoPrompt'   # the console already asked
    # -File cannot pass an array to a [string[]] parameter, and command-line quoting strips the quotes in -Command,
    # so the command goes in encoded.
    @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
}

function Get-VMCaptureArguments {
    # Command line for Capture-VMImage.ps1, run by the console in its own window.
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [ValidateSet('fast', 'max')][string]$Compression = 'max',
        [switch]$Split,
        [switch]$NewVersion
    )
    if (-not (Test-ImageName $Name)) { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $quote = { param($v) "'" + ($v -replace "'", "''") + "'" }
    $cmd = "& $(& $quote $ScriptPath) -VMName $(& $quote $VMName) -Name $(& $quote $Name) -ContentRoot $(& $quote $ContentRoot) -Compression $Compression"
    if ($Description) { $cmd += " -Description $(& $quote $Description)" }
    if ($Split) { $cmd += ' -SplitSizeMB 3800' }
    if ($NewVersion) { $cmd += ' -NewVersion' }
    $cmd += ' -NoPrompt'   # the console already asked
    @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd)))
}

#endregion

#region Naming list

function Get-NamingListPath {
    param([Parameter(Mandatory)][string]$ContentRoot)
    Join-ContentPath $ContentRoot 'config\naming-list.csv'
}

function Get-AnswerFileNames {
    param([Parameter(Mandatory)][string]$ContentRoot)
    @(Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue | ForEach-Object BaseName)
}

function Get-NamingListRows {
    # Naming list rows for the grid, with each row's problems and the result of the last deploy of that serial.
    param([Parameter(Mandatory)][string]$ContentRoot, [object[]]$Entries)
    if (-not $PSBoundParameters.ContainsKey('Entries')) { $Entries = @(Read-NamingList -Path (Get-NamingListPath -ContentRoot $ContentRoot)) }
    $answers = Get-AnswerFileNames -ContentRoot $ContentRoot
    $last = @{}
    foreach ($log in Get-DeploymentLogs -ContentRoot $ContentRoot) {
        # Logs come newest first; keep the first per serial.
        $key = "$($log.Serial)".ToUpperInvariant()
        if ($key -and -not $log.Serial.StartsWith('CAPTURE-') -and -not $last.ContainsKey($key)) { $last[$key] = '{0:yyyy-MM-dd HH:mm} {1}' -f $log.When, $log.Status }
    }
    $problems = @(Test-NamingList -Entries @($Entries) -AnswerFileNames $answers)
    for ($i = 0; $i -lt @($Entries).Count; $i++) {
        $e = @($Entries)[$i]
        $mine = @($problems | Where-Object { $_ -like "Row $($i + 1)[ :]*" } | ForEach-Object { $_ -replace '^Row \d+( \([^)]*\))?: ', '' })
        [pscustomobject]@{
            Serial       = $e.Serial
            ComputerName = $e.ComputerName
            OU           = $e.OU
            AnswerFile   = $e.AnswerFile
            Notes        = $e.Notes
            Status       = if ($mine) { $mine -join ' ' } else { 'OK' }
            LastDeploy   = if ($e.Serial -and $last.ContainsKey($e.Serial.ToUpperInvariant())) { $last[$e.Serial.ToUpperInvariant()] } else { '' }
        }
    }
}

function Save-NamingListFromConsole {
    # Validates every row against the content root's answer files, then writes the CSV. Throws listing every problem.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows)
    $entries = @($Rows | Where-Object { "$($_.Serial)$($_.ComputerName)$($_.OU)$($_.AnswerFile)$($_.Notes)".Trim() } | ForEach-Object {
        [pscustomobject]@{
            Serial       = "$($_.Serial)".Trim()
            ComputerName = "$($_.ComputerName)".Trim().ToUpperInvariant()
            OU           = "$($_.OU)".Trim()
            AnswerFile   = "$($_.AnswerFile)".Trim()
            Notes        = "$($_.Notes)".Trim()
        }
    })
    $problems = @(Test-NamingList -Entries $entries -AnswerFileNames (Get-AnswerFileNames -ContentRoot $ContentRoot))
    if ($problems) { throw "The naming list was not saved:`n - " + ($problems -join "`n - ") }
    Save-NamingList -Path (Get-NamingListPath -ContentRoot $ContentRoot) -Entries $entries
    $entries.Count
}

function Merge-NamingList {
    # Adds rows from an imported CSV: a serial already listed is updated with the imported row's non-empty columns.
    param([AllowEmptyCollection()][object[]]$Existing = @(), [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Incoming)
    $rows = [Collections.Generic.List[object]]::new()
    $bySerial = @{}
    foreach ($e in $Existing) {
        $copy = [pscustomobject]@{ Serial = $e.Serial; ComputerName = $e.ComputerName; OU = $e.OU; AnswerFile = $e.AnswerFile; Notes = $e.Notes }
        $rows.Add($copy)
        if ($e.Serial) { $bySerial["$($e.Serial)".Trim().ToUpperInvariant()] = $copy }
    }
    $added = 0; $updated = 0
    foreach ($n in $Incoming) {
        $key = "$($n.Serial)".Trim().ToUpperInvariant()
        if (-not $key) { continue }
        if ($bySerial.ContainsKey($key)) {
            $target = $bySerial[$key]
            foreach ($c in 'ComputerName', 'OU', 'AnswerFile', 'Notes') { if ($n.$c) { $target.$c = $n.$c } }
            $updated++
        } else {
            $copy = [pscustomobject]@{ Serial = $n.Serial; ComputerName = $n.ComputerName; OU = $n.OU; AnswerFile = $n.AnswerFile; Notes = $n.Notes }
            $rows.Add($copy); $bySerial[$key] = $copy; $added++
        }
    }
    [pscustomobject]@{ Rows = $rows.ToArray(); Added = $added; Updated = $updated }
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

function Get-WdsSettings {
    # The "wds" section of deploy-settings.json, with defaults for content roots made before it existed.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $wds = [ordered]@{ server = ''; imageName = 'Imaging Tool (x64)'; setup = $false; remoteInstallPath = 'D:\RemoteInstall'; dhcpOnServer = $false; noPrompt = $false }
    $saved = (Get-DeploySettings -ContentRoot $ContentRoot).wds
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { if ($wds.Contains($p.Name)) { $wds[$p.Name] = $p.Value } } }
    [pscustomobject]$wds
}

function Save-WdsSettings {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Wds)
    $s = Get-DeploySettings -ContentRoot $ContentRoot
    $s | Add-Member -NotePropertyName wds -NotePropertyValue ([pscustomobject]@{
        server            = "$($Wds.server)".Trim()
        imageName         = $(if ("$($Wds.imageName)".Trim()) { "$($Wds.imageName)".Trim() } else { 'Imaging Tool (x64)' })
        setup             = [bool]$Wds.setup
        remoteInstallPath = "$($Wds.remoteInstallPath)".Trim()
        dhcpOnServer      = [bool]$Wds.dhcpOnServer
        noPrompt          = [bool]$Wds.noPrompt
    }) -Force
    Save-DeploySettings -ContentRoot $ContentRoot -Settings $s
}

function Get-MulticastSettings {
    # The "multicast" section of deploy-settings.json, with defaults. WinPE reads it from the content root,
    # so turning multicast on or off needs no media rebuild.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $mc = [ordered]@{ enabled = $false; server = ''; namespace = 'ImagingTool'; contentPath = ''; type = 'AutoCast'
        clients = 0; startTime = ''; speedPolicy = 'None'; thresholdKbps = 1024; fallback = $true }
    $saved = (Get-DeploySettings -ContentRoot $ContentRoot).multicast
    if ($saved) { foreach ($p in $saved.PSObject.Properties) { if ($mc.Contains($p.Name)) { $mc[$p.Name] = $p.Value } } }
    [pscustomobject]$mc
}

function Get-MulticastIssues {
    # What is wrong with multicast settings before they are saved or sent to the server; empty when fine.
    param([Parameter(Mandatory)]$Multicast)
    $issues = @()
    if ("$($Multicast.namespace)".Trim() -notmatch '^[A-Za-z0-9][A-Za-z0-9 _.-]*$') { $issues += 'Session name: letters, digits, spaces, dots, dashes and underscores only.' }
    if ($Multicast.type -notin 'AutoCast', 'ScheduledCast') { $issues += "Session type must be AutoCast or ScheduledCast, not '$($Multicast.type)'." }
    if ($Multicast.speedPolicy -notin 'None', 'AutoDisconnect', 'Multistream') { $issues += "Slow PC policy must be None, AutoDisconnect or Multistream, not '$($Multicast.speedPolicy)'." }
    $clients = 0
    $clientText = "$($Multicast.clients)".Trim()   # empty means 0
    if ($clientText -and (-not [int]::TryParse($clientText, [ref]$clients) -or $clients -lt 0)) { $issues += 'Number of PCs must be a whole number, 0 or more.' }
    $start = "$($Multicast.startTime)".Trim()
    $t = [datetime]::MinValue
    if ($start -and -not [datetime]::TryParseExact($start, 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture, 'None', [ref]$t)) {
        $issues += "Start time must look like 2026-11-03 08:30, not '$start'."
    }
    if ($Multicast.type -eq 'ScheduledCast' -and $clients -le 0 -and -not $start) {
        $issues += 'A scheduled session needs a number of PCs, a start time, or both.'
    }
    $kbps = 0
    if ($Multicast.speedPolicy -eq 'AutoDisconnect' -and (-not [int]::TryParse("$($Multicast.thresholdKbps)", [ref]$kbps) -or $kbps -le 0)) {
        $issues += 'Disconnect threshold must be a number of KB/s above 0.'
    }
    $issues
}

function Save-MulticastSettings {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Multicast)
    $issues = @(Get-MulticastIssues -Multicast $Multicast)
    if ($issues) { throw ($issues -join "`n") }
    $s = Get-DeploySettings -ContentRoot $ContentRoot
    $s | Add-Member -NotePropertyName multicast -NotePropertyValue ([pscustomobject]@{
        enabled       = [bool]$Multicast.enabled
        server        = "$($Multicast.server)".Trim()
        namespace     = "$($Multicast.namespace)".Trim()
        contentPath   = "$($Multicast.contentPath)".Trim()
        type          = $Multicast.type
        clients       = [int]"$($Multicast.clients)".Trim()
        startTime     = "$($Multicast.startTime)".Trim()
        speedPolicy   = $Multicast.speedPolicy
        thresholdKbps = $(if ("$($Multicast.thresholdKbps)".Trim()) { [int]"$($Multicast.thresholdKbps)" } else { 1024 })
        fallback      = [bool]$Multicast.fallback
    }) -Force
    Save-DeploySettings -ContentRoot $ContentRoot -Settings $s
}

function Format-ByteRate([long]$BytesPerSecond) {
    if ($BytesPerSecond -ge 1MB) { '{0:N1} MB/s' -f ($BytesPerSecond / 1MB) } else { '{0:N0} KB/s' -f ($BytesPerSecond / 1KB) }
}

function ConvertTo-MulticastView {
    # Turns Set-WdsMulticast.ps1 -Action Monitor output into the Multicast tab's summary line and grid rows.
    param([Parameter(Mandatory)]$Monitor)
    $clients = @($Monitor.Clients | Where-Object { $_ })
    $rows = foreach ($c in $clients | Sort-Object Percent, Name) {
        $joined = [timespan]::FromSeconds([long]$c.JoinedSeconds)
        [pscustomobject]@{
            Id       = [long]$c.Id
            Name     = $c.Name
            Address  = (@($c.IpAddress, $c.MacAddress) | Where-Object { $_ }) -join '  '
            File     = Split-Path "$($c.File)" -Leaf
            Percent  = [int]$c.Percent
            Progress = "$([int]$c.Percent) %"
            Joined   = $(if ($joined.TotalHours -ge 1) { '{0} h {1:00} min' -f [int][math]::Floor($joined.TotalHours), $joined.Minutes } else { '{0} min' -f [int][math]::Floor($joined.TotalMinutes) })
            Speed    = Format-ByteRate $c.RateBytes
        }
    }
    $rows = @($rows)
    $summary = if (-not $Monitor.Exists) {
        "No multicast session named '$($Monitor.Namespace)' on $($Monitor.Server). Click Save and set up session."
    } elseif ($Monitor.Sessions -eq 0) {
        "Session '$($Monitor.Namespace)' on $($Monitor.Server) has not started sending yet. PCs waiting for a scheduled start show up once it starts."
    } elseif (-not $rows) {
        "Session '$($Monitor.Namespace)' on $($Monitor.Server): no PCs connected."
    } else {
        $avg = [int][math]::Round(($rows | Measure-Object Percent -Average).Average)
        $slow = $rows[0]
        $done = @($rows | Where-Object Percent -ge 100).Count
        "$($rows.Count) PC$(if ($rows.Count -ne 1) { 's' }) receiving, average $avg %, $done done. Slowest: $($slow.Name) at $($slow.Percent) %."
    }
    [pscustomobject]@{ Summary = $summary; Rows = $rows }
}

function Get-DeploymentLogs {
    # Log names are <serial>_<yyyyMMdd-HHmm>_<OK|FAILED>.log (Deploy-Image.ps1), CAPTURE-<name>_... (Capture-GoldenImage.ps1)
    # or SERVICE-<name>_... (Update-OfflineImage.ps1).
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
    Get-DeploySettings, Save-DeploySettings, Get-WdsSettings, Save-WdsSettings,
    Get-MulticastSettings, Get-MulticastIssues, Save-MulticastSettings, ConvertTo-MulticastView, Get-DeploymentLogs,
    Update-ContentTools, Test-ImageName, New-CaptureConfig, Get-CaptureReadiness, Get-ReferenceVMs,
    Get-AnswerFilePath, Get-AnswerFileIssues, Get-AnswerFileRows, New-AnswerFileFromSample, Import-SmartDeployAnswerFile, Get-ImageUsage,
    Get-NewAnswer, Test-SecretFile, Save-SecretFile, Save-AnswerFromEditor, Get-ApplicationList, New-Application,
    Get-ImageVersionRows, Remove-ImageVersions, Get-ImageVersionsToDelete, Get-ImageVersionArguments,
    Get-ImageEditions,
    Get-UpdateKB, Get-UpdatePackageRows, Get-ImageServicingHistory, Add-ImageServicingRecord, Get-ImageUpdateArguments,
    Get-ApplicationUsage, Save-Application, Remove-Application,
    Get-NamingListPath, Get-AnswerFileNames, Get-NamingListRows, Save-NamingListFromConsole, Merge-NamingList,
    Get-VMCaptureArguments
