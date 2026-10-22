# Architecture

A SmartDeploy-style imaging tool built on Microsoft's own tooling (Windows ADK,
WinPE, DISM, Sysprep) and driven by PowerShell. No third-party runtime.

## The four pieces

| Piece | Runs on | What it does |
|---|---|---|
| **Capture** (`src/Capture-GoldenImage.ps1`) | WinPE, booted on the reference VM | Captures the sysprepped Windows partition to `Images\<name>.wim`. |
| **Driver library** (`config/driver-catalog.json` + `Drivers\`) | The share or USB | Maps a PC's identity (maker, model, SKU / Lenovo machine type) to a driver folder. |
| **Deploy** (`src/Deploy-Image.ps1`) | WinPE, booted on the target PC | Detects the model, partitions the disk, applies the WIM, injects the matching drivers offline, writes boot files and unattend. |
| **Media builder** (`src/New-DeploymentMedia.ps1`) | Admin workstation with the ADK | Builds the WinPE boot image with the tool baked in, then a bootable USB, an ISO, or a `boot.wim` for WDS/PXE. |

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

1. Detect hardware and content root; pick image and task from settings (or prompt).
2. `diskpart`: wipe disk 0, create EFI (260 MB, FAT32), MSR (16 MB), Windows (NTFS), Recovery (1 GB).
3. `DISM /Apply-Image` the WIM to `W:`.
4. `DISM /Image:W:\ /Add-Driver /Driver:<pack> /Recurse` for the matched pack.
5. Copy `unattend.xml` to `W:\Windows\Panther\` (computer name, locale, domain join, local admin).
6. `bcdboot W:\Windows /s S: /f UEFI`.
7. Write a log to `W:\Windows\Temp\Deploy.log` and the share, then reboot.

## Driver packs

Download the official enterprise packs: Dell "Driver Packs for Enterprise Client
OS Deployment" (CAB), HP "SoftPaq Driver Packs" (EXE extracts to INF), Lenovo
"SCCM Driver Packs". Extract them to `Drivers\<Maker>\<Model>\`. A later step can
automate this from each vendor's catalog XML (Dell `DriverPackCatalog.cab`,
HP `HPClientDriverPackCatalog.cab`, Lenovo `catalogv2.xml`).

## Not in v1

GUI console, multicast, BitLocker pre-provisioning, BIOS-to-UEFI conversion,
legacy BIOS/MBR, app installs after deployment, user state migration (USMT).
