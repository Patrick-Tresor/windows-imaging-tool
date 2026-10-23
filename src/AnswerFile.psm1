# Answer files: one XML per deployment profile (image, apps, disk, regional settings, naming,
# domain join, tasks, shares), modelled on SmartDeploy's deploy wizard answer files.
# Used by Deploy-Image.ps1 in WinPE and by the admin console. PowerShell 5.1 compatible.

$script:Phases = 'POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON'

function Get-XmlText {
    # Inner text of the first node matching an XPath, trimmed; $Default when missing or empty.
    param($Node, [string]$XPath, $Default = $null)
    $n = $Node.SelectSingleNode($XPath)
    if (-not $n) { return $Default }
    # PowerShell's XML adapter hides InnerText on attributes, so read .Value for those.
    $v = if ($n -is [Xml.XmlAttribute]) { $n.Value } else { $n.InnerText }
    if ("$v".Trim()) { "$v".Trim() } else { $Default }
}

function ConvertTo-Bool([string]$Value, [bool]$Default) {
    if (-not $Value) { return $Default }
    $Value -in 'true', '1', 'yes'
}

function Read-AnswerFile {
    <#
    .SYNOPSIS
        Parses an answer file into a flat object and validates it. Throws one error listing every problem.
    #>
    param([Parameter(Mandatory)][string]$Path, [switch]$SkipValidation)

    [xml]$xml = Get-Content -Raw -Path $Path
    $d = $xml.SelectSingleNode('/deployment')
    if (-not $d) { throw "$Path is not an answer file (no <deployment> root)." }

    $a = [pscustomobject]@{
        Name                 = [IO.Path]::GetFileNameWithoutExtension($Path)
        Path                 = $Path
        Mode                 = Get-XmlText $d 'mode' 'Interactive'
        UnattendDelay        = [int](Get-XmlText $d 'unattendDelay' '10')
        ImageFile            = Get-XmlText $d 'image/file'
        ImageIndex           = [int](Get-XmlText $d 'image/index' '1')
        DiskNumber           = [int](Get-XmlText $d 'disk/number' '0')
        DiskOption           = Get-XmlText $d 'disk/option' 'Recreate'
        DriverRoot           = Get-XmlText $d 'drivers/root' 'Drivers'
        AppLocation          = Get-XmlText $d 'applications/@location' 'Applications'
        Applications         = @()
        ProductKey           = Get-XmlText $d 'productKey'
        FullName             = Get-XmlText $d 'userInformation/fullName'
        Organization         = Get-XmlText $d 'userInformation/organization'
        TimeZone             = Get-XmlText $d 'regional/timeZone'
        InputLocale          = Get-XmlText $d 'regional/inputLocale'
        SystemLocale         = Get-XmlText $d 'regional/systemLocale'
        UILanguage           = Get-XmlText $d 'regional/uiLanguage'
        UserLocale           = Get-XmlText $d 'regional/userLocale'
        NamingMode           = Get-XmlText $d 'identification/naming/@mode' 'WMI'
        WmiQuery             = Get-XmlText $d 'identification/naming/wmiQuery' 'SELECT SerialNumber FROM Win32_BIOS'
        CustomScheme         = Get-XmlText $d 'identification/naming/customScheme'
        Prefix               = Get-XmlText $d 'identification/naming/prefix' ''
        Membership           = Get-XmlText $d 'network/membership' 'Workgroup'
        Domain               = Get-XmlText $d 'network/domain'
        OrganizationalUnit   = Get-XmlText $d 'network/organizationalUnit'
        Workgroup            = Get-XmlText $d 'network/workgroup' 'WORKGROUP'
        JoinUser             = Get-XmlText $d 'network/joinCredentials/username'
        JoinDomain           = Get-XmlText $d 'network/joinCredentials/domain'
        JoinPasswordFile     = Get-XmlText $d 'network/joinCredentials/passwordFile'
        EnableAdministrator  = ConvertTo-Bool (Get-XmlText $d 'options/enableAdministrator') $false
        AdminPasswordFile    = Get-XmlText $d 'options/administratorPasswordFile'
        DisableSystemRestore = ConvertTo-Bool (Get-XmlText $d 'options/disableSystemRestore') $false
        Tasks                = @()
        Shares               = @()
        Reboot               = ConvertTo-Bool (Get-XmlText $d 'completion/reboot') $true
        Shutdown             = ConvertTo-Bool (Get-XmlText $d 'completion/shutdown') $false
    }

    $a.Applications = @($d.SelectNodes('applications/application') |
        Sort-Object { [int]$_.GetAttribute('order') } |
        ForEach-Object { "$($_.InnerText)".Trim() } | Where-Object { $_ })
    $a.Tasks = @($d.SelectNodes('tasks/task') | ForEach-Object {
        [pscustomobject]@{ Phase = $_.GetAttribute('phase').ToUpperInvariant(); Command = "$($_.InnerText)".Trim() }
    })
    $a.Shares = @($d.SelectNodes('shares/share') | ForEach-Object {
        [pscustomobject]@{
            LocalName    = Get-XmlText $_ 'localName'
            RemoteName   = Get-XmlText $_ 'remoteName'
            Username     = Get-XmlText $_ 'username'
            Domain       = Get-XmlText $_ 'domain'
            PasswordFile = Get-XmlText $_ 'passwordFile'
        }
    })

    if ($SkipValidation) { return $a }
    $problems = @(Test-AnswerFile $a)
    if ($problems) { throw "Answer file $($a.Name) has problems:`n - " + ($problems -join "`n - ") }
    $a
}

