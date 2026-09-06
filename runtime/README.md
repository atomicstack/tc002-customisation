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

## the network api (`tc002-netd`)

`tc002-netd` serves `/api/v1` over plain http on port 80 (the design's `isolated-lan` profile; there is
no tls in this build, see the tradeoffs below) and runs an mqtt 3.1.1 client. it runs as uid 1001 with
two inherited descriptors: the supervisor's channel and a listener that root bound for it. bearer
tokens (control and admin, 32 random bytes each) are generated once by the supervisor into
`<dir>/credentials/tokens` (mode 0600) and handed over the channel; nothing on disk is readable by netd.

```bash
adb pull /tmp/tc002/credentials/tokens tokens          # root over adb; keep the file private
tools/tc002ctl.py -s <device-ip> --token-file tokens status
tools/tc002ctl.py -s <device-ip> --token-file tokens scene art --generator plasma --seed 5
tools/tc002ctl.py -s <device-ip> --token-file tokens notify hello --colour 00ff80 --duration 4
tools/tc002ctl.py -s <device-ip> --token-file tokens frame --colour ff0000 --duration 3
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set brightness=60 timezone=JST-9   # admin token
tools/tc002ctl.py -s <device-ip> --token-file tokens config-save
tools/tc002ctl.py -s <device-ip> --token-file tokens mqtt-set enabled=true host=10.0.0.2 port=1883 prefix=tc002/dev
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set discovery=true metrics_interval_s=30
tools/tc002-test-broker.py                              # a minimal broker on the host, for tests
```

mqtt topics under the configured prefix: `availability` (retained, last will `offline`), `state`
(retained, at most twice per second), `result` (one per command, with the request id), `metrics`
(every 30 s by default), and `cmd/scene`, `cmd/action`, `cmd/notify`, `cmd/frame`, `cmd/config`
(control subset only). home-assistant discovery is opt-in and publishes read-only diagnostic sensors.

## tradeoffs made for this device (reported, not hidden)

- **own http/1.1 parser and mqtt codec** instead of `std.http.Server` or a library: fixed buffers,
  four connections, one request each, no chunked bodies, no dns. cost: a narrower protocol surface;
  gain: bounded memory (about 60 kb of static buffers for the whole daemon) and no allocator.
- **no tls**: zig 0.16's std has a tls client but no server, and no tls library is vendored. only the
  plaintext profile ships; status reports `transport: plaintext`; an mqtt `tls: true` setting stays
  disconnected instead of falling back. tokens are exposed to anyone on the lan path.
- **relay through the supervisor** instead of a netd→renderer channel: one fewer descriptor to pass
  across renderer restarts; the supervisor forwards typed messages and parses no http or mqtt.
- **`std.json` for bodies** (validated utf-8, strict fields) rather than a hand parser: costs code
  size, keeps correctness; bodies are capped at 4 kb and parsed into an 8 kb fixed arena.
- **ReleaseSafe by default** (bounds checks on) at 255–411 kb per binary versus 66–170 kb for
  ReleaseSmall; on the volatile path that is about 0.7 mb of tmpfs ram. `-Doptimize=ReleaseSmall`
  is available; a simple panic handler and no segfault handler already keep the dwarf unwinder out.
- **procfs rss on this kernel reads 4 kb for every static process** and is reported as-is.

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
