// layout regression tests for the console: they render the real page in headless chrome against
// mock-device.py through serve.py, then measure. the class of bug they catch is a row whose
// controls cannot fit beside their label, which collapses the label to nothing and paints its
// description text under the controls (seen on the notification and frame transition rows).
//
// run: /opt/homebrew/bin/node --test test_layout.mjs
// chrome is optional: without it every test skips rather than fails.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtempSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PYTHON = existsSync('/usr/bin/python3') ? '/usr/bin/python3' : 'python3';
const sleep = ms => new Promise(r => setTimeout(r, ms));

function freePort() {
  return new Promise(resolve => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

async function waitFor(fn, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { return await fn(); } catch (e) { if (Date.now() > deadline) throw e; await sleep(150); }
  }
}

// a minimal chrome devtools protocol session: enough to size the viewport and evaluate javascript
class Cdp {
  static async attach(port) {
    const list = await waitFor(async () => {
      const r = await fetch(`http://127.0.0.1:${port}/json/list`);
      const targets = await r.json();
      const page = targets.find(t => t.type === 'page');
      if (!page) throw new Error('no page target yet');
      return page;
    });
    const ws = await new Promise((res, rej) => {
      const w = new WebSocket(list.webSocketDebuggerUrl);
      w.addEventListener('open', () => res(w));
      w.addEventListener('error', rej);
    });
    return new Cdp(ws);
  }
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    ws.addEventListener('message', ev => {
      const m = JSON.parse(ev.data);
      const p = m.id && this.pending.get(m.id);
      if (!p) return;
      this.pending.delete(m.id);
      m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject }); this.ws.send(JSON.stringify({ id, method, params })); });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
    return r.result.value;
  }
  async setWidth(width) {
    await this.send('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false });
    await sleep(350);
  }
  async tabs() {
    return this.eval(`[...document.querySelectorAll('.tabbar button')].map(b => b.dataset.tab)`);
  }
  // measure every panel: they are hidden one at a time, and a hidden box measures as nothing
  async everyTab(expression) {
    const out = [];
    for (const tab of await this.tabs()) {
      await this.eval(`document.querySelector('.tabbar button[data-tab="${tab}"]').click()`);
      await sleep(250);
      out.push([tab, await this.eval(expression)]);
    }
    return out;
  }
}

// every labelled row on the page, with the numbers that say whether it fits
const MEASURE = `
(() => {
  const rows = [];
  for (const field of document.querySelectorAll('.card .field')) {
    const card = field.closest('.card');
    if (card.classList.contains('locked')) continue;
    const label = field.querySelector(':scope > label, :scope > .lab');
    if (!label || !label.textContent.trim()) continue;
    const controls = [...field.children].filter(el => el !== label);
    const need = controls.reduce((sum, el) => sum + el.scrollWidth, 0);
    rows.push({
      card: card.id || (card.querySelector('h2') ? card.querySelector('h2').textContent.trim() : 'preview'),
      label: label.querySelector('.lab, label') ? '' : (label.childNodes[0].textContent || '').trim(),
      labelWidth: Math.round(label.getBoundingClientRect().width),
      labelScrollWidth: label.scrollWidth,
      labelClientWidth: label.clientWidth,
      controlsNeed: Math.round(need),
    });
  }
  const cards = [...document.querySelectorAll('.card')].map(c => ({
    card: c.id || (c.querySelector('h2') ? c.querySelector('h2').textContent.trim() : 'preview'),
    clientWidth: c.clientWidth,
    scrollWidth: c.scrollWidth,
  }));
  return { rows, cards, docOverflows: document.documentElement.scrollWidth > document.documentElement.clientWidth + 1 };
})()
`;

let mock, proxy, chrome, cdp, tmp, mockPort, proxyPort;
const chromeAvailable = existsSync(CHROME);

test.before(async () => {
  if (!chromeAvailable) return;
  tmp = mkdtempSync(join(tmpdir(), 'tc002-layout-'));
  mockPort = await freePort();
  proxyPort = await freePort();
  const cdpPort = await freePort();
  const tokens = join(tmp, 'tokens');
  mock = spawn(PYTHON, ['mock-device.py', '--port', String(mockPort), '--token-file', tokens], { cwd: HERE, stdio: 'ignore' });
  await waitFor(async () => { await fetch(`http://127.0.0.1:${mockPort}/api/v1/status`); });
  proxy = spawn(PYTHON, ['serve.py', String(proxyPort), '--token-file', tokens], { cwd: HERE, stdio: 'ignore' });
  await waitFor(async () => { await fetch(`http://127.0.0.1:${proxyPort}/tokens`); });
  chrome = spawn(CHROME, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${join(tmp, 'profile')}`, `--remote-debugging-port=${cdpPort}`, 'about:blank'], { stdio: 'ignore' });
  cdp = await Cdp.attach(cdpPort);
  await cdp.send('Page.enable');
  await cdp.send('Page.navigate', { url: `http://127.0.0.1:${proxyPort}/?host=127.0.0.1:${mockPort}` });
  // wait for the page to actually be ready rather than guessing how long it takes. a fixed sleep
  // raced the slowest of connect / fetch /scenes / draw the readings, and failed intermittently
  // in a way that looked like whatever had just been edited
  await waitFor(async () => {
    const ready = await cdp.eval(`(() => {
      const bars = document.querySelectorAll('#now .bar').length;
      const selects = [...document.querySelectorAll('.card select')].filter(s => s.options.length).length;
      return bars >= 4 && selects > 0 && document.getElementById('conn').textContent === 'connected';
    })()`);
    if (!ready) throw new Error('the console has not finished connecting');
    return true;
  }, 20000);
});

test.after(async () => {
  // wait for each child to actually exit: chrome writes its profile on the way out, and removing
  // the directory underneath it fails the hook
  await Promise.all([chrome, proxy, mock].filter(Boolean).map(p => new Promise(resolve => {
    if (p.exitCode !== null || p.signalCode !== null) return resolve();
    p.once('exit', resolve);
    p.kill();
    setTimeout(resolve, 5000).unref?.();
  })));
  if (tmp) try { rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }); } catch { /* a stray profile file is not a test failure */ }
});

