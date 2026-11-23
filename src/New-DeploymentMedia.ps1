<#
.SYNOPSIS
    Builds the WinPE boot image with the deploy tool inside, then a USB stick, or the network boot image: boot.wim
    in a folder (what the Computers tab starts on PCs) plus Deploy-WinPE.iso of the same WinPE (for a VM or a PC
    without a stick; it loads everything from the share).
.DESCRIPTION
    Run as admin on a workstation with the Windows ADK and the WinPE add-on installed.
    Both targets boot both UEFI and legacy BIOS PCs.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare
    Copies every answer file, the images they deploy, drivers, applications and config to the stick.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare -AnswerFiles Staff-W11
    Copies only the Staff-W11 answer file and the image it names (not every image in the content root).
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare -DriverPacks 'Dell\Latitude 5440|Dell\_Generic WinPE-Storage-Net'
    Puts only those two driver packs on the stick instead of the whole Drivers folder.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare -WinPEPasswordFile C:\Temp\pe.txt
    WinPE asks for the password in that file before it does anything. The answer file key goes into boot.wim
    encrypted with it. Without a WinPE password the answer files still carry their passwords encrypted, and the key
    that decrypts them is in boot.wim, so the deploy needs no typing either way.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare -UpdateOnly
    Updates a stick built earlier without erasing it: new WinPE, and only the content files that changed.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Wim -OutputPath D:\DeployShare\Boot -SettingsPath D:\DeployShare\config\deploy-settings.json
    Writes boot.wim, boot.json and Deploy-WinPE.iso to the folder (the console's Computers tab starts boot.wim on PCs
    over the network; the ISO boots a VM or a PC from the same share).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Usb', 'Wim')][string]$Target,
    [string]$WorkDir = 'C:\WinPE_Build',
    [int]$UsbDiskNumber = -1,
    [string]$ContentSource,          # content root to copy to the USB's DEPLOY partition (answer files, their images, drivers, apps, config)
    [string[]]$AnswerFiles,          # with -ContentSource: only these answer files and the images they name; default all
    [string[]]$DriverPacks,          # with -ContentSource: only these driver packs (catalog paths, e.g. 'Dell\Latitude 5440'); default all
    [switch]$NoDriverPacks,          # with -ContentSource: no driver packs at all (PCs get Windows inbox drivers)
    [string]$OutputPath = (Get-Location).Path,
    [string]$WinPEDrivers,           # optional NIC/storage drivers WinPE itself needs on newer hardware
    [switch]$NoWinPECache,           # add the WinPE components and drivers again instead of reusing the last build's boot.wim
    [switch]$NoVendorWinPEDrivers,   # don't add any vendor WinPE driver pack (Intel RST/VMD storage, network) to boot.wim
    [string[]]$WinPEDriverVendors = @('Dell', 'HP'),   # whose WinPE driver packs go into boot.wim: Dell, HP (comma list from the console)
    [string]$SettingsPath,           # deploy-settings.json to bake in; defaults to the repo copy
    [string]$WinPEPasswordFile,      # file holding the WinPE password (read, then deleted when it is in %TEMP%): WinPE asks for it at start
    [switch]$NoAppDownloads,         # with -ContentSource: don't download online applications onto the stick (each PC downloads them at first boot)
    [switch]$LooseDriverFiles,       # with -ContentSource: copy driver packs as plain files, not one .wim each (much slower to copy to a stick)
    [switch]$UpdateOnly,             # with -Target Usb: update a stick this tool built (WINPE + DEPLOY) without erasing it
    [string]$ProgressFile,           # JSON file the console's Build progress window reads: each step, its percent and time
    [string]$LogPath,                # transcript of the build (the progress window's Open log button)
    [switch]$Force                   # skip the USB erase prompt (the console confirms before calling)
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'BuildSteps.psm1') -Force

if ($LogPath) {
    New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
    try { Start-Transcript -Path $LogPath -Append | Out-Null } catch { Write-Warning "No build log: $($_.Exception.Message)"; $LogPath = $null }
}
# The steps the progress window lists, in the order they run. Only the parameters decide them, so the list is
# there before anything can fail.
$appDownloads = $Target -eq 'Usb' -and $ContentSource -and -not $NoAppDownloads
$steps = @(, @('check', 'Checking the ADK and the content'))
if ($appDownloads) { $steps += , @('apps', 'Downloading online applications') }
$packDrivers = $Target -eq 'Usb' -and $ContentSource -and -not $LooseDriverFiles
if ($packDrivers) { $steps += , @('packdrivers', 'Packing each driver pack into one file') }
$steps += , @('copype', 'Copying WinPE files')
if (-not $NoVendorWinPEDrivers) { $steps += , @('pedrivers', 'Getting the WinPE driver packs') }
$steps += @(
    , @('mount', 'Mounting boot.wim')
    , @('components', 'Adding WinPE components')
    , @('drivers', 'Adding drivers to WinPE')
)
if (-not $NoWinPECache) { $steps += , @('cache', 'Saving WinPE for the next build') }
$steps += @(
    , @('configure', 'Configuring WinPE')
    , @('unmount', 'Unmounting boot.wim')
)
switch ($Target) {
    'Usb' {
        if ($UpdateOnly) { $steps += @(@('stick', 'Checking what changed on the stick'), @('bootfiles', 'Updating WinPE on the stick')) }
        else { $steps += @(@('stick', 'Partitioning the USB stick'), @('bootfiles', 'Copying WinPE to the stick')) }
        if ($ContentSource) { $steps += , @('content', $(if ($UpdateOnly) { 'Copying changed images and content' } else { 'Copying images and content' })) }
        if (-not $NoVendorWinPEDrivers) { $steps += , @('packs', 'Copying WinPE driver packs to the stick') }
    }
    'Wim' { $steps += @(@('wim', 'Writing boot.wim'), @('iso', 'Making the ISO')) }
}
$title = switch ($Target) {
    'Usb' { if ($UpdateOnly) { "Updating USB stick (disk $UsbDiskNumber)" } else { "Creating USB stick (disk $UsbDiskNumber)" } }
    'Wim' { 'Creating the network boot image and ISO' }
}
Start-BuildProgress -Path $ProgressFile -Title $title -Steps $steps -LogPath $LogPath
# Any error from here on: the progress window shows the step that failed and one line, this window and the log the rest.
trap {
    Stop-BuildProgress -Message $_.Exception.Message
    if ($LogPath) { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red; try { Stop-Transcript | Out-Null } catch { } }
    break
}
Start-BuildStep 'check'
Import-Module (Join-Path $PSScriptRoot 'AdkCheck.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UsbDisk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MediaContent.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MediaCopy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Format.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployStatus.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DriverPackFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\DriverPacks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1') -Function New-WinPEWallpaper -Force
Import-Module (Join-Path $PSScriptRoot 'JsonFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecretVault.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ToolVersion.psm1') -Force

