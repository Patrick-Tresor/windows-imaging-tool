# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick or a LAN share, on UEFI PCs. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 Deploy-Image.ps1, FirstBoot.ps1, Test-Deployment.ps1, Capture-GoldenImage.ps1, Capture-VMImage.ps1,
                     Prepare-Reference.ps1, VMwareVM.psm1, Update-OfflineImage.ps1, New-DeploymentMedia.ps1,
                     Get-DriverPacks.ps1, DeployCommon.psm1, AnswerFile.psm1, DeployStatus.psm1,
                     PostDeployChecks.psm1, NamingList.psm1, DeployWizard.psm1,
                     DeployProgress.psm1, DeployProgressWindow.ps1
src/Console/         ImagingConsole.ps1 (WPF GUI), CaptureWizard.ps1, UpdateImage.ps1, DriverDownloader.ps1,
                     UnknownModels.ps1, *.xaml, ConsoleData.psm1, DriverPacks.psm1 (vendor catalogs), DriverReport.psm1
config/              default deploy-settings.json, driver-catalog.json, naming-list.csv (header only),
                     answer-files/Default.xml (commented sample)
winpe/               startnet.cmd (auto-starts the deploy or capture in WinPE)
tests/               *.Tests.ps1 (pwsh -File tests/<name>.Tests.ps1), fixtures/
```

## Admin console

Double-click `ImagingConsole.cmd` on a Windows admin PC (it asks for admin rights). Only the console window
opens: the PowerShell window behind it stays hidden. If the console stops on an error, a message says so and
the details go to `%LOCALAPPDATA%\ImagingConsole\console-error.log`.
Pick a **content root** (a local folder, the USB `DEPLOY` volume, or the share)
and click **Create folders** the first time. Then:

- **Images**: see captured images, their size and editions, and which answer
  files use them. **Capture new image...** opens the capture wizard (below).
  **Versions...** (or double-click an image) lists its earlier versions (see
  [Image versions and rollback](#image-versions-and-rollback)).
  **Update image...** adds Windows updates to the selected image (see
  [Updating an image](#updating-an-image)).
- **Answer Files**: create, edit and check deployment profiles, pick the default,
  **Delete** one (it asks first, and says when it is the default or the naming list still uses it),
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
- **Driver Library**: **Find a model online** searches the Dell, HP and Lenovo
  driver pack catalogs for a model, SKU or machine type; pick the pack and it
  downloads, checks, extracts and registers it. You can also import a pack you already have
  (folder, .cab or .zip), edit how PCs are matched (SKU, machine type, model,
  pattern), and see which entries are missing drivers.
  **Unknown models...** (with a count when there are any) lists the models that
  were deployed without their driver pack: they got the maker fallback, inbox
  drivers only, or a catalog entry whose folder is missing. It shows how many
  PCs and which ones, and finds each model's pack in the vendor catalog. Models
  with a pack are pre-ticked, so **Download** fetches them all in one click.
  **Use inbox drivers** marks a model (a VM, say) as needing no pack.
- **Media**: build a USB stick or ISO in one click. The tab shows
  whether the Windows ADK and its WinPE add-on are installed (and their version),
  with a **Download ADK** button when they aren't. Media builds and the capture
  wizard refuse to start until both are there.
  A USB stick gets the answer files you check in the list, the image each one
  names (its pinned version when it has one), drivers, applications and config.
  The build stops before erasing the stick when an answer file's image is missing.
- **Deploy Settings**: five short sections. 1) USB stick only, or a network
  share (needed for ISO boot and the Computers tab). 2) The Active Directory account WinPE signs in
  with: type its password in the console (saved encrypted in
  `deploy-settings.json`, like the answer files' passwords, no password file) and click **Test connection** to check the sign-in and
  that the Dashboard's `Status` folder can be written. 3) Where PCs report for
  the Dashboard. 4) Default answer file and how many older image versions to
  keep. 5) Post-deploy checks. Save refuses the example values
  (`\\deploy-server`, `DOMAIN\...`), a share not written `\\server\share` and an
  account not written `DOMAIN\user` or `user@domain`, and says when the stick
  needs updating because WinPE reads these settings from the boot image.
- **Computers**: the computers in your Active Directory, to reimage them over
  the network (see [Reimage computers from Active Directory](#reimage-computers-from-active-directory)).
- **Dashboard**: every PC being deployed, live: computer name, model, IP,
  answer file, state, a progress bar, the current step, duration and when it was
  last heard from, with the PC's live log underneath. Refreshes every 10 seconds.
  See [Deployment dashboard](#deployment-dashboard).
- **Logs**: capture and image update logs, and the final log of each deployment cleared from the Dashboard.

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
config\        deploy-settings.json, driver-catalog.json, naming-list.csv, secrets\ (answer-key.txt)
Logs\          one log per deployed PC or capture
Reports\       Drivers\<serial>.json: which drivers each deployed PC got (for Unknown models)
Status\        <serial>.json + <serial>.log per PC, for the Dashboard
Boot\          boot.wim + boot.json: the network boot image the Computers tab starts on PCs
Reimage\       <serial>.json per PC waiting to be reimaged, Started\ for the ones WinPE took
```

