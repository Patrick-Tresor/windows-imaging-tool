# Windows Autopilot: the Autopilot-HardwareHash task template (config\task-templates.json) saves one CSV per PC at
# first boot; Merge-AutopilotCsv makes the single file Intune imports (Devices > Windows enrollment > Devices > Import).
# PowerShell 5.1 compatible.

function Merge-AutopilotCsv {
    <#
    .SYNOPSIS
        Joins the Autopilot-<serial>.csv files in Folder into OutFile, one row per serial (the newest file wins),
        in the format Intune imports: no quotes, and a Group Tag column when any PC has one. Returns the row count.
    #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$OutFile)
    $rows = @{}
    $tagged = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Filter 'Autopilot-*.csv' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc)) {
        foreach ($r in @(Import-Csv -LiteralPath $f.FullName)) {
            $serial = "$($r.'Device Serial Number')".Trim()
            $hash = "$($r.'Hardware Hash')".Trim()
            if (-not $serial -or -not $hash) { continue }
            $tag = if ($r.PSObject.Properties['Group Tag']) { "$($r.'Group Tag')".Trim() } else { '' }
            if ($tag) { $tagged = $true }
            $rows[$serial] = [pscustomobject]@{ Serial = $serial; ProductId = "$($r.'Windows Product ID')".Trim(); Hash = $hash; Tag = $tag }
        }
    }
    $lines = @('Device Serial Number,Windows Product ID,Hardware Hash' + $(if ($tagged) { ',Group Tag' } else { '' }))
    foreach ($r in @($rows.Values | Sort-Object Serial)) {
        $lines += "$($r.Serial),$($r.ProductId),$($r.Hash)" + $(if ($tagged) { ",$($r.Tag)" } else { '' })
    }
    $lines | Set-Content -LiteralPath $OutFile -Encoding ascii
    $rows.Count
}

Export-ModuleMember -Function Merge-AutopilotCsv
