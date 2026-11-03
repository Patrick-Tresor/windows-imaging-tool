# Plain-PowerShell tests for answer files: parsing, validation, naming, unattend generation and the
# deploy wizard answer file import. Run: pwsh -File tests/AnswerFile.Tests.ps1

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
    $bad.Shares = @(); $bad.Tasks = @(); $bad.JoinPasswordFile = 'x'; $bad.DiskOption = 'KeepUserData'
    Assert-Equal (@(Test-AnswerFile $bad) -join '') "disk/option 'KeepUserData' is not supported yet; only Recreate (wipe the disk and recreate partitions)." 'unsupported disk option is rejected'

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
    # Names Windows Setup rejects in the specialize pass are never built.
    $n.NamingMode = 'WMI'; $n.Prefix = ''
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue '1.25.0') 'PC-1250' 'an all-digit name gets a PC- prefix'
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue '-AB12-') 'AB12' 'leading and trailing dashes are dropped'
    $n.Prefix = 'ABCDEFGHIJKLMN'
    Assert-Equal (Resolve-ComputerName -Answer $n -WmiValue '-X') 'ABCDEFGHIJKLMN' 'a name cut at 15 characters does not end with a dash'
    foreach ($bad in '', '1234567', 'PC_01', 'ABCDEFGHIJKLMNOP', '-PC', 'PC-') {
        Assert-Equal ([bool](Test-UnattendComputerName $bad)) $true "computer name '$bad' is rejected"
    }
    Assert-Equal "$(Test-UnattendComputerName 'GWHZLG3')" '' 'a Dell service tag is a valid computer name'

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
    # The generated unattend is checked the way Windows Setup reads it, before the disk is erased. A Dell stopped at
    # Getting ready with "could not parse or process the unattend answer file for pass [specialize]" for component
    # Microsoft-Windows-Shell-Setup: a value there that Setup rejects.
    $full = $d.PSObject.Copy()
    $full.EnableAdministrator = $true; $full.AdminPasswordFile = 'config\secrets\admin.txt'
    $full.ProductKey = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'; $full.FullName = 'IT & Co'
    $good = New-UnattendXml -Answer $full -ComputerName 'GWHZLG3' -JoinPassword 'p&ss<1>' -AdminPassword 'a"b' -LogonCommands @('a.cmd')
    Assert-Equal (@(Test-UnattendXml -Xml $good) -join ' | ') '' 'every generated setting is in a pass and component that takes it'
    [xml]$gx = $good
    $specialShell = $gx.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Shell-Setup']", $ns)
    Assert-Equal (($specialShell.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object LocalName) -join ',') 'ComputerName,TimeZone,RegisteredOwner,RegisteredOrganization,ProductKey' 'specialize Shell-Setup holds only the name, time zone, owner and key'
    Assert-Equal $gx.SelectNodes("//u:settings[@pass='specialize']//u:OOBE | //u:settings[@pass='specialize']//u:UserAccounts | //u:settings[@pass='specialize']//u:FirstLogonCommands", $ns).Count 0 'no oobeSystem setting is in specialize'
    Assert-Equal (@(Test-UnattendXml -Xml (New-UnattendXml -Answer $default -ComputerName 'PC-02')) -join ' | ') '' 'the workgroup unattend checks out too'
    # Passwords are now kept encrypted in the answer file and decrypted in WinPE: the decrypted text goes in as it is.
    Import-Module (Join-Path $repo 'src/SecretVault.psm1') -Force
    $key = New-AnswerKey
    $plain = Unprotect-AnswerPassword -Value (Protect-AnswerPassword -Password 'J&in<Pa$$>' -Key $key) -Key $key
    [xml]$ex = New-UnattendXml -Answer $d -ComputerName 'PC-04' -JoinPassword $plain
    Assert-Equal "$($ex.SelectSingleNode('//u:Credentials/u:Password', $ns).InnerText)|$(@(Test-UnattendXml -Xml $ex.OuterXml).Count)" 'J&in<Pa$$>|0' 'a decrypted answer file password gives a valid unattend'

    $broken = $good -replace '<RegisteredOwner>', '<CopyProfile>true</CopyProfile><RegisteredOwner>'
    Assert-Equal @(@(Test-UnattendXml -Xml $broken) -like '*CopyProfile*').Count 1 'a setting the generator does not write in specialize is caught'
    $broken = $good -replace '(?s)(<settings pass="oobeSystem">.*?)(<component name="Microsoft-Windows-Shell-Setup")', '$1<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>X</ComputerName></component>$2'
    Assert-Equal @(@(Test-UnattendXml -Xml $broken) -like '*twice*').Count 1 'a component twice in one pass is caught'
    $broken = $good -replace 'NPPR9-FWDCX-D2C8J-H872K-2YT43', 'NPPR9FWDCX'
    Assert-Equal @(@(Test-UnattendXml -Xml $broken) -like "*productKey 'NPPR9FWDCX'*").Count 1 'a malformed product key is caught'
    $broken = $good -replace '<ComputerName>GWHZLG3</ComputerName>', '<ComputerName>1234567</ComputerName>'
    Assert-Equal @(@(Test-UnattendXml -Xml $broken) -like '*only digits*').Count 1 'an all-digit computer name is caught'
    Assert-Equal @(@(Test-UnattendXml -Xml ($good -replace '</unattend>', '')) -like '*not valid XML*').Count 1 'unattend XML that does not parse is caught'
    Assert-Throws { New-UnattendXml -Answer $default -ComputerName 'NAME_WITH_UNDERSCORE' } '*letters, digits and dashes*' 'no unattend is built with a bad computer name'

    # The answer file catches a bad product key or time zone, so the console and WinPE stop before the erase.
    $v = $default.PSObject.Copy(); $v.ProductKey = 'ABCDE-12345'
    Assert-Equal @(@(Test-AnswerFile $v) -like '*five groups of five*').Count 1 'a malformed product key is an answer file problem'
    $v.ProductKey = 'nppr9-fwdcx-d2c8j-h872k-2yt43'
    Assert-Equal @(Test-AnswerFile $v).Count 0 'a lower-case product key is fine'
    if ($env:OS -eq 'Windows_NT') {
        $v.TimeZone = '(UTC-05:00) Eastern Time (US & Canada)'
        Assert-Equal @(@(Test-AnswerFile $v) -like '*not a Windows time zone ID*').Count 1 'a time zone display name is an answer file problem'
        $v.TimeZone = 'America/Toronto'
        Assert-Equal @(@(Test-AnswerFile $v) -like '*not a Windows time zone ID*').Count 1 'an IANA time zone is an answer file problem'
        $v.TimeZone = 'Eastern Standard Time'
        Assert-Equal @(Test-AnswerFile $v).Count 0 'a Windows time zone ID is fine'
    }

    $deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
    $checkAt = $deploy.IndexOf('Test-UnattendXml -Xml $unattendXml')
    Assert-Equal ($checkAt -gt 0 -and $checkAt -lt $deploy.IndexOf("Invoke-Native -FilePath 'diskpart.exe'")) $true 'Deploy-Image checks the unattend before the disk is partitioned'

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

    # Deploy wizard answer file import.
    $conv = ConvertFrom-DeployWizardAnswerFile -Path (Join-Path $PSScriptRoot 'fixtures/deploy-wizard-sample.xml')
    $c = $conv.Answer
    Assert-Equal "$($c.Mode)|$($c.UnattendDelay)|$($c.ImageFile)" 'Unattended|3|Images\W11_Office_FR_EN.wim' 'deploy wizard mode, delay and image are converted'
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
    Assert-Equal ((Get-Content -Raw $out) -match 'DEADBEEF') $false 'no source password reaches the new answer file'
    Assert-Equal (@(Test-AnswerFile (Read-AnswerFile -Path $out -SkipValidation)).Count) 0 'imported answer file is valid'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
