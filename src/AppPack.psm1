# Application packs: Applications\<name>\ holds an installer and an app.json that says how to install it
# silently, which PCs it is for, and how to tell that it is installed (detection rules).
# Used by the console (build, inspect, export/import), Deploy-Image.ps1 in WinPE (requirements) and
# FirstBoot.ps1 on the deployed PC (detection). PowerShell 5.1 compatible; nothing Windows-only runs at import.

$script:InstallerTypes = 'msi', 'msix', 'nsis', 'inno', 'installshield', 'burn', 'advancedinstaller', 'squirrel', 'exe', 'script'
$script:RuleTypes = 'msi', 'uninstall', 'file', 'registry', 'appx', 'script'
$script:UninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

#region Definition

function ConvertTo-AppDefinition {
    <#
    .SYNOPSIS
        Normalizes an app.json object (old { command, successCodes } files included) into a full definition.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Json)
    # A JSON round trip turns hashtables (from scripts and tests) into the same objects app.json gives.
    $Json = $Json | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $get = { param($p, $default) if ($Json.PSObject.Properties[$p] -and $null -ne $Json.$p -and "$($Json.$p)" -ne '') { $Json.$p } else { $default } }
    $ints = { param($v) @($v | Where-Object { "$_" -ne '' } | ForEach-Object { [int]$_ }) }

    $req = & $get 'requirements' $null
    $det = & $get 'detection' $null
    $rules = @()
    if ($det) {
        # "detection" is either { match, rules } or, for short files, the rules array itself.
        $list = if ($det -is [array]) { $det } elseif ($det.PSObject.Properties['rules']) { $det.rules } else { @($det) }
        $rules = @($list | Where-Object { $_ } | ForEach-Object { ConvertTo-DetectionRule $_ })
    }
    [pscustomobject][ordered]@{
        name             = $Name
        displayName      = & $get 'displayName' $Name
        version          = & $get 'version' ''
        publisher        = & $get 'publisher' ''
        installer        = & $get 'installer' ''
        # When set, the PC downloads the installer from here at first boot (saved as installer) if it is not in the folder.
        downloadUrl      = & $get 'downloadUrl' ''
        # SHA256 of the download (from the winget catalog); a different file is refused.
        downloadSha256   = & $get 'downloadSha256' ''
        installerType    = & $get 'installerType' ''
        command          = & $get 'command' ''
        # Lists are wrapped in @() so an empty one stays []: Windows PowerShell 5.1 writes an if statement's
        # empty output as {} in JSON, and {} reads back as one blank maker or model.
        successCodes     = @(if ($Json.PSObject.Properties['successCodes'] -and @($Json.successCodes).Count) { & $ints $Json.successCodes } else { 0, 3010, 1641 })
        rebootCodes      = @(if ($Json.PSObject.Properties['rebootCodes'] -and $null -ne $Json.rebootCodes) { & $ints $Json.rebootCodes } else { 3010, 1641 })
        timeoutMinutes   = [int](& $get 'timeoutMinutes' 60)
        uninstallCommand = & $get 'uninstallCommand' ''
        requirements     = [pscustomobject][ordered]@{
            makers = @(if ($req -and $req.PSObject.Properties['makers']) { $req.makers | ForEach-Object { "$_" } | Where-Object { $_ } })
            models = @(if ($req -and $req.PSObject.Properties['models']) { $req.models | ForEach-Object { "$_" } | Where-Object { $_ } })
        }
        detection        = [pscustomobject][ordered]@{
            match = if ($det -and $det -isnot [array] -and $det.PSObject.Properties['match'] -and $det.match -eq 'any') { 'any' } else { 'all' }
            rules = $rules
        }
        skipIfDetected   = [bool](& $get 'skipIfDetected' $true)
        notes            = & $get 'notes' ''
    }
}

function ConvertTo-DetectionRule {
    # One rule, with every field present so the console grid and FirstBoot.ps1 can read it the same way.
    param([Parameter(Mandatory)]$Rule)
    if ($Rule -is [Collections.IDictionary]) { $Rule = [pscustomobject]$Rule }
    $f = { param($p) if ($Rule.PSObject.Properties[$p] -and $null -ne $Rule.$p) { "$($Rule.$p)" } else { '' } }
    $type = (& $f 'type').ToLowerInvariant()
    if ($type -notin $script:RuleTypes) { throw "Unknown detection rule type '$type'. Use one of: $($script:RuleTypes -join ', ')." }
    $op = & $f 'operator'
    [pscustomobject][ordered]@{
        type     = $type
        # msi: product code; uninstall: display name (wildcards); file: path; registry: key; appx: package name; script: file.
        target   = (& $f 'target'), (& $f 'productCode'), (& $f 'displayName'), (& $f 'path'), (& $f 'key'), (& $f 'name'), (& $f 'script') |
                   Where-Object { $_ } | Select-Object -First 1
        value    = & $f 'value'     # registry value name
        version  = & $f 'version'   # version or data to compare with
        operator = if ($op) { $op } elseif (& $f 'version') { '>=' } else { 'exists' }
    }
}

function Read-AppPack {
    # Reads Applications\<name>\app.json into a full definition. Throws when it is missing or has no command.
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Name)
    $json = Join-Path (Join-Path $AppRoot $Name) 'app.json'
    if (-not (Test-Path $json)) { throw "Application '$Name' has no app.json in $AppRoot\$Name." }
    $def = ConvertTo-AppDefinition -Name $Name -Json (Get-Content -Raw $json | ConvertFrom-Json)
    if (-not $def.command) { throw "Application '$Name': app.json has no command." }
    $def
}

function ConvertTo-AppJson {
    # What goes in app.json: the definition without its name (the folder is the name).
    param([Parameter(Mandatory)]$Definition)
    $o = [ordered]@{}
    foreach ($p in $Definition.PSObject.Properties) { if ($p.Name -ne 'name') { $o[$p.Name] = $p.Value } }
    $o.detection = [ordered]@{ match = $Definition.detection.match; rules = @($Definition.detection.rules) }
    [pscustomobject]$o | ConvertTo-Json -Depth 6
}

