# runtime — tc002 custom native runtime (plan b)

zig-built replacement for the stock application on the ulanzi tc002, following the design note
`tc002-customisation/2026-09-03/custom-native-runtime` and implementation plan
`tc002-customisation/2026-09-06/native-runtime-plan-b` in the agent-notes vault.

what is here: a no-libc bootstrap shared object that the vendor loader dlopens and whose
constructor execs the supervisor; `tc002-supervisor`, which raises the anti-brick property first and
then supervises the renderer and the network daemon; `tc002d`, the renderer, with a hardware-free
presentation model, pure scenes (three bases — clock, art and canvas — with popsquares, plasma and cube as the art generators), overlays, evdev input and a
bounded ipc channel; `tc002-netd`, the unprivileged http `/api/v1` server and mqtt client; and
`tc002-memdump`, a memory-audit tool. ~~nothing here writes flash or `/data`; every device run is
volatile under `/tmp/tc002/`~~ — **✗ no longer true:** settings and credentials live on `/data/tc002/state`, and the runtime is flashed to `/res`; `tools/tc002-flash.sh` is the one script here that writes flash. **the architecture, the api and the measured results are documented
in [`../RUNTIME.md`](../RUNTIME.md); this file is the build-and-run reference.**

## build and test

only zig 0.16.0 is required (`brew install zig`); the build refuses other versions.

```bash
cd runtime
zig build            # all seven binaries into zig-out/bin plus zig-out/lib/libtc002-bootstrap.so
                     # (arm; static and no-libc except tc002-berryd and tc002-audiod)
zig build test       # host unit tests of every pure module
zig build check      # elf sanity of the bootstrap: arm et_dyn, no dt_needed, has init_array
zig build wasm       # the scene code as wasm for the console preview -> ../panel-v2/tc002-panel.wasm
zig build test-berry # the .be fixtures in test/berry/ through the vendored interpreter, on the host
zig build berry-check # links the vendored interpreter for the device; not installed by default
zig build check-scripts # the shipped scripts in scripts/berry/, run and then fired real events at
```

### where the binaries live

`-Dbin_dir` is the directory the runtime's binaries are in **at runtime**. it defaults to
`/tmp/tc002`, the volatile install, and `tools/tc002-mkimage.sh` builds the flashable image with
`-Dbin_dir=/res/bin -Dnetup=true`.

this is not cosmetic. the bootstrap execs the supervisor at a compiled-in path with only
`--from-bootstrap`, and the supervisor spawns its five children by absolute path, so a flashed
runtime never sees a command-line argument: every path it uses is the one compiled in. built with
the default and put on `/res`, the binaries would not find each other.

`-Dnetup=true` turns on the wifi bring-up a flashed install has to do for itself — the vendor
loader we replace is what used to do it. leave it off for `/tmp`: bringing wifi up again restarts
`wpa_supplicant`, and adb is over that link.

`-Dsupervisor_path` still overrides the bootstrap's exec path on its own, for the loader
experiments; it defaults to `<bin_dir>/tc002-supervisor`.

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
`<state>/credentials/tokens` (default `/data/tc002/state`) (mode 0600) and handed over the channel; nothing on disk is readable by netd.

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
  eight connections, one request each (plus the event stream, which is one response that never
  ends), no chunked bodies, no dns. cost: a narrower protocol surface; gain: bounded memory and no
  allocator. `std.http` was re-examined when the event stream was added and rejected on the loop,
  not the size: it needs **no libc** (it compiles for `arm-linux-musleabihf` without it) and costs
  only +16.8 kb of `.text`, but `receiveHead` is written to block — it loops on `fillMore` until the
  head is complete and resets its parser state on every call, so on a non-blocking fd eagain arrives
  as `error.ReadFailed` and the parse position is gone. it happens to be re-enterable, because
  nothing is tossed from the buffer until the head completes, but that is an implementation detail
  rather than a contract, and it is quadratic in the number of partial reads. the streaming response
  we actually needed is one extra header builder in `net/sse.zig`.
- **no tls**: zig 0.16's std has a tls client but no server, and no tls library is vendored. only the
  plaintext profile ships; status reports `transport: plaintext`; an mqtt `tls: true` setting stays
  disconnected instead of falling back. tokens are exposed to anyone on the lan path.
