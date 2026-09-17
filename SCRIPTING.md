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
| what it costs | 256 kb of heap by default, one process, and one of the two `link_libc = true` binaries (the other is `tc002-audiod`) |

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

there is a library of ready scripts in
[`runtime/scripts/berry/`](runtime/scripts/berry/README.md) — an alarm, a pomodoro, a knob dimmer, a
scrolling ticker, mqtt gauges and charts, a clock that watches its own health — each with its
settings at the top, and all of them run and shaken by `zig build check-scripts` on every build.

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

- **sound is off by default.** `tc002.play` needs `sound.enabled`; see [sound](RUNTIME.md#sound).
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
| `tc002.notify(text, colour, seconds, name, stack, hold)` | trailing arguments optional: colour defaults white, seconds defaults 5, name defaults absent, stack and hold default false | the same queue and overlay `POST /notify` uses; seconds 1–300, names 1–32 ascii letters/digits/`_`/`-` |
| `tc002.dismiss(name)` | name optional; omit for current notification | removes the first matching name, active before waiting; a missing match is a successful no-op, an empty name is invalid |
| `tc002.subscribe(filter[, f])` | an mqtt topic filter, `+` and `#` allowed; optionally a handler | up to thirty-two; see [mqtt](#mqtt) |
| `tc002.unsubscribe(filter)` | the same filter, exactly as given to `subscribe` | frees its slot, tells the broker, drops its handler |
| `tc002.publish(topic, payload)` | | through the device's own broker connection |
| `tc002.play(name, volume, loop)` | volume 1–100 (0 = the setting), loop defaults false | plays a stored sound; see [sound](RUNTIME.md#sound) |
| `tc002.stop_sound()` | | stops whatever is playing |

notifications replace the active overlay by default, preserving waiting entries.
pass `true` for `stack` to append in arrival order, up to eight notifications
including the active one; a full queue rejects the append without changing state.
each timer starts when its notification becomes active. `hold` disables expiry,
so the next entry waits until dismissal, replacement or display takeover.
names are case-sensitive and may repeat: each named dismissal removes only the
first match, checking the active notification first. dismissing a waiting entry
does not restart the active timer.

```berry
tc002.notify('doorbell', 0xffaa00, 5, 'door', true, true)
tc002.notify('parcel arrived', 0x00ff80, 10, 'delivery', true)
tc002.dismiss('door')  # parcel now gets its full ten seconds if door was active
tc002.dismiss()        # dismiss the current notification
```

scene selection, raw frames, stream takeover and stream arming clear the whole
notification queue. power-off preserves it, with timed expiry still running.
the queue is not persistent and is lost on runtime restart. there is no priority
or queue-listing api. sound playback is unchanged and remains separate:
`tc002.dismiss()` does not call `tc002.stop_sound()`.

### `panel` — drawing

| call | arguments | notes |
|---|---|---|
| `panel.clear()` | | empties the document being built |
| `panel.pixel(x, y, colour)` | colour defaults white | |
| `panel.rect(x, y, w, h, colour, filled)` | `w`,`h` default 1; colour white; `filled` 0 | `filled` non-zero fills, otherwise it outlines |
| `panel.text(x, y, text, colour)` | colour defaults white | always the 5×7 `small` face: eight characters is a full line |
| `panel.icon(x, y, name, colour)` | colour defaults white | `name` from `GET /icons` |
| `panel.show()` | | install what you drew as the canvas document |
| `panel.stream()` | | ask for the frame stream |
| `panel.push()` | | send one frame, up to sixty a second |

a document holds **twenty-four elements and 256 bytes of text**, whichever runs out first, and a
script draws in one font: the four faces in [`CANVAS.md`](CANVAS.md) belong to documents sent over
http, and `panel.text` is always the small one. so a chart drawn from a script is a dozen columns
rather than fifty-two, and a label is eight characters rather than a sentence.

the panel is 52×16. `panel.show()` and `panel.push()` are two different things
and the difference matters — see [drawing](#drawing-two-ways).

### events

```berry
tc002.on('button', def (control, event, steps) … end)
tc002.on('mqtt',   def (topic, payload, filter) … end)
tc002.on('ntfy',   def (topic, message, n)     … end)
tc002.every(1000, def () … end)     # every second, for ever
tc002.after(250,  def () … end)     # once, after 250 ms
```

| event | arguments |
|---|---|
| `button` | `control` is `left`, `middle`, `right`, `knob` or `rotary`; `event` is `press`, `release` or `long` for the four buttons and `cw` or `ccw` for the rotary, where `steps` is the detent count |
| `mqtt` | the topic it arrived on, the payload, and the filter that matched |
| `ntfy` | **the topic is always empty** — ntfy has no topic here — the message is the second argument |

`tc002.on` may be called more than once for the same event; every handler runs.

**there is no `click` event.** a click is a *request* — `POST /api/v1/input` with
`"event":"click"` asks for a press and a release — and it arrives as those two edges and no third
thing. nothing has ever reported one, so a script that waits for a click waits for ever. it is not
in the list above for that reason.

**every button has a tap and a hold.** the hold is reported as `long` once held past 700 ms, and
the tap's action is then suppressed — holding `left` does not also select the clock. that is what
makes a hold a gesture rather than a slow press.

**a script cannot swallow either of them.** the device acts on every one:

| gesture | what the device does regardless of your script |
|---|---|
| tap left / middle / right | select the clock, art or canvas base |
| hold left / middle / right | show that base and open its settings menu |
| tap the knob | hand the click to the showing scene — art takes a new seed |
| hold the knob | open the device menu |
| turn the dial | page clock faces on the clock and generators on art; **nothing on the canvas** |

so a script drawing on the canvas is best driven by the **right** button, whose own job is to
select the canvas, and by the dial, which the arbiter deliberately leaves alone on that base — a
script showing a canvas owns the rotary completely. a hold is the wrong gesture for a script to
build on unless you want its settings menu too.


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
holds the list (up to thirty-two) and replays it whenever netd is spawned or the broker
connection comes back, so a reconnect does not silently stop delivering.

a filter is not a prefix. `home/+/state` matches `home/kitchen/state` but not
`home/kitchen/light/state`; `home/#` matches everything below `home/`.

**the refusals are logged, not raised.** `tc002.subscribe` complains only about the topic's own
length. the thirty-two-topic cap and the rule below are both the supervisor's, and it answers a
thirty-third subscription by logging why rather than by failing the call, so `GET /api/v1/logs` is
where a topic that never arrives explains itself.

thirty-two is not a taste judgement — it was eight, and that was. it is what one reconnect can
replay into netd's outbound buffer after the device's own command topics have taken their share,
because every topic here is re-subscribed on every reconnect and a topic that silently stops
arriving afterwards is the worst failure this code has.

that buffer was 4 kb, and adding the `cmd/sound` command topic left the worst-case replay three
bytes inside it. it is 5 kb now, and the sum is a compile-time assertion in
`messages.BerryEvent` rather than arithmetic in a comment, so the next command topic either fits
or fails the build.

**a filter may not cover the device's own command topics.** netd hands a
script-matched arrival to the script and stops there, so `tc002/cmd/#` — or a bare
`#` — would swallow every mqtt command sent to the clock. the supervisor refuses
such a filter and logs why; what the device *publishes* (`state`, `metrics`,
`result`, `screen`) is fair game, so a script may watch its own clock.

**the list belongs to the vm's lifetime.** `tc002.unsubscribe(filter)` gives a slot
back, and every one is dropped when berryd restarts — which is what happens when
`berry.enabled`, the heap or the handler budget change — because a fresh vm has
declared nothing yet. whatever runs then declares its topics again. before this the
list only filled: a deleted script's topic stayed subscribed until the device was
power cycled. a filter the device is no longer subscribed to still reaches nothing
even if the broker is mid-reconnect, because the supervisor's list is what a
reconnect replays.

give `subscribe` a handler and it hears **only that filter's** topics:

```berry
tc002.subscribe('home/+/doorbell', def (topic, payload)
  if payload == 'pressed'
    tc002.notify('doorbell', 0xff0000, 5)
  end
end)
```

every script shares one vm, so without this each `tc002.on('mqtt', …)` saw every
other script's traffic and had to re-check the topic itself. the runtime says which
filter matched — netd is the only process that matches, so the wildcard rules are
not written a second time in berry — and the handler is dropped when its filter is.

`tc002.on('mqtt', …)` still exists and still sees every arrival, for a script that
wants the lot. its third argument used to be `0`; it is now the filter that matched.

```berry
tc002.subscribe('home/+/doorbell')
tc002.on('mqtt', def (topic, payload, filter)
  if payload == 'pressed'
    tc002.notify('doorbell', 0xff0000, 5)
  end
end)
```

the broker is the device's own connection, configured in `/api/v1/mqtt`. if mqtt
is disabled, `subscribe` and `publish` do nothing useful — they do not raise, and
nothing arrives.

**a topic is at most 96 characters and a payload 3,991 bytes** — what an arriving
publish can carry, given the packet buffer netd reads into. an arrival past that
is **not delivered**, and netd logs the topic and the size: half a json document
parses and means something else, so a short delivery would be a wrong answer a
script could not detect. `publish` refuses the same bounds rather than sending a
prefix.

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
| `GET` | `/api/v1/berry/scripts/{name}` | **scripts** (admin) | — the source as `text/plain`, or 404 |
| `PUT` | `/api/v1/berry/scripts/{name}` | **admin** | `text/plain`, at most 8,000 bytes |
| `DELETE` | `/api/v1/berry/scripts/{name}` | **admin** | — |
| `POST` | `/api/v1/berry/scripts/{name}/run` | **admin** | **no body** — runs the stored script |

running a stored script is **admin**, like writing one: asking a script to drive
the panel now is the same kind of act as storing one that will. it takes **no
body** — a run route that accepted source would be the `eval` route this api
deliberately does not have, so one is `400 unexpected_body`. it runs the stored
source and writes nothing back. with berry disabled it says so (`409`) rather
than enabling it as a side effect; with berry enabled but the vm not yet up it
is `503`. a script that raises comes back `400 script_failed` carrying berry's
own message, so `divzero_error: division by zero` reaches the caller rather
than a bare failure.

reading a script back is **control**, the same as listing them: a split where a
token could enumerate names but not read them protects little, and an editor
needs admin to save anyway. the source comes back byte for byte as stored, so
`GET` then `PUT` is a faithful round trip.

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

## the browser editor

`panel-v2/start-panel.sh [--mock] [--open]` opens the runtime console. its
**scripts** tab lists device scripts and local drafts, reads source from the
device, and provides syntax highlighting, line numbers, block indentation,
compile-error navigation and a shared device-log view. the source stays exactly
as typed, including case. the editor counts the 8,000-byte limit in utf-8 bytes.

- **create local draft** only creates browser state. opening or editing a script
  does not write to the device.
- **save** (also command/ctrl+s) reads the latest device source before writing.
  identical source skips the put, including after a lost save response. a source
  changed by another client is shown for comparison and requires an explicit
  overwrite or discard. a refused save retains the draft and its error.
- **run saved** posts to the named-run route without a body. it never saves local
  edits, enables scripting or writes settings. **save & run** saves only changed
  source and runs only after save succeeds. there are no debugger controls.
- **delete from device** confirms for the selected script and retains a local
  recovery draft. **discard local draft** confirms separately, reads the device
  version again and removes the browser draft. **download draft** exports source
  without a device write.

localstorage holds drafts immediately on input, with the device address, script
name and the source version they were based on. it also remembers the selected
script per device. reloads and script/device switches recover that work without
uploading it. storage is scoped to this browser and console origin: changing the
proxy port uses a different store; clearing browser storage removes drafts.
proxy authentication tokens are never placed in webstorage.

storage denial, quota exhaustion or a conflicting browser tab leaves the current
text in memory, displays a warning and protects page unload while any such draft
remains, even after switching scripts or devices. download that draft before
closing. a stale tab cannot silently replace the other tab's stored draft; it
keeps its own text in memory. a browser crash cannot preserve memory-only work.

source comparison is a preflight read, not an atomic conditional write: the api
has no compare-and-swap, so another client can still race between read, save and
run. running executes whatever source is stored when the device handles it.
when scripting is disabled the editor identifies uncompiled saves and leaves
enabling it to an explicit settings change. output is the shared log because
plain `print()` lines have no source metadata; filtering for the word berry would
hide valid script output.

editor tests: `node --test test_scripts.mjs`, `node --test test_layout.mjs`, and
`python3 -m unittest test_serve test_scripts_proxy`, from `panel-v2/`.
the browser suite checks real source round trips through the proxy/mock and uses
a deterministic execution fixture for run failures and flash-write counts.

## testing scripts

`zig build test-berry` runs `.be` fixtures in `runtime/test/berry/` through the
same interpreter the device runs, on the host, with the bindings installed and the
messages recorded rather than sent:

- a sibling `.expected` file asserts what the script printed
- a sibling `.emits` file asserts the messages it produced
- a fixture named `*.fail.be` **must** fail — that is the harness testing itself

`zig build check-scripts` is the same harness pointed at `runtime/scripts/berry/` with `--exercise`,
which fires the events the device really produces at whatever each script registered — every button
edge, the dial both ways, an mqtt arrival on each filter a script subscribed to with nineteen
payloads that are as often wrong as right, the same as ntfy messages, and about seven seconds of timer ticks
followed by an hour in one jump. a handler that raises is caught by the prelude and printed rather
than thrown, so the check reads the output: silence is the pass.

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
- [`runtime/scripts/berry/README.md`](runtime/scripts/berry/README.md) — the script library, and
  the panel and input facts every one of them is written around
- [`CANVAS.md`](CANVAS.md) — every font, icon and drawing primitive, in pictures
- [`SECURITY.md`](SECURITY.md#the-custom-runtime-runtime) — what running user
  scripts on the device does and does not expose
