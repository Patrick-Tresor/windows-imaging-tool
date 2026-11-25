<#
.SYNOPSIS
    Puts the agent on running PCs that were imaged before it existed, and waits for each one to check in.
.DESCRIPTION
    Run by the console's Computers tab (Install agent, hidden, with its progress in a progress window), or by hand.
    For each PC: reaches it over PowerShell remoting, or when that is off its admin share and a one-time SYSTEM
    service (RemoteReimage.psm1), copies the agent to C:\ProgramData\ImagingTool\Agent (administrators and SYSTEM
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
    [int]$CheckInMinutes = 5,
    [int]$WaitMinutes = 3,
    [string]$ProgressFile,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RemoteReimage.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImagingAgent.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force

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
foreach ($c in @($Computers | ForEach-Object { "$_" -split ',' } | ForEach-Object Trim | Where-Object { $_ })) {
    $targets += [pscustomobject]@{ name = ($c -split '\.')[0].ToUpperInvariant(); address = $c }
}
if (-not $targets) { throw 'No computers to put the agent on.' }

$pcs = @(for ($i = 0; $i -lt $targets.Count; $i++) {
    [pscustomobject]@{ Id = "pc$i"; Name = "$($targets[$i].name)".ToUpperInvariant(); Address = $(if ($targets[$i].address) { "$($targets[$i].address)" } else { "$($targets[$i].name)" }); State = 'Pending'; Since = $null }
})
Start-BuildProgress -Path $ProgressFile -Title "Installing the agent on $($pcs.Count) PC$(if ($pcs.Count -ne 1) { 's' })" -LogPath $LogPath -Steps @($pcs | ForEach-Object { , @($_.Id, $_.Name) })

function Stop-Pc($p, [string]$Message) {
    $p.State = 'Failed'
    Write-Host "$($p.Name): $Message" -ForegroundColor Red
    Complete-BuildStep $p.Id -State failed -Detail (@("$Message" -split "`r?`n")[0])
}

try {
    $publicKey = Get-AgentPublicKey -ContentRoot $ContentRoot -Create
    Write-Host "Console key $(Get-AgentKeyId $publicKey); the agents check in to $StatusFolder every $CheckInMinutes min" -ForegroundColor Cyan
    $up = Get-RemoteOnlineState -ComputerName @($pcs | ForEach-Object Address)
    foreach ($p in $pcs) {
        Start-BuildStep $p.Id -Detail 'Reaching the PC'
        $check = $up[$p.Address]
        if (-not $check -or -not $check.Online) { Stop-Pc $p "Not reached: $(if ($check) { $check.Detail } else { 'not checked' })"; continue }
        $method = $check.Method
        if ($method -eq 'WinRM' -and $check.Smb -and $check.Address -match '^\d{1,3}(\.\d{1,3}){3}$') { $method = 'Smb' }
        $ch = $null
        try {
            try { $ch = Open-RemoteChannel -ComputerName $check.Address -Credential $credential -Method $method }
            catch {
                if ($method -ne 'WinRM' -or -not $check.Smb -or -not (Test-WinRMSignInError $_.Exception.Message)) { throw }
                Write-Host "$($p.Name): WinRM would not sign in from this PC; going through its admin share instead"
                $ch = Open-RemoteChannel -ComputerName $check.Address -Credential $credential -Method 'Smb'
            }
            Set-BuildStepProgress $p.Id -Percent 30 -Detail 'Copying the agent'
            $config = New-AgentConfig -StatusFolder $StatusFolder -PublicKeys @($publicKey) -CheckInMinutes $CheckInMinutes `
                -Deploy ([pscustomobject]@{ answerFile = ''; image = ''; toolVersion = ''; deployedAt = '' })
            Install-AgentOnRemotePC -Channel $ch -SourceDir $PSScriptRoot -Config $config
            Write-Host "$($p.Name): agent installed over $($ch.Method); waiting for its first check-in"
            $p.State = 'Waiting'; $p.Since = Get-Date
            Set-BuildStepProgress $p.Id -Percent 70 -Detail 'Waiting for its first check-in'
        } catch {
            Write-Host "$($p.Name): $($_.Exception.Message)"
            Stop-Pc $p (Get-RemotingProblemText -Message $_.Exception.Message -Account $(if ($credential) { $credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }))
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
                # Installed, but the computer account can't write to the share (or the network is slow to come up).
                Stop-Pc $p "Installed, but no check-in within $WaitMinutes min: give Domain Computers modify rights on $StatusFolder (see C:\Windows\Temp\ImagingAgent.log on the PC)"
            }
        }
        Start-Sleep -Seconds 5
    }
    $failed = @($pcs | Where-Object State -ne 'Done').Count
    Write-Host "Done: $($pcs.Count - $failed) of $($pcs.Count) PCs checked in." -ForegroundColor Cyan
    if ($failed) { Stop-BuildProgress -Message $(if ($pcs.Count -eq 1) { 'The agent is not working on this PC, see the row below.' } else { "$failed of $($pcs.Count) PCs have no working agent, see the rows below." }) }
    else { Stop-BuildProgress }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Stop-BuildProgress -Message $_.Exception.Message
    throw
} finally {
    if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
}
if (@($pcs | Where-Object State -ne 'Done').Count) { exit 1 }
