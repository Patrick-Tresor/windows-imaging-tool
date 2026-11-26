# Application packs: Applications\<name>\ holds an installer and an app.json that says how to install it
# silently, which PCs it is for, and how to tell that it is installed (detection rules).
# Used by the console (build, inspect, export/import), Deploy-Image.ps1 in WinPE (requirements) and
# FirstBoot.ps1 on the deployed PC (detection). PowerShell 5.1 compatible; nothing Windows-only runs at import.

Import-Module (Join-Path $PSScriptRoot 'LibraryPack.psm1')   # what applications and tasks share

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
    $def = ConvertTo-AppDefinition -Name $Name -Json (Read-PackJson -Root $AppRoot -Name $Name -File 'app.json' -Noun 'Application')
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
        MSIX package name, and a suggested silent command and detection rule.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Installer not found: $Path" }
    $leaf = Split-Path $Path -Leaf
    $info = [ordered]@{
        Installer = $leaf; Type = 'exe'; DisplayName = [IO.Path]::GetFileNameWithoutExtension($leaf); Version = ''; Publisher = ''
        ProductCode = ''; PackageName = ''; Command = ''; Detection = $null; Note = ''
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
    param([string]$Path)
    Get-PackTemplates -File 'app-templates.json' -Path $Path
}

function Copy-AppTemplateFiles {
    # The template's extra files (Office's configuration.xml) from config\ into the application's folder. The
    # application pack builder calls it when it saves an application made from such a template.
    param(
        [Parameter(Mandatory)]$Template,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ConfigDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config')
    )
    if (-not ($Template.PSObject.Properties['files'] -and $Template.files)) { return }
    foreach ($f in $Template.files.PSObject.Properties) {
        $target = Join-Path $Destination $f.Name
        # An edited configuration.xml in the pack is kept.
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath (Join-Path $ConfigDir $f.Value) -Destination $target }
    }
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
    if ($json.PSObject.Properties['command'] -and $json.command) { $json.command = $json.command.Replace('{installer}', $file) }
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
    $lines = @($Lines | ForEach-Object { Remove-ConsoleControl "$_" })
    $dash = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{5,}\s*$') { $dash = $i; break } }
    if ($dash -lt 1) { return }
    $starts = @([regex]::Matches($lines[$dash - 1], '\S+') | ForEach-Object Index)
    if ($starts.Count -lt 3) { return }
    $idPattern = '^[A-Za-z0-9][\w+-]*(\.[\w+-]+)+$'
    $cut = { param($line, $c)
        if ($line.Length -le $starts[$c]) { return '' }
        $end = if ($c + 1 -lt $starts.Count) { [Math]::Min($starts[$c + 1], $line.Length) } else { $line.Length }
        $line.Substring($starts[$c], $end - $starts[$c]).Trim() }
    foreach ($line in $lines[($dash + 1)..($lines.Count - 1)]) {
        if (-not $line.Trim()) { continue }
        $id = & $cut $line 1
        # The id must start where the ID column starts, or the row is shifted (see below).
        if ($id -match $idPattern -and ($starts[1] -eq 0 -or $line[$starts[1] - 1] -match '\s')) {
            [pscustomobject]@{ Name = $line.Substring(0, [Math]::Min($starts[1], $line.Length)).Trim(); Id = $id; Version = & $cut $line 2 }
            continue
        }
        # winget lines its columns up by screen width, so a name with wide letters (Chinese, emoji) shifts the row:
        # take the catalog id closest to the ID column, and the version right after it.
        $tokens = @([regex]::Matches($line, '\S+'))
        $best = $null
        for ($t = 1; $t -lt $tokens.Count - 1; $t++) {
            # Wide letters only move the id to the left, and a version number (1.0) is never an id.
            if ($tokens[$t].Index -gt $starts[1] -or $tokens[$t].Value -notmatch $idPattern -or $tokens[$t].Value -match '^[\d.]+$') { continue }
            if (-not $best -or [Math]::Abs($tokens[$t].Index - $starts[1]) -lt [Math]::Abs($tokens[$best].Index - $starts[1])) { $best = $t }
        }
        # A cut-off id (winget ends it with ...) can't be looked up.
        if (-not $best) { continue }
        [pscustomobject]@{ Name = $line.Substring(0, $tokens[$best].Index).Trim(); Id = $tokens[$best].Value; Version = $tokens[$best + 1].Value }
    }
}

function Remove-ConsoleControl {
    # A console line as it shows on screen: what is left after the last carriage return (spinners, progress bars),
    # without colour and taskbar progress codes (ESC[...m, ESC]9;4;...) or other control characters.
    param([string]$Line)
    $Line = $Line -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)?', '' -replace '\x1b\[[0-?]*[ -/]*[@-~]', '' -replace '\x1b[@-_]?', ''
    $Line = @($Line -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1) -join ''
    $Line -replace '[\x00-\x08\x0b-\x1f\x7f]', ''
}

function Get-WingetSearchFailure {
    <#
    .SYNOPSIS
        Why "winget search" gave no rows, in one short line, or $null when it simply found no match.
        Reads winget's exit code first, then its last message.
    #>
    param([string[]]$Lines, [int]$ExitCode)
    $hex = '0x{0:X8}' -f $ExitCode
    switch ($hex) {
        '0x00000000' { return $null }
        '0x8A150014' { return $null }   # no package matches
        '0x8A150002' { return "winget on this PC is too old (exit $hex). Update App Installer from the Microsoft Store." }
        '0x8A150044' { return "winget's source agreements were not accepted (exit $hex). Run 'winget search chrome' once in a command prompt." }
        '0x8A15000F' { return "winget's catalog is missing (exit $hex). Run 'winget source reset --force' as administrator." }
        '0x8A150011' { return "winget has no 'winget' source (exit $hex). Run 'winget source reset --force' as administrator." }
        '0xC0000005' { return "winget crashed (exit $hex). Update App Installer from the Microsoft Store or github.com/microsoft/winget-cli/releases." }
    }
    $last = @($Lines | ForEach-Object { Remove-ConsoleControl "$_" } | Where-Object { $_ -match '\w' -and $_ -notmatch '^-{5,}\s*$' -and $_ -notmatch '^\s*[\d.]+\s*[KMG]?B\s*/' } | Select-Object -Last 1)
    $why = if ($last) { $last[0].Trim() } else { 'no message' }
    if ($why.Length -gt 120) { $why = $why.Substring(0, 117) + '...' }
    "winget search failed (exit $hex): $why"
}

