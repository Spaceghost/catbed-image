# prepare.sh: the stages every image shares. Sourced inside the builder
# container by build-iso.sh and build-rootfs.sh. Mounts (from bin/build-image):
#   /src     this repository, read-only
#   /inputs  files.fossil snapshot, read-only
#   /keys    persistent image signing key (private, never in the repo)
#   /cache   exported closure, repositories, work dirs
#   /out     images and manifests
#
# Leaves behind: $render (machine.env, target/, target-vm/, render.json),
# $closure (verified packages, keys, world), $key (signing key, installed in
# /etc/apk/keys and abuild.conf), $closure_repo (signed repo of the closure
# alone), $payload (files.fossil + sha256), and LOCK BRANCH EXTRAS CHECKIN.
# shellcheck shell=sh disable=SC2034 # its variables are read by the sourcing script

say() { printf '== %s\n' "$*"; }
die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

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
for tree, files in (('target', r['files']), ('target-vm', r['vmFiles'])):
    for rel, text in files.items():
        dest = root / tree / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)
for key in ('isoExtras', 'isoLabel', 'lock', 'vmCmdline', 'vmFreeGiB'):
    val = r[key]
    (root / key).write_text((' '.join(val) if isinstance(val, list) else str(val)) + '\n')
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
cp "$closure"/keys/* /etc/apk/keys/
cp "$key.pub" /etc/apk/keys/

# index_repo DIR: index every APK in DIR/x86_64 and sign the index.
index_repo() {
    (cd "$1/x86_64" && apk index --quiet --rewrite-arch x86_64 \
        --description "catbed $(date -u +%Y%m%d)" -o APKINDEX.tar.gz ./*.apk &&
        abuild-sign -q APKINDEX.tar.gz)
}

say 'Signed repository of the closure'
closure_repo=/cache/repo/closure
rm -rf "$closure_repo"; mkdir -p "$closure_repo/x86_64"
cp "$closure"/packages/*.apk "$closure_repo/x86_64/"
index_repo "$closure_repo"

say 'Payload: Fossil database'
payload=/cache/payload
rm -rf "$payload"; mkdir -p "$payload"
cp "$DB" "$payload/files.fossil"
(cd "$payload" && sha256sum files.fossil > files.fossil.sha256)
CHECKIN=$(fossil info "$BRANCH" -R "$DB" | sed -n 's/^hash: *\([0-9a-f]*\).*/\1/p')

# write_manifest OUT KIND EXTRAS_LIST: provenance for one built image.
write_manifest() {
    python3 - "$1" "$2" "$3" "$LOCK" "$CHECKIN" "$(cat /aports/REVISION)" \
        "$payload/files.fossil.sha256" <<'PY'
import json, sys, time
from pathlib import Path
out, kind, extras_list, lock, checkin, aports, fossil_sum = sys.argv[1:]
extras = []
if Path(extras_list).is_file():
    extras = [dict(zip(('sha256', 'file'), l.split(' ', 1)))
              for l in Path(extras_list).read_text().splitlines() if l]
Path(out).write_text(json.dumps({
    'kind': kind,
    'built_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'fossil_checkin': checkin, 'lock': lock, 'aports_revision': aports,
    'files_fossil_sha256': Path(fossil_sum).read_text().split()[0],
    'unlocked_packages': extras}, indent=1) + '\n')
PY
}
