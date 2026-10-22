# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, Capture-GoldenImage.ps1, New-DeploymentMedia.ps1, DeployCommon.psm1
src/Console/         ImagingConsole.ps1 (WPF GUI), MainWindow.xaml, ConsoleData.psm1
config/              default deploy-settings.json, driver-catalog.json, unattend.xml
winpe/               startnet.cmd (auto-starts the deploy in WinPE)
tests/               ConsoleData.Tests.ps1 (pwsh -File tests/ConsoleData.Tests.ps1)
```

## Admin console

Double-click `ImagingConsole.cmd` on a Windows admin PC (it asks for admin rights).
Pick a **content root** (a local folder, the USB `DEPLOY` volume, or the share)
and click **Create folders** the first time. Then:

- **Images**: see captured images, their size and editions, and pick the default.
- **Driver Library**: import a vendor pack (folder, .cab or .zip) for a maker and
  model, edit how PCs are matched (SKU, machine type, model, pattern), and see
  which entries are missing drivers.
- **Media**: build a USB stick, ISO or PXE `boot.wim` in one click.
- **Deploy Settings**: share, default image, target disk, computer name pattern.
  Deployments read these from the content root, so no media rebuild is needed
  unless the share details change.
- **Deployment Logs**: one log per deployed PC, with result and full text.

Content root (USB `DEPLOY` partition or `\\server\Deploy`):

```
Images\   Win11-24H2-Enterprise.wim
Drivers\  Dell\Latitude 5440\...  HP\EliteBook 840 G9\...  Lenovo\ThinkPad T14 Gen 4\...
config\   driver-catalog.json, unattend.xml
Logs\     one log per deployed PC
```

## Workflow

1. **Build media** (admin PC with the ADK + WinPE add-on) from the console's
   Media tab, or from the command line:
   `.\src\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare`
   (or `-Target Iso`, or `-Target Pxe` and import `boot.wim` into WDS).
2. **Build the reference** in a Hyper-V VM: install Windows, apps, updates, then
   `sysprep /generalize /oobe /shutdown`.
3. **Capture**: boot the VM from the media, press Ctrl+C at the deploy prompt's
   confirmation, and run `X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise`.
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
