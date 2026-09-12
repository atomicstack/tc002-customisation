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

function both(status, extra = {}) {
  W.reset('art', 'popsquares', 1);
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
  W.reset('art', 'popsquares', 1);
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
  W.reset('clock', 'popsquares', 1);
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

test('an index past the end of an enum is ignored, not coerced to a neighbour', () => {
  // the wasm takes enum values as indices into the lists the console read out of it, and decides
  // what is in range from the enum itself. a count written into this shim would go stale the next
  // time the runtime gains or retires a variant, which is the whole bug being designed out
  W.reset('clock', 'popsquares', 1);
  const styled = W.compose(clockStatus({ font: 'big' }), localWith(W), WALL);
  const e = W.exports;
  e.setClockStyle(99, -1, -1, -1, -1, -1, -1, WALL);   // no such font: leave the style alone
  const after = W.compose(clockStatus({ font: 'big' }), localWith(W), WALL);
  assert.equal(bytesDiffering(styled.rgb, after.rgb), 0, 'a bogus font index changed the render');
  assert.equal(W.renderIpLayout(W.IP_MODES.length - 1, '1.2.3.4', WALL).rgb.length, W.RGB_BYTES);
  assert.throws(() => W.renderIpLayout(W.IP_MODES.length, '1.2.3.4', WALL), /no such ip layout/);
});

/* ---------- cadence: when the console is told to come back ---------- */

test('cadence follows the scene, not a fixed timer', () => {
  W.reset('clock', 'popsquares', 1);
  const clock = W.compose(clockStatus(), localWith(W), WALL);
  assert.equal(clock.cadenceMs, 1000, 'the clock redraws on the next whole second');

  assert.equal(W.renderIpLayout('lines', '192.168.1.42', WALL).cadenceMs, null,
               'a static ip layout needs no timer');
  const scrolling = W.renderIpLayout('scroll', '192.168.1.42', WALL).cadenceMs;
  assert.ok(scrolling > 0 && scrolling < 100, `a scrolling layout wants frames, got ${scrolling}`);

  const art = W.compose({ base: 'art', overlay: 'none', generator: 'popsquares', brightness: 100 }, localWith(W), WALL);
  assert.ok(art.cadenceMs > 10 && art.cadenceMs < 20, `art runs at ~60 hz, got ${art.cadenceMs}`);
});

/* ---------- the shadow: the device's seed, the device's clock, and a check ---------- */

test('the art seed comes from /status, so the preview runs the panel\'s animation', () => {
  const artStatus = seed => ({ base: 'art', overlay: 'none', generator: 'popsquares', brightness: 100, seed });
  W.reset('art', 'popsquares', 1);
  const a = W.compose(artStatus(4242), localWith(W), WALL);
  W.reset('art', 'popsquares', 999);              // a different starting seed
  const b = W.compose(artStatus(4242), localWith(W), WALL);
  assert.equal(bytesDiffering(a.rgb, b.rgb), 0, 'the same published seed must give the same frame');

  W.reset('art', 'popsquares', 1);
  const other = W.compose(artStatus(7), localWith(W), WALL);
  assert.notEqual(bytesDiffering(a.rgb, other.rgb), 0, 'a different seed must give a different frame');
  assert.match(a.label, /seed 4242 from the device/);

  // a runtime too old to publish one still previews, on the page's own seed
  const legacy = W.compose({ base: 'art', overlay: 'none', generator: 'popsquares', brightness: 100 },
                           localWith(W, { art: new W.Art('popsquares', 5) }), WALL);
  assert.match(legacy.label, /local seed/);
});

test('the wall clock is anchored to the device, not to this machine', () => {
  const header = 'Fri, 11 Sep 2026 23:00:00 GMT';
  assert.equal(W.anchorClock(header, Date.parse('2026-09-11T23:00:07Z')), true);
  assert.equal(W.clockSkewMs, -7000, 'seven seconds behind the browser');
  assert.equal(W.deviceNow(1000), 1000 + W.clockSkewMs);

  // a clock seven seconds off must draw a different second
  const withSkew = W.compose(clockStatus(), localWith(W), WALL);
  assert.equal(W.anchorClock('not a date'), false, 'a header that will not parse is ignored');
  W.anchorClock(new Date(WALL).toUTCString(), WALL);   // back to no skew
  const noSkew = W.compose(clockStatus(), localWith(W), WALL);
  assert.notEqual(bytesDiffering(withSkew.rgb, noSkew.rgb), 0, 'the skew must reach the clock face');
});

test('agreement measures the shadow against the panel', () => {
  const a = new Uint8Array(W.RGB_BYTES);
  const b = new Uint8Array(W.RGB_BYTES);
  const same = W.agreement(a, b);
  assert.equal(same.exact, true);
  assert.equal(same.fraction, 1);
  assert.equal(same.bytesDiffering, 0);

  b[0] = 1; b[9] = 200;
  const off = W.agreement(a, b);
  assert.equal(off.exact, false);
  assert.equal(off.bytesDiffering, 2);
  assert.ok(off.fraction > 0.999 && off.fraction < 1);
  assert.equal(off.simLit, 2, 'the second buffer is the simulation');

  assert.equal(W.agreement(null, b), null);
  assert.equal(W.agreement(a, new Uint8Array(4)), null, 'a length mismatch is not a comparison');
});

/* ---------- the canvas: a document the device parses, not one this file models ---------- */

const canvasStatus = { base: 'canvas', overlay: 'none', generator: 'popsquares', brightness: 100 };
const withCanvas = doc => localWith(W, { canvas: doc });

test('a canvas document renders through the runtime\'s own parser', () => {
  W.reset('canvas', 'popsquares', 1);
  const empty = W.compose(canvasStatus, withCanvas(null), WALL);
  assert.equal(empty.label, 'canvas · empty');
  assert.ok(lit(empty.rgb) > 0, 'an empty canvas draws its hint word, not a black panel');

  const doc = { elements: [
    { type: 'text', id: 't', at: [1, 0], text: '21.1C', colour: '00ff88' },
    { type: 'bar', id: 'b', at: [1, 9], size: [30, 3], value: 70, colour: '3a6ea5' },
    { type: 'icon', id: 'i', at: [42, 1], icon: 'heart', colour: 'ff0044' },
  ] };
  const drawn = W.compose(canvasStatus, withCanvas(doc), WALL);
  assert.equal(drawn.label, 'canvas');
  assert.notEqual(bytesDiffering(empty.rgb, drawn.rgb), 0, 'the document must change the frame');
  assert.ok(lit(drawn.rgb) > lit(empty.rgb));
});

test('a document the device would refuse is reported, not silently drawn empty', () => {
  W.reset('canvas', 'popsquares', 1);
  // `name` is not the icon field — the runtime calls it `icon` — so its strict parser refuses it
  const bad = { elements: [{ type: 'icon', id: 'i', at: [0, 0], name: 'heart' }] };
  const c = W.compose(canvasStatus, withCanvas(bad), WALL);
  assert.match(c.label, /the runtime refuses this document/);
  assert.match(c.label, /unknown_field/);
  assert.equal(W.lastCanvasResult.ok, false);

  const good = { elements: [{ type: 'icon', id: 'i', at: [0, 0], icon: 'heart' }] };
  const ok = W.compose(canvasStatus, withCanvas(good), WALL);
  assert.equal(ok.label, 'canvas');
  assert.equal(W.lastCanvasResult.ok, true);
});

test('an animated element ticks on the arbiter\'s clock', () => {
  W.reset('canvas', 'popsquares', 1);
  const doc = { elements: [{ type: 'text', id: 's', at: [2, 4], text: 'HELLO', colour: 'ffffff',
                             animate: { kind: 'scramble', ms: 600 } }] };
  const local = withCanvas(doc);
  const frames = [0, 100, 250, 450].map(dt => W.compose(canvasStatus, local, WALL + dt).rgb);
  const distinct = frames.filter((f, i) => i === 0 || bytesDiffering(frames[i - 1], f) !== 0);
  assert.ok(distinct.length > 1, 'a scramble must actually move between frames');
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
  // driven through the scene, not through a base: `ip` is retiring as a base scene and becoming a
  // page of the device menu, and previewing a layout never needed a base to begin with
  for (const addr of ['192.168.1.42', null]) {
    const wasm = W.renderIpLayout('lines', addr, WALL);
    const js = JS.black();
    JS.renderIp(js, JS.ipFromString(addr));
    assert.equal(bytesDiffering(js, wasm.rgb), 0, `ip lines differs for ${addr}`);
    assert.equal(wasm.cadenceMs, null, 'a static layout wants no timer');
  }
});

test('every ip layout renders and only the scrolling ones ask for frames', () => {
  const seen = new Map();
  for (const mode of W.IP_MODES) {
    const { rgb, cadenceMs } = W.renderIpLayout(mode, '192.168.1.42', WALL);
    assert.ok(lit(rgb) > 0, `${mode} drew nothing`);
    for (const [other, prev] of seen) {
      assert.notEqual(bytesDiffering(prev, rgb), 0, `${mode} draws the same pixels as ${other}`);
    }
    seen.set(mode, rgb);
    const scrolls = mode === 'scroll' || mode === 'big';
    assert.equal(cadenceMs !== null, scrolls, `${mode} cadence should${scrolls ? '' : ' not'} be set`);
  }
  assert.throws(() => W.renderIpLayout('nonesuch', '1.2.3.4', WALL), /no such ip layout/);
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

test('drift: sim.js has only one ip layout, and draws it whatever the mode', () => {
  const jsLines = JS.black();
  JS.renderIp(jsLines, JS.ipFromString('192.168.1.42'));
  for (const mode of W.IP_MODES) {
    const wasm = W.renderIpLayout(mode, '192.168.1.42', WALL);
    const same = bytesDiffering(jsLines, wasm.rgb) === 0;
    assert.equal(same, mode === 'lines', `sim.js's only layout should match ${mode} iff it is lines`);
  }
});

test('drift: sim.js clamps the gradient by a fixed 96, the runtime by the style\'s spread', () => {
  assert.equal(JS.CLOCK_MAX_SPREAD, 96);
  assert.equal(W.CLOCK_MAX_SPREAD, 255, 'clock.default_spread');
  const { js, wasm } = both(clockStatus({ colour_mode: 'gradient', colour: 'ff0000', colour2: '00ff00' }));
  assert.notEqual(bytesDiffering(js.rgb, wasm.rgb), 0, 'the two clamps should disagree');
});
