<#
.SYNOPSIS
    Builds the WinPE boot image with the deploy tool inside, then a USB stick, an ISO, or a boot.wim for PXE.
.DESCRIPTION
    Run as admin on a workstation with the Windows ADK and the WinPE add-on installed.
    All three targets boot both UEFI and legacy BIOS PCs.
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
    WinPE asks for the password in that file before it does anything. The content root's password files go into
    boot.wim encrypted with it; they are never copied to the stick as plain text (unless -SecretsOnMedia).
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare -UpdateOnly
    Updates a stick built earlier without erasing it: new WinPE, and only the content files that changed.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Pxe -OutputPath C:\WDS\Boot
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Pxe -OutputPath C:\WDS\Boot -PublishToWds -SettingsPath D:\DeployShare\config\deploy-settings.json
    Builds boot.wim and publishes it to the WDS server named in the settings' "wds" section.
.EXAMPLE
    .\New-DeploymentMedia.ps1 -Target Iso -CaptureConfig D:\DeployShare\config\capture.json -BootVM Win11-Ref
    Builds capture media and boots the Hyper-V VM Win11-Ref from it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Usb', 'Iso', 'Pxe')][string]$Target,
    [string]$WorkDir = 'C:\WinPE_Build',
    [int]$UsbDiskNumber = -1,
    [string]$ContentSource,          # content root to copy to the USB's DEPLOY partition (answer files, their images, drivers, apps, config)
    [string[]]$AnswerFiles,          # with -ContentSource: only these answer files and the images they name; default all
    [string[]]$DriverPacks,          # with -ContentSource: only these driver packs (catalog paths, e.g. 'Dell\Latitude 5440'); default all
    [switch]$NoDriverPacks,          # with -ContentSource: no driver packs at all (PCs get Windows inbox drivers)
    [string]$OutputPath = (Get-Location).Path,
    [string]$WinPEDrivers,           # optional NIC/storage drivers WinPE itself needs on newer hardware
    [switch]$NoVendorWinPEDrivers,   # don't add any vendor WinPE driver pack (Intel RST/VMD storage, network) to boot.wim
    [string[]]$WinPEDriverVendors = @('Dell', 'HP'),   # whose WinPE driver packs go into boot.wim: Dell, HP (comma list from the console)
    [string]$SettingsPath,           # deploy-settings.json to bake in; defaults to the repo copy
    [string]$CaptureConfig,          # capture.json to bake in: the media then captures instead of deploying
    [string]$BootVM,                 # with -Target Iso: attach the ISO to this Hyper-V VM and start it
    [switch]$PublishToWds,           # with -Target Pxe: publish boot.wim to WDS (Publish-WdsBootImage.ps1, settings' "wds" section)
    [string]$WinPEPasswordFile,      # file holding the WinPE password (read, then deleted when it is in %TEMP%): WinPE asks for it at start
    [switch]$SecretsOnMedia,
    [switch]$UpdateOnly,             # with -Target Usb: update a stick this tool built (WINPE + DEPLOY) without erasing it         # with -ContentSource: also copy config\secrets to the stick as plain text (not recommended)
    [switch]$Force                   # skip the USB erase prompt (the console confirms before calling)
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AdkCheck.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'UsbDisk.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MediaContent.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'MediaCopy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Console\DriverPacks.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SecretVault.psm1') -Force

# Check the ADK first: without it nothing below can work, and copype's own errors are cryptic.
$adkStatus = Get-AdkStatus
if (-not $adkStatus.Ready) { throw ("Can't build media on this PC yet:`n - " + ($adkStatus.Problems -join "`n - ")) }
Write-Host $adkStatus.Summary
foreach ($w in $adkStatus.Warnings) { Write-Warning $w }
$adk = $adkStatus.Root
$peRoot = "$adk\Windows Preinstallation Environment"