test('home assistant controls can be enabled and disabled from device settings',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(`document.querySelector('[data-tab="device"]').click(); loadConfig()`);
  assert.equal(await cdp.eval(`document.getElementById('ccontrols').checked`), false);
  for (const enabled of [true, false]) {
    await cdp.eval(`document.getElementById('ccontrols').checked=${enabled}; document.getElementById('capply').click()`);
    await waitFor(async () => {
      if (await cdp.eval(`CONFIG.discovery.controls`) !== enabled) throw new Error('waiting for settings reply');
      return true;
    });
    assert.equal(await cdp.eval(`call('GET', 'config').then(c => c.discovery.controls)`), enabled);
  }
});

// each control must be named by its own row: a select sitting beside two others under one shared
// label reads as an anonymous box (the transition rows once put effect, direction and exit under a
// single "Transition" label)
test('every select is named by the row it sits in', { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.setWidth(1200);
  const unnamed = await cdp.eval(`
    (() => {
      const out = [];
      for (const sel of document.querySelectorAll('.card select')) {
        const field = sel.closest('.field');
        const own = field && field.querySelector(\`label[for="\${sel.id}"]\`);
        if (!own && !sel.getAttribute('aria-label')) out.push({ card: (sel.closest('.card').id || ''), select: sel.id });
      }
      return out;
    })()
  `);
  assert.deepEqual(unnamed, [], `these selects have no label of their own in their row and no aria-label: ${
    unnamed.map(u => `${u.card}/${u.select}`).join(', ')}`);
});

// the now card draws a bar for the figures that are a fraction of something: brightness and cpu are
// percentages already, memory and flash are a used figure over the total the device reports with it
test('the client token name rule matches the device\'s, so a mistake costs no round trip',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // 1-32 of [a-zA-Z0-9._-], not starting with a dot, no commas. checked in the page rather than
  // by a round trip, so it has to agree with the runtime exactly
  const check = async name => cdp.eval(`tokenNameProblem(${JSON.stringify(name)}) === null`);
  for (const good of ['kitchen', 'home.assistant', 'a_b-c', 'A1', 'x'.repeat(32)]) {
    assert.equal(await check(good), true, `${good} should be accepted`);
  }
  for (const bad of ['', '.hidden', 'has,comma', 'has space', 'x'.repeat(33), 'sla/sh', 'sem;colon']) {
    assert.equal(await check(bad), false, `${JSON.stringify(bad)} should be refused`);
  }
});

test('a token that has not been used since a restart says so, rather than never',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // last_used_s is netd's memory and resets with the runtime, so 0 is not "never"
  const [zero, set] = await cdp.eval(`[tokenUsed(0), tokenUsed(1757803312)]`);
  assert.equal(zero, 'not used since restart');
  assert.notEqual(set, 'not used since restart');
  assert.ok(set.length > 0);
});

test('the client token card is locked without an admin token',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  const state = await cdp.eval(`
    (() => {
      const card = document.getElementById('tokenCard');
      return { present: !!card, locked: card.classList.contains('locked'),
               createDisabled: document.getElementById('tokadd').disabled,
               secretHidden: document.getElementById('toknew').hidden,
               secretEmpty: document.getElementById('toksecret').value === '' };
    })()
  `);
  assert.equal(state.present, true);
  assert.equal(state.secretHidden, true, 'no secret panel until one is issued');
  assert.equal(state.secretEmpty, true, 'and nothing sitting in the field');
});

test('a client row offers rotate and revoke, and both confirm in place',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // neither uses confirm(): a modal blocks the page and whatever is driving it. both are
  // destructive — rotate kills the current secret just as surely as revoke does
  const armed = await cdp.eval(`
    (() => {
      showClientTokens({ clients: [{ name: 'kitchen', role: 'control', created_s: 1757800000, last_used_s: 0 }], max: 120 });
      const labels = [...document.querySelectorAll('#toklist button')].map(b => b.textContent);
      const out = { labels, prompts: [] };
      for (const b of document.querySelectorAll('#toklist button')) { b.click(); out.prompts.push(b.textContent); }
      return out;
    })()
  `);
  assert.deepEqual(armed.labels, ['Rotate', 'Revoke']);
  assert.deepEqual(armed.prompts, ['Rotate kitchen?', 'Revoke kitchen?'],
                   'arming names the client, so the wrong row cannot be hit blind');
});

