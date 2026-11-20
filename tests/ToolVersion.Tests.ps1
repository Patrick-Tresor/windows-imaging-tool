# Tests for the tool version (src/ToolVersion.psm1): reading it from version.txt and from a stick, and the console's
# "this stick is older" message.
# Run: powershell -File tests/ToolVersion.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/ToolVersion.psm1') -Force
Import-Module (Join-Path $repo 'src/JsonFile.psm1') -Force

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('ToolVersion-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    # version.txt as GitHub's zip download fills it in.
    $v = ConvertTo-ToolVersion '853ca2f 2026-11-20T22:10:00+00:00'
    Assert-Equal $v.Commit '853ca2f' 'commit read from version.txt'
    Assert-Equal $v.Date.ToString('yyyy-MM-dd HH:mm') '2026-11-20 22:10' 'date read as UTC'
    Assert-Equal ($v.Text -like '853ca2f (2026-11-2*)') $true 'text has the commit and the date'
    Assert-Equal (ConvertTo-ToolVersion '$Format:%h %cI$') $null 'the unfilled placeholder is not a version'
    Assert-Equal (ConvertTo-ToolVersion '') $null 'empty is not a version'

    # The repo's own version.txt keeps the placeholder that GitHub fills in, and .gitattributes asks for it.
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $repo 'src/version.txt')).Trim()) '$Format:%h %cI$' 'version.txt holds the git placeholder'
    Assert-Equal ([bool](Select-String -LiteralPath (Join-Path $repo '.gitattributes') -Pattern '^src/version\.txt export-subst' -Quiet)) $true '.gitattributes fills version.txt in downloads'

    # A downloaded copy (no git): version.txt wins.
    $dl = Join-Path $tmp 'dl'
    New-Item -ItemType Directory -Path $dl | Out-Null
    [IO.File]::WriteAllText((Join-Path $dl 'version.txt'), "abcdef1 2026-11-01T10:00:00Z`n")
    Assert-Equal (Get-ToolVersion -SourceRoot $dl).Commit 'abcdef1' 'downloaded copy: version from version.txt'

    # Inside WinPE: the build's tool-version.json wins over everything.
    New-Item -ItemType Directory -Path (Join-Path $dl 'config') | Out-Null
    $baked = ConvertTo-ToolVersionRecord -Version (ConvertTo-ToolVersion '1234567 2026-11-10T08:00:00Z') -Target Usb -Built ([datetime]'2026-11-10 09:30')
    Save-JsonFile -Path (Join-Path $dl 'config/tool-version.json') -InputObject $baked
    $pe = Get-ToolVersion -SourceRoot $dl
    Assert-Equal $pe.Commit '1234567' 'WinPE: version from the baked tool-version.json'
    Assert-Equal $pe.Built '2026-11-10 09:30' 'WinPE: build time kept'

    # A copy with neither: "dev".
    $bare = Join-Path $tmp 'bare'
    New-Item -ItemType Directory -Path $bare | Out-Null
    Set-Content -LiteralPath (Join-Path $bare 'a.ps1') -Value '#'
    $dev = Get-ToolVersion -SourceRoot $bare
    Assert-Equal ($dev.Commit -in 'dev') $true 'no version.txt and no git: dev'

    # Comparing a stick with the console.
    $console = ConvertTo-ToolVersion '2222222 2026-11-20T10:00:00Z'
    $older = ConvertTo-ToolVersion '1111111 2026-11-11T10:00:00Z'
    $newer = ConvertTo-ToolVersion '3333333 2026-11-25T10:00:00Z'
    Assert-Equal (Compare-ToolVersion -Console $console -Stick $console) 'Same' 'same commit: Same'
    Assert-Equal (Compare-ToolVersion -Console $console -Stick $older) 'Older' 'older commit: Older'
    Assert-Equal (Compare-ToolVersion -Console $console -Stick $newer) 'Newer' 'newer commit: Newer'
    Assert-Equal (Compare-ToolVersion -Console $console -Stick $null) 'Older' 'stick without a version file: Older'
    Assert-Equal (Compare-ToolVersion -Console (New-ToolVersion -Commit 'dev') -Stick $older) 'Unknown' 'dev console without a date: Unknown'

    # The banner text, from sticks' DEPLOY roots.
    $stickA = Join-Path $tmp 'stickA'; $stickB = Join-Path $tmp 'stickB'; $stickC = Join-Path $tmp 'stickC'
    New-Item -ItemType Directory -Path $stickA, $stickB, $stickC | Out-Null
    Save-JsonFile -Path (Join-Path $stickA 'tool-version.json') -InputObject (ConvertTo-ToolVersionRecord -Version $older -Target Usb -Built ([datetime]'2026-11-11 12:00'))
    Save-JsonFile -Path (Join-Path $stickB 'tool-version.json') -InputObject (ConvertTo-ToolVersionRecord -Version $console -Target Usb)
    Assert-Equal (Get-StaleStickMessage -Console $console -StickRoots @($stickB)) $null 'an up-to-date stick: no banner'
    $msg = Get-StaleStickMessage -Console $console -StickRoots @($stickA, $stickB)
    Assert-Equal ($msg -like "*$stickA*1111111*2026-11-11 12:00*2222222*Update a stick*") $true 'an old stick: banner names it, both versions and how to update'
    $msg = Get-StaleStickMessage -Console $console -StickRoots @($stickC)
    Assert-Equal ($msg -like '*built before this console stamped versions*') $true 'a stick from before versions: banner too'

    # The media build writes the version into boot.wim and onto the stick; WinPE logs it.
    $build = Get-Content -Raw (Join-Path $repo 'src/New-DeploymentMedia.ps1')
    Assert-Equal ($build -match 'config\\tool-version\.json') $true 'build puts tool-version.json into boot.wim'
    Assert-Equal ($build -match '\$\{dataLetter\}:\\tool-version\.json') $true 'build puts tool-version.json on the DEPLOY partition'
    $deploy = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
    Assert-Equal ($deploy -match 'Imaging tool version') $true 'Deploy.log starts with the version'
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Complete-Tests
