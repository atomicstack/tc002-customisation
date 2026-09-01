# Ulanzi TC002 — local HTTP API, MQTT and adb notes

Reverse-engineered from a TC002 (Pixbar Smart Pixel Clock II) on the local
network, plus static analysis of `Mac_Apple_Ulanzi_Studio_V3.3.6_20260831.pkg`.

Device under test: `appVer 1.1.1`, `mcuVer V1.0.17`.

> Identifiers below (serial, MAC, SSID) are replaced with placeholders.
> Substitute your own from `GET /getBase`.

---

## Device summary

The TC002 runs **Linux on a Z21-series SoC** — not Android, and not the ESP32
of the TC001. Development is via the FlyThings IDE (C++, Windows-only).

It exposes two useful local interfaces with **no authentication**:

| Port | Service | Notes |
|-----:|---------|-------|
| 80   | HTTP settings API | unauthenticated read/write of all config |
| 5555 | `adbd` | wifi adb; USB is mass-storage only |

---

## Gotcha: macOS Local Network Privacy

On macOS 15 (Sequoia), Homebrew-installed binaries are denied local network
access until the **terminal app** is granted permission. The denial surfaces
as a misleading network error:

| Tool | Symptom |
|------|---------|
| `adb connect` | `failed to connect to '<ip>:5555': No route to host` |
| `nmap` | `Host seems down` / all ports `filtered (host-unreach)` |

Apple's own binaries (`/usr/bin/curl`, `/sbin/ping`, `/usr/bin/nc`) are exempt,
so they reach the device fine. That split is the diagnostic: if `/usr/bin/curl`
works and `/opt/homebrew/bin/nmap` does not, it is the permission, not the
network.

**Fix:** System Settings → Privacy & Security → Local Network → enable your
terminal app, then **fully quit and relaunch it** (the permission is evaluated
at process launch; a new tab is not enough).

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
```

---

## HTTP API

Base: `http://<device-ip>/`. No auth, no CSRF token, no rate limiting.
Unknown paths 301-redirect to `/settings/general`.

### Pages (HTML)

`/settings/general`, `/settings/calendar`, `/settings/info`,
`/settings/mqtt`, `/settings/social`, `/settings/tools`

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET  | `/getBase` | serial, SSID, IP, MAC, firmware versions |
| GET  | `/getConfig` | brightness, volume, timezone, date format |
| POST | `/setConfig` | write the above |
| GET  | `/getCalendar` | calendar provider credentials |
| POST | `/setCalendar` | write calendar providers |
| GET  | `/getSocial` | social platform uid/token per platform |
| POST | `/setSocial` | write social credentials |
| GET  | `/getToolsConfig` | weather, clock, pomodoro, scoreboard, etc. |
| POST | `/setToolsConfig` | write tool config |
| GET  | `/getMqttConfig` | broker address, credentials, topic prefix |
| POST | `/setMqttConfig` | write MQTT settings |
| GET  | `/getMqttStatus` | `{enabled, connected}` |
| GET  | `/checkUpdate` | firmware update check |
| POST | `/update` | **triggers firmware update — destructive** |
| POST | `/resetConfig` | **factory reset — destructive** |
| ?    | `/wifi/config` | wifi configuration |
| GET  | `/social/authorizeUrl?platform=<id>` | OAuth authorize URL |
| GET  | `/social/tokenStatus?platform=<id>` | OAuth token status |

Note: `/events` — the path Ulanzi Studio's agent hooks POST to by default —
**does not exist** on this firmware; it hits the catch-all redirect. The hook
client defaults to port 80 and `/events` but both are overridable via
`--device-port` / `--device-path`, so it likely targets a FlyThings app.

### Examples

```bash
# device identity
curl -s http://<device-ip>/getBase | jq .
# {"devSn":"<SERIAL>","ssid":"<SSID>","ip":"10.0.0.111",
#  "mac":"<MAC>","mcuVer":"V1.0.17","appVer":"1.1.1"}

# general config
curl -s http://<device-ip>/getConfig | jq .
# {"brightness":{"level":"low","low":50,"mid":80,"high":100},
#  "volume":0,"carouselSpeed":0,"scrollSpeed":7,"timezone":"UTC+2",
#  "dateFormat":"MM/DD","showWeek":true,"weekStart":1,
#  "lowBatteryAutoSleep":false}

# mqtt state
curl -s http://<device-ip>/getMqttConfig | jq .
# {"isMqtt":true,"ip":"","port":"1883","mqtt_name":"","mqtt_pwd":"",
#  "mqtt_prefix":"ulanzi","isHADiscoveryEnabled":false}

curl -s http://<device-ip>/getMqttStatus | jq .
# {"code":200,"data":{"enabled":true,"connected":false}}
```

`/getToolsConfig` exposes the built-in apps and their display order:
`weather`, `clock`, `busy`, `scoreboard`, `tomato`, `stopwatch`, `battery`,
`soundlight`, `ipshow` — each with `enable` plus per-tool settings.

`/getCalendar` covers `feishu`, `dingding`, `wecom`, `icloud`, `google`,
`outlook`. `/getSocial` covers `xhs`, `douyin`, `bilibili`, `weibo`,
`youtube`, `instagram`, `facebook`, `tiktok`, `x`.

---

## Security observations

These are properties of the device, not of anything installed on the Mac:

1. **No authentication on any endpoint.** Anyone on the LAN can read and write
   every setting, including triggering `/resetConfig` and `/update`.
2. **Credentials are returned in plaintext.** `/getCalendar` returns calendar
   `password` fields and `/getSocial` returns OAuth `token` values in clear
   text over unencrypted HTTP.
3. **No TLS.** Everything is plain HTTP on port 80.
4. **adb is open on 5555** with no pairing step.

Reasonable mitigation: put the device on an isolated IoT VLAN/SSID and
restrict which hosts may reach it.

---

## MQTT

MQTT is the supported way to drive the display without Ulanzi Studio.
Configure a broker via `/setMqttConfig` or the `/settings/mqtt` page.
Home Assistant discovery is available (`isHADiscoveryEnabled`).

**Custom App topic:** `[PREFIX]/custom/[APP_NAME]` — e.g.
`ulanzi_1bf6/custom/vibe_signal`. Default prefix is `ulanzi`.

**Payload:**

```json
{
  "duration": 10,
  "text": [],
  "image": [{ "data": "data:image/gif;base64,<...>", "position": [0, 0] }],
  "draw": []
}
```

The display is **52x16 RGB**. Icons are 8x8 PNG/GIF, either inlined as data
URIs or pre-loaded into the device's `/icons/` directory.

Ulanzi's repo ships community MQTT apps under `apps/mqtt/`, including
`vibe-coding-signal-light` (shows Claude Code / Codex / CI state as a traffic
light) and `claude-bot`. These achieve the same result as Ulanzi Studio's
agent-hook integration, but over a broker you control.

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

---

## References

- [UlanziTechnology/Ulanzi-U-Clock-TC002](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002)
- [FlyThings ADB docs](https://zkswe.github.io/flythings-doc/en/adb_debug.html)
