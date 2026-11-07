#!/bin/sh -e
# Build the live system's apkovl for the catbed installer. Called by mkimage.sh
# with the hostname as $1, in a scratch directory; writes $1.apkovl.tar.gz.
# CATBED_OVERLAY holds the prepared /etc/catbed tree (env, rendered target
# files, keys, world, installer scripts).

HOSTNAME="$1"
[ -n "$HOSTNAME" ] || { echo "usage: $0 hostname" >&2; exit 1; }
[ -d "${CATBED_OVERLAY:-}" ] || { echo "CATBED_OVERLAY not set" >&2; exit 1; }

cleanup() { rm -rf "$tmp"; }
tmp="$(mktemp -d)"
trap cleanup EXIT

makefile() {
	owner="$1" perms="$2" filename="$3"
	cat > "$filename"
	chown "$owner" "$filename"
	chmod "$perms" "$filename"
}

rc_add() {
	mkdir -p "$tmp"/etc/runlevels/"$2"
	ln -sf /etc/init.d/"$1" "$tmp"/etc/runlevels/"$2"/"$1"
}

mkdir -p "$tmp"/etc/apk "$tmp"/etc/apk/keys "$tmp"/usr/local/sbin

makefile root:root 0644 "$tmp"/etc/hostname <<EOF
$HOSTNAME
EOF

# Only what the installer runs; the target's closure stays on the media.
makefile root:root 0644 "$tmp"/etc/apk/world <<EOF
alpine-base
blkid
cryptsetup
dosfstools
e2fsprogs
findmnt
lsblk
lvm2
sfdisk
util-linux-misc
EOF

makefile root:root 0644 "$tmp"/etc/motd <<EOF

  catbed installer. Log in as root (no password on the live system), then:

      catbed-install --plan     # show every step, change nothing
      catbed-install            # erase the target disk and install

EOF

cp -a "$CATBED_OVERLAY" "$tmp"/etc/catbed
cp "$CATBED_OVERLAY"/keys/* "$tmp"/etc/apk/keys/
install -m 0755 "$CATBED_OVERLAY"/catbed-install "$tmp"/usr/local/sbin/catbed-install

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" etc usr | gzip -9n > "$HOSTNAME".apkovl.tar.gz
