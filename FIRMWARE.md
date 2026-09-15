# Ulanzi TC002 — firmware images, the flasher, and what a persistent install needs

How the device's `update.img` is built, what the vendor flasher checks, how the
boot chain recovers (and fails to), and what has to change in the custom
runtime before it can be baked into flash. This is the groundwork for
replacing the volatile `/tmp` install described in [`RUNTIME.md`](RUNTIME.md)
with a rebuilt `res` partition delivered through the vendor's own update path.

> **adb over the usb cable works, 2026-09-15 — and it is the recovery route
> this whole effort needed.** It was an open question at the bottom of this
> file. The answer is yes, after one sysfs write.
>
> The vendor's `/etc/init.rc` (lines 124-128) configures the usb **gadget**
> fully — `idVendor 18d1`, `idProduct D002`, `functions` from `sys.usb.config`
> (`adb`), `enable 1` — and then never sets the **controller's** role, which
> boots `usb_host`. So the device sat there with a correctly configured adb
> gadget that no host could ever see: it was trying to be a host too. The
> symptom pair is worth remembering — `/sys/class/zkswe_usb/zkswe0/state` at
> `DISCONNECTED` while `/sys/class/udc/soc:Sstar-udc/state` says `powered`,
> which reads as "the cable is delivering power and no data session has ever
> started", and looks exactly like a charge-only cable.
>
> ```sh
> echo usb_device > /sys/bus/platform/devices/soc:usbotg/otg_role
> ```
>
> Within a second: gadget `CONFIGURED`, controller `configured`, high-speed, and
> the device appears on the host as `18d1:d002` "Zkswe", serial
> `0123456789ABCDEF`, alongside the network transport. macOS asks to approve
> the accessory once.
>
> **Verified as a recovery route**, which is the point: with `wpa_supplicant`
> stopped and `wlan0` down to no carrier and no address — the LAN transport
> gone, confirmed unreachable from the host — the usb shell stayed up, and the
> wifi was brought back *through it* with `tc002-netup.sh`.
>
> The supervisor now does this write at startup (`--usb-role`, default
> `device`). It has to, because the role is not persistent and nothing in the
> stock boot sets it. That means a flashed device whose network bring-up fails
> is still reachable with a cable.
>
> **A trap, paid for once.** The three files beside `otg_role` named
> `usb_device`, `usb_host` and `usb_null` are **actions, not values**: reading
> one performs that role switch. Reading all three to find out the current role
> left the port in `null` mode. Read `otg_role`; never read its neighbours.
> Note also that a write is accepted (exit 0) but ignored while a host is
> attached and the gadget is `CONFIGURED` — the driver will not tear down a
> live session.

> **Cold boot, simulated and passed, 2026-09-15.** The test this document has
> prescribed all along has now been run, and the wifi bring-up is no longer the
> one piece resting on reasoning.
>
> It matters more than it looked: **nothing in `/etc/init.rc` loads the aic8800
> driver** — the stock app does, and `wpa_supplicant` is a `disabled` init
> service. So a flashed runtime boots with no driver, no supplicant and no
> address, and netup's `insmod` step is not the no-op its comment allows for.
>
> The simulation tore the device down to exactly that state: udhcpc killed,
> `ctl.stop wpa_supplicant`, `ifconfig wlan0 0.0.0.0 down`, then `rmmod
> aic8800_fdrv` and `aic8800_bsp`, confirmed by `wlan0_exists=no`,
> `aic_modules=0`, no address. The supervisor was then started with
> `--netup-dir` and recovered **all of it in 6 seconds** — driver loaded,
> carrier up, DHCP lease from 10.0.0.1, default route — with the renderer ready
> 11 ms after spawn. From the host, exactly one ping was lost. The two further
> rungs of the safety net (a direct re-run, then handing back to the stock app)
> were never reached.
>
> The hand-back was verified in the same run: on `stop`, the supervisor killed
> the udhcpc daemon by its pidfile, which is the path that exists because
> busybox runs it under the process name "busybox".
>
> A first attempt did not test anything and is worth recording. Its success
> condition was "wlan0 has an address" — but an address **survives `ifconfig
> down`**, so the wait loop exited at zero seconds and declared victory while
> the link was still torn down. The condition is now address **and** carrier
> **and** a default route.

