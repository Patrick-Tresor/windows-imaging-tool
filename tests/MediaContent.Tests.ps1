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
    Assert-Equal ($c.Folders -join ';') 'config;Tools;Drivers;Applications;Tasks' 'config, tools, drivers, applications and tasks are copied'
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

    # Driver packs: the Media tab lists the folders the catalog names, and only the checked ones are copied.
    Set-Content (Join-Path $root 'config/driver-catalog.json') @'
{
  "entries": [
    { "maker": "Dell", "sku": "0B0B", "path": "Dell\\Latitude 5440" },
    { "maker": "Dell", "model": "Latitude 5440", "path": "Dell\\Latitude 5440" },
    { "maker": "HP", "model": "EliteBook 840 G9", "path": "HP\\EliteBook 840 G9" },
    { "maker": "Lenovo", "machineType": "21HD", "path": "Lenovo\\T14, Gen 4" },
    { "maker": "Microsoft Corporation", "model": "Virtual Machine", "path": null }
  ],
  "fallbacks": { "Dell": "Dell\\_Generic" }
}
'@
    foreach ($d in 'Dell/Latitude 5440', 'HP/EliteBook 840 G9', 'Dell/_Generic', 'Unlisted/Model') {
        New-Item -ItemType Directory -Path (Join-Path $root "Drivers/$d") -Force | Out-Null
        Set-Content (Join-Path $root "Drivers/$d/net.inf") 'inf'
    }
    $packs = @(Get-MediaDriverPacks -ContentRoot $root)
    Assert-Equal ($packs.Path -join ';') 'Dell\Latitude 5440;HP\EliteBook 840 G9;Lenovo\T14, Gen 4;Dell\_Generic' 'driver packs: one row per catalog folder, not unlisted folders'
    Assert-Equal ($packs[0].Models -join ',') 'SKU 0B0B,Latitude 5440' 'driver packs: models that use the pack'
    Assert-Equal ($packs[0].Size -gt 0) $true 'driver packs: size measured'
    Assert-Equal $packs[2].Exists $false 'driver packs: missing folder flagged'
    Assert-Equal ($packs[2].Label -like '*folder missing*') $true 'driver packs: missing folder in label'
    Assert-Equal $packs[3].Fallback $true 'driver packs: maker fallback flagged'
    Assert-Equal ($packs[3].Label -like '*Dell fallback for unlisted models*') $true 'driver packs: fallback in label'
    $savedCatalog = Get-Content -Raw (Join-Path $root 'config/driver-catalog.json')
    Set-Content (Join-Path $root 'config/driver-catalog.json') '{ "entries": [], "fallbacks": { "HP": "HP\\_Generic", "Lenovo": "Lenovo\\_Generic" } }'
    New-Item -ItemType Directory -Path (Join-Path $root 'Drivers/HP/_Generic') -Force | Out-Null
    Set-Content (Join-Path $root 'Drivers/HP/_Generic/a.inf') 'inf'
    $fb = @(Get-MediaDriverPacks -ContentRoot $root)
    Assert-Equal ($fb.Path -join ';') 'HP\_Generic' 'fallback with a folder: listed'
    Assert-Equal (@($fb | Where-Object { $_.Label -like '*folder missing*' }).Count) 0 'fallback with no folder: not listed'
    Set-Content (Join-Path $root 'config/driver-catalog.json') $savedCatalog
    Remove-Item -Recurse -Force (Join-Path $root 'Drivers/HP/_Generic')

    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal ($c.Folders -contains 'Drivers') $true 'no pack choice: whole driver folder'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default' -DriverPacks 'Dell\Latitude 5440', 'Dell/_Generic', 'Lenovo\T14, Gen 4'
    Assert-Equal (@($c.Folders | Where-Object { $_ -like 'Drivers*' }) -join ';') 'Drivers\Dell\Latitude 5440;Drivers\Dell\_Generic' 'pack choice: only checked packs that exist'
    Assert-Equal ($c.Notes -join '' -like '*Driver packs on this stick: 2*') $true 'pack choice: note'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default' -DriverPacks @()
    Assert-Equal @($c.Folders | Where-Object { $_ -like 'Drivers*' }).Count 0 'no packs checked: no drivers copied'
    Assert-Equal ($c.Notes -join '' -like '*inbox drivers only*') $true 'no packs checked: note'
    Assert-Equal ($c.Folders -contains 'config') $true 'no packs checked: config still copied'
    # Drivers\_WinPE (drivers WinPE loads at start) always goes on the stick, whichever packs are checked.
    New-Item -ItemType Directory -Path (Join-Path $root 'Drivers/_WinPE/x64') -Force | Out-Null
    Set-Content (Join-Path $root 'Drivers/_WinPE/x64/iaStorVD.inf') 'inf'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default' -DriverPacks @()
    Assert-Equal (@($c.Folders | Where-Object { $_ -like 'Drivers*' }) -join ';') 'Drivers\_WinPE' 'no packs checked: WinPE drivers still copied'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal (@($c.Folders | Where-Object { $_ -like 'Drivers*' }) -join ';') 'Drivers' 'whole driver folder covers the WinPE drivers'
    Remove-Item (Join-Path $root 'Drivers/_WinPE') -Recurse -Force

    # Password files never go on the stick as plain text: config\secrets, and the share account's password file
    # when deploy-settings.json keeps it elsewhere (the old default, config\share.cred).
    Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force
    $set = Join-Path $root 'config/deploy-settings.json'
    $s = if (Test-Path $set) { Get-Content -Raw $set | ConvertFrom-Json } else { [pscustomobject]@{ share = [pscustomobject]@{ path = ''; user = ''; passwordFile = '' } } }
    $s.share.passwordFile = 'config\share.cred'
    $s | ConvertTo-Json -Depth 6 | Set-Content $set
    Set-Content (Join-Path $root 'config/share.cred') 'SharePw'
    $c = Get-MediaContent -ContentRoot $root -AnswerFiles 'Default'
    Assert-Equal ($c.Exclude -join ';') 'config\secrets;config\share.cred' 'share password file outside config\secrets is left off the stick'
    $plan = Get-MediaCopyPlan -ContentRoot $root -Folders $c.Folders -Files $c.Files -Exclude $c.Exclude
    Assert-Equal (@($plan.Items | Where-Object { $_.Relative -like '*share.cred' }).Count) 0 'the copy plan has no share.cred'
    Assert-Equal (@(Get-MediaContent -ContentRoot $root -AnswerFiles 'Default' -IncludeSecrets).Exclude.Count) 0 '-IncludeSecrets copies it'
    $s.share.passwordFile = 'config\secrets\share.txt'
    $s | ConvertTo-Json -Depth 6 | Set-Content $set
    Assert-Equal ((Get-MediaContent -ContentRoot $root -AnswerFiles 'Default').Exclude -join ';') 'config\secrets' 'share password file in config\secrets: one exclude'
    Remove-Item (Join-Path $root 'config/share.cred')

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
