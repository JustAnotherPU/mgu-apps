'use strict';
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 JustAnotherPU
// node resolve.js <name>: prints the A record of <name> by DNS over HTTPS on 1.1.1.1. The service's own resolver
// (dnsmasq on 127.0.0.1) answers nothing, and a home network's DNS may return a local override, not the WAN address.
// Runs on BMW's Node 8.
const name = process.argv[2];
require('https').get({ host: '1.1.1.1', path: '/dns-query?type=A&name=' + encodeURIComponent(name), headers: { accept: 'application/dns-json' }, timeout: 8000 }, (r) => {
    let b = '';
    r.on('data', (d) => { b += d; });
    r.on('end', () => {
        let ip;
        try { ip = ((JSON.parse(b).Answer || []).find((a) => a.type === 1) || {}).data; } catch (e) { /* not JSON */ }
        if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip || '')) { console.error('no A record for ' + name); process.exit(1); }
        console.log(ip);
    });
}).on('timeout', function () { this.destroy(new Error('timeout')); }).on('error', (e) => { console.error('DoH: ' + e.message); process.exit(1); });