test('an element can be dragged on the preview, and a corner resizes it',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // the panel is 52x16 at ten css pixels an led. a drag is measured as a distance rather than as
  // the difference between two floored cell indices, which counted an extra led whenever a
  // gesture began or ended exactly on a boundary
  const out = await cdp.eval(`
    (() => {
      const cv = document.getElementById('matrix');
      const send = (type, px, py, id) => { const r = cv.getBoundingClientRect();
        cv.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: id || 1,
          clientX: r.left + px * (r.width / 520), clientY: r.top + py * (r.height / 160) })); };
      const led = (type, lx, ly, id) => send(type, lx * 10 + 5, ly * 10 + 5, id);
      showTab('canvas');
      const was = cvDraft;
      cvDraft = { elements: [
        { type: 'text', id: 't', at: [1, 0], text: 'hi', colour: 'ffffff' },
        { type: 'rect', id: 'r', at: [10, 6], size: [8, 6], colour: 'ff0000', filled: true },
      ] };
      cvSelected = 0; cvList(); cvForm(); cvRender();
      const res = {};

      led('pointerdown', 2, 2); res.picked = cvSelected;
      led('pointermove', 6, 5); led('pointerup', 6, 5);
      res.movedTo = cvDraft.elements[0].at.slice();

      led('pointerdown', 12, 8, 2); led('pointerup', 12, 8, 2);
      res.selectedRect = cvSelected;
      const r0 = cvDraft.elements[1];
      const cx = (r0.at[0] + r0.size[0]) * 10, cy = (r0.at[1] + r0.size[1]) * 10;
      send('pointerdown', cx, cy, 3); res.corner = cvDragging && cvDragging.mode;
      send('pointermove', cx + 30, cy + 20, 3); send('pointerup', cx + 30, cy + 20, 3);
      res.size = cvDraft.elements[1].size.slice();
      res.at = cvDraft.elements[1].at.slice();

      cvDraft = was; cvSelected = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.equal(out.picked, 0, 'pressing on an element selects it');
  assert.deepEqual(out.movedTo, [5, 3], 'a four-by-three drag moves it exactly four by three');
  assert.equal(out.selectedRect, 1);
  assert.equal(out.corner, 'se', 'the corner of the selected element is a handle');
  assert.deepEqual(out.size, [11, 8], 'the south-east corner grew it by three by two');
  assert.deepEqual(out.at, [10, 6], 'and the opposite corner stayed where it was');
});

test('what is under an element can be selected without reordering the document',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // the renderer draws elements[0] first, so the last element is the front-most. the list showed
  // the array in order, which put the back-most at the top and made its "up" button send things
  // further back — so reaching text inside a filled rect meant moving the text *down*. the list
  // now reads front to back, and pressing the same led again steps down through the stack, so
  // selecting something never means changing what the panel draws
  const out = await cdp.eval(`
    (() => {
      const cv = document.getElementById('matrix');
      const led = (type, lx, ly, id) => { const r = cv.getBoundingClientRect();
        cv.dispatchEvent(new PointerEvent(type, { bubbles: true, pointerId: id,
          clientX: r.left + (lx * 10 + 5) * (r.width / 520),
          clientY: r.top + (ly * 10 + 5) * (r.height / 160) })); };
      showTab('canvas');
      const was = cvDraft;
      cvDraft = { elements: [
        { type: 'text', id: 'under', at: [12, 4], text: 'hi', colour: 'ffffff' },
        { type: 'rect', id: 'over', at: [10, 2], size: [20, 10], colour: 'ff0000', filled: true },
      ] };
      cvSelected = 0; cvList(); cvForm(); cvRender();
      const res = { rows: [...document.querySelectorAll('#cvelements .cvrow .cvname')].map(n => n.textContent) };
      const press = id => { led('pointerdown', 14, 5, id); led('pointerup', 14, 5, id); return cvSelected; };
      res.picks = [press(21), press(22), press(23)];
      res.elsewhere = (led('pointerdown', 45, 14, 24), led('pointerup', 45, 14, 24), press(25));
      res.order = cvDraft.elements.map(e => e.id);
      res.at = cvDraft.elements.map(e => e.at.slice());
      // a document that changed under the cycle restarts it, rather than resuming a count of a
      // stack that no longer exists
      cvDraft.elements.push({ type: 'rect', id: 'third', at: [13, 4], size: [3, 3], colour: '00ff00', filled: true });
      cvList(); cvRender();
      res.afterChange = press(26);
      cvDraft = was; cvSelected = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.deepEqual(out.picks, [1, 0, 1], 'the first press takes the front-most, the next reaches under it, then it wraps');
  assert.deepEqual(out.rows, ['over', 'under'], 'the front-most element is the first row, as in any layer list');
  assert.equal(out.elsewhere, 1, 'a press somewhere else resets the cycle, so the next one starts at the front again');
  assert.deepEqual(out.order, ['under', 'over'], 'and none of that reordered the document');
  assert.deepEqual(out.at, [[12, 4], [10, 2]], 'nor moved anything: a press and release in one place is not a drag');
  assert.equal(out.afterChange, 2, 'adding an element restarts the cycle at the new front-most, not part-way down');
});

test('an element placed by tile or row is not draggable, and says why',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // tile and row placement has no coordinate to move, so a drag would have nothing to write
  const out = await cdp.eval(`
    (() => {
      showTab('canvas');
      const was = cvDraft;
      cvDraft = { elements: [{ type: 'text', id: 'tiled', tile: 1, of: 2, text: 'hi', colour: 'ffffff' }] };
      cvSelected = 0; cvList(); cvForm(); cvRender();
      const cv = document.getElementById('matrix');
      const r = cv.getBoundingClientRect();
      const b = cvBounds[0];
      cv.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerId: 9,
        clientX: r.left + (b.x0 * 10 + 5) * (r.width / 520),
        clientY: r.top + (b.y0 * 10 + 5) * (r.height / 160) }));
      const res = { dragging: cvDragging, hasAt: 'at' in cvDraft.elements[0] };
      cvDraft = was; cvSelected = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.equal(out.dragging, null, 'no drag is started for a tile-placed element');
  assert.equal(out.hasAt, false, 'and nothing invented an `at` for it');
});

test('the canvas builder validates a draft with the runtime\'s own parser',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // the point of the builder: the thing that says yes or no is the device's parser compiled to
  // wasm, so a refusal quotes the runtime's own code and message instead of a guess at the rule
  const verdicts = await cdp.eval(`
    (() => {
      const was = cvDraft;
      const check = doc => { cvDraft = doc; cvRender(); return document.getElementById('cvvalid').textContent; };
      const out = {
        empty: check({ elements: [] }),
        good: check({ elements: [{ type: 'text', id: 't', at: [1, 4], text: 'hi', colour: 'ffffff' }] }),
        badField: check({ elements: [{ type: 'icon', id: 'i', at: [0, 0], name: 'heart' }] }),
        badType: check({ elements: [{ type: 'teleport', id: 'x', at: [0, 0] }] }),
      };
      cvDraft = was; cvRender();
      return out;
    })()
  `);
  assert.match(verdicts.empty, /accepts this/);
  assert.match(verdicts.good, /1 element . the runtime accepts this/);
  assert.match(verdicts.badField, /refuses this: unknown_field/, 'the runtime\'s own code, not ours');
  assert.match(verdicts.badType, /refuses this: invalid_element_type/);
});

test('the canvas builder draws the draft, not the device',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  const frames = await cdp.eval(`
    (() => {
      const was = cvDraft;
      const lit = doc => { cvDraft = doc; cvRender(); return cvFrame.filter(v => v).length; };
      const out = {
        empty: lit({ elements: [] }),
        drawn: lit({ elements: [{ type: 'rect', id: 'r', at: [0, 0], size: [40, 12], colour: 'ffffff', filled: true }] }),
      };
      cvDraft = was; cvRender();
      return out;
    })()
  `);
  // an empty document draws the hint word; a filled rect covers far more of the panel
  assert.ok(frames.drawn > frames.empty * 2, `a filled rect lit ${frames.drawn}, the empty hint ${frames.empty}`);
});

test('the canvas builder animates the draft it is drawing',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // installing a document starts every animation clock at the moment of the install, so a preview
  // that reinstalled the draft on each paint sat at elapsed zero for ever: a hue that never turned
  // and a blink that never went dark. the draft now runs on a clock of its own.
  const start = await cdp.eval(`
    (() => {
      showTab('canvas');
      cvDraft = { elements: [
        { type: 'rect', id: 'h', at: [2, 2], size: [20, 10], colour: 'ff0000', filled: true, animate: { kind: 'hue', ms: 500 } },
        { type: 'text', id: 'b', at: [30, 5], text: 'hi', colour: 'ffffff', animate: { kind: 'blink', ms: 300 } },
      ] };
      cvSelected = 0; cvList(); cvForm(); cvRender();
      window.__first = Array.from(cvFrame);
      // sample the blinking text's own corner of the panel while the loop runs
      window.__blink = [];
      const litAt = () => { let n = 0; for (let y = 0; y < 16; y++) for (let x = 29; x < 52; x++) {
        const o = (y * 52 + x) * 3; if (cvFrame[o] | cvFrame[o + 1] | cvFrame[o + 2]) n++; } return n; };
      const tick = () => { window.__blink.push(litAt() > 0); if (window.__blink.length < 40) setTimeout(tick, 30); };
      tick();
      return { lit: cvFrame.filter(v => v).length };
    })()
  `);
  assert.ok(start.lit > 0, 'the draft drew something to begin with');
  await sleep(1400);
  const out = await cdp.eval(`
    (() => {
      const now = Array.from(cvFrame);
      let moved = 0;
      for (let i = 0; i < now.length; i++) if (now[i] !== window.__first[i]) moved++;
      const res = { moved, blink: [...new Set(window.__blink)].sort().join(','), samples: window.__blink.length };
      cvDraft = { elements: [] }; cvSelected = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.ok(out.samples > 10, `the sampler ran (${out.samples} samples)`);
  assert.ok(out.moved > 0, 'the hue turned: the frame is not the one drawn a second and a half ago');
  assert.equal(out.blink, 'false,true', 'the blink was seen both lit and dark');
});

test("a sparkline's samples are numbers, not the text that was typed",
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // `data` is a list of samples, but the field is free text, so it was sent as the string the user
  // typed. the runtime's `data: ?[]const u8` takes a json string as readily as an array of
  // numbers, and reads its bytes: "1,2,3,4,5,6,7,8" became 49,44,50,44,51... — the digits and the
  // commas — which draws a square wave climbing one led per pair rather than a rising staircase.
  const out = await cdp.eval(`
    (() => {
      showTab('canvas');
      cvDraft = { elements: [{ type: 'sparkline', id: 'g', at: [0, 0], size: [52, 16],
                               style: 'bars', colour: 'ffffff' }] };
      cvSelected = 0; cvList(); cvForm(); cvRender();
      const field = [...document.querySelectorAll('#cvform input')]
        .find(i => i.getAttribute('aria-label') === 'data');
      if (!field) return { error: 'the sparkline has no data field' };
      field.value = '1,2,3,4,5,6,7,8';
      field.dispatchEvent(new Event('input', { bubbles: true }));
      // the height of each column of the drawn frame: a rising series never steps down
      const prof = [];
      for (let x = 0; x < 52; x++) {
        let top = null;
        for (let y = 0; y < 16; y++) {
          const o = (y * 52 + x) * 3;
          if (cvFrame[o] | cvFrame[o + 1] | cvFrame[o + 2]) { top = y; break; }
        }
        prof.push(top === null ? 0 : 16 - top);
      }
      let descents = 0;
      for (let i = 1; i < prof.length; i++) if (prof[i] < prof[i - 1]) descents++;
      const res = { data: cvDraft.elements[0].data, descents, shown: field.value,
                    valid: document.getElementById('cvvalid').textContent };
      cvDraft = { elements: [] }; cvSelected = 0; cvEpoch = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.equal(out.error, undefined, out.error);
  assert.deepEqual(out.data, [1, 2, 3, 4, 5, 6, 7, 8], 'the samples reach the renderer as numbers');
  assert.match(out.valid, /accepts this/, 'and the runtime accepts the document');
  assert.equal(out.descents, 0, 'a rising series draws a staircase, with no step down anywhere');
});

test('a bounce can be given its travel and its axis, and a blink its duty',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  // `amount` and `axis` had no control at all, so a bounce could only ever have the runtime's
  // default of two leds along y. `amount` is not one field but two: leds of travel for a bounce,
  // percent of the period lit for a blink, and nothing at all for the other seven motions.
  const out = await cdp.eval(`
    (() => {
      showTab('canvas');
      const find = label => [...document.querySelectorAll('#cvform input, #cvform select')]
        .find(i => i.getAttribute('aria-label') === label);
      const set = (label, value, ev) => { const c = find(label); if (!c) return false;
        c.value = value; c.dispatchEvent(new Event(ev, { bubbles: true })); return true; };
      const build = anim => {
        cvDraft = { elements: [{ type: 'text', id: 'b', at: [20, 5], text: 'hi',
                                 colour: 'ffffff', animate: anim }] };
        cvSelected = 0; cvList(); cvForm(); cvRender();
      };
      // how far the element wanders over one period, asked of the renderer rather than guessed
      const wander = () => {
        const at = Date.now();
        S.renderCanvasDraft({ elements: cvDraft.elements }, at);
        const xs = [], ys = [];
        for (let k = 0; k <= 1000; k += 40) {
          S.stepCanvasDraft(at + k);
          const b = S.canvasBounds(at + k)[0];
          if (b) { xs.push(b.x0); ys.push(b.y0); }
        }
        return { dx: Math.max(...xs) - Math.min(...xs), dy: Math.max(...ys) - Math.min(...ys) };
      };
      const res = {};

      build({ kind: 'bounce', ms: 1000 });
      res.hasTravel = !!find('travel');
      res.hasAxis = !!find('axis');
      if (!res.hasTravel || !res.hasAxis) return res;
      set('travel', '8', 'input');
      res.travelWrote = cvDraft.elements[0].animate.amount;
      res.alongY = wander();
      set('axis', 'x', 'change');
      res.axisWrote = cvDraft.elements[0].animate.axis;
      res.alongX = wander();

      // amount is the lit duty for a blink, so the control has to be named for that instead
      build({ kind: 'blink', ms: 400 });
      res.blinkTravel = !!find('travel');
      res.blinkDuty = !!find('duty');
      res.blinkAxis = !!find('axis');
      // the fraction of one period the element is lit for, which is what a duty is
      const litFraction = () => {
        const at = Date.now();
        S.renderCanvasDraft({ elements: cvDraft.elements }, at);
        let lit = 0, n = 0;
        for (let k = 0; k < 400; k += 10) {
          const rgb = S.stepCanvasDraft(at + k);
          if (rgb.some(v => v)) lit++;
          n++;
        }
        return lit / n;
      };
      set('duty', '10', 'input');
      res.dutyLow = litFraction();
      set('duty', '90', 'input');
      res.dutyHigh = litFraction();
      // and it means nothing at all for a hue
      build({ kind: 'hue', ms: 800 });
      res.hueAmount = !!find('travel') || !!find('duty') || !!find('axis');

      cvDraft = { elements: [] }; cvSelected = 0; cvEpoch = 0; cvList(); cvForm(); cvRender();
      showTab('scene');
      return res;
    })()
  `);
  assert.ok(out.hasTravel, 'a bounce offers a travel');
  assert.ok(out.hasAxis, 'a bounce offers an axis');
  assert.equal(out.travelWrote, 8, 'the travel reaches the document as a number');
  assert.equal(out.axisWrote, 'x', "the axis reaches the document as the runtime's own x/y");
  assert.ok(out.alongY.dy >= 6 && out.alongY.dx === 0, `eight leds of travel along y moved it ${JSON.stringify(out.alongY)}`);
  assert.ok(out.alongX.dx >= 6 && out.alongX.dy === 0, `the same travel along x moved it ${JSON.stringify(out.alongX)}`);
  assert.ok(out.blinkDuty, "a blink's amount is offered as a duty");
  assert.ok(out.dutyLow < 0.2, `a duty of 10 is lit a tenth of the period, was ${out.dutyLow}`);
  assert.ok(out.dutyHigh > 0.8, `a duty of 90 is lit nine tenths of it, was ${out.dutyHigh}`);
  assert.ok(!out.blinkTravel && !out.blinkAxis, 'and a blink has neither travel nor axis');
  assert.ok(!out.hueAmount, 'a hue uses neither, so it is offered neither');
});

test('the now card fills each metric bar to the fraction the device reports', { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.setWidth(1200);
  const st = await cdp.eval(`fetch('/api/127.0.0.1:${mockPort}/v1/status', { cache: 'no-store' }).then(r => r.json())`);
  const expected = {
    brightness: st.brightness,
    cpu: st.cpu_pct,
    memory: 100 * (st.memory_total_kb - st.memory_available_kb) / st.memory_total_kb,
    flash: 100 * st.flash_used_kb / st.flash_total_kb,
  };
  const drawn = await cdp.eval(`
    (() => {
      const out = {};
      for (const bar of document.querySelectorAll('#now .bar')) {
        const track = bar.getBoundingClientRect().width;
        const fill = bar.firstElementChild.getBoundingClientRect().width;
        out[bar.dataset.metric] = track ? 100 * fill / track : null;
      }
      return out;
    })()
  `);
  assert.deepEqual(Object.keys(drawn).sort(), ['brightness', 'cpu', 'flash', 'memory'], 'one bar per metric');
  for (const [metric, want] of Object.entries(expected)) {
    assert.ok(Math.abs(drawn[metric] - want) <= 1.5,
      `the ${metric} bar is ${drawn[metric]?.toFixed(1)}% wide, the device reports ${want.toFixed(1)}%`);
  }
});

test('the tabs show one panel at a time and never hide the preview', { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.setWidth(1200);
  for (const [tab, state] of await cdp.everyTab(`
    (() => ({
      shown: [...document.querySelectorAll('.tabpanel')].filter(p => !p.hidden).map(p => p.dataset.panel),
      selected: [...document.querySelectorAll('.tabbar button')].filter(b => b.getAttribute('aria-selected') === 'true').map(b => b.dataset.tab),
      previewVisible: !document.getElementById('matrix').closest('[hidden]'),
    }))()`)) {
    assert.deepEqual(state.shown, [tab], `the ${tab} tab should show its panel alone`);
    assert.deepEqual(state.selected, [tab], `the ${tab} tab should be the only one selected`);
    assert.equal(state.previewVisible, true, `the preview disappeared on the ${tab} tab`);
  }
});

// the widths that matter: 1440 and 1200 put the five-column cards at their narrowest useful size,
// 950 is just past the breakpoint where cards stop spanning the full grid, 700 and 390 are the
// stacked layouts
for (const width of [1440, 1200, 950, 700, 390]) {
  test(`at ${width} px no label is crushed by the controls beside it`, { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
    await cdp.setWidth(width);
    let seen = 0;
    for (const [tab, { rows }] of await cdp.everyTab(MEASURE)) {
      seen += rows.length;
      const crushed = rows.filter(r => r.labelScrollWidth > r.labelClientWidth + 1);
      assert.deepEqual(crushed, [], `on the ${tab} tab these labels overflow their box, so their text paints over the controls beside it:\n${
        crushed.map(r => `  ${r.card} · ${r.label}: label ${r.labelWidth} px wide, text needs ${r.labelScrollWidth} px, controls need ${r.controlsNeed} px`).join('\n')}`);
    }
    assert.ok(seen > 20, `expected the panels to be populated, saw ${seen} rows across the tabs`);
  });

  test(`at ${width} px nothing overflows its card or the page`, { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
    await cdp.setWidth(width);
    for (const [tab, { cards, docOverflows }] of await cdp.everyTab(MEASURE)) {
      const spilling = cards.filter(c => c.scrollWidth > c.clientWidth + 1);
      assert.deepEqual(spilling, [], `on the ${tab} tab these cards scroll sideways: ${spilling.map(c => `${c.card} (${c.scrollWidth} > ${c.clientWidth})`).join(', ')}`);
      assert.equal(docOverflows, false, `the page scrolls sideways on the ${tab} tab`);
    }
  });
}

// a retracted toast must be gone, not merely parked below the fold. sliding it past the bottom
// edge leaves it in the layout, so whether any of it shows comes down to rounding and to how the
// browser treats a fixed box hanging off the viewport — it came back twice, and the second time
// it could still be scrolled to. so the resting state is `display:none`: nothing to round, nothing
// to scroll to, nothing to hit-test. the slide is kept by transitioning `display` as a discrete
// property, which holds the box for the length of the retract and then drops it.
test('a retracted toast is not in the page at all',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.setWidth(1200);
  const geom = await cdp.eval(`(async () => {
    const t = document.getElementById('toast');
    const de = document.documentElement;
    const settle = () => new Promise(r => setTimeout(r, 400));
    toast('connected to the runtime');   // the shortest kind: one line, the case that used to strand a sliver
    await settle();
    const shownRect = t.getBoundingClientRect();
    const shown = { display: getComputedStyle(t).display, bottom: shownRect.bottom, height: shownRect.height };
    clearTimeout(t._t); t.className = '';
    await settle();
    const rect = t.getBoundingClientRect();
    // scroll to the very bottom: a box parked below the fold shows up here even when it does not
    // at the top of the page
    window.scrollTo(0, de.scrollHeight);
    await new Promise(r => setTimeout(r, 200));
    const atBottom = t.getBoundingClientRect();
    const scrolled = window.scrollY;
    window.scrollTo(0, 0);
    return { shown, viewport: window.innerHeight, display: getComputedStyle(t).display,
             paints: rect.width > 0 || rect.height > 0,
             // an unrendered element measures as a zero rect at the origin, which is not a sliver
             // at the top of the screen: nothing is painted, so nothing is showing
             sliverAtBottom: (atBottom.width || atBottom.height)
               ? Math.round(Math.max(0, window.innerHeight - atBottom.top)) : 0, scrolled };
  })()`);
  assert.equal(geom.shown.display !== 'none', true, 'a showing toast has to be rendered');
  assert.ok(geom.shown.height > 0 && geom.shown.bottom <= geom.viewport,
    `a showing toast should be inside the viewport, bottom ${geom.shown.bottom} of ${geom.viewport}`);
  assert.equal(geom.display, 'none', 'a retracted toast should be taken out of the layout, not parked below the fold');
  assert.equal(geom.paints, false, 'a retracted toast still has a box');
  assert.equal(geom.sliverAtBottom, 0,
    `scrolled to the bottom of the page, ${geom.sliverAtBottom} px of the retracted toast is still on screen`);
});

// the preview replays the statements the device publishes; /status is the bootstrap snapshot and
// the resync, not a second opinion to be applied on top. the replica's revision is the device's:
// it moves when a statement moves it and at no other time, because a statement that does not land
// on the revision it carries is how a missed one is noticed. installing a snapshot with the same
// commands the device applies moves it too — and then every statement afterwards looks missed.
//
// a knob turn is where that shows: the device publishes one statement per detent, so a turn of
// several steps is a burst, and a burst that is thrown away for a resync leaves the preview on
// whatever /status happened to say when it was sampled rather than where the panel ended up.
//
// the stream is stubbed at the seam the page already has: it builds an EventSource and reads
// `onmessage`, so a fake one delivers real statements without needing the mock to grow /events.
const STREAM_START = `
(() => {
  window.__RealES = window.__RealES || window.EventSource;
  window.EventSource = class {
    constructor(url) { this.url = url; this.onopen = null; this.onerror = null; this.onmessage = null; window.__ES = this; }
    close() { if (window.__ES === this) window.__ES = null; }
  };
  startEvents();
  window.__ES.onopen();
  return streamState;
})()`;
const STREAM_STOP = `(() => { window.EventSource = window.__RealES; startEvents(); return streamState; })()`;
const statement = ev => `window.__ES.onmessage({ data: ${JSON.stringify(JSON.stringify(ev))} })`;

test('a knob turn published one detent at a time plays out instead of forcing a resync',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  assert.equal(await cdp.eval(STREAM_START), 'live');
  try {
    // a resync is the one moment the replica is known to stand exactly where the device does:
    // it takes a fresh /status and stamps that revision on. everything after this asks whether
    // it is still standing there
    const at = await cdp.eval(`resyncFromState('test').then(() => STATUS.revision)`);
    await sleep(700);   // several paints, each of which installs the snapshot it is given
    assert.equal(await cdp.eval(`S.revision()`), at,
      'the preview moved its own revision on without the device applying anything');

    // three detents of one turn, published together as the device publishes them
    for (const [i, generator] of ['plasma', 'cube', 'popsquares'].entries()) {
      await cdp.eval(statement({ revision: at + i + 1, age_ms: 0, cmd: 'select_generator', source: 'input', generator }));
    }
    await sleep(1500);   // the mirror runs 750 ms behind, and /status is polled every second
    assert.equal(await cdp.eval(`lastStatement`), 'select_generator \u00b7 input',
      'the replica resynced instead of playing the turn the device published');
    assert.equal(await cdp.eval(`S.revision()`), at + 3,
      'the replica did not land on the revision the last detent carried');
  } finally {
    await cdp.eval(STREAM_STOP);
  }
});

test('script editor round-trips source through the real proxy and berry mock',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.setWidth(1200);
  await cdp.eval(`document.querySelector('[data-tab="scripts"]').click()`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('loading');});
  assert.ok(!(await cdp.eval(`document.getElementById('scriptBudget').textContent`)).includes('undefined'));
  await cdp.eval(`document.getElementById('scriptName').value='editor_roundtrip';document.getElementById('scriptNewForm').requestSubmit()`);
  const source = "# keep case and utf-8 exactly\nprint('MiXeD café')\n";
  await cdp.eval(`(() => {const e=document.getElementById('scriptSource');e.value=${JSON.stringify(source)};e.dispatchEvent(new Event('input'));})()`);
  assert.equal(await cdp.eval(`(async()=>{const r=await fetch(api('berry/scripts/editor_roundtrip'));return r.status;})()`),404,'creating and typing must not store a script');
  await cdp.eval(`document.getElementById('scriptSave').click()`);
  await waitFor(async () => {
    const actual=await cdp.eval(`(async()=>{const r=await fetch(api('berry/scripts/editor_roundtrip'));return r.ok ? await r.text() : null;})()`);
    if(actual !== source) throw new Error('source has not round-tripped');
  });
  await sleep(100);
  assert.ok((await cdp.eval(`document.getElementById('scriptMessage').textContent`)).includes('not compiled'),'disabled interpreter saves must be identified');
  assert.equal(await cdp.eval(`(async()=>{const list=await (await fetch(api('berry/scripts'))).json();return document.getElementById('scriptBudget').textContent.startsWith(list.used+' /');})()`),true,'store usage updates after saving');
  await cdp.eval(`document.getElementById('scriptRun').click()`);
  await waitFor(async()=>{if(!(await cdp.eval(`document.getElementById('scriptMessage').textContent`)).includes('not enabled')) throw new Error('disabled interpreter refusal missing');});
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),source);
  await cdp.eval(`document.getElementById('scriptDelete').click();document.getElementById('scriptDelete').click()`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('deleting');});
  assert.equal(await cdp.eval(`(async()=>{const r=await fetch(api('berry/scripts/editor_roundtrip'));return r.status;})()`),404);
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),source,'delete keeps a browser draft');
  await cdp.eval(`document.getElementById('scriptDiscard').click();document.getElementById('scriptDiscard').click()`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('discarding');});
  assert.equal(await cdp.eval('scriptEditor.session'),null,'discarding a local-only script closes it');
});

const SCRIPT_FIXTURE = `(() => {
    const original = window.fetch.bind(window);
    window.__scriptTest = { sources: { welcome: "print('hello')" }, writes: 0, runs: 0 };
    window.fetch = async (url, options = {}) => {
      const path = String(url).split('/v1/')[1];
      if (path?.startsWith('logs?')) {
        const after = new URL('http://fixture/' + path).searchParams.get('after');
        return new Response(JSON.stringify({next:2,lines:after === '2' ? [] : [{seq:1,text:'hello from script'},{seq:2,text:'42'}]}),{headers:{'content-type':'application/json'}});
      }
      if (!path || !path.startsWith('berry')) return original(url, options);
      if (window.__scriptTest.offline) throw new TypeError('device offline');
      const t = window.__scriptTest, method = options.method || 'GET';
      const json = (value, status = 200) => new Response(JSON.stringify(value), {status, headers: {'content-type':'application/json'}});
      if (path === 'berry') return json({state:'running', heap_used:1024, heap_bytes:262144, stops:0});
      if (path === 'berry/scripts') return json({used:32,budget:65536,scripts:Object.entries(t.sources).map(([name,source]) => ({name,bytes:source.length,compiled:true}))});
      const [, , name, action] = path.split('/');
      if (method === 'GET' && t.delayRead && name) await new Promise(resolve => t.releaseRead = resolve);
      if (action === 'run') { t.runs++; return json({status:'ok',name,note:'42'}); }
      if (method === 'PUT') {
        if (options.body.includes('broken!')) return json({error:'script_will_not_compile',message:'line 2: syntax error'},400);
        t.writes++; t.sources[name] = options.body; return json({ok:true});
      }
      if (method === 'DELETE') { delete t.sources[name]; return json({ok:true}); }
      return Object.hasOwn(t.sources,name) ? new Response(t.sources[name], {headers:{'content-type':'text/plain'}}) : json({error:'not_found'},404);
    };
  })()`;

// browser interaction tests use a small http contract fixture; the runtime integration tests
// exercise the actual mock separately. this lets failures and delayed saves be deterministic.
test('script editor recovers local drafts and writes only on explicit changed-source saves',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  assert.equal(await cdp.eval(`!!document.querySelector('[data-tab="scripts"]')`), true);
  const fixture = SCRIPT_FIXTURE;
  const installed = await cdp.send('Page.addScriptToEvaluateOnNewDocument', {source:fixture});
  await cdp.eval(fixture);
  try {
    await cdp.eval(`document.querySelector('[data-tab="scripts"]').click()`);
    await waitFor(async () => {
      if (await cdp.eval(`document.getElementById('scriptSource')?.value`) !== "print('hello')") throw new Error('source not loaded');
    });
    const edit = source => cdp.eval(`(() => { const e=document.getElementById('scriptSource'); e.value=${JSON.stringify(source)}; e.dispatchEvent(new Event('input',{bubbles:true})); })()`);
    await edit("print('local draft')");
    if (process.env.TC002_SCRIPT_SHOTS) { await cdp.setWidth(1200);await cdp.eval(`document.getElementById('scriptsCard').scrollIntoView({block:'start'})`);const shot=await cdp.send('Page.captureScreenshot',{format:'png'});writeFileSync('/tmp/tc002-script-desktop.png',Buffer.from(shot.data,'base64')); }
    assert.deepEqual(await cdp.eval(`[__scriptTest.writes,__scriptTest.runs]`),[0,0]);
    const previousOrigin = await cdp.eval('performance.timeOrigin');
    await cdp.send('Page.reload');
    await waitFor(async () => {
      if (await cdp.eval('performance.timeOrigin') === previousOrigin) throw new Error('reload has not started');
      if (await cdp.eval(`document.getElementById('scriptSource')?.value`) !== "print('local draft')") throw new Error('draft not recovered');
    });
    await cdp.eval(`document.getElementById('scriptRun').click()`);
    await waitFor(async () => { if (await cdp.eval('__scriptTest.runs') !== 1) throw new Error('run not sent'); });
    assert.equal(await cdp.eval('__scriptTest.writes'),0);
    assert.ok((await cdp.eval(`document.getElementById('scriptMessage').textContent`)).includes('42'),'run result is shown');
    await cdp.eval(`document.getElementById('scriptSave').click()`);
    await waitFor(async () => { if (await cdp.eval('__scriptTest.writes') !== 1) throw new Error('save not sent'); });
    await sleep(150);
    await cdp.eval(`document.getElementById('scriptSave').click()`);
    await sleep(150);
    assert.equal(await cdp.eval('__scriptTest.writes'),1);
    await edit("print('hello')\nbroken!");
    await cdp.eval(`document.getElementById('scriptSaveRun').click()`);
    await waitFor(async () => { if (!(await cdp.eval(`document.getElementById('scriptMessage').textContent`)).includes('syntax error')) throw new Error('compile error missing'); });
    assert.deepEqual(await cdp.eval(`[__scriptTest.writes,__scriptTest.runs]`),[1,1]);
    assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),"print('hello')\nbroken!");
    await sleep(2300);
    assert.equal(await cdp.eval(`document.getElementById('scriptOutput').textContent.split('hello from script').length-1`),1);
    assert.ok((await cdp.eval(`document.getElementById('scriptOutput').textContent`)).includes('42'),'plain print output is retained');
    await cdp.setWidth(390);
    if (process.env.TC002_SCRIPT_SHOTS) { const shot=await cdp.send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});writeFileSync('/tmp/tc002-script-narrow.png',Buffer.from(shot.data,'base64')); }
    assert.equal(await cdp.eval(`document.documentElement.scrollWidth > document.documentElement.clientWidth + 1`),false);
    assert.equal(await cdp.eval(`document.getElementById('scriptSource').getBoundingClientRect().width > 200`),true,await cdp.eval(`JSON.stringify({width:document.getElementById('scriptSource').getBoundingClientRect().width,hidden:document.getElementById('scriptsPanel').hidden,display:getComputedStyle(document.getElementById('scriptsPanel')).display})`));
  } finally {
    await cdp.send('Page.removeScriptToEvaluateOnNewDocument',{identifier:installed.identifier});
  }
});


test('script confirmations belong to the script they name and discard excludes concurrent edits',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  await cdp.eval(`__scriptTest.sources.other="print('other')"; scriptEditor.visible(true)`);
  await waitFor(async () => { if (await cdp.eval('scriptEditor.opening')) throw new Error('loading'); });
  await cdp.eval(`scriptEditor.open('welcome')`);
  await cdp.eval(`document.getElementById('scriptDelete').click()`);
  await cdp.eval(`scriptEditor.open('other')`);
  await cdp.eval(`document.getElementById('scriptDelete').click()`);
  await sleep(150);
  assert.equal(await cdp.eval(`Object.hasOwn(__scriptTest.sources,'other')`),true,'switching scripts must disarm delete');
  await cdp.eval(`(() => {const e=document.getElementById('scriptSource'); e.value="print('draft')";e.dispatchEvent(new Event('input'));__scriptTest.delayRead=true;document.getElementById('scriptDiscard').click();document.getElementById('scriptDiscard').click();})()`);
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').disabled`),true,'discard must protect edits while reading remote source');
  assert.equal(await cdp.eval(`document.getElementById('scriptSave').disabled`),true);
  await cdp.eval(`__scriptTest.delayRead=false;__scriptTest.releaseRead()`);
});

test('script draft unload protection includes inactive scripts after storage failure',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  const protectedDraft = await cdp.eval(`(async () => {
    const previous=scriptEditor.drafts;
    try {
      scriptEditor.drafts=new TC002ScriptsModel.Drafts({length:0,key(){return null;},getItem(){return null;},setItem(){throw new Error('quota exceeded');},removeItem(){}});
      await scriptEditor.open('welcome'); scriptEditor.session.edit('print(42)');
      __scriptTest.sources.other='print(1)'; scriptEditor.device='other-device'; await scriptEditor.open('other');
      const event=new Event('beforeunload',{cancelable:true}); window.dispatchEvent(event);
      return {unsafe:scriptEditor.drafts.hasUnsafeDrafts(),protected:event.defaultPrevented};
    } finally { scriptEditor.drafts=previous; }
  })()`);
  assert.equal(protectedDraft.unsafe,true);
  assert.equal(protectedDraft.protected,true);
});


test('script editor indents selected lines without deleting source',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  await cdp.eval(`scriptEditor.device=host();scriptEditor.visible(true)`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('loading');});
  await cdp.eval(`scriptEditor.open('welcome')`);
  const source="print(1)\nprint(2)";
  await cdp.eval(`(() => {const e=document.getElementById('scriptSource');e.value=${JSON.stringify(source)};e.dispatchEvent(new Event('input'));e.setSelectionRange(0,e.value.length);e.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));})()`);
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),'  print(1)\n  print(2)');
  await cdp.eval(`document.getElementById('scriptSource').dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}))`);
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),source);
});

