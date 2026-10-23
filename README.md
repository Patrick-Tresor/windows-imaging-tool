# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Capture-GoldenImage.ps1, Prepare-Reference.ps1,
                     New-DeploymentMedia.ps1, Start-RemoteReimage.ps1, DeployCommon.psm1, AnswerFile.psm1,
                     RemoteReimage.psm1
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
- **Driver Library**: import a vendor pack (folder, .cab or .zip) for a maker and
  model, edit how PCs are matched (SKU, machine type, model, pattern), and see
  which entries are missing drivers.
- **Media**: build a USB stick, ISO or PXE `boot.wim` in one click.
- **Remote Reimage**: the PCs on the network, by lab or room. Wake them, or
  reimage a whole lab from here (see [Remote reimage](#remote-reimage)).
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
Logs\          one log per deployed PC, capture or remote reimage
Computers\     one .json per PC that can be reimaged remotely (MAC, name, group)
Reimage\       pending remote reimage jobs, and Started\ for the ones WinPE picked up
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

## Remote reimage

The **Remote Reimage** tab reimages PCs without anyone walking to them, for
example a whole lab overnight. It needs PXE (WDS) and the network share in Deploy
Settings, since the PCs boot WinPE from the network.

**The computer list.** Every PC deployed by this tool is added with its MAC, IP,
model and last result. Add other PCs with **Save PC** (leave MAC empty to read it
from a PC that is on), **Import CSV...** (columns `Name`, `MAC`, and optionally
`Address`, `Group`, `Relay`; commas or semicolons), or select PCs and click
**Read from PCs**. **Group** is a lab or room, and the list filters by it.

**Reimage...** asks for confirmation, then opens a window that, for each selected PC:

1. Queues a job (`Reimage\<MAC>.json`) with the chosen answer file and, if **Keep
   each PC's name** is ticked, the PC's current name.
2. If **Boot without F12** is ticked, prestages the PC in WDS with no PXE prompt,
   so it boots straight into WinPE. Other PCs keep the server's prompt. The
   prestage is removed again once the PC's deploy starts.
3. **PC on:** connects with PowerShell remoting, sets the firmware's next boot (once
   only) to the network entry with `bcdedit /set {fwbootmgr} bootsequence`, and
   restarts it after a 60 second warning to anyone logged on.
   **PC off:** sends Wake-on-LAN. A PC that boots from the network first goes
   straight to WinPE. One that starts Windows instead is restarted into PXE as soon
   as it answers.
4. In WinPE, `Deploy-Image.ps1` finds the job by the PC's MAC, uses its answer file
   without the menu or the YES prompt (it still counts down at least 15 seconds,
   so someone at the PC can cancel), and deletes the job so the next network boot
   does not reimage the PC again. Jobs expire after 12 hours.

The window waits up to 20 minutes and then lists each PC as started or failed,
with the reason. That summary is saved as a `REIMAGE_...` log on the Deployment
Logs tab. **Cancel reimage** deletes the selected PCs' jobs (a deploy already running
is not stopped). **Wake** only sends Wake-on-LAN.

What the PCs need:

- **BIOS:** Wake-on-LAN on, the UEFI network stack (PXE) on, and for Dell "Deep
  Sleep Control" off, or Wake-on-LAN does not work from shutdown. UEFI only: a
  legacy BIOS PC can only be reimaged this way if network boot is first in its
  boot order.
- **Windows:** PowerShell remoting (WinRM, on by default on domain PCs with the
  usual GPO) and your account as administrator. The console tells you which PCs
  answer with **Check online**.
- **Network:** a Wake-on-LAN packet is a broadcast, and routers drop it unless
  directed broadcasts are allowed for that subnet. The console sends it both to
  the local broadcast and to the PC's subnet broadcast. If the lab is on another
  VLAN that blocks it, set a **Relay**: a PC (or server) in that subnet that is
  usually on; it sends the packet locally for the others.
- **WDS** for the no-F12 option: you must be an administrator on the WDS server,
  set as **WDS server** on the tab (empty = this PC). From the command line:
  `.\src\Start-RemoteReimage.ps1 -ContentRoot \\server\Deploy -Mac 00155D0A1B2C,00155D0A1B2D -AnswerFile Lab-W11 -KeepNames -SkipPxePrompt`

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
