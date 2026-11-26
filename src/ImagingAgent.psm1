# The agent on every imaged PC, and what the console needs to talk to it. PowerShell 5.1 compatible.
#
# On the PC (ImagingAgent.ps1, a SYSTEM scheduled task ImagingTool\Agent that starts with Windows and keeps running):
#   - every few minutes it writes a check-in to <status folder>\Agents\<serial>.json on the deployment share: name,
#     serial, IP, model, image, deploy result, who is signed in, when it last checked in. As SYSTEM the share sees the
#     computer account, which already writes to the Status folder (Domain Computers, Modify) at first boot.
#   - every minute it looks for a job in <status folder>\Agents\Jobs\<serial>\job.json. A job only counts when the
#     console signed it (RSA, SHA-256) with its private key, it names this PC's serial, UUID and agent id, it has not
#     expired, and it never ran here before. Any domain PC can write in the Status folder, so the signature is what
#     makes a job the console's.
#   - a reimage job: it copies the network boot image the console put next to the job (that folder is readable by
#     this PC's computer account only: boot.wim holds the answer file key), checks its SHA-256 against the signed
#     job, and restarts into WinPE from its own disk the way the console does over WinRM (Invoke-LocalDiskBoot
#     -Method Local). WinPE then takes the usual Reimage\<serial>.json job on the share.
#
# On the console: the key pair (private in <content root>\config\secrets\agent-key.xml, never on a stick; public in
# config\agent-public-key.xml and in every boot.wim), reading the check-ins, and writing signed jobs.
#
# The share layout:
#   Status\Agents\<serial>.json               a PC's last check-in
#   Status\Agents\Jobs\<serial>\job.json      a signed job for that PC
#   Status\Agents\Jobs\<serial>\boot.wim      the network boot image for a reimage job (that PC's account only)

Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1')   # ConvertTo-SerialKey, Invoke-LocalDiskBoot
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1')     # Update-DeployAppResults, Update-DeployCheckResults, Update-LocalDeployResult
Import-Module (Join-Path $PSScriptRoot 'PostDeployChecks.psm1') # Get-BitLockerCheck (BitLocker checked again)

$script:AgentDir = 'C:\ProgramData\ImagingTool\Agent'
$script:AgentTaskName = 'ImagingTool\Agent'
# The files the agent runs from (copied into C:\ProgramData\ImagingTool\Agent, administrators and SYSTEM only).
$script:AgentFiles = @('ImagingAgent.ps1', 'ImagingAgent.psm1', 'RemoteReimage.psm1', 'JsonFile.psm1', 'AnswerFile.psm1', 'AppPack.psm1',
    'LibraryPack.psm1', 'ScriptLog.psm1', 'DeployStatus.psm1', 'PostDeployChecks.psm1')
# What a PC needs to install the agent by itself (Publish-AgentInstaller puts them in <share>\Agent).
$script:AgentInstallerFiles = @('Install-AgentHere.ps1', 'Install-Agent.cmd')
$script:KeyFile = 'config\secrets\agent-key.xml'
$script:PublicKeyFile = 'config\agent-public-key.xml'

function Join-AgentPath([string]$Root, [string]$Child) {
    # [IO.Path]::Combine, not Join-Path: a UNC share or a WinPE volume may have no PowerShell drive.
    [IO.Path]::Combine($Root, ($Child -replace '[\\/]', [IO.Path]::DirectorySeparatorChar))
}

function ConvertFrom-AgentTime($Value) {
    # ConvertFrom-Json may already have made a date of it.
    if ($Value -is [datetime]) { return $Value }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$d)) { return $d }
    $null
}

#region Where things are

function Get-AgentInstallFolder { $script:AgentDir }
function Get-AgentTaskName { $script:AgentTaskName }
function Get-AgentFileNames { $script:AgentFiles }

function Get-AgentFolder {
    # Where the PCs check in: <status folder>\Agents.
    param([Parameter(Mandatory)][string]$StatusFolder)
    Join-AgentPath $StatusFolder 'Agents'
}

function Get-AgentStatusFolder {
    <#
    .SYNOPSIS
        Deploy: the UNC status folder the agent on a newly deployed PC checks in to, or '' when there is none. The one
        WinPE reported to; else, for a USB deploy that could not reach the share, the share's Status folder from
        deploy-settings.json (reporting.path on older setups), which Windows reaches later as the computer account.
    #>
    param($StatusTarget, $Settings)
    if ($StatusTarget -and $StatusTarget.Unc) { return "$($StatusTarget.Unc)" }
    if ($Settings -and $Settings.PSObject.Properties['reporting'] -and $Settings.reporting -and "$($Settings.reporting.path)" -like '\\*') { return "$($Settings.reporting.path)".TrimEnd('\') }
    $share = if ($Settings -and $Settings.PSObject.Properties['share'] -and $Settings.share) { "$($Settings.share.path)".Trim().TrimEnd('\') } else { '' }
    # The shipped example (\\deploy-server\Deploy) points at no real server.
    if (-not $share -or $share -notlike '\\*' -or $share -match '^\\\\(deploy-server|server|yourserver)\\') { return '' }
    "$share\Status"
}

function Get-AgentJobFolder {
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial)
    Join-AgentPath (Get-AgentFolder $StatusFolder) "Jobs\$(ConvertTo-SerialKey $Serial)"
}

#endregion

#region Keys (console)

function New-AgentKeyPair {
    # RSA 3072: the console signs with the private key, every PC checks with the public one. XML, as .NET has it.
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    try {
        $rsa.PersistKeyInCsp = $false
        [pscustomobject]@{ Private = $rsa.ToXmlString($true); Public = $rsa.ToXmlString($false) }
    } finally { $rsa.Dispose() }
}

function Get-AgentSigningKey {
    <#
    .SYNOPSIS
        The console's private key (XML) from <content root>\config\secrets\agent-key.xml, or $null. -Create makes the
        pair the first time and writes the public key to config\agent-public-key.xml (it goes into every boot.wim
        and on the sticks; config\secrets never does).
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [switch]$Create)
    $path = Join-AgentPath $ContentRoot $script:KeyFile
    $pub = Join-AgentPath $ContentRoot $script:PublicKeyFile
    if ([IO.File]::Exists($path)) {
        $key = [IO.File]::ReadAllText($path).Trim()
        # The public key file was deleted (or never copied): write it again from the private key.
        if (-not [IO.File]::Exists($pub)) { [IO.File]::WriteAllText($pub, (ConvertTo-AgentPublicKey $key), [Text.Encoding]::ASCII) }
        return $key
    }
    if (-not $Create) { return $null }
    $pair = New-AgentKeyPair
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $pair.Private, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText($pub, $pair.Public, [Text.Encoding]::ASCII)
    $pair.Private
}

function ConvertTo-AgentPublicKey {
    param([Parameter(Mandatory)][string]$PrivateKey)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp = $false; $rsa.FromXmlString($PrivateKey); $rsa.ToXmlString($false) } finally { $rsa.Dispose() }
}

function Get-AgentPublicKey {
    # The public key the PCs check jobs with: <content root>\config\agent-public-key.xml (made with the private key).
    param([Parameter(Mandatory)][string]$ContentRoot, [switch]$Create)
    $key = Get-AgentSigningKey -ContentRoot $ContentRoot -Create:$Create
    if (-not $key) { return $null }
    [IO.File]::ReadAllText((Join-AgentPath $ContentRoot $script:PublicKeyFile)).Trim()
}

function Get-AgentKeyId {
    # A short name for a public key (first 12 hex of its SHA-256), for the logs: which console's key a PC trusts.
    param([Parameter(Mandatory)][string]$PublicKey)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($PublicKey.Trim())) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12) }
    finally { $sha.Dispose() }
}

#endregion

#region Jobs

# The fields a signature covers, in this order. A job is signed as these lines (name=value), so nothing in it can be
# changed or added without breaking the signature.
$script:JobFields = @('version', 'id', 'action', 'serial', 'uuid', 'agentId', 'computerName', 'createdAt', 'expiresAt', 'bootWimSha256', 'delaySeconds', 'message', 'requestedBy')
# Fields added later (install apps jobs): signed too, but only when the job has them, so a reimage job reads the same
# as before and agents installed before them still take it.
$script:OptionalJobFields = @('apps', 'payloadSha256')

