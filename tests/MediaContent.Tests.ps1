# Plain-PowerShell tests for what a USB stick gets copied: the answer files and the images they name.
# Run: pwsh -File tests/MediaContent.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaContent.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Set-AnswerImage([string]$Path, [string]$File, [string]$Version) {
    [xml]$x = Get-Content -Raw $Path
    $x.deployment.image.file = $File
    $x.deployment.image.version = $Version
    $x.Save($Path)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-media-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    $answers = Join-Path $root 'AnswerFiles'
    $images = Join-Path $root 'Images'

    # The sample answer file names Images\Win11-Enterprise.wim, which isn't captured yet: the build must stop.
    $c = Get-MediaContent -ContentRoot $root
    Assert-Equal $c.Problems.Count 1 'missing image is a problem'
    Assert-Equal ($c.Problems[0] -like '*Default uses image Images\Win11-Enterprise.wim, which is not in*') $true 'problem names the answer file and image'

    # With the image there: the answer file, its image and the folders it uses, but not an image nobody uses.
    Set-Content (Join-Path $images 'Win11-Enterprise.wim') 'wim'
    Set-Content (Join-Path $images 'Win11-Enterprise.updates.json') '{}'
    Set-Content (Join-Path $images 'Unused.wim') 'other'
    $c = Get-MediaContent -ContentRoot $root
    Assert-Equal $c.Problems.Count 0 'no problems once the image exists'
    Assert-Equal ($c.Files -join ';') 'AnswerFiles\Default.xml;Images\Win11-Enterprise.wim;Images\Win11-Enterprise.updates.json' 'answer file, its image and history are copied'
    Assert-Equal ($c.Folders -join ';') 'config;Tools;Drivers;Applications' 'config, tools, drivers and applications are copied'
    Assert-Equal ($c.AnswerFiles[0].Image) 'Images\Win11-Enterprise.wim' 'answer file row shows its image'

    # Two answer files: only the checked one and its image go on the stick.
    Copy-Item (Join-Path $answers 'Default.xml') (Join-Path $answers 'Lab.xml')
    Set-AnswerImage (Join-Path $answers 'Lab.xml') 'Images\Lab.swm' ''
    Set-Content (Join-Path $images 'Lab.swm') 'p1'
    Set-Content (Join-Path $images 'Lab2.swm') 'p2'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Lab'
    Assert-Equal ($c.Files -join ';') 'AnswerFiles\Lab.xml;Images\Lab.swm;Images\Lab2.swm' 'split image: every part, and only the checked answer file'
    $c = Get-MediaContent -ContentRoot $root
    Assert-Equal ($c.AnswerFiles.Name -join ',') 'Default,Lab' 'no names given: every answer file'

    # A default answer file left off the stick is a note, not a problem.
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Lab' -DefaultAnswerFile 'Default'
    Assert-Equal $c.Problems.Count 0 'default left off: not a problem'
    Assert-Equal ($c.Notes -join '' -like '*default answer file Default is not on this stick*') $true 'default left off: note'

    # A pinned version copies its folder in Images\Previous, not the current image.
    $prev = Join-Path $images 'Previous/Win11-Enterprise_20261022-1530'
    New-Item -ItemType Directory -Path $prev -Force | Out-Null
    Set-Content (Join-Path $prev 'Win11-Enterprise.wim') 'old'
    Set-AnswerImage (Join-Path $answers 'Default.xml') 'Images\Win11-Enterprise.wim' '20261022-1530'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal ($c.Files -join ';') 'AnswerFiles\Default.xml' 'pinned: current image not copied'
    Assert-Equal ($c.Folders -contains 'Images\Previous\Win11-Enterprise_20261022-1530') $true 'pinned: version folder copied'
    Set-AnswerImage (Join-Path $answers 'Default.xml') 'Images\Win11-Enterprise.wim' '20250101-0000'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal $c.Problems.Count 1 'pinned to a missing version: problem'

    # An image on a network path is read at deploy time, not copied.
    Set-AnswerImage (Join-Path $answers 'Default.xml') '\\server\images\Win11.wim' ''
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal $c.Problems.Count 0 'network image: not a problem'
    Assert-Equal ($c.Files -join ';') 'AnswerFiles\Default.xml' 'network image: not copied'

    # Unknown answer file, none checked, none at all.
    Assert-Equal ((Get-MediaContent -ContentRoot $root -AnswerFiles 'Nope').Problems[0]) "Answer file Nope is not in $root\AnswerFiles." 'unknown answer file'
    $choices = @(Get-MediaAnswerChoices -ContentRoot $root)
    Assert-Equal ($choices.Name -join ',') 'Default,Lab' 'Media tab lists every answer file'
    Assert-Equal ($choices[1].Label -like 'Lab  ->  Images\Lab.swm*') $true 'Media tab shows the image each one deploys'
    Remove-Item (Join-Path $answers '*.xml')
    Assert-Equal ((Get-MediaContent -ContentRoot $root).Problems[0] -like 'There are no answer files*') $true 'no answer files at all'
}
finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All media content checks passed' -ForegroundColor Green
