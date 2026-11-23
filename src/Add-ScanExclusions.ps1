<#
.SYNOPSIS
    Adds the tool's own build folders to Microsoft Defender's folder exclusions, so builds and captures are faster.
.DESCRIPTION
    The admin console runs this hidden, as administrator, when it starts (since 2026-11-20, so the admin has nothing to
    click). It is a separate script on purpose: on 2026-11-13 Defender blocked a module of
    this tool for changing its settings, and the console could not start. If Defender blocks this file, only this
    step fails and the console shows the folders to add by hand.
    Rules: folders only (the console passes the WinPE work folder, the WinPE build cache and the Images folder), never
    a program, a file type or a drive root, and it never removes an exclusion.
    Writes a JSON result for the console: Ok, NoDefender, Added, Message (one short line), and details to the log.
    PowerShell 5.1 compatible.
#>
param(
    [Parameter(Mandatory)][string[]]$Folder,      # folders, or one string of folders joined with |
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'

Import-Module ([IO.Path]::Combine($PSScriptRoot, 'ScriptLog.psm1')) -Force
function Write-Log([string]$Message) { Write-ScriptLog -Path $LogPath -Message $Message }

function Get-FolderKey([string]$Path) { "$Path".Trim().TrimEnd('\').ToLowerInvariant() }

function Get-CurrentExclusions {
    # Defender's folder exclusions, or $null when it can't say (not running, or the list is hidden from this user).
    $list = @((Get-MpPreference).ExclusionPath | Where-Object { $_ })
    if ($list | Where-Object { $_ -like 'N/A*' }) { return $null }
    @($list | ForEach-Object { Get-FolderKey $_ })
}

function Get-ShortReason([string]$Text) {
    # One line for the console; the full error is in the log.
    if ($Text -match '0x800106ba|service.*not running|not running') { return 'Microsoft Defender is not running on this PC' }
    if ($Text -match '0x80070005|Access is denied|denied') { return 'Windows refused the change (Tamper Protection or a policy)' }
    if ($Text -match '0x80070032|not supported') { return 'this Windows edition does not allow it' }
    ($Text -split "`r?`n")[0]
}

# -File passes each argument as one string, so the console sends the folders joined with |.
$folders = @($Folder | ForEach-Object { "$_" -split '\|' } | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().TrimEnd('\') } |
    Where-Object { $_ -notmatch '^[A-Za-z]:$' -and $_ -notmatch '\.exe$' } | Select-Object -Unique)
$result = [ordered]@{ Ok = $false; NoDefender = $false; Added = @(); Message = '' }

try {
    Write-Log "Folders to exclude from Microsoft Defender scans: $($folders -join '; ')"
    if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) {
        $result.NoDefender = $true; $result.Ok = $true
        $result.Message = 'Microsoft Defender is not on this PC; nothing to add.'
        Write-Log $result.Message
    }
    else {
        $have = $null
        try { $have = Get-CurrentExclusions }
        catch {
            if ($_.Exception.Message -match '0x800106ba|not running') {
                # Another antivirus is in charge: Defender's exclusions would do nothing.
                $result.NoDefender = $true; $result.Ok = $true
                $result.Message = 'Microsoft Defender is not running on this PC; nothing to add.'
                Write-Log "$($result.Message) ($($_.Exception.Message))"
            }
            else { throw }
        }
        if (-not $result.NoDefender) {
            $missing = @($folders | Where-Object { $null -eq $have -or ($have -notcontains (Get-FolderKey $_)) })
            if ($missing.Count) {
                Write-Log "Adding: $($missing -join '; ')"
                Add-MpPreference -ExclusionPath $missing
            }
            else { Write-Log 'All folders were already excluded.' }
            $after = Get-CurrentExclusions
            $notKept = @(if ($null -ne $after) { $folders | Where-Object { $after -notcontains (Get-FolderKey $_) } })
            if ($notKept.Count) {
                # Add-MpPreference can succeed while a policy (Group Policy, Intune) or Tamper Protection drops them.
                $result.Message = 'Windows did not keep them (Tamper Protection or a policy)'
                Write-Log "Not in the exclusion list after adding: $($notKept -join '; ')"
            }
            else {
                $result.Ok = $true
                $result.Added = @($missing)
                $result.Message = if ($missing.Count) { "Added $($missing.Count) folder(s)." } else { 'Already in place.' }
                Write-Log $result.Message
            }
        }
    }
}
catch {
    $result.Ok = $false
    $result.Message = Get-ShortReason $_.Exception.Message
    Write-Log "Failed: $($_.Exception.Message)"
}

try {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ResultPath))
    [IO.File]::WriteAllText($ResultPath, ([pscustomobject]$result | ConvertTo-Json -Depth 3))
} catch { Write-Log "Could not write the result: $($_.Exception.Message)" }
if ($result.Ok) { exit 0 } else { exit 1 }