> **Paths, 2026-09-15: the last build-side gap closed.** `-Dbin_dir` sets the
> directory the runtime's binaries live in at runtime, and
> `tools/tc002-mkimage.sh` now builds the image with
> `-Dbin_dir=/res/bin -Dnetup=true`. The write side stays on `/tmp/tc002`,
> which is the point of the split: `/res` is a read-only squashfs, and while
> `--dir` meant both a runtime on flash would have tried to write its log into
> it.
>
> Two defects came out with it. All five child paths now resolve in one pure,
> tested place (`supervisor/cli.zig:resolve`); before, `netd` and `ntfy` were
> rebuilt from `--dir` at startup while `audiod` and `berryd` kept their
> compiled-in defaults, so moving the directory moved two of the four. And the
> image was being assembled without `tc002-audiod`, `tc002-berryd` or the two
> boot scripts at all — a flashed device would have failed at the exec the
> first time anyone enabled sound or scripting, and the bring-up would have had
> no script to run.
>
> The image is 4,444,160 bytes, 52% of the `res` partition, up from 47.8%
> before the two binaries, the scripts and the wider busybox. Still never
> flashed.

> **Boot machinery, parts three and four, 2026-09-15: the network and the panel.**
> `runtime/boot/tc002-netup.sh` and `tc002-udhcpc.script` are taken from
> aquarat's `5912865` unchanged; the supervisor gained `--netup-dir`, a
> re-run of the bring-up whenever the link is down, a pidfile-based stop for
> the udhcpc daemon on hand-back, and a **panel-ready gate** that exports gpio
> 35, sets it output and holds the first renderer spawn until `/dev/spidev0.0`
> and the gpio value file are both openable (20 s, then it spawns anyway and
> says so).
>
> Verified what can be: the gate runs on every start and the renderer comes up
> in 8 ms with no warning — on a warm path gpio 35 is already exported, so it is
> correctly a no-op — and both scripts parse under the ash we build. **Not
> verified: the bring-up actually running.** It restarts `wpa_supplicant` and
> replaces the dhcp client, and on this device adb *is* that link, so exercising
> it on a live system risks stranding the clock. Its real test is the cold boot
> it exists for. That makes this the one piece of the four resting on reasoning
> rather than a measurement.

> **Boot machinery, part two, 2026-09-15: yielding to the flasher.** The
> supervisor now checks `sys.zkupgrade.flag` and the image at
> `sys.zkupgrade.dir` (default `/mnt/storage`) before it takes anything, and
> when an upgrade really is pending it writes a `/tmp/EasyUI.cfg` with **no**
> `startupLibPath` and exits, so init's restart of `zkswe` reaches
> `checkUpgrade` and the vendor flasher runs. Verified on the device both ways,
> with a deliberately invalid image so nothing could be flashed: flag set with
> no image → `taking the panel anyway` and the runtime started; flag set with an
> image present → `standing aside so the vendor flasher can run`, the supervisor
> exited, and the config it left behind had no app library in it.
>
> One device fact this turned up, which cost an hour: **`getprop` finds the
> property area through `ANDROID_PROPERTY_WORKSPACE`** (`8,32768` here, an
> already-open fd onto `/dev/__properties__`). Run with an empty environment it
> prints nothing and **exits 0**, which is indistinguishable from a property
> that is not set. `setprop` is unaffected — it uses the property-service
> socket. Also worth knowing: the **stock app consumes a pending upgrade flag**,
> so any test that lets it run first will find the flag already cleared.

> **Boot machinery, part one, landed 2026-09-15: the recovery net.** The
> boot-failure counter and the stock-config fallback are implemented in
> `runtime/src/sys/recovery.zig`, armed by the bootstrap and cleared by the
> supervisor after 60 s of healthy running. **Verified on the device through the
> real loader**, using `tc002-boot-experiment.sh` so the vendor app was always one
> power cycle away: a bootstrap-led boot took the counter 0 → 1 and started the
> runtime; with the counter forced to 3 the bootstrap wrote the stock
> `/tmp/EasyUI.cfg`, exited, and **the vendor app came up instead of the runtime**
> (`startupLibPath = /res/lib/libzkgui.so`, no tc002 processes); and a healthy boot
> cleared a seeded count of 2. The other three items below — yielding to a pending
> upgrade, cold-boot wifi, and the gpio-35 panel gate — are **not done**, so this
> is still not a flashable tree.

> **Adopted from aquarat's fork (`c069a48`) on 2026-09-15, and re-verified here
> before it was taken.** Against the vendor `update.img` pulled from this unit's
> `/mnt/storage`: `inspect` passes every check (header crc32 `0xe6bd4276`,
> device code `0xaa550606` → `Zkswe_SSD21X_SPINOR`, payload md5
> `021d1589…`), and `unpack` then `pack --template` reproduces the vendor image
> **byte for byte**. The payload it extracts is also byte-identical to the one
> an independently written reader extracted here, which is what settled that the
> container layout below is right rather than merely self-consistent — the first
> 16 bytes of the `res` squashfs really are moved into the header and replaced
> by the md5 of the whole payload. Still nothing flashed.

