#!/bin/sh
# Runs inside the builder container. Mounts (all set up by bin/build-image):
#   /src     this repository, read-only
#   /inputs  files.fossil snapshot, read-only
#   /keys    persistent image signing key (private, never in the repo)
#   /cache   exported closure, repo, mkimage work dirs
#   /out     ISO and manifest
set -eu

say() { printf '== %s\n' "$*"; }
die() { printf 'build-iso: %s\n' "$*" >&2; exit 1; }

DB=/inputs/files.fossil
[ -r "$DB" ] || die "no Fossil snapshot at $DB"

say 'Rendering catbed.cue'
render=/cache/render
rm -rf "$render"; mkdir -p "$render"
(cd /src && cue vet ./... && cue export . -e render --out json) > "$render/render.json"
python3 - "$render" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]); r = json.loads((root / 'render.json').read_text())
(root / 'machine.env').write_text(r['env'])
for rel, text in r['files'].items():
    dest = root / 'target' / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(text)
for key in ('isoExtras', 'isoLabel', 'lock'):
    val = r[key]
    (root / key).write_text((' '.join(val) if isinstance(val, list) else val) + '\n')
PY
LOCK=$(cat "$render/lock")
BRANCH=$(sed -n "s/^FOSSIL_BRANCH='\(.*\)'$/\1/p" "$render/machine.env")
EXTRAS=$(cat "$render/isoExtras")

say "Exporting the locked closure ($LOCK @ $BRANCH)"
closure=/cache/closure
python3 /src/builder/export-packages.py "$DB" "$BRANCH" "$LOCK" "$closure"

say 'Image signing key'
key=
for k in /keys/*.rsa; do [ -e "$k" ] && key=$k; done
if [ -z "$key" ]; then
    (cd /keys && openssl genrsa -out catbed-image.rsa 4096 2>/dev/null &&
        openssl rsa -in catbed-image.rsa -pubout -out catbed-image.rsa.pub 2>/dev/null)
    key=/keys/catbed-image.rsa
fi
mkdir -p /root/.abuild
printf 'PACKAGER_PRIVKEY="%s"\n' "$key" > /root/.abuild/abuild.conf
# mkimage copies /etc/apk/keys into the ISO's initramfs and apk root.
cp "$closure"/keys/* /etc/apk/keys/
cp "$key.pub" /etc/apk/keys/

say "Assembling the local repository (+ ISO-only: $EXTRAS)"
repo=/cache/repo/catbed
rm -rf "$repo"; mkdir -p "$repo/x86_64" /cache/extras
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
(cd "$repo/x86_64" && apk index --quiet --rewrite-arch x86_64 \
    --description "catbed $(date -u +%Y%m%d)" -o APKINDEX.tar.gz ./*.apk &&
    abuild-sign -q APKINDEX.tar.gz)

say 'Payload: Fossil database + manifest'
payload=/cache/payload
rm -rf "$payload"; mkdir -p "$payload"
cp "$DB" "$payload/files.fossil"
(cd "$payload" && sha256sum files.fossil > files.fossil.sha256)
checkin=$(fossil info "$BRANCH" -R "$DB" | sed -n 's/^hash: *\([0-9a-f]*\).*/\1/p')
python3 - "$payload/manifest.json" "$LOCK" "$checkin" "$(cat /aports/REVISION)" <<'PY'
import json, sys, time
from pathlib import Path
out, lock, checkin, aports = sys.argv[1:]
extras = [dict(zip(('sha256', 'file'), l.split(' ', 1)))
          for l in Path('/cache/extras.list').read_text().splitlines() if l]
Path(out).write_text(json.dumps({
    'built_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'fossil_checkin': checkin, 'lock': lock, 'aports_revision': aports,
    'files_fossil_sha256': Path(out).with_name('files.fossil.sha256').read_text().split()[0],
    'iso_only_packages': extras}, indent=1) + '\n')
PY

say 'Live overlay (/etc/catbed)'
overlay=/cache/overlay
rm -rf "$overlay"; mkdir -p "$overlay/keys"
cp "$render/machine.env" "$overlay/"
cp -a "$render/target" "$overlay/target"
cp "$closure/world" "$closure/repositories" "$overlay/"
cp "$closure"/keys/* "$key.pub" "$overlay/keys/"
cp /src/installer/catbed-install /src/installer/catbed-firstboot "$overlay/"

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