function Test-AppPack {
    <#
    .SYNOPSIS
        Problems with an application pack, as sentences. Errors stop a deployment; warnings start with "Warning:".
    #>
    param([Parameter(Mandatory)]$Definition, [string]$Folder)
    $d = $Definition
    if ($d.name -notmatch '^[A-Za-z0-9._-]+$') { "Name '$($d.name)' may only contain letters, digits, dot, dash and underscore." }
    if (-not $d.command) { 'There is no install command.' }
    if ($d.command -match 'REPLACE_[A-Z_]+') { "The install command still has the placeholder $($Matches[0]): put the real value in." }
    if ($d.installerType -and $d.installerType -notin $script:InstallerTypes) { "Unknown installer type '$($d.installerType)'." }
    if ($d.timeoutMinutes -lt 1 -or $d.timeoutMinutes -gt 600) { 'The timeout must be between 1 and 600 minutes.' }
    if (-not @($d.successCodes).Count) { 'There must be at least one success code (usually 0).' }
    if ($Folder -and $d.installer -and -not $d.downloadUrl -and -not (Test-Path (Join-Path $Folder $d.installer))) { "The installer $($d.installer) is not in the application folder." }
    if ($d.downloadUrl -and $d.downloadUrl -notmatch '^https?://\S+$') { "The download address '$($d.downloadUrl)' must start with https://." }
    if ($d.downloadSha256 -and $d.downloadSha256 -notmatch '^[0-9A-Fa-f]{64}$') { "The download's SHA256 '$($d.downloadSha256)' must be 64 hexadecimal characters." }
    if ($d.downloadUrl -and -not $d.installer) { 'An application downloaded at first boot needs the installer file name to save it as (Installer to run).' }
    foreach ($r in $d.detection.rules) {
        if (-not $r.target) { "A $($r.type) detection rule has nothing to look for." }
        if ($r.operator -notin 'exists', '=', '>=') { "Detection operator '$($r.operator)' must be exists, = or >=." }
        if ($r.type -eq 'msi' -and $r.target -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { "MSI product code '$($r.target)' should look like {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}." }
        if ($r.type -eq 'script' -and $Folder -and -not (Test-Path (Join-Path $Folder $r.target))) { "The detection script $($r.target) is not in the application folder." }
    }
    if (-not @($d.detection.rules).Count) { 'Warning: no detection rule, so the result cannot be checked and the app is reinstalled on every run.' }
}

#endregion

#region Installer inspection

function Find-InstallerFramework {
    # Looks for the markers each installer framework leaves in its .exe (ASCII or UTF-16), in the first 4 MB and last 1 MB.
    param([Parameter(Mandatory)][string]$Path)
    $markers = [ordered]@{
        burn              = '.wixburn', 'WixBundle'
        inno              = 'Inno Setup'
        nsis              = 'Nullsoft', 'NSIS Error'
        installshield     = 'InstallShield'
        advancedinstaller = 'Advanced Installer'
        squirrel          = 'SquirrelSetup', 'Squirrel.Windows'
    }
    $fs = [IO.File]::OpenRead($Path)
    try {
        $chunks = @()
        $head = [byte[]]::new([Math]::Min($fs.Length, 4MB)); [void]$fs.Read($head, 0, $head.Length); $chunks += , $head
        if ($fs.Length -gt 5MB) {
            $tail = [byte[]]::new(1MB); [void]$fs.Seek(-1MB, 'End'); [void]$fs.Read($tail, 0, $tail.Length); $chunks += , $tail
        }
    } finally { $fs.Dispose() }
    $text = foreach ($c in $chunks) { [Text.Encoding]::ASCII.GetString($c); [Text.Encoding]::Unicode.GetString($c) }
    $text = $text -join "`n"
    foreach ($k in $markers.Keys) {
        foreach ($m in $markers[$k]) { if ($text.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $k } }
    }
    'exe'
}

function Get-SilentInstallCommand {
    # The usual silent command line for an installer type. $Installer is the file name in the application folder.
    param([Parameter(Mandatory)][string]$Installer, [Parameter(Mandatory)][string]$Type)
    $q = "`"$Installer`""
    switch ($Type) {
        'msi'               { "msiexec /i $q /qn /norestart /l*v `"%WINDIR%\Temp\$([IO.Path]::GetFileNameWithoutExtension($Installer))-install.log`"" }
        'msix'              { "powershell -NoProfile -Command Add-AppxProvisionedPackage -Online -PackagePath '$Installer' -SkipLicense" }
        'nsis'              { "$q /S" }
        'inno'              { "$q /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" }
        'installshield'     { "$q /s /v`"/qn /norestart`"" }
        'burn'              { "$q /quiet /norestart" }
        'advancedinstaller' { "$q /exenoui /qn /norestart" }
        'squirrel'          { "$q --silent" }
        'script'            { if ($Installer -like '*.ps1') { "powershell -NoProfile -ExecutionPolicy Bypass -File $q" } else { "cmd /c $q" } }
        default             { "$q /S" }
    }
}

function Get-InstallerTypeNote([string]$Type) {
    switch ($Type) {
        'installshield' { 'InstallShield: /s /v"/qn" fits MSI-based setups. A pure InstallScript setup needs a recorded setup.iss (run setup.exe /r on a test PC, then use /s /f1"setup.iss").' }
        'squirrel'      { 'Squirrel installers install per user, not for the whole PC. Prefer the vendor''s MSI or machine-wide installer.' }
        'exe'           { 'Unknown installer type. /S is a guess: check the vendor''s silent install documentation, or run the installer with /? on a test PC.' }
        default         { '' }
    }
}

function Get-InstallerInfo {
    <#
    .SYNOPSIS
        Reads what can be learned from an installer file: type, name, version, publisher, MSI product code or
        MSIX package name, and a suggested silent command, uninstall command and detection rule.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Installer not found: $Path" }
    $leaf = Split-Path $Path -Leaf
    $info = [ordered]@{
        Installer = $leaf; Type = 'exe'; DisplayName = [IO.Path]::GetFileNameWithoutExtension($leaf); Version = ''; Publisher = ''
        ProductCode = ''; PackageName = ''; Command = ''; UninstallCommand = ''; Detection = $null; Note = ''
    }
    switch -Wildcard ($leaf.ToLowerInvariant()) {
        '*.msi' {
            $info.Type = 'msi'
            $props = Get-MsiProperties -Path $Path
            if ($props) {
                if ($props.ProductName) { $info.DisplayName = $props.ProductName }
                $info.Version = "$($props.ProductVersion)"; $info.Publisher = "$($props.Manufacturer)"; $info.ProductCode = "$($props.ProductCode)"
            }
        }
        { $_ -like '*.msix' -or $_ -like '*.appx' -or $_ -like '*.msixbundle' -or $_ -like '*.appxbundle' } {
            $info.Type = 'msix'
            $id = Get-MsixIdentity -Path $Path
            if ($id) { $info.PackageName = $id.Name; $info.Version = $id.Version; $info.Publisher = $id.Publisher; $info.DisplayName = $id.Name }
        }
        { $_ -like '*.ps1' -or $_ -like '*.cmd' -or $_ -like '*.bat' } { $info.Type = 'script' }
        '*.exe' {
            $info.Type = Find-InstallerFramework -Path $Path
            try {
                $v = [Diagnostics.FileVersionInfo]::GetVersionInfo((Resolve-Path $Path).ProviderPath)
                if ($v.ProductName) { $info.DisplayName = $v.ProductName.Trim() }
                if ($v.ProductVersion) { $info.Version = ($v.ProductVersion -split '[ ,]')[0].Trim() }
                if ($v.CompanyName) { $info.Publisher = $v.CompanyName.Trim() }
            } catch { }
        }
    }
    $info.Command = Get-SilentInstallCommand -Installer $leaf -Type $info.Type
    $info.Note = Get-InstallerTypeNote $info.Type
    if ($info.ProductCode) {
        $info.UninstallCommand = "msiexec /x $($info.ProductCode) /qn /norestart"
        $info.Detection = ConvertTo-DetectionRule ([pscustomobject]@{ type = 'msi'; target = $info.ProductCode })
    } elseif ($info.PackageName) {
        $info.Detection = ConvertTo-DetectionRule ([pscustomobject]@{ type = 'appx'; target = $info.PackageName })
    } elseif ($info.Type -ne 'script' -and $info.DisplayName) {
        # Most installers register under their product name in Programs and Features.
        $info.Detection = ConvertTo-DetectionRule ([pscustomobject]@{ type = 'uninstall'; target = "$($info.DisplayName)*" })
    }
    [pscustomobject]$info
}

function Get-MsiProperties {
    # ProductCode, ProductName, ProductVersion and Manufacturer from the MSI's Property table. Windows only; $null elsewhere.
    param([Parameter(Mandatory)][string]$Path)
    try { $wi = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop } catch { return $null }
    $result = @{}
    try {
        $full = (Resolve-Path $Path).ProviderPath
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($full, 0))
        foreach ($p in 'ProductCode', 'ProductName', 'ProductVersion', 'Manufacturer') {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property = '$p'"))
            [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($rec) { $result[$p] = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        }
    } catch { return $null }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi) }
    [pscustomobject]$result
}

function Get-MsixIdentity {
    # Name, Version and Publisher from AppxManifest.xml (or the bundle manifest) inside an .msix/.appx zip.
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $Path).ProviderPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -in 'AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
        if (-not $entry) { return $null }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$m = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $id = $m.SelectSingleNode('//*[local-name()="Identity"]')
        if (-not $id) { return $null }
        $publisher = $id.GetAttribute('Publisher')
        if ($publisher -match 'CN=([^,]+)') { $publisher = $Matches[1] }
        [pscustomobject]@{ Name = $id.GetAttribute('Name'); Version = $id.GetAttribute('Version'); Publisher = $publisher }
    } catch { $null }
    finally { $zip.Dispose() }
}

#endregion

#region Templates

function Get-AppTemplates {
    # config\app-templates.json: known silent switches and detection rules for common applications.
    param([string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/app-templates.json'))
    if (-not (Test-Path $Path)) { return @() }
    @((Get-Content -Raw $Path | ConvertFrom-Json).templates)
}

function New-AppFromCatalog {
    <#
    .SYNOPSIS
        Creates Applications\<name> from a catalog template: app.json with the download address, plus the template's
        extra files (Office's configuration.xml) from config\. Nothing is downloaded now; the PC does it at first boot.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)]$Template,
        [string]$Name,
        [string]$ConfigDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config'),
        # Turns an existing application into the online one (the Applications tab's download tick box).
        [switch]$Overwrite
    )
    $d = New-AppDefinitionFromTemplate -Template $Template -Name $(if ($Name) { $Name } else { $Template.name }) -Online
    $dest = Save-AppPack -AppRoot $AppRoot -Definition $d -Overwrite:$Overwrite
    if ($Template.PSObject.Properties['files'] -and $Template.files) {
        foreach ($f in $Template.files.PSObject.Properties) {
            Copy-Item -LiteralPath (Join-Path $ConfigDir $f.Value) -Destination (Join-Path $dest $f.Name) -Force
        }
    }
    $dest
}

function Get-AppKnownDownload {
    # The catalog template that knows where to download this application (by installer file or name), or $null.
    param([Parameter(Mandatory)]$Definition, [object[]]$Templates = (Get-AppTemplates))
    $t = Find-AppTemplate -Installer $Definition.installer -Templates $Templates
    if (-not $t -or -not ($t.PSObject.Properties['download'] -and $t.download.url)) { $t = Find-AppTemplate -Name $Definition.name -Templates $Templates }
    if ($t -and $t.PSObject.Properties['download'] -and $t.download.url) { $t } else { $null }
}

function Find-AppTemplate {
    # The first template whose file patterns match the installer name, or whose name matches -Name.
    param([string]$Installer, [string]$Name, [object[]]$Templates = (Get-AppTemplates))
    foreach ($t in $Templates) {
        if ($Installer -and @($t.match | Where-Object { $Installer -like $_ }).Count) { return $t }
    }
    if ($Name) {
        $key = $Name -replace '[^A-Za-z0-9]', ''
        foreach ($t in $Templates) {
            if (($t.name -replace '[^A-Za-z0-9]', '') -eq $key -or @($t.aliases | Where-Object { ($_ -replace '[^A-Za-z0-9]', '') -eq $key }).Count) { return $t }
        }
    }
    $null
}

function New-AppDefinitionFromTemplate {
    # A definition from a template; {installer} in its commands becomes the installer's file name.
    # -Online: the template's download (address and, when it differs, the command), so the PC gets the installer itself.
    param([Parameter(Mandatory)]$Template, [string]$Installer, [string]$Name, [switch]$Online)
    $json = $Template | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $file = if ($Installer) { $Installer } elseif ($json.PSObject.Properties['installer']) { $json.installer } else { '' }
    if ($Online) {
        $dl = if ($json.PSObject.Properties['download']) { $json.download } else { $null }
        if (-not $dl -or -not $dl.url) { throw "There is no download for $($Template.name): pick its installer instead." }
        $json | Add-Member -NotePropertyName downloadUrl -NotePropertyValue $dl.url -Force
        if ($dl.PSObject.Properties['command'] -and $dl.command) { $json.command = $dl.command }
    }
    foreach ($p in 'command', 'uninstallCommand') {
        if ($json.PSObject.Properties[$p] -and $json.$p) { $json.$p = $json.$p.Replace('{installer}', $file) }
    }
    if ($json.PSObject.Properties['installer']) { $json.installer = $file } else { $json | Add-Member -NotePropertyName installer -NotePropertyValue $file }
    ConvertTo-AppDefinition -Name $(if ($Name) { $Name } else { $Template.name }) -Json $json
}

#endregion

#region Online search (winget catalog)

function ConvertFrom-WingetSearch {
    <#
    .SYNOPSIS
        Rows of "winget search" output as @{ Name; Id; Version }. Reads the columns from the header line above the
        dashes, so it works whatever the language winget speaks (Nom/ID/Version in French).
    #>
    param([string[]]$Lines)
    $lines = @($Lines | ForEach-Object { "$_" -split "`r" | Select-Object -Last 1 })
    $dash = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{5,}\s*$') { $dash = $i; break } }
    if ($dash -lt 1) { return }
    $starts = @([regex]::Matches($lines[$dash - 1], '\S+') | ForEach-Object Index)
    if ($starts.Count -lt 3) { return }
    $cut = { param($line, $c)
        if ($line.Length -le $starts[$c]) { return '' }
        $end = if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $line.Length) } else { $line.Length }
        $line.Substring($starts[$c], $end - $starts[$c]).Trim() }
    foreach ($line in $lines[($dash + 1)..($lines.Count - 1)]) {
        if (-not $line.Trim()) { continue }
        $id = & $cut $line 1
        # A cut-off id (winget ends it with ...) can't be looked up.
        if ($id -notmatch '^[A-Za-z0-9][\w+-]*(\.[\w+-]+)+$') { continue }
        [pscustomobject]@{ Name = $line.Substring(0, [Math]::Min($starts[1], $line.Length)).Trim(); Id = $id; Version = & $cut $line 2 }
    }
}

