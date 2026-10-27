# Architecture

A SmartDeploy-style imaging tool built on Microsoft's own tooling (Windows ADK,
WinPE, DISM, Sysprep) and driven by PowerShell. No third-party runtime.

## The four pieces

| Piece | Runs on | What it does |
|---|---|---|
| **Reference prep** (`src/Prepare-Reference.ps1`) | Inside the reference machine | Checks for a pending reboot, BitLocker and per-user Store apps (sysprep error 0x80073cf2), then runs sysprep and shuts down. |
| **Capture** (`src/Capture-GoldenImage.ps1`) | WinPE, booted on the reference VM | Captures the sysprepped Windows partition to `Images\<name>.wim`; with `-NewVersion` it replaces an existing image and keeps the old one in `Images\Previous\`. |
| **Image versions** (`src/ImageVersions.psm1`, `src/Invoke-ImageVersion.ps1`) | WinPE and the admin workstation | Keeps earlier images, rolls back, and resolves the version an answer file is pinned to. |
| **Driver library** (`config/driver-catalog.json` + `Drivers\`) | The share or USB | Maps a PC's identity (maker, model, SKU / Lenovo machine type) to a driver folder. |
| **Deploy** (`src/Deploy-Image.ps1`) | WinPE, booted on the target PC | Detects the model, partitions the disk, applies the WIM, injects the matching drivers offline, writes boot files and unattend. |
| **Media builder** (`src/New-DeploymentMedia.ps1`) | Admin workstation with the ADK | Builds the WinPE boot image with the tool baked in, then a bootable USB, an ISO, or a `boot.wim` for WDS/PXE. Checks the ADK first with `src/AdkCheck.psm1`: the ADK folder from the registry (`KitsRoot10`), Deployment Tools (`DandISetEnv.bat`, `oscdimg.exe`, `efisys_noprompt.bin`), the WinPE add-on (`copype.cmd`, `MakeWinPEMedia.cmd`, `winpe.wim`, each optional component it adds), and whether the ADK and add-on versions match. |
| **Image updates** (`src/Update-OfflineImage.ps1`) | Admin workstation | Adds .msu/.cab updates to every edition of a captured WIM offline (mount, add, clean up, commit, export), keeps the old version in `Images\Previous\`. |
| **WDS publisher** (`src/Publish-WdsBootImage.ps1`) | Admin workstation or the WDS server | Sets up WDS if asked and publishes `boot.wim` as the default UEFI PXE boot image. |
| **Multicast** (`src/Set-WdsMulticast.ps1`) | Admin workstation or the WDS server | Creates a WDS multicast namespace over the content root so a room of PCs downloads an image once, together. |
| **Admin console** (`src/Console/`) | Admin workstation | WPF GUI over the content root: images, driver library (import and matching rules), media builds, deploy settings, a live deployment dashboard, deployment logs. |

## Admin console

`ImagingConsole.ps1` is a WPF window loaded from `MainWindow.xaml`; all file
work lives in `ConsoleData.psm1` so it is testable without a UI. The console
edits the content root directly, so a USB stick or the share is managed the
same way. Media builds run `New-DeploymentMedia.ps1` in a separate elevated
window with `-Force` (the console already confirmed the erase) and bake in the
content root's `deploy-settings.json`. `Deploy-Image.ps1` re-reads that file
from the content root at run time, so settings such as the default image take
effect without rebuilding media.

## Capture wizard

`CaptureWizard.ps1` writes `config\capture.json` (name, description,
compression, split, unattended) and calls `New-DeploymentMedia.ps1
-CaptureConfig`, which bakes it into WinPE. `startnet.cmd` runs
`Capture-GoldenImage.ps1 -ConfigPath` when that file exists, and runs the deploy
otherwise, so capture media and deploy media share one build path.

For a Hyper-V VM (`-BootVM`), the ISO is built with `efisys_noprompt.bin` and
without `boot\bootfix.bin`, so it boots without a key press on UEFI and BIOS.
The script checks the VM is off, attaches the ISO, puts the DVD first in the boot
order (boot device on generation 2, startup order on generation 1) and starts the VM. It then
waits for the unattended capture to shut the VM down, ejects the ISO and sets
the boot order back to the disk. The ISO is kept under `%ProgramData%` because
Hyper-V cannot mount one from a share without delegation.

## Image versions

`ImageVersions.psm1` (used in WinPE and by the console) treats every folder
`Images\Previous\<name>_<stamp>\` that holds the image's file as a version. The
stamp (`yyyyMMdd-HHmm`, `-2` for a second one in the same minute) is the
version's name. A folder holds the image's parts with their original names, its
`<name>.updates.json` history when there is one, and `version.json` (reason,
note). Backups made by the offline updater have no `version.json` and are listed
as kept by an offline update.

- `Save-ImageVersion` copies the image to a new version, or with `-Move`
  empties the slot first (recapture, rollback). A failed move is put back. The
  update history is copied in both cases, so it stays with the image slot.
- `Restore-ImageVersion` moves the current image to a new version and then
  *links* the chosen one back (a hard link, or a copy where the volume can't), so
  answer files pinned to it keep a valid path and a rollback takes no extra space.
  Only image files are linked; the update history is copied, since it is rewritten
  in place. Nothing writes an image in place, so the two names can share data.
  If the link fails, the partial copy is removed and the old current image moved back.
- Retention: `Invoke-ImageVersionRetention` (in `ImageVersions.psm1`, so WinPE can
  use it too) keeps the newest N and deletes older versions that no answer file is
  pinned to, plus anything passed as `-Protect`. N is the image's own limit in
  `Images\<name>.versions.json` if it has one, else `versionsToKeep` in
  deploy-settings.json, else 0 (keep all). It runs after a copy, a rollback, and a
  replacing capture (`Capture-GoldenImage.ps1`, when the content root is known).
- `Test-ImageHardLinks` tells the rollback whether it can link; the console and
  `Invoke-ImageVersion.ps1` warn when it can't and the rollback will copy.
- `Capture-GoldenImage.ps1 -NewVersion` captures into `Images\.capture-<name>\`,
  then archives the old image and moves the new one in, so a failed capture
  leaves the current image alone.
- `Deploy-Image.ps1` reads `<image><version>`; when it is set it deploys
  `Get-ImageVersionPath` (the file in the version folder) instead of the current image.
- Deleting and pruning (`Remove-ImageVersions`, `Get-ImageVersionsToDelete` in
  `ConsoleData.psm1`) refuse versions an answer file names.
## Offline image updates

`UpdateImage.ps1` (the console dialog) lists packages from `Updates\` with
`Get-UpdatePackageRows` and starts `Update-OfflineImage.ps1` through
`-EncodedCommand`, because `-File` can't pass the package list as an array. The
script works on a local copy in `%ProgramData%\ImagingConsole\Servicing` (DISM
mounts must be on a local NTFS volume). Per index: `DISM /Mount-Image`,
`/Add-Package` for each package in order (exit 0x800F081E, not applicable, is a
warning), optional `/Cleanup-Image /StartComponentCleanup [/ResetBase]`,
`/Unmount-Image /Commit`. Then every index is exported to a new WIM to reclaim the
space of superseded components, and only after the export is verified is the
original moved to `Images\Previous\` and replaced. Any failure before that
discards the mount and leaves the original alone. `Add-ImageServicingRecord`
appends the packages, results and resulting builds to `Images\<name>.updates.json`,
which the Images tab reads.

## Why the golden image is hardware-independent

Build the reference image in a **VM** (Hyper-V), not on real hardware, so it
contains no OEM drivers. Run `sysprep /generalize /oobe /shutdown` before
capture. All hardware specifics arrive at deploy time from the driver library.
This is the same idea SmartDeploy's "Platform Packs" use.

## Model detection

Read from WMI inside WinPE:

- `Win32_ComputerSystem.Manufacturer` and `.Model` (Dell, HP, most others)
- `Win32_ComputerSystemProduct.Version` (Lenovo friendly name, e.g. "ThinkPad T14 Gen 4")
- `Win32_ComputerSystem.Model` first 4 chars (Lenovo machine type, e.g. "21HD")
- `MS_SystemInformation.SystemSKU` (Dell SKU / HP product ID, more exact than the name)

The catalog is matched most-specific first: SKU, then exact model, then a
wildcard model pattern, then a per-maker fallback (e.g. a generic
storage/network pack), then nothing (Windows inbox drivers only).

## Delivery modes

All three use the same WinPE image and the same `Deploy-Image.ps1`. Only the
**content root** differs, and the script finds it by itself:

1. **Offline USB**: the boot partition (FAT32) holds WinPE, a second NTFS
   partition labelled `DEPLOY` holds `Images\`, `Drivers\`, `config\`.
   Two partitions because UEFI needs FAT32 to boot and a WIM is usually over 4 GB.
   The stick is MBR with the FAT32 partition active and `bootsect /nt60 /mbr`
   boot code, so it also boots legacy BIOS PCs.
2. **LAN share**: WinPE boots from a small USB or ISO, then maps
   `\\server\Deploy` using `config/deploy-settings.json`.
3. **PXE**: the same `boot.wim` is published to WDS by `Publish-WdsBootImage.ps1`
   (or served by iPXE/wimboot); it then behaves like the LAN share mode.
   WDS serves BIOS (`pxeboot.n12`) and UEFI (`wdsmgfw.efi`) clients from the
   same boot image.
   The script runs its WDS steps on the server (locally, or with `Invoke-Command`
   after copying the WIM through `ADMIN$`): optionally install the role and
   `wdsutil /Initialize-Server /Standalone`, then remove any boot image with the
   same name, `Import-WdsBootImage`, and make it the default `x64uefi` boot image.
   It reads server state from the WDSServer service, the `REMINST` share and the
   WDS cmdlets, never from `wdsutil` text, which is localized.

Every medium boots both UEFI and legacy BIOS. The ISO carries both
`etfsboot.com` and `efisys.bin`.

### Multicast

`Set-WdsMulticast.ps1` creates a WDS namespace with the built-in `WDS` content
provider whose config string is the content root's local folder on the server
(`wdsutil /New-Namespace /ContentProvider:WDS /ConfigString:D:\Deploy`), as AutoCast
or ScheduledCast (client count and/or start time), and sets the transport server's
slow-client policy (`/Set-TransportServer /MulticastSessionPolicy`). It runs on the
server like the WDS publisher, and judges `wdsutil` by exit code only.
The room monitor (`-Action Monitor`) reads the WDS transport COM API
(`WdsTptMgmt.WdsTransportManager`: namespace > contents > sessions > clients) for
each PC's percent complete, address and join time, so it doesn't parse localized
text; `ConvertTo-MulticastView` (ConsoleData) turns that into the console's rows and
summary. `-Action Disconnect` calls `DisconnectClient` with the *fail* type, so
`wdsmcast` exits with an error and the deploy falls back to the share by itself.

In WinPE, `Get-MulticastPlan` (DeployCommon) decides per deploy: multicast is on,
the content came from the share, the image is under the content root and is not
split. After partitioning, `Receive-MulticastImage` runs
`wdsmcast /Transfer-File /Namespace:<name> /SourceFile:Images\<image>.wim` with the
share account into `W:\_Multicast`, DISM applies from there, and the folder is
deleted. On failure it falls back to applying from the share unless fallback is off.

## Deploy sequence

1. Detect hardware and content root; choose the answer file (the default, or a
   menu in interactive mode); map its extra shares.
2. Check everything before touching the disk: image, driver pack, applications,
   password files, computer name. Show a summary, then either a countdown
   (unattended) or a YES prompt (interactive).
3. `diskpart` (script from `New-DiskpartScript`): wipe the disk and create the layout for the
   firmware WinPE booted with (see below).
4. `DISM /Apply-Image` the WIM to `W:`.
5. `DISM /Image:W:\ /Add-Driver /Driver:<pack> /Recurse` for the matched pack.
6. Generate `W:\Windows\Panther\unattend.xml` from the answer file: computer name,
   time zone, owner, product key, domain or workgroup join, locales, OOBE pages,
   Administrator password, FIRSTLOGON commands. Setup blanks the passwords in its
   cached copy after use, and FirstBoot.ps1 deletes it.
7. Stage the applications in `W:\Deploy\Apps`, plus `FirstBoot.ps1` and
   `firstboot.json`, and write `SetupComplete.cmd` to run it.
8. Run POSTIMAGE tasks, then `bcdboot W:\Windows /s S: /f UEFI` (or `/f BIOS`).
9. Write a log to `W:\Windows\Temp\Deploy.log` and the content root, and
   `Reports\Drivers\<serial>.json` (which driver pack the PC got and how it was
   matched), then reboot or shut down.

### UEFI and legacy BIOS

The deploy reads `PEFirmwareType` to see how WinPE booted and partitions to match,
because a PC can only boot Windows the way its firmware starts it:

| Firmware | Disk | Partitions | Boot files |
|---|---|---|---|
| UEFI | GPT | EFI 260 MB FAT32 (S:), MSR 16 MB, Windows (W:), Recovery 1 GB | `bcdboot /f UEFI` |
| Legacy BIOS | MBR | System 100 MB NTFS, active (S:), Windows (W:), Recovery 1 GB, type 27 | `bcdboot /f BIOS` |

So the firmware mode the operator boots the USB stick or PXE in decides the
result. A UEFI PC booted through CSM/legacy deploys as MBR; the log warns about
it. The image is the same either way: a WIM captured on UEFI deploys to BIOS and
the other way round. On BIOS the log also warns when the disk is over 2 TB (MBR
only uses the first 2 TB) and when the image is Windows 11, which installs on
BIOS but is not supported there by Microsoft.

On first boot, `FirstBoot.ps1` (as SYSTEM, before logon) installs the
applications in order, applies the options, runs FIRSTBOOT tasks and removes
`C:\Deploy`.

### Status reporting

`DeployStatus.psm1` is shared by WinPE, first boot and the console. As soon as
the content root is found, `Deploy-Image.ps1` starts a status record and
rewrites `Status\<id>.json` (write to `.tmp`, then rename) plus `Status\<id>.log`
at each step; `<id>` is the BIOS serial, or `MAC-<mac>` for placeholder serials.
`Resolve-StatusTarget` picks the folder: the content root's `Status`, or
`reporting.path` from `deploy-settings.json`, reached through the share's `Z:`
when it lies under the share and mapped as `R:` otherwise. DISM's apply runs
through `Invoke-NativeWithProgress`, which polls its output every 15 seconds
for a percentage and doubles as a heartbeat. Reporting never fails a deployment:
a write error is one warning in the log.

When the status folder has a UNC path, `firstboot.json` carries it and the id,
WinPE leaves the record Running at 90 %, and `FirstBoot.ps1` resumes it
(`Resume-DeployStatus`, retried for a minute while the network comes up) and
finishes it at 100 %. Application failures are recorded as warnings, so the PC
ends as Warning instead of Succeeded.

### Post-deploy checks

`PostDeployChecks.psm1` is split so it can be tested off Windows. In WinPE,
`New-PostDeployCheckPlan` writes what the PC should look like into
`firstboot.json` (`checks`: name, membership, domain, BitLocker and device error
modes, applications and their `detect` rules). At the end of `FirstBoot.ps1`,
`Get-PostDeployFacts` reads the PC (`Win32_ComputerSystem`,
`Test-ComputerSecureChannel`, `Win32_PnPEntity` with a non-zero
`ConfigManagerErrorCode`, the Uninstall registry keys, `Get-BitLockerVolume`),
`Invoke-PostDeployCheck` compares the two and returns Passed, Failed, Warning
or Skipped per check, and `Set-DeployCheckResult` (in `DeployStatus.psm1`)
stores them on the status record as `checks`, `checkResult` and `checkSummary`.
Failed checks are one warning that starts with `Post-deploy checks:`, so a
re-run replaces it. FirstBoot copies both modules, `Test-Deployment.ps1` and
`checks.json` (plan, status folder and id, installer exit codes) to
`C:\ProgramData\ImagingTool`, where `Test-Deployment.ps1` re-runs the checks
and updates the record; it keeps the original finish time.

The console's Dashboard tab reads the folder every 10 seconds with
`Get-DeploymentStatus`, which marks a Running record with no update for 45
minutes as Stalled.

The console's answer file editor (`src/Console/AnswerEditor.ps1` + `.xaml`)
loads an answer object, shows each section as a form, and saves through
`Save-AnswerFromEditor`, which validates it, writes typed passwords to
`config\secrets\<answer>-*.txt` and exports the XML.

`AnswerFile.psm1` holds the parsing, validation, naming, unattend generation and
SmartDeploy import. It has no WinPE dependencies, so it is unit tested and shared
by the deploy and the console.

## Driver packs

The driver pack builder (`src/Console/DriverPacks.psm1`, the console's
**Download from vendor...** window, and `src/Get-DriverPacks.ps1`) uses each
vendor's public catalog of enterprise driver packs:

| Maker | Catalog | Pack | Matched by |
|---|---|---|---|
| Dell | `downloads.dell.com/catalog/DriverPackCatalog.cab` | .cab or self-extracting .exe (`/s /e=<dir>`) | system ID = `SystemSKU` |
| HP | `hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab` | SoftPaq .exe (`/s /e /f <dir>`) | platform ID = baseboard product |
| Lenovo | `download.lenovo.com/cdrt/td/catalogv2.xml` | SCCM pack .exe (`/VERYSILENT /DIR=<dir> /EXTRACT=YES`) | machine type |

Catalogs are cached for a day in `%LOCALAPPDATA%\ImagingConsole\VendorCatalogs`.
For each model and OS only the newest x64 pack is offered (highest Windows
release, then newest date; Dell WinPE packs are skipped). Installing a pack:

1. Downloads it with BITS (Invoke-WebRequest as a fallback) to a `.part` file.
2. Checks the catalog's SHA256 (or MD5 for older Dell and HP entries). Lenovo
   lists a hash only for some packs; when there is none, only the signature is checked.
3. Runs a vendor .exe only if it has a valid Authenticode signature from that vendor.
4. Extracts to `Drivers\<Maker>\<Model>.new`, checks it has .inf files, then
   replaces the old folder, so a failed update keeps the drivers you had.
5. Writes `pack.json` (vendor, OS, release, version, URL) in the folder; the
   window uses it to show what is installed and which models have a newer pack.
6. Adds catalog entries for every SKU or machine type the pack covers plus its
   model name, at the top of `driver-catalog.json`, replacing older entries
   with the same key.

The downloads run in their own PowerShell window (`Get-DriverPacks.ps1
-JobFile`), like media builds, so the console stays usable.

Packs can still be added by hand: extract one to `Drivers\<Maker>\<Model>\`
and import it from the Driver Library tab.

### Unknown models report

Every deployment writes `Reports\Drivers\<serial>.json` on the content root:
the PC's maker, model, SKU / machine type, computer name, and the driver
result from `Find-DriverCatalogMatch` (the same matching as the deploy):
`Matched`, `InboxOnly` (a catalog entry with no folder), `Fallback` (maker
fallback), `None`, or `MissingFolder`. One file per PC, so a reimage
replaces it. Writing it never fails a deployment.

`src/Console/DriverReport.psm1` reads these files and re-checks each PC against
the current catalog and `Drivers\` folder, so a model leaves the report as soon
as the library covers it. The rest are grouped by maker, model and SKU / machine
type, most PCs first. For Dell, HP and Lenovo it looks the model up in the
vendor catalog (SKU or machine type, then model name). The console's
**Unknown models...** window ticks every model that has a pack and hands them to
the same download job as **Download from vendor...**. **Use inbox drivers**
adds a catalog entry with no folder, keyed on the SKU, machine type or model.
`Get-DriverPacks.ps1 -UnknownModels [-List]` does the same from the command line.

PCs already deployed keep the drivers they got. Reimage them, or install the
pack on them by other means, once it is in the library.

## Not in v1

A deploy-time GUI on the target PC (it uses a console prompt), multicast, BitLocker pre-provisioning, BIOS-to-UEFI conversion,
user state migration (USMT) and SmartDeploy's wipe-and-load / SmartMigrate disk options,
static IP, display settings, Azure AD join, and a management agent.
