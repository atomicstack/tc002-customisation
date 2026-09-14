# berry scripts for the tc002

seventeen scripts for the [custom runtime](../../../RUNTIME.md)'s berry vm, written against the api
in [`SCRIPTING.md`](../../../SCRIPTING.md). they are meant to be read and edited: every one starts
with a block of settings, and the interesting numbers are at the top rather than buried.

**scripting is off by default and none of this turns it on.** these are files in a repository until
you store one on a device.

## putting one on the device

```bash
ADMIN=$(cut -d' ' -f2 tokens)        # the admin token; see RUNTIME.md
DEV=10.0.0.111

# store it under its own name and run it by hand
curl -X PUT --data-binary @stopwatch.be -H "authorization: Bearer $ADMIN" \
     -H 'content-type: text/plain' http://$DEV/api/v1/berry/scripts/stopwatch
curl -X POST -H "authorization: Bearer $ADMIN" http://$DEV/api/v1/berry/scripts/stopwatch/run

# or store it as autoexec, which is the one name that runs by itself after a power cycle
curl -X PUT --data-binary @night-mode.be -H "authorization: Bearer $ADMIN" \
     -H 'content-type: text/plain' http://$DEV/api/v1/berry/scripts/autoexec
```

`panel-v2/start-panel.sh` has an editor for the same thing with compile errors, the device log and
local drafts. either way the script is compiled before it is stored, so a typo is refused with
berry's own message and never reaches flash.

there is no import and no require: berryd has no filesystem and one script cannot call another. to
run several of these at once, concatenate them — every script prefixes its globals with its own
initials so that nothing collides.

```bash
cat night-mode.be mqtt-gauge.be watch-my-clock.be > autoexec.be
```

## the scripts

| script | what it does | what it needs |
|---|---|---|
| [`autoexec.be`](autoexec.be) | the starter: says hello, reports in on mqtt, takes nothing over | — |
| [`alarm.be`](alarm.be) | wakes you at a local time, lighting the panel gradually over the first minute; left stops, right snoozes | the clock synced; a sound for the sound |
| [`ambient.be`](ambient.be) | a slow colour wash across thirteen bands; the right button starts and stops it | — |
| [`auto-brightness.be`](auto-brightness.be) | follows a lux topic, smoothed and with hysteresis, so the panel stops being blinding at night | mqtt, a light sensor |
| [`button-macros.be`](button-macros.be) | gives the three buttons a long press the firmware does not have, and publishes each gesture | mqtt |
| [`countdown.be`](countdown.be) | days, hours and minutes until a date you care about | the clock synced |
| [`knob-dimmer.be`](knob-dimmer.be) | the dial sets the brightness, with the reading drawn while you turn | — |
| [`mqtt-alert.be`](mqtt-alert.be) | flashes the whole panel until you clear it or press a button | mqtt |
| [`mqtt-gauge.be`](mqtt-gauge.be) | one number as a reading, a bar and a colour that crosses thresholds | mqtt |
| [`mqtt-sparkline.be`](mqtt-sparkline.be) | the last twelve minutes of a number, as columns | mqtt |
| [`mqtt-tile.be`](mqtt-tile.be) | an icon and a reading from one json payload — weather, a charger, a machine | mqtt |
| [`night-mode.be`](night-mode.be) | dims between two local hours and puts the clock back up | the clock synced |
| [`pomodoro.be`](pomodoro.be) | the dial chooses the length, the right button starts it, a bar counts it down | a sound for the chime |
| [`signal-light.be`](signal-light.be) | a build, a deploy or an agent as a colour you can read from the doorway | mqtt |
| [`stopwatch.be`](stopwatch.be) | one button: start, freeze, put away | — |
| [`ticker.be`](ticker.be) | scrolls ntfy messages and an mqtt topic across the panel | ntfy or mqtt |
| [`watch-my-clock.be`](watch-my-clock.be) | the device subscribes to its own state and says when it does not like it | mqtt |

## what shaped them

these are the things that are not obvious from the api table, and that every script here is written
around. most of them were measured in the runtime source rather than read from a document.

- **a script gets one font.** `panel.text` always draws the five-by-seven face, so **eight
  characters** is a full line and there is no `big` or `block` from berry. anything longer is
  clipped at the panel edge, never wrapped.
- **a canvas document holds twenty-four elements** and 256 bytes of text. that is why the
  sparkline here draws twelve columns and not fifty-two.
- **the buttons keep their own job.** left, middle and right select the clock, art and canvas
  bases, and a script cannot swallow that. the scripts here use the **right** button, because
  selecting the canvas is exactly what a script drawing on the canvas wants anyway.
- **there is no click and no long press on the three buttons.** the hardware reports `press` and
  `release`; `long` belongs to the knob, and `click` only ever arrives from an injected
  `/api/v1/input`. `button-macros.be` times its own long press for that reason.
- **the rotary is free on the canvas and nowhere else.** it pages clock faces on the clock base
  and art generators on the art base, but the arbiter returns early for the canvas — so a script
  showing a canvas owns the dial.
- **`show()` for state, `push()` for animation.** a canvas document is a state change: it bumps
  the revision and every mirror watching `/api/v1/events` sees it. a stream frame does not, and
  carries a deadman so the panel clears itself if the script dies. anything redrawing more than
  about once a second here pushes; anything slower shows. the mqtt scripts also throttle their
  redraw, because a chatty topic would otherwise mean a hundred revisions a second.
- **a payload is not to be trusted.** berry's `number()` answers `0` for anything it cannot read,
  so an unparseable payload would draw a confident, wrong zero. every script here checks the text
  before believing it, and every handler tolerates any payload — a topic a script subscribed to is
  a topic anything on the broker can publish to.
- **the device clock is utc.** the runtime applies your timezone in zig, and berryd is execve'd
  with an empty environment, so berry's `localtime` has no `TZ` to read. the time-of-day scripts
  convert with an explicit offset, which does not follow daylight saving. they also refuse to act
  on an unsynced clock, which reads as january 1970.
- **subscribe refusals are logged, not raised.** the call only complains about the topic's length.
  the eight-topic cap and the refusal to shadow the device's own `cmd/` topics both happen in the
  supervisor, so a ninth subscription silently does nothing — `GET /api/v1/logs` says why.
- **sound is off by default.** every `tc002.play` here is wrapped, so a clock with no speaker
  enabled still gets the rest of the script.

## testing them

```bash
cd runtime && zig build check-scripts
```

that runs every script in this directory through the same interpreter the device runs, on the host,
and then fires the events the device really produces at whatever the script registered: presses and
releases on all four buttons, a long press on the knob, the dial in both directions, an mqtt
arrival on each filter the script subscribed to with nineteen different payloads — most of them
deliberately wrong — every one of those as an ntfy message, and two minutes of timer ticks followed
by an hour in one jump.

a handler that raises is caught by the prelude and logged rather than thrown, so the check looks for
what it printed: silence is the pass. this is not a formality. it caught `'%.*f'`, which berry's
`format` does not support, in a code path that only runs once a reading has arrived.

what it does not prove: nothing here has been run on a device, and no pixel has been looked at. the
geometry is the panel's and was checked by hand, not rendered.
