# Task library: Tasks\<name>\ holds a script (PowerShell, batch or an .exe) and a task.json that says how to run it,
# when (POSTIMAGE in WinPE, FIRSTBOOT as SYSTEM, FIRSTLOGON as the first user), which PCs it is for, and which exit
# codes mean success. Answer files pick tasks from the library and put them in order with their plain commands.
# Used by the console (Tasks tab, answer file editor), Deploy-Image.ps1 in WinPE and FirstBoot.ps1 on the deployed PC.
# PowerShell 5.1 compatible; nothing Windows-only runs at import.

Import-Module (Join-Path $PSScriptRoot 'LibraryPack.psm1')   # what applications and tasks share

$script:TaskTypes = 'powershell', 'cmd', 'exe'
$script:TaskPhases = 'POSTIMAGE', 'FIRSTBOOT', 'FIRSTLOGON'
# Where FIRSTLOGON tasks are kept on the deployed PC: first boot clears what it staged in C:\Temp.
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
    ConvertTo-TaskDefinition -Name $Name -Json (Read-PackJson -Root $TaskRoot -Name $Name -File 'task.json' -Noun 'Task')
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
    $writeScript = $PSBoundParameters.ContainsKey('ScriptText') -and $null -ne $ScriptText
    if ($writeScript -and $Definition.type -eq 'exe') { throw 'An .exe task runs a program from its folder; it has no script text.' }
    $fill = if ($writeScript) { { param($Folder) Write-TaskScriptText -Path (Join-Path $Folder $Definition.script) -Text $ScriptText } }
    Save-PackFolder -Root $TaskRoot -Name $Definition.name -Noun 'task' -File 'task.json' -JsonText (ConvertTo-TaskJson $Definition) `
        -Source $Source -SourceNoun 'Script' -Problems { param($Folder) Test-TaskPack -Definition $Definition -Folder $Folder } `
        -Fill $fill -Overwrite:$Overwrite
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
        .cmd/.bat and for a plain command (New-CommandTaskDefinition), the .exe itself otherwise. $ExtraArguments (from the answer file) go after the task's own.
    #>
    param([Parameter(Mandatory)]$Definition, [string]$Folder, [string]$ExtraArguments)
    $d = $Definition
    $file = $Folder.TrimEnd('\', '/') + '\' + $d.script
    $all = (@($d.arguments, $ExtraArguments) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' '
    $tail = if ($all) { " $all" } else { '' }
    switch ($d.type) {
        'command'    { [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = "/c $all" } }
        'powershell' { [pscustomobject]@{ FilePath = 'powershell.exe'; Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$file`"$tail" } }
        'cmd'        { [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = "/c `"`"$file`"$tail`"" } }
        default      { [pscustomobject]@{ FilePath = $file; Arguments = $all } }
    }
}

function Get-TaskCommandLine {
    # One command line for a task, for places that take a single string (unattend FirstLogonCommands).
    param([Parameter(Mandatory)]$Definition, [string]$Folder, [string]$ExtraArguments)
    $l = Get-TaskLaunch -Definition $Definition -Folder $Folder -ExtraArguments $ExtraArguments
    $exe = if ($l.FilePath -match '\s') { "`"$($l.FilePath)`"" } else { $l.FilePath }
    if ($l.Arguments) { "$exe $($l.Arguments)" } else { $exe }
}

function Resolve-DeployTasks {
    <#
    .SYNOPSIS
        The answer file's tasks in order, with each library task read from $TaskRoot. Library tasks limited to other
        makers or models are left out (reported through -OnSkip). Throws when a library task is missing or broken,
        so Deploy-Image.ps1 stops before the disk is erased.
        Each row: Phase, Name (task name or the command), Command (plain command or $null), Definition (a plain
        command gets one too, New-CommandTaskDefinition, so every task runs the same way), Folder ($null for a plain
        command), Arguments.
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
            [pscustomobject]@{ Phase = $t.Phase; Name = $t.Command; Command = $t.Command; Definition = (New-CommandTaskDefinition $t.Command); Folder = $null; Arguments = '' }
            continue
        }
        $folder = Join-Path $TaskRoot $scriptName
        $def = $null
        try { $def = Read-TaskPack -TaskRoot $TaskRoot -Name $scriptName } catch { $problems += $_.Exception.Message; continue }
        $bad = @(Test-TaskPack -Definition $def -Folder $folder)
        if ($bad) { $problems += "Task ${scriptName}: $($bad -join ' ')"; continue }
        if ($Identity -and -not (Test-PackRequirement -Definition $def -Identity $Identity)) {
            & $OnSkip "Skipping task ${scriptName}: it is for $((@($def.requirements.makers) + @($def.requirements.models)) -join ', ') only"
            continue
        }
        [pscustomobject]@{ Phase = $t.Phase; Name = $scriptName; Command = $null; Definition = $def; Folder = $folder; Arguments = "$($t.Command)".Trim() }
    }
    if ($problems) { throw "Answer file $($Answer.Name) tasks: $($problems -join ' ')" }
    @($rows)
}

function New-CommandTaskDefinition {
    # A plain command from the answer file (no script in the library) as a task definition: cmd /c, exit 0 is
    # success, and a POSTIMAGE one that fails stops the deployment, as before.
    param([Parameter(Mandatory)][string]$Command)
    ConvertTo-TaskDefinition -Name $Command -Json @{ type = 'command'; arguments = $Command; timeoutMinutes = 60; stopOnFailure = $true }
}

function Get-TaskLogName {
    # Task-<name>.log, with the characters a file name can't hold (a plain command's \ : " and so on) replaced.
    param([Parameter(Mandatory)][string]$Name, [string]$Suffix)
    $n = ($Name -replace '[\\/:*?"<>|%]+', '_').Trim()
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60).Trim() }
    "Task-$n$(if ($Suffix) { "-$Suffix" }).log"
}

function Get-LogonTaskFolder([string]$Name) { "$script:LogonTaskDir\$Name" }

function Get-LogonTaskCommand {
    # The FirstLogonCommands line for the FIRSTLOGON task at $Index in logon-tasks.json. Run-LogonTask.ps1
    # runs it with its timeout and success codes and logs it, like FirstBoot.ps1 does for FIRSTBOOT tasks.
    # conhost --headless gives PowerShell a console with no window: -WindowStyle Hidden alone still flashes an empty
    # "Windows PowerShell" window on the user's desktop until PowerShell has started (Patrick, 2026-11-22).
    param([Parameter(Mandatory)][int]$Index)
    "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:LogonTaskDir\Run-LogonTask.ps1`" -Index $Index"
}

function New-LogonTaskPlan {
    # What logon-tasks.json holds: the FIRSTLOGON tasks in order (plain commands too), each with its definition and arguments.
    param([object[]]$Tasks = @())
    @($Tasks | Where-Object { $_.Phase -eq 'FIRSTLOGON' -and $_.Definition } | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; task = $_.Definition; arguments = $_.Arguments }
    })
}