if (-not $SettingsPath) { $SettingsPath = "$repo\config\deploy-settings.json" }
if ($BootVM -and $Target -ne 'Iso') { throw '-BootVM needs -Target Iso.' }
if ($PublishToWds -and $Target -ne 'Pxe') { throw '-PublishToWds needs -Target Pxe.' }
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
if ($winPEPassword -and $CaptureConfig) { throw '-WinPEPasswordFile is for deploy media, not capture media.' }
if ($UpdateOnly -and $Target -ne 'Usb') { throw '-UpdateOnly needs -Target Usb.' }
if ($SecretsOnMedia -and -not $ContentSource) { throw '-SecretsOnMedia needs -ContentSource.' }
$packArgs = @{}
if ($SecretsOnMedia) { $packArgs.IncludeSecrets = $true }
if ($NoDriverPacks) { $packArgs.DriverPacks = @() } elseif ($DriverPacks) { $packArgs.DriverPacks = $DriverPacks }
$content = $null
if ($Target -eq 'Usb' -and $ContentSource -and -not $CaptureConfig) {
    # Check the content before the build and before the stick is erased: a stick without its answer file and
    # image boots, then fails on the PC ("Cannot find path D:\AnswerFiles").
    $default = try { (Get-Content -Raw $SettingsPath | ConvertFrom-Json).defaultAnswerFile } catch { $null }
    $content = Get-MediaContent -ContentRoot $ContentSource -AnswerFiles $AnswerFiles -DefaultAnswerFile $default @packArgs
    if ($content.Problems) { throw ("The USB stick would not deploy:`n - " + ($content.Problems -join "`n - ")) }
    foreach ($a in $content.AnswerFiles) { Write-Host "Answer file $($a.Name): image $($a.Image)$(if ($a.Version) { " version $($a.Version)" })" }
    foreach ($n in $content.Notes) { Write-Warning $n }
}
$copyPlan = $null
if ($Target -eq 'Usb' -and $ContentSource) {
    # Every file to copy and the total, for the progress bar and to check the stick is big enough before it is erased.
    $copyPlan = if ($content) { Get-MediaCopyPlan -ContentRoot $ContentSource -Folders $content.Folders -Files $content.Files -Exclude $content.Exclude }
                else { Get-MediaCopyPlan -ContentRoot $ContentSource -Folders @('Images', 'Drivers', 'config' | Where-Object { Test-Path (Join-Path $ContentSource $_) }) -Exclude @(if (-not $SecretsOnMedia) { 'config\secrets' }) }
    Write-Host ('Content to copy: {0} files, {1}' -f $copyPlan.FileCount, (Format-MediaSize $copyPlan.TotalBytes))
}
if ($UpdateOnly) {
    # Check the stick is one of ours before spending minutes on the build.
    if ($UsbDiskNumber -lt 0) { throw 'Pass -UsbDiskNumber (see Get-Disk).' }
    $null = Get-UsbStickVolumes -DiskNumber $UsbDiskNumber
}
if ($BootVM) {
    # Check the VM before spending minutes on the build.
    $vm = Get-VM -Name $BootVM
    if ($vm.State -ne 'Off') { throw "VM $BootVM is $($vm.State). Let sysprep shut it down first." }
}

# copype and MakeWinPEMedia expect the ADK environment variables that DandISetEnv.bat sets.
$envBat = "$adk\Deployment Tools\DandISetEnv.bat"
cmd /c "`"$envBat`" && set" | ForEach-Object { if ($_ -match '^(.*?)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
& cmd /c "copype amd64 `"$WorkDir`""
if ($LASTEXITCODE -ne 0) { throw 'copype failed' }

