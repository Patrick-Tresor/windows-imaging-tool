# Plain-PowerShell tests for the agent on imaged PCs (src/ImagingAgent.psm1, ImagingAgent.ps1): the console's key,
# signed jobs and what a PC refuses, check-ins and how the Computers tab shows them, the task, and how deploy,
# first boot, the media build and the console use it.
# Run: pwsh -File tests/ImagingAgent.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/ImagingAgent.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ("agent-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
$status = Join-Path $root 'Status'
try {
    # The console's key pair: made once, the private part in config\secrets, the public part next to it.
    Assert-Equal ($null -eq (Get-AgentSigningKey -ContentRoot $root)) $true 'no key until one is made'
    $private = Get-AgentSigningKey -ContentRoot $root -Create
    Assert-Equal ($private -match '<P>') $true 'the private key has its private parts'
    Assert-Equal (Test-Path (Join-Path $root 'config/secrets/agent-key.xml')) $true 'the private key is in config\secrets (never on a stick)'
    $public = Get-AgentPublicKey -ContentRoot $root
    Assert-Equal ($public -match '<Modulus>' -and $public -notmatch '<P>') $true 'the public key has no private parts'
    Assert-Equal (Get-AgentSigningKey -ContentRoot $root -Create) $private 'the key is made only once'
    Remove-Item (Join-Path $root 'config/agent-public-key.xml')
    Assert-Equal (Get-AgentPublicKey -ContentRoot $root) $public 'a deleted public key file is written again from the private key'
    Assert-Equal ((Get-AgentKeyId $public).Length) 12 'a key has a short id for the logs'

    # A PC's check-in.
    $now = [datetime]::new(2026, 11, 23, 15, 0, 0, [DateTimeKind]::Local)
    $identity = [pscustomobject]@{ serial = 'abc123'; uuid = '4C4C4544-0001'; maker = 'Dell Inc.'; model = 'Latitude 5521'; firmware = 'UEFI'; firmwareFrom = 'bcdedit' }
    $record = New-AgentCheckIn -Identity $identity -Network ([pscustomobject]@{ ipAddresses = @('10.1.2.34', '192.168.56.1'); macAddress = 'AA-BB' }) `
        -Deploy ([pscustomobject]@{ answerFile = 'Staff-W11'; image = 'Win11.wim'; toolVersion = 'abc1234'; deployedAt = '2026-11-20T10:00:00' }) `
        -AgentId 'agent-1' -ComputerName 'pc01' -Account 'CORP\PC01$' -AccountSid 'S-1-5-21-1-2-3-1104' -FreeC 50GB -Result 'Result: Ready' -Now $now
    Assert-Equal $record.computerName 'PC01' 'the name is upper case'
    # As on GWHZLG3: Windows gives the boot time as a date. A [Nullable[datetime]] parameter holds a plain date.
    $booted = New-AgentCheckIn -Identity $identity -AgentId 'agent-1' -BootTime $now.AddHours(-2) -FreeC $null -Now $now
    Assert-Equal $booted.bootTime $now.AddHours(-2).ToString('o') 'a check-in with the boot time is made (no null-valued expression)'
    Assert-Equal $record.ipAddress '10.1.2.34' 'the first address (the adapter with a gateway) is the IP'
    Save-AgentCheckIn -StatusFolder $status -Record $record
    Assert-Equal (Test-Path (Join-Path $status 'Agents/ABC123.json')) $true 'it is saved by serial in Status\Agents'
    $old = New-AgentCheckIn -Identity ([pscustomobject]@{ serial = 'OLD1'; uuid = 'U2' }) -AgentId 'agent-2' -ComputerName 'PC02' -Now $now.AddHours(-30)
    Save-AgentCheckIn -StatusFolder $status -Record $old
    $rows = @(Get-AgentCheckIns -StatusFolder $status -Now $now.AddMinutes(4))
    Assert-Equal $rows.Count 2 'the console reads every check-in'
    $pc1 = Find-AgentCheckIn -CheckIns $rows -ComputerName 'pc01'
    Assert-Equal $pc1.Online $true 'checked in 4 minutes ago: online'
    Assert-Equal $pc1.LastSeenText '4 min ago' 'when it last checked in'
    Assert-Equal (Find-AgentCheckIn -CheckIns $rows -ComputerName 'PC02').Online $false 'checked in 30 hours ago: not online'
    Assert-Equal (Find-AgentCheckIn -CheckIns $rows -Serial 'ABC123').computerName 'PC01' 'found by serial too (Dashboard)'
    Assert-Equal ((Get-AgentCheckIns -StatusFolder $status -Now $now.AddMinutes(17)) | Where-Object computerName -eq 'PC01').Online $false 'three missed check-ins: not online'
    Assert-Equal (Format-AgentLastSeen -LastSeen $now -Now $now.AddSeconds(30)) 'Just now' 'just now'
    Assert-Equal (Format-AgentLastSeen -LastSeen $now -Now $now.AddHours(3)) '3 h ago' 'hours'
    Assert-Equal (Format-AgentLastSeen -LastSeen $now -Now $now.AddDays(1).AddHours(-1)) "Yesterday 15:00" 'yesterday'

    # The Computers tab: a PC whose WinRM and file sharing are blocked is still online through its agent.
    $view = Get-AgentRowView -Check ([pscustomobject]@{ Online = $false; State = 'No access'; Detail = 'blocks WinRM' }) -Agent $pc1 -Name 'PC01'
    Assert-Equal $view.Online 'Agent' 'blocked on the network, but its agent checked in: Online says Agent'
    Assert-Equal $view.Agent '4 min ago' 'the Agent column says when it last checked in'
    Assert-Equal ($view.AgentDetail -match 'Staff-W11' -and $view.AgentDetail -match 'Result: Ready') $true 'the tooltip has the image and the deploy result'
    $view = Get-AgentRowView -Check ([pscustomobject]@{ Online = $true; State = 'Yes'; Detail = 'WinRM answers' }) -Agent $null -Name 'PC03'
    Assert-Equal "$($view.Online)|$($view.Agent)" 'Yes|' 'no agent: the network check alone'
    $view = Get-AgentRowView -Check $null -Agent (Find-AgentCheckIn -CheckIns $rows -ComputerName 'PC02') -Name 'PC02'
    Assert-Equal ($view.Agent -like 'Off: *') $true 'an agent that stopped checking in shows as off'
    $info = ConvertTo-AgentTargetInfo $pc1
    Assert-Equal "$($info.Firmware)|$($info.Serial)|$($info.FreeC)" "UEFI|abc123|$(50GB)" 'a check-in reads like the network check of a PC'
    Import-Module (Join-Path $repo 'src/RemoteReimage.psm1') -Force
    Assert-Equal (@(Test-RemoteTarget -Info $info -ExpectedName 'PC01').Count) 0 'so the same checks run before a reimage'
    # GWHZLG3: an agent from before the fix read PEFirmwareType (WinPE only) and said Legacy on a UEFI PC.
    $oldAgent = [pscustomobject]@{ computerName = 'PC01'; firmware = 'Legacy'; serial = 'abc123'; uuid = 'U1'; freeC = 50GB }
    $info = ConvertTo-AgentTargetInfo $oldAgent
    Assert-Equal $info.Firmware 'Unknown' 'an old agent firmware value is not trusted'
    Assert-Equal (@(Test-RemoteTarget -Info $info -ExpectedName 'PC01').Count) 0 'so it does not stop the reimage (WinPE checks again)'

    # A signed reimage job, with the network boot image next to it.
    $wim = Join-Path $root 'boot.wim'
    [IO.File]::WriteAllBytes($wim, [byte[]](1..200))
    $access = [Collections.Generic.List[string]]::new()
    $job = New-AgentJob -StatusFolder $status -PrivateKey $private -CheckIn $pc1 -BootWim $wim -Now $now -SetFolderAccess { param($f, $a) $access.Add($a) }
    $jobDir = Join-Path $status 'Agents/Jobs/ABC123'
    Assert-Equal (Test-Path (Join-Path $jobDir 'job.json')) $true 'the job is in Status\Agents\Jobs\<serial>'
    Assert-Equal (Test-Path (Join-Path $jobDir 'boot.wim')) $true 'the boot image is next to it'
    Assert-Equal $access[0] '*S-1-5-21-1-2-3-1104' 'the folder is limited to the PC''s computer account (by SID)'
    Assert-Equal $job.bootWimSha256 (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash 'the boot image checksum is in the signed job'
    $mine = [pscustomobject]@{ serial = 'ABC123'; uuid = '4C4C4544-0001'; agentId = 'agent-1' }
    $read = Get-AgentJob -StatusFolder $status -Serial 'abc123'
    Assert-Equal $read.id $job.id 'the PC reads its job'
    Assert-Equal ($null -eq (Test-AgentJob -Job $read -PublicKeys @($public) -Identity $mine -Now $now.AddMinutes(1))) $true 'the PC takes a job the console signed for it'

    $refuse = {
        param($Name, $Change, [string]$Like, $Now = $now.AddMinutes(1), $Identity = $mine, $Keys = @($public), $Done = @())
        $j = $read | ConvertTo-Json -Depth 4 | ConvertFrom-Json
        & $Change $j
        $why = Test-AgentJob -Job $j -PublicKeys $Keys -Identity $Identity -DoneIds $Done -Now $Now
        Assert-Equal ([bool]($why -and $why -like $Like)) $true "$Name ($why)"
    }
    & $refuse 'a job changed after signing is refused' { param($j) $j.delaySeconds = 0 } '*not signed*'
    & $refuse 'a job for another serial is refused' { param($j) $j.serial = 'OTHER' } '*not signed*'
    & $refuse 'a job without signature is refused' { param($j) $j.signature = '' } '*not signed*'
    $other = (New-AgentKeyPair)
    & $refuse 'a job signed with another key is refused' { param($j) $null = Set-AgentJobSignature -Job $j -PrivateKey $other.Private } '*not signed*'
    & $refuse 'a PC with no console key takes no job' { param($j) } '*no console key*' -Keys @()
    & $refuse 'another PC refuses it' { param($j) } '*serial*' -Identity ([pscustomobject]@{ serial = 'XYZ'; uuid = '4C4C4544-0001'; agentId = 'agent-1' })
    & $refuse 'a PC with the same serial but another UUID refuses it' { param($j) } '*UUID*' -Identity ([pscustomobject]@{ serial = 'ABC123'; uuid = 'OTHER'; agentId = 'agent-1' })
    & $refuse 'the same PC after a reimage (new agent id) refuses it' { param($j) } '*earlier install*' -Identity ([pscustomobject]@{ serial = 'ABC123'; uuid = '4C4C4544-0001'; agentId = 'agent-new' })
    & $refuse 'a job that ran already is refused' { param($j) } '*ran here already*' -Done @($read.id)
    & $refuse 'an expired job is refused' { param($j) } '*expired*' -Now $now.AddHours(2)
    & $refuse 'a job from the future is refused' { param($j) } '*future*' -Now $now.AddHours(-1)
    & $refuse 'an unreadable job file is refused' { param($j) $j | Add-Member -NotePropertyName unreadable -NotePropertyValue 'bad json' } '*can''t be read*'
    # Signed fields cover all of what the agent acts on.
    foreach ($f in 'id', 'action', 'serial', 'uuid', 'agentId', 'expiresAt', 'bootWimSha256', 'delaySeconds', 'message') {
        Assert-Equal ((Get-AgentJobText $read) -match "(?m)^$f=") $true "the signature covers $f"
    }

    Remove-AgentJob -StatusFolder $status -Serial 'ABC123' -JobFileOnly
    Assert-Equal "$(Test-Path (Join-Path $jobDir 'job.json'))|$(Test-Path (Join-Path $jobDir 'boot.wim'))" 'False|True' 'the PC deletes the job file once taken'
    # A folder another PC made beforehand is never reused: the console makes it fresh.
    Set-Content -Path (Join-Path $jobDir 'planted.txt') -Value 'x'
    $job2 = New-AgentJob -StatusFolder $status -PrivateKey $private -CheckIn $pc1 -BootWim $wim -Now $now -SetFolderAccess { param($f, $a) }
    Assert-Equal (Test-Path (Join-Path $jobDir 'planted.txt')) $false 'the job folder is made fresh'
    Assert-Equal ($job2.id -ne $job.id) $true 'each job has its own id'
    Assert-Throws { New-AgentJob -StatusFolder $status -PrivateKey $private -CheckIn $pc1 -BootWim $wim -SetFolderAccess { param($f, $a) Set-Content (Join-Path $f 'x') 'y' } } '*while it was made*' 'a file written into the folder while it was made stops the job'
    Assert-Equal (Test-Path $jobDir) $false 'and the folder is removed'
    Assert-Throws { New-AgentJob -StatusFolder $status -PrivateKey $private -CheckIn $pc1 -BootWim (Join-Path $root 'none.wim') -SetFolderAccess { param($f, $a) } } '*No network boot image*' 'no boot image, no job'
    Assert-Throws { New-AgentJob -StatusFolder $status -PrivateKey $private -CheckIn ([pscustomobject]@{ serial = 'S1'; computerName = 'X' }) -BootWim $wim } '*no id*' 'an agent with no id gets no job'
    Remove-AgentJob -StatusFolder $status -Serial 'ABC123'
    Assert-Equal (Test-Path $jobDir) $false 'the console removes the job and its boot image'
    Assert-Equal ($null -eq (Get-AgentJob -StatusFolder $status -Serial 'To be filled by O.E.M.')) $true 'a shared serial never has a job'

    # Where a new PC's agent checks in: the folder WinPE reported to, or for a USB deploy that could not reach the
    # share (status kept on the stick), the share's Status folder from the settings.
    $shareSettings = [pscustomobject]@{ share = [pscustomobject]@{ path = '\\srv\Deploy\' } }
    Assert-Equal (Get-AgentStatusFolder -StatusTarget ([pscustomobject]@{ Unc = '\\srv\Deploy\Status'; Local = 'R:\' }) -Settings $shareSettings) '\\srv\Deploy\Status' 'the folder WinPE reported to'
    Assert-Equal (Get-AgentStatusFolder -StatusTarget ([pscustomobject]@{ Unc = $null; Local = 'E:\Status' }) -Settings $shareSettings) '\\srv\Deploy\Status' 'a USB deploy that could not reach the share still gets the agent'
    Assert-Equal (Get-AgentStatusFolder -StatusTarget $null -Settings ([pscustomobject]@{ share = [pscustomobject]@{ path = '\\deploy-server\Deploy' } })) '' 'the shipped example share is no share'
    Assert-Equal (Get-AgentStatusFolder -StatusTarget $null -Settings ([pscustomobject]@{ share = [pscustomobject]@{ path = '' } })) '' 'USB only, no share: no agent'

    # agent.json and the task.
    $cfg = New-AgentConfig -StatusFolder '\\server\Deploy\Status' -PublicKeys @($public, '') -CheckInMinutes 0
    Assert-Equal "$($cfg.checkInMinutes)|$(@($cfg.publicKeys).Count)" '1|1' 'agent.json: at least 1 minute, empty keys left out'
    $xml = [xml](Get-AgentTaskXml)
    Assert-Equal $xml.Task.Principals.Principal.UserId 'S-1-5-18' 'the task runs as SYSTEM'
    Assert-Equal $xml.Task.Settings.MultipleInstancesPolicy 'IgnoreNew' 'a second start while it runs is ignored'
    Assert-Equal $xml.Task.Settings.ExecutionTimeLimit 'PT0S' 'it keeps running'
    Assert-Equal ($null -ne $xml.Task.Triggers.BootTrigger) $true 'it starts with Windows'
    Assert-Equal $xml.Task.Triggers.TimeTrigger.Repetition.Interval 'PT15M' 'and is started again every 15 minutes if it stopped'
    Assert-Equal ($xml.Task.Actions.Exec.Arguments -match 'C:\\ProgramData\\ImagingTool\\Agent\\ImagingAgent\.ps1') $true 'it runs the agent from ProgramData'
    foreach ($f in Get-AgentFileNames) { Assert-Equal (Test-Path (Join-Path $repo "src/$f")) $true "the agent file $f exists" }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# The share's rights: the agents write as their computer accounts (Domain Computers).
Assert-Equal (Get-DomainComputersSid 'S-1-5-21-111-222-333-1104') 'S-1-5-21-111-222-333-515' 'Domain Computers by SID, from any account of the domain'
Assert-Throws { Get-DomainComputersSid 'S-1-5-18' } 'a local account gives no domain'
$shares = @{ imager = 'C:\imager'; 'ADMIN$' = 'C:\Windows' }
$r = Resolve-LocalSharePath -Unc '\\IMAGER\imager\Status' -Shares $shares -ThisPC 'IMAGER'
Assert-Equal "$($r.Share)|$($r.Path)" 'imager|C:\imager\Status' 'a share on this PC gives its local folder'
Assert-Equal (Resolve-LocalSharePath -Unc '\\imager.boreal.local\imager\Status' -Shares $shares -ThisPC 'IMAGER').Path 'C:\imager\Status' 'by full name too'
Assert-Equal ($null -eq (Resolve-LocalSharePath -Unc '\\FILES01\imager\Status' -Shares $shares -ThisPC 'IMAGER')) $true 'a share on another server is left alone'
Assert-Equal ($null -eq (Resolve-LocalSharePath -Unc '\\IMAGER\other\Status' -Shares $shares -ThisPC 'IMAGER')) $true 'an unknown share is left alone'

# Why an agent did not check in, from its log.
Assert-Equal (Get-AgentLogProblem -Lines @() -TaskState 'Ready' -TaskResult '0x1') 'The agent never started (task Ready, last result 0x1)' 'no log: it never started'
Assert-Equal (Get-AgentLogProblem -Lines @() ) 'The agent never started (no task ImagingTool\Agent)' 'no log and no task'
$denied = @('2026-11-25 13:30:01 Agent started: GWHZLG3, serial GWHZLG3', '2026-11-25 13:30:02 Could not check in to \\IMAGER\imager\Status: Access to the path is denied.')
Assert-Equal ((Get-AgentLogProblem -Lines $denied) -like "The PC's computer account may not write to the share: Could not check in*") $true 'access denied: the share''s rights'
Assert-Equal (Get-AgentLogProblem -Lines @('2026-11-25 13:30:01 The BIOS serial ''0'' is not unique to this PC: the agent can''t check in. It stops.')) "The BIOS serial '0' is not unique to this PC: the agent can't check in. It stops." 'the line that says why it stopped'
Assert-Equal (Get-AgentLogProblem -Lines @('2026-11-25 13:30:01 Agent started: X')) 'Last agent log line: Agent started: X' 'otherwise its last line'
$install = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Install-RemoteAgent.ps1')
Assert-Equal ($install -match 'Grant-StatusFolderAccess -StatusFolder \$StatusFolder') $true 'Install agent gives Domain Computers their rights on the Status folder first'
Assert-Equal ($install -match 'Get-RemoteAgentProblem') $true 'and reads the agent''s log when it does not check in'

# The local channel: the agent restarts its own PC into WinPE with the console's steps.
Import-Module (Join-Path $repo 'src/RemoteReimage.psm1') -Force
$ch = Open-RemoteChannel -ComputerName 'PC01' -Method Local
Assert-Equal (@(Invoke-RemoteChannel -Channel $ch -ArgumentList 2, @('a', 'b') -ScriptBlock { param($n, $list) "$n $($list.Count)" })[0]) '2 2' 'the local channel runs the script block here with its arguments'
$tmp = [IO.Path]::GetTempFileName()
Copy-ToRemoteChannel -Channel $ch -Path $tmp -Destination "$tmp.copy"
Assert-Equal (Test-Path "$tmp.copy") $true 'and copies files here'
Remove-Item $tmp, "$tmp.copy" -Force

# How the rest of the tool uses it.
$agentPs1 = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/ImagingAgent.ps1')
Assert-Equal ($agentPs1 -match '(?s)while \(\$true\) \{\s*#[^\n]*\n\s*try \{') $true 'an error in one round never stops the agent'
Assert-Equal ($agentPs1 -match 'Test-AgentJob') $true 'the agent checks every job before running it'
Assert-Equal ($agentPs1 -match "Invoke-LocalDiskBoot[^\r\n]+-Method Local") $true 'a reimage job restarts the PC into WinPE through the local channel'
Assert-Equal ($agentPs1 -match 'bootWimSha256') $true 'the boot image is checked against the signed checksum'
Assert-Equal ($agentPs1 -match 'Global\\ImagingToolAgent') $true 'one agent at a time'
$deploy = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deploy -match '(?s)Get-AgentStatusFolder -StatusTarget \$statusTarget.{0,80}Copy-AgentToImage -StatusFolder \$agentStatus') $true 'deploy puts the agent on every PC when a share is set, USB deploys too'
Assert-Equal ($deploy -match "(?s)function Copy-AgentToImage.*?Protect-StagedItem -Path \`$dir -Folder.*?Get-AgentFileNames") $true 'its folder is limited to administrators before the files go in'
$firstBoot = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/FirstBoot.ps1')
Assert-Equal ($firstBoot -match '(?s)Agent\\ImagingAgent\.ps1.{0,200}-File \$agentScript -Register') $true 'first boot makes the agent''s task'
$media = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($media -match 'agent-public-key\.xml') $true 'the build puts the console''s public key in boot.wim'
$start = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Start-RemoteReimage.ps1')
Assert-Equal ($start -match '(?s)New-AgentJob.*?Start-PcOverNetwork \$p') $true 'reimage goes through the agent, and over the network when it does not take the job'
$console = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/ImagingConsole.ps1')
Assert-Equal ($console -match "'-StatusFolder'.*'-KeyRoot'") $true 'the console tells the reimage where the agents check in and which key signs'
Assert-Equal ($console -match 'Install-RemoteAgent\.ps1') $true 'Install agent puts it on PCs imaged before'
$xaml = Get-Content -Raw -LiteralPath (Join-Path $repo 'src/Console/MainWindow.xaml')
Assert-Equal ($xaml -match 'Header="Agent" Binding="\{Binding Agent\}"') $true 'the Computers grid has an Agent column'
Assert-Equal ($xaml -match 'Header="Last seen" Binding="\{Binding LastSeenText\}"') $true 'the Dashboard has a Last seen column'

# WinPE and Windows PowerShell 5.1 read these files: ASCII only.
foreach ($f in 'src/ImagingAgent.psm1', 'src/ImagingAgent.ps1', 'src/Install-RemoteAgent.ps1') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $f))
    Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 "$f is ASCII"
}

Complete-Tests 'All agent tests passed.'