function Test-AnswerFile {
    # Returns a list of problems; empty when the answer file can be deployed.
    param([Parameter(Mandatory)]$Answer)
    $a = $Answer
    if ($a.Mode -notin 'Interactive', 'Unattended') { "mode must be Interactive or Unattended, not '$($a.Mode)'." }
    if (-not $a.ImageFile) { 'image/file is required.' }
    if ($a.ImageIndex -lt 1) { 'image/index must be 1 or more.' }
    if ($a.DiskOption -ne 'Recreate') { "disk/option '$($a.DiskOption)' is not supported yet; only Recreate (wipe the disk and recreate partitions)." }
    if ($a.NamingMode -notin 'WMI', 'Custom', 'Prompt') { "identification/naming mode must be WMI, Custom or Prompt, not '$($a.NamingMode)'." }
    if ($a.NamingMode -eq 'Custom' -and -not $a.CustomScheme) { 'Custom naming needs identification/naming/customScheme.' }
    if ($a.Membership -notin 'Domain', 'Workgroup') { "network/membership must be Domain or Workgroup, not '$($a.Membership)'." }
    if ($a.Membership -eq 'Domain') {
        if (-not $a.Domain) { 'Domain membership needs network/domain.' }
        if (-not $a.JoinUser -or -not $a.JoinPasswordFile) { 'Domain membership needs network/joinCredentials username and passwordFile.' }
    }
    if ($a.EnableAdministrator -and -not $a.AdminPasswordFile) { 'options/enableAdministrator needs options/administratorPasswordFile.' }
    foreach ($t in $a.Tasks) {
        if ($t.Phase -notin $script:Phases) { "Task phase '$($t.Phase)' must be one of $($script:Phases -join ', ')." }
        if (-not $t.Command) { "A $($t.Phase) task has no command." }
    }
    foreach ($s in $a.Shares) {
        if ($s.LocalName -notmatch '^[D-WY]:$') { "Share local name '$($s.LocalName)' must be a drive letter from D: to Y: (W: and X: are used by the deploy, Z: by the content share)." }
        if ($s.LocalName -eq 'W:') { "Share local name W: is used for the new Windows partition." }
        if ($s.RemoteName -notmatch '^\\\\[^\\]+\\.+') { "Share '$($s.RemoteName)' must be a \\server\share path." }
    }
    if ($a.Prefix -and $a.Prefix.Length -gt 14) { 'identification/naming/prefix is longer than a computer name allows.' }
}

