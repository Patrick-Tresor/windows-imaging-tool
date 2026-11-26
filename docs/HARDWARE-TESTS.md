# Hardware test checklist

Everything below passes the Windows CI tests, but CI has no real WinPE, USB stick, network or laptop.
Work through it in this order: each step needs the ones before it. When one fails, use **Copy logs** in WinPE
and send the log.

Test PC used so far: Dell Latitude 5521 (Intel VMD on). Add a second maker (HP or Lenovo) when you can.

## 1. USB stick (offline)

| # | Test | Pass when |
|---|------|-----------|
| 1.1 | Build a stick on the Media tab with a WinPE password | Build ends with "USB media ready" and the boot key line; `config\secrets` is not on the DEPLOY partition |
| 1.2 | Boot the 5521 from it (F12) | WinPE asks for the password first; a wrong one says "tries left"; Shut down turns the PC off |
| 1.3 | Ctrl+C at the password window | WinPE restarts; no command prompt |
| 1.4 | Right password, deploy wizard | The SSD shows (Intel RST/VMD driver), the USB stick is not offered as the target disk |
| 1.5 | Domain answer file | "Join account ... signed in" in Deploy.log, or a clear refusal **before** the disk is erased |
| 1.6 | Copy logs and Command prompt in the wizard | A `Logs\<serial>-<date>` folder appears on the stick; cmd opens |
| 1.7 | Full deploy | Progress window shows percent for apply and drivers; no clipped text; PC restarts into Windows, not WinPE |
| 1.8 | First boot | PC is in the domain, apps and tasks ran (`C:\Windows\Temp\Task-*.log`), clock right |
| 1.9 | Build media with the WinPE password box empty | One red line asks for it and nothing is erased; with it, answer file passwords typed in the editor: no Passwords page, `Deploy.log` says "encrypted password(s) decrypted"; the PC joins the domain; the answer file on the DEPLOY partition shows only `aes256:...` |
| 1.10 | Update the stick in place (Media tab) after changing one answer file | Only the changed files are copied, it is much faster than a full build, and the stick still deploys |
| 1.11 | USB copy speed | Note the MB/s the build prints for the image |
| 1.11b | Driver packs as one file each | The build's "Packing each driver pack into one file" step lists the packs (a second build says "packed before"); `Drivers\<maker>\<model>.wim` is on the DEPLOY partition, not the folder; the build prints a `Small files` MB/s line; a deploy shows "Unpacking drivers" then "Injecting drivers", and `W:\_ImagingDrivers` is gone afterwards |
| 1.12 | Boot the stick in legacy BIOS (CSM) mode | The deploy stops with "Boot it in UEFI mode" before the disk is erased |
| 1.13 | Stick built with an online app (they always go on the stick), deployed with the network cable out | The build's Downloading online applications step lists the apps; `FirstBoot.log` says the installer "is already in the folder; not downloaded" and the apps install |
| 1.13b | Stick with the Microsoft 365 Apps pack | The build's applications step shows "Office files"; the pack folder on the stick has `Office\Data`; at first boot Office installs with no window, without downloading 2-3 GB, in under 60 minutes; `C:\Windows\Temp\App-<name>.log` shows `configuration-deploy.xml` |
| 1.14 | Tool version on the stick | The console header shows the version; the WinPE wizard shows the same one at the bottom of its left band and `Deploy.log` starts with "Imaging tool version"; a stick built before an update gets the yellow "built with version ..." banner in the console, and **Update the stick** starts the update of that stick with the answer files and driver packs it already holds (after the confirmation) |
| 1.15 | Full screen, no console, logo background | While WinPE starts, the background is dark blue with the logo and "Deploy Windows" (not plain blue); after the WinPE password, the wizard and the progress window fill the screen with no black console behind them; Command prompt and View log open over them; after a deploy that stays in WinPE (or fails), closing the progress window shows the console with a command prompt |

## 2. Network (LAN share)

