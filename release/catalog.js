'use strict';
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 JustAnotherPU
// node release/catalog.js <folder> <base url>: writes <folder>/catalog.json (MGU Store catalog, schema 2) for the
// artifacts in the folder, each with its size and sha256; <base url> is where they are downloaded from.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [dir, base] = process.argv.slice(2);
if (!dir || !/^https:\/\//.test(base || '')) { console.error('usage: node release/catalog.js <folder> <https base url>'); process.exit(2); }
const AUTHOR = 'JustAnotherPU';
const META = {
    jap_sysmon: { kind: 'app', title: 'iDrive Monitor', icon: 'jap_sysmon.png',
        description: require('../apps/jap_sysmon/app.json').description,
        requires: () => ({ 'mgu-render': '0.6.11', 'mgu-inputgate': '1.0.0' }) },
    // the tools are installed as another app's requirement (or on their own); optional: never offered as an
    // update until installed
    'jap-node22': { kind: 'tool', title: 'Node.js 22', optional: true,
        description: "Node.js 22 LTS for the background services of Moonride and RideTube (BMW's apps keep the system Node 8)",
        requires: () => ({ 'mgu-deploy': '0.7.0' }) },
    'jap-tailscale': { kind: 'tool', title: 'Tailscale', optional: true,
        description: 'Tailscale in userspace networking with a SOCKS5 server on 127.0.0.1 (Moonride plays over 5G through it); incoming connections refused; you log in by scanning a QR code in Moonride',
        requires: () => ({ 'mgu-deploy': '0.7.0' }) },
    'jap-wireproxy': { kind: 'tool', title: 'WireGuard (wireproxy)', optional: true,
        description: 'A WireGuard client to your own WireGuard server (no account, no relay), with a SOCKS5 server on 127.0.0.1; picks the endpoint, MTU and TCP send buffer for home Wi-Fi or 5G; does nothing until you write its configuration (README)',
        requires: () => ({ 'mgu-deploy': '0.7.0' }) },
};
const files = fs.readdirSync(dir).filter((f) => /^[a-z0-9_-]+@\d+\.\d+\.\d+\.tgz$/.test(f)).sort();
const version = {};
files.forEach((f) => { const [id, v] = f.slice(0, -4).split('@'); if (!META[id]) throw new Error('unknown artifact ' + f); version[id] = v; });
Object.keys(META).forEach((id) => { if (!version[id]) throw new Error('missing artifact for ' + id); });
const hash = (f) => crypto.createHash('sha256').update(fs.readFileSync(path.join(dir, f))).digest('hex');
const components = files.map((f) => {
    const [id, v] = f.slice(0, -4).split('@'), m = META[id];
    const c = { id, kind: m.kind, title: m.title, description: m.description, author: AUTHOR, version: v,
        artifact: { name: f, size: fs.statSync(path.join(dir, f)).size, sha256: hash(f), url: base + '/' + f },
        requires: m.requires(version), uninstallable: true, mguHmi: ['ID7'] };
    if (m.optional) c.optional = true;
    if (m.icon) { c.icon = m.icon; c.iconSha256 = hash(m.icon); }
    return c;
});
fs.writeFileSync(path.join(dir, 'catalog.json'), JSON.stringify({ schema: 2, components }, null, 2) + '\n');
console.log('catalog.json: ' + components.map((c) => c.id + '@' + c.version).join(', '));
