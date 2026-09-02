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

| | |
|---|---|
| SoC | SigmaStar SSD21x, dual core (`Zkswe_SSD21X_SPINOR`) |
| Kernel | Linux 4.9.84 SMP PREEMPT, built with OpenWrt GCC 9.1.0 |
| RAM | ~32 MB |
| Root fs | squashfs, 3.5 MB, **read-only** |
| `/res` | squashfs on `mtdblock3`, 2.8 MB, **read-only** (UI assets, fonts, certs) |
| `/data` | jffs2, 8 MB, **read-write and persistent** |
| `/mnt/storage` | vfat on `mtdblock7`, 8.5 MB, **read-only** (holds `update.img`) |
| `/tmp`, `/mnt`, `/misc` | tmpfs, volatile |

Userspace processes: `init`, `ueventd`, `vold`, `logd`, `adbd`, `wpa_supplicant`,
and the FlyThings stack — `zkdaemon`, `zkdisplay`, `zkgui` (the app runtime that
drives the display).

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
