# Architecture

A SmartDeploy-style imaging tool built on Microsoft's own tooling (Windows ADK,
WinPE, DISM, Sysprep) and driven by PowerShell. No third-party runtime.

## The four pieces

| Piece | Runs on | What it does |
|---|---|---|
| **Reference prep** (`src/Prepare-Reference.ps1`) | Inside the reference machine | Checks for a pending reboot, BitLocker and per-user Store apps (sysprep error 0x80073cf2), then runs sysprep and shuts down. |
| **Capture** (`src/Capture-GoldenImage.ps1`) | WinPE, booted on the reference VM | Captures the sysprepped Windows partition to `Images\<name>.wim`. |
| **Driver library** (`config/driver-catalog.json` + `Drivers\`) | The share or USB | Maps a PC's identity (maker, model, SKU / Lenovo machine type) to a driver folder. |
| **Deploy** (`src/Deploy-Image.ps1`) | WinPE, booted on the target PC | Detects the model, partitions the disk, applies the WIM, injects the matching drivers offline, writes boot files and unattend. |
| **Media builder** (`src/New-DeploymentMedia.ps1`) | Admin workstation with the ADK | Builds the WinPE boot image with the tool baked in, then a bootable USB, an ISO, or a `boot.wim` for WDS/PXE. |
| **Admin console** (`src/Console/`) | Admin workstation | WPF GUI over the content root: images, driver library (import and matching rules), media builds, deploy settings, deployment logs. |

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

For a Hyper-V VM (`-BootVM`), the ISO is built with `efisys_noprompt.bin` so
it boots without a key press. The script checks the VM is generation 2 and off,
attaches the ISO, sets the DVD as first boot device and starts the VM. It then
waits for the unattended capture to shut the VM down, ejects the ISO and sets
the boot order back to the disk. The ISO is kept under `%ProgramData%` because
Hyper-V cannot mount one from a share without delegation.

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
2. **LAN share**: WinPE boots from a small USB or ISO, then maps
   `\\server\Deploy` using `config/deploy-settings.json`.
3. **PXE**: the same `boot.wim` is imported into WDS (or served by iPXE/wimboot);
   it then behaves like the LAN share mode.

## Deploy sequence (UEFI/GPT)

1. Detect hardware and content root; choose the answer file (the default, or a
   menu in interactive mode); map its extra shares.
2. Check everything before touching the disk: image, driver pack, applications,
   password files, computer name. Show a summary, then either a countdown
   (unattended) or a YES prompt (interactive).
3. `diskpart`: wipe the disk, create EFI (260 MB, FAT32), MSR (16 MB), Windows (NTFS), Recovery (1 GB).
4. `DISM /Apply-Image` the WIM to `W:`.
5. `DISM /Image:W:\ /Add-Driver /Driver:<pack> /Recurse` for the matched pack.
6. Generate `W:\Windows\Panther\unattend.xml` from the answer file: computer name,
   time zone, owner, product key, domain or workgroup join, locales, OOBE pages,
   Administrator password, FIRSTLOGON commands. Setup blanks the passwords in its
   cached copy after use, and FirstBoot.ps1 deletes it.
7. Stage the applications in `W:\Deploy\Apps`, plus `FirstBoot.ps1` and
   `firstboot.json`, and write `SetupComplete.cmd` to run it.
8. Run POSTIMAGE tasks, then `bcdboot W:\Windows /s S: /f UEFI`.
9. Write a log to `W:\Windows\Temp\Deploy.log` and the content root, and
   `Reports\Drivers\<serial>.json` (which driver pack the PC got and how it was
   matched), then reboot or shut down.

On first boot, `FirstBoot.ps1` (as SYSTEM, before logon) installs the
applications in order, applies the options, runs FIRSTBOOT tasks and removes
`C:\Deploy`.

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
legacy BIOS/MBR, user state migration (USMT) and SmartDeploy's wipe-and-load / SmartMigrate disk options,
static IP, display settings, Azure AD join, and a management agent.
