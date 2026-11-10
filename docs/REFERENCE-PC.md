# Prepare and capture the reference PC

Step by step, from an empty VM to a new image on the Images tab. The reference is a VM
(VMware Workstation here) captured with the wizard's **A VM's disk file on this PC** choice.

## Why the Store went missing

Before PR #77, `Prepare-Reference.ps1 -RemoveUserApps` removed every Store app whose installed
version was not the provisioned one, with `-AllUsers`. Once the Store had updated itself (or
Notepad, Photos, Terminal...), that removal also took the app out of the image. Now
`-RemoveUserApps` only removes apps that were never part of Windows, and the script refuses
to run sysprep when the Store is not provisioned.

`wsreset -i` puts the Store back for the signed-in user only. That fixes one PC, but it does not put
the Store back in the image: sysprep would fail on it and new users would still not get it. A
reference that lost the Store has to be reverted or reinstalled (step 1).

## 1. Start from a clean Windows

Pick one:

- **Revert the VM** to a snapshot taken before `Prepare-Reference -RemoveUserApps` first ran on it
  (VM > Snapshot > Snapshot Manager). Only a snapshot from before that run still has the Store.
- **Install Windows fresh** in the VM from the Windows ISO (same edition as before). At the first
  OOBE screen (region), press **Ctrl+Shift+F3**: Windows restarts in **audit mode**, signed in as
  the built-in Administrator, with no user account and no Microsoft account. Stay in audit mode
  for every step below; close the System Preparation Tool window each time it opens.

Audit mode is the cleanest: no user ever signs in, so no app gets installed for one user only.

## 2. Keep the Store from changing apps while you build

The Store updating Windows apps for a user is what breaks sysprep and the image. Until capture:

- Do not sign in to the Store or with a Microsoft account.
- Do not open the Store, and don't install anything from it.

## 3. Update and set up Windows

1. Run Windows Update until it finds nothing, rebooting each time.
2. Install only what must be in the image. Applications are better as app packs (Applications
   tab): they install at first boot and you never recapture to update them.
3. No OEM drivers: the deploy injects the right pack for each model.

## 4. Check BitLocker

In an elevated prompt: `manage-bde -status C:`. If it is not **Fully Decrypted**, run
`manage-bde -off C:` and wait until it is.

## 5. Take a snapshot

Shut the VM down and take a snapshot named **Before sysprep**. You come back to it for the next
image, since a sysprepped Windows should not be sysprepped again and again.

## 6. Run the check

Start the VM. In an elevated PowerShell, run the command the capture wizard shows, with
`-CheckOnly` first:

```
powershell -ExecutionPolicy Bypass -File "<share>\Tools\Prepare-Reference.ps1" -CheckOnly
```

It prints `PROBLEM:` lines (must fix) and `WARNING:` lines (read them):

| Message | What to do |
| --- | --- |
| The Microsoft Store is missing | Go back to step 1. |
| A reboot is pending | Reboot, run the check again. |
| BitLocker is ... | Step 4. |
| Store apps installed for a user but not provisioned | Run again with `-RemoveUserApps` (it never removes the Store or a Windows app). |
| The Store updated these Windows apps | Fine as long as sysprep succeeds. If sysprep fails on one of them, revert to **Before sysprep**, then go back to step 2. |
| The Store policy ... is set | Delete it, unless every deployed PC should have it. |
| This looks like physical hardware | Expected only on a physical reference. |

## 7. Sysprep

Run the same command without `-CheckOnly` (add `-RemoveUserApps` if step 6 asked for it). Sysprep
runs and the VM **shuts down by itself**. Don't start it again: it would run OOBE and the disk would
no longer be generalized.

If the VM does not shut down and sysprep shows an error, the next `-CheckOnly` run shows the first
error line from `C:\Windows\System32\Sysprep\Panther\setuperr.log`.

## 8. Capture

On the admin PC, in the console: **Images > Capture new image...**

1. **A VM's disk file on this PC**, and the VM's .vmdk (the newest snapshot is read).
2. Tick that the prepare command has run.
3. **Check the disk**: wait until every line has a tick. A cross on "Sysprep has run" means the VM
   was not generalized: boot it, run the prepare command again, and click **Check again**.
4. Name the image. To replace the current image, keep the same name and tick
   **capture it as a new version**: the old one is kept in `Images\Previous`.
5. Start. The progress window shows each step and the time left.

## 9. Put the VM back

Revert the VM to **Before sysprep**, ready for the next image.

## 10. Test the new image

1. Update the stick (Media tab, **Update a stick this console built before**).
2. Deploy one test PC. On it, in an elevated PowerShell:

   ```
   Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*Store*'
   Get-AppxPackage -AllUsers Microsoft.WindowsStore
   ```

   Both should list the Store, and the Store should open from the Start menu.
