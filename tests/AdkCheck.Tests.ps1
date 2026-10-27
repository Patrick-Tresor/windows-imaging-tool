# Plain-PowerShell tests for the Windows ADK check. Run: pwsh -File tests/AdkCheck.Tests.ps1
# Builds fake ADK folders, so it works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/AdkCheck.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}

function New-FakeFile([string]$Root, [string]$Relative) {
    $path = Join-Path $Root ($Relative -replace '\\', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
    Set-Content -Path $path -Value 'x'
}

$base = Join-Path ([IO.Path]::GetTempPath()) ("adk-test-" + [guid]::NewGuid())
$adk = Join-Path $base 'Assessment and Deployment Kit'
$same = [pscustomobject]@{ Adk = '10.1.26100.1'; WinPE = '10.1.26100.1' }
try {
    $s = Get-AdkStatus -AdkRoot $adk -Versions $same
    Assert-Equal $s.Ready $false 'nothing installed is not ready'
    Assert-Equal $s.Problems.Count 2 'missing ADK and WinPE add-on are both reported'
    Assert-Equal ($s.Problems[0] -like '*ADK is not installed*adk-install*') $true 'the ADK problem links the download page'
    Assert-Equal ($s.Problems[1] -like '*Windows PE add-on*separate download*') $true 'the WinPE problem says it is a separate download'

    # Deployment Tools only.
    foreach ($f in 'DandISetEnv.bat', 'amd64\Oscdimg\oscdimg.exe', 'amd64\Oscdimg\efisys_noprompt.bin') { New-FakeFile (Join-Path $adk 'Deployment Tools') $f }
    $s = Get-AdkStatus -AdkRoot $adk -Versions $same
    Assert-Equal $s.Problems.Count 1 'with Deployment Tools, only the WinPE add-on is missing'
    Assert-Equal ($s.Problems[0] -like '*Windows PE add-on*not installed*') $true 'the missing add-on is named'

    # WinPE add-on with one optional component missing.
    $pe = Join-Path $adk 'Windows Preinstallation Environment'
    foreach ($f in 'copype.cmd', 'MakeWinPEMedia.cmd', 'amd64\en-us\winpe.wim') { New-FakeFile $pe $f }
    foreach ($oc in Get-WinPEComponentNames | Where-Object { $_ -ne 'WinPE-PowerShell' }) { New-FakeFile $pe "amd64\WinPE_OCs\$oc.cab" }
    $s = Get-AdkStatus -AdkRoot $adk -Versions $same
    Assert-Equal $s.Ready $false 'a missing WinPE component is not ready'
    Assert-Equal ($s.Problems[0] -like '*missing files (amd64\WinPE_OCs\WinPE-PowerShell.cab)*') $true 'the missing component is named'

    New-FakeFile $pe 'amd64\WinPE_OCs\WinPE-PowerShell.cab'
    $s = Get-AdkStatus -AdkRoot $adk -Versions $same
    Assert-Equal $s.Ready $true 'a complete install is ready'
    Assert-Equal $s.Problems.Count 0 'a complete install has no problems'
    Assert-Equal $s.Summary "Windows ADK 10.1.26100.1 and the WinPE add-on are installed in $adk." 'the summary gives the version and folder'
    Assert-Equal $s.Warnings.Count 0 'matching versions give no warning'

    $s = Get-AdkStatus -AdkRoot $adk -Versions ([pscustomobject]@{ Adk = '10.1.26100.1'; WinPE = '10.1.22621.1' })
    Assert-Equal $s.Ready $true 'mismatched versions can still build'
    Assert-Equal ($s.Warnings[0] -like '*different versions*') $true 'mismatched versions are warned about'

    Remove-Item (Join-Path $adk 'Deployment Tools/amd64') -Recurse -Force
    $s = Get-AdkStatus -AdkRoot $adk -Versions $same
    Assert-Equal ($s.Problems[0] -like '*missing parts of Deployment Tools (amd64\Oscdimg\oscdimg.exe, amd64\Oscdimg\efisys_noprompt.bin)*') $true 'missing oscdimg is reported'

    # Off Windows there is no registry; the check still answers instead of throwing.
    $s = Get-AdkStatus
    Assert-Equal ($s.Ready -is [bool]) $true 'the default check runs without an ADK path'
}
finally {
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures) { Write-Host "$failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'All ADK check tests passed' -ForegroundColor Green
