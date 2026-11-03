<#
.SYNOPSIS
    Runs one FIRSTLOGON task from the task library when the first user logs on (unattend FirstLogonCommands).
.DESCRIPTION
    Deploy-Image.ps1 copies this, TaskPack.psm1, logon-tasks.json and each task's folder to
    C:\ProgramData\ImagingTool\Tasks. Runs as the user who logs on, with the task's timeout and success codes,
    and logs to C:\Windows\Temp\Task-<name>-<user>.log (the user's %TEMP% when that folder can't be written).
#>
param([Parameter(Mandatory)][int]$Index)
$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'TaskPack.psm1') -Force
# Assigned first: Windows PowerShell 5.1's ConvertFrom-Json writes a JSON array as one object, so @(...) around
# the pipeline would wrap it again.
$all = Get-Content -Raw (Join-Path $PSScriptRoot 'logon-tasks.json') | ConvertFrom-Json
$t = @($all)[$Index]
$def = ConvertTo-TaskDefinition -Name $t.name -Json $t.task
$log = "$env:WINDIR\Temp\Task-$($def.name)-$($env:USERNAME).log"
try { [IO.File]::AppendAllText($log, '') } catch { $log = Join-Path $env:TEMP "Task-$($def.name).log" }
$r = try { Invoke-TaskPack -Definition $def -Folder (Join-Path $PSScriptRoot $def.name) -ExtraArguments $t.arguments -LogPath $log -Log { param($m) } }
     catch { [pscustomobject]@{ Status = 'Failed'; ExitCode = $null; Message = $_.Exception.Message } }
Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}: {2}' -f (Get-Date), $r.Status, $r.Message) -Encoding UTF8 -ErrorAction SilentlyContinue
exit $(if ($r.Status -eq 'Succeeded') { 0 } else { 1 })
