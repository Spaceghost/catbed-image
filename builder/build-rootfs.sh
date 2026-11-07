#!/bin/sh
# Build the catbed rootfs tarball and the qcow2 VM image. Runs inside the
# builder container started with --privileged (still rootless: "root" here is
# the unprivileged fedora user), which lets it mount proc and bind /dev into
# the root being filled, as apk's scripts and mkinitfs expect.
#
#   /out/catbed-rootfs-x86_64.tar.zst  the installed base system, machine
#       files with @...@ tokens unresolved; `catbed-install --rootfs` lays it
#       onto the LUKS/LVM disk and fills them in.
#   /out/catbed-vm-x86_64.qcow2  the same system on one GPT disk (ESP + plain
#       ext4), booted by a standalone GRUB, consoles logged in on tty1/ttyS0.
set -eu
# shellcheck source=prepare.sh
. /src/builder/prepare.sh

# What catbed-common.sh reads, staged the way the ISO lays out /etc/catbed.
CONF=/cache/conf
rm -rf "$CONF"; mkdir -p "$CONF/keys"
cp "$render/machine.env" "$closure/world" "$closure/repositories" "$CONF/"
cp "$closure"/keys/* "$key.pub" "$CONF/keys/"
cp /src/installer/catbed-firstboot "$CONF/"
# shellcheck source=/dev/null
. "$CONF/machine.env"
# shellcheck source=../installer/catbed-common.sh
. /src/installer/catbed-common.sh
PLAN=0
REPO=$closure_repo
TARGET=/cache/rootfs

mount_api() {
    mkdir -p "$TARGET/proc" "$TARGET/dev" "$TARGET/sys"
    mount -t proc proc "$TARGET/proc"
    mount -o rbind /dev "$TARGET/dev"
}
umount_api() {
    umount -R "$TARGET/dev" 2>/dev/null || true
    umount "$TARGET/proc" 2>/dev/null || true
}
trap umount_api EXIT

umount_api
rm -rf "$TARGET"; mkdir -p "$TARGET"
step 'Base configuration (tokens left for the installer)'
lay_config "$render/target" '@ESP_UUID@' '@CRYPT_UUID@' '@ROOT_UUID@'
mount_api
step "Installing the locked closure ($(wc -l < "$CONF/world") world entries)"
# grub's /boot trigger runs update-grub, whose grub-probe needs the real disk
# behind /; a container has none. The trigger honours this file; it is
# removed again so the machine matches catbed (which has none), and
# catbed-install runs grub-mkconfig once the disk exists.
printf 'disable_trigger=1\n' > "$TARGET/etc/update-grub.conf"
install_closure
rm "$TARGET/etc/update-grub.conf"
# The builder's repo path means nothing on the machine; drop it.
sed -i "\\|^#$REPO\$|d" "$TARGET/etc/apk/repositories"
step "User $USER_NAME (uid $USER_UID), account locked"
create_user
in_target passwd -l root >/dev/null
step 'OpenRC services'
enable_services
step 'Initramfs'
build_initramfs
step "Fossil database and ~/.files checkout ($FOSSIL_BRANCH)"
place_checkout "$payload"
write_manifest "$payload/manifest.json" rootfs /dev/null
stamp_handoff "$payload/manifest.json"
umount_api
! grep -q " $TARGET/" /proc/mounts || die "still mounted under $TARGET; not archiving"
rm -rf "${TARGET:?}/var/cache/apk/"*

step 'Rootfs tarball'
tarball=/out/catbed-rootfs-x86_64.tar.zst
# Keep file capabilities (newuidmap and friends); drop security.selinux, the
# label fedora's SELinux puts on every file the build creates. Alpine has no
# use for it, and it would only record the build host's policy.
(cd "$TARGET" && tar -c --numeric-owner --xattrs --xattrs-include='*' \
    --xattrs-exclude='security.selinux' -f - .) |
    zstd -q -T0 -19 -f -o "$tarball"
cp "$payload/manifest.json" /out/catbed-rootfs-x86_64.manifest.json
(cd /out && sha256sum "${tarball##*/}" > "${tarball##*/}.sha256")

step 'VM image'
vm=/cache/vmroot
# From the tarball, with GNU tar: busybox cp -a would drop xattrs (file
# capabilities), and this way the VM is exactly the published rootfs.
rm -rf "$vm"; mkdir -p "$vm"
zstd -dc "$tarball" | tar -xp --numeric-owner --xattrs --xattrs-include='*' -C "$vm" -f -
ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
serial=$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n' | tr a-f A-F)
ESP_UUID=$(printf '%s-%s' "$(printf %s "$serial" | cut -c1-4)" "$(printf %s "$serial" | cut -c5-8)")
(cd "$render/target-vm" && find . -type f) | while read -r rel; do
    mkdir -p "$(dirname "$vm/${rel#./}")"
    sed -e "s|@ESP_UUID@|$ESP_UUID|g" -e "s|@ROOT_UUID@|$ROOT_UUID|g" \
        -e "s|@CRYPT_UUID@||g" "$render/target-vm/$rel" > "$vm/${rel#./}"
done
manifest_vm=/out/catbed-vm-x86_64.manifest.json
write_manifest "$manifest_vm" vm /dev/null
cp "$manifest_vm" "$vm/var/lib/catbed/image-manifest.json"

work=/cache/vmwork
rm -rf "$work"; mkdir -p "$work/esp/EFI/BOOT"
# /boot is the ESP: its contents move to the FAT image, the mount point stays.
mv "$vm"/boot/* "$work/esp/"
kernel=; initrd=
for f in "$work"/esp/vmlinuz-*; do kernel=${f##*/}; done
for f in "$work"/esp/initramfs-*; do initrd=${f##*/}; done
[ -n "$kernel" ] && [ -n "$initrd" ] || die 'no kernel or initramfs in /boot'
cmdline=$(sed "s|@ROOT_UUID@|$ROOT_UUID|g" "$render/vmCmdline")
cat > "$work/grub.cfg" <<EOF
set timeout=1
search --no-floppy --fs-uuid --set=root $ESP_UUID
menuentry 'catbed (VM)' {
    linux /$kernel $cmdline
    initrd /$initrd
}
EOF
grub-mkstandalone -O x86_64-efi -o "$work/esp/EFI/BOOT/BOOTX64.EFI" \
    --modules='part_gpt fat ext2 linux normal search search_fs_uuid gzio all_video efi_gop' \
    "boot/grub/grub.cfg=$work/grub.cfg"

esp_mib=$EFI_MIB
root_mib=$(( $(du -sm "$vm" | cut -f1) * 115 / 100 + $(cat "$render/vmFreeGiB") * 1024 ))
mkfs.vfat -C -F 32 -i "$serial" -n CATBEDESP "$work/esp.img" $((esp_mib * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -i "$work/esp.img" "$work"/esp/* ::/
mkfs.ext4 -q -F -U "$ROOT_UUID" -L catbed-root -d "$vm" "$work/root.img" "${root_mib}M"
# Files extracted here were labelled by fedora's SELinux again, and mke2fs -d
# copies every xattr it finds; take the label back out of the image.
(cd "$vm" && find . | sed -e 's|^\.||' -e 's|^$|/|' -e 's|"|\\"|g' \
    -e 's|.*|ea_rm "&" security.selinux|') > "$work/ea_rm.cmds"
debugfs -w -f "$work/ea_rm.cmds" "$work/root.img" >/dev/null 2>&1
e2fsck -fn "$work/root.img" >/dev/null || die 'root.img fails e2fsck after relabel'
total_mib=$((1 + esp_mib + root_mib + 1))
truncate -s "${total_mib}M" "$work/disk.raw"
printf 'label: gpt\nstart=2048, size=%s, type=U\nstart=%s, size=%s, type=L\n' \
    $((esp_mib * 2048)) $(((1 + esp_mib) * 2048)) $((root_mib * 2048)) |
    sfdisk --quiet "$work/disk.raw"
dd if="$work/esp.img" of="$work/disk.raw" bs=1M seek=1 conv=notrunc status=none
dd if="$work/root.img" of="$work/disk.raw" bs=1M seek=$((1 + esp_mib)) conv=notrunc status=none
qcow=/out/catbed-vm-x86_64.qcow2
qemu-img convert -c -O qcow2 "$work/disk.raw" "$qcow"
rm -rf "$work" "$vm"
(cd /out && sha256sum "${qcow##*/}" > "${qcow##*/}.sha256")

say "Built $tarball and $qcow"
cat "$tarball.sha256" "$qcow.sha256"
