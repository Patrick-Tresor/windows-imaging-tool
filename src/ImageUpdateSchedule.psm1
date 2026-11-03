# Monthly offline patching of golden images, run by a scheduled task on the admin PC (Register-ImageUpdateSchedule).
# Each day the task runs Invoke-ScheduledImageUpdate.ps1, which does nothing until Patch Tuesday plus a few days,
# then applies, once that month, the .msu/.cab files in the content root's Updates folder that an image has not
# had yet (Update-OfflineImage.ps1, which keeps the previous version). Settings: config\image-update-schedule.json.
# PowerShell 5.1 compatible.

Import-Module (Join-Path $PSScriptRoot 'Console\ConsoleData.psm1')

function Get-PatchTuesday {
    # The second Tuesday of the month, when Microsoft releases its monthly updates.
    param([Parameter(Mandatory)][int]$Year, [Parameter(Mandatory)][int]$Month)
    $first = [datetime]::new($Year, $Month, 1)
    $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
    $first.AddDays($offset + 7)
}

function Test-ImageUpdateDue {
    <#
    .SYNOPSIS
        True on or after Patch Tuesday + DaysAfter when this month has not run yet (LastRun 'yyyy-MM'). A PC that
        was off on the day catches up the next day the task runs.
    #>
    param([datetime]$Now = (Get-Date), [int]$DaysAfter = 1, [string]$LastRun)
    $month = $Now.ToString('yyyy-MM')
    if ($LastRun -eq $month) { return $false }
    $Now.Date -ge (Get-PatchTuesday -Year $Now.Year -Month $Now.Month).AddDays($DaysAfter).Date
}

function Get-ImageUpdateSchedule {
    # config\image-update-schedule.json, or the defaults (off).
    param([Parameter(Mandatory)][string]$ContentRoot)
    $path = Join-Path $ContentRoot ('config\image-update-schedule.json' -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
    $s = [ordered]@{ enabled = $false; images = @(); updateFolder = 'Updates'; daysAfterPatchTuesday = 1; cleanup = $true; time = '03:00'; lastRun = '' }
    if (Test-Path -LiteralPath $path) {
        $j = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $s[$p.Name] = $p.Value }
    }
    $s.images = @($s.images | Where-Object { $_ })
    [pscustomobject]$s
}

function Save-ImageUpdateSchedule {
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)]$Schedule)
    $path = Join-Path $ContentRoot ('config\image-update-schedule.json' -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)
    $o = [ordered]@{}
    foreach ($p in $Schedule.PSObject.Properties) { $o[$p.Name] = $p.Value }
    $o.images = @($o.images)
    [pscustomobject]$o | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding utf8
}

function Get-PendingImageUpdates {
    <#
    .SYNOPSIS
        The update files for one image that it has not had yet, in the order to apply them: Updates\<image name>\
        when that folder exists (images of different Windows versions need different files), else Updates\.
        Applied = named in the image's <name>.updates.json history.
    #>
    param([Parameter(Mandatory)][string]$ContentRoot, [Parameter(Mandatory)][string]$ImagePath, [string]$UpdateFolder = 'Updates', [object[]]$History)
    $base = [IO.Path]::GetFileNameWithoutExtension($ImagePath)
    $root = Join-Path $ContentRoot $UpdateFolder
    $own = Join-Path $root $base
    $folder = if (Test-Path -LiteralPath $own -PathType Container) { $own } else { $root }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @() }
    if ($null -eq $History) { $History = @(Get-ImageServicingHistory -ImagePath $ImagePath) }
    $done = @{}
    foreach ($h in @($History)) { foreach ($p in @($h.packages)) { if ($p.package) { $done[(Split-Path "$($p.package)" -Leaf).ToLowerInvariant()] = $true } } }
    @(Get-UpdatePackageRows -Path @($folder) | Where-Object { -not $done.ContainsKey($_.Name.ToLowerInvariant()) })
}

function Register-ImageUpdateSchedule {
    # The scheduled task on this PC: daily at Time as SYSTEM (DISM needs admin rights), with the check in the script.
    param([Parameter(Mandatory)][string]$ContentRoot, [string]$Time = '03:00', [string]$TaskName = 'Imaging - monthly image update')
    $script = Join-Path $PSScriptRoot 'Invoke-ScheduledImageUpdate.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"$script`" -ContentRoot `"$ContentRoot`"")
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($Time, 'HH:mm', $null))
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

function Unregister-ImageUpdateSchedule {
    param([string]$TaskName = 'Imaging - monthly image update')
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-PatchTuesday, Test-ImageUpdateDue, Get-ImageUpdateSchedule, Save-ImageUpdateSchedule, Get-PendingImageUpdates, Register-ImageUpdateSchedule, Unregister-ImageUpdateSchedule