$mount = Join-Path $WorkDir 'mount'
$bootWim = Join-Path $WorkDir 'media\sources\boot.wim'
Mount-WindowsImage -ImagePath $bootWim -Index 1 -Path $mount | Out-Null
try {
    # PowerShell, WMI, and storage cmdlets inside WinPE. Order matters: dependencies first.
    $ocs = "$peRoot\amd64\WinPE_OCs"
    foreach ($oc in Get-WinPEComponentNames) {
        Add-WindowsPackage -Path $mount -PackagePath "$ocs\$oc.cab" | Out-Null
        $lang = "$ocs\en-us\$($oc)_en-us.cab"
        if (Test-Path $lang) { Add-WindowsPackage -Path $mount -PackagePath $lang | Out-Null }
    }
    # Storage and network drivers for WinPE itself. Without the Intel RST/VMD driver, WinPE sees no SSD on PCs that
    # ship with VMD on (Dell 11th gen and later, and others), and the deploy stops with "No internal disk found".
    # Each vendor's WinPE pack (Dell: Intel RST/VMD, NICs; HP: its business PCs' storage and NICs) is downloaded once
    # into the cache; a build without internet carries on without it. Lenovo publishes no single WinPE pack, but the
    # Intel storage drivers in Dell's pack match the controller, so they cover Lenovo PCs with VMD too.
    $peSources = @(); $peProblem = $null; $vendorPacks = @()
    if (-not $NoVendorWinPEDrivers) {
        foreach ($vendor in $WinPEDriverVendors) {
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
    }
    if ($WinPEDrivers) { $peSources += [pscustomobject]@{ Path = $WinPEDrivers; Name = 'Extra WinPE drivers' } }
    if ($ContentSource -and (Test-Path "$ContentSource\Drivers\_WinPE")) { $peSources += [pscustomobject]@{ Path = "$ContentSource\Drivers\_WinPE"; Name = 'Drivers\_WinPE' } }
    $peReport = @()
    $seenInfs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($src in $peSources) {
        # x64 drivers only (Dell's pack also has x86); one bad driver must not lose the others.
        $infs = @(Get-WinPEDriverInfs -Folder $src.Path)
        Write-Host "Adding $($infs.Count) WinPE driver(s) from $($src.Name) ($($src.Path)). Each takes a few seconds:"
        $added = @(); $failed = @(); $same = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $infs.Count; $i++) {
            $inf = $infs[$i]
            $line = Format-DriverProgressLine -Index ($i + 1) -Total $infs.Count -Path $inf.FullName -Root $src.Path -Elapsed $clock.Elapsed
            Write-Progress -Activity "Adding WinPE drivers from $($src.Name)" -Status $line -PercentComplete ([int](100 * $i / [Math]::Max(1, $infs.Count)))
            Write-Host -NoNewline "  $line"
            # The same driver in two vendors' packs (Intel NICs, Intel RST) goes in once.
            $key = "$($inf.Name)|$((Get-FileHash $inf.FullName -Algorithm SHA256).Hash)"
            if ($seenInfs.Contains($key)) { $same++; Write-Host ' already added'; continue }
            [void]$seenInfs.Add($key)
            try { Add-WindowsDriver -Path $mount -Driver $inf.FullName -ErrorAction Stop | Out-Null; $added += $inf.Name; Write-Host ' ok' }
            catch { $failed += $inf.Name; Write-Host ' FAILED' -ForegroundColor Yellow; Write-Verbose "Not added: $($inf.FullName): $($_.Exception.Message)" }
        }
        Write-Progress -Activity "Adding WinPE drivers from $($src.Name)" -Completed
        Write-Host ('Done: {0} of {1} WinPE driver(s) added{2} in {3:m\:ss}.' -f $added.Count, $infs.Count, $(if ($same) { ", $same already in from another pack" } else { '' }), $clock.Elapsed)
        if ($failed) { Write-Warning "$($failed.Count) of $($infs.Count) WinPE driver(s) from $($src.Name) could not be added: $(($failed | Select-Object -Unique) -join ', ')" }
        $peReport += [ordered]@{ name = $src.Name; added = $added.Count; failed = @($failed) ; vmd = @($added | Where-Object { $_ -match '^(iaStorVD|iaStorAC|iaStorAVC|iaVROC|iaStorE)\.inf$' } | Select-Object -Unique) }
    }
    $vmdAdded = @($peReport | ForEach-Object { $_.vmd }).Count -gt 0
    if ($vmdAdded) { Write-Host "WinPE has the Intel RST/VMD storage driver ($((@($peReport | ForEach-Object { $_.vmd }) | Select-Object -Unique) -join ', '))." -ForegroundColor Green }
    else { Write-Warning 'WinPE has no Intel RST/VMD storage driver: PCs with VMD on (many 11th gen and later laptops) will show no internal disk.' }

    $deployDir = Join-Path $mount 'Deploy'
    New-Item -ItemType Directory -Path "$deployDir\config" -Force | Out-Null
    Copy-Item "$repo\src\*.ps1", "$repo\src\*.psm1" $deployDir
    Copy-Item $SettingsPath "$deployDir\config\deploy-settings.json"
    if ($CaptureConfig) { Copy-Item $CaptureConfig "$deployDir\config\capture.json" }
    if ($winPEPassword) {
        # The password files, encrypted with the WinPE password, inside boot.wim. WinPE asks for it at start.
        $secretRoot = if ($ContentSource) { $ContentSource } else { Split-Path (Split-Path $SettingsPath -Parent) -Parent }
        $secrets = Get-ContentSecrets -ContentRoot $secretRoot -SettingsPath $SettingsPath
        New-SecretVault -Password $winPEPassword -Secrets $secrets | ConvertTo-Json | Set-Content "$deployDir\config\vault.json" -Encoding ascii
        Write-Host "WinPE password set: WinPE asks for it at start. $($secrets.Count) password file(s) from $secretRoot\config\secrets are inside boot.wim, encrypted with it." -ForegroundColor Green
        $winPEPassword = $null
        # cmd /c instead of WinPE's default cmd /k: Ctrl+C at the password prompt ends the shell, and WinPE restarts
        # instead of leaving a command prompt behind the lock.
        "[LaunchApps]`r`n%SYSTEMROOT%\System32\cmd.exe, /c %SYSTEMROOT%\System32\startnet.cmd`r`n" |
            Set-Content "$mount\Windows\System32\winpeshl.ini" -Encoding ascii
    } elseif ($Target -eq 'Usb' -and $ContentSource -and -not $SecretsOnMedia) {
        Write-Warning 'No WinPE password: anyone with the stick can boot it, and WinPE asks the operator for the join and other passwords (they are not on the stick).'
    }
    # What WinPE drivers went in, so Deploy-Image can log it: "no internal disk" is then easy to explain.
    [ordered]@{ built = (Get-Date).ToString('yyyy-MM-dd HH:mm'); sources = @($peReport); vmd = $vmdAdded; problem = $peProblem } |
        ConvertTo-Json -Depth 4 | Set-Content "$deployDir\config\winpe-drivers.json" -Encoding utf8
    # USMT for answer files that migrate user data (ScanState runs in WinPE, LoadState on the deployed PC).
    $usmt = "$adk\User State Migration Tool\amd64"
    if (Test-Path "$usmt\scanstate.exe") { Copy-Item $usmt "$deployDir\USMT" -Recurse }
    elseif (-not $CaptureConfig) { Write-Warning 'USMT is not installed (ADK feature User State Migration Tool). Answer files that migrate user data will stop before erasing anything.' }
    Copy-Item "$repo\winpe\startnet.cmd" "$mount\Windows\System32\startnet.cmd" -Force
}
catch {
    Dismount-WindowsImage -Path $mount -Discard | Out-Null
    throw
}
Dismount-WindowsImage -Path $mount -Save | Out-Null

