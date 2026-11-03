# Task library: Tasks\<name>\ holds a script (PowerShell, batch or an .exe) and a task.json that says how to run it,
# when (POSTIMAGE in WinPE, FIRSTBOOT as SYSTEM, FIRSTLOGON as the first user), which PCs it is for, and which exit
# codes mean success. Answer files pick tasks from the library and put them in order with their plain commands.
# Used by the console (Tasks tab, answer file editor), Deploy-Image.ps1 in WinPE and FirstBoot.ps1 on the deployed PC.
# PowerShell 5.1 compatible; nothing Windows-only runs at import.

$script:TaskTypes = 'powershell', 'cmd', 'exe'
$script:TaskPhases = 'POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON'
# Where FIRSTLOGON tasks are kept on the deployed PC: C:\Deploy is removed at the end of first boot.
$script:LogonTaskDir = 'C:\ProgramData\ImagingTool\Tasks'

#region Definition

function Get-TaskTypeFromFile([string]$FileName) {
    # The way a script file runs, from its extension; $null for files that can't run on their own.
    switch -Regex ([IO.Path]::GetExtension("$FileName").ToLowerInvariant()) {
        '^\.ps1$'       { 'powershell' }
        '^\.(cmd|bat)$' { 'cmd' }
        '^\.exe$'       { 'exe' }
        default         { $null }
    }
}

