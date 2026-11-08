#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# The service, as uid 3921 (jap-runas): wireproxy, WireGuard in userspace (the head unit's kernel has no TUN) to the
# owner's own WireGuard server, with its SOCKS5/HTTP proxies on 127.0.0.1 only. It picks the endpoint, MTU and TCP
# send buffer from the car's uplink (mgu-uplink's status.json) and restarts wireproxy when they change:
# - on the home Wi-Fi (HOME_SSID): HOME_ENDPOINT, the server's LAN address (a router that hairpins the WAN address
#   can switch the source of its replies mid-flow, and the head unit's firewall drops them), HOME_MTU, HOME_SNDBUF;
# - elsewhere: ENDPOINT (a name is resolved by DNS over HTTPS: the head unit's own resolver answers nothing), checked
#   again every RECHECK seconds for a dynamic address, AWAY_MTU, AWAY_SNDBUF.
# WG_TCP_SNDBUF (wireproxy v1.1.3-mgu2) caps what one TCP connection queues toward the server: on a slow mobile
# uplink an upload no longer buries the other flows' ACKs and the handshakes (10-11 s freezes without it).
# Without a valid configuration in $D it starts nothing and says why, once, then waits for one.
set -u
D=${JAP_WP_CONF_DIR:-/var/opt/jap-wireproxy/conf}     # the overrides are for the tests (test/run.sh)
R=${JAP_WP_RUN:-/run/jap-wireproxy/s}   # setup.sh makes it ours; the RuntimeDirectory above it stays root's
BIN=${JAP_WP_BIN:-/var/opt/jap-wireproxy/current/wireproxy}
NODE=${JAP_WP_NODE:-/usr/bin/node}                    # BMW's Node 8: parses status.json, DoH
ST=${JAP_WP_STATUS:-/run/mgu-uplink/status.json}
RESOLVE=${JAP_WP_RESOLVE:-$NODE /var/opt/jap-wireproxy/current/resolve.js}
TICK=${JAP_WP_TICK:-5}
CONF=$R/wireproxy.conf
export GOGC=${GOGC:-30} GOMEMLIMIT=${GOMEMLIMIT:-48MiB}   # 26-29 MB under load instead of up to 166 MB (measured)
umask 077
child= cur= why= last_mt=x last_chk=0 sig=x said=

