<#
.SYNOPSIS
    Deploys a Windows image to this PC from WinPE, driven by an answer file, and injects the matching OEM drivers.
.DESCRIPTION
    Launched by startnet.cmd. Finds content on a USB volume labelled DEPLOY, or on the network share in
    deploy-settings.json (LAN or PXE boot). Reads an answer file from <content root>\AnswerFiles: image,
    applications, disk, regional settings, naming, domain join, tasks and extra shares.
    Wipes the target disk. UEFI/GPT only.
.EXAMPLE
    X:\Deploy\Deploy-Image.ps1 -AnswerFile W11-Office-FR -NoPrompt
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = 'X:\Deploy\config\deploy-settings.json',
    [string]$AnswerFile,        # name in AnswerFiles\ without .xml; defaults to defaultAnswerFile in settings
    [string]$ComputerName,      # overrides the answer file's naming
    [switch]$NoPrompt           # no countdown or confirmation, whatever the answer file's mode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AppPack.psm1') -Force

function Resolve-ContentPath([string]$Root, [string]$Path) {
    # Answer file paths are relative to the content root unless they are absolute (Y:\..., \\server\...).
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
}

function Select-AnswerFile([string]$Root, [string]$Default, [bool]$Interactive) {
    $files = @(Get-ChildItem -Path (Join-Path $Root 'AnswerFiles') -Filter *.xml -File | Sort-Object Name)
    if (-not $files) { throw "No answer files in $Root\AnswerFiles." }
    if (-not $Interactive -or $files.Count -eq 1) {
        if ($Default) { return $Default }
        return $files[0].BaseName
    }
    Write-Host ''
    Write-Host 'Answer files:'
    for ($i = 0; $i -lt $files.Count; $i++) {
        $mark = if ($files[$i].BaseName -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $files[$i].BaseName, $mark)
    }
    $pick = Read-Host 'Number to deploy (Enter for the default)'
    if (-not $pick -and $Default) { return $Default }
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) { return $files[$n - 1].BaseName }
    throw "No answer file number '$pick'."
}

function Wait-Countdown([int]$Seconds) {
    # Unattended mode: start after a short countdown that any key cancels, like SmartDeploy's unattend delay.
    for ($s = $Seconds; $s -gt 0; $s--) {
        Write-Host -NoNewline "`rStarting in $s s. Press any key to cancel. "
        for ($t = 0; $t -lt 10; $t++) {
            if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); Write-Host ''; return $false }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    $true
}