function Find-WingetPackage {
    # Searches Microsoft's winget catalog with winget.exe on this PC (Windows 10 1809 and later have it).
    param([Parameter(Mandatory)][string]$Query)
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is not on this PC. Install App Installer from the Microsoft Store, then search again.'
    }
    $old = try { [Console]::OutputEncoding } catch { $null }
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { $out = & winget.exe search --query $Query --source winget --accept-source-agreements --disable-interactivity 2>&1 }
    finally { if ($old) { try { [Console]::OutputEncoding = $old } catch { } } }
    @(ConvertFrom-WingetSearch -Lines @($out | ForEach-Object { "$_" }))
}

function Get-WingetManifestUrl {
    # Where the winget catalog keeps a package's installer manifest (github.com/microsoft/winget-pkgs).
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version, [switch]$Singleton)
    $path = "$($Id.Substring(0, 1).ToLowerInvariant())/$($Id.Replace('.', '/'))/$Version"
    $file = if ($Singleton) { "$Id.yaml" } else { "$Id.installer.yaml" }
    "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$path/$file"
}

function ConvertFrom-WingetInstallerYaml {
    <#
    .SYNOPSIS
        The installers in a winget installer manifest, each with the manifest's defaults filled in:
        Architecture, InstallerType, InstallerUrl, InstallerSha256, Scope, Silent, ProductCode, DisplayName.
    #>
    param([Parameter(Mandatory)][string]$Text)
    $root = @{}; $items = [Collections.Generic.List[hashtable]]::new(); $cur = $null; $inList = $false; $parent = ''
    foreach ($raw in $Text -split "\r?\n") {
        if ($raw -match '^\s*(#|$)') { continue }
        $m = [regex]::Match($raw, '^( *)(- )?(.*)$')
        $ind = $m.Groups[1].Length; $dash = $m.Groups[2].Success; $body = $m.Groups[3].Value
        if ($ind -eq 0 -and -not $dash) {
            $cur = $null; $inList = $body -match '^Installers:\s*$'
            if ($inList) { continue }
        }
        if ($inList -and $ind -eq 0 -and $dash) { $cur = @{}; $items.Add($cur) }
        $target = if ($inList -and $cur) { $cur } else { $root }
        $level = $ind + $(if ($dash) { 2 } else { 0 }) - $(if ($inList -and $cur) { 2 } else { 0 })
        if ($body -notmatch '^([A-Za-z0-9]+):\s*(.*?)\s*$') { continue }
        $k = $Matches[1]; $v = $Matches[2] -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1'
        $key = if ($level -le 0) { $parent = $k; $k } else { "$parent.$k" }
        if ($v -and -not $target.ContainsKey($key)) { $target[$key] = $v }
    }
    $pick = { param($i, $k) if ($i.ContainsKey($k)) { $i[$k] } elseif ($root.ContainsKey($k)) { $root[$k] } else { '' } }
    foreach ($i in $items) {
        [pscustomobject]@{
            Architecture    = & $pick $i 'Architecture'
            InstallerType   = & $pick $i 'InstallerType'
            InstallerUrl    = & $pick $i 'InstallerUrl'
            InstallerSha256 = & $pick $i 'InstallerSha256'
            Scope           = & $pick $i 'Scope'
            Silent          = & $pick $i 'InstallerSwitches.Silent'
            ProductCode     = & $pick $i 'ProductCode'
            DisplayName     = & $pick $i 'AppsAndFeaturesEntries.DisplayName'
        }
    }
}