function Find-WingetPackage {
    # Searches Microsoft's winget catalog with winget.exe on this PC (Windows 10 1809 and later have it).
    # Every search is written to %LOCALAPPDATA%\ImagingConsole\winget-search.log (command, exit code, full output).
    # No match gives an empty list; a winget failure throws one short line that says why.
    param([Parameter(Mandatory)][string]$Query, [string]$LogPath = [IO.Path]::Combine($env:LOCALAPPDATA, 'ImagingConsole', 'winget-search.log'),
        [scriptblock]$Runner)
    if (-not $Runner) {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw 'winget is not on this PC (or not for this admin account). Install App Installer from the Microsoft Store, then search again.'
        }
        $Runner = { param([string[]]$WingetArgs)
            $old = try { [Console]::OutputEncoding } catch { $null }
            try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
            try { $out = @(& winget.exe @WingetArgs 2>&1 | ForEach-Object { "$_" }); [pscustomobject]@{ Lines = $out; ExitCode = [int]$LASTEXITCODE } }
            catch { [pscustomobject]@{ Lines = @("$($_.Exception.Message)"); ExitCode = -1 } }
            finally { if ($old) { try { [Console]::OutputEncoding = $old } catch { } } }
        }
    }
    $wingetArgs = @('search', '--query', $Query, '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
    $r = & $Runner $wingetArgs
    # winget before 1.4 doesn't know --disable-interactivity and stops on it.
    $oldWinget = ('0x{0:X8}' -f [int]$r.ExitCode) -eq '0x8A150002'
    if ($oldWinget) { $wingetArgs = $wingetArgs[0..5]; $r = & $Runner $wingetArgs }
    $lines = @($r.Lines)
    $found = @(ConvertFrom-WingetSearch -Lines $lines)
    if ($LogPath) {
        try {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($LogPath))
            $text = "==== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  winget $($wingetArgs -join ' ')`r`nExit code: $('0x{0:X8}' -f [int]$r.ExitCode)  Rows read: $($found.Count)`r`n" +
                (($lines | ForEach-Object { Remove-ConsoleControl $_ }) -join "`r`n") + "`r`n"
            [IO.File]::AppendAllText($LogPath, $text, [Text.Encoding]::UTF8)
        } catch { }
    }
    if ($found.Count) { return $found }
    $why = Get-WingetSearchFailure -Lines $lines -ExitCode ([int]$r.ExitCode)
    if ($why -and $oldWinget) { $why = "winget on this PC is too old (before 1.4) and failed (exit $('0x{0:X8}' -f [int]$r.ExitCode)). Update App Installer from the Microsoft Store or github.com/microsoft/winget-cli/releases." }
    if ($why) { throw "$why Details: $LogPath" }
    # winget printed a results table but no row could be read: say so, it isn't "nothing found".
    if (@($lines | Where-Object { (Remove-ConsoleControl $_) -match '^-{5,}\s*$' }).Count) {
        throw "winget found packages but the list could not be read. Details: $LogPath"
    }
    @()
}

function Get-WingetManifestUrl {
    # Where the winget catalog keeps a package's installer manifest (github.com/microsoft/winget-pkgs).
    # -Locale gives the locale manifest instead (Publisher, PackageName); en-US is the catalog's usual default.
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Version, [switch]$Singleton, [string]$Locale)
    $path = "$($Id.Substring(0, 1).ToLowerInvariant())/$($Id.Replace('.', '/'))/$Version"
    $file = if ($Locale) { "$Id.locale.$Locale.yaml" } elseif ($Singleton) { "$Id.yaml" } else { "$Id.installer.yaml" }
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
    if (-not $publisher) {
        # A multi-file manifest keeps Publisher in the locale manifest. The download check needs it (Test-AppDownloadFile).
        $loc = try { & $Fetch (Get-WingetManifestUrl -Id $Id -Version $Version -Locale 'en-US') } catch { $null }
        if ($loc -is [byte[]]) { $loc = [Text.Encoding]::UTF8.GetString($loc) }
        if ("$loc" -match '(?m)^Publisher:\s*(.+?)\s*$') { $publisher = $Matches[1].Trim().Trim('"', "'") }
    }
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
    Save-PackFolder -Root $AppRoot -Name $Definition.name -Noun 'application' -File 'app.json' -JsonText (ConvertTo-AppJson $Definition) `
        -Source $Source -SourceNoun 'Installer' -Overwrite:$Overwrite `
        -Problems { param($Folder) Test-AppPack -Definition $Definition -Folder $Folder | Where-Object { $_ -notlike 'Warning:*' } }
}

#endregion

