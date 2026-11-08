#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# sh tools/jap-wireproxy/test/run.sh: start.sh's decisions against fakes, with no car and no network. A fake
# wireproxy records the config and WG_TCP_SNDBUF it was started with; the uplink is a status.json the test writes
# (mgu-uplink's format); DNS over HTTPS is a fake resolver. Needs sh, awk, grep and node (any version).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/jap-wp-test.XXXXXX")
trap 'kill $pid $occ 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0 pid= occ=

mkdir -p "$T/bin"
cat > "$T/bin/wireproxy" <<'EOF'
#!/bin/sh
c=; for a; do [ "$p" = -c ] && c=$a; p=$a; done
case " $* " in *" -n "*) [ -f "$FAKE/configtest-fails" ] && { echo "2026/11/08 bad key"; exit 1; }; echo "Config OK"; exit 0 ;; esac
n=$(ls "$FAKE/runs" | wc -l | tr -d ' ')
mkdir -p "$FAKE/runs/$n" && cp "$c" "$FAKE/runs/$n/conf" && printf '%s\n' "${WG_TCP_SNDBUF-unset}" > "$FAKE/runs/$n/sndbuf"
exec sleep 300
EOF
cat > "$T/bin/resolve" <<'EOF'
#!/bin/sh
echo "$1" >> "$FAKE/resolved"
[ -f "$FAKE/dns" ] && cat "$FAKE/dns" || exit 1
EOF
chmod 755 "$T/bin/wireproxy" "$T/bin/resolve"

CONF='[Interface]
Address = 10.0.0.2/32
PrivateKey = TEST-NOT-A-KEY
DNS = 10.0.0.1
MTU = 1420

[Peer]
PublicKey = TEST-NOT-A-KEY
Endpoint = @ENDPOINT@
AllowedIPs = 0.0.0.0/0

[Socks5]
BindAddress = 127.0.0.1:1085
'
SET='ENDPOINT=vpn.example.net:51820
HOME_SSID=Test Home
HOME_ENDPOINT=192.0.2.1:51820
'
WIFI='{"device":{"kind":"wifi","name":"Test Home"},"state":"online","error":null}'
PHONE='{"device":{"kind":"iphone","name":"Apple Inc. iPhone"},"state":"online","error":null}'

# fresh case: $1 conf ("" = none), $2 settings ("" = none), $3 status.json ("" = none)
setup() {
    kill $pid 2>/dev/null; wait $pid 2>/dev/null; pid=
    F=$T/case; rm -rf "$F"; mkdir -p "$F/conf" "$F/run" "$F/runs"
    [ -n "$1" ] && printf '%s' "$1" > "$F/conf/wireproxy.conf"
    [ -n "$2" ] && printf '%s' "$2" > "$F/conf/settings"
    [ -n "$3" ] && printf '%s\n' "$3" > "$F/status.json"
    echo 203.0.113.7 > "$F/dns"
}
start() {
    FAKE=$F JAP_WP_CONF_DIR=$F/conf JAP_WP_RUN=$F/run JAP_WP_BIN=$T/bin/wireproxy JAP_WP_NODE=$(command -v node) \
        JAP_WP_STATUS=$F/status.json JAP_WP_RESOLVE=$T/bin/resolve JAP_WP_TICK=1 \
        sh "$here/start.sh" > "$F/log" 2>&1 &
    pid=$!
}
until_() { i=0; while [ $i -lt "${2:-40}" ]; do eval "$1" && return 0; sleep 0.25; i=$((i + 1)); done; return 1; }   # $2: tries
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ko() { fail=$((fail + 1)); echo "FAIL $1"; sed 's/^/     | /' "$F/log"; }
state() { cat "$F/run/state" 2>/dev/null; }
# the run's config has $2 (a grep -x pattern) and its sndbuf is $3
ran() { [ -f "$F/runs/$1/sndbuf" ] && grep -qx "$2" "$F/runs/$1/conf" && [ "$(cat "$F/runs/$1/sndbuf")" = "$3" ] &&
    [ "$(grep -c '^MTU' "$F/runs/$1/conf")" = 1 ]; }
idle() {    # $1 name, $2 text the state must contain; and nothing started
    if until_ "state | grep -qF -- \"$2\"" && sleep 1 && [ -z "$(ls "$F/runs")" ] && kill -0 $pid 2>/dev/null; then ok "$1"; else ko "$1"; fi
}

