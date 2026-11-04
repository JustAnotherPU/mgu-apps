#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 JustAnotherPU
# Builds dist/jap-tailscale@<version>.tgz: tailscaled (with the tailscale CLI linked in) from the upstream tag,
# static linux/amd64, and jap-runas, in a golang container (Docker; on a Mac run it in colima, TMPDIR outside
# /var/folders), then packs them with the MGU Store's packer ($MGU_STORE: a checkout of
# https://github.com/robertnisipeanu/mgu-store).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
store=${MGU_STORE:?set MGU_STORE to a checkout of github.com/robertnisipeanu/mgu-store}
TS_TAG=v1.104.4
TS_COMMIT=27047635f237d1f3e0b08c0f487674757f30d2f7
GO_IMAGE=${GO_IMAGE:-golang:1.27.3@sha256:2920bb124f1a2e12a1d39f0cab756ae0068441ee1da7655dec7f5e374944095b}
# the full feature set (SOCKS5 outbound proxy and subnet routes among them) plus the CLI in the same binary
TAGS=ts_include_cli
mkdir -p "$here/build"
docker run --rm -v "$here:/w" -e TS_TAG="$TS_TAG" -e TS_COMMIT="$TS_COMMIT" -e TAGS="$TAGS" -e GOTOOLCHAIN=local \
    -e GOFLAGS=-buildvcs=false "$GO_IMAGE" sh -euc '
    cd /w/runas && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o /w/build/jap-runas .
    rm -rf /tmp/ts && git clone -q --depth 1 --branch "$TS_TAG" https://github.com/tailscale/tailscale.git /tmp/ts
    cd /tmp/ts && [ "$(git rev-parse HEAD)" = "$TS_COMMIT" ] || { echo "tag $TS_TAG is not $TS_COMMIT" >&2; exit 1; }
    eval "$(CGO_ENABLED=0 go run ./cmd/mkversion)"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -tags="$TAGS" -trimpath \
        -ldflags "-s -w -X tailscale.com/version.longStamp=$VERSION_LONG -X tailscale.com/version.shortStamp=$VERSION_SHORT" \
        -o /w/build/tailscaled ./cmd/tailscaled
    cp LICENSE /w/build/LICENSE
    echo "tailscaled $VERSION_LONG ($TS_COMMIT): $(wc -c < /w/build/tailscaled) bytes"'
file "$here/build/tailscaled" | grep -q 'ELF 64-bit.*x86-64.*statically linked' || { echo "build.sh: tailscaled is not a static x86-64 ELF" >&2; exit 1; }
node "$store/deploy/hu" artifact "$here" --out "$here/../../dist"
