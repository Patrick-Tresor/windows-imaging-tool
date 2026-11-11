# Plain-PowerShell tests for copying a USB stick's content with progress (src/MediaCopy.psm1).
# Run: powershell -File tests\MediaCopy.Tests.ps1 (the copy compiles a small C# helper); exits non-zero when a check fails.

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

    Assert-Equal (Test-NativeCopy) $true 'copy helper compiles'
    $updates = New-Object System.Collections.ArrayList
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Path $dst | Out-Null
    # LineEvery10PercentFrom 1000 makes the image count as a big file: it reports at its start and end.
    $result = Copy-MediaContent -Plan $plan -Destination $dst -LineEvery10PercentFrom 1000 -Quiet -OnProgress { param($s) [void]$updates.Add($s) }
    Assert-Equal $result.FileCount 4 "copy: files copied"
    Assert-Equal $result.Bytes $plan.TotalBytes "copy: bytes copied"
    foreach ($rel in 'config\deploy-settings.json', 'Drivers\Dell\Latitude 5521\a.inf', 'AnswerFiles\Staff.xml', 'Images\Win11-Staff.wim') {
        $a = [IO.File]::ReadAllBytes((Join-T $src $rel)); $b = [IO.File]::ReadAllBytes((Join-T $dst $rel))
        Assert-Equal ([Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String($b)) $true "copy: $rel is identical"
    }
    Assert-Equal (Test-Path (Join-T $dst 'Images\Unused.wim')) $false "copy: unused image left off"
    Assert-Equal (Test-Path (Join-T $dst 'Drivers\Empty')) $true "copy: empty folder created"
    Assert-Equal ([IO.File]::GetLastWriteTimeUtc((Join-T $dst 'Images\Win11-Staff.wim')) -eq [IO.File]::GetLastWriteTimeUtc((Join-T $src 'Images\Win11-Staff.wim'))) $true "copy: timestamp kept"

    $wim = @($updates | Where-Object { $_.File -eq 'Images\Win11-Staff.wim' })
    Assert-Equal ($wim.Count -ge 2) $true "progress: the image reports at its start and end"
    Assert-Equal $wim[0].FilePercent 0 "progress: image starts at 0%"
    Assert-Equal $wim[-1].FilePercent 100 "progress: image ends at 100%"
    Assert-Equal $wim[-1].FileIndex 4 "progress: file number"
    Assert-Equal $wim[-1].FileCount 4 "progress: file count"
    Assert-Equal $updates[-1].Percent 100 "progress: overall ends at 100%"
    Assert-Equal $updates[-1].BytesDone $plan.TotalBytes "progress: overall bytes"
    $rising = $true
    for ($i = 1; $i -lt $updates.Count; $i++) { if ($updates[$i].BytesDone -lt $updates[$i - 1].BytesDone) { $rising = $false } }
    Assert-Equal $rising $true "progress: never goes backwards"

    # Write-through made each chunk wait for the stick and halved the copy speed.
    Assert-Equal ((Get-Content -Raw (Join-Path $repo 'src/MediaCopy.psm1')) -match 'FileOptions\]::WriteThrough') $false 'copy: no write-through (slow on USB sticks)'
    # CopyFileEx unbuffered waited for the stick on every block: 3 MB/s where the chunked copy did 40 MB/s.
    $copySource = Get-Content -Raw (Join-Path $repo 'src/MediaCopy.psm1')
    Assert-Equal ($copySource -match 'CopyFileEx\(|NoBuffering|WriteThrough') $false 'copy: no unbuffered or write-through copy (slow on USB sticks)'
    Assert-Equal ($copySource -match '8 \* 1024 \* 1024') $true 'copy: 8 MB chunks'

    # Copying over an older, bigger file on the stick leaves exactly the new file.
    New-TestFile (Join-T $dst 'config\deploy-settings.json') 9000
    $again = Get-MediaCopyPlan -ContentRoot $src -Folders 'config'
    $null = Copy-MediaContent -Plan $again -Destination $dst -Quiet
    Assert-Equal ([IO.File]::ReadAllBytes((Join-T $dst 'config\deploy-settings.json')).Length) 50 'copy: an old bigger file is replaced, not left longer'
    # A read-only or hidden file already on the stick (CopyFileEx kept the source's attributes) is replaced too.
    $old = Join-T $dst 'config\deploy-settings.json'
    [IO.File]::WriteAllText($old, 'old')
    [IO.File]::SetAttributes($old, [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden)
    $msg = ''
    try { $null = Copy-MediaContent -Plan $again -Destination $dst -Quiet } catch { $msg = $_.Exception.Message }
    Assert-Equal $msg '' 'copy: a read-only file on the stick does not stop the copy'
    Assert-Equal ([IO.File]::ReadAllBytes($old).Length) 50 'copy: a read-only file on the stick is replaced'

    # Big files get a line of their own and a done line, so the console shows the copy moving without a progress bar.
    Remove-Item $dst -Recurse -Force; New-Item -ItemType Directory -Path $dst | Out-Null
    $one = Get-MediaCopyPlan -ContentRoot $src -Files 'Images\Win11-Staff.wim'
    $lines = & { Copy-MediaContent -Plan $one -Destination $dst -LineEvery10PercentFrom 1000 | Out-Null } 6>&1 | ForEach-Object { "$_" }
    Assert-Equal ($lines[0] -like 'Copying Images\Win11-Staff.wim (*KB)...') $true 'text: names the file and its size'
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
    try { Copy-MediaContent -Plan $bad -Destination $dst -Quiet | Out-Null } catch { $msg = $_.Exception.Message }
    Assert-Equal ($msg -like 'Copying Images\Gone.wim to the USB stick failed:*') $true 'error names the file'
}
finally { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) { Write-Host "$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'All media copy checks passed' -ForegroundColor Green
