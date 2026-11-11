# Data layer for the admin console: reads and writes the content root (Images, Drivers, config, Logs).
# No UI code here, so it can be tested without Windows.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AnswerFile.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ImageVersions.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'AppPack.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'TaskPack.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'NamingList.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'SecretVault.psm1') -Force

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
    foreach ($dir in 'Images', 'Drivers', 'config', 'config\secrets', 'Logs', 'Tools', 'AnswerFiles', 'Applications', 'Tasks', 'Updates') {
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
        $parts = @(if ($f.Extension -eq '.swm') { Get-ChildItem -Path $dir -Filter "$($f.BaseName)*.swm" } else { $f })
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
    # Network captures (capture ISO) need the share; USB captures write to the stick's DEPLOY volume.
    param([Parameter(Mandatory)][string]$ContentRoot, [ValidateSet('Network', 'Usb')][string]$Destination)
    $issues = @()
    if ($Destination -eq 'Network') {
        $share = (Get-DeploySettings -ContentRoot $ContentRoot).share.path
        if (-not $share) { $issues += 'No network share is set in Deploy Settings, so WinPE has nowhere to save the image.' }
        elseif ($share -notmatch '^\\\\[^\\]+\\.+') { $issues += "The share '$share' is not a \\server\share path." }
    }
    $issues
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
    $taskLocation = if ($a.PSObject.Properties['TaskLocation'] -and $a.TaskLocation) { $a.TaskLocation } else { 'Tasks' }
    if (& $local $taskLocation) {
        $taskRoot = Join-ContentPath $ContentRoot $taskLocation
        foreach ($name in @($a.Tasks | Where-Object { $_.PSObject.Properties['Script'] -and $_.Script } | ForEach-Object Script | Select-Object -Unique)) {
            try {
                $def = Read-TaskPack -TaskRoot $taskRoot -Name $name
                foreach ($p in Test-TaskPack -Definition $def -Folder (Join-Path $taskRoot $name)) { "Task ${name}: $p" }
            } catch { "Task ${name}: $($_.Exception.Message)" }
        }
    }
    # Each password the deploy needs: encrypted in the answer file (with this content root's key) or in its file.
    $key = Get-AnswerKey -ContentRoot $ContentRoot
    foreach ($s in @(Get-AnswerSecrets -Answer $a)) {
        if ($s.Encrypted) {
            if (-not $key) { "$($s.Label) is encrypted, but config\secrets\answer-key.txt is missing: type it again in the editor."; continue }
            try { $null = Unprotect-AnswerPassword -Value $s.Encrypted -Key $key } catch { "$($s.Label) can't be decrypted ($($_.Exception.Message)): type it again in the editor." }
        }
        elseif (-not (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $s.RelativePath)) { "$($s.Label) is not saved: type it in the editor." }
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

function Import-DeployWizardAnswerFile {
    # Converts a deploy wizard answer file XML into AnswerFiles\<name>.xml. Returns the notes to show the user.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Path, [string]$Name)
    $result = ConvertFrom-DeployWizardAnswerFile -Path $Path
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
    $a
}

function Test-SecretFile {
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$RelativePath)
    [bool]($RelativePath -and (Test-Path (Join-ContentPath $ContentRoot $RelativePath)))
}

function Test-SavedPassword {
    # True when a password is saved for this field: encrypted in the answer file, or in its password file.
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$RelativePath, [string]$Encrypted)
    [bool]((Test-AnswerPasswordText $Encrypted) -or (Test-SecretFile -ContentRoot $ContentRoot -RelativePath $RelativePath))
}