#region On the target PC

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
        A link the server refuses (HTTP 4xx such as 403 or 404) is not tried again: it gives the same answer every time.
        Once a download found no internet, the next ones within 10 minutes try only once, so a PC with no network
        does not wait minutes for every application.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$AppFolder,
        [scriptblock]$Log = { param($m) Write-Host $m },
        [int]$Attempts = 6,
        [int]$WaitSeconds = 20,
        # Tests pass their own; the default is Invoke-WebRequest.
        [scriptblock]$Downloader = { param($Url, $Path) Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing },
        # Tests pass their own; the default reads the file's Authenticode signature (Status, Subject).
        [scriptblock]$Signature = {
            param($Path)
            $s = Get-AuthenticodeSignature -LiteralPath $Path
            [pscustomobject]@{ Status = "$($s.Status)"; Subject = $(if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { '' }) }
        }
    )
    $d = $Definition
    if (-not $d.downloadUrl) { return }
    $path = [IO.Path]::Combine($AppFolder, $d.installer)
    if ([IO.File]::Exists($path)) { & $Log "  $($d.installer) is already in the folder; not downloaded"; return }
    # Windows PowerShell 5.1 does not always offer TLS 1.2 on its own.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    if (-not $PSBoundParameters.ContainsKey('Attempts') -and $script:DownloadOfflineUntil -and (Get-Date) -lt $script:DownloadOfflineUntil) {
        & $Log '  No internet for the last download: trying once'
        $Attempts = 1
    }
    try {
        $last = ''
        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                & $Downloader $d.downloadUrl $path
                if (-not [IO.File]::Exists($path)) { throw 'nothing was saved' }
            } catch {
                $last = $_.Exception.Message
                & $Log "  Download attempt $i of $Attempts failed: $last"
                if ([IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                $status = Get-HttpErrorStatus $_.Exception
                if ($status -ge 400 -and $status -lt 500 -and $status -notin 408, 429) { throw "the server refused the link (HTTP $status)" }
                if ($i -lt $Attempts) { Start-Sleep -Seconds $WaitSeconds }
                continue
            }
            $script:DownloadOfflineUntil = $null
            # The download worked. A file that fails the check is refused at once: downloading it again gives the same file.
            $problem = Test-AppDownloadFile -Definition $d -Path $path -Signature $Signature -Log $Log
            if ($problem) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                throw $problem
            }
            & $Log ("  Downloaded {0} ({1:N1} MB)" -f $d.downloadUrl, ((Get-Item -LiteralPath $path).Length / 1MB))
            return
        }
    } finally { $ProgressPreference = $old }
    $script:DownloadOfflineUntil = (Get-Date).AddMinutes(10)
    throw "could not download $($d.downloadUrl) after $Attempts tries (no internet?). Last error: $last"
}

function Get-HttpErrorStatus {
    # The HTTP status of a failed web request (WebException in Windows PowerShell, HttpResponseException in 7), else 0.
    param($Exception)
    for ($e = $Exception; $e; $e = $e.InnerException) {
        $code = try { [int]$e.Response.StatusCode } catch { 0 }
        if ($code) { return $code }
        if ("$($e.Message)" -match '\((\d{3})\)|status code does not indicate success: (\d{3})') { return [int]$(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }) }
    }
    0
}

# Signer names of well-known publishers. A pack matches an entry when its publisher is one of the entry's names
# (ignoring Inc/LLC/Corporation...) or its download address is on one of the entry's domains; then a file signed
# by any of the entry's names is the publisher's. Packs added before the publisher was saved still work this way.
$script:KnownPublishers = @(
    @{ Names = 'Google LLC', 'Google';                                   Domains = 'google.com', 'googleapis.com', 'gstatic.com' }
    @{ Names = 'Mozilla Corporation', 'Mozilla';                         Domains = 'mozilla.org', 'mozilla.net' }
    @{ Names = 'Microsoft Corporation', 'Microsoft';                     Domains = 'microsoft.com', 'office.com', 'office.net', 'aka.ms', 'dot.net', 'live.com', 'skype.com' }
    @{ Names = 'Zoom Video Communications, Inc.', 'Zoom Communications, Inc.', 'Zoom'; Domains = 'zoom.us', 'zoom.com' }
    @{ Names = 'Adobe Inc.', 'Adobe Systems Incorporated', 'Adobe';      Domains = 'adobe.com' }
    @{ Names = 'VideoLAN';                                               Domains = 'videolan.org' }
    @{ Names = 'Dell Inc', 'Dell Technologies Inc.', 'Dell';             Domains = 'dell.com' }
    @{ Names = 'HP Inc.', 'Hewlett-Packard Company', 'HP';               Domains = 'hp.com' }
    @{ Names = 'Lenovo';                                                 Domains = 'lenovo.com' }
    @{ Names = 'Cisco Systems, Inc.', 'Cisco WebEx LLC', 'Cisco';        Domains = 'cisco.com', 'webex.com' }
    @{ Names = 'Notepad++';                                              Domains = 'notepad-plus-plus.org' }
    @{ Names = 'Oracle America, Inc.', 'Oracle';                         Domains = 'oracle.com', 'java.com' }
)

function ConvertTo-PublisherKey {
    # A company name without case, quotes, trailing dots and legal endings: 'Google LLC' and 'Google' give 'google'.
    param([string]$Name)
    $n = "$Name".ToLowerInvariant() -replace '["]', '' -replace '\s+', ' '
    do { $old = $n; $n = ($n.Trim().TrimEnd('.', ',').Trim() -replace '[ ,]+(llc|l\.l\.c|inc|incorporated|corp|corporation|ltd|limited|gmbh|ag|s\.?a|co|company)$', '') } while ($n -ne $old)
    $n
}

function Get-AppExpectedSigners {
    # Names a download of this pack may be signed by: the pack's publisher, plus the known publisher it or its
    # download address belongs to.
    param([Parameter(Mandatory)]$Definition)
    $names = [Collections.Generic.List[string]]::new()
    if ("$($Definition.publisher)".Trim()) { $names.Add("$($Definition.publisher)".Trim()) }
    $pubKey = ConvertTo-PublisherKey $Definition.publisher
    $urlHost = try { ([Uri]"$($Definition.downloadUrl)").Host.ToLowerInvariant() } catch { '' }
    foreach ($k in $script:KnownPublishers) {
        $byName = $pubKey -and @($k.Names | Where-Object { (ConvertTo-PublisherKey $_) -eq $pubKey }).Count
        $byHost = $urlHost -and @($k.Domains | Where-Object { $urlHost -eq $_ -or $urlHost.EndsWith(".$_") }).Count
        if ($byName -or $byHost) { foreach ($n in $k.Names) { if (-not $names.Contains($n)) { $names.Add($n) } } }
    }
    $names.ToArray()
}

function Get-SignerName {
    # The O= (else CN=) name of an Authenticode signer subject, for short messages.
    param([string]$Subject)
    foreach ($f in 'O', 'CN') {
        $m = [regex]::Match("$Subject", "(?:^|,)\s*$f=(`"([^`"]*)`"|[^,]*)")
        if ($m.Success) { return $(if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[1].Value }).Trim() }
    }
    "$Subject"
}

function Test-AppSignerMatch {
    # Whether an Authenticode signer subject ('CN=Google LLC, O=Google LLC, L=Mountain View, ...') is one of the
    # -Publisher names: its CN or O is that name, ignoring case, quotes, a trailing dot and legal endings (Inc, LLC...).
    param([string]$Subject, [string[]]$Publisher)
    $want = @($Publisher | ForEach-Object { ConvertTo-PublisherKey $_ } | Where-Object { $_ })
    if (-not $want.Count -or -not $Subject) { return $false }
    foreach ($m in [regex]::Matches($Subject, '(?:^|,)\s*(?:CN|O)=("([^"]*)"|[^,]*)')) {
        $v = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[1].Value }
        if ((ConvertTo-PublisherKey $v) -in $want) { return $true }
    }
    $false
}