switch ($Target) {
    'Pxe' {
        $pxeWim = Join-Path $OutputPath 'boot.wim'
        Copy-Item $bootWim $pxeWim -Force
        if ($PublishToWds) { & "$PSScriptRoot\Publish-WdsBootImage.ps1" -BootWim $pxeWim -SettingsPath $SettingsPath | Format-List }
        else { Write-Host "boot.wim written to $OutputPath. Publish it with Publish-WdsBootImage.ps1, or import it into WDS (Boot Images > Add Boot Image)." }
    }
    'Iso' {
        $iso = Join-Path $OutputPath $(if ($CaptureConfig) { 'Capture-WinPE.iso' } else { 'Deploy-WinPE.iso' })
        if (Test-Path $iso) { Remove-Item $iso }
        # Capture ISOs boot without the "Press any key to boot from CD" prompt so an unattended VM starts WinPE.
        # UEFI: the no-prompt EFI boot image. BIOS: etfsboot.com only prompts when boot\bootfix.bin exists.
        # The boot files come from the ADK's Oscdimg folder: newer copype versions no longer create fwfiles.
        $bootFiles = Get-IsoBootFiles -AdkRoot $adk -WorkDir $WorkDir -NoPrompt:([bool]$CaptureConfig)
        if ($CaptureConfig) { Remove-Item "$WorkDir\media\boot\bootfix.bin" -ErrorAction SilentlyContinue }
        $bootData = "2#p0,e,b`"$($bootFiles.BiosBoot)`"#pEF,e,b`"$($bootFiles.UefiBoot)`""
        & cmd /c "oscdimg -m -o -u2 -udfver102 -bootdata:$bootData `"$WorkDir\media`" `"$iso`""
        if ($LASTEXITCODE -ne 0) {
            throw ("oscdimg could not build $iso (exit code $LASTEXITCODE). Its own message above says why. " +
                "It used $WorkDir\media with the boot files $($bootFiles.BiosBoot) and $($bootFiles.UefiBoot). " +
                'Check that the output folder exists, has free space and the ISO is not open or attached to a VM.')
        }
        Write-Host "ISO written to $iso"

        if ($BootVM) {
            $dvd = Get-VMDvdDrive -VMName $BootVM | Select-Object -First 1
            if ($dvd) { Set-VMDvdDrive -VMName $BootVM -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $iso }
            else { $dvd = Add-VMDvdDrive -VMName $BootVM -Path $iso -Passthru }
            # Generation 2 (UEFI) picks a boot device; generation 1 (BIOS) orders device types.
            if ($vm.Generation -eq 2) { Set-VMFirmware -VMName $BootVM -FirstBootDevice (Get-VMDvdDrive -VMName $BootVM | Select-Object -First 1) }
            else { Set-VMBios -VMName $BootVM -StartupOrder @('CD', 'IDE', 'LegacyNetworkAdapter', 'Floppy') }
            Start-VM -Name $BootVM
            Write-Host "Started $BootVM from $iso. Watch it with: vmconnect localhost `"$BootVM`""

            # The capture shuts the VM down when it finishes. Then eject the ISO and boot from disk again,
            # or the next start would capture a second time.
            Write-Host 'Waiting for the capture to finish and the VM to shut down...'
            while ((Get-VM -Name $BootVM).State -ne 'Off') { Start-Sleep -Seconds 30 }
            Set-VMDvdDrive -VMName $BootVM -ControllerNumber $dvd.ControllerNumber -ControllerLocation $dvd.ControllerLocation -Path $null
            if ($vm.Generation -eq 2) {
                $disk = Get-VMHardDiskDrive -VMName $BootVM | Select-Object -First 1
                if ($disk) { Set-VMFirmware -VMName $BootVM -FirstBootDevice $disk }
            }
            else { Set-VMBios -VMName $BootVM -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy') }
            Write-Host "$BootVM is off, the ISO is ejected and it boots from its disk again. Check the Logs folder for the capture result."
        }
    }
    'Usb' {
        if ($UsbDiskNumber -lt 0) { throw 'Pass -UsbDiskNumber (see Get-Disk). That disk will be erased.' }
        $disk = Get-UsbTargetDisk -DiskNumber $UsbDiskNumber
        $update = $null
        if ($UpdateOnly) {
            # A stick built before: keep its partitions, refresh WinPE, copy only what changed, delete what was dropped.
            $sticks = Get-UsbStickVolumes -DiskNumber $UsbDiskNumber
            $bootLetter = $sticks.Boot.Letter; $dataLetter = $sticks.Data.Letter
            if ($copyPlan) {
                $update = Get-MediaUpdatePlan -Plan $copyPlan -Destination "${dataLetter}:\"
                Write-Host ('Update: {0} file(s) to copy ({1}), {2} unchanged, {3} to delete' -f $update.Copy.FileCount, (Format-MediaSize $update.Copy.TotalBytes), $update.Unchanged, @($update.Stale).Count)
                if ($update.NeededBytes -gt ($sticks.Data.FreeBytes - 64MB)) {
                    throw ('The update needs {0} more but the stick''s DEPLOY partition has {1} free. Use a bigger stick, or put fewer answer files or driver packs on it.' -f (Format-MediaSize $update.NeededBytes), (Format-MediaSize $sticks.Data.FreeBytes))
                }
            }
            Write-Host "Updating WinPE on ${bootLetter}:..."
            robocopy "$WorkDir\media" "${bootLetter}:\" /MIR /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Updating the WinPE boot files on ${bootLetter}: failed (robocopy exit code $LASTEXITCODE)." }
            if ($update) {
                Remove-StaleMediaFiles -UpdatePlan $update -Destination "${dataLetter}:\"
                $copied = Copy-MediaContent -Plan $update.Copy -Destination "${dataLetter}:\"
                Write-Host ('Copied {0} files, {1}, in {2}; {3} file(s) were already up to date' -f $copied.FileCount, (Format-MediaSize $copied.Bytes), (Format-MediaDuration $copied.Seconds), $update.Unchanged)
            }
        }
        if (-not $UpdateOnly) {
            if ($copyPlan) {
                # 2 GB WINPE partition, plus a little for NTFS itself.
                $room = [int64]$disk.Size - 2GB - [int64]($disk.Size * 0.02)
                if ($copyPlan.TotalBytes -gt $room) {
                    throw ('The content is {0} but USB disk {1} only has room for about {2}. Use a bigger stick, or put fewer answer files or driver packs on it.' -f (Format-MediaSize $copyPlan.TotalBytes), $UsbDiskNumber, (Format-MediaSize ([Math]::Max(0, $room))))
                }
            }
            if (-not $Force -and (Read-Host "ERASE disk $UsbDiskNumber ($($disk.FriendlyName))? Type YES") -ne 'YES') { return }
            Write-Host "Erasing and partitioning USB disk $UsbDiskNumber..."

            # Two partitions on MBR: an active FAT32 one that boots both UEFI and BIOS, NTFS for images larger than 4 GB.
            Reset-UsbDisk -DiskNumber $UsbDiskNumber
            $boot = New-Partition -DiskNumber $UsbDiskNumber -Size 2GB -IsActive -AssignDriveLetter
            Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'WINPE' -Confirm:$false | Out-Null
            $data = New-Partition -DiskNumber $UsbDiskNumber -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition $data -FileSystem NTFS -NewFileSystemLabel 'DEPLOY' -Confirm:$false | Out-Null

            $bootLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $boot.PartitionNumber).DriveLetter
            $dataLetter = (Get-Partition -DiskNumber $UsbDiskNumber -PartitionNumber $data.PartitionNumber).DriveLetter
            Write-Host "Copying WinPE boot files to ${bootLetter}:..."
            robocopy "$WorkDir\media" "${bootLetter}:\" /E /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying the WinPE boot files to ${bootLetter}: failed (robocopy exit code $LASTEXITCODE)." }
            # Legacy BIOS boot code in the MBR and the partition boot sector, as MakeWinPEMedia writes it.
            $bootsect = "$adk\Deployment Tools\amd64\BCDBoot\bootsect.exe"
            & $bootsect /nt60 "${bootLetter}:" /force /mbr | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'bootsect failed' }
            # Find-ContentRoot recognizes the stick by its Images folder; capture media saves there too.
            New-Item -ItemType Directory -Path "${dataLetter}:\Images" -Force | Out-Null
            if ($copyPlan) {
                # The answer files, the image each one names, and what they use (or, for capture media, Images, Drivers
                # and config), copied in chunks with a progress bar: a 5 GB image takes minutes on a USB stick.
                $copied = Copy-MediaContent -Plan $copyPlan -Destination "${dataLetter}:\"
                Write-Host ('Copied {0} files, {1}, in {2}' -f $copied.FileCount, (Format-MediaSize $copied.Bytes), (Format-MediaDuration $copied.Seconds))
            }
        }
        if ($content) { Write-Host "Answer files on the stick: $(($content.AnswerFiles | ForEach-Object Name) -join ', ')" }
        # The vendor WinPE packs on the stick too, so WinPE can load them with drvload when boot.wim lacks a driver.
        foreach ($pack in $vendorPacks) {
            $peOnStick = "${dataLetter}:\Drivers\_WinPE\$(Split-Path $pack.Path -Leaf)"
            New-Item -ItemType Directory -Path $peOnStick -Force | Out-Null
            Copy-Item -Path (Join-Path $pack.Path '*') -Destination $peOnStick -Recurse -Force
        }
        Write-Host ''
        Write-Host '==============================================' -ForegroundColor Green
        Write-Host ' USB media ready' -ForegroundColor Green
        Write-Host " WinPE on ${bootLetter}:, content on ${dataLetter}: (DEPLOY)" -ForegroundColor Green
        Write-Host ' Eject the stick in Windows before you unplug it.' -ForegroundColor Green
        Write-Host ' Boot menu key: Dell F12, HP F9, Lenovo F12 (or the Novo button), Microsoft Surface: hold Volume down' -ForegroundColor Green
        Write-Host '==============================================' -ForegroundColor Green
    }
}
