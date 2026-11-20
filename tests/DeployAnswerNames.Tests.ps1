# Tests for picking the answer file in Deploy-Image.ps1 when the media holds a single one: the list must stay an
# array, or $names[0] is the first letter of the name ("Answer file W not found in E:\\AnswerFiles", 2026-11-20).
# Run: powershell -File tests/DeployAnswerNames.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'src/Deploy-Image.ps1'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# The script needs WinPE and admin rights, so load only the functions under test.
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
foreach ($fnName in 'Get-AnswerFileNames', 'Read-DeployAnswer') {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("AnswerNames-" + [guid]::NewGuid().ToString('N'))
$dir = Join-Path $root 'AnswerFiles'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $dir 'W11-Staff.xml') -Value '<x/>'

    # One answer file.
    $one = Get-AnswerFileNames -Root $root
    Assert-Equal ($one -is [array]) $true 'one answer file still comes back as an array'
    Assert-Equal $one.Count 1 'one answer file: one name'
    Assert-Equal $one[0] 'W11-Staff' 'one answer file: [0] is the whole name, not its first letter'

    # The selection Deploy-Image does when there is no default.
    $names = @(Get-AnswerFileNames -Root $root)
    $AnswerFile = $null
    if ($names.Count -eq 1) { $AnswerFile = $names[0] }
    Assert-Equal $AnswerFile 'W11-Staff' 'the only answer file is chosen by its full name'

    # Several answer files, sorted.
    Set-Content -LiteralPath (Join-Path $dir 'A-Lab.xml') -Value '<x/>'
    $two = Get-AnswerFileNames -Root $root
    Assert-Equal ($two -join ',') 'A-Lab,W11-Staff' 'several answer files come back sorted'

    # A content root at the top of a drive (E:\) must not give E:\\AnswerFiles in the message.
    $driveRoot = [IO.Path]::GetPathRoot($root)
    $missing = 'NoSuch-' + [guid]::NewGuid().ToString('N')
    $expectedDir = [IO.Path]::Combine($driveRoot, 'AnswerFiles')
    Assert-Throws { Read-DeployAnswer -Root $driveRoot -Name $missing } "Answer file $missing not found in $expectedDir." 'missing answer file message has one separator after the drive'
    Assert-Equal ($expectedDir -match '[\\/]{2}') $false 'answer file folder on a drive root has no doubled separator'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Deploy-Image.ps1 keeps the list an array where it calls the function.
$text = [IO.File]::ReadAllText($script)
Assert-Equal ($text -match '\$names = @\(Get-AnswerFileNames -Root \$root\)') $true 'Deploy-Image wraps Get-AnswerFileNames in @()'

Complete-Tests
