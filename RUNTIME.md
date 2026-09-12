# the custom runtime (`runtime/`)

a replacement for the stock application on the tc002: four static arm binaries
and one tiny shared object, written in zig 0.16 with no libc, that take over
the panel, the buttons and the knob, and expose an authenticated http and mqtt
api of their own. while it runs, the stock `zkgui` app (and with it the stock
http api on port 80, the cloud client, the built-in apps) is not running.

the **code** here is volatile: binaries, logs and the panel lock live under
`/tmp/tc002/`, the boot hook is `/tmp/EasyUI.cfg`, and a power cycle always
comes back stock. the **settings and credentials are not**: they live under
`/data/tc002/state/` on the persistent jffs2 partition and survive a reboot, so
a restarted runtime comes back configured. nothing else is written to flash, and
no partition is ever rewritten. this document is the reference for what the code
does; how to build and run it is in [`runtime/README.md`](runtime/README.md).

## processes

| binary | runs as | size¹ | role |
|--------|---------|------:|------|
| `libtc002-bootstrap.so` | inside the vendor loader | 1.8 kb | the "startup library" the loader `dlopen`s. its constructor `execve`s the supervisor in place, passing `--from-bootstrap` and the loader's environment. no libc, no `DT_NEEDED`. if the exec fails it prints one line and exits 1; it never touches the anti-brick property |
| `tc002-supervisor` | root | 384 kb | sets `sys.zkapp.state=running` first, then owns everything privileged: spawns and watches the renderer, binds port 80, generates the api tokens, keeps the settings file, reads the maintenance gesture, polls `wlan0`, relays api commands, samples `/proc` |
| `tc002d` | root | 255 kb | the renderer. the only process that opens `/dev/spidev0.0` and the latch gpio. scenes, overlays, physical input, paced presentation, heartbeats |
| `tc002-netd` | uid 1001 | 396 kb | the network daemon: an http/1.1 server for `/api/v1` and an mqtt 3.1.1 client. holds no authoritative state; every command is relayed through the supervisor to the live renderer |
| `tc002-ntfy` | uid 1001 | 1.1 mb | the ntfy subscriber: dns, tcp, tls 1.3 with the standard library (that is the size), the json stream; sends `notify` to the supervisor. only runs while `ntfy.enabled` |
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
  --keymap L,M,R,K        keycodes for left, middle, right, knob (108,105,106,103)
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
by accident. the renderer is spawned with `--start-dark`, so nothing of its
built-in default scene reaches the panel; on `ready` the supervisor pushes the saved brightness, base scene,
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

- **where they live**: `--state PATH`, `/data/tc002/state` by default, on the
  persistent partition, so both survive a reboot. the supervisor creates it at
  startup; if it cannot (no `/data`, a full or read-only partition) it logs a
  warning, falls back to `--dir` and keeps running, volatile as before. the
  layout under either directory is the same, so the fallback is a swap.
  the first start with a durable directory carries `config/config.json`,
  `credentials/tokens` and `credentials/ntfy-ca.pem` over from `--dir` if they
  are there, which keeps the settings and the tokens an upgrade already had. an
  existing durable file is never overwritten.
- **credentials**: two 32-byte random tokens (control, admin) generated once
  into `<state>/credentials/tokens` (mode 0600, directory 0700) and handed
  to netd over the channel. netd never reads the file; nothing in the runtime
  ever logs them. they are durable, so the console keeps working across a
  reboot; a factory reset (the reset key, which wipes `/data`) clears them.
