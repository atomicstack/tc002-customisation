# KERNEL.md — what is in the tc002's kernel, and what is not

the tc002 runs **linux 4.9.84**, configured for exactly one product and
stripped of nearly everything that product does not need. this document is the
inventory: which subsystems are compiled in, which syscalls actually work,
which kernel services are worth using from the runtime, and what the gaps cost.

the short version, for the three questions people ask first:

| question | answer |
|---|---|
| is nfs usable? | **no.** not built in, no module on the device, and nothing to load. `mount("nfs")` returns `ENODEV`. cifs/smb are absent too. see [network filesystems](#network-filesystems) for the three ways out |
| is ebpf available? | **no.** `sys_bpf` is a weak stub returning `ENOSYS`. the `bpf_*` symbols that *do* exist are classic-bpf plumbing for socket filters, not ebpf |
| can the device firewall itself? | **no.** netfilter is not compiled in at all — no hooks, no `iptables`, no conntrack. network position is the only access control there is |

everything below was measured on a running unit at the commit that added this
file. nothing here is from a datasheet.

---

## how this was measured

**there is no `.config` on the device.** `CONFIG_IKCONFIG_PROC` is off, so
`/proc/config.gz` does not exist. the inventory is therefore inferred from
three sources, and every claim below rests on at least one of them:

1. **`/proc/kallsyms`** — readable in full, with real addresses. 31 339 lines,
   23 217 unique symbol names. a subsystem that is compiled in leaves its
   function names here; one that is not, leaves nothing.
2. **runtime state** — `/proc/filesystems`, `/proc/devices`, `/proc/net/*`,
   the `/proc/sys` tree, `/sys/class/*`, `/proc/interrupts`, `/proc/misc`.
3. **the device tree** at `/proc/device-tree`, which describes the *hardware*
   and is not evidence that a driver was built for it.

### the stub trick, for syscalls

a syscall the kernel was built without is not missing from the symbol table —
`cond_syscall()` leaves a **weak alias pointing at `sys_ni_syscall`**, which
returns `ENOSYS`. so "is `sys_bpf` in kallsyms" is the wrong question; it is.
the right question is whether its address differs from `sys_ni_syscall`:

```
sys_ni_syscall      c002a9dc
sys_bpf             c002a9dc  W   <- same address, weak: stub, returns ENOSYS
sys_mount           c009ab88  T   <- real implementation
```

that is how the [syscall table](#syscalls-that-work-and-that-do-not) below was
produced, and it is the only reliable way to ask this kernel what it supports.

### two caveats worth carrying

- **absence of a symbol is strong evidence, not proof.** several spellings were
  checked per subsystem, and anything marked "no" below was corroborated by a
  second artefact wherever one exists — a missing filesystem type, a missing
  `/proc/net` entry, a missing sysctl directory.
- **`adb shell` translates lf to crlf.** every line of `/proc/kallsyms` arrives
  with a trailing `\r` attached to the symbol name, so anchored greps
  (`grep '^sys_bpf$'`) fail silently and every subsystem looks absent. pipe
  through `tr -d '\r'` before matching. this cost a full pass of wrong answers
  while writing this document.

---

## identity

| | |
|---|---|
| version | `linux 4.9.84 (guoxs@jf) #1624 smp preempt wed may 27 13:08:02 utc 2026` |
| toolchain | gcc 9.1.0 (openwrt gcc 9.1.0 1612336227) |
| arch | armv7, thumb2, 2 × cortex-a7, `p2v8` |
| preemption | `CONFIG_PREEMPT` (the low-latency variant, not `PREEMPT_RT`) |
| tick | `CONFIG_HZ=100`, but the tick device runs **oneshot** (`mode: 1`) with `hrtimer_interrupt` as the handler — tickless, high-resolution, `min_delta_ns` 2500 |
| clock bases | all four: monotonic, realtime, boottime, tai |
| module vermagic | `4.9.84 SMP preempt mod_unload ARMv7 thumb2 p2v8` |
| taint | `4097` = proprietary (bit 0) + out-of-tree (bit 12), from the sigmastar `mi_*` and aicsemi wi-fi modules |
| console | `ttyS0,115200`, `loglevel=0` — the kernel says nothing on the console by default (`/proc/sys/kernel/printk` = `0 3 1 7`) |

the full command line:

```
console=ttyS0,115200 root=/dev/mtdblock2 rootfstype=squashfs ro init=/sbin/init
LX_MEM=0x3FE0000 mma_heap=mma_heap_name0,miu=0,sz=0x1800000 cma=2M highres=on
mmap_reserved=fb,miu=0,sz=0x300000,... loglevel=0 mtdparts=nor0:...
```

`LX_MEM=0x3FE0000` is 63.9 mib handed to linux; `mma_heap` reserves 24 mib for
sigmastar's media allocator and `mmap_reserved=fb` another 3 mib, which is where
the ~35 mib in `MemTotal` comes from. `cma=2M` is a further 2 mib contiguous
pool. the arithmetic behind those numbers is in the
[readme's hardware section](README.md#hardware).

---

## filesystems

`/proc/filesystems` in full, annotated:

| filesystem | built in | used for |
|---|---|---|
| `squashfs` | yes | `/` (`mtdblock2`), `/res`, `/config` — all read-only and 100% full |
| `jffs2` | yes | `/data`, the **only** persistent writable space. 8 mib, 7.7 mib free |
| `vfat` / `msdos` | yes | `/mnt/storage` (`mtdblock7`, read-only from linux) |
| `tmpfs` / `ramfs` / `devtmpfs` | yes | `/tmp`, `/dev`, `/mnt`, `/misc`, 16 mib each |
| `proc` / `sysfs` | yes | — |
| `devpts` | yes | ptys |
| `configfs` | yes | mounted nowhere; the usb gadget uses a vendor class instead |
| `fuse` / `fuseblk` / `fusectl` | yes | **nothing yet** — `/dev/fuse` exists and works |
| `pipefs` / `sockfs` / `bdev` / `mqueue` | yes | internal |

**absent:** `ext2`/`ext3`/`ext4`, `overlayfs`, `ubifs`, `nfs`, `cifs`/`smb`,
`f2fs`, `btrfs`, `iso9660`, `autofs`, `debugfs`, `tracefs`.

no `debugfs` is worth calling out separately: it means there is nowhere for
ftrace, and nothing to mount even if there were.

### block layer

`sd` (scsi disk), `usb-storage` and `mmc_block` are all compiled in, and the
majors are registered — but `/sys/class/block` holds nothing except the eight
`mtdblock*` nodes. the scsi and usb-storage code is there for a usb host port
that has nothing on it. **absent:** loop devices, device-mapper, md, zram, and
`sys_swapon` is a stub, so swap is impossible regardless of `swappiness`
appearing in sysctl.

that last point matters: **35 mib is the whole budget**, there is no swap and no
zram, and the oom killer is the only backstop.

### network filesystems

nfs is absent by every test:

- not in `/proc/filesystems`, so `mount(2)` returns `ENODEV`
- no `nfs_*`, `rpc_*`, `xdr_*` or `sunrpc` symbols in kallsyms (the 93 symbols
  matching "nfs" are `kernfs_*` and `__fat_nfs_get_inode`, the fat export op —
  false positives, not the nfs client)
- the only `.ko` files on the device are `/lib/modules/4.9.84/aic8800_{bsp,fdrv}.ko`
  and the eleven sigmastar `mi_*` modules in `/config/modules`. there is no nfs
  module to load

the three ways to get network storage on this device, cheapest first:

1. **don't.** the runtime already serves and consumes http, and `/data` has
   7.7 mib free for anything that must persist. for a clock this is almost
   always the right answer.
2. **fuse.** `/dev/fuse` is present and the filesystem type is registered, so a
   userspace daemon can mount a real filesystem at a real path. there is no
   libfuse on the device, so this means speaking the `/dev/fuse` protocol
   directly — plausible in zig, but it is a protocol implementation, not an
   afternoon.
3. **build `nfs.ko` out of tree.** module loading is permitted
   (`modules_disabled=0`, `sys_init_module` is real, and the kernel is already
   tainted by out-of-tree modules), but the module must match the vermagic
   string above *exactly*, which means the matching 4.9.84 sigmastar source, its
   `.config`, and openwrt gcc 9.1.0. nfs also needs `sunrpc` and `lockd`
   alongside it, and those depend on exported symbols a kernel built without
   `CONFIG_NFS_FS` may or may not still export. unverified, and the rootfs is
   read-only and 100% full, so the modules would have to live in `/data`.

---

## networking

registered protocol families, from `/proc/net/protocols`: `TCP`, `UDP`,
`UDP-Lite`, `RAW`, `PING`, `PACKET`, `UNIX`, `NETLINK`, `L2CAP`, `HCI`.

| feature | present | note |
|---|---|---|
| ipv4 (tcp/udp/icmp/igmp) | yes | cubic and reno congestion control; cubic is the default |
| **ipv6** | **no** | no `inet6_create`, no `/proc/net/if_inet6`, no `/proc/sys/net/ipv6`. the handful of `ipv6`-shaped symbols are checksum/gso helpers in the core. the device is ipv4-only, permanently |
| **netfilter** | **no** | no hooks, no `iptables`, no conntrack, no nat, no `/proc/sys/net/netfilter`. `/proc/sys/net` contains only `core`, `ipv4` and `unix` |
| af_packet | yes | raw frames, for arp/mdns/wake-on-lan style work |
| netlink | yes | how `wpa_supplicant` talks to the wi-fi driver |
| unix sockets | yes | the runtime's own ipc |
| cfg80211 | yes | with the out-of-tree aicsemi driver; **mac80211 is absent**, the driver is full-mac |
| bluetooth | partial | bluez core, `l2cap` and `hci_uart` are in. **`rfcomm`, `bnep` and `hidp` are not** — ble/gatt is reachable, classic serial/pan/hid profiles are not |
| tun/tap, bridge, vlan, bonding, gre | no | no vpn, no virtual interfaces |
| traffic control (qdiscs) | no | no shaping, no `tc` |
| xfrm/ipsec | no | |

interfaces: `lo`, `wlan0`, `p2p0`. there is no ethernet.

**tcp tuning is available and unusually complete** — the whole
`/proc/sys/net/ipv4/tcp_*` tree is there, including `tcp_fastopen`,
`tcp_keepalive_*`, `tcp_low_latency`, `tcp_notsent_lowat` and `tcp_syncookies`.
if a long-lived mqtt or sse connection ever needs to detect a dead peer faster,
the knobs are `tcp_keepalive_time`/`_intvl`/`_probes`, and they are writable.

---

## syscalls that work, and that do not

by the address comparison described above. this is the definitive list for
anything the runtime might want to call.

**implemented:**

`mount` · `unshare` · `setns` · `ptrace` · `syslog` · `init_module` ·
`delete_module` · `memfd_create` · `timerfd_create` · `signalfd4` · `eventfd2` ·
`inotify_init1` · `epoll_create1` · `splice` · `fallocate` · `getrandom` ·
`prlimit64` · `sendmmsg` · `sendfile` · `mlockall`

**stubs — they return `ENOSYS`:**

`bpf` · `perf_event_open` · `seccomp` · `kexec_load` · `userfaultfd` ·
`keyctl` · `swapon` · `quotactl` · `fanotify_init` · `process_vm_readv` ·
`io_setup` (no aio)

the runtime currently uses `getrandom`, `epoll_create1`/`epoll_ctl`,
`signalfd` and `timerfd_create`. `inotify`, `memfd_create`, `mlockall` and
`splice` are available and unused.

---

## observability: there is none

this is the single most limiting thing about the kernel, and it is worth
stating plainly before anyone plans a debugging session around it.

| tool | present |
|---|---|
| ftrace / tracefs | no |
| tracepoints | no |
| kprobes / uprobes | no |
| perf events | no |
| ebpf | no |
| oprofile | no |
| kgdb | no |
| magic sysrq | no |
| lockdep / kmemleak | no |
| audit | no |

what is left: `/proc`, `/dev/kmsg`, `printk`, core dumps, and `ptrace`
(implemented, though there is no gdbserver on the device). `save_stack_trace`
and `kallsyms_lookup_name` exist, so the kernel can still symbolise its own
oops output.

practical consequence: **there is no way to profile or trace anything on this
device**. the runtime's own log ring and the `/api/v1` counters are not a
convenience, they are the entire observability story, which is why they earn
their memory.

---

## isolation and security primitives

| primitive | present | consequence |
|---|---|---|
| uid/gid | yes | the only real boundary the runtime has |
| posix capabilities | yes | `cap_capable`, `ns_capable` |
| **seccomp** | **no** | `CONFIG_SECCOMP=n` entirely — no `__secure_computing`, and `sys_seccomp` is a stub. a compromised parser cannot be confined by syscall filter |
| **cgroups** | **no** | no `/proc/cgroups`. no memory or cpu limits for any process |
| **namespaces** | mount only | `/proc/self/ns` contains `mnt` and nothing else. no pid, net, user, ipc or uts namespace. containers are impossible |
| selinux / apparmor / yama | no | no lsm at all |
| keyring | no | `sys_keyctl` is a stub |
| `kptr_restrict` | **0** | kernel pointers are readable from `/proc/kallsyms` by anyone who can read it |
| `dmesg_restrict` | 0 | |
| `modules_disabled` | 0 | unsigned modules can be loaded at runtime |
| `randomize_va_space` | present as a sysctl | |

so the runtime's split — `tc002-netd` and `tc002-berryd` dropped to uid 1001,
holding no authoritative state, relaying every command to the supervisor over a
unix socket — is not one defence among several. **it is the only isolation the
kernel offers.** there is no seccomp filter to fall back on, no namespace to
put netd in, and no cgroup to bound its memory. that design choice is recorded
in [`RUNTIME.md`](RUNTIME.md); this is the kernel-level reason it matters.

see [`SECURITY.md`](SECURITY.md) for the device's network-facing posture.

---

## drivers and device classes

| class | present | note |
|---|---|---|
| input / evdev | yes | the buttons and knob; see [button timing](#button-timing-the-buttons-are-polled) |
| **uinput** | **no** | input events cannot be synthesised from userspace. anything that wants to fake a button press must go through the runtime's own input layer, not the kernel |
| spi + spidev | yes | `/dev/spidev0.0`, the led path |
| gpio + sysfs export | yes | `gpiochip0`, **88 lines**, `gpiod_export` present |
| pwm | yes | `pwmchip0` and a `soc:backlight` node, both driving nothing |
| watchdog | yes | `/dev/watchdog`, major 253, `sstar,infinity-wdt` — **unused**, see below |
| framebuffer | yes | `/dev/fb0`, 640×480, connected to nothing |
| usb gadget | yes | `soc:Sstar-udc`, with `f_adb` and `f_hid` function drivers registered |
| usb host (ehci) | yes | irq 38 exists and has fired zero times |
| bluetooth (hci uart) | yes | `/dev/ttyS3` + `hciattach` |
| mmc/sdio | yes | carries the wi-fi chip; irq 42 is the busiest device interrupt in the system, ahead of the display vsync |
| mtd + mtdchar | yes | raw flash access |
| **i2c** | **no** | no i2c core in the kernel, and both device-tree nodes are `status = disabled` |
| **rtc** | **no driver** | see below |
| **alsa** | **no** | audio goes through sigmastar's proprietary `mi_ao` module, which is why `tc002-audiod` links `libmi_ao.so` |
| v4l2, iio, thermal, hwmon | no | no temperature sensor of any kind is exposed |
| cpufreq | compiled in, unbound | no driver attaches, so the two cores sit at a fixed 1.0 ghz |
| cpuidle | no | |

### the rtc nuance

[`DEVICE.md`](DEVICE.md) says there is no rtc, and as an observation that is
correct — `/dev/rtc*` and `/sys/class/rtc` do not exist, and time comes from
sntp on every boot. the kernel-level reason is more specific: the soc's rtc
block *is* described in the device tree and *is* enabled
(`sstar,infinity-rtc`, `status = ok`), but **no rtc driver was compiled in**, so
nothing ever binds to it. separately, `rtcpwc` — the always-on rtc in the power
controller, the one that would actually keep time across a power cut — is
`status = disabled`.

so a kernel rebuild might yield a working `/dev/rtc0`; whether it would survive
a power cycle is a different question this document cannot answer.

---

## button timing: the buttons are polled

worth its own section because it bounds the input work the runtime does.

```
compatible      = gpio-keys-polled
poll-interval   = 20 ms
debounce        = 5 ms  (per key)
keys            = up 103 (gpio 31), down 108 (gpio 32),
                  left 105 (gpio 33), right 106 (gpio 34)
```

those four gpio keys are **polled every 20 ms**, not interrupt-driven — and
they are not four face buttons. there are only three of those; the fourth key is
**the knob's press**, which the runtime maps to keycode 103
([`evdev.zig`](runtime/src/input/evdev.zig)). so the knob is split across two
mechanisms: its *press* is polled with the buttons, while its *rotation* is not.
`knob_a` and `knob_b` are real edge interrupts on `MS_GPI_INTC` (irqs 55 and 56)
and surface on a separate virtual input device, `knob_key`, which reports
`EV_ABS` only.

that asymmetry is the thing to remember: **turning the knob is edge-accurate,
pressing it is not.**

two consequences for the press/release/long-press handling in
[`runtime/src/input/actions.zig`](runtime/src/input/actions.zig):

- **every button edge is quantised to 20 ms**, and the timestamp on the event is
  when the poll ran, not when the contact moved. a long-press threshold is
  therefore accurate to ±20 ms at best, which is far below the threshold used,
  so it does not matter — but a "double click within 150 ms" gesture would be
  working with only ~7 samples of resolution, and should not be built on this.
- **a press shorter than ~20 ms can be missed entirely**, because press and
  release can fall between two polls. this is a hardware-level floor; no amount
  of care in userspace recovers it.

`/bin/getevent` is one of the few useful busybox-adjacent tools that *is* on
the device, and it prints raw evdev events — the quickest way to confirm a
keycode by hand.

the keycode mapping is documented in
[`runtime/src/input/evdev.zig`](runtime/src/input/evdev.zig); note that the
device tree's names (`key up`, `key left`) are wiring labels, not panel
positions.

---

## kernel services worth using, and not yet used

ranked by what they would actually buy this clock.

### 1. the hardware watchdog — `/dev/watchdog`

`sstar,infinity-wdt`, char major 253, `/sys/class/watchdog/watchdog0` present,
and **no process currently holds it open**. the supervisor already restarts
children that die; a hardware watchdog closes the remaining hole, which is the
supervisor itself wedging — the one failure the current design cannot recover
from without the user power-cycling the clock.

**this was deliberately not tested.** opening `/dev/watchdog` *starts* the
timer, and closing it without writing the magic `V` first leaves it armed, so a
careless probe reboots the user's clock some seconds later. the driver exposes
none of the usual sysfs attributes (`timeout`, `state`, `identity` are all
absent), so the timeout is unknown and would have to be read with
`WDIOC_GETTIMEOUT` by a process that is prepared to keep petting it.

### 2. `SCHED_FIFO` for the renderer — **tried, and it does not help**

this section used to say a modest rt priority on `tc002d` would cut frame
jitter. it was a guess, and measuring it showed it was wrong. it is left here
with the numbers because the reasoning looked sound and the next person will
have the same idea.

`sched_setscheduler` is implemented and rt throttling is configured at the
default 950 ms in every 1 s. the renderer was put on `SCHED_FIFO` at priority
10 (kernel-confirmed: `policy=1 rtprio=10` in `/proc/<pid>/stat`) with the rt
budget lowered to 900 ms for safety, and its wake latency measured against the
same scene before and after:

| | wakes >2 ms late, of ~615 | worst | mean |
|---|---|---|---|
| normal (cfs) | 33, 34, 70 | 5,026 µs | 278–530 µs |
| `SCHED_FIFO` 10 | 24–76 | 4,938 µs | 223–554 µs |

no difference at all. timing the two halves of a frame separately says why:

| per frame, plasma at 60 fps | mean | worst |
|---|---|---|
| drawing it | **95 µs** | 252 µs |
| handing it to the panel (latch, write, latch) | **4,999 µs** | 5,229 µs |

the renderer is not waiting for a cpu it could be given sooner — it is sitting
in one `write`, for **5 ms of every 16.7 ms frame period**. no scheduling
policy can help with that, which is exactly what the table above shows.

~~that is also twice what this repo assumed … where the other 2.5 ms goes has
not been looked at, and it is the single biggest lever on this device's frame
budget.~~

**✗ that was wrong, and it was wrong because the counter measures more than it
claimed.** `write_ns` wraps the whole of `spidev.writeFrame`, which is *gpio low
→ `nanosleep(1 ms)` → `write()` → `nanosleep(1 ms)` → gpio high*. so **2 ms of
the 5 ms is two deliberate sleeps** — the latch pulse LED-SPI.md prescribes — and
2.46 ms is the bus at 10 mhz. 2.0 + 2.46 + hrtimer wake overhead lands on the
5 ms measured. nothing is unaccounted for.

the lever is therefore not a mysterious driver cost. it is the question of
whether the panel mcu really needs a full millisecond on each edge of the latch,
which nobody has tested. that is a smaller and much better-defined target.
where the other 2.5 ms goes has not been looked at, and it is the single
biggest lever on this device's frame budget.

so the thing worth attacking is the frame delivery path, not the scheduler.
the option exists (`--rt-priority N`, off by default) and costs nothing when
unused, but nothing here has shown it earning its place.

### 3. the usb hid gadget — `f_hid`

`/sys/class/zkswe_usb/` registers both `f_adb` and `f_hid`, and
`/sys/class/zkswe_usb/zkswe0/functions` currently reads `adb`. the gadget's
function list is writable, and `hidg` is a registered char-device major (251).

that means the clock can plausibly present itself to a host computer as a **usb
hid device** — the knob becomes a volume wheel, the three buttons become media
keys. for a desk clock this is the most interesting unused capability in the
kernel.

> **✗ INCORRECT — corrected 2026-09-15.** this paragraph used to say the hid
> gadget was "genuinely untestable right now" because
> `/sys/class/udc/soc:Sstar-udc/state` reads `powered` with speed `UNKNOWN` and
> the gadget reads `DISCONNECTED`, **"because the pogo dock supplies vbus but no
> usb data host is attached"**.
>
> that reading of the symptom was wrong, and it is wrong in a way that cost
> hours later: the same `powered` + `DISCONNECTED` pair appeared with a laptop
> plugged straight into the usb-c port, and it sent the investigation chasing
> cables.
>
> **the replacement explanation was also wrong, and is corrected here
> (2026-09-16).** it said *"the otg controller boots in **host** mode ... one
> write of `usb_device` and a replug takes it to `CONFIGURED`"*. measured on two
> boots: the controller comes up in **device** mode and the gadget enumerates by
> itself at t≈2.7 s. (scoped 2026-09-19: that holds for a unit with a stored
> `sys_usb_mode_key`, which is what restores the role. a factory-fresh unit has
> none, so nothing undoes the walk below and it settles in `usb_host` with no
> gadget — see `DEVICE.md`.) the port then flips to host at t≈3.7 s and back at t≈6.8 s.
> that excursion — not the boot role — is what leaves a host holding a dead
> device object, and it happens before any of our code is loaded.
>
> **the "it is `/bin/zkgui` scanning for a firmware stick" half of that was in
> turn wrong, corrected 2026-09-16 from the disassembly.** the flip to host is
> this kernel's own `zkswe,sstar-otg` driver: its `usb-scan` kthread sleeps
> 3500 ms after probe and then walks the port device → null → host whenever the
> device-tree property `type` is `1`, which this board's built-in dtb sets. the
> return at t≈6.8 s is `libzkhardware.so`. so it cannot be prevented from
> userspace at all — only by patching the kernel.
>
> so the gadget is **not** untestable. adb over the cable is working and is
> documented in [`DEVICE.md`](DEVICE.md#adb), with the full timeline in
> [what happens to usb across a reboot](DEVICE.md#what-happens-to-usb-across-a-reboot).

hid itself is still untested, for a different and better reason: changing the
function list is mutative and would drop the `adb` function the deploy path
depends on, so it needs the device lock, a plan to recover over wi-fi, and the
user's say-so.

### 4. ble via l2cap/hci

bluez core, `l2cap` and `hci_uart` are compiled in and `/proc/net/hci` and
`/proc/net/l2cap` exist. gatt is reachable from userspace over an hci socket.
useful for presence detection (is a phone nearby → wake the panel) or reading
ble sensors. `rfcomm`, `bnep` and `hidp` are **not** present, so anything
needing classic bluetooth profiles is out.

### 5. suspend-to-ram and wakelocks

`/sys/power/state` offers `freeze mem`, and android-style `wake_lock` /
`wake_unlock` are exposed. on battery, suspending between minute ticks is the
only large power saving left after brightness. **high risk**: waking reliably
needs a wake source, the panel mcu holds its own state, and a failed resume on
a device whose only recovery is a power cycle is a bad trade. worth an
experiment, not worth assuming.

### 6. smaller ones, all present and unused

- **`inotify`** — watch `/data/tc002/state/config.json` and notice edits made
  outside the api.
- **pm qos** — `/dev/cpu_dma_latency`, plus `network_latency` and
  `network_throughput`. writing a latency bound keeps the cpu out of deeper
  idle states during frame delivery.
- **`/dev/kmsg`** — writable (`printk_devkmsg` is a sysctl). a line written here
  survives the writing process's death and is readable after a restart, which
  the runtime's in-memory log ring is not. a good place for the last words
  before an intentional shutdown.
- **core dumps** — `core_pattern` is `core` and writable. pointing it at
  `/tmp/core.%p` would capture a real crash of `tc002d`, which today leaves
  nothing behind but a supervisor log line. costs nothing until something
  crashes; `/tmp` is 16 mib of tmpfs, so cap it.
- **`memfd_create`** — anonymous, sealable buffers, no filesystem involved.
- **`mlockall`** — pinning the supervisor's pages against an oom-pressure stall.
  with no swap the benefit is small but not zero.
- **af_packet** — raw frames for arp-based presence detection or sending
  wake-on-lan magic packets to other machines.
- **gpio sysfs** — 88 lines, most unused, for anyone who opens the case.

---

## what the gaps cost, in one place

| missing | cost |
|---|---|
| netfilter | the clock cannot defend itself; put it on an iot vlan |
| ipv6 | ipv4-only forever, without a kernel rebuild |
| cgroups, namespaces, seccomp | uid separation is the whole sandbox |
| ftrace, perf, ebpf, kprobes | no profiling or tracing is possible at all |
| swap, zram | 35 mib is hard; the oom killer is the only backstop |
| nfs, cifs | no network filesystems; use http or fuse |
| rtc | time is sntp-only on every boot ([`DEVICE.md`](DEVICE.md)) |
| uinput | input cannot be synthesised; go through the runtime |
| i2c, alsa, v4l2, thermal, hwmon | no sensor bus, no generic audio, **no temperature reading anywhere** |
| cpufreq driver | fixed 1.0 ghz, no dvfs power saving |
| debugfs | nowhere for the debug interfaces that do not exist anyway |

---

## rebuilding the kernel, if it ever comes to that

not attempted, and the bar is high. what is known:

- module loading works and is not locked down (`modules_disabled=0`,
  `sys_init_module` implemented, kernel already tainted `4097`).
- a module must match the vermagic **exactly**:
  `4.9.84 SMP preempt mod_unload ARMv7 thumb2 p2v8`. that requires the matching
  sigmastar 4.9.84 source, the same `.config`, and openwrt gcc 9.1.0 — a
  mismatch in any of the four fields is rejected at load.
- the kernel itself lives in `mtd1` (`KERNEL`, 1.9 mib). replacing it means
  flashing, and `zkdaemon` restarts `zkswe` (it does **not** reflash anything
  itself — FIRMWARE.md) if `sys.zkapp.state` is
  not `running` within ~15 s of boot — see the boot chain in
  [`RUNTIME.md`](RUNTIME.md) before touching anything in flash.
- `/data` has 7.7 mib free and is the only writable place a module could live.

---

## see also

| topic | doc |
|---|---|
| hardware inventory — soc, dram split, flash map, panel, wireless | [`README.md`](README.md#hardware) |
| shell access, busybox limits, flashing, time | [`DEVICE.md`](DEVICE.md) |
| the custom runtime, its process split and boot chain | [`RUNTIME.md`](RUNTIME.md) |
| network-facing posture and threat model | [`SECURITY.md`](SECURITY.md) |
| the led frame path over spi | [`LED-SPI.md`](LED-SPI.md) |
