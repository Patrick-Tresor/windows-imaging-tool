# Windows imaging tool

Capture one hardware-independent Windows 10/11 image, then deploy it to any
Dell, HP or Lenovo PC with the right drivers injected automatically. Works from
an offline USB stick or a LAN share, on UEFI PCs. Built on the Windows ADK, WinPE and
DISM with PowerShell. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```
ImagingConsole.cmd   double-click to open the admin console
src/                 the scripts and modules that run in WinPE, at first boot and behind the console:
                     Deploy-Image.ps1 (deploy), FirstBoot.ps1 (first start), New-DeploymentMedia.ps1 (USB stick
                     and network boot image), Capture-VMImage.ps1 + Prepare-Reference.ps1 (capture),
                     Update-OfflineImage.ps1, Start-RemoteReimage.ps1, Invoke-SysprepAtDeploy.ps1,
                     Get-DriverPacks.ps1, Test-Deployment.ps1, and their *.psm1 modules; Assets\ (logo)
src/Console/         ImagingConsole.ps1 (WPF GUI, MainWindow.xaml), the capture wizard, answer file, application
                     and task editors, Update image, Versions and Progress windows, Styles.xaml (colours and
                     button styles), ConsoleData.psm1, DriverPacks.psm1 (vendor catalogs), DriverReport.psm1
config/              default deploy-settings.json, driver-catalog.json, app-templates.json, task-templates.json,
                     office-configuration.xml, answer-files/Default.xml (commented sample)
winpe/               startnet.cmd (auto-starts the deploy or capture in WinPE)
tests/               Run-All.ps1 (every suite, as CI runs them), *.Tests.ps1 (pwsh -File tests/<name>.Tests.ps1), fixtures/
```

## Admin console

Double-click `ImagingConsole.cmd` on a Windows admin PC (it asks for admin rights). Only the console window
opens: the PowerShell window behind it stays hidden. If the console stops on an error, a message says so and
the details go to `%LOCALAPPDATA%\ImagingConsole\console-error.log`.
The header shows the tool's version, `v1.NN`, where NN counts the pull requests merged since v1.00
(from `src\version.txt` in a downloaded zip, or git in a clone). The same number is written on every
stick and network boot image, in WinPE and at the top of `Deploy.log`; a yellow banner says when a
plugged-in stick or the network boot image is older than the console, with **Update the stick** or
**Rebuild network boot image**. Builds, captures, updates, downloads and reimages show as cards in
one **Progress** window. A job that worked leaves it 10 seconds after it ends, and the window closes
by itself once nothing is left; a failed job, or one with a failed row (such as Office not downloaded), stays, with its log. **Show progress** in the header opens
it again after you close it.

The window has a header bar at the top (logo, version, the **content root** with **Browse...**
and **Open folder**, and **Show progress** while a job runs), the tabs down the left side, and a
status line at the bottom. Pick a **content root** (a local folder, the USB `DEPLOY` volume, or
the share) with **Browse...**; a new folder gets the content folders right away. Each tab
reloads when you open it, so there are no Refresh buttons. The tabs, top to bottom:

