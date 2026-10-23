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
    [string]$ComputerName,      # overrides the answer file's naming (the wizard still lets the operator change it)
    [switch]$NoPrompt           # no wizard, countdown or confirmation, whatever the answer file's mode
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DeployWizard.psm1') -Force

function Resolve-ContentPath([string]$Root, [string]$Path) {
    # Answer file paths are relative to the content root unless they are absolute (Y:\..., \\server\...).
    if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $Root $Path }
}

function Get-AnswerFileNames([string]$Root) {
    $names = @(Get-ChildItem -Path (Join-Path $Root 'AnswerFiles') -Filter *.xml -File | Sort-Object Name | ForEach-Object BaseName)
    if (-not $names) { throw "No answer files in $Root\AnswerFiles." }
    $names
}

function Select-AnswerFile([string[]]$Names, [string]$Default) {
    # Console fallback when WinPE has no WinForms (media built without WinPE-NetFX).
    if ($Names.Count -eq 1) { return $Names[0] }
    Write-Host ''
    Write-Host 'Answer files:'
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $mark = if ($Names[$i] -eq $Default) { ' (default)' } else { '' }
        Write-Host ("  {0}. {1}{2}" -f ($i + 1), $Names[$i], $mark)
    }
    $pick = Read-Host 'Number to deploy (Enter for the default)'
    if (-not $pick -and $Default) { return $Default }
    $n = 0
    if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $Names.Count) { return $Names[$n - 1] }
    throw "No answer file number '$pick'."
}

