# Sysprep at deploy time: an image captured from a VM that was only shut down, not sysprepped, is generalized by
# each PC at its first start. WinPE (Deploy-Image.ps1) sets a one-time startup command in the new Windows'
# offline registry; that command (Invoke-SysprepAtDeploy.ps1) runs the reference checks and sysprep /generalize
# /oobe /reboot with the deploy's answer file, and the PC then goes through Windows setup as with a sysprepped image.
# Pure helpers are unit-tested (tests\SysprepAtDeploy.Tests.ps1); the registry writes run in WinPE or on the PC.
# .NET file calls, not Join-Path/Test-Path: in WinPE a volume can have no PowerShell drive.

$script:Folder = 'C:\ProgramData\ImagingTool\Sysprep'

function Get-SysprepAtDeployFolder { $script:Folder }

function Test-HibernatedWindows {
    <#
    .SYNOPSIS
        True when the Windows at $Root was hibernated, not shut down: Fast Startup ("Shut down" from the Start menu)
        writes the kernel's memory to hiberfil.sys and marks it 'hibr'. Its disk is then not a clean copy to deploy
        without sysprep; 'shutdown /s /t 0' in the VM shuts it down fully. A resumed or empty hiberfil.sys is fine.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $path = [IO.Path]::Combine($Root, 'hiberfil.sys')
    if (-not [IO.File]::Exists($path)) { return $false }
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $bytes = New-Object byte[] 4
            if ($stream.Read($bytes, 0, 4) -ne 4) { return $false }
        } finally { $stream.Dispose() }
        [Text.Encoding]::ASCII.GetString($bytes) -ieq 'hibr'
    } catch { $false }
}

function Get-SysprepHookCommand {
    # What Windows runs at its first start, before the logon screen (HKLM\SYSTEM\Setup CmdLine is REG_SZ, so no
    # environment variables: the deployed Windows is always on C:).
    param([string]$Folder = $script:Folder)
    "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Folder\Invoke-SysprepAtDeploy.ps1`" -Stage Hook"
}

function Get-SysprepHookRegArgs {
    <#
    .SYNOPSIS
        reg.exe argument lists that make the Windows whose SYSTEM hive is loaded at $HiveKey run $Command once at
        its next start: SetupType 2 makes winlogon run Setup\CmdLine as SYSTEM before the logon screen (the hook
        sets it back to 0 first thing). With -PreventDeviceEncryption, Windows does not start device encryption
        during that boot, since sysprep refuses an encrypted disk; the hook removes the value again before sysprep.
    #>
    param(
        [Parameter(Mandatory)][string]$HiveKey,
        [Parameter(Mandatory)][string]$Command,
        [string]$ControlSet,
        [switch]$PreventDeviceEncryption
    )
    $list = New-Object Collections.ArrayList
    [void]$list.Add(@('add', "$HiveKey\Setup", '/v', 'SetupType', '/t', 'REG_DWORD', '/d', '2', '/f'))
    [void]$list.Add(@('add', "$HiveKey\Setup", '/v', 'CmdLine', '/t', 'REG_SZ', '/d', $Command, '/f'))
    if ($PreventDeviceEncryption -and $ControlSet) {
        [void]$list.Add(@('add', "$HiveKey\$ControlSet\Control\BitLocker", '/v', 'PreventDeviceEncryption', '/t', 'REG_DWORD', '/d', '1', '/f'))
    }
    $list.ToArray()   # one argument list per write: the pipeline unrolls only this outer array
}

function Get-ControlSetName {
    # 'ControlSet001' from reg.exe's query of <hive>\Select /v Current (REG_DWORD 0x1); ControlSet001 when unreadable.
    param([string[]]$Lines)
    foreach ($l in @($Lines)) {
        if ($l -match '^\s*Current\s+REG_DWORD\s+0x([0-9a-fA-F]+)') { return 'ControlSet{0:D3}' -f [Convert]::ToInt32($Matches[1], 16) }
    }
    'ControlSet001'
}

function Test-RegQueryHasValue {
    # True when reg.exe query output lists the value $Name.
    param([string[]]$Lines, [Parameter(Mandatory)][string]$Name)
    [bool](@($Lines) | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s+REG_" })
}

function Get-SysprepArguments {
    # sysprep's command line for a deployed PC: generalize, back to OOBE with the deploy's answer file, restart.
    param([Parameter(Mandatory)][string]$UnattendPath)
    @('/generalize', '/oobe', '/reboot', '/quiet', "/unattend:$UnattendPath")
}

function Test-RebootPendingFor {
    # Whether a restart should come before sysprep: Windows servicing or Windows Update waiting for one, while
    # the attempts so far leave room (each restart counts one, up to $MaxAttempts).
    param([bool]$Pending, [int]$Attempt, [int]$MaxAttempts = 3)
    $Pending -and $Attempt -lt $MaxAttempts
}

function Get-SysprepOutcome {
    <#
    .SYNOPSIS
        What happened after sysprep returned: Ok when Windows is now generalized (the restart is on its way),
        otherwise a one-line reason from sysprep's exit code and its last SYSPRP error line.
    #>
    param([string]$ImageState, [int]$ExitCode, [string[]]$ErrorLines)
    if ($ImageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { return [pscustomobject]@{ Ok = $true; Reason = '' } }
    $last = @(@($ErrorLines) | Where-Object { $_ -match '\bSYSPRP\b' }) | Select-Object -Last 1
    $reason = "sysprep exited with code $ExitCode and Windows is still $(if ($ImageState) { $ImageState } else { 'not generalized' })."
    if ($last) { $reason += " Last error: $($last.Trim())" }
    [pscustomobject]@{ Ok = $false; Reason = $reason }
}

function Get-SysprepFailureNotice {
    # The message the logon screen shows on a PC where sysprep failed, so whoever turns it on sees it. Short:
    # the details are in the log.
    param([Parameter(Mandatory)][string]$Reason, [string]$LogPath = 'C:\Windows\Temp\SysprepAtDeploy.log')
    $first = (@("$Reason" -split "`r?`n" | Where-Object { $_.Trim() })[0])
    if ($first.Length -gt 300) { $first = $first.Substring(0, 297) + '...' }
    [pscustomobject]@{
        Caption = 'Deployment not finished: sysprep failed'
        Text    = "This PC is still a copy of the reference VM. $first Details: $LogPath. Fix the reference VM (or sysprep it there), capture it again and redeploy this PC."
    }
}

function Get-SysprepWaitMinutes { 45 }

function Test-SysprepHookDone {
    # Whether the hook can stop waiting for the Run stage: it finished, failed, or Windows is restarting.
    param([string]$State)
    $State -in 'done', 'failed', 'restart'
}

Export-ModuleMember -Function Get-SysprepAtDeployFolder, Test-HibernatedWindows, Get-SysprepHookCommand, Get-SysprepHookRegArgs,
    Get-ControlSetName, Test-RegQueryHasValue, Get-SysprepArguments, Test-RebootPendingFor, Get-SysprepOutcome,
    Get-SysprepFailureNotice, Get-SysprepWaitMinutes, Test-SysprepHookDone