function Resolve-ComputerName {
    <#
    .SYNOPSIS
        Builds the computer name: prefix + WMI value (WMI), or prefix + scheme (Custom) where # is a random
        digit and {SERIAL} the BIOS serial. Cleaned to letters, digits and dashes, cut to 15 characters.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [string]$WmiValue,          # result of the answer file's WMI query (Get-WmiNamingValue)
        [string]$Serial,
        [string]$Typed,             # operator's answer when NamingMode is Prompt
        [Random]$Random = [Random]::new()
    )
    $body = switch ($Answer.NamingMode) {
        'WMI'    { $WmiValue }
        'Custom' {
            $s = $Answer.CustomScheme -replace '\{SERIAL\}', $Serial
            -join ($s.ToCharArray() | ForEach-Object { if ($_ -eq '#') { $Random.Next(0, 10) } else { $_ } })
        }
        'Prompt' { if ($Typed) { $Typed } else { $WmiValue } }
    }
    $name = ("$($Answer.Prefix)$body" -replace '[^A-Za-z0-9-]', '').ToUpperInvariant()
    if (-not $name) { $name = "PC-$($Random.Next(100000, 999999))" }
    $name.Substring(0, [Math]::Min(15, $name.Length))
}

function Get-WmiNamingValue {
    # Runs the answer file's WMI query and returns the first property of the first result.
    param([Parameter(Mandatory)][string]$Query)
    $r = Get-CimInstance -Query $Query | Select-Object -First 1
    if (-not $r) { return $null }
    $prop = $r.CimInstanceProperties | Where-Object { $_.Value -and $_.Name -notlike 'PS*' } | Select-Object -First 1
    if ($prop) { "$($prop.Value)".Trim() }
}

function Read-SecretFile {
    # Passwords live in their own files under the content root (see docs), never in the answer file.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$RelativePath)
    $p = Join-Path $ContentRoot ($RelativePath -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $p)) { throw "Password file not found: $p" }
    (Get-Content -Raw $p).Trim()
}

function ConvertTo-XmlText([string]$Value) { [Security.SecurityElement]::Escape($Value) }

