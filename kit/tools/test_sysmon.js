'use strict';

// iDrive Monitor's alert gate against synthetic readings: CPU needs three busy samples in a row, memory alerts at
// once, one pop-up per spell (re-armed only after all are back under), at most one per 10 min. No SDK needed:
//   node kit/tools/test_sysmon.js

const assert = require('assert');
const path = require('path');
const Module = require('module');

const ROOT = path.join(__dirname, '..', '..'), KIT = path.join(ROOT, 'kit', 'runtime');
const stubs = { './kit/mgu': { run() {} } };
const load = Module._load;
Module._load = function (req, parent, isMain) {
    if (stubs[req]) return stubs[req];
    if (req.startsWith('./kit/')) return load.call(this, path.join(KIT, req.slice(6)), parent, isMain);
    return load.call(this, req, parent, isMain);
};
const { Gate, COOLDOWN_MS } = require(path.join(ROOT, 'apps', 'jap_sysmon', 'main.js'));

// a reading whose CPU over the last 10 s is busy %: 1000 ticks per sample
let ticks = { idle: 0, total: 0 };
function at(busy, mem) {
    ticks = { idle: ticks.idle + (100 - busy) * 10, total: ticks.total + 1000 };
    return Object.assign({ idle: ticks.idle, total: ticks.total, avail: 2000, swap: 0, apps: 800, cap: 1400, fail: 5, gpu: 600 }, mem || {});
}

let g = new Gate(), t = 0;
const step = (busy, mem) => { t += 10000; return g.feed(at(busy, mem), t); };

assert.strictEqual(step(10), null, 'first sample has no CPU yet');
assert.strictEqual(g.last.cpu, null); assert.strictEqual(step(10), null); assert.strictEqual(Math.round(g.last.cpu), 10);
assert.strictEqual(step(95), null, '1 busy sample');
assert.strictEqual(step(95), null, '2 busy samples');
assert.match(step(95), /CPU 95 %/, '3rd busy sample alerts');
assert.strictEqual(step(95), null, 'still busy: same spell, no second pop-up');
assert.strictEqual(step(85), null, '85 % is not calm yet (clears under 80)');
assert.strictEqual(step(50), null, 'calm: re-armed, nothing to say');
step(95); step(95);
assert.strictEqual(step(95), null, 'new spell inside 10 min: held back by the cooldown');

// memory alerts at once, after the cooldown
g = new Gate(); t = 0; step(10);
assert.match(step(10, { avail: 400 }), /free memory 400 MB/);
t += COOLDOWN_MS;
assert.strictEqual(step(10, { avail: 450 }), null, 'never back over 600 MB: still the same spell');
step(10);
t += COOLDOWN_MS;
assert.match(step(10, { apps: 1320 }), /apps 1320 of 1400 MB/);

// the cap refusing memory (failcnt rising) without the usage line crossing
g = new Gate(); t = 0; step(10, { fail: 5 });
assert.match(step(10, { fail: 9 }), /apps at their memory cap/);

// unreadable files: no alert, no throw
g = new Gate(); t = 0;
assert.strictEqual(g.feed({ avail: null, apps: null, cap: null, fail: null, gpu: null }, 1), null);

console.log('sysmon: OK');
