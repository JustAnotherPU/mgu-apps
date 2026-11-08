#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# sh tools/jap-wireproxy/test/e2e.sh <unpacked files/ of the artifact>: the packaged wireproxy through start.sh, end
# to end on one machine. A second wireproxy is the "home" WireGuard server (a [TCPServerTunnel] to a small HTTP
# server); start.sh starts the packaged one as the client from an owner's conf; a request through its SOCKS5 proxy
# must cross the tunnel, and the client must run with the away MTU and WG_TCP_SNDBUF. Fresh keys each run.
# Linux amd64 with node, e.g.: docker run --rm --platform linux/amd64 -v <files>:/x:ro -v $PWD:/t:ro node:22-alpine \
#   sh /t/tools/jap-wireproxy/test/e2e.sh /x
set -eu
X=$(cd "$1" && pwd)
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
key() { node -e 'const c = require("crypto"), k = c.generateKeyPairSync("x25519");
    const raw = (o) => Buffer.from(o.export({ format: "jwk" }).x || o.export({ format: "jwk" }).d, "base64url").toString("base64");
    console.log(Buffer.from(k.privateKey.export({ format: "jwk" }).d, "base64url").toString("base64"), raw(k.publicKey));'; }
set -- $(key); SPRIV=$1 SPUB=$2
set -- $(key); CPRIV=$1 CPUB=$2

node -e 'require("http").createServer((q, r) => r.end("hello through wireguard\n")).listen(18080, "127.0.0.1")' &
cat > "$T/server.conf" <<EOF
[Interface]
Address = 10.9.0.1/32
PrivateKey = $SPRIV
ListenPort = 51999

[Peer]
PublicKey = $CPUB
AllowedIPs = 10.9.0.2/32

[TCPServerTunnel]
ListenPort = 8080
Target = 127.0.0.1:18080
EOF
"$X/wireproxy" -s -c "$T/server.conf" &

mkdir -p "$T/conf" "$T/run"
cat > "$T/conf/wireproxy.conf" <<EOF
[Interface]
Address = 10.9.0.2/32
PrivateKey = $CPRIV
DNS = 10.9.0.1

[Peer]
PublicKey = $SPUB
Endpoint = @ENDPOINT@
AllowedIPs = 10.9.0.0/24
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:1085
EOF
printf 'ENDPOINT=127.0.0.1:51999\nAWAY_MTU=1280\nAWAY_SNDBUF=65536\n' > "$T/conf/settings"
echo '{"device":{"kind":"iphone","name":"Apple Inc. iPhone"},"state":"online","error":null}' > "$T/status.json"
JAP_WP_CONF_DIR=$T/conf JAP_WP_RUN=$T/run JAP_WP_BIN=$X/wireproxy JAP_WP_STATUS=$T/status.json \
    JAP_WP_NODE=$(command -v node) JAP_WP_TICK=1 sh "$X/start.sh" > "$T/log" 2>&1 &

# one HTTP request through the SOCKS5 proxy to the server's tunnel address (10.9.0.1:8080)
get() { node -e 'const s = require("net").connect(1085, "127.0.0.1"); let st = 0, out = "";
    s.on("connect", () => s.write(Buffer.from([5, 1, 0])));
    s.on("data", (d) => { if (st === 0) { st = 1; s.write(Buffer.from([5, 1, 0, 1, 10, 9, 0, 1, 0x1f, 0x90])); }
        else if (st === 1) { st = d[1] === 0 ? 2 : 9; if (st === 2) s.write("GET / HTTP/1.0\r\n\r\n"); else s.end(); }
        else out += d; });
    s.on("close", () => { process.stdout.write(out); process.exit(out.indexOf("hello through wireguard") >= 0 ? 0 : 1); });
    s.on("error", () => process.exit(1)); setTimeout(() => process.exit(1), 5000);' > "$T/got" 2>/dev/null; }
i=0; until get; do i=$((i + 1)); [ $i -lt 20 ] || { echo "FAIL no answer through the tunnel"; cat "$T/log"; exit 1; }; sleep 1; done
echo "ok   HTTP through SOCKS5 -> WireGuard -> server: $(tail -1 "$T/got")"
grep -q 'running: endpoint 127.0.0.1:51999 mtu 1280 tcp-sndbuf 65536' "$T/log" && grep -qx 'MTU = 1280' "$T/run/wireproxy.conf" &&
    echo "ok   start.sh ran the client with $(grep running: "$T/log")" || { echo "FAIL start.sh log"; cat "$T/log"; exit 1; }
for p in $(pgrep -f "$T/run/wireproxy.conf"); do
    tr '\0' '\n' < /proc/$p/environ | grep -qx 'WG_TCP_SNDBUF=65536' && ok=1
done
[ "${ok:-}" = 1 ] && echo "ok   the client wireproxy has WG_TCP_SNDBUF=65536 in its environment" || { echo "FAIL WG_TCP_SNDBUF"; exit 1; }
# SOCKS5 UDP ASSOCIATE: the relay must be bound to the loopback (go-socks5 v0.1.3), not to every interface
bnd=$(node -e 'const s = require("net").connect(1085, "127.0.0.1"); let st = 0;
    s.on("connect", () => s.write(Buffer.from([5, 1, 0])));
    s.on("data", (d) => { if (st++ === 0) return s.write(Buffer.from([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]));
        console.log(d[1] === 0 && d[3] === 1 ? Array.from(d.slice(4, 8)).join(".") + ":" + d.readUInt16BE(8) : "reply " + d[1]); process.exit(0); });
    s.on("error", (e) => { console.log(e.message); process.exit(1); }); setTimeout(() => process.exit(1), 5000);') || true
case $bnd in 127.0.0.1:[1-9]*) echo "ok   UDP ASSOCIATE relay bound to $bnd" ;; *) echo "FAIL UDP ASSOCIATE: $bnd"; exit 1 ;; esac
echo "4 passed, 0 failed"
