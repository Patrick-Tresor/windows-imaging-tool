# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick, a LAN share, or PXE, on UEFI PCs. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Test-Deployment.ps1, Capture-GoldenImage.ps1, Capture-VMImage.ps1,
                     Prepare-Reference.ps1, VMwareVM.psm1, Update-OfflineImage.ps1, New-DeploymentMedia.ps1, Publish-WdsBootImage.ps1,
                     Get-DriverPacks.ps1, DeployCommon.psm1, AnswerFile.psm1, DeployStatus.psm1,
                     PostDeployChecks.psm1, NamingList.psm1, Win11Readiness.psm1, DeployWizard.psm1,
                     DeployProgress.psm1, DeployProgressWindow.ps1
src/Console/         ImagingConsole.ps1 (WPF GUI), CaptureWizard.ps1, UpdateImage.ps1, DriverDownloader.ps1,
                     UnknownModels.ps1, *.xaml, ConsoleData.psm1, DriverPacks.psm1 (vendor catalogs), DriverReport.psm1
config/              default deploy-settings.json, driver-catalog.json, naming-list.csv (header only),
                     answer-files/Default.xml (commented sample)
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
  and **Import answer file XML...** to convert an existing deploy wizard answer file.
  **New** and **Edit** (or double-click) open the answer file editor, where every
  setting is a form field: General, Image and disk, Applications (pick and order
  them, or add a new installer), Windows settings, Computer name (with a preview),
  Domain or workgroup, Tasks, Network shares and BitLocker. Passwords are typed into password
  boxes and saved in the answer file, encrypted (see Passwords below).
- **Applications**: the application pack builder. Build, edit, test, export and
  import packs (see Applications below).
- **Tasks**: the task library, scripts to run during or after a deployment
  (see Tasks below).
- **Naming List**: one row per PC by BIOS serial, with its computer name, OU
  and answer file (see below). Edit cells, **Import CSV...** to merge a list
  from Excel or an inventory export, **Export CSV...**, then **Save**. Each row
  shows its problems and the result of that PC's last deploy.
- **Driver Library**: **Download from vendor...** lists every model in the Dell,
  HP or Lenovo driver pack catalog for Windows 10 or 11; tick the models you
  deploy and it downloads, checks, extracts and registers their packs, and shows
  which ones have a newer pack. You can also import a pack you already have
  (folder, .cab or .zip), edit how PCs are matched (SKU, machine type, model,
  pattern), and see which entries are missing drivers.
  **Unknown models...** (with a count when there are any) lists the models that
  were deployed without their driver pack: they got the maker fallback, inbox
  drivers only, or a catalog entry whose folder is missing. It shows how many
  PCs and which ones, and finds each model's pack in the vendor catalog. Models
  with a pack are pre-ticked, so **Download** fetches them all in one click.
  **Use inbox drivers** marks a model (a VM, say) as needing no pack.
