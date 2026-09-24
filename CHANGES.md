# changes

what each release of the custom runtime brought, newest first. the headline is the tag message;
the rest is what it took. every release gets a section here before it is cut: `tc002-mkrelease.sh`
refuses a version this file does not know. the github releases carry the same notes at length.

## unreleased

- **the block face fade is brightness-aware.** the cross-fade blends in the led driver's terms and
  cuts to off under the driver's floor of 50, so a dimmed night clock no longer hovers and flickers
  through the middle of a fade.
- **ten more transitions from awtrix-ng, and easing for all of them.**
- the api contract test's canvas example reports `persist`, as the device does.

## v0.3.3 — rich notifications and a transient canvas (2026-09-24)

- **a notification may be a canvas document.** `POST /notify` with `elements` draws every
  element, font, icon, sprite, bar, sparkline, tile and animation of the canvas under the
  notification lifecycle: duration or `hold`, `name`, `stack`, the queue, transitions, dismissal.
  `text` becomes the optional summary the event stream and mqtt carry; arrival animations start
  when the notification is shown, not when it was queued.
- **`PUT /canvas` takes `persist: false`.** the document is shown and never written; the supervisor
  keeps the last durable document beside it, so a sprite change or a restart never promotes a
  transient one. `GET /canvas` reports `persist`.
- **the update notice is a held notification named `updating`.** it used to be the canvas document,
  and outlived every update it announced: the canvas button showed "Updating..." for ever. it now
  leaves with the runtime that showed it, and the updaters touch neither the canvas nor the scene.
- the go client gains `notify [text] --data` and `canvas put --persist=false`; the console's canvas
  builder gains "send as notification"; the mock accepts every notification field; the event
  stream's `notify` statement gains `rich`.
- ipc: kind 86 `notify_rich`; the applied statement and the canvas view each gained one trailing
  byte. deploy the binaries together.

## v0.3.2 — the block face fades, and the clock reboots on request (2026-09-23)

- **the block face fades.** with the clock's `fade` parameter on, each digit about to change
  cross-fades into the next over the last 400 ms of the second and lands exactly as the second
  turns. on the device menu, over `PUT /scene`, and as the `clock_fade` setting; off by default.
- **`POST /reboot`** reaches the menu's own reboot path from outside, behind a scope of its own,
  `reboot`, which the admin token holds and the control token does not. the updater uses it to
  clear an adbd that has run out of ptys instead of printing the old build as if it had finished.
- **notifications queue.** `stack` queues behind the active one (eight slots), `hold` keeps one up
  until dismissed, and `POST /notify/dismiss` removes one by name or the current one.
- **rolling rainbow terrain**, a fourth art generator, with speed, height and colour-drift controls.
- the clock winks its separators once on every time sync.
- **one "Updating..." for both kinds of update.** `tc002-update.sh --in-place | --flash` replaces
  `tc002-up.sh`; the in-place push is staged beside the running runtime; the flash's res dump makes
  the mtd node it reads.
- discovery asks mDNSResponder instead of competing with it on udp/5353; `tc002-devices.py` lists
  the stock firmware's broadcasts too, so `tc002-adopt.py` retires.
- the api contract covers the new routes, options and scope, and is checked against the source.
- nothing is pinned to apple's python any more, except the two scripts that touch the lan before
  anyone has granted access.
- the go client `api-client-v2/` is the documented way to drive the api; `tc002ctl.py` is deprecated.

## v0.3.1 — a rebooted clock keeps its settings (2026-09-20)

- **the settings file parser skips unknown fields.** a flashed image older than a setting rejected
  the whole file on every power cycle and came up on the classic face, in utc, with no ntp server.
  flashing is the only way the fix takes; after that a newer build's file loads on an older one.
- popsquares in bigger squares: `cell` 1x1, 2x2 or 4x4. declaring an eighth parameter found the
  art scene menu overflowing its value array, which is fixed.
- two clocks, one console: `tokens-<host>` beside `tokens`, and the proxy picks the file for the
  clock a request names.
