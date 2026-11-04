#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 JustAnotherPU
# The service, as uid 3920 (jap-runas): tailscaled in userspace networking (the head unit's kernel has no TUN), its
# traffic routed by the internet uplink, and a SOCKS5 server on 127.0.0.1:1065 only (Moonride's relay). Incoming
# tailnet connections are refused (--shields-up). While not logged in it asks for a login and writes the link to
# /run/jap-tailscale/pub/login-url, which the Moonride app shows as a QR code.
D=${JAP_TS_DIR:-/var/opt/jap-tailscale}   # overridable for a test outside the car
R=${JAP_TS_RUN:-/run/jap-tailscale}
BIN=$D/current/tailscaled
SOCK=$R/sock/tailscaled.sock
LEASE=${JAP_TS_LEASE:-/run/mgu-uplink/lease.json}
PUB=$R/pub
cli() { TS_BE_CLI=1 "$BIN" --socket="$SOCK" "$@"; }   # the binary is tailscaled and the tailscale CLI (ts_include_cli; TS_BE_CLI=1 picks the CLI)

# the unit's resolver has no internet: point resolv.conf (bound over /etc/resolv.conf by the unit) at the lease's DNS
dns() {
    [ -r "$LEASE" ] || return 0
    want=$(tr -d '\n ' < "$LEASE" | sed -n 's/.*"dns":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d '"' |
        grep -E '^[0-9A-Fa-f.:]+$' | sed 's/^/nameserver /')
    [ -n "$want" ] && [ "$want" != "$(cat "$R/resolv.conf" 2>/dev/null)" ] && printf '%s\n' "$want" > "$R/resolv.conf"
    return 0
}
pub() { printf '%s\n' "$2" > "$PUB/.$1" && mv -f "$PUB/.$1" "$PUB/$1"; }

dns
"$BIN" --tun=userspace-networking --statedir="$D/state" --socket="$SOCK" --port=0 \
    --socks5-server=127.0.0.1:1065 --no-logs-no-support &
pid=$!
up=
trap 'kill "$pid" $up 2>/dev/null; wait "$pid"; exit 0' TERM INT
while kill -0 "$pid" 2>/dev/null; do
    [ -S "$SOCK" ] && chmod 0600 "$SOCK"
    dns
    js=$(cli status --json --peers=false 2>/dev/null | tr -d '\n')
    state=$(printf '%s' "$js" | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p')
    url=$(printf '%s' "$js" | sed -n 's/.*"AuthURL": *"\(https:[^"]*\)".*/\1/p')
    pub state "${state:-Starting}"
    if [ "$state" = NeedsLogin ]; then
        # one login attempt at a time; it waits until the owner opens the link
        if [ -z "$up" ] || ! kill -0 "$up" 2>/dev/null; then
            cli up --timeout=0 --hostname=idrive --accept-routes --accept-dns=false --shields-up >/dev/null 2>&1 &
            up=$!
        fi
        pub login-url "$url"
    else
        [ -s "$PUB/login-url" ] && : > "$PUB/login-url"
    fi
    sleep 5 & wait $!
done
wait "$pid"
