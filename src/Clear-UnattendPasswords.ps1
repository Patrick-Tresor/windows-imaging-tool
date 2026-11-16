<#
.SYNOPSIS
    Removes the passwords from the unattend.xml copies Windows keeps on the deployed PC, once Windows setup is done.
.DESCRIPTION
    Deploy-Image.ps1 writes C:\Windows\Panther\unattend.xml with the join account, local Administrator and other
    passwords. OOBE still reads it after first boot (deleting it early made OOBE ask for a local account on the Dell
    5521), and Windows Setup is not relied on to blank them. So this runs as SYSTEM from the ImagingTool\ClearUnattend
    task at each logon (FirstBoot.ps1 creates it), waits until setup and OOBE are over, replaces every password value
    with *removed* in each copy, logs to C:\Windows\Temp\FirstBoot.log, then deletes the task and itself.
    Deploy-Image.ps1 stages it in C:\ProgramData\ImagingTool, for Administrators and SYSTEM only.
    No DeployCommon here: this runs on the deployed PC. PowerShell 5.1 compatible.
#>
param(
    [string[]]$Path = @(
        "$env:WINDIR\Panther\unattend.xml",
        "$env:WINDIR\Panther\Unattend\unattend.xml",
        "$env:WINDIR\System32\Sysprep\unattend.xml"
    ),
    [string]$LogPath = "$env:WINDIR\Temp\FirstBoot.log",
    [string]$TaskName = 'ImagingTool\ClearUnattend',
    [int]$WaitMinutes = 360,
    [switch]$NoWait,       # tests: don't wait for setup
    [switch]$KeepTask
)
$ErrorActionPreference = 'Continue'
function Write-Log([string]$Message) {
    try { Add-Content -Path $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) } catch { }
}

function Remove-UnattendPasswordText([string]$Text) {
    # Every <Value> and <Password> element (local accounts, AutoLogon, AdministratorPassword, domain join Credentials)
    # keeps its tags and loses its content. Returns the new text and how many were changed.
    $found = [regex]::Matches($Text, '(?s)<(Value|Password)(\s[^>]*)?>(.*?)</\1>') | Where-Object { $_.Groups[3].Value -ne '*removed*' }
    $new = [regex]::Replace($Text, '(?s)(<(Value|Password)(\s[^>]*)?>)(.*?)(</\2>)', '$1*removed*$5')
    [pscustomobject]@{ Text = $new; Count = @($found).Count }
}

if (-not $NoWait) {
    # A logon during OOBE (defaultuser0) starts this too early: OOBE still needs the passwords.
    $deadline = (Get-Date).AddMinutes($WaitMinutes)
    while ((Get-Date) -lt $deadline) {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        if (-not $setup -or (-not $setup.SystemSetupInProgress -and -not $setup.OOBEInProgress)) { break }
        Start-Sleep -Seconds 30
    }
    $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
    if ($setup -and ($setup.SystemSetupInProgress -or $setup.OOBEInProgress)) {
        Write-Log 'unattend.xml passwords: Windows setup is still running; the next logon tries again'
        exit 0
    }
}

$failed = $false
foreach ($p in $Path) {
    if (-not [IO.File]::Exists($p)) { continue }
    try {
        $text = [IO.File]::ReadAllText($p)
        $r = Remove-UnattendPasswordText $text
        if ($r.Count) {
            [IO.File]::WriteAllText($p, $r.Text, (New-Object Text.UTF8Encoding($false)))
            Write-Log "unattend.xml passwords: removed $($r.Count) from $p"
        } else {
            Write-Log "unattend.xml passwords: none left in $p"
        }
    } catch {
        $failed = $true
        Write-Log "unattend.xml passwords: could not clean $p ($($_.Exception.Message)); the next logon tries again"
    }
}
if ($failed -or $KeepTask) { exit 0 }
& schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
Write-Log "unattend.xml passwords: task $TaskName removed (exit $LASTEXITCODE)"
Start-Process -FilePath cmd.exe -ArgumentList "/c timeout /t 5 >nul & del /f /q `"$PSCommandPath`"" -WindowStyle Hidden
