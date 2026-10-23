# Plain-PowerShell tests for image versions and rollback. Run: pwsh -File tests/ImageVersions.Tests.ps1
# Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/ImageVersions.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function Assert-Throws([scriptblock]$Action, $Name) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-Equal $threw $true $Name
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("imaging-versions-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    $images = Join-Path $root 'Images'
    $wim = Join-Path $images 'Win11.wim'
    Set-Content $wim 'v1'
    Set-Content (Join-Path $images 'Win11.updates.json') '{"history":[{"date":"v1"}]}'

    # Keep a copy: the current image stays, a version appears with its history and note.
    $v1 = Save-ImageVersion -ImagePath $wim -Note 'Known good' -Date ([datetime]'2026-10-01 09:00')
    Assert-Equal $v1.Version '20261001-0900' 'version is named after its time stamp'
    Assert-Equal (Get-Content $wim) 'v1' 'keeping a copy leaves the current image in place'
    Assert-Equal (Test-Path (Join-Path $v1.Folder 'Win11.updates.json')) $true 'the update history travels with the version'
    Assert-Equal $v1.Note 'Known good' 'the note is stored'
    $again = Save-ImageVersion -ImagePath $wim -Date ([datetime]'2026-10-01 09:00')
    Assert-Equal $again.Version '20261001-0900-2' 'a second copy in the same minute gets a suffix'
    Remove-ImageVersion -ImagePath $wim -Version $again.Version

    # Recapture-style replacement: move the current image out, put a new one in.
    $v2 = Save-ImageVersion -ImagePath $wim -Move -Reason 'Replaced by a new capture' -Date ([datetime]'2026-10-15 14:30')
    Assert-Equal (Test-Path $wim) $false 'moving empties the current slot'
    Assert-Equal (Test-Path (Join-Path $images 'Win11.updates.json')) $true 'moving keeps the update history with the image slot'
    Assert-Equal (Test-Path (Join-Path $v2.Folder 'Win11.updates.json')) $true 'the version gets a copy of the update history'
    Set-Content $wim 'v3'

    # A backup from before version.json existed (no version.json) is listed too.
    $legacy = Join-Path $images 'Previous/Win11_20261020-0800'
    New-Item -ItemType Directory -Path $legacy -Force | Out-Null
    Set-Content (Join-Path $legacy 'Win11.wim') 'v2b'
    # A folder for another image whose name starts the same way is not.
    New-Item -ItemType Directory -Path (Join-Path $images 'Previous/Win11_Lab_20261020-0800') -Force | Out-Null
    Set-Content (Join-Path $images 'Previous/Win11_Lab_20261020-0800/Win11_Lab.wim') 'lab'

    $list = @(Get-ImageVersions -ImagePath $wim)
    Assert-Equal ($list.Version -join ',') '20261020-0800,20261015-1430,20261001-0900' 'versions are listed newest first'
    Assert-Equal ($list | Where-Object Version -eq '20261020-0800').Reason 'Kept by an offline update' 'offline update backups are listed'
    Assert-Equal (Get-ImageVersionPath -ImagePath $wim -Version '20261001-0900') (Join-Path $v1.Folder 'Win11.wim') 'a version resolves to its archived file'
    Assert-Equal (Get-ImageVersionPath -ImagePath $wim -Version '') $wim 'no version resolves to the current image'
    Assert-Throws { Get-ImageVersionPath -ImagePath $wim -Version '20250101-0000' } 'a missing version throws'
    Assert-Throws { Get-ImageVersionPath -ImagePath $wim -Version '..\x' } 'a malformed version throws'

    Set-ImageVersionNote -ImagePath $wim -Version '20261015-1430' -Note 'Driver issue on G10'
    Assert-Equal (Get-ImageVersions -ImagePath $wim | Where-Object Version -eq '20261015-1430').Note 'Driver issue on G10' 'notes can be changed'

    # Rollback: current is archived, the chosen version is copied back and stays archived.
    $old = Restore-ImageVersion -ImagePath $wim -Version '20261001-0900' -Date ([datetime]'2026-10-22 16:00')
    Assert-Equal (Get-Content $wim) 'v1' 'rollback makes the chosen version current'
    Assert-Equal (Get-Content (Join-Path $old.Folder 'Win11.wim')) 'v3' 'the image rolled away from is kept'
    Assert-Equal $old.Reason 'Replaced by a rollback to 20261001-0900' 'the kept image says why'
    Assert-Equal (Test-Path (Join-Path $v1.Folder 'Win11.wim')) $true 'the restored version stays archived for pinned answer files'
    Assert-Equal ((Get-Content -Raw (Join-Path $images 'Win11.updates.json')).Trim()) '{"history":[{"date":"v1"}]}' 'rollback restores the matching update history'
    Set-Content (Join-Path $v1.Folder 'Win11.wim') 'v1'
    Assert-Equal (Get-Content (Join-Path $v1.Folder 'Win11.wim')) 'v1' 'the chosen version is still archived after a rollback'

    # Split images move all their parts.
    Set-Content (Join-Path $images 'Big.swm') 'a'; Set-Content (Join-Path $images 'Big2.swm') 'b'
    $big = Save-ImageVersion -ImagePath (Join-Path $images 'Big.swm') -Move
    Assert-Equal ((Get-ChildItem $big.Folder -Filter *.swm).Name -join ',') 'Big.swm,Big2.swm' 'every part of a split image is archived'

    # Answer files: version pinned in XML, round trip, validation, console issues.
    $answerPath = Get-AnswerFilePath -ContentRoot $root -Name 'Default'
    $a = Read-AnswerFile -Path $answerPath -SkipValidation
    Assert-Equal "$($a.ImageVersion)" '' 'the sample answer file uses the current image'
    $a.ImageFile = 'Images\Win11.wim'
    $a.ImageVersion = '20261015-1430'
    Export-AnswerFile -Answer $a -Path $answerPath
    $b = Read-AnswerFile -Path $answerPath -SkipValidation
    Assert-Equal $b.ImageVersion '20261015-1430' 'the version survives a save'
    Assert-Equal (@(Get-AnswerFileIssues -ContentRoot $root -Answer $b).Count) 0 'a pinned version that exists is not a problem'
    $b.ImageVersion = '20250101-0000'
    Assert-Equal (@(Get-AnswerFileIssues -ContentRoot $root -Answer $b) -join '') 'Version 20250101-0000 of Images\Win11.wim is no longer in Images\Previous.' 'a pinned version that is gone is reported'
    $b.ImageVersion = 'latest'
    Assert-Equal (@(Test-AnswerFile $b).Count) 1 'a version that is not a time stamp is invalid'

    $lab = Get-NewAnswer -Name 'Lab'
    $lab.ImageFile = 'Images\Win11.wim'
    Export-AnswerFile -Answer $lab -Path (Get-AnswerFilePath -ContentRoot $root -Name 'Lab')

    Assert-Equal ((Get-ImageUsage -ContentRoot $root)['Win11.wim'] -join ', ') 'Default (version 20261015-1430), Lab' 'image usage shows pinned versions'
    Assert-Equal ((Get-AnswerFileRows -ContentRoot $root | Where-Object Name -eq 'Default').Image) 'Images\Win11.wim (version 20261015-1430)' 'answer file list shows the version'

    $rows = @(Get-ImageVersionRows -ContentRoot $root -ImageName 'Win11.wim')
    Assert-Equal ($rows.Label -join ',') 'Current,20261022-1600,20261020-0800,20261015-1430,20261001-0900' 'version rows start with the current image'
    Assert-Equal $rows[0].UsedBy 'Lab' 'the current row lists answer files without a version'
    Assert-Equal ($rows | Where-Object Version -eq '20261015-1430').UsedBy 'Default' 'a version row lists answer files pinned to it'
    Assert-Equal ((Get-ImageList -ContentRoot $root | Where-Object Name -eq 'Win11.wim').Versions) 4 'the image list counts earlier versions'

    # Deleting and pruning never touch a pinned version.
    Assert-Throws { Remove-ImageVersions -ContentRoot $root -ImageName 'Win11.wim' -Version '20261015-1430' } 'a pinned version cannot be deleted'
    $prune = @(Get-ImageVersionsToDelete -ContentRoot $root -ImageName 'Win11.wim' -Keep 1)
    Assert-Equal ($prune.Version -join ',') '20261020-0800,20261001-0900' 'pruning keeps the newest and the pinned versions'
    Remove-ImageVersions -ContentRoot $root -ImageName 'Win11.wim' -Version @($prune.Version)
    Assert-Equal ((Get-ImageVersions -ImagePath $wim).Version -join ',') '20261022-1600,20261015-1430' 'pruned versions are gone'

    # Retention: versions beyond versionsToKeep go, pinned ones stay.
    $settingsPath = Join-Path $root 'config/deploy-settings.json'
    $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json
    $settings | Add-Member -NotePropertyName versionsToKeep -NotePropertyValue 0
    $settings | ConvertTo-Json | Set-Content $settingsPath
    Assert-Equal (@(Invoke-ImageVersionRetention -ContentRoot $root -ImagePath $wim)).Count 0 'retention 0 keeps every version'
    $settings.versionsToKeep = 1
    $settings | ConvertTo-Json | Set-Content $settingsPath
    Save-ImageVersion -ImagePath $wim -Date ([datetime]'2026-10-23 17:00') | Out-Null
    $gone = @(Invoke-ImageVersionRetention -ContentRoot $root -ImagePath $wim)
    Assert-Equal ($gone.Version -join ',') '20261022-1600' 'retention deletes the unpinned version beyond the newest one'
    Assert-Equal ((Get-ImageVersions -ImagePath $wim).Version -join ',') '20261023-1700,20261015-1430' 'retention keeps the newest and the pinned version'

    # A version protected by a rollback survives retention even when it is the oldest unpinned one.
    $ten = Save-ImageVersion -ImagePath $wim -Date ([datetime]'2026-10-20 10:00')
    Assert-Equal (@(Invoke-ImageVersionRetention -ContentRoot $root -ImagePath $wim -Keep 1 -Protect $ten.Version)).Count 0 'a protected version is not deleted by retention'
    Assert-Equal ((Get-ImageVersions -ImagePath $wim).Version -join ',') "20261023-1700,$($ten.Version),20261015-1430" 'the protected version is still listed'
    Remove-ImageVersion -ImagePath $wim -Version $ten.Version

    # Per-image limit overrides the default, and clearing it goes back to the default.
    Set-ImageVersionLimit -ImagePath $wim -Keep 5
    Assert-Equal (Get-VersionsToKeep -ContentRoot $root -ImagePath $wim) 5 'a per-image limit overrides the default'
    Set-ImageVersionLimit -ImagePath $wim -Keep $null
    Assert-Equal (Get-VersionsToKeep -ContentRoot $root -ImagePath $wim) 1 'clearing the per-image limit restores the default'
    Assert-Equal ((Get-ImageList -ContentRoot $root | Where-Object Name -eq 'Win11.wim').Name) 'Win11.wim' 'limit files do not show up as images'
    Assert-Equal (Test-ImageHardLinks -Path $images) $true 'the hard link check runs on the images folder'

    # Command lines the console starts.
    $cmd = Get-ImageVersionArguments -ScriptPath 'C:\Tool\src\Invoke-ImageVersion.ps1' -ContentRoot $root -ImageName 'Win11.wim' -Action Rollback -Version '20261015-1430'
    Assert-Equal ($cmd -contains '-Version' -and $cmd -contains '20261015-1430' -and $cmd -contains 'Rollback') $true 'rollback command names the version'
    Assert-Throws { Get-ImageVersionArguments -ScriptPath 'x' -ContentRoot $root -ImageName 'Win11.wim' -Action Rollback } 'rollback needs a version'

    # Capture config: an existing name is allowed only as a new version.
    Assert-Throws { New-CaptureConfig -ContentRoot $root -Name 'Win11' } 'capturing over an existing image needs -NewVersion'
    $cfg = Get-Content -Raw (New-CaptureConfig -ContentRoot $root -Name 'Win11' -NewVersion) | ConvertFrom-Json
    Assert-Equal $cfg.newVersion $true 'capture config asks for a new version'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All image version tests passed' -ForegroundColor Green
