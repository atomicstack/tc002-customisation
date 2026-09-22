// screenshot.mjs: regenerate the console screenshots the docs use.
//
//   node --no-warnings panel-v2/screenshot.mjs [host[:port]] [--token-file FILE] [--no-redact]
//
// the screenshots in README.md went stale because nothing regenerated them: the console grew a
// canvas builder and a script editor and the pictures still showed four tabs. this exists so that
// "the images are out of date" is a command rather than an afternoon.
//
// it drives the same headless chrome the layout tests use, against the same proxy the console is
// normally served by, so what it captures is the real page against a real device rather than a
// mock-up. with --mock it runs against mock-device.py instead, which is enough for a shape check
// but shows invented readings.
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { writeFileSync, existsSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
// the mock and the proxy bind 127.0.0.1 only, so no lan gate applies and any python3 will do
const PYTHON = 'python3';
const sleep = ms => new Promise(r => setTimeout(r, ms));

const args = process.argv.slice(2);
const mock = args.includes('--mock');
// the screenshots are published; redaction is on unless someone deliberately turns it off
const noRedact = args.includes('--no-redact');
const tokenIx = args.indexOf('--token-file');
const tokenFile = tokenIx >= 0 ? args[tokenIx + 1] : null;
const host = args.find(a => !a.startsWith('--') && a !== tokenFile) || null;

function freePort() {
  return new Promise(resolve => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}
async function waitFor(fn, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try { return await fn(); } catch (e) { if (Date.now() > deadline) throw e; await sleep(200); }
  }
}

// the same minimal cdp session test_layout.mjs uses
class Cdp {
  static async attach(port) {
    const page = await waitFor(async () => {
      const r = await fetch(`http://127.0.0.1:${port}/json/list`);
      const target = (await r.json()).find(t => t.type === 'page');
      if (!target) throw new Error('no page target yet');
      return target;
    });
    const ws = await new Promise((res, rej) => {
      const w = new WebSocket(page.webSocketDebuggerUrl);
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
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails));
    return r.result.value;
  }
  async setWidth(width, height = 1000) {
    await this.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: false });
    await sleep(400);
  }
  async shot(path, beyondViewport = true) {
    const r = await this.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: beyondViewport });
    writeFileSync(path, Buffer.from(r.data, 'base64'));
    return path;
  }
  async tab(name) {
    await this.eval(`document.querySelector('.tabbar button[data-tab="${name}"]').click()`);
    await sleep(600);
  }
}

// every child has to die with this process, including when something kills *this* process from
// outside. an earlier version only cleaned up on the happy path and on ctrl-c, so a run that hit a
// timeout left a proxy and a whole chrome tree behind -- one of them was still up three and a half
// hours later, holding a port.
const started = [];
let closing = false;
function reap() {
  if (closing) return;
  closing = true;
  for (const p of started) { try { process.kill(-p.pid, 'SIGKILL'); } catch { try { p.kill('SIGKILL'); } catch {} } }
}
function bail(message) { console.error(message); shutdown(1); }
function shutdown(code) { reap(); process.exit(code); }
process.on('exit', reap);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => shutdown(130));
process.on('uncaughtException', e => { console.error(e.message); shutdown(1); });

if (!existsSync(CHROME)) bail(`google chrome is not at ${CHROME}; it is what takes the pictures`);

// serve.py takes the port positionally and proxies /api/<device>/v1/...; the page is told which
// device to talk to with ?host=, the same way start-panel.sh --open does it.
const proxyPort = await freePort();
const proxyArgs = ['serve.py', String(proxyPort)];
let target = host;
if (mock) {
  const mockPort = await freePort();
  started.push(spawn(PYTHON, ['mock-device.py', '--port', String(mockPort)], { cwd: HERE, stdio: 'ignore', detached: true }));
  target = `127.0.0.1:${mockPort}`;
  await sleep(700);
} else if (!host) {
  bail('give the device address, or --mock: screenshot.mjs 10.0.0.111');
}
// without a token the console renders "no tokens" and every control is dead -- which is exactly
// the useless picture this script existed to stop someone committing. so a token is required, not
// best-effort, and the run fails loudly without one.
let tokens = tokenFile;
if (!tokens) {
  for (const f of ['tokens', '../tokens', join(HERE, '../tokens')]) {
    if (existsSync(f)) { tokens = f; break; }
  }
}
if (!tokens && !mock) bail('no token file: pass --token-file, or run the console once to pull one');
if (tokens) proxyArgs.push('--token-file', tokens);
const proxy = spawn(PYTHON, proxyArgs, { cwd: HERE, stdio: ['ignore', 'ignore', 'inherit'], detached: true });
started.push(proxy);

const url = `http://127.0.0.1:${proxyPort}/?host=${encodeURIComponent(target)}`;
await waitFor(async () => { const r = await fetch(url); if (!r.ok) throw new Error(`proxy says ${r.status}`); });

const profile = mkdtempSync(join(tmpdir(), 'tc002-shots-'));
const debugPort = await freePort();
const chrome = spawn(CHROME, [
  '--headless=new', `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`,
  '--hide-scrollbars', '--force-device-scale-factor=2', '--no-first-run', '--no-default-browser-check', url,
], { stdio: 'ignore', detached: true });
started.push(chrome);

const out = join(HERE, 'screenshots');
mkdirSync(out, { recursive: true });
const cdp = await Cdp.attach(debugPort);
await cdp.send('Page.enable');

