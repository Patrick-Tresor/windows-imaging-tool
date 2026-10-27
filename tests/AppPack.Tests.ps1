# Plain-PowerShell tests for application packs: app.json, installer inspection, templates, export/import,
# requirements and detection. Run: pwsh -File tests/AppPack.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/AppPack.psm1') -Force

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

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("apppack-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # Old app.json files keep working; new fields get defaults.
    $old = ConvertTo-AppDefinition -Name 'Zoom' -Json ('{ "command": "msiexec /i zoom.msi /qn", "successCodes": [0] }' | ConvertFrom-Json)
    Assert-Equal "$($old.command)|$($old.successCodes -join ',')|$($old.rebootCodes -join ',')|$($old.timeoutMinutes)|$($old.detection.rules.Count)|$($old.skipIfDetected)" 'msiexec /i zoom.msi /qn|0|3010,1641|60|0|True' 'old app.json gets defaults'
    $short = ConvertTo-AppDefinition -Name 'X' -Json ('{ "command": "x", "detection": [ { "type": "MSI", "productCode": "{11111111-2222-3333-4444-555555555555}" } ] }' | ConvertFrom-Json)
    Assert-Equal "$($short.detection.match)|$($short.detection.rules[0].type)|$($short.detection.rules[0].target)|$($short.detection.rules[0].operator)" 'all|msi|{11111111-2222-3333-4444-555555555555}|exists' 'detection can be a plain list of rules'
    Assert-Throws { ConvertTo-DetectionRule ([pscustomobject]@{ type = 'wmi'; target = 'x' }) } '*Unknown detection rule type*' 'unknown rule types are refused'
    $r = ConvertTo-DetectionRule ([pscustomobject]@{ type = 'file'; path = '%ProgramFiles%\VLC\vlc.exe'; version = '3.0' })
    Assert-Equal "$($r.target)|$($r.operator)" '%ProgramFiles%\VLC\vlc.exe|>=' 'a version without operator means at least'

    # Validation.
    $bad = ConvertTo-AppDefinition -Name 'Bad name' -Json ([pscustomobject]@{ command = 'x.exe --server REPLACE_SERVER'; timeoutMinutes = 0
        detection = @{ rules = @(@{ type = 'msi'; target = 'not-a-guid' }) } })
    $issues = @(Test-AppPack -Definition $bad)
    Assert-Equal $issues.Count 4 'name, placeholder, timeout and product code problems are found'
    Assert-Equal (@(Test-AppPack -Definition $old) -join '|') 'Warning: no detection rule, so the result cannot be checked and the app is reinstalled on every run.' 'no detection is only a warning'

    # Version comparison.
    Assert-Equal (Compare-AppVersion '6.2.0.1234' '>=' '6.2') $true '6.2.0.1234 >= 6.2'
    Assert-Equal (Compare-AppVersion '3.0.9' '>=' '3.0.20') $false '3.0.9 < 3.0.20 compares numerically'
    Assert-Equal (Compare-AppVersion '6.2' '=' '6.2.0.0') $true 'missing version parts count as 0'
    Assert-Equal (Compare-AppVersion '' '>=' '1.0') $false 'no version found fails a version check'
    Assert-Equal (Compare-AppVersion '' 'exists' '') $true 'exists needs no version'

    # Installer framework detection from markers in the .exe.
    $mk = { param($name, [string]$marker, [switch]$Unicode)
        $p = Join-Path $tmp $name
        $enc = if ($Unicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
        [IO.File]::WriteAllBytes($p, [byte[]](@(0x4D, 0x5A) + [byte[]]::new(200) + $enc.GetBytes($marker) + [byte[]]::new(50)))
        $p }
    Assert-Equal (Find-InstallerFramework (& $mk 'vlc-3.0.21-win64.exe' 'Nullsoft.NSIS.exehead')) 'nsis' 'NSIS installer is recognized'
    Assert-Equal (Find-InstallerFramework (& $mk 'inno.exe' 'Inno Setup Setup Data' -Unicode)) 'inno' 'Inno Setup (UTF-16 marker) is recognized'
    Assert-Equal (Find-InstallerFramework (& $mk 'burn.exe' '.wixburn')) 'burn' 'WiX Burn bundle is recognized'
    Assert-Equal (Find-InstallerFramework (& $mk 'plain.exe' 'hello')) 'exe' 'unknown installer falls back to exe'
    Assert-Equal (Get-SilentInstallCommand -Installer 'setup.exe' -Type 'inno') '"setup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' 'Inno Setup silent switches'
    Assert-Equal (Get-SilentInstallCommand -Installer 'ZoomInstallerFull.msi' -Type 'msi') 'msiexec /i "ZoomInstallerFull.msi" /qn /norestart /l*v "%WINDIR%\Temp\ZoomInstallerFull-install.log"' 'MSI silent command logs to Temp'
    $info = Get-InstallerInfo (Join-Path $tmp 'vlc-3.0.21-win64.exe')
    Assert-Equal "$($info.Type)|$($info.Command)|$($info.Detection.type)" 'nsis|"vlc-3.0.21-win64.exe" /S|uninstall' 'exe inspection suggests the command and a detection rule'

    # MSIX identity from the manifest inside the package.
    $msixDir = Join-Path $tmp 'msix'; New-Item -ItemType Directory $msixDir | Out-Null
    '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="MSTeams" Version="24.1.0.0" Publisher="CN=Microsoft Corporation, O=Microsoft Corporation"/></Package>' |
        Set-Content (Join-Path $msixDir 'AppxManifest.xml')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $msix = Join-Path $tmp 'MSTeams-x64.msix'
    [IO.Compression.ZipFile]::CreateFromDirectory($msixDir, $msix)
    $mi = Get-InstallerInfo $msix
    Assert-Equal "$($mi.Type)|$($mi.PackageName)|$($mi.Version)|$($mi.Publisher)|$($mi.Detection.type) $($mi.Detection.target)" 'msix|MSTeams|24.1.0.0|Microsoft Corporation|appx MSTeams' 'MSIX identity is read from AppxManifest.xml'

    # Templates for the applications in the SmartDeploy answer file.
    $templates = Get-AppTemplates
    Assert-Equal ((Find-AppTemplate -Installer 'system_update_5.08.03.59.exe' -Templates $templates).name) 'Lenovo-System-Update' 'template found by installer file name'
    Assert-Equal ((Find-AppTemplate -Name 'Dell-Command-Update' -Templates $templates).name) 'Dell-Command-Update' 'template found by SmartDeploy pack name'
    Assert-Equal ((Find-AppTemplate -Name 'Zoom-Latest' -Templates $templates).name) 'Zoom' 'template found by alias'
    Assert-Equal (Find-AppTemplate -Installer 'unknown.exe' -Templates $templates) $null 'no template for unknown installers'
    $vlc = New-AppDefinitionFromTemplate -Template (Find-AppTemplate -Installer 'vlc-3.0.21-win64.exe' -Templates $templates) -Installer 'vlc-3.0.21-win64.exe'
    Assert-Equal "$($vlc.name)|$($vlc.command)|$($vlc.installer)|$($vlc.detection.rules[0].type)" 'VLC|"vlc-3.0.21-win64.exe" /L=1036 /S|vlc-3.0.21-win64.exe|file'.Replace('1036', '1033') 'template fills in the installer name'
    foreach ($t in $templates) {
        $d = New-AppDefinitionFromTemplate -Template $t -Installer 'setup.exe'
        $errs = @(Test-AppPack -Definition $d | Where-Object { $_ -notlike 'Warning:*' -and $_ -notlike '*no install command*' -and $_ -notlike '*placeholder*' })
        Assert-Equal ($errs -join '; ') '' "template $($t.name) is valid"
    }

    # Requirements: maker and model wildcards.
    $dcu = New-AppDefinitionFromTemplate -Template (Find-AppTemplate -Name 'Dell-Command-Update' -Templates $templates) -Installer 'dcu.exe'
    Assert-Equal (Test-AppRequirement -Definition $dcu -Identity ([pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5440' })) $true 'Dell app is for Dell PCs'
    Assert-Equal (Test-AppRequirement -Definition $dcu -Identity ([pscustomobject]@{ Maker = 'Lenovo'; Model = 'ThinkPad T14' })) $false 'Dell app is skipped on a Lenovo'
    $dcu.requirements.models = @('OptiPlex*')
    Assert-Equal (Test-AppRequirement -Definition $dcu -Identity ([pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5440' })) $false 'model wildcard limits further'
    Assert-Equal (Test-AppRequirement -Definition $vlc -Identity ([pscustomobject]@{ Maker = 'HP'; Model = 'x' })) $true 'no requirement means every PC'

    # Detection against a given list of Programs and Features entries, and the file system.
    $entries = @([pscustomobject]@{ KeyName = '{11111111-2222-3333-4444-555555555555}'; DisplayName = 'Zoom Workplace (64-bit)'; DisplayVersion = '6.2.5.1234' })
    $z = ConvertTo-AppDefinition -Name 'Zoom' -Json ([pscustomobject]@{ command = 'x'; detection = @{ match = 'all'; rules = @(
        @{ type = 'uninstall'; target = 'Zoom Workplace*'; version = '6.0' }, @{ type = 'msi'; target = '{11111111-2222-3333-4444-555555555555}' }) } })
    Assert-Equal (Test-AppDetection -Definition $z -UninstallEntries $entries).Detected $true 'uninstall name and product code are found'
    $z.detection.rules[0].version = '7.0'
    Assert-Equal (Test-AppDetection -Definition $z -UninstallEntries $entries).Detected $false 'all rules must match: version too old'
    $z.detection.match = 'any'
    Assert-Equal (Test-AppDetection -Definition $z -UninstallEntries $entries).Detected $true 'any rule is enough with match any'
    $marker = Join-Path $tmp 'installed.txt'; Set-Content $marker 'x'
    $f = ConvertTo-AppDefinition -Name 'F' -Json ([pscustomobject]@{ command = 'x'; detection = @(@{ type = 'file'; target = $marker }) })
    Assert-Equal (Test-AppDetection -Definition $f -UninstallEntries @()).Detected $true 'file rule finds an existing file'
    $f.detection.rules[0].target = Join-Path $tmp 'missing.txt'
    Assert-Equal (Test-AppDetection -Definition $f -UninstallEntries @()).Detected $false 'file rule reports a missing file'
    Assert-Equal (Test-AppDetection -Definition $old -UninstallEntries @()).HasRules $false 'no rules is reported as such'

    # Save, list, export, import and remove through the console data layer.
    $root = Join-Path $tmp 'root'
    Initialize-ContentRoot -Path $root
    $vlcSrc = Join-Path $tmp 'vlc-3.0.21-win64.exe'
    New-Application -ContentRoot $root -Name 'VLC' -Source $vlcSrc -Definition $vlc | Out-Null
    $json = Get-Content -Raw (Join-Path $root 'Applications/VLC/app.json') | ConvertFrom-Json
    Assert-Equal "$($json.installer)|$($json.detection.rules[0].type)|$($json.PSObject.Properties['name'])" 'vlc-3.0.21-win64.exe|file|' 'app.json keeps the full definition without the name'
    $back = Read-AppPack -AppRoot (Join-Path $root 'Applications') -Name 'VLC'
    Assert-Equal "$($back.command)|$($back.detection.rules[0].target)" "$($vlc.command)|$($vlc.detection.rules[0].target)" 'saved pack reads back the same'
    Assert-Throws { New-Application -ContentRoot $root -Name 'VLC' -Source $vlcSrc -Definition $vlc } '*already exists*' 'an existing application is not overwritten'
    $noFile = ConvertTo-AppDefinition -Name 'Ghost' -Json ([pscustomobject]@{ command = 'x'; installer = 'ghost.exe' })
    Assert-Throws { Save-AppPack -AppRoot (Join-Path $root 'Applications') -Definition $noFile } '*not in the application folder*' 'a missing installer file is refused'

    $back.version = '3.0.21'
    Save-Application -ContentRoot $root -Definition $back | Out-Null
    $list = @(Get-ApplicationList -ContentRoot $root)
    Assert-Equal "$($list.Name)|$($list.Version)|$($list.Type)|$($list.Status)|$($list.For)" 'VLC|3.0.21|nsis|Ready|All PCs' 'application list shows version, type and status'

    $zip = Join-Path $tmp 'VLC.zip'
    Export-AppPack -AppRoot (Join-Path $root 'Applications') -Name 'VLC' -Path $zip | Out-Null
    Import-AppPack -AppRoot (Join-Path $root 'Applications') -Path $zip -Name 'VLC-copy' | Out-Null
    Assert-Equal "$(Test-Path (Join-Path $root 'Applications/VLC-copy/vlc-3.0.21-win64.exe'))|$((Read-AppPack -AppRoot (Join-Path $root 'Applications') -Name 'VLC-copy').version)" 'True|3.0.21' 'exported pack imports under a new name'
    Assert-Throws { Import-AppPack -AppRoot (Join-Path $root 'Applications') -Path $zip -Name 'VLC' } '*already exists*' 'import does not overwrite without -Overwrite'
    $notPack = Join-Path $tmp 'notpack.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($msixDir, $notPack)
    Assert-Throws { Import-AppPack -AppRoot (Join-Path $root 'Applications') -Path $notPack } '*not an application pack*' 'a zip without app.json is refused'

    $a = Get-NewAnswer -Name 'Lab'
    $a.Applications = @('VLC')
    Save-AnswerFromEditor -ContentRoot $root -Answer $a -IsNew | Out-Null
    Assert-Equal ((Get-ApplicationList -ContentRoot $root | Where-Object Name -eq 'VLC').UsedBy) 'Lab' 'list shows which answer files use an app'
    Assert-Throws { Remove-Application -ContentRoot $root -Name 'VLC' } '*still in these answer files*' 'an app in use cannot be removed'
    Remove-Application -ContentRoot $root -Name 'VLC-copy'
    Assert-Equal (Test-Path (Join-Path $root 'Applications/VLC-copy')) $false 'unused app is removed'

    # Answer file issues include broken packs.
    '{ "command": "x --server REPLACE_SERVER" }' | Set-Content (Join-Path $root 'Applications/VLC/app.json')
    $issues = @(Get-AnswerFileIssues -ContentRoot $root -Answer (Read-AnswerFile -Path (Join-Path $root 'AnswerFiles/Lab.xml') -SkipValidation))
    Assert-Equal (@($issues | Where-Object { $_ -like 'Application VLC:*placeholder*' }).Count) 1 'answer file issues report a placeholder in an app command'

    # First boot plan keeps the detection rules through JSON.
    $plan = [pscustomobject]@{ applications = @($vlc) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $again = ConvertTo-AppDefinition -Name $plan.applications[0].name -Json $plan.applications[0]
    Assert-Equal "$($again.detection.rules[0].type)|$($again.detection.rules[0].target)|$($again.timeoutMinutes)" "file|$($vlc.detection.rules[0].target)|15" 'definition survives the first boot plan JSON'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures test(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All tests passed' -ForegroundColor Green
