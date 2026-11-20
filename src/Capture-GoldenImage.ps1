<#
.SYNOPSIS
    Captures a sysprepped reference PC (ideally a VM) to a WIM, from WinPE.
.DESCRIPTION
    With -NewVersion, an existing image of the same name is replaced only once the new capture has
    succeeded, and the old one is kept as a version in Images\Previous\ (see ImageVersions.psm1).

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
    [Parameter(ParameterSetName = 'Direct')][ValidateSet('fast', 'max', 'recovery')][string]$Compression = 'max',
    [Parameter(ParameterSetName = 'Direct')][int]$SplitSizeMB = 0,   # e.g. 3800 to fit a FAT32 USB; 0 = no split
    [Parameter(ParameterSetName = 'Direct')][switch]$NewVersion,     # replace an existing image, keeping the old one as a version
    [Parameter(Mandatory, ParameterSetName = 'Config')][string]$ConfigPath,
    [string]$Destination,
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [switch]$NoPrompt,
    [switch]$ShutdownWhenDone
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ImageVersions.psm1') -Force

if ($PSCmdlet.ParameterSetName -eq 'Config') {
    $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    $Name             = $cfg.name
    $Description      = $cfg.description
    $Compression      = $cfg.compression
    $SplitSizeMB      = [int]$cfg.splitSizeMB
    $NoPrompt         = [switch][bool]$cfg.noPrompt
    $ShutdownWhenDone = [switch][bool]$cfg.shutdownWhenDone
    $NewVersion       = [switch][bool]$cfg.newVersion
}
if ($Name -notmatch '^[A-Za-z0-9._-]+$') { throw "Image name '$Name' may only contain letters, digits, dot, dash and underscore." }

$root = $null
$staging = $null
$swap = @{ Swapping = $false }
$status = 'FAILED'
try {
    Set-DeployConsole -Title 'Capture Windows image'
    # WinPE assigns letters unpredictably: find the volume that holds an offline Windows install.
    # A VM with a second Windows disk attached has two; capture the generalized one.
    $found = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne 'X' } |
        Where-Object { [IO.File]::Exists("$($_.DriveLetter):\Windows\System32\config\SYSTEM") } | Sort-Object DriveLetter |
        ForEach-Object { [pscustomobject]@{ Volume = $_; State = Get-OfflineImageState -Root "$($_.DriveLetter):\" } })
    if (-not $found) { throw 'No offline Windows installation found on this machine.' }
    foreach ($f in $found) {
        $shown = if ($null -eq $f.State.ImageState) { 'no Setup\State\State.ini' } else { "ImageState=$($f.State.ImageState)" }
        Write-DeployLog "Found Windows on $($f.Volume.DriveLetter):\ ($shown)"
    }
    $pick = @($found | Where-Object { $_.State.Generalized })[0]
    if (-not $pick) { $pick = $found[0] }
    $windows = $pick.Volume
    $source = "$($windows.DriveLetter):\"

    # Refuse to capture an image that skipped sysprep, since it would not be hardware-independent.
    if (-not $pick.State.Generalized) {
        $why = "ImageState is $($pick.State.ImageState), so sysprep /generalize did not run or did not finish."
        if ($pick.State.LastError) { $why += " Last sysprep error: $($pick.State.LastError)" }
        throw "Windows on $source was not generalized. $why Boot it, run Prepare-Reference.ps1 (or sysprep /generalize /oobe /shutdown), let it shut down by itself, then boot the capture media."
    }
    if ($null -eq $pick.State.ImageState) {
        Write-DeployLog "$source has no Setup\State\State.ini, so it cannot be checked for sysprep. Capturing anyway." -Level WARN
    }

    if (-not $Destination) {
        $root = Find-ContentRoot -SettingsPath $SettingsPath
        $Destination = Join-Path $root 'Images'
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Assert-CaptureCompression -Compression $Compression -SplitSizeMB $SplitSizeMB
    $existing = @(Get-ExistingImageFiles -ImagesDir $Destination -Name $Name)
    if ($existing -and -not $NewVersion) {
        throw "An image named $Name already exists in $Destination. Pick another name, or capture it as a new version."
    }
    # A new version is captured to a staging folder first, so a failed capture leaves the current image alone.
    $staging = if ($existing) { Join-Path $Destination ".capture-$Name" } else { $Destination }
    if ($existing) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
    }
    $wim = Join-Path $staging "$Name.wim"

    Write-DeployLog ("Capturing {0} ({1:N0} GB used) to {2}" -f $source, (($windows.Size - $windows.SizeRemaining) / 1GB), $wim)
    if (-not $NoPrompt -and (Read-Host 'Type YES to start the capture') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; return }

    $captureArgs = @('/Capture-Image', "/ImageFile:$wim", "/CaptureDir:$source", "/Name:$Name",
        "/Compress:$(if ($Compression -eq 'recovery') { 'max' } else { $Compression })", '/CheckIntegrity', '/Verify')
    if ($Description) { $captureArgs += "/Description:$Description" }
    Invoke-Native -FilePath 'dism.exe' -ArgumentList $captureArgs
    # Smallest: recompressed into an .esd (DISM cannot capture to recovery compression directly).
    if ($Compression -eq 'recovery') { $esd = Convert-ImageToEsd -WimPath $wim; Write-DeployLog "Compressed to $esd" }

    if ($SplitSizeMB -gt 0) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @(
            '/Split-Image', "/ImageFile:$wim", "/SWMFile:$(Join-Path $staging "$Name.swm")", "/FileSize:$SplitSizeMB")
        Remove-Item $wim
    }

    [void](Publish-CapturedImage -Staging $staging -ImagesDir $Destination -Name $Name -SplitSizeMB $SplitSizeMB -Compression $Compression -Existing $existing -ContentRoot $root -State $swap)

    Write-DeployLog "Captured $source to $Destination"
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
    if ($swap.Swapping) { Write-DeployLog "Failed while replacing the old image. The new capture is in $staging and the old one in $Destination\Previous." -Level WARN }
}
finally {
    # Once the swap has started the staging folder may hold the only copy of the new capture, so keep it then.
    if ($staging -and $staging -ne $Destination -and -not $swap.Swapping) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    if ($root) {
        $logDir = Join-Path $root 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item 'X:\Windows\Temp\Deploy.log' (Join-Path $logDir ("CAPTURE-{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $Name, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'OK' -and $ShutdownWhenDone) { & wpeutil.exe shutdown }
if ($status -ne 'OK') { exit 1 }