function Test-AppDownloadFile {
    <#
    .SYNOPSIS
        Checks a downloaded installer against the pack's downloadSha256. Returns '' when it is fine, else why not.
        Publishers update the file behind a "latest" link (Chrome, Office's setup.exe), so the SHA256 saved from the
        winget catalog goes stale: a file with another SHA256 is still taken when it has a valid Authenticode
        signature from the pack's publisher (Get-AppExpectedSigners), and the log says so.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Signature, [scriptblock]$Log = { param($m) })
    $d = $Definition
    if (-not $d.downloadSha256) { return '' }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -eq $d.downloadSha256.ToUpperInvariant()) { return '' }
    $sig = try { & $Signature $Path } catch { [pscustomobject]@{ Status = "unreadable ($($_.Exception.Message))"; Subject = '' } }
    $expected = @(Get-AppExpectedSigners -Definition $d)
    if ($sig.Status -eq 'Valid' -and (Test-AppSignerMatch -Subject $sig.Subject -Publisher $expected)) {
        & $Log "  New version from the publisher (SHA256 $hash, saved $($d.downloadSha256)); kept: signed by $(Get-SignerName $sig.Subject)"
        return ''
    }
    & $Log "  Download refused: SHA256 $hash, expected $($d.downloadSha256); signature $($sig.Status) $($sig.Subject); expected signer: $(if ($expected.Count) { $expected -join ' / ' } else { 'none known' })"
    if ($sig.Status -ne 'Valid') { return "download refused: the file changed and its signature is $($sig.Status)" }
    "download refused: the file changed and is signed by $(Get-SignerName $sig.Subject), not $(if ($expected.Count) { $expected[0] } else { 'a known publisher' })"
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

#region Office offline source

function Test-OfficeDeploymentCommand {
    # Whether an application runs the Office Deployment Tool (setup.exe /configure <file>.xml).
    param([Parameter(Mandatory)]$Definition)
    [regex]::IsMatch("$($Definition.command)", '/configure\s+\S', 'IgnoreCase')
}

function Get-OfficeConfigPath {
    <#
    .SYNOPSIS
        For an Office Deployment Tool pack (command "setup.exe /configure <file>.xml"), the full path of its
        configuration file; '' for any other application or when the file is nowhere.
        The file in -AppFolder wins, by its name alone: a command written with a path on the console PC
        (C:\imager\Applications\Microsoft-Office\Configuration.xml) still finds the copy that travels with the pack.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$AppFolder)
    $m = [regex]::Match("$($Definition.command)", '/configure\s+(?:"([^"]+)"|(\S+))', 'IgnoreCase')
    if (-not $m.Success) { return '' }
    $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
    $leaf = @($name -split '[\\/]')[-1]
    if ([IO.Directory]::Exists($AppFolder)) {
        $local = @([IO.Directory]::GetFiles($AppFolder) | Where-Object { [IO.Path]::GetFileName($_) -ieq $leaf })
        if ($local) { return $local[0] }
    }
    if ([IO.Path]::IsPathRooted($name) -and [IO.File]::Exists($name)) { return $name }
    ''
}

function New-OfficeDeployConfig {
    <#
    .SYNOPSIS
        On the PC, just before Office installs: writes configuration-deploy.xml next to setup.exe from the pack's
        configuration and returns the command to run, "<setup.exe>" /configure "configuration-deploy.xml".
        - Display Level None and AcceptEULA: with any window the Office Deployment Tool waits forever for a click
          nobody can see (first boot runs as SYSTEM, behind the logon screen).
        - The Office files next to setup.exe (Office\Data, from Update-OfficeSource) are the source, with the
          internet as a fallback; a SourcePath that this PC can't reach is dropped, so Office comes from the internet.
        Returns Command and Notes (what was changed, for the log). Throws when the configuration file is missing.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$AppFolder)
    $config = Get-OfficeConfigPath -Definition $Definition -AppFolder $AppFolder
    if (-not $config) {
        $m = [regex]::Match("$($Definition.command)", '/configure\s+(?:"([^"]+)"|(\S+))', 'IgnoreCase')
        throw "the Office configuration file ($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })) is not in the application's folder; put configuration.xml next to setup.exe"
    }
    [xml]$xml = [IO.File]::ReadAllText($config)
    $root = $xml.SelectSingleNode('/Configuration')
    if (-not $root) { throw "$([IO.Path]::GetFileName($config)) is not an Office Deployment Tool configuration (no <Configuration>)." }
    $notes = @()
    $display = $xml.SelectSingleNode('/Configuration/Display')
    if (-not $display) { $display = $root.AppendChild($xml.CreateElement('Display')) }
    if ($display.GetAttribute('Level') -ne 'None' -or $display.GetAttribute('AcceptEULA') -ne 'TRUE') { $notes += 'silent (Display Level None, AcceptEULA)' }
    $display.SetAttribute('Level', 'None'); $display.SetAttribute('AcceptEULA', 'TRUE')
    # Office's own log next to FirstBoot.log. A Logging Path from the console PC (a folder this PC doesn't have) makes
    # setup.exe stop at once with "The directory name is invalid" (exit 1).
    $logging = $xml.SelectSingleNode('/Configuration/Logging')
    if (-not $logging) { $logging = $root.AppendChild($xml.CreateElement('Logging')) }
    $oldLog = $logging.GetAttribute('Path').Trim()
    $logDir = [IO.Path]::Combine($env:WINDIR, 'Temp')
    if ($oldLog -and -not [IO.Directory]::Exists([Environment]::ExpandEnvironmentVariables($oldLog))) { $notes += "Logging Path $oldLog not on this PC" }
    $logging.SetAttribute('Level', 'Standard'); $logging.SetAttribute('Path', $logDir)
    $local = Get-OfficeSourceVersion -AppFolder $AppFolder
    foreach ($add in @($xml.SelectNodes('/Configuration/Add'))) {
        if ($add.HasAttribute('DownloadPath')) { $add.RemoveAttribute('DownloadPath'); $notes += 'DownloadPath dropped' }
        $src = $add.GetAttribute('SourcePath').Trim()
        if ($local) {
            $add.SetAttribute('SourcePath', $AppFolder); $add.SetAttribute('AllowCdnFallback', 'TRUE')
        } elseif ($src -and $src -notin '.', '.\', './' -and -not [IO.Directory]::Exists($src)) {
            $add.RemoveAttribute('SourcePath'); $add.SetAttribute('AllowCdnFallback', 'TRUE')
            $notes += "SourcePath $src not reachable here, so from the internet"
        }
    }
    $notes = @($(if ($local) { "Office $local files from this folder" } else { 'no Office files in this folder, so from the internet' })) + $notes
    $notes += "Office log in $logDir"
    $out = [IO.Path]::Combine($AppFolder, 'configuration-deploy.xml')
    $xml.Save($out)
    [pscustomobject]@{ Command = "`"$($Definition.installer)`" /configure `"configuration-deploy.xml`""; Notes = $notes }
}

