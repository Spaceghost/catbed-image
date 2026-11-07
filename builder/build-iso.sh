#!/bin/sh
# Build the catbed installer ISO. Runs inside the builder container; see
# prepare.sh for the mounts and the shared stages.
set -eu
# shellcheck source=prepare.sh
. /src/builder/prepare.sh

say "ISO repository (closure + ISO-only: $EXTRAS)"
repo=/cache/repo/catbed
rm -rf "$repo" /cache/extras; mkdir -p "$repo/x86_64" /cache/extras
cp "$closure"/packages/*.apk "$repo/x86_64/"
# ISO-only packages and any dependency the lock lacks; locked names win.
# shellcheck disable=SC2086 # EXTRAS is a word list
apk fetch --no-cache -R -o /cache/extras \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/main \
    -X https://dl-cdn.alpinelinux.org/alpine/edge/community $EXTRAS >/dev/null
: > /cache/extras.list
for f in /cache/extras/*.apk; do
    name=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p')
    if ! grep -qx "$name" "$closure/names"; then
        cp "$f" "$repo/x86_64/"
        printf '%s %s\n' "$(sha256sum "$f" | cut -c1-64)" "$(basename "$f")" >> /cache/extras.list
    fi
done
# update-kernel always installs `linux-firmware`, the upstream metapackage
# that pins every firmware package at upstream's current version. This stub
# stands in for it on the ISO only: no files, depending on exactly the locked
# split firmware. The target never installs it.
stub=/cache/stub/linux-firmware
rm -rf /cache/stub; mkdir -p "$stub"
cat > "$stub/APKBUILD" <<EOF
pkgname=linux-firmware
pkgver=0
pkgrel=0
pkgdesc="catbed ISO stub: the locked split linux-firmware packages"
url="https://github.com/Spaceghost/catbed-image"
arch="noarch"
license="custom"
depends="$(grep '^linux-firmware-' "$closure/names" | tr '\n' ' ')"
options="!check"
package() { mkdir -p "\$pkgdir"; }
EOF
(cd "$stub" && abuild -F -d -P /cache/stub/out rootpkg >/dev/null)
for f in /cache/stub/out/*/*/linux-firmware-0-r0.apk; do
    cp "$f" "$repo/x86_64/"
    printf '%s %s (generated stub)\n' "$(sha256sum "$f" | cut -c1-64)" "${f##*/}" >> /cache/extras.list
done
index_repo "$repo"
write_manifest "$payload/manifest.json" iso /cache/extras.list

say 'Live overlay (/etc/catbed)'
overlay=/cache/overlay
rm -rf "$overlay"; mkdir -p "$overlay/keys"
cp "$render/machine.env" "$overlay/"
cp -a "$render/target" "$overlay/target"
cp "$closure/world" "$closure/repositories" "$overlay/"
cp "$closure"/keys/* "$key.pub" "$overlay/keys/"
cp /src/installer/catbed-install /src/installer/catbed-firstboot \
    /src/installer/catbed-common.sh "$overlay/"

say 'mkimage'
cp /src/mkimage/mkimg.catbed.sh /src/mkimage/genapkovl-catbed.sh /aports/scripts/
# apk 3 maps --no-chown to --usermode, which refuses root. Root here is the
# unprivileged fedora user (rootless podman), so ownership is safe to keep.
grep -q 'add --initdb --no-chown' /aports/scripts/mkimage.sh ||
    die 'mkimage.sh no longer has the --no-chown line this build patches; recheck'
sed -i 's/ add --initdb --no-chown/ add --initdb/' /aports/scripts/mkimage.sh
chmod +x /aports/scripts/genapkovl-catbed.sh
export CATBED_NAMES="$closure/names" CATBED_EXTRAS="$EXTRAS" \
    CATBED_PAYLOAD="$payload" CATBED_OVERLAY="$overlay"
# Always from an empty work dir. mkimage reuses any section whose directory
# exists, and the names do not cover the inputs: the overlay is just
# apkovl_<hostname>, the package and kernel sections hash the package names,
# not the packages. A kept work dir silently ships the previous overlay.
rm -rf /cache/mkimage
mkdir -p /cache/mkimage
# --hostkeys: the lock's 1Password and personal keys, not only Alpine's.
sh /aports/scripts/mkimage.sh --tag edge --arch x86_64 --profile catbed --hostkeys \
    --outdir /out --workdir /cache/mkimage --repository "$repo"

iso=
# Names carry the build date, so the last in glob order is the newest.
for f in /out/alpine-catbed-*.iso; do iso=$f; done
[ -e "$iso" ] || die "mkimage produced no ISO"
cp "$payload/manifest.json" "${iso%.iso}.manifest.json"
(cd /out && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256")
say "Built $iso"
cat "$iso.sha256"
