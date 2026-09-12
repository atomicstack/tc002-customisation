/* tc002 preview, backed by the device's own renderer.
   loads tc002-panel.wasm — runtime/src/scene compiled to wasm32-freestanding — and drives the real
   scene.Arbiter from a /status document, so the console draws the pixels the device draws and there
   is no second implementation to keep in sync. this file holds no pixel decisions of its own: it
   maps /status into arbiter commands and copies bytes out. loads in a browser as window.TC002Sim
   and under node as a commonjs module; the wasm is fetched, so call `await TC002Sim.ready(url)`
   before the first compose. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.TC002Sim = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const WIDTH = 52, HEIGHT = 16, PIXELS = WIDTH * HEIGHT, RGB_BYTES = PIXELS * 3;
  const WHITE = [255, 255, 255];
  const black = () => new Uint8Array(RGB_BYTES);
  const pixelOffset = (x, y) => (y * WIDTH + x) * 3;

  /* the tz rule is opaque to this file: the wasm parses and holds it, we only carry the text so
     compose can tell one rule from another and re-apply it when it changes. */
  const TZ_UTC = { text: 'UTC0', stdOffset: 0 };

  let E = null;           // wasm exports, once ready
  let readyPromise = null;
  /* every enum name comes from the wasm, so a new font or generator needs no edit here */
  let BASES = [], GENERATORS = [], CLOCK_FONTS = [], CLOCK_MODES = [],
      GRADIENTS = [], DIGIT_STYLES = [], IP_MODES = [];
  let CLOCK_MAX_SPREAD = 255, NOTIFY_MAX_S = 300;
  const DEFAULT_CLOCK_STYLE = { font: 'classic', colour_mode: 'solid', colour: 'ffffff', colour2: 'ffffff', gradient: 'horizontal' };

  function bytes(ptr, len) { return new Uint8Array(E.memory.buffer, ptr, len); }
  function readScratch(len) { return new TextDecoder().decode(bytes(E.scratchPtr(), len)); }
  function writeScratch(text) {
    const b = new TextEncoder().encode(text);
    const n = Math.min(b.length, E.scratchLen());
    bytes(E.scratchPtr(), n).set(b.subarray(0, n));
    return n;
  }
  const names = fn => readScratch(fn()).split(',');

  async function ready(url) {
    if (readyPromise) return readyPromise;
    readyPromise = (async () => {
      const src = url || 'tc002-panel.wasm';
      // in a browser the server sends application/wasm and streaming compiles as it arrives;
      // under node (the parity tests) there is no fetch of a local path, so read the file
      const mod = typeof window === 'undefined'
        ? await WebAssembly.instantiate(require('node:fs').readFileSync(src), {})
        : await WebAssembly.instantiateStreaming(fetch(src), {});
      E = mod.instance.exports;
      BASES = names(E.baseNames);
      GENERATORS = names(E.generatorNames);
      CLOCK_FONTS = names(E.clockFontNames);
      CLOCK_MODES = names(E.clockModeNames);
      GRADIENTS = names(E.gradientNames);
      DIGIT_STYLES = names(E.digitStyleNames);
      IP_MODES = names(E.ipModeNames);
      CLOCK_MAX_SPREAD = E.clockDefaultSpread();
      NOTIFY_MAX_S = E.notifyMaxSeconds();
      E.init(0, 0, 1);
      return api;
    })();
    return readyPromise;
  }
  const loaded = () => E !== null;
  function need() { if (!E) throw new Error('tc002-panel.wasm is not loaded yet: await TC002Sim.ready()'); return E; }

  /* ---------- the pieces index.html uses directly ---------- */

  function buildLut(brightness) {
    need().buildLut(brightness);
    return bytes(E.lutPtr(), 256).slice();
  }

  function tzParse(text) {
    const e = need();
    const offset = e.setTz(writeScratch(String(text == null ? '' : text)));
    if (!e.tzOk()) throw new Error('invalid tz rule');
    applied.tz = String(text); // setTz already installed it; keep the mirror honest
    return { text: String(text), stdOffset: offset };
  }

  /* the console constructs one of these when the generator changes and steps it every frame;
     the arbiter owns the animation now, so this only carries the choice and the seed. */
  function Art(generator, seed) {
    this.generator = generator;
    this.seed = seed >>> 0;
    this.step = function () {};   // the arbiter advances on tick
    this.render = function (rgb) { rgb.set(frameBytes()); };
  }

  function frameBytes() { return bytes(E.framePtr(), E.frameLen()); }

  /* ---------- /status -> arbiter commands ---------- */

  /* what we last pushed in, so each poll issues only the commands that actually changed */
  const applied = { base: null, generator: null, seed: null, tz: null, clock: null, ipMode: null, ip: null, notify: null, canvas: null };
  let lastCanvasResult = { ok: true };

  /* the panel's clock is the device's, not this browser's. every response carries a Date header,
     which is whole seconds — the same resolution the clock scene redraws at — so anchoring to it
     is enough to put the previewed time on the panel's second rather than the laptop's. */
  let clockSkewMs = 0;
  function anchorClock(dateHeader, receivedAtMs) {
    const t = Date.parse(dateHeader || '');
    if (!Number.isFinite(t)) return false;
    clockSkewMs = t - (receivedAtMs == null ? Date.now() : receivedAtMs);
    return true;
  }
  const deviceNow = (nowMs) => (nowMs == null ? Date.now() : nowMs) + clockSkewMs;

  const hexInt = (s, fallback) => {
    const m = /^#?([0-9a-fA-F]{6})$/.exec(String(s == null ? '' : s));
    return m ? parseInt(m[1], 16) : fallback;
  };
  const indexOf = (list, v, fallback) => { const i = list.indexOf(v); return i < 0 ? fallback : i; };

  function ipOctets(v) {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(v == null ? '' : v));
    if (!m) return null;
    const o = m.slice(1, 5).map(Number);
    return o.every(n => n <= 255) ? o : null;
  }

  function applyStatus(status, local, nowMs) {
    const e = need();
    const s = status || {};

    const tzText = (local && local.tz && local.tz.text) || TZ_UTC.text;
    if (tzText !== applied.tz) { e.setTz(writeScratch(tzText)); applied.tz = tzText; }

    const base = indexOf(BASES, s.base, 0);
    if (base !== applied.base) { e.setBase(base, nowMs); applied.base = base; }

    const gen = indexOf(GENERATORS, s.generator, 0);
    if (gen !== applied.generator) { e.setGenerator(gen, nowMs); applied.generator = gen; }
    // the device publishes its art seed, so the preview runs the panel's animation rather than a
    // lookalike. a runtime too old to report one falls back to the page's own seed
    const seed = typeof s.seed === 'number' ? s.seed >>> 0
               : (local && local.art ? local.art.seed : null);
    if (seed !== null && seed !== applied.seed) { e.reseed(seed, nowMs); applied.seed = seed; }

    const c = s.clock || null;
    const key = c ? JSON.stringify(c) : null;
    if (key !== applied.clock) {
      if (c) {
        e.setClockStyle(
          indexOf(CLOCK_FONTS, c.font, 0),
          indexOf(CLOCK_MODES, c.colour_mode, 0),
          indexOf(GRADIENTS, c.gradient, 0),
          c.spread == null ? -1 : c.spread,
          indexOf(DIGIT_STYLES, c.digit, -1),
          hexInt(c.colour, 0xffffff),
          hexInt(c.colour2, 0xffffff),
          nowMs);
      }
      applied.clock = key;
    }

    if (s.ip_mode != null) {
      const m = indexOf(IP_MODES, s.ip_mode, 0);
      if (m !== applied.ipMode) { e.setIpMode(m, nowMs); applied.ipMode = m; }
    }

    const addr = ipOctets(s.network && s.network.ip != null ? s.network.ip : s.ip);
    const addrKey = addr ? addr.join('.') : '';
    if (addrKey !== applied.ip) {
      if (addr) e.setIp(1, addr[0], addr[1], addr[2], addr[3], nowMs);
      else e.setIp(0, 0, 0, 0, 0, nowMs);
      applied.ip = addrKey;
    }

    /* the canvas document, as the page last read it from GET /canvas */
    const canvasKey = local && local.canvas ? JSON.stringify(local.canvas) : null;
    if (canvasKey !== applied.canvas) {
      if (canvasKey) lastCanvasResult = installCanvas(canvasKey, nowMs);
      else { e.clearCanvas(nowMs); lastCanvasResult = { ok: true }; }
      applied.canvas = canvasKey;
    }

    /* a notification the console itself sent: the arbiter scrolls it and times it out */
    const n = s.overlay === 'notify' && local && local.notify ? local.notify : null;
    const nKey = n ? `${n.sinceMs}:${n.text}` : null;
    if (nKey !== applied.notify) {
      if (n) {
        const colour = Array.isArray(n.colour)
          ? (n.colour[0] << 16) | (n.colour[1] << 8) | n.colour[2]
          : hexInt(n.colour, 0xffffff);
        // /status does not say how much of the notification is left, so ask for the longest
        // the arbiter accepts and let it expire on its own clock
        e.notify(writeScratch(n.text), colour, NOTIFY_MAX_S, n.sinceMs);
      }
      applied.notify = nKey;
    }
  }

  function label(status, local) {
    const s = status || {};
    if (local && local.pending) return 'pending frame';
    if (s.overlay === 'frame') return local && local.frame ? 'frame' : 'frame (contents unknown: not sent from this page)';
    if (s.overlay === 'notify') return local && local.notify ? 'notification' : 'notification (text unknown: not sent from this page)';
    // switch on the base with a default: the set of bases is the runtime's enum, not a list this
    // file knows. a base it has never heard of captions as itself rather than as art
    if (s.base === 'clock') {
      const c = s.clock;
      return c ? `clock · ${c.font || 'classic'} · ${c.colour_mode || 'solid'}` : 'clock';
    }
    if (s.base === 'canvas') {
      if (!lastCanvasResult.ok) return `canvas · the runtime refuses this document (${lastCanvasResult.reason})`;
      return canvasEmpty() ? 'canvas · empty' : 'canvas';
    }
    if (s.base === 'art') {
      // the seed used to be the page's own, so the preview could only claim the algorithm
      return typeof s.seed === 'number'
        ? `art: ${s.generator}, seed ${s.seed >>> 0} from the device`
        : `art: ${s.generator}, same algorithm, local seed`;
    }
    return s.base ? String(s.base) : 'unknown base';
  }

  /* the console's entry point: a /status document plus what only this page knows, in; one frame,
     a redraw delay and a caption, out. every pixel comes from the wasm. */
  function compose(status, local, nowMs) {
    const e = need();
    const l = local || {};
    if (l.pending) return { rgb: l.pending.slice(), cadenceMs: null, label: 'pending frame' };
    if ((status || {}).overlay === 'frame') {
      if (l.frame) return { rgb: l.frame.slice(), cadenceMs: null, label: 'frame' };
      const rgb = black(); rgb.fill(24);
      return { rgb, cadenceMs: null, label: 'frame (contents unknown: not sent from this page)' };
    }
    applyStatus(status, l, nowMs);
    // two clocks: the browser's elapsed time advances the animation, the device's decides what
    // the clock scene reads. passing one for both made the panel's time the laptop's time
    const cadence = e.frame(nowMs, deviceNow(nowMs));
    return { rgb: frameBytes().slice(), cadenceMs: cadence < 0 ? null : cadence, label: label(status, l) };
  }

  /* ---------- the ip layouts, without a base ----------
     `ip` is leaving the base scenes for a page of the device menu, but ip.State and its four
     layouts stay where they are. previewing a layout never needed a base, so this asks the scene
     directly and keeps working across that change. */
  function renderIpLayout(mode, ip, nowMs, colour) {
    const e = need();
    const i = typeof mode === 'number' ? mode : IP_MODES.indexOf(mode);
    const o = ipOctets(ip);
    const c = colour == null ? -1 : (Array.isArray(colour) ? (colour[0] << 16) | (colour[1] << 8) | colour[2] : colour);
    const ok = e.renderIpLayout(i, o ? 1 : 0, o ? o[0] : 0, o ? o[1] : 0, o ? o[2] : 0, o ? o[3] : 0, c, nowMs || 0);
    if (!ok) throw new Error(`no such ip layout: ${mode}`);
    const cadence = e.ipLayoutCadenceMs(i);
    return { rgb: frameBytes().slice(), cadenceMs: cadence < 0 ? null : cadence };
  }

  /* ---------- the canvas ----------
     the canvas's content is not in /status: an integration PUTs a document and the panel draws
     it. the console fetches GET /canvas and hands the bytes to the runtime's own parser, so the
     document model lives in one place, on the device's terms. */
  function installCanvas(doc, nowMs) {
    const e = need();
    const text = typeof doc === 'string' ? doc : JSON.stringify(doc);
    if (e.installCanvas(writeScratch(text), nowMs || 0)) return { ok: true };
    const len = e.canvasRejectReason();
    return { ok: false, reason: len ? readScratch(len) : 'the document was refused' };
  }
  const clearCanvas = nowMs => need().clearCanvas(nowMs || 0);
  const canvasEmpty = () => need().canvasEmpty() !== 0;

  /* ---------- agreement: the shadow, checked against the device ----------
     /screen returns the frame the panel is actually showing. rather than displaying it instead of
     the simulation, compare the two: a shadow you can watch agreeing is worth more than a picture
     you have to trust, and the figure says at a glance whether the preview can be believed. */
  function agreement(deviceRgb, simRgb) {
    if (!deviceRgb || !simRgb || deviceRgb.length !== simRgb.length) return null;
    let same = 0, deviceLit = 0, simLit = 0;
    for (let i = 0; i < deviceRgb.length; i++) {
      if (deviceRgb[i] === simRgb[i]) same++;
      if (deviceRgb[i]) deviceLit++;
      if (simRgb[i]) simLit++;
    }
    return {
      exact: same === deviceRgb.length,
      fraction: same / deviceRgb.length,
      bytesDiffering: deviceRgb.length - same,
      deviceLit,
      simLit,
    };
  }

  /* ---------- scene parameters, straight from the arbiter's own tables ---------- */
  function sceneParams() {
    const e = need();
    const out = [];
    for (let i = 0; i < e.sceneParamCount(); i++) {
      const [name, kind, min, max, step, def] = readScratch(e.sceneParamInfo(i)).split(',');
      out.push({ name, kind, min: +min, max: +max, step: +step, default: +def, value: e.getSceneParam(i) });
    }
    return out;
  }

  const api = {
    WIDTH, HEIGHT, PIXELS, RGB_BYTES, WHITE, black, pixelOffset,
    ready, loaded, buildLut, tzParse, TZ_UTC, Art, compose, sceneParams, renderIpLayout,
    agreement, anchorClock, deviceNow, installCanvas, clearCanvas, canvasEmpty,
    get lastCanvasResult() { return lastCanvasResult; },
    get clockSkewMs() { return clockSkewMs; },
    DEFAULT_CLOCK_STYLE,
    /* enum catalogues: live values read out of the wasm at load, so they cannot drift */
    get BASES() { return BASES; },
    get GENERATORS() { return GENERATORS; },
    get CLOCK_FONTS() { return CLOCK_FONTS; },
    get CLOCK_MODES() { return CLOCK_MODES; },
    get GRADIENTS() { return GRADIENTS; },
    get DIGIT_STYLES() { return DIGIT_STYLES; },
    get IP_MODES() { return IP_MODES; },
    get CLOCK_MAX_SPREAD() { return CLOCK_MAX_SPREAD; },
    get NOTIFY_MAX_S() { return NOTIFY_MAX_S; },
    /* escape hatches for tests and the menu preview */
    get exports() { return E; },
    action: (a, nowMs) => need().action(a, nowMs),
    openMenu: nowMs => need().openMenu(nowMs),
    menuOpen: () => need().menuOpen() !== 0,
    revision: () => need().revision(),
    takeTransition: () => { const t = need().takeTransition(); return t === 255 ? null : t; },
    /* base and generator may be names or indices; names are safer, because the indices are the
       runtime's enum values and those are renumbered whenever a scene is added or retired */
    reset: (base, generator, seed) => {
      const b = typeof base === 'number' ? base : Math.max(0, BASES.indexOf(base));
      const g = typeof generator === 'number' ? generator : Math.max(0, GENERATORS.indexOf(generator));
      need().init(b | 0, g | 0, seed >>> 0);
      for (const k of Object.keys(applied)) applied[k] = null;
    },
  };
  return api;
});