function Get-OfficeSourceVersion {
    # The newest Office version folder (Office\Data\16.0.x.y) in an app folder, or $null.
    param([Parameter(Mandatory)][string]$AppFolder)
    $data = [IO.Path]::Combine($AppFolder, 'Office', 'Data')
    if (-not [IO.Directory]::Exists($data)) { return $null }
    $versions = @(foreach ($d in [IO.Directory]::GetDirectories($data)) {
        $v = $null
        if ([version]::TryParse([IO.Path]::GetFileName($d), [ref]$v)) { $v }
    })
    if ($versions) { ($versions | Sort-Object -Descending)[0] } else { $null }
}

function Remove-OldOfficeSource {
    # Office\Data keeps every version /download ever fetched: only the newest folder and its cabs are kept,
    # so the stick and each deploy copy one version (about 2-3 GB), not all of them.
    param([Parameter(Mandatory)][string]$AppFolder, [scriptblock]$Log = { param($m) })
    $keep = Get-OfficeSourceVersion -AppFolder $AppFolder
    if (-not $keep) { return }
    $data = [IO.Path]::Combine($AppFolder, 'Office', 'Data')
    foreach ($d in [IO.Directory]::GetDirectories($data)) {
        $v = $null
        if ([version]::TryParse([IO.Path]::GetFileName($d), [ref]$v) -and $v -ne $keep) {
            & $Log "  Removing the older Office files $v"
            [IO.Directory]::Delete($d, $true)
        }
    }
    foreach ($f in [IO.Directory]::GetFiles($data, 'v*_*.cab')) {
        $m = [regex]::Match([IO.Path]::GetFileName($f), '^v(?:32|64)_(\d+(?:\.\d+){3})\.cab$')
        if ($m.Success -and [version]$m.Groups[1].Value -ne $keep) { [IO.File]::Delete($f) }
    }
}

