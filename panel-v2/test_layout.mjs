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
  await sleep(3000);   // connect, fetch /scenes, fill every select
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
