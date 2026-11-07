# catbed-image

An offline installer ISO that puts the **catbed** desktop (Spaceghost's
MacBookPro11,5 running Alpine edge) back on bare hardware.

It covers the stage `RECOVERY.md` in `~/.files` assumes is already done —
disk, encryption, bootloader, user — and then hands over to that repo's own
`oldbook-rebuild`, which finishes the desktop. Nothing here duplicates the
rebuild.

```
catbed.cue ──render──▶ machine.env + /etc files ─┐
~/.files Fossil snapshot ──export──▶ locked APK closure ─┼─▶ mkimage ─▶ ISO
                         └──────────▶ files.fossil payload ┘
ISO ─▶ catbed-install ─▶ LUKS2/LVM, closure, GRUB ─▶ catbed-firstboot ─▶ oldbook-rebuild
```

## Public code, private artifacts

This repository holds only code and the machine description. It contains no
keys, passwords, Wi-Fi networks or packages. Built ISOs are private: they carry
proprietary 1Password packages and the whole `~/.files` Fossil database.
They are published only to the private `Spaceghost/catbed-image-private`
repository. `.gitignore` refuses `*.iso`, `*.fossil`, `*.rsa` and `*.apk`.

Machine identity (SSH host keys, Wi-Fi PSKs, the Tailscale node key) is never
in any image. Restore it after install, selectively, per `RECOVERY.md` step 1.

## Layout

| Path | Item | Role |
| --- | --- | --- |
| `schema.cue`, `catbed.cue` | 1 | The machine: disk, LUKS parameters, LVM, boot, user, services, lock |
| `bin/build-image` | 2 | Host command (run on `fedora`): `check`, `plan`, `iso`, `shell` |
| `builder/Containerfile` | 2 | Alpine edge build tools plus aports' `scripts/` (mkimage) |
| `builder/export-packages.py` | 3 | Locked closure out of Fossil UV, every file checked against the lock's SHA-256 |
| `builder/build-iso.sh` | 2–3 | Render, export, index and sign the repo, assemble payload, run mkimage |
| `mkimage/mkimg.catbed.sh` | 2 | mkimage profile: whole closure on the ISO, payload under `/catbed` |
| `mkimage/genapkovl-catbed.sh` | 4 | Live overlay: `/etc/catbed`, `catbed-install`, minimal live world |
| `installer/catbed-install` | 4 | Partition, LUKS2, LVM, offline install, user, services, initramfs, GRUB, checkout |
| `installer/catbed-firstboot` | 5 | First login: `oldbook-rebuild --plan`, confirm, run |

## Building (on fedora)

Builds run in rootless podman on `fedora`, never on the MacBook. Private inputs
and outputs live outside the checkout, in `~/.local/share/catbed-image/`:

```
inputs/files.fossil   consistent snapshot of ~/.files (fossil backup), copied from catbed
keys/                 image signing key (APKINDEX, modloop); generated on first build
cache/                exported closure, repository, mkimage work dirs
out/                  alpine-catbed-*.iso, .sha256, .manifest.json
```

To refresh the snapshot, run this from catbed:

```sh
fossil backup -R ~/.local/share/fossil/files.fossil /tmp/files.fossil
rsync /tmp/files.fossil fedora:.local/share/catbed-image/inputs/files.fossil
```

Then, on fedora:

```sh
bin/build-image check   # cue vet, shellcheck, parse
bin/build-image plan    # print the rendered machine.env
bin/build-image iso     # build; ~5 GB ISO in ~/.local/share/catbed-image/out
```

### What is and is not locked

Every package the **target** receives is the exact file named in the lock,
taken from Fossil and checked by SHA-256. The apk signatures are checked
against the lock's own five public keys. Packages needed only to **build or
boot the ISO** but absent from the lock (`syslinux`, `mtools`, `xorriso` and
any dependency the lock lacks) come from Alpine edge at build time. Their
hashes are recorded in the ISO's `manifest.json`. A locked package name always
wins over an extra.

The repository index is signed with a per-image key that never leaves
fedora's private directory. That key's public half sits beside the lock's keys
on the ISO and the target.

## Installing

1. Write the ISO to a USB stick (`dd if=alpine-catbed-*.iso of=/dev/sdX bs=4M`)
   and boot the Mac holding **Option**, choosing "EFI Boot".
2. Log in as `root` and run `catbed-install --plan` to read every step.
3. Run `catbed-install`. Type the disk name to confirm, then enter the LUKS
   passphrase and the account passwords when asked. Nothing secret is stored.
4. Reboot, log in as `jack` and run `catbed-firstboot`.

The install is fully offline: packages and the Fossil database come from the
stick. Wi-Fi, Tailscale and logins come afterwards, as `oldbook-rebuild`
reports.

## Not yet

- **VM test** (`build-image test`): waits for VT-x to be enabled in fedora's
  firmware. QEMU without KVM would make each install test take most of an hour.
- **Root filesystem tarball / qcow2** and the **Guix** recipes and image: these
  come after the ISO, per the plan.