function New-UnattendXml {
    <#
    .SYNOPSIS
        Builds unattend.xml (specialize + oobeSystem) from an answer file. Passwords are passed in, already read.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$JoinPassword,
        [string]$AdminPassword
    )
    $a = $Answer
    $x = { param($v) ConvertTo-XmlText $v }
    $comp = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'

    $shell = @("      <ComputerName>$(& $x $ComputerName)</ComputerName>")
    if ($a.TimeZone)     { $shell += "      <TimeZone>$(& $x $a.TimeZone)</TimeZone>" }
    if ($a.FullName)     { $shell += "      <RegisteredOwner>$(& $x $a.FullName)</RegisteredOwner>" }
    if ($a.Organization) { $shell += "      <RegisteredOrganization>$(& $x $a.Organization)</RegisteredOrganization>" }
    if ($a.ProductKey)   { $shell += "      <ProductKey>$(& $x $a.ProductKey)</ProductKey>" }

    $join = if ($a.Membership -eq 'Domain') {
        $ou = if ($a.OrganizationalUnit) { "`n        <MachineObjectOU>$(& $x $a.OrganizationalUnit)</MachineObjectOU>" } else { '' }
        $credDomain = if ($a.JoinDomain) { $a.JoinDomain } else { $a.Domain }
        @"
    <component name="Microsoft-Windows-UnattendedJoin" $comp>
      <Identification>
        <Credentials>
          <Domain>$(& $x $credDomain)</Domain>
          <Username>$(& $x $a.JoinUser)</Username>
          <Password>$(& $x $JoinPassword)</Password>
        </Credentials>
        <JoinDomain>$(& $x $a.Domain)</JoinDomain>$ou
      </Identification>
    </component>
"@
    } else {
        @"
    <component name="Microsoft-Windows-UnattendedJoin" $comp>
      <Identification>
        <JoinWorkgroup>$(& $x $a.Workgroup)</JoinWorkgroup>
      </Identification>
    </component>
"@
    }

    $intl = @()
    foreach ($pair in @(@('InputLocale', $a.InputLocale), @('SystemLocale', $a.SystemLocale), @('UILanguage', $a.UILanguage), @('UserLocale', $a.UserLocale))) {
        if ($pair[1]) { $intl += "      <$($pair[0])>$(& $x $pair[1])</$($pair[0])>" }
    }
    $intlBlock = if ($intl) { "    <component name=`"Microsoft-Windows-International-Core`" $comp>`n$($intl -join "`n")`n    </component>`n" } else { '' }

    $accounts = ''
    if ($a.EnableAdministrator) {
        $accounts = @"
      <UserAccounts>
        <AdministratorPassword>
          <Value>$(& $x $AdminPassword)</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
"@
    }

    $logon = @($a.Tasks | Where-Object Phase -eq 'FIRSTLOGON')
    $logonBlock = ''
    if ($logon) {
        $i = 0
        $cmds = foreach ($t in $logon) {
            $i++
            "        <SynchronousCommand wcm:action=`"add`">`n          <Order>$i</Order>`n          <CommandLine>$(& $x $t.Command)</CommandLine>`n        </SynchronousCommand>"
        }
        $logonBlock = "      <FirstLogonCommands>`n$($cmds -join "`n")`n      </FirstLogonCommands>`n"
    }
    # Without a password for the built-in Administrator, OOBE has to ask for a local account.
    $hideLocal = if ($a.EnableAdministrator) { 'true' } else { 'false' }

    @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Generated by Deploy-Image.ps1 from answer file $(& $x $a.Name). -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $comp>
$($shell -join "`n")
    </component>
$join  </settings>
  <settings pass="oobeSystem">
$intlBlock    <component name="Microsoft-Windows-Shell-Setup" $comp>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <HideLocalAccountScreen>$hideLocal</HideLocalAccountScreen>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
$accounts$logonBlock    </component>
  </settings>
</unattend>
"@
}

function New-FirstBootPlan {
    # What FirstBoot.ps1 runs on the deployed PC (as SYSTEM, from SetupComplete.cmd): apps in order, then tasks.
    param([Parameter(Mandatory)]$Answer, [object[]]$AppDefinitions = @())
    [pscustomobject]@{
        answerFile           = $Answer.Name
        disableSystemRestore = $Answer.DisableSystemRestore
        enableAdministrator  = $Answer.EnableAdministrator
        applications         = @($AppDefinitions)
        tasks                = @($Answer.Tasks | Where-Object Phase -eq 'FIRSTBOOT' | ForEach-Object Command)
    }
}

function Get-AppDefinition {
    # Applications\<name>\app.json: { "command": "setup.exe /S", "successCodes": [0, 3010] }
    # Optional "detect": { "displayName": "Google Chrome*" } or { "path": "%ProgramFiles%\\App\\app.exe" },
    # which the post-deploy checks use to confirm the app is really installed.
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$Name)
    $json = Join-Path (Join-Path $AppRoot $Name) 'app.json'
    if (-not (Test-Path $json)) { throw "Application '$Name' has no app.json in $AppRoot\$Name." }
    $def = Get-Content -Raw $json | ConvertFrom-Json
    if (-not $def.command) { throw "Application '$Name': app.json has no command." }
    [pscustomobject]@{
        name         = $Name
        command      = $def.command
        successCodes = if ($def.successCodes) { @($def.successCodes | ForEach-Object { [int]$_ }) } else { @(0, 3010) }
        detect       = if ($def.PSObject.Properties['detect']) { $def.detect } else { $null }
    }
}