function Select-WingetInstaller {
    # The installer to deploy: 64-bit first, then neutral, then 32-bit; for every user (machine) before per user.
    # Zip and portable packages are left out: they have no installer to run.
    param([object[]]$Installers)
    $arch = @{ x64 = 0; neutral = 1; x86 = 2 }
    $scope = @{ machine = 0; '' = 1; user = 2 }
    @($Installers | Where-Object { $_.InstallerUrl -and $_.InstallerType -notin 'zip', 'portable', 'pwa' -and $arch.ContainsKey("$($_.Architecture)") } |
        Sort-Object { $arch["$($_.Architecture)"] }, { $scope["$($_.Scope)"] }) | Select-Object -First 1
}

function New-AppDefinitionFromWinget {
    # An application pack definition for a winget installer: downloaded at first boot from the publisher's address,
    # checked against the catalog's SHA256, installed silently, detected by MSI product code or uninstall name.
    param([Parameter(Mandatory)]$Installer, [Parameter(Mandatory)][string]$Id, [string]$Name, [string]$DisplayName, [string]$Version, [string]$Publisher)
    $i = $Installer
    $type = switch ("$($i.InstallerType)") { 'wix' { 'msi' } 'msi' { 'msi' } 'nullsoft' { 'nsis' } 'inno' { 'inno' } 'burn' { 'burn' } 'msix' { 'msix' } 'appx' { 'msix' } default { 'exe' } }
    $ext = switch ($type) { 'msi' { '.msi' } 'msix' { '.msix' } default { '.exe' } }
    $leaf = try { [IO.Path]::GetFileName(([Uri]$i.InstallerUrl).AbsolutePath) } catch { '' }
    $file = if ($leaf -match '^[\w.()+ -]+\.(exe|msi|msix|msixbundle|appx|appxbundle)$') { $leaf } else { ($Id -replace '[^A-Za-z0-9.-]', '-') + "-setup$ext" }
    $command = if ($type -ne 'msi' -and $type -ne 'msix' -and $i.Silent) { "`"$file`" $($i.Silent)" } else { Get-SilentInstallCommand -Installer $file -Type $type }
    $shown = if ($i.DisplayName) { $i.DisplayName } elseif ($DisplayName) { $DisplayName } else { $Id }
    $rule = if ($type -eq 'msi' -and $i.ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$') { @{ type = 'msi'; target = $i.ProductCode } }
            else { @{ type = 'uninstall'; target = "$shown*" } }
    $note = "From the winget catalog ($Id $Version). The PC downloads it from the publisher at first boot and checks its SHA256."
    if ($type -eq 'exe' -and -not $i.Silent) { $note += ' The catalog gives no silent switch: /S is a guess, test it on a VM first.' }
    ConvertTo-AppDefinition -Name $(if ($Name) { $Name } else { $Id -replace '\.', '-' }) -Json @{
        displayName = $shown; version = $Version; publisher = $Publisher
        installer = $file; installerType = $type; command = $command
        downloadUrl = $i.InstallerUrl; downloadSha256 = "$($i.InstallerSha256)".ToUpperInvariant()
        detection = @{ match = 'all'; rules = @($rule) }; timeoutMinutes = 30; notes = $note
    }
}

function New-AppFromWinget {
    <#
    .SYNOPSIS
        Adds Applications\<name> for a winget package (from Find-WingetPackage): reads its installer manifest from the
        winget catalog on GitHub and saves a pack the PC downloads at first boot. Nothing big is downloaded now.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [string]$Name,
        [string]$DisplayName,
        # Tests pass their own; the default reads the address with Invoke-WebRequest.
        [scriptblock]$Fetch = { param($Url) (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content }
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $yaml = $null
    foreach ($single in $false, $true) {
        try { $yaml = & $Fetch (Get-WingetManifestUrl -Id $Id -Version $Version -Singleton:$single); break } catch { }
    }
    if (-not $yaml) { throw "Could not read the winget manifest of $Id $Version. Check the internet connection, or search again." }
    if ($yaml -is [byte[]]) { $yaml = [Text.Encoding]::UTF8.GetString($yaml) }
    $publisher = if ("$yaml" -match '(?m)^Publisher:\s*(.+?)\s*$') { $Matches[1] } else { '' }
    $inst = Select-WingetInstaller -Installers @(ConvertFrom-WingetInstallerYaml -Text "$yaml")
    if (-not $inst) { throw "$Id $Version has no installer this tool can run (only zip or portable files)." }
    $d = New-AppDefinitionFromWinget -Installer $inst -Id $Id -Name $Name -DisplayName $DisplayName -Version $Version -Publisher $publisher
    Save-AppPack -AppRoot $AppRoot -Definition $d | Out-Null
    $d
}

#endregion

#region Pack folders and files

function Save-AppPack {
    <#
    .SYNOPSIS
        Writes Applications\<name>: copies the installer (a file, or a folder's contents) when -Source is given,
        then writes app.json. Without -Overwrite, an existing application is an error.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)]$Definition,
        [string]$Source,
        [switch]$Overwrite
    )
    $dest = Join-Path $AppRoot $Definition.name
    if ((Test-Path $dest) -and -not $Overwrite) { throw "An application named $($Definition.name) already exists." }
    if ($Source -and -not (Test-Path $Source)) { throw "Installer not found: $Source" }
    $problems = @(Test-AppPack -Definition $Definition | Where-Object { $_ -notlike 'Warning:*' })
    if ($problems) { throw ($problems -join "`n") }

    $isNew = -not (Test-Path $dest)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    if ($Source) {
        if (Test-Path $Source -PathType Container) { Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force }
        else { Copy-Item -Path $Source -Destination $dest -Force }
    }
    $problems = @(Test-AppPack -Definition $Definition -Folder $dest | Where-Object { $_ -notlike 'Warning:*' })
    if ($problems) {
        if ($isNew) { Remove-Item $dest -Recurse -Force }
        throw ($problems -join "`n")
    }
    ConvertTo-AppJson $Definition | Set-Content (Join-Path $dest 'app.json') -Encoding utf8
    $dest
}

function Export-AppPack {
    # Zips Applications\<name> (installer, app.json, scripts) into one file to copy to another content root.
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    $src = Join-Path $AppRoot $Name
    [void](Read-AppPack -AppRoot $AppRoot -Name $Name)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path $src).ProviderPath, $Path, 'Optimal', $false)
    $Path
}

