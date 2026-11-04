#!/bin/sh
# mgu-deploy "check": the binaries start on the unit (static: no loader or glibc needed); offline on purpose.
set -eu
d=$(cd "$(dirname "$0")" && pwd)
"$d/tailscaled" --version | head -1 | grep -q '^1\.104\.4$'
rc=0; "$d/jap-runas" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ]
