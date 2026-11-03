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
| 1.9 | Stick built **without** a WinPE password | The wizard shows a Passwords page after the answer file with one box per password (join, local Administrator...); after Confirm no password window pops up |
| 1.10 | Update the stick in place (Media tab) after changing one answer file | Only the changed files are copied, it is much faster than a full build, and the stick still deploys |
| 1.11 | USB copy speed | Note the MB/s the build prints for the image |

## 2. Network (LAN share, PXE)

| # | Test | Pass when |
|---|------|-----------|
| 2.1 | ISO or PXE boot.wim reaching the share | WinPE maps the share (password from the WinPE password vault or the share's password file) |
| 2.2 | Publish to WDS, PXE boot a PC | WinPE starts with F12 (or without, when prestaged) |
| 2.3 | Multicast with 2+ PCs | Room monitor shows both; both deploy |
| 2.4 | Dashboard | Each PC shows live progress, then the post-deploy checks |

## 3. Remote reimage

| # | Test | Pass when |
|---|------|-----------|
| 3.1 | PC on, PXE method | Restarts into PXE once, deploys, does not loop |
| 3.2 | PC off, Wake-on-LAN | Wakes and reimages (check Deep Sleep Control on Dell) |
| 3.3 | **No PXE** (boot.wim from the PC's own disk) | PC restarts straight into WinPE from C:, deploys; works with BitLocker on |
| 3.4 | **Back up the old Windows first** | `Backups\<serial>-<date>.wim` on the share, and it mounts with `dism /Mount-Image` |

## 4. Features on the deployed PC

| # | Test | Pass when |
|---|------|-----------|
| 4.1 | BitLocker (TPM, and TPM+PIN) | Encrypted at first boot; the recovery key is backed up where the answer file says |
| 4.2 | BIOS settings (Dell, HP, Lenovo) | Settings changed; a BIOS password is used when set |
| 4.3 | USMT user data (share and local store) | A user's files and settings come back after the reimage |
| 4.4 | Windows 11 readiness in Block mode | An unsupported PC stops before the erase |

## 5. Capture and image upkeep

| # | Test | Pass when |
|---|------|-----------|
| 5.1 | Hands-free Hyper-V capture | Image in `Images`, VM rolled back to its checkpoint |
| 5.2 | VMware disk file capture | Same |
| 5.3 | Update image with a month's .msu | New version in the Images tab, old one under Versions |
| 5.5 | Roll back a version | Answer files deploy the older image |
