# Hardware test checklist

Everything below passes the Windows CI tests, but CI has no real WinPE, USB stick, PXE server or laptop.
Work through it in this order: each step needs the ones before it. Note the date and result next to each
line, and when one fails, use **Copy logs** in WinPE and keep the `Logs\<serial>-<date>` folder.

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
| 1.9 | Stick built **without** a WinPE password, answer file passwords typed in the editor | No Passwords page and no password window; `Deploy.log` says "encrypted password(s) decrypted"; the PC joins the domain; the answer file on the DEPLOY partition shows only `aes256:...` |
| 1.10 | Update the stick in place (Media tab) after changing one answer file | Only the changed files are copied, it is much faster than a full build, and the stick still deploys |
| 1.11 | USB copy speed | Note the MB/s the build prints for the image |
| 1.12 | Boot the stick in legacy BIOS (CSM) mode | The deploy stops with "Boot it in UEFI mode" before the disk is erased |
| 1.13 | Stick built with **Online apps on USB** ticked, deployed with the network cable out | The build's Downloading online applications step lists the apps; `FirstBoot.log` says the installer "is already in the folder; not downloaded" and the apps install |

## 2. Network (LAN share, PXE)

| # | Test | Pass when |
|---|------|-----------|
| 2.1 | ISO or PXE boot.wim reaching the share | WinPE maps the share (password from the WinPE password vault or the share's password file) |
| 2.2 | Publish to WDS, PXE boot a PC | WinPE starts with F12 (or without, when prestaged) |
| 2.3 | Dashboard | Each PC shows live progress, then the post-deploy checks |
| 2.4 | Deploy Settings: Network share, your AD account and password, **Test connection** | Green "Connected as ... The Dashboard folder ... can be written"; a wrong password gives one red line "wrong user name or password"; `deploy-settings.json` shows only `aes256:...` for the password, an old `config\share.cred` is gone after Save, and ISO/PXE still maps the share |

## 3. Features on the deployed PC

| # | Test | Pass when |
|---|------|-----------|
| 3.1 | BitLocker (TPM, and TPM+PIN) | Encrypted at first boot; the recovery key is backed up where the answer file says |
| 3.2 | Windows 11 readiness in Block mode | An unsupported PC stops before the erase |
| 3.2b | Same PC, tick **Install Windows 11 anyway on this PC** and press Next | The wizard goes on; the Ready to deploy summary shows the failed requirement; `Deploy.log` has "Deploying Windows 11 anyway"; Windows 11 starts and joins the domain |

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
| 4.2 | Capture ISO booted in a VM | Image on the share's `Images` folder, VM shuts down |
| 4.3 | Update image with a month's .msu | New version in the Images tab, old one under Versions |
| 4.4 | Roll back a version | Answer files deploy the older image |
