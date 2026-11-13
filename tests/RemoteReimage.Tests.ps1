# Plain-PowerShell tests for reimaging PCs from the Computers tab (src/RemoteReimage.psm1): serial numbers, reimage
# jobs on the share, the one-time boot entry, the checks before a PC is touched, and how Deploy-Image takes a job.
# Run: pwsh -File tests/RemoteReimage.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/RemoteReimage.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Assert-Throws([scriptblock]$Action, $Name) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true $Name
}

# Serial numbers
Assert-Equal (ConvertTo-SerialKey ' 5cg1234xyz ') '5CG1234XYZ' 'a serial is trimmed and upper case'
Assert-Equal (ConvertTo-SerialKey 'VMware-56 4d 12, ab') 'VMWARE-56_4D_12__AB' 'spaces and commas become _'
foreach ($bad in '', 'To be filled by O.E.M.', 'Default string', '0000000000', 'System Serial Number', 'N/A') {
    Assert-Equal (Test-UsableSerial $bad) $false "serial '$bad' is not unique to one PC"
}
Assert-Throws { ConvertTo-SerialKey 'To be filled by O.E.M.' } 'a job cannot be keyed by a shared serial'

$root = Join-Path ([IO.Path]::GetTempPath()) ("reimage-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $root 'AnswerFiles') -Force | Out-Null
Set-Content -Path (Join-Path $root 'AnswerFiles/Staff-W11.xml') -Value '<answer/>'
try {
    $now = [datetime]::new(2026, 11, 11, 14, 0, 0, [DateTimeKind]::Local)
    Assert-Throws { New-ReimageJob -ContentRoot $root -Serial 'ABC123' -AnswerFile 'Missing' -Now $now } 'a job needs an answer file that is on the share'

    $job = New-ReimageJob -ContentRoot $root -Serial 'abc123' -Uuid '4C4C4544-0001' -AnswerFile 'Staff-W11' -ComputerName 'pc01' -OU 'OU=Laptops,DC=corp,DC=local' -ExpiresHours 2 -Now $now
    Assert-Equal $job.computerName 'PC01' 'the job keeps the name in upper case'
    Assert-Equal (Test-Path (Join-Path $root 'Reimage/ABC123.json')) $true 'the job is written by serial'
    Assert-Equal (Get-ReimageJob -ContentRoot $root -Serial 'ABC123').ou 'OU=Laptops,DC=corp,DC=local' 'the job keeps the OU'

    $states = Get-ReimageStates -ContentRoot $root -Now $now.AddMinutes(1)
    Assert-Equal $states['PC01'] 'Waiting: Staff-W11' 'the console shows the waiting job by computer name'
    Assert-Equal (Find-ReimageJobByName -ContentRoot $root -ComputerName 'pc01').serial 'abc123' 'the console finds the job by name to cancel it'

    $notes = [Collections.Generic.List[string]]::new()
    $note = { param($m) $notes.Add($m) }
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Serial 'OTHER1' -Now $now)) $true 'another PC finds no job'
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Serial 'ABC123' -Uuid '4C4C4544-9999' -Now $now -OnNote $note)) $true 'a PC with the same serial but another UUID does not take it'
    Assert-Equal ($notes.Count) 1 'that is logged'
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Serial 'ABC123' -Now $now.AddHours(17) -OnNote $note)) $true 'an expired job is not taken'
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Serial 'To be filled by O.E.M.' -Now $now)) $true 'a shared serial never takes a job'

    # WinPE's clock hours ahead (an older stick reads the PC's Toronto clock as Pacific time): the job is still taken.
    $taken = Receive-ReimageJob -ContentRoot $root -Serial 'ABC123' -Uuid '4C4C4544-0001' -Now $now.AddHours(3)
    Assert-Equal $taken.answerFile 'Staff-W11' 'WinPE takes the job for its serial'
    Assert-Equal (Test-Path (Join-Path $root 'Reimage/ABC123.json')) $false 'taking a job removes it, so it runs once'
    Assert-Equal ($null -eq (Receive-ReimageJob -ContentRoot $root -Serial 'ABC123' -Now $now.AddMinutes(3))) $true 'a second start of WinPE finds no job'
    Assert-Equal ($null -ne (Get-StartedJob -ContentRoot $root -Serial 'ABC123' -RequestedAt $job.requestedAt)) $true 'the console finds the job it queued, whatever WinPE''s clock said'
    Assert-Equal ($null -eq (Get-StartedJob -ContentRoot $root -Serial 'ABC123' -RequestedAt $now.AddHours(-5).ToString('o'))) $true 'an older job does not count for a new reimage'
    Assert-Equal ($null -ne (Get-StartedJob -ContentRoot $root -Serial 'ABC123' -Since $now)) $true 'by time: a start after the request'
    Assert-Equal ($null -eq (Get-StartedJob -ContentRoot $root -Serial 'ABC123' -Since $now.AddHours(4))) $true 'by time: an older start does not count'
    $states = Get-ReimageStates -ContentRoot $root -Now $now.AddHours(3).AddMinutes(1)
    Assert-Equal $states['PC01'] "Started $($now.AddHours(3).ToString('HH:mm'))" 'the console shows when it started'

    # A job with no UUID (the PC did not report one) is taken by serial alone.
    [void](New-ReimageJob -ContentRoot $root -Serial 'XYZ9' -AnswerFile 'Staff-W11' -Now $now)
    Assert-Equal ($null -ne (Receive-ReimageJob -ContentRoot $root -Serial 'XYZ9' -Uuid 'ANY' -Now $now)) $true 'a job without UUID is taken by serial'
    [void](New-ReimageJob -ContentRoot $root -Serial 'CANCEL1' -AnswerFile 'Staff-W11' -ComputerName 'PC09' -Now $now)
    Remove-ReimageJob -ContentRoot $root -Serial 'cancel1'
    Assert-Equal ($null -eq (Get-ReimageJob -ContentRoot $root -Serial 'CANCEL1')) $true 'a cancelled job is gone'

    # Network boot image and the checks before a reimage
    $settings = [pscustomobject]@{ share = [pscustomobject]@{ path = '\\srv\Deploy' } }
    $boot = Get-NetworkBootImage -ContentRoot $root
    Assert-Equal $boot.Exists $false 'no network boot image yet'
    Assert-Equal (@(Get-RemoteReimageProblems -Settings $settings -Boot $boot)[0] -like 'No network boot image*') $true 'a missing boot image stops the reimage'
    Assert-Equal (@(Get-RemoteReimageProblems -Settings ([pscustomobject]@{ share = [pscustomobject]@{ path = '' } }) -Boot $boot)[0] -like 'No deployment share*') $true 'no share stops the reimage'
    New-Item -ItemType Directory -Path (Join-Path $root 'Boot') -Force | Out-Null
    Set-Content -Path (Join-Path $root 'Boot/boot.wim') -Value 'x'
    '{ "built": "2026-11-11 10:00", "locked": true, "share": "\\\\srv\\Deploy" }' | Set-Content -Path (Join-Path $root 'Boot/boot.json')
    $boot = Get-NetworkBootImage -ContentRoot $root
    Assert-Equal $boot.Built '2026-11-11 10:00' 'the boot image build time is read'
    Assert-Equal (@(Get-RemoteReimageProblems -Settings $settings -Boot $boot)[0] -like '*WinPE password*') $true 'a boot image with a WinPE password stops the reimage'
    '{ "built": "2026-11-11 10:00", "locked": false, "share": "\\\\old\\Deploy" }' | Set-Content -Path (Join-Path $root 'Boot/boot.json')
    Assert-Equal (@(Get-RemoteReimageProblems -Settings $settings -Boot (Get-NetworkBootImage -ContentRoot $root))[0] -like '*maps \\old\Deploy*') $true 'a boot image for another share stops the reimage'
    '{ "built": "2026-11-11 10:00", "locked": false, "share": "\\\\srv\\Deploy" }' | Set-Content -Path (Join-Path $root 'Boot/boot.json')
    Assert-Equal @(Get-RemoteReimageProblems -Settings $settings -Boot (Get-NetworkBootImage -ContentRoot $root)).Count 0 'a matching unlocked boot image is ready'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# The PCs handed over by the console. PowerShell 5.1 returned the JSON list as one object, and the first real
