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

test('ip: no address renders the no ip text, an address renders on two lines', () => {
  const none = S.black();
  S.renderIp(none, null);
  const e1 = S.black();
  S.blit(e1, 11, 4, 'no ip', S.WHITE);
  assert.deepEqual(none, e1);
  const some = S.black();
  S.renderIp(some, S.ipFromString('10.0.0.111'));
  const e2 = S.black();
  S.blit(e2, 1, 0, '10.0.', S.WHITE);
  S.blit(e2, 1, 8, '0.111', S.WHITE);
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