function Get-AgentJobText {
    param([Parameter(Mandatory)]$Job)
    $line = { param($n)
        $v = if ($Job.PSObject.Properties[$n]) { $Job.$n } else { '' }
        if ($v -is [datetime]) { $v = $v.ToUniversalTime().ToString('o') }
        "$n=$("$v" -replace "[`r`n]", ' ')"
    }
    $extra = @($script:OptionalJobFields | Where-Object { $Job.PSObject.Properties[$_] -and "$($Job.$_)" -ne '' })
    (@(@($script:JobFields) + $extra | ForEach-Object { & $line $_ })) -join "`n"
}

function Get-AgentPayloadHash {
    <#
    .SYNOPSIS
        One SHA-256 for every file under a folder (relative path and content), so the console can sign what it put
        next to a job and the PC can check it got exactly that.
    #>
    param([Parameter(Mandatory)][string]$Folder)
    $base = [IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    $lines = foreach ($f in [IO.Directory]::GetFiles($base, '*', [IO.SearchOption]::AllDirectories)) {
        $rel = $f.Substring($base.Length + 1).Replace('/', '\').ToLowerInvariant()
        "$rel|$((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash)"
    }
    $text = (@($lines) | Sort-Object { $_ } -Culture ([Globalization.CultureInfo]::InvariantCulture)) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '') } finally { $sha.Dispose() }
}

function Get-AgentCodeHash {
    <#
    .SYNOPSIS
        The agent's code version: one SHA-256 (first 12 hex digits) of its files (Get-AgentFileNames) in -Folder: the
        console's src folder, or C:\ProgramData\ImagingTool\Agent on a PC. '' when one of them is missing.
    #>
    param([Parameter(Mandatory)][string]$Folder)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($f in $script:AgentFiles) {
        $p = Join-AgentPath $Folder $f
        if (-not [IO.File]::Exists($p)) { return '' }
        $lines.Add("$($f.ToLowerInvariant())|$((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash)")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))).Replace('-', '').Substring(0, 12) } finally { $sha.Dispose() }
}

function Set-AgentJobSignature {
    # Adds signature (base64 RSA SHA-256 over Get-AgentJobText) to the job.
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$PrivateKey)
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    try {
        $rsa.PersistKeyInCsp = $false
        $rsa.FromXmlString($PrivateKey)
        $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes((Get-AgentJobText $Job)), 'SHA256')
    } finally { $rsa.Dispose() }
    $Job | Add-Member -NotePropertyName signature -NotePropertyValue ([Convert]::ToBase64String($sig)) -Force
    $Job
}

function Test-AgentJobSignature {
    param([Parameter(Mandatory)]$Job, [string[]]$PublicKeys)
    if (-not $Job.PSObject.Properties['signature'] -or -not $Job.signature) { return $false }
    try { $sig = [Convert]::FromBase64String("$($Job.signature)") } catch { return $false }
    $data = [Text.Encoding]::UTF8.GetBytes((Get-AgentJobText $Job))
    foreach ($k in @($PublicKeys | Where-Object { $_ })) {
        $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
        try {
            $rsa.PersistKeyInCsp = $false
            $rsa.FromXmlString($k)
            if ($rsa.VerifyData($data, 'SHA256', $sig)) { return $true }
        } catch { } finally { $rsa.Dispose() }
    }
    $false
}

function New-AgentJob {
    <#
    .SYNOPSIS
        Console: a signed job for one PC's agent, from its check-in (serial, UUID, agent id). For a reimage, -BootWim
        is copied next to the job and its SHA-256 goes into the signed job. The job's folder is made fresh and
        limited to administrators, the console's account and that PC's computer account (-SetFolderAccess; tests pass
        a stand-in), because boot.wim holds the answer file key.
    #>
    param(
        [Parameter(Mandatory)][string]$StatusFolder,
        [Parameter(Mandatory)][string]$PrivateKey,
        [Parameter(Mandatory)]$CheckIn,                  # the PC's check-in (Get-AgentCheckIns row or the raw record)
        [ValidateSet('reimage', 'installapps', 'update')][string]$Action = 'reimage',
        [string]$SourceDir,                              # update: the console's src folder (the agent's new files)
        [string]$BootWim,
        [string[]]$Apps,                                 # installapps: the app names; their packs are in -AppRoot
        [string]$AppRoot,
        [string]$BootWimSha256,                          # when known already (several PCs, one image)
        [int]$DelaySeconds = 60,
        [string]$Message = 'IT is reinstalling Windows on this PC. Save your work: it restarts shortly.',
        [int]$ExpiresMinutes = 60,
        [datetime]$Now = (Get-Date),
        [scriptblock]$SetFolderAccess = { param($Folder, $Account) Set-AgentJobFolderAccess -Folder $Folder -Account $Account }
    )
    $serial = "$($CheckIn.serial)"
    if (-not $CheckIn.agentId) { throw "The agent on $($CheckIn.computerName) has no id: it can't take jobs." }
    $dir = Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $serial
    # Fresh every time: a folder some other PC made beforehand (anyone can write in Status) is never reused.
    if ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dir))
    New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
    $account = if ($CheckIn.PSObject.Properties['accountSid'] -and $CheckIn.accountSid) { "*$($CheckIn.accountSid)" } else { "$($CheckIn.account)" }
    & $SetFolderAccess $dir $account
    if (@([IO.Directory]::GetFileSystemEntries($dir)).Count) { [IO.Directory]::Delete($dir, $true); throw "Something wrote into $dir while it was made; not used." }
    try {
        $hash = ''
        $payload = ''
        if ($Action -eq 'reimage') {
            if (-not $BootWim -or -not [IO.File]::Exists($BootWim)) { throw "No network boot image at $BootWim." }
            $hash = if ($BootWimSha256) { $BootWimSha256 } else { (Get-FileHash -LiteralPath $BootWim -Algorithm SHA256).Hash }
            [IO.File]::Copy($BootWim, (Join-AgentPath $dir 'boot.wim'), $true)
        } elseif ($Action -eq 'update') {
            # The agent's files go next to the job, and one hash of them all into the signed job.
            if (-not $SourceDir) { throw 'No folder with the agent files.' }
            $agentDir = Join-AgentPath $dir 'Agent'
            [void][IO.Directory]::CreateDirectory($agentDir)
            foreach ($f in $script:AgentFiles) { [IO.File]::Copy((Join-AgentPath $SourceDir $f), (Join-AgentPath $agentDir $f), $true) }
            $payload = Get-AgentPayloadHash $agentDir
        } else {
            # The app packs go next to the job (that PC's account only), and one hash of them all into the signed job.
            $Apps = @($Apps | Where-Object { $_ } | Select-Object -Unique)
            if (-not $Apps) { throw 'No application to install.' }
            $appsDir = Join-AgentPath $dir 'Apps'
            foreach ($a in $Apps) {
                $src = Join-AgentPath $AppRoot $a
                if (-not [IO.Directory]::Exists($src)) { throw "The application pack $a is not in $AppRoot." }
                Copy-AgentFolder -Source $src -Destination (Join-AgentPath $appsDir $a)
            }
            $payload = Get-AgentPayloadHash $appsDir
        }
        $job = [pscustomobject][ordered]@{
            version       = 1
            id            = [guid]::NewGuid().ToString()
            action        = $Action
            serial        = $serial.Trim()
            uuid          = "$($CheckIn.uuid)".Trim()
            agentId       = "$($CheckIn.agentId)"
            computerName  = "$($CheckIn.computerName)".ToUpperInvariant()
            createdAt     = $Now.ToUniversalTime().ToString('o')
            expiresAt     = $Now.ToUniversalTime().AddMinutes($ExpiresMinutes).ToString('o')
            bootWimSha256 = "$hash".ToUpperInvariant()
            delaySeconds  = $DelaySeconds
            message       = $Message
            requestedBy   = "$env:USERDOMAIN\$env:USERNAME".Trim('\')
        }
        if ($Action -eq 'installapps') { $job | Add-Member -NotePropertyName apps -NotePropertyValue ($Apps -join ', ') }
        if ($Action -in 'installapps', 'update') { $job | Add-Member -NotePropertyName payloadSha256 -NotePropertyValue $payload }
        $job = Set-AgentJobSignature -Job $job -PrivateKey $PrivateKey
        Save-JsonFile -Path (Join-AgentPath $dir 'job.json') -InputObject $job
        $job
    } catch {
        try { [IO.Directory]::Delete($dir, $true) } catch { }
        throw
    }
}

