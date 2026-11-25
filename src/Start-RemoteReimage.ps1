<#
.SYNOPSIS
    Reimages running PCs over the network: for each one, queues a job on the deployment share, starts WinPE from
    the PC's own disk, and waits until its deploy has started.
.DESCRIPTION
    Run by the console's Computers tab (hidden, with its progress in a progress window), or by hand on an admin PC.
    For each PC (RemoteReimage.psm1):
      0. A PC whose agent checked in lately (ImagingAgent.psm1) goes through its agent instead: the console writes
         the WinPE job, puts a job it signed and the network boot image in Status\Agents\Jobs\<serial> on the share,
         and the agent restarts the PC into WinPE by itself (no WinRM or file sharing needed). If the agent has not
         taken the job within AgentPickupMinutes, the PC is reached over the network as below.
      1. Reads it over PowerShell remoting, or when that is off over its admin share and a one-time SYSTEM
         service: the name it answers with, BIOS serial, UUID, firmware, free space.
         A PC that is off, has neither WinRM nor file sharing, answers with another name, starts in legacy BIOS mode or has a serial many
         PCs share is skipped, with nothing changed on it.
      2. Writes Reimage\<serial>.json on the share: the answer file, and the name and OU to keep.
      3. Copies the network boot image to C:\_ImagingBoot, adds a one-time boot entry for it, suspends BitLocker
         for one restart, and restarts the PC after a warning.
      4. Waits until WinPE on that PC has taken the job (Reimage\Started). From there the deploy shows on the
         Dashboard like any other.
    Needs admin rights on the PCs, PowerShell remoting (WinRM) or file sharing on them, and a deployment share (deploy-settings.json
    share.path) that WinPE maps.
.EXAMPLE
    .\src\Start-RemoteReimage.ps1 -ContentRoot \\server\Deploy -BootWim D:\Deploy\Boot\boot.wim -AnswerFile Staff-W11 -Computers PC01.corp.local,PC02.corp.local
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContentRoot,     # the deployment share WinPE maps (jobs go there)
    [Parameter(Mandatory)][string]$BootWim,         # the network boot image to start on each PC
    [Parameter(Mandatory)][string]$AnswerFile,
    [string]$TargetsFile,           # JSON from the console: [{ name, address, ou, local, credentialFile }]; deleted once read
    [string[]]$Computers,           # or names/addresses (the answer file's OU and the PC's own name are kept)
    [switch]$KeepNames,             # each PC keeps its name
    [switch]$KeepOU,                # each PC joins back into the OU it is in now (from TargetsFile)
    [string]$CredentialFile,        # Export-Clixml of a PSCredential for remoting (only this user can read it); deleted once read
    [int]$RestartDelay = 60,        # seconds of warning for anyone logged on
    [int]$TimeoutMinutes = 20,      # how long to wait for each PC to start its deploy
    [string]$StatusFolder,          # where the agents check in (the Dashboard's folder); default <ContentRoot>\Status
    [string]$KeyRoot,               # the content root whose config\secrets holds the agent signing key; default ContentRoot
    [int]$AgentPickupMinutes = 4,   # how long an agent has to take its job before the PC is reached over the network
    [switch]$NoAgent,               # never through the agents
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImagingAgent.psm1') -Force

if ($LogPath) {
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
    try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { $LogPath = $null }
}

$credential = $null
if ($CredentialFile) {
    try { $credential = Import-Clixml -LiteralPath $CredentialFile } finally { Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue }
}
$targets = @()
if ($TargetsFile) {
    try { $targets = @(Read-ReimageTargets -Path $TargetsFile) } finally { Remove-Item -LiteralPath $TargetsFile -Force -ErrorAction SilentlyContinue }
}
# From the console (powershell -File) a list arrives as one comma-separated string.
foreach ($c in @($Computers | ForEach-Object { "$_" -split ',' } | ForEach-Object Trim | Where-Object { $_ })) {
    $targets += [pscustomobject]@{ name = ($c -split '\.')[0].ToUpperInvariant(); address = $c; ou = '' }
}
if (-not $targets) { throw 'No computers to reimage.' }

