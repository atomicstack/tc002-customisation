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