function Copy-AgentFolder {
    # A folder and everything in it (.NET: the share is a UNC path).
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $base = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($d in [IO.Directory]::GetDirectories($base, '*', [IO.SearchOption]::AllDirectories)) {
        [void][IO.Directory]::CreateDirectory((Join-AgentPath $Destination $d.Substring($base.Length + 1)))
    }
    foreach ($f in [IO.Directory]::GetFiles($base, '*', [IO.SearchOption]::AllDirectories)) {
        [IO.File]::Copy($f, (Join-AgentPath $Destination $f.Substring($base.Length + 1)), $true)
    }
}

function Get-AgentJobApps {
    # The app names of an install apps job.
    param([Parameter(Mandatory)]$Job)
    @("$(if ($Job.PSObject.Properties['apps']) { $Job.apps })" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Set-AgentJobFolderAccess {
    # Administrators, SYSTEM and the console's own account full control, the PC's computer account modify (it
    # deletes the job and boot.wim once taken), nothing inherited: the other domain PCs that write in Status get
    # nothing. Account: *SID or DOMAIN\PC$.
    param([Parameter(Mandatory)][string]$Folder, [string]$Account)
    if (-not $Account) { throw 'The PC did not report its computer account: its job folder could not be limited to it.' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $out = & icacls.exe $Folder /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' "*${me}:(OI)(CI)F" "${Account}:(OI)(CI)M" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not limit $Folder to $Account (icacls exit $LASTEXITCODE): $(@($out) -join ' ')" }
}

function Get-AgentJob {
    # The job waiting for this PC, or $null. .NET calls: the share is a UNC path.
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial)
    if (-not (Test-UsableSerial $Serial)) { return $null }
    $path = Join-AgentPath (Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $Serial) 'job.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $text = [IO.File]::ReadAllText($path)
    try { $text | ConvertFrom-Json } catch { [pscustomobject]@{ id = ''; unreadable = $_.Exception.Message } }
}

function Remove-AgentJob {
    # Console: the job and its boot image (cancelled, timed out, or done). PC: the job file once taken.
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial, [switch]$JobFileOnly)
    $dir = Get-AgentJobFolder -StatusFolder $StatusFolder -Serial $Serial
    try {
        if ($JobFileOnly) { [IO.File]::Delete((Join-AgentPath $dir 'job.json')) }
        elseif ([IO.Directory]::Exists($dir)) { [IO.Directory]::Delete($dir, $true) }
    } catch { }
}

function Test-AgentJob {
    <#
    .SYNOPSIS
        PC: why a job must not run here, or $null when it may. Identity: this PC's serial, uuid and agentId. DoneIds:
        the jobs that ran here already. ClockSkewMinutes: how far this PC's clock may be from the console's.
    #>
    param(
        [Parameter(Mandatory)]$Job,
        [string[]]$PublicKeys,
        [Parameter(Mandatory)]$Identity,
        [string[]]$DoneIds = @(),
        [datetime]$Now = (Get-Date),
        [int]$ClockSkewMinutes = 10
    )
    if ($Job.PSObject.Properties['unreadable']) { return "the job file can't be read ($($Job.unreadable))" }
    if (-not @($PublicKeys | Where-Object { $_ })) { return 'this PC has no console key, so it takes no jobs' }
    if (-not (Test-AgentJobSignature -Job $Job -PublicKeys $PublicKeys)) { return 'it is not signed by the console' }
    if ("$($Job.version)" -ne '1') { return "job version $($Job.version) is not known to this agent" }
    if ($Job.action -notin 'reimage', 'installapps', 'update') { return "action '$($Job.action)' is not known to this agent" }
    if ("$($Job.serial)".Trim().ToUpperInvariant() -ne "$($Identity.serial)".Trim().ToUpperInvariant()) { return "it is for serial $($Job.serial)" }
    if ($Job.uuid -and $Identity.uuid -and "$($Job.uuid)".Trim() -ne "$($Identity.uuid)".Trim()) { return "it is for UUID $($Job.uuid)" }
    # The agent id is new after each deploy, so a job signed for this PC before it was reimaged never runs again.
    if ("$($Job.agentId)" -ne "$($Identity.agentId)") { return 'it was made for an earlier install of this PC' }
    if (@($DoneIds) -contains "$($Job.id)") { return 'it ran here already' }
    $created = ConvertFrom-AgentTime $Job.createdAt
    $expires = ConvertFrom-AgentTime $Job.expiresAt
    if (-not $created -or -not $expires) { return 'its times can''t be read' }
    $utc = $Now.ToUniversalTime()
    if ($expires.ToUniversalTime() -lt $utc.AddMinutes(-$ClockSkewMinutes)) { return "it expired at $($expires.ToLocalTime().ToString('yyyy-MM-dd HH:mm'))" }
    if ($created.ToUniversalTime() -gt $utc.AddMinutes($ClockSkewMinutes)) { return 'it was made in the future (is this PC''s clock right?)' }
    if ($Job.action -eq 'reimage' -and "$($Job.bootWimSha256)" -notmatch '^[0-9A-Fa-f]{64}$') { return 'it has no boot image checksum' }
    if ($Job.action -eq 'update' -and "$(if ($Job.PSObject.Properties['payloadSha256']) { $Job.payloadSha256 })" -notmatch '^[0-9A-Fa-f]{64}$') { return 'it has no checksum for the agent files' }
    if ($Job.action -eq 'installapps') {
        if (-not (Get-AgentJobApps $Job)) { return 'it names no application' }
        if ("$(if ($Job.PSObject.Properties['payloadSha256']) { $Job.payloadSha256 })" -notmatch '^[0-9A-Fa-f]{64}$') { return 'it has no checksum for the application packs' }
        # App names become folder names here.
        if (@(Get-AgentJobApps $Job | Where-Object { $_ -match '[\\/:*?"<>|]|\.\.' })) { return 'an application name is not a folder name' }
    }
    $null
}

function Update-AgentDeployStatus {
    # PC: after an install apps job, each app's new result on this PC's Dashboard row (Update-DeployAppResults).
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)][string]$Serial, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results, [datetime]$Now = (Get-Date))
    Update-DeployAppResults -StatusFolder $StatusFolder -Id (Get-StatusId -Serial $Serial) -Results $Results -By 'the agent' -Now $Now
}

