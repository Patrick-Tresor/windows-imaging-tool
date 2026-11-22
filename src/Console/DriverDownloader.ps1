# Driver pack downloads. Dot-sourced by ImagingConsole.ps1, which provides ConvertTo-Arg and imports
# DriverPacks.psm1. The downloads run hidden through Get-DriverPacks.ps1 so the console stays usable; their progress
# is a card in the Progress window (BuildProgress.ps1), like everything else that runs.

function Start-DriverPackDownload {
    # Hands the packs to Get-DriverPacks.ps1 through a job file. It runs hidden, in its own process so the console
    # stays usable, and the console's progress window shows each pack: download percent, time left, then checking,
    # extracting and adding it to the library (Patrick, 2026-11-11: no PowerShell window with the BITS bar).
    # When it ends the driver library refreshes by itself. Used by Find a model online and the Unknown models window.
    param(
        [Parameter(Mandatory)][object[]]$Packs,
        [Parameter(Mandatory)][string]$ContentRoot,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)]$Owner,
        [switch]$KeepDownload
    )
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $job = Join-Path ([IO.Path]::GetTempPath()) "driverpacks-$stamp-$tag.json"
    Save-JsonFile -Path $job -InputObject @($Packs) -Depth 4
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (ConvertTo-Arg (Join-Path $SrcDir 'Get-DriverPacks.ps1')),
        '-ContentRoot', (ConvertTo-Arg $ContentRoot), '-JobFile', (ConvertTo-Arg $job))
    if ($KeepDownload) { $runArgs += '-KeepDownload' }
    $run = Start-ConsoleJob -Name 'driverpacks' -ArgumentList $runArgs -Hidden
    $title = if (@($Packs).Count -eq 1) { "$(Format-DriverPackName @($Packs)[0]) driver pack" } else { "$(@($Packs).Count) driver packs" }
    # One card in the Progress window. A download that worked takes itself off after 5 seconds (Patrick, 2026-11-11);
    # a failed one stays for its log.
    Show-BuildProgress -Owner $Owner -ProgressFile $run.ProgressFile -LogPath $run.LogPath -Process $run.Process -Title "Downloading the $title" `
        -Noun 'download' -Hidden -RemoveWhenDoneSeconds 5 -OnFinished { try { Update-Drivers } catch { } }
}
