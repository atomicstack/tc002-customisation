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
import { mkdtempSync, rmSync, existsSync } from 'node:fs';
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