// wait for the console to be genuinely connected. an earlier version accepted "any digit on the
// page" and happily photographed a disconnected console showing "no tokens" -- the ip address in
// the header was the digit it found.
await waitFor(async () => {
  const text = await cdp.eval(`document.body.innerText`);
  if (/no tokens|not connected|connect to populate|has no tokens/i.test(text)) throw new Error('not connected yet');
  if (!/uptime|build|brightness/i.test(text)) throw new Error('no device readings yet');
}, 40000);
await sleep(1200);   // let the preview render a frame or two

// --- redaction ---------------------------------------------------------------------------------
// these screenshots go in the readme, so they must not carry the owner's details: the device
// address, the broker and its username, the ntp server, issued token names, and -- the one that is
// easy to miss -- **the location**, which reads as `latitude, longitude` on the device tab. the
// timezone and the sun times are left real, by agreement -- they say "amsterdam", which the
// coordinates are rounded to anyway.
//
// it runs per tab, immediately before each shot, and the real address goes back afterwards. doing
// it once up front looked tidier and broke two tabs: the console kept polling the fake address and
// repainted "unreachable", and the scripts tab, which fetches when you open it, showed "host is
// down" in red. nothing here reads a secret -- the password fields already answer "never returned".
const DEVICE_REAL = target;
const DEVICE_FAKE = '10.0.0.42';
const swaps = [
  [String.raw`\b${DEVICE_REAL.replace(/\./g, String.raw`\.`)}\b`, 'g', DEVICE_FAKE],
  [String.raw`\b10\.0\.0\.136\b`, 'g', '10.0.0.50'],
  [String.raw`\bmqtt_tc002\b`, 'g', 'mqtt_user'],
  [String.raw`\bphoton-claude\b`, 'g', 'kitchen'],
  // the timezone stays real -- matt is fine with Europe/Amsterdam being public. the coordinates are
  // rounded to the city they already imply rather than swapped for another country's, so the page
  // stays internally consistent: a london latitude beside an amsterdam timezone just reads as a bug.
  // the sun times follow from the location and are left alone for the same reason.
  [String.raw`\b5[0-9]\.\d{2,4},\s*-?\d{1,3}\.\d{2,4}\b`, 'g', '52.37, 4.89'],
];
// the toast sits fixed at the centre-bottom and lands in the middle of every picture -- including
// "connected to the runtime", which fires on the connection each shot is waiting for. hide it for
// the duration rather than racing its timeout.
async function hideToast() {
  await cdp.eval(`(() => {
    const t = document.getElementById('toast');
    if (t) { t.classList.remove('show'); t.style.display = 'none'; }
    return true;
  })()`);
}

async function redact() {
  await hideToast();
  if (noRedact) return;
  // stop the timers so a poll cannot repaint over the edits mid-shot
  await cdp.eval(`(() => { const top = setInterval(() => {}, 9e6); for (let i = 1; i <= top; i++) { clearInterval(i); clearTimeout(i); } return top; })()`);
  await cdp.eval(`(() => {
    const swaps = ${JSON.stringify(swaps)};
    const apply = t => swaps.reduce((acc, [src, flags, to]) => acc.replace(new RegExp(src, flags), to), t);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const next = apply(n.nodeValue);
      if (next !== n.nodeValue) n.nodeValue = next;
    }
    for (const el of document.querySelectorAll('input')) {
      if (el.value) el.value = apply(el.value);
      if (el.placeholder) el.placeholder = apply(el.placeholder);
    }
    return true;
  })()`);
  await sleep(250);
}
// put the real address back so the next tab can still talk to the device
async function unredact() {
  if (noRedact) return;
  await cdp.eval(`(() => {
    for (const el of document.querySelectorAll('input')) {
      if (el.value === ${JSON.stringify(DEVICE_FAKE)}) el.value = ${JSON.stringify(DEVICE_REAL)};
    }
    return true;
  })()`);
}

await cdp.setWidth(1280);
const wrote = [];
// the canvas tab photographs as an empty form unless a draft exists, which shows none of what the
// builder does. build one through the real controls -- the draft lives in the browser and nothing
// reaches the device until "send to device" is pressed, so this changes nothing on the clock.
await cdp.tab('canvas');
await cdp.eval(`(async () => {
  const type = document.getElementById('cvtype'), add = document.getElementById('cvadd');
  const wait = ms => new Promise(r => setTimeout(r, ms));
  for (const kind of ['text', 'bar', 'sparkline']) {
    if ([...type.options].some(o => o.value === kind)) {
      type.value = kind;
      type.dispatchEvent(new Event('change', { bubbles: true }));
      add.click();
      await wait(250);
    }
  }
  return document.getElementById('cvcount')?.textContent;
})()`);
await sleep(800);

// note: the scripts tab photographs as an empty editor when the device holds no scripts, which is
// the honest state rather than a fault -- the byte budget, the device list and the output pane are
// all still shown. an attempt to pre-fill a local draft through the ui is not worth the fragility:
// the create button is a form submit and driving it from here threw.
for (const [tab, file] of [
  ['scene', 'console.png'],
  ['send', 'console-send.png'],
  ['canvas', 'console-canvas.png'],
  ['scripts', 'console-scripts.png'],
  ['device', 'console-device.png'],
  ['logs', 'console-logs.png'],
]) {
  await cdp.tab(tab);
  await sleep(900);          // let the tab fetch whatever it fetches on open
  await redact();
  wrote.push(await cdp.shot(join(out, file)));
  await unredact();
}

// there is deliberately no phone-width shot here. one was captured for a while and the readme
// carried it; at 430 css pixels the console stacks into a single column roughly four screens tall,
// which is an honest picture of the page and a useless one in a document -- a sliver too narrow to
// read anything in. the responsive layout is covered by test_layout.mjs instead.

rmSync(profile, { recursive: true, force: true });
for (const f of wrote) console.log(`wrote ${f}`);
shutdown(0);