say() { [ "$1" = "$said" ] || { echo "$1"; printf '%s\n' "$1" > "$R/state"; said=$1; }; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
stopchild() { [ -n "$child" ] && kill "$child" 2>/dev/null && wait "$child" 2>/dev/null; child= cur=; }
trap 'stopchild; exit 0' TERM INT

# settings ($D/settings, KEY=VALUE lines) and checks of wireproxy.conf; sets why to the refusal, empty when fine
load() {
    why= ENDPOINT= HOME_SSID= HOME_ENDPOINT= HOME_MTU=1420 AWAY_MTU=1280 HOME_SNDBUF=524288 AWAY_SNDBUF=65536 RECHECK=120
    [ -f "$D/wireproxy.conf" ] || { why="idle: no configuration, write $D/wireproxy.conf (see the README)"; return; }
    [ -r "$D/wireproxy.conf" ] || { why="idle: cannot read $D/wireproxy.conf: chgrp 3921 and chmod 640 it"; return; }
    if [ -f "$D/settings" ]; then
        [ -r "$D/settings" ] || { why="idle: cannot read $D/settings: chgrp 3921 and chmod 640 it"; return; }
        while IFS= read -r l || [ -n "$l" ]; do
            case $l in '' | '#'*) continue ;; esac
            k=${l%%=*} v=${l#*=}
            case $k in
                ENDPOINT | HOME_ENDPOINT) printf '%s\n' "$v" | grep -Eqx '[A-Za-z0-9.-]+:[0-9]{1,5}' ;;
                HOME_SSID) [ -n "$v" ] ;;
                HOME_MTU | AWAY_MTU) num "$v" && [ "$v" -ge 576 ] && [ "$v" -le 1500 ] ;;
                HOME_SNDBUF | AWAY_SNDBUF) num "$v" && [ "$v" -le 16777216 ] ;;   # 0: gVisor's default (1 MiB)
                RECHECK) num "$v" && [ "$v" -ge 30 ] ;;
                *) why="idle: refused: unknown setting '$k' in $D/settings"; return ;;
            esac || { why="idle: refused: bad value for $k in $D/settings"; return; }
            eval "$k=\$v"   # $k is one of the names above
        done < "$D/settings"
    fi
    [ -z "$HOME_ENDPOINT" ] || [ -n "$HOME_SSID" ] || { why="idle: refused: HOME_ENDPOINT needs HOME_SSID"; return; }
    has=$(grep -c '@ENDPOINT@' "$D/wireproxy.conf")
    [ -n "$ENDPOINT" ] && [ "$has" -eq 0 ] && { why="idle: refused: ENDPOINT is set but wireproxy.conf has no 'Endpoint = @ENDPOINT@'"; return; }
    [ -z "$ENDPOINT" ] && [ "$has" -gt 0 ] && { why="idle: refused: wireproxy.conf has @ENDPOINT@ but settings has no ENDPOINT"; return; }
    # awk and wireproxy's ini parser may read other bytes differently (UTF-8, CR, NUL): only printable ASCII and tabs
    LC_ALL=C grep -q "$(printf '[^ -~\t]')" "$D/wireproxy.conf" &&
        { why="idle: refused: wireproxy.conf has a byte that is not printable ASCII or a tab (Windows line ends too)"; return; }
    # the proxies must listen on the loopback only, and nothing may listen for the tunnel's peers
    why=$(awk '
        function no(why) { print "idle: refused: " why " (line " NR " of wireproxy.conf)"; exit }
        /^[ \t]*[#;]/ || /^[ \t]*$/ { next }
        /^[ \t]*\[/ { s = tolower($0); gsub(/[][ \t]/, "", s); if (s == "tcpservertunnel") no("[TCPServerTunnel] accepts connections from the tunnel"); next }
        {
            k = $0; sub(/[=:].*/, "", k); gsub(/[ \t]/, "", k); k = tolower(k)
            v = $0; sub(/^[^=:]*[=:][ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            if (k == "wgconfig") no("WGConfig: keep everything in wireproxy.conf")
            if (k == "bindaddress" && v !~ /^(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]|localhost):[0-9]+$/)
                no("BindAddress " v " is not on 127.0.0.1 or [::1]")
        }' "$D/wireproxy.conf")
}
num() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }

# "home" | "away" | nothing while offline
uplink() {
    "$NODE" -e 'try { const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); if (s.state === "online")
        process.stdout.write(process.argv[2] && s.device && s.device.kind === "wifi" && s.device.name === process.argv[2] ? "home" : "away"); } catch (e) {}' "$ST" "$HOME_SSID"
}
resolve() { case $1 in *[!0-9.]*) $RESOLVE "$1" ;; *) echo "$1" ;; esac; }

# "<ip:port or -> <mtu> <sndbuf> <1 when resolved from a name, else 0>", or nothing while offline or unresolved
want() {
    case $(uplink) in
        home) ep=${HOME_ENDPOINT:-$ENDPOINT} mtu=$HOME_MTU sb=$HOME_SNDBUF ;;
        away) ep=$ENDPOINT mtu=$AWAY_MTU sb=$AWAY_SNDBUF ;;
        *) return ;;
    esac
    dyn=0
    if [ -n "$ep" ]; then
        case ${ep%:*} in *[!0-9.]*) dyn=1 ;; esac
        ip=$(resolve "${ep%:*}") && printf '%s\n' "$ip" | grep -Eqx '[0-9]{1,3}(\.[0-9]{1,3}){3}' || return
        ep=$ip:${ep##*:}
    else
        ep=-
    fi
    echo "$ep $mtu $sb $dyn"
}