Everything here was established on 2026-09-12 against the unit described in
[`DEVICE.md`](DEVICE.md) (`Zkswe_SSD21X_SPINOR`, app 1.1.1, kernel 4.9.84
build #1624) by pulling the binaries over adb and disassembling them with
radare2, then recomputing every checksum against the vendor's own image. The
device was only read from; the one thing run on it was a static busybox
telnetd in `/tmp`, removed afterwards. Nothing was flashed. **A custom image
has not been flashed yet**; the [first-flash plan](#first-flash-plan) says how
to do it with the least risk.

The tool that goes with this document is
[`tc002-update-img.py`](tc002-update-img.py): `inspect` verifies an image the
way the device does, `unpack` extracts the squashfs, `pack` builds a new image.
It reproduces the vendor's `update.img` byte for byte from its own payload.

---

## The pieces on the device

| path | what | size |
|------|------|-----:|
| `/bin/zkgui` | the `zkswe` init service: a thin loader linking `libeasyui.so`, `libzknet.so`, `libzkupgrade.so`, … | 9.5 kb |
| `/lib/libeasyui.so` | the ui framework; reads `EasyUI.cfg`, `dlopen`s the app library, owns `UpgradeMonitor` | 823 kb |
| `/lib/libzkupgrade.so` | **the flasher**: parses `update.img`, writes the mtd, reboots | 55 kb |
| `/lib/libzknet.so` | wifi and **the dhcp client**, as threads inside the loader process | 141 kb |
| `/bin/zkdaemon` | init service (`class main`, oneshot): the boot watchdog and the reset key | 14 kb |
| `/mnt/storage/update.img` | a vendor image on the `UDISK` vfat partition (mtd7) | 2.7 mb |
| `/mnt/storage/zkupgradetipbin` | the upgrade progress animation; opens `/dev/spidev0.0` and the latch gpio, so it draws on the panel | 9.6 kb |
| `/res` (mtd3) | the squashfs the image replaces: `etc/EasyUI.cfg`, `lib/libzkgui.so` (7.4 mb uncompressed), bt tools, web ui, fonts | 2.7 mb compressed of 8 mib |

There is no `/bin/zkupgradebin`, no `zkupgrade` init service and no
`/etc/EasyUI.cfg` on this rootfs, although `zkdaemon` has code paths for all
three (dead on this device). `/init.rc` is `/etc/init.rc`.

Two things the existing docs got slightly wrong, corrected here:

- `zkdaemon` does not reflash anything itself. When the app has not raised
  `sys.zkapp.state=running` it sets two properties and restarts `zkswe`, and
  the loader's own upgrade check does the flashing, only if an `update.img` is
  present (details [below](#zkdaemon-the-boot-check-and-the-reset-key)).
- The usb gadget on this unit is configured as **adb**
  (`/sys/class/zkswe_usb/zkswe0/functions` = `adb`, `persist.sys.usb.config=adb`,
  vid:pid `18d1:d002`), not mass storage. Whether adb over the usb cable
  actually works was not tried; the vendor docs say it does not for wifi
  models, but the gadget configuration says otherwise. Worth testing, because
  it would be a recovery channel that does not depend on wifi.

The vendor image on the udisk is a **newer build (8 June 2026) than the
flashed `res` (5 June 2026)**: `lib/libzkgui.so` and `ui/web/uclockSocial.html`
differ, everything else is identical. The stock app's ota code downloads to
`/tmp/update.img` and copies `zkupgradetipbin` to `/tmp` (strings
`otaPendingAppMd5`, `OTA: resume pending app update`), so the udisk copy is
probably a staged or factory image rather than what the ota flow uses.

---

## The `update.img` container

A 572-byte header, then the partition image. The first 16 bytes of the image
are moved into the header and their place is taken by the md5 of the whole
image, so the payload is not a valid squashfs until those bytes are put back.
All fields little-endian. Offsets are file offsets.

| offset | size | field | in the vendor image | checked by the flasher? |
|-------:|-----:|-------|---------------------|-------------------------|
| `0x000` | 16 | magic `ZKSWEV1.0-180127` | | **first 9 bytes only** (`memcmp(…, "ZKSWEV1.0", 9)`); the date tail is ignored |
| `0x010` | 1 | prefix length, `0x30` | 48 | used as the read length |
| `0x011` | 1 | entry count | 1 | **yes**, loop bound |
| `0x012` | 1 | info-block offset, `0x30` | 48 | used as an `lseek` |
| `0x013` | 1 | reserved | `0x23` | no |
| `0x014` | 28 × n | partition entries, one per image (see below) | one entry | |
| `0x030` | 4 | info-block length, `0x20c` | 524 | no (the read length is hard-coded) |
| `0x034` | 1 | ? | `0x02` | no |
| `0x035` | 4 | **device code** | `0xaa550606` | **yes**: must equal the model table's value for `ro.product.model` |
| `0x039` | 1 | **device flag** | `0` (means `0xf1`) | **yes**: `0` maps to `0xf1` (spi-nor); `0xf4` is emmc |
| `0x03a` | 1 | ? | `0` | no |
| `0x03b` | 509 | opaque | pseudo-random | no; never dereferenced by the linux flasher, only covered by the crc. possibly for u-boot |
| `0x238` | 4 | **header crc32** | `0x2865ffb1` | **yes**: standard zlib crc-32 over `file[0:0x238]` |
| `0x23c` | 16 | **md5 of the whole padded image** | | **yes**, before writing; and again read back from the mtd after writing |
| `0x24c` | … | image bytes 16 onwards | | |

A partition entry (28 bytes, at `0x14 + 28·i`):

| offset | size | field | vendor image |
|-------:|-----:|-------|--------------|
| `+0x00` | 1 | **partition index** (must be ≤ 8): the index into the device's mtd table, so `3` = `res` | 3 |
| `+0x01` | 3 | reserved | `10 60 6c` |
| `+0x04` | 4 | payload offset in the file | `0x23c` |
| `+0x08` | 4 | image size (padded to 4 KiB) | `0x2a5000` |
| `+0x0c` | 16 | the image's original first 16 bytes | `hsqs …` |

The header for one entry is therefore `16 + 4 + 28 + 524 = 572` bytes; more
entries push the info block along. Multi-partition images are supported by the
parser, but only the single-`res` form has been seen and reproduced.

The model table in `libzkupgrade.so` (14 rows of name, code, flag) gives
`Zkswe_SSD21X_SPINOR` → `0xaa550606`, `0xf1`; the full table is in
`tc002-update-img.py`.

**What is not checked:** no signature, no version, no date, no partition name.
The "ts" (touch panel) type/version/pixel gates in the flasher apply only to
the separate `full_update.zk` path. A home-built image is accepted when the
magic, device code, header crc and payload md5 are right and the image fits
the partition.

Proof: `tc002-update-img.py pack --template update.img` on the unpacked
payload reproduces the vendor file byte for byte; `pack` without a template
(constants in the unchecked bytes) passes every check `inspect` reproduces
from the disassembly. Evidence lives at these addresses in `libzkupgrade.so`
(file offsets, radare2 names): header parser `fcn.000054a4` (called from
`zk_upgrade_check`), md5 check `fcn.00004fc0`, mtd writer `fcn.00005a9c`,
read-back verify `fcn.000050f0`, crc-32 `fcn.00008fd8`, model table at
`0x1c958`.

The squashfs itself: 4.0, xz, 128 KiB blocks, exportable, one uid/gid
(1000). The `res` tree is owned by uid 1000 with mode `0770`; keep that when
repacking (`mksquashfs … -comp xz -b 128K -noappend`).

---

## The flasher (`libzkupgrade.so`)

Four exported entry points, called in this order by `libeasyui`'s
`UpgradeMonitor`:

1. **`zk_upgrade_check(const char *dir)`** reads `sys.zkupgrade.dir`,
   `sys.zkupgrade.flag` and `sys.zkupgrade.force`, scans `dir` for
   `update.img` (also `zkimg/update.img`, `full_update.zk`, `extupdate.img`,
   `ts.cfg`, logo files), parses the header, matches the device, lists the
   flashable entries. Returns `1` for nothing to do. It also removes
   `/data/.zkupgraderec` if present (a one-shot "an upgrade just ran" marker,
   not a rollback record).
2. **`zk_upgrade_ready()`** rewrites `/tmp/EasyUI.cfg` **without
   `startupLibPath`**, `lowMemMode` and `font`, and, unless the environment
   variable `ZK_UPGRADE_RESTART=1` is set, sets the two properties and
   `ctl.restart zkswe` so that the loader comes back with no application
   library and runs the upgrade ui clean. On the second pass it proceeds.
3. **`zk_upgrade_perform()`** copies `zkupgradetipbin` to `/tmp` and runs it,
   sets `sys.zkapp.state=running` (so `zkdaemon` stays quiet), stops
   `wpa_supplicant` and friends, drops caches, then per entry: md5 check
   ("img md5 check err!!!"), size check against the mtd ("imgSize > mtdSize
   error"), `SecurityManager::unlockWriteProtect`, **erase and write the mtd
   directly**, read back and md5 again, up to five attempts. Entries flagged
   for u-boot (the rootfs, partition index 2) are not written; the library
   writes a `uboot:BOOT:BOOT0` hand-off and reboots with `reboot /Zk2Updi`
   instead. **`res` (index 3) is written from linux**, no u-boot involved.
4. **`zk_upgrade_end(int)`** waits for `sys.zkupgrade.umount` if configured,
   logs `upgrade success, will reboot system!`, and reboots.

`sys.zkupgrade.flag=255` is what `zk_upgrade_ready` itself writes for a
normal full upgrade, which is why the vendor recipe uses it. The "ab ota"
exports (`zk_abota_*`) target an emmc by-name layout and are never called on
this spi-nor device: **there is no a/b slot and no automatic rollback**.

A standalone program could drive the flash without the ui by linking the
library: `setenv ZK_UPGRADE_RESTART=1`, then `zk_upgrade_check(dir)`,
`zk_upgrade_has_select_item()`, `zk_upgrade_ready()`, `zk_upgrade_perform()`,
`zk_upgrade_end(result)`. The non-`1` return encodings were not mapped. The
simpler alternative is to make sure the stock loader still gets to run the
upgrade, see [the bootstrap must yield](#1-the-bootstrap-must-yield-to-a-pending-upgrade).

---

## `zkdaemon`: the boot check and the reset key

Pseudocode recovered from the binary (`main` at `0x10be4`, the key thread at
`0x11848`, `do_recovery` at `0x114c0`):

```
main:
    start key_monitor thread
    sleep(getenv("ZK_APPCHECK_DELAY") or 15)          # seconds, once; it is not a poll
    if getprop("sys.zkapp.state") == "running": join the key thread forever
    else: log "Auto recovery triggered"; do_recovery()

key_monitor:
    export gpio 2 as an input; poll it every 10 ms
    held for 5000 ms -> setprop ctl.stop zkswe; rm -rf /data/*; sync; do_recovery()
    (released earlier -> "Key released early", ignored)

do_recovery (runs once):
    dir = getprop("persist.zkupgrade.dir") or "/mnt/storage"
    if exists dir/update.img:
        setprop sys.zkupgrade.dir <dir>; setprop sys.zkupgrade.flag 255; setprop ctl.restart zkswe
        # (a branch through /bin/zkupgradebin + "ctl.restart zkupgrade" exists but neither is on this device)
    else:
        # no image: reset the app configuration for this boot only, no flash
        cp /etc/EasyUI.cfg /tmp/EasyUI.cfg            if it exists (it does not here)
        else echo {} > /tmp/EasyUI.cfg                if /lib/libzkext.so exists (not here)
        else setprop sys.zkapp.state running; cp /res/etc/EasyUI.cfg /tmp/EasyUI.cfg
        setprop ctl.restart zkswe
```

So both recovery triggers end in **restarting `zkswe` with the upgrade
properties set** and rely on the loader to do the work. The reset button
also wipes `/data` (settings, wifi credentials, and the runtime's state
directory), which is what "factory reset" means on this device. The boot
check is a single 15 s timer, not a watchdog: a runtime that raises the
property once and later dies is not caught by it. Both paths use
`setprop ctl.restart zkswe`, which [`DEVICE.md`](DEVICE.md#adb) found this
init ignores from an adb shell; whether it works from `zkdaemon` was not
tested, and if it does not, the recovery paths end with the app merely
stopped until the next boot. `ctl.stop` then `ctl.start` is the sequence
that is known to work.

---

## The loader's order of operations, and why it matters

`zkgui`'s `main` waits for the display and `/data`, starts
`HardwareManager`, starts `NetManager` (wifi association and **the dhcp
client, both as threads inside this process**), then calls
`EasyUIContext::initEasyUI()` → `runEasyUI()`. Inside `initEasyUI`:

1. `initLib`: read `EasyUI.cfg` (`/tmp` first, then `/res/etc`),
   **`dlopen(startupLibPath)`** at `libeasyui.so:0x71784`, `dlsym` three entry
   points.
2. Then, still in `initEasyUI`, the boot-time **`UpgradeMonitor::checkUpgrade()`**
   which calls `zk_upgrade_check` on three fixed directories.
3. `runEasyUI` calls the app's startup entry, then
   **`UpgradeMonitor::startMonitoring()`**, which registers a mount listener:
   a usb stick or sd card being mounted by `vold` runs `zk_upgrade_check` on
   the new mount.

The custom bootstrap's constructor `execve`s the supervisor **during step 1**.
Consequences once that is in flash:

- steps 2 and 3 never run, so **every vendor reflash route is dead**: the
  reset key, the boot check, the `flag=255` recipe and the udisk/usb/sd
  routes all restart `zkswe`, which hands over to the runtime again before
  it looks for an image.
- the dhcp client thread dies with the exec. At a warm takeover the lease
  already exists (which is why the `/tmp` experiments worked); **at a cold
  boot the exec happens milliseconds after `NetManager::start`, before any
  address is obtained**, so the device would come up associated but
  addressless: no api, no adb, no way in except the reset key.

Neither is a problem for the volatile install (a power cycle restores
everything); both must be fixed before anything is flashed.

---

## What a persistent runtime needs

### 1. The bootstrap must yield to a pending upgrade

Before exec'ing, the bootstrap (or the supervisor, before it does anything
else) must check whether an upgrade is pending: `sys.zkupgrade.flag` set and
`<sys.zkupgrade.dir or /mnt/storage>/update.img` present. If so, it must
**not** take over. The cleanest way, given the loader's behaviour: write a
`/tmp/EasyUI.cfg` without `startupLibPath` and exit the process; init
restarts `zkswe` about a second later, the loader reads the `/tmp` config,
finds no app library, runs `checkUpgrade`, and the flasher takes it from
there (`zk_upgrade_ready` would have produced exactly that config itself).
Reading a property from a no-libc binary means running `/bin/getprop` with a
pipe, which the supervisor already does for `setprop`. Keeping the stock
`libzkgui.so` in the image is not needed for this, but it costs little
(about 2.5 mb compressed of the 5.3 mb spare) and makes "back to stock" a
one-line config change over adb instead of a reflash. Recommended for the
first images.

### 2. Network bring-up at cold boot

The supervisor has to own the address. `wpa_supplicant` is an init service
(`disabled, oneshot`) that the loader starts with `ctl.start`; by the time
the bootstrap runs it is normally already started, but the supervisor should
start it if `init.svc.wpa_supplicant` is not `running`. Then a dhcp client:
the easiest is a static busybox in the image and
`busybox udhcpc -i wlan0 -s <script>` with a script that runs `ifconfig`,
`route` and `setprop net.dns1` (the device's own busybox has `ifconfig` but
no `route`; the static one has both). Renewal is then busybox's problem. The setup-ap flow (`U-Clock` hotspot, `hostapd` +
`dnsmasq`) is not reproduced and a device with no stored credentials would
need the stock image again.

### 3. Paths — **done** (2026-09-15)

`-Dbin_dir` sets where the binaries are; `-Dnetup` says whether this build
brings wifi up itself. The bootstrap's exec target follows `bin_dir`, and
`--bin-dir` overrides it at runtime for experiments. `/tmp/tc002` stays the
writable directory for the log, the lock and udhcpc's pidfile; the binaries
live in `/res/bin` and the bootstrap in `/res/lib`.

The reason this had to be a build option rather than a flag: the bootstrap
execs the supervisor with only `--from-bootstrap`, and the supervisor spawns
its five children by absolute path. **A flashed runtime never sees a
command-line argument in its life**, so every path it uses is the one compiled
in.

### 4. Battery — **done**, and this section was stale

The stock app polls the mcu and powers the device off below 3550 mv. This said
the runtime never powers off; it has since `supervisor/power.zig`, which uses
the stock firmware's own numbers — `battery.shutdown` (default on),
`battery.shutdown_mv` (default 3550), `battery.grace_s` (default 30), with the
warning band at `shutdown_mv + 50`. See
[the low-battery shutdown](RUNTIME.md#the-low-battery-shutdown).

What is still true is the caveat in `RUNTIME.md`: the behaviour has not been
watched through a real discharge.

### 5. A shell that survives the stock app's absence

adbd keeps running (it is an init service gated on `persist.sys.zkdebug`),
so the dev profile keeps root adb. In addition:

- **telnet** works today with no changes to the runtime: the static armv7
  busybox from the docker image `busybox:musl` (1 mb, `static-pie`, runs on
  this kernel) was pushed to `/tmp` and `busybox telnetd -p 2323 -l /bin/sh`
  gave a root shell from the lan (`MemAvailable` stayed at 13.5 mb). The
  binary must be named `busybox` (it selects the applet by `argv[0]`), and
  `killall telnetd` does not find it (the process name is `busybox`); kill
  by pid. The supervisor would spawn it like it spawns netd. It is
  unauthenticated; the panel lock, the hardened profile's gesture, or a
  password via `login` are the options.
- **ssh** needs dropbear built static for `arm-linux-musleabihf`; `zig cc`
  can do that inside the same build (zig is already the toolchain), so no
  separate cross-compiler is needed. A host key must persist under
  `/data/tc002/state`. Debian's `dropbear-bin` for armhf will not run:
  it links a newer glibc than the device's 2.30.
- **sftp/scp** is not in busybox; `adb push` or dropbear's scp.

---

## Recovery routes, verified and not

| route | status |
|-------|--------|
| root adb over wifi, kill the supervisor, rewrite `/tmp/EasyUI.cfg`, flash or restore | **works as long as the runtime keeps adbd up and has an address** (dev profile, and item 2 above). the volatile experiments used it throughout |
| the vendor flasher via the reset key or the `flag=255` recipe | **works only if the loader reaches `checkUpgrade`**, i.e. after item 1 above. with the current bootstrap it does not |
| an `update.img` on the udisk read through `zkdaemon` (`persist.zkupgrade.dir` defaults to `/mnt/storage`) | same condition; and the udisk is mounted read-only from linux, so the image gets there over usb from a pc (if the gadget is switched to mass storage by something) or by `mount -o remount,rw` as root. neither was tried |
| u-boot flashing from the udisk (`reboot /Zk2Updi`, `uboot:BOOT:BOOT0`) | **not tested**; only seen in strings. would be the one route independent of linux |
| serial console on `ttyS0` | pads not located; case not opened |
| adb over the usb cable | **works**, and is independent of wifi — verified with the lan transport down. needs `otg_role` set to `usb_device`, which the supervisor now does at startup; nothing in the stock boot does |

The takeaway: until items 1 and 2 are done, the only recovery from a bad
`res` image is the reset key **plus** a working loader, which the bad image
itself may have taken away. Do not flash a runtime image before those two
changes exist and have been exercised from a cold boot on the volatile path
(kill `wpa_supplicant` and `ifconfig wlan0 down` first to simulate it; a
power cycle is the way back if it fails).

> **2026-09-15.** Items 1 and 2 exist, and **the cold-boot simulation has now
> been run and passed** on the volatile path — driver, supplicant and address
> all removed, everything back in 6 s. The condition in that paragraph is met.
> See the note at the top of this file for what was torn down and what came
> back.

### The mtd nodes do not exist in `/dev`

`/proc/mtd` lists all eight partitions and `/proc/devices` has `mtd` (char 90)
and `mtdblock` (block 31), but **there are no `/dev/mtd*` or `/dev/mtdblock*`
nodes**. Nothing on the device can read or write a partition until they are
made:

```sh
busybox mknod /dev/mtdblock3 b 31 3     # block, for reading a partition out
busybox mknod /dev/mtd3      c 90 6     # char, minor 2*N, what flashcp wants
```

They live in a tmpfs `/dev` and do not survive a reboot. This is why `flashcp`
being in our busybox is necessary but not sufficient, and it is worth knowing
before a flash rather than during one.

Taking a verified backup of the running device is then:

```sh
busybox dd if=/dev/mtdblock3 of=/tmp/res-live.sqsh bs=1024 count=2730
adb pull /tmp/res-live.sqsh && adb shell busybox rm -f /tmp/res-live.sqsh
unsquashfs -d live-res res-live.sqsh    # it must unpack, and hold lib/libzkgui.so
```

### The vendor image we hold is **not** what is on the device

Compared on 2026-09-15. The `res` on the unit and the payload of the
`update.img` in hand are different vendor releases:

| | on the device | our `update.img` |
|---|---|---|
| squashfs inodes | 234 | 233 |
| mkfs timestamp | `0x6a882f3d` | `0x6a3f2ed7` (≈ 55 days older) |
| bytes used | 2,787,758 | 2,779,578 |

`lib/libzkgui.so` and three `ui/web/*.html` pages differ in content; the device
additionally has `ui/app_icons/tools_focus_clock.png` and
`ui/font_image/t_9_L.png`, and lacks `ui/font_image/t_10_L.png`. That is a
vendor revision, not a modification by anything in this repository — nothing
here writes to `/res`, and nothing here would add a focus-clock icon.

Two consequences, both of which matter more than they look:

1. **Feed `tc002-mkimage.sh` the device's own dump, not the downloaded image.**
   The script takes either (an mtd3 dump reads the same way). Built from the
   older `update.img`, the result would quietly downgrade the vendor app and
   the UI resources — including the `libzkgui.so` that the recovery net hands
   back to, which is the one file that has to be right when everything else has
   gone wrong.
2. **The way back has to be the device's own partition.** A downloaded image of
   a different release restores a working clock, but not *this* clock.

---

## The build (the planned Dockerfile)

Nothing here has been run yet; it is the plan the findings support. The
inputs are the repository, a vendor `update.img` (or a dump of mtd3: `cat
/dev/block/mtdblock3 > /tmp/m.bin` on the device, `adb pull`), and nothing
else. Steps:

1. `FROM debian:bookworm`, install `squashfs-tools` (xz support is in the
   package), `python3`, `curl`, `xz-utils`.
2. Fetch zig **0.16.0** for the build host (`build.zig` refuses any other
   version): `https://ziglang.org/download/0.16.0/zig-<arch>-linux-0.16.0.tar.xz`,
   sha256 `ea4b09bf…534f17` for aarch64, `70e49664…ba3d00` for x86_64 (the
   index at `ziglang.org/download/index.json` is authoritative).
3. `zig build -Dsupervisor_path=/res/bin/tc002-supervisor -Doptimize=ReleaseSafe`
   in `runtime/`; `zig build check` for the bootstrap's elf sanity.
4. Unpack the vendor image: `tc002-update-img.py unpack update.img res.sqsh`,
   `unsquashfs -d res res.sqsh` (as root, to keep uid 1000 and the modes).
5. Edit `res/etc/EasyUI.cfg`: `startupLibPath` → `/res/lib/libtc002-bootstrap.so`.
   Add `res/bin/tc002-supervisor`, `tc002d`, `tc002-netd`, `tc002-ntfy`,
   `res/lib/libtc002-bootstrap.so`, `res/bin/busybox` (and `dropbear` if
   built). Optionally delete what is not wanted: `ui/` (web ui, icons,
   fonts), `bin/gattserver*`, `bin/hci*` (the `hciattach` service in
   `init.rc` points at `/res/bin/hciattach` and would fail harmlessly if it
   goes; leave it in the first images).
6. `mksquashfs res res-new.sqsh -comp xz -b 128K -noappend`, run as root so
   the stock ownership (uid/gid 1000, mode 0770) is kept. The loader runs as
   root, so `-all-root` would work too, but stay identical to stock until
   there is a reason not to.
7. `tc002-update-img.py pack res-new.sqsh UPDATE.img --template update.img`
   then `tc002-update-img.py inspect UPDATE.img` as the build's own check.

Size budget (compressed, xz): stock `res` 2.7 mb, of which `libzkgui.so` is
about 2.5 mb; runtime binaries about 2.3 mb uncompressed (ReleaseSafe; the
ntfy client is half of it) and roughly half that compressed; busybox 1 mb
uncompressed. Everything, stock app included, fits the 8 mib partition with
room to spare; `pack` refuses an image larger than the partition.

The wasm preview and the host tools are not part of the image.

---

## First-flash plan

1. **Rehearse with a no-op image.** Pack the flashed partition's own
   squashfs (mtd3 dump, first 2 771 146 bytes; or the vendor image's payload)
   into a new `update.img` with `pack` and no template. Flash it with the
   vendor recipe over adb:

   ```bash
   adb push UPDATE.img /tmp/update.img
   adb shell setprop sys.zkupgrade.flag 255
   adb shell setprop sys.zkupgrade.dir /tmp
   adb shell "setprop ctl.stop zkswe; setprop ctl.start zkswe"
   ```

   The panel should show the progress animation and the device reboots
   itself. This exercises the header, the md5, the mtd write and the
   read-back with content that cannot change behaviour, and it proves the
   `ctl.stop`/`ctl.start` sequence reaches `checkUpgrade`. Confirm with
   `adb shell cat /proc/version` and `getprop ro.build.date` afterwards, and
   `md5sum` of `/dev/block/mtdblock3` against the padded squashfs.
2. **Then the runtime image**, dev profile (adbd stays on), stock
   `libzkgui.so` kept, after items 1 and 2 above exist and the cold-boot
   simulation on the volatile path has passed.
3. Keep the vendor `update.img` and the mtd3 dump somewhere safe; they are
   the way back and they are not in this repository (they are Ulanzi's).

---

## Host notes

- On linux, `adb` is `android-tools` (fedora: `sudo dnf install android-tools`);
  `adb connect <ip>:5555` works without pairing. The device's adbd has no
  `exec-out`, so binary output goes through files and `adb pull`.
- Raw partition dumps: the block nodes are `/dev/block/mtdblockN` (not
  `/dev/mtdblockN`); `cat` into `/tmp` (16 mib tmpfs, so one partition at a
  time) and pull. Character nodes `/dev/mtd/mtdN` exist too.
- The device shell has no `grep`, `sleep`, `id`, `md5sum`; pushing the
  static busybox to `/tmp` for a session gives all of them.
- A static armv7 busybox: `docker pull --platform linux/arm/v7 busybox:musl`,
  `docker create`, `docker cp <id>:/bin/busybox .`. busybox.net's binary
  directory has no arm builds.
- Disassembly: `radare2` (`r2 -q -e scr.color=0 -c 'aaa; afl; iz; axt @ str.x; pdf @ fn' lib.so`)
  and `binutils-arm-linux-gnu` for `arm-linux-gnu-objdump`. The libraries
  are stripped of local symbols but keep their exports, and the log strings
  name most functions.

---

## Open questions

- What the 509 opaque header bytes and the three reserved entry bytes mean
  (u-boot? a build id?). Not needed for the linux flasher.
- Whether u-boot flashes `update.img` from the udisk on its own, and how the
  udisk is written from a pc on this unit (the gadget is `adb`, not mass
  storage, as configured today).
- The exact partition entry flag that routes an image to u-boot rather than
  the mtd writer; only `res` (index 3, direct) and `rootfs` (index 2, u-boot)
  were traced.
- The loader's three fixed upgrade directories and the config path literals
  are stored obfuscated in `libeasyui.so`'s data and were not recovered; the
  behaviour (`/tmp` before `/res/etc`, `/mnt/storage`, `/mnt/usb1`,
  `/mnt/extsd`) is known from the other binaries and from the vendor docs.
- Cold boot: the timing between `NetManager::start`, the `dlopen` and
  `zkdaemon`'s 15 s check has not been measured on a real cold boot, only
  inferred from the code.
