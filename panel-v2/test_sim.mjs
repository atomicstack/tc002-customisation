import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const S = createRequire(import.meta.url)('./sim.js');

test('every printable character has a glyph and space is empty', () => {
  for (let c = 0x20; c <= 0x7e; c++) {
    const g = S.glyph(c);
    assert.equal(g.length, 7);
    let any = false;
    for (const row of g) { assert.equal(row & 0xe0, 0); any = any || row !== 0; }
    if (c === 0x20) assert.equal(any, false); else assert.equal(any, true);
  }
});

test('lowercase differs from uppercase and non-printables map to the question mark', () => {
  for (let c = 97; c <= 122; c++) assert.notDeepEqual(S.glyph(c), S.glyph(c - 32));
  assert.deepEqual(S.glyph(1), S.glyph(63));
  assert.deepEqual(S.glyph(255), S.glyph(63));
});

test('known glyph rows', () => {
  assert.equal(S.glyph(65)[3], 0b11111);   // A
  assert.equal(S.glyph(49)[6], 0b01110);   // 1
  assert.equal(S.glyph(63)[6], 0b00100);   // ?
  assert.equal(S.glyph(103)[6], 0b01110);  // g
});

test('text width counts advances without a trailing gap', () => {
  assert.equal(S.textWidth(''), 0);
  assert.equal(S.textWidth('a'), 5);
  assert.equal(S.textWidth('ab'), 11);
  assert.equal(S.textWidth('13:05:09'), 47);
});

test('blit clips at every edge and lights something inside', () => {
  const rgb = S.black();
  S.blit(rgb, -3, -2, 'hi', [255, 0, 0]);
  S.blit(rgb, 49, 13, 'xy', [0, 255, 0]);
  S.blit(rgb, 200, 200, 'far', [0, 0, 255]);
  assert.notDeepEqual(rgb, S.black());
  let lit = false;
  for (let y = 0; y < 5; y++) lit = lit || rgb[S.pixelOffset(5, y)] !== 0;
  assert.equal(lit, true);
});

test('remap follows the firmware curve and the lut scales before it', () => {
  assert.equal(S.remap(0), 0);
  assert.equal(S.remap(1), 50);
  assert.equal(S.remap(255), 255);
  assert.equal(S.remap(128), 152);
  const lut = S.buildLut(50);
  assert.equal(lut[200], S.remap(100));
  assert.equal(lut[0], 0);
  assert.equal(S.buildLut(255)[255], 255);
});

test('tz: a bare utc rule has no dst', () => {
  const r = S.tzParse('UTC0');
  assert.equal(r.stdOffset, 0);
  assert.equal(r.dst, null);
  assert.equal(S.localFromUtc(r, 123), 123);
});

test('tz: fixed positive offsets with a name', () => {
  assert.equal(S.tzParse('JST-9').stdOffset, 9 * 3600);
  assert.equal(S.tzParse('IST-5:30').stdOffset, 5 * 3600 + 30 * 60);
});

test('tz: sydney, southern hemisphere dst with an end-of-rule time', () => {
  const r = S.tzParse('AEST-10AEDT,M10.1.0,M4.1.0/3');
  assert.equal(r.stdOffset, 10 * 3600);
  assert.equal(r.dst.offset, 11 * 3600);
  assert.equal(S.localFromUtc(r, 1768435200), 1768435200 + 11 * 3600);
  assert.equal(S.localFromUtc(r, 1784073600), 1784073600 + 10 * 3600);
  assert.equal(S.utcOffsetAt(r, 1791043199), 10 * 3600);
  assert.equal(S.utcOffsetAt(r, 1791043200), 11 * 3600);
  assert.equal(S.utcOffsetAt(r, 1775318399), 11 * 3600);
  assert.equal(S.utcOffsetAt(r, 1775318400), 10 * 3600);
});

