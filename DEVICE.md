# Ulanzi TC002 — device internals, shell and adb

What the TC002 is running, how to get a root shell on it, and how to flash or
recover it. Part of [tc002-customisation](README.md); the local API is in
[HTTP-API.md](HTTP-API.md).

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
| 80   | HTTP settings API | unauthenticated read/write of all config — see [HTTP-API.md](HTTP-API.md) |
| 5555 | `adbd` | wifi adb; USB is mass-storage only |

It also phones home to `api.ulanzistudio.com` over **plain HTTP** for weather,
social counts, calendars and the update check — see [CLOUD.md](CLOUD.md).

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
led matrix over spi is in [LED-SPI.md](LED-SPI.md)).

`/data/setting.ini` is the single source of truth the HTTP API writes: brightness,
timezone, volume, wifi credentials, MQTT settings and social tokens. It also
holds the device's cloud credentials (`secretKey`, `authToken`,
`authRefreshToken`) — see [CLOUD.md](CLOUD.md).

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
`settimeofday`):

- **When:** once at app start (`mainActivity::onCreate`), then from a
  **repeating** scheduled task with a **2 h period** and a random component
  of up to 1 h (`schedule(name, fn, 7200000, rand() % 3600000)` in the
  binary; whether the random part is a first-run delay or per-run jitter was
  not settled). Observed here: a boot sync, then one 16 h 12 min later, which
  fits 2 h × 8 plus a 12 min initial delay. Between syncs the clock
  free-runs, and each sync *steps* the time rather than slewing it, so with
  the clock app set to `HH:MM:SS` a few seconds of drift can be visible just
  before a sync.
- **From where:** four hardcoded IPs, no hostname, not configurable:
  `203.107.6.88` (`ntp.aliyun.com`), `182.92.12.11` (`time5.aliyun.com`),
  `120.25.115.20` (`cn.ntp.org.cn`) and `103.11.143.248` (unlabelled,
  AS58436). All in China; the sync still landed within a fraction of a second
  of an NTP-checked host here.
- **Timezone:** the OS runs in UTC (`date` prints UTC). The `timezone` value
  from `/getConfig` is applied by the app when it renders.

There is **no HTTP or MQTT endpoint** to set the time or the NTP server. Over
adb the busybox `date` applet works, as root:

```bash
adb shell date -u -s "$(date -u +'%Y-%m-%d %H:%M:%S')"
```

It takes effect immediately, is overwritten at the next SNTP sync (harmless if
the host is NTP-disciplined), and is lost on reboot. Measured here before and
after such a set, the device was within half a second of an NTP-checked host
both times: the sync itself is accurate, and any offset you see is drift
between syncs.

If you firewall the device's internet access, **leave UDP/123 open to those
four IPs** (or redirect it to a local NTP server). Otherwise the clock never
leaves 1970 after a reboot.

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

**Persistence:** "Download and debug" from the IDE is volatile — code reverts
on power loss or TF-card removal. To flash persistently:

```bash
adb push ./update.img /tmp/update.img
adb shell setprop sys.zkupgrade.flag 255
adb shell setprop sys.zkupgrade.dir /tmp
adb shell setprop ctl.restart zkswe
```

**Recovery:** hold the reset button during power-up to restore factory
firmware.