- **Images**: see captured images, their size and editions, and which answer
  files use them. **Capture new image...** opens the capture wizard (below).
  **Versions...** (or double-click an image) lists its earlier versions (see
  [Image versions and rollback](#image-versions-and-rollback)).
  **Update image...** adds Windows updates to the selected image (see
  [Updating an image](#updating-an-image)). **Open log** shows the capture or update log.
- **Driver Library**: **Find a model online** searches the Dell, HP and Lenovo
  driver pack catalogs for a model, SKU or machine type; pick the pack and it
  downloads, checks, extracts and registers it. You can also import a pack you already have
  (folder, .cab or .zip), edit how PCs are matched (SKU, machine type, model,
  pattern), and see which entries are missing drivers.
  To import, type the model (Latitude 5521, HP EliteBook 840 G8): the maker is
  read from the model or the pack's name. Lenovo PCs are matched by machine type
  (the first four letters of the model, `20FR`), one row per model.
  **Deployed without a driver pack** shows, on the same page and only when there
  are any, the models that were deployed without their pack: they got the maker
  fallback, inbox drivers only, or a catalog entry whose folder is missing, with
  how many PCs and which ones. **Find its pack** puts the selected model's pack
  in the Find a model online list, ready for **Download**. **No pack needed**
  marks a model (a VM, say) as needing no pack.
- **Media**: build a USB stick in one click (the ISO is made with the network
  boot image, on the Computers tab). The tab shows
  whether the Windows ADK and its WinPE add-on are installed (and their version),
  with a **Download ADK** button when they aren't. Media builds and the capture
  wizard refuse to start until both are there.
  A USB stick gets the answer files you check in the list, the image each one
  names (its pinned version when it has one), drivers, applications and config.
  The build stops before erasing the stick when an answer file's image is missing.
  Pick the **USB disk** (a stick this tool built before is updated in place, any other
  is erased; the tab says which), uncheck the **Driver packs on USB** you don't need, type the
  **WinPE password** twice and click **Build media**. When Windows refused the console's
  Defender folder exclusions, a tip lists the folders with **Open Windows Security**.
- **Answer Files**: create, edit and check deployment profiles, and
  **Delete** one (it asks first).
  **New** and **Edit** (or double-click) open the answer file editor, where every
  setting is a form field: General, Image and disk, Applications (pick and order
  them, or add a new installer), Windows settings, Computer name (with a preview),
  Domain or workgroup, Tasks, Network shares and BitLocker. Passwords are typed into password
  boxes and saved in the answer file, encrypted (see Passwords below).
- **Apps and Tasks**: one list of application packs and task scripts, with
  when each runs. **New application...** opens the pack builder, **New task...**
  the task editor, **Edit** and **Delete** the selected one, and **Find an app online**
  adds an application from the winget catalog (see Applications and Tasks below).
- **Deploy Settings**: four short sections. 1) The network share, left empty
  for USB sticks only (needed for ISO boot and the Computers tab; with a share,
  every PC, USB ones too, reports to its `Status` folder for the Dashboard).
  2) The Active Directory account WinPE signs in
  with: type its password in the console (saved encrypted in
  `deploy-settings.json`, like the answer files' passwords, no password file) and click **Test connection** to check the sign-in and
  that the Dashboard's `Status` folder can be written. 3) Active Directory: the
  **Domain controller** the Computers tab reads, left empty when the console PC
  is joined to the domain. 4) Checks after deploy: they always run; only the devices to ignore are set here. Save refuses the example values
  (`\\deploy-server`, `DOMAIN\...`), a share not written `\\server\share` and an
  account not written `DOMAIN\user` or `user@domain`, and says when the stick
  needs updating because WinPE reads these settings from the boot image.
- **Computers**: the computers in your Active Directory, to reimage them over
  the network (see [Reimage computers from Active Directory](#reimage-computers-from-active-directory)).
- **Dashboard**: every PC being deployed, live: computer name, model, IP,
  answer file, state, a progress bar, the current step, duration and when it was
  last heard from, with the PC's live log underneath. At the end, the **Result**
  column says whether the PC is ready (see [Deployment dashboard](#deployment-dashboard)). Refreshes every 10 seconds while it is open.
  Counters at the top (Deploying, Succeeded, With warnings, Failed or stalled, PCs
  listed), a **Show** filter (All, Deploying, Failed or stalled, Finished, History),
  **Open folder** and **Remove**. **History**
  lists the final log of each deployment cleared from the Dashboard; capture and
  image update logs open from the Images tab's **Open log**.

Content root (USB `DEPLOY` partition or `\\server\Deploy`):

```
Images\        Win11-24H2-Enterprise.wim or .esd (+ .updates.json history)
               Previous\Win11-24H2-Enterprise_20261015-1430\  (earlier versions)
Updates\       .msu / .cab packages from the Microsoft Update Catalog
Drivers\       Dell\Latitude 5440\...  HP\EliteBook 840 G9\...  Lenovo\ThinkPad T14 Gen 4\...
AnswerFiles\   Default.xml, W11-Office-FR.xml, ...
Applications\  Zoom\app.json + installer, Teams\app.json + installer, ...
Tasks\         Set-Wallpaper\task.json + script.ps1, ... (scripts answer files run)
config\        deploy-settings.json, driver-catalog.json, secrets\ (answer-key.txt)
Logs\          one log per deployed PC or capture
Reports\       Drivers\<serial>.json: which drivers each deployed PC got (for the Driver Library)
Status\        <serial>.json + <serial>.log per PC, for the Dashboard
Boot\          boot.wim + boot.json + Deploy-WinPE.iso: the network boot image, and the same WinPE as an ISO
Reimage\       <serial>.json per PC waiting to be reimaged, Started\ for the ones WinPE took
```

## Reimage computers from Active Directory

The **Computers** tab lists the computers in your domain and reinstalls Windows
on the ones you pick, with nobody at the PCs.

1. The tab connects by itself the first time you open it, with the account
   and saved password from the Deploy Settings tab (or your own sign-in when
   none is set there). Not joined to the domain? Type a **Domain controller**
   in Deploy Settings, section 3 (Active Directory). The domain comes from the domain controller's
   full name (`dc01.corp.local`), the account (`user@corp.local`) or the
   console PC. If it could not connect, the first **Search** tries again.
2. Optionally type part of a name (`LAB` or `LAB-*`), an IP address, or a name
   and its IP (`GWHZLG3 10.1.2.34`) when DNS has an old address, and
   **Search**. The whole domain is searched. Servers, domain controllers and disabled accounts
   are left out. Each row shows the IP address, OU, Windows version, last
   logon and whether the console can reach it, checked on every Search (Search again
   to check again). The IP is where that PC really answers: each DNS address is
   asked for its computer name, and one that names another PC is dropped (Online
   then says **Old DNS** and a reimage never goes there). A PC typed by IP that is
   not in Active Directory (a laptop outside the domain) is listed too, and
   **Reimage...** asks for its local administrator account. **Online** (point at it for
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
   The same build writes `Boot\Deploy-WinPE.iso`, to boot a PC or VM from.
   Rebuild it after updating the tool or the share settings: a banner at the top
   of the console says when it is older than the console, with a **Rebuild
   network boot image** button.
4. Select the PCs (Ctrl+click, Shift+click), pick the answer file and click
   **Reimage...**. Each PC keeps its name and joins back into the OU it is in.

For each PC, the console (Start-RemoteReimage.ps1, RemoteReimage.psm1):
checks (over PowerShell remoting, or its admin share) that it answers with its own name, starts in
UEFI mode and has a BIOS serial of its own; writes `Reimage\<serial>.json` on
the share; copies the network boot image to `C:\_ImagingBoot`, adds a one-time
boot entry for it (no PXE or WDS needed), suspends BitLocker for that one
restart and restarts the PC after a 60 second warning (a window with a countdown,
**Reboot now** and **Close** for whoever is signed in). WinPE maps the share,
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
- **image** and index, **disk** number (the disk is always erased and partitioned again; drivers come from `Drivers`).
- **applications** installed in order at first boot (see below).
- **product key**, **user information**, **regional** settings (time zone and
  locales such as `fr-CA`).
- **computer name pattern**: `{SERIAL}` is the BIOS serial and `#` a random
  digit, for example `LAB-{SERIAL}` or `A########`. Older answer files with a
  serial number WMI query or a prefix are read as that pattern; one with
  another WMI query (an asset tag) keeps it until a pattern is typed.
- **domain or workgroup**, with OU and join account.
- **tasks** by phase: `POSTIMAGE` (in WinPE, `%OSDRIVE%` is the new Windows
  drive, `%DEPLOYROOT%` the content root), `FIRSTBOOT` (as SYSTEM after the
  applications), `FIRSTLOGON` (when the first user logs on). A task is a
  command or a script from the task library (`<task script="name">`).
- extra **shares** to map in WinPE, **options** (enable
  the built-in Administrator). The PC restarts into Windows when the deploy is
  done; the result screen in WinPE still has **Shut down**. (An older answer file
  with `<shutdown>` or `<reboot>false` keeps doing that until it is saved again.)
- **BitLocker** on the Windows drive at first boot (TPM only, XTS-AES 256, used
  space only), with the recovery key backed up to AD and/or a share first.

**BitLocker** needs a TPM that is on and ready, or it is skipped (see
`C:\Windows\Temp\FirstBoot.log`). Backing the recovery key up to Active
Directory needs a domain join; on most domains the computer can write its own
key without extra setup. A recovery key folder (`\\server\share\BitLocker`)
needs write access for Domain Computers and tight read access. BitLocker always
stays off when no backup worked, so no PC is encrypted without a saved key.
There is no startup PIN: the TPM unlocks the drive.

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
and other PCs with VMD too. The console always adds both; from the command
line `-WinPEDriverVendors Dell` picks one and `-NoVendorWinPEDrivers` skips
them. Each pack makes boot.wim bigger. Adding the components and drivers
takes many minutes, so the result is kept in
`%LOCALAPPDATA%\ImagingConsole\WinPEBuilds` (the last two builds) and the next
build reuses it while the ADK, the components and every driver .inf stay the
same; `-NoWinPECache` adds them again. Only the packs' x64 drivers are copied
to the stick, and an update copies only the files that changed.
Drivers in `<content root>\Drivers\_WinPE` are also added to boot.wim and, from
the stick or share, loaded with drvload when WinPE starts, so a new storage
driver can be added without rebuilding WinPE.


**Passwords are kept in the answer file, encrypted.** The join account, share
and local Administrator passwords typed in the answer file editor
are saved in the XML as `aes256:<key id>:<base64>` (AES-256-CBC with an
HMAC-SHA256, next to each `passwordFile`, which now only names the password). The
key is random, made once in `config\secrets\answer-key.txt` on the content root,
and never copied to the stick. Each media build puts it inside the boot image,
so WinPE decrypts the passwords itself and **the deploy asks for nothing**.
Plain password files are not used: a password that only sits in a text file
under `config\secrets` is not read, so type it once in the editor. Use a join account that can only join computers to one OU, and
restrict who can read `config\secrets`.

How far that protects them, honestly: the answer files on the stick, or a copy
mailed or left on a share, give nothing away without the key. Every USB stick
the console builds needs a **WinPE password** (Media tab, 8 characters or
more, typed for each build): the key goes
inside the boot image encrypted with it (AES-256, key from PBKDF2-SHA256); WinPE
asks for that one password before it does anything and shuts down after 5 wrong
tries or **Shut down**. (The network boot image has no WinPE password, since
nobody is at the PC to type it; its key sits in `Boot\boot.wim` on the share, so
keep that folder readable only by the share account.)

If a password can't be found or decrypted (an answer file copied from another
content root with another key), the deploy wizard shows a **Passwords** page
right after the answer file, with one box for each missing password. An
unattended answer file that needs one opens the wizard instead of counting
down, and a reimage from the console stops with the name of the missing
password. That page is the only place a password is typed. Nothing under
`config\secrets` is ever copied to the stick.

**The join account is checked before the disk is wiped.** When WinPE can reach
the domain, it signs in once with the join account (`net use \\<domain>\IPC$`).
A wrong password, or a locked, disabled or expired account, stops the deploy
with the reason; otherwise Windows would retry it for 15 minutes after the
restart and the PC would stay out of the domain. If WinPE can't reach the
domain, the check is skipped and noted in `Deploy.log`.

**Applications** are packs: a folder under `Applications\` with the installer
(and any files it needs) and an `app.json`. Build them on the **Apps and Tasks**
tab, or with **New application...** in the answer file editor:

1. Pick the installer file, or a folder when it needs files next to it.
   The editor reads its type at once (MSI, MSIX, NSIS, Inno Setup, InstallShield, WiX
   Burn, Advanced Installer, Squirrel), name, version, publisher and MSI product
   code, and fills in the silent command, uninstall command and a detection rule.
   Changing the installer type changes the silent command too, unless you typed it.
   There is one **Name** box (the folder under `Applications` is made from it);
   version and publisher come from the installer and are shown, not typed.
2. Or pick a **template** from `config\app-templates.json` (it fills the form in at once,
   and an installer that matches one picks it by itself). There are templates
   for Lenovo System Update, Dell Command Update, Teams (new Teams, offline MSIX),
   Zoom, VLC, Lansweeper LsAgent, MirrorOp and a generic softphone. The ones marked
   *verify* are best guesses to test on a VM first.
3. Check the **install command**, success exit codes and timeout (3010 and 1641
   always mean "installed, restart needed").
4. Add **detection** rules: MSI product code, program name in Programs and
   Features (wildcards, optional minimum version), file (with version), registry
   key or value, MSIX package, or a `.ps1` that exits 0 when installed. Every
   rule must match; when they all do, the install is skipped (the app is already
   there). **Test on this PC** runs them on the admin PC.
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
its folder as SYSTEM, is stopped after its timeout (real time, so a PC that
slept does not stretch it; the PC is kept awake until first boot ends), and is marked
failed when it exits 0 but detection still can't find it. Results go to
`C:\Windows\Temp\FirstBoot.log` and `C:\Windows\Temp\FirstBoot-apps.json`, and
each installer's own output to `C:\Windows\Temp\App-<name>.log`, as a task's does.
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
  `config\office-configuration.xml`). Each USB build and each reimage first
  downloads the Office files into the pack on the console PC (`setup.exe
  /download`, refreshed every 14 days or when `configuration.xml` changes, older
  versions removed), so every PC installs Office from its own copy instead of
  downloading 2-3 GB from Microsoft; the internet stays as a backup. On the PC,
  the pack's own `configuration.xml` is used (found by name in the pack folder),
  made silent (no Office window, EULA accepted), and a `SourcePath` the PC can't
  reach is dropped. Office gets at least 60 minutes.
- **Dell Command | Update 5** needs the .NET 8 Desktop Runtime and exits 4
  without it. Add the `DotNet-Desktop-Runtime-8` application and list it
  before Dell Command | Update in the answer file.

Some applications are ready to download with nothing to get first, because
`config\app-templates.json` has a `download` address for them: .NET 8 Desktop
Runtime, Microsoft 365 Apps (Office Deployment Tool plus
`config\office-configuration.xml`), Teams, Zoom, Google Chrome and Firefox.
The PC needs internet at first boot; it tries for about five minutes, and a
failed download marks the application failed in `FirstBoot.log`.
To make one, click **New application...** on the Apps and Tasks tab and pick the
template with the installer left empty: the pack gets the publisher's
link (and, for Office, `configuration.xml`). A pack's details on the Apps and
Tasks tab show where it downloads from, and the builder's **Download from**
box takes any other address. When the installer file is
in the pack folder anyway, it is used and nothing is downloaded.

**Find an app online** (on the Apps and Tasks tab) is for any other
application: type its name (VLC, 7-Zip, Notepad++, Adobe Reader...), press
Enter or click **Search**, pick the right result and click **Add**. The
search uses Microsoft's winget catalog, so the console PC needs winget (App
Installer, on Windows 10 1809 and later and Windows 11). The new pack keeps
the publisher's download address, the silent switches and the file's SHA256
from the catalog; nothing big is downloaded when you add it. The PC downloads
the installer at first boot and checks its SHA256. A "latest" link whose file
the publisher has since replaced (Office's `setup.exe`) gives another SHA256:
the file is kept when it is signed by the pack's publisher, and the log says so;
otherwise it is refused at once, with the hash and the signer in the log. Add
the application again to save the new SHA256. Packs whose catalog entry gives no silent switch say so in their
notes; test those on a VM first. Every search is written to
`%LOCALAPPDATA%\ImagingConsole\winget-search.log` (winget's exit code and full
output); when winget itself fails, the status line says why instead of
"Nothing found".

**Tasks** are scripts kept in the task library: a folder under `Tasks\` with the
script (and any files it needs) and a `task.json`. Make them on the **Apps and Tasks** tab (**New task...**),
or with **New task...** on the answer file editor's Tasks page:

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

In the answer file editor's **Tasks** page, pick a task under **Available** and
**Add >** (or double-click it): it goes in the **Run order**, where you set when it
runs, its order (**Up**/**Down**) and, in **Arguments**, extra arguments for that
answer file. A plain command saved by an older version still runs and shows as
**Command**; for a new one, make a task. A missing or broken task stops the
deployment in WinPE before the disk is erased. USB sticks get the whole `Tasks`
folder with the answer files. The deploy summary (wizard and `Deploy.log`) lists
the tasks. POSTIMAGE and FIRSTBOOT runs are logged to
`C:\Windows\Temp\Task-<name>.log` on the PC (and `Deploy.log` or
`FirstBoot.log`), first boot results go to `C:\Windows\Temp\FirstBoot-tasks.json`,
and each FIRSTBOOT task is a post-deploy check on the Dashboard. FIRSTLOGON tasks
are kept in `C:\ProgramData\ImagingTool\Tasks` and run through
`Run-LogonTask.ps1` with the same timeout and success codes, logged to
`C:\Windows\Temp\Task-<name>-<user>.log`. A plain command in the list runs the
same way in every phase (`cmd /c`, exit code 0 is success, 60 minute timeout,
its own log named after the command); a POSTIMAGE command that fails stops the
deployment, and a FIRSTBOOT one is a post-deploy check like the library tasks.

## Image versions and rollback

Earlier copies of an image are kept in `Images\Previous\<name>_<yyyyMMdd-HHmm>\`,
so a bad capture or update never leaves you without a working image:

- **Recapture** under the same name: the old image always moves to `Previous`,
  only once the new capture has succeeded.
- **Offline updates** keep the image they replace in the same place.
- **Roll back to selected** makes an earlier version current again for every
  answer file that doesn't name a version. It links the file rather than copying
  it, so it is quick and uses no extra space. The image you roll away from is kept
  as a version too, so a rollback can itself be undone.
- **Earlier versions to keep** (in the Versions window, one number for every image) deletes
  the oldest unpinned versions after a rollback, a capture or an update, keeping
  the newest N. 0 keeps every version, which is the default. The version you
  just rolled back to is never deleted by this.
- **Pin an answer file** to a version on its *Image and disk* page (the
  `<image><version>` element). Use it to keep a lab or a pilot group on a
  known-good build while the current image moves on, or the other way round.
- **Delete selected** frees space. It refuses a version an answer file is
  pinned to.

Rollbacks run in their own window (`src\Invoke-ImageVersion.ps1`)
and write a `VERSION-<name>` log. Each version takes as much space as the image.

## Updating an image

Patch Tuesday does not need a new capture. Select the image on the Images tab and
click **Update image...**. It always looks for the latest cumulative update first: the
update reads the image's Windows build, finds the newest x64 cumulative update for
that version (not a preview) in the
[Microsoft Update Catalog](https://www.catalog.update.microsoft.com) and downloads
it into the content root's `Updates` folder (both files for a Windows 11 24H2
checkpoint update; Windows 11 26H2 uses the cumulative update it shares with 25H2), then applies it. The catalog has no official interface, so this
can stop working when Microsoft changes the site, and it needs internet: when the
catalog can't be reached, the packages in the list are still added (one warning line
in the log), and with no packages the update stops before touching the image and
says to download the `.msu` by hand into `Updates`. Packages in the dialog's list (the .NET cumulative update, or one
downloaded by hand) are applied after it, in a fixed order: a standalone
servicing stack update (`ssu` in its name) first, then Windows, then .NET,
oldest KB first.

It runs `Update-OfflineImage.ps1` in the background on this PC, with each step in the Progress window. For each edition
it mounts the image, adds the packages, cleans up the replaced
components, and commits. It then exports the result to a fresh file (which drops
the space the old components took), moves the old version to
`Images\Previous\<name>_<date>\` and puts the new one in its place, under the same
name, so answer files pick it up without changes. An `.esd` image is exported to a
.wim, updated and exported back. Split images (`.swm`) from older captures are
joined, updated and split again (new captures are never split). The Images tab shows when each image was last updated and
with which KBs, and **Open log** shows its `SERVICE-<name>` log.

It needs about three times the image size free on the system drive (or pass
`-WorkDir`). A package that does not apply to the image is logged and skipped; any
other failure discards the changes and leaves the image as it was. The console
never resets the base, so the updates can still be uninstalled on deployed PCs
(`-ResetBase` from the command line does). Without the console:

```powershell
.\src\Update-OfflineImage.ps1 -ImagePath D:\DeployShare\Images\Win11-24H2-Enterprise.wim `
    -PackagePath D:\DeployShare\Updates\windows11.0-kb5044284-x64.msu -Cleanup
.\src\Update-OfflineImage.ps1 -ImagePath D:\DeployShare\Images\Win11-24H2-Enterprise.wim -LatestUpdate -Cleanup
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
files. The console reads the folder and shows (the window refreshes every 10 seconds):

| State | Meaning |
|---|---|
| Running | Deploying now. |
| Succeeded | Finished. |
| Warning | Finished, but something needs a look: no driver pack matched, an application failed, or a post-deploy check did not pass. |
| Failed | Stopped with an error; the error and the log are shown underneath. |
| Cancelled | The operator cancelled at the prompt. |
| Stalled | Running, but nothing heard for 45 minutes: powered off, network lost, hung, or (at first boot) unable to reach the share. |

At the end of first boot each PC gets one **Result**: Ready, Ready with warnings,
Not ready or Failed, with one line each for the image, drivers (pack, drivers
added, device errors), applications, tasks, computer name, domain join,
BitLocker, total time and tool version. The Dashboard's Result column and the
PC's details show it, and the PC keeps it in `C:\Windows\Temp\DeployResult.txt`
(and `FirstBoot.log`).

After WinPE the PC restarts into Windows, and `FirstBoot.ps1` carries on from
90 % while the applications install, then marks it Succeeded. That part needs
a UNC path, so it works when the PC deployed from the share (or a status share
is set), and it writes **as the computer account**: give `Domain Computers`
modify rights on the `Status` folder. Without that, the PC shows as Stalled
after first boot even though it finished; its `C:\Windows\Temp\FirstBoot.log`
has the result. With a network share on the Deploy Settings tab, USB
deployments report to its `Status` folder too (WinPE maps it as `R:` with the
share account), falling back to the stick's `Status` folder when the share can't
be reached; the console reads the stick's records when it is plugged in.

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
named. BitLocker and device driver problems are warnings only. The checks always
run; the **Deploy Settings** tab lists devices to ignore (wildcards, for
example `*Smart Card*`), saved as `checks` in `deploy-settings.json`.

The application pack's detection rules (set on the Apps and Tasks tab) catch
installers that exit 0 without installing anything: first boot checks them after
each install, and the check reports what it found.

The checks stay on the PC in `C:\ProgramData\ImagingTool`. After fixing
something (adding a missing driver, re-joining the domain) or once BitLocker
finishes, run them again as an administrator; the dashboard row updates, and
the warning clears when everything passes:

```
powershell -ExecutionPolicy Bypass -File C:\ProgramData\ImagingTool\Test-Deployment.ps1
```

**Remove** takes one PC off the dashboard; succeeded, warning and cancelled PCs
leave by themselves 7 days after their last report. Their final logs stay under the **History** filter. A PC
that is redeployed replaces its earlier entry. PCs with a placeholder serial
(common on white boxes) are listed by MAC address.

## Workflow

1. **Build media** (admin PC with the ADK + WinPE add-on) from the console's
   Media tab, or from the command line:
   `.\src\New-DeploymentMedia.ps1 -Target Usb -UsbDiskNumber 2 -ContentSource D:\DeployShare`
   (`-Target Wim -OutputPath <root>\Boot` builds the network boot image and its ISO).
   Add `-AnswerFiles Staff-W11,Lab` to put only those answer files and their images on the stick.
   On the Media tab, uncheck the driver packs for models the stick won't image to keep it small
   (`-DriverPacks 'Dell\Latitude 5440|Dell\_Generic WinPE-Storage-Net'`, or `-NoDriverPacks`). A PC whose
   pack is left off gets its maker's fallback pack if that is on the stick, otherwise Windows inbox drivers.
   A stick you built before (it has WINPE and DEPLOY partitions) is refreshed without erasing it
   (`-UpdateOnly`); to start one fresh, format it in File Explorer first. WinPE is replaced, only files whose size or date changed are copied, and
   files the new content no longer has are deleted from `AnswerFiles`, `Images`, `Drivers`,
   `Applications`, `Tasks`, `Tools` and `config` (the stick's `Logs` folder is kept). The boot menu key
   is printed when the stick is ready: Dell F12, HP F9, Lenovo F12 or the Novo button, Surface: hold
   Volume down while it starts.
   From the console, the build is a card in the **Progress** window: it lists every step (checking the content, copying WinPE,
   mounting boot.wim, adding components and drivers, configuring WinPE, unmounting, partitioning the
   stick, copying WinPE and the content) with its own bar, elapsed time and a tick when it is complete;
   steps taken from the WinPE build cache say Reused. If a step fails it is marked Failed with one line;
   **Open log** shows the whole build (`%LOCALAPPDATA%\ImagingConsole\Logs\media-build-*.log`); the
   build's own PowerShell window stays minimized on the taskbar. Closing the Progress window does not stop the
   build (**Show progress** brings it back). From the command line, `-ProgressFile` and `-LogPath` do the same.
   In WinPE, **Copy logs** (wizard and progress window) saves Deploy.log, DISM's log and, once Windows is
   on the disk, its Panther and NetSetup logs to `Logs\<serial>-<date>` on the stick (or the share).
2. **Build the reference** in a VM (VMware Workstation, VirtualBox, Hyper-V or others): install Windows,
   apps and updates, no OEM drivers. Step by step, including audit mode and keeping the Microsoft Store
   in the image: [docs/REFERENCE-PC.md](docs/REFERENCE-PC.md).
3. **Capture** with the console's capture wizard (Images > Capture new image...):
   1. Choose the reference VM's disk file on this PC (see below).
   2. Run the prepare command the wizard shows on the reference machine
      (`Tools\Prepare-Reference.ps1`). It checks for a pending reboot, BitLocker,
      Store apps that break sysprep and a missing Microsoft Store, then runs sysprep and shuts down.
      Or tick **Skip sysprep here: each PC runs sysprep at its first start** and only
      run `shutdown /s /t 0` in the VM: each deployed PC then runs these checks and sysprep itself
      (5-10 minutes and one restart more per PC; see [docs/REFERENCE-PC.md](docs/REFERENCE-PC.md)).
   3. **Check the disk**: each line gets a tick or a cross. The quick checks (the
      disk is on a drive in this PC, the VM is shut down, the snapshot that will be read, qemu-img,
      free space for the temporary copy) come first, then the wizard reads the Windows on the disk
      and shows its edition, version, size and whether sysprep has run. Next stays off until every
      line has a tick, so a disk that was not generalized is caught here, not after the capture
      started. A VMDK is copied to a temporary VHD for this; the capture reuses that copy.
   4. Name the image, choose compression (**Maximum**, or **Smallest**: an `.esd` about a quarter
      smaller, slower to capture) and **Save to**: the content root's
      `Images` folder by default (**Default** puts it back), or **Browse...** to any folder on this PC
      or a server share (`\\server\share\Images`). An image saved outside the open content root
      shows on the Images tab when the console opens that folder's content root.
   5. Review and click Start. The capture is a card in the Progress window with each step (copy,
      read, capture, save), its bar and the time left.
   The image is saved to the Save to folder, and the Images tab's **Open log** shows its `CAPTURE-VM-<name>` log.
   Without the console: run `Prepare-Reference.ps1` in the VM, then
   `src\Capture-VMImage.ps1 -DiskPath <disk file> -Name <name> -ContentRoot <content root>` on this PC.

   **A VM's disk file (VMware, VirtualBox, Proxmox, ESXi and others).** The simplest way
   to capture a VM. In the wizard pick the VM's disk. On the next page the wizard shows the
   prepare command: run it in the VM as administrator (turn BitLocker off first, and don't
   capture while updates are installing), and sysprep shuts the VM down. Then the tool runs
   `src\Capture-VMImage.ps1 -DiskPath <disk file>` on the admin PC. VHD and VHDX files are
   mounted directly. VMDK, VDI, qcow2 and raw files are first converted to a temporary VHD
   of the whole disk with qemu-img (or VirtualBox), so the admin PC needs free space for it.
   For a VMware disk with snapshots, the newest snapshot of the chain is read, whichever
   .vmdk you pick, and the capture refuses to start while VMware still has the VM open. No
   password or ISO is needed, and the VM, its disk and its snapshots are left alone.
   Afterwards revert the VM to a snapshot taken before sysprep if you want to keep working
   on it. VMDK capture from VMware Workstation has worked; the other conversions are untested.
4. **Add drivers** in the console's Driver Library tab (**Find a model online**).
   After deploying, the same tab lists the models that had no pack, and **Find
   its pack** finds theirs. You can also extract a pack into
   `Drivers\<Maker>\<Model>` and add a line to `driver-catalog.json` by hand.
   Find a PC's identity in WinPE with `Get-HardwareIdentity`.
   Each month, run **Update image...** to add the latest cumulative update instead of
   capturing again.
5. **Deploy**: boot the target PC from USB or ISO. The deploy wizard opens
   and shows the detected maker, model and serial. Pick the answer file, check
   or change the computer name, OU and target disk, tick the applications, then
   review the summary, tick the erase confirmation and click **Deploy**. The
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

Version 1 is in use on a Dell Latitude 5521 (Intel VMD): USB deploys, the
NVMe disk, domain join, the OOBE account, applications (including downloads at
first boot) and tasks have worked there. Many newer features have not yet been
tried on real hardware; [docs/HARDWARE-TESTS.md](docs/HARDWARE-TESTS.md) lists
them in order. Every pull request runs the automated tests on Windows, in
Windows PowerShell 5.1 and PowerShell 7 (`tests\Run-All.ps1`): they parse every
script, load every window and run the data, matching, deploy and WinPE layout
tests, but CI has no real WinPE, USB stick, network or laptop.
