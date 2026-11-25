# Plain-PowerShell tests for the clean-up before capture: Prepare-Reference.ps1 empties junk folders (never this
# script's own folder or the answer file), and every capture leaves the same junk out of the image.
# Run: pwsh -File tests/ReferenceCleanup.Tests.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repo 'src/Prepare-Reference.ps1'

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
Import-Module (Join-Path $repo 'src/ImageVersions.psm1') -Force

# The script needs admin rights and runs sysprep, so load only the functions.
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
foreach ($fnName in 'Get-CleanupFolders', 'Clear-FolderContents') {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("RefCleanup-" + [guid]::NewGuid().ToString('N'))
try {
    $win = Join-Path $root 'Windows'
    $users = Join-Path $root 'Users'
    foreach ($d in "$win\SoftwareDistribution\Download\abc", "$win\Temp", "$users\Admin\AppData\Local\Temp\Tools",
                   "$users\Public") {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Set-Content "$win\SoftwareDistribution\Download\abc\update.cab" 'x'
    Set-Content "$win\Temp\old.log" 'x'
    Set-Content "$users\Admin\AppData\Local\Temp\junk.tmp" 'x'
    Set-Content "$users\Admin\AppData\Local\Temp\Tools\Prepare-Reference.ps1" 'x'
    Set-Content "$users\Admin\AppData\Local\Temp\unattend.xml" 'x'

    $folders = @(Get-CleanupFolders -WinDir $win -UsersDir $users | ForEach-Object { $_.Substring($root.Length) })
    Assert-Equal ($folders -join '|') '\Windows\SoftwareDistribution\Download|\Windows\Temp|\Users\Admin\AppData\Local\Temp' 'only existing junk folders are listed (no Delivery Optimization cache, no Public temp here)'
    Assert-Equal @(Get-CleanupFolders -WinDir $win -UsersDir (Join-Path $root 'NoUsers')).Count 2 'a missing Users folder is skipped'

    $keep = @("$users\Admin\AppData\Local\Temp\Tools", "$users\Admin\AppData\Local\Temp\unattend.xml", $null)
    foreach ($f in Get-CleanupFolders -WinDir $win -UsersDir $users) {
        Assert-Equal (Clear-FolderContents -Folder $f -Keep $keep) 0 "nothing left in $f"
    }
    Assert-Equal (Test-Path "$win\SoftwareDistribution\Download") $true 'the folder itself stays'
    Assert-Equal @(Get-ChildItem "$win\SoftwareDistribution\Download" -Force).Count 0 'update downloads are deleted'
    Assert-Equal @(Get-ChildItem "$win\Temp" -Force).Count 0 'Windows temp is emptied'
    Assert-Equal (Test-Path "$users\Admin\AppData\Local\Temp\junk.tmp") $false 'user temp is emptied'
    Assert-Equal (Test-Path "$users\Admin\AppData\Local\Temp\Tools\Prepare-Reference.ps1") $true 'the running script folder is kept'
    Assert-Equal (Test-Path "$users\Admin\AppData\Local\Temp\unattend.xml") $true 'the answer file is kept'

    # Kept file inside a folder: the folder that holds it stays too.
    New-Item -ItemType Directory -Path "$win\Temp\Run\Sub" -Force | Out-Null
    Set-Content "$win\Temp\Run\Sub\a.xml" 'x'
    Set-Content "$win\Temp\Run\other.txt" 'x'
    Clear-FolderContents -Folder "$win\Temp" -Keep @("$win\Temp\Run\Sub\a.xml") | Out-Null
    Assert-Equal (Test-Path "$win\Temp\Run\Sub\a.xml") $true 'a kept file deep in a folder is not deleted with its parent'

    # Capture exclusion list
    $list = @(Get-CaptureExclusionList)
    foreach ($p in '\pagefile.sys', '\hiberfil.sys', '\swapfile.sys', '\System Volume Information', '\Windows\CSC', '\$ntfs.log', '\RECYCLER') {
        Assert-Equal ($list -contains $p) $true "DISM default $p stays excluded"
    }
    foreach ($p in '\Windows\SoftwareDistribution\Download', '\$Recycle.Bin', '\Windows.old', '\Windows\MEMORY.DMP') {
        Assert-Equal ($list -contains $p) $true "$p is left out of the image"
    }
    Assert-Equal @($list | Where-Object { $_ -like '*`**' }).Count 0 'no wildcards (DISM allows them only in a last part with no leading \)'
    Assert-Equal @($list | Where-Object { $_ -notlike '\*' }).Count 0 'every path starts at the root'
    foreach ($never in '\Windows\Temp', '\Users', '\ProgramData', '\Windows\System32', '\Windows\WinSxS', '\Program Files') {
        Assert-Equal ($list -contains $never) $false "$never is captured"
    }
    $ini = New-CaptureConfigFile -Path (Join-Path $root 'x.ini')
    $text = [IO.File]::ReadAllLines($ini)
    Assert-Equal $text[0] '[ExclusionList]' 'config file starts with the exclusion list'
    Assert-Equal ($text -contains '[CompressionExclusionList]') $true 'DISM default compression exclusions kept'
    Assert-Equal ($text -contains '\WINDOWS\inf\*.pnf') $true 'pnf files are not compressed, like DISM default'
    Assert-Equal @([IO.File]::ReadAllBytes($ini) | Where-Object { $_ -gt 127 }).Count 0 'config file is plain ASCII'
    Assert-Equal ((Get-CaptureImageArgs -WimPath 'W.wim' -CaptureDir 'V:\' -Name 'W' -ConfigFile 'C:\T\x.ini') -join ' ') '/Capture-Image /ImageFile:W.wim /CaptureDir:V:\ /Name:W /Compress:max /CheckIntegrity /ConfigFile:C:\T\x.ini' 'capture passes the exclusion list'

    # The script wires it up: cleanup before sysprep, never in -CheckOnly (sysprep at deploy), -CleanupOnly stops.
    $text = [IO.File]::ReadAllText($script)
    Assert-Equal ($text -match 'if \(\$CheckOnly -and -not \$CleanupOnly\) \{ return \}') $true '-CheckOnly never cleans up'
    Assert-Equal ($text -match 'Invoke-ReferenceCleanup -Keep @\(\$PSScriptRoot, \$Unattend\)') $true 'cleanup keeps the script folder and answer file'
    Assert-Equal ($text -match '/StartComponentCleanup /ResetBase') $true 'component cleanup runs'
    Assert-Equal ($text -match 'if \(\$problems\.Count -and \$CleanupOnly\)') $true '-CleanupOnly still cleans up when a check finds a problem'
    Assert-Equal ($text -match 'if \(\$ShutDown\).*shutdown\.exe /s /t 0') $true '-CleanupOnly -ShutDown shuts down fully'
    $wizard = [IO.File]::ReadAllText((Join-Path $repo 'src/Console/CaptureWizard.ps1'))
    Assert-Equal ($wizard -match '"\$prepCommand -CleanupOnly -ShutDown"') $true 'sysprep at deploy: the wizard shows the clean-up and shut down command'
    $cap = [IO.File]::ReadAllText((Join-Path $repo 'src/Capture-VMImage.ps1'))
    Assert-Equal ($cap -match '-ConfigFile \$captureConfig') $true 'Capture-VMImage passes the exclusion list'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests 'All tests passed'
