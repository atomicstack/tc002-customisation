# runtime — tc002 custom native runtime (plan b)

zig-built replacement for the stock application on the ulanzi tc002, following the design note
`tc002-customisation/2026-09-03/custom-native-runtime` and implementation plan
`tc002-customisation/2026-09-06/native-runtime-plan-b` in the agent-notes vault.

what is here: a no-libc bootstrap shared object that the vendor loader dlopens and whose
constructor execs the supervisor; `tc002-supervisor`, which raises the anti-brick property first and
then supervises the renderer and the network daemon; `tc002d`, the renderer, with a hardware-free
presentation model, pure scenes (popsquares, plasma, clock, ip), overlays, evdev input and a
bounded ipc channel; `tc002-netd`, the unprivileged http `/api/v1` server and mqtt client; and
`tc002-memdump`, a memory-audit tool. nothing here writes flash or `/data`; every device run is
volatile under `/tmp/tc002/`. **the architecture, the api and the measured results are documented
in [`../RUNTIME.md`](../RUNTIME.md); this file is the build-and-run reference.**

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
adb pull /data/tc002/state/credentials/tokens tokens   # root over adb; keep the file private
tools/tc002ctl.py -s <device-ip> --token-file tokens status
tools/tc002ctl.py -s <device-ip> --token-file tokens scene art --generator plasma --seed 5
tools/tc002ctl.py -s <device-ip> --token-file tokens notify hello --colour 00ff80 --duration 4
tools/tc002ctl.py -s <device-ip> --token-file tokens notify hello --transition swipe_in --direction left   # leaves as swipe_out right
tools/tc002ctl.py -s <device-ip> --token-file tokens frame --colour ff0000 --duration 3
tools/tc002ctl.py -s <device-ip> --token-file tokens power off               # fades to black; `power on` fades back
tools/tc002ctl.py -s <device-ip> --token-file tokens scene clock --font big --colour-mode gradient --colour 2060ff --colour2 60c0ff --gradient vertical
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set clock_font=block timezone=Europe/Amsterdam   # durable defaults, admin token
tools/tc002ctl.py -s <device-ip> --token-file tokens scene ip --ip-mode big                      # the address in one of four layouts
tools/tc002ctl.py -s <device-ip> --token-file tokens scene clock --font hires                     # time, a bar through the second, milliseconds at 60 fps
tools/tc002ctl.py -s <device-ip> --token-file tokens --admin ntfy-set enabled=true url=https://ntfy.sh topic=my-clock   # then: curl -d hello ntfy.sh/my-clock
tools/tc002ctl.py -s <device-ip> --token-file tokens --admin ntfy-set url=https://ntfy.home.lan:8443 --ca-file ca.pem  # a self-hosted server with a private ca
tools/tc002ctl.py -s <device-ip> --token-file tokens input middle click      # a remote press; rotary cw --steps 3
tools/tc002ctl.py -s <device-ip> --token-file tokens screen --ascii          # the frame as shown, drawn in the terminal
tools/tc002ctl.py -s <device-ip> --token-file tokens logs --follow           # the supervisor's log ring
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set brightness=60 timezone=JST-9   # admin token
tools/tc002ctl.py -s <device-ip> --token-file tokens config-save
tools/tc002ctl.py -s <device-ip> --token-file tokens mqtt-set enabled=true host=10.0.0.2 port=1883 prefix=tc002/dev
tools/tc002ctl.py -s <device-ip> --token-file tokens config-set discovery=true metrics_interval_s=30
tools/tc002-test-broker.py                              # a minimal broker on the host, for tests
```

mqtt topics under the configured prefix: `availability` (retained, last will `offline`), `state`
(retained, at most twice per second), `result` (one per command, with the request id), `metrics`
(every 30 s by default), `screen` (a binary frame, in answer to `cmd/screen`), `input/<control>`
(momentary button, knob and rotary events, never retained), and `cmd/scene`, `cmd/action`,
`cmd/notify`, `cmd/frame`, `cmd/input`, `cmd/screen`, `cmd/config` (control subset only).
home-assistant discovery is opt-in and publishes read-only sensors plus event entities for the
controls. the full reference is [`RUNTIME.md`](../RUNTIME.md).

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
- **the ntfy subscriber is a 1.1 mb binary**: the standard library's tls 1.3 client, certificate
  verification (rsa and ecdsa), dns resolution and the threaded io layer come along with it. it is a
  process of its own, spawned only while a subscription is enabled, so the rest of the runtime does
  not pay for it. one root certificate (isrg root x1) is built in; anything else needs the `ca`
  setting or `insecure`.
- **transitions in the renderer** cost two more 2,496-byte frame buffers (the old layer is the
  outgoing scene rendered live every frame, so two scenes render per frame while an effect runs)
  and a per-pixel source lookup (or multiply-add for the fade) at 60 hz for the duration of the
  effect, 500 ms unless the request says otherwise; a dark panel costs nothing (no redraws at all). fifteen effects are compiled in
  (`panel/transition.zig`); a request names one, a direction, a duration and an exit mode, and an
  overlay leaves with the paired effect the other way, the same way, or a cut.
- **the screen document is base64 in json** (3,328 characters) so `curl` and `jq` can use it without
  a binary path; `?format=raw` and the mqtt `screen` topic carry the bytes instead. netd's json buffer
  grew from 2 kb to 3.5 kb for it.
- **the log ring is 64 lines of 160 bytes** (10 kb of static storage in the supervisor), served sixteen
  lines a page; older lines are gone, and a flooding child drops lines rather than blocking.
- **clock gradients show the whole requested ramp by default** (`spread` 255); a smaller `spread`
  bounds the per-channel distance between the two colours for a subtler shade shift. the first cut
  clamped every gradient to 96 and was too timid on the panel.
- **the zone table costs 22 kb in the supervisor**: 597 iana names with their current posix rules,
  looked up by a linear scan when settings change. no tzdata on the device, no historical rules.
- **input events are not retained** on mqtt, on purpose: a consumer that was offline must not replay
  a stale press. events raised while the broker is unreachable are lost.

## running it on the device (volatile)

after a reboot the stock app is back and nothing of the runtime is left on the device. one
command brings it up again, with the settings applied and the console's tokens pulled:

```bash
runtime/tools/tc002-up.sh                          # adb connect, build, push, start, settings, tokens
runtime/tools/tc002-up.sh --tz Australia/Melbourne --font classic --no-build
runtime/tools/tc002-demo.py -s <device-ip> --token-file tokens         # a demo reel of every transition; --only, --ms, --hold, --loop
panel-v2/start.sh --open                           # the console, once the runtime is up
runtime/tools/tc002-run.sh stop                    # back to the stock app
```

the defaults (device `10.0.0.111:5555`, `Europe/Amsterdam`, sntp from `10.0.0.136`, the `block`
clock) can be changed with options or the `TC002_*` environment variables listed in the script.

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

## memory audits (`tc002-memdump`)

`tc002-memdump <pid> hex` (root, over adb) streams a sparse snapshot of a process: procfs text, every
readable mapping's *present* pages, and the raw `pagemap` entries, hex-encoded so it survives
`adb shell` (this adbd has no `exec-out`). nothing is written to the device and the process keeps
running. `zig build -Dstrip=false --prefix <dir>` produces the same code with symbols kept for
attribution of `.data`/`.bss` objects (the section start differs by a constant per binary; subtract
it). this kernel reports `VmRSS` = 4 kB for the static processes; the pagemap present bits are the
trustworthy residency signal.

```bash
adb push zig-out/bin/tc002-memdump /tmp/tc002-memdump
adb shell "/tmp/tc002-memdump $(pid) hex" | tr -d '\r\n' | xxd -r -p > snapshot.tcmd
```

## telemetry for home assistant and grafana

with mqtt enabled and `discovery=true`, netd advertises 24 read-only diagnostic sensors, a display-power
binary sensor and five event entities for the physical controls, grouped under
one device whose identity is the wlan0 mac (`tc002-<mac>`), so entities survive reboots and never
depend on the ip. every sensor reads a field of the `metrics` json (default every 30 s, `metrics_interval_s`
10–3600 or 0 to disable) with `expire_after` = 3 × the interval and the shared availability topic, so a
silent device goes unavailable instead of freezing at its last value. `state_class: measurement`
sensors chart directly in grafana through home assistant's recorder or influxdb export.

| field | source | note |
|---|---|---|
| `cpu_pct` | `/proc/stat` deltas over 5 s, both cores | busy / total |
| `cpu_pct_by_process.{supervisor,renderer,netd}` | `/proc/<pid>/stat` utime+stime deltas | percent of one core |
| `memory_available_kb`, `memory_free_kb`, `tmpfs_used_kb` | `/proc/meminfo` | `Shmem` counts tmpfs on this kernel |
| `rss_kb.*` | `/proc/<pid>/status` | this kernel reports 4 kb for static binaries; unreliable |
| `load_1m` | `/proc/loadavg` | |
| `wifi.rssi_dbm`, `wifi.quality` | `/proc/net/wireless` | kernel-reported |
| `battery.millivolts`, `battery.percent`, `battery.usb_present` | the pixel mcu over `/dev/ttyS1` | see below |
| `fps`, `presented`, `renderer_restarts`, `mqtt_reconnects`, `http_*`, `mqtt_*` | runtime counters | `fps` is null unless art runs |
| `uptime_s`, `boot_id`, `device_id`, `sample_age_ms`, `time.state` | supervisor | counters identify their lifetime |

### the pixel mcu link

recovered from the vendor library and verified on the device: `/dev/ttyS1` at **1,500,000 baud**
(the constant `McuManager::initialize` receives), frames `FF 55 <cmd> <len> <payload> <sum16>` with
a big-endian 16-bit byte sum, commands `01` mic level, `02` usb state, `03` battery, `04` auto mic
report, `10` power off, `11` version, `13` led register. the battery reply is one byte (percent) and a
16-bit value the vendor multiplies by 1.3235 to get millivolts; measured here: version `V1.0.17`,
`89 %`, raw 3121 → 4130 mV, usb present. the supervisor only queries (version once, then battery and
usb every `--mcu-poll` seconds, one outstanding request, 500 ms timeout); it never sends the
power-off, register or firmware-upload commands. the mcu also streams unsolicited mic reports that the
synchroniser discards.

### time sync (sntp)

the supervisor keeps the clock in sync with one local ntp server once `ntp_server` is set (a dotted
ipv4; `ntp_interval_s` 300 or 600): `tc002ctl.py -s <ip> --token-file FILE config-set ntp_server=10.0.0.136`,
then `config-save` to keep it across restarts. `/status` reports `time.state` (`unsynced` / `synced` /
`stale`) and `time.age_s`; the supervisor log shows every exchange as `sntp: offset N ms, delay N ms,
stratum N, stepped|slewing`. the client, its validation rules and the step/slew thresholds are described
in [RUNTIME.md](../RUNTIME.md#time-sntp).