test('tz: new york, default dst offset and default 02:00 time', () => {
  const r = S.tzParse('EST5EDT,M3.2.0,M11.1.0');
  assert.equal(r.stdOffset, -5 * 3600);
  assert.equal(r.dst.offset, -4 * 3600);
  assert.equal(S.localFromUtc(r, 1782864000), 1782864000 - 4 * 3600);
  assert.equal(S.utcOffsetAt(r, 20520 * 86400 + 7 * 3600 - 1), -5 * 3600);
  assert.equal(S.utcOffsetAt(r, 20520 * 86400 + 7 * 3600), -4 * 3600);
});

test('tz: malformed rules are rejected', () => {
  for (const bad of ['', 'A1', 'AEST-10AEDT', 'AEST-10AEDT,M13.1.0,M4.1.0', 'AEST-30', 'AEST-10,M10.1.0,M4.1.0'])
    assert.throws(() => S.tzParse(bad), /invalid tz rule/);
});

test('tz: civil date helpers round trip', () => {
  assert.equal(S.daysFromCivil(2026, 1, 1), 20454);
  assert.deepEqual(S.civilFromDays(20454 + 275), { year: 2026, month: 10, day: 3 });
  assert.equal(S.weekday(20454), 4);
});

test('clock: time of day formats as hh:mm:ss in local time', () => {
  assert.equal(S.formatTime(13 * 3600 + 5 * 60 + 9), '13:05:09');
  assert.equal(S.formatTime(86400 * 3), '00:00:00');
  assert.equal(S.formatTime(-1), '23:59:59');
  assert.equal(S.nextSecondMs(1500), 2000);
  assert.equal(S.nextSecondMs(2000), 3000);
});

test('clock: render equals a direct blit of the formatted local time', () => {
  const rule = S.tzParse('JST-9');
  const wallMs = (4 * 3600 + 5 * 60 + 6) * 1000 + 700;
  const rgb = S.black();
  S.renderClock(rgb, wallMs, rule);
  const expected = S.black();
  S.blit(expected, S.CLOCK_X, S.CLOCK_Y, '13:05:06', S.WHITE);
  assert.deepEqual(rgb, expected);
});

test('ip: no address renders the no ip text, an address renders on two centred lines', () => {
  const none = S.black();
  S.renderIp(none, null);
  const e1 = S.black();
  S.blit(e1, 11, 4, 'no ip', S.WHITE);
  assert.deepEqual(none, e1);
  const some = S.black();
  S.renderIp(some, S.ipFromString('10.0.0.111'));
  const e2 = S.black();
  S.blit(e2, 11, 0, '10.0.', S.WHITE);
  S.blit(e2, 11, 8, '0.111', S.WHITE);
  assert.deepEqual(some, e2);
  assert.equal(S.ipFromString('10.0.0'), null);
  assert.equal(S.ipFromString('256.0.0.1'), null);
  assert.equal(S.ipFromString(null), null);
});

test('notify: short text is centred, long text scrolls one pixel per period', () => {
  const rgb = S.black();
  S.renderNotify(rgb, 'hi', S.WHITE, 0);
  const expected = S.black();
  S.blit(expected, 20, 4, 'hi', S.WHITE);
  assert.deepEqual(rgb, expected);
  const long = 'this text is far wider than the panel';
  const a = S.black(), b = S.black();
  S.renderNotify(a, long, S.WHITE, 0);
  S.renderNotify(b, long, S.WHITE, 10 * S.SCROLL_MS + 1);
  assert.notDeepEqual(a, b);
  const e = S.black();
  S.blit(e, S.WIDTH - 10, 4, long, S.WHITE);
  assert.deepEqual(b, e);
});

test('rng is deterministic and never returns zero for a zero seed', () => {
  const a = new S.Rng(0), b = new S.Rng(0);
  assert.equal(a.next(), b.next());
  assert.notEqual(a.state, 0);
  const u = new S.Rng(42).unit();
  assert.ok(u >= 0 && u < 1);
});

