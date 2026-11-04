#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 JustAnotherPU
# ExecStartPre, as root: the folders the service (uid $U) needs. /run/jap-tailscale stays root's, so the service
# cannot put a link in it for this root pass to follow; only its own subfolders and resolv.conf's contents are its.
set -eu
U=3920
D=/var/opt/jap-tailscale
R=/run/jap-tailscale
mkdir -p "$D/state" "$R"
chown root:root "$R"; chmod 0755 "$R"
for d in "$R/sock" "$R/pub"; do
    [ -L "$d" ] && rm -f "$d"
    mkdir -p "$d"
done
[ -L "$D/state" ] && { echo "setup.sh: $D/state is a link" >&2; exit 1; }
chown -h "$U:$U" "$D/state" "$R/sock" "$R/pub"
chmod 0700 "$D/state" "$R/sock"
# pub: the login link and state for the Moonride app, world-readable on purpose. While a login is pending the link
# is a claim credential (whoever opens it first adds the car to their tailnet) that every app can read: the README
# says to complete the login promptly; it is emptied once logged in
chmod 0755 "$R/pub"
[ -L "$R/resolv.conf" ] && rm -f "$R/resolv.conf"
[ -f "$R/resolv.conf" ] || { rm -rf "$R/resolv.conf"; : > "$R/resolv.conf"; }
chown -h "$U:$U" "$R/resolv.conf"; chmod 0644 "$R/resolv.conf"