$pcs = @(for ($i = 0; $i -lt $targets.Count; $i++) {
    $t = $targets[$i]
    [pscustomobject]@{
        Id = "pc$i"; Name = "$($t.name)".ToUpperInvariant(); Address = $(if ($t.address) { "$($t.address)" } else { "$($t.name)" }); OU = "$($t.ou)"
        State = 'Pending'; Method = 'WinRM'; Serial = $null; RequestedAt = $null; RestartAt = $null; BootEntry = $null
        Agent = $null; AgentJob = $null; QueuedAt = $null
        # A PC outside the domain (found by IP) signs in with its own local admin account, read here and deleted.
        Local = [bool]($t.PSObject.Properties['local'] -and $t.local)
        Credential = $(if ($t.PSObject.Properties['credentialFile'] -and $t.credentialFile) {
            try { Import-Clixml -LiteralPath $t.credentialFile } catch { $null } finally { Remove-Item -LiteralPath $t.credentialFile -Force -ErrorAction SilentlyContinue }
        } else { $credential })
    }
})
# Microsoft 365 Apps in the answer file: its Office files go next to setup.exe on the share first, so each PC
# installs Office from the share instead of downloading 2-3 GB from Microsoft at first boot.
$officeApps = @()
try {
    $answerPath = Join-Path $ContentRoot "AnswerFiles\$AnswerFile.xml"
    if (Test-Path -LiteralPath $answerPath) {
        Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force   # after AnswerFile, which imports it for itself only
        $ans = Read-AnswerFile -Path $answerPath -SkipValidation
        $officeAppRoot = Join-Path $ContentRoot $ans.AppLocation
        $officeApps = @($ans.Applications | Where-Object {
            $def = try { Read-AppPack -AppRoot $officeAppRoot -Name $_ } catch { $null }
            $def -and (Get-OfficeConfigPath -Definition $def -AppFolder (Join-Path $officeAppRoot $_))
        })
    }
} catch { Write-Warning "Could not check the answer file's applications for Office: $($_.Exception.Message)" }
$reimageSteps = @($pcs | ForEach-Object { , @($_.Id, $_.Name) })
if ($officeApps) { $reimageSteps = @(, @('office', 'Getting the Office files ready')) + $reimageSteps }
Start-BuildProgress -Path $ProgressFile -Title "Reimaging $($pcs.Count) PC$(if ($pcs.Count -ne 1) { 's' }) with $AnswerFile" -LogPath $LogPath -Steps $reimageSteps
if ($officeApps) {
    Start-BuildStep 'office' -Detail ($officeApps -join ', ')
    $officeRows = @(Update-OfficeSources -AppRoot $officeAppRoot -Names $officeApps)
    $bad = @($officeRows | Where-Object Status -eq 'Failed')
    $ok = @($officeRows | Where-Object { $_.Status -in 'Downloaded', 'Fresh' })
    if ($bad) { Complete-BuildStep 'office' -State failed -Detail "Not downloaded: the PCs download Office at first boot ($($bad[0].Message))" }
    else { Complete-BuildStep 'office' -Detail $(if ($ok) { "Office $($ok[0].Version) on the share" } else { 'Nothing to do' }) }
}
Write-Host "Reimaging $($pcs.Count) PC(s) with answer file $AnswerFile from $ContentRoot" -ForegroundColor Cyan

function Stop-Pc($p, [string]$Message) {
    $p.State = 'Failed'
    Write-Host "$($p.Name): $Message" -ForegroundColor Red
    Complete-BuildStep $p.Id -State failed -Detail (@("$Message" -split "`r?`n")[0])
}

