#!/bin/sh
# mgu-deploy "check": the binaries start on the unit (static: no loader or glibc needed); offline on purpose.
set -eu
d=$(cd "$(dirname "$0")" && pwd)
"$d/wireproxy" -v | grep -q 'version v1\.1\.3-mgu1$'
rc=0; "$d/jap-runas" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ]