function Split-JoinAccount {
    # "CORP\svc-join" typed as the join account -> user svc-join, domain CORP, whatever the account's domain box held:
    # Windows signs in as domain\user, so keeping both made CORP\svc-join into OTHER\CORP\svc-join and the join failed.
    # A UPN (svc-join@corp.example.com) needs no domain, so the box is cleared. Other forms are left for
    # Get-DomainJoinProblem to point at.
    param([string]$User, [string]$Domain)
    $User = "$User".Trim(); $Domain = "$Domain".Trim()
    if ($Domain -notmatch '[\\/@]') {
        if ($User -match '^([^\\@/]+)\\([^\\@/]+)$') { $User = $Matches[2].Trim(); $Domain = $Matches[1].Trim() }
        elseif ($User -match '^[^\\@/]+@[^\\@/]+$') { $Domain = '' }
    }
    [pscustomobject]@{ User = $User; Domain = $Domain }
}

function Get-DomainJoinProblem {
    <#
    .SYNOPSIS
        The first missing domain join field in the answer file editor, as the control to show and a plain message.
        Nothing when the answer is a workgroup one or every field is filled in.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [bool]$PasswordTyped,
        [bool]$PasswordSaved
    )
    if ($Answer.Membership -ne 'Domain') { return }
    $page = 'Domain or workgroup page'
    if (-not $Answer.Domain) {
        return [pscustomobject]@{ Control = 'TxtDomain'; Message = "Type the domain to join, such as corp.example.com, in Domain ($page)." }
    }
    if (-not $Answer.JoinUser) {
        return [pscustomobject]@{ Control = 'TxtJoinUser'; Message = "Type the user name of the account that joins PCs to the domain, such as svc-join, in Join account user name ($page)." }
    }
    $account = Resolve-JoinAccount -Answer $Answer
    if ($account.ProblemField -eq 'Domain') {
        return [pscustomobject]@{ Control = 'TxtJoinDomain'; Message = "Account's domain must be just a domain name such as CORP, without \ or @. To give the domain with the user, type DOMAIN\user in Join account user name ($page)." }
    }
    if ($account.ProblemField -eq 'User') {
        return [pscustomobject]@{ Control = 'TxtJoinUser'; Message = "Type the join account as svc-join, CORP\svc-join or svc-join@corp.example.com in Join account user name ($page)." }
    }
    if (-not $PasswordTyped -and -not $PasswordSaved) {
        return [pscustomobject]@{ Control = 'PwdJoin'; Message = "Type the join account's password in Password ($page). It is saved encrypted in the answer file." }
    }
}