| # | Test | Pass when |
|---|------|-----------|
| 2.1 | ISO boot reaching the share | WinPE maps the share (share password decrypted with the answer file key from boot.wim or the WinPE password vault) |
| 2.3 | Dashboard | Each PC shows live progress, then the post-deploy checks |
| 2.3a | Dashboard with USB deploys, no network share set | Deploy a PC from the stick with no network, then plug the stick into the console PC with the Dashboard open: the PC appears within 10 s (state Succeeded, "applications install at first boot"), its log shows under its Dashboard row, and the stick's `Status` folder is empty |
| 2.3b | Dashboard with USB deploys, network share set (Domain Computers can write to its `Status` folder) | The PC shows live from WinPE, then first boot (apps, checks) until "Deployment complete"; unplug the network cable in WinPE before the deploy and the status goes to the stick instead (2.3a) |
| 2.4 | Deploy Settings: Network share, your AD account and password, **Test connection** | Green "Connected as ... The Dashboard folder ... can be written"; a wrong password gives one red line "wrong user name or password"; `deploy-settings.json` shows only `aes256:...` for the password, and ISO boot still maps the share |
| 2.5 | Computers tab: open it, Search | It connects by itself with the Deploy Settings account and domain controller (there is no Connect box); the domain's computers are listed with OU, OS, last logon; the Agent column says the version and last check-in for PCs with an agent, **None, PC online** for PCs that are on with WinRM or file sharing |
| 2.6 | Reimage with no network boot image yet | The confirmation says it is built first; a "Building the network boot image" card, then the reimage card; `Boot\boot.wim`, `boot.json`, `tool-version.json` and `Deploy-WinPE.iso` on the content root; after updating the console or saving Deploy Settings, the next Reimage rebuilds it first |
| 2.7 | Reimage one running PC (BitLocker on) | It restarts into WinPE with no recovery key prompt, deploys without questions, keeps its name and OU, restarts into Windows; the Dashboard shows it |
| 2.8 | Reimage a PC with no agent, and one whose agent stopped checking in | Both are refused with one line, nothing changed on either PC |
| 2.8a | Search `NAME 10.1.2.34` for a PC whose DNS record is old | The IP column shows where the PC really answers; with only the old address, the Agent column says **None, old DNS** and Install agent refuses it |
| 2.8c | Search the whole domain (no name) | The list shows at once with **None, checking...** for PCs with no agent; that and the IP fill in a few seconds later; a PC with two addresses in DNS (`Resolve-DnsName NAME`) shows the one that answers, the same on every Search |

| 2.9 | Search the IP of a laptop that is not in the domain, Reimage | Reimage refuses it in one line (no agent checking in); it is reimaged from the USB stick |
| 2.10 | Reimage notice on a PC with someone signed in | A window shows the countdown with **Reboot now** and **Close**; Reboot now restarts at once |
| 2.11 | Deploy a PC from the share (new stick or network boot image), wait 5 min | Task `ImagingTool\Agent` is running; `Status\Agents\<serial>.json` appears; the Computers tab's Agent column says "v1.x, seen just now" or "seen x min ago", the Dashboard's Last seen too |
| 2.12 | Block WinRM and file sharing on that PC (firewall), Search, Reimage; then stop its agent task and Reimage again | First the reimage goes through the agent: notice, restart into WinPE, deploy, back on the Dashboard. Then Reimage refuses it: no agent checking in |
| 2.13 | Install agent on a PC imaged before the agent | The row ends "Checked in from <IP>"; the Agent column fills in |
| 2.13b | On a PC the console cannot reach, run `\\server\share\Agent\Install-Agent.cmd` as administrator | "Done: <PC> checked in"; the Agent column fills in |
| 2.13c | Reimage a laptop on Wi-Fi only through its agent, then again with a cable | First: "on Wi-Fi only", the PC does not restart. Then: WinPE maps the share (Deploy.log "Network: ..." and "Using network content at Z:\ (...)") |
| 2.14 | Copy an old `job.json` back into `Status\Agents\Jobs\<serial>` after the reimage | The agent refuses it ("made for an earlier install"), nothing restarts |
| 2.15 | Dashboard: a PC whose app failed at first boot (agent installed with this version), select it, **Retry failed apps** | Within a minute the details show "Agent job: installapps Running", then Done; the app's line turns green, Result says Ready (or the next problem), and the log has "Agent: <app> installed" |
| 2.16 | Dashboard: click each count box, then History | The list shows only those PCs, the box is outlined; PCs listed shows them all again |
| 2.17 | Start a deploy, switch to another tab (or another window) until it ends | A Windows notification "<PC> is ready" (or "not ready", "failed"), the taskbar button flashes; clicking the notification opens the Dashboard on that PC |
| 2.18 | Deploy a PC with an app that fails (agent on), wait an hour | `ImagingAgent.log` has "Retry 1 of 3 by the agent"; once it installs, the Dashboard row and `DeployResult.txt` say Ready, BitLocker stays OK if a first-logon task turned it on; no `ImagingTool\RetryApps` task on that PC |
| 2.19 | After updating the console, open the Computers tab with a PC whose agent is from the previous version (but has automatic updates) | The Agent column says "v1.x updating, ...", then "v1.y, seen ..." within a few minutes; `ImagingAgent.log` says "Agent updated from ... to ..." and the agent checks in again |
| 2.20 | Turn a PC with the agent off for over a day, open the Dashboard | A line above the list names it ("have not checked in for over a day") |