function Import-AppPack {
    # Unzips an exported pack into Applications\<name>; the name comes from the file unless -Name is given.
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Path, [string]$Name, [switch]$Overwrite)
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Path) -replace '\.apppack$', '' }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Application name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $dest = Join-Path $AppRoot $Name
    if ((Test-Path $dest) -and -not $Overwrite) { throw "An application named $Name already exists." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("apppack-" + [guid]::NewGuid())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $Path).ProviderPath, $tmp)
        if (-not (Test-Path (Join-Path $tmp 'app.json'))) { throw "$Path is not an application pack (no app.json at the top)." }
        $def = ConvertTo-AppDefinition -Name $Name -Json (Get-Content -Raw (Join-Path $tmp 'app.json') | ConvertFrom-Json)
        $problems = @(Test-AppPack -Definition $def -Folder $tmp | Where-Object { $_ -notlike 'Warning:*' })
        if ($problems) { throw ($problems -join "`n") }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $AppRoot -Force | Out-Null
        Move-Item $tmp $dest
    } finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } }
    $dest
}

#endregion

#region On the target PC

function Test-AppRequirement {
    # $true when the app is for this PC. Makers and models are wildcards, compared with Get-HardwareIdentity's Maker/Model.
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)]$Identity)
    $r = $Definition.requirements
    $makerOk = -not @($r.makers).Count -or @($r.makers | Where-Object { $Identity.Maker -like $_ }).Count
    $modelOk = -not @($r.models).Count -or @($r.models | Where-Object { $Identity.Model -like $_ -or ($Identity.MachineType -and $Identity.MachineType -like $_) }).Count
    [bool]($makerOk -and $modelOk)
}

