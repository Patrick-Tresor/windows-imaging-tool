# What application packs (AppPack.psm1) and library tasks (TaskPack.psm1) have in common: a folder with a JSON file
# under Applications\ or Tasks\, ready-made templates in config\, "only for these makers / models", and running a
# program with a timeout, success codes and a log of its output. Written once here so both behave the same.
# Copied next to AppPack.psm1 and TaskPack.psm1 wherever those go (WinPE, C:\Temp at first boot, the logon tasks).
# PowerShell 5.1 compatible; nothing Windows-only runs at import.

function Read-PackJson {
    # <Root>\<Name>\<File> as an object. Throws when it is not there: "Application 'X' has no app.json in ...".
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$File,
          [Parameter(Mandatory)][string]$Noun)
    $json = Join-Path (Join-Path $Root $Name) $File
    if (-not (Test-Path $json)) { throw "$Noun '$Name' has no $File in $Root\$Name." }
    Get-Content -Raw $json | ConvertFrom-Json
}

function Save-PackFolder {
    <#
    .SYNOPSIS
        Writes <Root>\<Name>: copies -Source (a file, or a folder's contents), runs -Fill on the folder, checks it with
        -Problems, then writes -JsonText to -File. A new folder is removed again when anything fails. Without
        -Overwrite an existing folder is an error. -Problems { param($Folder) } returns the errors ($Folder empty
        before anything is copied); -Fill { param($Folder) } writes extra files (a task's script).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Noun,           # 'application', 'task'
        [Parameter(Mandatory)][string]$File,           # 'app.json', 'task.json'
        [Parameter(Mandatory)][string]$JsonText,
        [string]$Source,
        [string]$SourceNoun = 'File',                  # what -Source is, for "Installer not found"
        [scriptblock]$Problems = { param($Folder) },
        [scriptblock]$Fill,
        [switch]$Overwrite
    )
    $dest = Join-Path $Root $Name
    $article = if ($Noun -match '^[aeiou]') { 'An' } else { 'A' }
    if ((Test-Path $dest) -and -not $Overwrite) { throw "$article $Noun named $Name already exists." }
    if ($Source -and -not (Test-Path $Source)) { throw "$SourceNoun not found: $Source" }
    $errors = @(& $Problems $null)
    if ($errors) { throw ($errors -join "`n") }

    $isNew = -not (Test-Path $dest)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    try {
        if ($Source) {
            if (Test-Path $Source -PathType Container) { Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force }
            else { Copy-Item -Path $Source -Destination $dest -Force }
        }
        if ($Fill) { & $Fill $dest }
        $errors = @(& $Problems $dest)
        if ($errors) { throw ($errors -join "`n") }
    } catch {
        if ($isNew -and (Test-Path $dest)) { Remove-Item $dest -Recurse -Force }
        throw
    }
    $JsonText | Set-Content (Join-Path $dest $File) -Encoding utf8
    $dest
}

function Get-PackTemplates {
    # config\<File> (app-templates.json, task-templates.json): its templates list, or nothing when the file is missing.
    param([Parameter(Mandatory)][string]$File, [string]$Path)
    if (-not $Path) { $Path = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config') $File }
    if (-not (Test-Path $Path)) { return @() }
    @((Get-Content -Raw $Path | ConvertFrom-Json).templates)
}

function Test-PackRequirement {
    # $true when an application or task is for this PC. Makers and models are wildcards, compared with
    # Get-HardwareIdentity's Maker and Model (or Lenovo machine type).
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)]$Identity)
    $r = $Definition.requirements
    $makerOk = -not @($r.makers).Count -or @($r.makers | Where-Object { $Identity.Maker -like $_ }).Count
    $modelOk = -not @($r.models).Count -or @($r.models | Where-Object { $Identity.Model -like $_ -or ($Identity.MachineType -and $Identity.MachineType -like $_) }).Count
    [bool]($makerOk -and $modelOk)
}

function Invoke-PackProcess {
    <#
    .SYNOPSIS
        Runs a program with a timeout, its output and errors going to $LogPath (UTF-8, after a line with the command).
        Returns @{ TimedOut; ExitCode; LastLine } (LastLine: the last line it printed, for the message).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][string]$LogPath,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    & $Log "  > $FilePath $Arguments"
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
    # Console programs (powershell.exe, cmd.exe) write redirected output in the OEM code page, so read it that way
    # or accented letters in the log come out wrong. Both streams are read while it runs so neither pipe fills.
    $oem = try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { [Console]::OutputEncoding }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = "$Arguments"
    if ($WorkingDirectory -and [IO.Directory]::Exists($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $oem
    $psi.StandardErrorEncoding = $oem
    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutMinutes * 60000)
    if ($timedOut) { try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch { } }
    else { $p.WaitForExit() }
    # The pipes close once the program (and anything it started) has ended; don't hang on one that stays open.
    $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 15000)

    $lines = @("{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $FilePath, $Arguments)
    foreach ($t in $stdout, $stderr) {
        if ($t.IsCompleted -and -not $t.IsFaulted -and $t.Result) { $lines += @($t.Result -split "\r?\n" | Where-Object { $_ -ne '' }) }
    }
    Add-Content -Path $LogPath -Value $lines -Encoding UTF8
    $last = @($lines | Select-Object -Skip 1 | Where-Object { "$_".Trim() } | Select-Object -Last 1)
    [pscustomobject]@{
        TimedOut = $timedOut
        ExitCode = if ($timedOut) { $null } else { $p.ExitCode }
        LastLine = if ($last) { "$($last[0])".Trim() } else { '' }
    }
}

Export-ModuleMember -Function Read-PackJson, Save-PackFolder, Get-PackTemplates, Test-PackRequirement, Invoke-PackProcess