## 3. Features on the deployed PC

| # | Test | Pass when |
|---|------|-----------|
| 3.1 | BitLocker (TPM only) | Encrypted at first boot (used space, XTS-AES 256); the recovery key is backed up where the answer file says; with no backup possible, BitLocker stays off |
| 3.2 | Windows 11 on an older PC (ThinkPad X1 Yoga 1st gen, say) | No hardware check: the deploy goes through and Windows 11 starts and joins the domain |
| 3.3 | Passwords removed from unattend.xml | After the first logon (OOBE over), `C:\Windows\Panther\unattend.xml` shows `*removed*` for every password, `C:\Windows\Temp\FirstBoot.log` says "unattend.xml passwords: removed N from ...", and the `ImagingTool\ClearUnattend` task and `C:\ProgramData\ImagingTool\Clear-UnattendPasswords.ps1` are gone; OOBE still skipped the account page and the domain join worked |
| 3.4 | End-of-deploy result | `C:\Windows\Temp\DeployResult.txt` says Ready (or what failed) with one line each for drivers, applications, tasks, domain join, BitLocker and total time; the Dashboard's Result column and details say the same |

## 4. Capture and image upkeep

| # | Test | Pass when |
|---|------|-----------|
| 4.1 | VMware disk file capture | Image in `Images`, VM and its snapshots unchanged |
| 4.1a | Check the disk page, sysprepped VM | Every line ticked; edition, version and size right; the capture reuses the check's copy (step says Reused) |
| 4.1b | Check the disk page, VM not sysprepped or still open | Cross on Sysprep has run or VM shut down, Next stays off |
| 4.1c | Capture progress window | Each step with its bar, the capture step shows a percent and the time left |
| 4.1d | Sysprep on each PC: capture a VM shut down with `shutdown /s /t 0`, not sysprepped | Check the disk passes with "Not sysprepped: each PC runs sysprep"; a VM shut down from the Start menu with Fast Startup gets a cross |
| 4.1e | Deploy that image to the Dell 5521, then an HP and a Lenovo | First start shows only the spinner (no logon screen, no message), restarts by itself, then setup, name, domain join, apps and tasks as usual; `C:\Windows\Temp\SysprepAtDeploy.log` ends with "Sysprep finished" |
| 4.1f | Same, with a Store app installed for one user only in the VM (or a Store-updated app with an optional package such as Microsoft.OneDrive.Photos) | Sysprep stops on it once (0x80073cf2), the package is removed for every user and sysprep runs again and finishes; with a missing Store the logon screen says sysprep failed |
| 4.3 | Update image (it always looks for the latest cumulative update) | The Progress window shows "Downloading the latest cumulative update" with the KB, the `.msu` lands in `Updates`, then a new version in the Images tab, old one under Versions; with no internet it fails before touching the image and says to download the `.msu` by hand |
| 4.4 | Roll back a version | Answer files deploy the older image |
| 4.5 | Capture with compression **Smallest (.esd)** | The capture shows a "Compressing to the smallest size" step and logs the .esd size (about 70-80 % of Maximum); the Images tab lists `Name.esd`; a stick with it deploys normally; Update image works on it |
