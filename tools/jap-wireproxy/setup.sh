#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# ExecStartPre, as root: the owner's configuration folder (root:3921 0750, so the service reads it and cannot change
# it) and the service's runtime folder: s/ in systemd's RuntimeDirectory, owned by uid 3921 (the generated config
# with the key lives there and goes when the service stops). Not the RuntimeDirectory itself: systemd hands it back
# to the unit's user (root) each time it starts a command, so after this ExecStartPre (seen on the car's systemd 237).
set -eu
U=3921
C=/var/opt/jap-wireproxy/conf
R=/run/jap-wireproxy/s
for d in "$C" "$R"; do [ -L "$d" ] && { echo "setup.sh: $d is a link" >&2; exit 1; }; done
mkdir -p "$C" "$R"   # the RuntimeDirectory is 0755 (unit), s/ is 0700
chown root:$U "$C"; chmod 0750 "$C"
chown $U:$U "$R"; chmod 0700 "$R"
# the owner's files, readable by the service (root and uid 3921 only: the folder is 0750)
for f in "$C/wireproxy.conf" "$C/settings"; do
    [ -f "$f" ] && [ ! -L "$f" ] && chown root:$U "$f" && chmod 0640 "$f"
done
exit 0
