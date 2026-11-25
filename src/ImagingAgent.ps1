<#
.SYNOPSIS
    The agent on an imaged PC: checks in with the imaging console and takes the jobs it signed (reimage).
.DESCRIPTION
    Runs as SYSTEM from the scheduled task ImagingTool\Agent (at startup, and every 15 minutes in case it stopped),
    from C:\ProgramData\ImagingTool\Agent (administrators and SYSTEM only). Deploy-Image.ps1 puts it there with
    agent.json; FirstBoot.ps1 runs it once with -Register to make the task. The console can also put it on a PC that
    was imaged before (Computers tab, Install agent).
    Every CheckInMinutes (agent.json, 5 by default) it writes Status\Agents\<serial>.json on the share; every minute
    it looks for Status\Agents\Jobs\<serial>\job.json and runs it if the console signed it for this PC
    (ImagingAgent.psm1). Log: C:\Windows\Temp\ImagingAgent.log.
.PARAMETER Register
    Makes (or replaces) the ImagingTool\Agent task from agent-task.xml next to this script, starts it, and exits.
.PARAMETER Once
    One check-in and one look for a job, then exits (to test it by hand, as SYSTEM or an administrator).
#>
param([switch]$Register, [switch]$Once)

$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = "$env:WINDIR\Temp\ImagingAgent.log"
Import-Module ([IO.Path]::Combine($dir, 'ScriptLog.psm1')) -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $log -Message $Message }
# The log stays small: over 1 MB, the older half goes.
try {
    $fi = New-Object IO.FileInfo $log
    if ($fi.Exists -and $fi.Length -gt 1MB) {
        $lines = [IO.File]::ReadAllLines($log)
        [IO.File]::WriteAllLines($log, $lines[([int]($lines.Count / 2))..($lines.Count - 1)])
    }
} catch { }

if ($Register) {
    $xml = [IO.Path]::Combine($dir, 'agent-task.xml')
    $out = & schtasks.exe /Create /TN 'ImagingTool\Agent' /XML $xml /F 2>&1
    $code = $LASTEXITCODE
    Write-Log "Task ImagingTool\Agent made: exit $code $(@($out) -join ' ')"
    if ($code -ne 0) { exit $code }
    & schtasks.exe /Run /TN 'ImagingTool\Agent' 2>&1 | Out-Null
    Write-Log "Task ImagingTool\Agent started: exit $LASTEXITCODE"
    exit 0
}

# One agent at a time (the task starts it again every 15 minutes in case it stopped).
$mutex = New-Object Threading.Mutex($false, 'Global\ImagingToolAgent')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

Import-Module ([IO.Path]::Combine($dir, 'ImagingAgent.psm1')) -Force

$configPath = [IO.Path]::Combine($dir, 'agent.json')
try { $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json }
catch { Write-Log "Could not read ${configPath}: $($_.Exception.Message). The agent stops."; exit 1 }
$statusFolder = "$($config.statusFolder)"
$keys = @($config.publicKeys | Where-Object { $_ })
$every = [Math]::Max(1, [int]$(if ($config.checkInMinutes) { $config.checkInMinutes } else { 5 }))

# This install's id: new after every deploy, so a job signed for this PC before it was reimaged is never taken.
$statePath = [IO.Path]::Combine($dir, 'state.json')
$state = $null
try { $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json } catch { }
if (-not $state -or -not $state.agentId) { $state = [pscustomobject]@{ agentId = [guid]::NewGuid().ToString(); doneJobs = @(); lastJob = $null } }
if (-not $state.PSObject.Properties['doneJobs']) { $state | Add-Member -NotePropertyName doneJobs -NotePropertyValue @() }
if (-not $state.PSObject.Properties['lastJob']) { $state | Add-Member -NotePropertyName lastJob -NotePropertyValue $null }
function Save-State {
    try { [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state -Depth 4), (New-Object Text.UTF8Encoding $true)) }
    catch { Write-Log "Could not save ${statePath}: $($_.Exception.Message)" }
}
Save-State

