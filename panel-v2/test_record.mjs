/* tests for the transition recorder: frames come from the wasm at any rate, and go to apng. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { recordTransition, encodePng, writeApng } from './record-transitions.mjs';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const WASM = join(here, 'tc002-panel.wasm');
const W = require('./sim-wasm.js');
if (existsSync(WASM)) await W.ready(WASM);

const ffmpeg = (() => { try { execFileSync('ffmpeg', ['-version'], { stdio: 'ignore' }); return true; } catch { return false; } })();

test('a recording is the scene change at the asked rate, ending on the new scene', { skip: existsSync(WASM) ? false : 'wasm not built' }, () => {
  const r = recordTransition(W, { effect: 'fade', direction: 'left', easing: 'linear', durationMs: 500, holdMs: 100, fps: 60 });
  // hold, the effect, hold: 100 + 500 + 100 ms at 60 fps
  assert.equal(r.frames.length, Math.round(700 / 1000 * 60));
  assert.equal(r.frames[0].length, W.RGB_BYTES);
  const differs = (a, b) => a.some((v, i) => v !== b[i]);
  assert.ok(!differs(r.frames[0], r.frames[1]), 'the hold at the start is still');
  assert.ok(differs(r.frames[0], r.frames[r.frames.length - 1]), 'it ends on the other scene');
  const mid = r.frames[Math.round(r.frames.length / 2)];
  assert.ok(differs(mid, r.frames[0]) && differs(mid, r.frames[r.frames.length - 1]), 'the middle is the effect in flight');
  assert.equal(r.fps, 60);
});

test('a png is a png of the scaled panel', () => {
  const rgb = new Uint8Array(52 * 16 * 3).fill(0); rgb[0] = 255;
  const png = encodePng(rgb, 52, 16, 4);
  assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.equal(png.readUInt32BE(16), 52 * 4);
  assert.equal(png.readUInt32BE(20), 16 * 4);
});

test('an apng carries every frame at the exact rate', { skip: ffmpeg ? false : 'ffmpeg is not installed' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tc002-apng-'));
  try {
    const frames = [];
    for (let i = 0; i < 6; i++) { const f = new Uint8Array(52 * 16 * 3).fill(0); f[i * 3] = 200; frames.push(f); }
    const out = join(dir, 'x.png');
    writeApng(frames, 60, out, 2);
    const bytes = readFileSync(out);
    assert.deepEqual([...bytes.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10]);
    const actl = bytes.indexOf('acTL');
    assert.ok(actl > 0, 'an animation control chunk');
    assert.equal(bytes.readUInt32BE(actl + 4), 6, 'six frames');
    // the first frame control chunk says 1/60 s
    const fctl = bytes.indexOf('fcTL');
    assert.equal(bytes.readUInt16BE(fctl + 4 + 20), 1); assert.equal(bytes.readUInt16BE(fctl + 4 + 22), 60);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