function Update-OfficeSource {
    <#
    .SYNOPSIS
        Puts the Office installation files next to setup.exe in an Office Deployment Tool pack (setup.exe /download
        on this PC), so each deployed PC installs Office from its own copy instead of downloading 2-3 GB from
        Microsoft at first boot, the step that failed most. With no SourcePath in configuration.xml the Office
        Deployment Tool takes the files next to setup.exe, and goes to the internet only when they aren't there.
        Skipped while the files are newer than -MaxAgeDays and configuration.xml is unchanged.
        Returns Status (NotOffice, OwnSource, Fresh, Downloaded), Version and Message. Throws when the download fails.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$AppFolder,
        [int]$MaxAgeDays = 14,
        [int]$TimeoutMinutes = 120,
        [scriptblock]$Log = { param($m) Write-Host $m },
        [string]$LogPath,
        # Tests pass their own; the default runs setup.exe /download (Invoke-PackProcess).
        [scriptblock]$Runner,
        [scriptblock]$Downloader
    )
    $out = { param($s, $v, $msg) [pscustomobject]@{ Status = $s; Version = $v; Message = $msg } }
    $d = $Definition
    $config = Get-OfficeConfigPath -Definition $d -AppFolder $AppFolder
    if (-not $config) { return & $out 'NotOffice' $null '' }
    [xml]$xml = [IO.File]::ReadAllText($config)
    $add = $xml.SelectSingleNode('/Configuration/Add')
    if (-not $add) { throw "$([IO.Path]::GetFileName($config)) has no <Add> element." }
    $own = $add.GetAttribute('SourcePath').Trim()
    # A file server (\\server\office) is the admin's own choice and every PC reaches it; a drive path
    # (C:\imager\...) only exists on the console PC, so the files are downloaded into the pack all the same.
    if ($own -and $own.StartsWith('\\') -and [IO.Directory]::Exists($own)) {
        return & $out 'OwnSource' $null "configuration.xml installs from $own; left as is"
    }
    $configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
    $markerPath = [IO.Path]::Combine($AppFolder, 'office-source.json')
    $have = Get-OfficeSourceVersion -AppFolder $AppFolder
    if ($have -and [IO.File]::Exists($markerPath)) {
        $marker = try { [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json } catch { $null }
        $age = if ($marker -and $marker.downloaded) { ((Get-Date) - [datetime]$marker.downloaded).TotalDays } else { [double]::MaxValue }
        if ($marker -and $marker.configSha256 -eq $configHash -and $age -lt $MaxAgeDays) {
            return & $out 'Fresh' $have ("Office $have files already there (downloaded {0:N0} day(s) ago)" -f $age)
        }
    }

    # setup.exe itself (the Office Deployment Tool), from the pack's download link when it isn't in the folder.
    if ($d.downloadUrl) {
        $dlArgs = @{ Definition = $d; AppFolder = $AppFolder; Log = $Log; Attempts = 3; WaitSeconds = 10 }
        if ($Downloader) { $dlArgs.Downloader = $Downloader }
        Get-AppDownload @dlArgs
    }
    $setup = [IO.Path]::Combine($AppFolder, $d.installer)
    if (-not [IO.File]::Exists($setup)) { throw "$($d.installer) (Office Deployment Tool) is not in $AppFolder." }

    # The download uses a copy of configuration.xml pointing at this folder (a network share works too); the
    # pack's own file keeps no SourcePath, so on the PC it reads the files next to setup.exe wherever it is copied.
    $add.SetAttribute('SourcePath', $AppFolder)
    $tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "office-download-$([guid]::NewGuid().ToString('N').Substring(0, 8)).xml")
    $xml.Save($tmp)
    if (-not $LogPath) { $LogPath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'Office-download.log') }
    & $Log "  Downloading the Office files into $AppFolder (2-3 GB, can take a while)"
    try {
        $run = if ($Runner) { & $Runner $setup "/download `"$tmp`"" $AppFolder }
               else { Invoke-PackProcess -FilePath $setup -Arguments "/download `"$tmp`"" -WorkingDirectory $AppFolder -TimeoutMinutes $TimeoutMinutes -LogPath $LogPath -Log $Log }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($run.TimedOut) { throw "the Office download was still running after $TimeoutMinutes minutes" }
    if ($run.ExitCode -ne 0) { throw "setup.exe /download ended with exit code $($run.ExitCode)$(if ($run.LastLine) { ": $($run.LastLine)" })" }
    $version = Get-OfficeSourceVersion -AppFolder $AppFolder
    if (-not $version) { throw "setup.exe /download ended with exit 0 but there is no Office\Data folder in $AppFolder" }
    Remove-OldOfficeSource -AppFolder $AppFolder -Log $Log
    [IO.File]::WriteAllText($markerPath, ([ordered]@{ downloaded = (Get-Date).ToString('o'); version = "$version"; configSha256 = $configHash } | ConvertTo-Json))
    & $Log "  Office $version files are ready in $AppFolder"
    & $out 'Downloaded' $version "Office $version files downloaded"
}

function Update-OfficeSources {
    <#
    .SYNOPSIS
        Update-OfficeSource for every Office Deployment Tool pack in -AppRoot (only -Names when given).
        A failure only warns: that PC then downloads Office from Microsoft at first boot, as before.
        Returns one row per Office pack: Name, Status, Version, Message.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string[]]$Names,
        [scriptblock]$Log = { param($m) Write-Host $m },
        [scriptblock]$OnApp,
        [scriptblock]$Runner,
        [scriptblock]$Downloader
    )
    if (-not [IO.Directory]::Exists($AppRoot)) { return @() }
    $folders = @([IO.Directory]::GetDirectories($AppRoot) | Where-Object {
        (-not $Names -or $Names -contains [IO.Path]::GetFileName($_)) -and [IO.File]::Exists([IO.Path]::Combine($_, 'app.json'))
    })
    $office = @(foreach ($f in $folders) {
        $name = [IO.Path]::GetFileName($f)
        $def = try { Read-AppPack -AppRoot $AppRoot -Name $name } catch { $null }
        if ($def -and (Get-OfficeConfigPath -Definition $def -AppFolder $f)) { [pscustomobject]@{ Name = $name; Folder = $f; Definition = $def } }
    })
    $i = 0
    @(foreach ($o in $office) {
        $i++
        if ($OnApp) { & $OnApp $o.Name $i $office.Count }
        $a = @{ Definition = $o.Definition; AppFolder = $o.Folder; Log = $Log }
        if ($Runner) { $a.Runner = $Runner }
        if ($Downloader) { $a.Downloader = $Downloader }
        try {
            $r = Update-OfficeSource @a
            & $Log "  $($o.Name): $($r.Message)"
            [pscustomobject]@{ Name = $o.Name; Status = $r.Status; Version = $r.Version; Message = $r.Message }
        } catch {
            & $Log "  $($o.Name): Office files not downloaded ($($_.Exception.Message)); the PC downloads Office from Microsoft at first boot"
            [pscustomobject]@{ Name = $o.Name; Status = 'Failed'; Version = $null; Message = $_.Exception.Message }
        }
    })
}

#endregion

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

function Update-MsiDetectionRule {
    # Points the pack's one MSI product code rule at -ProductCode (the downloaded MSI's), when they differ.
    # A pack with several MSI rules (a suite) is left as it is.
    param([Parameter(Mandatory)]$Definition, [string]$ProductCode, [scriptblock]$Log = { param($m) })
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { return }
    $rules = @($Definition.detection.rules | Where-Object { $_.type -eq 'msi' })
    if ($rules.Count -ne 1 -or $rules[0].target -eq $ProductCode) { return }
    & $Log "  Detection: the downloaded MSI is $ProductCode (the pack had $($rules[0].target))"
    $rules[0].target = $ProductCode
}