function Get-Identity {
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $prod = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    # PEFirmwareType is only there in WinPE: in Windows the loader it started from says it (winload.efi = UEFI).
    # Reading PEFirmwareType alone made GWHZLG3 (UEFI) report legacy BIOS and refuse the reimage.
    $fw = 'Unknown'; $from = ''
    $bcd = "$(& bcdedit.exe /enum '{current}' 2>$null)"
    if ($bcd -match 'winload\.efi') { $fw = 'UEFI'; $from = 'bcdedit' } elseif ($bcd -match 'winload\.exe') { $fw = 'Legacy'; $from = 'bcdedit' }
    else { try { $null = Confirm-SecureBootUEFI -ErrorAction Stop; $fw = 'UEFI'; $from = 'secureboot' } catch { } }
    [pscustomobject]@{ serial = "$($bios.SerialNumber)".Trim(); uuid = "$($prod.UUID)".Trim(); maker = "$($cs.Manufacturer)".Trim(); model = "$($cs.Model)".Trim()
        firmware = $fw; firmwareFrom = $from; domain = "$($cs.Domain)"; partOfDomain = [bool]$cs.PartOfDomain; user = "$($cs.UserName)" }
}

function Get-Network {
    # The adapters with a gateway first (the one the console reaches), then the rest; IPv4 only.
    $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress })
    $nics = @($nics | Sort-Object { if ($_.DefaultIPGateway) { 0 } else { 1 } }, InterfaceIndex)
    [pscustomobject]@{
        ipAddresses = @($nics | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+(\.\d+){3}$' -and $_ -notlike '169.254.*' })
        macAddress  = $(if ($nics) { "$($nics[0].MACAddress)" } else { '' })
    }
}

$script:account = $null; $script:accountSid = $null
function Get-ComputerAccount {
    # DOMAIN\PC$ and its SID: the console limits this PC's job folder to it. As SYSTEM, USERDOMAIN is the domain.
    # Outside a domain the share can't tell who the PC is, so there is no account to give it.
    if ($script:accountSid -or -not $identity.partOfDomain) { return }
    $script:account = "$env:USERDOMAIN\$env:COMPUTERNAME`$"
    foreach ($name in $script:account, "$env:COMPUTERNAME`$") {
        try { $script:accountSid = ([Security.Principal.NTAccount]$name).Translate([Security.Principal.SecurityIdentifier]).Value; break } catch { }
    }
}

function Get-DeployResultLine {
    # The verdict of this PC's deploy (first line of C:\Windows\Temp\DeployResult.txt), or ''.
    try { $l = @([IO.File]::ReadAllLines("$env:WINDIR\Temp\DeployResult.txt") | Where-Object { $_.Trim() }); if ($l) { return $l[0].Trim() } } catch { }
    ''
}

$identity = Get-Identity
$script:agentVersion = if ($config.deploy -and $config.deploy.toolVersion) { "$($config.deploy.toolVersion)" } else { '' }
Write-Log ("Agent started: {0}, serial {1}, agent id {2}, checks in to {3} every {4} min; {5}" -f $env:COMPUTERNAME, $identity.serial, $state.agentId, $statusFolder, $every,
    $(if ($keys) { "takes jobs signed by console key $(@($keys | ForEach-Object { Get-AgentKeyId $_ }) -join ', ')" } else { 'no console key: takes no jobs' }))
if (-not (Test-UsableSerial $identity.serial)) { Write-Log "The BIOS serial '$($identity.serial)' is not unique to this PC: the agent can't check in. It stops."; exit 1 }

$script:lastCheckIn = [datetime]::MinValue
$script:lastError = ''
function Send-CheckIn {
    Get-ComputerAccount
    $net = Get-Network
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $free = try { [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop).FreeSpace } catch { $null }
    $deploy = if ($config.PSObject.Properties['deploy']) { $config.deploy } else { $null }
    $script:lastCheckIn = Get-Date
    # A problem building the record is logged (once) and tried again at the next check-in: the agent keeps running.
    $record = try { New-AgentCheckIn -Identity $identity -Network $net -Deploy $deploy -AgentId $state.agentId -AgentVersion $script:agentVersion -CheckInMinutes $every `
        -Account $script:account -AccountSid $script:accountSid -Os $(if ($os) { "$($os.Caption) $($os.Version)".Trim() }) -UserSignedIn "$($cs.UserName)" `
        -BootTime $(if ($os) { $os.LastBootUpTime }) -FreeC $free -Result (Get-DeployResultLine) -Job $state.lastJob -ErrorAction Stop
    } catch {
        $m = "Could not make the check-in: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
        if ($script:lastError -ne $m) { Write-Log $m }
        $script:lastError = $m
        return
    }
    try {
        Save-AgentCheckIn -StatusFolder $statusFolder -Record $record
        if ($script:lastError) { Write-Log 'Checked in again' }
        $script:lastError = ''
    } catch {
        # Logged once until it works again: the share is down, or the computer account can't write there.
        if ($script:lastError -ne $_.Exception.Message) { Write-Log "Could not check in to ${statusFolder}: $($_.Exception.Message)" }
        $script:lastError = $_.Exception.Message
    }
}