function Save-AnswerFromEditor {
    <#
    .SYNOPSIS
        Saves an answer object edited in the console. Passwords typed in the editor are saved in the answer file,
        encrypted with the content root's answer file key (SecretVault.psm1; made the first time). Each one keeps a
        passwordFile name (named after the answer file when it has none), which names the password for the vault and
        the deploy wizard; an old password file there is removed so it can't override the new password. Throws with
        the problems if it can't be deployed.
    #>
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Answer,
        [string]$JoinPassword,
        [string]$AdminPassword,
        [hashtable]$SharePasswords = @{},   # local name (Y:) -> password
        [string]$BitLockerPin,
        [switch]$IsNew
    )
    $a = $Answer
    if ($a.Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Answer file name '$($a.Name)' may only contain letters, digits, dot, dash and underscore." }
    $dest = Get-AnswerFilePath -ContentRoot $ContentRoot -Name $a.Name
    if ($IsNew -and (Test-Path $dest)) { throw "An answer file named $($a.Name) already exists." }

    if (-not $a.JoinPasswordFile) { $a.JoinPasswordFile = "config\secrets\$($a.Name)-join.txt" }
    if (-not $a.AdminPasswordFile) { $a.AdminPasswordFile = "config\secrets\$($a.Name)-admin.txt" }
    if (-not $a.BitLocker.PinFile) { $a.BitLocker.PinFile = "config\secrets\$($a.Name)-bitlocker-pin.txt" }
    if ($BitLockerPin -and $BitLockerPin -notmatch '^\d{6,20}$') { throw 'The BitLocker startup PIN must be 6 to 20 digits.' }
    foreach ($sh in $a.Shares) {
        if (-not $sh.PasswordFile -and $sh.Username) { $sh.PasswordFile = "config\secrets\$($a.Name)-share-$($sh.LocalName.TrimEnd(':').ToLowerInvariant()).txt" }
    }

    $problems = @(Test-AnswerFile $a)
    if ($problems) { throw "Can't save yet:`n - " + ($problems -join "`n - ") }

    $typed = @($JoinPassword, $AdminPassword, $BitLockerPin) + @($SharePasswords.Values) | Where-Object { $_ }
    $key = if ($typed) { Get-AnswerKey -ContentRoot $ContentRoot -Create } else { $null }
    $replaced = New-Object Collections.Generic.List[string]
    $protect = {
        param($Object, [string]$Property, [string]$Password, [string]$RelativePath)
        if (-not $Password) { return }
        $Object | Add-Member -NotePropertyName $Property -NotePropertyValue (Protect-AnswerPassword -Password $Password -Key $key) -Force
        if ($RelativePath) { $replaced.Add($RelativePath) }
    }
    & $protect $a 'JoinPasswordEncrypted' $JoinPassword $a.JoinPasswordFile
    & $protect $a 'AdminPasswordEncrypted' $AdminPassword $a.AdminPasswordFile
    & $protect $a.BitLocker 'PinEncrypted' $BitLockerPin $a.BitLocker.PinFile
    foreach ($sh in $a.Shares) { & $protect $sh 'PasswordEncrypted' $SharePasswords[$sh.LocalName] $sh.PasswordFile }
    # A password file left from before would win over the new password at deploy time, and the next build would put
    # it back in the answer file: drop it, once the other answer files that name it carry its password encrypted.
    $old = @($replaced | Where-Object { Test-SecretFile -ContentRoot $ContentRoot -RelativePath $_ })
    if ($old) {
        $null = Sync-AnswerFilePasswords -ContentRoot $ContentRoot
        foreach ($f in $old) { Remove-Item -LiteralPath (Join-ContentPath $ContentRoot $f) -Force }
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
    $templates = @(Get-AppTemplates)
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ Name = $_.Name; DisplayName = ''; Version = ''; Type = ''; Command = $null; Detection = ''; For = 'All PCs'; Download = ''; KnownDownload = ''
                           UsedBy = if ($usage.ContainsKey($_.Name)) { $usage[$_.Name] -join ', ' } else { '' }
                           Status = 'Ready'; Issues = @(); Definition = $null; FullName = $_.FullName }
        try {
            $d = Read-AppPack -AppRoot $root -Name $_.Name
            $row.Definition = $d
            $row.DisplayName = $d.displayName; $row.Version = $d.version; $row.Type = $d.installerType; $row.Command = $d.command
            $row.Download = $d.downloadUrl
            $known = Get-AppKnownDownload -Definition $d -Templates $templates
            if ($known) { $row.KnownDownload = $known.download.url }
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

function Set-ApplicationOnline {
    <#
    .SYNOPSIS
        The Applications tab's "Download it from the internet" tick box. On: the application becomes its catalog
        version (download address, command and files from the template that knows it), so the PC downloads it when it
        installs it. Off: the download address is removed and the installer in the folder is used again.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$On)
    $root = Join-Path $ContentRoot 'Applications'
    $dir = Join-Path $root $Name
    # The settings from before the tick (installer in the pack) are kept here, and come back on untick.
    $local = Join-Path $dir 'app-local.json'
    $d = Read-AppPack -AppRoot $root -Name $Name
    if ($On) {
        if ($d.downloadUrl) { return $d }
        $t = Get-AppKnownDownload -Definition $d
        if (-not $t) { throw "There is no known download for $Name. Pick its installer, or find the application online on the Applications tab." }
        Copy-Item -LiteralPath (Join-Path $dir 'app.json') -Destination $local -Force
        New-AppFromCatalog -AppRoot $root -Template $t -Name $Name -Overwrite | Out-Null
    } elseif (Test-Path -LiteralPath $local) {
        Move-Item -LiteralPath $local -Destination (Join-Path $dir 'app.json') -Force
    } else {
        $d.downloadUrl = ''
        try { Save-AppPack -AppRoot $root -Definition $d -Overwrite | Out-Null }
        catch { throw "$Name has no installer in its folder, so it must keep downloading. Edit it to add the installer first." }
    }
    Read-AppPack -AppRoot $root -Name $Name
}

function New-Application {
    # Creates Applications\<name>: copies the installer (a file, or a folder's contents) and writes app.json.
    # The simple form (-Command, -SuccessCodes) or a full -Definition from the application pack builder.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$Name,
        # Empty for an application the PC downloads at first boot (downloadUrl in -Definition).
        [string]$Source,
        [string]$Command,
        [int[]]$SuccessCodes = @(0, 3010),
        $Definition
    )
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Application name '$Name' may only contain letters, digits, dot, dash and underscore." }
    if (-not $Definition) {
        $leaf = if ($Source -and (Test-Path $Source -PathType Leaf)) { Split-Path $Source -Leaf } else { '' }
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

function Get-TaskUsage {
    # Task library name -> names of the answer files that run it.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $usage = @{}
    foreach ($f in Get-ChildItem -Path (Join-Path $ContentRoot 'AnswerFiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
        try { $a = Read-AnswerFile -Path $f.FullName -SkipValidation } catch { continue }
        foreach ($n in @($a.Tasks | Where-Object Script | ForEach-Object Script | Select-Object -Unique)) {
            if (-not $usage.ContainsKey($n)) { $usage[$n] = @() }
            $usage[$n] += $f.BaseName
        }
    }
    $usage
}

function Get-TaskList {
    # Tasks\<name>\task.json folders, for the Tasks tab and the answer file editor's picker.
    param([Parameter(Mandatory)][string]$ContentRoot)
    $root = Join-Path $ContentRoot 'Tasks'
    $usage = Get-TaskUsage -ContentRoot $ContentRoot
    Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'task.json') } | Sort-Object Name | ForEach-Object {
        $row = [ordered]@{ Name = $_.Name; Description = ''; Script = ''; Type = ''; Phase = ''; For = 'All PCs'; CommandLine = ''
                           UsedBy = if ($usage.ContainsKey($_.Name)) { $usage[$_.Name] -join ', ' } else { '' }
                           Status = 'Ready'; Issues = @(); Definition = $null; FullName = $_.FullName }
        try {
            $d = Read-TaskPack -TaskRoot $root -Name $_.Name
            $row.Definition = $d
            $row.Description = $d.description; $row.Script = $d.script; $row.Type = $d.type; $row.Phase = $d.phase
            $for = @($d.requirements.makers) + @($d.requirements.models)
            if ($for) { $row.For = $for -join ', ' }
            if ($d.script -and $d.type) { $row.CommandLine = Get-TaskCommandLine -Definition $d -Folder "<task folder>" }
            $row.Issues = @(Test-TaskPack -Definition $d -Folder $_.FullName)
            if ($row.Issues) { $row.Status = "$($row.Issues.Count) problem(s)" }
        } catch { $row.Status = $_.Exception.Message; $row.Issues = @($_.Exception.Message) }
        [pscustomobject]$row
    }
}

function Save-Task {
    # Creates or updates Tasks\<name>: -Source copies a script file (or a folder's contents), -ScriptText writes the
    # script typed in the console. -New refuses an existing name.
    param(
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)]$Definition,
        [string]$Source,
        [AllowNull()][string]$ScriptText,
        [switch]$New
    )
    $save = @{ TaskRoot = (Join-Path $ContentRoot 'Tasks'); Definition = $Definition; Source = $Source; Overwrite = -not $New }
    if ($PSBoundParameters.ContainsKey('ScriptText')) { $save.ScriptText = $ScriptText }
    Save-TaskPack @save
}