function Invoke-AppInstall {
    <#
    .SYNOPSIS
        Installs one application on this PC: skips it when already detected, runs the command with a timeout,
        then checks the detection rules again; the installer's output goes to -LogPath, as a task's does.
        Returns @{ Status; ExitCode; RebootNeeded; Message }.
        Status is Installed, AlreadyInstalled, Failed or TimedOut.
    #>
    param(
        [Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$AppFolder, [scriptblock]$Log = { param($m) Write-Host $m },
        [string]$LogPath,   # the installer's own output; default App-<name>.log in TEMP
        [int]$IdleMinutes = 5
    )
    $d = $Definition
    $out = { param($s, $code, $reboot, $msg) [pscustomobject]@{ Status = $s; ExitCode = $code; RebootNeeded = [bool]$reboot; Message = $msg } }

    $before = Test-AppDetection -Definition $d -AppFolder $AppFolder
    if ($before.HasRules -and $before.Detected -and $d.skipIfDetected) {
        return & $out 'AlreadyInstalled' $null $false "already installed ($(($before.Details | ForEach-Object Detail) -join '; '))"
    }
    if ($d.downloadUrl) {
        try { Get-AppDownload -Definition $d -AppFolder $AppFolder -Log $Log }
        catch { return & $out 'Failed' $null $false "download failed: $($_.Exception.Message)" }
        # A "latest" MSI link (Chrome) brings a new product code with every version: detect the MSI that came down.
        $msi = [IO.Path]::Combine($AppFolder, "$($d.installer)")
        if ($msi -like '*.msi' -and [IO.File]::Exists($msi)) {
            $code = try { (Get-MsiProperties -Path $msi).ProductCode } catch { $null }
            Update-MsiDetectionRule -Definition $d -ProductCode $code -Log $Log
        }
    }

    $command = $d.command
    $odt = $null
    if (Test-OfficeDeploymentCommand -Definition $d) {
        # Office Deployment Tool: the pack's configuration, made silent, from the Office files in the folder.
        try { $odt = New-OfficeDeployConfig -Definition $d -AppFolder $AppFolder }
        catch { return & $out 'Failed' $null $false $_.Exception.Message }
        $command = $odt.Command
        & $Log "  Office: $($odt.Notes -join '; ')"
    }
    if (-not $LogPath) { $LogPath = Join-Path ([IO.Path]::GetTempPath()) "App-$($d.name).log" }
    # Office takes 10-20 minutes from local files, longer from the internet: never less than an hour for it.
    $timeout = if ($odt) { [Math]::Max(60, [int]$d.timeoutMinutes) } else { $d.timeoutMinutes }
    # An installer that shows a window and does nothing for 5 minutes waits for a click: stopped then, not after the
    # whole timeout (first boot holds the PC on "Please wait" meanwhile). Office's setup is left to its timeout.
    $idle = if ($odt) { 0 } else { $IdleMinutes * 60 }
    $run = Invoke-PackProcess -FilePath 'cmd.exe' -Arguments "/c $command" -WorkingDirectory $AppFolder -TimeoutMinutes $timeout -LogPath $LogPath -Log $Log -IdleSeconds $idle
    $tail = if ($run.LastLine) { "; last line: $($run.LastLine)" } else { '' }
    if ($run.Stuck) { return & $out 'TimedOut' $null $false "stuck on a window for $IdleMinutes minutes (wrong silent switch?); stopped" }
    if ($run.TimedOut) { return & $out 'TimedOut' $null $false "still running after $timeout minutes; stopped$tail" }
    $code = $run.ExitCode
    if ($d.successCodes -notcontains $code) { return & $out 'Failed' $code $false "exit code $code is not a success code ($($d.successCodes -join ', '))$tail" }
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

#region Installing again after first boot

function Invoke-AppReinstall {
    <#
    .SYNOPSIS
        PC: installs applications again after first boot, each the way first boot does (Invoke-AppInstall): the logon
        retry (Retry-FailedApps.ps1) and the agent's Retry failed apps. -AppRoot holds a folder per app; -Definitions
        (name -> app.json fields) when the packs' app.json is not there. -OnApp runs before each one.
        Returns { name, ok, status, message } per app.
    #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string[]]$Names, [hashtable]$Definitions = @{},
          [string]$LogFolder = "$env:WINDIR\Temp", [scriptblock]$Log = { param($m) }, [scriptblock]$OnApp = { param($n) })
    foreach ($name in @($Names | Where-Object { $_ })) {
        & $OnApp $name
        $r = try {
            $app = if ($Definitions.ContainsKey($name)) { ConvertTo-AppDefinition -Name $name -Json $Definitions[$name] } else { Read-AppPack -AppRoot $AppRoot -Name $name }
            Invoke-AppInstall -Definition $app -AppFolder ([IO.Path]::Combine($AppRoot, $name)) -LogPath ([IO.Path]::Combine($LogFolder, "App-$name.log")) -Log $Log
        } catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; RebootNeeded = $false; Message = $_.Exception.Message } }
        $ok = $r.Status -in 'Installed', 'AlreadyInstalled'
        & $Log "  $name $(if ($ok) { 'OK' } else { 'FAILED' }) ($($r.Status)): $($r.Message)"
        [pscustomobject]@{ name = $name; ok = $ok; status = "$($r.Status)"; message = "$($r.Message)" }
    }
}

function Enter-AppInstallLock {
    <#
    .SYNOPSIS
        PC: one install at a time between the logon retry and the agent's Retry failed apps (two installers at once
        fail with 1618). Waits up to -Minutes; returns the mutex to release, or $null when the other one still runs.
    #>
    param([int]$Minutes = 30)
    $m = New-Object Threading.Mutex($false, 'Global\ImagingToolAppInstall')
    try { if ($m.WaitOne([timespan]::FromMinutes($Minutes))) { return $m } } catch [Threading.AbandonedMutexException] { return $m }
    $m.Dispose()
    $null
}

function Exit-AppInstallLock($Lock) {
    if ($Lock) { try { $Lock.ReleaseMutex() } catch { }; try { $Lock.Dispose() } catch { } }
}

function Get-AppRetryFolder {
    # Where first boot keeps the failed apps' packs and retry.json (administrators and SYSTEM only).
    [IO.Path]::Combine([Environment]::GetFolderPath('CommonApplicationData'), 'ImagingTool\RetryApps')
}

