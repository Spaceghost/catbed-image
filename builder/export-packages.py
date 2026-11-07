#!/usr/bin/env python3
"""Export the locked APK closure from a Fossil snapshot into a flat repo dir.

Every file is taken from Fossil unversioned storage by the artifact path the
lock records, and must match the lock's SHA-256 before it is kept. Nothing is
downloaded. The lock's public keys are written beside it so `apk` can check
each package's own signature against exactly the keys the machine trusted.

usage: export-packages.py FOSSIL_DB BRANCH LOCK_PATH OUT_DIR
  LOCK_PATH is a path inside the checkout, e.g. alpine/packages/locks/x.json
"""
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    db, branch, lock_path, out = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
    pkgs, keys = out / 'packages', out / 'keys'
    pkgs.mkdir(parents=True, exist_ok=True)
    keys.mkdir(parents=True, exist_ok=True)

    lock = json.loads(subprocess.run(
        ['fossil', 'cat', lock_path, '-R', str(db), '-r', branch],
        check=True, capture_output=True).stdout)
    if lock.get('schema') != 2 or lock.get('arch') != 'x86_64':
        sys.exit(f'unexpected lock schema/arch in {lock_path}')

    for key in lock['keys']:
        data = key['content'].encode()
        if hashlib.sha256(data).hexdigest() != key['sha256']:
            sys.exit(f'key {key["name"]} does not match its recorded hash')
        (keys / key['name']).write_bytes(data)

    missing, kept = [], 0
    with tempfile.TemporaryDirectory(dir=out) as tmp:
        for entry in lock['packages']:
            dest = pkgs / entry['filename']
            if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest() == entry['sha256']:
                kept += 1
                continue
            staged = Path(tmp) / entry['filename']
            result = subprocess.run(['fossil', 'uv', 'export', entry['artifact'],
                                     str(staged), '-R', str(db)],
                                    capture_output=True, text=True)
            if result.returncode:
                missing.append(entry['artifact'])
                continue
            digest = hashlib.sha256(staged.read_bytes()).hexdigest()
            if digest != entry['sha256']:
                sys.exit(f'{entry["filename"]}: sha256 {digest} != lock {entry["sha256"]}')
            staged.replace(dest)
            kept += 1

    if missing:
        sys.exit('missing from Fossil UV:\n  ' + '\n  '.join(missing))

    world = [line for line in lock['world'].splitlines() if line.strip()]
    (out / 'world').write_text('\n'.join(world) + '\n')
    (out / 'repositories').write_text(lock['repositories'])
    (out / 'lock.json').write_text(json.dumps(lock, indent=1) + '\n')
    names = sorted(e['name'] for e in lock['packages'])
    (out / 'names').write_text('\n'.join(names) + '\n')
    print(f'exported {kept} packages, {len(lock["keys"])} keys, {len(world)} world entries')


if __name__ == '__main__':
    main()