function Set-JobState($Job, [string]$JobState, [string]$Message) {
    $state.lastJob = [pscustomobject][ordered]@{ id = "$($Job.id)"; action = "$($Job.action)"; state = $JobState; message = $Message; at = (Get-Date).ToUniversalTime().ToString('o') }
    Save-State
    Send-CheckIn
}

function Invoke-AgentJob {
    $job = $null
    try { $job = Get-AgentJob -StatusFolder $statusFolder -Serial $identity.serial } catch { return }
    if (-not $job) { return }
    $ident = [pscustomobject]@{ serial = $identity.serial; uuid = $identity.uuid; agentId = $state.agentId }
    $why = Test-AgentJob -Job $job -PublicKeys $keys -Identity $ident -DoneIds @($state.doneJobs)
    $jobDir = Get-AgentJobFolder -StatusFolder $statusFolder -Serial $identity.serial
    if ($why) {
        # Refused once: the job file goes, so it is not read every minute. The console sees why in the check-in.
        Write-Log "Job $($job.id) ($($job.action)) refused: $why"
        Remove-AgentJob -StatusFolder $statusFolder -Serial $identity.serial -JobFileOnly
        Set-JobState $job 'Refused' $why
        return
    }
    # Taken: it can't run twice, even if the restart below does not happen.
    $state.doneJobs = @(@($state.doneJobs) + "$($job.id)" | Select-Object -Last 20)
    Remove-AgentJob -StatusFolder $statusFolder -Serial $identity.serial -JobFileOnly
    Write-Log "Job $($job.id): $($job.action) asked by $($job.requestedBy) at $($job.createdAt)"
    Set-JobState $job 'Running' 'Copying the boot image'
    $work = [IO.Path]::Combine($dir, 'Work')
    $wim = [IO.Path]::Combine($work, 'boot.wim')
    try {
        [void][IO.Directory]::CreateDirectory($work)
        [IO.File]::Copy([IO.Path]::Combine($jobDir, 'boot.wim'), $wim, $true)
        $hash = (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash
        if ($hash -ne "$($job.bootWimSha256)".ToUpperInvariant()) { throw "the boot image's SHA-256 ($hash) is not the one the console signed" }
        Write-Log 'Boot image copied and checked; adding the one-time WinPE boot entry'
        $r = Invoke-LocalDiskBoot -ComputerName $env:COMPUTERNAME -Method Local -BootWim $wim -DelaySeconds ([int]$job.delaySeconds) -Message "$($job.message)"
        Write-Log "Restarting into WinPE in $($job.delaySeconds) s (boot entry $($r.BootEntry))"
        Set-JobState $job 'Restarting' "Restarting into WinPE in $($job.delaySeconds) s"
        # The share's copy is not needed any more (this PC's account may delete it).
        try { [IO.File]::Delete([IO.Path]::Combine($jobDir, 'boot.wim')) } catch { }
    } catch {
        Write-Log "Job $($job.id) FAILED: $($_.Exception.Message)"
        Set-JobState $job 'Failed' $_.Exception.Message
    } finally {
        try { [IO.File]::Delete($wim) } catch { }
    }
}

try {
    while ($true) {
        # One bad round is logged (once while it repeats) and the agent carries on: it must never stop by itself.
        try {
            if (((Get-Date) - $script:lastCheckIn).TotalMinutes -ge $every) { Send-CheckIn }
            Invoke-AgentJob
        } catch {
            $m = "Error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
            if ($script:lastLoopError -ne $m) { Write-Log $m }
            $script:lastLoopError = $m
        }
        if ($Once) { break }
        Start-Sleep -Seconds 60
    }
} catch {
    Write-Log "The agent stopped: $($_.Exception.Message)"
    exit 1
} finally {
    if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
}