$script:Mounted = @{}
function Get-DeployPlan($Root, $Answer, $Hardware) {
    # Everything that must be found before the disk is wiped. The wizard calls this each time an answer file is picked.
    foreach ($share in $Answer.Shares) {
        if ($script:Mounted[$share.LocalName] -eq $share.RemoteName) { continue }
        $pw = if ($share.PasswordFile) { Read-SecretFile -ContentRoot $Root -RelativePath $share.PasswordFile } else { $null }
        $user = if ($share.Domain -and $share.Username) { "$($share.Domain)\$($share.Username)" } else { $share.Username }
        Mount-NetworkShare -LocalName $share.LocalName -RemoteName $share.RemoteName -User $user -Password $pw
        $script:Mounted[$share.LocalName] = $share.RemoteName
    }

    $imagePath = Resolve-ContentPath $Root $Answer.ImageFile
    if (-not (Test-Path $imagePath)) { throw "Image not found: $imagePath" }

    $driverRoot = Resolve-ContentPath $Root $Answer.DriverRoot
    $driverPack = Resolve-DriverPack -Identity $Hardware -CatalogPath (Join-Path $Root 'config\driver-catalog.json') -DriverRoot $driverRoot

    # The wizard offers every application in the library, not only the answer file's.
    $appRoot = Resolve-ContentPath $Root $Answer.AppLocation
    $available = @(Get-ChildItem -Path $appRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'app.json') } | ForEach-Object Name)

    $wmiValue = try { Get-WmiNamingValue -Query $Answer.WmiQuery } catch { Write-DeployLog "WMI naming query failed: $($_.Exception.Message)" -Level WARN; $Hardware.Serial }
    if (-not $wmiValue) { $wmiValue = $Hardware.Serial }

    [pscustomobject]@{
        ImagePath     = $imagePath
        DriverPack    = $driverPack
        AppRoot       = $appRoot
        AvailableApps = $available
        WmiValue      = $wmiValue
        DefaultName   = Resolve-ComputerName -Answer $Answer -WmiValue $wmiValue -Serial $Hardware.Serial
    }
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

    $names = Get-AnswerFileNames -Root $root
    if (-not $AnswerFile) {
        if ($settings.defaultAnswerFile -and ($NoPrompt -or $settings.defaultAnswerFile -in $names)) { $AnswerFile = $settings.defaultAnswerFile }
        elseif ($NoPrompt -or $names.Count -eq 1) { $AnswerFile = $names[0] }
    }

    # -NoPrompt and Unattended answer files start without the wizard. A key pressed during the
    # Unattended countdown opens the wizard instead, so the operator can change anything.
    $answer = $null; $plan = $null; $confirmed = $false
    if ($AnswerFile) {
        $answer = Read-AnswerFile -Path (Join-Path $root "AnswerFiles\$AnswerFile.xml")
        if ($NoPrompt) { $confirmed = $true }
        elseif ($answer.Mode -eq 'Unattended') {
            $plan = Get-DeployPlan -Root $root -Answer $answer -Hardware $hw
            $name = if ($ComputerName) { $ComputerName } else { $plan.DefaultName }
            Write-Host ''
            Get-DeploySummary -Answer $answer -Plan $plan -ComputerName $name -Disk (Get-Disk -Number $answer.DiskNumber) -Applications $answer.Applications |
                ForEach-Object { Write-Host $_ }
            $confirmed = Wait-Countdown $answer.UnattendDelay
            if ($confirmed) { $ComputerName = $name } else { Write-DeployLog 'Countdown cancelled by operator' -Level WARN }
        }
    }

    if (-not $confirmed -and (Test-DeployWizardAvailable)) {
        $choice = Show-DeployWizard -Hardware $hw -AnswerFiles $names -Default $AnswerFile -ComputerName $ComputerName `
            -ReadAnswer { param($Name) Read-AnswerFile -Path (Join-Path $root "AnswerFiles\$Name.xml") } `
            -PreparePlan { param($Answer) Get-DeployPlan -Root $root -Answer $Answer -Hardware $hw }
        if (-not $choice) { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
        $answer = $choice.Answer; $plan = $choice.Plan; $ComputerName = $choice.ComputerName
        $confirmed = $true
    }

    if (-not $answer) { $answer = Read-AnswerFile -Path (Join-Path $root "AnswerFiles\$(Select-AnswerFile -Names $names -Default $settings.defaultAnswerFile).xml") }
    if (-not $plan) { $plan = Get-DeployPlan -Root $root -Answer $answer -Hardware $hw }
    if (-not $ComputerName) {
        $ComputerName = $plan.DefaultName
        if ($answer.NamingMode -eq 'Prompt' -and -not $confirmed) {
            $typed = Read-Host "Computer name (Enter for $ComputerName)"
            if ($typed) { $ComputerName = Resolve-ComputerName -Answer $answer -WmiValue $plan.WmiValue -Serial $hw.Serial -Typed $typed }
        }
    }
    Write-DeployLog "Answer file: $($answer.Name) ($($answer.Mode)), name $ComputerName, disk $($answer.DiskNumber)"

    # Applications are checked now, before the disk is wiped.
    $imagePath = $plan.ImagePath; $driverPack = $plan.DriverPack; $appRoot = $plan.AppRoot
    $apps = @($answer.Applications | ForEach-Object { Get-AppDefinition -AppRoot $appRoot -Name $_ })

    $joinPassword  = if ($answer.Membership -eq 'Domain') { Read-SecretFile -ContentRoot $root -RelativePath $answer.JoinPasswordFile } else { $null }
    $adminPassword = if ($answer.EnableAdministrator) { Read-SecretFile -ContentRoot $root -RelativePath $answer.AdminPasswordFile } else { $null }

    if (-not $confirmed) {
        Write-Host ''
        Get-DeploySummary -Answer $answer -Plan $plan -ComputerName $ComputerName -Disk (Get-Disk -Number $answer.DiskNumber) -Applications $answer.Applications |
            ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like 'ERASE*') { 'Red' } else { 'Gray' }) }
        if ((Read-Host 'Type YES to continue') -ne 'YES') { Write-DeployLog 'Cancelled by operator' -Level WARN; $status = 'CANCELLED'; return }
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
    New-FirstBootPlan -Answer $answer -AppDefinitions $apps | ConvertTo-Json -Depth 5 | Set-Content 'W:\Deploy\firstboot.json' -Encoding utf8
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
