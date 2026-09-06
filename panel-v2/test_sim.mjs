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
