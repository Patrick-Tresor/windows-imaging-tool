# Plain-PowerShell tests for copying a USB stick's content with progress (src/MediaCopy.psm1).
# Run: pwsh -File tests/MediaCopy.Tests.ps1. Works on Windows and Linux; exits non-zero when a check fails.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/MediaCopy.psm1') -Force

$failures = 0
function Assert-Equal($Actual, $Expected, $Name) {
    if ("$Actual" -ceq "$Expected") { Write-Host "PASS $Name" -ForegroundColor Green }
    else { Write-Host "FAIL $Name`n  expected: $Expected`n  actual:   $Actual" -ForegroundColor Red; $script:failures++ }
}
function New-TestFile([string]$Path, [int]$Bytes) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $data = New-Object byte[] $Bytes
    for ($i = 0; $i -lt $Bytes; $i++) { $data[$i] = [byte]($i % 251) }
    [IO.File]::WriteAllBytes($Path, $data)
}
function Join-T([string]$Root, [string]$Rel) { Join-Path $Root ($Rel -replace '\\', [IO.Path]::DirectorySeparatorChar) }

Assert-Equal (Format-MediaSize 500) '500 bytes' 'size: bytes'
Assert-Equal (Format-MediaSize 1536) ('{0:N1} KB' -f 1.5) 'size: KB'
Assert-Equal (Format-MediaSize 700MB) ('{0:N0} MB' -f 700) 'size: MB'
Assert-Equal (Format-MediaSize ([int64](5.5 * 1GB))) ('{0:N2} GB' -f 5.5) 'size: GB'
Assert-Equal (Format-MediaDuration 42) '42s' 'duration: seconds'
Assert-Equal (Format-MediaDuration 192) '3m 12s' 'duration: minutes'
Assert-Equal (Format-MediaDuration 3900) '1h 05m' 'duration: hours'

