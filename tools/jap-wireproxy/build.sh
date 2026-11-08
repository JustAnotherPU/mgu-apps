#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 JustAnotherPU
# Builds dist/jap-wireproxy@<version>.tgz: wireproxy v1.1.3-mgu2 from the pinned commit of its fork (wireguard-go
# with the TCP send buffer cap, pinned in its go.mod/go.sum), static linux/amd64, jap-runas (../jap-tailscale/runas)
# and LICENSES.txt (the licence texts of the Go modules in the binary, and Go's own), in a golang container (Docker;
# on a Mac run it in colima, TMPDIR outside /var/folders), then packs them
# with the MGU Store's packer ($MGU_STORE: a checkout of https://github.com/robertnisipeanu/mgu-store).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
store=${MGU_STORE:?set MGU_STORE to a checkout of github.com/robertnisipeanu/mgu-store}
WP_REPO=https://github.com/JustAnotherPU/wireproxy.git
WP_COMMIT=64c5904bc6b918464fd401687ae3c87e7a806e8a      # branch mgu2
WG_MOD=github.com/JustAnotherPU/wireguard-go@v0.0.0-20261108050311-2a38e13930f2   # branch mgu-tcp-sndbuf-2
GO_IMAGE=${GO_IMAGE:-golang:1.27.3@sha256:2920bb124f1a2e12a1d39f0cab756ae0068441ee1da7655dec7f5e374944095b}
mkdir -p "$here/build"
docker run --rm -v "$here/..:/w" -e WP_REPO="$WP_REPO" -e WP_COMMIT="$WP_COMMIT" -e WG_MOD="$WG_MOD" \
    -e GOTOOLCHAIN=local -e GOFLAGS=-buildvcs=false -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=amd64 "$GO_IMAGE" sh -euc '
    b=/w/jap-wireproxy/build
    cd /w/jap-tailscale/runas && go build -trimpath -ldflags "-s -w" -o $b/jap-runas . && cp ../COPYING $b/COPYING.jap-runas
    rm -rf /tmp/wp && git clone -q "$WP_REPO" /tmp/wp && cd /tmp/wp && git checkout -q "$WP_COMMIT"
    grep -q "=> ${WG_MOD%@*} ${WG_MOD#*@}$" go.mod || { echo "go.mod does not pin $WG_MOD" >&2; exit 1; }
    go build -trimpath -ldflags "-s -w -X main.version=v1.1.3-mgu2" -o $b/wireproxy ./cmd/wireproxy
    cp LICENSE $b/LICENSE.wireproxy
    install -m 644 "$(go mod download -json "$WG_MOD" | sed -n "s/.*\"Dir\": \"\(.*\)\".*/\1/p")/LICENSE" $b/LICENSE.wireguard-go   # module cache files are 0444
    GOOS= GOARCH= go install github.com/google/go-licenses@v1.6.0
    rm -rf /tmp/lic && /go/bin/go-licenses save ./cmd/wireproxy --save_path=/tmp/lic 2>/dev/null
    { echo "Licences of the Go modules built into wireproxy (go-licenses v1.6.0 save, wireproxy $WP_COMMIT), then Go'"'"'s."
      echo "kernel.org/.../libcap/psx is BSD-3-Clause OR GPL-2.0-only: used here under BSD-3-Clause."
      cd /tmp/lic && find . -type f \( -iname "licen[cs]e*" -o -iname "copying*" -o -iname "notice*" \) | LC_ALL=C sort |
          while read -r f; do printf "\n==== %s\n\n" "${f#./}"; cat "$f"; done
      printf "\n==== Go standard library and runtime (%s)\n\n" "$(go version | cut -d" " -f3)"; cat "$(go env GOROOT)/LICENSE"; } > $b/LICENSES.txt
    echo "wireproxy $($b/wireproxy -v) ($WP_COMMIT): $(wc -c < $b/wireproxy) bytes, sha256 $(sha256sum $b/wireproxy | cut -c1-64)"'
file "$here/build/wireproxy" | grep -q 'ELF 64-bit.*x86-64.*statically linked' || { echo "build.sh: wireproxy is not a static x86-64 ELF" >&2; exit 1; }
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$here" log -1 --format=%ct 2>/dev/null || echo 0)} \
    node "$store/deploy/hu" artifact "$here" --out "$here/../../dist"
