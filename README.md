# mgu-apps

Apps and shared tools for the BMW iDrive 7 head unit (MGU), installed from the MGU Store:

- **iDrive Monitor** (`jap_sysmon`): the head unit's CPU, memory and graphics load, with a pop-up when it runs short.
- **wireproxy** (`jap-wireproxy`): the car's tunnel home. A client for the WireGuard® protocol to your own server,
  through a local SOCKS5 proxy, tuned for the car's 5G uplink. Your traffic goes from the car to your server and
  nowhere else.
- **Node.js 22** (`jap-node22`): the Node runtime that the background services of Moonride and RideTube run on.

The tools live only here, so the Store never sees the same tool id from two sources. Moonride and RideTube
require `jap-node22` from this source.

![iDrive Monitor on a quiet head unit](docs/media/sysmon.png)

*iDrive Monitor on a quiet head unit.*

![iDrive Monitor when the head unit runs short](docs/media/sysmon-short.png)

*When the iDrive runs short: the values over a limit change colour and the last alert stays on the page.*

![iDrive Monitor in the Night Amber theme](docs/media/sysmon-amber.png)

*The Night Amber colour theme.*

(Drawn offline by the head unit's renderer, with demo values.)

Independent project, not affiliated with or endorsed by BMW, Tailscale Inc., the WireGuard project or the OpenJS
Foundation. The wireproxy package is an unofficial build of an open-source client. WireGuard is a
registered trademark of Jason A. Donenfeld. Use at your own risk.

Tested on one car: BMW X5 xDrive45e (G05), iDrive 7 (MGU, ID7 HMI), firmware P18_23w44.2-1-3. Reports from other
cars are welcome in the issues.

## Requirements

- A BMW with iDrive 7 (MGU, `ID7`) and the [MGU Store](https://github.com/robertnisipeanu/mgu-store) installed.
- From the Store's own source: the renderer `mgu-render` 0.6.11 or newer, `mgu-deploy` 0.7.0 (for the tools) and,
  for wireproxy, `mgu-uplink` with an internet connection. From the Store's default
  `cauliflowermossgrape/idrive7-apps` source: the controller gate `mgu-inputgate` (for iDrive Monitor). The Store
  installs requirements first; keep those sources in the Store, or the install stops with a missing requirement.

## Install

In the MGU Store, add the source

```
JustAnotherPU/mgu-apps:releases
```

(the `catalog` release of this repository), then install iDrive Monitor or wireproxy. You don't need to install
Node.js 22 yourself: the Store installs it when an app needs it. The packages are prebuilt. The BMW SDK module is
not in them: the head unit makes it from an app already on the car.

## iDrive Monitor

It shows the head unit's CPU, free memory, the apps' memory against their cap, swap and the graphics clock on
one page. It raises a short pop-up when the iDrive runs short:

- CPU at 90 % or more for 30 s
- under 500 MB free
- the apps at 1300 MB of their cap, or the cap refusing memory

At most one pop-up comes every 10 minutes, and none while reversing. It starts with the head unit, so the check
runs without opening the app. It reads three small system files every 10 s and nothing else.

Settings:

- **Pop-up when the iDrive is short of resources**: on by default.
- **Colour theme**.
- The page's *Test pop-up* button shows the pop-up once.

Known limits:

- The thresholds are fixed (see above). They were chosen on one car.
- The graphics clock is shown but never alerted on, because the GPU never idles on this unit.


## wireproxy

`jap-wireproxy` runs [wireproxy](https://github.com/whyvl/wireproxy) v1.1.3-mgu2, a client for the WireGuard®
protocol in userspace, to a WireGuard server you run yourself (a home router, a VPS), with a SOCKS5 proxy on
`127.0.0.1` for programs on the head unit. RideWatch and Moonride use it to reach your cameras and your PC from the
road.

Why use it rather than a hosted mesh VPN such as Tailscale:

- **Private.** The car talks to your server only. There is no account, no company coordination server that learns
  your devices, their addresses and when they connect, and no company relay. In one 5G session of the bench,
  Tailscale went through its relay in Amsterdam in 2 of 3 runs. That traffic is end-to-end encrypted, but it still
  passes through a server you don't run. With wireproxy, one peer, one key and one UDP port on your server
  are the whole setup.
- **Faster down.** Measured on the car against Tailscale 1.104.4: 140 against 94 Mbit/s on the home Wi-Fi, 47 to
  50 against 20 to 22 Mbit/s on 5G, and 1.6 to 3.2 times faster in the last 5G session.
- **Smoother video.** In that last session, after a first round on a weak link, a 60 s camera stream froze once
  per run through wireproxy (0.34 to 0.52 s, 30 frames per second) and 14 and 26 times through Tailscale (up to
  0.86 s, 21.5 and 27.8 frames per second).
- **Lighter.** 23 to 29 MB of memory, against 28 to 35 MB for Tailscale.

What it costs: Tailscale's upload was faster in most 5G runs (for example 6.7 against 3.7 Mbit/s); in a session
where the phone sharing its 5G was busy playing videos, wireproxy's longest freezes were longer; and wireproxy needs
a WireGuard server you can reach from the internet. Full numbers and conditions: the bench in the
[tool's README](tools/jap-wireproxy/README.md#measured-on-the-car).

- Its WireGuard library caps the TCP send buffer of the userspace network stack. Without the cap, an upload on a
  slow 5G uplink froze video streams for 10 to 11 s; with it, the longest gap measured was 0.44 s.
- It picks the endpoint, MTU and that cap from the uplink: your home Wi-Fi (`HOME_SSID`, a LAN endpoint) or
  elsewhere (`ENDPOINT`, resolved by DNS over HTTPS).
- It does nothing until you write `/var/opt/jap-wireproxy/conf/wireproxy.conf` (and `settings`) as root, and says
  so in `systemctl status jap-wireproxy`. It refuses a proxy that is not on the loopback and a `[TCPServerTunnel]`.

Configuration, head-unit rules, tests and bench: [tools/jap-wireproxy/README.md](tools/jap-wireproxy/README.md).

## Node.js 22

`jap-node22` is Node.js 22.23.4 from nodejs.org's unofficial-builds `linux-x64-glibc-217` flavour. The unit has
glibc 2.27, and the official build needs 2.28. It installs to `/var/opt/jap-node22/current/bin/node` and changes
nothing else: BMW's apps keep the system Node 8. Moonride's service (`jap-moonride`) and RideTube's service
(`jap-ridetube-d`) require it and call it by that path. See [tools/jap-node22/README.md](tools/jap-node22/README.md).

## Repository layout

| Path | |
|---|---|
| `apps/jap_sysmon` | iDrive Monitor (Node 8, the iDrive's own app runtime) |
| `kit/` | the idrive7-apps app kit, trimmed to what iDrive Monitor uses |
| `tools/jap-wireproxy` | the wireproxy tool: manifest, unit, supervisor, `jap-runas`, build script, tests |
| `tools/jap-node22` | the Node.js 22 tool: manifest, build script (downloads and checks the pinned build) |
| `release/` | makes the Store release (`catalog.json` and the artifacts) |

## Build and test on a computer

```sh
node kit/tools/test_runtime.js && node kit/tools/test_life.js && node kit/tools/test_sysmon.js
```

The tests need a current Node (18 or newer). The app itself runs on the head unit's Node 8. The wireproxy tool's
supervisor has its own tests (`sh tools/jap-wireproxy/test/run.sh`, any Node; see its README).

A release needs an `oap-sdk` folder extracted from a BMW app you own (`node kit/tools/extract_sdk.js
<javascript/app.js of a BMW app>`, which writes `./oap-sdk`; never commit it). It also needs Docker (on a Mac:
colima, with `TMPDIR` outside `/var/folders`) and a checkout of the MGU Store for its packer:

```sh
export MGU_STORE=<a clone of the MGU Store>
python3 kit/tools/build.py jap_sysmon        # dist/jap_sysmon@<version>.tgz
sh tools/jap-node22/build.sh                 # dist/jap-node22@<version>.tgz
sh tools/jap-wireproxy/build.sh              # dist/jap-wireproxy@<version>.tgz
sh release/release.sh                        # dist/release/: catalog.json + artifacts (no oap-sdk)
```

## Releasing

Make a GitHub release named `catalog` (tag `catalog`) and upload every file of `dist/release/`: `catalog.json`,
the three `.tgz` artifacts and `jap_sysmon.png`. The Store reads `catalog.json` from that release and checks every
download against its size and sha256. For a new version, run `release/release.sh` again and replace the release's
files. No binary is committed to this repository.

## License

MIT, Copyright (c) 2026 JustAnotherPU ([LICENSE](LICENSE)), except:

- `tools/jap-wireproxy/runas` (`jap-runas`, shipped in `jap-wireproxy`) and `tools/jap-node22/set-loader.js`:
  GPL-3.0-or-later ([tools/jap-wireproxy/runas/COPYING](tools/jap-wireproxy/runas/COPYING)).
- The app kit in `kit/` (MIT), wireproxy (ISC), wireguard-go (MIT) and Node.js (MIT and
  others): see
  [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Each tool package carries the licences of what it ships; the
  wireproxy package has the full texts of its Go modules in `files/LICENSES.txt`.
