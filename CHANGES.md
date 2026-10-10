# changes

what each release of the custom runtime brought, newest first. the headline is the tag message;
the rest is what it took. every release gets a section here before it is cut: `tc002-mkrelease.sh`
refuses a version this file does not know. the github releases carry the same notes at length.

## unreleased

- **the update bar is the panel's width, white, and fades in.** the bar under `Updating...` and
  `Flashing...` is four rows of white inside a one-pixel dark grey border the width of the panel,
  over the panel's own black, and a moving bar's leading pixel lights by how far the fill has
  reached into it, so each new pixel fades in.

- **every face fades.** `clock_fade` used to touch only `block`; every other face cut hard at the
  second. the hand-drawn faces now blend their changing glyphs the way `block` does, and the
  imported faces crossfade each changing character in its slot.

- **the clock face is `block` unless you say otherwise.** a fresh clock, a settings file with no
  face in it and a face a build does not know all come up as `block` now, where they came up as
  `classic`. the face enum keeps its order: that order is the number in the settings file.

- **twenty imported pixel faces.** trip5's matrix fonts (ten faces, 6 and 8 rows), tiny5 with
  its duo and mono cuts, and seven int10h faces (phoenix bios and its doubled and 8×14 forms, ibm
  dos iso8, apricot xen-c, robotron a7100, and the extended ibm vga) can be named wherever a font
  is: canvas text and rich notifications, a plain notification's new `font`, the clock (with
  `hh:mm` where the whole time does not fit), berry's `panel.text`, and — the faces of seven rows
  or fewer — the device menus, through a new `menu_font` setting and a `menu font` item in the
  device menu itself. they are one 212 kb blob
  generated from the vendored sources; `tc002d` and `tc002-berryd` each grow by it.
  [`CANVAS.md`](CANVAS.md#imported-faces) shows every one, and the licences are in the readme.
- **text is utf-8.** notifications, canvas text and scripts take any utf-8 without control
  characters instead of printable ascii; the byte limits are unchanged. a character a face lacks
  is one `?` (or the face's replacement glyph), not one per byte. control characters in canvas
  text, which used to be drawn as `?`, are now refused. the hand-drawn `small` and `mini` gained
  a degree sign, so tiles and the demos read `21.4°C`.
- **paired binaries required** for both: the canvas and clock font bytes, the notification
  options, the settings patch, the settings block and the device status each grew.
- **flash this before saving an imported face.** a clock running this build in place falls back
  to its flashed build on a power cycle, and every earlier build (v0.3.6 and before) refuses a
  settings file whose `clock_font` it does not know: it starts on its defaults (utc, the classic
  face, full brightness, no mqtt) and its next save overwrites the file with them. an earlier
  build also drops a saved canvas that uses an imported face. so keep imported faces out of the
  saved settings and the persisted canvas until the flashed image carries this build. this build
  itself loads an unknown `clock_font` as `classic` and an unknown or too-tall `menu_font` as
  `mini`, so the next face added will not repeat the trap.
- **the update notice shows how far the copy has got.** under `Updating...` and `Flashing...` sits
  a bar the clock fills itself: a bar may now `watch` the staging directory of an in-place update
  or the image a flash stages, with the `bytes` it will reach, and tc002d measures it every 100 ms
  and eases to each reading, so the bar moves smoothly with what has actually arrived. the flash
  notice now goes up before the image is copied rather than after. it shows on a clock already
  running this build; an older one is sent the word on its own. the bar stops where it is when the
  old runtime stops — about 3 s for an in-place swap, the whole 10–15 s write for a flash.
- **a progress bar can move smoothly.** a bar with `"animate":{"kind":"glide"}` eases to each
  new value from wherever it was drawn, and a document notification posted again under the name of
  the one showing updates it in place — no transition, its pulse keeping its phase. together they
  are a progress bar that a client nudges a few times a second and the panel draws as one motion.
- **ntfy messages keep their accents.** the subscriber used to fold every message to printable
  ascii, so `café` arrived as `caf?`; it now passes utf-8 through whole (a character no face has
  still draws as `?`), keeps line breaks, and cuts at the 128-byte limit between characters.
- **the clock's digits keep still.** an imported face sets each digit centred in a slot as wide as
  its widest digit, so the four proportional `light` faces no longer shift the colons a pixel as
  a `1` comes and goes. the hand-drawn faces never did: their digits are all one width.
- **text can break lines.** a `\n` is the one control character text may carry now. canvas text
  stacks its lines in the box, each aligned on its own; a plain notification stacks them when they
  fit the 16 rows and otherwise shows them in turn, two seconds each or as long as a line takes to
  scroll by; a tile's label and value read it as a space. the console's notification text is a
  two-row box.
- **a flash says so.** the panel reads "flashing..." while `tc002-update.sh --flash` writes an
  image, and "updating" only for an in-place update, which leaves flash alone.
- **popsquares cells go off instead of hanging at the driver's floor.** the led driver lights any
  non-zero frame byte at a fifth of full or more, and the generator scaled white by the cell's
  level, so a dying cell sat at that fifth and then snapped off, and `dim floor` at 0 never showed
  a cell dimmer than that. each led is now driven at a straight share of its lit level at the
  panel's brightness, as the clock's fade is, and is off once the share falls under the floor.
  `Art.render` takes the brightness for it; the console's preview runs the same renderer.
- **popsquares cells can stay dark.** a ninth parameter, `off ms` (0–10000, 500 by default), is
  the longest a spent cell stays off before it pops again, each pop rolling its own wait up to it;
  0 pops it at once, as before. it is what the processing sketch's lingering black cells look like
  with a dial on them. popsquares already used all eight generator slots, so every generator now
  has nine: the ipc settings block grows by sixteen bytes (deploy the binaries together) and the
  settings file's slot arrays grow by one. a file saved with eight loads, the ninth slot taking its
  default, and a file with more slots than the build knows loses those slots rather than being
  refused.

## v0.3.6 — a twelve-hour clock, built with zig 0.17 (2026-10-08)

- **the runtime is built with zig 0.17.0**, pinned exactly, up from 0.16.0. 0.17 removed the `**`
  operator and split enum and struct reflection into two arrays, so the scene and api tables moved
  with it; the output did not change (`panel-v2/scenes.json` is byte-identical, the console's wasm
  tests pass against a 0.17 renderer). zig 0.17.0's own `std.debug.simple_panic` does not compile,
  so `src/sys/panic.zig` carries a corrected copy. a wrong compiler now stops the build with one
  line naming both versions instead of a wall of api errors.
- **the console outlives the toolchain moving under it**: `start-panel.sh` keeps serving the wasm
  already built when a rebuild fails, `$ZIG` names a compiler when the one on `PATH` is not the
  pinned one, and `PYTHON=/usr/bin/python3` runs it while the macos local network grant is missing.
- **`tc002-ntp-patch.py` knows both stock app builds**: beside app 1.1.1 it now patches the
  app 1.0.8 `libzkgui.so` (the "unit B" `res` of FINGERPRINTS.md) — period literal, first-delay
  instruction and server slots, all three offsets confirmed by disassembly. unknown builds are
  still refused, and the refusal now lists the builds it does know.
- **the clock can count 12 hours.** a new clock parameter, `hours`, is `24h` (as before, the
  default) or `12h`: 13:05 is drawn `1:05`, no leading zero and no am/pm, on every face. on the
  device menu, over `PUT /scene` as `clock.hours`, as the `clock_hours` setting, in the console,
  the go client (`--hours`, `--clock-hours`) and as a home assistant select. the clock style's
  `has` field outgrew its byte, so the style is two bytes longer on the ipc: deploy the binaries
  together. applied `set_clock_style` events now carry `fade` and `hours`, which they omitted.
- **the night schedule's brightness is eased**, over two seconds, instead of stepped: after a
  reboot the panel used to jump from the flashed daylight level straight to the night one. the
  target is reported at once; the event carries `ramp_ms`; the knob and the api still land at once.
- **a notification name may be 255 characters**, up from 32, in the api, the go client, the mock
  and the console's preview. the name is a fixed field of the notification and applied-statement
  ipc messages, which grow with it: deploy the binaries together.

## v0.3.5 — every transition on record (2026-09-25)

- **every transition has a recording**, in RUNTIME.md's effects table: the renderer's own code
  compiled to webassembly, driven at 60 fps, saved as animated png (full colour, exact frame
  delays). each goes from the block clock face to a white canvas naming the effect in black, and
  back with the paired effect. `panel-v2/record-transitions.mjs` regenerates them; the canvas
  page's animations are apng now too, re-recorded off a clock.
- **the console preview runs transitions** as the panel does, instead of cutting; a status snapshot
  still lands at once.
- RUNTIME.md has an **art** section describing all four generators and their controls, where the
  cube alone had one.
- **`shrink`**, a new transition: zoom backwards, the old content shrinking into the centre over
  the new. zoom and shrink are a pair, so a notification that zoomed in shrinks out.
- `CHANGES.md` itself, and the release script refusing a version this file does not know.

## v0.3.4 — more transitions, and a fade that survives the night (2026-09-24)

- **the block face fade is brightness-aware.** the cross-fade blends in the led driver's terms and
  cuts to off under the driver's floor of 50, so a dimmed night clock no longer hovers and flickers
  through the middle of a fade.
- **ten more transitions from awtrix-ng**: `dim`, `blink`, `flash`, `zoom`, `ripple`, `diamond`, `blocks`,
  `wave`, `interlace` and `random` (one of the others, picked afresh each time), redone for this
  renderer in integer maths. **and easing for every effect**: `ease_in`, `ease_out` and
  `ease_in_out` beside the linear default.
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
