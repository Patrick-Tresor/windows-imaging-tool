<#
.SYNOPSIS
    Reimages running PCs through their agent: for each one, queues a job on the deployment share, has its agent
    start WinPE from the PC's own disk, and waits until its deploy has started.
.DESCRIPTION
    Run by the console's Computers tab (hidden, with its progress in a progress window), or by hand on an admin PC.
    For each PC:
      1. Its agent must have checked in lately (ImagingAgent.psm1). A PC without one (Install agent on the
         Computers tab puts it there), whose agent is silent, that answers with another name, starts in legacy BIOS
         mode, has a serial many PCs share or is on Wi-Fi only is skipped, with nothing changed on it.
      2. Writes Reimage\<serial>.json on the share: the answer file, and the name and OU to keep.
      3. Puts a job the console signed and the network boot image in Status\Agents\Jobs\<serial>: the agent copies
         WinPE to C:\_ImagingBoot, adds a one-time boot entry, suspends BitLocker for one restart, and restarts
         the PC after a warning. No WinRM or file sharing on the PC is needed.
      4. Waits until WinPE on that PC has taken the job (Reimage\Started). From there the deploy shows on the
         Dashboard like any other.
    Needs the console's agent signing key and a deployment share (deploy-settings.json share.path) that WinPE maps.
.EXAMPLE
    .\src\Start-RemoteReimage.ps1 -ContentRoot \\server\Deploy -BootWim D:\Deploy\Boot\boot.wim -AnswerFile Staff-W11 -Computers PC01,PC02
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
    [int]$RestartDelay = 60,        # seconds of warning for anyone logged on
    [int]$TimeoutMinutes = 20,      # how long to wait for each PC to start its deploy
    [string]$StatusFolder,          # where the agents check in (the Dashboard's folder); default <ContentRoot>\Status
    [string]$KeyRoot,               # the content root whose config\secrets holds the agent signing key; default ContentRoot
    [int]$AgentPickupMinutes = 10,  # how long an agent has to take its job
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImagingAgent.psm1') -Force

$LogPath = Start-BuildLog -LogPath $LogPath

$targets = @(Get-ReimageTargetList -TargetsFile $TargetsFile -Computers $Computers)
if (-not $targets) { throw 'No computers to reimage.' }