function ConvertTo-TaskDefinition {
    <#
    .SYNOPSIS
        Normalizes a task.json object (or a hashtable from scripts and tests) into a full task definition.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Json)
    $Json = $Json | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $get = { param($p, $default) if ($Json -and $Json.PSObject.Properties[$p] -and $null -ne $Json.$p -and "$($Json.$p)" -ne '') { $Json.$p } else { $default } }
    $list = { param($v) @($v | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
    $file = "$(& $get 'script' '')".Trim()
    $type = "$(& $get 'type' '')".ToLowerInvariant()
    if (-not $type) { $type = Get-TaskTypeFromFile $file }
    $req = & $get 'requirements' $null
    [pscustomobject][ordered]@{
        name           = $Name
        description    = "$(& $get 'description' '')"
        script         = $file
        type           = "$type"
        arguments      = "$(& $get 'arguments' '')"
        phase          = "$(& $get 'phase' 'FIRSTBOOT')".ToUpperInvariant()
        timeoutMinutes = [int](& $get 'timeoutMinutes' 30)
        successCodes   = @(@(& $get 'successCodes' @(0)) | Where-Object { "$_" -ne '' } | ForEach-Object { [int]$_ })
        stopOnFailure  = [bool](& $get 'stopOnFailure' $false)
        requirements   = [pscustomobject]@{
            makers = & $list $(if ($req) { $req.makers })
            models = & $list $(if ($req) { $req.models })
        }
    }
}

function ConvertTo-TaskJson {
    # What goes in task.json: the definition without its name (the folder is the name).
    # Lists are wrapped in @() so Windows PowerShell 5.1 writes [] and not {} for empty ones.
    param([Parameter(Mandatory)]$Definition)
    $o = [ordered]@{}
    foreach ($p in $Definition.PSObject.Properties) { if ($p.Name -ne 'name') { $o[$p.Name] = $p.Value } }
    $o.successCodes = @($Definition.successCodes)
    $o.requirements = [ordered]@{ makers = @($Definition.requirements.makers); models = @($Definition.requirements.models) }
    [pscustomobject]$o | ConvertTo-Json -Depth 5
}

function Read-TaskPack {
    # Reads Tasks\<name>\task.json into a full definition. Throws when it is missing.
    param([Parameter(Mandatory)][string]$TaskRoot, [Parameter(Mandatory)][string]$Name)
    $json = Join-Path (Join-Path $TaskRoot $Name) 'task.json'
    if (-not (Test-Path $json)) { throw "Task '$Name' has no task.json in $TaskRoot\$Name." }
    ConvertTo-TaskDefinition -Name $Name -Json (Get-Content -Raw $json | ConvertFrom-Json)
}

function Test-TaskPack {
    # Problems that stop the task from running; empty when it is fine. With -Folder, also checks the script is there.
    param([Parameter(Mandatory)]$Definition, [string]$Folder)
    $d = $Definition
    if ($d.name -notmatch '^[A-Za-z0-9._-]+$') { "Task name '$($d.name)' may only contain letters, digits, dot, dash and underscore." }
    if (-not $d.script) { 'Choose the script to run, or write one.' }
    elseif ($d.script -match '[\\/:*?"<>|]') { "Script '$($d.script)' must be a file name in the task's folder, without a folder." }
    if (-not $d.type) { "Script '$($d.script)' must be a .ps1, .cmd, .bat or .exe file." }
    elseif ($d.type -notin $script:TaskTypes) { "Task type must be powershell, cmd or exe, not '$($d.type)'." }
    if ($d.phase -notin $script:TaskPhases) { "When must be POSTIMAGE, FIRSTBOOT or FIRSTLOGON, not '$($d.phase)'." }
    if ($d.timeoutMinutes -lt 1) { 'The timeout must be at least 1 minute.' }
    if ("$($d.arguments)" -match 'REPLACE_[A-Z_]+') { "Replace $($Matches[0]) in the arguments." }
    if (-not @($d.successCodes).Count) { 'Give at least one success exit code (usually 0).' }
    if ($Folder -and $d.script -and -not (Test-Path (Join-Path $Folder $d.script) -PathType Leaf)) { "The script $($d.script) is not in $Folder." }
}

function Write-TaskScriptText {
    # Writes a script typed in the console: .ps1 as UTF-8 with a BOM (Windows PowerShell 5.1 reads BOM-less files
    # as ANSI), .cmd/.bat as ANSI because cmd.exe would choke on a BOM. Lines end in CRLF.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $crlf = ($Text -replace "`r`n", "`n" -replace "`r", "`n") -replace "`n", "`r`n"
    $enc = if ((Get-TaskTypeFromFile $Path) -eq 'powershell') { New-Object Text.UTF8Encoding $true } else { [Text.Encoding]::Default }
    [IO.File]::WriteAllText($Path, $crlf, $enc)
}

function Save-TaskPack {
    <#
    .SYNOPSIS
        Writes Tasks\<name>: copies -Source (a script file, or a folder's contents) when given, writes -ScriptText
        to the definition's script file when given, then writes task.json. Without -Overwrite an existing task is an error.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskRoot,
        [Parameter(Mandatory)]$Definition,
        [string]$Source,
        [AllowNull()][string]$ScriptText,
        [switch]$Overwrite
    )
    $dest = Join-Path $TaskRoot $Definition.name
    if ((Test-Path $dest) -and -not $Overwrite) { throw "A task named $($Definition.name) already exists." }
    if ($Source -and -not (Test-Path $Source)) { throw "Script not found: $Source" }
    $problems = @(Test-TaskPack -Definition $Definition)
    if ($problems) { throw ($problems -join "`n") }

    $isNew = -not (Test-Path $dest)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    try {
        if ($Source) {
            if (Test-Path $Source -PathType Container) { Copy-Item -Path (Join-Path $Source '*') -Destination $dest -Recurse -Force }
            else { Copy-Item -Path $Source -Destination $dest -Force }
        }
        if ($PSBoundParameters.ContainsKey('ScriptText') -and $null -ne $ScriptText) {
            if ($Definition.type -eq 'exe') { throw 'An .exe task runs a program from its folder; it has no script text.' }
            Write-TaskScriptText -Path (Join-Path $dest $Definition.script) -Text $ScriptText
        }
        $problems = @(Test-TaskPack -Definition $Definition -Folder $dest)
        if ($problems) { throw ($problems -join "`n") }
    } catch {
        if ($isNew -and (Test-Path $dest)) { Remove-Item $dest -Recurse -Force }
        throw
    }
    ConvertTo-TaskJson $Definition | Set-Content (Join-Path $dest 'task.json') -Encoding utf8
    $dest
}

function Get-TaskScriptText {
    # The text of a task's script for the editor, or $null for an .exe or a missing file.
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Folder)
    if ($Definition.type -eq 'exe' -or -not $Definition.script) { return $null }
    $path = Join-Path $Folder $Definition.script
    if (-not (Test-Path $path -PathType Leaf)) { return $null }
    Get-Content -Raw -Path $path
}

#endregion

#region Running

