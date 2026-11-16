# Saving JSON files the same way everywhere. Used by the console, the media build, the capture and WinPE; the
# modules that run on the deployed PC (DeployStatus, FirstBootState, AppPack, TaskPack...) do not depend on it,
# because only the files Deploy-Image.ps1 copies reach the PC.

function Save-JsonFile {
    <#
    .SYNOPSIS
        Writes -InputObject as JSON to -Path. The text goes to Path.tmp first and is then swapped in, so a reader
        (the console, a progress window, another PC on the share) never reads half a file. A reader that has the
        file open can block the swap for a moment, so it is tried a few times.
    .DESCRIPTION
        UTF-8 with a BOM, as Set-Content -Encoding utf8 writes it in Windows PowerShell 5.1, so 5.1's Get-Content
        reads accented letters right. -Depth is ConvertTo-Json's (2 by default, like ConvertTo-Json).
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [int]$Depth = 2
    )
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))
    for ($try = 1; ; $try++) {
        try {
            if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
            [IO.File]::Move($tmp, $Path)
            return
        } catch {
            if ($try -ge 5) { [IO.File]::Delete($tmp); throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

Export-ModuleMember -Function Save-JsonFile
