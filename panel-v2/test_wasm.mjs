/* tests for the wasm-backed preview: `node --test panel-v2/`.
   the module under test is runtime/src/scene compiled to wasm, so these are not a second
   implementation to keep honest — they check the javascript glue (status -> commands, memory
   windows, catalogues) and pin the wasm renderer against the old hand-written sim.js port.
   run `zig build wasm` in runtime/ first; the .wasm is generated and not committed. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const WASM = join(here, 'tc002-panel.wasm');
const W = require('./sim-wasm.js');
const JS = require('./sim.js');

if (!existsSync(WASM)) {
  test('tc002-panel.wasm is built', () => {
    assert.fail(`${WASM} is missing: run \`zig build wasm\` in runtime/`);
  });
} else {
  await W.ready(WASM);
}

const WALL = Date.UTC(2026, 8, 6, 12, 34, 56);
const TZ = 'GMT0BST,M3.5.0/1,M10.5.0';
const localWith = (S, extra = {}) => ({ art: null, tz: S.tzParse(TZ), notify: null, frame: null, pending: null, ...extra });
const lit = rgb => rgb.filter(v => v).length;
const bytesDiffering = (a, b) => { let n = 0; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++; return n; };

const clockStatus = extra => ({
  base: 'clock', overlay: 'none', generator: 'popsquares', brightness: 100,
  clock: { font: 'classic', colour_mode: 'solid', colour: 'ffffff', colour2: 'ffffff', gradient: 'horizontal', ...extra },
});
const ipStatus = (mode, ip = '192.168.1.42') => ({ base: 'ip', overlay: 'none', generator: 'popsquares', brightness: 100, ip, ip_mode: mode });

function both(status, extra = {}) {
  W.reset(0, 0, 1);
  return {
    js: JS.compose(status, localWith(JS, extra), WALL),
    wasm: W.compose(status, localWith(W, extra), WALL),
  };
}

/* ---------- the module itself ---------- */

test('the wasm exposes the panel geometry the console assumes', () => {
  assert.equal(W.WIDTH, 52);
  assert.equal(W.HEIGHT, 16);
  assert.equal(W.RGB_BYTES, 2496);
  assert.equal(W.exports.panelWidth(), W.WIDTH);
  assert.equal(W.exports.panelHeight(), W.HEIGHT);
  assert.equal(W.exports.frameLen(), W.RGB_BYTES);
});

test('catalogues come from the zig enums, not from a list in this file', () => {
  // the base scenes are in flux (ip is retiring as a base and canvas is arriving on feat/canvas),
  // so this asserts the two that are staying rather than pinning the whole list. the ip tests
  // further down DO drive `base: "ip"` and will fail when that lands — deliberately: that is the
  // point at which the console needs to preview the ip layouts through the device menu instead
  assert.ok(W.BASES.includes('art') && W.BASES.includes('clock'), `bases: ${W.BASES.join(',')}`);
  assert.ok(W.BASES.length >= 2);
  assert.deepEqual(W.GENERATORS, ['popsquares', 'plasma', 'cube']);
  assert.deepEqual(W.CLOCK_FONTS, ['classic', 'mini', 'segment', 'big', 'block', 'hires']);
  assert.deepEqual(W.CLOCK_MODES, ['solid', 'gradient']);
  assert.deepEqual(W.GRADIENTS, ['horizontal', 'vertical', 'diagonal']);
  assert.deepEqual(W.DIGIT_STYLES, ['solid', 'outline', 'shadow']);
  assert.deepEqual(W.IP_MODES, ['lines', 'mini', 'scroll', 'big']);
});

test('a bad tz rule throws and leaves the clock on utc', () => {
  assert.throws(() => W.tzParse('nonsense!!'), /invalid tz rule/);
  assert.equal(W.tzParse('GMT0').stdOffset, 0);
  assert.equal(W.tzParse('EST5EDT,M3.2.0,M11.1.0').stdOffset, -18000);
});

test('scene parameters carry the arbiter\'s own table', () => {
  W.reset(0, 0, 1);
  const params = W.sceneParams();
  assert.ok(params.length > 0);
  const names = params.map(p => p.name);
  assert.ok(names.includes('scene'), `expected a scene selector, got ${names.join(',')}`);
  for (const p of params) {
    assert.ok(['choice', 'number', 'colour', 'toggle'].includes(p.kind), `bad kind ${p.kind}`);
    assert.equal(typeof p.value, 'number');
  }
});

