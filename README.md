# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Capture-GoldenImage.ps1, Prepare-Reference.ps1,
                     New-DeploymentMedia.ps1, DeployCommon.psm1, AnswerFile.psm1
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
  Domain or workgroup, Tasks and Network shares. Passwords are typed into password
  boxes and saved to their own files.
- **Applications**: the application pack builder. Build, edit, test, export and
  import packs (see Applications below).
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
Logs\          one log per deployed PC or capture
```

## Answer files

An answer file (`AnswerFiles\<name>.xml`) is one deployment profile. Edit it in
the console; the format is documented in the commented
[config/answer-files/Default.xml](config/answer-files/Default.xml). It sets:

- **mode**: `Interactive` (pick the answer file and type YES) or `Unattended`
  (start after `unattendDelay` seconds unless a key is pressed).
- **image** and index, **disk** number, **drivers** root.
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

**Applications** are packs: a folder under `Applications\` with the installer
(and any files it needs) and an `app.json`. Build them on the **Applications**
tab, or with **New application...** in the answer file editor:

1. Pick the installer file, or a folder when it needs files next to it.
   **Inspect** reads its type (MSI, MSIX, NSIS, Inno Setup, InstallShield, WiX
   Burn, Advanced Installer, Squirrel), name, version, publisher and MSI product
   code, and fills in the silent command, uninstall command and a detection rule.
2. Or apply a **template** from `config\app-templates.json`. There are templates
   for Lenovo System Update, Dell Command Update, Teams (new Teams, offline MSIX),
   Zoom, VLC, Lansweeper LsAgent, MirrorOp and a generic softphone. The ones marked
   *verify* are best guesses to test on a VM first.
3. Check the **install command**, success and restart exit codes, and timeout.
4. Add **detection** rules: MSI product code, program name in Programs and
   Features (wildcards, optional minimum version), file (with version), registry
   key or value, MSIX package, or a `.ps1` that exits 0 when installed.
   **Test on this PC** runs them on the admin PC.
5. Limit **which PCs** get it by maker and model (Dell Command Update only on
   Dell, Lenovo System Update only on Lenovo).

```json
{
  "displayName": "VLC media player", "version": "3.0.21", "installer": "vlc-3.0.21-win64.exe",
  "installerType": "nsis", "command": "\"vlc-3.0.21-win64.exe\" /L=1033 /S",
  "successCodes": [0, 3010, 1641], "rebootCodes": [3010, 1641], "timeoutMinutes": 15,
  "requirements": { "makers": [], "models": [] },
  "detection": { "match": "all", "rules": [ { "type": "file", "target": "%ProgramFiles%\\VideoLAN\\VLC\\vlc.exe" } ] }
}
```

On the PC, apps for another maker or model are skipped in WinPE and never copied.
At first boot each app is skipped when its detection already finds it, runs from
its folder as SYSTEM (from `SetupComplete.cmd`, which does not run on images
activated with an OEM product key), is stopped after its timeout, and is marked
failed when it exits 0 but detection still can't find it. Results go to
`C:\Windows\Temp\FirstBoot.log` and `C:\Windows\Temp\FirstBoot-apps.json`.
Old `app.json` files with only `command` and `successCodes` still work.

**Export...** zips a pack (installer included) to copy it to another content
root; **Import...** adds it back.

**Importing from SmartDeploy** keeps the mode, delay, image name, application
order, regional settings, naming, domain join, tasks, shares and completion
options. SmartDeploy encrypts its passwords, so they are never carried over; the
import lists the password files to create, the `.spk` application packs to
rebuild on the Applications tab (templates cover the common ones), and anything it can't convert (static IP, client agent,
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
