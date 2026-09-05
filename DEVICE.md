# Ulanzi TC002 — device internals, shell and adb

What the TC002 is running, how to get a root shell on it, and how to flash or
recover it. The local API is in `HTTP-API.md`.

Device under test: `appVer 1.1.1`, `mcuVer V1.0.17`.

> Identifiers (serial, MAC, SSID) are replaced with placeholders.
> Substitute your own from `GET /getBase`.

---

## Device summary

The TC002 runs **Linux on a Z21-series SoC** — not Android, and not the ESP32
of the TC001. Development is via the FlyThings IDE (C++, Windows-only).

It exposes two useful local interfaces with **no authentication**:

| Port | Service | Notes |
|-----:|---------|-------|
| 80   | HTTP settings API | unauthenticated read/write of all config — see `HTTP-API.md` |
| 5555 | `adbd` | wifi adb; USB is mass-storage only |

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
| Kernel | Linux 4.9.84 SMP PREEMPT, built with OpenWrt GCC 9.1.0 |
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

- **busybox is nearly empty** — only `top` and `ifconfig` resolve. There is no
  `grep`, `sed`, `awk`, `find`, `vi`, `head` or `tail`. Filter on the host side by
  piping `adb shell` output instead.
- `/bin` holds: `cat ls cp mv rm mkdir chmod chown date df ps kill ping mount sync
  touch ln getprop setprop logcat reboot mksh sh`, plus `wpa_supplicant hostapd
  dnsmasq`, `vold`, `test_fb` and the `zk*` app stack.
- **`/data` is the only persistent writable location.** Everything else is either
  read-only squashfs/vfat or volatile tmpfs.

---

## Time

There is **no RTC** (`/dev/rtc*` and `/sys/class/rtc` are absent). The system
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

Wifi only — the USB-C port is mass storage plus force-recovery. Ulanzi's docs
are explicit: for wifi-equipped models, USB adb does not work.

```bash
brew install --cask android-platform-tools
adb connect <device-ip>:5555     # default port; grant Local Network first
adb devices -l
adb shell

adb shell logcat -v time         # timestamped logs
adb shell df                     # data partition is only a few hundred KB
adb shell cat /proc/meminfo
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
firmware.