function Compare-AppVersion {
    # True when $Found satisfies "$Operator $Wanted". Dotted versions compare numerically, anything else as text.
    param([string]$Found, [string]$Operator, [string]$Wanted)
    if ($Operator -eq 'exists' -or -not $Wanted) { return $true }
    if (-not $Found) { return $false }
    $a = $null; $b = $null
    $clean = { param($v) ($v -replace '[^0-9.].*$', '').Trim('.') }
    if ([version]::TryParse((& $clean $Found), [ref]$a) -and [version]::TryParse((& $clean $Wanted), [ref]$b)) {
        # Missing parts count as 0, so 6.2 = 6.2.0.0.
        $norm = { param($v) [version]::new($v.Major, $v.Minor, [Math]::Max($v.Build, 0), [Math]::Max($v.Revision, 0)) }
        $a = & $norm $a; $b = & $norm $b
        if ($Operator -eq '=') { return $a -eq $b } else { return $a -ge $b }
    }
    if ($Operator -eq '=') { $Found -eq $Wanted } else { [string]::Compare($Found, $Wanted, $true) -ge 0 }
}

function Get-UninstallEntries {
    # Programs and Features entries (64- and 32-bit) with the key name, which is the product code for MSIs.
    foreach ($k in $script:UninstallKeys) {
        Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            [pscustomobject]@{ KeyName = $_.PSChildName; DisplayName = $p.DisplayName; DisplayVersion = $p.DisplayVersion }
        }
    }
}