## Reimage computers from Active Directory

The **Computers** tab lists the computers in your domain and reinstalls Windows
on the ones you pick, with nobody at the PCs.

1. Click **Connect**. By default the tab uses the account and saved password
   from the Deploy Settings tab (**Use the Deploy Settings account**), and the
   domain comes from that account (`user@corp.local`) or the console PC. To use
   another account, for example an administrator of the PCs, untick it and type
   one (`CORP\admin`); its password is asked once and never saved. Not joined to
   the domain? Also type a domain controller.
2. Pick an OU (or the whole domain), optionally part of a name (`LAB` or
   `LAB-*`), and **Search**. Servers, domain controllers and disabled accounts
   are left out unless ticked. Each row shows the OU, Windows version, last
   logon and whether the console can reach it now. **Online** (point at it for
   details):
   - **Yes**: PowerShell remoting (WinRM) answers.
   - **Yes (SMB)**: remoting is off, but file sharing answers. The console
     goes through the PC's admin share (`\\PC\ADMIN$`, `\\PC\C$`) and a
     one-time SYSTEM service that it deletes right after, the way Windows admin
     tools do. Some antivirus products block services that start PowerShell;
     the progress window then says the PC did not run the command.
   - **No access**: the PC is on, but its firewall blocks both. Allow
     *File and Printer Sharing (SMB-In)*, or turn on remoting
     (`Enable-PSRemoting -Force`, or for a whole OU the Group Policy *Computer
     Configuration > Administrative Templates > Windows Components > Windows
     Remote Management > WinRM Service > Allow remote server management
     through WinRM* plus the firewall rule *Windows Remote Management (HTTP-In)*).
   - **Not found**: its name does not resolve from the console PC. Use a domain
     controller as the console PC's DNS server.
   - **No answer**: it is off or asleep, or a firewall drops everything.
