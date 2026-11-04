'use strict';
/**
 * iDrive Monitor - is the head unit short of CPU or memory?
 *
 *   - a page with CPU, free memory, the apps' memory against their cap (the nodejs.slice cgroup),
 *     swap and the graphics clock, refreshed every 2 s while shown
 *   - a short pop-up (BMW's own small pop-up, as x_call raises it) when the head unit is short:
 *     CPU >= 90 % for three 10 s samples in a row, free memory < 500 MB, the apps >= 1300 MB of
 *     their cap or the cap refusing memory (failcnt rising). At most one pop-up per 10 min, and
 *     the next only after all are back under (80 %, 600 MB, 1200 MB). None in reverse.
 *
 * The app starts with the head unit ("startType": "autostart") so the check runs without the app
 * being opened. It reads three small files every 10 s, nothing else. The graphics clock is shown,
 * never alerted on: the GPU never idles on this unit, so a high clock means awake, not busy.
 */
const fs = require('fs');
const mgu = require('./kit/mgu');
const G = require('./kit/gauges');
const { withAlpha } = require('./kit/canvas');
const Car = require('./kit/car');

const W = 1600, H = 520;
const CG = '/sys/fs/cgroup/memory/oap.slice/nodejs.slice/';
const GPU = '/sys/class/drm/card0/gt_act_freq_mhz', GPU_MAX = 750;
const SAMPLE_MS = 10000, POP_MS = 8000, COOLDOWN_MS = 10 * 60000;
const LIM = { cpu: 90, cpuN: 3, avail: 500, apps: 1300 }, CLR = { cpu: 80, avail: 600, apps: 1200 };

const MB = 1048576;
const readNum = (f) => { try { return Number(fs.readFileSync(f, 'utf8').trim()); } catch (e) { return null; } };

/** One reading: cpu ticks (busy, total), MemAvailable and swap used (MB), apps memory, cap and failcnt. */
function read() {
    const r = {};
    try {
        const c = fs.readFileSync('/proc/stat', 'utf8').split('\n')[0].trim().split(/\s+/).slice(1).map(Number);
        r.idle = c[3] + (c[4] || 0); r.total = c.reduce((a, b) => a + b, 0);
    } catch (e) { /* unreadable */ }
    try {
        const m = fs.readFileSync('/proc/meminfo', 'utf8'), kb = (k) => { const x = new RegExp('^' + k + ':\\s+(\\d+)', 'm').exec(m); return x ? Number(x[1]) : null; };
        r.avail = kb('MemAvailable') / 1024;
        r.swap = (kb('SwapTotal') - kb('SwapFree')) / 1024;
    } catch (e) { /* unreadable */ }
    const u = readNum(CG + 'memory.usage_in_bytes'), l = readNum(CG + 'memory.limit_in_bytes');
    r.apps = u === null ? null : u / MB; r.cap = l === null ? null : l / MB;
    r.fail = readNum(CG + 'memory.failcnt');
    r.gpu = readNum(GPU);
    return r;
}

/**
 * Turns readings into at most one alert per short spell. feed(reading, now) -> alert text or null;
 * last = the latest derived values ({ cpu %, avail, apps, cap, swap, gpu }).
 */
class Gate {
    constructor() { this.prev = null; this.hot = 0; this.armed = true; this.lastAt = -Infinity; this.lastFail = null; this.last = {}; }
    feed(r, now) {
        let cpu = null;
        if (this.prev && r.total > this.prev.total) cpu = 100 * (1 - (r.idle - this.prev.idle) / (r.total - this.prev.total));
        if (r.total !== undefined) this.prev = { idle: r.idle, total: r.total };
        const failUp = this.lastFail !== null && r.fail !== null && r.fail > this.lastFail;
        if (r.fail !== null) this.lastFail = r.fail;
        this.last = { cpu, avail: r.avail, apps: r.apps, cap: r.cap, swap: r.swap, gpu: r.gpu };
        this.hot = cpu !== null && cpu >= LIM.cpu ? this.hot + 1 : 0;
        const why = [];
        if (this.hot >= LIM.cpuN) why.push('CPU ' + Math.round(cpu) + ' %');
        if (r.avail !== null && r.avail < LIM.avail) why.push('free memory ' + Math.round(r.avail) + ' MB');
        if (r.apps !== null && r.apps >= LIM.apps) why.push('apps ' + Math.round(r.apps) + ' of ' + Math.round(r.cap) + ' MB');
        else if (failUp) why.push('apps at their memory cap');
        const calm = (cpu === null || cpu < CLR.cpu) && (r.avail === null || r.avail > CLR.avail) && (r.apps === null || r.apps < CLR.apps) && !failUp;
        if (calm) this.armed = true;
        if (!why.length || !this.armed || now - this.lastAt < COOLDOWN_MS) return null;
        this.armed = false; this.lastAt = now;
        return 'iDrive short of resources: ' + why.join(', ');
    }
}

