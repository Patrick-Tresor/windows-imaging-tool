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
| **Remote reimage** (`src/Start-RemoteReimage.ps1` + `src/RemoteReimage.psm1`) | Admin workstation | Queues reimage jobs, wakes PCs with Wake-on-LAN, restarts running PCs into a one-time PXE boot. |
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

## Remote reimage

The pieces meet on the content root, so the admin PC and WinPE never talk directly:

- `Computers\<MAC>.json`: one per PC. Written by the console (manual, CSV, or
  read over WinRM) and by `Deploy-Image.ps1` at the end of every deploy.
- `Reimage\<MAC>.json`: a pending job (answer file, name to keep, expiry).
  `Deploy-Image.ps1` matches it against the MACs of its adapters with an IP
  (`Win32_NetworkAdapterConfiguration`), then moves it to `Reimage\Started\`. The
  move is what `Start-RemoteReimage.ps1` waits for, and it means a PC that network
  boots again later finds no job and gets the normal deploy menu.

Forcing the network boot on a running PC uses the firmware boot manager:
`bcdedit /enum firmware` lists the firmware's boot entries, the network one is
picked by its firmware description (PXE, IPv4, Network, NIC...; IPv4 before IPv6),
and `bcdedit /set {fwbootmgr} bootsequence {id}` makes it the next boot only.
bcdedit's labels are localized (`identifier` / `identificateur`), so the parser
only reads GUIDs, dashed separators and the firmware's own descriptions.

A PC that is off gets a Wake-on-LAN magic packet (6 x `FF`, then the MAC 16 times)
on UDP port 9 (`remote.wakePort`), sent to 255.255.255.255, to its subnet's
directed broadcast when its IP is known, and from its relay PC over WinRM when it
has one. A PC whose firmware boots the network first goes straight to WinPE;
otherwise Windows starts, WinRM answers and it gets the one-time PXE restart.

To skip the F12 prompt only for these PCs, the PC is prestaged in WDS with
`New-WdsClient -DeviceID <MAC> -PxePromptPolicy NoPrompt` and removed with
`Remove-WdsClient` when its job is taken or the wait times out.

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
9. Write a log to `W:\Windows\Temp\Deploy.log` and the content root, then reboot or shut down.

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

Download the official enterprise packs: Dell "Driver Packs for Enterprise Client
OS Deployment" (CAB), HP "SoftPaq Driver Packs" (EXE extracts to INF), Lenovo
"SCCM Driver Packs". Extract them to `Drivers\<Maker>\<Model>\`. A later step can
automate this from each vendor's catalog XML (Dell `DriverPackCatalog.cab`,
HP `HPClientDriverPackCatalog.cab`, Lenovo `catalogv2.xml`).

## Not in v1

A deploy-time GUI on the target PC (it uses a console prompt), multicast, BitLocker pre-provisioning, BIOS-to-UEFI conversion,
legacy BIOS/MBR, user state migration (USMT) and SmartDeploy's wipe-and-load / SmartMigrate disk options,
static IP, display settings, Azure AD join, and a management agent.