function Invoke-AppRetryPlan {
    <#
    .SYNOPSIS
        PC: the one way the applications that failed at first boot are installed again, silently as SYSTEM. The agent
        runs it at its check-ins (-MinMinutes 60: an hour after first boot, then hourly); a PC without the agent
        (deployed without a network share) runs it from the logon task ImagingTool\RetryApps (Retry-FailedApps.ps1).
        Each run is one attempt of retry.json's maxAttempts; once every app is in, or out of attempts, the logon task
        and the folder go. -OnResults gets the plan and the results (DeployResult.txt and the Dashboard:
        Publish-AppRetryResults). Never two installs at once (Enter-AppInstallLock). Returns
        { Ran, Left, Results, Message }.
    #>
    param(
        [string]$Dir = (Get-AppRetryFolder),
        [string]$By = 'the logon retry',
        [int]$WaitMinutes = 30,
        [int]$MinMinutes = 0,
        [scriptblock]$OnResults = { param($Plan, $Results) },
        [scriptblock]$Log = { param($m) },
        [scriptblock]$RemoveTask = { & schtasks.exe /Delete /TN 'ImagingTool\RetryApps' /F 2>&1 | Out-Null },
        [scriptblock]$RemoveFolder,     # default: delete it now (the logon script deletes itself a moment after it ends)
        [datetime]$Now = (Get-Date)
    )
    $out = { param($ran, $left, $results, $msg) [pscustomobject]@{ Ran = $ran; Left = @($left); Results = @($results); Message = $msg } }
    $planPath = [IO.Path]::Combine($Dir, 'retry.json')
    if (-not [IO.File]::Exists($planPath)) { return & $out $false @() @() 'no applications to install again' }
    $lock = Enter-AppInstallLock -Minutes $WaitMinutes
    if (-not $lock) { return & $out $false @() @() 'another application install is still running' }
    try {
        # The other one may have installed them all while this waited.
        if (-not [IO.File]::Exists($planPath)) { return & $out $false @() @() 'no applications to install again' }
        $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
        $last = $null
        foreach ($n in 'lastAttempt', 'created') { if (-not $last -and $plan.PSObject.Properties[$n] -and $plan.$n) { $last = try { [datetime]::Parse("$($plan.$n)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $null } } }
        if ($MinMinutes -gt 0 -and $last -and ($Now - $last.ToLocalTime()).TotalMinutes -lt $MinMinutes) {
            return & $out $false @($plan.apps | ForEach-Object { "$($_.name)" }) @() 'not yet: tried less than an hour ago'
        }
        $plan.attempts = [int]$plan.attempts + 1
        $plan | Add-Member -NotePropertyName lastAttempt -NotePropertyValue $Now.ToUniversalTime().ToString('o') -Force
        [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
        $names = @($plan.apps | ForEach-Object { "$($_.name)" })
        & $Log "Retry $($plan.attempts) of $($plan.maxAttempts) by ${By}: installing $($names -join ', ') again"
        $defs = @{}
        foreach ($a in @($plan.apps)) { $defs["$($a.name)"] = $a }
        $results = @(Invoke-AppReinstall -AppRoot ([IO.Path]::Combine($Dir, 'Apps')) -Names $names -Definitions $defs -Log $Log)
        try { & $OnResults $plan $results } catch { & $Log "Could not report the results: $($_.Exception.Message)" }
        $left = @($plan.apps | Where-Object { $n = "$($_.name)"; @($results | Where-Object { $_.name -eq $n -and -not $_.ok }).Count })
        $plan.apps = @($left)
        [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
        $leftNames = @($left | ForEach-Object { "$($_.name)" })
        $msg = if (-not $left) { 'Every application is installed now' }
               elseif ($plan.attempts -ge [int]$plan.maxAttempts) { "Giving up after $($plan.attempts) tries: $($leftNames -join ', ') still not installed" }
               else { "Trying $($leftNames -join ', ') again later" }
        & $Log $msg
        if (-not $left -or $plan.attempts -ge [int]$plan.maxAttempts) {
            try { & $RemoveTask } catch { }
            if ($RemoveFolder) { & $RemoveFolder } else { try { [IO.Directory]::Delete($Dir, $true) } catch { } }
        }
        & $out $true $leftNames $results $msg
    } finally { Exit-AppInstallLock $lock }
}

function Remove-AppRetry {
    <#
    .SYNOPSIS
        PC: takes applications that are installed now (the agent's Retry failed apps) out of the logon retry
        (C:\ProgramData\ImagingTool\RetryApps\retry.json), so they are not installed again at the next logon. With
        none left, the logon task ImagingTool\RetryApps and its folder go. Returns the apps still waiting there.
    #>
    param([string[]]$Names = @(), [string]$Dir = (Get-AppRetryFolder),
          [scriptblock]$RemoveTask = { & schtasks.exe /Delete /TN 'ImagingTool\RetryApps' /F 2>&1 | Out-Null })
    $planPath = [IO.Path]::Combine($Dir, 'retry.json')
    if (-not [IO.File]::Exists($planPath)) { return @() }
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    $left = @(@($plan.apps) | Where-Object { $_ -and @($Names) -notcontains "$($_.name)" })
    if ($left.Count -eq @(@($plan.apps) | Where-Object { $_ }).Count) { return @($left | ForEach-Object { "$($_.name)" }) }
    if (-not $left) {
        try { & $RemoveTask } catch { }
        try { [IO.Directory]::Delete($Dir, $true) } catch { }
        return @()
    }
    $plan.apps = @($left)
    [IO.File]::WriteAllText($planPath, (ConvertTo-Json -InputObject $plan -Depth 8), (New-Object Text.UTF8Encoding $true))
    @($left | ForEach-Object { "$($_.name)" })
}

#endregion

Export-ModuleMember -Function ConvertTo-AppDefinition, ConvertTo-DetectionRule, Read-AppPack, ConvertTo-AppJson, Test-AppPack,
    Find-InstallerFramework, Get-SilentInstallCommand, Get-InstallerTypeNote, Get-InstallerInfo, Get-MsiProperties, Get-MsixIdentity,
    Get-AppTemplates, Copy-AppTemplateFiles,
    ConvertFrom-WingetSearch, Remove-ConsoleControl, Get-WingetSearchFailure, Find-WingetPackage, Get-WingetManifestUrl, ConvertFrom-WingetInstallerYaml, Select-WingetInstaller,
    New-AppDefinitionFromWinget, New-AppFromWinget, Find-AppTemplate, New-AppDefinitionFromTemplate, Get-AppDownload, Get-HttpErrorStatus, Test-AppDownloadFile, Test-AppSignerMatch, Get-AppExpectedSigners,
    Get-MediaAppDownloads, Add-MediaCopyItems, Test-OfficeDeploymentCommand, Get-OfficeConfigPath, New-OfficeDeployConfig, Get-OfficeSourceVersion, Remove-OldOfficeSource, Update-OfficeSource, Update-OfficeSources,
    Save-AppPack,
    Compare-AppVersion, Get-UninstallEntries, Test-DetectionRule, Test-AppDetection, Update-MsiDetectionRule, Invoke-AppInstall,
    Invoke-AppReinstall, Enter-AppInstallLock, Exit-AppInstallLock, Remove-AppRetry, Get-AppRetryFolder, Invoke-AppRetryPlan
