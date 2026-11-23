# One log line writer for the scripts that run on their own (FirstBoot.ps1, Clear-UnattendPasswords.ps1,
# Invoke-SysprepAtDeploy.ps1 on the deployed PC, Add-ScanExclusions.ps1 on the console PC). Each is staged with
# this file next to it. Never throws: a log that can't be written must not stop the work. PowerShell 5.1 compatible.

function Write-ScriptLog {
    # Appends "yyyy-MM-dd HH:mm:ss <Prefix><Message>" to $Path (UTF-8), making its folder when needed.
    param([string]$Path, [AllowEmptyString()][string]$Message, [string]$Prefix)
    if (-not $Path) { return }
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        [IO.File]::AppendAllText($Path, ('{0:yyyy-MM-dd HH:mm:ss} {1}{2}' -f (Get-Date), $Prefix, $Message) + [Environment]::NewLine)
    } catch { }
}

Export-ModuleMember -Function Write-ScriptLog