- a turn of sixteen detents is sixteen detents through the input route, the mapper and the arbiter.
- the readme lists every tool in the repository.

## v0.3.0 — the clock answers to a name (2026-09-20)

- **discovery (mdns).** `tc002-<mac>.local` and `_tc002._tcp`, from a responder of the runtime's
  own: probing and conflict recovery with a `-2` suffix, unicast answers to one-shot resolvers,
  goodbyes on rename or exit, the socket following the address. `mdns` is a setting, on by default.
- **two clocks.** `tc002-devices.py` enumerates them by name and refuses to guess; every adb call
  names its device; the /24 sweep is behind `--sweep`; lock records name the clock.
- **from the box to the runtime.** `tc002-onboard.sh` is the whole path in one command, and this
  release ships a tarball for machines with no compiler. a freshly flashed clock gets a timezone and
  an ntp server, saved. the way back (a packed `UPDATE.img` from the raw `mtd3` dump) works as written.
- the flasher brings its own `dd`, removes the image it staged on `/data`, and the image carries a
  symlink per busybox applet.
- boot, network, usb: a router rebooting is not a failed boot; the usb host-mode excursion at boot
  is the kernel's, and the replug after every reboot cannot be engineered away without flashing `mtd1`.
- opt-in writable home assistant controls behind `discovery_controls`; an offline api explorer with
  the openapi and json-schema contracts; four documentation audits; length constants as named terms.

## v0.2.0 — the runtime boots from flash (2026-09-15)

- **the persistent install.** binaries in `/res/bin`, the bootstrap in `/res/lib`, the stock
  `libzkgui.so` kept for the fallback: a cold boot reaches a drawing panel in 7.5 s and a synced
  clock at 17 s. the runtime loads the wifi driver, exports the latch gpio and brings the network up
  itself, none of which the stock boot does.
- **the recovery net.** a boot-fail counter handing the panel back to the stock app after three bad
  boots, a no-network hand-back, and yielding to a pending vendor upgrade so the reset button still
  reflashes.
- `tc002-flash.sh` backs up `mtd3`, refuses to continue unless the backup unpacks, prefers usb, and
  puts a pulsing "Updating..." on the panel. the freeze is ten to fifteen seconds.
- adb over the usb cable works, against the vendor's documentation; the supervisor sets the otg role,
  and the cable needs a replug after every reboot.
- `FINGERPRINTS.md`, so you can tell whether your unit is the one these notes describe.
- named client tokens with per-client scopes and rotation; a canvas builder and a script editor in
  the console; berry scripts stored and run by name; sound over mqtt; a stable device identity for
  home assistant; the battery drawn at panel size; `KERNEL.md`; a busybox built from source.
- measurements that overturned assumptions: the renderer's jitter is a 5 ms spi write, and
  `SCHED_FIFO` does not help; the panel freeze during a flash is twenty seconds, not three minutes.

## v0.1.0 — the custom runtime, scripting, the event stream and sound (2026-09-13)

- **`runtime/`, a zig replacement for the stock application.** six arm binaries and a bootstrap
  `.so` that take over the panel, the buttons and the knob; scenes (six clock faces, popsquares,
  plasma, cube, a canvas of text, shapes, icons and sprites, notifications, raw frames, fifteen
  transitions); an on-panel settings menu; a bearer-authenticated `/api/v1` with every route
  documented; mqtt 3.1.1 with home assistant discovery; an ntfy subscriber over tls.
- **scripting.** berry scripts on the device, reacting to buttons, mqtt, ntfy and timers, drawing on
  the panel or owning the pixels at 60 fps.
- **an event stream.** `GET /api/v1/events` publishes every statement the device applies, so a
  console mirrors the device by replaying statements rather than polling.
- **sound.** short wavs stored on flash and played through the speaker.
- **`panel-v2/`**, a web console whose preview is the runtime's own scene code compiled to
  webassembly, following the event stream.
- the reverse-engineered control of the stock firmware that the repo started as: docs and tools for
  the undocumented http api, mqtt and adb, device adoption, a web control panel.
- not there yet at this release: no tls, no persistent install (a power cycle returned the stock app).