function Get-TaskLaunch {
    <#
    .SYNOPSIS
        The program and arguments that run a task from $Folder: powershell.exe -File for .ps1, cmd.exe /c for
        .cmd/.bat, the .exe itself otherwise. $ExtraArguments (from the answer file) go after the task's own.
    #>
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Folder, [string]$ExtraArguments)
    $d = $Definition
    $file = $Folder.TrimEnd('\', '/') + '\' + $d.script
    $all = (@($d.arguments, $ExtraArguments) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
    $tail = if ($all) { " $all" } else { '' }
    switch ($d.type) {
        'powershell' { [pscustomobject]@{ FilePath = 'powershell.exe'; Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$file`"$tail" } }
        'cmd'        { [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = "/c `"`"$file`"$tail`"" } }
        default      { [pscustomobject]@{ FilePath = $file; Arguments = $all } }
    }
}

function Get-TaskCommandLine {
    # One command line for a task, for places that take a single string (unattend FirstLogonCommands).
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Folder, [string]$ExtraArguments)
    $l = Get-TaskLaunch -Definition $Definition -Folder $Folder -ExtraArguments $ExtraArguments
    $exe = if ($l.FilePath -match '\s') { "`"$($l.FilePath)`"" } else { $l.FilePath }
    if ($l.Arguments) { "$exe $($l.Arguments)" } else { $exe }
}

function Test-TaskRequirement {
    # $true when the task is for this PC. Makers and models are wildcards, the same as for applications.
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)]$Identity)
    $r = $Definition.requirements
    $makerOk = -not @($r.makers).Count -or @($r.makers | Where-Object { $Identity.Maker -like $_ }).Count
    $modelOk = -not @($r.models).Count -or @($r.models | Where-Object { $Identity.Model -like $_ -or ($Identity.MachineType -and $Identity.MachineType -like $_) }).Count
    [bool]($makerOk -and $modelOk)
}

function Resolve-DeployTasks {
    <#
    .SYNOPSIS
        The answer file's tasks in order, with each library task read from $TaskRoot. Library tasks limited to other
        makers or models are left out (reported through -OnSkip). Throws when a library task is missing or broken,
        so Deploy-Image.ps1 stops before the disk is erased.
        Each row: Phase, Name (task name or the command), Command (plain command or $null), Definition, Folder, Arguments.
    #>
    param(
        [Parameter(Mandatory)]$Answer,
        [Parameter(Mandatory)][string]$TaskRoot,
        $Identity,
        [scriptblock]$OnSkip = { param($m) }
    )
    $problems = @()
    $rows = foreach ($t in @($Answer.Tasks)) {
        $scriptName = if ($t.PSObject.Properties['Script']) { "$($t.Script)" } else { '' }
        if (-not $scriptName) {
            [pscustomobject]@{ Phase = $t.Phase; Name = $t.Command; Command = $t.Command; Definition = $null; Folder = $null; Arguments = '' }
            continue
        }
        $folder = Join-Path $TaskRoot $scriptName
        $def = $null
        try { $def = Read-TaskPack -TaskRoot $TaskRoot -Name $scriptName } catch { $problems += $_.Exception.Message; continue }
        $bad = @(Test-TaskPack -Definition $def -Folder $folder)
        if ($bad) { $problems += "Task ${scriptName}: $($bad -join ' ')"; continue }
        if ($Identity -and -not (Test-TaskRequirement -Definition $def -Identity $Identity)) {
            & $OnSkip "Skipping task ${scriptName}: it is for $((@($def.requirements.makers) + @($def.requirements.models)) -join ', ') only"
            continue
        }
        [pscustomobject]@{ Phase = $t.Phase; Name = $scriptName; Command = $null; Definition = $def; Folder = $folder; Arguments = "$($t.Command)".Trim() }
    }
    if ($problems) { throw "Answer file $($Answer.Name) tasks: $($problems -join ' ')" }
    @($rows)
}

function Get-LogonTaskFolder([string]$Name) { "$script:LogonTaskDir\$Name" }

function Get-LogonTaskCommand {
    # The FirstLogonCommands line for the FIRSTLOGON library task at $Index in logon-tasks.json. Run-LogonTask.ps1
    # runs it with its timeout and success codes and logs it, like FirstBoot.ps1 does for FIRSTBOOT tasks.
    param([Parameter(Mandatory)][int]$Index)
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:LogonTaskDir\Run-LogonTask.ps1`" -Index $Index"
}

function New-LogonTaskPlan {
    # What logon-tasks.json holds: the FIRSTLOGON library tasks in order, each with its definition and arguments.
    param([object[]]$Tasks = @())
    @($Tasks | Where-Object { $_.Phase -eq 'FIRSTLOGON' -and $_.Definition } | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; task = $_.Definition; arguments = $_.Arguments }
    })
}