test('popsquares: same seed same bytes, cells re-arm, no alive cells is black, long pauses are clamped', () => {
  const a = new S.Popsquares(1), b = new S.Popsquares(1);
  const ra = S.black(), rb = S.black();
  a.render(ra); b.render(rb);
  assert.deepEqual(ra, rb);
  const s = new S.Popsquares(3);
  let rose = false;
  for (let i = 0; i < 40; i++) {
    const before = Float32Array.from(s.level);
    s.step(0.5);
    for (let j = 0; j < before.length; j++) if (s.level[j] > before[j]) rose = true;
  }
  assert.equal(rose, true);
  const dead = new S.Popsquares(5, { alive: 0 });
  dead.step(0.01);
  const rgb = S.black();
  dead.render(rgb);
  assert.deepEqual(rgb, S.black());
  const p = new S.Popsquares(7), q = new S.Popsquares(7);
  p.step(10); q.step(0.5);
  assert.deepEqual(p.level, q.level);
});

test('plasma: same seed same bytes, different seeds differ, stepping changes the frame', () => {
  const ra = S.black(), rb = S.black(), rc = S.black();
  new S.Plasma(4).render(ra); new S.Plasma(4).render(rb); new S.Plasma(5).render(rc);
  assert.deepEqual(ra, rb);
  assert.notDeepEqual(ra, rc);
  const s = new S.Plasma(1);
  const before = S.black(), after = S.black();
  s.render(before);
  assert.notDeepEqual(before, S.black());
  s.step(0.1);
  s.render(after);
  assert.notDeepEqual(before, after);
});

test('art: selecting plasma renders what a fresh plasma renders; reseeding changes popsquares', () => {
  const art = new S.Art('popsquares', 9);
  art.select('plasma');
  art.step(0.1);
  const fromArt = S.black(), direct = S.black();
  art.render(fromArt);
  const p = new S.Plasma(9); p.step(0.1); p.render(direct);
  assert.deepEqual(fromArt, direct);
  const a2 = new S.Art('popsquares', 1);
  const x = S.black(), y = S.black();
  a2.render(x); a2.reseed(2); a2.render(y);
  assert.notDeepEqual(x, y);
});

test('compose picks the right layer and cadence', () => {
  const base = { base: 'clock', generator: 'popsquares', overlay: 'none', brightness: 100, ip: '10.0.0.5' };
  const local = { art: new S.Art('popsquares', 1), tz: S.tzParse('JST-9'), notify: null, frame: null, pending: null };
  const wallMs = (4 * 3600 + 5 * 60 + 6) * 1000 + 700;
  const clock = S.compose(base, local, wallMs);
  const expected = S.black();
  S.blit(expected, S.CLOCK_X, S.CLOCK_Y, '13:05:06', S.WHITE);
  assert.deepEqual(clock.rgb, expected);
  assert.equal(clock.cadenceMs, 300);
  assert.equal(clock.label, 'clock');

  const ip = S.compose({ ...base, base: 'ip' }, local, 0);
  const e2 = S.black(); S.blit(e2, 11, 0, '10.0.', S.WHITE); S.blit(e2, 17, 8, '0.5', S.WHITE); // both lines centred
  assert.deepEqual(ip.rgb, e2);
  assert.equal(ip.cadenceMs, null);

  const ipFromNetwork = S.compose({ ...base, base: 'ip', ip: undefined, network: { ip: '10.0.0.5' } }, local, 0);
  assert.deepEqual(ipFromNetwork.rgb, e2);

  const art = S.compose({ ...base, base: 'art', generator: 'plasma' }, local, 0);
  assert.notDeepEqual(art.rgb, S.black());
  assert.equal(art.cadenceMs, 1000 / 60);
  assert.match(art.label, /local seed/);

  const n = S.compose({ ...base, overlay: 'notify' }, { ...local, notify: { text: 'hi', colour: [1, 2, 3], sinceMs: 0 } }, 100);
  const e3 = S.black(); S.blit(e3, 20, 4, 'hi', [1, 2, 3]);
  assert.deepEqual(n.rgb, e3);
  assert.equal(n.cadenceMs, null);
  const unknownN = S.compose({ ...base, overlay: 'notify' }, local, 100);
  assert.match(unknownN.label, /unknown/);

  const frame = new Uint8Array(S.RGB_BYTES).fill(9);
  const f = S.compose({ ...base, overlay: 'frame' }, { ...local, frame }, 0);
  assert.deepEqual(f.rgb, frame);
  const pend = new Uint8Array(S.RGB_BYTES).fill(7);
  const pdg = S.compose(base, { ...local, pending: pend }, 0);
  assert.deepEqual(pdg.rgb, pend);
  assert.equal(pdg.label, 'pending frame');
});