function Remove-Task {
    # Deletes Tasks\<name>. Refuses while an answer file still runs it.
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$Name)
    $usage = Get-TaskUsage -ContentRoot $ContentRoot
    if ($usage.ContainsKey($Name)) { throw "$Name is still in these answer files: $($usage[$Name] -join ', '). Remove it from them first." }
    $dir = Join-Path (Join-Path $ContentRoot 'Tasks') $Name
    if (-not (Test-Path (Join-Path $dir 'task.json'))) { throw "$Name is not a task folder." }
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
    # Command line for Capture-VMImage.ps1, run by the console in its own window: a shut-down VM's disk file,
    # sysprepped, or not with -SysprepAtDeploy (each PC runs sysprep at its first start).
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$DiskPath,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description,
        [ValidateSet('fast', 'max')][string]$Compression = 'max',
        [switch]$Split,
        [switch]$NewVersion,
        [switch]$SysprepAtDeploy,
        [string]$ReuseConvertedDisk,
        [string]$ProgressFile,
        [string]$LogPath
    )
    if (-not (Test-ImageName $Name)) { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $quote = { param($v) "'" + ($v -replace "'", "''") + "'" }
    $cmd = "& $(& $quote $ScriptPath) -DiskPath $(& $quote $DiskPath) -Name $(& $quote $Name) -ContentRoot $(& $quote $ContentRoot) -Compression $Compression"
    if ($Description) { $cmd += " -Description $(& $quote $Description)" }
    if ($Split) { $cmd += ' -SplitSizeMB 3800' }
    if ($NewVersion) { $cmd += ' -NewVersion' }
    if ($SysprepAtDeploy) { $cmd += ' -SysprepAtDeploy' }
    if ($ReuseConvertedDisk) { $cmd += " -ReuseConvertedDisk $(& $quote $ReuseConvertedDisk)" }
    if ($ProgressFile) { $cmd += " -ProgressFile $(& $quote $ProgressFile)" }
    if ($LogPath) { $cmd += " -LogPath $(& $quote $LogPath)" }
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

Export-ModuleMember -Function Join-ContentPath, Get-ConsoleConfig, Save-ConsoleConfig, Initialize-ContentRoot, Test-ContentRoot,
    Get-ImageList, Get-DriverCatalog, Get-DriverCatalogRows, Save-DriverCatalog, Import-DriverPack,
    Get-DeploySettings, Save-DeploySettings, Get-WdsSettings, Save-WdsSettings,
    Get-DeploymentLogs,
    Update-ContentTools, Test-ImageName, New-CaptureConfig, Get-CaptureReadiness,
    Get-AnswerFilePath, Get-AnswerFileIssues, Get-AnswerFileRows, Import-DeployWizardAnswerFile, Get-ImageUsage,
    Get-NewAnswer, Test-SecretFile, Test-SavedPassword, Save-AnswerFromEditor, Split-JoinAccount, Get-DomainJoinProblem, Get-ApplicationList, New-Application, Set-ApplicationOnline,
    Get-TaskUsage, Get-TaskList, Save-Task, Remove-Task,
    Get-ImageVersionRows, Remove-ImageVersions, Get-ImageVersionsToDelete, Get-ImageVersionArguments,
    Get-ImageEditions,
    Get-UpdateKB, Get-UpdatePackageRows, Get-ImageServicingHistory, Add-ImageServicingRecord, Get-ImageUpdateArguments,
    Get-ApplicationUsage, Save-Application, Remove-Application,
    Get-NamingListPath, Get-AnswerFileNames, Get-NamingListRows, Save-NamingListFromConsole, Merge-NamingList,
    Get-VMCaptureArguments