3. Once: set **Network share** on the Deploy Settings tab, then click **Build
   network boot image**. It builds WinPE with the deploy tool into `Boot\` on
   the content root, without a WinPE password (nobody is there to type it).
   Rebuild it after updating the tool or the share settings.
4. Select the PCs (Ctrl+click, Shift+click), pick the answer file and click
   **Reimage...**. **Keep each PC's name** and **Join it back into its OU** are
   on by default.

For each PC, the console (Start-RemoteReimage.ps1, RemoteReimage.psm1):
checks (over PowerShell remoting, or its admin share) that it answers with its own name, starts in
UEFI mode and has a BIOS serial of its own; writes `Reimage\<serial>.json` on
the share; copies the network boot image to `C:\_ImagingBoot`, adds a one-time
boot entry for it (no PXE or WDS needed), suspends BitLocker for that one
restart and restarts the PC after a 60 second warning. WinPE maps the share,
takes the job for its serial (and UUID), and deploys that answer file with the
PC's name and OU after a 15 second countdown (a key there opens the wizard).
At the end it restarts into Windows. The progress window lists each PC until
its deploy starts; from there it is on the Dashboard.

Needs:
- PowerShell remoting (WinRM) or file sharing on the PCs, with your account
  (or the one typed) as administrator.
- The answer file and its image on the network share; the console checks.
- An answer file whose passwords are encrypted in it, or on the share: a
  reimaged PC never waits for someone to type one.
- Domain join of a computer account that already exists: since the October 2022
  Windows updates the join account must be the one that created it, a Domain
  Admin, or allowed by the *Domain controller: Allow computer account re-use
  during domain join* policy. Otherwise the join fails at first boot (error 0xaac).

**Cancel reimage** removes a waiting job. A PC that already restarted into WinPE
then waits at the wizard for someone at its screen.

## Answer files

An answer file (`AnswerFiles\<name>.xml`) is one deployment profile. Edit it in
the console; the format is documented in the commented
[config/answer-files/Default.xml](config/answer-files/Default.xml). It sets:

- **mode**: `Interactive` (the deploy wizard opens on the PC) or `Unattended`
  (start after `unattendDelay` seconds; a key pressed during the countdown opens
  the wizard instead).
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

### Windows on any PC, and the target disk

There is no Windows 11 hardware check: Windows is installed on any PC, whatever
its processor, TPM or Secure Boot state (DISM does not enforce the
requirements). Microsoft does not support Windows 11 on older PCs (Intel 7th
gen and earlier, such as a ThinkPad X1 Yoga 1st gen) and may not offer them
feature updates through Windows Update.

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


**Passwords are kept in the answer file, encrypted.** The join account, share,
local Administrator and BitLocker PIN passwords typed in the answer file editor
are saved in the XML as `aes256:<key id>:<base64>` (AES-256-CBC with an
HMAC-SHA256, next to each `passwordFile`, which now only names the password). The
key is random, made once in `config\secrets\answer-key.txt` on the content root,
and never copied to the stick. Each media build puts it inside the boot image,
so WinPE decrypts the passwords itself and **the deploy asks for nothing**.
Plain password files are not used: a password that only sits in a text file
under `config\secrets` is not read, so type it once in the editor. Use a join account that can only join computers to one OU, and
restrict who can read `config\secrets`.

How far that protects them, honestly: the answer files on the stick, or a copy
mailed or left on a share, give nothing away without the key. But without a
WinPE password the key sits in `boot.wim` on the same stick, so someone who has
the whole stick and knows where to look can decrypt them. This is still real
encryption, not the base64 that unattend.xml calls `PlainText=false`, but it is
only as safe as the stick. Set a **WinPE password** on the Media tab (8
characters or more) to close that gap: the key then goes
inside the boot image encrypted with it (AES-256, key from PBKDF2-SHA256); WinPE
asks for that one password before it does anything and shuts down after 5 wrong
tries or **Shut down**.

If a password can't be found or decrypted (an answer file copied from another
content root with another key), the deploy wizard shows a **Passwords** page
right after the answer file, with one box for each missing password; an
unattended answer file asks in one window before its countdown. Nothing under
`config\secrets` is ever copied to the stick.

**The join account is checked before the disk is wiped.** When WinPE can reach
the domain, it signs in once with the join account (`net use \\<domain>\IPC$`).
A wrong password, or a locked, disabled or expired account, stops the deploy
with the reason; otherwise Windows would retry it for 15 minutes after the
restart and the PC would stay out of the domain. If WinPE can't reach the
domain, the check is skipped and noted in `Deploy.log`.

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

Some applications are ready to download with nothing to get first, because
`config\app-templates.json` has a `download` address for them: .NET 8 Desktop
Runtime, Microsoft 365 Apps (Office Deployment Tool plus
`config\office-configuration.xml`), Teams, Zoom, Google Chrome and Firefox.
The PC needs internet at first boot; it tries for about five minutes, and a
failed download marks the application failed in `FirstBoot.log`. An
To make one, click **New...** on the Applications tab, pick the template,
leave the installer empty and click **Apply**: the pack gets the publisher's
link (and, for Office, `configuration.xml`). The **Download
link** column shows which packs download, and the builder's **Download from**
box takes any other address. When the installer file is
in the pack folder anyway, it is used and nothing is downloaded.

**Find an app online** (on the Applications tab) is for any other
application: type its name (VLC, 7-Zip, Notepad++, Adobe Reader...), press
Enter or click **Search**, pick the right result and click **Add**. The
search uses Microsoft's winget catalog, so the console PC needs winget (App
Installer, on Windows 10 1809 and later and Windows 11). The new pack keeps
the publisher's download address, the silent switches and the file's SHA256
from the catalog; nothing big is downloaded when you add it. The PC downloads
the installer at first boot and refuses it if its SHA256 changed (the
publisher replaced the file): add the application again to get the new
version. Packs whose catalog entry gives no silent switch say so in their
notes; test those on a VM first. Every search is written to
`%LOCALAPPDATA%\ImagingConsole\winget-search.log` (winget's exit code and full
output); when winget itself fails, the status line says why instead of
"Nothing found".

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
import lists the passwords to type in the editor, the `.spk` application packs to
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
with which KBs, and the log appears on the Logs tab as `SERVICE-<name>`.

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
**A network folder** is chosen under "Where PCs report progress" on the Deploy
Settings tab (for example `\\SERVER01\Deploy\Status`), in which case WinPE maps
it as `R:` with the share account and reports there.

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
succeeded, warning and cancelled PCs; their final logs move to the Logs tab. A PC
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
   (or `-Target Iso`).
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
   From the console, a **Build progress** window lists every step (checking the content, copying WinPE,
   mounting boot.wim, adding components and drivers, configuring WinPE, unmounting, partitioning the
   stick, copying WinPE and the content) with its own bar, elapsed time and a tick when it is complete;
   steps taken from the WinPE build cache say Reused. If a step fails it is marked Failed with one line;
   **Open log** shows the whole build (`%LOCALAPPDATA%\ImagingConsole\Logs\media-build-*.log`) and
   **Show build window** brings up the build's own window. Closing the progress window does not stop the
   build. From the command line, `-ProgressFile` and `-LogPath` do the same.
   In WinPE, **Copy logs** (wizard and progress window) saves Deploy.log, DISM's log and, once Windows is
   on the disk, its Panther and NetSetup logs to `Logs\<serial>-<date>` on the stick (or the share).
2. **Build the reference** in a VM (VMware Workstation, VirtualBox, Hyper-V or others): install Windows,
   apps and updates, no OEM drivers. Step by step, including audit mode and keeping the Microsoft Store
   in the image: [docs/REFERENCE-PC.md](docs/REFERENCE-PC.md).
3. **Capture** with the console's capture wizard (Images > Capture new image...):
   1. Choose the reference machine: **a VM's disk file on this PC** (the default, see
      below) or a **capture ISO** for a VM that boots from it.
   2. Run the prepare command the wizard shows on the reference machine
      (`Tools\Prepare-Reference.ps1`). It checks for a pending reboot, BitLocker,
      Store apps that break sysprep and a missing Microsoft Store, then runs sysprep and shuts down.
      Or, for a disk file, tick **Skip sysprep here: each PC runs sysprep at its first start** and only
      run `shutdown /s /t 0` in the VM: each deployed PC then runs these checks and sysprep itself
      (5-10 minutes and one restart more per PC; see [docs/REFERENCE-PC.md](docs/REFERENCE-PC.md)).
   3. **Check the disk** (disk file only): each line gets a tick or a cross. The quick checks (the
      disk is on a drive in this PC, the VM is shut down, the snapshot that will be read, qemu-img,
      free space for the temporary copy) come first, then the wizard reads the Windows on the disk
      and shows its edition, version, size and whether sysprep has run. Next stays off until every
      line has a tick, so a disk that was not generalized is caught here, not after the capture
      started. A VMDK is copied to a temporary VHD for this; the capture reuses that copy.
   4. Name the image, choose compression and, for a disk file, **Save to**: the content root's
      `Images` folder by default (**Default** puts it back), or **Browse...** to any folder on this PC
      or a server share (`\\server\share\Images`). An image saved outside the open content root
      shows on the Images tab when the console opens that folder's content root.
   5. Review and click Start (disk file) or Build and start. A disk file capture shows a progress
      window with each step (copy, read, capture, save), its bar and the time left.
   The image is saved to the Save to folder (disk file) or the share's
   `Images` folder (ISO), and a
   `CAPTURE-<name>` log appears on the Logs tab.
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
4. **Add drivers** in the console's Driver Library tab (**Find a model online**).
   After deploying, **Unknown models...** on the same tab lists the models that had
   no pack and downloads theirs. You can also extract a pack into
   `Drivers\<Maker>\<Model>` and add a line to `driver-catalog.json` by hand.
   Find a PC's identity in WinPE with `Get-HardwareIdentity`.
   Each month, add the new cumulative update with **Update image...** instead of
   capturing again.
5. **Deploy**: boot the target PC from USB or ISO. The deploy wizard opens
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
   entirely.

## Status

Untested first draft. It has not yet been run on real hardware or in a VM.
The console's data layer and the driver matching have automated tests; the
WPF window itself has only been checked for syntax and XAML validity.