/* ---------- clock fonts and colour styles (clockfont.zig, clock.zig) ---------- */
const CLOCK_DEFAULT = { font: 'classic', colour_mode: 'solid', colour: 'ffffff', colour2: 'ffffff', gradient: 'horizontal' };
// 2026-09-06 18:08:08 utc, as the zig fixtures use it
const WALL_180808_MS = (1788739200 + 18 * 3600 + 8 * 60 + 8) * 1000;
function litBox(rgb) {
  const b = { x0: S.WIDTH, y0: S.HEIGHT, x1: -1, y1: -1 };
  for (let y = 0; y < S.HEIGHT; y++) for (let x = 0; x < S.WIDTH; x++) {
    const o = S.pixelOffset(x, y);
    if (rgb[o] || rgb[o + 1] || rgb[o + 2]) { b.x0 = Math.min(b.x0, x); b.x1 = Math.max(b.x1, x); b.y0 = Math.min(b.y0, y); b.y1 = Math.max(b.y1, y); }
  }
  return b;
}
const px = (rgb, x, y) => [...rgb.slice(S.pixelOffset(x, y), S.pixelOffset(x, y) + 3)];

test('clock fonts: text widths match the layouts the clock relies on', () => {
  assert.deepEqual(S.CLOCK_FONTS, ['classic', 'mini', 'segment', 'big']);
  assert.equal(S.clockTextWidth('classic', '13:05:09'), 47);
  assert.equal(S.clockTextWidth('segment', '13:05:09'), 39);
  assert.equal(S.clockTextWidth('mini', '13:05:09'), 27);
  assert.equal(S.clockTextWidth('mini', '07/09'), 19);
  assert.equal(S.clockTextWidth('big', '13:05'), 52);
  assert.equal(S.clockTextWidth('big', ''), 0);
  for (const f of S.CLOCK_FONTS) assert.equal(S.clockGlyph(f, '0'.charCodeAt(0)).h, { classic: 7, mini: 5, segment: 9, big: 14 }[f]);
});

test('clock fonts: big is the classic digit scaled by two and segment digits are the expected shapes', () => {
  const one = S.glyph(49), bigOne = S.clockGlyph('big', 49);
  assert.equal(bigOne.w, 10); assert.equal(bigOne.h, 14);
  for (let r = 0; r < 7; r++) {
    let expected = 0;
    for (let col = 0; col < 5; col++) if ((one[r] >> (4 - col)) & 1) expected |= 0b11 << (8 - col * 2);
    assert.equal(bigOne.rows[2 * r], expected); assert.equal(bigOne.rows[2 * r + 1], expected);
  }
  const eight = S.clockGlyph('segment', 56);
  assert.equal(eight.rows[0], 0b01110); assert.equal(eight.rows[1], 0b10001); assert.equal(eight.rows[4], 0b01110); assert.equal(eight.rows[8], 0b01110);
  const seven = S.clockGlyph('segment', 55);
  assert.equal(seven.rows[6], 0b00001); assert.equal(seven.rows[8], 0);
  for (const f of S.CLOCK_FONTS) for (let d = 48; d <= 57; d++) for (let e = 48; e < d; e++) assert.notDeepEqual(S.clockGlyph(f, d).rows, S.clockGlyph(f, e).rows);
});