# reimage tried to reach a PC whose address was the array's Address() method.
$tf = [IO.Path]::Combine([IO.Path]::GetTempPath(), "targets-$([guid]::NewGuid()).json")
try {
    ConvertTo-Json -InputObject @([ordered]@{ name = 'dgwhzlg3'; address = 'DGWHZLG3.corp.local'; ou = 'OU=Staff,DC=corp,DC=local' }) | Set-Content -Path $tf
    $one = @(Read-ReimageTargets -Path $tf)
    Assert-Equal $one.Count 1 'one PC from the console is one target'
    Assert-Equal ($one[0].address -is [string]) $true 'its address is text'
    Assert-Equal $one[0].address 'DGWHZLG3.corp.local' 'its address is the DNS name'
    Assert-Equal $one[0].name 'DGWHZLG3' 'its name'
    Assert-Equal $one[0].ou 'OU=Staff,DC=corp,DC=local' 'its OU'
    # What 5.1 handed over: the whole list as one item.
    $nested = @(, @([pscustomobject]@{ name = 'PC1'; address = 'pc1.corp.local' }))
    Assert-Equal ("$($nested[0].address)" -like '*Address(int*') $true 'the 5.1 bug is reproduced: an array in an array shows its Address() method'
    ConvertTo-Json -InputObject @([ordered]@{ name = 'PC1'; address = 'pc1.corp.local' }, [ordered]@{ name = 'PC2'; address = '' }) | Set-Content -Path $tf
    $two = @(Read-ReimageTargets -Path $tf)
    Assert-Equal $two.Count 2 'two PCs are two targets'
    Assert-Equal $two[1].address 'PC2' 'a PC with no DNS name is reached by its name'
} finally { Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue }

