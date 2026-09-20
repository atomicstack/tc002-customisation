# the custom runtime (`runtime/`)

a replacement for the stock application on the tc002: six arm binaries
and one tiny shared object, written in zig 0.16, that take over the panel, the
buttons and the knob, and expose an authenticated http and mqtt api of their own.
`tc002-berryd` links libc for the [script interpreter](#scripting-berry), and
`tc002-audiod` is dynamically linked because it uses the device's own audio
library; the rest are static with `link_libc = false`. while it runs, the stock `zkgui` app (and with it the stock
http api on port 80, the cloud client, the built-in apps) is not running.

the runtime is **flashed to the `res` partition** and boots itself: binaries in
`/res/bin`, the bootstrap in `/res/lib`, the boot hook `/res/etc/EasyUI.cfg`.
settings and credentials live under `/data/tc002/state/` on the jffs2 partition.
logs, the panel lock and udhcpc's pidfile stay in `/tmp/tc002/`, which is the one
directory that has to be writable.

the `/tmp` install still exists and is what development uses: push the binaries
there, write `/tmp/EasyUI.cfg` (the loader reads it before `/res/etc`), and a
power cycle comes back to whatever is in flash. that is also the shape of the
recovery hand-back. ~~a power cycle always comes back stock … no partition is
ever rewritten~~ — **✗ that was true until 2026-09-15 and is not now.** this document is the reference for what the code
does; how to build and run it is in [`runtime/README.md`](runtime/README.md).

## processes

| binary | runs as | size¹ | role |
|--------|---------|------:|------|
| `libtc002-bootstrap.so` | inside the vendor loader | 4.3 kb | the "startup library" the loader `dlopen`s. its constructor `execve`s the supervisor in place, passing `--from-bootstrap` and the loader's environment. no libc, no `DT_NEEDED`. if the exec fails it prints one line and exits 1; it never touches the anti-brick property |
| `tc002-supervisor` | root | 1,078 kb | sets `sys.zkapp.state=running` first, then owns everything privileged: spawns and watches the renderer, binds port 80, generates the api tokens, keeps the settings file, reads the maintenance gesture, polls `wlan0`, relays api commands, samples `/proc` |
| `tc002d` | root | 534 kb | the renderer. the only process that opens `/dev/spidev0.0` and the latch gpio. scenes, overlays, physical input, paced presentation, heartbeats |
| `tc002-netd` | uid 1001 | 873 kb | the network daemon: an http/1.1 server for `/api/v1`, an mqtt 3.1.1 client and an mdns responder for the clock's own name ([discovery](#discovery-mdns)). holds no authoritative state; every command is relayed through the supervisor to the live renderer |
| `tc002-ntfy` | uid 1001 | 1,231 kb | the ntfy subscriber: dns, tcp, tls 1.3 with the standard library (that is the size), the json stream; sends `notify` to the supervisor. only runs while `ntfy.enabled` |
| `tc002-berryd` | uid 1001 | 749 kb | the [script interpreter](#scripting-berry): one berry vm on a fixed heap. the only binary that links libc. no network descriptor at all. only runs while `berry.enabled` |
| `tc002-audiod` | root | 397 kb | the speaker: one sound at a time from the store, decoded and handed to the audio-out. root because `/dev/mi_ao` is `crw-------`, the same trade the renderer makes for spidev. only runs while `sound.enabled` |
| `tc002-memdump` | root, by hand | 167 kb | a maintenance tool that streams a sparse memory snapshot of one process over adb ([memory audits](#memory-audits)) |

¹ ReleaseSafe, stripped, measured at `v0.1.0-87` on 2026-09-15. ~~as built on
2026-09-06 … roughly 66 / 147 / 170 kb for the three daemons~~ — **✗ those
figures were two to three times too small and are gone.** the six runtime
binaries total about 5.0 mb; in the flashed image, squashfs-compressed, the whole
`res` comes to 4.45 mb of the 8 mib partition. on the `/tmp` path the binaries
sit in tmpfs, so their size is ram.

the split follows one rule: the supervisor is the only privileged process that
parses nothing from the network, the renderer is the only process that touches
the panel, and the network daemon can be killed and restarted at any time
without the display noticing. all three are single-threaded epoll loops with
static buffers and no steady-state allocation; every state machine, codec and
scene is a pure module with host tests (461 of them pass under `zig build
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
- `zkdaemon` triggers a reflash of the app partition (by restarting the
  loader with the upgrade properties set; it only works if an `update.img`
  is on the udisk, see [`FIRMWARE.md`](FIRMWARE.md#zkdaemon-the-boot-check-and-the-reset-key))
  if `sys.zkapp.state` is not `running` 15 s after boot. the supervisor's very
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

**power:** the runtime polls the mcu for the pack voltage and usb state and
puts the device away when the cell is flat, at the stock firmware's own
thresholds — see [the low-battery shutdown](#the-low-battery-shutdown). the
behaviour has not been watched through a real discharge, so on a bench run it is
still worth staying on usb power.

## the supervisor

```
usage: tc002-supervisor [options]
  --profile dev|hardened  dev leaves adbd alone; hardened resets persist.sys.zkdebug=0 at boot (dev)
  --bin-dir PATH          where this runtime's own binaries are (the build's -Dbin_dir)
  --renderer PATH         candidate renderer (<bin-dir>/tc002d)
  --fallback PATH         fallback renderer after three failures in sixty seconds (same as --renderer)
  --dir PATH              writable runtime directory: log, lock, pidfiles (/tmp/tc002)
  --lock PATH             panel lock file (<dir>/panel.lock)
  --tz RULE               posix tz rule handed to the renderer (UTC0)
  --keymap L,M,R,K        keycodes for left, middle, right, knob (108,105,106,103)
  --keys PATH             button evdev node (/dev/input/event67)
  --knob PATH             rotary evdev node (/dev/input/event68)
  --ip-poll S             seconds between wlan0 address checks (5)
  --no-property           do not set sys.zkapp.state (host-less experiments only)
  --close-inherited       close every inherited descriptor above stderr after the audit
  --stats                 ask the renderer for periodic statistics
  --rt-priority N         run the renderer at SCHED_FIFO N (1..99); 0 leaves it normal
  --usb-role device|host|keep  put the usb port in device mode so adb works over the cable (device)
  --netup-dir DIR         bring wifi up ourselves, using busybox and the scripts in DIR
                          (the build's -Dnetup picks the default; empty means do not)
  --from-bootstrap        set by the bootstrap shared object; logged only
```

#### `--usb-role`, and the replug that catches everyone

The supervisor writes `usb_device` to
`/sys/bus/platform/devices/soc:usbotg/otg_role` at startup, and `--usb-role`
chooses what it writes.

> **corrected 2026-09-16.** This section used to say the controller *"boots in
> host mode and nothing in the stock boot changes it"*, and that the
> supervisor's write *"has to be us, because the role resets on every boot"*.
> ~~Both were wrong.~~ Measured across two boots of the flashed runtime: the
> controller comes up in **device** mode, the gadget enumerates at t≈2.7 s, the
> kernel's `usb-scan` kthread flips the port to host at t≈3.7 s, and
> `libzkhardware.so` flips it back at t≈6.8 s — **200 ms before** the supervisor's write at
> t≈7.0 s, which therefore only confirms a role that is already set. The write
> is cheap and still worth keeping as a guarantee, but it is not what turns adb
> on. What the *stock* app leaves the role at after its own scan was not
> re-measured, and the original stock reading may itself have been an artifact
> of reading the action files — see [`DEVICE.md`](DEVICE.md#adb).

**A cable left plugged in across a reboot does not come back, and no code we run
can fix it.** The port re-enumerates on the host within about five seconds — but
what it enumerates is the one-second gadget session that exists between t≈2.7 s
and t≈3.7 s, and the host-mode excursion that follows hides the disconnect, so
the host keeps a device object it can never talk to again. Nothing the device can
do afterwards clears it, and the excursion itself belongs to the kernel's
`zkswe,sstar-otg` driver, which runs long before any process of ours exists.
Expect a replug after every reboot if you want usb back; wifi returns on its own
in about sixteen seconds. [`DEVICE.md`](DEVICE.md#what-happens-to-usb-across-a-reboot)
has the measured timeline, the disassembly, the three re-advertise mechanisms
that were tried and failed, and the two bytes of kernel that would fix it.

`--usb-role keep` opts out. The default costs physical-access root over usb,
which is the same root the dev profile already hands to anyone on the lan, and
the hardened profile turns adbd off entirely.

#### where the binaries are, and why it is not `--dir`

`--bin-dir` and `--dir` used to be one option, and they cannot be. `--dir` is
the **writable** directory — the log, the panel lock, udhcpc's pidfile — while
the binaries on a flashed install sit on a read-only squashfs. while the two
were one, a runtime on `/res` would have tried to write its log into flash.

both have compiled-in defaults, and for a flashed runtime those defaults are all
it will ever have: the bootstrap execs the supervisor with only
`--from-bootstrap`, and the supervisor spawns its five children by absolute
path, so **a flashed runtime never sees a command-line argument in its life**.
`zig build -Dbin_dir=/res/bin -Dnetup=true` is what `tools/tc002-mkimage.sh`
uses; the default build stays on `/tmp/tc002` with bring-up off, because on a
pushed install the vendor loader has already brought wifi up and restarting
`wpa_supplicant` would drop the adb link underneath you.

| built with | binaries | writable | wifi bring-up |
|---|---|---|---|
| `zig build` | `/tmp/tc002` | `/tmp/tc002` | the loader already did it |
| `-Dbin_dir=/res/bin -Dnetup=true` | `/res/bin` | `/tmp/tc002` | ours, at boot |

all five child paths come from one place (`supervisor/cli.zig:resolve`). they
did not always: `netd` and `ntfy` were rebuilt from `--dir` at startup while
`audiod` and `berryd` kept their compiled-in defaults, so moving the directory
moved two of the four and silently left the other two behind — a failure with no
symptom until `sound.enabled` or `berry.enabled` was turned on and the exec
failed.

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
topics report. two honesty notes: ~~this 4.9 kernel reports `VmRSS` = 4 kb for
every static process~~ — **✗ not every one:** the supervisor reports 1,112 kb and
netd 972 kb, with `statm` agreeing, while `tc002d` reports 4 kb while actively
drawing. no cause has been established; use `tc002-memdump` where a real figure
matters. and the values are
reported as-is with a `sample_age_ms`. `wlan0`'s address is polled every
`--ip-poll` seconds through `SIOCGIFADDR` and pushed to the renderer on change.

### time (sntp)

with `ntp_server` set, the supervisor runs a minimal sntp client (rfc 4330)
on one udp socket connected to that ipv4 address on port 123: no dns, no
thread, no rtc.

**opening that socket is retried for as long as it takes.** `connect` needs a
route, so it fails for the first seconds of a cold boot and during any wifi
outage; that used to be treated as "no `ntp_server` configured" and switched
sntp off for the rest of the run. with no rtc on this device the clock then sat
at the 1970 epoch until someone restarted the runtime. the open now backs off
2, 4, 8 … up to 60 s and never gives up, and an address arriving retries at
once rather than waiting out the backoff.

it sends a 48-byte ntpv4 request as soon as wlan0 has an
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

#### the clock does not show a time it does not have

There is no usable rtc, so the device boots at the unix epoch and the clock
scene would draw `01:00:00` — in Europe/Amsterdam — until the first reply
lands. That is a plausible-looking lie: it is a time, it ticks, and nothing on
the panel says it is wrong.

So until the clock has been set, **the digits are not drawn at all.** What is
left is the separators — `:` between the fields, `/` in the `mini` date line —
pulsing once a second, deeper than the canvas `pulse` because they are the only
thing on the glass, and never quite to black, because a pulse that vanishes
reads as a fault rather than as waiting. The `hires` sweep bar is dropped too:
it implies progress through a second that is not worth drawing. The moment sntp
steps the clock, the time appears.

The renderer works this out for itself, from `clock.isUnset`: a wall clock
still below 2020-01-01 has never been told what time it is. Nothing is pushed
from the supervisor and no ipc field was added, which also means the console's
preview shows the same thing without being taught about it — it is the same
scene code compiled to wasm, reading the same wall time.

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

**[`CANVAS.md`](CANVAS.md) is the visual companion to this section**: every font, numeral, icon and
primitive photographed off the panel, and the animations as recordings. this section is the
reference — the fields, the limits and what is stored when.


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

`data` is a **list of numbers**, and a json string in its place is refused rather than read: zig's
parser fills a byte slice from a string as readily as from an array, so `{"data":"1,2,3"}` would
otherwise become five samples of 49,44,50,44,51 — the digits and the commas — and draw a
plausible-looking wrong picture. `data_hex` is the supported way to carry samples as a string, and
is the same samples as hex for a document that would not otherwise fit: 52 samples cost 208
characters as json digits and 104 as hex.

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
layout decision: given at least twelve pixels of width beyond its glyph it puts the glyph on the
left with the label over the value beside it; narrower than that, the value goes under the glyph.
the label is **dropped** rather than squeezed or cut off whenever it cannot be drawn whole — too
narrow a tile, a box shorter than the eleven pixels two lines of the small face need (`row n of 2`
is eight), or simply a label wider than the room left beside the glyph. a box too short for even a
glyph and a value keeps the value, which is the half worth having. the glyph's width is whatever is
actually drawn, so a 16×16 uploaded sprite pushes the text further right than an 8×8 icon does.
a patch's `text` replaces a tile's `value_text`, because the reading is the part that changes; the
label is layout and waits for a `PUT`.

**limits**, reported by `GET /canvas` so a client need not hard-code them: 24 elements, 256 bytes of
text, 1,024 bytes of sample data, 52 samples per sparkline (one per panel column). a document is
about two kilobytes on the wire and travels in one ipc packet, whole.

a request body is capped at 8,192 bytes, which is what actually bounds a document: nothing bigger
can be put there. the read-back is wordier than the put — the device's canonical form plus each
element's `age_ms` — so netd answers from a 12 kb buffer. it was 3,584, and at that size a client
could create a document it was then unable to read back: a full one of 24 animated elements with
the sample pool loaded measures **5,957 bytes**. that cost 45 kb of netd's bss (four connection
buffers and the shared json buffer), taking it from 356 kb to 401 kb — the slot count was four
when that was measured; `GET /events` raised it to eight later, and **that** raise is the
100.5 kb one below.

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

**the animation clocks, and why the document alone is not enough.** the device starts a
document's animations when it installs it: one `epoch_ns` for the continuous motions (hue, pulse,
blink, bounce) and one `started_ns` per element for the arrival ones (scramble, typewriter, sweep).
none of that is in the document — a document is a declaration and says nothing about when it was
said — so a second renderer of the same document installs at its own instant and every animated
element is permanently out of phase with the panel. the console's preview is exactly that second
renderer, and it measured the gap: the same document installed 400 ms apart and drawn at the same
instant differed by 136 bytes on a scramble, 146 on a blink, 219 on a hue, and not at all with no
animation.

so `GET /canvas` publishes **`age_ms`**: one for the document, and one on each element. both are
needed, because installing restarts only the elements whose value actually changed — after a
`PATCH` of one reading, that element's clock is young and its neighbours' are not. a client
back-dates its own install by those ages and the phases line up; `canvas.Clocks.backdate` is that
operation, and an element it is not given an age for falls back to the document's.

`PUT` **accepts `age_ms` and ignores it**. the device owns when an animation started, but a client
that reads a document and puts it back — which is how the demo reels restore what they found —
would otherwise be sending a field the schema refused.

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
no effect named, from the buttons or `PUT /scene`, slides forward (clock, art,
canvas) to the left and back to the right; the knob's generator change fades.
**both layers stay live** while an effect runs: the outgoing scene keeps
rendering as the old layer (art keeps stepping, an outgoing generator too,
the clock keeps ticking, a notification keeps scrolling) until the effect
ends. **the canvas is the exception**: it leaves as the last frame it rendered,
because the document behind it belongs to a client, and a client that clears
what it drew before handing the panel back would otherwise slide out as the
empty canvas's hint rather than as its own picture. only when an effect starts while another is still running is the old
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
of a tzdata directory (`runtime/src/scene/zones.zig`, about 22 kb, in the
supervisor only: the renderer still receives a plain rule). daylight saving
therefore follows each zone's current law with no database on the device;
historical rule changes are not modelled, and the two african zones on
permanent summer time are stored as their fixed summer offset. regenerate the
table when tzdata changes. names match case-insensitively; a name the table
does not know is rejected with `400 rejected`.

### physical controls

| control | in `art` | in `clock` | in `canvas` |
|---------|----------|------------|-------------|
| left button (tap) | select `clock` | select `clock` | select `clock` |
| middle button (tap) | select `art` | select `art` | select `art` |
| right button (tap) | select `canvas` | select `canvas` | select `canvas` |
| left button (hold, 700 ms) | show the clock and open [its settings](#scene-parameters) | " | " |
| middle button (hold) | show art and open its settings | " | " |
| right button (hold) | show the canvas and open its settings | " | " |
| knob rotate | next / previous generator | next / previous clock face | nothing: a canvas is what was pushed to it and has no pages |
| knob tap | a new seed | nothing yet | nothing yet |
| knob hold (700 ms) | the [device menu](#the-settings-menu) | the device menu | the device menu |

while the menu is open every control belongs to it — **except the three holds**,
which work from anywhere and walk straight from one scene's settings to the
next. the rest of the table applies only when the menu is closed.

**every button has a tap and a hold, and they are one pair.** a button selects a
base and holding it opens that base's settings, so the settings you are editing
always belong to the thing you are looking at, and you never have to select a
scene before you can configure it.

**a hold is not also a tap.** `long` is reported once held past 700 ms and the
tap's action is then suppressed on release, so holding `left` opens the clock's
settings rather than also selecting the clock twice over. that is what makes a
hold a gesture rather than a slow press, and it is the rule the knob has always
followed.

**which is what freed the dial's click.** it used to open the showing scene's
settings; that is the hold's job now, so a click goes to the scene itself. art
takes a new seed from it — which is what a click on a generated picture should
do, and what it did before the menus existed. the clock and the canvas do
nothing with one yet.

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

**holding a base's own button** — left for the clock, middle for art, right for
the canvas — shows that base and opens its parameter table as a menu, one entry
per screen with an `exit` at the end. a colour draws as a swatch rather
than six hex digits, and turning the dial walks a hue wheel of 32 positions at
full saturation, snapped to those positions so repeated turns do not drift.
saturation, value and an exact hex belong to the console; a parameter can say
so with `on_panel = false`.

a change previews on the scene at once and is written once it settles, the same
700 ms rule the device menu uses. the supervisor turns it into an ordinary
settings patch, so it persists and reaches netd like any other.

### the settings menu

the knob's **hold** opens the device's own menu, so brightness, the
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
| `reboot` | asks first, defaulting to no; the panel then reads [`rebooting...`](#the-reboot-notice) | n/a |
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

#### the reboot notice

A reboot takes the device away for about twenty seconds. This used to blank the
display on the way out, on the reasoning that a dark panel beats a frozen clock.
Both are worse than a word, because a dark panel and a dead one look identical.

So the supervisor draws `rebooting...` across the panel first — the `mini` face,
centred, in rgb 58 110 165 — waits 1.2 s, and only then runs `/bin/reboot`. The
wait is the point: the renderer has to receive the frame, draw it and latch it,
and killing the process that does that in the same breath would leave whatever
was there before. The panel holds its last latched frame while nothing is
driving it, so the word stays on the glass for the whole dark stretch and
costs nothing to keep there.

It goes out as a stream frame, so it touches no persisted state — unlike the
flasher's `Updating...`, which is the canvas base and has to be captured and put
back. It is held for ten seconds, far longer than the wait, so that **if the
exec fails the notice expires by itself** and the clock returns rather than the
device sitting on a lie. A battery notice due in the same window stands aside.

`scene/banner.zig` draws it, and is a pure module with pixel tests like
`batteryart.zig`. A string too wide for the panel is refused rather than drawn
off the edge: half a word is worse than none.

There is no reboot route on the http api — `ActionKind` is
`brightness reseed arm_stream power` — so this is reached from the device menu,
or over `/input` by driving that menu. To put the same word up before a reboot
you are causing from outside, send a notification first and then reboot however
you were going to:

```bash
runtime/tools/tc002ctl.py -s <ip> --token-file tokens notify "rebooting..." --colour 3a6ea5 --duration 30
adb -s <ip>:5555 reboot
```

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
five, and netd two plus a request buffer for each of its eight connection slots
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

`zig build ipcbench` builds `tc002-ipcbench`, the latency companion: it forks a
peer over the same socketpair and pins both ends with `sched_setaffinity`, so
the cost of putting a component in a process of its own is measured rather than
argued about. on this device, p50 over 2,000 round trips after 200 warmup:

| payload | same core | across the two cores |
|---|---:|---:|
| 64 bytes | 41 us | 42 us |
| 2,520 bytes (a whole frame packet) | 53 us | 60 us |
| 8,192 bytes | 88 us | 98 us |
| frame packet, waiting in `epoll_wait` | 56 us | 66 us |

one-way with the peer draining, 3,000 frames: 48,149 frames/s on one core,
**120,192 frames/s across the two** (8.3 us per frame). streaming is faster
across cores because the two processes run at the same time instead of
ping-ponging through the scheduler. against a 16,667 us frame budget, handing a
whole frame to another process costs 0.05% of a frame.

| direction | kinds |
|-----------|-------|
| supervisor → ntfy subscriber | `ntfy_config` (the settings and the ca, once after spawn) |
| ntfy subscriber → supervisor | `notify` (each message), `ntfy_status` |
| netd → supervisor | `ntfy_put` (the settings patch, the ca inline) |
| renderer → supervisor | `heartbeat` (presented count, revision, state, base, generator, overlay, brightness), `ready`, `result`, `input` (the edges), `applied` (the statements those edges and every command turn into) |
| supervisor → renderer | `set_base`, `notify`, `frame`, `brightness`, `reseed`, `arm_stream`, `time_corrected`, `ip_changed`, `stop`, `set_timezone` |
| supervisor → netd | `credentials`, `config`, `status`, `result`, `save_result`, `input`, `applied` (fanned out to any [event stream](#the-event-stream) subscriber) |
| netd → supervisor | `status_get`, `config_get`, `config_patch`, `config_save`, `mqtt_put`, and the renderer commands above for relay |
| supervisor → audiod | `sound_config` (once after spawn), `sound_cmd` (play, stop) |
| audiod → supervisor | `sound_status` (every second; also the liveness ping) |
| supervisor → berryd | `berry_config` (once after spawn), `berry_script` (each stored script, then `reload`), `input` (button and knob edges), `berry_event` (mqtt and ntfy arrivals) |
| berryd → supervisor | `berry_status` (every second; also the liveness ping), `berry_result` (did a script compile), `berry_event` (subscribe, publish), `stream_frame`, and the renderer commands above for relay |

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
the protocol surface is deliberately narrow. ~~the whole daemon fits in about
60 kb of static buffers~~ — **✗ it is nearer 250 kb**: 8 connections × (12,288 in
+ 13,312 out) is 200 kb on its own, plus a 16 kb json arena, a 12 kb json buffer
and two 8 kb ipc packets:

| limit | value |
|-------|-------|
| concurrent connections | 8 (a ninth gets a canned `429` and is closed); a subscriber holds one for as long as its page is open |
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
against both.

the tokens are in `/data/tc002/state/credentials/tokens` on the device; `adb
pull` it as root. the file is text, and each line is the token exactly as the
header wants it:

```
control=<64 hex>
admin=<64 hex>
```

so driving the api by hand is `CONTROL=$(awk -F= '/^control=/{print $2}' tokens)`
and then `-H "authorization: Bearer $CONTROL"`.

**give an integration its own token rather than the built-in one.**
`POST /tokens` issues a named token you can revoke on its own; the two built-in
tokens cannot be revoked without invalidating every client at once. the built-in
admin token holds every scope, so pasting the wrong line into a shortcut works
and says nothing, while being able to rewrite settings, mqtt credentials and
stored scripts.

### scopes

a token holds a **set of scopes** and a route needs **one bit**. there is no
hierarchy: holding `settings` does not imply `notify`, and a token can be given
exactly one job. this replaced a `read < control < admin` ladder, which could
not express the thing almost every integration wants — a token that may raise a
notification and nothing else.

| scope | reaches |
|---|---|
| `status` | the safe reads: `GET` `/status` `/scenes` `/config` `/canvas` `/icons` `/sprites` `/sounds` `/berry` `/berry/scripts` `/mqtt/status` |
| `screen` | `GET /screen` — the one read that returns what is *on* the panel rather than how it is set up |
| `logs` | `GET /logs` and `GET /events` — the ring carries whatever any component printed, a script's own `print` included |
| `notify` | `POST /notify`, and nothing else |
| `display` | what is on the panel now: `/scene`, `/action`, `/frame`, `/streams`, canvas `PATCH` and `DELETE` |
| `sound` | `POST /sound` |
| `input` | `POST /input` — **see the warning below** |
| `content` | stored assets: sprites, sounds, canvas `PUT` |
| `scripts` | the berry store: reading a script's source, writing, deleting, running |
| `settings` | `PATCH /config`, `/config/save`, `/mqtt`, `/ntfy` — durable configuration, and the only place credentials live |
| `tokens` | the token routes. **the admin token's alone**: one that could mint tokens could mint itself more, and revocation would stop meaning much |

the two built-in secrets are scope sets like any other token. `admin` holds
every scope. `control` holds `status screen logs notify display sound input` —
operate the device and watch it, but do not store, reconfigure or mint.

**`input` reaches further than it looks.** injecting button events drives the
physical ui, and the knob's hold opens the device menu, which can change
brightness, the night schedule, the ip layout, mqtt and ntfy on or off — gated
over http by `display` and `settings` — and **reboot**, which has no http route
at all. so `/input` reaches past `settings` rather than merely as far as it.
that has always been true of any token that could post to `/input`; what is new
is that a named token can now be issued **without** `input`, which is the only
way that reach was ever going to be refusable. treat granting `input` as
granting `settings`, and then some.

a named token is never granted `tokens`, and asking for it is refused by name
rather than quietly dropped.

**a credentials file written before scopes existed is migrated, not refused.**
its client lines carry a role name; `control` becomes exactly the set the
built-in control secret holds, and `read` becomes `status screen` — it reached
`GET /events`, which now lives under `logs` beside the log ring it was
deliberately kept away from, so it loses the event stream rather than gaining
the ring. the file is rewritten in the new form on the next start, so the
migration happens once. this matters more than it sounds: an unreadable
credentials file makes the supervisor **generate new tokens**, so refusing the
old format would have answered an upgrade by silently invalidating every
integration on the network.

**rotating replaces a secret in place** rather than issuing a second token and
revoking the first. at capacity there is no free slot, so create-then-revoke
could not rotate the token you would most need to; it is also two calls where a
failure between them leaves either two live secrets or a dead client. the old
secret stops working immediately. `POST /tokens` still answers `409` for a name
that exists, so a mistyped re-create cannot quietly replace a working
integration's credential — rotation has its own verb precisely so it never
happens by accident.

`last_used_s` lives in memory and resets when the runtime restarts, because netd
is the process that sees a token used and persisting it would mean a flash write
per request. `0` means "not since the last restart", not "never".

a file written before this format was 64 raw bytes, control then admin. the
supervisor still reads that, keeps the same tokens and rewrites the file as
text on its next start, so nothing needs re-pairing.

anyone who can sniff the lan can read the tokens in flight, which is why this
profile is called `isolated-lan`.

a request with no `Origin` header (a non-browser client) is allowed. a browser
request is also allowed when its origin exactly matches `http://` plus the request
host, so the device's own api explorer can execute authenticated requests. other
origins must appear exactly in `allowed_origins`, or receive `403 origin_denied`.
no cors headers are emitted. every api request still needs its bearer token;
there are no cookie credentials. `allowed_origins` is file-only.

### offline api explorer and schemas

open `http://<device>/api/docs` for a swagger-style reference and request editor.
the page, javascript, styles and schema ship in netd and work without internet
access. `/api/openapi.json` is the openapi 3.1 document; `/api/schema.json` exports
its models as json schema draft 2020-12 `$defs`. for example, a validator can use
`/api/schema.json#/$defs/NotifyBody` to validate a notification body. the
[`openapi file`](runtime/src/net/docs/openapi.json) can also be loaded into swagger ui
or another openapi client.

these five static assets (plus the trailing-slash page alias) are public and
contain no device state. executing an operation still requires a token with its
listed scope. the page keeps the token only in memory, sends only to this origin,
and never follows redirects. requests run only when execute is pressed. responses
are limited to a 64 kib preview and ten seconds, with a stop button for event streams.
use the cli for ongoing streams and multi-chunk uploads. stream-session routes are
listed as unavailable rather than presented as working features.

schemas are generated from the route and request-field declarations with explicit
validation constraints and response models in `runtime/tools/generate-api-schema.py`.
changes to wire behavior must update this contract. shared byte pools, state-dependent
conflicts and other runtime-only checks are documented where json schema cannot
express them. assets larger than a response buffer are sent in bounded chunks from
read-only storage; connection buffers stay the same size.

### routes

| method | path | scope | body | reply |
|--------|------|-------|------|-------|
| `GET` | `/status` | `status` | | the [status document](#the-status-document), including `build` — see [which build is running](#which-build-is-running) |
| `GET` | `/scenes` | `status` | | the static catalogue: bases, generators, notification and frame bounds |
| `PUT` | `/scene` | `display` | `{"base":"clock\|art\|canvas","generator":"popsquares\|plasma\|cube"?,"seed":u32?,"clock":{"font","colour_mode","colour","colour2","gradient","spread"}?,"request_id":hex?,"epoch":u32?}` | `{"status":"applied","revision":n,"epoch":n,"request_id":…}` |
| `POST` | `/action` | `display` | `{"action":"brightness\|reseed\|arm_stream","brightness":1..100?,"seed":u32?,"request_id":hex?,"epoch":u32?}` | as above |
| `POST` | `/notify` | `notify` | `{"text":"…","colour":"rrggbb"?,"duration_s":1..300?,"request_id":hex?,"epoch":u32?}` (`duration_s` optional, defaults to 5) | as above |
| `POST` | `/frame?duration_s=` (`request_id`, `epoch` optional) | `display` | `application/octet-stream`, exactly 2,496 bytes | as above |
| `POST` | `/action` (`"action":"power"`) | `display` | `{"action":"power","power":true\|false,"request_id":hex?,"epoch":u32?}` | as above; fades over 600 ms |
| `POST` | `/input` | `input` | `{"control":"left\|middle\|right\|knob\|rotary","event":"press\|release\|click\|long\|cw\|ccw","steps":1..16?,"request_id":hex?,"epoch":u32?}` | as above. `click` is a request for a press and a release and reports as those two edges, never as a third; `long` is any button; `cw`/`ccw` are the rotary only and take `steps` |
| `GET` | `/screen` | `screen` | | `{"width":52,"height":16,"epoch","revision","brightness","power","rgb_base64":"…"}`: the frame as shown, after fades, before brightness. `?format=raw` returns the 2,496 rgb bytes as `application/octet-stream` |
| `GET` | `/logs?after=N` | `logs` | | `{"next":seq,"lines":[{"seq":n,"text":"…"}…]}`: up to 16 lines of the [log ring](#the-log-ring) after sequence number `after` (0 = oldest kept); pass `next` back to continue. a jump in `seq` means lines were evicted |
| `GET` | `/events` | `logs` | | an [event stream](#the-event-stream): `text/event-stream`, one `data:` frame per statement applied, held open until the client goes away |
| `GET` | `/sounds` | `status` | | `{"used","budget","sounds":[{"name","bytes"}…]}` |
| `PUT` | `/sounds/{name}?offset=N&final=1` | `content` | `application/octet-stream`, at most 4,096 bytes | one chunk of a sound. `offset` must be exactly what has already landed; `final=1` commits. see [sound](#sound) |
| `DELETE` | `/sounds/{name}` | `content` | | `{"status":"ok",…}` |
| `POST` | `/sound` | `sound` | `{"name":"chime","volume":1..100?,"loop":bool?}` or `{"stop":true}` | plays a stored sound, or stops what is playing |
| `GET` | `/berry` | `status` | | `{"state":"off\|starting\|running\|failed","heap_bytes","heap_used","heap_high_water","alloc_failures","stops"}` |
| `GET` | `/berry/scripts` | `status` | | `{"used":n,"budget":65536,"scripts":[{"name","bytes","compiled"}…]}` |
| `GET` | `/berry/scripts/{name}` | `scripts` | | the source as `text/plain`, byte for byte as stored and exactly what `PUT` takes back; 404 if there is no script of that name |
| `PUT` | `/berry/scripts/{name}` | `scripts` | `text/plain`, at most 8,000 bytes | `{"status":"ok","name":"…"}`. the script is **compiled before it is stored**: one that will not parse answers 400 `script_will_not_compile` carrying berry's own message, and never reaches flash |
| `DELETE` | `/berry/scripts/{name}` | `scripts` | | `{"status":"ok","name":"…"}`, or 404 |
| `POST` | `/berry/scripts/{name}/run` | `scripts` | **none** | runs the stored script: `{"status":"ok","name":"…"}` plus `"note"` when it evaluated to something. a body is `400 unexpected_body`; berry off is `409`; the vm not up yet is `503`; a script that raises is `400 script_failed` carrying berry's own message |
| `GET` | `/config` | `status` | | the [settings document](#settings) |
| `PATCH` | `/config` | `settings` | any subset of the settings fields plus `expected_revision`? | the settings document after the patch |
| `POST` | `/config/save` | `settings` | `{"revision":u32}` or an empty body, `application/json` either way | `{"status":"saved","saved_revision":n}` |
| `GET` | `/icons` | `status` | | `{"size":8,"names":[…]}`: the built-in [icon](#the-canvas) names |
| `GET` | `/sprites` | `status` | | `{"slots":8,"sprites":[{"id","width","height"}…]}` |
| `PUT` | `/sprites/{id}` | `content` | `application/octet-stream`, 192 or 768 bytes of rgb888 | the sprite list |
| `DELETE` | `/sprites/{id}` | `content` | | the sprite list |
| `GET` | `/canvas` | `status` | | the [document](#the-canvas) as held, plus `limits` and the `age_ms` of every animation clock |
| `PUT` | `/canvas` | `content` | `{"elements":[…]}` | the document as stored |
| `PATCH` | `/canvas` | `display` | `{"values":[{"id":"…","text"/"data"/"data_hex"/"value"/"colour"}…]}` | the document as stored |
| `DELETE` | `/canvas` | `display` | | the emptied document |
| `GET` | `/mqtt` | `settings` | | broker settings; `password_set` instead of the password |
| `PUT` | `/mqtt` | `settings` | `{"enabled","host","port","username","password","client_id","prefix","tls"}`, any subset | the broker settings |
| `GET` | `/mqtt/status` | `status` | | `{"enabled","connected","state","reconnect_delay_s","reconnects","last_error"}` |
| `GET` | `/tokens` | `tokens` | | `{"clients":[{"name","scopes":[…],"created_s","last_used_s"}],"max":16}`; **never a secret** |
| `POST` | `/tokens` | `tokens` | `{"name":"kitchen","scopes":["notify","display"]}` | `{"name","scopes","token":"<64 hex>"}` — the only time a token is returned. an empty list, an unknown name or `tokens` is `400 invalid_scope` |
| `POST` | `/tokens/{name}/rotate` | `tokens` | `{"scopes":[…]}?` (optional) | `{"name","scopes","token"}` — a new secret in place; `created_s` becomes now, `last_used_s` resets, the scopes are unchanged unless supplied |
| `DELETE` | `/tokens/{name}` | `tokens` | | the remaining list. takes effect immediately, no restart |
| `POST` | `/streams`, `PUT` `/streams/{id}/palette`, `DELETE` `/streams/{id}` | `display` | | `503 not_implemented` |

json bodies must be `application/json`. `request_id` and `epoch` are both
optional on every command: the shortest useful request is a one-liner with
neither, which is what makes the api usable from a shell, a home-automation
rule or an apple shortcut without a preparatory round trip.

**omitting `request_id` gives up at-most-once delivery.** the renderer keeps
completed ids for sixty seconds and replays the stored result for a repeat, so
a client that retries under its own id applies the command at most once however
many times it is delivered. omit the id and the device mints a fresh one per
request, so the window has nothing to match on and a retry is a second command
— a repeated `/notify` shows twice, a repeated `reseed` reseeds twice. send
your own `request_id` (1–16 hex digits) whenever a duplicate would matter, and
reuse that same id for the retry. minted ids have the top bit set, a range
reserved for the device, so they cannot collide with one you chose.

`epoch` guards against applying a command to a renderer that has restarted
since you read the state; supply it (from `/status`) and a mismatch is
`409 stale_epoch`, omit it and the command applies to whichever renderer is
current. a field that is present but malformed is still `400`, on both.

so the whole of a message and a power-off, with nothing read first:

```bash
curl -sX POST http://10.0.0.111/api/v1/notify -H "authorization: Bearer $CONTROL" \
     -H 'content-type: application/json' -d '{"text":"bins out","duration_s":10}'
curl -sX POST http://10.0.0.111/api/v1/action -H "authorization: Bearer $CONTROL" \
     -H 'content-type: application/json' -d '{"action":"power","power":false}'
```

scene, brightness and generator changes made this way are transient; to make
them the boot defaults, patch and save the settings.

errors are `{"error":"<code>","message":"…","request_id":"…"}` with a stable
lowercase code. a number the schema cannot hold names the field it was given
for — `{"error":"value_out_of_range","message":"spread is outside the range this
field allows"}` rather than a blanket "not valid json" — which matters most to
the clients that hand-roll their json:

| status | codes |
|-------:|-------|
| 400 | `malformed_request`, `unsupported_request`, `request_timeout`, `invalid_json`, `unknown_field`, `duplicate_field`, `missing_field`, `value_out_of_range`, `value_not_whole`, `body_too_deep`, `invalid_*`, `missing_*`, `rejected` (the renderer refused it) |
| 401 | `unauthorized` |
| 403 | `origin_denied`, `forbidden` (admin token needed) |
| 404 / 405 | `not_found`, `method_not_allowed` |
| 409 | `stale_epoch`, `revision_conflict`, `expired`, `conflict` |
| 413 / 415 | `head_too_large`, `body_too_large`, `request_too_large`, `unsupported_media_type` |
| 429 | `overload` (connections or the renderer's dedup window), `frame_rate` |
| 503 | `not_ready` (netd has no credentials or settings yet), `supervisor_unavailable`, `renderer_unavailable`, `save_failed`, `not_implemented`, `too_many_subscribers` (two event streams are already held) |
| 504 | `timeout` |

### which build is running

`GET /status` reports `build`: `git describe --always --dirty --abbrev=12`,
resolved when the build graph is made and compiled into every binary.

it exists because there was no way to answer the question. `boot_id` changes on
every runtime start, so it says the thing restarted, not what it restarted into;
`uptime_s` is the *device's* uptime and does not move when the runtime does. the
only checks available were inference — a log line that only the new build emits,
a behaviour that only the new build has, or the mtime of a pushed binary — and
all of those work only when the change happens to be observable. a push that
silently left an old binary in place passed every one of them.

**every binary logs its own as soon as it can**, and the supervisor pipes each
child's stdout into the log ring, so one call shows the whole set:

```sh
tc002 logs | grep build
```

the supervisor says it twice on purpose: once at entry, which reaches the log
*file* and is the only place it appears if a run dies before the ring exists, and
once the ring is up, which is what `GET /logs` can actually see. the first
version of this shipped with only the entry line, and the supervisor was the one
binary missing from its own check.

that is the check that matters. the six binaries are built together and share an
id by construction, so a disagreement in that list is not a build problem — it is
a **deploy** problem, one binary left behind from a previous push. the ipc
between them has changed repeatedly, and a mismatched set fails in ways that look
like anything except a version mismatch.

two honest limits. `-dirty` is a flag, not a fingerprint: two builds of the same
uncommitted tree share an id, and when that matters, commit. and the id is
resolved at configure time rather than compile time, so it is deliberately not a
timestamp — a value that changed on every build would invalidate the options
module and rebuild all six binaries every time, to answer a question a clock
cannot answer anyway.

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

### the event stream

`GET /api/v1/events` publishes every statement the device applies, as
server-sent events. it exists because a console mirroring this device can send
statements itself but cannot see the three buttons, the knob, ntfy or mqtt —
which on a clock are the primary interface, not an edge case — so a mirror that
polls `/status` and diffs has to guess at what it missed, and has guessed wrong.

```
$ curl -N -H "authorization: Bearer $TOKEN" http://10.0.0.111/api/v1/events
data: {"revision":7,"age_ms":0,"cmd":"set_base","source":"input","base":"clock"}

data: {"revision":8,"age_ms":0,"cmd":"set_clock_style","source":"input","clock":{"font":"hires",…}}

data: {"revision":9,"age_ms":0,"cmd":"brightness","source":"api","brightness":50}

: ping
```

every frame carries `revision`, `age_ms`, `cmd` and `source`, plus whatever that
`cmd` resolved to. the fields are the api's own vocabulary: `base`, `generator`,
`seed`, `brightness`, `power`, `ip_mode`, `clock`, and `text`/`colour`/
`duration_s` for a notification.

| field | meaning |
|---|---|
| `revision` | the revision this statement produced. a mirror applies the same statement and expects to land on the same number; a **gap means it missed one** and should resync from `/status` |
| `age_ms` | how long ago it was applied. set by the renderer and added to at each hop, exactly as `sample_age_ms` is for `/status`, so a mirror running deliberately behind real time can place it at the right instant |
| `cmd` | `set_base`, `select_generator`, `notify`, `raw`, `brightness`, `reseed`, `arm_stream`, `power`, `set_clock_style`, `set_ip_mode`, `overlay_expired` |
| `source` | `api` (http or mqtt), `ntfy`, `input` (a button or the knob), `local` (the device itself: a menu selection, night brightness, an overlay reaching its deadline) |

**the parameters are resolved, not requested.** the knob asks for "the next
generator" and the statement names the one it landed on; a seedless reseed
publishes the seed actually taken. that is what lets a replica replay a statement
with no special cases of its own.

**what is not published.** a `raw` or `stream` frame says how long the overlay
holds, never which pixels: 2,496 bytes per statement would not fit the ipc, and a
mirror that wants them can read `/screen`. a stream frame does not appear at all,
because it deliberately does not move the revision — which is also what stops
sixty frames a second from flooding the stream. `api` does not distinguish http
from mqtt: netd serves both and marks neither, and the question a console
actually asks — "was this mine?" — is answered by the revision its own request
returned.

**bounds.** at most **two** subscribers; a third gets `503 too_many_subscribers`
and should poll. a subscriber holds one of netd's eight connection slots for as
long as it stays, which is why the cap matters more than the slot count. a quiet
stream is sent a `: ping` comment every four seconds — that is a *write*, so a
subscriber that died without a fin fails it and its slot comes back; exempting
the route from the idle timeout without writing would have held the slot for
ever. a subscriber that falls behind further than its buffer is dropped rather
than buffered without bound, which is safe by construction: the missed statement
shows up as a revision gap, and the gap is the signal to resync.

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
| `frame_timeout_ms` | 100–2000 | how long one pushed [stream frame](#the-frame-stream) stands before the panel clears itself; carried with every frame |
| `berry.enabled`, `berry.heap_kb`, `berry.handler_ms` (patch as `berry_enabled`, `berry_heap_kb`, `berry_handler_ms`) | bool, default false; 16–256 kb; 10–1000 ms | the [script interpreter](#scripting-berry). berryd is spawned only while enabled, and **replaced** on any change: a heap cannot be resized under a live vm |
| `sound.enabled`, `sound.volume` (patch as `sound_enabled`, `sound_volume`) | bool, default false; 1–100, default 60 | the [speaker](#sound). audiod is spawned only while enabled, and **replaced** on any change |
| `battery.shutdown`, `battery.shutdown_mv`, `battery.grace_s` (patch as `battery_shutdown`, `battery_shutdown_mv`, `battery_grace_s`) | bool, default **true**; 3000–4000 mv, default 3550; 0–300 s, default 30 | [low-battery shutdown](#the-low-battery-shutdown). the warning threshold is `shutdown_mv + 50` and is not a setting of its own |
| `metrics_interval_s` | 0 (off) or 10–3600 | mqtt `metrics` cadence |
| `discovery.enabled`, `discovery.controls`, `discovery.prefix` (patch as `discovery`, `discovery_controls`, `discovery_prefix`) | bool; bool default false; ≤ 64 characters | opt-in discovery, with a separate opt-in for writable controls |
| `allowed_origins` | up to four exact origins | read from the file only |
| `expected_revision` (patch only) | | the patch is refused with `409 revision_conflict` unless the current revision matches |

`revision` counts accepted patches (and mqtt setting changes) since the
supervisor started with the loaded file; `saved_revision` is what is on disk.
`PATCH /config` (there is no `PUT /config`), `PUT /mqtt` and `PUT /ntfy` write the file before they answer,
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

## discovery (mdns)

netd advertises one ipv4 dns-sd service, `_tc002._tcp`, on udp/5353. the host and
service instance use the whole wlan mac: `cc:c4:b2:77:9e:85` becomes
`tc002-ccc4b2779e85.local`. the old four-digit suffix was not unique across devices;
short hostnames from the first mdns branch are no longer advertised.

```text
tc002-ccc4b2779e85.local                     A     10.0.0.68
_tc002._tcp.local                            PTR   tc002-ccc4b2779e85._tc002._tcp.local
tc002-ccc4b2779e85._tc002._tcp.local          SRV   0 0 80 tc002-ccc4b2779e85.local
tc002-ccc4b2779e85._tc002._tcp.local          TXT   (empty)
_services._dns-sd._udp.local                 PTR   _tc002._tcp.local
```

`dns-sd -B _tc002._tcp` browses the service, and
`http://tc002-ccc4b2779e85.local/` addresses this example clock. service discovery
is implemented in netd, keeping network packet parsing outside the supervisor.
`src/net/mdns.zig` handles packets; `src/net/mdns_owner.zig` handles ownership and
startup timing. both have host tests.

once status supplies a mac and ipv4 address, netd joins the multicast group on
that interface. it sends three probes 250 ms apart after an initial 0–250 ms
jitter, then two announcements at least one second apart. replies are withheld
until probing and the first successful announcement complete. failed sends do
not advance ownership. a losing simultaneous proposal waits before re-probing;
a conflict with an established responder selects a numeric suffix such as `-2`
and re-probes after a five-second backoff. an already established clock first
re-probes its current name before deciding to rename. suffixes survive address
changes within netd, but are not persisted across netd restarts.

address loss closes the multicast socket and withdraws local ownership. an
address change recreates membership and outbound routing before probing again.
bind/join failures retry once a second, without preventing the http api from
running; the failure is logged once per episode and the recovery once, so a
persistent failure cannot turn the log ring over. multicast loopback is off:
netd is the only 5353 listener on the device, and its ownership logic does not
need to hear its own probes.

queries from ephemeral ports receive legacy unicast responses with their query
id and question section, no cache-flush bits, and record ttls capped at ten
seconds. port-5353 queries receive multicast responses. ownership decisions
require a source port of 5353 and an observed ipv4 ttl of 255; this deliberately
strict local-link check ignores ownership claims from responders that send lower
ttls. ordinary legacy queries still work with lower ttls. all outgoing replies
use an ipv4 ttl of 255.

remaining limitations:

- ipv4 only; no reverse-address or negative-answer records.
- outgoing names are uncompressed; incoming compression pointers are supported.
- qu questions from port 5353 still receive multicast replies.
- no known-answer suppression or randomized multicast response delay.
- discovery is always on; there is no configuration setting.

a name that is given up is withdrawn with a goodbye (rfc 6762 s10.1: the same
records with every ttl at zero), so caches drop it within a second instead of at
expiry, which is 75 minutes for the service pointer. that happens on a rename,
before the new name is probed, and on a clean exit of netd (a signal, or the
supervisor going away). like an announcement it is sent twice, a second apart,
because multicast over wifi drops frames and one lost goodbye was observed on
the bench; the exit takes a second longer for it. a crash or a power cut sends
nothing, and those names expire by ttl. a name that was never announced is not
withdrawn: nothing holds it.

`tc002-devices.py` treats multicast discovery as optional and still tries adb and
an explicitly requested sweep when it is unavailable. names survive merging with
adb metadata. conflicting instance names at different addresses remain separate,
so `--one` refuses to select one silently. `tc002-up.sh --device` accepts bare ips
or hostnames (default adb port 5555) and explicit ports.

`tc002-devices.py` asks on every ipv4 interface the host has, runs the probe
alongside the adb probes and any sweep, and stops 300 ms after the last answer
rather than waiting out its two-second window. a clock any probe saw running the
runtime is reported as `runtime`, whether the binaries are in `/res/bin` or `/tmp`.

validation commands: `zig build test` and `zig build` from `runtime`, plus
`/usr/bin/python3 -m unittest -v test_tc002_devices` from the repository root.
live device and resolver acceptance testing is separate from those offline checks.

## the low-battery shutdown

the clock has a 3,600 mah cell and no way to tell you it is nearly empty. left
alone it runs until the rails collapse, and the write it collapses during is the
one that matters: the settings file lives on jffs2, and a brownout mid-write is
how a device comes back without its configuration — or without its filesystem.

so the supervisor watches the pack and puts the device away first. the numbers
are the **stock firmware's own**, recovered during the reverse engineering and
recorded in [`README.md`](README.md#power): warn below 3,600 mv, and
below 3,550 mv run a thirty-second countdown and then power off, skipped while
usb power is present.

| | |
|---|---|
| where the decision lives | `runtime/src/supervisor/power.zig`, pure and host-tested |
| where it acts | the supervisor, which is the only process that writes flash |
| how it powers off | the mcu's own `powerOff` command (`0x10`) |
| how often it is asked | every second; the pack voltage every 30 s (three times a second while the cell is low), and the **usb rail every second** |
| what the panel shows | a [coloured battery icon](#the-battery-icon) on an unplug and on the way down through 50%, 20% and 5% |

**the warning threshold is derived, not configured.** it is `shutdown_mv + 50`,
the stock app's own gap. two independent thresholds can be set the wrong way
round, and then this code has to decide what someone meant.

### the battery icon

the shutdown is the last thing that happens; long before it, the panel says what
the cell is doing. a battery is drawn across the **whole panel** for four seconds
when there is something to say — a case, a terminal, and a fill bar as long as
the charge — tinted by what is left:

| charge | colour | glyph | |
|---|---|---|---|
| over 50% | green | | |
| 20–50% | amber | | |
| 5–20% | red | | |
| under 5% | red | a sliver | **blinking**, 400 ms on, 400 ms off |

it is raised by three kinds of moment, and only while the device is actually
running on its cell:

- **the cable coming out.** an unplug shows the icon at whatever the charge is,
  which is the one moment you most want to know it. the rail is read once a
  second for this: it was once a side effect of the thirty-second battery poll,
  and a ten-second undock could then pass entirely between two readings and be
  seen by nobody. measured after the split: **under a second**, and the pogo-pin
  dock registers on the same `vin` the usb-c port does.
- **falling through 50%, 20% or 5%.** downwards only — a clock that flashed at
  you while it was charging back up would be noise. falling past two thresholds
  between one mcu reading and the next reports the lower one.
- nothing at boot: a device that starts up already at 30% has not *crossed*
  anything, and an icon on every power-on would be a nag rather than a warning.

**plugging back in replaces a warning rather than clearing it.** the reconnect is
a trigger of its own: the same battery, with the `plug` glyph fading in over the
bar. the question a red battery was asking is answered, which is better than the
answer simply being that the question went away. a countdown still suppresses a
notice entirely — `plug me in` is the more urgent thing to be reading.

### how it arrives

the bar is not drawn at its final length. it **grows from nothing to the reading
over 700 ms**, eased with a smoothstep — flat at both ends, quickest through the
middle — so the charge arrives rather than appearing. there is no libm on this
device, which rules out anything with a sine in it; smoothstep is `t²(3−2t)` and
is nothing but multiplication.

the plug fades in over 350 ms, and **starts the moment the growing bar passes the
midpoint of the battery, or when the bar stops growing, whichever comes first**.
for a cell over half full the first of those happens and the plug is fully in
before the fill has finished; for one under half full the bar never reaches the
midpoint, so the end of the fill is what releases it. the fade mixes with
whatever is under it, so the glyph emerges out of the bar rather than sitting in
a hole punched through it.

blinking waits for the fill to finish. a bar that is growing *and* flashing reads
as a fault rather than as a measurement, and a charging notice never blinks at
all — flashing red at someone who has just plugged the clock in is telling them
off for fixing it.

the pictures in this section can be regenerated without a device:
`zig run src/battery_preview_main.zig 2> frames.hex` prints every frame of every
state, drawn by the same two files the panel uses.

the icon is pushed as stream frames rather than installed as one timed frame,
which sounds like more work and is less: blinking is an animation, and a stream
frame carries its own deadline, so the last frame of a notice is sent with
exactly the time remaining and the overlay expires when the notice does instead
of leaving the panel dark until a fixed timeout runs out. it lands in the same
overlay slot a script's animation uses, so a notice interrupts one — which is the
right way round.

### silence is not a low battery

three rules are this runtime's own rather than the vendor's, and they all say
the same thing:

- **a reading only counts while the mcu is answering.** the poll loop keeps the
  last value when the link goes quiet, so a stale 3.4 v would otherwise power
  off a clock that is sitting happily on a charger. a reading older than 95 s —
  three missed polls — is not acted on.
- **losing the link cancels a countdown** rather than letting it run out. we
  could not see a cable being plugged in either, and the power-off goes *through*
  the mcu: a link we cannot hear is a link we cannot use.
- **one low reading is a dip, not a flat battery.** the pack voltage is a raw adc
  value scaled by a float and read while the panel is drawing, so a single sample
  can sag under load. two consecutive readings start the countdown; the first one
  only warns.

a countdown is cancelled by usb power, by the cell recovering 30 mv clear of the
threshold, by the link going quiet, or by the setting being turned off. the
panel says `battery low` when the warning band is entered and `plug me in` for
the length of the countdown, and every transition is a line in the log ring.

### what happens at the end

in this order, and the order is the point:

1. **the settings are written** if the live revision is ahead of the saved one.
   this is the last moment they can be, and a save begun *after* the power-off
   command would be exactly the interrupted write this feature exists to avoid.
2. the panel is blanked, so the device does not sit showing a frozen clock.
3. `powerOff` goes to the mcu, which is the only thing on this board that can
   actually cut the rails — the soc halting on its own would leave them up.

nothing else needs winding down: the supervisor owns the state directory and the
children only relay, so there is no other flash writer to stop.

### what is not verified

the thresholds are the vendor's and the policy has eleven host tests, but
**nothing here has watched a real discharge cross 3,550 mv**, and the `powerOff`
command has never been sent to this hardware. if the reading turns out to be
scaled differently under load, the threshold is a setting for that reason.
`battery_shutdown: false` turns the whole thing off.

## sound

the device has a speaker, and the runtime can store short sounds on `/data` and play one at a
time: on its own, alongside a notification or a canvas, or from a berry script with
`tc002.play('chime')`.

four ways in, all of them the same command underneath — `POST /sound` over http, `cmd/sound` over
mqtt, `tc002.play()` from a script, or the on-panel menu. uploading a wav is http only
(`PUT /sounds/{name}`, in chunks): mqtt has no place to put 192 kb, and the reason the http side
is chunked at all is that netd caps a request body at 8 kb.

**off by default**, like scripting: `tc002-audiod` is not spawned until `sound.enabled`.

### what plays

**wav only, pcm, 8- or 16-bit, mono or stereo, 8–48 khz.** anything else — adpcm, a-law, 24-bit,
float, wave-extensible — is refused by name rather than played as noise, because "it made a
horrible sound" is a much worse bug report than "this device does not play adpcm".

**there is no mp3, and there is no hardware decoder to lean on.** the stock firmware decodes mp3 in
software: `libzkmedia.so` carries an `Mp3AudioParser` calling `mad_frame_decode`, and
`/lib/libmad.so.0.2.1` ships on the device to provide it. `mi_ao` takes pcm and only pcm — its own
debug dump format is `.pcm`, no codec name appears in `libmi_ao.so`, and the `mi_adec` kernel
module is not loaded. `MI_AO_EnableAdec` exists as an entry point but the vendor does not use it for
mp3, which is the strongest evidence available that it would not help. adding mp3 means vendoring a
software decoder, and that is a dependency decision nobody has taken.

### the store

`config/sounds.bin` on `/data`, written with the same `saveFileAtomic` as the scripts and the
canvas. 192 kb a sound (six seconds of 16-bit 16 khz mono, twenty-four of 8-bit 8 khz), 256 kb for
the whole store. the count is whatever fits.

**a sound arrives in chunks.** netd caps a request body at 8 kb and raising that would cost the cap
times eight connection slots in static buffers, so `PUT /api/v1/sounds/{name}?offset=N` takes at
most 4,096 bytes and `&final=1` commits what has been assembled. `offset` must be exactly what has
already landed: a retried or reordered chunk is refused (`409 conflict`) rather than written,
because an uploader can recover from an error and a device cannot recover from corrupted samples.

### why a process of its own, and why it is root

`/dev/mi_ao` and `/dev/mi_sys` are `crw-------`, so audiod runs as root — the same trade the
renderer makes for `/dev/spidev0.0`. it parses nothing from the network; every command reaches it as
a typed ipc message the supervisor has already validated.

being root is also what keeps the design simple. a sound is far too big for an 8 kb ipc datagram, so
audiod reads the store file itself rather than having it streamed to it; the supervisor writes that
file atomically, so a reader sees either the old set or the new.

pushing pcm means waking on a timer and blocking on a device. doing that inside the renderer's
60 fps loop would put audio jitter and frame jitter in the same thread.

### how it reaches the speaker

`tc002-audiod` configures the audio-out per sound (sample rate and channel count are a property of
the device, not of a frame), feeds it in ~46 ms chunks, and closes it when the sound ends, so a
clock that is not playing holds nothing open. when the device's buffer is full it says so, and that
is back-pressure rather than an error — the feed simply returns and comes back on the next tick.

playback goes through the device's own `libmi_ao.so`. the control-plane ioctls were recovered and
work (`src/sound/mi.zig`, and `zig build soundprobe` exercises them), but `MI_AO_SendFrame` marshals
samples through a buffer the library allocates for itself, so the samples go through the vendor's
code rather than a reimplementation of it. that makes audiod the one dynamically linked binary here.

[`runtime/vendor/mi_ao/README.md`](runtime/vendor/mi_ao/README.md) has the recovered abi and how it
was obtained, including a hazard worth reading before experimenting: a wrong `SendFrame` payload
wedges the audio device until the box is rebooted.

### measured

a 1.5 s 44.1 khz mono wav, uploaded in 33 chunks in one second, stored on `/data`, surviving a
reboot, and played at four volumes. feeding 1.495 s of audio takes about 1.35 s of wall clock — the
device consuming at roughly real time.

## scripting (berry)

the device runs [berry](https://github.com/berry-lang/berry) scripts: react to
buttons, mqtt, ntfy and timers, draw on the panel, and — when a script wants
them — own the pixels at sixty frames a second. off by default; a device that has
never been told to run scripts is not running one, and `tc002-berryd` is not even
spawned.

**[`SCRIPTING.md`](SCRIPTING.md) is the reference**: the language, the `tc002` and
`panel` api, events, the store, the bounds and how to test a script. what follows
is only where berryd sits in this runtime.

the interpreter is vendored at `runtime/vendor/berry/` (upstream `6e6e621`, mit,
with its `coc` output committed). `runtime/vendor/berry/README.md` has the config
table and what was changed. it is the one binary here that links libc: berry's
error model is `setjmp`/`longjmp` and it formats reals with `snprintf`.

### why a process of its own

measured, not assumed. `zig build ipcbench` forks a peer over the same socketpair
the runtime uses and pins both ends: a whole frame reaches another process in
**8.3 us across the two cores**, 0.05% of a 16.7 ms frame budget, and streaming is
*faster* across cores than on one because the processes run at the same time
rather than ping-ponging through the scheduler.

the interpreter costs far more than the boundary. on this device:

| a script that, per frame… | cost | share of a frame |
|---|---:|---:|
| makes 20 native draw calls plus arithmetic | 0.20 ms | 1.2% |
| touches all 832 pixels itself | 10.8 ms | 65% |

so the boundary is free and berryd runs on the second core, where a slow script is
somewhere the renderer's 60 fps loop never looks. isolating it also means a wedged
or runaway interpreter is a process the supervisor can kill, not a fault in the
renderer.

### how it is held

| concern | mechanism |
|---|---|
| lifecycle | spawned by the supervisor only while `berry.enabled`, uid 1001, restarted with backoff; **replaced** on any berry settings change, because a heap cannot be resized under a live vm |
| liveness | berryd reports every second; two seconds of silence and the supervisor kills it. a script looping forever leaves the process alive and silent, so silence is the only signal |
| memory | one fixed arena (`berry.heap_kb`), so a full heap raises inside berry and nothing else on the device notices |
| cpu | berry's observability hook stops a handler past `berry.handler_ms`, twenty times over before the silence threshold could fire |
| reach | no network descriptor, no filesystem, no binding to settings or credentials |

the ipc it speaks is in [the local channel](#the-local-channel-ipc): the
supervisor hands it `berry_config`, each stored script and then `reload`, the
`input` edges and `berry_event` arrivals; it sends back `berry_status`,
`berry_result`, `berry_event` (subscribe and publish) and `stream_frame`.

### the frame stream

`panel.push()` renders the document the script has been drawing into pixels — in
zig, against the renderer's own canvas code — and sends it as a `stream_frame`.

that is a different message kind from `frame`, not a faster one. `frame` is a
discrete command and passes through the renderer's [deduplication
window](#the-local-channel-ipc): 128 ids held for sixty seconds, which caps
discrete commands at about **two a second**. a stream frame is idempotent — the
last one wins and a lost one is a lost frame, not a lost side effect — so there is
nothing for dedup to protect and it is carried ahead of it. it stays epoch-gated,
carries a sequence number so drops and coalesces are counted, and never bumps the
revision, because sixty state changes a second is not a state change.

it lands in the same overlay slot a raw frame uses, so a base selection clears it
and the user always wins.

measured on the device: a bouncing block pushed by a script ran at **60 fps
sustained (720 frames in 12 s) at 5% cpu**, using 22 kb of a 256 kb heap.

## mqtt

netd runs one mqtt 3.1.1 client when `enabled` is true and `host` is an ipv4
literal (there is no resolver). keepalive is 30 s, a missed ping response
within 15 s drops the connection, and reconnects back off from 1 s to 60 s
with jitter. `tls: true` is accepted as a setting and makes the client **stay
disconnected** with `last_error: tls is not available in this build`; it
never falls back to plaintext silently. the client id defaults to the
device's own stable name — `tc002-<mac>`, the same string home assistant
knows the device by, falling back to `tc002-boot<boot_id>` only in the
window on a cold boot before `wlan0` exists. it was `tc002-<boot_id>`
unconditionally, which meant a rebooted clock arrived as a *different*
client: the broker kept the previous session until its keepalive expired,
and that dead session's will (`offline`) was then published after the new
one had said `online`, leaving every home-assistant entity unavailable.
all topics live under `prefix` (default `tc002`):

| topic | direction | payload |
|-------|-----------|---------|
| `availability` | out, retained, qos 1 | `online`; the last will publishes `offline` |
| `state` | out, retained | the status document, republished on change at most twice a second |
| `result` | out | `{"request_id","status","revision","epoch"}` for every command received on `cmd/*`, or `{"status":"rejected","error","message"}` for a body that did not parse |
| `metrics` | out, every `metrics_interval_s` | the [metrics document](#the-metrics-document) |
| `cmd/scene`, `cmd/action`, `cmd/notify` | in, qos 1 | exactly the http json bodies |
| `cmd/frame` | in, qos 1 | binary, 2,510 bytes big-endian: `u64 request_id`, `u32 epoch`, `u16 duration_s`, 2,496 rgb bytes. a binary payload cannot leave a field out, so zero says "you pick": a zero id is minted by the device, a zero epoch means the current one; or 2,514 / 2,515 bytes with `u8 effect`, `u8 direction`, `u16 duration_ms` and optionally `u8 exit` before the rgb (see [transitions](#transitions)) |
| `cmd/config` | in, qos 1 | `brightness`, `base`, `generator` stay transient. with `discovery_controls: true`, the explicitly allowed clock/time/night fields below are durable; other privileged fields are refused |
| `cmd/input` | in, qos 1 | the `/input` json body; answered on `result` |
| `cmd/sound` | in, qos 1 | the `POST /sound` json body — `{"name","volume"?,"loop"?}` or `{"stop":true}`; answered on `result`. the only command topic whose answer is not the renderer's: the id in that `result` is minted by the device, because the body carries no `request_id` to echo. `sound.enabled` is off by default, and playing while it is off answers `unavailable` rather than failing silently |
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
 "time":{"state":"unsynced"},
 "net":{"interface":"wlan0","rx_bytes":530478830,"tx_bytes":48216323,
            "rx_packets":2290185,"tx_packets":297493,"rx_errors":0,"rx_dropped":1344978,
            "tx_errors":0,"tx_dropped":0,"rx_bytes_per_s":5809,"tx_bytes_per_s":1102},
 "memory_cached_kb":12560,"memory_dirty_kb":0,"memory_writeback_kb":0,"memory_slab_kb":8576,
 "config_saves":{"count":1,"failures":0,"bytes":910,"last_ms":2}}
```

(the `rss_kb` values are the kernel's unreliable 4 kb figure; see
[memory audits](#memory-audits).)

#### the device counters, and what they are not

the same block is in `GET /status`, so the console sees it too.

- **`net`** is one interface, `wlan0`, straight out of `/proc/net/dev` under the kernel's own
  field names. the counters are the kernel's `unsigned long`, 32 bits on this cpu, so they wrap
  where it wraps. the two `_per_s` figures are derived in the supervisor from its own sample
  interval and are **`null`, never zero**, until a second sample exists or if a counter goes
  backwards, which is what an interface reset looks like from here. it is `net`, not `network`:
  the status document's `network` object is the ip address and was there first.
- **`rx_dropped` is not packet loss.** this device reports over 1.3 million dropped receives
  against 2.3 million received packets and zero receive errors, so whatever the driver counts
  there, it is not an application-visible fault. it is published under the driver's name, its
  discovery entity is called "wifi frames the driver dropped", and nothing derives a loss
  percentage from it.
- **`config_saves`** counts what the runtime writes to the settings file: attempts, failures,
  serialised bytes and the duration of the last one. **this is not flash wear.** it excludes
  jffs2 metadata, compression and garbage collection, and every other process on the device.
  mtd6 exposes geometry, ecc and bad-block fields but no programmed-byte or erase totals, so no
  lifetime estimate is derivable on this build and none is offered.
- **headroom**: the metrics document measured 1,114 bytes against its 1,536-byte cap once these
  counters were added, and `GET /status` 1,654 against 3,584. an overflow stops publication
  entirely, so netd now logs it rather than counting a silent drop, and the status route answers
  500 rather than sending a truncated body that is not json.
- **what is deliberately absent**, having been measured rather than assumed on linux 4.9.84:
  `bpf` and `perf_event_open` both return `ENOSYS`, there are no kprobes, `/proc/self/io` does
  not exist, and vmstat carries gauges only — no `pgfault`, `pgalloc` or `pgscan` rates. the
  sigmastar miu bandwidth counter at `/sys/devices/system/miu/miu_bw0` does work, but a read
  blocks around ten seconds inside the vendor driver and needs a global sysfs flag flipped and
  restored, so the runtime does not use it.

### home-assistant discovery

opt-in with `discovery: true`. on every mqtt connection netd publishes one
retained config per second under
`<discovery_prefix>/<component>/tc002-<mac>/<key>/config` (the boot id stands
in when there is no wlan0 mac).

the mac is read once at startup, and on a **cold boot `wlan0` does not exist
yet** — netup loads the wifi driver a few seconds later — so that fallback used
to be permanent for the life of the run: discovery went out under a random
per-boot id and home assistant made a new device on every reboot, each one
orphaning the last one's entities. the supervisor now keeps looking until the
mac appears and pushes it to netd, and netd republishes discovery if the
identity changed under it. in practice the mac is there well before the broker
connects, so the republish is a guard on the race rather than the normal path.

the set is 43 read-only diagnostic `sensor` entities that
read from the `metrics` topic (uptime, memory used and available and total and
cached and dirty and slab, cpu
overall and per process, load, wifi signal and quality and byte rates and totals
and error and dropped counts, settings saves and failures and bytes written,
tmpfs used and total, flash used and total
and as a percentage, battery and usb power, renderer restarts, mqtt reconnects,
scene, brightness, fps, frames presented, time sync state), one
`binary_sensor` for display power that reads the retained `state` topic, and
five `event` entities (left, middle and right buttons, the knob, the rotary)
fed by the momentary `input/<control>` topics with `event_types`
press/release/long for the three face buttons and the knob's press and `cw`/`ccw` for the rotary. forty-nine entities at
one per second means a full pass takes about that many seconds. they are grouped into
one device, linked to the `availability` topic, and the metrics sensors expire
after three metrics intervals. a home-assistant birth message
(`<discovery_prefix>/status` = `online`) repeats the pass; turning discovery
off, or changing the prefix, clears exactly those topics with empty retained
publishes. writable discovery has a second opt-in, `discovery_controls`, which is
false by default. enable both over authenticated http, for example:

```sh
tc002 --server http://<device> --token-file tokens config set --discovery --discovery-controls
```

or `PATCH /api/v1/config` with `{"discovery":true,"discovery_controls":true}`.
the console exposes the same checkbox. turning controls off removes their retained
discovery records; reconnects retry unacknowledged removals before moving on. old
prefixes and device identities are cleared before the new set is published. the
original read-only entity ids stay unchanged; the 19 additional controls use
`*_control` keys:

- display power, brightness, base scene, art generator and notification text;
- clock font, colour mode, both colours, gradient, digit style and spread;
- ip layout, timezone, ntp server and interval;
- night dimming, night brightness and night lead.

power/scene/brightness/generator/notification commands are transient. the allowed
durable fields are `clock_font`, `clock_colour_mode`, `clock_colour`, `clock_colour2`,
`clock_gradient`, `clock_spread`, `clock_digit`, `ip_mode`, `timezone`, `ntp_server`,
`ntp_interval_s`, `night`, `night_brightness` and `night_lead_min`; `expected_revision`
may guard a patch. the supervisor validates and saves these exactly as for http.
with controls enabled, broker write access is the authority for those settings.
mqtt cannot enable its own opt-in, change discovery, credentials or unrelated
privileged settings. ordinary mqtt control commands remain available as before.

controls read live display values from retained `state` and durable values from a
retained `config` document, published only while the writable feature is enabled
and cleared on disable. ha payloads omit request ids so each click receives a fresh
one; explicit caller ids retain their existing retry/deduplication semantics.
there are 68 discovery records with controls enabled, paced one per second; disabled
controls also receive empty retained records to remove previously advertised entries.

## host tools (`runtime/tools/`)

| tool | what it does |
|------|--------------|
| `tc002ctl.py` | a client for every route: `status`, `scenes`, `scene` (with `--font`, `--colour-mode`, `--colour`, `--colour2`, `--gradient`, `--spread` for the clock), `brightness`, `reseed`, `arm-stream`, `notify`, `frame`, `power`, `input`, `screen` (`--ascii` draws the panel in the terminal, `--out` saves the raw rgb), `logs` (`--follow`), `config`, `config-set`, `config-save`, `mqtt`, `mqtt-set`, `mqtt-status`. takes the pulled token file (`--token-file`) or a hex token, picks the admin token for admin commands, generates request ids and fetches the epoch for you |
| `tc002-up.sh` | the one-shot cold start for a person: connect adb, build and push (`--no-build` to skip the build), start the supervisor with `--tz`, apply and save the timezone, scene, clock font and sntp server, pull the tokens to the repo root for the console, print the status. after a reboot this is the way back |
| `tc002-demo-*.py` | the demo reels, one per topic, played from this machine over the api: `shapes` (the primitives, clipping, bars), `text` (four fonts, alignment, and all eight animations), `charts` (sparkline styles, autoscale against a fixed range, thresholds, sweep, hex samples, a live feed), `icons` (every built-in glyph, five a page, the set fetched from the device), `images` (sprites generated on the host, uploaded, drawn, animated, deleted), `layout` (absolute placement, tiles and rows, boxes, clipping, draw order), `tiles` (the composite at four widths, so the layout switch is visible), `dashboard` (four realistic dashboards, each pushed once then fed only numbers, printing what the layout and the patches cost in bytes). all take `-s`, a token, `--hold`, `--only`, `--list` and `--loop`, and all put back the scene **and the canvas** they found. `tc002demo.py` is their shared helper, not a demo, and `tc002-demo-lint.py` puts every document all eight would send through the runtime's own rules without a device — the limits and field rules, and where the ink lands: text off the edge of a 52×16 panel, two pieces of text on the same pixels, a tile label too wide for its tile. it is how the shapes reel's 26 elements against a limit of 24 were caught on this machine rather than on the panel, and it now catches the overflows that only showed up once the reels were played on one. a step whose subject is running off an edge names itself in the demo's `LINT_ALLOW`. `tc002-canvas-docs.py` photographs the panel for [`CANVAS.md`](CANVAS.md) -- it drives the device through that page's catalogue and saves a png per still and a gif per motion off `GET /screen`, so the document and the picture of it cannot drift (the gifs need ffmpeg on the host; the stills do not) |
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

the preview is a **replica**, and it follows triggers rather than state. `GET /events` streams
every statement the arbiter applies, whoever issued it — the api, a button, the knob, mqtt — and
the console applies the same statement to its own arbiter and checks it landed on the same
`revision`. nothing is reconstructed from polled state, so there is no piece of device state that
can be forgotten; every earlier accuracy bug in this preview was exactly that. state replication
is still what bootstraps it and what recovers it: a statement that does not land on the device's
revision means one was missed, and the console resyncs from `/status`, `/config` and `/canvas`.

two things the stream does not carry, and so still come from state. `ip_changed` and
`time_corrected` are arbiter commands with no `Statement.Kind` — they mark the panel dirty and
return the *current* revision rather than bumping it (`applyInner` returns
`.{ .applied = self.revision }` for both), because a redraw is not a state change. so they produce
no event **and no gap**: a new ip address simply never reaches the replica over the stream, which
is why the address keeps coming from `/status`. a `raw` frame is different — it does bump, so its
event arrives, but its pixels are deliberately not on the wire (2,496 bytes per frame have no
business there), so the replica refuses it and resyncs rather than inventing them.

the mirror runs **750 ms behind on purpose**. every event says how long ago it was applied, so it
is queued and played when the mirror's clock reaches that instant. running behind is what makes
the ordering right: a statement learned about late is placed where it happened rather than
guessed at. between statements the replica renders locally at 60 fps, so the panel does no
per-frame work for it at all.

the preview is a **shadow**, not a snapshot: it runs the scene code at the
scene's own rate — 60 hz for art, the next whole second for the clock, 33 ms
for a scrolling layout — and reconciles against the device once a second. what
it takes from the device: the scene state from `/status`, the art
[seed](#the-status-document) so the animation is the panel's and not a
lookalike, and the wall clock from the device's own `Date` header, which
`serve.py` forwards as `X-Device-Date` (its own `Date` is this machine's
clock). `/screen` is still polled twice a second, but to *check* the shadow
rather than to replace it: the console compares the live frame against the
frames it recently painted and reports how many bytes agree. it never composes
a fresh one for the comparison — `compose` advances the arbiter, so measuring
that way ticks the clock it is measuring.

**the canvas needs the ages, and gets them.** the device starts every animation clock when it
installs a document — `epoch_ns` for the continuous motions, each element's `started_ns` for the
arrival ones — and the preview installs whenever it fetched, so without help every animated
element is permanently out of phase. `GET /canvas` publishes `age_ms` for the document and for
each element (a patch restarts only what changed, so one age cannot describe them all), and the
console back-dates the clocks through `canvas.Clocks.backdate`, the runtime's own counterpart to
the accounting that produced the ages. against a runtime too old to send them the caption says so
rather than offering a figure it cannot stand behind.

note that a `GET /canvas` body is not a `PUT` body: get adds `revision`, `saved_revision`,
`limits` and the top-level `age_ms`, and the put schema takes `elements` only (an element's own
`age_ms` it accepts and ignores). the console sends the reshaped document.

**measured on hardware with three animations running** (hue 2 s, pulse 1.5 s, blink 0.9 s): the
shadow lights exactly the pixels the panel lights — zero of 832 differing, every sample — with
colours up to 24-30/255 advanced, because `/canvas` and `/screen` are separate requests and the
continuous motions keep moving in between. before the ages it was 81.7% of bytes matching. the
console reports shape and colour separately for that reason: a byte-difference count alone reads
as a rendering fault when the picture is the same picture.

**measured on hardware (2026-09-12):** captured at the same instant, the
shadow and the panel are **byte-for-byte identical** — 0 of 2496 bytes
differing on the `block` clock face with shadowed digits, the 89-value shadow
tone included. the console's continuous figure spreads 94–100% because
`/screen` carries no timestamp and the clock ticks once a second while the
poll runs twice, so about half the pairs straddle a second boundary and one
digit differs. the figure reaching 100% is the verdict; below it is the
sampling gap, not the renderer.

it replaced `panel-v2/sim.js`, a 600-line hand-written port of the same logic, which was
deleted once the wasm had been verified byte-exact against the panel. while the two ran side by
side the javascript was pinned against the wasm, and it had drifted in five places nobody had
noticed: it knew 2 of 3 generators and 4 of 6 clock fonts, drew all four ip layouts as `lines`,
clamped clock gradients by a fixed ±96 where the runtime uses the style's own `spread`, and had
no concept of the digit styles. that is the argument for compiling the source rather than
porting it.

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
| ipc latency (2026-09-13) | frame-sized round trip 53 us on one core, 60 us across two; one-way streaming 120,192 frames/s across cores; `tc002-ipcbench` |
| renderer, clock | exactly two paced transfers per wall-second update, none in between |
| supervisor start | `sys.zkapp.state=running` accepted 10 ms after entry; renderer `ready` 7 ms after spawn |
| frozen renderer (`SIGSTOP`) | stop requested 2.0 s after the last heartbeat, `SIGKILL` 2.0 s later, new epoch spawned 1.0 s after that |
| supervisor killed (`SIGKILL`) | the renderer died with it; a fresh supervisor found the lock free |
| graceful stop | black presented, renderer exit 0, supervisor exit 0 |
| boot experiment | `/tmp/EasyUI.cfg` precedence confirmed; bootstrap execs the supervisor in place keeping the `zkswe` pid; `ctl.start` → property 1.67 s versus 1.57–2.66 s stock; init restarts the service about 1 s after the supervisor dies and retries every ~4 s after a failed exec, property untouched |
| http | every route and every documented error code exercised; 20 parallel status requests → 14×200 and 6×429; a half-sent request times out at 5 s; a 10 s flood of garbage, wrong methods and 5 kb headers left the renderer at 59.7–59.9 fps with cpu at 5 % |
| mqtt | will, subscriptions, retained `state`, `metrics`, every `cmd/*` topic of the day answered on `result` (five then, eight now); broker stopped → backoff with reconnects counted; broker back → reconnected within 4 s |
| discovery | 13 retained configs published one per second, cleared exactly on disable |
| netd restart | `SIGTERM` to netd → respawned 1 s later with fresh credentials; the renderer never noticed |
| memory | the table above; the whole runtime leaves 2 mb more available than the stock app |
| screen, input, logs (2026-09-07) | `/screen` json and raw (2,496 bytes) match the panel; injected clicks, rotary steps and a knob long press produce the same scene changes and the same outward events as the mapper would (30 events over mqtt in one run, none retained); `/logs` pages both children's lines through the pipe while `supervisor.log` stays complete |
| power and fades (2026-09-07) | power off ramps the mean level 29 → 0 in ~600 ms, then a 5 s window shows `transfers=1 redraws=0`; power on ramps 0 → 127 in ~600 ms; a plasma → clock cross-fade runs 127 → 29 in ~500 ms; cpu 2 % overall with mqtt, discovery and fades active |
| discovery (2026-09-07) | 30 retained configs (24 sensors, 1 binary sensor, 5 event entities), one per second; `cmd/screen` answered with 2,502 bytes on `screen` |
| `cmd/sound` (2026-09-14) | against a real broker: `{"stop":true}`, a name that is not stored, a body with neither, and `{"name":"cityrail","volume":25}` all made the round trip and answered on `result` — three `applied` and one `rejected` / `missing_field` for the bad body. the clock played the 1,495 ms 44.1 khz sound audibly at volume 25 and logged `finished`. a name that is not stored still answers `applied`: the supervisor replies as soon as it has handed the command to audiod, which only then logs `no sound called ...`. http has always behaved the same way, so this is the speaker's contract rather than something mqtt introduced |

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
- **streaming, for network clients.** the `/streams` routes still answer
  `503 not_implemented`. the *internal* path exists and is used: a script pushes
  frames through `stream_frame`, outside the deduplication window and with
  `frame_timeout_ms` as the deadman, measured at 60 fps sustained (see
  [scripting](#scripting-berry)). what is missing is an http or mqtt surface for a
  client that is not a script.
- **network bring-up.** ~~the runtime relies on the wifi and address the stock
  stack established before it took over. dhcp renewal after the takeover~~ — **✗
  no longer true.** the runtime brings wifi up itself (`runtime/boot/tc002-netup.sh`
  loads the aic8800 driver, starts the supplicant and runs `udhcpc` as a
  renewing daemon tracked by pidfile) and re-runs it on carrier or address loss.
  measured from a cold boot with the driver removed: everything back in 6 s.
  **the setup-ap flow is still not handled** — a factory-fresh device still
  needs the stock app or `tc002-adopt.py` to join wifi in the first place.
- **the mcu.** the supervisor queries the version, battery and usb state
  (see [the pixel mcu link](runtime/README.md#the-pixel-mcu-link)), reports
  them, and uses the power-off command when the cell runs out — see
  [the low-battery shutdown](#the-low-battery-shutdown). nothing reads the
  microphone or sets the led current gain. **what is untested is the part only a
  flat battery can test:** the thresholds are the vendor's own but nothing here
  has watched a real discharge cross them, and the power-off command has never
  been sent to this hardware.
- **persistence.** settings and credentials are durable (`/data/tc002/state`),
  ~~but the **binaries are not**: they are pushed to `/tmp` and a power cycle
  brings the stock app back, so the runtime is still started by hand.~~ **✗ no
  longer true:** the binaries are on the `res` partition and the runtime starts
  itself from a cold boot. the `/tmp` path still works and is what
  `tc002-run.sh` uses for development. a
  self-starting runtime meant rewriting the `res` partition, since nothing in
  the boot chain reads a writable location; the design, the evidence and the
  risks are in the vault note `tc002-customisation/2026-09-09/boot-persistence`
  and, from 2026-09-12, in [`FIRMWARE.md`](FIRMWARE.md): the vendor image
  format is decoded and reproduced by
  [`tc002-update-img.py`](tc002-update-img.py), the flasher writes mtd3 from
  linux with no signature check, and the loader's ordering is now known: it
  `dlopen`s the app **before** the upgrade check, so this bootstrap's
  exec-in-constructor disables every vendor recovery route, and the dhcp
  client is a thread of the loader, so a cold boot through the bootstrap
  would come up without an address. both need fixing in the bootstrap and
  the supervisor before anything is flashed; the paired-slot install and the
  recovery rehearsal do not exist yet.
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
- **a switch for discovery.** mdns is always on; turning it off means threading
  a setting through the api body, the ipc `ConfigPatch` and its `has` bits,
  `config.Config` and `GET /config`, which is the settings invariant and was
  left for a second pass. see [discovery](#discovery-mdns) for what the
  responder also leaves out.

## design notes

the design and its review live in the agent-notes vault
(`tc002-customisation/2026-09-03/custom-native-runtime`,
`2026-09-06/custom-native-runtime-design-review`, and the implementation
record `2026-09-06/native-runtime-plan-b`). the tradeoffs made against that
design, all deliberate and reported rather than hidden: an own http parser
and mqtt codec instead of a library (bounded memory, narrower protocol), the
netd relay through the supervisor instead of a direct channel to the renderer
(no descriptor passing across renderer restarts), `std.json` for bodies
rather than a hand parser (correctness over code size), an own mdns responder
rather than a library (there is none on the device; see
[discovery](#discovery-mdns) for what it leaves out), and ReleaseSafe by
default (bounds checks on in a network-facing parser, at about 0.7 mb of
tmpfs).