- **Media**: build a USB stick, ISO or PXE `boot.wim` in one click. The tab shows
  whether the Windows ADK and its WinPE add-on are installed (and their version),
  with a **Download ADK** button when they aren't. Media builds and the capture
  wizard refuse to start until both are there. For PXE it also publishes
  `boot.wim` to a WDS server (see [PXE with WDS](#pxe-with-wds)).
  A USB stick gets the answer files you check in the list, the image each one
  names (its pinned version when it has one), drivers, applications and config.
  The build stops before erasing the stick when an answer file's image is missing.
- **Deploy Settings**: the network share WinPE uses to find the content root,
  and the default answer file.
- **Dashboard**: every PC being deployed, live: computer name, model, IP,
  answer file, state, a progress bar, the current step, duration and when it was
  last heard from, with the PC's live log underneath. Refreshes every 10 seconds.
  See [Deployment dashboard](#deployment-dashboard).
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
Tasks\         Set-Wallpaper\task.json + script.ps1, ... (scripts answer files run)
config\        deploy-settings.json, driver-catalog.json, naming-list.csv, secrets\ (password files)
Logs\          one log per deployed PC or capture
Reports\       Drivers\<serial>.json: which drivers each deployed PC got (for Unknown models)
Status\        <serial>.json + <serial>.log per PC, for the Dashboard
```

## Answer files

An answer file (`AnswerFiles\<name>.xml`) is one deployment profile. Edit it in
the console; the format is documented in the commented
[config/answer-files/Default.xml](config/answer-files/Default.xml). It sets:

- **mode**: `Interactive` (the deploy wizard opens on the PC) or `Unattended`
  (start after `unattendDelay` seconds; a key pressed during the countdown opens
  the wizard instead).
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
  applications), `FIRSTLOGON` (when the first user logs on). A task is a
  command or a script from the task library (`<task script="name">`).
- extra **shares** to map in WinPE, **options** (disable System Restore, enable
  the built-in Administrator), and reboot or shut down when done.
- **BitLocker** on the Windows drive at first boot, with TPM or TPM + PIN, and
  the recovery key backed up to AD and/or a share first.

**BitLocker** needs a TPM that is on and ready, or it is skipped (see
`C:\Windows\Temp\FirstBoot.log`). Backing the recovery key up to Active
Directory needs a domain join; on most domains the computer can write its own
key without extra setup. A recovery key folder (`\\server\share\BitLocker`)
needs write access for Domain Computers and tight read access. With **leave
BitLocker off if no backup worked** (the default), no PC is encrypted without a
saved key. A startup PIN is the same for every PC deployed with that answer file.

### Windows 11 readiness check

When the answer file's image is Windows 11 (build 22000 or later, read from
the WIM), WinPE checks the PC before the disk is erased: TPM 2.0 present and
on, UEFI boot, Secure Boot, a processor on Microsoft's supported list (Intel
8th gen Core and later, AMD Ryzen 2000 desktop and later), 2 cores at 1 GHz,
4 GB of memory and a 64 GB target disk. Each result goes to the deploy log and
the summary shows `Windows 11: ready` or `NOT READY: TPM 2.0, Processor`.

The target disk is the internal disk Windows will go on, never the USB stick
or the disk holding the content: WinPE often numbers the stick disk 0, so when
the answer file's disk is USB, a card reader or missing, the first internal
disk (NVMe, then SATA) is used instead and the log says so. The Disk line in
the log names the disk it measured. When WinPE sees no internal disk at all
(Intel RST/VMD, on by default on Dell 11th gen and later and many other
laptops, hides the SSD from plain WinPE), the wizard says so in one line and
the log has the details.

To avoid that, every media build adds the vendors' WinPE driver packs (storage
such as Intel RST/VMD, and network) to boot.wim: Dell's (WinPE 11, from its
catalog) and HP's (WinPE 10/11, one pack for its business PCs). Each is
downloaded once into the console's cache
(`%LOCALAPPDATA%\ImagingConsole\VendorCatalogs\WinPE`) and reused; the same
driver in two packs goes in once. Lenovo publishes no single WinPE pack, but the
Intel storage drivers in Dell's pack match the controller, so they cover Lenovo
and other PCs with VMD too. Choose the vendors on the Media tab (both on by
default) or with `-WinPEDriverVendors Dell,HP`; `-NoVendorWinPEDrivers` skips
them. Each pack makes boot.wim bigger. Adding the components and drivers
takes many minutes, so the result is kept in
`%LOCALAPPDATA%\ImagingConsole\WinPEBuilds` (the last two builds) and the next
build reuses it while the ADK, the components and every driver .inf stay the
same; `-NoWinPECache` adds them again. Only the packs' x64 drivers are copied
to the stick, and an update copies only the files that changed.
Drivers in `<content root>\Drivers\_WinPE` are also added to boot.wim and, from
the stick or share, loaded with drvload when WinPE starts, so a new storage
driver can be added without rebuilding WinPE.

- **Block**: a failed requirement stops the deploy with nothing erased. Fix it
  in the firmware (often TPM or PTT/fTPM is just turned off), use a Windows 10
  answer file, or run `Deploy-Image.ps1 -IgnoreWindows11Check` to deploy anyway.
- **Warn**: the problems are logged and shown, and the deploy carries on.
- **Off**: no check.

Secure Boot turned off, a processor the check cannot match (some Celeron,
Pentium and Xeon models) and an image whose version cannot be read only warn;
they never block.

**Passwords are kept in the answer file, encrypted.** The join account, share,
local Administrator and BitLocker PIN passwords typed in the answer file editor
are saved in the XML as `aes256:<key id>:<base64>` (AES-256-CBC with an
HMAC-SHA256, next to each `passwordFile`, which still names the password). The
key is random, made once in `config\secrets\answer-key.txt` on the content root,
and never copied to the stick. Each media build puts it inside the boot image,
so WinPE decrypts the passwords itself and **the deploy asks for nothing**.
Older answer files that only name password files are filled in by the next
media build (the build reads each password file and writes it, encrypted, into
the answer file). Use a join account that can only join computers to one OU, and
restrict who can read `config\secrets`.

How far that protects them, honestly: the answer files on the stick, or a copy
mailed or left on a share, give nothing away without the key. But without a
WinPE password the key sits in `boot.wim` on the same stick, so someone who has
the whole stick and knows where to look can decrypt them. This is still real
encryption, not the base64 that unattend.xml calls `PlainText=false`, but it is
only as safe as the stick. Set a **WinPE password** on the Media tab (8
characters or more) to close that gap: the key and any password files then go
inside the boot image encrypted with it (AES-256, key from PBKDF2-SHA256); WinPE
asks for that one password before it does anything and shuts down after 5 wrong
tries or **Shut down**. A PXE image with a WinPE password waits for someone to
type it.

If a password can't be found or decrypted (an answer file copied from another
content root with another key), the deploy wizard shows a **Passwords** page
right after the answer file, with one box for each missing password; an
unattended answer file asks in one window before its countdown. Tick
**Passwords on USB** only if you also want the plain password files on the
stick; it is not needed.

**The join account is checked before the disk is wiped.** When WinPE can reach
the domain, it signs in once with the join account (`net use \\<domain>\IPC$`).
A wrong password, or a locked, disabled or expired account, stops the deploy
with the reason; otherwise Windows would retry it for 15 minutes after the
restart and the PC would stay out of the domain. If WinPE can't reach the
domain, the check is skipped and noted in `Deploy.log`. Password files can be
UTF-8 (with or without a BOM), UTF-16 or ANSI, so accented passwords survive
Notepad.

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
its folder as SYSTEM, is stopped after its timeout, and is marked
failed when it exits 0 but detection still can't find it. Results go to
`C:\Windows\Temp\FirstBoot.log` and `C:\Windows\Temp\FirstBoot-apps.json`.
First boot starts from `SetupComplete.cmd`. Windows skips that script when it
activates with an OEM product key (Dell, HP and Lenovo PCs have one in the
firmware) on editions other than Enterprise, so the unattend also creates a
startup task, `ImagingTool\FirstBoot`, that starts it five minutes after boot.
Only the first of the two runs it; the first line of `FirstBoot.log` says which.
Old `app.json` files with only `command` and `successCodes` still work.

Two installers need more than a silent switch:

- **Microsoft 365 Apps (Office).** `OfficeSetup.exe` from office.com exits 0
  without installing anything. Use the Office Deployment Tool's `setup.exe`
  with a `configuration.xml` next to it (template `Microsoft-365-Apps`, sample in
  `config\office-configuration.xml`). It downloads Office at first boot unless
  you run `setup.exe /download configuration.xml` first and keep the files
  in the pack.
- **Dell Command | Update 5** needs the .NET 8 Desktop Runtime and exits 4
  without it. Add the `DotNet-Desktop-Runtime-8` application and list it
  before Dell Command | Update in the answer file.

**From the internet...** adds applications that the PC downloads by itself at
first boot, with nothing to download first: tick them in the list and click
Add. The list is every template with a `download` address in
`config\app-templates.json`: .NET 8 Desktop Runtime, Microsoft 365 Apps
(Office Deployment Tool plus `config\office-configuration.xml`), Teams, Zoom,
Google Chrome and Firefox. The PC needs internet at first boot; it tries for
about five minutes, and a failed download marks the application failed in
`FirstBoot.log`. An application the console already knows (by its name or installer, for
example an Office pack built from `OfficeSetup.exe`) can switch too: select it
on the Applications tab and tick **Download it from the internet when the PC
installs it**. No link to paste: it uses the publisher's link from the
catalog, and unticking brings back the pack's own installer. The **Download
link** column shows which packs download, and the builder's **Download from**
box takes any other address. When the installer file is
in the pack folder anyway, it is used and nothing is downloaded.

**Export...** zips a pack (installer included) to copy it to another content
root; **Import...** adds it back.

**Tasks** are scripts kept in the task library: a folder under `Tasks\` with the
script (and any files it needs) and a `task.json`. Make them on the **Tasks** tab,
or with **New script...** on the answer file editor's Tasks page:

1. Start from a **template** (`config\task-templates.json`): sync the clock,
   turn on Remote Desktop, no sleep on mains power, remove consumer Store apps,
   copy the deployment logs to a share, set the wallpaper (Enterprise/Education),
   Dell Command | Update. The ones marked *verify* are best guesses to test on a VM.
   Or type the script in the editor, or import a file, or a folder when the script
   needs other files next to it. The file name says how it runs: `.ps1` with
   Windows PowerShell (`-ExecutionPolicy Bypass`), `.cmd`/`.bat` with cmd, `.exe`
   as a program.
2. Choose **when** it runs by default: `POSTIMAGE` (in WinPE before the restart,
   `%OSDRIVE%` is the new Windows), `FIRSTBOOT` (as SYSTEM after the applications)
   or `FIRSTLOGON` (as the first user who logs on).
3. Set its arguments, success exit codes, timeout, and whether a failure stops the
   deployment (POSTIMAGE only; later a failure is logged and shown as a warning).
4. Limit **which PCs** run it by maker and model, as for applications.

```json
{
  "description": "School wallpaper", "script": "script.ps1", "type": "powershell",
  "arguments": "-Path C:\\Windows\\Web\\Wallpaper\\School.jpg", "phase": "FIRSTBOOT",
  "timeoutMinutes": 30, "successCodes": [0], "stopOnFailure": false,
  "requirements": { "makers": [], "models": [] }
}
```

In the answer file editor's **Tasks** page, pick a task and **Add script**: it
goes in the list with the other commands, in order, and its **Command** column
takes extra arguments for that answer file. A missing or broken task stops the
deployment in WinPE before the disk is erased. USB sticks get the whole `Tasks`
folder with the answer files. The deploy summary (wizard and `Deploy.log`) lists
the tasks. POSTIMAGE and FIRSTBOOT runs are logged to
`C:\Windows\Temp\Task-<name>.log` on the PC (and `Deploy.log` or
`FirstBoot.log`), first boot results go to `C:\Windows\Temp\FirstBoot-tasks.json`,
and each FIRSTBOOT task is a post-deploy check on the Dashboard. FIRSTLOGON tasks
are kept in `C:\ProgramData\ImagingTool\Tasks` and run through
`Run-LogonTask.ps1` with the same timeout and success codes, logged to
`C:\Windows\Temp\Task-<name>-<user>.log`. **Export...** zips a task to copy it to
another content root; **Import...** adds it back.

**Importing a deploy wizard answer file** keeps the mode, delay, image name, application
order, regional settings, naming, domain join, tasks, shares and completion
options. The source file encrypts its passwords, so they are never carried over; the
import lists the password files to create, the `.spk` application packs to
rebuild on the Applications tab (templates cover the common ones), and anything it can't convert (static IP, client agent,
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

## Testing on real hardware

[docs/HARDWARE-TESTS.md](docs/HARDWARE-TESTS.md) lists what still needs a real PC,
in order, with what a pass looks like.

## PXE with WDS

On the Media tab, pick **PXE boot.wim**, fill in the **Windows Deployment
Services** box and click **Build media**. After the build, `boot.wim` is
published to the WDS server and set as the default UEFI network boot entry.
Building again replaces it. **Check server** shows whether WDS is installed and
configured and which boot images it serves. The settings are saved in the
`wds` section of `config\deploy-settings.json`.

- **WDS server**: empty for this PC, or a server name. A remote server must allow
  PowerShell remoting (on by default on Windows Server) and you must be an
  administrator on it; `boot.wim` is copied through its `ADMIN$` share.
- **Set up WDS if needed** installs the WDS role and configures it in standalone
  mode (no Active Directory needed) in the **RemoteInstall folder**, then answers
  all PXE clients. Use a data volume, not `C:`. Without it, a server that isn't set
  up stops with an error.
- **DHCP runs on the WDS server too**: WDS then leaves port 67 to DHCP and sets
  option 60. When DHCP runs elsewhere (another server or a router), add an IP
  helper for the WDS server on the client VLAN's router. That is the reliable
  way for UEFI. DHCP options 66 (WDS server) and 67 (`boot\x64\wdsmgfm.efi`) also
  work on a single subnet.
- **Boot without pressing F12 or Enter** sets the PXE prompt policy to no prompt.
  Then any PC set to network boot first starts the deploy tool, so pair it with
  interactive answer files or a separate VLAN. Unticked, the policy is left as it is.

PXE-booted PCs find the content root through the network share in Deploy Settings,
the same as an ISO boot. From the command line:
`.\src\Publish-WdsBootImage.ps1 -BootWim C:\WinPE\boot.wim -Server wds01 -Setup -RemoteInstallPath D:\RemoteInstall`
publishes an existing `boot.wim`, and `-Status` only reports the server's state.

## Deployment dashboard

Each PC writes `Status\<serial>.json` (and a live copy of its log) at every step:
checking the answer file, partitioning, applying the image (with DISM's
percentage, updated every 15 seconds), drivers, settings, applications, boot
files. The console reads the folder and shows:

| State | Meaning |
|---|---|
| Running | Deploying now. |
| Succeeded | Finished. |
| Warning | Finished, but something needs a look: no driver pack matched, an application failed, or a post-deploy check did not pass. |
| Failed | Stopped with an error; the error and the log are shown underneath. |
| Cancelled | The operator cancelled at the prompt. |
| Stalled | Running, but nothing heard for 45 minutes: powered off, network lost, hung, or (at first boot) unable to reach the share. |

After WinPE the PC restarts into Windows, and `FirstBoot.ps1` carries on from
90 % while the applications install, then marks it Succeeded. That part needs
a UNC path, so it works when the PC deployed from the share (or a status share
is set), and it writes **as the computer account**: give `Domain Computers`
modify rights on the `Status` folder. Without that, the PC shows as Stalled
after first boot even though it finished; its `C:\Windows\Temp\FirstBoot.log`
has the result. USB deployments write to the stick's `Status` folder, unless
**Status share** is set on the Deploy Settings tab (for example
`\\deploy-server\Deploy\Status`), in which case WinPE maps it as `R:` with the
share account and reports there.

### Post-deploy checks

At the end of first boot, after the applications and FIRSTBOOT tasks, the PC
checks itself and reports each result to the dashboard (the **Checks** column,
with every check listed under the PC's details):

| Check | Passes when |
|---|---|
| Computer name | Windows has the name the answer file gave it. |
| Domain join | The PC is in the answer file's domain and a domain controller answers (secure channel). Workgroup answer files check the PC stayed in a workgroup. |
| Device drivers | No device in Device Manager has an error (no driver, cannot start). Disabled devices are ignored. |
| App: *name* | The app pack installed (or was already there): a success exit code and, when the pack has detection rules, the app is really there. |
| BitLocker | The Windows drive is encrypted with protection on (or encrypting with a protector in place). |

Any failed check turns the deployment into Warning, with the failed checks
named. The **Deploy Settings** tab sets how strict they are, saved as `checks`
in `deploy-settings.json`: turn them off, make BitLocker **Required**,
**Report** only (a warning, never a failure) or **Off** (**Auto**, the default,
requires it when the answer file turns BitLocker on), do the same for device
errors, and list devices to ignore (wildcards, for example `*Smart Card*`).

The application pack's detection rules (set in the Applications tab) catch
installers that exit 0 without installing anything: first boot checks them after
each install, and the check reports what it found.

The checks stay on the PC in `C:\ProgramData\ImagingTool`. After fixing
something (adding a missing driver, re-joining the domain) or once BitLocker
finishes, run them again as an administrator; the dashboard row updates, and
the warning clears when everything passes:

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\ImagingTool\Test-Deployment.ps1
```

**Remove** takes one PC off the dashboard and **Clear finished** removes all
succeeded, warning and cancelled PCs; final logs stay in Deployment Logs. A PC
that is redeployed replaces its earlier entry. PCs with a placeholder serial
(common on white boxes) are listed by MAC address.

## Naming list

`config\naming-list.csv` on the content root names PCs you know in advance,
by BIOS serial number (Dell service tag, HP or Lenovo serial):

```csv
Serial,ComputerName,OU,AnswerFile,Notes
5CG0000ABC,MTL-ACC-014,"OU=Accounting,OU=Workstations,DC=corp,DC=example",W11-Office-FR,Front desk
PF0XXXXX,MTL-LAB-002,,,
```

When a PC's serial is listed, the deploy uses its computer name instead of the
answer file's naming, joins its OU instead of the answer file's OU (domain
answer files only), and deploys its answer file without asking which one. Empty
cells fall back to the answer file, and an unlisted PC is named by the answer
file as before. Edit it in the console or in Excel; comma and semicolon files
are both read. The deploy log says which entry was used.

## Workflow

1. **Build media** (admin PC with the ADK + WinPE add-on) from the console's
   Media tab, or from the command line:
   `.\src\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare`
   (or `-Target Iso`, or `-Target Pxe -PublishToWds` to publish it to WDS).
   Add `-AnswerFiles Staff-W11,Lab` to put only those answer files and their images on the stick.
   On the Media tab, uncheck the driver packs for models the stick won't image to keep it small
   (`-DriverPacks 'Dell\Latitude 5440|Dell\_Generic WinPE-Storage-Net'`, or `-NoDriverPacks`). A PC whose
   pack is left off gets its maker's fallback pack if that is on the stick, otherwise Windows inbox drivers.
   To refresh a stick you built before without erasing it, tick **Update a stick this console built
   before** (`-UpdateOnly`): WinPE is replaced, only files whose size or date changed are copied, and
   files the new content no longer has are deleted from `AnswerFiles`, `Images`, `Drivers`,
   `Applications`, `Tasks`, `Tools` and `config` (the stick's `Logs` folder is kept). The boot menu key
   is printed when the stick is ready: Dell F12, HP F9, Lenovo F12 or the Novo button, Surface: hold
   Volume down while it starts.
   In WinPE, **Copy logs** (wizard and progress window) saves Deploy.log, DISM's log and, once Windows is
   on the disk, its Panther and NetSetup logs to `Logs\<serial>-<date>` on the stick (or the share).
2. **Build the reference** in a VM (VMware Workstation, VirtualBox, Hyper-V or others): install Windows,
   apps and updates, no OEM drivers.
3. **Capture** with the console's capture wizard (Images > Capture new image...):
   1. Choose the reference machine: **a VM's disk file on this PC** (the default, see
      below), an **ISO** for a VM or PC that boots from one, or a **USB stick** for a
      physical PC.
   2. Run the prepare command the wizard shows on the reference machine
      (`Tools\Prepare-Reference.ps1`). It checks for a pending reboot, BitLocker and
      Store apps that break sysprep, then runs sysprep and shuts down.
   3. Name the image and choose compression.
   4. Review and click Start (disk file) or Build and start.
   The image is saved to the content root's `Images` folder (disk file), the share's
   `Images` folder, or the USB stick, and a
   `CAPTURE-<name>` log appears on the Deployment Logs tab.
   Without the console: run `Prepare-Reference.ps1`, boot any deploy media and run
   `X:\Deploy\Capture-GoldenImage.ps1 -Name Win11-24H2-Enterprise`.

   **A VM's disk file (VMware, VirtualBox, Proxmox, ESXi and others).** The simplest way
   to capture a VM. In the wizard pick
   **A VM's disk file on this PC** and the VM's disk. On the next page the wizard shows the
   prepare command: run it in the VM as administrator (turn BitLocker off first, and don't
   capture while updates are installing), and sysprep shuts the VM down. Then the tool runs
   `src\Capture-VMImage.ps1 -DiskPath <disk file>` on the admin PC. VHD and VHDX files are
   mounted directly. VMDK, VDI, qcow2 and raw files are first converted to a temporary VHD
   of the whole disk with qemu-img (or VirtualBox), so the admin PC needs free space for it.
   For a VMware disk with snapshots, the newest snapshot of the chain is read, whichever
   .vmdk you pick, and the capture refuses to start while VMware still has the VM open. No
   password or ISO is needed, and the VM, its disk and its snapshots are left alone.
   Afterwards revert the VM to a snapshot taken before sysprep if you want to keep working
   on it. Untested on Windows, including every conversion.
4. **Add drivers** in the console's Driver Library tab (**Download from vendor...**),
   or from the command line:
   `.\src\Get-DriverPacks.ps1 -ContentRoot D:\Deploy -Maker Dell -Model 'Latitude 54*' -List`
   (drop `-List` to download). After deploying, `Get-DriverPacks.ps1 -ContentRoot D:\Deploy -UnknownModels -List`
   shows the models that had no pack (drop `-List` to download their packs). You can also extract a pack into
   `Drivers\<Maker>\<Model>` and add a line to `driver-catalog.json` by hand.
   Find a PC's identity in WinPE with `Get-HardwareIdentity`.
   Each month, add the new cumulative update with **Update image...** instead of
   capturing again.
5. **Deploy**: boot the target PC from USB or PXE. The deploy wizard opens
   and shows the detected maker, model and serial. Pick the answer file, check
   or change the computer name, OU and target disk, tick the applications, then
   review the summary, tick the erase confirmation and click **Deploy**. A PC in
   the naming list starts with its own answer file, name and OU filled in. The
   tool wipes the disk, applies the image, injects the
   drivers, and reboots. BitLocker, if set, starts at first boot.
   While it works, a progress window shows the current step, a progress bar,
   the elapsed time and the end of the log. At the end it shows the result, with
   **Restart**, **Shut down**, **View log** and **Command prompt** buttons; a
   failure names the step and the error.
   `Unattended` answer files skip the wizard after their
   countdown (the progress window's **Change settings** button, or any key on the
   console, opens it instead), and `Deploy-Image.ps1 -AnswerFile <name> -NoPrompt` skips it
   entirely. If the WinPE image has no WinForms (built without WinPE-NetFX), the
   same questions are asked on the console.

## Status

Untested first draft. It has not yet been run on real hardware or in a VM.
The console's data layer and the driver matching have automated tests; the
WPF window itself has only been checked for syntax and XAML validity.
