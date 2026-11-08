#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# ExecStartPre, as root: the owner's configuration folder (root:3921 0750, so the service reads it and cannot change
# it) and the service's runtime folder (systemd's RuntimeDirectory, handed to uid 3921: the generated config with
# the key lives there and goes when the service stops).
set -eu
U=3921
C=/var/opt/jap-wireproxy/conf
R=/run/jap-wireproxy
for d in "$C" "$R"; do [ -L "$d" ] && { echo "setup.sh: $d is a link" >&2; exit 1; }; done
mkdir -p "$C" "$R"
chown root:$U "$C"; chmod 0750 "$C"
chown $U:$U "$R"; chmod 0700 "$R"
# the owner's files, readable by the service (root and uid 3921 only: the folder is 0750)
for f in "$C/wireproxy.conf" "$C/settings"; do
    [ -f "$f" ] && [ ! -L "$f" ] && chown root:$U "$f" && chmod 0640 "$f"
done
exit 0
