#!/usr/bin/env node
/* record every transition effect from the runtime's own renderer, compiled to wasm, into an
   animated png: pixel-exact frames at whatever rate is asked, no clock and no http in the loop.

     node panel-v2/record-transitions.mjs [--out DIR] [--fps 60] [--duration 800] [--hold 300]
                                          [--scale 6] [--only fade,slide] [--list]

   each file is one effect: the block clock face gives way, with the effect, to a canvas that is
   the effect's name in black on a white ground in the mini face, holds, and comes back with the
   paired effect the other way, which is how a notification leaves. the two scenes are chosen to
   be told apart at a glance halfway through any effect. `random`
   is not recorded, since it resolves to one of the others. the effect list is read out of the wasm,
   so a new effect in transition.zig is a new file here the next time this runs.

   apng rather than gif: a frame delay is a fraction, so 1/60 s is honoured, and every frame is a
   full-colour png. ffmpeg writes the file; `zig build wasm` in runtime/ makes the module. */
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { deflateSync } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

/* the same start instant as the wasm tests: a whole second, so the clock face holds still for
   the length of a recording that stays inside it, and a second boundary is a visible tick */
const T0 = Date.UTC(2026, 8, 6, 12, 34, 56);

const PAIRED = { swipe_in: 'swipe_out', swipe_out: 'swipe_in', split_in: 'split_out', split_out: 'split_in', expand: 'collapse', collapse: 'expand' };
const OPPOSITE = { left: 'right', right: 'left', up: 'down', down: 'up' };
export const naturalDirection = effect => (effect === 'rain' || effect === 'rain_random') ? 'down' : 'left';

/* the canvas an effect lands on: the effect's name in black on a white ground, the negative of the
   white-on-black clock, so the two scenes are unmistakable mid-effect. underscores read as spaces
   in the mini face. the canvas draws nothing for pure black (black is transparent there, as it is
   for sprites), so the ink is one step above it, which is black in a recording */
export const ground = 'ffffff';
export const ink = '010101';
export function nameCanvas(effect) {
  return { elements: [
    { type: 'rect', id: 'bg', at: [0, 0], size: [52, 16], colour: ground, filled: true },
    { type: 'text', id: 'name', at: [0, 5], size: [52, 5], font: 'mini', align: 'centre', colour: ink, text: effect.replace(/_/g, ' ') },
  ] };
}

/* frames of one effect: hold, the effect in, hold, the paired effect out, hold. `andBack: false`
   stops after the first hold. returns { frames, fps, width, height, label } */
export function recordTransition(W, { effect, direction = naturalDirection(effect), easing = 'linear', exit = 'reverse',
                                      durationMs = 800, holdMs = 300, fps = 60, andBack = false, from = 'clock', to = 'canvas', font = 'block' }) {
  const E = W.exports;
  const idx = (list, name, what) => { const i = list.indexOf(name); if (i < 0) throw new Error(`unknown ${what} ${name}`); return i; };
  const step = 1000 / fps;
  const frames = [];
  let t = T0;
  const run = ms => { for (let i = 0, n = Math.round(ms / step); i < n; i++) { E.frame(t, t); frames.push(W.frame().slice()); t += step; } };
  W.reset(from, 'popsquares', 1);
  // the face to show, and the named canvas to land on; a restyle would cross-fade, so drop that
  E.setClockStyle(idx(W.CLOCK_FONTS, font, 'font'), -1, -1, -1, -1, -1, -1, -1, t);
  E.dropTransition();
  const installed = W.installCanvas(nameCanvas(effect), t);
  if (!installed.ok) throw new Error(`the canvas for ${effect} was refused: ${installed.reason}`);
  E.runTransitions(1);
  try {
    run(holdMs);
    if (!E.setBaseWith(idx(W.BASES, to, 'base'), idx(W.TRANSITION_EFFECTS, effect, 'effect'), idx(W.TRANSITION_DIRECTIONS, direction, 'direction'),
                       idx(W.TRANSITION_EASINGS, easing, 'easing'), durationMs, idx(W.TRANSITION_EXITS, exit, 'exit'), t)) throw new Error(`the arbiter refused ${effect}`);
    run(durationMs + holdMs);
    if (andBack) {
      const back = PAIRED[effect] || effect, backDir = OPPOSITE[direction] || direction;
      E.setBaseWith(idx(W.BASES, from, 'base'), idx(W.TRANSITION_EFFECTS, back, 'effect'), idx(W.TRANSITION_DIRECTIONS, backDir, 'direction'),
                    idx(W.TRANSITION_EASINGS, easing, 'easing'), durationMs, idx(W.TRANSITION_EXITS, exit, 'exit'), t);
      run(durationMs + holdMs);
    }
  } finally { E.runTransitions(0); }
  return { frames, fps, width: W.WIDTH, height: W.HEIGHT, label: effect };
}

/* a plain png of the panel, each pixel a `scale` square, 8-bit rgb, no dependencies */
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
const crc32 = buf => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (type, data) => {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
};
export function encodePng(rgb, width, height, scale = 1) {
  const w = width * scale, h = height * scale;
  const raw = Buffer.alloc((1 + w * 3) * h);
  for (let y = 0; y < h; y++) {
    const row = y * (1 + w * 3); raw[row] = 0;
    const sy = Math.floor(y / scale);
    for (let x = 0; x < w; x++) {
      const s = (sy * width + Math.floor(x / scale)) * 3, d = row + 1 + x * 3;
      raw[d] = rgb[s]; raw[d + 1] = rgb[s + 1]; raw[d + 2] = rgb[s + 2];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

/* the frames as an apng that loops for ever, through ffmpeg; each frame delay is exactly 1/fps */
export function writeApng(frames, fps, path, scale = 6, width = 52, height = 16) {
  const dir = mkdtempSync(join(tmpdir(), 'tc002-apng-'));
  try {
    frames.forEach((f, i) => writeFileSync(join(dir, `f${String(i).padStart(4, '0')}.png`), encodePng(f, width, height, scale)));
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(dir, 'f%04d.png'), '-plays', '0', '-f', 'apng', path], { stdio: 'inherit' });
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

async function main(argv) {
  const opt = { out: resolve(here, '../runtime/screenshots/transitions'), fps: 60, duration: 800, hold: 300, scale: 6, only: null, list: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--list') opt.list = true;
    else if (a.startsWith('--') && i + 1 < argv.length) { const k = a.slice(2); opt[k] = k === 'only' ? argv[++i].split(',') : k === 'out' ? resolve(argv[++i]) : Number(argv[++i]); }
    else { console.error('usage: record-transitions.mjs [--out DIR] [--fps N] [--duration MS] [--hold MS] [--scale N] [--only a,b] [--list]'); process.exit(2); }
  }
  const W = require('./sim-wasm.js');
  await W.ready(join(here, 'tc002-panel.wasm'));
  const effects = W.TRANSITION_EFFECTS.filter(e => e !== 'random' && (!opt.only || opt.only.includes(e)));
  if (opt.list) { console.log(effects.join('\n')); return; }
  mkdirSync(opt.out, { recursive: true });
  for (const effect of effects) {
    const r = recordTransition(W, { effect, durationMs: opt.duration, holdMs: opt.hold, fps: opt.fps, andBack: true });
    const path = join(opt.out, `${effect}.png`);
    writeApng(r.frames, r.fps, path, opt.scale, r.width, r.height);
    console.log(`${effect}: ${r.frames.length} frames at ${r.fps} fps -> ${path}`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2)).catch(e => { console.error(e.message); process.exit(1); });