- **settings**: `<state>/config/config.json`, written atomically (temp
  file, fsync, rename, directory fsync). every accepted patch bumps
  `revision`. **every accepted settings write is persisted at once**, so
  `saved_revision` follows on its own and a client confirms persistence by
  seeing the two match in the reply; `POST /config/save` remains and forces a
  write. a patch can name the revision it expects and is refused with
  `conflict` if it is stale. the model is in [settings](#settings).
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

every 5 s the supervisor reads `MemAvailable`, `MemFree`, `MemTotal` and
`Shmem` from `/proc/meminfo`, cpu utilisation from `/proc/stat`, `VmRSS` of the
three processes, and `statfs` of `/data` and `/tmp`, and derives achieved fps
from the renderer's `presented` counter over windows of at least 2 s. the
`/data` figure is the **flash** one: jffs2 on mtd6 is the only durable storage
and its usage appears nowhere in `/proc`. every used figure is reported with
the total it is a fraction of (`memory_total_kb`, `tmpfs_total_kb`,
`flash_total_kb`), because a bar needs a denominator. that snapshot is what `/api/v1/status` and the mqtt `state` and `metrics`
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

### the night brightness schedule

with `night` on, the supervisor dims the panel in the evening and brightens it
again in the morning, following the sun where the device actually is. the
daylight level is the settings' own `brightness`; `night_brightness` is the
other end.

the day is a polyline through four instants. dimming starts `night_lead_min`
before sunset and is finished by civil dusk (the sun 6° below the horizon);
brightening starts at civil dawn and is finished `night_lead_min` after
sunrise. between them the brightness is interpolated, so the two ends mirror
each other and both windows last as long as the twilight does — about 50
minutes in amsterdam in september, over an hour in a scottish winter, half an
hour at the equator. outside them the level is flat.

`sys/solar.zig` computes the crossings from the low-precision sunrise equation:
solar mean anomaly, the equation of the centre, the declination that follows,
and the hour angle at which the sun reaches a given zenith (90.833° for
sunrise and sunset, allowing for the sun's radius and refraction; 96° for
civil twilight). `@sin` and `@cos` lower to libm calls this binary cannot
link, so the sine is a truncated taylor series and the arccosine an
abramowitz-and-stegun fit; against the noaa solar calculator's formulation,
which shares none of its terms, it agrees within 80 s at the worst case tried.
inside the polar circles a day may have no crossings at all: the panel then
holds daylight through a polar summer and the night level through a polar
night.

**where the device is** comes from the timezone. tzdata gives every iana zone
a reference point and `tools/gen-zones.py` carries it into the generated
table, so `Europe/Amsterdam` also means 52.37° N, 4.90° E. `latitude` and
`longitude` override that pair when the zone's reference city is far from you
(`US/Pacific` runs from los angeles to seattle, an hour apart in midwinter) or
when the timezone is a bare posix rule, which names no place at all. with
neither, the schedule cannot run: the log says so and the menu's `night` item
reads `no place` instead of `on`.

the schedule drives the panel **transiently**, exactly as an api client does.
nothing it decides is written to flash, so a ramp that runs every evening
costs no jffs2 wear and the settings keep meaning the daylight brightness. it
is consulted every ten seconds, which is finer than a ramp of tens of minutes
over a hundred steps can move. a clock that has not been set yet (1970, before
sntp has answered) holds daylight rather than guessing.

a brightness that arrives from anywhere else — the knob, `PATCH /config`,
`POST /action`, mqtt — **holds the schedule off until the next ramp begins**:
turn it up at midnight and it stays up until dawn; turn it down in the
afternoon and the evening ramp takes it from there. `/status` reports this as
`night.held`. turning the schedule off hands the settings' own brightness
back at once.


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
  --keymap L,M,R,K    keycodes for left, middle, right, knob (108,105,106,103)
  --tz RULE           posix tz rule for the clock (UTC0)
  --base clock|art|canvas  initial base scene (clock)
  --generator N       initial art generator index (0)
  --seed N            art seed, 0 = from the clock (0)
  --brightness N      1..100 (100)
  --seconds S         stop after s seconds, 0 = run until stopped (0)
  --crossfade-ms N    default transition, a cross-fade, 0..5000 ms, 0 = none (500)
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
| `canvas` | a document of drawing primitives pushed by an integration, or a dim `canvas` when nothing has been pushed; see [the canvas](#the-canvas) | idle, unless an element declares an animation |

| overlay | bounds | behaviour |
|---------|--------|-----------|
| notification | 1–128 printable ascii characters, a colour, 1–300 s | centred if it fits; otherwise scrolls in from the right one pixel per 33 ms and wraps |
| raw frame | exactly 2,496 rgb888 bytes (52×16×3), 1–300 s | shown as-is; switches at once unless the request names a [transition](#transitions) |
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
shows the current state when it comes back. every visible change of scene
runs a [transition](#transitions), 500 ms by default: a slide between the
base scenes, following where their buttons sit — left to right the panel reads
clock, art, canvas, which is also the enum's own numbering, so a scene further
right comes in from the right, like pages, a cross-fade when the generator,
a notification (start or end)
or the showing clock's style changes; raw frames, reseeds and brightness
switch at once. both durations are renderer options; 0 disables.

### the canvas

an integration that wanted anything other than the clock, the art or the address used to have to
compose 2,496 bytes of rgb itself. the canvas is the alternative: a document of drawing primitives,
pushed once, patched by value afterwards, so an integration sends **data** and the device draws it.

```
PUT    /canvas   admin     replaces the document, whole or not at all
PATCH  /canvas   control   values only, by element id
GET    /canvas   control   the document as held, in the shape a put would send it
DELETE /canvas   control   empties it
```

```json
PUT /canvas
{"elements":[
  {"id":"hdr","type":"text","at":[0,0],"font":"mini","colour":"606060","text":"living room"},
  {"id":"t","type":"text","at":[0,6],"font":"small","text":"20.4C"},
  {"id":"lvl","type":"bar","at":[34,7],"size":[18,3],"value":40,"colour":"30a0ff","background":"101010"},
  {"id":"g","type":"sparkline","at":[0,13],"size":[52,3],"style":"bars","colour":"208020",
   "data":[2,4,3,6,9,7,5,8,11,14,12,15,13],"threshold":13,"over":"ff4000"}]}
```

```json
PATCH /canvas
{"values":[{"id":"t","text":"21.1C"},{"id":"lvl","value":85},{"id":"g","data":[14,12,15,13]}]}
```

a patch body is a **list, not an object keyed by id**: the json parser resolves field names at
compile time and the ids belong to the client, the same constraint that made `generator_params` a
list. a value naming an id the document does not have is `unknown_element`; one carrying a field
that element's type has no use for is `invalid_element_field`; either refuses the **whole** patch,
because a half-applied dashboard is worse than a rejected one.

**placement.** `at: [x,y]` puts the top-left corner (the centre, for a circle) and `size: [w,h]`
bounds the element; both are pixels on 52x16 and both clip at the edge rather than being refused,
so something can be animated in from off-panel. `tile: n, of: m` is the column shorthand and
`row: n, of: m` the row one; neither combines with `at` or `size`. a width or height of zero means
"as big as it needs to be".

| type | fields | notes |
|---|---|---|
| `text` | `text`, `font`, `align` | `small` is the 5x7 with every printable character; `mini` the 3x5 of the menus; `block` and `big` are the clock's own faces and carry **digits and a colon only**, for a number read across a room |
| `rect` | `filled` | a one-pixel outline unless filled |
| `line` | `to: [x,y]` | bresenham, so a diagonal has no gaps |
| `circle` | `r`, `filled` | `at` is the centre |
| `pixel` | | the cheap escape hatch |
| `bar` | `value` 0-100, `background`, `vertical` | rounds so 1% of a wide bar still lights a pixel and 99% leaves one dark; vertical fills from the bottom |
| `sparkline` | `data` or `data_hex`, `style` (`line`/`bars`/`area`), `min`, `max`, `threshold`, `over` | `min` equal to `max` scales to whatever the samples span; a flat line sits on the floor; samples at or above `threshold` draw in `over` |
| `icon` | `icon` | one of the built-in 8x8 glyphs by name, in the element's colour; `GET /icons` lists them |
| `sprite` | `sprite` | an uploaded picture by id, drawn in its own colours; black is transparent |
| `tile` | `icon` or `sprite`, `label`, `value_text`, `accent` | the composite: a glyph, a label and a reading, laid out by the device |

every element takes `id` (1-8 characters; without one it is drawn but cannot be patched), `colour`
as `rrggbb`, and its placement. elements draw in the order given, painter-style. **a field that does
not belong to the type given is refused** rather than dropped: `{"type":"rect","text":"hi"}` is a
mistake worth hearing about.

`data_hex` is the same samples as hex, for a document that would not otherwise fit: 52 samples cost
208 characters as json digits and 104 as hex.

**animation is declared, not driven.** an element carries an `animate` block and the renderer ticks
it, so an integration pushes once and walks away:

```json
{"id":"t","type":"text","text":"21.1C","animate":{"kind":"scramble","ms":600}}
```

| kind | what it does | `ms` | `amount` |
|---|---|---|---|
| `hue` | walks the element's colour round the wheel at full saturation | one full turn (8,000) | |
| `bounce` | oscillates it, `axis` `y` (default) or `x` | one bounce (1,000) | pixels of travel (2) |
| `scramble` | the flipboard: each character settles out of flipping glyphs, left to right | the whole word (1,000) | |
| `scroll` | moves text wider than its box, wrapping with a panel's width of gap | per pixel (33) | |
| `blink` | lit, then dark | the period (1,000) | the lit percentage (50) |
| `pulse` | rides the brightness up and down, never to nothing | the period (1,000) | |
| `typewriter` | reveals a character at a time | the whole string (1,000) | |
| `sweep` | draws a sparkline left to right | the whole width (1,000) | |

`phase` (0–100) offsets an element within its period, so a row of tiles does not move in lockstep.
`scramble`, `typewriter` and `sweep` are **arrivals**: they run once, hold, and start again when the
value they are showing changes — which the renderer works out by comparing the document that
arrives with the one it holds, so a patch that moves a bar does not make the text beside it scramble
all over again. a motion that cannot mean anything for the type given (`sweep` on a text, `scramble`
on a rectangle) is refused rather than ignored.

**what it costs.** the scene asks for frames only while something is moving, per element: a document
with no animation is drawn when it changes and not again, and one that only scrambles on update goes
quiet as soon as it has settled. measured on the device: 180 frames in three seconds with a hue and
a bounce running, and **0 in three seconds** once a scramble had finished.

**icons and sprites.** the set is 61 monochrome 8x8 glyphs — weather, battery and signal, arrows,
media, marks, and the objects a room has — authored as text art the way the fonts are, because a
mistake in a picture is only visible if you can see the picture. they take the element's colour, so
one fits whatever the document is already doing. `GET /icons` returns the names.

anything the set has not got is a **sprite**, which an integration uploads:

```
PUT    /sprites/<id>   admin     8x8 (192 bytes) or 16x16 (768) of rgb888, application/octet-stream
GET    /sprites        control   what is held: ids, sizes and how many slots there are
DELETE /sprites/<id>   control
```

the size is inferred from how many bytes arrived, and octets rather than base64 because
`POST /frame` already proved that path. eight slots, volatile, replayed to the renderer when it
restarts — pictures first, so the document finds them. black is transparent, which is what lets a
sprite sit over something else. a sprite an element names but nothing has uploaded simply does not
draw; deleting one out from under a tile leaves the tile's text and drops its glyph.

real emoji are not shipped. at 8x8 the art has to be drawn for the size rather than shrunk, and the
upload path is how an integration puts its own there.

**the tile** is the composite an integration reaches for first, and the one place the device makes a
layout decision: given at least twenty pixels of width it puts the glyph on the left with the label
over the value beside it; narrower than that, the label is **dropped** rather than squeezed into two
characters, and the value goes under the glyph. a patch's `text` replaces a tile's `value_text`,
because the reading is the part that changes; the label is layout and waits for a `PUT`.

**limits**, reported by `GET /canvas` so a client need not hard-code them: 24 elements, 256 bytes of
text, 1,024 bytes of sample data, 52 samples per sparkline (one per panel column). a document is
about two kilobytes on the wire and travels in one ipc packet, whole.

**who holds it.** the supervisor, because it is state a client reads back and the renderer is the
thing that restarts: kill the renderer and the document is pushed again when it comes up, which is
verified rather than assumed. `revision` counts accepted changes.

**what survives.** the document and its sprites are written to `config/canvas.bin` in the [state
directory](#settings-credentials-the-listener) on a `PUT`, a `DELETE` and a sprite change, and
**never on a value patch** — home assistant pushing a reading every minute would otherwise be 1,440
jffs2 writes a day. so a restart restores the layout with the values its last full push carried,
which is what any dashboard shows until its next update. `saved_revision` in `GET /canvas` says what
is on disk, the same confirmation the settings give: it trails `revision` after a patch and catches
up at the next layout change.

the file is binary rather than json because half of it is pixels — the readable view of a canvas is
`GET /canvas`, and `config.json` stays the one a person would edit. a document of one tile with an
8x8 sprite is 283 bytes. a file that does not start with `TCCV` and its version byte, or that runs
out part way through, is refused and the canvas starts empty with the file left alone.

### the cube

a solid rotating cube, shaded rather than flat: each of the six faces takes one
brightness from its own normal against a fixed light up, left and towards the
viewer, so the form reads as three dimensional instead of a silhouette. back
faces are culled, which for a convex solid is the whole of the depth problem,
so at most three faces ever draw and none needs sorting. faces are filled by
scanline; the trigonometry comes from a comptime table, so nothing calls libm
at runtime.

`palette` is `mono`, one colour separated by shading, or `poly`, a hue per
face. `hue drift` walks the colour round the wheel, up to 60 degrees a second.
`spin` is `single` (one axis), `series` (x, then y, then z, four seconds each)
or `parallel` (all three at once at different rates), `speed` multiplies the
rate and `zoom` scales the projection between 40 and 200 per cent.

the edges are **softened**: a cube this size is mostly edge, and whole-pixel
edges are what make it read as a staircase. each face is filled by taking exact
coverage across four sub-rows per output row and blending by that coverage, so
a diagonal lands part-lit rather than stepped. it costs one 832-byte coverage
buffer per face and no supersampled frame. the seed decides where it starts, so a reseed turns it to a new face
and keeps the settings.

### transitions

a scene change, a notification or a pushed frame may name how it arrives.
`PUT /scene`, `POST /notify` and `POST /frame` (in the query, the body being
the image) and their mqtt twins `cmd/scene`, `cmd/notify`, `cmd/frame` take
three optional fields:

| field | values | default |
|---|---|---|
| `transition` | one of the effects below | `fade` for scenes and notifications, `cut` for frames |
| `direction` | `left`, `right`, `up`, `down` | the effect's natural direction: `down` for the rains, `left` otherwise |
| `transition_ms` | 0..5000 | 500 |
| `exit` | `reverse`, `same`, `none`: how a notification or pushed frame leaves (ignored on a base scene) | `reverse` |

**direction is the way the moving content travels.** slide left moves
everything left with the new content entering from the right; swipe in left
pulls the new content in from the right edge over the old; swipe out left
pushes the old content off the left edge, revealing the new underneath.

| effect | what moves |
|---|---|
| `fade` | a cross-fade of the whole frame |
| `cut` | nothing: the new content at once |
| `slide` | old and new content move in tandem, the new following the old in |
| `swipe_out` | the old content slides away; the new content sits still underneath |
| `swipe_in` | the new content slides in over the old, which sits still |
| `collapse` | the old content is kept inside a rectangle shrinking to the centre, both axes meeting there together; the new shows outside it |
| `expand` | the new content grows out of the centre over the old (the reverse) |
| `wipe` | a hard edge sweeps that way; nothing moves |
| `dissolve` | pixels switch from old to new in a fixed pseudo-random order |
| `split_out` | the old content parts at the centre line and both halves slide off; left/right part sideways, up/down part vertically |
| `split_in` | both halves of the new content slide in from the edges and meet at the centre |
| `blinds` | four slats perpendicular to the direction each wipe that way at once |
| `flip` | the old content squashes to the centre line of the axis, then the new grows out of it; a flat card flip |
| `rain` | columns (rows for left/right) fall that way one after another with an accelerating drop, revealing the new |
| `rain_random` | the same with the lines starting in a pseudo-random order |

a notification or pushed frame **leaves with the paired effect**: swipe in ↔
swipe out, split in ↔ split out, expand ↔ collapse; the others repeat
themselves. `exit` says which way: `reverse` (the default) backs out the way
it came, so a notification that swiped in from the right slides back out to
the right and one that expanded from the centre collapses into it; `same`
keeps the direction, so the content carries on across the panel like a
carousel and the base follows it in; `none` cuts. omitting the fields keeps
the defaults; a request with `direction`, `transition_ms` or `exit` alone
applies them to the default effect. a change between the base scenes with
no effect named, from the buttons or `PUT /scene`, slides forward (art, clock,
ip) to the left and back to the right; the knob's generator change fades.
**both layers stay live** while an effect runs: the outgoing scene keeps
rendering as the old layer (art keeps stepping, an outgoing generator too,
the clock keeps ticking, a notification keeps scrolling) until the effect
ends. only when an effect starts while another is still running is the old
layer the composite frame that was on the panel at that moment, held still. the effects are composited in the renderer from
the frame that was on the panel and the scene's new output; `GET /scenes`
lists them under `transitions`. the mqtt `cmd/frame` envelope grows from 14
to 18 or 19 bytes when it carries one: `u8 effect` (the index in that list),
`u8 direction` (left 0, right 1, up 2, down 3), `u16 duration_ms` and
optionally `u8 exit` (reverse 0, same 1, none 2) before the rgb bytes; over
ipc the same block, prefixed with a presence byte, rides on `set_base`,
`notify` and `frame`.

### clock styles

**digits** is `solid`, `outline` or `shadow`, and applies to the two faces with
a body, `block` and `big`. outline keeps only the pixels of a stroke that touch
an unlit one, hollowing the interior; shadow lays the same digits down again a
pixel right and below at about a third strength, then draws the digit on top.
the thinner faces have no interior to remove and no room to cast anything, so
they ignore it and stay solid. it is a clock parameter like any other: on the
panel, over `PUT /scene` as `clock.digits` and in the settings as
`clock_digit`.


a clock style is `{font, colour_mode, colour, colour2, gradient, spread}`:

| font | digits | what is shown | width |
|------|--------|---------------|------:|
| `classic` | the built-in 5×7 font | `hh:mm:ss` | 47 px |
| `mini` | 3×5 | `hh:mm:ss` on rows 2–6 and the date `dd/mm` on rows 9–13 | 27 px |
| `segment` | seven-segment 5×9, generated from a segment table | `hh:mm:ss` | 39 px |
| `big` | the classic digits scaled to 10×14 | `hh:mm` (no seconds) | 52 px, edge to edge |
| `block` | the stock clock's face: 6×10 digits with two-pixel strokes, a flagged 1 with a base, a 2×2-dot colon | `hh:mm:ss` | 47 px |
| `hires` | the classic 5×7 time on rows 0–6, a one-pixel bar on row 8 filling left to right through each second, the milliseconds in 3×5 digits on rows 10–14; redrawn every frame (60 fps) instead of once a second | `hh:mm:ss` and `mmm` | 47 px |

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

### ip layouts

the address is a **page of the device menu**, not a base scene: there are three
buttons and the canvas took the third. it keeps everything it had — the same
full-panel renderer and all four layouts — and the `ip` item draws it instead
of the menu's usual name-over-value, because `big` and `scroll` need the whole
height. turning the dial on that item pages the layouts.

the layout is the `ip_mode` setting (durable, admin over `PATCH /config`,
applied at once); `/status` and `/config` report it and `/scenes` lists the
four under `ip.modes`, which is fed from the enum and so is independent of the
base list. there is no transient form any more: `{"base":"ip"}` on `PUT /scene`
is `invalid_base`.

| mode | layout |
|---|---|
| `lines` | the first two octets with a trailing dot over the last two, each line centred in the 5×7 font (the default) |
| `mini` | the whole address on one centred line of 3×5 digits with one-pixel dots; the widest possible address (four three-digit octets) is 53 px and loses its last column |
| `scroll` | one line in the 5×7 font, centred when it fits (up to 8 characters) and otherwise scrolling in from the right one pixel per 33 ms |
| `big` | one line of 10×14 digits, scrolling |

a layout change redraws the menu page rather than running a transition: no base
renders the address now.

### ntfy

the runtime can subscribe to a [ntfy](https://docs.ntfy.sh/subscribe/api/)
topic, on the official service or a self-hosted server, and show every message
as a notification. `GET /ntfy` and `PUT /ntfy` (admin) carry the settings;
`tools/tc002ctl.py ntfy` / `ntfy-set` are the client side:

| field | meaning | default |
|---|---|---|
| `enabled` | subscribe or not | `false` |
| `url` | `https://ntfy.sh`, or a self-hosted `http://host[:port][/prefix]` / `https://…` (at most 64 characters; a host name or a dotted address) | `""` |
| `topic` | the topic name (letters, digits, `_`, `-`; at most 64) | `""` |
| `token` | a ntfy access token, sent as `Authorization: Bearer` (a secret: reported only as `token_set`) | `""` |
| `username`, `password` | basic auth instead of a token (the password is a secret: `password_set`) | `""` |
| `duration_s` | how long each message stays on the panel, 1–300 | `10` |
| `insecure` | skip certificate verification (a self-signed server) | `false` |
| `ca` | a pem certificate (at most 3,500 bytes) to trust in addition to the built-in root; `""` removes it; reported as `ca_set` | none |

the settings are part of the saved configuration (`config-save`); the ca is
kept beside the tokens in the credentials directory (root only) and handed to
the subscriber over ipc. a message shows as `title: message` (or the message
alone), folded to printable ascii and at most 128 characters, coloured by
priority: min and low grey, default white, high orange, urgent red. it
arrives with the default transition and leaves like any notification.

**how it runs.** the subscriber is a fourth process, `tc002-ntfy`, spawned
by the supervisor as uid 1001 like netd, with the ipc socket on fd 3 and no
other descriptors. it takes its settings once (the supervisor replaces it on
every settings change), resolves the host through the device's resolvers,
connects, and for `https` speaks tls 1.3 with the standard library's client
and a bundle holding **ISRG Root X1** (the root of ntfy.sh's chain and of
every let's encrypt certificate; sha256
`96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6`,
valid to 2035) plus the extra `ca` if one is installed; `insecure` skips
both the chain and the host name check. it then keeps
`GET /<topic>/json` open (chunked ndjson, a keepalive every 45 s; 90 s of
silence counts as a dead stream), sends each message to the panel through the
supervisor, and reconnects with a backoff from one to sixty seconds using
`since=<last message id>` so nothing published during a gap is lost. the
supervisor restarts it with its own backoff should it exit.

`/status` and `GET /ntfy` report `ntfy.state` (`off`, `connecting`,
`subscribed`, `error`), the message count and the last error text (`dns
lookup failed`, `connect failed`, `tls handshake failed`, `certificate
rejected`, `unauthorized: check the token or password`, `not found: check the
url and topic`, …). the subscriber's log lines are in the ring like everyone
else's.

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

| control | in `art` | in `clock` | in `canvas` |
|---------|----------|------------|-------------|
| left button (release) | select `clock` | select `clock` | select `clock` |
| middle button (release) | select `art` | select `art` | select `art` |
| right button (release) | select `canvas` | select `canvas` | select `canvas` |
| knob rotate | next / previous generator | next / previous clock face | nothing: a canvas is what was pushed to it and has no pages |
| knob short press | the showing scene's own settings | the showing scene's own settings | the showing scene's own settings |
| knob long press (700 ms) | the [device menu](#the-settings-menu) | the device menu | the device menu |

while the menu is open every control belongs to it; the table above applies
only when it is closed.

**the page indicator.** wherever the dial pages something, turning it raises a
row of dots along the bottom: one per page, the one you are on solid and the
rest pulled back towards the background. it covers the art generators, the
clock faces and the menu's own items. it is deliberately
temporary, because a row left up permanently is a row of a 52x16 panel given
away: it fades in over 150 ms, holds for 2.5 s and fades out over 600 ms.

each dot picks its own colour from what is already underneath it, white on a
dark background and black on a light one, so the white clock face and the
brighter corners of the art do not swallow it. the whole row is blended over
the scene by the fade, so a half-faded indicator is a hint rather than a mask.
it is drawn on both sides of a cross-fade, so changing a face leaves the dots
crisp instead of diluting them into the outgoing scene. a notification or a
pushed frame never gets one, because the dial does not page those.

the keycode assignment (`108,105,106,103` = left, middle, right, knob) was
measured on 2026-09-09 from the renderer's press log while the buttons were
pressed: the left button reports the kernel's "key down" 108, the middle one
"key left" 105, the right one "key right" 106 and the knob's push "key up"
103 (the device tree's names are not positions). the supervisor passes the
map to the renderer, so both defaults agree; it is overridable with
`--keymap`; every mapped press is logged (`key N pressed: middle`) and so is
a press outside the map (`unmapped keycode N pressed`), so the map can be
checked from the log route. the vendor's knob driver (the
`knob` device tree node, `ABS_X` on `event68`) reports state codes rather than
a counter: one detent is a pair of events, **8 then 1 turning clockwise and 13
then 11 counter-clockwise**, and the second value of each pair is the step;
anything else is logged as unexpected. the pairs were measured on 2026-09-09
but assigned to the two directions by inference, the wrong way round; the panel
settled it on 2026-09-11, when a clockwise turn walked the menu's dot row
leftwards. everything downstream reads these labels, so `rotate_cw`, the
`cw` of `POST /input` and the `rotary` mqtt event now all mean the direction
the knob is actually turning. actions are queued eight
at a time per loop iteration; overflow is counted and logged, never blocks.

every edge is also reported outward: each button press and release, the
knob's long hold, and every rotary detent with the running position (cw
positive, from renderer start). the supervisor forwards them to netd, which
publishes them on mqtt as momentary events (see [mqtt](#mqtt)). the same
controls can be driven remotely (`POST /input`, `cmd/input`): an injected
`click` is a press and a release through the same mapper, so it produces the
same actions and the same outward events as a finger would.

### scene parameters

every scene declares a table of what it can be told: a name, a kind (`choice`,
`number`, `colour` or `toggle`), its range and its default. nothing outside the
scene knows what any of it means, so the on-panel menus walk a table they have
never seen, and a new scene writes one table rather than touching five places.
a value is always a `u32`: a choice is its index, a number is itself, a colour
is `0x00RRGGBB`, a toggle is 0 or 1.

| scene | parameters |
|---|---|
| clock | `face`, `colour`, `shade`, `colour 2`, `gradient`, `spread`, `digits` |
| art | `scene` (the generator), then the showing generator's own |
| popsquares | `pop ms`, `alive`, `dim chance`, `dim floor`, `dim ceiling`, `tint`, `tint colour` |
| cube | `palette`, `colour`, `hue drift`, `background`, `spin`, `speed`, `zoom` |
| ip | `layout` |

popsquares' table is the sliders of the `popsquares_tc002` processing sketch,
which is where the generator came from. its other sliders — led gap, corner,
off level, panel brightness and the glow — simulate the physical panel this
runs on, so they have nothing to set here. the one change of unit is the
sketch's `decay`, which counts levels lost per frame and therefore means
something different at every frame rate: `pop ms` is the length of a whole pop
instead, which says the same thing and survives a dropped frame (the sketch's
0.1 to 8 is roughly 20 s down to 0.26 s). `alive` is the percentage of the
panel that ever lights, `dim chance` how often a spent cell comes back part-lit
rather than full, `dim floor` and `dim ceiling` the range it comes back into as
a percentage of full, and `tint` the percentage of pops that use `tint colour`
instead of white — rolled afresh on every pop, so the colour drifts around the
panel.

**over the api.** `GET /config` reports every generator's parameters as an
object keyed by the names its table declares, values in the same shape a patch
sends them: a choice by name, a colour as `rrggbb`, a number in decimal, a
toggle as `on` or `off`. `PATCH /config` takes them as a list, because the
names are a scene's own and a strict parser cannot know them in advance:

```json
{"generator_params":[{"scene":"cube","name":"zoom","value":"150"},
                     {"scene":"cube","name":"palette","value":"poly"}]}
```

at most eight per request. an unknown scene, an unknown name or a value that
does not fit its kind is refused with `invalid_scene`, `invalid_param` or
`invalid_param_value` and nothing is written. the change persists and is pushed
to the renderer, so an http client needs no preview of its own.

a generator whose slots have never been written takes the defaults its table
declares rather than zeros: the cube starts blue at 100 per cent zoom, and an
all-zero set is unreachable by editing (speed stops at 1, zoom at 40, a pop at
250 ms), so it is a safe marker for "never set".

the clock is a fixed part of the runtime and keeps named settings; a **generator is pluggable**, so its parameters live in generic slots
(`generator_params`, eight `u32` each) which the supervisor replays to the
renderer when it starts. `GET /scenes` carries every table with its kinds,
ranges and choices, which is the contract the console builds its forms from:
nothing outside the runtime needs to know what a cube is.

the menus draw in the 3x5 `mini` font, the one the mini clock face and the
mini ip layout use: thirteen characters across, and easier to read close up
than the 5x7. that font gained a letter set for them.

a **short press of the knob** opens the showing scene's table as a menu, one
entry per screen with an `exit` at the end. a colour draws as a swatch rather
than six hex digits, and turning the dial walks a hue wheel of 32 positions at
full saturation, snapped to those positions so repeated turns do not drift.
saturation, value and an exact hex belong to the console; a parameter can say
so with `on_panel = false`.

a change previews on the scene at once and is written once it settles, the same
700 ms rule the device menu uses. the supervisor turns it into an ordinary
settings patch, so it persists and reaches netd like any other.

### the settings menu

the knob's **long** press opens the device's own menu, so brightness, the
night schedule and the two message services can be changed with nothing else
to hand.
one item shows at a time, which is the only honest layout on 52x16: the item's
name on the top rows, its value below, and a row of dots along the bottom with
the current item lit.

| item | what it does | persists |
|---|---|---|
| `brightness` | brightness in ten steps, 10 to 100 | yes |
| `ip` | the ipv4 address, drawn full-panel in the current [layout](#ip-layouts); the dial pages the four | yes, as `ip_mode` |
| `night` | the [night brightness schedule](#the-night-brightness-schedule) on or off; reads `no place` when it is on but the device has no location | yes |
| `night level` | the night end of the ramp, in fives down to 5 and then 1 | yes |
| `display off` | turns the display off and closes the menu | no, the panel comes back on a restart |
| `new seed` | reseeds the art at once | no, a seed is not a setting |
| `mqtt` | the broker connection on or off | yes |
| `ntfy` | the subscriber on or off | yes |
| `info` | wifi, battery, time sync and uptime | read only |
| `reboot` | asks first, defaulting to no | n/a |
| `exit` | closes the menu | n/a |

`exit` is last, so it is one counter-clockwise click from the item the menu
opens on. the clock face, the art generator and the ip layout used to live here
and are now parameters of their own scenes, reached by the short press.

- **the knob** turns to move between items, clockwise moving rightwards along
  the dot row (which fades away a few seconds after the last turn, like every
  other page indicator), and its click acts on the one showing: a toggle flips, an adjustable opens for editing (turn to change,
  click to finish), an action runs.
- **the left and right buttons** change the showing item's value in place,
  without opening it for editing; **middle** backs out, and closes the menu
  when nothing is open for editing.
- **fifteen seconds** with nothing touched closes the menu, keeping whatever is
  on the panel. in the reboot dialogue a timeout answers no.

a value is applied at once as a preview but is only **written** once it has
settled, 700 ms after the last change, so a knob spin sends one request and
one file write rather than one per detent. the renderer draws the menu and
previews the change; the supervisor validates it as an ordinary settings patch,
persists it and pushes the result to netd, so the api and mqtt agree with the
panel. two small ipc messages carry this: `menu_request` upward, and
`device_status` every five seconds downward for the info page, which is
otherwise invisible to the renderer.

a notification that arrives while the menu is open is not shown until the menu
closes; its timer runs regardless.

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
`SOCK_SEQPACKET` unix sockets, one packet per message, at most 8,192 bytes
(raised from 4,096 so a canvas document carrying an image arrives whole:
chunking would cost atomicity, and a half-applied document is worse than a
rejected one). `zig build ipcprobe` builds `tc002-ipcprobe`, which measures
what the kernel will actually carry: on this device `SO_SNDBUF` is 196,608 and
datagrams round-trip up to 131,072 bytes, so the limit has a sixteenfold
margin. the cost of the raise is 68 kb of reserved bss across the four
binaries — the renderer and ntfy hold two packet buffers each, the supervisor
five, and netd two plus a request buffer for each of its four connection slots
plus the json parse arena:

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
| supervisor → ntfy subscriber | `ntfy_config` (the settings and the ca, once after spawn) |
| ntfy subscriber → supervisor | `notify` (each message), `ntfy_status` |
| netd → supervisor | `ntfy_put` (the settings patch, the ca inline) |
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
| request head / json body | 4,096 and 8,192 bytes; json nesting ≤ 8; unknown or duplicate fields rejected; invalid utf-8 rejected |
| unsupported | chunked or encoded bodies, `expect: 100-continue`, http/2 |
| time to send a complete request | 5 s, then `400 request_timeout` |
| time for the renderer to answer | 2 s, then `504 timeout` (retry with the same request id) |
| raw frames | 10 per second, then `429 frame_rate` |

### authentication and origins

every route, reads included, needs `Authorization: Bearer <token>` where the
token is 64 hex characters. two tokens exist: **control** (scenes, actions,
notifications, frames, reading settings and status) and **admin** (changing
and saving settings, mqtt credentials). the comparison is constant-time
against both. the tokens are in `/data/tc002/state/credentials/tokens` on the device
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
| `PUT` | `/scene` | control | `{"base":"clock\|art\|canvas","generator":"popsquares\|plasma\|cube"?,"seed":u32?,"clock":{"font","colour_mode","colour","colour2","gradient","spread"}?,"request_id":hex,"epoch":u32?}` | `{"status":"applied","revision":n,"epoch":n,"request_id":…}` |
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
| `GET` | `/icons` | control | | `{"size":8,"names":[…]}`: the built-in [icon](#the-canvas) names |
| `GET` | `/sprites` | control | | `{"slots":8,"sprites":[{"id","width","height"}…]}` |
| `PUT` | `/sprites/{id}` | admin | `application/octet-stream`, 192 or 768 bytes of rgb888 | the sprite list |
| `DELETE` | `/sprites/{id}` | control | | the sprite list |
| `GET` | `/canvas` | control | | the [document](#the-canvas) as held, plus `limits` |
| `PUT` | `/canvas` | admin | `{"elements":[…]}` | the document as stored |
| `PATCH` | `/canvas` | control | `{"values":[{"id":"…","text"/"data"/"data_hex"/"value"/"colour"}…]}` | the document as stored |
| `DELETE` | `/canvas` | control | | the emptied document |
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
{"epoch":1,"revision":12,"renderer":"running","base":"art","generator":"popsquares","seed":3735928559,
 "overlay":"none","brightness":100,"power":true,"presented":35990,"fps":59.9,
 "uptime_s":600,"memory_available_kb":16084,"cpu_pct":5,"restarts":0,
 "network":{"ip":"10.0.0.111"},"time":{"state":"unsynced","age_s":null},
 "menu":{"open":true,"kind":"device","state":"browsing","item":"ip","index":1,"items":11},
 "night":{"enabled":true,"phase":"to_night","held":false,
          "today":{"dawn":1789101184,"sunrise":1789103263,"sunset":1789150014,"dusk":1789152094,"sun_up":false}},
 "config_revision":1,"saved_revision":1,"transport":"plaintext",
 "mqtt":{"enabled":false,"connected":false,"state":"disconnected","reconnect_delay_s":0,"reconnects":0,"last_error":""},
 "boot_id":"3fa1c2d4","sample_age_ms":1200}
```

`fps` is a number only while art is running with no overlay, otherwise
`null` (there is no frame rate to report for a clock). `seed` is the art
scene's current seed, as `POST /action reseed` last set it or as the renderer
picked it at start. it is reported because a client that runs the same
generators — the console's preview compiles them to wasm — can reproduce what
the panel is drawing from it, and cannot without it. it travels renderer →
supervisor → netd on the heartbeat, so it is as fresh as the last beat. `renderer` is `none`,
`starting`, `running` or `stopping`. `power` (after `brightness`) is the
display power switch; `clock` is the effective [clock style](#clock-styles). `boot_id` is random per supervisor start
and is what groups the mqtt discovery entities. `time` is the sntp client's
view: `state` and seconds since the last accepted reply (see
[time](#time-sntp)). `menu` is what the [device menu](#the-settings-menu) is
showing — `{"open":false}` when none is, otherwise its `kind`, its `state`
(`browsing`, `adjusting`, `confirming`) and the item, by name for the device
menu and by position for a scene's. **a client driving the panel over
`/input` should assert this rather than count detents from the top**: that
count changes whenever an item is added, and adding one is what silently
switched mqtt off here on 2026-09-12 — a script that counted six to reach
`info` clicked into `mqtt` instead and then toggled it five times. note also
that once an item is open for editing, further detents change its **value**
rather than moving on. `night` is the [brightness schedule](#the-night-brightness-schedule):
`phase` is `day`, `to_night`, `night`, `to_day`, or `null` when the schedule
is not running; `held` says a hand-set brightness is standing in its way; and
`today` is the sun's own day where the device is, which is `null` with no
location or before the clock has been set. the mqtt metrics carry the phase as
`night` (`off` when it is not running), and home assistant gets it as a
sensor.

### settings

`GET /config` returns, and `PATCH /config` accepts any subset of:

| field | range | live effect |
|-------|-------|-------------|
| `brightness` | 1–100 | applied to the renderer at once |
| `clock_font`, `clock_colour_mode`, `clock_colour`, `clock_colour2`, `clock_gradient`, `clock_spread` | `classic\|mini\|segment\|big\|block\|hires`; `solid\|gradient`; `rrggbb`; `rrggbb`; `horizontal\|vertical\|diagonal`; 0–255 | applied at once; reported as a `clock` object in `/config` |
| `ip_mode` | `lines\|mini\|scroll\|big` | the layout of the device menu's ip page, applied at once; see [ip layouts](#ip-layouts) |
| `base` | `clock`, `art`, `canvas` | applied at once |
| `generator` | `popsquares`, `plasma`, `cube` | applied at once |
| `timezone` | a posix tz rule (`AEST-10AEDT,M10.1.0,M4.1.0/3`) or an iana zone name (`Europe/Amsterdam`, case-insensitive), ≤ 64 characters; anything else is rejected | applied at once; a zone name follows that zone's current daylight-saving law |
| `ntp.server`, `ntp.interval_s` (patch as `ntp_server`, `ntp_interval_s`) | dotted ipv4 or null; 300 or 600 | the sntp client restarts at once and syncs promptly; null disables it |
| `night`, `night_brightness`, `night_lead_min` | bool; 1–100; 0–120 minutes | the [night brightness schedule](#the-night-brightness-schedule); reported as a `night` object in `/config` |
| `latitude`, `longitude` | −90–90 and −180–180 degrees, both together or neither | pins where the device is, overriding the timezone's reference point; `location_auto: true` (patch only) drops the pin again. `/config` reports the pinned pair, and the point they resolve to under `location` with its `source` |
| `frame_timeout_ms` | 100–2000 | stored only: belongs to the unimplemented streaming feature |
| `metrics_interval_s` | 0 (off) or 10–3600 | mqtt `metrics` cadence |
| `discovery.enabled`, `discovery.prefix` (patch as `discovery`, `discovery_prefix`) | bool; ≤ 64 characters | home-assistant discovery on the next mqtt connection |
| `allowed_origins` | up to four exact origins | read from the file only |
| `expected_revision` (patch only) | | the patch is refused with `409 revision_conflict` unless the current revision matches |

`revision` counts accepted patches (and mqtt setting changes) since the
supervisor started with the loaded file; `saved_revision` is what is on disk.
`PUT /config`, `PUT /mqtt` and `PUT /ntfy` write the file before they answer,
so the two match in the reply unless the write itself failed, which is the
signal that it did: the settings are live but not on disk, and the log says
why. nothing needs an explicit save, and nothing is lost by forgetting one.
the file itself is the same document in a slightly different shape, with
`"schema":1` and the mqtt and ntfy blocks inline (the ntfy `token` and `password` are stored as given; the ca lives in the credentials directory instead):

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
| `cmd/frame` | in, qos 1 | binary, 2,510 bytes big-endian: `u64 request_id`, `u32 epoch`, `u16 duration_s`, 2,496 rgb bytes; or 2,514 / 2,515 bytes with `u8 effect`, `u8 direction`, `u16 duration_ms` and optionally `u8 exit` before the rgb (see [transitions](#transitions)) |
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
in when there is no wlan0 mac): 30 read-only diagnostic `sensor` entities that
read from the `metrics` topic (uptime, memory used and available and total, cpu
overall and per process, load, wifi, tmpfs used and total, flash used and total
and as a percentage, battery and usb power, renderer restarts, mqtt reconnects,
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
| `tc002-demo-*.py` | the demo reels, one per topic, played from this machine over the api: `shapes` (the primitives, clipping, bars), `text` (four fonts, alignment, and all eight animations), `charts` (sparkline styles, autoscale against a fixed range, thresholds, sweep, hex samples, a live feed), `icons` (every built-in glyph, five a page, the set fetched from the device), `images` (sprites generated on the host, uploaded, drawn, animated, deleted), `layout` (absolute placement, tiles and rows, boxes, clipping, draw order), `tiles` (the composite at four widths, so the layout switch is visible), `dashboard` (four realistic dashboards, each pushed once then fed only numbers, printing what the layout and the patches cost in bytes). all take `-s`, a token, `--hold`, `--only`, `--list` and `--loop`, and all put back the scene **and the canvas** they found. `tc002demo.py` is their shared helper, not a demo, and `tc002-demo-lint.py` puts every document all eight would send through the runtime's own rules without a device, which is how the shapes reel's 26 elements against a limit of 24 were caught on this machine rather than on the panel |
| `tc002-demo-transitions.py` | a demo reel of every transition, played from this machine over the api: for each effect a clock ↔ art scene change arrives with it, then a labelled notification arrives with it and leaves with the paired exit; `--only` with per-step direction and exit overrides, `--ms`, `--hold`, `--loop`, `--no-scenes`, `--list`; restores the scene it started from and leaves the settings alone |
| `tc002-run.sh` | `push` (build, elf check, push to `/tmp/tc002/`; `TC002_NO_BUILD=1` skips the build), `start [supervisor options]` (under the lock: stop `zkswe`, start the supervisor detached with its log in `/tmp/tc002/`), `status`, `stop` (sigterm, restart the stock app, release the lock), `restore` (stop and remove everything under `/tmp`) |
| `tc002-ipcprobe` (`zig build ipcprobe`) | a device binary, not part of the runtime and not installed with it: makes the same seqpacket socketpair the supervisor uses and round-trips a filled datagram at 1 kb through 256 kb, reporting `SO_SNDBUF` and the largest that survives intact. it answers the one question that bounds every protocol decision here — what the kernel will actually carry — on the device rather than from the host. measured 2026-09-12: `SO_SNDBUF` 196,608, largest datagram 131,072 |
| `tc002-boot-experiment.sh` | `baseline` (time the stock `ctl.start` to the property), `start` (rewrite `startupLibPath` into `/tmp/EasyUI.cfg`, restart `zkswe` through the bootstrap, show the audit), `status`, `restore` |
| `tc002-lock.sh` | the append-only advisory lock in `/tmp/tc002-lock.txt` on the host, for two agents sharing one device: `acquire <intent> [timeout]`, `release`, `status`, `note`. every device-mutating step in the scripts above runs under it |
| `tc002-test-broker.py` | a minimal mqtt 3.1.1 broker (`#`/`+` matching, retained messages, qos 1 acks) that logs every packet, plus a tiny publisher (`--publish HOST TOPIC PAYLOAD_OR_@FILE`) for lan acceptance runs |

typical session:

```bash
cd runtime
tools/tc002-run.sh push
tools/tc002-run.sh start --profile dev --stats --tz 'AEST-10AEDT,M10.1.0,M4.1.0/3'
adb pull /data/tc002/state/credentials/tokens tokens # root over adb; keep the file private
tools/tc002ctl.py -s <device-ip> --token-file tokens status
tools/tc002ctl.py -s <device-ip> --token-file tokens notify hello --colour 00ff80 --duration 4
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set brightness=60 base=clock
tools/tc002ctl.py -s <device-ip> --token-file tokens config-save
tools/tc002-run.sh stop
```

the english web control panel in [`panel/`](panel/) talks to the **stock**
api; [`panel-v2/`](panel-v2/) is the same idea for this api, with a local
proxy that holds the tokens, the transient and durable
[clock styles](#clock-styles) and a live preview from `/screen`.

### the preview renderer (`zig build wasm`)

the console's preview is not a model of the renderer, it **is** the renderer:
`src/wasm_main.zig` wraps `scene.Arbiter` and the modules under `src/scene/`
and `src/panel/`, and `zig build wasm` cross-compiles them to
wasm32-freestanding as `panel-v2/tc002-panel.wasm` (~55 kB, generated, not
committed; `start-panel.sh` refreshes it on every start when zig is present).
the scenes were already the right shape for it — pure, no allocator, no os —
so nothing under `src/scene/` changed to make this work.

the boundary is deliberately javascript-shaped: times cross as f64
milliseconds rather than u64 nanoseconds (a u64 parameter reaches js as a
BigInt, which infects every caller), strings and frames cross through one
scratch buffer, and enums cross as their numeric value. `panel-v2/sim-wasm.js`
maps a `/status` document onto arbiter commands and copies bytes out; it holds
no pixel decisions of its own. the font, generator, clock font, gradient,
digit style and ip layout lists the console offers are read out of the wasm at
load, so a new enum variant in `src/scene/` appears in the console with no
javascript edit at all.

the canvas is shadowed the same way, but its content is not in `/status`: an
integration PUTs a document and the panel draws it. the console fetches
`GET /canvas` when the base is showing one and the revision has moved, and
hands those bytes to `api.parseBody(.canvas_put, ...)` — the runtime's own
parser, the one a real PUT goes through — which wants a fixed byte arena and
no allocator, so it works unchanged in freestanding. there is no document
model in javascript at all, and a document the device would refuse is refused
here too, with the runtime's own code and message shown in the caption rather
than a silently empty panel. this is what took the module from 55 kB to
148 kB: the canvas renderer, 61 icons and the json parser.

the preview is a **shadow**, not a snapshot: it runs the scene code at the
scene's own rate — 60 hz for art, the next whole second for the clock, 33 ms
for a scrolling layout — and reconciles against the device once a second. what
it takes from the device: the scene state from `/status`, the art
[seed](#the-status-document) so the animation is the panel's and not a
lookalike, and the wall clock from the device's own `Date` header, which
`serve.py` forwards as `X-Device-Date` (its own `Date` is this machine's
clock). `/screen` is still polled twice a second, but to *check* the shadow
rather than to replace it: the console compares the two frames and reports how
many bytes agree. on a scene that redraws faster than the poll the two frames
are simply from different instants, so the figure is only offered as a verdict
when the scene is holding still.

this replaced `panel-v2/sim.js`, a 600-line hand-written port of the same
logic. the two agree byte-for-byte on every clock font, the ip `lines`
layout, notifications (centred and scrolling) and the whole brightness curve —
and `panel-v2/test_wasm.mjs` pins that. where they disagree, the port had
drifted: it knew 2 of 3 generators and 4 of 6 clock fonts, drew all four ip
layouts as `lines`, clamped clock gradients by a fixed ±96 where the runtime
uses the style's own `spread`, and had no concept of the digit styles.

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
- **persistence.** settings and credentials are durable (`/data/tc002/state`),
  but the **binaries are not**: they are pushed to `/tmp` and a power cycle
  brings the stock app back, so the runtime is still started by hand. a
  self-starting runtime means rewriting the `res` partition, since nothing in
  the boot chain reads a writable location; the design, the evidence and the
  risks are in the vault note `tc002-customisation/2026-09-09/boot-persistence`.
  the paired-slot install, the vendor image builder and the recovery rehearsal
  do not exist. cold boot against zkdaemon's 15 s check, the upgrade-hook
  ordering (the loader `dlopen`s the app **before** it checks for an upgrade,
  which would strand the vendor flasher) and anything on mtd3 are unmeasured.
- **confinement.** netd is uid 1001, but `/dev/socket/property_service` is
  world-writable on this init, so the uid change alone does not deny it the
  property service. recorded as a gap, not claimed as isolated.
- **physical input**: the three buttons are confirmed on the device (the
  keymap was corrected on 2026-09-09); the knob's push and long press, the
  maintenance gesture and the hardened profile are host-tested only.
- cors headers and an api field for `allowed_origins` (browser clients go
  through `panel-v2/serve.py`).
- **input on hardware.** the outward events and remote injection are tested
  through the api; the buttons have been pressed under this runtime (see the
  keymap above), the knob's push has not.

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