# The version of the tool this build puts on the media: shown in the WinPE wizard, written in every Deploy.log, and
# read back by the console to say a stick is older than the console.
$toolVersion = Get-ToolVersion
$versionRecord = ConvertTo-ToolVersionRecord -Version $toolVersion -Target $Target
Write-Host "Imaging tool version $($toolVersion.Text)"

# Check the ADK first: without it nothing below can work, and copype's own errors are cryptic.
$adkStatus = Get-AdkStatus
if (-not $adkStatus.Ready) { throw ("Can't build media on this PC yet:`n - " + ($adkStatus.Problems -join "`n - ")) }
Write-Host $adkStatus.Summary
foreach ($w in $adkStatus.Warnings) { Write-Warning $w }
$adk = $adkStatus.Root
$peRoot = "$adk\Windows Preinstallation Environment"

if (-not $SettingsPath) { $SettingsPath = "$repo\config\deploy-settings.json" }
if ($AnswerFiles -and -not $ContentSource) { throw '-AnswerFiles needs -ContentSource.' }
# The console passes the names as one comma-separated argument (powershell.exe -File doesn't take arrays).
$AnswerFiles = @($AnswerFiles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$WinPEDriverVendors = @($WinPEDriverVendors | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
foreach ($v in $WinPEDriverVendors) { if ($v -notin 'Dell', 'HP') { throw "-WinPEDriverVendors: '$v' is not Dell or HP." } }
if (($DriverPacks -or $NoDriverPacks) -and -not $ContentSource) { throw '-DriverPacks and -NoDriverPacks need -ContentSource.' }
if ($DriverPacks -and $NoDriverPacks) { throw 'Pass -DriverPacks or -NoDriverPacks, not both.' }
# Pack folders can contain commas, so the console joins them with | (not allowed in Windows file names).
$DriverPacks = @($DriverPacks | ForEach-Object { $_ -split '\|' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# The WinPE password: read now, and the console's temporary file removed, so it is not left on disk.
$winPEPassword = $null
if ($WinPEPasswordFile) {
    if (-not (Test-Path -LiteralPath $WinPEPasswordFile)) { throw "WinPE password file not found: $WinPEPasswordFile" }
    $winPEPassword = (ConvertFrom-SecretBytes ([IO.File]::ReadAllBytes($WinPEPasswordFile))).Trim()
    $tempFull = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ([IO.Path]::GetFullPath($WinPEPasswordFile).StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $WinPEPasswordFile -Force }
    if ($winPEPassword.Length -lt 8) { throw 'The WinPE password needs at least 8 characters.' }
}
if ($winPEPassword -and $Target -eq 'Wim') { throw '-WinPEPasswordFile is for USB sticks: the network boot image starts on PCs nobody is at to type it.' }
if ($UpdateOnly -and $Target -ne 'Usb') { throw '-UpdateOnly needs -Target Usb.' }
$packArgs = @{}
if ($NoDriverPacks) { $packArgs.DriverPacks = @() } elseif ($DriverPacks) { $packArgs.DriverPacks = $DriverPacks }
$content = $null
if ($Target -eq 'Usb' -and $ContentSource) {
    # Check the content before the build and before the stick is erased: a stick without its answer file and
    # image boots, then fails on the PC ("Cannot find path D:\AnswerFiles").
    $content = Get-MediaContent -ContentRoot $ContentSource -AnswerFiles $AnswerFiles @packArgs
    if ($content.Problems) { throw ("The USB stick would not deploy:`n - " + ($content.Problems -join "`n - ")) }
    foreach ($a in $content.AnswerFiles) { Write-Host "Answer file $($a.Name): image $($a.Image)$(if ($a.Version) { " version $($a.Version)" })" }
    foreach ($n in $content.Notes) { Write-Warning $n }
}
$copyPlan = $null
if ($content) {
    # Every file to copy and the total, for the progress bar and to check the stick is big enough before it is erased.
    $copyPlan = Get-MediaCopyPlan -ContentRoot $ContentSource -Folders $content.Folders -Files $content.Files -Exclude $content.Exclude
    Write-Host ('Content to copy: {0} files, {1}' -f $copyPlan.FileCount, (Format-ByteSize $copyPlan.TotalBytes))
}
if ($UpdateOnly) {
    # Check the stick is one of ours before spending minutes on the build.
    if ($UsbDiskNumber -lt 0) { throw 'Pass -UsbDiskNumber (see Get-Disk).' }
    $null = Get-UsbStickVolumes -DiskNumber $UsbDiskNumber
}

Complete-BuildStep 'check' -Detail $(if ($copyPlan) { '{0} files, {1} to copy' -f $copyPlan.FileCount, (Format-ByteSize $copyPlan.TotalBytes) } else { '' })

if ($appDownloads -and $copyPlan) {
    # Applications that download at first boot (Find an app online, or a template with no installer in New...): download them here
    # once, so an offline stick installs them without internet. Cached for the next build; a failure only warns.
    Start-BuildStep 'apps'
    $appCache = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }), 'ImagingConsole', 'AppDownloads')
    $onApp = { param($name, $i, $count) Set-BuildStepProgress 'apps' -Percent ([int](100 * ($i - 1) / [Math]::Max(1, $count))) -Detail $name }
    $dl = Get-MediaAppDownloads -Plan $copyPlan -CacheRoot $appCache -OnApp $onApp
    $copyPlan = Add-MediaCopyItems -Plan $copyPlan -Items $dl.Items
    foreach ($f in $dl.Failed) { Write-Warning "$f was not downloaded onto the stick: the PC downloads it at first boot, so it needs internet." }
    $appDetail = if (-not $dl.Items -and -not $dl.Failed) { 'No online applications' }
                 else { '{0} on the stick{1}' -f @($dl.Items).Count, $(if ($dl.Failed) { ", not downloaded: $($dl.Failed -join ', ')" }) }
    Complete-BuildStep 'apps' -Detail $appDetail
} elseif ($appDownloads) { Start-BuildStep 'apps'; Complete-BuildStep 'apps' -Detail 'No content to copy' }

if ($packDrivers) {
    # Each driver pack goes on the stick as one .wim: a stick writes thousands of small driver files at a few MB/s,
    # one big file many times faster. Packed once and cached on this PC; the deploy unpacks the PC's pack only.
    Start-BuildStep 'packdrivers'
    $packFolders = @(if ($copyPlan) { Get-DriverPackFolders -Plan $copyPlan -CatalogPath (Join-Path $ContentSource 'config\driver-catalog.json') -DriverRoots $content.DriverRoots })
    if ($packFolders) {
        $packCache = [IO.Path]::Combine($(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }), 'ImagingConsole', 'DriverPackFiles')
        $onPackFolder = {
            param($folder, $i, $count, $reused)
            Set-BuildStepProgress 'packdrivers' -Percent ([int](100 * ($i - 1) / [Math]::Max(1, $count))) -Detail $(if ($reused) { "$folder (packed before)" } else { $folder })
            Write-Host $(if ($reused) { "Driver pack ${folder}: packed before, reusing it" } else { "Packing driver pack $folder..." })
        }
        $copyPlan = ConvertTo-PackedDriverPlan -Plan $copyPlan -ContentRoot $ContentSource -Folders $packFolders -CacheRoot $packCache -OnPack $onPackFolder
        foreach ($f in @($copyPlan.Failed)) { Write-Warning "Driver pack $($f.Folder) goes on the stick as plain files (slower to copy): $($f.Reason)" }
        Remove-OldDriverPackFiles -CacheRoot $packCache -InUse @($copyPlan.Items | ForEach-Object { $_.Source } | Where-Object { $_ -like "$packCache*" })
        $files = 0; $before = [int64]0; $after = [int64]0
        foreach ($p in @($copyPlan.Packed)) { $files += $p.Files; $before += $p.Bytes; $after += $p.PackedBytes }
        $packDetail = '{0} pack(s): {1} files, {2}, now {3}' -f @($copyPlan.Packed).Count, $files, (Format-ByteSize $before), (Format-ByteSize $after)
        Write-Host "Driver packs: $packDetail"
        Write-Host ('Content to copy now: {0} files, {1}' -f $copyPlan.FileCount, (Format-ByteSize $copyPlan.TotalBytes))
        Complete-BuildStep 'packdrivers' -Detail $packDetail
    } else { Complete-BuildStep 'packdrivers' -State skipped -Detail 'No driver packs on this stick' }
}

