# jap-wireproxy

A WireGuard client for the iDrive 7 head unit, to **your own WireGuard server** (a home router, a VPS): no account,
no coordination server, no relay. It runs [wireproxy](https://github.com/whyvl/wireproxy) in userspace (the head
unit's kernel has no TUN device and loads only signed modules) and gives programs on the head unit a SOCKS5 proxy
on `127.0.0.1` into your network.

The binary is wireproxy v1.1.3 with one change in its WireGuard library: a cap on the TCP send buffer of the
userspace network stack (`WG_TCP_SNDBUF`, below). It also picks the endpoint, MTU and that cap from the car's
uplink: your home Wi-Fi, or a phone or LTE stick elsewhere.

## Why the patch

wireguard-go's userspace stack (gVisor) lets one TCP connection queue 1 MiB toward the server. On a mobile uplink
of 1 Mbit/s that is 8 s of queue: an upload filled the phone's uplink buffer, and the ACKs of a video stream and
WireGuard's own handshakes waited behind it. Camera streams froze for 10 to 11 s. With the queue capped at 64 KiB
away from home, the freezes are gone (see Tests). On the home Wi-Fi the cap is 512 KiB, where there is no such
queue and a bigger buffer keeps the upload fast.

## Configure

Nothing runs until you write a configuration. Until then `systemctl status jap-wireproxy` (and its journal) says
`idle: no configuration`. As root on the head unit (SSH on the car's own network):

1. Make a peer for the car on your WireGuard server, with its own key pair. Do not reuse a key that another
   device (or another wireproxy on this car) uses: two clients with one key take the session from each other.
2. Write `/var/opt/jap-wireproxy/conf/wireproxy.conf`, a normal
   [wireproxy configuration](https://github.com/whyvl/wireproxy#configuration), with `Endpoint = @ENDPOINT@`:

   ```ini
   [Interface]
   Address = 10.0.0.2/32
   PrivateKey = <the car's private key>
   DNS = 10.0.0.1

   [Peer]
   PublicKey = <the server's public key>
   Endpoint = @ENDPOINT@
   AllowedIPs = 10.0.0.0/24, 192.168.1.0/24
   PersistentKeepalive = 25

   [Socks5]
   BindAddress = 127.0.0.1:1085
   ```

   Pick a free port: `jap-tailscale` uses 1065.
3. Write `/var/opt/jap-wireproxy/conf/settings`, one `KEY=VALUE` per line:

   ```
   ENDPOINT=vpn.example.net:51820
   HOME_SSID=My Home Wi-Fi
   HOME_ENDPOINT=192.168.1.1:51820
   ```

4. `chgrp 3921 /var/opt/jap-wireproxy/conf/* && chmod 640 /var/opt/jap-wireproxy/conf/*` (the service also does
   this when it starts). The folder is `root:3921 0750`: only root and the service read your key.

The service sees the files within a few seconds and starts wireproxy. `systemctl status jap-wireproxy` then shows
`running: endpoint <address:port> mtu <mtu> tcp-sndbuf <bytes>`, also in `/run/jap-wireproxy/state`.

| Setting | Default | |
|---|---|---|
| `ENDPOINT` | none | `host:port` of your server, used away from home. A name is resolved by DNS over HTTPS (1.1.1.1), because the head unit's resolver answers nothing; checked again every `RECHECK` s for a dynamic address |
| `HOME_SSID` | none | your home Wi-Fi's name. Unset: always "away" |
| `HOME_ENDPOINT` | `ENDPOINT` | `host:port` used on `HOME_SSID`, e.g. the server's LAN address: a router can send replies to its WAN address from another source address, and the head unit's firewall drops them |
| `HOME_MTU` / `AWAY_MTU` | 1420 / 1280 | 576 to 1500; 1280 fits mobile networks |
| `HOME_SNDBUF` / `AWAY_SNDBUF` | 524288 / 65536 | TCP send buffer cap in bytes; 0 = gVisor's 1 MiB |
| `RECHECK` | 120 | seconds, 30 or more |

Without a `settings` file the conf is used as written (a fixed `Endpoint` address), with `AWAY_MTU`. There are no
defaults for your network: no SSID and no address.

What the service refuses, and says so in its status (it then waits for a corrected file, without a restart loop):

- any `BindAddress` that is not `127.x.x.x` or `[::1]`: the proxies have **no authentication**, and only the head
  unit itself may use them;
- `[TCPServerTunnel]`: it would let your network open connections to the head unit's own services;
- `WGConfig` (an included file), unknown settings, values out of range, `@ENDPOINT@` without `ENDPOINT` or the
  reverse, and anything wireproxy's own `-n` configuration test rejects.

What to know:

- Every program on the head unit can use the SOCKS5 proxy. Limit what the car's peer can reach on the server side
  (its `AllowedIPs` and your firewall), not only here.
- The UDP relay of SOCKS5 `UDP ASSOCIATE` binds the client's local address (go-socks5 v0.1.3); older wireproxy
  builds bound it to every interface.
- It reads the uplink from mgu-uplink's `/run/mgu-uplink/status.json` and parses it with BMW's own Node 8
  (`/usr/bin/node`). Without mgu-uplink it waits (`idle: waiting for mgu-uplink`).
- After a wake-up it makes one SOCKS connection to the `DNS` address of `[Interface]`, so WireGuard handshakes at
  once instead of at its next keepalive (17 s measured).

## Head-unit rules

- The service is in recmgr's restart list (`"recmgr": ["jap-wireproxy"]`). Stopping a service the list does not
  name resets the head unit, and recmgr reads its list only at boot. mgu-deploy therefore starts the service at the
  next boot after the first install, and never stops or restarts it before recmgr has loaded its entry.
- Do not stop or restart a unit by hand that was not in the list at this boot. `jap-wireproxy.service` is, from
  the boot after the install.
- A wireproxy installed by hand (another unit, e.g. `wireproxy.service` in `/var/opt/wireproxy/`) is left alone.
  Do not run both with the same key (see Configure). Disable the old unit only if it was in recmgr's list at this
  boot.
- Limits from the unit: `MemoryLimit=96M`, `CPUQuota=20%`; `GOGC=30 GOMEMLIMIT=48MiB` keeps wireproxy at 26 to
  29 MB under load (the 5G runs below), against up to 166 MB without (the 05/11 Wi-Fi runs).

## On the unit

| Path | |
|---|---|
| `/var/opt/jap-wireproxy/current/wireproxy` | the static binary (`wireproxy -v`: `v1.1.3-mgu1`) |
| `/var/opt/jap-wireproxy/current/start.sh` | the supervisor (uid 3921): picks endpoint, MTU, send buffer; restarts wireproxy when they change |
| `/var/opt/jap-wireproxy/current/setup.sh` | `ExecStartPre` as root: the folders and their owners |
| `/var/opt/jap-wireproxy/current/resolve.js` | DNS over HTTPS on 1.1.1.1 (Node 8) |
| `/var/opt/jap-wireproxy/current/jap-runas` | drops root to uid 3921 (from `tools/jap-tailscale/runas`) |
| `/var/opt/jap-wireproxy/conf/` | your `wireproxy.conf` and `settings`, kept by updates |
| `/run/jap-wireproxy/` | the generated config and `state`; gone when the service stops |

The unit is `jap-wireproxy.service`: `uid` 3921 gets internet from mgu-uplink (`"internet": true`). It is less
hardened than a unit with `User=`: it starts as root for `setup.sh` and `jap-runas`, so it keeps the capabilities
those need.

## Tests

This package has not yet been installed on a car through the Store. The bench below is the hand-installed
wireproxy v1.1.3-mgu1, built from the same sources one commit earlier (before go-socks5 v0.1.3), with the same
supervisor logic.

Run on a computer, no car:

```sh
sh tools/jap-wireproxy/test/run.sh            # start.sh against fakes: 33 cases
docker run --rm -v "$PWD:/t:ro" -w /t node:8-alpine sh tools/jap-wireproxy/test/run.sh   # the same, BMW's Node 8, busybox
# the packaged binary end to end (after build.sh): a second wireproxy is the server
mkdir -p /tmp/x && tar -xzf dist/jap-wireproxy@1.1.3.tgz -C /tmp/x
docker run --rm -v /tmp/x/files:/x:ro -v "$PWD:/t:ro" node:22-alpine sh /t/tools/jap-wireproxy/test/e2e.sh /x
# (an amd64 host; on an arm64 Mac the amd64 binary runs under the VM's emulation, as for the results below)
```

Results on 2026-11-08:

| Suite | Result |
|---|---|
| `test/run.sh` (macOS sh; busybox with Node 8.17 and Node 22.23) | 33 passed, 0 failed, on each |
| `test/e2e.sh` (Node 22 arm64 image, the amd64 binary emulated): HTTP through SOCKS5, WireGuard and a server peer; MTU 1280 and `WG_TCP_SNDBUF=65536` applied | 3 passed, 0 failed |
| wireguard-go `go test ./...` at the pinned commit (including `TestTCPSendBuf` and `TestCreateNetTUNSendBuf`: unset = 128 KiB cap, `0` = gVisor's 1 MiB, a value = that value) | 8 packages ok: 100 tests and subtests passed, 1 skipped, 0 failed |
| wireproxy `go vet ./... && go test ./...` at the pinned commit | 3 passed, 0 failed |

`test/run.sh` covers home Wi-Fi (`HOME_ENDPOINT`, MTU 1420, 512 KiB, no DNS lookup), the switch to 5G (restart on
`ENDPOINT` by DoH, MTU 1280, 64 KiB), another Wi-Fi, no `HOME_SSID`, custom MTU and buffer, an address as
`ENDPOINT`, a new address after `RECHECK`, offline, no mgu-uplink, DoH failing, no configuration (idle, said once,
then started when the file appears), and every refusal above (`0.0.0.0`, `[::]`, a LAN address, `:port`, a quoted
address, `bindaddress:` syntax, the HTTP proxy, `[TCPServerTunnel]`, `WGConfig`, bad settings, a failing configtest).

### Measured on the car

BMW X5 G05, iDrive 7, camera streams from a home server through each tunnel (SOCKS5), against Tailscale
(another Store tool, userspace, SOCKS5). A run is 20 connects, 50 round trips, 50 MB down, 20 MB up, then a 60 s
1920x720 stream (freezes = gaps between frames over 300 ms). Medians unless stated; numbers from the bench's
`results.jsonl` and `weaklink.jsonl`.

| Where (date, runs per tunnel) | | down Mbit/s | up Mbit/s | longest freeze | freezes > 300 ms | RSS MB |
|---|---|---|---|---|---|---|
| home Wi-Fi (05/11, 5) | wireproxy 1.1.3, unpatched | 159.9 | 131.9 | 0.64 s max | 0 to 65 | 140 |
| | Tailscale | 98.8 | 106.6 | 0.85 s max | 37 to 61 | 98 |
| at home, after the patch and GOGC (07/11, 3) | wireproxy v1.1.3-mgu1 | 140.0 | 112.9 | 0.07 s max | 0 | 27 |
| | Tailscale | 93.5 | 85.0 | 0.35 s max | 0 to 1 | 35 |
| 5G, before the patch (05/11, 3) | wireproxy 1.1.3, unpatched | 49.5 | 1.1 (2 of 3 uploads timed out) | **11.4 s, 10.3 s, 1.1 s** | 7, 10, 4 | 27 |
| | Tailscale | 24.9 | 2.1 | 0.31 to 0.47 s | 1, 2, 1 | 32 |
| 5G, after the patch, away sndbuf 64 KiB (05/11, 2) | wireproxy v1.1.3-mgu1 | 46.6, 49.5 | 4.5, 3.8 | **0.31 s, 0.44 s** | 1, 3 | 26 to 29 |
| | Tailscale | 22.2, 19.9 | 7.1, 4.9 | 0.39 s, 0.47 s | 3, 4 | 32 |

Both tunnels froze often in the 05/11 Wi-Fi runs. For wireproxy the cause was its endpoint, the router's WAN
address used from the router's own LAN, which `HOME_ENDPOINT` fixes; the 07/11 runs have no freeze on either. The 5G rows are two sessions an hour
apart, not an A/B in one session: few runs, one car, one network.

## Build

`MGU_STORE=<a clone of the MGU Store> sh tools/jap-wireproxy/build.sh` (Docker). It clones the fork at
`WP_COMMIT`, checks that its `go.mod` pins the wireguard-go fork commit, and builds static linux/amd64 with
`-trimpath -ldflags "-s -w -X main.version=v1.1.3-mgu1"`.

## Licenses

| Part | License | Source |
|---|---|---|
| wireproxy | ISC (`LICENSE.wireproxy` in the package) | upstream [whyvl/wireproxy](https://github.com/whyvl/wireproxy); built from [JustAnotherPU/wireproxy `mgu1`](https://github.com/JustAnotherPU/wireproxy/tree/mgu1) at `2a4b1b2d531f8f53342ddc5d4f63a9f328e25de7` (upstream `31a9a34` + the pinned replace + go-socks5 v0.1.3) |
| wireguard-go | MIT (`LICENSE.wireguard-go`) | upstream [git.zx2c4.com/wireguard-go](https://git.zx2c4.com/wireguard-go); built from [JustAnotherPU/wireguard-go `mgu-tcp-sndbuf`](https://github.com/JustAnotherPU/wireguard-go/tree/mgu-tcp-sndbuf) at `4c208941dfb3c99924b20834c4f2828f7d309cfb` (upstream `f333402` + the send buffer cap and its tests) |
| Go dependencies (gVisor Apache-2.0, golang.org/x BSD-3-Clause, go-socks5 MIT, ...) and the Go runtime (BSD-3-Clause) | their own | listed in the fork's `go.mod`; each licence is in its module |
| `jap-runas` | GPL-3.0-or-later (`COPYING.jap-runas`) | [tools/jap-tailscale/runas](../jap-tailscale/runas) |
| `start.sh`, `setup.sh`, `resolve.js`, `check.sh`, the unit, the tests | MIT | this folder |

WireGuard is a registered trademark of Jason A. Donenfeld. This package is an unofficial build, not affiliated
with or endorsed by the WireGuard project or wireproxy's authors.
