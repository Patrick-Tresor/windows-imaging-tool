<#
.SYNOPSIS
    Installs the agent on this PC, for a PC the console cannot reach (WinRM and the admin share blocked).
.DESCRIPTION
    The console keeps a copy of this script, the agent files and agent.json (where to check in, the console's public
    key) in <share>\Agent. On the PC, right-click \\server\share\Agent\Install-Agent.cmd and pick Run as administrator.
    It does what the console's Install agent does over the network (ImagingAgent.psm1, Install-AgentOnRemotePC):
    copies the agent to C:\ProgramData\ImagingTool\Agent (administrators and SYSTEM only), makes the SYSTEM task
    ImagingTool\Agent and starts it, then waits for its first check-in.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File \\server\Deploy\Agent\Install-AgentHere.ps1
#>
[CmdletBinding()]
param([int]$WaitMinutes = 6)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Write-Step([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

try {
    $me = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run it as administrator: right-click Install-Agent.cmd, then Run as administrator.'
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) { throw 'This PC is not in the domain: the agent checks in as the computer account, so it only works on domain PCs.' }
    $configPath = [IO.Path]::Combine($here, 'agent.json')
    if (-not [IO.File]::Exists($configPath)) { throw "No agent.json next to this script ($here). Open the console once so it puts it there." }
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    Import-Module ([IO.Path]::Combine($here, 'RemoteReimage.psm1')) -Force
    Import-Module ([IO.Path]::Combine($here, 'ImagingAgent.psm1')) -Force

    Write-Step "Installing the agent on $env:COMPUTERNAME; it will check in to $($config.statusFolder)" Cyan
    $started = Get-Date
    $ch = Open-RemoteChannel -ComputerName $env:COMPUTERNAME -Method Local
    Install-AgentOnRemotePC -Channel $ch -SourceDir $here -Config $config
    Write-Step 'Agent installed and started. Waiting for its first check-in...'

    $serial = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
    $checkIn = [IO.Path]::Combine((Get-AgentFolder $config.statusFolder), "$(ConvertTo-SerialKey $serial).json")
    $log = "$env:WINDIR\Temp\ImagingAgent.log"
    $ok = $false
    while (((Get-Date) - $started).TotalMinutes -lt $WaitMinutes) {
        Start-Sleep -Seconds 5
        try { $fi = New-Object IO.FileInfo $checkIn; if ($fi.Exists -and $fi.LastWriteTime -ge $started.AddMinutes(-1)) { $ok = $true; break } } catch { }
        # This account may not read the Status folder: the agent's own log says when it checked in.
        $since = $started.AddMinutes(-1).ToString('yyyy-MM-dd HH:mm:ss')
        $lines = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 30 -Encoding UTF8 })
        if (@($lines | Where-Object { $_ -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) Checked in to ' -and $Matches[1] -ge $since }).Count) { $ok = $true; break }
    }
    if ($ok) {
        Write-Step "Done: $env:COMPUTERNAME checked in. The console's Computers tab shows it in the Agent column." Green
        exit 0
    }
    $lines = @(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 15 -Encoding UTF8 })
    foreach ($l in $lines) { Write-Step "  agent log: $l" }
    $task = Get-ScheduledTask -TaskPath '\ImagingTool\' -TaskName 'Agent' -ErrorAction SilentlyContinue
    $info = if ($task) { $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue }
    $why = Get-AgentLogProblem -Lines $lines -TaskState $(if ($task) { "$($task.State)" } else { '' }) -TaskResult $(if ($info) { '0x{0:X}' -f [int64]$info.LastTaskResult } else { '' })
    Write-Step "No check-in seen within $WaitMinutes min. $why (log: $log)" Yellow
    if ($task) { Write-Step "  task ImagingTool\Agent: $($task.State)$(if ($info) { ", last result 0x{0:X}" -f [int64]$info.LastTaskResult })" }
    # Read only: an antivirus that blocked one of the agent's files in the last hour.
    try {
        foreach ($d in @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -gt $started.AddHours(-1) -and "$($_.Resources)" -match 'ImagingTool|ImagingAgent' })) {
            Write-Step "  Microsoft Defender blocked: $($d.Resources -join ', ') at $($d.InitialDetectionTime)" Yellow
        }
    } catch { }
    Write-Step 'If the log says it checked in, this account just may not read the Status folder: look at the console instead.' Yellow
    exit 1
} catch {
    Write-Step $_.Exception.Message Red
    exit 1
}
