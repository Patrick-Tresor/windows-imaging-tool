# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Capture-GoldenImage.ps1, Prepare-Reference.ps1,
                     Update-OfflineImage.ps1, New-DeploymentMedia.ps1, DeployCommon.psm1, AnswerFile.psm1, Win11Readiness.psm1
src/Console/         ImagingConsole.ps1 (WPF GUI), CaptureWizard.ps1, UpdateImage.ps1, *.xaml, ConsoleData.psm1
config/              default deploy-settings.json, driver-catalog.json, answer-files/Default.xml (commented sample)
winpe/               startnet.cmd (auto-starts the deploy or capture in WinPE)
tests/               *.Tests.ps1 (pwsh -File tests/<name>.Tests.ps1), fixtures/
```

## Admin console

Double-click `ImagingConsole.cmd` on a Windows admin PC (it asks for admin rights).
Pick a **content root** (a local folder, the USB `DEPLOY` volume, or the share)
and click **Create folders** the first time. Then:

- **Images**: see captured images, their size and editions, and which answer
  files use them. **Capture new image...** opens the capture wizard (below).
  **Versions...** (or double-click an image) lists its earlier versions (see
  [Image versions and rollback](#image-versions-and-rollback)).
  **Update image...** adds Windows updates to the selected image (see
  [Updating an image](#updating-an-image)).
- **Answer Files**: create, edit and check deployment profiles, pick the default,
  and **Import SmartDeploy XML...** to convert an existing SmartDeploy answer file.
  **New** and **Edit** (or double-click) open the answer file editor, where every
  setting is a form field: General, Image and disk, Applications (pick and order
  them, or add a new installer), Windows settings, Computer name (with a preview),
  Domain or workgroup, Tasks and Network shares. Passwords are typed into password
  boxes and saved to their own files.
- **Driver Library**: import a vendor pack (folder, .cab or .zip) for a maker and
  model, edit how PCs are matched (SKU, machine type, model, pattern), and see
  which entries are missing drivers.
- **Media**: build a USB stick, ISO or PXE `boot.wim` in one click. The tab shows
  whether the Windows ADK and its WinPE add-on are installed (and their version),
  with a **Download ADK** button when they aren't. Media builds and the capture
  wizard refuse to start until both are there.
- **Deploy Settings**: the network share WinPE uses to find the content root,
  and the default answer file.
- **Deployment Logs**: one log per deployed PC, with result and full text.

Content root (USB `DEPLOY` partition or `\\server\Deploy`):

```
Images\        Win11-24H2-Enterprise.wim
               Previous\Win11-24H2-Enterprise_20261015-1430\  (earlier versions)
Images\        Win11-24H2-Enterprise.wim (+ .updates.json history), Previous\ (versions before an update)
Updates\       .msu / .cab packages from the Microsoft Update Catalog
Drivers\       Dell\Latitude 5440\...  HP\EliteBook 840 G9\...  Lenovo\ThinkPad T14 Gen 4\...
AnswerFiles\   Default.xml, W11-Office-FR.xml, ...
Applications\  Zoom\app.json + installer, Teams\app.json + installer, ...
config\        deploy-settings.json, driver-catalog.json, secrets\ (password files)
Logs\          one log per deployed PC or capture
```

## Answer files

An answer file (`AnswerFiles\<name>.xml`) is one deployment profile. Edit it in
the console; the format is documented in the commented
[config/answer-files/Default.xml](config/answer-files/Default.xml). It sets:

- **mode**: `Interactive` (pick the answer file and type YES) or `Unattended`
  (start after `unattendDelay` seconds unless a key is pressed).
- **image** and index, **disk** number, **drivers** root.
- **Windows 11 check** (`image/windows11Check`): `Block` (default), `Warn` or
  `Off`. See below.
- **applications** installed in order at first boot (see below).
- **product key**, **user information**, **regional** settings (time zone and
  locales such as `fr-CA`).
- **computer naming**: a WMI query (for example the serial from
  `Win32_SystemEnclosure`) with a prefix, a custom scheme like `A########`
  (`#` = random digit, `{SERIAL}` = BIOS serial), or a prompt.