function Sync-AgentBitLockerCheck {
    <#
    .SYNOPSIS
        PC: checks BitLocker again while the deploy result still says it is off. First boot's checks run before the
        first logon, so a FIRSTLOGON task that turns BitLocker on (GWHZLG3: "Ready, with warnings: BitLocker") was
        never seen. Once the drive is protected (or encrypting with a protector), the BitLocker check passes in
        deploy-result.json (last-check.json on a PC deployed before it existed), C:\Windows\Temp\DeployResult.txt
        and this PC's Dashboard row. Returns the new check when it changed, else $null. A share it can't reach is
        tried again next time (the PC's own file is saved last).
    #>
    param(
        [string]$ToolDir = "$env:ProgramData\ImagingTool",
        [string]$ResultPath = "$env:WINDIR\Temp\DeployResult.txt",
        [string]$StatusFolder,
        [string]$Serial,
        $BitLocker,                  # Get-BitLockerFacts' answer; read from the PC when not given (tests give it)
        [datetime]$Now = (Get-Date)
    )
    $dataPath = [IO.Path]::Combine($ToolDir, 'deploy-result.json')
    $reportPath = [IO.Path]::Combine($ToolDir, 'last-check.json')
    $data = Read-LocalDeployResult -Path $dataPath
    $report = if (-not $data -and [IO.File]::Exists($reportPath)) { [IO.File]::ReadAllText($reportPath) | ConvertFrom-Json } else { $null }
    $source = if ($data) { $data } else { $report }
    if (-not $source) { return $null }
    $old = @(@(if ($source.PSObject.Properties['checks']) { $source.checks }) | Where-Object { $_ -and $_.name -eq 'BitLocker' }) | Select-Object -First 1
    if (-not $old -or "$($old.result)" -eq 'Passed') { return $null }
    if (-not $PSBoundParameters.ContainsKey('BitLocker')) { $BitLocker = Get-BitLockerFacts }
    $check = Get-BitLockerCheck -BitLocker $BitLocker -Outcome "$($old.result)"
    if ($check.result -ne 'Passed') { return $null }

    # The Dashboard first: when the share is down, nothing is saved and the next check-in tries again.
    if ($StatusFolder -and $Serial) {
        $null = Update-DeployCheckResults -StatusFolder $StatusFolder -Id (Get-StatusId -Serial $Serial) -Results @($check) -By 'the agent' -Now $Now `
            -CheckWarning { param($all) ConvertTo-CheckWarning (Get-PostDeployCheckSummary -Results @($all)) }
    }
    # The whole result made again from deploy-result.json (one line changed on PCs deployed before it existed).
    $null = Update-LocalDeployResult -Results @($check) -DataPath $dataPath -ResultPath $ResultPath
    $checks = Merge-CheckResults -Checks @($source.checks) -Results @($check)
    if ($data) { Save-LocalDeployResult -Checks $checks -Path $dataPath }
    else {
        $summary = Get-PostDeployCheckSummary -Results $checks
        $saved = [pscustomobject]@{ checked = $Now.ToString('o'); result = $summary.Result; summary = $summary.Text; checks = $checks }
        [IO.File]::WriteAllText($reportPath, (ConvertTo-Json -InputObject $saved -Depth 4), (New-Object Text.UTF8Encoding $true))
    }
    $check
}

#endregion

#region Check-ins

function New-AgentCheckIn {
    <#
    .SYNOPSIS
        The record a PC writes to Status\Agents\<serial>.json. Identity: serial, uuid, maker, model, firmware.
        Network: ipAddresses, macAddress. Deploy: from agent.json (answer file, image, tool version, deployed).
        Job: the last job's { id, state, message, at }.
    #>
    param(
        [Parameter(Mandatory)]$Identity,
        $Network,
        $Deploy,
        [Parameter(Mandatory)][string]$AgentId,
        [string]$AgentVersion,
        [string]$AgentCode,
        [int]$CheckInSeconds = 30,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$Account,
        [string]$AccountSid,
        [string]$Os,
        [string]$UserSignedIn,
        [string]$UserSessionId,
        [string]$RemoteSupport,
        [Nullable[datetime]]$BootTime,
        [Nullable[int64]]$FreeC,
        [string]$Result,
        $Job,
        [string]$RemoteDesktop,
        [datetime]$Now = (Get-Date)
    )
    $get = { param($o, $n) if ($o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $ips = @(& $get $Network 'ipAddresses' | Where-Object { $_ })
    [pscustomobject][ordered]@{
        computerName   = "$ComputerName".ToUpperInvariant()
        serial         = "$($Identity.serial)".Trim()
        uuid           = "$($Identity.uuid)".Trim()
        maker          = "$(& $get $Identity 'maker')"
        model          = "$(& $get $Identity 'model')"
        firmware       = "$(& $get $Identity 'firmware')"
        firmwareFrom   = "$(& $get $Identity 'firmwareFrom')"
        account        = $Account
        accountSid     = $AccountSid
        ipAddress      = $(if ($ips) { "$($ips[0])" } else { '' })
        ipAddresses    = @($ips)
        macAddress     = "$(& $get $Network 'macAddress')"
        wired          = $(& $get $Network 'wired')
        os             = $Os
        userSignedIn   = $UserSignedIn
        # The signed-in user's Windows session, which remote support joins (mstsc /shadow).
        userSessionId  = $UserSessionId
        remoteSupport  = $RemoteSupport
        # A [Nullable[datetime]] parameter holds a plain date in PowerShell (no .Value): that was GWHZLG3's
        # "cannot call a method on a null-valued expression" at every start.
        bootTime       = $(if ($BootTime) { ([datetime]$BootTime).ToString('o') } else { '' })
        freeC          = $FreeC
        answerFile     = "$(& $get $Deploy 'answerFile')"
        image          = "$(& $get $Deploy 'image')"
        toolVersion    = "$(& $get $Deploy 'toolVersion')"
        deployedAt     = "$(& $get $Deploy 'deployedAt')"
        result         = $Result
        remoteDesktop  = $RemoteDesktop
        agentId        = $AgentId
        agentVersion   = $AgentVersion
        agentCode      = $AgentCode
        # Minutes too, rounded up: a console from before checkInSeconds reads only that.
        checkInMinutes = [int][Math]::Max(1, [Math]::Ceiling($CheckInSeconds / 60))
        checkInSeconds = $CheckInSeconds
        lastSeen       = $Now.ToUniversalTime().ToString('o')
        job            = $Job
    }
}

function Save-AgentCheckIn {
    param([Parameter(Mandatory)][string]$StatusFolder, [Parameter(Mandatory)]$Record)
    $dir = Get-AgentFolder $StatusFolder
    [void][IO.Directory]::CreateDirectory($dir)
    Save-JsonFile -Path (Join-AgentPath $dir "$(ConvertTo-SerialKey $Record.serial).json") -InputObject $Record -Depth 4
}

function Get-AgentCheckIns {
    <#
    .SYNOPSIS
        Console: every PC's last check-in, with LastSeen (local time), Online (checked in within 3 check-in intervals,
        plus 30 s for a slow share: about 2 minutes at the 30-second default)
        and LastSeenText. One per computer name: the newest when a PC got a new serial (board swap).
    #>
    param([Parameter(Mandatory)][string]$StatusFolder, [datetime]$Now = (Get-Date))
    $dir = Get-AgentFolder $StatusFolder
    $rows = @(foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue)) {
        try { $r = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
        if (-not $r.serial -or -not $r.lastSeen) { continue }
        $seen = ConvertFrom-AgentTime $r.lastSeen
        if (-not $seen) { continue }
        $seen = $seen.ToLocalTime()
        # An agent from before checkInSeconds checks in every checkInMinutes.
        $every = if ($r.PSObject.Properties['checkInSeconds'] -and $r.checkInSeconds) { [Math]::Max(10, [int]$r.checkInSeconds) }
                 else { 60 * [Math]::Max(1, [int]$(if ($r.checkInMinutes) { $r.checkInMinutes } else { 5 })) }
        $r | Add-Member -NotePropertyName LastSeen -NotePropertyValue $seen -Force
        $r | Add-Member -NotePropertyName CheckInSeconds -NotePropertyValue $every -Force
        $r | Add-Member -NotePropertyName Online -NotePropertyValue (($Now - $seen).TotalSeconds -le (3 * $every + 30)) -Force
        $r | Add-Member -NotePropertyName LastSeenText -NotePropertyValue (Format-AgentLastSeen -LastSeen $seen -Now $Now) -Force
        $r
    })
    @($rows | Sort-Object LastSeen -Descending | Group-Object { "$($_.computerName)".ToUpperInvariant() } | ForEach-Object { $_.Group[0] })
}

function Find-AgentCheckIn {
    # A computer's check-in by name (or by serial), or $null.
    param([object[]]$CheckIns, [string]$ComputerName, [string]$Serial)
    if ($Serial) { $s = @($CheckIns | Where-Object { "$($_.serial)".Trim() -eq $Serial.Trim() }); if ($s) { return $s[0] } }
    if ($ComputerName) {
        $n = @($CheckIns | Where-Object { "$($_.computerName)" -eq $ComputerName.ToUpperInvariant() })
        if ($n) { return $n[0] }
    }
    $null
}

function Format-AgentLastSeen {
    # 'Just now', '7 min ago', '3 h ago', 'Yesterday 14:05', '2026-11-20 09:12'.
    param([Parameter(Mandatory)][datetime]$LastSeen, [datetime]$Now = (Get-Date))
    $ago = $Now - $LastSeen
    if ($ago.TotalMinutes -lt 1) { return 'Just now' }
    if ($ago.TotalMinutes -lt 60) { return "$([int][Math]::Floor($ago.TotalMinutes)) min ago" }
    if ($ago.TotalHours -lt 12) { return "$([int][Math]::Floor($ago.TotalHours)) h ago" }
    if ($LastSeen.Date -eq $Now.Date.AddDays(-1)) { return "Yesterday $($LastSeen.ToString('HH:mm'))" }
    if ($LastSeen.Date -eq $Now.Date) { return "Today $($LastSeen.ToString('HH:mm'))" }
    $LastSeen.ToString('yyyy-MM-dd HH:mm')
}

function Get-AgentKnownAddresses {
    <#
    .SYNOPSIS
        Address -> the IPv4 addresses each PC's agent reported in its last check-in, for Get-RemoteOnlineState
        -KnownAddress: DNS can hold an old address, the PC's own report is fresher. Targets: objects with Name, Address.
    #>
    param($CheckIns, $Targets)
    $known = @{}
    foreach ($t in @($Targets | Where-Object { $_ })) {
        $a = Find-AgentCheckIn -CheckIns @($CheckIns) -ComputerName "$($t.Name)"
        if (-not $a) { continue }
        $ips = @(@("$($a.ipAddress)") + @($a.ipAddresses) | Where-Object { "$_" } | ForEach-Object { "$_" } | Select-Object -Unique)
        if ($ips) { $known["$($t.Address)"] = $ips }
    }
    $known
}

function ConvertTo-AgentTargetInfo {
    # A check-in as the record Test-RemoteTarget checks (ComputerName, Firmware, Serial, Model, FreeC, BitLocker).
    param([Parameter(Mandatory)]$CheckIn)
    # An agent from before firmwareFrom read PEFirmwareType, which Windows does not have: it said Legacy on UEFI PCs.
    $fw = if ($CheckIn.PSObject.Properties['firmwareFrom'] -and "$($CheckIn.firmwareFrom)") { "$($CheckIn.firmware)" } else { 'Unknown' }
    [pscustomobject]@{
        ComputerName = "$($CheckIn.computerName)"; Firmware = $fw; Serial = "$($CheckIn.serial)"; Uuid = "$($CheckIn.uuid)"
        Model = "$($CheckIn.model)"; FreeC = $(if ($CheckIn.freeC) { [int64]$CheckIn.freeC } else { $null }); BitLocker = ''
    }
}

function Get-AgentRowView {
    <#
    .SYNOPSIS
        Console, Computers tab: what the one Agent column shows for a PC, from its agent's check-in and the network
        check (Get-RemoteOnlineState). A reimage goes through the agent only, so the column leads with it: "v1.35, seen
        2 min ago", "v1.30 updating, ...", "v1.20 old, ..." (needs Install agent once), "v1.35, off (seen yesterday ...)";
        a PC with no agent shows what the network check found ("None, PC online": Install agent can reach it).
        -Checking: the network check is still running.
    #>
    param($Check, $Agent, [string]$Name, [string]$CurrentCode, [switch]$Checking)
    $version = Get-AgentVersionText -Agent $Agent -CurrentCode $CurrentCode
    $detail = @()
    if ($Agent) {
        $v = if ($Agent.PSObject.Properties['agentVersion'] -and $Agent.agentVersion) { "$($Agent.agentVersion)" -replace '\s*\(.*\)$' } else { 'Agent' }
        if ($version.Text -eq 'Updating') { $v += ' updating' } elseif ($version.Text -eq 'Old') { $v += ' old' }
        $seen = "$($Agent.LastSeenText)"
        if ($seen -notmatch '^\d') { $seen = $seen.Substring(0, 1).ToLowerInvariant() + $seen.Substring(1) }
        $text = if ($Agent.Online) { "$v, seen $seen" } else { "$v, off (seen $seen)" }
        $detail += $(if ($Agent.Online) { "Its agent checked in ${seen}: Reimage goes through it." } else { "Its agent has not checked in since ${seen}: turn the PC on (and connect it to the network) before Reimage." })
        $detail += "Last check-in $($Agent.LastSeen.ToString('yyyy-MM-dd HH:mm')) from $(if ($Agent.ipAddress) { $Agent.ipAddress } else { 'no IPv4 address' })"
        if ($Agent.answerFile -or $Agent.image) { $detail += "Deployed with $((@("$($Agent.answerFile)", "$($Agent.image)") | Where-Object { $_ }) -join ', ')$(if ($Agent.deployedAt) { " on $("$($Agent.deployedAt)".Substring(0, [Math]::Min(10, "$($Agent.deployedAt)".Length)))" })" }
        if ($Agent.result) { $detail += "$($Agent.result)" }
        if ($Agent.userSignedIn) { $detail += "Signed in: $($Agent.userSignedIn)" }
        if ($Agent.PSObject.Properties['remoteDesktop'] -and "$($Agent.remoteDesktop)") { $detail += "Remote Desktop: $($Agent.remoteDesktop)" }
        if ($Agent.PSObject.Properties['remoteSupport'] -and "$($Agent.remoteSupport)") { $detail += "Remote support: $($Agent.remoteSupport)" }
        if ($Agent.job -and $Agent.job.state) { $detail += "Last job: $($Agent.job.action) $($Agent.job.state)$(if ($Agent.job.message) { " ($($Agent.job.message))" })" }
        if ($version.Detail) { $detail += $version.Detail }
    } else {
        $state = if ($Check) { "$($Check.State)" } else { '' }
        $text = if ($Checking -and -not $Check) { 'None, checking...' } else {
            switch ($state) {
                'Yes'       { 'None, PC online' }
                'Yes (SMB)' { 'None, PC online' }
                'No access' { 'None, PC blocked' }
                'Not found' { 'None, name not found' }
                'Old DNS'   { 'None, old DNS' }
                'No answer' { 'None, PC off' }
                default     { 'None' }
            }
        }
        $detail += $(if ($Check -and $Check.Online) { 'No agent: select the PC and click Install agent, then Reimage.' } else { 'No agent: it is put on each PC deployed while the network share is set, or with Install agent (the PC must be on, with PowerShell remoting or file sharing allowed).' })
    }
    if ($Check) { $detail += "$Name $($Check.Detail)" }
    [pscustomobject]@{ Agent = $text; AgentDetail = ($detail -join "`n") }
}

function Get-AgentVersionText {
    <#
    .SYNOPSIS
        Console, Computers tab's Agent column: is a PC's agent the console's (agentCode = Get-AgentCodeHash of
        the console's src folder)? { Text, Detail }. An old agent that knows update jobs gets the new one by itself
        (Select-AgentsToUpdate); one from before them needs Install agent once.
    #>
    param($Agent, [string]$CurrentCode)
    if (-not $Agent) { return [pscustomobject]@{ Text = ''; Detail = $null } }
    $code = if ($Agent.PSObject.Properties['agentCode']) { "$($Agent.agentCode)" } else { '' }
    $from = if ($Agent.PSObject.Properties['agentVersion'] -and $Agent.agentVersion) { " (tool version $($Agent.agentVersion))" } else { '' }
    if (-not $code) { return [pscustomobject]@{ Text = 'Old'; Detail = "This agent is from before automatic updates$from. Select the PC and click Install agent once; after that the console updates it by itself." } }
    if (-not $CurrentCode -or $code -eq $CurrentCode) { return [pscustomobject]@{ Text = 'Up to date'; Detail = "Agent $code$from" } }
    $job = if ($Agent.PSObject.Properties['job'] -and $Agent.job -and "$($Agent.job.action)" -eq 'update') { " Last update: $($Agent.job.state)$(if ($Agent.job.message) { " ($($Agent.job.message))" })." } else { '' }
    [pscustomobject]@{ Text = 'Updating'; Detail = "Agent $code, the console has $CurrentCode. The console sends it the new agent while it is on.$job" }
}

function Select-AgentsToUpdate {
    <#
    .SYNOPSIS
        Console: the online agents whose code is not the console's and that know update jobs (they report agentCode),
        not sent the console's code yet (-Sent: serial -> code, kept by the console while it runs).
    #>
    param([object[]]$CheckIns = @(), [Parameter(Mandatory)][string]$CurrentCode, [hashtable]$Sent = @{})
    @($CheckIns | Where-Object {
        $_ -and $_.Online -and $_.PSObject.Properties['agentCode'] -and "$($_.agentCode)" -and "$($_.agentCode)" -ne $CurrentCode -and
        $_.agentId -and $Sent["$($_.serial)"] -ne $CurrentCode
    })
}

function Get-SilentAgents {
    <#
    .SYNOPSIS
        Console, Dashboard: agents that have not checked in for more than -Days (1) but fewer than -MaxDays (14: a PC
        gone longer was most likely retired). The PC is off, or its agent stopped: a reimage would not reach it.
    #>
    param([object[]]$CheckIns = @(), [double]$Days = 1, [double]$MaxDays = 14, [datetime]$Now = (Get-Date))
    @($CheckIns | Where-Object { $_ -and $_.LastSeen -and ($Now - $_.LastSeen).TotalDays -gt $Days -and ($Now - $_.LastSeen).TotalDays -le $MaxDays } |
        Sort-Object LastSeen)
}

#endregion

#region The share's rights

function Get-DomainComputersSid {
    # Domain Computers (RID 515) from any account SID of the domain (the console PC's computer account): by SID, so a
    # French domain's "Ordinateurs du domaine" works the same.
    param([Parameter(Mandatory)][string]$DomainAccountSid)
    if ($DomainAccountSid -notmatch '^(S-1-5-21-\d+-\d+-\d+)-\d+$') { throw "Not a domain account SID: $DomainAccountSid" }
    "$($Matches[1])-515"
}

function Resolve-LocalSharePath {
    <#
    .SYNOPSIS
        \\IMAGER\imager\Status -> C:\imager\Status when the share is on this PC (its name, full name, localhost or
        127.0.0.1), else $null. Shares: name -> local path (Get-SmbShare on Windows; tests pass a hashtable).
    #>
    param([Parameter(Mandatory)][string]$Unc, [hashtable]$Shares, [string[]]$ThisPC = @($env:COMPUTERNAME))
    if ($Unc -notmatch '^\\\\([^\\]+)\\([^\\]+)(\\.*)?$') { return $null }
    $hostName = $Matches[1]; $share = $Matches[2]; $rest = "$($Matches[3])".TrimStart('\')
    $names = @($ThisPC | Where-Object { $_ } | ForEach-Object { "$_".ToUpperInvariant() }) + 'LOCALHOST', '127.0.0.1'
    if ($names -notcontains ($hostName.Split('.')[0].ToUpperInvariant()) -and $names -notcontains $hostName.ToUpperInvariant()) { return $null }
    $key = @($Shares.Keys | Where-Object { "$_" -eq $share })[0]
    if (-not $key) { return $null }
    $local = "$($Shares[$key])".TrimEnd('\')
    [pscustomobject]@{ Share = $key; Path = $(if ($rest) { "$local\$rest" } else { $local }) }
}

function Grant-StatusFolderAccess {
    <#
    .SYNOPSIS
        Lets the agents (and first boot) write their status: Domain Computers modify rights on the Status folder, and
        Change on its share, when that share is on this PC. Only adds, never takes anything away. Returns
        { Changed, Lines }: what it found or did, for the log. Needs admin rights (the console runs with them).
    #>
    param([Parameter(Mandatory)][string]$StatusFolder)
    $lines = [Collections.Generic.List[string]]::new()
    $changed = $false
    $shares = @{}
    try { foreach ($s in @(Get-SmbShare -ErrorAction Stop)) { $shares[$s.Name] = $s.Path } } catch { }
    $local = Resolve-LocalSharePath -Unc $StatusFolder -Shares $shares -ThisPC @($env:COMPUTERNAME)
    if (-not $local) {
        $lines.Add("$StatusFolder is not a share on this PC: on its server, give Domain Computers modify rights on that folder and Change on the share.")
        return [pscustomobject]@{ Changed = $false; Lines = @($lines) }
    }
    $me = ([Security.Principal.NTAccount]"$env:USERDOMAIN\$env:COMPUTERNAME`$").Translate([Security.Principal.SecurityIdentifier]).Value
    $dc = Get-DomainComputersSid $me
    $dcName = try { ([Security.Principal.SecurityIdentifier]$dc).Translate([Security.Principal.NTAccount]).Value } catch { $dc }
    [void][IO.Directory]::CreateDirectory($local.Path)
    # The folder: an allow rule for Domain Computers with at least Modify, passed on to what is in it.
    $modify = [Security.AccessControl.FileSystemRights]::Modify
    $hasNtfs = @((Get-Acl -LiteralPath $local.Path).Access | Where-Object {
        $_.AccessControlType -eq 'Allow' -and (($_.FileSystemRights -band $modify) -eq $modify) -and
        $(try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in $dc, 'S-1-1-0', 'S-1-5-11' } catch { $false })
    }).Count -gt 0
    if ($hasNtfs) { $lines.Add("$($local.Path): Domain Computers can already write there.") }
    else {
        $o = & icacls.exe $local.Path /grant "*${dc}:(OI)(CI)M" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not give $dcName modify rights on $($local.Path): $(@($o) -join ' ')" }
        $lines.Add("$($local.Path): gave $dcName modify rights."); $changed = $true
    }
    # The share: Change or Full for Domain Computers, Everyone or Authenticated Users.
    $hasShare = @(Get-SmbShareAccess -Name $local.Share -ErrorAction Stop | Where-Object {
        $_.AccessControlType -eq 'Allow' -and "$($_.AccessRight)" -in 'Change', 'Full' -and
        $(try { ([Security.Principal.NTAccount]"$($_.AccountName)").Translate([Security.Principal.SecurityIdentifier]).Value -in $dc, 'S-1-1-0', 'S-1-5-11' } catch { $false })
    }).Count -gt 0
    if ($hasShare) { $lines.Add("Share $($local.Share): Domain Computers can already change files there.") }
    else {
        Grant-SmbShareAccess -Name $local.Share -AccountName $dcName -AccessRight Change -Force -ErrorAction Stop | Out-Null
        $lines.Add("Share $($local.Share): gave $dcName Change."); $changed = $true
    }
    [pscustomobject]@{ Changed = $changed; Lines = @($lines) }
}

# Runs on the PC (here, or sent over a remote channel, so it uses nothing from this module): the last -Tail lines of
# the agent's log and its task's state and last result.
$script:AgentStateScript = {
    param([int]$Tail = 15)
    $log = "$env:WINDIR\Temp\ImagingAgent.log"
    $lines = if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log -Tail $Tail -Encoding UTF8) } else { @() }
    $task = Get-ScheduledTask -TaskPath '\ImagingTool\' -TaskName 'Agent' -ErrorAction SilentlyContinue
    $info = if ($task) { $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue }
    [pscustomobject]@{ Lines = $lines; State = $(if ($task) { "$($task.State)" } else { '' }); Result = $(if ($info) { '0x{0:X}' -f [int64]$info.LastTaskResult } else { '' }) }
}

function Get-AgentStateScript { $script:AgentStateScript }

function Get-AgentLocalState {
    # This PC's agent: { Lines; State; Result } (Install-AgentHere.ps1). Over the network: Get-AgentStateScript.
    param([int]$Tail = 15)
    & $script:AgentStateScript $Tail
}

function Get-AgentLogProblem {
    <#
    .SYNOPSIS
        One line saying why an agent did not check in, from the end of its log (C:\Windows\Temp\ImagingAgent.log) and its
        task's state. Lines: the log's last lines ($null: no log, it never started). TaskState / TaskResult: from
        Get-ScheduledTask / Get-ScheduledTaskInfo.
    #>
    param([string[]]$Lines, [string]$TaskState, [string]$TaskResult,
          $State)   # or what Get-AgentLocalState / Get-AgentStateScript returned
    if ($State) { $Lines = @($State.Lines); $TaskState = "$($State.State)"; $TaskResult = "$($State.Result)" }
    $Lines = @($Lines | Where-Object { "$_".Trim() })
    if (-not $Lines) {
        $t = if ($TaskState) { "task $TaskState$(if ($TaskResult) { ", last result $TaskResult" })" } else { 'no task ImagingTool\Agent' }
        return "The agent never started ($t)"
    }
    $text = { param($l) ($l -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ', '').Trim() }
    $bad = @($Lines | Where-Object { $_ -match 'Could not check in|stops|stopped|Could not read' }) | Select-Object -Last 1
    if ($bad) {
        $t = & $text $bad
        if ($t -match '(?i)Could not check in' -and $t -match '(?i)denied|refus') { return "The PC's computer account may not write to the share: $t" }
        return $t
    }
    "Last agent log line: $(& $text $Lines[-1])"
}

#endregion

#region Installing it

function Get-AgentCheckInSeconds {
    # deploy-settings.json agent.checkInSeconds: how often the agents check in (30 by default, at least 10). The old
    # checkInMinutes setting is not read: at 5 minutes the console could not show the PCs close to real time.
    param($Settings)
    $cfg = if ($Settings -and $Settings.PSObject.Properties['agent']) { $Settings.agent } else { $null }
    if ($cfg -and $cfg.PSObject.Properties['checkInSeconds'] -and $cfg.checkInSeconds) { return [Math]::Max(10, [int]$cfg.checkInSeconds) }
    30
}

# Remote Desktop on agent PCs: the agent turns it on (Network Level Authentication required, firewall open on the
# Domain profile only) unless agent.json says remoteDesktop false, and says in its check-in whether it is on. The
# console's Remote support button joins the signed-in user's screen over it (mstsc /shadow). Who may sign in is not changed: the PC's
# Administrators (Domain Admins on a domain PC) and its Remote Desktop Users group, which is empty unless IT fills it.
$script:RdpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$script:RdpTcpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
$script:RdpPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
# The built-in "Remote Desktop" firewall rules, by their group's resource name (the same on every Windows language).
$script:RdpFirewallGroup = '@FirewallAPI.dll,-28752'

function Get-RemoteDesktopPlan {
    <#
    .SYNOPSIS
        What the agent changes to have Remote Desktop on with NLA, reachable on the Domain firewall profile only, and
        what it reports. -State: { deny, nla, policyDeny, policyNla } (registry DWORDs or $null) and rules: the
        Remote Desktop group's firewall rules { name, enabled, profile }. Returns { Allow, Nla, Rules (name, enabled,
        profile to set), Text }. A group policy that turns Remote Desktop off or NLA off wins: nothing is forced
        against it, and Text says so.
        Remote support (joining the signed-in user's own screen, mstsc /shadow): policyShadow is the Terminal Services
        policy 'Shadow' (0 none, 1 control with the user's permission, 2 control without, 3 view with permission,
        4 view without). Not set: the agent sets 1, so the user is always asked first. Shadow = set it; SupportText.
    #>
    param([Parameter(Mandatory)]$State, [switch]$Off)
    $get = { param($n) if ($State.PSObject.Properties[$n] -and $null -ne $State.$n -and "$($State.$n)" -ne '') { [int]$State.$n } else { $null } }
    $deny = & $get 'deny'; $nla = & $get 'nla'; $pDeny = & $get 'policyDeny'; $pNla = & $get 'policyNla'; $pShadow = & $get 'policyShadow'
    $support = switch ($pShadow) {
        $null { 'Ready: the user is asked first' }
        0 { 'Off: a group policy turns remote control off on this PC' }
        1 { 'Ready: the user is asked first' }
        2 { 'Ready, but a group policy lets IT take control without asking the user' }
        3 { 'View only: a group policy allows watching the screen, not control (the user is asked first)' }
        4 { 'View only, without asking the user (group policy)' }
        default { "Unknown remote control policy ($pShadow)" }
    }
    $rules = @($State.rules | Where-Object { $_ })
    $on = $(if ($null -ne $pDeny) { $pDeny -eq 0 } else { $deny -eq 0 })
    if ($Off) {
        # Turned off in the agent settings: left as it is, only reported.
        $s = if ($null -eq $pShadow -or -not $on) { 'Off (left as it is: turned off in the agent settings)' } else { $support }
        return [pscustomobject]@{ Allow = $false; Nla = $false; Shadow = $false; Rules = @(); Text = "$(if ($on) { 'On' } else { 'Off' }) (left as it is: turned off in the agent settings)"; SupportText = $s }
    }
    if ($pDeny -eq 1) { return [pscustomobject]@{ Allow = $false; Nla = $false; Shadow = $false; Rules = @(); Text = 'Off: a group policy turns Remote Desktop off on this PC'; SupportText = 'Off: a group policy turns Remote Desktop off on this PC' } }
    $set = @(foreach ($r in $rules) {
        $profile = "$($r.profile)"
        $domain = $profile -match 'Domain|Any' -or $profile -eq '0' -or $profile -eq ''
        # Rules that cover the Domain profile are opened for it only; the others (Private, Public) stay closed.
        $wantEnabled = [bool]$domain
        $wantProfile = if ($domain) { 'Domain' } else { $profile }
        if ([bool]$r.enabled -ne $wantEnabled -or ($domain -and $profile -ne 'Domain')) {
            [pscustomobject]@{ name = "$($r.name)"; enabled = $wantEnabled; profile = $wantProfile }
        }
    })
    $text = if (-not $rules) { 'On, but no Remote Desktop firewall rule was found on this PC' }
        elseif ($pNla -eq 0) { 'On, but a group policy turns Network Level Authentication off' }
        else { 'On (Network Level Authentication, Domain network only)' }
    [pscustomobject]@{ Allow = ($deny -ne 0 -and $null -eq $pDeny); Nla = ($nla -ne 1 -and $pNla -ne 0); Shadow = ($null -eq $pShadow); Rules = $set; Text = $text; SupportText = $support }
}

function Get-RemoteDesktopState {
    # This PC's Remote Desktop settings for Get-RemoteDesktopPlan (as SYSTEM or an administrator).
    $read = { param($key, $name) try { $v = (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop).$name; if ($null -ne $v) { [int]$v } } catch { $null } }
    $rules = @(Get-NetFirewallRule -Group $script:RdpFirewallGroup -PolicyStore PersistentStore -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ name = "$($_.Name)"; enabled = ("$($_.Enabled)" -eq 'True'); profile = "$($_.Profile)" }
    })
    [pscustomobject]@{
        deny = & $read $script:RdpKey 'fDenyTSConnections'
        nla = & $read $script:RdpTcpKey 'UserAuthentication'
        policyDeny = & $read $script:RdpPolicyKey 'fDenyTSConnections'
        policyNla = & $read $script:RdpPolicyKey 'UserAuthentication'
        policyShadow = & $read $script:RdpPolicyKey 'Shadow'
        rules = $rules
    }
}

