# the custom runtime (`runtime/`)

a replacement for the stock application on the tc002: four static arm binaries
and one tiny shared object, written in zig 0.16 with no libc, that take over
the panel, the buttons and the knob, and expose an authenticated http and mqtt
api of their own. while it runs, the stock `zkgui` app (and with it the stock
http api on port 80, the cloud client, the built-in apps) is not running.

everything here is **volatile**: binaries, logs, credentials and settings live
under `/tmp/tc002/`, the boot hook is `/tmp/EasyUI.cfg`, and nothing is written
to flash or `/data`. a power cycle always comes back stock. this document is
the reference for what the code does; how to build and run it is in
[`runtime/README.md`](runtime/README.md).

## processes

| binary | runs as | size¹ | role |
|--------|---------|------:|------|
| `libtc002-bootstrap.so` | inside the vendor loader | 1.8 kb | the "startup library" the loader `dlopen`s. its constructor `execve`s the supervisor in place, passing `--from-bootstrap` and the loader's environment. no libc, no `DT_NEEDED`. if the exec fails it prints one line and exits 1; it never touches the anti-brick property |
| `tc002-supervisor` | root | 384 kb | sets `sys.zkapp.state=running` first, then owns everything privileged: spawns and watches the renderer, binds port 80, generates the api tokens, keeps the settings file, reads the maintenance gesture, polls `wlan0`, relays api commands, samples `/proc` |
| `tc002d` | root | 255 kb | the renderer. the only process that opens `/dev/spidev0.0` and the latch gpio. scenes, overlays, physical input, paced presentation, heartbeats |
| `tc002-netd` | uid 1001 | 396 kb | the network daemon: an http/1.1 server for `/api/v1` and an mqtt 3.1.1 client. holds no authoritative state; every command is relayed through the supervisor to the live renderer |
| `tc002-memdump` | root, by hand | 171 kb | a maintenance tool that streams a sparse memory snapshot of one process over adb ([memory audits](#memory-audits)) |

¹ ReleaseSafe, stripped, as built on 2026-09-06. `-Doptimize=ReleaseSmall` gives
roughly 66 / 147 / 170 kb for the three daemons. on the volatile path the
binaries sit in tmpfs, so their size is ram.

the split follows one rule: the supervisor is the only privileged process that
parses nothing from the network, the renderer is the only process that touches
the panel, and the network daemon can be killed and restarted at any time
without the display noticing. all three are single-threaded epoll loops with
static buffers and no steady-state allocation; every state machine, codec and
scene is a pure module with host tests (102 of them pass under `zig build
test` on macos).

## how it gets started

the stock app is the init service `zkswe`: a loader (`zkgui`) that reads
`EasyUI.cfg`, brings up the display and network manager, and `dlopen`s the
application library named by `startupLibPath`. two facts, both measured on a
warm device (details in [what has been measured](#what-has-been-measured)),
make the takeover possible without touching flash:

- the loader reads **`/tmp/EasyUI.cfg` before `/res/etc/EasyUI.cfg`** (it logs
  `load /tmp/EasyUI.cfg ok!`), so a copy with `startupLibPath` pointing at the
  bootstrap is enough.
- `zkdaemon` reflashes the app partition if `sys.zkapp.state` is not `running`
  within about 15 s of boot ([`DEVICE.md`](DEVICE.md)). the supervisor's very
  first action is a bounded `/bin/setprop sys.zkapp.state running` (2 s
  timeout); if that fails it exits with code 2 rather than carry on. measured:
  accepted 10 ms after entry.

so the chain is `init` → `zkgui` loader → `dlopen(libtc002-bootstrap.so)` →
constructor `execve(tc002-supervisor --from-bootstrap)` → the supervisor **is
now the `zkswe` service process** (same pid, `init.svc.zkswe=running`), and
init restarts the whole chain about a second after it dies. the loader hands
over a handful of descriptors (`/dev/fb0`, a font, the property workspace, an
inotify fd, a pipe, `/dev/input/event67`) and `/dev/null` on stderr; the
supervisor logs every inherited fd, signal mask and environment name (never
values), can close them all (`--close-inherited`), and redirects its log to
`/tmp/tc002/supervisor.log` when it came from the bootstrap.

`tools/tc002-run.sh start` is the simpler path for development: it stops
`zkswe`, starts the supervisor from an adb shell, and `stop` restores the stock
app. `tools/tc002-boot-experiment.sh` is the loader path above.

**power:** the stock app is what polls the mcu for battery level and shuts the
device down at 3550 mv. the runtime does not talk to the mcu at all, so run it
on usb power. nothing here reads the battery.

## the supervisor

```
usage: tc002-supervisor [options]
  --profile dev|hardened  dev leaves adbd alone; hardened resets persist.sys.zkdebug=0 at boot (dev)
  --renderer PATH         candidate renderer (/tmp/tc002/tc002d)
  --fallback PATH         fallback renderer after three failures in sixty seconds (same as --renderer)
  --dir PATH              runtime directory (/tmp/tc002)
  --lock PATH             panel lock file (/tmp/tc002/panel.lock)
  --tz RULE               posix tz rule handed to the renderer (UTC0)
  --keymap L,M,R,K        keycodes for left, middle, right, knob (105,103,106,108)
  --keys PATH             button evdev node (/dev/input/event67)
  --knob PATH             rotary evdev node (/dev/input/event68)
  --ip-poll S             seconds between wlan0 address checks (5)
  --no-property           do not set sys.zkapp.state (host-less experiments only)
  --close-inherited       close every inherited descriptor above stderr after the audit
  --stats                 ask the renderer for periodic statistics
  --from-bootstrap        set by the bootstrap shared object; logged only
```

### renderer lifecycle

the renderer is a child on a private `SOCK_SEQPACKET` socketpair (its fd 3),
with `PR_SET_PDEATHSIG` so it dies with the supervisor, an empty environment
and an exact argv. the supervisor never starts a renderer while
`/tmp/tc002/panel.lock` is held by someone else. the lifecycle is a pure state
machine driven by monotonic time:

| rule | value |
|------|-------|
| `ready` must arrive after spawn within | 10 s |
| heartbeat period (from the renderer's real loop) | 250 ms |
| missing heartbeats before a stop is requested | 2 s |
| graceful stop (`stop` packet + `SIGTERM`) escalates to `SIGKILL` after | 2 s |
| restart delay after a failure | 1 s, 2 s, then 5 s |
| three failures within 60 s | switch from the candidate binary to the fallback; three more → **halt** (no renderer, supervisor stays up) |
| healthy for 60 s | the running slot is confirmed once and the failure counter resets |
| a stop the supervisor asked for | not counted as a failure |

each spawn gets a new **epoch** (1, 2, …). commands carry the epoch they were
issued against, and a renderer rejects commands from an older epoch with
`stale_epoch`, so a client cannot re-apply a command to a restarted renderer
by accident. on `ready` the supervisor pushes the saved brightness, base scene,
generator and timezone, and the current ip.

### the maintenance gesture and profiles

the supervisor reads the button device itself (independently of the renderer)
and recognises the **knob held for 3 s**. a key already down at startup is
detected through `EVIOCGKEY`. what the gesture does depends on the profile:

| profile | at boot | on the gesture | 15 min later |
|---------|---------|----------------|--------------|
| `dev` (default) | nothing | logged only | logged only |
| `hardened` | `persist.sys.zkdebug=0` (adbd off) | `persist.sys.zkdebug=1` (adbd on) | `persist.sys.zkdebug=0` |

a second hold during the window extends it. the hardened profile has not been
exercised on the device (nobody has pressed the knob during a run).

### settings, credentials, the listener

- **credentials**: two 32-byte random tokens (control, admin) generated once
  into `/tmp/tc002/credentials/tokens` (mode 0600, directory 0700) and handed
  to netd over the channel. netd never reads the file; nothing in the runtime
  ever logs them.
- **settings**: `/tmp/tc002/config/config.json`, written atomically (temp
  file, fsync, rename, directory fsync). every accepted patch bumps
  `revision`; `saved_revision` follows on an explicit save; a patch can name
  the revision it expects and is refused with `conflict` if it is stale. the
  model is in [settings](#settings).
- **the listener**: port 80 is bound by root with `SO_REUSEADDR`, then netd
  is forked with exactly two inherited descriptors (fd 3 the channel, fd 5 the
  listener), privileges dropped to uid/gid 1001 with no supplementary groups
  (verified, not assumed), and restarted 1 s after any exit. if the bind fails
  the api is simply unavailable and the display keeps working.

### the log ring

every runtime process logs one line per `write(2)` to its stderr, prefixed
with a utc timestamp of fixed width, the program and the level:
`[2026-09-08 04:36:30.00001] tc002-supervisor info renderer ready 7 ms after
spawn` (the fraction is tens of microseconds, zero-padded; before the first
sntp sync the date is whatever the device clock says). the
supervisor hands both children a non-blocking pipe as their stdout and stderr,
drains it in its event loop, appends each line to `supervisor.log` as before,
and keeps the last 64 lines (160 bytes each, 10 kib of static storage) in a
ring numbered from 1; its own lines join the ring through a hook in the
logger. netd serves the ring through `GET /logs?after=N`, sixteen lines a
page. a child that logs faster than the supervisor drains loses lines rather
than blocking in `write(2)`; the file and the ring are equally affected.

### what it samples

every 5 s the supervisor reads `MemAvailable` from `/proc/meminfo`, cpu
utilisation from `/proc/stat`, and `VmRSS` of the three processes, and derives
achieved fps from the renderer's `presented` counter over windows of at least
2 s. that snapshot is what `/api/v1/status` and the mqtt `state` and `metrics`
topics report. two honesty notes: this 4.9 kernel reports `VmRSS` = 4 kb for
every static process (it is wrong; use `tc002-memdump`), and the values are
reported as-is with a `sample_age_ms`. `wlan0`'s address is polled every
`--ip-poll` seconds through `SIOCGIFADDR` and pushed to the renderer on change.

### time (sntp)

with `ntp_server` set, the supervisor runs a minimal sntp client (rfc 4330)
on one udp socket connected to that ipv4 address on port 123: no dns, no
thread, no rtc. it sends a 48-byte ntpv4 request as soon as wlan0 has an
address and then every `ntp_interval_s` (300 or 600). a reply is accepted only
when it echoes the request's transmit timestamp, comes from a synchronised
server with stratum 1..15, carries nonzero server timestamps, a date within
twenty years of the client's build date (the era reference: a 1970 clock after
a cold boot still resolves the 32-bit ntp seconds to the right era) and a round
trip under one second. offset and delay are computed from all four timestamps.
an offset of 128 ms or more is stepped with `clock_settime` and the renderer
receives `time_corrected` so the clock scene rearms its wall-clock deadline; a
smaller one is slewed by the kernel (`adjtimex` single-shot at 500 ppm, so
128 ms takes about four minutes). failures back off 2, 4, 8 … seconds up to the
interval; a kiss-o'-death `RATE` doubles the wait and `DENY`/`RSTR` stop
polling until the settings change. the status `time.state` is `unsynced`
until the first success, `synced` after it and `stale` when no success arrived
within one hour (or three intervals, whichever is longer); `time.age_s` counts
seconds since the last success. there is no frequency discipline: between polls
the ~70 ppm oscillator drift accumulates (about 21 ms per 300 s) and is taken
out at the next exchange. measured on 2026-09-07 against the home assistant
host's chrony (stratum 3): first exchange −187 ms offset at 25 ms round trip,
stepped; the following exchanges within ±10 ms at 2 ms round trip, slewed.

## the renderer (`tc002d`)

```
usage: tc002d [options]
  --ipc-fd N          supervisor channel (SOCK_SEQPACKET); omit for standalone runs
  --epoch N           renderer epoch given by the supervisor (1)
  --lock PATH         panel lock file (/tmp/tc002/panel.lock); created if standalone
  --spi PATH          spidev node (/dev/spidev0.0)
  --gpio PATH         latch gpio value file (/sys/class/gpio/gpio35/value)
  --keys PATH         button evdev node (/dev/input/event67)
  --knob PATH         rotary evdev node (/dev/input/event68)
  --keymap L,M,R,K    keycodes for left, middle, right, knob (105,103,106,108)
  --tz RULE           posix tz rule for the clock (UTC0)
  --base art|clock|ip initial base scene (art)
  --generator N       initial art generator index (0)
  --seed N            art seed, 0 = from the clock (0)
  --brightness N      1..100 (100)
  --seconds S         stop after s seconds, 0 = run until stopped (0)
  --crossfade-ms N    cross-fade between scenes, 0..5000, 0 = none (500)
  --power-fade-ms N   fade to and from black on power changes, 0..5000 (600)
  --dry-run           never open spidev/gpio; model the panel only
  --stats             log achieved cadence every 5 s
```

it can run standalone (no `--ipc-fd`) for smoke tests, and `--dry-run` runs
the whole loop without hardware. it takes an exclusive `flock` on the panel
lock and refuses to start if another renderer holds it.

### scenes and overlays

the visible output is one **base** scene plus at most one temporary
**overlay**:

| base | what it shows | redraw cadence |
|------|---------------|----------------|
| `art` | a generator: `popsquares` (the same cell simulation as [`led/`](LED-SPI.md#led-native-popsquares-at-60-fps)) or `plasma` (integer sum-of-sines) | continuous, 60 hz |
| `clock` | local time from a posix tz rule (`AEST-10AEDT,M10.1.0,M4.1.0/3` style, with `Mm.w.d` transitions) or an iana zone name, in one of five fonts and a solid or gradient colour; see [clock styles](#clock-styles) and [time zones](#time-zones) | once per wall-second boundary |
| `ip` | the ipv4 address on two lines, or `no ip` | on change only |

| overlay | bounds | behaviour |
|---------|--------|-----------|
| notification | 1–128 printable ascii characters, a colour, 1–300 s | centred if it fits; otherwise scrolls in from the right one pixel per 33 ms and wraps |
| raw frame | exactly 2,496 rgb888 bytes (52×16×3), 1–300 s | shown as-is |
| stream arming | 2 s | a placeholder for the streaming feature; falls back to the base when nothing arrives |

a new notification or frame replaces the current overlay; expiry reveals the
base; selecting a base clears any overlay. every visible change bumps a
**revision** counter that the api reports back, so a client can tell whether a
command had an effect. brightness is 1–100 (never fully off) and is applied
before the panel's level curve ([`LED-SPI.md`](LED-SPI.md)): 0 stays 0, 1..255
land on 50..255.

**display power** is a separate switch (`power` action, `cmd/action`): off
fades the output to black over 600 ms and then stops redrawing altogether (no
art stepping, no transfers, no cpu); on fades back in. scene selection,
notifications and brightness keep applying while the panel is dark, so it
shows the current state when it comes back. **cross-fades** blend the frame
that was on the panel into the new output over 500 ms whenever the base, the
generator or a notification changes (start or end); raw frames, reseeds and
brightness switch at once. both durations are renderer options; 0 disables.

### clock styles

a clock style is `{font, colour_mode, colour, colour2, gradient, spread}`:

| font | digits | what is shown | width |
|------|--------|---------------|------:|
| `classic` | the built-in 5×7 font | `hh:mm:ss` | 47 px |
| `mini` | 3×5 | `hh:mm:ss` on rows 2–6 and the date `dd/mm` on rows 9–13 | 27 px |
| `segment` | seven-segment 5×9, generated from a segment table | `hh:mm:ss` | 39 px |
| `big` | the classic digits scaled to 10×14 | `hh:mm` (no seconds) | 52 px, edge to edge |
| `block` | the stock clock's face: 6×10 digits with two-pixel strokes, a flagged 1 with a base, a 2×2-dot colon | `hh:mm:ss` | 47 px |

everything is centred. `colour_mode` is `solid` (`colour` only) or `gradient`:
a linear ramp from `colour` to `colour2` across the text's bounding box,
`horizontal`, `vertical` or `diagonal`. `spread` (0–255, default 255) bounds
how far any channel of the end colour may sit from the start colour: at 255
the whole requested ramp is shown; a smaller value pulls the end colour
towards the start for a subtler shade shift (the status reports the
requested `colour2`, the panel shows the bounded one). a style change while
the clock is showing cross-fades like a scene change.

the style has two homes. the settings (`clock_font`, `clock_colour_mode`,
`clock_colour`, `clock_colour2`, `clock_gradient`, `clock_spread`, admin over `PATCH /config`)
are the durable defaults, applied live and restored on every renderer start.
`PUT /scene` and `cmd/scene` take a transient `clock` object with any subset
of the six fields (`font`, `colour_mode`, `colour`, `colour2`, `gradient`, `spread`)
for automations, exactly like a transient generator choice for art; the next
settings change or renderer restart returns to the defaults. `/status` and
the retained `state` report the effective style under `clock`.

### time zones

the `timezone` setting (and the supervisor's `--tz`) takes either a posix
rule or an iana zone name such as `Europe/Amsterdam` or `Australia/Melbourne`.
the supervisor carries a table of 597 zone names with the posix rule each
zone follows from now on, generated by `tools/gen-zones.py` from the footers
of a tzdata directory (`runtime/src/zones.zig`, about 22 kb, in the
supervisor only: the renderer still receives a plain rule). daylight saving
therefore follows each zone's current law with no database on the device;
historical rule changes are not modelled, and the two african zones on
permanent summer time are stored as their fixed summer offset. regenerate the
table when tzdata changes. names match case-insensitively; a name the table
does not know is rejected with `400 rejected`.

### physical controls

| control | in `art` | in `clock` / `ip` |
|---------|----------|-------------------|
| left button (release) | select `art` | select `art` |
| middle button (release) | select `clock` | select `clock` |
| right button (release) | select `ip` | select `ip` |
| knob rotate | next / previous generator | brightness ± 5 |
| knob short press | reseed the art | nothing |
| knob long press (700 ms) | arm streaming | arm streaming |

the keycode assignment (`105,103,106,108` = left, middle, right, knob) is the
working guess from the gpio-keys driver and has not been confirmed by pressing
buttons on the device; it is overridable with `--keymap`, and a press on a
keycode outside the map is logged (`unmapped keycode N pressed`) so the map
can be corrected from the log route. the rotary encoder reports an absolute
counter, which is decoded as 8-bit with wrap-around. actions are queued eight
at a time per loop iteration; overflow is counted and logged, never blocks.

every edge is also reported outward: each button press and release, the
knob's long hold, and every rotary detent with the running position (cw
positive, from renderer start). the supervisor forwards them to netd, which
publishes them on mqtt as momentary events (see [mqtt](#mqtt)). the same
controls can be driven remotely (`POST /input`, `cmd/input`): an injected
`click` is a press and a release through the same mapper, so it produces the
same actions and the same outward events as a finger would.

### presentation

the panel's mcu double-buffers: a pulsed spi transfer stores the new frame
and makes the *previous* one visible. the renderer models that explicitly
(intended, buffered and visible versions) and derives two cadences from it:

- **continuous** (art, scrolling text): one transfer per 60 hz deadline,
  accepting one frame of lag. a missed deadline resynchronises to now rather
  than bursting to catch up.
- **isolated** (a clock tick, an ip change, brightness, a notification, a
  frame, the final black): the latest intended frame is sent, paced at least
  16.667 ms apart, until it is visible. a newer update that arrives while an
  older one awaits its latch simply becomes the next frame sent.

a transfer is gpio 35 low, 1 ms, 3,072 bytes to spidev at 10 mhz, 1 ms, gpio
35 high, exactly as the stock library does it; the latch is always released
even after a failed write. a graceful stop (signal, `stop` packet, or the
supervisor's channel closing) submits a black frame and exits once it is
visible or after 300 ms, then releases the lock. measured on the device: art
runs at 59.7–59.9 fps with zero short writes; the clock produces exactly two
transfers per second and nothing in between.

## the local channel (ipc)

supervisor ↔ renderer and supervisor ↔ netd use the same framing on
`SOCK_SEQPACKET` unix sockets, one packet per message, at most 4,096 bytes:

| offset | size | field |
|-------:|-----:|-------|
| 0 | 4 | magic `TCI1` |
| 4 | 1 | version (1) |
| 5 | 1 | message kind |
| 6 | 2 | reserved, zero |
| 8 | 8 | request id (big-endian) |
| 16 | 4 | renderer epoch |
| 20 | 2 | payload length |
| 22 | 2 | reserved, zero |
| 24 | n | payload |

| direction | kinds |
|-----------|-------|
| renderer → supervisor | `heartbeat` (presented count, revision, state, base, generator, overlay, brightness), `ready`, `result` |
| supervisor → renderer | `set_base`, `notify`, `frame`, `brightness`, `reseed`, `arm_stream`, `time_corrected`, `ip_changed`, `stop`, `set_timezone` |
| supervisor → netd | `credentials`, `config`, `status`, `result`, `save_result` |
| netd → supervisor | `status_get`, `config_get`, `config_patch`, `config_save`, `mqtt_put`, and the renderer commands above for relay |

results carry a status: `applied`, `rejected`, `overload`, `stale_epoch`,
`expired`, `unavailable`, `timeout`, `conflict`. discrete commands are
**deduplicated** by request id: the renderer keeps the last 128 completed ids
for 60 s and answers a repeat with the original result instead of acting
twice; when that cache is full of live entries new commands get `overload`
rather than losing the guarantee. the supervisor keeps 32 relays in flight
with a 2 s deadline each; netd's own requests use ids in the upper half of
the 64-bit space so they never collide with a client's.

## the http api (`/api/v1`)

plain http/1.1 on port 80, no tls (see [what is not there](#what-is-not-there-yet)).
the protocol surface is deliberately narrow so the whole daemon fits in about
60 kb of static buffers:

| limit | value |
|-------|-------|
| concurrent connections | 4 (a fifth gets a canned `429` and is closed) |
| requests per connection | 1; every response says `connection: close` and `cache-control: no-store` |
| request head / json body | 4,096 bytes each; json nesting ≤ 8; unknown or duplicate fields rejected; invalid utf-8 rejected |
| unsupported | chunked or encoded bodies, `expect: 100-continue`, http/2 |
| time to send a complete request | 5 s, then `400 request_timeout` |
| time for the renderer to answer | 2 s, then `504 timeout` (retry with the same request id) |
| raw frames | 10 per second, then `429 frame_rate` |

### authentication and origins

every route, reads included, needs `Authorization: Bearer <token>` where the
token is 64 hex characters. two tokens exist: **control** (scenes, actions,
notifications, frames, reading settings and status) and **admin** (changing
and saving settings, mqtt credentials). the comparison is constant-time
against both. the tokens are in `/tmp/tc002/credentials/tokens` on the device
(32 bytes control, then 32 bytes admin); `adb pull` it as root. anyone who can
sniff the lan can read them in flight, which is why this profile is called
`isolated-lan`.

a request with no `Origin` header (a non-browser client) is allowed. a
request with one is refused with `403 origin_denied` unless the origin is
listed exactly in the settings' `allowed_origins`. no cors headers are
emitted at all, so a browser could not read the replies even if allowed; the
api is for programs, not pages. `allowed_origins` can only be set by editing
`config.json` before the supervisor starts; there is no api field for it.

### routes

| method | path | token | body | reply |
|--------|------|-------|------|-------|
| `GET` | `/status` | control | | the [status document](#the-status-document) |
| `GET` | `/scenes` | control | | the static catalogue: bases, generators, notification and frame bounds |
| `PUT` | `/scene` | control | `{"base":"art\|clock\|ip","generator":"popsquares\|plasma"?,"seed":u32?,"clock":{"font","colour_mode","colour","colour2","gradient","spread"}?,"request_id":hex,"epoch":u32?}` | `{"status":"applied","revision":n,"epoch":n,"request_id":…}` |
| `POST` | `/action` | control | `{"action":"brightness\|reseed\|arm_stream","brightness":1..100?,"seed":u32?,"request_id":hex,"epoch":u32}` | as above |
| `POST` | `/notify` | control | `{"text":"…","colour":"rrggbb"?,"duration_s":1..300?,"request_id":hex,"epoch":u32}` (`duration_s` optional, defaults to 5) | as above |
| `POST` | `/frame?duration_s=&request_id=&epoch=` | control | `application/octet-stream`, exactly 2,496 bytes | as above |
| `POST` | `/action` (`"action":"power"`) | control | `{"action":"power","power":true\|false,"request_id":hex,"epoch":u32}` | as above; fades over 600 ms |
| `POST` | `/input` | control | `{"control":"left\|middle\|right\|knob\|rotary","event":"press\|release\|click\|long\|cw\|ccw","steps":1..16?,"request_id":hex,"epoch":u32}` | as above. `long` is the knob only; `cw`/`ccw` are the rotary only and take `steps` |
| `GET` | `/screen` | control | | `{"width":52,"height":16,"epoch","revision","brightness","power","rgb_base64":"…"}`: the frame as shown, after fades, before brightness. `?format=raw` returns the 2,496 rgb bytes as `application/octet-stream` |
| `GET` | `/logs?after=N` | control | | `{"next":seq,"lines":[{"seq":n,"text":"…"}…]}`: up to 16 lines of the [log ring](#the-log-ring) after sequence number `after` (0 = oldest kept); pass `next` back to continue. a jump in `seq` means lines were evicted |
| `GET` | `/config` | control | | the [settings document](#settings) |
| `PATCH` | `/config` | admin | any subset of the settings fields plus `expected_revision`? | the settings document after the patch |
| `POST` | `/config/save` | admin | `{"revision":u32}` or an empty body, `application/json` either way | `{"status":"saved","saved_revision":n}` |
| `GET` | `/mqtt` | admin | | broker settings; `password_set` instead of the password |
| `PUT` | `/mqtt` | admin | `{"enabled","host","port","username","password","client_id","prefix","tls"}`, any subset | the broker settings |
| `GET` | `/mqtt/status` | control | | `{"enabled","connected","state","reconnect_delay_s","reconnects","last_error"}` |
| `POST` | `/streams`, `PUT` `/streams/{id}/palette`, `DELETE` `/streams/{id}` | control | | `503 not_implemented` |

json bodies must be `application/json`; `request_id` is 1–16 hex digits chosen
by the client and is what makes a retry safe. `epoch` is required for
actions, notifications and frames (read it from `/status` first) and optional
for `/scene`; a mismatch is `409 stale_epoch`. scene, brightness and generator
changes made this way are transient; to make them the boot defaults, patch
and save the settings.

errors are `{"error":"<code>","message":"…","request_id":"…"}` with a stable
lowercase code:

| status | codes |
|-------:|-------|
| 400 | `malformed_request`, `unsupported_request`, `request_timeout`, `invalid_json`, `unknown_field`, `duplicate_field`, `missing_field`, `body_too_deep`, `invalid_*`, `missing_*`, `rejected` (the renderer refused it) |
| 401 | `unauthorized` |
| 403 | `origin_denied`, `forbidden` (admin token needed) |
| 404 / 405 | `not_found`, `method_not_allowed` |
| 409 | `stale_epoch`, `revision_conflict`, `expired`, `conflict` |
| 413 / 415 | `head_too_large`, `body_too_large`, `request_too_large`, `unsupported_media_type` |
| 429 | `overload` (connections or the renderer's dedup window), `frame_rate` |
| 503 | `not_ready` (netd has no credentials or settings yet), `supervisor_unavailable`, `renderer_unavailable`, `save_failed`, `not_implemented` |
| 504 | `timeout` |

### the status document

```json
{"epoch":1,"revision":12,"renderer":"running","base":"art","generator":"popsquares",
 "overlay":"none","brightness":100,"power":true,"presented":35990,"fps":59.9,
 "uptime_s":600,"memory_available_kb":16084,"cpu_pct":5,"restarts":0,
 "network":{"ip":"10.0.0.111"},"time":{"state":"unsynced","age_s":null},
 "config_revision":1,"saved_revision":1,"transport":"plaintext",
 "mqtt":{"enabled":false,"connected":false,"state":"disconnected","reconnect_delay_s":0,"reconnects":0,"last_error":""},
 "boot_id":"3fa1c2d4","sample_age_ms":1200}
```

`fps` is a number only while art is running with no overlay, otherwise
`null` (there is no frame rate to report for a clock). `renderer` is `none`,
`starting`, `running` or `stopping`. `power` (after `brightness`) is the
display power switch; `clock` is the effective [clock style](#clock-styles). `boot_id` is random per supervisor start
and is what groups the mqtt discovery entities. `time` is the sntp client's
view: `state` and seconds since the last accepted reply (see
[time](#time-sntp)).

### settings

`GET /config` returns, and `PATCH /config` accepts any subset of:

| field | range | live effect |
|-------|-------|-------------|
| `brightness` | 1–100 | applied to the renderer at once |
| `clock_font`, `clock_colour_mode`, `clock_colour`, `clock_colour2`, `clock_gradient`, `clock_spread` | `classic\|mini\|segment\|big\|block`; `solid\|gradient`; `rrggbb`; `rrggbb`; `horizontal\|vertical\|diagonal`; 0–255 | applied at once; reported as a `clock` object in `/config` |
| `base` | `art`, `clock`, `ip` | applied at once |
| `generator` | `popsquares`, `plasma` | applied at once |
| `timezone` | a posix tz rule (`AEST-10AEDT,M10.1.0,M4.1.0/3`) or an iana zone name (`Europe/Amsterdam`, case-insensitive), ≤ 64 characters; anything else is rejected | applied at once; a zone name follows that zone's current daylight-saving law |
| `ntp.server`, `ntp.interval_s` (patch as `ntp_server`, `ntp_interval_s`) | dotted ipv4 or null; 300 or 600 | the sntp client restarts at once and syncs promptly; null disables it |
| `frame_timeout_ms` | 100–2000 | stored only: belongs to the unimplemented streaming feature |
| `metrics_interval_s` | 0 (off) or 10–3600 | mqtt `metrics` cadence |
| `discovery.enabled`, `discovery.prefix` (patch as `discovery`, `discovery_prefix`) | bool; ≤ 64 characters | home-assistant discovery on the next mqtt connection |
| `allowed_origins` | up to four exact origins | read from the file only |
| `expected_revision` (patch only) | | the patch is refused with `409 revision_conflict` unless the current revision matches |

`revision` counts accepted patches (and mqtt setting changes) since the
supervisor started with the loaded file; `saved_revision` is what is on disk.
the file itself is the same document in a slightly different shape, with
`"schema":1` and the mqtt block inline:

```json
{"schema":1,"revision":1,"brightness":60,"base":"clock","generator":"popsquares",
 "timezone":"AEST-10AEDT,M10.1.0,M4.1.0/3","ntp_server":null,"ntp_interval_s":300,
 "frame_timeout_ms":500,"metrics_interval_s":30,"discovery":false,"discovery_prefix":"homeassistant",
 "origins":[],"mqtt":{"enabled":false,"host":"","port":1883,"username":"","password":"","client_id":"","prefix":"","tls":false}}
```

an invalid or unknown file is ignored with a warning (defaults are used and
the file is left alone). the mqtt password is in that file in clear, mode
0600, root only; it is never returned by the api.

## mqtt

netd runs one mqtt 3.1.1 client when `enabled` is true and `host` is an ipv4
literal (there is no resolver). keepalive is 30 s, a missed ping response
within 15 s drops the connection, and reconnects back off from 1 s to 60 s
with jitter. `tls: true` is accepted as a setting and makes the client **stay
disconnected** with `last_error: tls is not available in this build`; it
never falls back to plaintext silently. the client id defaults to
`tc002-<boot_id>`. all topics live under `prefix` (default `tc002`):

| topic | direction | payload |
|-------|-----------|---------|
| `availability` | out, retained, qos 1 | `online`; the last will publishes `offline` |
| `state` | out, retained | the status document, republished on change at most twice a second |
| `result` | out | `{"request_id","status","revision","epoch"}` for every command received on `cmd/*`, or `{"status":"rejected","error","message"}` for a body that did not parse |
| `metrics` | out, every `metrics_interval_s` | the [metrics document](#the-metrics-document) |
| `cmd/scene`, `cmd/action`, `cmd/notify` | in, qos 1 | exactly the http json bodies |
| `cmd/frame` | in, qos 1 | binary, 2,510 bytes big-endian: `u64 request_id`, `u32 epoch`, `u16 duration_s`, 2,496 rgb bytes |
| `cmd/config` | in, qos 1 | the control subset only: `brightness`, `base`, `generator` (transient, like `/action` and `/scene`). any durable field is answered `admin_only`; those are administered over http |
| `cmd/input` | in, qos 1 | the `/input` json body; answered on `result` |
| `cmd/screen` | in, qos 1 | any payload; answered on `screen` |
| `screen` | out, not retained | binary, 2,502 bytes: `u32 revision, u8 brightness, u8 power`, then the 2,496 rgb bytes as shown |
| `input/left`, `input/middle`, `input/right`, `input/knob`, `input/rotary` | out, qos 0, **not retained** | one json object per event, `{"event_type":"press\|release\|long\|cw\|ccw","position":n}`, the shape home assistant's mqtt `event` entities consume. deliberately not retained: a consumer that reconnects after being offline must not act on a stale press. events raised while the broker is unreachable are lost |

retained deliveries are never treated as commands, so a stale retained
`cmd/*` message cannot replay on reconnect. the same ten-frames-per-second and
dedup rules as http apply; up to eight mqtt commands wait for the renderer at
once.

### the metrics document

```json
{"v":1,"boot_id":"3fa1c2d4","epoch":1,"sample_age_ms":800,"uptime_s":600,
 "memory_available_kb":16084,"cpu_pct":5,"rss_kb":{"supervisor":4,"renderer":4,"netd":4},
 "renderer_restarts":0,"mqtt_reconnects":0,"scene":"art","brightness":100,"fps":59.9,
 "presented":35990,"http_requests":12,"http_rejected":1,"mqtt_commands":3,"mqtt_dropped":0,
 "time":{"state":"unsynced"}}
```

(the `rss_kb` values are the kernel's unreliable 4 kb figure; see
[memory audits](#memory-audits).)

### home-assistant discovery

opt-in with `discovery: true`. on every mqtt connection netd publishes one
retained config per second under
`<discovery_prefix>/<component>/tc002-<mac>/<key>/config` (the boot id stands
in when there is no wlan0 mac): 24 read-only diagnostic `sensor` entities that
read from the `metrics` topic (uptime, memory, cpu overall and per process,
load, wifi, tmpfs, battery and usb power, renderer restarts, mqtt reconnects,
scene, brightness, fps, frames presented, time sync state), one
`binary_sensor` for display power that reads the retained `state` topic, and
five `event` entities (left, middle and right buttons, the knob, the rotary)
fed by the momentary `input/<control>` topics with `event_types` press/release
(plus `long` for the knob, `cw`/`ccw` for the rotary). they are grouped into
one device, linked to the `availability` topic, and the metrics sensors expire
after three metrics intervals. a home-assistant birth message
(`<discovery_prefix>/status` = `online`) repeats the pass; turning discovery
off, or changing the prefix, clears exactly those topics with empty retained
publishes. nothing writable is exposed through discovery; control goes through
`cmd/*`.

## host tools (`runtime/tools/`)

| tool | what it does |
|------|--------------|
| `tc002ctl.py` | a client for every route: `status`, `scenes`, `scene` (with `--font`, `--colour-mode`, `--colour`, `--colour2`, `--gradient`, `--spread` for the clock), `brightness`, `reseed`, `arm-stream`, `notify`, `frame`, `power`, `input`, `screen` (`--ascii` draws the panel in the terminal, `--out` saves the raw rgb), `logs` (`--follow`), `config`, `config-set`, `config-save`, `mqtt`, `mqtt-set`, `mqtt-status`. takes the pulled token file (`--token-file`) or a hex token, picks the admin token for admin commands, generates request ids and fetches the epoch for you |
| `tc002-up.sh` | the one-shot cold start for a person: connect adb, build and push (`--no-build` to skip the build), start the supervisor with `--tz`, apply and save the timezone, scene, clock font and sntp server, pull the tokens to the repo root for the console, print the status. after a reboot this is the way back |
| `tc002-run.sh` | `push` (build, elf check, push to `/tmp/tc002/`; `TC002_NO_BUILD=1` skips the build), `start [supervisor options]` (under the lock: stop `zkswe`, start the supervisor detached with its log in `/tmp/tc002/`), `status`, `stop` (sigterm, restart the stock app, release the lock), `restore` (stop and remove everything under `/tmp`) |
| `tc002-boot-experiment.sh` | `baseline` (time the stock `ctl.start` to the property), `start` (rewrite `startupLibPath` into `/tmp/EasyUI.cfg`, restart `zkswe` through the bootstrap, show the audit), `status`, `restore` |
| `tc002-lock.sh` | the append-only advisory lock in `/tmp/tc002-lock.txt` on the host, for two agents sharing one device: `acquire <intent> [timeout]`, `release`, `status`, `note`. every device-mutating step in the scripts above runs under it |
| `tc002-test-broker.py` | a minimal mqtt 3.1.1 broker (`#`/`+` matching, retained messages, qos 1 acks) that logs every packet, plus a tiny publisher (`--publish HOST TOPIC PAYLOAD_OR_@FILE`) for lan acceptance runs |

typical session:

```bash
cd runtime
tools/tc002-run.sh push
tools/tc002-run.sh start --profile dev --stats --tz 'AEST-10AEDT,M10.1.0,M4.1.0/3'
adb pull /tmp/tc002/credentials/tokens tokens        # root over adb; keep the file private
tools/tc002ctl.py -s <device-ip> --token-file tokens status
tools/tc002ctl.py -s <device-ip> --token-file tokens notify hello --colour 00ff80 --duration 4
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set brightness=60 base=clock
tools/tc002ctl.py -s <device-ip> --token-file tokens config-save
tools/tc002-run.sh stop
```

the english web control panel in [`panel/`](panel/) talks to the **stock**
api; [`panel-v2/`](panel-v2/) is the same idea for this api, with a local
proxy that holds the tokens, the transient and durable
[clock styles](#clock-styles) and a live preview from `/screen` (simulated
against the mock, fonts and gradients included).

## memory audits

`tc002-memdump <pid> hex`, run as root over adb, streams a snapshot of one
process: `maps`, `smaps`, `status` and `statm` as text, then every readable
mapping's *present* pages (from `/proc/<pid>/pagemap`) with the pagemap
entries themselves, in a small tagged container, hex-encoded with a newline
every 128 bytes so it survives `adb shell` (this adbd has no `exec-out`).
nothing is written to the device and the process keeps running; the snapshot
may tear. `zig build -Dstrip=false --prefix <dir>` produces a symbol-keeping
build of the same code for attributing `.data` and `.bss` objects.

```bash
adb push runtime/zig-out/bin/tc002-memdump /tmp/tc002-memdump
adb shell "/tmp/tc002-memdump <pid> hex" | tr -d '\r\n' | xxd -r -p > snapshot.tcmd
```

the tool exists because the kernel's `VmRSS` is wrong here; the pagemap
present bits are the trustworthy residency signal. the 2026-09-06 audit
(resident kib by page-table walk):

| | stock `zkgui` | custom runtime, all three processes |
|---|---:|---:|
| resident | 7,860 | 1,232 |
| private anonymous | 2,924 | 252 |
| file-backed / page cache | 4,936 | 980 (the binaries themselves, on tmpfs) |
| threads | 31 | 1 per process |
| heap | 1.6 mib committed across four arenas | none |
| system `MemAvailable` | 12,552 kb | 16,084 kb |

## what has been measured

all on a warm device that had been up for days, under the lock, on
2026-09-06. nothing here is cold-boot evidence.

| area | result |
|------|--------|
| renderer, art | 900 transfers in 15 s, 59.7–59.9 fps per 5 s window, 0 short writes, 0 errors; one thread |
| renderer, clock | exactly two paced transfers per wall-second update, none in between |
| supervisor start | `sys.zkapp.state=running` accepted 10 ms after entry; renderer `ready` 7 ms after spawn |
| frozen renderer (`SIGSTOP`) | stop requested 2.0 s after the last heartbeat, `SIGKILL` 2.0 s later, new epoch spawned 1.0 s after that |
| supervisor killed (`SIGKILL`) | the renderer died with it; a fresh supervisor found the lock free |
| graceful stop | black presented, renderer exit 0, supervisor exit 0 |
| boot experiment | `/tmp/EasyUI.cfg` precedence confirmed; bootstrap execs the supervisor in place keeping the `zkswe` pid; `ctl.start` → property 1.67 s versus 1.57–2.66 s stock; init restarts the service about 1 s after the supervisor dies and retries every ~4 s after a failed exec, property untouched |
| http | every route and every documented error code exercised; 20 parallel status requests → 14×200 and 6×429; a half-sent request times out at 5 s; a 10 s flood of garbage, wrong methods and 5 kb headers left the renderer at 59.7–59.9 fps with cpu at 5 % |
| mqtt | will, subscriptions, retained `state`, `metrics`, all five `cmd/*` topics answered on `result`; broker stopped → backoff with reconnects counted; broker back → reconnected within 4 s |
| discovery | 13 retained configs published one per second, cleared exactly on disable |
| netd restart | `SIGTERM` to netd → respawned 1 s later with fresh credentials; the renderer never noticed |
| memory | the table above; the whole runtime leaves 2 mb more available than the stock app |
| screen, input, logs (2026-09-07) | `/screen` json and raw (2,496 bytes) match the panel; injected clicks, rotary steps and a knob long press produce the same scene changes and the same outward events as the mapper would (30 events over mqtt in one run, none retained); `/logs` pages both children's lines through the pipe while `supervisor.log` stays complete |
| power and fades (2026-09-07) | power off ramps the mean level 29 → 0 in ~600 ms, then a 5 s window shows `transfers=1 redraws=0`; power on ramps 0 → 127 in ~600 ms; a plasma → clock cross-fade runs 127 → 29 in ~500 ms; cpu 2 % overall with mqtt, discovery and fades active |
| discovery (2026-09-07) | 30 retained configs (24 sensors, 1 binary sensor, 5 event entities), one per second; `cmd/screen` answered with 2,502 bytes on `screen` |

## what is not there yet

- **tls.** zig 0.16's standard library has a tls client but no server, and no
  tls library is vendored. only the plaintext `isolated-lan` profile exists,
  and `/status` says so (`transport: plaintext`). the tokens are readable by
  anyone on the network path.
- **time.** the sntp client trusts one unauthenticated local server, steps
  or slews only when a poll succeeds, and has no drift estimator, so the
  ~70 ppm oscillator error described in [`DEVICE.md`](DEVICE.md#time) is
  corrected every poll rather than continuously. nothing survives a reboot:
  `ntp_server` must be in the saved settings or set again.
- **streaming.** the stream routes answer `503 not_implemented`;
  `arm_stream` and `frame_timeout_ms` exist for it.
- **network bring-up.** the runtime relies on the wifi and address the stock
  stack established before it took over. dhcp renewal after the takeover and
  the setup-ap flow are not handled and were not measured.
- **the mcu.** the supervisor queries the version, battery and usb state
  every 30 s (see [the pixel mcu link](runtime/README.md#the-pixel-mcu-link))
  and reports them; nothing reads the microphone, sets the led current gain
  or uses the power-off command, and the low-battery behaviour is not
  reproduced. run on usb power.
- **persistence.** everything is under `/tmp`; the paired-slot durable
  install, the vendor image builder and the recovery rehearsal the design
  calls for do not exist. cold boot against zkdaemon's 15 s check, the
  upgrade-hook ordering and anything on mtd3 are unmeasured.
- **confinement.** netd is uid 1001, but `/dev/socket/property_service` is
  world-writable on this init, so the uid change alone does not deny it the
  property service. recorded as a gap, not claimed as isolated.
- **physical input** has not been exercised on the device: the keymap is a
  guess, and the maintenance gesture and hardened profile are host-tested
  only.
- cors headers and an api field for `allowed_origins` (browser clients go
  through `panel-v2/serve.py`).
- **input on hardware.** the outward events and remote injection are tested
  through the api; nobody has pressed the physical buttons under this runtime
  yet, so the keymap is still the working guess above.

## design notes

the design and its review live in the agent-notes vault
(`tc002-customisation/2026-09-03/custom-native-runtime`,
`2026-09-06/custom-native-runtime-design-review`, and the implementation
record `2026-09-06/native-runtime-plan-b`). the tradeoffs made against that
design, all deliberate and reported rather than hidden: an own http parser
and mqtt codec instead of a library (bounded memory, narrower protocol), the
netd relay through the supervisor instead of a direct channel to the renderer
(no descriptor passing across renderer restarts), `std.json` for bodies
rather than a hand parser (correctness over code size), and ReleaseSafe by
default (bounds checks on in a network-facing parser, at about 0.7 mb of
tmpfs).
