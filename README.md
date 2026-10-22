# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
src/   Deploy-Image.ps1, Capture-GoldenImage.ps1, New-DeploymentMedia.ps1, DeployCommon.psm1
config/ deploy-settings.json, driver-catalog.json, unattend.xml
winpe/ startnet.cmd (auto-starts the deploy in WinPE)
```

Content root (USB `DEPLOY` partition or `\\server\Deploy`):

```
Images\   Win11-24H2-Enterprise.wim
Drivers\  Dell\Latitude 5440\...  HP\EliteBook 840 G9\...  Lenovo\ThinkPad T14 Gen 4\...
config\   driver-catalog.json, unattend.xml
Logs\     one log per deployed PC
```

## Workflow

1. **Build media** (admin PC with the ADK + WinPE add-on):
   `.\src\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare`
   (or `-Target Iso`, or `-Target Pxe` and import `boot.wim` into WDS).
2. **Build the reference** in a Hyper-V VM: install Windows, apps, updates, then
   `sysprep /generalize /oobe /shutdown`.
3. **Capture**: boot the VM from the media, press Ctrl+C at the deploy prompt's
   confirmation, and run `X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise`.
4. **Add drivers**: extract each vendor's enterprise driver pack into
   `Drivers\<Maker>\<Model>` and add a line to `driver-catalog.json`.
   Find a PC's identity in WinPE with `Get-HardwareIdentity`.
5. **Deploy**: boot the target PC from USB or PXE. The tool detects the model,
   wipes disk 0, applies the image, injects the drivers, and reboots.

## Status

Untested first draft. It has not yet been run on real hardware or in a VM.