function Sync-AgentRemoteDesktop {
    <#
    .SYNOPSIS
        On the PC (the agent, as SYSTEM): turns Remote Desktop on with NLA and opens its firewall rules on the Domain
        profile only, where they are not already, and allows remote support with the user's permission (policy
        Shadow 1, only when no policy sets it). Returns { Text, SupportText, Changed (what it did, for the log) }.
    #>
    param([switch]$Off)
    $plan = Get-RemoteDesktopPlan -State (Get-RemoteDesktopState) -Off:$Off
    $changed = @()
    if ($plan.Nla) { Set-ItemProperty -LiteralPath $script:RdpTcpKey -Name UserAuthentication -Value 1 -Type DWord -ErrorAction Stop; $changed += 'Network Level Authentication required' }
    if ($plan.Allow) { Set-ItemProperty -LiteralPath $script:RdpKey -Name fDenyTSConnections -Value 0 -Type DWord -ErrorAction Stop; $changed += 'Remote Desktop turned on' }
    if ($plan.Shadow) {
        if (-not (Test-Path -LiteralPath $script:RdpPolicyKey)) { $null = New-Item -Path $script:RdpPolicyKey -Force -ErrorAction Stop }
        Set-ItemProperty -LiteralPath $script:RdpPolicyKey -Name Shadow -Value 1 -Type DWord -ErrorAction Stop
        $changed += 'remote support allowed, with the user''s permission'
    }
    foreach ($r in @($plan.Rules)) {
        if ($r.enabled) { Set-NetFirewallRule -Name $r.name -Profile Domain -Enabled True -ErrorAction Stop; $changed += "firewall rule $($r.name) open on the Domain network only" }
        else { Set-NetFirewallRule -Name $r.name -Enabled False -ErrorAction Stop; $changed += "firewall rule $($r.name) closed" }
    }
    [pscustomobject]@{ Text = $plan.Text; SupportText = $plan.SupportText; Changed = $changed }
}