function Invoke-TaskPack {
    <#
    .SYNOPSIS
        Runs one task (a library task from $Folder, or a plain command) with a timeout, its output going to $LogPath.
        Every phase runs its tasks through this: POSTIMAGE (Deploy-Image.ps1), FIRSTBOOT (FirstBoot.ps1) and
        FIRSTLOGON (Run-LogonTask.ps1).
        Returns @{ Status = Succeeded | Failed | TimedOut; ExitCode; Message; LogPath }.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [string]$Folder,             # the task's folder; a plain command has none
        [string]$ExtraArguments,
        [Parameter(Mandatory)][string]$LogPath,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $d = $Definition
    $out = { param($s, $code, $msg) [pscustomobject]@{ Status = $s; ExitCode = $code; Message = $msg; LogPath = $LogPath } }
    $l = Get-TaskLaunch -Definition $d -Folder $Folder -ExtraArguments $ExtraArguments
    $run = Invoke-PackProcess -FilePath $l.FilePath -Arguments $l.Arguments -WorkingDirectory $Folder -TimeoutMinutes $d.timeoutMinutes -LogPath $LogPath -Log $Log
    $tail = if ($run.LastLine) { "; last line: $($run.LastLine)" } else { '' }
    if ($run.TimedOut) { return & $out 'TimedOut' $null "still running after $($d.timeoutMinutes) minutes; stopped$tail" }
    $code = $run.ExitCode
    if ($d.successCodes -notcontains $code) { return & $out 'Failed' $code "exit code $code is not a success code ($($d.successCodes -join ', '))$tail" }
    & $out 'Succeeded' $code "exit $code"
}

#endregion

#region Library

function Get-TaskTemplates {
    # config\task-templates.json: ready-made scripts for common jobs, to start a new task from.
    param([string]$Path)
    Get-PackTemplates -File 'task-templates.json' -Path $Path
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

Export-ModuleMember -Function Get-TaskTypeFromFile, ConvertTo-TaskDefinition, ConvertTo-TaskJson, Read-TaskPack, Test-TaskPack, New-CommandTaskDefinition, Get-TaskLogName,
    Write-TaskScriptText, Save-TaskPack, Get-TaskScriptText, Get-TaskLaunch, Get-TaskCommandLine,
    Resolve-DeployTasks, Get-LogonTaskFolder, Get-LogonTaskCommand, New-LogonTaskPlan, Invoke-TaskPack,
    Get-TaskTemplates, New-TaskFromTemplate
