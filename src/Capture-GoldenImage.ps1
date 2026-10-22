<#
.SYNOPSIS
    Captures a sysprepped reference PC (ideally a Hyper-V VM) to a WIM, from WinPE.
.DESCRIPTION
    Before running, prepare the reference machine with Prepare-Reference.ps1 (or
    sysprep /generalize /oobe /shutdown), then boot it from capture media.
    Capture media built by the console's capture wizard runs this automatically with
    -ConfigPath X:\Deploy\config\capture.json.
.EXAMPLE
    X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise -Destination Z:\Images
.EXAMPLE
    X:\Deploy\Capture-GoldenImage.ps1 -ConfigPath X:\Deploy\config\capture.json
#>
[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Direct')][string]$Name,
    [Parameter(ParameterSetName = 'Direct')][string]$Description,
    [Parameter(ParameterSetName = 'Direct')][ValidateSet('fast', 'max')][string]$Compression = 'max',
    [Parameter(ParameterSetName = 'Direct')][int]$SplitSizeMB = 0,   # e.g. 3800 to fit a FAT32 USB; 0 = no split
    [Parameter(Mandatory, ParameterSetName = 'Config')][string]$ConfigPath,
    [string]$Destination,
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [switch]$NoPrompt,
    [switch]$ShutdownWhenDone
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Config') {
    $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    $Name             = $cfg.name
    $Description      = $cfg.description
    $Compression      = $cfg.compression
    $SplitSizeMB      = [int]$cfg.splitSizeMB
    $NoPrompt         = [switch][bool]$cfg.noPrompt
    $ShutdownWhenDone = [switch][bool]$cfg.shutdownWhenDone
}
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$root = $null
$status = 'FAILED'
try {
    # WinPE assigns letters unpredictably: find the volume that holds an offline Windows install.
    $windows = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' } |
        Where-Object { Test-Path "$($_.DriveLetter):\Windows\System32\config\SYSTEM" } |
        Select-Object -First 1
    if (-not $windows) { throw 'No offline Windows installation found on this machine.' }
    $source = "$($windows.DriveLetter):\"

    # Refuse to capture an image that skipped sysprep, since it would not be hardware-independent.
    $setupState = "$source\Windows\Setup\State\State.ini"
    if ((Test-Path $setupState) -and -not (Select-String -Path $setupState -Pattern 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -Quiet)) {
        throw "Windows on $source was not generalized. Run Prepare-Reference.ps1 (or sysprep /generalize /oobe /shutdown) on it first."
    }

    if (-not $Destination) {
        $root = Find-ContentRoot -SettingsPath $SettingsPath
        $Destination = Join-Path $root 'Images'
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $wim = Join-Path $Destination "$Name.wim"
    if ((Test-Path $wim) -or (Test-Path (Join-Path $Destination "$Name.swm"))) {
        throw "An image named $Name already exists in $Destination. Pick another name."
    }

    Write-DeployLog ("Capturing {0} ({1:N0} GB used) to {2}" -f $source, (($windows.Size - $windows.SizeRemaining) / 1GB), $wim)
    if (-not $NoPrompt -and (Read-Host 'Type YES to start the capture') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; return }

    $captureArgs = @('/Capture-Image', "/ImageFile:$wim", "/CaptureDir:$source", "/Name:$Name",
        "/Compress:$Compression", '/CheckIntegrity', '/Verify')
    if ($Description) { $captureArgs += "/Description:$Description" }
    Invoke-Native -FilePath 'dism.exe' -ArgumentList $captureArgs

    if ($SplitSizeMB -gt 0) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
            '/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $Destination "$Name.swm")", "/FileSize:$SplitSizeMB")
        Remove-Item $wim
    }

    Write-DeployLog "Captured $source to $Destination"
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
}
finally {
    if ($root) {
        $logDir = Join-Path $root 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item 'X:\Windows\Temp\Deploy.log' (Join-Path $logDir ("CAPTURE-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'OK' -and $ShutdownWhenDone) { & wpeutil.exe shutdown }
if ($status -ne 'OK') { exit 1 }