$base = Join-Path ([IO.Path]::GetTempPath()) ("imaging-copy-" + [guid]::NewGuid())
$src = Join-Path $base 'content'
$dst = Join-Path $base 'stick'
try {
    New-TestFile (Join-T $src 'Images\Win11-Staff.wim') 300000
    New-TestFile (Join-T $src 'Images\Unused.wim') 10
    New-TestFile (Join-T $src 'AnswerFiles\Staff.xml') 100
    New-TestFile (Join-T $src 'Drivers\Dell\Latitude 5521\a.inf') 2000
    New-TestFile (Join-T $src 'config\deploy-settings.json') 50
    New-Item -ItemType Directory -Path (Join-T $src 'Drivers\Empty') -Force | Out-Null
    New-Item -ItemType Directory -Path $dst -Force | Out-Null

    $plan = Get-MediaCopyPlan -ContentRoot $src -Folders 'config', 'Drivers', 'Gone' -Files 'AnswerFiles\Staff.xml', 'Images\Win11-Staff.wim'
    Assert-Equal (@($plan.Items | ForEach-Object Relative) -join ';') 'config\deploy-settings.json;Drivers\Dell\Latitude 5521\a.inf;AnswerFiles\Staff.xml;Images\Win11-Staff.wim' 'plan: every file in the folders, then the files'
    Assert-Equal $plan.TotalBytes (50 + 2000 + 100 + 300000) 'plan: total size'
    Assert-Equal $plan.FileCount 4 'plan: file count'
    Assert-Equal ($plan.Missing -join ';') 'Gone' 'plan: missing folder reported'
    Assert-Equal ($plan.Directories -contains 'Drivers\Empty') $true 'plan: empty folders are created too'

    # Both copy methods: Stream everywhere, Native (CopyFileEx, the default on Windows) where it exists.
    $methods = @('Stream')
    if (Test-NativeCopy) { $methods += 'Native' }
    Assert-Equal ($methods -contains 'Native') ([IO.Path]::DirectorySeparatorChar -eq '\') 'native copy is used on Windows'
    foreach ($method in $methods) {
        # Small chunks so the image is copied in many steps, and every update is recorded.
        $updates = New-Object System.Collections.ArrayList
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        New-Item -ItemType Directory -Path $dst | Out-Null
        # LineEvery10PercentFrom 1000 makes the image count as a big file: it reports at its start and end.
        $result = Copy-MediaContent -Plan $plan -Destination $dst -Method $method -BufferSize 65536 -FlushEvery 100000 -LineEvery10PercentFrom 1000 -Quiet -OnProgress { param($s) [void]$updates.Add($s) }
        Assert-Equal $result.FileCount 4 "$method copy: files copied"
        Assert-Equal $result.Bytes $plan.TotalBytes "$method copy: bytes copied"
        foreach ($rel in 'config\deploy-settings.json', 'Drivers\Dell\Latitude 5521\a.inf', 'AnswerFiles\Staff.xml', 'Images\Win11-Staff.wim') {
            $a = [IO.File]::ReadAllBytes((Join-T $src $rel)); $b = [IO.File]::ReadAllBytes((Join-T $dst $rel))
            Assert-Equal ([Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b)) $true "$method copy: $rel is identical"
        }
        Assert-Equal (Test-Path (Join-T $dst 'Images\Unused.wim')) $false "$method copy: unused image left off"
        Assert-Equal (Test-Path (Join-T $dst 'Drivers\Empty')) $true "$method copy: empty folder created"
        Assert-Equal ([IO.File]::GetLastWriteTimeUtc((Join-T $dst 'Images\Win11-Staff.wim')) -eq [IO.File]::GetLastWriteTimeUtc((Join-T $src 'Images\Win11-Staff.wim'))) $true "$method copy: timestamp kept"

        $wim = @($updates | Where-Object { $_.File -eq 'Images\Win11-Staff.wim' })
        Assert-Equal ($wim.Count -ge 2) $true "$method progress: the image reports at its start and end"
        Assert-Equal $wim[0].FilePercent 0 "$method progress: image starts at 0%"
        Assert-Equal $wim[-1].FilePercent 100 "$method progress: image ends at 100%"
        Assert-Equal $wim[-1].FileIndex 4 "$method progress: file number"
        Assert-Equal $wim[-1].FileCount 4 "$method progress: file count"
        Assert-Equal $updates[-1].Percent 100 "$method progress: overall ends at 100%"
        Assert-Equal $updates[-1].BytesDone $plan.TotalBytes "$method progress: overall bytes"
        $rising = $true
        for ($i = 1; $i -lt $updates.Count; $i++) { if ($updates[$i].BytesDone -lt $updates[$i - 1].BytesDone) { $rising = $false } }
        Assert-Equal $rising $true "$method progress: never goes backwards"
    }

    # Write-through made each chunk wait for the stick and halved the copy speed.
    Assert-Equal ((Get-Content -Raw (Join-Path $repo 'src/MediaCopy.psm1')) -match 'FileOptions\]::WriteThrough') $false 'copy: no write-through (slow on USB sticks)'

    # Text lines every 10% for big files, so the console shows the copy moving even without a progress bar.
    Remove-Item $dst -Recurse -Force; New-Item -ItemType Directory -Path $dst | Out-Null
    $one = Get-MediaCopyPlan -ContentRoot $src -Files 'Images\Win11-Staff.wim'
    $lines = & { Copy-MediaContent -Plan $one -Destination $dst -Method Stream -BufferSize 16384 -LineEvery10PercentFrom 1000 | Out-Null } 6>&1 | ForEach-Object { "$_" }
    Assert-Equal ($lines[0] -like 'Copying Images\Win11-Staff.wim (*KB)...') $true 'text: names the file and its size'
    Assert-Equal (@($lines | Where-Object { $_ -match '^\s+\d+%' }).Count -ge 5) $true 'text: percent lines while a big file copies'
    Assert-Equal (@($lines | Where-Object { $_ -like '*done in*' }).Count) 1 'text: done line for the big file'

    # Small files get no line of their own: thousands of driver files would mean thousands of slow console writes.
    Remove-Item $dst -Recurse -Force; New-Item -ItemType Directory -Path $dst | Out-Null
    $small = Get-MediaCopyPlan -ContentRoot $src -Folders 'Drivers', 'config'
    $lines = & { Copy-MediaContent -Plan $small -Destination $dst | Out-Null } 6>&1 | ForEach-Object { "$_" }
    Assert-Equal @($lines | Where-Object { $_ -like 'Copying*' }).Count 0 'text: no line per small file'
    Assert-Equal (Test-Path (Join-T $dst 'Drivers\Dell\Latitude 5521\a.inf')) $true 'text: small files still copied'

    # A source that can't be read gives a plain message naming the file.
    $bad = [pscustomobject]@{ Items = @([pscustomobject]@{ Relative = 'Images\Gone.wim'; Source = (Join-T $src 'Images\Gone.wim'); Length = 5 }); Directories = @(); TotalBytes = 5 }
    $msg = ''
    foreach ($method in $methods) {
        $msg = ''
        try { Copy-MediaContent -Plan $bad -Destination $dst -Method $method -Quiet | Out-Null } catch { $msg = $_.Exception.Message }
        Assert-Equal ($msg -like 'Copying Images\Gone.wim to the USB stick failed:*') $true "$method error names the file"
    }
}
finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All media copy checks passed' -ForegroundColor Green