function Test-AgentRemoteDesktopOn {
    # deploy-settings.json agent.remoteDesktop: on unless it is false.
    param($Settings)
    $cfg = if ($Settings -and $Settings.PSObject.Properties['agent']) { $Settings.agent } else { $null }
    -not ($cfg -and $cfg.PSObject.Properties['remoteDesktop'] -and $cfg.remoteDesktop -eq $false)
}

function Get-RemoteDesktopTarget {
    <#
    .SYNOPSIS
        Console: what mstsc connects to for a PC. Its DNS name when DNS gives an address the agent reported (Kerberos
        signs in with NLA); else the IP its agent reported (DNS is old or the PC moved); else the name. -Check: the
        network check (Get-RemoteOnlineState: Ip = what DNS gives). Returns '' when there is nothing to connect to.
    #>
    param([string]$Name, $Agent, $Check)
    $agentIps = @(if ($Agent -and $Agent.Online) { @($Agent.ipAddresses) + "$($Agent.ipAddress)" | Where-Object { "$_" } })
    $dnsIp = if ($Check -and $Check.PSObject.Properties['Ip']) { "$($Check.Ip)" } else { '' }
    $stale = $Check -and $Check.PSObject.Properties['State'] -and "$($Check.State)" -in 'Old DNS', 'Not found'
    if ($Name -and $Name -notmatch '^\d+(\.\d+){3}$' -and -not $stale -and (-not $agentIps -or -not $dnsIp -or $agentIps -contains $dnsIp)) { return $Name }
    if ($agentIps) { return "$($agentIps[0])" }
    "$Name"
}

