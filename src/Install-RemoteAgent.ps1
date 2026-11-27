<#
.SYNOPSIS
    Puts the agent on running PCs that were imaged before it existed, and waits for each one to check in.
.DESCRIPTION
    Run by the console's Computers tab (Install agent, hidden, with its progress in a progress window), or by hand.
    For each PC: reaches it over PowerShell remoting, or when that is off its admin share and a one-time SYSTEM
    service, or when both are blocked by its firewall WMI over the RPC port 135 (RemoteReimage.psm1), copies the agent to C:\ProgramData\ImagingTool\Agent (administrators and SYSTEM
    only) with agent.json (the status folder and the console's public key), makes the SYSTEM task ImagingTool\Agent
    and starts it (ImagingAgent.psm1, Install-AgentOnRemotePC). Then waits up to 3 minutes for its first check-in.
    Newly deployed PCs get the agent at deploy; this is only for the ones already out there.
.EXAMPLE
    .\src\Install-RemoteAgent.ps1 -ContentRoot \\server\Deploy -StatusFolder \\server\Deploy\Status -Computers PC01,PC02
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContentRoot,     # holds config\agent-public-key.xml (made here the first time)
    [Parameter(Mandatory)][string]$StatusFolder,    # where the agents check in (a UNC path)
    [string]$TargetsFile,           # JSON from the console: [{ name, address }]; deleted once read
    [string[]]$Computers,
    [string]$CredentialFile,        # Export-Clixml of a PSCredential (only this user can read it); deleted once read
    [int]$CheckInSeconds = 30,
    [int]$WaitMinutes = 3,
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImagingAgent.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force

$LogPath = Start-BuildLog -LogPath $LogPath
$credential = $null
if ($CredentialFile) {
    try { $credential = Import-Clixml -LiteralPath $CredentialFile } finally { Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue }
}
$targets = @(Get-ReimageTargetList -TargetsFile $TargetsFile -Computers $Computers)
if (-not $targets) { throw 'No computers to put the agent on.' }

$pcs = @(for ($i = 0; $i -lt $targets.Count; $i++) {
    [pscustomobject]@{ Id = "pc$i"; Name = "$($targets[$i].name)".ToUpperInvariant(); Address = $(if ($targets[$i].address) { "$($targets[$i].address)" } else { "$($targets[$i].name)" }); State = 'Pending'; Since = $null; Reached = $null; Method = $null }
})
Start-BuildProgress -Path $ProgressFile -Title "Installing the agent on $($pcs.Count) PC$(if ($pcs.Count -ne 1) { 's' })" -LogPath $LogPath -Steps @($pcs | ForEach-Object { , @($_.Id, $_.Name) })

function Get-RemoteAgentProblem($p) {
    # The last lines of the agent's log and its task's state, over the same way in as the install.
    $ch = Open-RemoteChannel -ComputerName $p.Reached -Credential $credential -Method $p.Method
    try {
        $r = @(Invoke-RemoteChannel -Channel $ch -ScriptBlock (Get-AgentStateScript))[0]
    } finally { Close-RemoteChannel $ch }
    foreach ($l in @($r.Lines)) { Write-Host "  $($p.Name) agent log: $l" }
    Get-AgentLogProblem -State $r
}

try {
    $publicKey = Get-AgentPublicKey -ContentRoot $ContentRoot -Create
    Write-Host "Console key $(Get-AgentKeyId $publicKey); the agents check in to $StatusFolder every $CheckInSeconds s" -ForegroundColor Cyan
    # The agents write there as their computer accounts: when the share is on this PC, make sure Domain Computers may.
    try { foreach ($l in (Grant-StatusFolderAccess -StatusFolder $StatusFolder).Lines) { Write-Host $l } }
    catch { Write-Host "Could not check the rights on ${StatusFolder}: $($_.Exception.Message)" -ForegroundColor Yellow }
    $up = Get-RemoteOnlineState -ComputerName @($pcs | ForEach-Object Address)
    foreach ($p in $pcs) {
        Start-BuildStep $p.Id -Detail 'Reaching the PC'
        $check = $up[$p.Address]
        if (-not $check -or -not $check.Online) { Stop-PcStep $p "Not reached: $(if ($check) { $check.Detail } else { 'not checked' })"; continue }
        $method = $check.Method
        if ($method -eq 'WinRM' -and $check.Smb -and $check.Address -match '^\d{1,3}(\.\d{1,3}){3}$') { $method = 'Smb' }
        $ch = $null
        try {
            try { $ch = Open-RemoteChannel -ComputerName $check.Address -Credential $credential -Method $method }
            catch {
                $next = if ($check.Smb) { 'Smb' } elseif ($check.PSObject.Properties['Rpc'] -and $check.Rpc) { 'Wmi' } else { '' }
                if ($method -ne 'WinRM' -or -not $next -or -not (Test-WinRMSignInError $_.Exception.Message)) { throw }
                Write-Host "$($p.Name): WinRM would not sign in from this PC; going through $(if ($next -eq 'Smb') { 'its admin share' } else { 'WMI' }) instead"
                $method = $next
                $ch = Open-RemoteChannel -ComputerName $check.Address -Credential $credential -Method $next
            }
            Set-BuildStepProgress $p.Id -Percent 30 -Detail 'Copying the agent'
            $config = New-AgentConfig -StatusFolder $StatusFolder -PublicKeys @($publicKey) -CheckInSeconds $CheckInSeconds `
                -Deploy ([pscustomobject]@{ answerFile = ''; image = ''; toolVersion = ''; deployedAt = '' })
            Install-AgentOnRemotePC -Channel $ch -SourceDir $PSScriptRoot -Config $config
            Write-Host "$($p.Name): agent installed over $($ch.Method); waiting for its first check-in"
            $p.State = 'Waiting'; $p.Since = Get-Date; $p.Reached = $ch.ComputerName; $p.Method = $ch.Method
            Set-BuildStepProgress $p.Id -Percent 70 -Detail 'Waiting for its first check-in'
        } catch {
            Write-Host "$($p.Name): $($_.Exception.Message)"
            if ($method -eq 'Wmi') {
                if ($_.Exception.Message -match '(?i)RPC server|serveur RPC|0x800706BA') {
                    Write-Host "$($p.Name): port 135 answers but WMI's own ports are blocked by its firewall. Fix it for every PC with a Group Policy: Computer Configuration > Policies > Windows Settings > Security Settings > Windows Defender Firewall > Inbound Rules > New rule > Predefined 'Windows Management Instrumentation (WMI)' > allow, for the Domain profile. Or turn on PowerShell remoting: Computer Configuration > Policies > Administrative Templates > Windows Components > Windows Remote Management > WinRM Service > Allow remote server management through WinRM, plus the predefined rule 'Windows Remote Management'."
                }
                Stop-PcStep $p (Get-WmiProblemText -Message $_.Exception.Message); continue
            }
            Stop-PcStep $p (Get-RemotingProblemText -Message $_.Exception.Message -Account $(if ($credential) { $credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }))
        } finally { Close-RemoteChannel $ch }
    }

    while ($true) {
        $waiting = @($pcs | Where-Object State -eq 'Waiting')
        if (-not $waiting) { break }
        $checkIns = @(try { Get-AgentCheckIns -StatusFolder $StatusFolder } catch { })
        foreach ($p in $waiting) {
            $a = Find-AgentCheckIn -CheckIns $checkIns -ComputerName $p.Name
            if ($a -and $a.LastSeen -ge $p.Since.AddMinutes(-1)) {
                $p.State = 'Done'
                Write-Host "$($p.Name): checked in from $($a.ipAddress)" -ForegroundColor Green
                Complete-BuildStep $p.Id -Detail "Checked in from $($a.ipAddress)"
            } elseif ((Get-Date) -gt $p.Since.AddMinutes($WaitMinutes)) {
                # Installed, but no check-in: read why from the agent's own log and task on the PC.
                $why = try { Get-RemoteAgentProblem $p } catch { "its log could not be read ($($_.Exception.Message))" }
                Stop-PcStep $p "No check-in within $WaitMinutes min. $why (C:\Windows\Temp\ImagingAgent.log on the PC)"
            }
        }
        Start-Sleep -Seconds 5
    }
    $null = Complete-PcRun -Pcs $pcs -DoneState 'Done' -DoneText 'PCs checked in' -OneFailed 'The agent is not working on this PC, see the row below.' -ManyFailed '{0} of {1} PCs have no working agent, see the rows below.'
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    Stop-BuildLog -LogPath $LogPath
}
if (@($pcs | Where-Object State -ne 'Done').Count) { exit 1 }