function Start-PcOverNetwork($p) {
    # The PC over PowerShell remoting or its admin share: read it, queue its WinPE job, start WinPE from its disk.
    $check = $up[$p.Address]
    if (-not $check -or -not $check.Online) {
        Write-Host "$($p.Name): $(if ($check) { $check.Detail } else { 'not checked' })"
        if ($check -and $check.State -eq 'Not found') {
            Write-Host 'Use a domain controller as this PC''s DNS server (or connect it to the domain network or VPN), then try again.'
            Stop-Pc $p "Not reimaged: $($p.Address) is not found in this PC's DNS (see the log)"; return
        }
        if ($check -and $check.State -eq 'Old DNS') { Stop-Pc $p "Not reimaged: DNS gives an old address for $($p.Name); search it by its IP address (see the log)"; return }
        Write-Host 'The console needs one of: PowerShell remoting (Enable-PSRemoting -Force, or the Group Policy Computer Configuration > Administrative Templates > Windows Components > Windows Remote Management > WinRM Service > Allow remote server management through WinRM, plus the firewall rule Windows Remote Management (HTTP-In)), or file sharing (firewall rule File and Printer Sharing (SMB-In)).'
        Stop-Pc $p $(if ($check -and $check.State -eq 'No access') { 'Not reimaged: it is on, but its firewall blocks PowerShell remoting and file sharing (see the log)' }
                     else { "Not reimaged: no answer from $($p.Address): it is off or asleep (see the log)" }); return
    }
    # The short name, when only that resolves from this PC.
    $p.Address = $check.Address
    $p.Method = $check.Method
    # Typed as an IP address: Windows sign-in over WinRM needs a name (Kerberos) or TrustedHosts, but file sharing
    # signs in to an IP address, so use it when it answers.
    if ($p.Method -eq 'WinRM' -and $check.Smb -and $p.Address -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $p.Method = 'Smb'
        Write-Host "$($p.Name): reached by IP address $($p.Address), going through its admin share and a one-time service"
    }
    elseif ($p.Method -eq 'Smb') { Write-Host "$($p.Name): PowerShell remoting is off, going through its admin share and a one-time service" }
    try {
        try {
            $info = Get-RemoteComputerInfo -ComputerName $p.Address -Credential $p.Credential -Method $p.Method
        } catch {
            # This console PC is outside the domain and WinRM won't sign in: file sharing takes domain accounts.
            if ($p.Method -ne 'WinRM' -or -not $check.Smb -or -not (Test-WinRMSignInError $_.Exception.Message)) { throw }
            Write-Host "$($p.Name): WinRM would not sign in from this PC ($($_.Exception.Message -replace '\s+', ' ')); going through its admin share and a one-time service instead"
            $p.Method = 'Smb'
            $info = Get-RemoteComputerInfo -ComputerName $p.Address -Credential $p.Credential -Method $p.Method
        }
        Write-Host "$($p.Name): $($info.Model), serial $($info.Serial), $($info.Firmware), BitLocker $($info.BitLocker)"
        # Outside the domain there is no name in Active Directory to compare with; it keeps the name it has now.
        $problems = @(Test-RemoteTarget -Info $info -ExpectedName $(if ($p.Local) { '' } else { $p.Name }))
        if ($problems) { Stop-Pc $p "Not reimaged: $($problems[0])"; return }
        if ($p.Local -and "$($info.ComputerName)") { $p.Name = "$($info.ComputerName)".ToUpperInvariant() }
        $p.Serial = $info.Serial
        $queued = (New-ReimageJob -ContentRoot $ContentRoot -Serial $info.Serial -Uuid $info.Uuid -AnswerFile $AnswerFile `
            -ComputerName $(if ($KeepNames) { $p.Name } else { '' }) -OU $(if ($KeepOU -and -not $p.Local) { $p.OU } else { '' }) -ExpiresHours ([Math]::Max(2, [Math]::Ceiling($TimeoutMinutes / 60) + 1)))
        # The console's own time stamp: the started job is matched by it, not by WinPE's clock.
        $p.RequestedAt = "$($queued.requestedAt)"
        Write-Host "$($p.Name): job queued$(if ($KeepNames) { ", keeps its name" })$(if ($KeepOU -and $p.OU) { ", joins $($p.OU)" })"
        $onStage = {
            param($stage)
            switch ($stage) {
                'copy'      { Set-BuildStepProgress $p.Id -Percent 20 -Detail 'Copying WinPE to the PC' }
                'bootentry' { Set-BuildStepProgress $p.Id -Percent 50 -Detail 'Adding the one-time boot entry' }
                'restart'   { Set-BuildStepProgress $p.Id -Percent 60 -Detail "Restarting in $RestartDelay s" }
            }
        }
        try {
            $r = Invoke-LocalDiskBoot -ComputerName $p.Address -BootWim $BootWim -Credential $p.Credential -Method $p.Method -DelaySeconds $RestartDelay -OnStage $onStage
        } catch {
            Remove-ReimageJob -ContentRoot $ContentRoot -Serial $info.Serial
            throw
        }
        $p.BootEntry = $r.BootEntry
        Write-Host "$($p.Name): next boot set to WinPE from its own disk (entry $($r.BootEntry)); restarting in $RestartDelay s"
        $p.State = 'Restarting'; $p.RestartAt = (Get-Date).AddSeconds($RestartDelay)
        Set-BuildStepProgress $p.Id -Percent 70 -Detail 'Restarting into WinPE'
    } catch {
        # The whole error in the log, one line saying what to do in the window.
        Write-Host "$($p.Name): $($_.Exception.Message)"
        if ($_.Exception.Message -match '(?i)TrustedHosts') {
            Write-Host "On this console PC, as administrator: Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*.<your domain>' -Concatenate -Force, and sign in with DOMAIN\user."
        }
        if ($p.Local -and $_.Exception.Message -match '(?i)Access is denied|Acc.s refus|0x80070005') {
            Write-Host 'Windows gives a local account other than the built-in Administrator no admin rights over the network. Sign in with the built-in Administrator (enabled, with a password), or on that PC, as administrator: reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f'
        }
        Stop-Pc $p (Get-RemotingProblemText -Message $_.Exception.Message -Local:$p.Local -Account $(if ($p.Credential) { $p.Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }))
    }
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "Answer file $AnswerFile is not on $ContentRoot." }
    # The agents that checked in lately, and the console's key to sign their jobs.
    $agentKey = $null; $checkIns = @(); $bootHash = $null
    if (-not $NoAgent) {
        if (-not $StatusFolder) { $StatusFolder = Join-Path $ContentRoot 'Status' }
        try {
            $agentKey = Get-AgentSigningKey -ContentRoot $(if ($KeyRoot) { $KeyRoot } else { $ContentRoot })
            $checkIns = @(Get-AgentCheckIns -StatusFolder $StatusFolder)
        } catch { Write-Host "Could not read the agents' check-ins in ${StatusFolder}: $($_.Exception.Message)" }
        # The agents write their job's progress there as their computer accounts.
        if ($agentKey -and $checkIns) { try { $null = Grant-StatusFolderAccess -StatusFolder $StatusFolder } catch { } }
        if (-not $agentKey -and $checkIns) { Write-Host 'No agent signing key (config\secrets\agent-key.xml) on this content root: the agents are not used.' }
    }
    # The addresses each PC's agent reported go first: DNS may hold an old one (GWHZLG3: DNS 10.10.64.51, the agent
    # reported 10.10.2.1), and the network check is the fallback when the agent can't do the job.
    $up = Get-RemoteOnlineState -ComputerName @($pcs | ForEach-Object Address) -KnownAddress (Get-AgentKnownAddresses -CheckIns $checkIns -Targets $pcs)

    # One PC at a time up to its restart: each copy of boot.wim is a few hundred MB.
    foreach ($p in $pcs) {
        Start-BuildStep $p.Id -Detail 'Reading the PC'
        $agent = if ($agentKey) { Find-AgentCheckIn -CheckIns $checkIns -ComputerName $p.Name } else { $null }
        if ($agent -and $agent.Online -and $agent.agentId) {
            try {
                $problems = @(Test-RemoteTarget -Info (ConvertTo-AgentTargetInfo $agent) -ExpectedName $(if ($p.Local) { '' } else { $p.Name }))
                if ($problems) { Stop-Pc $p "Not reimaged: $($problems[0])"; continue }
                Set-BuildStepProgress $p.Id -Percent 20 -Detail 'Giving the job to its agent'
                if (-not $bootHash) { $bootHash = (Get-FileHash -LiteralPath $BootWim -Algorithm SHA256).Hash }
                $p.Serial = "$($agent.serial)"
                $queued = (New-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial -Uuid "$($agent.uuid)" -AnswerFile $AnswerFile `
                    -ComputerName $(if ($KeepNames) { $p.Name } else { '' }) -OU $(if ($KeepOU -and -not $p.Local) { $p.OU } else { '' }) -ExpiresHours ([Math]::Max(2, [Math]::Ceiling($TimeoutMinutes / 60) + 1)))
                $p.RequestedAt = "$($queued.requestedAt)"
                $p.AgentJob = New-AgentJob -StatusFolder $StatusFolder -PrivateKey $agentKey -CheckIn $agent -BootWim $BootWim -BootWimSha256 $bootHash -DelaySeconds $RestartDelay
                $p.Agent = $agent; $p.Method = 'Agent'; $p.State = 'AgentQueued'; $p.QueuedAt = Get-Date
                Write-Host "$($p.Name): job given to its agent (last check-in $($agent.LastSeenText), $($agent.ipAddress))"
                Set-BuildStepProgress $p.Id -Percent 40 -Detail 'Waiting for its agent to take the job'
                continue
            } catch {
                Write-Host "$($p.Name): could not go through its agent ($($_.Exception.Message)); reaching it over the network instead"
                if ($p.Serial) { Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial; Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial }
                $p.Method = 'WinRM'; $p.Serial = $null; $p.AgentJob = $null
            }
        } elseif ($agent) {
            Write-Host "$($p.Name): its agent last checked in $($agent.LastSeenText); reaching it over the network"
        }
        Start-PcOverNetwork $p
    }

    # Then wait for WinPE on each PC to take its job.
    while ($true) {
        $waiting = @($pcs | Where-Object { $_.State -in 'Restarting', 'AgentQueued' })
        if (-not $waiting) { break }
        if (@($waiting | Where-Object State -eq 'AgentQueued')) { $checkIns = @(try { Get-AgentCheckIns -StatusFolder $StatusFolder } catch { }) }
        foreach ($p in $waiting) {
            if ($p.State -eq 'AgentQueued') {
                # The agent says what it did with the job in its check-in.
                $now = Find-AgentCheckIn -CheckIns $checkIns -Serial $p.Serial
                $js = if ($now -and $now.job -and "$($now.job.id)" -eq "$($p.AgentJob.id)") { $now.job } else { $null }
                if ($js -and $js.state -in 'Running', 'Restarting') {
                    if ($js.state -eq 'Restarting') {
                        $p.State = 'Restarting'; $p.RestartAt = (Get-Date).AddSeconds($RestartDelay)
                        Write-Host "$($p.Name): its agent restarts it into WinPE in $RestartDelay s"
                        Set-BuildStepProgress $p.Id -Percent 70 -Detail 'Restarting into WinPE'
                    } else { Set-BuildStepProgress $p.Id -Percent 55 -Detail 'Its agent is copying WinPE' }
                    # Copying 500 MB can take a while: the agent has its pickup time again.
                    if ($js.state -eq 'Running') { $p.QueuedAt = Get-Date }
                    continue
                }
                if (($js -and $js.state -in 'Refused', 'Failed') -or (Get-Date) -gt $p.QueuedAt.AddMinutes($AgentPickupMinutes)) {
                    $why = if ($js) { "its agent: $($js.state), $($js.message)" } else { "its agent did not take the job within $AgentPickupMinutes min" }
                    Write-Host "$($p.Name): $why; reaching it over the network instead"
                    Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial
                    Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial
                    $p.Method = 'WinRM'; $p.State = 'Pending'; $p.Serial = $null
                    Set-BuildStepProgress $p.Id -Percent 10 -Detail 'Reading the PC over the network'
                    Start-PcOverNetwork $p
                }
                continue
            }
            if (Get-StartedJob -ContentRoot $ContentRoot -Serial $p.Serial -RequestedAt $p.RequestedAt) {
                $p.State = 'Started'
                Write-Host "$($p.Name): deploy started" -ForegroundColor Green
                Complete-BuildStep $p.Id -Detail 'Deploy started: follow it on the Dashboard'
                if ($p.Method -eq 'Agent') { Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial }
            } elseif ((Get-Date) -gt $p.RestartAt.AddMinutes($TimeoutMinutes)) {
                Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial
                if ($p.Method -eq 'Agent') {
                    # Its startup task takes WinPE off the disk at the next Windows start.
                    Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial
                    Stop-Pc $p "WinPE did not start the deploy within $TimeoutMinutes min: check the PC's screen (network, share)"
                    continue
                }
                # Back in Windows (WinPE could not start, or nobody took the job)? Take WinPE off its disk now. If the
                # PC does not answer, its startup task does it at the next Windows start.
                $cleaned = try { Remove-LocalDiskBoot -ComputerName $p.Address -BootEntry $p.BootEntry -Credential $p.Credential -Method $p.Method; $true } catch { $false }
                Stop-Pc $p ("WinPE did not start the deploy within $TimeoutMinutes min: check the PC's screen (network, share)" + $(if ($cleaned) { '. WinPE was removed from its disk.' } else { '' }))
            } elseif ((Get-Date) -gt $p.RestartAt) {
                Set-BuildStepProgress $p.Id -Percent 85 -Detail 'Waiting for WinPE to start the deploy'
            }
        }
        Start-Sleep -Seconds 5
    }

    $failed = @($pcs | Where-Object State -ne 'Started').Count
    Write-Host ''
    Write-Host "Done: $($pcs.Count - $failed) of $($pcs.Count) started." -ForegroundColor Cyan
    if ($failed) { Stop-BuildProgress -Message $(if ($pcs.Count -eq 1) { 'The PC was not reimaged, see the row below.' } else { "$failed of $($pcs.Count) PCs were not reimaged, see the rows below." }) }
    else { Stop-BuildProgress }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
}
if (@($pcs | Where-Object State -ne 'Started').Count) { exit 1 }