function Export-AnswerFile {
    <#
    .SYNOPSIS
        Writes an answer object (as returned by Read-AnswerFile) back to XML.
    #>
    param([Parameter(Mandatory)]$Answer, [Parameter(Mandatory)][string]$Path)
    $a = $Answer
    $x = { param($v) ConvertTo-XmlText "$v" }
    $b = { param([bool]$v) if ($v) { 'true' } else { 'false' } }
    $i = 0
    $apps = foreach ($n in $a.Applications) { $i++; "    <application order=`"$i`">$(& $x $n)</application>" }
    $tasks = foreach ($t in $a.Tasks) { "    <task phase=`"$($t.Phase)`">$(& $x $t.Command)</task>" }
    $shares = foreach ($s in $a.Shares) {
        @"
    <share>
      <localName>$(& $x $s.LocalName)</localName>
      <remoteName>$(& $x $s.RemoteName)</remoteName>
      <username>$(& $x $s.Username)</username>
      <domain>$(& $x $s.Domain)</domain>
      <passwordFile>$(& $x $s.PasswordFile)</passwordFile>
    </share>
"@
    }
    $text = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- Answer file. See config\answer-files\Default.xml in the repo for what each setting does. -->
<deployment version="1.0">
  <mode>$(& $x $a.Mode)</mode>
  <unattendDelay>$($a.UnattendDelay)</unattendDelay>
  <image>
    <file>$(& $x $a.ImageFile)</file>
    <index>$($a.ImageIndex)</index>
  </image>
  <disk>
    <number>$($a.DiskNumber)</number>
    <option>$(& $x $a.DiskOption)</option>
  </disk>
  <drivers>
    <root>$(& $x $a.DriverRoot)</root>
  </drivers>
  <applications location="$(& $x $a.AppLocation)">
$($apps -join "`n")
  </applications>
  <productKey>$(& $x $a.ProductKey)</productKey>
  <userInformation>
    <fullName>$(& $x $a.FullName)</fullName>
    <organization>$(& $x $a.Organization)</organization>
  </userInformation>
  <regional>
    <timeZone>$(& $x $a.TimeZone)</timeZone>
    <inputLocale>$(& $x $a.InputLocale)</inputLocale>
    <systemLocale>$(& $x $a.SystemLocale)</systemLocale>
    <uiLanguage>$(& $x $a.UILanguage)</uiLanguage>
    <userLocale>$(& $x $a.UserLocale)</userLocale>
  </regional>
  <identification>
    <naming mode="$(& $x $a.NamingMode)">
      <wmiQuery>$(& $x $a.WmiQuery)</wmiQuery>
      <customScheme>$(& $x $a.CustomScheme)</customScheme>
      <prefix>$(& $x $a.Prefix)</prefix>
    </naming>
  </identification>
  <network>
    <membership>$(& $x $a.Membership)</membership>
    <workgroup>$(& $x $a.Workgroup)</workgroup>
    <domain>$(& $x $a.Domain)</domain>
    <organizationalUnit>$(& $x $a.OrganizationalUnit)</organizationalUnit>
    <joinCredentials>
      <username>$(& $x $a.JoinUser)</username>
      <domain>$(& $x $a.JoinDomain)</domain>
      <passwordFile>$(& $x $a.JoinPasswordFile)</passwordFile>
    </joinCredentials>
  </network>
  <options>
    <disableSystemRestore>$(& $b $a.DisableSystemRestore)</disableSystemRestore>
    <enableAdministrator>$(& $b $a.EnableAdministrator)</enableAdministrator>
    <administratorPasswordFile>$(& $x $a.AdminPasswordFile)</administratorPasswordFile>
  </options>
  <tasks>
$($tasks -join "`n")
  </tasks>
  <shares>
$($shares -join "`n")
  </shares>
  <completion>
    <reboot>$(& $b $a.Reboot)</reboot>
    <shutdown>$(& $b $a.Shutdown)</shutdown>
  </completion>
</deployment>
"@
    # Drop the blank lines left by empty lists.
    ($text -split "`r?`n" | Where-Object { $_.Trim() }) -join "`r`n" | Set-Content -Path $Path -Encoding utf8
}

function ConvertTo-LocaleTag([string]$Value) {
    # SmartDeploy stores display names ("French (Canada)"); unattend wants tags (fr-CA).
    if (-not $Value) { return $null }
    if ($Value -match '^[a-z]{2,3}(-[A-Za-z0-9]+)+$') { return $Value }
    $c = [Globalization.CultureInfo]::GetCultures('SpecificCultures') | Where-Object { $_.EnglishName -eq $Value } | Select-Object -First 1
    if ($c) { $c.Name } else { $null }
}

function ConvertFrom-SmartDeployAnswerFile {
    <#
    .SYNOPSIS
        Converts a SmartDeploy deploy wizard answer file (.xml) to this tool's answer object.
        Returns @{ Answer; Notes }: Notes lists what needs a manual step. Passwords are never carried over
        (SmartDeploy encrypts them); each one becomes a passwordFile to fill in.
    #>
    param([Parameter(Mandatory)][string]$Path)
    [xml]$xml = Get-Content -Raw -Path $Path
    $w = $xml.SelectSingleNode('/smartdeploy/deploy_wizard')
    if (-not $w) { throw "$Path is not a SmartDeploy answer file (no smartdeploy/deploy_wizard)." }
    $notes = [Collections.Generic.List[string]]::new()

    $imageFile = Get-XmlText $w 'select_image/image_file'
    $imageLeaf = if ($imageFile) { Split-Path $imageFile -Leaf } else { 'Image.wim' }
    $notes.Add("Image: copy $imageFile to the content root's Images folder (the answer file points to Images\$imageLeaf).")

    $apps = @($w.SelectNodes('application_packs/application_pack') |
        Sort-Object { [int]$_.GetAttribute('installation_order') } |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension("$($_.InnerText)".Trim()) })
    if ($apps) { $notes.Add("Applications: SmartDeploy .spk packs can't be read. Create a folder with an app.json under Applications\ for each of: $($apps -join ', ').") }

    $diskOption = Get-XmlText $w 'disk_options/disk_option' '0'
    if ($diskOption -ne '0') { $notes.Add("Disk option $diskOption (Wipe and load / SmartMigrate) isn't supported; the disk will be recreated.") }

    $membership = switch (Get-XmlText $w 'network_identification/membership' '1') { '0' { 'Domain' } '2' { 'Workgroup' } default { 'Workgroup' } }
    if ((Get-XmlText $w 'network_identification/membership') -eq '2') { $notes.Add('Azure AD join isn''t supported; set to Workgroup.') }

    $inputName = Get-XmlText $w 'regional_settings/input_locale'
    $locale = ConvertTo-LocaleTag $inputName
    if ($inputName -and -not $locale) { $notes.Add("Input locale '$inputName' wasn't recognized; set it by hand (for example fr-CA).") }

    $wmiQuery = Get-XmlText $w 'advanced_options/identification/wmi_query'
    $scheme = Get-XmlText $w 'advanced_options/identification/custom_naming_scheme'
    # SmartDeploy tries its naming methods in order (WMI, existing name, custom scheme); a fresh disk has no
    # existing name, so the WMI query wins when there is one.
    $mode = if ($wmiQuery) { 'WMI' } elseif ($scheme) { 'Custom' } else { 'WMI' }

    $props = @{}
    foreach ($p in $w.SelectNodes('advanced_options/general/system_properties/system_property')) { $props["$($p.InnerText)".Trim()] = $p.GetAttribute('enabled') -eq '1' }
    $unsupportedProps = @($props.Keys | Where-Object { $props[$_] -and $_ -notin 'DISABLE_SYSTEM_RESTORE', 'ENABLE_ADMINISTRATOR_ACCOUNT' })
    if ($unsupportedProps) { $notes.Add("System properties not supported (ignored): $($unsupportedProps -join ', ').") }

    $tasks = @($w.SelectNodes('advanced_options/tasks/task') | ForEach-Object {
        $phase = (Get-XmlText $_ 'phase' '').ToUpperInvariant()
        $cmd = Get-XmlText $_ 'command' ''
        if ($phase -eq 'POSTIMAGE' -and $cmd -match '(?i)\bT:\\') {
            $cmd = $cmd -replace '(?i)\bT:\\', '%OSDRIVE%\'
            $notes.Add("POSTIMAGE task: SmartDeploy's T: drive was changed to %OSDRIVE%: $cmd")
        }
        if ($phase -in 'POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON') { [pscustomobject]@{ Phase = $phase; Command = $cmd } }
        else { $notes.Add("Task phase '$phase' isn't supported; skipped: $cmd") }
    })
    foreach ($t in $tasks | Where-Object { $_.Phase -ne 'POSTIMAGE' -and $_.Command -match '(?i)\bT:\\' }) {
        $notes.Add("$($t.Phase) task uses T:, which only exists in WinPE; check it: $($t.Command)")
    }

    # Letters W:, X: and Z: are taken by the deploy; keep every other letter the file already uses.
    $shareNodes = @($w.SelectNodes('settings/network_shares/network_share'))
    $reserved = @('W:', 'X:', 'Z:')
    $used = $reserved + @($shareNodes | ForEach-Object { (Get-XmlText $_ 'local_name' '').ToUpperInvariant() } |
        Where-Object { $_ -match '^[D-Y]:$' -and $_ -notin $reserved })
    $shares = @($shareNodes | ForEach-Object {
        $local = (Get-XmlText $_ 'local_name' '').ToUpperInvariant()
        if ($local -in $reserved -or $local -notmatch '^[D-Y]:$') {
            $free = [char[]](89..68) | ForEach-Object { "$($_):" } | Where-Object { $_ -notin $used } | Select-Object -First 1
            $notes.Add("Share $(Get-XmlText $_ 'remote_name') moved from $local to $free ($local is used by the deploy).")
            $local = $free
        }
        $used += $local
        [pscustomobject]@{
            LocalName    = $local
            RemoteName   = Get-XmlText $_ 'remote_name'
            Username     = Get-XmlText $_ 'username'
            Domain       = Get-XmlText $_ 'domain'
            PasswordFile = "config\secrets\share-$($local.TrimEnd(':').ToLowerInvariant()).txt"
        }
    })
    if ($shares) { $notes.Add("Shares: put each share's password in its passwordFile ($(($shares.PasswordFile) -join ', ')).") }
    if ($membership -eq 'Domain') { $notes.Add('Domain join: put the join account''s password in config\secrets\join.txt.') }
    if (Get-XmlText $w 'advanced_options/general/platform_pack') { $notes.Add('Drivers: SmartDeploy platform packs (.ppk) aren''t used; import the OEM driver packs in the Driver Library tab.') }
    if ((Get-XmlText $w 'network_tcpip_settings/ipv4/static') -eq '1') { $notes.Add('Static IP settings aren''t supported; the PC will use DHCP.') }
    if ((Get-XmlText $w 'client/install_during_deployment') -eq 'true') { $notes.Add('The SmartDeploy client agent isn''t installed; add your management agent as an application if needed.') }

    $answer = [pscustomobject]@{
        Name                 = [IO.Path]::GetFileNameWithoutExtension($Path)
        Path                 = $null
        Mode                 = if ((Get-XmlText $w '@mode') -eq 'Unattended') { 'Unattended' } else { 'Interactive' }
        UnattendDelay        = [int](Get-XmlText $w 'settings/unattend_delay' '10')
        ImageFile            = "Images\$imageLeaf"
        ImageIndex           = 1
        DiskNumber           = 0
        DiskOption           = 'Recreate'
        DriverRoot           = 'Drivers'
        AppLocation          = 'Applications'
        Applications         = $apps
        ProductKey           = Get-XmlText $w 'product_key/product_key'
        FullName             = Get-XmlText $w 'user_information/full_name'
        Organization         = Get-XmlText $w 'user_information/organization_name'
        TimeZone             = Get-XmlText $w 'regional_settings/time_zone'
        InputLocale          = $locale
        SystemLocale         = $null
        UILanguage           = $null
        UserLocale           = $locale
        NamingMode           = $mode
        WmiQuery             = if ($wmiQuery) { $wmiQuery } else { 'SELECT SerialNumber FROM Win32_BIOS' }
        CustomScheme         = $scheme
        Prefix               = Get-XmlText $w 'advanced_options/identification/prefix' ''
        Membership           = $membership
        Domain               = Get-XmlText $w 'network_identification/domain'
        OrganizationalUnit   = Get-XmlText $w 'network_identification/organizational_unit'
        Workgroup            = Get-XmlText $w 'network_identification/workgroup' 'WORKGROUP'
        JoinUser             = Get-XmlText $w 'join_domain_credentials/username'
        JoinDomain           = Get-XmlText $w 'join_domain_credentials/domain'
        JoinPasswordFile     = 'config\secrets\join.txt'
        EnableAdministrator  = [bool]$props['ENABLE_ADMINISTRATOR_ACCOUNT']
        AdminPasswordFile    = 'config\secrets\admin.txt'
        DisableSystemRestore = [bool]$props['DISABLE_SYSTEM_RESTORE']
        Tasks                = $tasks
        Shares               = $shares
        Reboot               = (Get-XmlText $w 'advanced_options/general/reboot_after_deployment' 'true') -eq 'true'
        Shutdown             = (Get-XmlText $w 'advanced_options/general/shutdown_after_deployment' 'false') -eq 'true'
    }
    if ($answer.EnableAdministrator) { $notes.Add('Built-in Administrator: put its password in config\secrets\admin.txt.') }
    @{ Answer = $answer; Notes = @($notes) }
}

Export-ModuleMember -Function Read-AnswerFile, Test-AnswerFile, Resolve-ComputerName, Get-WmiNamingValue,
    Read-SecretFile, New-UnattendXml, New-FirstBootPlan, Get-AppDefinition, Export-AnswerFile, ConvertFrom-SmartDeployAnswerFile
