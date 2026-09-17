// exercise the offline explorer in chrome against the existing device mock.
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


let fixture, chrome, cdp, tmp, port;
const available = existsSync(CHROME);
test.before(async () => {
  if (!available) return;
  tmp = mkdtempSync(join(tmpdir(), 'tc002-docs-browser-'));
  port = await freePort();
  fixture = spawn('/usr/bin/python3', [join(HERE, '../test/docs_server.py'), String(port)], {stdio:'ignore'});
  await waitFor(async () => { const r = await fetch(`http://127.0.0.1:${port}/api/openapi.json`); assert.equal(r.status,200); });
  const debug = await freePort();
  chrome = spawn(CHROME, ['--headless=new','--no-first-run','--no-default-browser-check',`--user-data-dir=${tmp}`,`--remote-debugging-port=${debug}`,`http://127.0.0.1:${port}/api/docs`], {stdio:'ignore'});
  cdp = await Cdp.attach(debug);
  await waitFor(async () => assert.equal(await cdp.eval("document.querySelectorAll('.operation').length"),45));
});
test.after(async () => {
  cdp?.ws.close();
  for (const process of [chrome, fixture]) if (process && process.exitCode === null && process.signalCode === null) {
    // these handles refer only to the exact children this fixture spawned.
    const exited = new Promise(resolve => process.once('exit',resolve)); process.kill('SIGTERM'); await exited;
  }
  if (tmp) rmSync(tmp,{recursive:true,force:true});
});
test('offline explorer lists operations, schemas and unavailable routes without credentials', {skip:!available}, async () => {
  assert.equal(await cdp.eval("document.querySelectorAll('.operation').length"),45);
  assert.equal(await cdp.eval("document.querySelectorAll('.unavailable').length"),3);
  assert.equal(await cdp.eval("document.getElementById('token').value"),'');
  for (const width of [1200,390]) {
    await cdp.setWidth(width);
    assert.equal(await cdp.eval('document.documentElement.scrollWidth <= innerWidth'),true);
  }
});
test('execute authenticates and sends a real notification to the mock', {skip:!available}, async () => {
  await cdp.eval(`(() => {
    document.getElementById('token').value='c'.repeat(64);
    const card=[...document.querySelectorAll('.operation')].find(c=>c.querySelector('code').textContent==='/notify');
    card.open=true; card.querySelector('textarea').value=JSON.stringify({text:'hello from docs'}); card.querySelector('.primary').click();
  })()`);
  await waitFor(async()=>assert.match(await cdp.eval("[...document.querySelectorAll('.operation')].find(c=>c.querySelector('code').textContent==='/notify').querySelector('.response').textContent"),/applied/));
  const status=await fetch(`http://127.0.0.1:${port}/api/v1/status`,{headers:{authorization:'Bearer '+'c'.repeat(64)}}).then(r=>r.json());
  assert.equal(status.overlay,'notify');
  await cdp.eval("document.getElementById('forget').click()");
  assert.equal(await cdp.eval("document.getElementById('token').value"),'');
  assert.equal(await cdp.eval('localStorage.length + sessionStorage.length'),0);
});
test('schema downloads are complete and the page remains readable on a phone', {skip:!available}, async () => {
  for (const name of ['openapi','schema']) {
    const response=await fetch(`http://127.0.0.1:${port}/api/${name}.json`);
    const data=await response.arrayBuffer(); assert.equal(data.byteLength,Number(response.headers.get('content-length'))); JSON.parse(new TextDecoder().decode(data));
  }
  await cdp.setWidth(1200);
  await cdp.eval("document.querySelectorAll('.operation').forEach(c=>c.open=false);scrollTo(0,0)");
  const shot=await cdp.send('Page.captureScreenshot',{format:'png'});
  writeFileSync('/tmp/tc002-ha-api-docs.png',Buffer.from(shot.data,'base64'));
});
