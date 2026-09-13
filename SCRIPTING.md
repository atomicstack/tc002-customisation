# scripting the tc002

the custom runtime in [`RUNTIME.md`](RUNTIME.md) runs
[berry](https://github.com/berry-lang/berry) scripts on the device: react to the
buttons, the knob, mqtt, ntfy and timers; draw on the panel; and — when a script
asks for it — own all 832 pixels at sixty frames a second.

this is the one part of the runtime a user can change without rebuilding it.

**it is off by default.** a device that has never been told to run scripts is not
running one, and `tc002-berryd` is not even spawned. everything below assumes you
turned it on.

| | |
|---|---|
| the interpreter | [berry](https://github.com/berry-lang/berry), vendored at `runtime/vendor/berry/` (upstream `6e6e621`, mit, `coc` output committed) |
| the process | `tc002-berryd`, uid 1001, spawned by the supervisor only while `berry.enabled` |
| where scripts live | `config/scripts.bin` on `/data`, so they survive a power cycle |
| what it costs | 256 kb of heap by default, one process, and the only `link_libc = true` binary in the runtime |

## quick start

```bash
# 1. turn it on (admin token; berryd is spawned as a result)
tools/tc002ctl.py -s 10.0.0.111 --token-file tokens config-set berry_enabled=true

# 2. store a script. `autoexec` is the name that runs by itself.
cat > hello.be <<'EOF'
tc002.notify('hello from berry', 0x00ff00, 3)
tc002.on('button', def (control, event, steps)
  tc002.notify(control + ' ' + event, 0xffaa00, 2)
end)
EOF
curl -X PUT --data-binary @hello.be \
  -H "authorization: Bearer $ADMIN_TOKEN" -H 'content-type: text/plain' \
  http://10.0.0.111/api/v1/berry/scripts/autoexec

# 3. see what is stored, and what the vm is doing
curl -H "authorization: Bearer $TOKEN" http://10.0.0.111/api/v1/berry/scripts
curl -H "authorization: Bearer $TOKEN" http://10.0.0.111/api/v1/berry
```

a script is **compiled before it is stored**. one that will not parse is refused
with `400 script_will_not_compile` carrying berry's own message, and never
reaches flash — so a typo cannot leave the device with a script that breaks it on
every boot.

## the language

berry is a small dynamically-typed language with a one-pass compiler and a
register vm: `var`, `def`, `if`/`elif`/`else`, `while`, `for … : …`, `try`/
`except`, classes, lists (`[]`), maps (`{}`), and `import`. the
[upstream reference](https://github.com/berry-lang/berry) is the language
authority; this document covers only what the device adds.

two things to know here specifically:

- **there is no filesystem and no network.** `import os`, `open()`, sockets —
  none of it. see [what a script cannot do](#what-a-script-cannot-do).
- **`print` goes to the log ring.** berryd's stdout is read by the supervisor like
  any other child's, so `print('x')` shows up in `GET /api/v1/logs`. that is the
  debugger.

## the device api

two globals, `tc002` and `panel`, assembled by a prelude in
`runtime/src/berry/api.zig` — which is the only place the script-facing names are
written down, and the file to read if this document and the device disagree.

the vocabulary is deliberately the http api's: bases are `clock|art|canvas`,
icons are the names `GET /icons` lists, colours are `0xrrggbb` or `'rrggbb'`. a
call turns into the same ipc message an http request turns into, and hears the
same refusal — `tc002.brightness(0)` raises rather than quietly clamping.

### `tc002` — the device

| call | arguments | notes |
|---|---|---|
| `tc002.scene(name)` | `'clock'`, `'art'` or `'canvas'` | |
| `tc002.brightness(n)` | 1–100 | outside the range it raises |
| `tc002.notify(text, colour, seconds)` | colour defaults white, seconds defaults 5 | the same overlay `POST /notify` uses |
| `tc002.subscribe(filter)` | an mqtt topic filter, `+` and `#` allowed | up to eight; see [mqtt](#mqtt) |
| `tc002.publish(topic, payload)` | | through the device's own broker connection |

### `panel` — drawing

| call | arguments | notes |
|---|---|---|
| `panel.clear()` | | empties the document being built |
| `panel.pixel(x, y, colour)` | colour defaults white | |
| `panel.rect(x, y, w, h, colour, filled)` | `w`,`h` default 1; colour white; `filled` 0 | `filled` non-zero fills, otherwise it outlines |
| `panel.text(x, y, text, colour)` | colour defaults white | |
| `panel.icon(x, y, name, colour)` | colour defaults white | `name` from `GET /icons` |
| `panel.show()` | | install what you drew as the canvas document |
| `panel.stream()` | | ask for the frame stream |
| `panel.push()` | | send one frame, up to sixty a second |

the panel is 52×16. `panel.show()` and `panel.push()` are two different things
and the difference matters — see [drawing](#drawing-two-ways).

### events

```berry
tc002.on('button', def (control, event, steps) … end)
tc002.on('mqtt',   def (topic, payload, n)     … end)
tc002.on('ntfy',   def (topic, message, n)     … end)
tc002.every(1000, def () … end)     # every second, for ever
tc002.after(250,  def () … end)     # once, after 250 ms
```

| event | arguments |
|---|---|
| `button` | `control` is `left`, `middle`, `right`, `knob` or `rotary`; `event` is `press`, `release`, `click`, `long`, `cw` or `ccw`; `steps` matters for the rotary |
| `mqtt` | the topic it arrived on, the payload, and `0` |
| `ntfy` | **the topic is always empty** — ntfy has no topic here — the message is the second argument |

`tc002.on` may be called more than once for the same event; every handler runs.

**a handler that raises is caught, named in the log, and left registered** — one
bad event is not a reason to stop listening. but ten failures in a row and it is
dropped, because a handler that fails on every event would otherwise fill a
64-line log ring at event rate and destroy the evidence of everything else.
timer failures are caught and logged the same way, and the timer keeps running.

## drawing: two ways

**`panel.show()` installs a canvas document.** the elements you drew become the
canvas scene, the renderer owns it from then on, and it survives until something
replaces it. this is the cheap way, and the right one for anything that is not
animating every frame.

**`panel.stream()` then `panel.push()` owns the pixels.** `push` renders what you
drew into an actual 2,496-byte frame — in zig, against the renderer's own canvas
code — and sends it as a `stream_frame`.

a stream frame is a **different ipc message** from a discrete `frame`, not a
faster one. `frame` passes through the renderer's deduplication window (128 ids
for sixty seconds), which caps discrete commands at about **two a second**. a
stream frame is idempotent — the last one wins, a lost one is a lost frame and
not a lost side effect — so there is nothing for dedup to protect and it is
carried ahead of it.

it never bumps the revision, because sixty state changes a second is not a state
change, and it lands in the same overlay slot a raw frame uses, so **a button
press clears it**. the user always wins.

every stream frame carries `frame_timeout_ms` (100–2000, default 500) as a
deadman: if a script dies mid-animation the panel clears itself rather than
freezing on the last frame.

measured on the device: a bouncing block pushed by a script ran at **60 fps
sustained — 720 frames in 12 s — at 5% cpu**, using 22 kb of a 256 kb heap.

```berry
# a block that bounces at 60 fps
var x = 0, dx = 1
panel.stream()
tc002.every(16, def ()
  panel.clear()
  panel.rect(x, 6, 4, 4, 0x00aaff, 1)
  panel.push()
  x += dx
  if x <= 0 || x >= 48 dx = -dx end
end)
```

## mqtt

`tc002.subscribe(filter)` takes an mqtt topic filter, wildcards included. the
subscription is **not a setting**: a script declares it at runtime, the supervisor
holds the list (up to eight) and replays it whenever netd is spawned or the broker
connection comes back, so a reconnect does not silently stop delivering.

a filter is not a prefix. `home/+/state` matches `home/kitchen/state` but not
`home/kitchen/light/state`; `home/#` matches everything below `home/`.

```berry
tc002.subscribe('home/+/doorbell')
tc002.on('mqtt', def (topic, payload, n)
  if payload == 'pressed'
    tc002.notify('doorbell', 0xff0000, 5)
  end
end)
```

the broker is the device's own connection, configured in `/api/v1/mqtt`. if mqtt
is disabled, `subscribe` and `publish` do nothing useful — they do not raise, and
nothing arrives.

## the script store

`config/scripts.bin` on `/data`, written with the same `saveFileAtomic` as
`canvas.bin`. not a directory — `sys/linux.zig` has no `readdir`, and a directory
cannot be updated atomically, so a power cut mid-save could leave a half-written
set — and not a fixed number of slots either. the bounds are the physical ones:

| bound | value | where it comes from |
|---|---|---|
| one script | 8,000 bytes | it must reach berryd in one ipc datagram; there is no chunking |
| the whole store | 64 kb | the supervisor's static save buffer, and the arena it implies |
| one name | 32 bytes | it is a path segment and a log token: letters, digits, `-`, `_`, `.` |

the count is whatever fits, and a full store reports `n of 65536 bytes used`
rather than "no free slot". **compiled berry is about 2.3× its source** on this
device, so the heap, not the store, is usually what runs out first.

**`autoexec`** is the one magic name: the script called that runs once berryd has
been handed the whole set. that is what makes a script survive a power cycle.

### routes

| method | path | token | body |
|---|---|---|---|
| `GET` | `/api/v1/berry` | control | — `{"state","heap_bytes","heap_used","heap_high_water","alloc_failures","stops"}` |
| `GET` | `/api/v1/berry/scripts` | control | — `{"used","budget","scripts":[{"name","bytes","compiled"}…]}` |
| `PUT` | `/api/v1/berry/scripts/{name}` | **admin** | `text/plain`, at most 8,000 bytes |
| `DELETE` | `/api/v1/berry/scripts/{name}` | **admin** | — |

writing a script needs the **admin** token, not the control token: a script can
drive the panel for ever, so storing one is a different kind of act from sending
one notification. there is deliberately **no `eval` route** — nothing accepts
source and runs it without storing it, so there is no arbitrary-code surface to
gate separately.

## what a script cannot do

| bound | mechanism |
|---|---|
| memory | one fixed arena (`berry.heap_kb`, default 256 kb). full, and berry raises; nothing else on the device notices |
| cpu | berry's observability hook fires every 2¹⁶ instructions — about 7.8 ms here — and stops a handler past `berry.handler_ms` (default 100 ms) |
| a wedged vm | berryd reports every second; two seconds of silence and the supervisor kills and restarts it. a script looping forever leaves the process alive and silent, so silence is the only signal there is |
| a dead script mid-animation | every stream frame carries `frame_timeout_ms`; the panel clears itself |
| the network | berryd holds no network descriptor: it cannot bind, connect or resolve |
| the filesystem | `BE_USE_FILE_SYSTEM` is off, `be_filelib.c` is not compiled in, and the four entry points the linker still wants refuse in `port/be_port.c`. `open()` raises `io_error` |
| settings, tokens, credentials | there is no binding for them. scripts change what is on the panel, not what the device is |

the two watchdogs are deliberately ordered: a runaway handler dies at 100 ms,
twenty times over before the two-second silence threshold could make the
supervisor think berryd itself is wedged.

## settings

patched through `/api/v1/config` like any other setting:

| field | range | default |
|---|---|---|
| `berry_enabled` | bool | `false` |
| `berry_heap_kb` | 16–256 | 256 |
| `berry_handler_ms` | 10–1000 | 100 |

berryd takes its heap once and cannot resize it under a live vm, so **any berry
settings change replaces the process** rather than reconfiguring it. scripts are
reloaded from the store and `autoexec` runs again.

## testing scripts

`zig build test-berry` runs `.be` fixtures in `runtime/test/berry/` through the
same interpreter the device runs, on the host, with the bindings installed and the
messages recorded rather than sent:

- a sibling `.expected` file asserts what the script printed
- a sibling `.emits` file asserts the messages it produced
- a fixture named `*.fail.be` **must** fail — that is the harness testing itself

one number does not transfer: compiled berry is **2.3× its source on 32-bit arm
and 2.8× on a 64-bit host**, so heap figures from the harness are not the
device's.

## when something does not work

- **`print` is the debugger.** it reaches `GET /api/v1/logs`, which
  `tools/tc002ctl.py … logs --follow` will tail for you.
- **a handler that raises is logged with its message** and stays registered, until
  ten consecutive failures drop it — and that drop is logged too.
- **`GET /api/v1/berry`** reports `heap_used`, `heap_high_water`, `alloc_failures`
  and `stops`. a rising `stops` means handlers are being cut off at
  `berry_handler_ms`; a non-zero `alloc_failures` means the heap is too small.
- **the script is stored but nothing happens**: only `autoexec` runs by itself.
  anything else has to be called from it.
- **`state` is `failed`** in `GET /api/v1/berry`: berryd could not start or kept
  dying; the log ring says why.

## see also

- [`RUNTIME.md`](RUNTIME.md#scripting-berry) — where berryd sits in the runtime,
  and the ipc it speaks
- [`runtime/vendor/berry/README.md`](runtime/vendor/berry/README.md) — the
  vendored interpreter: the config table and everything changed from upstream
- [`CANVAS.md`](CANVAS.md) — every font, icon and drawing primitive, in pictures
- [`SECURITY.md`](SECURITY.md#the-custom-runtime-runtime) — what running user
  scripts on the device does and does not expose
