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

    # A configuration with its own SourcePath (a file server) is left alone.
    $x = [xml](Get-Content -Raw (Join-Path $folder 'configuration.xml'))
    $x.Configuration.Add.SetAttribute('SourcePath', '\\server\office')
    $x.Save((Join-Path $folder 'configuration.xml'))
    $script:runs = @()
    $r = Update-OfficeSource -Definition $def -AppFolder $folder -Runner $runner -Log { param($m) }
    Assert-Equal "$($r.Status)|$($script:runs.Count)" 'OwnSource|0' 'a configuration with its own SourcePath is not downloaded'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests 'All tests passed'