# copype and MakeWinPEMedia expect the ADK environment variables that DandISetEnv.bat sets.
Start-BuildStep 'copype'
$envBat = "$adk\Deployment Tools\DandISetEnv.bat"
cmd /c "`"$envBat`" && set" | ForEach-Object { if ($_ -match '^(.*?)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
& cmd /c "copype amd64 `"$WorkDir`""
if ($LASTEXITCODE -ne 0) { throw 'copype failed' }
Complete-BuildStep 'copype'

$mount = Join-Path $WorkDir 'mount'
$bootWim = Join-Path $WorkDir 'media\sources\boot.wim'

# Storage and network drivers for WinPE itself. Without the Intel RST/VMD driver, WinPE sees no SSD on PCs that
# ship with VMD on (Dell 11th gen and later, and others), and the deploy stops with "No internal disk found".
# Each vendor's WinPE pack (Dell: Intel RST/VMD, NICs; HP: its business PCs' storage and NICs) is downloaded once
# into the cache; a build without internet carries on without it. Lenovo publishes no single WinPE pack, but the
# Intel storage drivers in Dell's pack match the controller, so they cover Lenovo PCs with VMD too.
$peSources = @(); $peProblem = $null; $vendorPacks = @()
if (-not $NoVendorWinPEDrivers) {
    Start-BuildStep 'pedrivers'
    foreach ($vendor in $WinPEDriverVendors) {
        Set-BuildStepProgress 'pedrivers' -Detail "$vendor (downloaded once, then taken from the cache)"
        try {
            $pack = if ($vendor -eq 'HP') { Save-HpWinPEDriverPack } else { Save-WinPEDriverPack }
            $vendorPacks += $pack
            $peSources += [pscustomobject]@{ Path = $pack.Path; Name = $pack.Source }
        } catch {
            $msg = "$vendor WinPE driver pack not added: $($_.Exception.Message)"
            $peProblem = (@($peProblem, $msg) | Where-Object { $_ }) -join ' '
            Write-Warning $msg
        }
    }
    Complete-BuildStep 'pedrivers' -Detail $(if ($peProblem) { 'Some packs missing, see the log' } else { (@($vendorPacks | ForEach-Object Source) -join ', ') })
}
if ($WinPEDrivers) { $peSources += [pscustomobject]@{ Path = $WinPEDrivers; Name = 'Extra WinPE drivers' } }
if ($ContentSource -and (Test-Path "$ContentSource\Drivers\_WinPE")) { $peSources += [pscustomobject]@{ Path = "$ContentSource\Drivers\_WinPE"; Name = 'Drivers\_WinPE' } }
# x64 drivers only (Dell's pack also has x86), each driver once.
$pePlan = @(Get-WinPEDriverPlan -Sources $peSources)

