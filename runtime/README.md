# runtime — tc002 custom native runtime (plan b)

zig-built replacement for the stock application on the ulanzi tc002, following the design note
`tc002-customisation/2026-09-03/custom-native-runtime` and implementation plan
`tc002-customisation/2026-09-06/native-runtime-plan-b` in the agent-notes vault.

what is here so far is the skeleton of phases 1–2: a no-libc bootstrap shared object that the vendor
loader dlopens and whose constructor execs the supervisor; a supervisor that raises the anti-brick
property first and then supervises the renderer; and `tc002d`, the renderer, with a hardware-free
presentation model, pure scenes, evdev input, and a bounded ipc channel. nothing here writes flash
or `/data`; every device run is volatile under `/tmp/tc002/`.

## build and test

only zig 0.16.0 is required (`brew install zig`); the build refuses other versions.

```bash
cd runtime
zig build            # zig-out/bin/tc002d, zig-out/bin/tc002-supervisor, zig-out/lib/libtc002-bootstrap.so (arm, static, no libc)
zig build test       # host unit tests of every pure module
zig build check      # elf sanity of the bootstrap: arm et_dyn, no dt_needed, has init_array
```

`-Dsupervisor_path=/res/bin/tc002-supervisor` selects the production exec path; the default is the
volatile `/tmp/tc002/tc002-supervisor`.

## sharing the device with another agent

`tools/tc002-lock.sh` implements an advisory, append-only lock in `/tmp/tc002-lock.txt` on the host:

```
<utc-iso8601> <agent> <ACQUIRE|RELEASE|NOTE> <free text>
```

an agent holds the lock while its last ACQUIRE/RELEASE record is an ACQUIRE younger than 30 minutes.
`acquire <intent> [timeout]` waits for other holders, appends ACQUIRE, re-reads to resolve a race in
favour of the earlier line; `release` appends RELEASE; `status` prints holders and the last lines. the
file is never truncated. every device-mutating step (stopping/starting `zkswe`, running anything that
opens spidev/gpio, writing `/tmp`, setprop) happens under the lock; read-only adb commands do not.

## running it on the device (volatile)

```bash
tools/tc002-run.sh push                     # build, check, push to /tmp/tc002/
tools/tc002-run.sh start --profile dev --stats --tz 'AEST-10AEDT,M10.1.0,M4.1.0/3'
tools/tc002-run.sh status
tools/tc002-run.sh stop                     # sigterm the supervisor (paced black frame), restart the stock app
tools/tc002-boot-experiment.sh start        # let the vendor loader dlopen the bootstrap via /tmp/EasyUI.cfg
tools/tc002-boot-experiment.sh restore
```

## what has been measured (2026-09-06, warm system)

- `tc002d` art: 60 fps sustained with real spi writes, 0 short writes, 0 errors; clock scene: exactly two
  paced transfers per wall-second update and nothing in between.
- supervisor: property accepted 10 ms after entry; a frozen renderer is stopped after 2 s of missing
  heartbeats, killed 2 s later, replaced 1 s after that with a new epoch; killing the supervisor takes the
  renderer with it; a graceful stop presents black and exits 0.
- boot experiment: `/tmp/EasyUI.cfg` takes precedence over `/res/etc/EasyUI.cfg` (the loader logs
  `load /tmp/EasyUI.cfg ok!`); the bootstrap's constructor execs the supervisor in place of the loader,
  keeping the `zkswe` service pid; `ctl.start` to property 1.67 s versus 1.6–2.7 s stock; init restarts
  the service about a second after the supervisor dies and every ~4 s after a failed exec, with the
  property untouched. the loader hands over `/dev/fb0`, a font file, the property workspace, an inotify
  fd, a pipe and its own `/dev/input/event67` reader; stderr is `/dev/null`.

not measured: cold boot against zkdaemon's 15 s check, upgrade-hook ordering, mtd3, physical input,
the hardened profile's adbd toggling, battery. full tables are in the vault plan note.
