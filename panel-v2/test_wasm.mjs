/* tests for the wasm-backed preview: `node --test panel-v2/`.
   the module under test is runtime/src/scene compiled to wasm, so these are not a second
   implementation to keep honest — they check the javascript glue (status -> commands, memory
   windows, catalogues) and the behaviour of the scenes as seen through it. the scenes' own
   correctness is tested in zig, next to the code: `zig build test` in runtime/.
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

test('the timezone takes an iana name as well as a posix rule', () => {
  // caught on hardware: /config.timezone holds an iana name, not a rule. parsing it directly
  // failed, the console caught the throw and fell back to utc, and the shadow's clock ran two
  // hours off the panel's. the runtime resolves both forms and so must this
  assert.equal(W.tzParse('GMT0').stdOffset, 0);
  assert.equal(W.tzParse('EST5EDT,M3.2.0,M11.1.0').stdOffset, -18000);
  assert.equal(W.tzParse('Europe/Amsterdam').stdOffset, 3600);
  assert.equal(W.tzParse('Europe/London').stdOffset, 0);
  assert.equal(W.tzParse('australia/sydney').stdOffset, 36000, 'zone names match case-insensitively');
  assert.throws(() => W.tzParse('nonsense!!'), /invalid tz rule/);
  assert.throws(() => W.tzParse('Nowhere/Nothing'), /invalid tz rule/);

  // and it must reach the clock face, not just the parser
  W.reset('clock', 'popsquares', 1);
  const utc = W.compose(clockStatus(), localWith(W, { tz: W.tzParse('UTC0') }), WALL).rgb.slice();
  const ams = W.compose(clockStatus(), localWith(W, { tz: W.tzParse('Europe/Amsterdam') }), WALL).rgb;
  assert.notEqual(bytesDiffering(utc, ams), 0, 'a zone two hours out must draw a different time');
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

test('every field of the clock style reaches the renderer', () => {
  // caught on hardware: the style block calls the digit style `digits`, this file read `digit`,
  // and the panel drew a shadowed face while the preview drew a solid one. the defaults matched,
  // so nothing below noticed until a real device was showing a non-default style
  W.reset('clock', 'popsquares', 1);
  const base = clockStatus({ font: 'block' });
  const solid = W.compose(base, localWith(W), WALL).rgb.slice();
  const cases = [
    { digits: 'shadow' }, { digits: 'outline' }, { font: 'big' }, { colour: 'ff0000' },
    // a gradient needs two colours to be one: white-to-white is solid white, and asserting on
    // that would only have proved the test could tell nothing apart
    { colour_mode: 'gradient', colour2: '0015ff' },
    { colour_mode: 'gradient', colour2: '0015ff', spread: 8 },
  ];
  for (const patch of cases) {
    W.reset('clock', 'popsquares', 1);
    const changed = W.compose(clockStatus({ font: 'block', ...patch }), localWith(W), WALL).rgb;
    assert.notEqual(bytesDiffering(solid, changed), 0,
                    `${JSON.stringify(patch)} changed nothing in the render`);
  }
});

test('every clock font renders, and no two of them draw the same thing', () => {
  // this used to compare against sim.js, the hand-written port these tests were written to
  // retire. with the port gone the claim worth making is about the fonts themselves: each one
  // draws something, and none is silently an alias for another
  const seen = new Map();
  for (const font of W.CLOCK_FONTS) {
    W.reset('clock', 'popsquares', 1);
    const { rgb, cadenceMs } = W.compose(clockStatus({ font }), localWith(W), WALL);
    assert.ok(lit(rgb) > 0, `clock font ${font} drew nothing`);
    for (const [other, prev] of seen) {
      assert.notEqual(bytesDiffering(prev, rgb), 0, `font ${font} draws the same pixels as ${other}`);
    }
    seen.set(font, rgb);
    // hires counts milliseconds, so it wants every frame; the rest wake on the next second
    if (font === 'hires') assert.ok(cadenceMs < 100, `hires should run fast, got ${cadenceMs}`);
    else assert.ok(cadenceMs > 100, `${font} should wake on the second, got ${cadenceMs}`);
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
  const noAddress = W.renderIpLayout('lines', null, WALL);
  assert.ok(lit(noAddress.rgb) > 0, 'no address should still draw `no ip`, not a black panel');
  assert.notEqual(bytesDiffering(noAddress.rgb, seen.get('lines')), 0);
  assert.throws(() => W.renderIpLayout('nonesuch', '1.2.3.4', WALL), /no such ip layout/);
});

test('a notification is centred when it fits and scrolls when it does not', () => {
  const base = { base: 'clock', overlay: 'notify', generator: 'popsquares', brightness: 100 };
  const shown = text => {
    W.reset('clock', 'popsquares', 1);
    return W.compose(base, localWith(W, { notify: { text, colour: [0, 255, 136], sinceMs: WALL } }), WALL);
  };
  const short = shown('hi');
  assert.equal(short.cadenceMs, null, 'text that fits needs no timer');
  assert.ok(lit(short.rgb) > 0);
  // centred: the lit columns are symmetric about the middle of the panel
  const cols = [];
  for (let x = 0; x < W.WIDTH; x++) {
    for (let y = 0; y < W.HEIGHT; y++) {
      const o = (y * W.WIDTH + x) * 3;
      if (short.rgb[o] | short.rgb[o + 1] | short.rgb[o + 2]) { cols.push(x); break; }
    }
  }
  // the 5x7 font advances a spacing column after every glyph including the last, so the lit
  // extent sits a column or two left of true centre. that is the font, not a placement bug
  const margin = Math.abs(cols[0] - (W.WIDTH - 1 - cols[cols.length - 1]));
  assert.ok(margin <= 2, `short text is not centred: margins differ by ${margin}`);

  const long = shown('a much longer notification that scrolls');
  assert.ok(long.cadenceMs > 0 && long.cadenceMs < 100, `scrolling text wants frames, got ${long.cadenceMs}`);
});

test('the brightness lut is the firmware level curve', () => {
  // the curve libzkgui.so applies: 0 stays 0, 1..255 land on 50..255. these are the values
  // runtime/src/panel/pack.zig asserts of itself, checked here through the wasm boundary
  const full = W.buildLut(100);
  assert.equal(full[0], 0);
  assert.equal(full[1], 50);
  assert.equal(full[128], 152);
  assert.equal(full[255], 255);
  for (let v = 1; v < 256; v++) assert.ok(full[v] >= full[v - 1], `the curve dips at ${v}`);

  const half = W.buildLut(50);
  assert.equal(half[0], 0, 'zero stays off at any brightness');
  // v * 50 / 100 is integer division, so 255 scales to 127, not 128
  assert.equal(half[255], full[127], 'half brightness is the curve of half the value');
  assert.deepEqual(W.buildLut(255), full, 'brightness is clamped to 100');
});