# Adding the components and a few hundred drivers to boot.wim takes minutes. The result
# is kept in the cache and reused while the ADK, the components and every driver .inf stay the same.
$peKey = Get-WinPEBuildKey -BaseWim $bootWim -Components (Get-WinPEComponentNames) -DriverPlan $pePlan
$peCached = if ($NoWinPECache) { $null } else { Find-WinPEBuildCache -Key $peKey }
if (-not $NoWinPECache -and -not $peCached) {
    # Says why the drivers go in again: a new driver pack version, another ADK, or the first build.
    $cacheDir = Get-WinPEBuildCacheDir
    $saved = @(if ([IO.Directory]::Exists($cacheDir)) { [IO.Directory]::GetDirectories($cacheDir) | ForEach-Object { [IO.Path]::GetFileName($_) } })
    Write-Host ("No saved WinPE build matches this one (key {0}; saved: {1}). A driver pack, the ADK or the components changed, so the components and drivers go in again; this build is saved for the next one." -f $peKey, $(if ($saved) { $saved -join ', ' } else { 'none' })) -ForegroundColor DarkGray
    foreach ($peSrc in $pePlan) { Write-Host "  WinPE driver source: $($peSrc.Name) ($($peSrc.Path)), $(@($peSrc.Infs).Count) .inf" -ForegroundColor DarkGray }
}
$peReport = @()
Start-BuildStep 'mount'
if ($peCached) {
    Copy-Item -LiteralPath $peCached.Wim -Destination $bootWim -Force
    $peReport = @($peCached.Sources)
    Write-Host ("WinPE components and drivers reused from the build of {0} (same ADK and drivers): {1} driver(s) in." -f $peCached.Built, (@($peReport | ForEach-Object { [int]$_.added }) | Measure-Object -Sum).Sum) -ForegroundColor Green
}

Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mount | Out-Null
Complete-BuildStep 'mount'
try {
    if ($peCached) {
        $reused = "From the build of $($peCached.Built)"
        Complete-BuildStep 'components' -State reused -Detail $reused
        Complete-BuildStep 'drivers' -State reused -Detail $reused
        Complete-BuildStep 'cache' -State skipped -Detail 'Same ADK and drivers as last time'
    } else {
        # PowerShell, WMI, and storage cmdlets inside WinPE. Order matters: dependencies first.
        $ocs = "$peRoot\amd64\WinPE_OCs"
        Write-Host 'Adding the WinPE components (PowerShell, WMI, storage)...'
        Start-BuildStep 'components'
        $ocNames = @(Get-WinPEComponentNames)
        for ($n = 0; $n -lt $ocNames.Count; $n++) {
            $oc = $ocNames[$n]
            Set-BuildStepProgress 'components' -Percent (100 * $n / $ocNames.Count) -Detail $oc
            Add-WindowsPackage -Path $mount -PackagePath "$ocs\$oc.cab" | Out-Null
            $lang = "$ocs\en-us\$($oc)_en-us.cab"
            if (Test-Path $lang) { Add-WindowsPackage -Path $mount -PackagePath $lang | Out-Null }
        }
        Complete-BuildStep 'components' -Detail "$($ocNames.Count) components"
        Start-BuildStep 'drivers'
        # All the drivers in one DISM run over one staging folder: one servicing session instead of one per
        # driver (that took about 10 seconds a driver, 45 minutes for Dell's and HP's packs).
        $infTotal = (@($pePlan | ForEach-Object { @($_.Infs | Where-Object { -not $_.Duplicate }).Count }) | Measure-Object -Sum).Sum
        $infSame = (@($pePlan | ForEach-Object { @($_.Infs | Where-Object Duplicate).Count }) | Measure-Object -Sum).Sum
        $infAdded = 0
        if ($infTotal) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Set-BuildStepProgress 'drivers' -Percent 0 -Detail "Gathering $infTotal driver(s)"
            $staging = Join-Path $WorkDir 'pedrivers'
            $staged = @(New-WinPEDriverStaging -Plan $pePlan -Destination $staging)
            Write-Host ('Adding {0} WinPE driver(s) from {1} in one DISM run{2}...' -f $staged.Count, (@($pePlan | ForEach-Object Name) -join ', '), $(if ($infSame) { " ($infSame already in another pack)" } else { '' }))
            $dismOut = Join-Path $WorkDir 'dism-add-driver.txt'
            $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
            $dismArgs = "/Image:`"$mount`" /Add-Driver /Driver:`"$staging`" /Recurse /English"
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"`"$dism`" $dismArgs > `"$dismOut`" 2>&1`"" -NoNewWindow -PassThru
            $null = $p.Handle   # PowerShell 5.1 only keeps ExitCode if the handle was read before exit
            while (-not $p.WaitForExit(2000)) {
                $text = Read-SharedText $dismOut
                $info = Get-NativeProgress -Text $text
                $last = [regex]::Matches($text, '(?m)- ([^\r\n]*?\.inf)\b')
                $name = if ($last.Count) { Split-Path $last[$last.Count - 1].Groups[1].Value -Leaf } else { '' }
                if ($info -and $info.Total) {
                    Set-BuildStepProgress 'drivers' -Percent $info.Percent -Detail ('{0} of {1}: {2}' -f ($info.Done + 1), $info.Total, $name)
                } else { Set-BuildStepProgress 'drivers' -Detail 'DISM is reading the drivers' }
            }
            Get-NativeLogLines -Text (Read-SharedText $dismOut) | Where-Object { $_ -notmatch 'successfully installed' } | ForEach-Object { Write-Host "  $_" }
            $installed = $null
            try { $installed = @(Get-WindowsDriver -Path $mount -ErrorAction Stop | ForEach-Object { Split-Path "$($_.OriginalFileName)" -Leaf }) }
            catch { Write-Warning "Could not list the drivers in boot.wim ($($_.Exception.Message)); using DISM's exit code $($p.ExitCode) instead." }
            $peReport = @(if ($null -ne $installed) { Get-WinPEDriverResults -Plan $pePlan -Staged $staged -InstalledNames $installed }
                          else { Get-WinPEDriverResults -Plan $pePlan -Staged $staged -ExitCode $p.ExitCode })
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($r in $peReport) {
                $infAdded += $r.added
                if (@($r.failed).Count) { Write-Warning "$(@($r.failed).Count) WinPE driver(s) from $($r.name) could not be added: $((@($r.failed) | Select-Object -Unique) -join ', '). DISM's log: $env:SystemRoot\Logs\DISM\dism.log" }
            }
            Write-Host ('Done: {0} of {1} WinPE driver(s) added in {2:m\:ss}.' -f $infAdded, $staged.Count, $clock.Elapsed)
        } else {
            $peReport = @(Get-WinPEDriverResults -Plan $pePlan -Staged @())
        }
        Complete-BuildStep 'drivers' -Detail $(if ($pePlan) { "$infAdded driver(s) added" } else { 'No WinPE drivers' })
        # A DISM run that added nothing (it failed as a whole) must not be cached: the next builds would reuse a
        # WinPE without its storage and network drivers while the key stays the same.
        $peCacheThis = -not $NoWinPECache -and -not ($infTotal -and $infAdded -eq 0)
        if ($infTotal -and $infAdded -eq 0) { Write-Warning "No WinPE driver could be added (DISM exit code $($p.ExitCode)). This WinPE is not saved for the next build. DISM's log: $env:SystemRoot\Logs\DISM\dism.log" }
        if ($peCacheThis) {
            # Save now, before the scripts and settings of this build go in, and keep that boot.wim for the next build.
            Write-Host 'Saving WinPE with its components and drivers for the next build...'
            Start-BuildStep 'cache'
            Dismount-WindowsImage -Path $mount -Save | Out-Null
            try { $null = Save-WinPEBuildCache -Key $peKey -WimPath $bootWim -Sources $peReport }
            catch { Write-Warning "WinPE build not cached (the next build adds the drivers again): $($_.Exception.Message)" }
            Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mount | Out-Null
            Complete-BuildStep 'cache'
        } elseif (-not $NoWinPECache) {
            Complete-BuildStep 'cache' -State skipped -Detail 'Not saved: no WinPE driver was added'
        }
    }
    Start-BuildStep 'configure'
    # WinPE's own time zone is Pacific. A PC's clock holds its local time, so in Toronto WinPE was 3 hours ahead: wrong
    # times in Deploy.log and on the Dashboard, and reimage jobs from the Computers tab looked expired. WinPE gets this
    # PC's time zone (the deploy PCs are normally in the same place).
    $tz = try { (Get-TimeZone).Id } catch { $null }
    if ($tz) {
        & dism.exe /English /Image:$mount "/Set-TimeZone:$tz" | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "WinPE time zone: $tz" -ForegroundColor DarkGray }
        else { Write-Warning "Could not set the WinPE time zone to $tz (DISM exit $LASTEXITCODE): WinPE keeps Pacific time, so its log times can be off." }
    }
    $vmdAdded = @($peReport | ForEach-Object { $_.vmd } | Where-Object { $_ }).Count -gt 0
    if ($vmdAdded) { Write-Host "WinPE has the Intel RST/VMD storage driver ($((@($peReport | ForEach-Object { $_.vmd } | Where-Object { $_ }) | Select-Object -Unique) -join ', '))." -ForegroundColor Green }
    else { Write-Warning 'WinPE has no Intel RST/VMD storage driver: PCs with VMD on (many 11th gen and later laptops) will show no internal disk.' }

    $deployDir = Join-Path $mount 'Deploy'
    New-Item -ItemType Directory -Path "$deployDir\config" -Force | Out-Null
    Copy-Item "$repo\src\*.ps1", "$repo\src\*.psm1" $deployDir
    # The logo shown in the WinPE wizard and progress window.
    Copy-Item "$repo\src\Assets" "$deployDir\Assets" -Recurse -Force
    # WinPE's desktop background, seen while it starts: the logo on the deploy windows' dark blue instead of plain blue.
    # winpe.jpg belongs to TrustedInstaller, so Administrators (by SID: the group has another name on a French PC)
    # take it first. A failure keeps the plain blue.
    try {
        $wallpaper = Join-Path $mount 'Windows\System32\winpe.jpg'
        $newWallpaper = New-WinPEWallpaper -Path (Join-Path $WorkDir 'winpe.jpg') -LogoPath "$repo\src\Assets\logo.png"
        if (Test-Path -LiteralPath $wallpaper) {
            & takeown.exe /f $wallpaper /a 2>&1 | Out-Null
            & icacls.exe $wallpaper /grant '*S-1-5-32-544:F' 2>&1 | Out-Null
        }
        Copy-Item -LiteralPath $newWallpaper -Destination $wallpaper -Force
    } catch { Write-Warning "WinPE keeps its plain blue background: $($_.Exception.Message)" }
    Copy-Item $SettingsPath "$deployDir\config\deploy-settings.json"
    Save-JsonFile -Path "$deployDir\config\tool-version.json" -InputObject $versionRecord
    # The content root that holds config\secrets: its answer file key decrypts the passwords in the answer files.
    $secretRoot = if ($ContentSource) { $ContentSource } else { Split-Path (Split-Path $SettingsPath -Parent) -Parent }
    $answerKey = Get-AnswerKey -ContentRoot $secretRoot
    if ($winPEPassword) {
        # The answer file key, encrypted with the WinPE password, inside boot.wim. WinPE asks for it at start; the key
        # then decrypts the passwords in the answer files and the share password in the settings.
        $secrets = @{}
        if ($answerKey) { $secrets['config\secrets\answer-key.txt'] = $answerKey }
        New-SecretVault -Password $winPEPassword -Secrets $secrets | ConvertTo-Json | Set-Content "$deployDir\config\vault.json" -Encoding ascii
        Write-Host "WinPE password set: WinPE asks for it at start. $(if ($answerKey) { 'The answer file key is' } else { 'Nothing is' }) inside boot.wim, encrypted with it." -ForegroundColor Green
        $winPEPassword = $null
        # cmd /c instead of WinPE's default cmd /k: Ctrl+C at the password prompt ends the shell, and WinPE restarts
        # instead of leaving a command prompt behind the lock.
        "[LaunchApps]`r`n%SYSTEMROOT%\System32\cmd.exe, /c %SYSTEMROOT%\System32\startnet.cmd`r`n" |
            Set-Content "$mount\Windows\System32\winpeshl.ini" -Encoding ascii
    } elseif ($answerKey) {
        # No WinPE password: the key goes into boot.wim as it is, so the passwords in the answer files decrypt
        # without anyone typing. The answer files on the DEPLOY partition alone give nothing away, but someone with
        # the whole stick can take the key out of boot.wim.
        [IO.File]::WriteAllText("$deployDir\config\answer-key.txt", $answerKey, [Text.Encoding]::ASCII)
        Write-Host "Answer file key $(Get-AnswerKeyId $answerKey) is in boot.wim: the passwords encrypted in the answer files are used without typing." -ForegroundColor Green
        if ($Target -eq 'Usb' -and $ContentSource) {
            Write-Warning 'No WinPE password: anyone with the stick can boot it, and could take the answer file key out of boot.wim to decrypt the passwords. Set a WinPE password to lock it.'
        }
    } elseif ($Target -eq 'Usb' -and $ContentSource) {
        Write-Warning 'No answer file key in config\secrets: no answer file has an encrypted password, so the deploy wizard asks for the passwords on its Passwords page.'
    }
    $answerKey = $null
    # What WinPE drivers went in, so Deploy-Image can log it: "no internal disk" is then easy to explain.
    Save-JsonFile -Path "$deployDir\config\winpe-drivers.json" -Depth 4 -InputObject ([ordered]@{
        built = (Get-Date).ToString('yyyy-MM-dd HH:mm'); sources = @($peReport); vmd = $vmdAdded; problem = $peProblem })
    Copy-Item "$repo\winpe\startnet.cmd" "$mount\Windows\System32\startnet.cmd" -Force
    Complete-BuildStep 'configure' -Detail $(if ($vmdAdded) { 'Intel RST/VMD storage driver in' } else { 'No Intel RST/VMD storage driver, see the log' })
}
catch {
    Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
}
Start-BuildStep 'unmount' -Detail 'Saving the changes to boot.wim'
Dismount-WindowsImage -Path $mount -Save | Out-Null
Complete-BuildStep 'unmount'

switch ($Target) {
    'Wim' {
        $outWim = Join-Path $OutputPath 'boot.wim'
        Start-BuildStep 'wim' -Detail $outWim
        Copy-Item $bootWim $outWim -Force
        # What the console's Computers tab checks before it starts this image on PCs over the network: which share it maps.
        Save-JsonFile -Path (Join-Path $OutputPath 'boot.json') -InputObject ([ordered]@{ built = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            share = "$((Get-Content -Raw $SettingsPath | ConvertFrom-Json).share.path)"; toolVersion = $toolVersion.Text })
        # The console compares this with its own version and says when the network boot image needs rebuilding.
        Save-JsonFile -Path (Join-Path $OutputPath 'tool-version.json') -InputObject $versionRecord
        Complete-BuildStep 'wim'
        Write-Host "boot.wim written to $OutputPath."
        # The same WinPE as an ISO, for a VM or a PC without a stick: it maps the share like the network boot image.
        $iso = Join-Path $OutputPath 'Deploy-WinPE.iso'
        Start-BuildStep 'iso' -Detail $iso
        if (Test-Path $iso) { Remove-Item $iso }
        # The boot files come from the ADK's Oscdimg folder: newer copype versions no longer create fwfiles.
        $bootFiles = Get-IsoBootFiles -AdkRoot $adk
        $bootData = "2#p0,e,b`"$($bootFiles.BiosBoot)`"#pEF,e,b`"$($bootFiles.UefiBoot)`""
        & cmd /c "oscdimg -m -o -u2 -udfver102 -bootdata:$bootData `"$WorkDir\media`" `"$iso`""
        if ($LASTEXITCODE -ne 0) {
            throw ("oscdimg could not build $iso (exit code $LASTEXITCODE). Its own message above says why. " +
                "It used $WorkDir\media with the boot files $($bootFiles.BiosBoot) and $($bootFiles.UefiBoot). " +
                'Check that the folder has free space and the ISO is not open or attached to a VM.')
        }
        Complete-BuildStep 'iso'
        Write-Host "ISO written to $iso"
    }
    'Usb' {
        function Disable-ShortNames([string]$Letter) {
            # No 8.3 short names on DEPLOY: NTFS makes one for every new file, an extra write per driver file on a
            # slow stick. Nothing here uses them. A failure only costs that speed.
            try { & fsutil.exe 8dot3name set "${Letter}:" 1 2>&1 | Out-Null } catch { Write-Verbose "fsutil 8dot3name: $_" }
        }
        if ($UsbDiskNumber -lt 0) { throw 'Pass -UsbDiskNumber (see Get-Disk). That disk will be erased.' }
        $disk = Get-UsbTargetDisk -DiskNumber $UsbDiskNumber
        $update = $null
        # The content copy's percent, speed and time left for the progress window.
        $onCopy = { param($p) Set-BuildStepProgress 'content' -Percent $p.Percent -Detail ('{0} of {1}, {2}/s, about {3} left' -f (Format-ByteSize $p.BytesDone), (Format-ByteSize $p.TotalBytes), (Format-ByteSize ([int64]$p.BytesPerSecond)), (Format-Duration $p.SecondsLeft)) }
        if ($UpdateOnly) {
            # A stick built before: keep its partitions, refresh WinPE, copy only what changed, delete what was dropped.
            Start-BuildStep 'stick'
            $sticks = Get-UsbStickVolumes -DiskNumber $UsbDiskNumber
            $bootLetter = $sticks.Boot.Letter; $dataLetter = $sticks.Data.Letter
            if ($copyPlan) {
                $update = Get-MediaUpdatePlan -Plan $copyPlan -Destination "${dataLetter}:\"
                Write-Host ('Update: {0} file(s) to copy ({1}), {2} unchanged, {3} to delete' -f $update.Copy.FileCount, (Format-ByteSize $update.Copy.TotalBytes), $update.Unchanged, @($update.Stale).Count)
                if ($update.NeededBytes -gt ($sticks.Data.FreeBytes - 64MB)) {
                    throw ('The update needs {0} more but the stick''s DEPLOY partition has {1} free. Use a bigger stick, or put fewer answer files or driver packs on it.' -f (Format-ByteSize $update.NeededBytes), (Format-ByteSize $sticks.Data.FreeBytes))
                }
            }
            Complete-BuildStep 'stick' -Detail $(if ($update) { '{0} file(s) to copy, {1} unchanged, {2} to delete' -f $update.Copy.FileCount, $update.Unchanged, @($update.Stale).Count } else { '' })
            Write-Host "Updating WinPE on ${bootLetter}:..."
            Start-BuildStep 'bootfiles' -Detail "${bootLetter}:"
            robocopy "$WorkDir\media" "${bootLetter}:\" /MIR /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Updating the WinPE boot files on ${bootLetter}: failed (robocopy exit code $LASTEXITCODE)." }
            Complete-BuildStep 'bootfiles'
            if ($update) {
                Start-BuildStep 'content'
                Disable-ShortNames $dataLetter
                Remove-StaleMediaFiles -UpdatePlan $update -Destination "${dataLetter}:\"
                $copied = Copy-MediaContent -Plan $update.Copy -Destination "${dataLetter}:\" -OnProgress $onCopy
                Complete-BuildStep 'content' -Detail ('{0} files, {1}, in {2}' -f $copied.FileCount, (Format-ByteSize $copied.Bytes), (Format-Duration $copied.Seconds))
                Write-Host ('Copied {0} files, {1}, in {2}; {3} file(s) were already up to date' -f $copied.FileCount, (Format-ByteSize $copied.Bytes), (Format-Duration $copied.Seconds), $update.Unchanged)
            }
        }
        if (-not $UpdateOnly) {
            if ($copyPlan) {
                # 2 GB WINPE partition, plus a little for NTFS itself.
                $room = [int64]$disk.Size - 2GB - [int64]($disk.Size * 0.02)
                if ($copyPlan.TotalBytes -gt $room) {
                    throw ('The content is {0} but USB disk {1} only has room for about {2}. Use a bigger stick, or put fewer answer files or driver packs on it.' -f (Format-ByteSize $copyPlan.TotalBytes), $UsbDiskNumber, (Format-ByteSize ([Math]::Max(0, $room))))
                }
            }
            if (-not $Force -and (Read-Host "ERASE disk $UsbDiskNumber ($($disk.FriendlyName))? Type YES") -ne 'YES') { Stop-BuildProgress -Message 'Cancelled: the stick was not erased.'; return }
            Write-Host "Erasing and partitioning USB disk $UsbDiskNumber..."
            Start-BuildStep 'stick' -Detail "$($disk.FriendlyName): WINPE (FAT32) and DEPLOY (NTFS)"

            # Two partitions on MBR: an active FAT32 one that boots both UEFI and BIOS, NTFS for images larger than 4 GB.
            Reset-UsbDisk -DiskNumber $UsbDiskNumber
            $boot = New-Partition -DiskNumber $UsbDiskNumber -Size 2GB -IsActive -AssignDriveLetter
            Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'WINPE' -Confirm:$false | Out-Null
            $data = New-Partition -DiskNumber $UsbDiskNumber -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition $data -FileSystem NTFS -NewFileSystemLabel 'DEPLOY' -Confirm:$false | Out-Null

            $bootLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $boot.PartitionNumber).DriveLetter
            $dataLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $data.PartitionNumber).DriveLetter
            Disable-ShortNames $dataLetter
            Complete-BuildStep 'stick' -Detail "WINPE on ${bootLetter}:, DEPLOY on ${dataLetter}:"
            Write-Host "Copying WinPE boot files to ${bootLetter}:..."
            Start-BuildStep 'bootfiles' -Detail "${bootLetter}:"
            robocopy "$WorkDir\media" "${bootLetter}:\" /E /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying the WinPE boot files to ${bootLetter}: failed (robocopy exit code $LASTEXITCODE)." }
            # Legacy BIOS boot code in the MBR and the partition boot sector, as MakeWinPEMedia writes it.
            $bootsect = "$adk\Deployment Tools\amd64\BCDBoot\bootsect.exe"
            & $bootsect /nt60 "${bootLetter}:" /force /mbr | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'bootsect failed' }
            Complete-BuildStep 'bootfiles'
            # Find-ContentRoot recognizes the stick by its Images folder.
            New-Item -ItemType Directory -Path "${dataLetter}:\Images" -Force | Out-Null
            if ($copyPlan) {
                # The answer files, the image each one names, and what they use, copied in chunks with a progress bar: a 5 GB image takes minutes on a USB stick.
                Start-BuildStep 'content'
                $copied = Copy-MediaContent -Plan $copyPlan -Destination "${dataLetter}:\" -OnProgress $onCopy
                Write-Host ('Copied {0} files, {1}, in {2} ({3}/s on average)' -f $copied.FileCount, (Format-ByteSize $copied.Bytes), (Format-Duration $copied.Seconds), (Format-ByteSize ([int64]($copied.Bytes / [Math]::Max(0.001, $copied.Seconds)))))
                Complete-BuildStep 'content' -Detail ('{0} files, {1}, in {2}' -f $copied.FileCount, (Format-ByteSize $copied.Bytes), (Format-Duration $copied.Seconds))
            }
        }
        if ($content) { Write-Host "Answer files on the stick: $(($content.AnswerFiles | ForEach-Object Name) -join ', ')" }
        # The version on the DEPLOY partition too, where the console can read it without opening boot.wim.
        Save-JsonFile -Path "${dataLetter}:\tool-version.json" -InputObject $versionRecord
        # The vendor WinPE packs on the stick too, so WinPE can load them with drvload when boot.wim lacks a driver.
        # Only the x64 drivers, with progress, and on an update only the files that changed.
        if ($vendorPacks) { Start-BuildStep 'packs' }
        $packCopied = 0
        for ($n = 0; $n -lt $vendorPacks.Count; $n++) {
            $pack = $vendorPacks[$n]
            $packPlan = (Get-MediaUpdatePlan -Plan (Get-WinPEPackCopyPlan -PackPath $pack.Path) -Destination "${dataLetter}:\").Copy
            if (-not $packPlan.FileCount) { Write-Host "$($pack.Source) is already on the stick."; continue }
            Write-Host ('Copying {0} to the stick: {1} files, {2}' -f $pack.Source, $packPlan.FileCount, (Format-ByteSize $packPlan.TotalBytes))
            $packBase = 100 * $n / $vendorPacks.Count; $packShare = 100 / $vendorPacks.Count; $packName = $pack.Source
            $onPack = { param($p) Set-BuildStepProgress 'packs' -Percent ($packBase + $packShare * $p.Percent / 100) -Detail ('{0}: {1} of {2}' -f $packName, (Format-ByteSize $p.BytesDone), (Format-ByteSize $p.TotalBytes)) }
            $copied = Copy-MediaContent -Plan $packPlan -Destination "${dataLetter}:\" -OnProgress $onPack
            $packCopied++
            Write-Host ('Copied in {0}' -f (Format-Duration $copied.Seconds))
        }
        if ($vendorPacks) { Complete-BuildStep 'packs' -Detail $(if ($packCopied) { "$packCopied pack(s) copied" } else { 'Already on the stick' }) }
        Write-Host ''
        Write-Host '==============================================' -ForegroundColor Green
        Write-Host ' USB media ready' -ForegroundColor Green
        Write-Host " WinPE on ${bootLetter}:, content on ${dataLetter}: (DEPLOY)" -ForegroundColor Green
        Write-Host " Tool version $($toolVersion.Text)" -ForegroundColor Green
        Write-Host ' Eject the stick in Windows before you unplug it.' -ForegroundColor Green
        Write-Host ' Boot menu key: Dell F12, HP F9, Lenovo F12 (or the Novo button), Microsoft Surface: hold Volume down' -ForegroundColor Green
        Write-Host '==============================================' -ForegroundColor Green
    }
}
Stop-BuildProgress
if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
