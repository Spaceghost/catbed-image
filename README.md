# catbed-image

An offline installer ISO that puts the **catbed** desktop (Spaceghost's
MacBookPro11,5 running Alpine edge) back on bare hardware. The same locked
closure is also built as a rootfs tarball and a qcow2 VM image.

It covers the stage `RECOVERY.md` in `~/.files` assumes is already done —
disk, encryption, bootloader, user — and then hands over to that repo's own
`oldbook-rebuild`, which finishes the desktop. Nothing here duplicates the
rebuild.

```
catbed.cue ──render──▶ machine.env + /etc files ─┐
~/.files Fossil snapshot ──export──▶ locked APK closure ─┼─▶ mkimage ─▶ ISO
                         └──────────▶ files.fossil payload ┘
ISO ─▶ catbed-install ─▶ LUKS2/LVM, closure, GRUB ─▶ catbed-firstboot ─▶ oldbook-rebuild
closure ─▶ build-rootfs ─▶ catbed-rootfs.tar.zst ─▶ catbed-install --rootfs
                       └─▶ catbed-vm.qcow2 (GPT: ESP + ext4, autologin consoles)
```

## Public code, private artifacts

This repository holds only code and the machine description. It contains no
keys, passwords, Wi-Fi networks or packages. Built ISOs are private: they carry
proprietary 1Password packages and the whole `~/.files` Fossil database.
The rootfs tarball and qcow2 carry the same, so they are private too. Images
are published only to the private `Spaceghost/catbed-image-private`
repository, age-encrypted to the recovery identity. `.gitignore` refuses `*.iso`, `*.fossil`, `*.rsa` and `*.apk`.

Machine identity (SSH host keys, Wi-Fi PSKs, the Tailscale node key) is never
in any image. Restore it after install, selectively, per `RECOVERY.md` step 1.

## Layout

| Path | Item | Role |
| --- | --- | --- |
| `schema.cue`, `catbed.cue` | 1 | The machine: disk, LUKS parameters, LVM, boot, user, services, lock |
| `bin/build-image` | 2 | Host command (run on `fedora`): `check`, `plan`, `iso`, `rootfs`, `publish`, `shell` |
| `builder/Containerfile` | 2 | Alpine edge build tools plus aports' `scripts/` (mkimage) |
| `builder/export-packages.py` | 3 | Locked closure out of Fossil UV, every file checked against the lock's SHA-256 |
| `builder/prepare.sh` | 2–3 | Shared stages: render, export, signing key, closure repo, payload, manifest |
| `builder/build-iso.sh` | 2–3 | ISO repo (closure + ISO-only extras), live overlay, mkimage |
| `builder/build-rootfs.sh` | 7 | Installed base system as a tarball, then the qcow2 VM rendition |
| `mkimage/mkimg.catbed.sh` | 2 | mkimage profile: whole closure on the ISO, payload under `/catbed` |
| `mkimage/genapkovl-catbed.sh` | 4 | Live overlay: `/etc/catbed`, `catbed-install`, minimal live world |
| `installer/catbed-install` | 4 | Partition, LUKS2, LVM, offline install (or `--rootfs`), initramfs, GRUB, checkout |
| `installer/catbed-common.sh` | 4, 7 | Laying the system into a root: config, closure, user, services, handoff |
| `installer/catbed-firstboot` | 5 | First login: `oldbook-rebuild --plan`, confirm, run |

## Building (on fedora)

Builds run in rootless podman on `fedora`, never on the MacBook. Private inputs
and outputs live outside the checkout, in `~/.local/share/catbed-image/`:

```
inputs/files.fossil   consistent snapshot of ~/.files (fossil backup), copied from catbed
keys/                 image signing key (APKINDEX, modloop); generated on first build
cache/                exported closure, repository, mkimage work dirs
out/                  ISO, rootfs tarball, qcow2, each with .sha256 and .manifest.json
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
bin/build-image rootfs  # rootfs tarball and qcow2, same closure
bin/build-image publish iso|rootfs|vm   # encrypt and release to the private repo
```

### Rootfs tarball and VM image

`catbed-rootfs-x86_64.tar.zst` is the base system `catbed-install` would lay
down: closure, user (locked), services, initramfs, the Fossil checkout. The
machine files keep their `@ESP_UUID@` / `@CRYPT_UUID@` tokens.
`catbed-install --rootfs FILE` partitions and encrypts as usual, unpacks the
tarball instead of installing packages, fills the tokens and installs GRUB.

`catbed-vm-x86_64.qcow2` is the same system for a VM: one GPT disk with the
ESP and a plain ext4 root (no LUKS, no LVM), booted by a standalone GRUB with
the console on ttyS0, `jack` logged in on tty1 and ttyS0. It needs UEFI
firmware:

```sh
qemu-system-x86_64 -enable-kvm -m 4G -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
    -drive file=catbed-vm-x86_64.qcow2,if=virtio -nographic
```

The build runs with `podman --privileged`, still rootless: it needs to mount
proc and bind `/dev` into the new root for apk's scripts and mkinitfs.

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
- **Booting the qcow2** is part of the VM test, for the same reason.
- **Guix**: recipes for the patched desktop parts, and a Guix-on-Alpine image.