- **relay through the supervisor** instead of a netd→renderer channel: one fewer descriptor to pass
  across renderer restarts; the supervisor forwards typed messages and parses no http or mqtt.
- **`std.json` for bodies** (validated utf-8, strict fields) rather than a hand parser: costs code
  size, keeps correctness; bodies are capped at 8 kb (`json.max_body`) and parsed into a 16 kb fixed arena (`json.arena_size`); 4 kb is `http.max_head`.
- **ReleaseSafe by default** (bounds checks on) at 255–411 kb per binary versus 66–170 kb for
  ReleaseSmall; on the volatile path that is about 0.7 mb of tmpfs ram. `-Doptimize=ReleaseSmall`
  is available; a simple panic handler and no segfault handler already keep the dwarf unwinder out.
- **procfs rss on this kernel is unreliable for some processes and is reported as-is.** measured
  together on one device, at one moment: `tc002-supervisor` reports `VmRSS` 1,112 kb and
  `tc002-netd` 972 kb, with `statm` agreeing and `RssShmem` accounting for the binary's own pages
  (tmpfs pages are shmem), while **`tc002d` reports 4 kb** — `VmRSS`, `VmHWM` and `RssAnon` all 4 kb
  — while actively presenting frames. so it is not "4 kb for every static process", and it is not
  trustworthy either; no cause has been established, and none is asserted here. where a real figure
  is needed, `VmData` against `RssAnon` still shows demand-zero working: netd reserves 520 kb of
  data and has 188 kb of it resident.
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
- **berry is vendored, and its binary is the only one that links libc.** the interpreter needs 56
  external symbols, and two of them decide the question: `setjmp`/`longjmp` is berry's entire error
  model, and `snprintf` is how it formats reals. writing those by hand means arm assembly and a
  printf family; zig's static musl supplies them correctly, and the parts actually used measure
  19 kb. `tc002-audiod` links libc too, and is dynamic; the rest are unchanged.
  `runtime/vendor/berry/` holds upstream `6e6e621` with its `coc` output committed (builds never
  need python, exactly as `src/scene/zones.zig` never needs zoneinfo), `be_filelib.c` deleted, and
  four entry points in `port/be_port.c` that refuse rather than pretend -- `open()` raises
  `io_error`. the trimmed interpreter is **205 kb** of armv7 image at `-Os`.
  `zig build berry-check` links it for the device and `zig build test-berry` runs `.be` fixtures
  through the same c on the host; neither is part of `zig build` or `zig build test`, which stay
  pure zig. note that `tc002-berry-check` measures 731 kb allocated rather than 205: it is a
  ReleaseSafe zig program linking static musl, and 262,144 bytes of that is zig's
  `Thread.maybeAttachSignalStack` signal stack in `.bss`, demand-zero and not resident. the numbers
  that matter are the ones the berry daemon produces when it exists.

## running it on the device (volatile)

~~after a reboot the stock app is back and nothing of the runtime is left on the device.~~ **✗ that is the `/tmp` path only**; a flashed runtime comes back as itself. one
command brings it up again, with the settings applied and the console's tokens pulled:

> making that survive a reboot means flashing the runtime into the `res` partition, which is
> **not done here** — see [busybox, for a persistent install](#busybox-for-a-persistent-install)
> for the one piece of groundwork that exists so far.

```bash
runtime/tools/tc002-up.sh                          # adb connect, build, push, start, settings, tokens
runtime/tools/tc002-up.sh --tz Australia/Melbourne --font classic --no-build
runtime/tools/tc002-demo-transitions.py -s <device-ip> --token-file tokens   # a demo reel of every transition; --only, --ms, --hold, --loop
runtime/tools/tc002-demo-shapes.py -s <device-ip> --token-file tokens        # the canvas primitives; and -text, -charts, -icons,
                                                                            # -images, -layout, -tiles, -dashboard alongside it
panel-v2/start-panel.sh --open                     # the console, once the runtime is up
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
it). this kernel reports `VmRSS` = 4 kB for **some** of the static processes (`tc002d`, but not the
supervisor or netd — see the tradeoffs above); the pagemap present bits are the trustworthy
residency signal either way.

```bash
adb push zig-out/bin/tc002-memdump /tmp/tc002-memdump
adb shell "/tmp/tc002-memdump $(pid) hex" | tr -d '\r\n' | xxd -r -p > snapshot.tcmd
```

## telemetry for home assistant and grafana

with mqtt enabled and `discovery=true`, netd advertises 43 read-only diagnostic sensors, a display-power
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
the pack voltage every `--mcu-poll` seconds and the usb rail **every second**, one outstanding
request at a time, 500 ms timeout), and sends `10` power off
when the cell runs out — see [the low-battery shutdown](../RUNTIME.md#the-low-battery-shutdown).
the two cadences are separate because they answer different questions: a cell's charge moves over
hours, but the rail changes the instant someone lifts the clock off its dock and they are looking
at the panel when they do it. while the battery is *low* the voltage poll also drops to three times
a second, and is handed back to whatever `--mcu-poll` asked for rather than to the default.
measured on the device: an undock is seen in under a second, and the pogo-pin dock registers on the
same `vin` the usb-c port does. the register and firmware-upload commands
are still never sent. the mcu also streams unsolicited mic reports that the synchroniser discards.

### time sync (sntp)

the supervisor keeps the clock in sync with one local ntp server once `ntp_server` is set (a dotted
ipv4; `ntp_interval_s` 300 or 600): `tc002ctl.py -s <ip> --token-file FILE config-set ntp_server=10.0.0.136`,
then `config-save` to keep it across restarts. `/status` reports `time.state` (`unsynced` / `synced` /
`stale`) and `time.age_s`; the supervisor log shows every exchange as `sntp: offset N ms, delay N ms,
stratum N, stepped|slewing`. the client, its validation rules and the step/slew thresholds are described
in [RUNTIME.md](../RUNTIME.md#time-sntp).


## busybox, for a persistent install

a runtime that boots on its own, before the stock app, has to bring the network up itself: load the
aic8800 driver, wait for the supplicant to associate, and run a dhcp client. the device's own
busybox resolves almost nothing — **there is no `udhcpc`**, and no `grep`, `sed`, `head` or `wc`
either, which is a tax on every investigation on this device.

so the image needs a busybox of its own. `runtime/tools/tc002-mkbusybox.sh` builds one from source
rather than taking a prebuilt binary from anywhere:

```bash
runtime/tools/tc002-mkbusybox.sh [workdir] [out]   # -> a static armv7 busybox, 508 kb, 135 applets
```

it fetches a pinned busybox tarball, **checks it against a recorded sha256**, configures from
`allnoconfig` up (so the applet list is a decision, not a default), and cross-compiles.

**zig is the entire toolchain.** the repo already pins zig 0.16 for the runtime and `zig cc` ships
musl and the linux headers, so this adds no dependency: no docker, no crosstool, no homebrew
binutils. `zig ar` stands in for gnu `ar` and `zig cc` drives the relocatable link, because macos
ships bsd versions of both that busybox's makefiles cannot use.

four things about that build are not obvious, and each one cost a round:

| symptom | cause |
|---|---|
| `undefined symbol: _libintl_gettext` linking kconfig | kconfig wants gettext on macos. `-DKBUILD_NO_NLS` is upstream's switch; `lkc.h` then defines `gettext()` as the identity |
| `BUG_off_t_size_is_misdetected` | musl's `off_t` is 64-bit even on 32-bit arm, and busybox static-asserts its own `uoff_t` matches. `CONFIG_LFS=y` |
| `busybox: applet not found`, for every applet | `allnoconfig` turns off `CONFIG_BUSYBOX`, the multiplexer. without it the binary works only through argv[0] symlinks, and `busybox insmod …` — which is how every boot script calls it — fails. it builds and runs, so nothing catches this but trying it |
| `strip: unrecognized option --remove-section` | busybox strips with gnu options. `SKIP_STRIP=y`; lld has already stripped the output |

the binary was pushed to the device's `/tmp` and run: `udhcpc`, `insmod`, `ifconfig`, `route` and
`ash` for the boot path, and `uname`, `dd`, `find`, `stat`, `pstree`, `awk`, `top`, `tar` and the
rest for the investigations this device otherwise makes painful — its own busybox resolves almost
nothing. **nothing here writes to `/res`.**

### every applet is a symlink beside it

`/res/bin` holds one symlink per applet, pointing at `busybox`, so an applet is
`/res/bin/head` rather than `/res/bin/busybox head`. busybox dispatches on `argv[0]`, which is what
makes that work; the image build creates them.

the list comes from **that build**, not from a list kept by hand: `tc002-mkbusybox.sh` writes
`<binary>.applets` out of the generated `include/applet_tables.h` — the table the multiplexer
actually dispatches on — and `tc002-mkimage.sh` reads it and refuses to build without it. a symlink
for an applet the binary does not carry would be a name that answers `applet not found`, which is a
worse failure than the name not being there.

**they shadow nothing.** the device's `PATH` is `/sbin:/bin:/tmp:` and `/res/bin` is not on it, so
`reboot` still finds `/bin/reboot`. to have the applets by name, put `/res/bin` **last**:

```sh
export PATH=$PATH:/res/bin
```

busybox carries its own `reboot`, `mount`, `sh` and `ps`, and on this device the stock ones are
what the system expects — putting `/res/bin` first would quietly swap them.

**the script now reports what it asked for and did not get.** `oldconfig` silently drops any
symbol whose dependencies are unmet, which is how `dd`, `df -h`, `busybox insmod` and `ls --color`
were each found missing *on the device* rather than at build time. `ls --color` needs
`LONG_OPTS`, which `allnoconfig` leaves off; the multiplexer and the rest had their own reasons.
the check costs nothing and turns that whole class from silent to noisy.

`telnetd` is deliberately absent. it would be a recovery channel independent of adbd, which is
tempting for a flashed device — but this kernel has **no netfilter at all**, so the device cannot
firewall itself, and an unauthenticated root shell on the network is not a trade worth making.


## assembling an image (not flashing one)

`runtime/tools/tc002-mkimage.sh` takes a stock `update.img`, adds the runtime, the bootstrap and
our own busybox, points the loader's `EasyUI.cfg` at the bootstrap, repacks and validates:

```bash
runtime/tools/tc002-mkimage.sh /path/to/stock-update.img OUT.img
```

it needs `squashfs-tools` (`brew install squashfs-tools`) and builds busybox itself if there
isn't one already.

**the size question is answered.** the stock `res` is 2,781,184 bytes compressed; the six
binaries, the bootstrap, busybox with a symlink per applet, and the boot scripts land at
**4,456,448 bytes of the 8 mib partition — 53% used, 3.93 mb spare**. a persistent install fits
comfortably. (this used to read "47% used, 4.4 mb spare", which had used and spare the wrong way
round, and counted four binaries when there are six.)

the pipeline is also verified in both directions: the reader reproduces the vendor image byte for
byte from an untouched payload, and a repack of the *unmodified* tree comes back the same size and
differs only in the superblock's `mkfs_time` and `flags` — the timestamp, and mksquashfs 4.7.5's
defaults against whatever version the vendor used. content-identical, not byte-identical, and
byte-identity is not something a repack needs.

### what it was not, until 2026-09-15

> **✗ this section described a tree that could not safely be flashed. it has
> been flashed since, and every prerequisite below exists.** kept because the
> four items are still the right checklist for anyone porting this to another
> unit — see [`FIRMWARE.md`](../FIRMWARE.md) for the boot log and the sequence
> that worked, and `tools/tc002-flash.sh` for the install itself.

~~the image it writes would be **accepted by the flasher and must not be given
to one**. four things have to exist first~~ — all four now do:

1. the boot-failure counter and stock-config fallback → `src/sys/recovery.zig`,
   three bad boots hand the panel back, cleared after 60 healthy seconds;
2. yielding to a pending upgrade → `recovery.upgradePending` /
   `writeUpgradeYieldCfg`, so the reset button's reflash still runs;
3. wifi bring-up at cold boot → `boot/tc002-netup.sh` + `Supervisor.spawnNetup`,
   which loads the driver the stock boot never loads;
4. exporting gpio 35 and waiting for `spidev0.0` → `Supervisor.panelReady`,
   `panel_wait_ns = 45 s`.

a fifth was added after the fact: a 120 s no-network hand-back, because a
runtime that comes up healthy and never gets an address is unreachable and
nothing else caught that.

~~the runtime in the image is also built with this tree's default paths (`/tmp/tc002`) rather than
`/res/bin` … that is a build option this tree does not have yet.~~ **✗ `-Dbin_dir` exists**
(`build.zig`), and `tools/tc002-mkimage.sh` builds with `-Dbin_dir=/res/bin -Dnetup=true`. this
contradicted the "where the binaries live" section 300 lines above it.