- **domain or workgroup**, with OU and join account.
- **tasks** by phase: `POSTIMAGE` (in WinPE, `%OSDRIVE%` is the new Windows
  drive, `%DEPLOYROOT%` the content root), `FIRSTBOOT` (as SYSTEM after the
  applications), `FIRSTLOGON` (when the first user logs on).
- extra **shares** to map in WinPE, **options** (disable System Restore, enable
  the built-in Administrator), and reboot or shut down when done.

### Windows 11 readiness check

When the answer file's image is Windows 11 (build 22000 or later, read from
the WIM), WinPE checks the PC before the disk is erased: TPM 2.0 present and
on, UEFI boot, Secure Boot, a processor on Microsoft's supported list (Intel
8th gen Core and later, AMD Ryzen 2000 desktop and later), 2 cores at 1 GHz,
4 GB of memory and a 64 GB target disk. Each result goes to the deploy log and
the summary shows `Windows 11: ready` or `NOT READY: TPM 2.0, Processor`.

- **Block**: a failed requirement stops the deploy with nothing erased. Fix it
  in the firmware (often TPM or PTT/fTPM is just turned off), use a Windows 10
  answer file, or run `Deploy-Image.ps1 -IgnoreWindows11Check` to deploy anyway.
- **Warn**: the problems are logged and shown, and the deploy carries on.
- **Off**: no check.

Secure Boot turned off, a processor the check cannot match (some Celeron,
Pentium and Xeon models) and an image whose version cannot be read only warn;
they never block.

**Passwords never go in the answer file.** Each `passwordFile` names a text file
under the content root, usually `config\secrets\`. Anyone who can read the share
can read them, so use a join account that can only join computers to one OU, and
restrict who can read `config\secrets`.

**Applications** are folders under `Applications\` with the installer and an
`app.json`. The editor's **New application...** creates them: pick the installer
file or folder, and it suggests the silent command for .msi, .exe, .msix and .ps1:

```json
{ "command": "msiexec /i ZoomInstallerFull.msi /qn", "successCodes": [0, 3010] }
```

The command runs in the application's folder, as SYSTEM, from
`SetupComplete.cmd`. (`SetupComplete.cmd` does not run on images activated with
an OEM product key.) Results go to `C:\Windows\Temp\FirstBoot.log`.

**Importing from SmartDeploy** keeps the mode, delay, image name, application
order, regional settings, naming, domain join, tasks, shares and completion
options. SmartDeploy encrypts its passwords, so they are never carried over; the
import lists the password files to create, the `.spk` application packs to
rebuild as folders, and anything it can't convert (static IP, client agent,
platform packs, unsupported system properties).

## Image versions and rollback

Earlier copies of an image are kept in `Images\Previous\<name>_<yyyyMMdd-HHmm>\`,
so a bad capture or update never leaves you without a working image:

- **Recapture** under the same name by ticking *replace it and keep the old one*
  in the capture wizard. The old image moves to `Previous` only once the new
  capture has succeeded.
- **Offline updates** keep the image they replace in the same place.
- **Keep a copy of current** (Images > Versions...) takes a snapshot, for
  example before you try something, with a note saying what it is.
- **Roll back to selected** makes an earlier version current again for every
  answer file that doesn't name a version. It links the file rather than copying
  it, so it is quick and uses no extra space. The image you roll away from is kept
  as a version too, so a rollback can itself be undone.
- **Keep newest** deletes the oldest unpinned versions after a copy, a rollback or
  a replacing capture, keeping the newest N. Set it for one image in the Versions
  dialog (blank uses the default), or for all images as *Versions to keep* on
  Deploy Settings. 0 keeps every version, which is the default. The version you
  just rolled back to is never deleted by this.
- **Pin an answer file** to a version on its *Image and disk* page (the
  `<image><version>` element). Use it to keep a lab or a pilot group on a
  known-good build while the current image moves on, or the other way round.
- **Delete selected** and **Delete older** (keep the newest N) free space. Both
  refuse versions an answer file is pinned to.

Copies and rollbacks run in their own window (`src\Invoke-ImageVersion.ps1`)
and write a `VERSION-<name>` log. Each version takes as much space as the image.
## Updating an image

Patch Tuesday does not need a new capture. Download the month's cumulative update
for the image's Windows version (and the .NET cumulative update) from the
[Microsoft Update Catalog](https://www.catalog.update.microsoft.com) into the
content root's `Updates` folder, select the image on the Images tab and click
**Update image...**. The dialog lists the packages in the order they will be
applied (Windows first, then .NET, oldest KB first); move a standalone servicing
stack update to the top if there is one. For Windows 11 24H2 checkpoint updates,
keep the earlier checkpoint in the same folder: DISM picks it up from there.

It runs `Update-OfflineImage.ps1` in its own window, on this PC. For each edition
it mounts the image, adds the packages, optionally cleans up the replaced
components, and commits. It then exports the result to a fresh file (which drops
the space the old components took), moves the old version to
`Images\Previous\<name>_<date>\` and puts the new one in its place, under the same
name, so answer files pick it up without changes. Split images (`.swm`) are joined,
updated and split again. The Images tab shows when each image was last updated and
with which KBs, and the log appears on the Deployment Logs tab as `SERVICE-<name>`.

It needs about three times the image size free on the system drive (or pass
`-WorkDir`). A package that does not apply to the image is logged and skipped; any
other failure discards the changes and leaves the image as it was. **Reset base**
makes the image smallest but means those updates can't be uninstalled on deployed
PCs. Without the console:

```powershell
.\src\Update-OfflineImage.ps1 -ImagePath D:\DeployShare\Images\Win11-24H2-Enterprise.wim `
    -PackagePath D:\DeployShare\Updates\windows11.0-kb5044284-x64.msu -Cleanup
```

