# Hardware test checklist

Everything below passes the Windows CI tests, but CI has no real WinPE, USB stick, network or laptop.
Work through it in this order: each step needs the ones before it. Mark each result on the console's
**Hardware Tests** tab (it reads this list), and when one fails, use **Copy logs** in WinPE, then **Attach the
latest log** on that tab.

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
| 1.9 | Stick built **without** a WinPE password, answer file passwords typed in the editor | No Passwords page; `Deploy.log` says "encrypted password(s) decrypted"; the PC joins the domain; the answer file on the DEPLOY partition shows only `aes256:...` |
| 1.10 | Update the stick in place (Media tab) after changing one answer file | Only the changed files are copied, it is much faster than a full build, and the stick still deploys |
| 1.11 | USB copy speed | Note the MB/s the build prints for the image |
| 1.11b | Driver packs as one file each | The build's "Packing each driver pack into one file" step lists the packs (a second build says "packed before"); `Drivers\<maker>\<model>.wim` is on the DEPLOY partition, not the folder; the build prints a `Small files` MB/s line; a deploy shows "Unpacking drivers" then "Injecting drivers", and `W:\_ImagingDrivers` is gone afterwards |
| 1.12 | Boot the stick in legacy BIOS (CSM) mode | The deploy stops with "Boot it in UEFI mode" before the disk is erased |
| 1.13 | Stick built with **Online apps on USB** ticked, deployed with the network cable out | The build's Downloading online applications step lists the apps; `FirstBoot.log` says the installer "is already in the folder; not downloaded" and the apps install |
| 1.14 | Tool version on the stick | The console header shows the version; the WinPE wizard shows the same one at the bottom of its left band and `Deploy.log` starts with "Imaging tool version"; a stick built before an update gets the yellow "built with version ..." banner in the console, and **Update the stick** opens the Media tab with that stick and Update ticked |
| 1.15 | Full screen, no console, logo background | While WinPE starts, the background is dark blue with the logo and "Deploy Windows" (not plain blue); after the WinPE password, the wizard and the progress window fill the screen with no black console behind them; Command prompt and View log open over them; after a deploy that stays in WinPE (or fails), closing the progress window shows the console with a command prompt |

## 2. Network (LAN share)

| # | Test | Pass when |
|---|------|-----------|
| 2.1 | ISO boot reaching the share | WinPE maps the share (share password decrypted with the answer file key from boot.wim or the WinPE password vault) |
| 2.3 | Dashboard | Each PC shows live progress, then the post-deploy checks |
| 2.3a | Dashboard with USB deploys, Deploy Settings section 3 on "Same place" | Deploy a PC from the stick with no network, then plug the stick into the console PC with the Dashboard open: the PC appears within 10 s (state Succeeded, "applications install at first boot"), its log shows under its Dashboard row, and the stick's `Status` folder is empty |
| 2.3b | Dashboard with USB deploys, section 3 set to a network folder (Domain Computers can write to it) | The PC shows live from WinPE, then first boot (apps, checks) until "Deployment complete"; unplug the network cable in WinPE before the deploy and the status goes to the stick instead (2.3a) |
| 2.4 | Deploy Settings: Network share, your AD account and password, **Test connection** | Green "Connected as ... The Dashboard folder ... can be written"; a wrong password gives one red line "wrong user name or password"; `deploy-settings.json` shows only `aes256:...` for the password, and ISO boot still maps the share |
| 2.5 | Computers tab: Connect, Search | The domain's computers are listed with OU, OS, last logon; Online is Yes for PCs that are on with WinRM |
| 2.6 | Build network boot image | `Boot\boot.wim` and `boot.json` on the content root; the tab says it is ready |
| 2.7 | Reimage one running PC (BitLocker on) | It restarts into WinPE with no recovery key prompt, deploys without questions, keeps its name and OU, restarts into Windows; the Dashboard shows it |
| 2.8 | Reimage a PC that is off, and one with a wrong DNS record | Both rows fail with one line, nothing changed on either PC |
| 2.8b | Check online and Reimage on a PC with PowerShell remoting off (file sharing on) | Online says Yes (SMB); the reimage goes through the admin share, no `ImagingToolRun*` service is left on it (`sc.exe \\PC query state= all`), and no `C:\Windows\Temp\ImagingTool-*` folder |

## 3. Features on the deployed PC

| # | Test | Pass when |
|---|------|-----------|
| 3.1 | BitLocker (TPM, and TPM+PIN) | Encrypted at first boot; the recovery key is backed up where the answer file says |
| 3.2 | Windows 11 readiness in Block mode | An unsupported PC stops before the erase |
| 3.2b | Same PC, tick **Install Windows 11 anyway on this PC** and press Next | The wizard goes on; the Ready to deploy summary shows the failed requirement; `Deploy.log` has "Deploying Windows 11 anyway"; Windows 11 starts and joins the domain |
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
| 4.1f | Same, with a Store app installed for one user only in the VM | The app is removed and sysprep still runs; with a missing Store the logon screen says sysprep failed |
| 4.3 | Update image with a month's .msu | New version in the Images tab, old one under Versions |
| 4.4 | Roll back a version | Answer files deploy the older image |
| 4.5 | Capture with compression **Smallest (.esd)** | The capture shows a "Compressing to the smallest size" step and logs the .esd size (about 70-80 % of Maximum); the Images tab lists `Name.esd`; a stick with it deploys normally; Update image works on it |
