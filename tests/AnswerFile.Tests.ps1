# Plain-PowerShell tests for answer files: parsing, validation, naming, unattend generation and the
# SmartDeploy import. Run: pwsh -File tests/AnswerFile.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Assert-Throws([scriptblock]$Block, [string]$Like, $Name) {
    try { & $Block; Write-Host "FAIL $Name (no error)" -ForegroundColor Red; $script:failures++ }
    catch {
        if ($_.Exception.Message -like $Like) { Write-Host "PASS $Name" -ForegroundColor Green }
        else { Write-Host "FAIL $Name`n  error: $($_.Exception.Message)" -ForegroundColor Red; $script:failures++ }
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("answer-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # The shipped sample is valid as is.
    $default = Read-AnswerFile -Path (Join-Path $repo 'config/answer-files/Default.xml')
    Assert-Equal "$($default.Mode)|$($default.ImageFile)|$($default.Membership)|$($default.NamingMode)" 'Interactive|Images\Win11-Enterprise.wim|Workgroup|WMI' 'sample answer file parses'
    Assert-Equal $default.Applications.Count 0 'commented-out applications are ignored'

    # Validation.
    $bad = $default.PSObject.Copy()
    $bad.Membership = 'Domain'; $bad.JoinPasswordFile = $null
    $bad.Tasks = @([pscustomobject]@{ Phase = 'LATER'; Command = 'x' })
    $bad.Shares = @([pscustomobject]@{ LocalName = 'Z:'; RemoteName = 'server'; Username = $null; Domain = $null; PasswordFile = $null })
    $problems = @(Test-AnswerFile $bad)
    Assert-Equal $problems.Count 4 'validation lists every problem (join creds, phase, share letter, share path)'
    $bad.Shares = @(); $bad.Tasks = @(); $bad.JoinPasswordFile = 'x'; $bad.DiskOption = 'SmartMigrate'
    Assert-Equal (@(Test-AnswerFile $bad) -join '') "disk/option 'SmartMigrate' is not supported yet; only Recreate (wipe the disk and recreate partitions)." 'unsupported disk option is rejected'

    # Naming.
    $n = $default.PSObject.Copy()
    $n.Prefix = 'lab-'
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue 'pf3x 9k!' -Serial 'S1') 'LAB-PF3X9K' 'WMI name is prefixed and cleaned'
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue 'ABCDEFGHIJKLMNOPQRS') 'LAB-ABCDEFGHIJK' 'name is cut to 15 characters'
    $n.NamingMode = 'Custom'; $n.Prefix = ''; $n.CustomScheme = 'A####-{SERIAL}'
    $name = Resolve-ComputerName -Answer $n -Serial 'XY9' -Random ([Random]::new(1))
    Assert-Equal ($name -match '^A\d{4}-XY9$') $true "custom scheme fills # with digits and {SERIAL} ($name)"
    $n.NamingMode = 'Prompt'
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue 'SER1' -Typed 'kiosk 01') 'KIOSK01' 'typed name wins in prompt mode'

    # Unattend generation.
    $d = $default.PSObject.Copy()
    $d.Membership = 'Domain'; $d.Domain = 'corp.example.com'; $d.OrganizationalUnit = 'OU=Labs,DC=corp,DC=example,DC=com'
    $d.Organization = 'R&D <Labs>'; $d.InputLocale = 'fr-CA'
    $d.Tasks = @([pscustomobject]@{ Phase = 'FIRSTLOGON'; Command = 'a.cmd' }, [pscustomobject]@{ Phase = 'FIRSTBOOT'; Command = 'b.cmd' },
                 [pscustomobject]@{ Phase = 'FIRSTLOGON'; Command = 'c.cmd' })
    [xml]$u = New-UnattendXml -Answer $d -ComputerName 'PC-01' -JoinPassword 'p&ss'
    $ns = [Xml.XmlNamespaceManager]::new($u.NameTable); $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    Assert-Equal $u.SelectSingleNode('//u:ComputerName', $ns).InnerText 'PC-01' 'unattend sets the computer name'
    Assert-Equal $u.SelectSingleNode('//u:JoinDomain', $ns).InnerText 'corp.example.com' 'unattend joins the domain'
    Assert-Equal $u.SelectSingleNode('//u:MachineObjectOU', $ns).InnerText 'OU=Labs,DC=corp,DC=example,DC=com' 'unattend sets the OU'
    Assert-Equal $u.SelectSingleNode('//u:Credentials/u:Password', $ns).InnerText 'p&ss' 'join password is escaped correctly'
    Assert-Equal $u.SelectSingleNode('//u:RegisteredOrganization', $ns).InnerText 'R&D <Labs>' 'special characters survive'
    Assert-Equal $u.SelectSingleNode('//u:InputLocale', $ns).InnerText 'fr-CA' 'unattend sets the input locale'
    Assert-Equal (($u.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine', $ns) | ForEach-Object InnerText) -join ',') 'a.cmd,c.cmd' 'only FIRSTLOGON tasks go to FirstLogonCommands, in order'
    [xml]$wg = New-UnattendXml -Answer $default -ComputerName 'PC-02'
    Assert-Equal $wg.SelectSingleNode('//u:JoinWorkgroup', $ns).InnerText 'WORKGROUP' 'workgroup answer file joins the workgroup'
    # Local account page. A domain PC deployed with no built-in Administrator (the Dell 5521, French OOBE) stopped
    # at "Qui utilisera cet appareil?" because the page was only hidden when the Administrator had a password.
    $hide = { param($doc) $doc.SelectSingleNode('//u:OOBE/u:HideLocalAccountScreen', $ns).InnerText }
    Assert-Equal "$($d.EnableAdministrator)|$(& $hide $u)" 'False|true' 'a domain PC skips the local account page without the built-in Administrator'
    Assert-Equal "$($default.EnableAdministrator)|$(& $hide $wg)" 'False|false' 'a workgroup PC with no Administrator still asks for a local account'
    $wa = $default.PSObject.Copy(); $wa.EnableAdministrator = $true; $wa.AdminPasswordFile = 'config\secrets\admin.txt'
    [xml]$uwa = New-UnattendXml -Answer $wa -ComputerName 'PC-02' -AdminPassword 'a'
    Assert-Equal "$(& $hide $uwa)|$($uwa.SelectSingleNode('//u:AdministratorPassword/u:Value', $ns).InnerText)" 'true|a' 'a workgroup PC with the Administrator skips the page and sets its password'

    # Join account. Windows signs in as Credentials Domain\Username: CORP\svc typed as the user name with svc as the
    # account's domain came out as svc\CORP\svc, and every join attempt failed with 0x89a (bad user name).
    $j = $d.PSObject.Copy(); $j.JoinUser = 'CORP\svc'; $j.JoinDomain = 'svc'
    [xml]$uj = New-UnattendXml -Answer $j -ComputerName 'PC-03' -JoinPassword 'x'
    Assert-Equal "$($uj.SelectSingleNode('//u:Credentials/u:Domain', $ns).InnerText)|$($uj.SelectSingleNode('//u:Credentials/u:Username', $ns).InnerText)" 'CORP|svc' 'DOMAIN\user in the user name wins over a different account domain'
    Assert-Equal (Resolve-JoinAccount -Answer $j).Note "Join account: used CORP\svc from the user name; the account's domain 'svc' was ignored." 'the ignored account domain is noted for the deploy log'
    $j.JoinUser = 'svc'; $j.JoinDomain = ''
    Assert-Equal (Resolve-JoinAccount -Answer $j).Account 'corp.example.com\svc' 'a plain user name signs in to the domain being joined'
    $j.JoinDomain = 'CORP'
    Assert-Equal "$((Resolve-JoinAccount -Answer $j).Account)|$((Resolve-JoinAccount -Answer $j).Note)" 'CORP\svc|' 'a plain user name signs in to the account domain'
    $j.JoinUser = 'svc@corp.example.com'
    [xml]$uj = New-UnattendXml -Answer $j -ComputerName 'PC-03' -JoinPassword 'x'
    Assert-Equal "$($null -eq $uj.SelectSingleNode('//u:Credentials/u:Domain', $ns))|$($uj.SelectSingleNode('//u:Credentials/u:Username', $ns).InnerText)" 'True|svc@corp.example.com' 'a UPN goes in as it is, with no domain in front'
    Assert-Equal @(Test-AnswerFile $j).Count 0 'a UPN join account is valid'
    $j.JoinUser = 'CORP\svc\x'
    Assert-Equal @(@(Test-AnswerFile $j) -like '*must be user, DOMAIN\user or user@domain*').Count 1 'a user name with two backslashes is caught before the disk is wiped'
    Assert-Throws { New-UnattendXml -Answer $j -ComputerName 'PC-03' -JoinPassword 'x' } '*must be user, DOMAIN\user or user@domain*' 'no unattend is written with a bad join account'
    $j.JoinUser = 'svc'; $j.JoinDomain = 'svc\CORP'
    Assert-Equal @(@(Test-AnswerFile $j) -like "*account's domain 'svc\CORP'*").Count 1 'an account domain with a backslash is caught before the disk is wiped'

    $plan = New-FirstBootPlan -Answer $d -AppDefinitions @()
    Assert-Equal (($plan.tasks | ForEach-Object command) -join ',') 'b.cmd' 'first boot plan holds the FIRSTBOOT tasks'

    # Applications.
    $apps = Join-Path $tmp 'Applications'
    New-Item -ItemType Directory -Path (Join-Path $apps 'Zoom') -Force | Out-Null
    '{ "command": "msiexec /i zoom.msi /qn" }' | Set-Content (Join-Path $apps 'Zoom/app.json')
    $def = Get-AppDefinition -AppRoot $apps -Name 'Zoom'
    Assert-Equal "$($def.command)|$($def.successCodes -join ',')" 'msiexec /i zoom.msi /qn|0,3010,1641' 'app.json is read with default success codes'
    Assert-Throws { Get-AppDefinition -AppRoot $apps -Name 'Missing' } '*no app.json*' 'missing application is reported before the disk is wiped'

    # Round trip.
    $rt = Join-Path $tmp 'RoundTrip.xml'
    $d.JoinUser = 'svc'; $d.JoinPasswordFile = 'config\secrets\join.txt'; $d.Applications = @('Zoom', 'Teams')
    Export-AnswerFile -Answer $d -Path $rt
    $back = Read-AnswerFile -Path $rt
    Assert-Equal "$($back.Domain)|$($back.Organization)|$($back.Applications -join ',')|$($back.Tasks.Count)|$($back.OrganizationalUnit)" 'corp.example.com|R&D <Labs>|Zoom,Teams|3|OU=Labs,DC=corp,DC=example,DC=com' 'export then read gives the same answer file'

    # BitLocker.
    Assert-Equal "$($default.BitLocker.Enabled)" 'False' 'sample has BitLocker off'
    $sec = $d.PSObject.Copy()
    $sec.BitLocker = $default.BitLocker.PSObject.Copy()
    $sec.BitLocker.Enabled = $true; $sec.BitLocker.Protector = 'TpmPin'; $sec.BitLocker.PinFile = $null; $sec.BitLocker.RecoveryKeyFolder = 'keys'
    Assert-Equal @(Test-AnswerFile $sec).Count 2 'validation catches PIN file and key folder'
    $ws = $default.PSObject.Copy(); $ws.BitLocker = $default.BitLocker.PSObject.Copy(); $ws.BitLocker.Enabled = $true
    Assert-Equal (@(Test-AnswerFile $ws) -join '|') 'bitlocker/backupToAD needs domain membership; use recoveryKeyFolder for workgroup PCs.' 'AD key backup needs a domain'
    $ws.BitLocker.BackupToAD = $false
    Assert-Equal (@(Test-AnswerFile $ws) -join '|') 'bitlocker/requireBackup needs backupToAD or recoveryKeyFolder.' 'required backup needs somewhere to go'

    $sec.BitLocker.PinFile = 'config\secrets\pin.txt'; $sec.BitLocker.RecoveryKeyFolder = '\\srv\Keys$'
    Assert-Equal @(Test-AnswerFile $sec).Count 0 'valid BitLocker settings pass'
    $secPath = Join-Path $tmp 'Secure.xml'
    Export-AnswerFile -Answer $sec -Path $secPath
    $sb = Read-AnswerFile -Path $secPath
    Assert-Equal "$($sb.BitLocker.Enabled)|$($sb.BitLocker.Protector)|$($sb.BitLocker.PinFile)|$($sb.BitLocker.RecoveryKeyFolder)|$($sb.BitLocker.EncryptionMethod)" 'True|TpmPin|config\secrets\pin.txt|\\srv\Keys$|XtsAes256' 'BitLocker settings survive export and read'
    $bp = New-FirstBootPlan -Answer $sb -BitLockerPin '123456'
    Assert-Equal "$($bp.bitlocker.protector)|$($bp.bitlocker.pin)|$($bp.bitlocker.backupToAD)" 'TpmPin|123456|True' 'first boot plan carries BitLocker with the PIN'
    $sb.BitLocker.Protector = 'Tpm'
    Assert-Equal "[$((New-FirstBootPlan -Answer $sb -BitLockerPin '123456').bitlocker.pin)]" '[]' 'no PIN in the plan for TPM only'
    Assert-Equal ($null -eq (New-FirstBootPlan -Answer $default).bitlocker) $true 'no BitLocker in the plan when it is off'
    [xml]$old = '<deployment><mode>Interactive</mode><image><file>a.wim</file></image></deployment>'
    $oldPath = Join-Path $tmp 'Old.xml'; $old.Save($oldPath)
    $o = Read-AnswerFile -Path $oldPath
    Assert-Equal "$($o.BitLocker.Enabled)" 'False' 'answer files without the bitlocker section still read, with it off'

    # SmartDeploy import.
    $conv = ConvertFrom-SmartDeployAnswerFile -Path (Join-Path $PSScriptRoot 'fixtures/smartdeploy-sample.xml')
    $c = $conv.Answer
    Assert-Equal "$($c.Mode)|$($c.UnattendDelay)|$($c.ImageFile)" 'Unattended|3|Images\W11_Office_FR_EN.wim' 'SmartDeploy mode, delay and image are converted'
    Assert-Equal ($c.Applications -join ',') 'Dell-Command-Update,Zoom-Latest' 'application packs keep their installation order'
    Assert-Equal "$($c.InputLocale)|$($c.TimeZone)" 'fr-CA|Eastern Standard Time' 'regional settings are converted to locale tags'
    Assert-Equal "$($c.Membership)|$($c.Domain)|$($c.JoinUser)|$($c.JoinDomain)" 'Domain|example.local|imaging|EXAMPLE' 'domain join is converted'
    Assert-Equal "$($c.NamingMode)|$($c.WmiQuery)" 'WMI|SELECT SerialNumber FROM Win32_SystemEnclosure' 'WMI naming is converted'
    Assert-Equal (($c.Tasks | ForEach-Object { "$($_.Phase)=$($_.Command)" }) -join ';') 'POSTIMAGE=cscript.exe %OSDRIVE%\temp\UpdateInputLocale.vbs;FIRSTLOGON=powershell -file C:\temp\Bitlocker.ps1;FIRSTBOOT=powershell -file C:\temp\Cleanup.ps1' 'tasks keep their phase; POSTIMAGE T: becomes %OSDRIVE%'
    Assert-Equal (($c.Shares | ForEach-Object LocalName) -join ',') 'V:,Y:' 'share on Z: is moved to a free letter'
    Assert-Equal "$($c.DisableSystemRestore)|$($c.EnableAdministrator)|$($c.Reboot)" 'True|False|True' 'system properties and completion are converted'
    Assert-Equal (@($conv.Notes | Where-Object { $_ -like '*PRESERVE_DESKTOP_ICONS*' }).Count) 1 'unsupported settings are listed in the notes'

    $out = Join-Path $tmp 'Imported.xml'
    Export-AnswerFile -Answer $c -Path $out
    Assert-Equal ((Get-Content -Raw $out) -match 'DEADBEEF') $false 'no SmartDeploy password reaches the new answer file'
    Assert-Equal (@(Test-AnswerFile (Read-AnswerFile -Path $out -SkipValidation)).Count) 0 'imported answer file is valid'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