# Remoting errors become one line saying what to do
Assert-Equal ((Get-RemotingProblemText -Message 'Connecting to remote server PC1 failed: The WinRM client cannot process the request. ... add the destination computer to the TrustedHosts configuration setting.' -Account 'CORP\svc') -like '*not in the domain*') $true 'a TrustedHosts error says the console PC is not in the domain'
Assert-Equal ((Get-RemotingProblemText -Message 'Connecting to remote server PC1 failed with the following error message : Access is denied.' -Account 'CORP\svc') -like 'CORP\svc is not an administrator*') $true 'access denied names the account'
Assert-Equal ((Get-RemotingProblemText -Message "first line`nsecond line" -Account 'x')) 'first line' 'another error keeps its first line'

# The PC as it answers over remoting
$ok = [pscustomobject]@{ ComputerName = 'PC01'; Firmware = 'UEFI'; Serial = 'ABC123'; FreeC = 50GB }
Assert-Equal @(Test-RemoteTarget -Info $ok -ExpectedName 'PC01').Count 0 'a UEFI PC with its own name and serial can be reimaged'
Assert-Equal (@(Test-RemoteTarget -Info ([pscustomobject]@{ ComputerName = 'PC77'; Firmware = 'UEFI'; Serial = 'ABC123'; FreeC = 50GB }) -ExpectedName 'PC01')[0] -like '*answers as PC77*') $true 'an address that answers as another PC is refused'
Assert-Equal (@(Test-RemoteTarget -Info ([pscustomobject]@{ ComputerName = 'PC01'; Firmware = 'Legacy'; Serial = 'ABC123'; FreeC = 50GB }) -ExpectedName 'PC01')[0] -like '*legacy BIOS*') $true 'a legacy BIOS PC is refused'
Assert-Equal (@(Test-RemoteTarget -Info ([pscustomobject]@{ ComputerName = 'PC01'; Firmware = 'UEFI'; Serial = 'Default string'; FreeC = 50GB }) -ExpectedName 'PC01')[0] -like '*not unique*') $true 'a shared serial is refused'
Assert-Equal (@(Test-RemoteTarget -Info ([pscustomobject]@{ ComputerName = 'PC01'; Firmware = 'UEFI'; Serial = 'ABC123'; FreeC = 500MB }) -ExpectedName 'PC01')[0] -like '*free on C:*') $true 'a full C: is refused'

# The one-time boot entry
Assert-Equal (Get-BcdGuid 'The entry {0a1b2c3d-1111-2222-3333-444455556666} was successfully created.') '{0a1b2c3d-1111-2222-3333-444455556666}' 'GUID from bcdedit /create (English)'
Assert-Equal (Get-BcdGuid "L'entr$([char]0xE9)e {0a1b2c3d-1111-2222-3333-444455556666} a $([char]0xE9)t$([char]0xE9) cr$([char]0xE9)$([char]0xE9)e.") '{0a1b2c3d-1111-2222-3333-444455556666}' 'GUID from bcdedit /create (French)'
Assert-Equal ($null -eq (Get-BcdGuid 'Access is denied.')) $true 'no GUID when bcdedit failed'
$cmds = @(Get-LocalBootCommands -RamdiskId '{r}' -LoaderId '{l}')
$text = ($cmds | ForEach-Object { $_ -join ' ' }) -join "`n"
Assert-Equal ($text -match [regex]::Escape('/set {l} osdevice ramdisk=[C:]\_ImagingBoot\boot.wim,{r}')) $true 'WinPE starts from boot.wim on C: as a RAM disk'
Assert-Equal ($text -match [regex]::Escape('/set {r} ramdisksdipath \_ImagingBoot\boot.sdi')) $true 'the RAM disk uses boot.sdi next to it'
Assert-Equal ($text -match 'winload\.efi') $true 'UEFI loader'
Assert-Equal ($cmds[-1] -join ' ') '/bootsequence {l}' 'the entry is used for the next start only, last'

