#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# Puts the Store release in dist/release/: the app package WITHOUT BMW's oap-sdk (the head unit generates that
# module from a stock app), the tool artifacts, the app icon and catalog.json. Upload every file of that
# folder to the GitHub release named "catalog" (README.md, "Releasing"). Build first:
#   python3 kit/tools/build.py jap_sysmon && sh tools/jap-node22/build.sh && sh tools/jap-wireproxy/build.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/dist/release
base=${RELEASE_URL:-https://github.com/JustAnotherPU/mgu-apps/releases/download/catalog}
one() { set -- $1; [ $# -eq 1 ] && [ -f "$1" ] || { echo "release.sh: expected one $1" >&2; exit 1; }; echo "$1"; }
app=$(one "$root/dist/jap_sysmon@*.tgz")
rm -rf "$out" && mkdir -p "$out"
# the package again without node_modules/oap-sdk, reproducible: sorted, owner 0:0, every mtime SOURCE_DATE_EPOCH
# (default: the last commit's time), gzip without a name or time
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct 2>/dev/null || echo 0)}
python3 - "$app" "$out/$(basename "$app")" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip, io, sys, tarfile
src, dst, mtime = sys.argv[1], sys.argv[2], int(sys.argv[3])
with tarfile.open(src, 'r:gz') as t:
    members = [(m, t.extractfile(m).read() if m.isfile() else None) for m in t.getmembers()
               if 'node_modules/oap-sdk' not in m.name and m.name.rstrip('/') != 'package/node_modules']
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode='w', format=tarfile.USTAR_FORMAT) as out:
    for m, d in sorted(members, key=lambda x: x[0].name):
        m.uid = m.gid = 0; m.uname = m.gname = 'root'; m.mtime = mtime
        out.addfile(m, io.BytesIO(d) if d is not None else None)
with open(dst, 'wb') as f, gzip.GzipFile(fileobj=f, mode='wb', mtime=mtime, filename='') as g:
    g.write(buf.getvalue())
PY
if tar -tzf "$out/$(basename "$app")" | grep -qi 'oap-sdk'; then echo "release.sh: the oap-sdk is still in the package" >&2; exit 1; fi
# the local build's packages hold BMW's oap-sdk: only dist/release/ is ever uploaded, so they go
rm -f "$app" "${app%.tgz}.mgu"
for t in jap-node22 jap-wireproxy; do cp "$(one "$root/dist/$t@*.tgz")" "$out/"; done
cp "$root/apps/jap_sysmon/icon.png" "$out/jap_sysmon.png"
node "$root/release/catalog.js" "$out" "$base"
ls -la "$out"
