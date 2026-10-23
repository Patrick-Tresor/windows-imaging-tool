# Checks that the Windows ADK and its WinPE add-on are installed with everything New-DeploymentMedia.ps1 uses.
# Used by New-DeploymentMedia.ps1 and the admin console. PowerShell 5.1 compatible.

$script:AdkDownload = 'https://learn.microsoft.com/windows-hardware/get-started/adk-install'

# WinPE optional components added to boot.wim, in the order New-DeploymentMedia.ps1 adds them.
$script:WinPEComponents = 'WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell',
    'WinPE-StorageWMI', 'WinPE-DismCmdlets', 'WinPE-SecureStartup'

function Get-AdkDownloadUrl { $script:AdkDownload }

function Get-WinPEComponentNames { $script:WinPEComponents }

function Get-AdkRoot {
    # The ADK folder from the registry (it can be installed anywhere), else the default location.
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots') {
        $kits = (Get-ItemProperty -Path $key -Name KitsRoot10 -ErrorAction SilentlyContinue).KitsRoot10
        if ($kits) {
            $adk = Join-Path $kits 'Assessment and Deployment Kit'
            if (Test-Path -LiteralPath $adk) { return $adk }
        }
    }
    $programFiles = ${env:ProgramFiles(x86)}
    if (-not $programFiles) { $programFiles = $env:ProgramFiles }
    if (-not $programFiles) { return $null }
    Join-Path $programFiles 'Windows Kits\10\Assessment and Deployment Kit'
}

function Get-AdkInstalledVersions {
    # Display versions of the ADK and the WinPE add-on from Programs and Features; empty where not found.
    $result = [ordered]@{ Adk = ''; WinPE = '' }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        foreach ($p in Get-ItemProperty -Path $key -ErrorAction SilentlyContinue) {
            if ("$($p.DisplayName)" -like 'Windows Assessment and Deployment Kit Windows Preinstallation Environment*') {
                if (-not $result.WinPE) { $result.WinPE = "$($p.DisplayVersion)" }
            } elseif ("$($p.DisplayName)" -like 'Windows Assessment and Deployment Kit*') {
                if (-not $result.Adk) { $result.Adk = "$($p.DisplayVersion)" }
            }
        }
    }
    [pscustomobject]$result
}

function Get-AdkStatus {
    <#
    .SYNOPSIS
        Checks the ADK install. Ready is $true when media can be built; Problems says what to install when it can't.
    .PARAMETER AdkRoot
        The "Assessment and Deployment Kit" folder. Defaults to the one the registry names.
    .PARAMETER Versions
        ADK and WinPE add-on versions (Adk, WinPE). Defaults to what Programs and Features lists.
    #>
    param([string]$AdkRoot, $Versions)
    if (-not $AdkRoot) { $AdkRoot = Get-AdkRoot }
    if (-not $Versions) { $Versions = Get-AdkInstalledVersions }

    $deploy = if ($AdkRoot) { Join-Path $AdkRoot 'Deployment Tools' } else { $null }
    $pe = if ($AdkRoot) { Join-Path $AdkRoot 'Windows Preinstallation Environment' } else { $null }
    $has = { param($Base, $Child) $Base -and (Test-Path -LiteralPath (Join-Path $Base ($Child -replace '\\', [IO.Path]::DirectorySeparatorChar))) }

    $checks = @(
        [pscustomobject]@{ Part = 'ADK Deployment Tools'; Path = 'DandISetEnv.bat'; Ok = & $has $deploy 'DandISetEnv.bat' }
        [pscustomobject]@{ Part = 'ADK Deployment Tools'; Path = 'amd64\Oscdimg\oscdimg.exe'; Ok = & $has $deploy 'amd64\Oscdimg\oscdimg.exe' }
        [pscustomobject]@{ Part = 'ADK Deployment Tools'; Path = 'amd64\Oscdimg\efisys_noprompt.bin'; Ok = & $has $deploy 'amd64\Oscdimg\efisys_noprompt.bin' }
        [pscustomobject]@{ Part = 'WinPE add-on'; Path = 'copype.cmd'; Ok = & $has $pe 'copype.cmd' }
        [pscustomobject]@{ Part = 'WinPE add-on'; Path = 'MakeWinPEMedia.cmd'; Ok = & $has $pe 'MakeWinPEMedia.cmd' }
        [pscustomobject]@{ Part = 'WinPE add-on'; Path = 'amd64\en-us\winpe.wim'; Ok = & $has $pe 'amd64\en-us\winpe.wim' }
    )
    $checks += foreach ($oc in $script:WinPEComponents) {
        [pscustomobject]@{ Part = 'WinPE add-on'; Path = "amd64\WinPE_OCs\$oc.cab"; Ok = & $has $pe "amd64\WinPE_OCs\$oc.cab" }
    }

    $adkOk = -not ($checks | Where-Object { $_.Part -eq 'ADK Deployment Tools' -and -not $_.Ok })
    $peOk = -not ($checks | Where-Object { $_.Part -eq 'WinPE add-on' -and -not $_.Ok })
    $adkFound = [bool]($deploy -and (Test-Path -LiteralPath $deploy))
    $peFound = [bool]($pe -and (Test-Path -LiteralPath $pe))

    $problems = @()
    if (-not $adkFound) {
        $problems += "The Windows ADK is not installed. Install it with the Deployment Tools feature from $($script:AdkDownload)."
    } elseif (-not $adkOk) {
        $missing = ($checks | Where-Object { $_.Part -eq 'ADK Deployment Tools' -and -not $_.Ok }).Path -join ', '
        $problems += "The Windows ADK is missing parts of Deployment Tools ($missing). Run the ADK installer again and tick Deployment Tools."
    }
    if (-not $peFound) {
        $problems += "The Windows PE add-on for the ADK is not installed. Install it from $($script:AdkDownload) (it is a separate download)."
    } elseif (-not $peOk) {
        $missing = ($checks | Where-Object { $_.Part -eq 'WinPE add-on' -and -not $_.Ok }).Path -join ', '
        $problems += "The Windows PE add-on is missing files ($missing). Repair or reinstall it."
    }

    $warnings = @()
    if ($Versions.Adk -and $Versions.WinPE -and $Versions.Adk -ne $Versions.WinPE) {
        $warnings += "The ADK ($($Versions.Adk)) and the WinPE add-on ($($Versions.WinPE)) are different versions. Install matching versions, or copype and DISM may fail."
    }

    $version = if ($Versions.Adk) { $Versions.Adk } elseif ($Versions.WinPE) { $Versions.WinPE } else { '' }
    [pscustomobject]@{
        Root     = $AdkRoot
        Version  = $version
        Ready    = $adkOk -and $peOk
        Problems = $problems
        Warnings = $warnings
        Checks   = $checks
        Summary  = if ($adkOk -and $peOk) { "Windows ADK$(if ($version) { " $version" }) and the WinPE add-on are installed in $AdkRoot." }
                   else { $problems -join ' ' }
    }
}

Export-ModuleMember -Function Get-AdkDownloadUrl, Get-WinPEComponentNames, Get-AdkRoot, Get-AdkInstalledVersions, Get-AdkStatus