setup "" "" "$WIFI"; start
idle "no wireproxy.conf: idle, says so, stays up" "idle: no configuration"
grep -q "idle: no configuration" "$F/log" && [ "$(grep -c idle "$F/log")" = 1 ] && ok "  ...in the journal, once" || ko "  ...in the journal, once"
printf '%s' "$CONF" > "$F/conf/wireproxy.conf"; printf '%s' "$SET" > "$F/conf/settings"
until_ 'ran 0 "Endpoint = 192.0.2.1:51820" 524288' && ok "  ...and starts once the owner writes it" || ko "  ...and starts once the owner writes it"

setup "$CONF" "$SET" "$WIFI"; start
until_ 'ran 0 "Endpoint = 192.0.2.1:51820" 524288' && grep -qx 'MTU = 1420' "$F/runs/0/conf" && [ ! -f "$F/resolved" ] &&
    ok "home Wi-Fi: HOME_ENDPOINT, MTU 1420, sndbuf 512 KiB, no DoH" || ko "home Wi-Fi"
grep -q '^BindAddress = 127.0.0.1:1085$' "$F/runs/0/conf" && grep -q '^PrivateKey = TEST-NOT-A-KEY$' "$F/runs/0/conf" &&
    ok "  ...the rest of the owner's config is kept" || ko "  ...the rest of the owner's config is kept"
sleep 1.1; printf '%s\n' "$PHONE" > "$F/status.json.new"; mv "$F/status.json.new" "$F/status.json"   # a later mtime second
until_ 'ran 1 "Endpoint = 203.0.113.7:51820" 65536' && grep -qx 'MTU = 1280' "$F/runs/1/conf" && [ "$(grep -c '^running:' "$F/log")" = 2 ] &&
    ok "  ...then 5G: restarted on ENDPOINT by DoH, MTU 1280, sndbuf 64 KiB" || ko "  ...then 5G"
grep -qx vpn.example.net "$F/resolved" && ok "  ...DoH asked for ENDPOINT's name" || ko "  ...DoH asked for ENDPOINT's name"

setup "$CONF" "$SET
RECHECK=30
" "$PHONE"; start
until_ 'ran 0 "Endpoint = 203.0.113.7:51820" 65536' && grep -qx 'MTU = 1280' "$F/runs/0/conf" && ok "phone (away): ENDPOINT, MTU 1280, sndbuf 64 KiB" || ko "phone (away)"
echo 203.0.113.9 > "$F/dns"
until_ 'ran 1 "Endpoint = 203.0.113.9:51820" 65536' 160 && ok "  ...the name's new address is picked up after RECHECK (30 s)" || ko "  ...RECHECK"

setup "$CONF" "$SET" '{"device":{"kind":"wifi","name":"Someone Else"},"state":"online","error":null}'; start
until_ 'ran 0 "Endpoint = 203.0.113.7:51820" 65536' && ok "another Wi-Fi: away" || ko "another Wi-Fi: away"

setup "$CONF" 'ENDPOINT=vpn.example.net:51820
AWAY_MTU=1200
AWAY_SNDBUF=0
' "$WIFI"; start
until_ 'ran 0 "Endpoint = 203.0.113.7:51820" 0' && grep -qx 'MTU = 1200' "$F/runs/0/conf" && ok "no HOME_SSID: always away; AWAY_MTU and AWAY_SNDBUF=0 used" || ko "no HOME_SSID"

setup "$CONF" 'ENDPOINT=198.51.100.4:443' "$PHONE"; start
until_ 'ran 0 "Endpoint = 198.51.100.4:443" 65536' && [ ! -f "$F/resolved" ] && ok "an address as ENDPOINT: no DoH" || ko "an address as ENDPOINT"

setup "$(printf '%s' "$CONF" | sed -e 's/@ENDPOINT@/198.51.100.4:51820/' -e '/^MTU/d')" "" "$PHONE"; start
until_ 'ran 0 "Endpoint = 198.51.100.4:51820" 65536' && grep -qx 'MTU = 1280' "$F/runs/0/conf" && ok "no settings: the conf's own Endpoint, MTU added" || ko "no settings"

setup "$CONF" "$SET" '{"device":{"kind":"iphone","name":"x"},"state":"trust-needed","error":"Tap Trust"}'; start
idle "uplink not online: idle" "idle: offline"
setup "$CONF" "$SET" ""; start
idle "no mgu-uplink: idle" "idle: waiting for mgu-uplink"
setup "$CONF" "$SET" "$PHONE"; rm "$F/dns"; start
idle "DoH fails: idle" "or the endpoint does not resolve"

