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

    $plan = New-FirstBootPlan -Answer $d -AppDefinitions @()
    Assert-Equal ($plan.tasks -join ',') 'b.cmd' 'first boot plan holds the FIRSTBOOT tasks'

    # Applications.
    $apps = Join-Path $tmp 'Applications'
    New-Item -ItemType Directory -Path (Join-Path $apps 'Zoom') -Force | Out-Null
    '{ "command": "msiexec /i zoom.msi /qn" }' | Set-Content (Join-Path $apps 'Zoom/app.json')
    $def = Get-AppDefinition -AppRoot $apps -Name 'Zoom'
    Assert-Equal "$($def.command)|$($def.successCodes -join ',')" 'msiexec /i zoom.msi /qn|0,3010' 'app.json is read with default success codes'
    Assert-Throws { Get-AppDefinition -AppRoot $apps -Name 'Missing' } '*no app.json*' 'missing application is reported before the disk is wiped'

    # Round trip.
    $rt = Join-Path $tmp 'RoundTrip.xml'
    $d.JoinUser = 'svc'; $d.JoinPasswordFile = 'config\secrets\join.txt'; $d.Applications = @('Zoom', 'Teams')
    Export-AnswerFile -Answer $d -Path $rt
    $back = Read-AnswerFile -Path $rt
    Assert-Equal "$($back.Domain)|$($back.Organization)|$($back.Applications -join ',')|$($back.Tasks.Count)|$($back.OrganizationalUnit)" 'corp.example.com|R&D <Labs>|Zoom,Teams|3|OU=Labs,DC=corp,DC=example,DC=com' 'export then read gives the same answer file'

    # BitLocker and BIOS settings.
    Assert-Equal "$($default.BitLocker.Enabled)|$($default.Bios.Enabled)|$($default.Bios.Settings.Count)" 'False|False|6' 'sample has BitLocker and BIOS off, with example settings'
    $sec = $d.PSObject.Copy()
    $sec.BitLocker = $default.BitLocker.PSObject.Copy(); $sec.Bios = $default.Bios.PSObject.Copy()
    $sec.BitLocker.Enabled = $true; $sec.BitLocker.Protector = 'TpmPin'; $sec.BitLocker.PinFile = $null; $sec.BitLocker.RecoveryKeyFolder = 'keys'
    $sec.Bios.Enabled = $true
    $sec.Bios.Settings = @([pscustomobject]@{ Maker = 'Acer'; Name = 'X'; Value = 'Y' }, [pscustomobject]@{ Maker = 'Lenovo'; Name = 'Wake,OnLAN'; Value = 'ACOnly' })
    Assert-Equal @(Test-AnswerFile $sec).Count 4 'validation catches PIN file, key folder, unknown maker and Lenovo commas'
    $ws = $default.PSObject.Copy(); $ws.BitLocker = $default.BitLocker.PSObject.Copy(); $ws.BitLocker.Enabled = $true
    Assert-Equal (@(Test-AnswerFile $ws) -join '|') 'bitlocker/backupToAD needs domain membership; use recoveryKeyFolder for workgroup PCs.' 'AD key backup needs a domain'
    $ws.BitLocker.BackupToAD = $false
    Assert-Equal (@(Test-AnswerFile $ws) -join '|') 'bitlocker/requireBackup needs backupToAD or recoveryKeyFolder.' 'required backup needs somewhere to go'

    $sec.BitLocker.PinFile = 'config\secrets\pin.txt'; $sec.BitLocker.RecoveryKeyFolder = '\\srv\Keys$'
    $sec.Bios.PasswordFile = 'config\secrets\bios.txt'; $sec.Bios.StopOnError = $true
    $sec.Bios.Settings = @([pscustomobject]@{ Maker = 'HP'; Name = 'Virtualization Technology (VTx)'; Value = 'Enable' }, [pscustomobject]@{ Maker = 'Dell'; Name = 'SecureBoot'; Value = 'Enabled' })
    Assert-Equal @(Test-AnswerFile $sec).Count 0 'valid BitLocker and BIOS settings pass'
    $secPath = Join-Path $tmp 'Secure.xml'
    Export-AnswerFile -Answer $sec -Path $secPath
    $sb = Read-AnswerFile -Path $secPath
    Assert-Equal "$($sb.BitLocker.Enabled)|$($sb.BitLocker.Protector)|$($sb.BitLocker.PinFile)|$($sb.BitLocker.RecoveryKeyFolder)|$($sb.BitLocker.EncryptionMethod)" 'True|TpmPin|config\secrets\pin.txt|\\srv\Keys$|XtsAes256' 'BitLocker settings survive export and read'
    Assert-Equal "$($sb.Bios.Enabled)|$($sb.Bios.StopOnError)|$($sb.Bios.PasswordFile)|$(($sb.Bios.Settings | ForEach-Object { "$($_.Maker):$($_.Name)=$($_.Value)" }) -join ';')" 'True|True|config\secrets\bios.txt|HP:Virtualization Technology (VTx)=Enable;Dell:SecureBoot=Enabled' 'BIOS settings survive export and read'
    $bp = New-FirstBootPlan -Answer $sb -BitLockerPin '123456'
    Assert-Equal "$($bp.bitlocker.protector)|$($bp.bitlocker.pin)|$($bp.bitlocker.backupToAD)" 'TpmPin|123456|True' 'first boot plan carries BitLocker with the PIN'
    $sb.BitLocker.Protector = 'Tpm'
    Assert-Equal "[$((New-FirstBootPlan -Answer $sb -BitLockerPin '123456').bitlocker.pin)]" '[]' 'no PIN in the plan for TPM only'
    Assert-Equal ($null -eq (New-FirstBootPlan -Answer $default).bitlocker) $true 'no BitLocker in the plan when it is off'
    [xml]$old = '<deployment><mode>Interactive</mode><image><file>a.wim</file></image></deployment>'
    $oldPath = Join-Path $tmp 'Old.xml'; $old.Save($oldPath)
    $o = Read-AnswerFile -Path $oldPath
    Assert-Equal "$($o.BitLocker.Enabled)|$($o.Bios.Enabled)|$($o.Bios.Settings.Count)" 'False|False|0' 'answer files without the new sections still read, with both off'

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