mgu.run({
    async start(ctx) {
        const { ui, settings, log } = ctx;
        const car = new Car(ctx, ['gear']);
        const gate = new Gate();
        let popTimer = null, lastAlert = null;

        const closePop = () => { clearTimeout(popTimer); popTimer = null; ui.close('SYS_POP'); };
        function pop(text) {
            if (car.data().stage === 'R') { log.info('alert held back (reverse): ' + text); return; }
            log.warn('alert: ' + text);
            // as x_call: open the pop-up, then set its text (text sent before the open is refused, INVALID_MODELID)
            ui.open('SYS_POP').then(() => ui.text('SYS_POP_TEXT', text));
            clearTimeout(popTimer);
            popTimer = setTimeout(closePop, POP_MS);
        }
        ui.onClick('SYS_POP_OK', closePop);
        ui.onClick('BTN_TEST', () => pop('Test: ' + summary()));

        const n = (v, d) => (v === null || v === undefined || isNaN(v) ? '--' : v.toFixed(d || 0));
        const summary = () => { const s = gate.last; return 'CPU ' + n(s.cpu) + ' %, free ' + n(s.avail) + ' MB, apps ' + n(s.apps) + ' of ' + n(s.cap) + ' MB'; };

        // a test from the shell: touch <data>/test-popup, and the next sample shows a pop-up (the file is removed)
        const TEST_FILE = require('path').join(ctx.dataDir, 'test-popup');
        function sample() {
            const text = gate.feed(read(), Date.now());
            if (fs.existsSync(TEST_FILE)) { try { fs.unlinkSync(TEST_FILE); } catch (e) { /* root-owned */ } pop('Test: ' + summary()); }
            if (text) { lastAlert = { text, at: Date.now() }; if (settings.get('alerts') !== false) pop(text); }
        }
        sample();
        setInterval(sample, SAMPLE_MS);
        // keep running while hidden: the check is the app's job (autostart also keeps MainApp from stopping it)
        ctx.background('watch', true);

        function row(cv, t, x, y, label, value, unit, frac, warn) {
            cv.text(label, x, y, 22, t.dim, { font: 'bold', spacing: 1.5 });
            const w = cv.text(value, x, y + 62, 60, warn ? t.accent2 : t.text, { font: 'num' });
            cv.text(unit, x + w + 8, y + 62, 24, t.dim);
            if (frac !== null && !isNaN(frac)) {
                cv.fillRect(x, y + 84, 440, 8, withAlpha(t.tick, 0.3));
                cv.fillRect(x, y + 84, Math.max(0, Math.min(1, frac)) * 440, 8, warn ? t.accent2 : t.accent);
            }
        }

        // the page reads every 2 s while shown (its own Gate, only for its values); hidden it draws nothing
        const view = new Gate();
        async function render() {
            view.feed(read(), Date.now());
            const s = view.last.cpu === null ? Object.assign({}, view.last, { cpu: gate.last.cpu }) : view.last;
            const t = ctx.theme(), cv = ctx.canvas(W, H).clear(t.bg);
            row(cv, t, 80, 110, 'CPU', n(s.cpu), '%', s.cpu / 100, s.cpu >= LIM.cpu);
            row(cv, t, 580, 110, 'FREE MEMORY', n(s.avail), 'MB', null, s.avail < LIM.avail);
            row(cv, t, 1080, 110, 'APPS MEMORY', n(s.apps), 'of ' + n(s.cap) + ' MB', s.apps / s.cap, s.apps >= LIM.apps);
            row(cv, t, 80, 300, 'GRAPHICS CLOCK', n(s.gpu), 'MHz', s.gpu / GPU_MAX, false);
            row(cv, t, 580, 300, 'SWAP USED', n(s.swap), 'MB', null, false);
            const when = lastAlert ? new Date(lastAlert.at).toISOString().slice(11, 16) + ' UTC  ' + lastAlert.text.replace(/^iDrive short of resources: /, '') : 'none since start';
            cv.text('LAST ALERT', 1080, 300, 22, t.dim, { font: 'bold', spacing: 1.5 });
            cv.text(when, 1080, 340, 22, lastAlert ? t.text : t.dim, { maxWidth: 480 });
            G.frame(cv, t, ['iDrive Monitor'], 0);
            await ui.image('MAIN_GFX', cv);
        }
        let viewTimer = null;
        const redraw = () => render().catch((e) => log.warn('render: ' + e));
        ui.onVisible((name, on) => {
            if (name !== 'MAIN') return;
            clearInterval(viewTimer); viewTimer = null;
            if (on) { redraw(); viewTimer = setInterval(redraw, 2000); }
        });
        redraw();
    },
});

module.exports = { Gate, read, LIM, CLR, COOLDOWN_MS };