test('clock: the date formats as dd/mm and the classic solid render equals a direct blit', () => {
  assert.equal(S.formatDate(1788739200), '07/09');
  assert.equal(S.formatDate(0), '01/01');
  const rule = S.tzParse('JST-9');
  const rgb = S.black();
  S.renderClock(rgb, (4 * 3600 + 5 * 60 + 6) * 1000 + 700, rule, CLOCK_DEFAULT);
  const expected = S.black();
  S.blit(expected, 2, 4, '13:05:06', S.WHITE);
  assert.deepEqual(rgb, expected);
  const legacy = S.black();
  S.renderClock(legacy, (4 * 3600 + 5 * 60 + 6) * 1000 + 700, rule);   // no style = the classic defaults
  assert.deepEqual(legacy, expected);
});

test('clock: every font renders centred within its box; big drops the seconds; mini adds the date', () => {
  const rgb = S.black();
  S.renderClock(rgb, WALL_180808_MS, S.TZ_UTC, { ...CLOCK_DEFAULT, font: 'segment' });
  assert.deepEqual(litBox(rgb), { x0: 10, y0: 3, x1: 44, y1: 11 });
  S.renderClock(rgb, WALL_180808_MS, S.TZ_UTC, { ...CLOCK_DEFAULT, font: 'big' });
  assert.deepEqual(litBox(rgb), { x0: 2, y0: 1, x1: 51, y1: 14 });
  S.renderClock(rgb, WALL_180808_MS, S.TZ_UTC, { ...CLOCK_DEFAULT, font: 'mini' });
  assert.deepEqual(litBox(rgb), { x0: 12, y0: 2, x1: 38, y1: 13 });
  assert.notEqual(rgb[S.pixelOffset(16 + 3 + 1 + 3 + 1 + 2, 9)], 0);   // the slash of "06/09" on the date line
});

test('clock: a gradient runs from the start colour to the clamped end colour across the text', () => {
  assert.equal(S.CLOCK_MAX_SPREAD, 96);
  const style = { font: 'segment', colour_mode: 'gradient', colour: 'c80000', colour2: '00ff00', gradient: 'horizontal' };
  assert.deepEqual(S.effectiveColour2(style), [104, 96, 0]);
  const wall = (8 * 3600 + 8 * 60 + 8) * 1000;
  const rgb = S.black();
  S.renderClock(rgb, wall, S.TZ_UTC, style);
  assert.deepEqual(px(rgb, 6, 4), [200, 0, 0]);
  const right = px(rgb, 44, 4);
  assert.ok(right[0] < 120 && right[1] > 80, `right ${right}`);
  S.renderClock(rgb, wall, S.TZ_UTC, { ...style, gradient: 'vertical' });
  assert.deepEqual(px(rgb, 7, 3), [200, 0, 0]);
  assert.ok(px(rgb, 7, 11)[1] > 80);
  S.renderClock(rgb, wall, S.TZ_UTC, { ...style, colour_mode: 'solid' });
  assert.deepEqual(px(rgb, 44, 4), [200, 0, 0]);
});

test('compose: the clock takes its style from status.clock and falls back to the classic defaults', () => {
  const local = { tz: S.TZ_UTC, art: null, notify: null, frame: null, pending: null };
  const styled = S.compose({ base: 'clock', overlay: 'none', generator: 'popsquares', clock: { ...CLOCK_DEFAULT, font: 'big', colour: '2060ff' } }, local, WALL_180808_MS);
  const expected = S.black();
  S.renderClock(expected, WALL_180808_MS, S.TZ_UTC, { ...CLOCK_DEFAULT, font: 'big', colour: '2060ff' });
  assert.deepEqual(styled.rgb, expected);
  assert.equal(styled.label, 'clock · big · solid');
  assert.deepEqual(px(styled.rgb, 2, 14), [0x20, 0x60, 0xff]);   // the foot of the big "1" at column 2
  const plain = S.compose({ base: 'clock', overlay: 'none', generator: 'popsquares' }, local, WALL_180808_MS);
  const classic = S.black();
  S.renderClock(classic, WALL_180808_MS, S.TZ_UTC);
  assert.deepEqual(plain.rgb, classic);
  assert.equal(plain.label, 'clock');
});