test('the notification duration cap is read from the arbiter, not hardcoded here', () => {
  assert.equal(W.NOTIFY_MAX_S, 300);
  W.reset(1, 0, 1);
  const s = { base: 'clock', overlay: 'notify', generator: 'popsquares', brightness: 100 };
  const c = W.compose(s, localWith(W, { notify: { text: 'hi', colour: [255, 255, 255], sinceMs: WALL } }), WALL);
  assert.equal(c.label, 'notification');
  assert.ok(lit(c.rgb) > 0, 'an accepted notification draws something');
});

test('a staged frame is shown as-is and never reaches the arbiter', () => {
  const pending = new Uint8Array(W.RGB_BYTES).fill(9);
  const c = W.compose(clockStatus(), localWith(W, { pending }), WALL);
  assert.equal(c.label, 'pending frame');
  assert.deepEqual(c.rgb, pending);
});

/* ---------- cadence: when the console is told to come back ---------- */

test('cadence follows the scene, not a fixed timer', () => {
  W.reset(1, 0, 1);
  const clock = W.compose(clockStatus(), localWith(W), WALL);
  assert.equal(clock.cadenceMs, 1000, 'the clock redraws on the next whole second');

  const still = W.compose(ipStatus('lines'), localWith(W), WALL);
  assert.equal(still.cadenceMs, null, 'a static ip layout needs no timer');

  const scrolling = W.compose(ipStatus('scroll'), localWith(W), WALL);
  assert.ok(scrolling.cadenceMs > 0 && scrolling.cadenceMs < 100, `a scrolling layout wants frames, got ${scrolling.cadenceMs}`);
});

/* ---------- parity with the hand-written port, where it was still faithful ---------- */

test('every clock font sim.js implements is pixel-identical', () => {
  for (const font of ['classic', 'mini', 'segment', 'big']) {
    const { js, wasm } = both(clockStatus({ font }));
    assert.equal(bytesDiffering(js.rgb, wasm.rgb), 0, `clock font ${font} differs`);
    assert.equal(js.cadenceMs, wasm.cadenceMs);
  }
});

test('the ip lines layout and the no-address case are pixel-identical', () => {
  for (const status of [ipStatus('lines'), ipStatus('lines', null)]) {
    const { js, wasm } = both(status);
    assert.equal(bytesDiffering(js.rgb, wasm.rgb), 0);
  }
});

test('notifications are pixel-identical, centred and scrolling', () => {
  const base = { base: 'clock', overlay: 'notify', generator: 'popsquares', brightness: 100 };
  for (const text of ['hi', 'a much longer notification that scrolls']) {
    const notify = { text, colour: [0, 255, 136], sinceMs: WALL };
    const { js, wasm } = both(base, { notify });
    assert.equal(bytesDiffering(js.rgb, wasm.rgb), 0, `notification "${text}" differs`);
    assert.equal(Math.round(js.cadenceMs ?? -1), Math.round(wasm.cadenceMs ?? -1));
  }
});

test('the firmware level curve is identical at every brightness', () => {
  for (const b of [0, 1, 25, 50, 99, 100]) {
    assert.equal(bytesDiffering(JS.buildLut(b), W.buildLut(b)), 0, `lut differs at brightness ${b}`);
  }
});

/* ---------- the drift this change exists to remove ----------
   these assert that sim.js is WRONG, so they are the checklist for deleting it. each one is a
   place the javascript port stopped following runtime/src and nobody noticed. when sim.js goes,
   this block goes with it. */

test('drift: sim.js is missing generators and clock fonts the runtime has', () => {
  assert.deepEqual(JS.GENERATORS, ['popsquares', 'plasma']);
  assert.ok(W.GENERATORS.includes('cube'), 'the runtime grew a cube generator');
  assert.equal(JS.CLOCK_FONTS.length, 4);
  assert.equal(W.CLOCK_FONTS.length, 6, 'the runtime grew the block and hires fonts');
});

test('drift: sim.js draws every ip layout as `lines`', () => {
  const linesLit = lit(both(ipStatus('lines')).js.rgb);
  for (const mode of ['mini', 'scroll', 'big']) {
    const { js, wasm } = both(ipStatus(mode));
    assert.equal(lit(js.rgb), linesLit, `sim.js should be ignoring ip_mode ${mode}`);
    assert.notEqual(bytesDiffering(js.rgb, wasm.rgb), 0, `ip ${mode} should differ until sim.js goes`);
  }
});

test('drift: sim.js clamps the gradient by a fixed 96, the runtime by the style\'s spread', () => {
  assert.equal(JS.CLOCK_MAX_SPREAD, 96);
  assert.equal(W.CLOCK_MAX_SPREAD, 255, 'clock.default_spread');
  const { js, wasm } = both(clockStatus({ colour_mode: 'gradient', colour: 'ff0000', colour2: '00ff00' }));
  assert.notEqual(bytesDiffering(js.rgb, wasm.rgb), 0, 'the two clamps should disagree');
});