function Invoke-Phase([string]$Phase, $Answer, [string]$Root) {
    # POSTIMAGE tasks run here in WinPE with the new Windows at %OSDRIVE% (W:) and content at %DEPLOYROOT%.
    $env:OSDRIVE = 'W:'
    $env:DEPLOYROOT = $Root.TrimEnd('\')
    foreach ($t in $Answer.Tasks | Where-Object Phase -eq $Phase) {
        Invoke-Native -FilePath 'cmd.exe' -ArgumentList @('/c', $t.Command)
    }
}

$root = $null; $hw = $null; $answer = $null
$status = 'FAILED'
try {
    $hw = Get-HardwareIdentity
    Write-DeployLog ("Hardware: {0} | {1} | type {2} | SKU {3} | serial {4} | UEFI {5}" -f
        $hw.Maker, $hw.Model, $hw.MachineType, $hw.Sku, $hw.Serial, $hw.IsUefi)
    if (-not $hw.IsUefi) { throw 'This PC booted WinPE in legacy BIOS mode. Switch the firmware to UEFI and boot again.' }

    $root = Find-ContentRoot -SettingsPath $SettingsPath

    # Settings on the content root (edited in the console) win over the copy baked into the media.
    $rootSettings = Join-Path $root 'config\deploy-settings.json'
    $settings = Get-Content -Raw $(if (Test-Path $rootSettings) { $rootSettings } else { $SettingsPath }) | ConvertFrom-Json

    if (-not $AnswerFile) { $AnswerFile = Select-AnswerFile -Root $root -Default $settings.defaultAnswerFile -Interactive (-not $NoPrompt) }
    $answer = Read-AnswerFile -Path (Join-Path $root "AnswerFiles\$AnswerFile.xml")
    Write-DeployLog "Answer file: $($answer.Name) ($($answer.Mode))"

    foreach ($share in $answer.Shares) {
        $pw = if ($share.PasswordFile) { Read-SecretFile -ContentRoot $root -RelativePath $share.PasswordFile } else { $null }
        $user = if ($share.Domain -and $share.Username) { "$($share.Domain)\$($share.Username)" } else { $share.Username }
        Mount-NetworkShare -LocalName $share.LocalName -RemoteName $share.RemoteName -User $user -Password $pw
    }

    $imagePath = Resolve-ContentPath $root $answer.ImageFile
    if (-not (Test-Path $imagePath)) { throw "Image not found: $imagePath" }

    $driverRoot = Resolve-ContentPath $root $answer.DriverRoot
    $driverPack = Resolve-DriverPack -Identity $hw -CatalogPath (Join-Path $root 'config\driver-catalog.json') -DriverRoot $driverRoot

    # Applications are checked now, before the disk is wiped.
    $appRoot = Resolve-ContentPath $root $answer.AppLocation
    # Apps limited to other makers or models (Dell Command Update on a Lenovo) are left out.
    $apps = @($answer.Applications | ForEach-Object { Get-AppDefinition -AppRoot $appRoot -Name $_ } | Where-Object {
        if (Test-AppRequirement -Definition $_ -Identity $hw) { return $true }
        Write-DeployLog "Skipping application $($_.name): it is for $((@($_.requirements.makers) + @($_.requirements.models)) -join ', ') only"
        $false
    })

    $joinPassword  = if ($answer.Membership -eq 'Domain') { Read-SecretFile -ContentRoot $root -RelativePath $answer.JoinPasswordFile } else { $null }
    $adminPassword = if ($answer.EnableAdministrator) { Read-SecretFile -ContentRoot $root -RelativePath $answer.AdminPasswordFile } else { $null }

    $interactive = -not $NoPrompt -and $answer.Mode -eq 'Interactive'
    if (-not $ComputerName) {
        $wmiValue = try { Get-WmiNamingValue -Query $answer.WmiQuery } catch { Write-DeployLog "WMI naming query failed: $($_.Exception.Message)" -Level WARN; $hw.Serial }
        if (-not $wmiValue) { $wmiValue = $hw.Serial }
        $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $wmiValue -Serial $hw.Serial
        if ($answer.NamingMode -eq 'Prompt' -and $interactive) {
            $typed = Read-Host "Computer name (Enter for $ComputerName)"
            if ($typed) { $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $wmiValue -Serial $hw.Serial -Typed $typed }
        }
    }

    $disk = Get-Disk -Number $answer.DiskNumber
    Write-Host ''
    Write-Host "Answer file:  $($answer.Name)"
    Write-Host "Image:        $imagePath (index $($answer.ImageIndex))"
    Write-Host "Drivers:      $(if ($driverPack) { $driverPack } else { 'inbox only' })"
    Write-Host "Applications: $(if ($apps) { ($apps.name -join ', ') } else { 'none' })"
    Write-Host "Name:         $ComputerName"
    Write-Host "Joins:        $(if ($answer.Membership -eq 'Domain') { "domain $($answer.Domain)" } else { "workgroup $($answer.Workgroup)" })"
    Write-Host ("ERASE disk:   {0} {1} ({2:N0} GB)" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Red
    if (-not $NoPrompt) {
        $go = if ($answer.Mode -eq 'Unattended') { Wait-Countdown $answer.UnattendDelay } else { (Read-Host 'Type YES to continue') -eq 'YES' }
        if (-not $go) { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
    }

    # 1. Partition: EFI, MSR, Windows, Recovery (Microsoft's recommended UEFI layout).
    $dp = Join-Path $env:TEMP 'diskpart.txt'
    @"
select disk $($answer.DiskNumber)
clean
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
shrink minimum=1024
format quick fs=ntfs label="Windows"
assign letter=W
create partition primary
format quick fs=ntfs label="Recovery"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
exit
"@ | Set-Content -Path $dp -Encoding ascii
    Invoke-Native -FilePath 'diskpart.exe' -ArgumentList @('/s', $dp)

    # 2. Apply the image. Split images (.swm) need /SWMFile.
    $applyArgs = @('/Apply-Image', "/ImageFile:$imagePath", "/Index:$($answer.ImageIndex)", '/ApplyDir:W:\')
    if ($imagePath -like '*.swm') { $applyArgs += "/SWMFile:$($imagePath -replace '\.swm$', '*.swm')" }
    Invoke-Native -FilePath 'dism.exe' -ArgumentList $applyArgs

    # 3. Inject the OEM driver pack offline.
    if ($driverPack) {
        Invoke-Native -FilePath 'dism.exe' -ArgumentList @('/Image:W:\', '/Add-Driver', "/Driver:$driverPack", '/Recurse', '/ForceUnsigned:No')
    }

    # 4. Unattend generated from the answer file. Setup blanks the passwords in it after use.
    New-Item -ItemType Directory -Path 'W:\Windows\Panther' -Force | Out-Null
    New-UnattendXml -Answer $answer -ComputerName $ComputerName -JoinPassword $joinPassword -AdminPassword $adminPassword |
        Set-Content -Path 'W:\Windows\Panther\unattend.xml' -Encoding utf8
    Write-DeployLog "Unattend written: name $ComputerName, $($answer.Membership)"

    # 5. First boot: applications and FIRSTBOOT tasks run as SYSTEM from SetupComplete.cmd.
    New-Item -ItemType Directory -Path 'W:\Deploy\Apps' -Force | Out-Null
    foreach ($app in $apps) {
        Write-DeployLog "Staging application $($app.name)"
        Copy-Item -Path (Join-Path $appRoot $app.name) -Destination 'W:\Deploy\Apps\' -Recurse -Force
    }
    Copy-Item (Join-Path $PSScriptRoot 'FirstBoot.ps1') 'W:\Deploy\FirstBoot.ps1'
    Copy-Item (Join-Path $PSScriptRoot 'AppPack.psm1') 'W:\Deploy\AppPack.psm1'
    New-FirstBootPlan -Answer $answer -AppDefinitions $apps | ConvertTo-Json -Depth 8 | Set-Content 'W:\Deploy\firstboot.json' -Encoding utf8
    New-Item -ItemType Directory -Path 'W:\Windows\Setup\Scripts' -Force | Out-Null
    "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Deploy\FirstBoot.ps1`r`n" |
        Set-Content -Path 'W:\Windows\Setup\Scripts\SetupComplete.cmd' -Encoding ascii

    # 6. POSTIMAGE tasks, then boot files.
    Invoke-Phase -Phase 'POSTIMAGE' -Answer $answer -Root $root
    Invoke-Native -FilePath 'W:\Windows\System32\bcdboot.exe' -ArgumentList @('W:\Windows', '/s', 'S:', '/f', 'UEFI')

    Write-DeployLog 'Deployment finished'
    $status = 'OK'
}
catch {
    Write-DeployLog $_.Exception.Message -Level ERROR
}
finally {
    # Keep the log on the deployed disk and, when available, on the content root for central review.
    if (Test-Path 'W:\Windows') { Copy-Item 'X:\Windows\Temp\Deploy.log' 'W:\Windows\Temp\Deploy.log' -ErrorAction SilentlyContinue }
    if ($root -and $hw -and $status -ne 'CANCELLED') {
        $logDir = Join-Path $root 'Logs'
        New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-Item 'X:\Windows\Temp\Deploy.log' (Join-Path $logDir ("{0}_{1:yyyyMMdd-HHmm}_{2}.log" -f $hw.Serial, (Get-Date), $status)) -ErrorAction SilentlyContinue
    }
}

if ($status -eq 'OK' -and $answer.Shutdown) { & wpeutil.exe shutdown }
elseif ($status -eq 'OK' -and $answer.Reboot) { & wpeutil.exe reboot }
if ($status -ne 'OK') { exit 1 }