# The copy on the PC: admins only (boot.wim holds the answer file key), and gone if the PC starts Windows again.
Assert-Equal ((Get-LocalBootFolderAclArgs) -join ' ') 'C:\_ImagingBoot /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F' 'C:\_ImagingBoot: no inherited access, Administrators and SYSTEM only'
$clean = Get-LocalBootCleanupCommand -BootEntry '{l}'
Assert-Equal $clean 'cmd.exe /c rd /s /q C:\_ImagingBoot & bcdedit /delete {l} /f & schtasks /Delete /TN ImagingTool\RemoveImagingBoot /F' 'the startup task removes WinPE, its boot entry and itself'
Assert-Equal ($clean.Length -le 261) $true 'the task command fits schtasks /TR'
$reimage = Get-Content -Raw (Join-Path $repo 'src/RemoteReimage.psm1')
$aclAt = $reimage.IndexOf('& icacls.exe @AclArgs'); $copyAt = $reimage.IndexOf("Copy-Item -LiteralPath `$BootWim")
Assert-Equal ($aclAt -gt 0 -and $aclAt -lt $copyAt) $true 'the folder is locked before boot.wim is copied in'
Assert-Equal ($reimage -match "schtasks\.exe /Create /TN 'ImagingTool\\RemoveImagingBoot'") $true 'the cleanup task is created with the boot entry'
$start = Get-Content -Raw (Join-Path $repo 'src/Start-RemoteReimage.ps1')
Assert-Equal ($start -match 'Remove-LocalDiskBoot -ComputerName \$p\.Address') $true 'a time-out takes WinPE off the PC when it answers'
Assert-Equal ($start -match 'Get-StartedJob -ContentRoot \$ContentRoot -Serial \$p\.Serial -RequestedAt') $true 'the console matches the started job by its own time stamp'

# The build gives WinPE this PC's time zone.
$media = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
Assert-Equal ($media -match '/Set-TimeZone:\$tz') $true 'the build sets the WinPE time zone'

# Deploy-Image takes the job before the naming list and the wizard, and keeps the name and OU.
$deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
Assert-Equal ($deploy -match "Import-Module \(Join-Path \`$PSScriptRoot 'RemoteReimage.psm1'\)") $true 'Deploy-Image loads RemoteReimage.psm1'
$find = $deploy.IndexOf('$root = Find-ContentRoot'); $take = $deploy.IndexOf('Receive-ReimageJob'); $naming = $deploy.IndexOf('$listed = Find-NamingEntry'); $wizard = $deploy.IndexOf('Show-DeployWizard -Hardware')
Assert-Equal ($find -lt $take -and $take -lt $naming -and $naming -lt $wizard) $true 'the job is taken once the share is mapped, before the naming list and the wizard'
Assert-Equal ($deploy -match '\$script:CanAskSecrets = -not \$NoPrompt -and -not \$job') $true 'a reimaged PC never waits for a typed password'
Assert-Equal ($deploy -match "-or \`$job\) \{") $true 'a job starts without the wizard'
Assert-Equal ($deploy -match 'OU = \$job\.ou') $true 'the job OU replaces the answer file OU'
Assert-Equal ($deploy -match '\$job -and -not \$answer\.Shutdown -and -not \$answer\.Reboot\) \{ \$answer\.Reboot = \$true') $true 'a reimaged PC restarts into Windows by itself'

# WinPE and Windows PowerShell 5.1 read these files: ASCII only.
foreach ($f in 'src/RemoteReimage.psm1', 'src/Start-RemoteReimage.ps1') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $f))
    Assert-Equal (@($bytes | Where-Object { $_ -gt 127 }).Count) 0 "$f is ASCII"
}

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All remote reimage tests passed.' -ForegroundColor Green
