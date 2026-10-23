# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Capture-GoldenImage.ps1, Prepare-Reference.ps1,
                     New-DeploymentMedia.ps1, DeployCommon.psm1, AnswerFile.psm1, UserState.psm1
src/Console/         ImagingConsole.ps1 (WPF GUI), CaptureWizard.ps1, *.xaml, ConsoleData.psm1
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
- **Answer Files**: create, edit and check deployment profiles, pick the default,
  and **Import SmartDeploy XML...** to convert an existing SmartDeploy answer file.
  **New** and **Edit** (or double-click) open the answer file editor, where every
  setting is a form field: General, Image and disk, Applications (pick and order
  them, or add a new installer), Windows settings, Computer name (with a preview),
  Domain or workgroup, Tasks, Network shares and User data. Passwords are typed into password
  boxes and saved to their own files.
- **Driver Library**: import a vendor pack (folder, .cab or .zip) for a maker and
  model, edit how PCs are matched (SKU, machine type, model, pattern), and see
  which entries are missing drivers.
- **Media**: build a USB stick, ISO or PXE `boot.wim` in one click.
- **Deploy Settings**: the network share WinPE uses to find the content root,
  and the default answer file.
- **Deployment Logs**: one log per deployed PC, with result and full text.

Content root (USB `DEPLOY` partition or `\\server\Deploy`):

```
Images\        Win11-24H2-Enterprise.wim
Drivers\       Dell\Latitude 5440\...  HP\EliteBook 840 G9\...  Lenovo\ThinkPad T14 Gen 4\...
AnswerFiles\   Default.xml, W11-Office-FR.xml, ...
Applications\  Zoom\app.json + installer, Teams\app.json + installer, ...
config\        deploy-settings.json, driver-catalog.json, secrets\ (password files)
UserState\     user data backups, one folder per PC serial (only with a folder store)
Logs\          one log per deployed PC or capture
```

## Answer files

An answer file (`AnswerFiles\<name>.xml`) is one deployment profile. Edit it in
the console; the format is documented in the commented
[config/answer-files/Default.xml](config/answer-files/Default.xml). It sets:

- **mode**: `Interactive` (pick the answer file and type YES) or `Unattended`
  (start after `unattendDelay` seconds unless a key is pressed).
- **image** and index, **disk** number, **drivers** root.
- **user data**: keep the users' files and settings when redeploying a PC (see below).
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

**User data migration** backs up the user profiles of the Windows already on
the PC with USMT, in WinPE, before the disk is erased, and restores them at first
boot after the applications. Turn it on in the editor's **User data** section.
Install the ADK's *User State Migration Tool* feature before building media: the
media builder copies it into WinPE. Two places to keep the data during the deploy:

- **On the PC's disk** (hard links): fast and nothing is copied, but the disk's
  partitions are kept and only the Windows partition is emptied. GPT disks
  without BitLocker encryption only.
- **In a folder** on the content root or an extra share (`UserState\<serial>` by
  default): a compressed copy, optionally encrypted with a key saved under
  `config\secrets`. WinPE needs write access to it. The copy stays as a backup;
  delete it when you no longer need it.

Choose what to keep (user files with `MigDocs.xml`, application settings with
`MigApp.xml`, or your own rule files), users to skip (`*\Administrator`), and
whether to recreate local accounts. A PC with no Windows on the disk is deployed
without user data. A disk locked by BitLocker stops the deployment before anything
is erased: unlock it with `manage-bde -unlock` in WinPE or suspend BitLocker first.
USMT logs: `C:\Windows\Temp\ScanState.log` and `LoadState.log`.

**Importing from SmartDeploy** keeps the mode, delay, image name, application
order, regional settings, naming, domain join, tasks, shares and completion
options. SmartDeploy encrypts its passwords, so they are never carried over; the
import lists the password files to create, the `.spk` application packs to
rebuild as folders, and anything it can't convert (static IP, client agent,
platform packs, unsupported system properties).

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
5. **Deploy**: boot the target PC from USB or PXE. The tool detects the model,
   wipes disk 0, applies the image, injects the drivers, and reboots.

## Status

Untested first draft. It has not yet been run on real hardware or in a VM.
The console's data layer and the driver matching have automated tests; the
WPF window itself has only been checked for syntax and XAML validity.