function Test-DetectionRule {
    # One rule against this PC. Returns @{ Found; Detail }. -UninstallEntries can be passed in (tests, or to read the registry once).
    param([Parameter(Mandatory)]$Rule, [string]$AppFolder, [object[]]$UninstallEntries)
    $r = $Rule
    $result = { param($found, $detail) [pscustomobject]@{ Found = [bool]$found; Detail = $detail } }
    $entries = { if ($null -ne $UninstallEntries) { $UninstallEntries } else { @(Get-UninstallEntries) } }
    switch ($r.type) {
        'msi' {
            $e = & $entries | Where-Object { $_.KeyName -eq $r.target } | Select-Object -First 1
            if (-not $e) { return & $result $false "product $($r.target) not installed" }
            & $result (Compare-AppVersion $e.DisplayVersion $r.operator $r.version) "$($e.DisplayName) $($e.DisplayVersion)"
        }
        'uninstall' {
            $e = @(& $entries | Where-Object { $_.DisplayName -and $_.DisplayName -like $r.target })
            if (-not $e) { return & $result $false "no installed program named $($r.target)" }
            $ok = @($e | Where-Object { Compare-AppVersion $_.DisplayVersion $r.operator $r.version })
            $pick = if ($ok) { $ok[0] } else { $e[0] }
            & $result ([bool]$ok) "$($pick.DisplayName) $($pick.DisplayVersion)"
        }
        'file' {
            $path = [Environment]::ExpandEnvironmentVariables($r.target)
            if (-not (Test-Path -LiteralPath $path)) { return & $result $false "$path not found" }
            $ver = ''
            try { $ver = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion } catch { }
            $ver = if ($ver) { ($ver -split '[ ,]')[0] } else { '' }
            & $result (Compare-AppVersion $ver $r.operator $r.version) "$path $ver".Trim()
        }
        'registry' {
            $key = $r.target -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\'
            if (-not (Test-Path -LiteralPath $key)) { return & $result $false "$($r.target) not found" }
            if (-not $r.value) { return & $result $true "$($r.target) exists" }
            $v = (Get-ItemProperty -LiteralPath $key -Name $r.value -ErrorAction SilentlyContinue).($r.value)
            if ($null -eq $v) { return & $result $false "$($r.target)\$($r.value) not set" }
            & $result (Compare-AppVersion "$v" $r.operator $r.version) "$($r.value) = $v"
        }
        'appx' {
            # Provisioned (for new users) or installed for any user.
            $p = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -like $r.target)
            $ver = if ($p) { "$($p[0].Version)" } else { "$((Get-AppxPackage -AllUsers -Name $r.target -ErrorAction SilentlyContinue | Select-Object -First 1).Version)" }
            if (-not $ver) { return & $result $false "package $($r.target) not installed" }
            & $result (Compare-AppVersion $ver $r.operator $r.version) "$($r.target) $ver"
        }
        'script' {
            # Exit code 0 means installed.
            $file = if ($AppFolder) { Join-Path $AppFolder $r.target } else { $r.target }
            if (-not (Test-Path $file)) { return & $result $false "detection script $file not found" }
            $p = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$file`"" -Wait -PassThru -WindowStyle Hidden
            & $result ($p.ExitCode -eq 0) "script exit $($p.ExitCode)"
        }
    }
}

function Test-AppDetection {
    <#
    .SYNOPSIS
        Runs an application's detection rules. Returns @{ HasRules; Detected; Details }.
    #>
    param([Parameter(Mandatory)]$Definition, [string]$AppFolder, [object[]]$UninstallEntries)
    $rules = @($Definition.detection.rules)
    if (-not $rules.Count) { return [pscustomobject]@{ HasRules = $false; Detected = $false; Details = @() } }
    if ($null -eq $UninstallEntries -and @($rules | Where-Object { $_.type -in 'msi', 'uninstall' }).Count) { $UninstallEntries = @(Get-UninstallEntries) }
    $results = @(foreach ($r in $rules) {
        $t = try { Test-DetectionRule -Rule $r -AppFolder $AppFolder -UninstallEntries $UninstallEntries } catch { [pscustomobject]@{ Found = $false; Detail = $_.Exception.Message } }
        [pscustomobject]@{ Rule = "$($r.type) $($r.target)"; Found = $t.Found; Detail = $t.Detail }
    })
    $found = @($results | Where-Object Found).Count
    $detected = if ($Definition.detection.match -eq 'any') { $found -gt 0 } else { $found -eq $results.Count }
    [pscustomobject]@{ HasRules = $true; Detected = $detected; Details = $results }
}

function Get-AppDownload {
    <#
    .SYNOPSIS
        Downloads the installer of an application that has a downloadUrl into its folder, unless it is already there.
        Tries -Attempts times, -WaitSeconds apart (the network can take a minute after setup). Throws when it can't.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$AppFolder,
        [scriptblock]$Log = { param($m) Write-Host $m },
        [int]$Attempts = 10,
        [int]$WaitSeconds = 30,
        # Tests pass their own; the default is Invoke-WebRequest.
        [scriptblock]$Downloader = { param($Url, $Path) Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing }
    )
    $d = $Definition
    if (-not $d.downloadUrl) { return }
    $path = [IO.Path]::Combine($AppFolder, $d.installer)
    if ([IO.File]::Exists($path)) { & $Log "  $($d.installer) is already in the folder; not downloaded"; return }
    # Windows PowerShell 5.1 does not always offer TLS 1.2 on its own.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                & $Downloader $d.downloadUrl $path
                if (-not [IO.File]::Exists($path)) { throw 'nothing was saved' }
                if ($d.downloadSha256) {
                    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                    if ($hash -ne $d.downloadSha256.ToUpperInvariant()) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                        throw "the download's SHA256 $hash is not the expected $($d.downloadSha256); the publisher changed the file, so add the application again"
                    }
                }
                & $Log ("  Downloaded {0} ({1:N1} MB)" -f $d.downloadUrl, ((Get-Item -LiteralPath $path).Length / 1MB))
                return
            } catch {
                & $Log "  Download attempt $i of $Attempts failed: $($_.Exception.Message)"
                if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                if ($i -lt $Attempts) { Start-Sleep -Seconds $WaitSeconds }
            }
        }
    } finally { $ProgressPreference = $old }
    throw "could not download $($d.downloadUrl) (no internet?)"
}

function Get-MediaAppDownloads {
    <#
    .SYNOPSIS
        For a media copy plan (Get-MediaCopyPlan): downloads, on the console PC, the installer of every application
        in the plan that has a downloadUrl and no installer in its folder, so an offline USB stick installs it without
        internet. Downloads go to -CacheRoot (not into the content root) and are reused by the next build: one with
        a downloadSha256 while its hash matches, one without for -MaxAgeDays (a "latest" link changes over time).
        Returns Items (Relative, Source, Length) to add to the plan and Failed (app names). A failed download is not
        an error: that PC downloads the installer at first boot, as before.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$CacheRoot,
        [int]$MaxAgeDays = 7,
        [scriptblock]$Log = { param($m) Write-Host $m },
        [int]$Attempts = 2,
        [int]$WaitSeconds = 5,
        [scriptblock]$Downloader,
        [scriptblock]$OnApp
    )
    $inPlan = @{}
    foreach ($i in @($Plan.Items)) { $inPlan[$i.Relative.ToLowerInvariant()] = $true }
    $jsons = @($Plan.Items | Where-Object { $_.Relative -match '\\app\.json$' -and ($_.Relative -replace '\\app\.json$', '') -match '\\' })
    $items = @(); $failed = @(); $n = 0
    foreach ($j in $jsons) {
        $n++
        $relDir = $j.Relative -replace '\\app\.json$', ''
        $name = ($relDir -split '\\')[-1]
        $def = $null
        try { $def = ConvertTo-AppDefinition -Name $name -Json ([IO.File]::ReadAllText($j.Source) | ConvertFrom-Json) } catch { continue }
        if (-not $def.downloadUrl -or -not $def.installer) { continue }
        $rel = "$relDir\$($def.installer)"
        if ($inPlan.ContainsKey($rel.ToLowerInvariant())) { continue }   # the installer is already in the folder
        if ($OnApp) { & $OnApp $name $n $jsons.Count }
        $cacheDir = [IO.Path]::Combine($CacheRoot, $relDir)
        $cached = [IO.Path]::Combine($cacheDir, $def.installer)
        if ([IO.File]::Exists($cached)) {
            $keep = if ($def.downloadSha256) { (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -eq $def.downloadSha256.ToUpperInvariant() }
                    else { ((Get-Date) - [IO.File]::GetLastWriteTime($cached)).TotalDays -lt $MaxAgeDays }
            if (-not $keep) { [IO.File]::Delete($cached) }
        }
        [void][IO.Directory]::CreateDirectory($cacheDir)
        $dlArgs = @{ Definition = $def; AppFolder = $cacheDir; Log = $Log; Attempts = $Attempts; WaitSeconds = $WaitSeconds }
        if ($Downloader) { $dlArgs.Downloader = $Downloader }
        try {
            if ([IO.File]::Exists($cached)) { & $Log "  ${name}: $($def.installer) reused from the last build" }
            else { & $Log "  ${name}: downloading $($def.downloadUrl)"; Get-AppDownload @dlArgs }
            $items += [pscustomobject]@{ Relative = $rel; Source = $cached; Length = [int64](New-Object IO.FileInfo $cached).Length }
        } catch {
            & $Log "  ${name}: not downloaded ($($_.Exception.Message)); the PC downloads it at first boot"
            $failed += $name
        }
    }
    [pscustomobject]@{ Items = $items; Failed = $failed }
}

function Add-MediaCopyItems {
    # Adds extra files (Relative, Source, Length) to a media copy plan; returns the new plan.
    param([Parameter(Mandatory)]$Plan, [object[]]$Items)
    if (-not $Items) { return $Plan }
    $all = @($Plan.Items) + @($Items)
    $total = [int64]0
    foreach ($i in $all) { $total += $i.Length }
    $out = $Plan.PSObject.Copy()
    $out.Items = $all; $out.TotalBytes = $total; $out.FileCount = $all.Count
    $out
}

function Invoke-AppInstall {
    <#
    .SYNOPSIS
        Installs one application on this PC: skips it when already detected, runs the command with a timeout,
        then checks the detection rules again. Returns @{ Status; ExitCode; RebootNeeded; Message }.
        Status is Installed, AlreadyInstalled, Failed or TimedOut.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$AppFolder, [scriptblock]$Log = { param($m) Write-Host $m })
    $d = $Definition
    $out = { param($s, $code, $reboot, $msg) [pscustomobject]@{ Status = $s; ExitCode = $code; RebootNeeded = [bool]$reboot; Message = $msg } }

    $before = Test-AppDetection -Definition $d -AppFolder $AppFolder
    if ($before.HasRules -and $before.Detected -and $d.skipIfDetected) {
        return & $out 'AlreadyInstalled' $null $false "already installed ($(($before.Details | ForEach-Object Detail) -join '; '))"
    }
    if ($d.downloadUrl) {
        try { Get-AppDownload -Definition $d -AppFolder $AppFolder -Log $Log }
        catch { return & $out 'Failed' $null $false "download failed: $($_.Exception.Message)" }
    }

    & $Log "  > $($d.command)"
    $p = Start-Process -FilePath cmd.exe -ArgumentList "/c $($d.command)" -WorkingDirectory $AppFolder -PassThru -WindowStyle Hidden
    $null = $p.Handle   # keeps the handle open, or ExitCode is empty after a timed wait
    if (-not $p.WaitForExit($d.timeoutMinutes * 60000)) {
        try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch { }
        return & $out 'TimedOut' $null $false "still running after $($d.timeoutMinutes) minutes; stopped"
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($d.successCodes -notcontains $code) { return & $out 'Failed' $code $false "exit code $code is not a success code ($($d.successCodes -join ', '))" }
    $reboot = $d.rebootCodes -contains $code

    $after = Test-AppDetection -Definition $d -AppFolder $AppFolder
    if ($after.HasRules -and -not $after.Detected) {
        # Some installers finish their work after a restart; do not fail those.
        if ($reboot) { return & $out 'Installed' $code $true "exit $code (restart needed); not detected yet: $(($after.Details | ForEach-Object Detail) -join '; ')" }
        return & $out 'Failed' $code $false "exit $code but not detected: $(($after.Details | ForEach-Object Detail) -join '; ')"
    }
    & $out 'Installed' $code $reboot "exit $code$(if ($reboot) { ' (restart needed)' })$(if (-not $after.HasRules) { ', no detection rule to check' })"
}

#endregion

Export-ModuleMember -Function ConvertTo-AppDefinition, ConvertTo-DetectionRule, Read-AppPack, ConvertTo-AppJson, Test-AppPack,
    Find-InstallerFramework, Get-SilentInstallCommand, Get-InstallerTypeNote, Get-InstallerInfo, Get-MsiProperties, Get-MsixIdentity,
    Get-AppTemplates, New-AppFromCatalog, Get-AppKnownDownload,
    ConvertFrom-WingetSearch, Find-WingetPackage, Get-WingetManifestUrl, ConvertFrom-WingetInstallerYaml, Select-WingetInstaller,
    New-AppDefinitionFromWinget, New-AppFromWinget, Find-AppTemplate, New-AppDefinitionFromTemplate, Get-AppDownload,
    Get-MediaAppDownloads, Add-MediaCopyItems,
    Save-AppPack, Export-AppPack, Import-AppPack,
    Test-AppRequirement, Compare-AppVersion, Get-UninstallEntries, Test-DetectionRule, Test-AppDetection, Invoke-AppInstall