$pcs = @(for ($i = 0; $i -lt $targets.Count; $i++) {
    $t = $targets[$i]
    [pscustomobject]@{
        Id = "pc$i"; Name = "$($t.name)".ToUpperInvariant(); Address = $(if ($t.address) { "$($t.address)" } else { "$($t.name)" }); OU = "$($t.ou)"
        State = 'Pending'; Serial = $null; RequestedAt = $null; RestartAt = $null
        Agent = $null; AgentJob = $null; QueuedAt = $null
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

try {
    if (-not (Test-Path -LiteralPath (Join-Path $ContentRoot "AnswerFiles\$AnswerFile.xml"))) { throw "Answer file $AnswerFile is not on $ContentRoot." }
    # The agents that checked in lately, and the console's key to sign their jobs.
    $checkIns = @(); $bootHash = $null
    if (-not $StatusFolder) { $StatusFolder = Join-Path $ContentRoot 'Status' }
    $agentKey = Get-AgentSigningKey -ContentRoot $(if ($KeyRoot) { $KeyRoot } else { $ContentRoot })
    if (-not $agentKey) { throw 'No agent signing key (config\secrets\agent-key.xml) on this content root: click Install agent on the Computers tab once, it makes the key.' }
    try { $checkIns = @(Get-AgentCheckIns -StatusFolder $StatusFolder) } catch { Write-Host "Could not read the agents' check-ins in ${StatusFolder}: $($_.Exception.Message)" }
    # The agents write their job's progress there as their computer accounts.
    if ($checkIns) { try { $null = Grant-StatusFolderAccess -StatusFolder $StatusFolder } catch { } }

    # One PC at a time up to its restart: each copy of boot.wim is a few hundred MB.
    foreach ($p in $pcs) {
        Start-BuildStep $p.Id -Detail 'Reading the PC'
        $agent = Find-AgentCheckIn -CheckIns $checkIns -ComputerName $p.Name
        if (-not $agent -or -not $agent.agentId) {
            Write-Host "$($p.Name): no agent has checked in from it. Select it and click Install agent on the Computers tab (or run <share>\Agent\Install-Agent.cmd on it as administrator), then reimage it."
            Stop-PcStep $p 'Not reimaged: it has no agent; click Install agent first (see the log)'; continue
        }
        if (-not $agent.Online) {
            Write-Host "$($p.Name): its agent last checked in $($agent.LastSeenText): the PC is off, asleep or off the network."
            Stop-PcStep $p "Not reimaged: its agent last checked in $($agent.LastSeenText); turn the PC on and try again"; continue
        }
        try {
            $problems = @(Test-RemoteTarget -Info (ConvertTo-AgentTargetInfo $agent) -ExpectedName $p.Name)
            if ($problems) { Stop-PcStep $p "Not reimaged: $($problems[0])"; continue }
            # WinPE has no Wi-Fi: on Wi-Fi only, the PC would restart into WinPE and not reach the share.
            if ($agent.PSObject.Properties['wired'] -and $agent.wired -eq $false) {
                Write-Host "$($p.Name): its agent says it has no network cable connected (Wi-Fi only). WinPE has no Wi-Fi, so it could not reach the share. Connect a cable or a dock, wait for its next check-in (up to $(if ($agent.checkInMinutes) { $agent.checkInMinutes } else { 5 }) min), then try again."
                Stop-PcStep $p 'Not reimaged: it is on Wi-Fi only; WinPE needs a network cable or dock (see the log)'; continue
            }
            Set-BuildStepProgress $p.Id -Percent 20 -Detail 'Giving the job to its agent'
            if (-not $bootHash) { $bootHash = (Get-FileHash -LiteralPath $BootWim -Algorithm SHA256).Hash }
            $p.Serial = "$($agent.serial)"
            $queued = (New-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial -Uuid "$($agent.uuid)" -AnswerFile $AnswerFile `
                -ComputerName $(if ($KeepNames) { $p.Name } else { '' }) -OU $(if ($KeepOU) { $p.OU } else { '' }) -ExpiresHours ([Math]::Max(2, [Math]::Ceiling($TimeoutMinutes / 60) + 1)))
            $p.RequestedAt = "$($queued.requestedAt)"
            $p.AgentJob = New-AgentJob -StatusFolder $StatusFolder -PrivateKey $agentKey -CheckIn $agent -BootWim $BootWim -BootWimSha256 $bootHash -DelaySeconds $RestartDelay
            $p.Agent = $agent; $p.State = 'AgentQueued'; $p.QueuedAt = Get-Date
            Write-Host "$($p.Name): job given to its agent (last check-in $($agent.LastSeenText), $($agent.ipAddress))"
            Set-BuildStepProgress $p.Id -Percent 40 -Detail 'Waiting for its agent to take the job'
        } catch {
            Write-Host "$($p.Name): could not give the job to its agent: $($_.Exception.Message)"
            if ($p.Serial) { Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial; Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial }
            Stop-PcStep $p "Not reimaged: could not give the job to its agent (see the log)"
        }
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
                    Write-Host "$($p.Name): $why"
                    Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial
                    Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial
                    Stop-PcStep $p "Not reimaged: $why (see the log)"
                }
                continue
            }
            if (Get-StartedJob -ContentRoot $ContentRoot -Serial $p.Serial -RequestedAt $p.RequestedAt) {
                $p.State = 'Started'
                Write-Host "$($p.Name): deploy started" -ForegroundColor Green
                Complete-BuildStep $p.Id -Detail 'Deploy started: follow it on the Dashboard'
                Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial
            } elseif ((Get-Date) -gt $p.RestartAt.AddMinutes($TimeoutMinutes)) {
                Remove-ReimageJob -ContentRoot $ContentRoot -Serial $p.Serial
                # Its startup task takes WinPE off the disk at the next Windows start.
                Remove-AgentJob -StatusFolder $StatusFolder -Serial $p.Serial
                Stop-PcStep $p "WinPE did not start the deploy within $TimeoutMinutes min: check the PC's screen (network, share)"
            } elseif ((Get-Date) -gt $p.RestartAt) {
                Set-BuildStepProgress $p.Id -Percent 85 -Detail 'Waiting for WinPE to start the deploy'
            }
        }
        Start-Sleep -Seconds 5
    }

    Write-Host ''
    $null = Complete-PcRun -Pcs $pcs -DoneState 'Started' -DoneText 'started' -OneFailed 'The PC was not reimaged, see the row below.' -ManyFailed '{0} of {1} PCs were not reimaged, see the rows below.'
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    Stop-BuildLog -LogPath $LogPath
}
if (@($pcs | Where-Object State -ne 'Started').Count) { exit 1 }