test('script editor clears old highlights when switching to an empty device',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  await cdp.eval(`scriptEditor.device=host();scriptEditor.visible(true)`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('loading');});
  await cdp.eval(`scriptEditor.open('welcome')`);
  const result=await cdp.eval(`(async()=>{const old=scriptEditor.connection;try{__scriptTest.sources={};scriptEditor.connection=()=>({device:'empty-device',admin:true,control:true});await scriptEditor.activate();return {source:document.getElementById('scriptSource').value,highlight:document.getElementById('scriptHighlight').textContent.trim()};}finally{scriptEditor.connection=old;}})()`);
  assert.equal(result.source,'');
  assert.equal(result.highlight,'');
});

test('script save shortcut enforces the utf-8 byte limit before sending',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  await cdp.eval(`scriptEditor.device=host();scriptEditor.visible(true)`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('loading');});
  await cdp.eval(`scriptEditor.open('welcome')`);
  await cdp.eval(`(() => {const e=document.getElementById('scriptSource');e.value='é'.repeat(4001);e.dispatchEvent(new Event('input'));e.dispatchEvent(new KeyboardEvent('keydown',{key:'s',ctrlKey:true,bubbles:true,cancelable:true}));})()`);
  await sleep(100);
  assert.equal(await cdp.eval('__scriptTest.writes'),0);
});


test('script editor restores its selected draft when the device cannot be reached',
  { skip: chromeAvailable ? false : 'google chrome is not installed' }, async () => {
  await cdp.eval(SCRIPT_FIXTURE);
  await cdp.eval(`scriptEditor.device=host();scriptEditor.visible(true)`);
  await waitFor(async () => {if(await cdp.eval('scriptEditor.opening')) throw new Error('loading');});
  await cdp.eval(`scriptEditor.open('welcome')`);
  await cdp.eval(`scriptEditor.session.edit("print('offline draft')");scriptEditor.session=null;document.getElementById('scriptSource').value='';__scriptTest.offline=true;scriptEditor.activate()`);
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').value`),"print('offline draft')");
  assert.equal(await cdp.eval(`document.getElementById('scriptSource').disabled`),false);
});