function Invoke-TaskPack {
    <#
    .SYNOPSIS
        Runs one library task from $Folder with a timeout, its output going to $LogPath.
        Returns @{ Status = Succeeded | Failed | TimedOut; ExitCode; Message; LogPath }.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$Folder,
        [string]$ExtraArguments,
        [Parameter(Mandatory)][string]$LogPath,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $d = $Definition
    $out = { param($s, $code, $msg) [pscustomobject]@{ Status = $s; ExitCode = $code; Message = $msg; LogPath = $LogPath } }
    $l = Get-TaskLaunch -Definition $d -Folder $Folder -ExtraArguments $ExtraArguments
    & $Log "  > $($l.FilePath) $($l.Arguments)"
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
    # Console programs (powershell.exe, cmd.exe) write redirected output in the OEM code page, so read it that way
    # or accented letters in the log come out wrong. Both streams are read while the task runs so neither pipe fills.
    $oem = try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { [Console]::OutputEncoding }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $l.FilePath
    $psi.Arguments = "$($l.Arguments)"
    $psi.WorkingDirectory = $Folder
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $oem
    $psi.StandardErrorEncoding = $oem
    $p = [Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEndAsync()
    $stderr = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($d.timeoutMinutes * 60000)
    if ($timedOut) { try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch { } }
    else { $p.WaitForExit() }
    # The pipes close once the task (and anything it started) has ended; don't hang on one that stays open.
    $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 15000)

    # One log per task: the command, its output, then its errors. UTF-8, so accents survive.
    $lines = @("{0:yyyy-MM-dd HH:mm:ss} {1} {2}" -f (Get-Date), $l.FilePath, $l.Arguments)
    foreach ($t in $stdout, $stderr) {
        if ($t.IsCompleted -and -not $t.IsFaulted -and $t.Result) { $lines += @($t.Result -split "\r?\n" | Where-Object { $_ -ne '' }) }
    }
    Add-Content -Path $LogPath -Value $lines -Encoding UTF8
    $last = @($lines | Select-Object -Skip 1 | Where-Object { "$_".Trim() } | Select-Object -Last 1)
    $tail = if ($last) { "; last line: $("$($last[0])".Trim())" } else { '' }

    if ($timedOut) { return & $out 'TimedOut' $null "still running after $($d.timeoutMinutes) minutes; stopped$tail" }
    $code = $p.ExitCode
    if ($d.successCodes -notcontains $code) { return & $out 'Failed' $code "exit code $code is not a success code ($($d.successCodes -join ', '))$tail" }
    & $out 'Succeeded' $code "exit $code"
}

#endregion

#region Library

function Export-TaskPack {
    # Zips Tasks\<name> (script, task.json, other files) into one file to copy to another content root.
    param([Parameter(Mandatory)][string]$TaskRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    $src = Join-Path $TaskRoot $Name
    [void](Read-TaskPack -TaskRoot $TaskRoot -Name $Name)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path $src).ProviderPath, $Path, 'Optimal', $false)
    $Path
}

function Import-TaskPack {
    # Unzips an exported task into Tasks\<name>; the name comes from the file unless -Name is given.
    param([Parameter(Mandatory)][string]$TaskRoot, [Parameter(Mandatory)][string]$Path, [string]$Name, [switch]$Overwrite)
    if (-not $Name) { $Name = [IO.Path]::GetFileNameWithoutExtension($Path) }
    if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Task name '$Name' may only contain letters, digits, dot, dash and underscore." }
    $dest = Join-Path $TaskRoot $Name
    if ((Test-Path $dest) -and -not $Overwrite) { throw "A task named $Name already exists." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("taskpack-" + [guid]::NewGuid())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $Path).ProviderPath, $tmp)
        if (-not (Test-Path (Join-Path $tmp 'task.json'))) { throw "$Path is not an exported task (no task.json at the top)." }
        $def = ConvertTo-TaskDefinition -Name $Name -Json (Get-Content -Raw (Join-Path $tmp 'task.json') | ConvertFrom-Json)
        $problems = @(Test-TaskPack -Definition $def -Folder $tmp)
        if ($problems) { throw ($problems -join "`n") }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $TaskRoot -Force | Out-Null
        Move-Item $tmp $dest
    } finally { if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force } }
    $dest
}

function Get-TaskTemplates {
    # config\task-templates.json: ready-made scripts for common jobs, to start a new task from.
    param([string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/task-templates.json'))
    if (-not (Test-Path $Path)) { return @() }
    @((Get-Content -Raw $Path | ConvertFrom-Json).templates)
}

function New-TaskFromTemplate {
    # A definition and script text from a template. Returns @{ Definition; ScriptText }.
    param([Parameter(Mandatory)]$Template, [string]$Name)
    $t = $Template
    if (-not $Name) { $Name = $t.name }
    $def = ConvertTo-TaskDefinition -Name $Name -Json ([pscustomobject]@{
        description = $t.description; script = $t.script; arguments = $t.arguments; phase = $t.phase
        timeoutMinutes = $t.timeoutMinutes; successCodes = $t.successCodes; requirements = $t.requirements
    })
    [pscustomobject]@{ Definition = $def; ScriptText = (@($t.text) -join "`r`n") + "`r`n" }
}

#endregion

Export-ModuleMember -Function Get-TaskTypeFromFile, ConvertTo-TaskDefinition, ConvertTo-TaskJson, Read-TaskPack, Test-TaskPack,
    Write-TaskScriptText, Save-TaskPack, Get-TaskScriptText, Get-TaskLaunch, Get-TaskCommandLine, Test-TaskRequirement,
    Resolve-DeployTasks, Get-LogonTaskFolder, Get-LogonTaskCommand, New-LogonTaskPlan, Invoke-TaskPack,
    Export-TaskPack, Import-TaskPack, Get-TaskTemplates, New-TaskFromTemplate
