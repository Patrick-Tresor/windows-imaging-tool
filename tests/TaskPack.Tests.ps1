# Plain-PowerShell tests for the task library (Tasks tab): task.json, saving typed scripts, how a task is launched,
# answer files that use library tasks, what the deploy runs and what goes on a USB stick.
# Run: pwsh -File tests/TaskPack.Tests.ps1 (running real scripts needs Windows).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'src/Console/ConsoleData.psm1') -Force
Import-Module (Join-Path $repo 'src/AnswerFile.psm1') -Force
Import-Module (Join-Path $repo 'src/TaskPack.psm1') -Force
Import-Module (Join-Path $repo 'src/MediaContent.psm1') -Force

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ("tasks-test-" + [guid]::NewGuid())
try {
    Initialize-ContentRoot -Path $root
    $taskRoot = Join-Path $root 'Tasks'
    Assert-Equal (Test-Path $taskRoot) $true 'a new content root has a Tasks folder'

    # Definitions: defaults, and the type follows the file name.
    $d = ConvertTo-TaskDefinition -Name 'Wallpaper' -Json ([pscustomobject]@{ script = 'set.ps1' })
    Assert-Equal "$($d.type)|$($d.phase)|$($d.timeoutMinutes)|$($d.successCodes -join ',')|$($d.stopOnFailure)|$(@($d.requirements.makers).Count)" 'powershell|FIRSTBOOT|30|0|False|0' 'a short task.json gets defaults'
    Assert-Equal (Get-TaskTypeFromFile 'x.CMD') 'cmd' '.cmd runs with cmd'
    Assert-Equal (Get-TaskTypeFromFile 'x.bat') 'cmd' '.bat runs with cmd'
    Assert-Equal (Get-TaskTypeFromFile 'tool.exe') 'exe' '.exe runs as a program'
    Assert-Equal ($null -eq (Get-TaskTypeFromFile 'notes.txt')) $true 'a .txt file cannot run'

    $bad = ConvertTo-TaskDefinition -Name 'Bad name' -Json ([pscustomobject]@{ script = 'notes.txt'; phase = 'later'; timeoutMinutes = 0 })
    Assert-Equal @(Test-TaskPack -Definition $bad).Count 4 'name, file type, phase and timeout problems are found'
    Assert-Equal @(Test-TaskPack -Definition $d -Folder $root).Count 1 'a missing script file is found'

    # Saving a typed script: .ps1 gets a BOM (Windows PowerShell 5.1), .cmd none (cmd.exe), lines end in CRLF.
    $psText = "Write-Output 'caf$([char]0xE9)'`nexit 0"
    Save-Task -ContentRoot $root -Definition $d -ScriptText $psText -New | Out-Null
    $bytes = [IO.File]::ReadAllBytes((Join-Path $taskRoot 'Wallpaper/set.ps1'))
    Assert-Equal ("{0:X2}{1:X2}{2:X2}" -f $bytes[0], $bytes[1], $bytes[2]) 'EFBBBF' 'a typed .ps1 is saved with a UTF-8 BOM'
    Assert-Equal ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r`n")) $true 'a typed script gets CRLF line ends'
    Assert-Equal ((Get-TaskScriptText -Definition $d -Folder (Join-Path $taskRoot 'Wallpaper')).Trim() -like "*caf$([char]0xE9)*") $true 'the editor reads the script back'
    Assert-Throws { Save-Task -ContentRoot $root -Definition $d -ScriptText 'x' -New } '*already exists*' 'a new task cannot take an existing name'

    $c = ConvertTo-TaskDefinition -Name 'Cleanup' -Json ([pscustomobject]@{ script = 'clean.cmd'; phase = 'POSTIMAGE'; arguments = '/q'; successCodes = @(0, 1)
        requirements = @{ makers = @('Dell'); models = @() } })
    Save-Task -ContentRoot $root -Definition $c -ScriptText "@echo off`ndel /q %OSDRIVE%\Temp\*" -New | Out-Null
    $cb = [IO.File]::ReadAllBytes((Join-Path $taskRoot 'Cleanup/clean.cmd'))
    Assert-Equal ([char]$cb[0]) '@' 'a typed .cmd has no BOM'
    $json = Get-Content -Raw (Join-Path $taskRoot 'Cleanup/task.json') | ConvertFrom-Json
    Assert-Equal "$($json.successCodes -join ',')|$($json.requirements.makers -join ',')|$(@($json.requirements.models).Count)|$($json.PSObject.Properties['name'] -eq $null)" '0,1|Dell|0|True' 'task.json keeps lists as lists and leaves out the name'

    # Importing a script file instead of typing it.
    $srcDir = Join-Path $root 'src'
    New-Item -ItemType Directory -Path $srcDir | Out-Null
    Set-Content (Join-Path $srcDir 'Rename-Pc.ps1') 'exit 0'
    Set-Content (Join-Path $srcDir 'helper.txt') 'data'
    $imp = ConvertTo-TaskDefinition -Name 'Rename' -Json ([pscustomobject]@{ script = 'Rename-Pc.ps1' })
    Save-Task -ContentRoot $root -Definition $imp -Source $srcDir -New | Out-Null
    Assert-Equal (Test-Path (Join-Path $taskRoot 'Rename/helper.txt')) $true 'a folder import copies the files the script needs'
    Assert-Throws { Save-Task -ContentRoot $root -Definition (ConvertTo-TaskDefinition -Name 'Nope' -Json @{ script = 'missing.ps1' }) -New } '*missing.ps1 is not in*' 'a task without its script is refused'
    Assert-Equal (Test-Path (Join-Path $taskRoot 'Nope')) $false 'a refused new task leaves no folder behind'

    # How tasks are launched.
    $l = Get-TaskLaunch -Definition $d -Folder 'C:\Temp\Tasks\Wallpaper' -ExtraArguments '-Path X.jpg'
    Assert-Equal "$($l.FilePath) $($l.Arguments)" 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Temp\Tasks\Wallpaper\set.ps1" -Path X.jpg' 'a .ps1 runs with powershell -File and the answer file arguments'
    $l = Get-TaskLaunch -Definition $c -Folder 'W:\x\Cleanup\'
    Assert-Equal "$($l.FilePath) $($l.Arguments)" 'cmd.exe /c ""W:\x\Cleanup\clean.cmd" /q"' 'a .cmd runs with cmd /c and its own arguments'
    $exe = ConvertTo-TaskDefinition -Name 'Tool' -Json @{ script = 'tool.exe'; arguments = '/s' }
    Assert-Equal (Get-TaskCommandLine -Definition $exe -Folder 'C:\Program Data\T') '"C:\Program Data\T\tool.exe" /s' 'an .exe path with spaces is quoted in a command line'
    Assert-Equal (Get-LogonTaskFolder 'Wallpaper') 'C:\ProgramData\ImagingTool\Tasks\Wallpaper' 'FIRSTLOGON tasks live under ProgramData'

    # Answer files: script tasks round-trip, mixed with plain commands, in order.
    $path = Join-Path $root 'AnswerFiles/Default.xml'
    $a = Read-AnswerFile -Path $path -SkipValidation
    Assert-Equal $a.TaskLocation 'Tasks' 'answer files read the task library location'
    $a.Tasks = @(
        [pscustomobject]@{ Phase = 'POSTIMAGE'; Script = 'Cleanup'; Command = '' }
        [pscustomobject]@{ Phase = 'FIRSTBOOT'; Script = ''; Command = 'echo hi' }
        [pscustomobject]@{ Phase = 'FIRSTBOOT'; Script = 'Wallpaper'; Command = '-Path X.jpg' }
        [pscustomobject]@{ Phase = 'FIRSTLOGON'; Script = 'Rename'; Command = '' }
        [pscustomobject]@{ Phase = 'FIRSTLOGON'; Script = ''; Command = 'logon.cmd' }
    )
    Export-AnswerFile -Answer $a -Path $path
    $b = Read-AnswerFile -Path $path -SkipValidation
    Assert-Equal (($b.Tasks | ForEach-Object { "$($_.Phase):$($_.Script):$($_.Command)" }) -join '|') 'POSTIMAGE:Cleanup:|FIRSTBOOT::echo hi|FIRSTBOOT:Wallpaper:-Path X.jpg|FIRSTLOGON:Rename:|FIRSTLOGON::logon.cmd' 'script tasks and commands keep their order'
    Assert-Equal @(Test-AnswerFile $b | Where-Object { $_ -like '*task*' }).Count 0 'a script task needs no command'
    $b.Tasks[0].Script = 'bad name'
    Assert-Equal @(Test-AnswerFile $b | Where-Object { $_ -like "*isn't a task library name*" }).Count 1 'a bad task name is caught'
    $b.Tasks[0].Script = 'Cleanup'

    # Usage, the Tasks tab list, and delete.
    $rows = @(Get-TaskList -ContentRoot $root)
    Assert-Equal (($rows | ForEach-Object Name) -join ',') 'Cleanup,Rename,Wallpaper' 'the Tasks tab lists every task'
    $cleanup = $rows | Where-Object Name -eq 'Cleanup'
    Assert-Equal "$($cleanup.Phase)|$($cleanup.For)|$($cleanup.UsedBy)|$($cleanup.Status)" 'POSTIMAGE|Dell|Default|Ready' 'a row shows when it runs, which PCs and who uses it'
    Assert-Throws { Remove-LibraryItem -Kind Task -ContentRoot $root -Name 'Cleanup' } '*still in these answer files: Default*' 'a task in use cannot be deleted'
    Assert-Equal @(Get-AnswerFileIssues -ContentRoot $root -Answer $b | Where-Object { $_ -like 'Task *' }).Count 0 'existing tasks raise no answer file issue'

    # What the deploy runs: library tasks read, other makers' tasks left out, missing ones stop before the erase.
    $skipped = @()
    $hp = [pscustomobject]@{ Maker = 'HP'; Model = 'EliteBook 840'; MachineType = '' }
    $plan = @(Resolve-DeployTasks -Answer $b -TaskRoot $taskRoot -Identity $hp -OnSkip { param($m) $script:skipped += $m })
    Assert-Equal (($plan | ForEach-Object Name) -join '|') 'echo hi|Wallpaper|Rename|logon.cmd' 'the Dell-only task is left out on an HP'
    Assert-Equal $skipped.Count 1 'the skipped task is reported'
    $dell = [pscustomobject]@{ Maker = 'Dell'; Model = 'Latitude 5521'; MachineType = '' }
    $plan = @(Resolve-DeployTasks -Answer $b -TaskRoot $taskRoot -Identity $dell)
    Assert-Equal $plan.Count 5 'every task runs on a Dell'
    Assert-Equal "$($plan[2].Arguments)|$($plan[2].Definition.script)" '-Path X.jpg|set.ps1' 'a library task carries its answer file arguments'

    $fb = New-FirstBootPlan -Answer $b -Tasks $plan
    Assert-Equal (($fb.tasks | ForEach-Object { "$($_.task.type):$($_.name)" }) -join '|') 'command:echo hi|powershell:Wallpaper' 'first boot gets the FIRSTBOOT commands and tasks in order, each with a definition'
    $echo = $plan | Where-Object Command -eq 'echo hi'
    Assert-Equal "$($echo.Definition.type)|$($echo.Definition.successCodes -join ',')|$($echo.Definition.stopOnFailure)|$($echo.Folder)" 'command|0|True|' 'a plain command is a task definition too: exit 0, stops a POSTIMAGE deploy, no folder'
    Assert-Equal ((Get-TaskLaunch -Definition $echo.Definition) | ForEach-Object { "$($_.FilePath) $($_.Arguments)" }) 'cmd.exe /c echo hi' 'a plain command runs with cmd /c'
    Assert-Equal (Get-TaskLogName 'copy "C:\a b\x.txt" D:\' ) 'Task-copy _C_a b_x.txt_ D_.log' 'a plain command makes a safe log name'
    Assert-Equal (Get-TaskLogName 'Wallpaper' -Suffix 'pat') 'Task-Wallpaper-pat.log' 'a library task keeps its name in the log name'
    $fbJson = $fb | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $again = ConvertTo-TaskDefinition -Name $fbJson.tasks[1].name -Json $fbJson.tasks[1].task
    Assert-Equal "$($again.script)|$($again.type)|$($fbJson.tasks[1].arguments)" 'set.ps1|powershell|-Path X.jpg' 'FirstBoot.ps1 can rebuild the task from firstboot.json'
    Assert-Equal @((New-FirstBootPlan -Answer $b).tasks).Count 1 'without resolved tasks only plain commands go in the plan'

    $logon = @($plan | Where-Object Phase -eq 'FIRSTLOGON' | ForEach-Object {
        Get-TaskCommandLine -Definition $_.Definition -Folder (Get-LogonTaskFolder $_.Name) -ExtraArguments $_.Arguments
    })
    [xml]$u = New-UnattendXml -Answer $b -ComputerName 'PC-01' -LogonCommands $logon
    $ns = [Xml.XmlNamespaceManager]::new($u.NameTable); $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $cmds = @($u.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine', $ns) | ForEach-Object InnerText)
    Assert-Equal ($cmds -join '|') 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\ImagingTool\Tasks\Rename\Rename-Pc.ps1"|cmd.exe /c logon.cmd' 'FIRSTLOGON tasks run from ProgramData, in order with commands'
    [xml]$u2 = New-UnattendXml -Answer $b -ComputerName 'PC-01'
    Assert-Equal (@($u2.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand', $ns)).Count) 1 'without resolved tasks a script task is not written as a command'

    $b.Tasks += [pscustomobject]@{ Phase = 'FIRSTBOOT'; Script = 'Gone'; Command = '' }
    Assert-Throws { Resolve-DeployTasks -Answer $b -TaskRoot $taskRoot -Identity $dell } "*Task 'Gone' has no task.json*" 'a missing task stops the deploy before the disk is erased'
    Assert-Equal @(Get-AnswerFileIssues -ContentRoot $root -Answer $b | Where-Object { $_ -like 'Task Gone:*' }).Count 1 'the console shows the missing task'

    # USB sticks get the task library with the answer files.
    Set-Content (Join-Path $root 'Images/Win11-Enterprise.wim') 'wim'
    $m = Get-MediaContent -ContentRoot $root
    Assert-Equal ('Tasks' -in $m.Folders) $true 'the Tasks folder goes on the stick'

    # FIRSTLOGON library tasks go through Run-LogonTask.ps1 with their own entry in logon-tasks.json.
    $logonPlan = @(New-LogonTaskPlan -Tasks $plan)
    Assert-Equal (($logonPlan | ForEach-Object name) -join ',') 'Rename,logon.cmd' 'logon-tasks.json holds every FIRSTLOGON task, plain commands too'
    $deployText = Get-Content -Raw (Join-Path $repo 'src/Deploy-Image.ps1')
    Assert-Equal ($deployText.Contains('for ($i = 0; $i -lt $logonCount; $i++) { Get-LogonTaskCommand -Index $i }')) $true 'every FIRSTLOGON task goes through Run-LogonTask.ps1'
    Assert-Equal ($deployText -match "'Run-LogonTask\.ps1'\), \(Join-Path \`$PSScriptRoot 'TaskPack\.psm1'\), \(Join-Path \`$PSScriptRoot 'LibraryPack\.psm1'\) \`$logonDir") $true 'the logon runner gets LibraryPack.psm1, which TaskPack.psm1 imports'
    Assert-Equal ($deployText.Contains("Invoke-Native -FilePath 'cmd.exe' -ArgumentList @('/c', `$t.Command)")) $false 'POSTIMAGE commands run through Invoke-TaskPack too'
    Assert-Equal (Get-LogonTaskCommand -Index 0) 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\ProgramData\ImagingTool\Tasks\Run-LogonTask.ps1" -Index 0' 'a logon task runs through Run-LogonTask.ps1'
    $runner = Get-Content -Raw (Join-Path $repo 'src/Run-LogonTask.ps1')
    Assert-Equal ($runner -match '\$all = Get-Content' -and $runner.Contains('Get-TaskLogName $def.name -Suffix $env:USERNAME')) $true 'the logon runner reads the plan safely in 5.1 and logs per user'
    $runnerErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($runner, [ref]$null, [ref]$runnerErrors)
    Assert-Equal @($runnerErrors).Count 0 'the logon runner parses'

    # The deploy summary names the tasks.
    Import-Module (Join-Path $repo 'src/DeployWizard.psm1') -Force
    $sum = @(Get-DeploySummary -Answer $b -Plan ([pscustomobject]@{ ImagePath = 'x.wim'; DriverPack = $null }) -ComputerName 'PC1' -Disk ([pscustomobject]@{ Number = 0; FriendlyName = 'SSD'; Size = 256GB; BusType = 'NVMe' }))
    Assert-Equal (@($sum | Where-Object { $_ -like 'Tasks:*' }) -join '') 'Tasks:        Cleanup (POSTIMAGE), Wallpaper (FIRSTBOOT), Rename (FIRSTLOGON), Gone (FIRSTBOOT), 2 commands' 'the summary lists library tasks and counts commands'

    # FIRSTBOOT task results become post-deploy checks; plain commands don't.
    Import-Module (Join-Path $repo 'src/PostDeployChecks.psm1') -Force
    $checks = (Invoke-PostDeployCheck -Plan ([pscustomobject]@{ applications = @() }) -Facts ([pscustomobject]@{ ComputerName = 'PC1' }) -TaskResults @(
        [pscustomobject]@{ name = 'echo hi'; status = 'Ran'; ok = $true; exitCode = 0; message = 'exit 0' }
        [pscustomobject]@{ name = 'Wallpaper'; status = 'Succeeded'; ok = $true; exitCode = 0; message = 'exit 0' }
        [pscustomobject]@{ name = 'Cleanup'; status = 'Failed'; ok = $false; exitCode = 2; message = 'exit code 2 is not a success code (0)' }))
    Assert-Equal (($checks | Where-Object name -like 'Task:*' | ForEach-Object { "$($_.name)=$($_.result)" }) -join '|') 'Task: Wallpaper=Passed|Task: Cleanup=Failed' 'library tasks are checked, commands are not'
    Assert-Equal (($checks | Where-Object name -eq 'Task: Cleanup').detail -like '*Task-Cleanup.log*') $true 'a failed task check points to its log'

    # Templates: each one makes a valid task whose PowerShell parses; placeholders must be replaced before saving.
    foreach ($tpl in Get-TaskTemplates) {
        $made = New-TaskFromTemplate -Template $tpl
        $problems = @(Test-TaskPack -Definition $made.Definition | Where-Object { $_ -notlike 'Replace REPLACE_*' })
        Assert-Equal ($problems -join '; ') '' "template $($tpl.name) is valid"
        if ($made.Definition.type -eq 'powershell') {
            $pe = $null; [void][Management.Automation.Language.Parser]::ParseInput($made.ScriptText, [ref]$null, [ref]$pe)
            Assert-Equal @($pe).Count 0 "template $($tpl.name) parses"
        }
        Assert-Equal ($made.ScriptText -match '[^\x00-\x7F]') $false "template $($tpl.name) is ASCII"
    }
    $logs = New-TaskFromTemplate -Template (Get-TaskTemplates | Where-Object name -eq 'Copy-DeployLogs')
    Assert-Equal @(Test-TaskPack -Definition $logs.Definition | Where-Object { $_ -like '*REPLACE_SHARE*' }).Count 1 'a template placeholder blocks saving until replaced'

    # Task logs go straight in C:\Windows\Temp, next to Deploy.log and FirstBoot.log, not in a subfolder.
    # (C:\Temp\Tasks, without Windows, is where FIRSTBOOT tasks are staged.)
    foreach ($f in 'FirstBoot.ps1', 'Deploy-Image.ps1') {
        $text = Get-Content -Raw (Join-Path $repo "src/$f")
        Assert-Equal ($text -match 'Temp\\\$(\(Get-TaskLogName|logName)' -and $text -notmatch '\\Windows\\Temp\\Tasks\\') $true "$f logs tasks to C:\Windows\Temp\Task-<name>.log"
    }

    # Running tasks for real needs Windows (powershell.exe, cmd.exe).
    if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
        $logDir = Join-Path $root 'logs'
        $ok = Invoke-TaskPack -Definition $d -Folder (Join-Path $taskRoot 'Wallpaper') -LogPath (Join-Path $logDir 'Wallpaper.log') -Log { param($m) }
        Assert-Equal "$($ok.Status)|$($ok.ExitCode)" 'Succeeded|0' 'a PowerShell task runs and succeeds'
        Assert-Equal ((Get-Content -Raw (Join-Path $logDir 'Wallpaper.log')) -like "*caf$([char]0xE9)*") $true 'its output is in its log, accents included'
        $failing = ConvertTo-TaskDefinition -Name 'Fails' -Json @{ script = 'fail.cmd' }
        Save-Task -ContentRoot $root -Definition $failing -ScriptText "@echo off`necho something broke`nexit /b 3" -New | Out-Null
        $r = Invoke-TaskPack -Definition $failing -Folder (Join-Path $taskRoot 'Fails') -ExtraArguments 'one two' -LogPath (Join-Path $logDir 'Fails.log') -Log { param($m) }
        Assert-Equal "$($r.Status)|$($r.ExitCode)" 'Failed|3' 'a cmd task with a non-success exit code fails'
        Assert-Equal ($r.Message -like '*something broke*') $true 'the failure message shows the last output line'
    } else {
        Write-Host 'SKIP running tasks: needs Windows' -ForegroundColor Yellow
    }
} finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-Tests 'All task library checks passed.'
