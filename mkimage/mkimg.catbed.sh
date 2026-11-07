# mkimage profile for the catbed installer ISO. Sourced by aports'
# scripts/mkimage.sh, which must be given only the catbed repository (the
# locked closure plus the few ISO-only extras), so nothing unlocked can enter.
#
# Inputs from the environment (set by builder/build-iso.sh):
#   CATBED_NAMES    file listing every package in the lock, one per line
#   CATBED_EXTRAS   space-separated ISO-only packages (syslinux ...)
#   CATBED_PAYLOAD  directory copied to /catbed on the ISO (fossil db, manifest)
#   CATBED_OVERLAY  directory genapkovl-catbed.sh turns into the live apkovl

profile_catbed() {
	profile_base
	title="catbed installer"
	desc="Offline installer for the catbed MacBookPro11,5 Alpine desktop."
	arch="x86_64"
	image_ext="iso"
	output_format="iso"
	kernel_flavors="lts"
	kernel_addons=
	kernel_cmdline="console=tty0"
	syslinux_serial=
	# The whole closure goes into the ISO's /apks repository so the target
	# installs offline; the live system itself only boots the small world in
	# the apkovl.
	apks="$(cat "$CATBED_NAMES") $CATBED_EXTRAS"
	hostname="catbed-installer"
	apkovl="genapkovl-catbed.sh"
}

section_catbed_payload() {
	[ -n "${CATBED_PAYLOAD:-}" ] || return 0
	[ "$PROFILE" = catbed ] || return 0
	build_section catbed_payload \
		$(cat "$CATBED_PAYLOAD"/manifest.json "$CATBED_PAYLOAD"/files.fossil.sha256 2>/dev/null | sha1sum | cut -c1-16)
}

build_catbed_payload() {
	mkdir -p "$DESTDIR"/catbed
	cp -a "$CATBED_PAYLOAD"/. "$DESTDIR"/catbed/
}

# mkimage.base asks for the linux-firmware metapackage; the lock carries only
# the split linux-firmware-* packages this machine needs (brcm for the
# BCM43602, i915, radeon ...). Same section, locked firmware instead. Sourced
# after mkimg.base.sh, so this definition wins for every profile in the run.
section_kernels() {
	local _f _a _pkgs _fw
	_fw=$(grep '^linux-firmware-' "$CATBED_NAMES" | tr '\n' ' ')
	for _f in $kernel_flavors; do
		_pkgs="linux-$_f $_fw wireless-regdb $modloop_addons"
		for _a in $kernel_addons; do
			_pkgs="$_pkgs $_a-$_f"
		done
		local id=$( (echo "$initfs_features::$_hostkeys" ; apk fetch --root "$APKROOT" --simulate alpine-base $_pkgs | sort) | checksum)
		# The section dir is named from its arguments; thirteen firmware names
		# overflow NAME_MAX. $id already hashes the package set, so pass the
		# list beside the call instead of in it.
		CATBED_KERNEL_PKGS=$_pkgs
		build_section kernel $ARCH $_f $id
	done
}

# Upstream build_kernel (aports scripts/mkimg.base.sh), changed only to take
# its packages from CATBED_KERNEL_PKGS when the section passes none.
build_kernel() {
	local _flavor="$2" _modloopsign='' _add
	shift 3
	local _pkgs="${*:-$CATBED_KERNEL_PKGS}"
	if [ "$modloop_sign" = "yes" ]; then
		_modloopsign="--modloopsign --apk-pubkey $_abuild_pubkey"
		if [ -z "$PACKAGER_PRIVKEY" ]; then
			error "Need \$PACKAGER_PRIVKEY to be set for modloop_sign=yes"
			return 1
		fi
	fi
	update-kernel \
		$_hostkeys \
		$_modloopsign \
		--media \
		--cache-dir "$APKROOT/etc/apk/cache" \
		--keys-dir "$APKROOT/etc/apk/keys" \
		--flavor "$_flavor" \
		--arch "$ARCH" \
		--package "$_pkgs" \
		--feature "$initfs_features" \
		--modloopfw "$modloopfw" \
		--repositories-file "$APKROOT/etc/apk/repositories" \
		"$DESTDIR"
	for _add in $boot_addons; do
		apk fetch --root "$APKROOT" --quiet --stdout $_add | tar -C "${DESTDIR}" -zx boot/
	done
}