function Get-RemoteSupportPlan {
    <#
    .SYNOPSIS
        Console: how to join a PC's signed-in user's screen. { Args (mstsc arguments) , Problem (one line, the
        reason it can't), Ask (one line to confirm first, or '') }. The user always gets Windows' own prompt to allow
        it, unless a group policy says otherwise (then Ask says so).
    #>
    param([string]$ComputerName, $Agent, [string]$Target)
    $no = { param($m) [pscustomobject]@{ Args = ''; Problem = $m; Ask = '' } }
    if (-not $Agent) { return & $no "$ComputerName has no agent checking in: Install agent first (Computers tab)." }
    if (-not $Agent.Online) { return & $no "$ComputerName's agent last checked in $("$($Agent.LastSeenText)".ToLowerInvariant()): the PC is probably off." }
    $support = if ($Agent.PSObject.Properties['remoteSupport']) { "$($Agent.remoteSupport)" } else { '' }
    if (-not $support) { return & $no "$ComputerName's agent is older than remote support: it updates itself within a few minutes, try again then." }
    if ($support -like 'Off*') { return & $no "Remote support on ${ComputerName}: $support" }
    $id = if ($Agent.PSObject.Properties['userSessionId']) { "$($Agent.userSessionId)" } else { '' }
    if (-not "$($Agent.userSignedIn)" -or $id -notmatch '^\d+$') { return & $no "Nobody is signed in on ${ComputerName}: remote support joins the screen of someone signed in." }
    $view = $support -like 'View only*'
    $ask = if ($support -match 'without asking') { "A group policy on $ComputerName lets you in without asking $($Agent.userSignedIn). Join their screen anyway?" } else { '' }
    $a = "/v:$Target /shadow:$id" + $(if (-not $view) { ' /control' })
    [pscustomobject]@{ Args = $a; Problem = ''; Ask = $ask }
}

function New-AgentConfig {
    # agent.json next to the agent: where to check in, the console keys it trusts, and what this deploy was.
    param(
        [Parameter(Mandatory)][string]$StatusFolder,
        [string[]]$PublicKeys,
        [int]$CheckInSeconds = 30,
        $Deploy,
        [bool]$RemoteDesktop = $true
    )
    [pscustomobject][ordered]@{
        statusFolder   = $StatusFolder
        checkInSeconds = [Math]::Max(10, $CheckInSeconds)
        publicKeys     = @($PublicKeys | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
        # Remote Desktop on, with NLA, Domain network only (Sync-AgentRemoteDesktop). Missing = on.
        remoteDesktop  = $RemoteDesktop
        deploy         = $Deploy
    }
}

function Get-AgentTaskXml {
    <#
    .SYNOPSIS
        Task Scheduler XML for ImagingTool\Agent: SYSTEM, at startup, and every 15 minutes in case it stopped (a second
        start while it runs is ignored). No time limit: it keeps running and checks in on its own.
    #>
    param([string]$ScriptPath = "$script:AgentDir\ImagingAgent.ps1")
    New-TaskXml -Description 'Imaging tool agent: tells the imaging console this PC is on, and takes the jobs the console signed (reimage).' `
        -Triggers ("<BootTrigger><Enabled>true</Enabled><Delay>PT1M</Delay></BootTrigger>`r`n    " +
                   '<TimeTrigger><StartBoundary>2020-01-01T00:00:00</StartBoundary><Repetition><Interval>PT15M</Interval></Repetition><Enabled>true</Enabled></TimeTrigger>') `
        -TimeLimit 'PT0S' -Settings '<StartWhenAvailable>true</StartWhenAvailable>', '<RestartOnFailure><Interval>PT5M</Interval><Count>3</Count></RestartOnFailure>', '<Priority>7</Priority>' `
        -Command 'powershell.exe' -Arguments "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
}

function Install-AgentOnRemotePC {
    <#
    .SYNOPSIS
        Console: puts the agent on a running PC over a remote channel (Open-RemoteChannel: WinRM, or the admin share and
        a one-time service), and starts it. For PCs imaged before the agent existed; newly deployed PCs get it at deploy.
    #>
    param(
        [Parameter(Mandatory)]$Channel,
        [Parameter(Mandatory)][string]$SourceDir,     # the console's src folder
        [Parameter(Mandatory)]$Config                 # New-AgentConfig
    )
    $dir = $script:AgentDir
    $acl = @($dir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
    Invoke-RemoteChannel -Channel $Channel -ArgumentList $dir, $acl -ScriptBlock {
        param($Dir, $AclArgs)
        # An agent already running keeps its old code (one at a time): stop it, -Register starts the new one.
        # try: with no task yet schtasks writes "file not found" to stderr, and under ErrorAction Stop (the Local and
        # Smb channels) PowerShell 5.1 makes that a terminating error (D2J14HL3: "Le fichier specifie est introuvable").
        try { & schtasks.exe /End /TN 'ImagingTool\Agent' 2>&1 | Out-Null } catch { }
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        # Administrators and SYSTEM only, before the scripts that run as SYSTEM go in.
        $o = & icacls.exe ([string[]]$AclArgs) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not limit $Dir to administrators: $o" }
    } | Out-Null
    foreach ($f in $script:AgentFiles) { Copy-ToRemoteChannel -Channel $Channel -Path (Join-AgentPath $SourceDir $f) -Destination "$dir\$f" }
    $json = ConvertTo-Json -InputObject $Config -Depth 6
    Invoke-RemoteChannel -Channel $Channel -ArgumentList $dir, $json, (Get-AgentTaskXml) -ScriptBlock {
        param($Dir, $Json, $TaskXml)
        [IO.File]::WriteAllText("$Dir\agent.json", $Json, (New-Object Text.UTF8Encoding $true))
        [IO.File]::WriteAllText("$Dir\agent-task.xml", $TaskXml, [Text.Encoding]::Unicode)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\ImagingAgent.ps1" -Register
        if ($LASTEXITCODE -ne 0) { throw "The agent's task could not be made (exit $LASTEXITCODE): see C:\Windows\Temp\ImagingAgent.log on the PC." }
    } | Out-Null
}

function Publish-AgentInstaller {
    <#
    .SYNOPSIS
        Console: puts what a PC needs to install the agent by itself in a folder on the share (<share>\Agent): the agent
        files, agent.json (the status folder and the console's public key, nothing secret) and Install-Agent.cmd.
        For a PC the console cannot reach: on that PC, run \\server\share\Agent\Install-Agent.cmd as administrator.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$SourceDir,     # the console's src folder
        [Parameter(Mandatory)]$Config                 # New-AgentConfig
    )
    [void][IO.Directory]::CreateDirectory($Folder)
    foreach ($f in @($script:AgentFiles + $script:AgentInstallerFiles)) {
        $src = Join-AgentPath $SourceDir $f
        $dst = Join-AgentPath $Folder $f
        $si = New-Object IO.FileInfo $src
        $di = New-Object IO.FileInfo $dst
        if ($di.Exists -and $di.Length -eq $si.Length -and $di.LastWriteTimeUtc -eq $si.LastWriteTimeUtc) { continue }
        [IO.File]::Copy($src, $dst, $true)
    }
    $json = ConvertTo-Json -InputObject $Config -Depth 6
    $cfg = Join-AgentPath $Folder 'agent.json'
    $old = try { [IO.File]::ReadAllText($cfg) } catch { $null }
    if ($old -ne $json) { [IO.File]::WriteAllText($cfg, $json, (New-Object Text.UTF8Encoding $true)) }
    $Folder
}

#endregion

Export-ModuleMember -Function Get-AgentStateScript, Get-AgentLocalState, Get-AgentInstallFolder, Get-AgentTaskName, Get-AgentFileNames, Get-AgentFolder, Get-AgentStatusFolder, Get-AgentJobFolder,
    New-AgentKeyPair, Get-AgentSigningKey, ConvertTo-AgentPublicKey, Get-AgentPublicKey, Get-AgentKeyId,
    Get-AgentJobText, Get-AgentPayloadHash, Get-AgentCodeHash, Get-AgentVersionText, Select-AgentsToUpdate, Get-SilentAgents, Copy-AgentFolder, Get-AgentJobApps, Update-AgentDeployStatus, Sync-AgentBitLockerCheck, Set-AgentJobSignature, Test-AgentJobSignature, New-AgentJob, Set-AgentJobFolderAccess, Get-AgentJob, Remove-AgentJob, Test-AgentJob,
    New-AgentCheckIn, Save-AgentCheckIn, Get-AgentCheckIns, Find-AgentCheckIn, Format-AgentLastSeen, ConvertTo-AgentTargetInfo, Get-AgentKnownAddresses, Get-AgentRowView,
    Get-AgentCheckInSeconds, New-AgentConfig, Get-AgentTaskXml, Get-RemoteDesktopPlan, Get-RemoteDesktopState, Sync-AgentRemoteDesktop, Test-AgentRemoteDesktopOn, Get-RemoteDesktopTarget, Get-RemoteSupportPlan, Install-AgentOnRemotePC, Publish-AgentInstaller, Get-DomainComputersSid, Resolve-LocalSharePath, Grant-StatusFolderAccess, Get-AgentLogProblem