run() {     # (re)start wireproxy on want's line
    stopchild
    set -- $1
    awk -v ep="$1" -v mtu="$2" '
        /^[ \t]*\[/ { print; s = tolower($0); gsub(/[][ \t]/, "", s); if (s == "interface") print "MTU = " mtu; next }
        s == "interface" { k = $0; sub(/[=:].*/, "", k); gsub(/[ \t]/, "", k); if (tolower(k) == "mtu") next }
        { if (ep != "-") gsub(/@ENDPOINT@/, ep); print }' "$D/wireproxy.conf" > "$CONF"
    # a port someone else holds would make wireproxy exit, and systemd restart it every 30 s: wait for it instead
    while read -r a; do
        [ -n "$a" ] || continue
        h=${a%:*} h=${h#[} h=${h%]}
        "$NODE" -e 'const s = require("net").createServer(); s.on("error", (e) => process.exit(e.code === "EADDRINUSE" ? 1 : 0));
            s.listen(+process.argv[1], process.argv[2], () => s.close());' "${a##*:}" "$h" ||
            { say "idle: port ${a##*:} is in use ($a in wireproxy.conf); waiting for it"; return 2; }
    done <<EOF
$(awk 'tolower($0) ~ /^[ \t]*bindaddress[ \t]*[=:]/ { sub(/^[^=:]*[=:][ \t]*/, ""); sub(/[ \t]+$/, ""); print }' "$CONF")
EOF
    if ! out=$("$BIN" -c "$CONF" -n 2>&1); then
        say "idle: refused by wireproxy's configtest: $(printf '%s' "$out" | tail -1)"; return 1
    fi
    say "running: endpoint $1 mtu $2 tcp-sndbuf $3"
    WG_TCP_SNDBUF=$3 "$BIN" -c "$CONF" &
    child=$! cur="$*"
}

# same endpoint after a wake or reconnect: wireguard-go waits for its next keepalive before it handshakes again
# (17 s measured); one SOCKS connect to the tunnel's DNS server makes it handshake now
poke() {
    p=$(awk '/^[ \t]*\[/ { s = tolower($0); gsub(/[][ \t]/, "", s) } s == "socks5" && tolower($0) ~ /^[ \t]*bindaddress/ { sub(/.*:/, ""); print; exit }' "$CONF")
    dns=$(awk '/^[ \t]*\[/ { s = tolower($0); gsub(/[][ \t]/, "", s) } s == "interface" && tolower($0) ~ /^[ \t]*dns[ \t]*[=:]/ { sub(/^[^=:]*[=:][ \t]*/, ""); sub(/[ ,].*/, ""); print; exit }' "$CONF")
    printf '%s\n' "$dns" | grep -Eqx '[0-9]{1,3}(\.[0-9]{1,3}){3}' && num "$p" || return 0
    "$NODE" -e 'const a = process.argv[2].split(".").map(Number), s = require("net").connect(+process.argv[1], "127.0.0.1", () => s.write(Buffer.from([5, 1, 0])));
        s.once("data", () => s.write(Buffer.from([5, 1, 0, 1].concat(a, [0, 53])))); s.on("error", () => {}); setTimeout(() => process.exit(0), 3000);' "$p" "$dns" &
}

while :; do
    now=$(date +%s)
    s="$(mtime "$D/wireproxy.conf")/$(mtime "$D/settings")"
    if [ "$s" != "$sig" ]; then          # the configuration changed (or first pass)
        sig=$s
        load
        stopchild; last_mt=x
        [ -n "$why" ] && say "$why"
    fi
    if [ -z "$why" ]; then
        mt=$(mtime "$ST")   # shortcut: whole seconds, two uplink changes within one second look like one (the car's script did the same); compare contents if that bites
        if [ -z "$mt" ]; then
            say "idle: waiting for mgu-uplink ($ST)"
        elif [ "$mt" != "$last_mt" ] || { [ -z "$cur" ] && [ $((now - last_chk)) -ge 30 ]; } ||
             { [ "${cur##* }" = 1 ] && [ $((now - last_chk)) -ge "$RECHECK" ]; }; then
            last_mt=$mt last_chk=$now
            w=$(want)
            if [ -z "$w" ]; then
                [ -n "$cur" ] || say "idle: offline, or the endpoint does not resolve"
            elif [ "$w" != "$cur" ]; then
                run "$w"; [ $? -eq 1 ] && why=configtest   # 2: port in use, try again in 30 s
            else
                poke
            fi
        fi
        [ -n "$child" ] && ! kill -0 "$child" 2>/dev/null && { echo "wireproxy exited"; exit 1; }   # systemd restarts
    fi
    sleep "$TICK" & wait $!
done