This updates Windows itself, not the applications in the image or its recovery
environment (`winre.wim`); refresh those with a new capture from time to time.

## Workflow

1. **Build media** (admin PC with the ADK + WinPE add-on) from the console's
   Media tab, or from the command line:
   `.\src\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare`
   (or `-Target Iso`, or `-Target Pxe` and import `boot.wim` into WDS).
2. **Build the reference** in a generation 2 Hyper-V VM: install Windows, apps
   and updates, no OEM drivers. Take a checkpoint.
3. **Capture** with the console's capture wizard (Images > Capture new image...):
   1. Run the prepare command it shows on the reference machine
      (`Tools\Prepare-Reference.ps1`). It checks for a pending reboot, BitLocker and
      Store apps that break sysprep, then runs sysprep and shuts down.
   2. Name the image and choose compression.
   3. Choose the reference machine. For a **Hyper-V VM** the wizard builds a capture
      ISO, boots the VM from it, and ejects it when the capture finishes. Use an
      **ISO** for other VMs, or a **USB stick** for a physical PC.
   4. Review and click Build and start.
   The image is saved to the share's `Images` folder, or to the USB stick, and a
   `CAPTURE-<name>` log appears on the Deployment Logs tab.
   Without the console: run `Prepare-Reference.ps1`, boot any deploy media and run
   `X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise`.
4. **Add drivers** in the console's Driver Library tab, or extract each vendor's
   enterprise driver pack into `Drivers\<Maker>\<Model>` and add a line to
   `driver-catalog.json` by hand.
   Find a PC's identity in WinPE with `Get-HardwareIdentity`.
   Each month, add the new cumulative update with **Update image...** instead of
   capturing again.
5. **Deploy**: boot the target PC from USB or PXE. The tool detects the model,
   wipes disk 0, applies the image, injects the drivers, and reboots.

## Status

Untested first draft. It has not yet been run on real hardware or in a VM.
The console's data layer and the driver matching have automated tests; the
WPF window itself has only been checked for syntax and XAML validity.
