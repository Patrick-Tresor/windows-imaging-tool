# Plain-PowerShell tests for the Office offline source (Update-OfficeSource in AppPack.psm1): setup.exe /download
# into the Microsoft 365 Apps pack folder, so each PC installs Office from its own copy. Run: pwsh -File tests/OfficeSource.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AppPack.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("officesource-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $templates = Get-AppTemplates -Path (Join-Path $repo 'config/app-templates.json')
    $t = Find-AppTemplate -Name 'Microsoft-365-Apps' -Templates $templates
    $def = New-AppDefinitionFromTemplate -Template $t -Online
    $appRoot = Join-Path $tmp 'Applications'
    $folder = Join-Path $appRoot $def.name
    Save-AppPack -AppRoot $appRoot -Definition $def | Out-Null
    Copy-Item (Join-Path $repo 'config/office-configuration.xml') (Join-Path $folder 'configuration.xml')
    $other = Join-Path $appRoot 'Zoom'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    '{ "command": "msiexec /i zoom.msi /qn" }' | Set-Content (Join-Path $other 'app.json')

    # The sample configuration installs from the files next to setup.exe: no SourcePath, internet as a fallback.
    [xml]$odt = Get-Content -Raw (Join-Path $repo 'config/office-configuration.xml')
    Assert-Equal "$($odt.Configuration.Add.GetAttribute('SourcePath'))|$($odt.Configuration.Add.AllowCdnFallback)" '|TRUE' 'sample Office configuration has no SourcePath and falls back to the internet'

    Assert-Equal (Get-OfficeConfigPath -Definition $def -AppFolder $folder) (Join-Path $folder 'configuration.xml') 'an Office Deployment Tool pack is found by its /configure command'
    $zoom = ConvertTo-AppDefinition -Name 'Zoom' -Json ('{ "command": "msiexec /i zoom.msi /qn" }' | ConvertFrom-Json)
    Assert-Equal (Get-OfficeConfigPath -Definition $zoom -AppFolder $other) '' 'another application is not Office'

    # A fake setup.exe /download: makes Office\Data\<version> like the real one, and records the configuration it got.
    $script:runs = @()
    $script:fakeVersion = '16.0.17928.20156'
    $runner = {
        param($exe, $arguments, $dir)
        $cfg = [regex]::Match($arguments, '"([^"]+)"').Groups[1].Value
        [xml]$x = Get-Content -Raw $cfg
        $script:runs += [pscustomobject]@{ Exe = $exe; Args = $arguments; Source = $x.Configuration.Add.GetAttribute('SourcePath') }
        $data = Join-Path $x.Configuration.Add.GetAttribute('SourcePath') "Office\Data\$script:fakeVersion"
        New-Item -ItemType Directory -Path $data -Force | Out-Null
        Set-Content (Join-Path $data 'stream.x64.x-none.dat') 'x'
        Set-Content (Join-Path (Split-Path $data -Parent) "v64_$script:fakeVersion.cab") 'x'
        Set-Content (Join-Path (Split-Path $data -Parent) 'v64.cab') 'x'
        [pscustomobject]@{ TimedOut = $false; ExitCode = 0; LastLine = '' }
    }
    $script:dls = 0
    $downloader = { param($Url, $Path) $script:dls++; Set-Content -Path $Path -Value 'odt' }

    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Downloader $downloader -Log { param($m) }
    Assert-Equal "$($r.Status)|$($r.Version)" "Downloaded|$script:fakeVersion" 'the Office files are downloaded into the pack folder'
    Assert-Equal "$($script:runs.Count)|$($script:runs[0].Source)|$($script:runs[0].Args -like '/download *')" "1|$folder|True" 'setup.exe /download gets a configuration pointing at the pack folder'
    Assert-Equal $script:dls 1 'setup.exe (Office Deployment Tool) is downloaded when missing'
    [xml]$kept = Get-Content -Raw (Join-Path $folder 'configuration.xml')
    Assert-Equal $kept.Configuration.Add.GetAttribute('SourcePath') '' 'the pack''s own configuration.xml keeps no SourcePath (the PC reads the files next to setup.exe)'
    Assert-Equal (@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'office-download-*.xml').Count) 0 'the temporary download configuration is deleted'

    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Downloader $downloader -Log { param($m) }
    Assert-Equal "$($r.Status)|$($script:runs.Count)" 'Fresh|1' 'fresh Office files are not downloaded again'

    # A changed configuration (another language) downloads again; older versions are removed.
    (Get-Content -Raw (Join-Path $folder 'configuration.xml')).Replace('<Language ID="en-us" />', '<Language ID="en-us" /><Language ID="es-es" />') | Set-Content (Join-Path $folder 'configuration.xml')
    $script:fakeVersion = '16.0.18000.20000'
    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Downloader $downloader -Log { param($m) }
    [string[]]$names = @(Get-ChildItem -LiteralPath (Join-Path $folder 'Office\Data') | ForEach-Object Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    Assert-Equal "$($r.Status)|$($names -join ',')" 'Downloaded|16.0.18000.20000,v64.cab,v64_16.0.18000.20000.cab' 'a changed configuration downloads again and only the newest version is kept'

    # Old files (past MaxAgeDays) are refreshed.
    $m = Get-Content -Raw (Join-Path $folder 'office-source.json') | ConvertFrom-Json
    $m.downloaded = (Get-Date).AddDays(-20).ToString('o')
    $m | ConvertTo-Json | Set-Content (Join-Path $folder 'office-source.json')
    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Downloader $downloader -Log { param($m) }
    Assert-Equal $r.Status 'Downloaded' 'Office files older than 14 days are downloaded again'

    # A failed download throws for one pack; Update-OfficeSources only reports it.
    $bad = { param($exe, $arguments, $dir) [pscustomobject]@{ TimedOut = $false; ExitCode = 17002; LastLine = 'no network' } }
    Remove-Item (Join-Path $folder 'office-source.json')
    Assert-Throws { Update-OfficeSource -Definition $def -AppFolder $folder -Runner $bad -Log { param($m) } } '*exit code 17002*' 'a failed setup.exe /download throws with its exit code'
    $rows = @(Update-OfficeSources -AppRoot $appRoot -Runner $bad -Downloader $downloader -Log { param($m) })
    Assert-Equal "$($rows.Count)|$($rows[0].Name)|$($rows[0].Status)" '1|Microsoft-365-Apps|Failed' 'Update-OfficeSources: only Office packs, a failure is reported, not thrown'
    $rows = @(Update-OfficeSources -AppRoot $appRoot -Names 'Zoom' -Runner $runner -Log { param($m) })
    Assert-Equal $rows.Count 0 'Update-OfficeSources: -Names limits the packs'

    # A SourcePath on a drive of the console PC (C:\imager\...) means nothing on the PCs: the files are downloaded all the same.
    $x = [xml](Get-Content -Raw (Join-Path $folder 'configuration.xml'))
    $x.Configuration.Add.SetAttribute('SourcePath', 'C:\imager\Office')
    $x.Save((Join-Path $folder 'configuration.xml'))
    $script:runs = @()
    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Log { param($m) }
    Assert-Equal "$($r.Status)|$($script:runs.Count)" 'Downloaded|1' 'a SourcePath on a console PC drive is not a reason to skip the download'

    # A command written with the console PC's path (Patrick's Microsoft-Office pack, 2026-11-23) finds the pack's own copy.
    $console = ConvertTo-AppDefinition -Name 'Microsoft-Office' -Json ([pscustomobject]@{ installer = 'setup.exe'; command = '"setup.exe" /configure C:\imager\Applications\Microsoft-Office\Configuration.xml' })
    Assert-Equal (Test-OfficeDeploymentCommand -Definition $console) $true 'the /configure command is an Office Deployment Tool pack'
    Assert-Equal (Get-OfficeConfigPath -Definition $console -AppFolder $folder) (Join-Path $folder 'configuration.xml') 'a console PC path in the command finds configuration.xml in the pack folder (any case)'

    # On the PC: configuration-deploy.xml is silent, installs from the folder's Office files, and the command uses it.
    $x = [xml](Get-Content -Raw (Join-Path $folder 'configuration.xml'))
    $x.Configuration.Display.SetAttribute('Level', 'Full')
    $lg = $x.CreateElement('Logging'); $lg.SetAttribute('Path', 'Q:\NoSuchFolder\OfficeLogs'); [void]$x.Configuration.AppendChild($lg)
    $x.Configuration.Add.SetAttribute('DownloadPath', 'Q:\NoSuchFolder')
    $x.Save((Join-Path $folder 'configuration.xml'))
    $odtRun = New-OfficeDeployConfig -Definition $console -AppFolder $folder
    [xml]$dep = Get-Content -Raw (Join-Path $folder 'configuration-deploy.xml')
    Assert-Equal $odtRun.Command '"setup.exe" /configure "configuration-deploy.xml"' 'the PC runs setup.exe with configuration-deploy.xml'
    Assert-Equal "$($dep.Configuration.Display.Level)|$($dep.Configuration.Display.AcceptEULA)|$($dep.Configuration.Add.SourcePath)|$($dep.Configuration.Add.AllowCdnFallback)" "None|TRUE|$folder|TRUE" 'configuration-deploy.xml: silent, from the folder''s Office files, internet as a fallback'
    Assert-Equal (@($odtRun.Notes)[0] -like 'Office 16.0.* files from this folder') $true 'the log says Office installs from the folder'
    Assert-Equal "$($dep.Configuration.Logging.Path)|$($dep.Configuration.Logging.Level)|$($dep.Configuration.Add.HasAttribute('DownloadPath'))" "$([IO.Path]::Combine($env:WINDIR, 'Temp'))|Standard|False" 'configuration-deploy.xml: Office logs to Windows\Temp, a console PC log or download folder is dropped (setup.exe exit 1, directory name invalid)'
    Assert-Equal @(@($odtRun.Notes) -like 'Logging Path Q:*').Count 1 'the log says the console PC log folder was replaced'

    # No Office files in the folder and a SourcePath the PC can't reach: from the internet, still silent.
    $bare = Join-Path $appRoot 'Bare-Office'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    Copy-Item (Join-Path $folder 'configuration.xml') (Join-Path $bare 'configuration.xml')
    $odtRun = New-OfficeDeployConfig -Definition $console -AppFolder $bare
    [xml]$dep = Get-Content -Raw (Join-Path $bare 'configuration-deploy.xml')
    Assert-Equal "$($dep.Configuration.Display.Level)|$($dep.Configuration.Add.GetAttribute('SourcePath'))|$($dep.Configuration.Add.AllowCdnFallback)" 'None||TRUE' 'no Office files: the unreachable SourcePath is dropped, Office comes from the internet'

    # No configuration file at all: a clear error at once, not an Office Deployment Tool window nobody sees.
    $none = Join-Path $appRoot 'No-Config'
    New-Item -ItemType Directory -Path $none -Force | Out-Null
    Assert-Throws { New-OfficeDeployConfig -Definition $console -AppFolder $none } '*is not in the application''s folder*' 'a missing configuration file fails at once'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests 'All tests passed'
