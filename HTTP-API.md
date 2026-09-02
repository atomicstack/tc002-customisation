# Ulanzi TC002 — local HTTP API

The unauthenticated HTTP API the device serves on port 80, reverse-engineered
from a TC002 (Pixbar Smart Pixel Clock II) on the local network plus static
analysis of `Mac_Apple_Ulanzi_Studio_V3.3.6_20260831.pkg`.

Part of [tc002-customisation](README.md). The other docs: [DEVICE.md](DEVICE.md)
for what the device is and how to get a shell, [SETUP.md](SETUP.md) for getting
it onto wifi, [CLOUD.md](CLOUD.md) for its outbound traffic, [MQTT.md](MQTT.md)
for driving the display, and [SECURITY.md](SECURITY.md) for the caveats.

Device under test: `appVer 1.1.1`, `mcuVer V1.0.17`.

> Identifiers below (serial, MAC, SSID) are replaced with placeholders.
> Substitute your own from `GET /getBase`.

---

## HTTP API

Base: `http://<device-ip>/`. No auth, no CSRF token, no rate limiting.
Unknown paths 301-redirect to `/settings/general`.

**CORS: cross-origin reads are blocked, cross-origin writes are not.** The
device sends `Access-Control-Allow-Origin: *` on `OPTIONS` preflights and on
`404` responses, but **real `200` responses carry no CORS headers at all**.
Measured against `appVer 1.1.1` with `Origin: http://evil.example`:

| Request | Status | `Access-Control-*` headers |
|---------|-------:|----------------------------|
| `GET /getConfig` | 200 | none |
| `POST /setConfig` | 200 | none — but the write is applied |
| `OPTIONS /setConfig` (preflight) | 200 | `Allow-Origin: *`, `Allow-Methods: POST`, `Allow-Headers: content-type`, `Max-Age: 60` |
| `HEAD /getConfig`, `POST /getBase` | 404 | `Allow-Origin: *` |
| `GET /nope` (catch-all) | 301 | none |

Two consequences:

- **Reads:** a browser blocks every cross-origin response body, surfacing as a
  bare "Load failed" / "Failed to fetch". A web page cannot talk to the device
  directly, so `panel/` ships a small same-origin proxy (`panel/serve.py`).
- **Writes:** the preflight *approves* a cross-origin `POST` with
  `Content-Type: application/json`, and the device also accepts the same body
  sent as `text/plain` (a "simple request" that needs no preflight at all). It
  checks neither `Origin` nor `Content-Type`. The browser withholds the *reply*,
  but the device has already acted on the request. See
  [SECURITY.md](SECURITY.md).

Verifying with `curl -I` is misleading — the device 404s `HEAD`, and that error
response *does* carry the header. Check a real `GET`:

```bash
curl -s -i -H 'Origin: http://localhost' http://<device-ip>/getConfig | grep -i access-control
# (no output — the header is absent on 200 responses)
```

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
| POST | `/setWifiConfig` | join a wifi network — payload and flow in [SETUP.md](SETUP.md) |
| POST | `/setLedRegister` | LED driver current gain (see below) |
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

## LED current gain

`POST /setLedRegister` writes the LED driver's per-channel current-gain register
(`0x16`, decimal 22). Each channel takes `0`-`63`; stock default appears to be `30`.

```json
{"rReg":22,"rVal":30,"gReg":22,"gVal":30,"bReg":22,"bVal":30}
```

This sets LED **drive current**, so it governs white balance and panel headroom —
useful for correcting a colour cast. Caveats:

- There is **no `getLedRegister`**, so values cannot be read back. Record what you
  have before changing anything.
- Raising gain raises drive current, which affects heat and LED lifetime.

The stock firmware ships a test harness for this at
`/res/ui/web/ledRegisterTest.html`, but it is **not routed** — every URL guess hits
the catch-all 301, so it was only ever usable by opening the file directly.

---

## Web UI language

The built-in web UI is **Chinese only** and cannot be switched:

- `common.js` contains hardcoded Chinese strings and **no i18n machinery** — no
  `navigator.language` check, no locale storage, no switcher.
- No `language` or `locale` field exists in any config endpoint.
- `/checkUpdate` reports `needUpdate: false` on `1.0.17_1.1.1` — no English build
  is offered.
- Pages live in `/res/ui/web` on a **read-only squashfs**, so they cannot be
  patched in place; changing them means rebuilding and reflashing `update.img`.

The `<title>` is English while the body is Chinese, which is easy to misread when
fetching with `curl`.

The practical fix is to drive the JSON API from a local page instead — see
`panel/` in this repo. That page has to go through a same-origin proxy, because
the device's CORS handling blocks browser reads (see the CORS note under
[HTTP API](#http-api)).