for b in '0.0.0.0:1080' '[::]:1080' '192.0.2.5:1080' ':1080' '"127.0.0.1:1080"'; do
    setup "$(printf '%s' "$CONF" | sed "s/127.0.0.1:1085/$b/")" "$SET" "$PHONE"; start
    idle "SOCKS on $b: refused" "is not on 127.0.0.1"
done
setup "$(printf '%s' "$CONF" | sed 's/^BindAddress = 127.0.0.1:1085/bindaddress: 0.0.0.0:1085/')" "$SET" "$PHONE"; start
idle "  ...also as 'bindaddress: 0.0.0.0:1085'" "is not on 127.0.0.1"
setup "$CONF[http]
BindAddress = 0.0.0.0:8080
" "$SET" "$PHONE"; start
idle "HTTP proxy on 0.0.0.0: refused" "is not on 127.0.0.1"
setup "$(printf '%s' "$CONF" | sed 's/127.0.0.1:1085/[::1]:1085/')" "$SET" "$PHONE"; start
until_ 'ran 0 "BindAddress = \[::1\]:1085" 65536' && ok "SOCKS on [::1]: accepted" || ko "SOCKS on [::1]"
setup "$CONF[TCPServerTunnel]
ListenPort = 2222
Target = 127.0.0.1:22
" "$SET" "$PHONE"; start
idle "[TCPServerTunnel]: refused" "accepts connections from the tunnel"
setup "WGConfig = other.conf
$CONF" "$SET" "$PHONE"; start
idle "WGConfig include: refused" "WGConfig"

setup "$CONF" "$SET
FOO=1
" "$PHONE"; start
idle "unknown setting: refused" "unknown setting 'FOO'"
setup "$CONF" "$SET
AWAY_MTU=99999
" "$PHONE"; start
idle "MTU out of range: refused" "bad value for AWAY_MTU"
setup "$CONF" 'ENDPOINT=vpn.example.net:51820;reboot' "$PHONE"; start
idle "ENDPOINT not host:port: refused" "bad value for ENDPOINT"
setup "$(printf '%s' "$CONF" | sed 's/@ENDPOINT@/198.51.100.4:1/')" "$SET" "$PHONE"; start
idle "ENDPOINT without @ENDPOINT@ in the conf: refused" "has no 'Endpoint = @ENDPOINT@'"
setup "$CONF" "" "$PHONE"; start
idle "@ENDPOINT@ without ENDPOINT: refused" "settings has no ENDPOINT"
setup "$CONF" 'ENDPOINT=vpn.example.net:51820
HOME_ENDPOINT=192.0.2.1:51820
' "$WIFI"; start
idle "HOME_ENDPOINT without HOME_SSID: refused" "HOME_ENDPOINT needs HOME_SSID"
setup "$CONF" "$SET" "$PHONE"; : > "$F/configtest-fails"; start
idle "wireproxy's configtest fails: idle, no restart loop" "refused by wireproxy's configtest"
setup "$CONF# caf$(printf '\303\251')
" "$SET" "$PHONE"; start
idle "non-ASCII byte in wireproxy.conf (UTF-8 in a comment): refused" "not printable ASCII"
setup "$(printf '%s' "$CONF" | awk '{ printf "%s\r\n", $0 }')" "$SET" "$PHONE"; start
idle "  ...also Windows line ends (CR)" "not printable ASCII"

# a port another program listens on: idle and say so (wireproxy would exit, systemd restart it every 30 s)
node -e 'const s = require("net").createServer().listen(0, "127.0.0.1", () => require("fs").writeFileSync(process.argv[1], String(s.address().port)));
    setTimeout(() => {}, 300000);' "$T/port" &
occ=$!
until_ '[ -s "$T/port" ]'; port=$(cat "$T/port")
setup "$(printf '%s' "$CONF" | sed "s/127.0.0.1:1085/127.0.0.1:$port/")" "$SET" "$PHONE"; start
idle "SOCKS port in use: idle, says so, no exit" "idle: port $port is in use"
kill $occ; wait $occ 2>/dev/null; occ=
until_ "ran 0 'BindAddress = 127.0.0.1:$port' 65536" 160 && ok "  ...and starts once the port is free (within 30 s)" || ko "  ...and starts once the port is free"

kill $pid 2>/dev/null; wait $pid 2>/dev/null
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
