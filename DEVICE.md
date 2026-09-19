# Ulanzi TC002 — device internals, shell and adb

What the TC002 is running, how to get a root shell on it, and how to flash or
recover it. The local API is in `HTTP-API.md`.

Device under test: `appVer 1.1.1`, `mcuVer V1.0.17`.

> Identifiers (serial, MAC, SSID) are replaced with placeholders.
> Substitute your own from `GET /getBase`.

---

## Device summary

The TC002 runs **Linux on a SigmaStar SSD21x SoC** (`ro.product.model` is `Zkswe_SSD21X_SPINOR`, which is where the "Z21" in earlier drafts came from) — not Android, and not the ESP32
of the TC001. Development is via the FlyThings IDE (C++, Windows-only).

It exposes two useful local interfaces with **no authentication**:

| Port | Service | Notes |
|-----:|---------|-------|
| 80   | HTTP settings API | unauthenticated read/write of all config — see `HTTP-API.md` |
| 5555 | `adbd` | wifi adb. adb over the **usb cable** also works, after one sysfs write — see [adb](#adb) |

It also phones home to `api.ulanzistudio.com` over **plain HTTP** for weather,
social counts, calendars and the update check — see `CLOUD.md`.

---

## Device internals

The full hardware inventory (SoC, clock, DRAM split, flash map, the pixel MCU,
wireless chip, inputs, audio, power) lives in the
[README's hardware section](README.md#hardware). The short version:

| | |
|---|---|
| SoC | SigmaStar SSD21x "Pioneer3", 2 × Cortex-A7 at a fixed 1.0 GHz (`Zkswe_SSD21X_SPINOR`) |
| Kernel | Linux 4.9.84 SMP PREEMPT, built with OpenWrt GCC 9.1.0. What it was and was not built with — no NFS, no netfilter, no IPv6, no tracing — is in [`KERNEL.md`](KERNEL.md) |
| RAM | 64 MB in-package; ~35 MB left for Linux after the media-heap and framebuffer reservations |
| Flash | 32 MiB SPI NOR, eight MTD partitions |
| Root fs | squashfs, 3.5 MB, **read-only** |
| `/res` | squashfs on `mtdblock3`, 2.8 MB, **read-only** (UI assets, fonts, certs) |
| `/data` | jffs2, 8 MB, **read-write and persistent** |
| `/mnt/storage` | vfat on `mtdblock7`, 8.5 MB, **read-only** (holds `update.img`) |
| `/tmp`, `/mnt`, `/misc` | tmpfs, volatile |

Userspace processes: `init`, `ueventd`, `vold`, `logd`, `adbd`, `wpa_supplicant`,
and the FlyThings stack — `zkdaemon`, `zkdisplay`, `zkgui` (the app runtime that
drives the display; it is the init service `zkswe`, and how it pushes pixels to the
led matrix over spi is in `LED-SPI.md`).

`/data/setting.ini` is the single source of truth the HTTP API writes: brightness,
timezone, volume, wifi credentials, MQTT settings and social tokens. It also
holds the device's cloud credentials (`secretKey`, `authToken`,
`authRefreshToken`) — see `CLOUD.md`.

### Shell access

`adb shell` gives a **root shell**, but the environment is heavily stripped:

- **the stock busybox is nearly empty** — only `top` and `ifconfig` resolve. There
  is no `grep`, `sed`, `awk`, `find`, `vi`, `head` or `tail`. Filter on the host
  side by piping `adb shell` output instead.
- **a device running the custom runtime has a full one** at `/res/bin/busybox`,
  with a symlink per applet beside it, so `/res/bin/head` works directly. it is
  not on `PATH` (which is `/sbin:/bin:/tmp:`); add it **last** if you want the
  names — busybox has its own `reboot`, `mount`, `sh` and `ps` and the stock ones
  are what the system expects:

  ```sh
  export PATH=$PATH:/res/bin
  ```
- `/bin` holds: `cat ls cp mv rm mkdir chmod chown date df ps kill ping mount sync
  touch ln getprop setprop logcat reboot mksh sh`, plus `wpa_supplicant hostapd
  dnsmasq`, `vold`, `test_fb` and the `zk*` app stack.
- **`/data` is the only persistent writable location.** Everything else is either
  read-only squashfs/vfat or volatile tmpfs.

---

## Time

There is **no RTC** (`/dev/rtc*` and `/sys/class/rtc` are absent — the SoC's RTC
block is enabled in the device tree, but no driver was compiled in; see
[`KERNEL.md`](KERNEL.md#the-rtc-nuance)). The system
clock starts at the 1970 epoch on every boot and is set purely by an SNTP
client built into the app library (`ntp::` in `libzkgui.so`, calling
`settimeofday`). Everything below was read out of that library's disassembly
and then checked against the running device.

- **When:** once at app start (`mainActivity::onCreate`), then from a
  repeating `UiHandler::schedule(name, fn, period, firstDelay)` with
  `period = 7200000` ms and `firstDelay = rand() % 3600000` ms — **every
  2 h**, starting at a random point in the first hour. (The argument order is
  settled by `postDelayed`, which passes its delay in the `firstDelay` slot.)
  Each sync *steps* the clock rather than slewing it. An earlier note here
  about a 16 h gap was an artefact of the log buffer, which a once-a-second
  audio message keeps to about an hour of history.
- **How:** a detached thread tries the servers in order with a **3 s** receive
  timeout each, takes the first reply, sets the time and logs
  `time sync success` (`D/NTP`) and `NTP sync success, server=<ip>`
  (`I/zkgui`). If all seven fail it logs `can not sync time`, sleeps 5 s and
  starts over, forever, until one answers.
- **From where:** seven hardcoded IPv4 literals, parsed with `inet_addr`, so
  there is no DNS lookup to redirect and no hostname involved:
  `203.107.6.88` (`ntp.aliyun.com`), `182.92.12.11` (`time5.aliyun.com`),
  `120.25.115.20` (`cn.ntp.org.cn`), `103.11.143.248`, `202.73.57.107`,
  `158.69.48.97` and `216.218.254.202`. The first two drop ICMP but answer
  NTP; syncs here have landed on the first three.
- **Drift:** the unit tested here runs about **70 ppm fast** (three offset
  samples against an NTP-disciplined host over 7 min, and the same figure from
  the offset accumulated since a logged sync). That is roughly half a second
  ahead just before each 2 h sync, and about 6 s/day if it cannot sync at all.
- **Timezone:** the OS runs in UTC (`date` prints UTC). The `timezone` value
  from `/getConfig` is applied by the app when it renders.

There is **no HTTP or MQTT endpoint** to set the time, the period or the
servers. Over adb the busybox `date` applet works, as root:

```bash
adb shell date -u -s "$(date -u +'%Y-%m-%d %H:%M:%S')"
```

It takes effect immediately, is overwritten at the next SNTP sync (harmless if
the host is NTP-disciplined), and is lost on reboot.

If you firewall the device's internet access, **leave UDP/123 open to those
seven IPs**, DNAT it to a local NTP server (it must be NAT: the list is
addresses, not names), or patch the list as below. Otherwise the clock never
leaves 1970 after a reboot.

### Syncing more often, or from your own server (`tc002-ntp-patch.py`)

The period, the first-delay expression and the seven server strings are
constants in `libzkgui.so`, which lives on the read-only `/res` squashfs. The
launcher opens it by absolute path (`startupLibPath` in `/res/etc/EasyUI.cfg`),
so the `/tmp`-first `LD_LIBRARY_PATH` that `init.rc` sets does not help — but
a bind mount over that path does, and nothing in flash has to change.
(the launcher also reads `/tmp/EasyUI.cfg` in preference to the one in `/res`,
which is how the custom runtime in [`RUNTIME.md`](RUNTIME.md#how-it-gets-started)
replaces the app library wholesale; the runtime has had an sntp client of its
own since 2026-09-07, so this patch is for the stock app only.)
`tc002-ntp-patch.py` does the whole thing:

```bash
/usr/bin/python3 tc002-ntp-patch.py status -s <device-ip>
/usr/bin/python3 tc002-ntp-patch.py apply  -s <device-ip> --period 10
/usr/bin/python3 tc002-ntp-patch.py apply  -s <device-ip> --period 10 --server 10.0.0.5
/usr/bin/python3 tc002-ntp-patch.py revert -s <device-ip>
```

`apply` pulls the library, refuses anything but the app 1.1.1 build the
offsets were worked out on (by sha256), patches the constants, pushes the copy
to `/tmp`, bind-mounts it over `/res/lib/libzkgui.so`, stops and starts the
`zkswe` service (this init silently ignores `ctl.restart`) and confirms by
inode that the new process mapped the copy. `--period` also swaps the
first-delay `rand() % 3600000` for `rand() & 0xff00` (0–65 s) so the regular
cadence starts straight away; `--server` overwrites all seven 16-byte slots
with the IPv4 literals you give, cycling if you give fewer than seven.
`patch --in --out` does the byte edit on a local copy with no device attached.

Verified here with `--period 10`: the app synced at start, again 24 s later,
and then every 10 min.

What it costs: the copy sits in tmpfs, so **about 7.5 MB of the ~13 MB the
device had available** is gone while it is applied (`MemAvailable` went from
13.3 MB to 7–8 MB here, with no ill effect seen in the time it has run). It is
**not persistent**: a power cycle brings back the stock 2 h schedule and you
run `apply` again. `status` says which library the running app has mapped.

---

## adb

Over wifi, and **over the usb cable too** — Ulanzi's docs say USB adb does not
work on wifi-equipped models, and on this unit that is wrong.

The vendor's `/etc/init.rc` configures the usb **gadget** completely: vendor id
`18d1`, product `d002`, the `adb` function, `enable 1`. Once it is up the device
appears as `18d1:d002` "Zkswe", serial `0123456789ABCDEF`, alongside any network
transport, and macOS asks to approve the accessory once. It is a way in that does
not depend on wifi: verified with `wpa_supplicant` stopped and `wlan0` down to no
carrier and no address, the usb shell stayed up and the wifi was brought back
through it.

**Do not read the three files beside `otg_role`** named `usb_device`, `usb_host`
and `usb_null` to find out the current role: they are *actions*, and reading one
performs that switch. Read `otg_role`.

### what happens to usb across a reboot

Short version: **a cable left plugged in does not come back, and nothing running
on the device can change that.** Replug it, or use wifi, which returns on its own
in about sixteen seconds. The cause is two bytes of kernel, so it is fixable, but
only by reflashing the kernel partition — see "what a fix would take" below.

> **corrected 2026-09-16.** This section used to say the controller *"boots as
> `usb_host`"*, that one write of `usb_device` plus a replug was what turned adb
> on, and that a plugged cable *"leaves the host's view of the port unchanged and
> nothing enumerates"*. ~~All three were wrong~~, and the third was wrong in the
> direction that makes the real fault harder to find: the host **does**
> re-enumerate, promptly, and still cannot talk to the device.

> **scoped 2026-09-19, against a second unit that was factory-fresh.** Both
> readings above are correct, for different devices, and the difference is the
> `sys_usb_mode_key` guard already disassembled below: `UsbSwitchHelper`'s ctor
> reads it with a default of `-1` and **only calls `setUsbMode` when it is not
> `-1`**. On a unit that has ever had a usb mode stored, that restore runs at
> t≈6.8 s and the port settles in **device** mode — the timeline measured on the
> first unit. On a unit fresh from the box nothing is stored, the restore never
> runs, nothing undoes the kernel kthread's walk to host, and the port settles
> in **`usb_host`** presenting no gadget at all. Measured on the second unit:
> `otg_role` read `usb_host`, no gadget was on the bus, and a single write of
> `usb_device` brought one up **immediately, with no replug** — the replug is
> only ever needed after a reboot has stranded a host's view of a port that was
> already in device mode. The guard is read from the disassembly; the two
> end states are measured.

> **corrected again 2026-09-16**, by disassembling the binaries rather than
> reasoning from the log. This section then said *"the excursion belongs to
> `/bin/zkgui`"* and that `libzkhardware.so` *"runs the scan before it `dlopen`s
> our bootstrap"*. ~~Both were wrong~~. The excursion is in the **kernel**, it
> has nothing to do with scanning for a firmware stick, and `libzkhardware.so` is
> the thing that switches the port back afterwards.

The measured sequence, from the device's kernel log and the mac's
`IOUSBHostFamily` log on the same reboot, two boots running:

| device t | what happens | what the mac sees |
|---|---|---|
| 0.15 s | `PULL_UP(OFF)` then `PULL_UP(ON)` — the controller comes up in **device** mode | `terminateDevice: hardware connection lost` at reset |
| 2.1 s | `init.rc`'s `sys.usb.config=adb` block binds the `adb` function | two `enumeration failed` for `18d1/0001` |
| 2.7 s | `USB_STATE=CONFIGURED` | `enumerated 0x18d1/d002 at 480 Mbps` — about 5 s after the reset |
| 3.7 s | `PULL_UP(OFF)`, ehci registers: **the kernel's `usb-scan` kthread flips the port to host**, 3500 ms after it was created at driver probe | nothing — the disconnect is hidden behind the host-mode bus |
| 4.4 s | `usb scan usb_id thread exit!!!` — the same kthread, done, having moved the port and nothing else | |
| 6.8 s | ehci removed, `PULL_UP(ON)` — **`libzkhardware.so`'s "switch" thread** puts it back to device mode | nothing |
| 7.0 s | the supervisor writes `usb_device`, reads back `usb_device` | nothing |

So the host enumerates the **one-second gadget session that lives between 2.7 s
and 3.7 s**, and the host-mode excursion that immediately follows keeps it from
ever seeing that session end. It is left holding a device object whose endpoints
answer nothing: `AppleUSBIORequest::complete: ... endpoint 0x00: status
0xe00002ed (transaction error)`, once a second, until the port is physically
re-cycled. `system_profiler SPUSBDataType` still lists the clock the whole time,
which is what makes this look like a working cable.

#### who moves the port, and when

The excursion is in the built-in kernel driver `zkswe,sstar-otg`. At probe it
creates a kthread called `usb-scan`; the thread sleeps 3500 ms and then, when the
device-tree property `type` is `1`, walks the port **device → null → host** and
exits. Disassembled at `0xc01abf8c` in the decompressed kernel:

```c
usb_scan_thread(priv) {
    msleep(3500);
    if (priv->type == 1) {
        if (priv->role == 0 /*device*/) device_to_null(priv);  /* gadget unregister */
        if (priv->role == 2 /*null*/)   null_to_host(priv);    /* ehci_hcd register */
    }
    /* priv->type != 2, so the id-pin polling loop never runs: */
    printk("usb scan usb_id thread exit!!!");
    return 0;
}
```

and the device tree, which is built into the kernel image — u-boot's `bootcmd` is
`sf probe 0; sf read 0x22000000 KERNEL; dcache on; bootm 0x22000000`, with no dtb
argument, so the embedded one is the live one:

```dts
usbotg {
    compatible = "zkswe,sstar-otg";
    type = <0x1>;
    status = "ok";
};
```

`type = <1>` is exactly the value that parks the port in host mode. No userspace
process is consulted, and none exists yet that could be. This is presumably how
the vendor lets a firmware stick enumerate at boot; `libzkupgrade.so` then looks
for an already-mounted `/mnt/usb1`, so it never touches the role itself.

The port comes back because of `libzkhardware.so`, which only `/bin/zkgui` and
`/res/lib/libzkgui.so` link, and which is the one binary on the device holding
the four role paths:

```
HardwareManager::HardwareManager()            @0x52ec
  └─ 0x5320: bl UsbSwitchHelper::getInstance()
       └─ UsbSwitchHelper::UsbSwitchHelper()   @0x8aac
            v = StoragePreferences::getInt("sys_usb_mode_key", -1)
            if (v != -1) setUsbMode(v)         @0x8a70 → Thread::run("switch")
                 └─ SwitchThread::threadLoop() @0x88dc
                      fwrite("22") → otg_role
                      usleep(1 500 000)
                      read .../usb_null              ← the action files
                      read .../usb_device | usb_host
```

`zkgui` imports exactly one symbol from that library, `HardwareManager::getInstance()`,
and the 1.5 s sleep in the switch thread is the gap between zkgui starting and the
6.8 s restore. Nothing else in the firmware reaches `UsbSwitchHelper`
(`libinternalapp.so` does, but nothing links or `dlopen`s it). So patching that
library can only move the *recovery*; the library is not mapped into any process
at 3.7 s, when the session the mac is holding is destroyed.

One trap if you read either side: the driver's role encoding is
`0 = usb_device, 1 = usb_host, 2 = null`, which is **not** what
`UsbSwitchHelper::getUsbMode()` returns (`1 = device, 2 = host, 0 = unknown`).

Three device-side ways to re-advertise were tried against a wedged port. All
three reach the hardware, and the mac logs **nothing** for any of them:

```sh
echo 0 > /sys/class/zkswe_usb/zkswe0/enable; sleep 1; echo 1 > ...  # PULL_UP off/on, adb re-bind
cat /sys/bus/platform/devices/soc:usbotg/usb_null   # role to null, then usb_device:
cat /sys/bus/platform/devices/soc:usbotg/usb_device #   a full "Init USB controller"
echo disconnect > /sys/class/udc/soc:Sstar-udc/soft_connect; ...; echo connect > ...
```

A twelve-second disconnect was no more visible than a one-second one. The host
is not watching that port for a connect any more, and macOS offers no way to
power-cycle a port from userspace.

Two smaller things measured at the same time, both worth knowing:

- with the role already at `usb_device`, **writes to `otg_role` are silently
  ignored** — `usb_null`, `usb_host` and `usb_device` all returned success and
  changed nothing. Only the action files moved it. The older claim that writes
  are ignored *"while a host is attached and the gadget is `CONFIGURED`"* is too
  narrow; the gadget was `DISCONNECTED` for this test.
- after the excursion the gadget can be left reporting `state: CONFIGURED` with
  `current_speed: UNKNOWN`, which is not a live session. The symptom pair below
  is the honest one, and it impersonates a bad cable exactly:

```sh
cat /sys/class/zkswe_usb/zkswe0/state   # DISCONNECTED
cat /sys/class/udc/soc:Sstar-udc/state  # powered  <- vbus is there, no data session
```

The custom runtime still writes the role at startup (`--usb-role`, default
`device`). On the flashed path that write lands 200 ms after `libzkhardware.so`'s
switch thread has already restored device mode, so it confirms rather than causes
— but it costs nothing and it is the guarantee that matters on a device whose
network bring-up is the thing that failed.

#### what a fix would take

Not tried; recorded so nobody has to re-derive it. The robust change is two bytes
of kernel text: at file offset `0x1a3f9c` in the decompressed kernel (va
`0xc01abf9c`), `0a d1` — the `bne` that guards the `type == 1` block — becomes
`0a e0`, an unconditional `b` to the same target. The kthread still runs and still
sets the flag `otg_role` needs, but it moves nothing.

The one-byte device-tree change `type = <1>` → `<3>` looks cheaper and is worse:
`type > 2` makes probe skip `wake_up_process`, so the thread never runs, `priv+0x40`
is never set, and `otg_role` then reads `unkown` forever — which `applyUsbRole`
reads back.

Either way it means repacking the uImage (xz payload, uImage header CRCs, then the
`ZKSWEV1.0` container) and flashing **mtd1 (`KERNEL`)**, which has no anti-brick
fallback: `zkdaemon` only reflashes mtd3. A bad kernel is not a hard brick — u-boot
lives in `BOOT0` and still runs — but recovery is `sf write` over the UART pads.

Two lighter alternatives, both unproven:

- **rootfs.** Drop `sys.usb.config=adb` from `/etc/default.prop` and set it from a
  delayed oneshot, so the doomed gadget session never enumerates in the first place.
  Flashes mtd2, same risk class.
- **res only.** `LD_LIBRARY_PATH` is `/tmp:/res/lib:/lib`, so a shadow copy of one
  of `/bin/zkdisplay`'s libraries in `/res/lib` would give us root code at boot from
  the partition we already flash and that *does* have the three-bad-boots fallback.
  It would have to put the port in host mode before 3.5 s, so that the kthread's
  `role == 0` test fails — which means winning a race against `init.rc`'s 2.1 s
  gadget bind. Whether it can has not been measured.

```bash
brew install --cask android-platform-tools
adb connect <device-ip>:5555     # default port; grant Local Network first
adb devices -l
adb shell

adb shell logcat -v time         # timestamped logs
adb shell df                     # /data is 8 MiB, a few hundred KB of it used
adb shell cat /proc/meminfo      # text only: `adb shell cat` corrupts binaries, see FINGERPRINTS.md
adb shell busybox top
```

On macOS, `adb` is a third-party binary and reports `No route to host` until
your terminal app has Local Network permission — see the
[note on macOS](README.md#a-note-on-macos) in the README.

**Persistence:** "Download and debug" from the IDE is volatile — code pushed
that way lives in tmpfs and is gone after a power cycle. (The FlyThings docs
also say it reverts "if you unplug the TF card"; that applies to zkswe's dev
boards, not the TC002, which has no card slot. Its SoC's SD/MMC controller
is wired to the Wi-Fi chip as SDIO, and `/mnt/extsd` is an empty mount point
left over from the SDK.) To flash persistently:

```bash
adb push ./update.img /tmp/update.img
adb shell setprop sys.zkupgrade.flag 255
adb shell setprop sys.zkupgrade.dir /tmp
adb shell setprop ctl.restart zkswe
```

(That last line is the vendor recipe as published. When tried here,
`ctl.restart` was silently ignored by this init; `setprop ctl.stop zkswe`
followed by `setprop ctl.start zkswe` does restart the app.)

**Recovery:** hold the reset button during power-up to restore factory
firmware. What that actually does (`zkdaemon`, read from the binary): after
5 s on gpio 2 it stops the app, **wipes `/data`** (settings, wifi
credentials), and restarts the app with the upgrade properties pointing at
`/mnt/storage/update.img`; the loader then flashes that image if it is
present, otherwise nothing is reflashed and only the configuration is reset.
The same properties are set by the boot check when the app has not reported
`running` after 15 s. So the "factory firmware" is whatever `update.img` sits
on the UDISK partition, and recovery depends on the app loader still
reaching its upgrade check. The image format, the flasher and what a custom
image must respect are in [`FIRMWARE.md`](FIRMWARE.md);
[`tc002-update-img.py`](tc002-update-img.py) inspects and builds them.

Note that on this unit the USB gadget is configured as `adb`
(`/sys/class/zkswe_usb/zkswe0/functions`), not mass storage, and adb over the
cable **works** — see [adb](#adb) for the one write it needs.
