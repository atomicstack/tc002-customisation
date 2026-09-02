# Ulanzi TC002 — local HTTP API

The unauthenticated HTTP API the device serves on port 80, reverse-engineered
from a TC002 (Pixbar Smart Pixel Clock II) on the local network plus static
analysis of `Mac_Apple_Ulanzi_Studio_V3.3.6_20260831.pkg`.

Part of [tc002-customisation](README.md). The other docs: [DEVICE.md](DEVICE.md)
for what the device is and how to get a shell, [SETUP.md](SETUP.md) for getting
it onto wifi, [CLOUD.md](CLOUD.md) for its outbound traffic, [MQTT.md](MQTT.md)
for driving the display over a broker, [CUSTOM-APP.md](CUSTOM-APP.md) for
the frame payload both transports share, and [SECURITY.md](SECURITY.md) for
the caveats.

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
| POST | `/api/custom?name=<app>` | create/replace a custom (DIY) app's frame; body `{}` removes it — see [Custom apps](#custom-apps) |
| GET  | `/api/customList` | `{apps: [...], count}` — the custom apps currently on the device |
| POST | `/switchApp` | jump to a built-in app: body `{type, index}` — see [Navigation and input](#navigation-and-input) |
| POST | `/api/switchDiyApp?name=<app>` | jump to a custom app by name — see [Navigation and input](#navigation-and-input) |
| POST | `/keyEvent` | inject a button/knob press: body `{key, event}` — see [Navigation and input](#navigation-and-input) |
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

## Custom apps

The display can be driven directly over HTTP, without a broker: `POST
/api/custom?name=<app>` takes the same `{duration, text, image, draw}` JSON
that the MQTT topic `<prefix>/custom/<app>` takes, and `GET /api/customList`
lists what is there. This is the protocol [PixDeck](https://github.com/cailurus/PixDeck)
uses on stock firmware. The payload — text, draw primitives, bitmaps, animated
GIFs, the ASCII-only font and the no-scrolling caveat — is documented once in
[CUSTOM-APP.md](CUSTOM-APP.md).

```bash
# push a frame (creates the app on first use)
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' \
  -d '{"duration":10,"text":[{"content":"HELLO","fontHeight":10,"x":-1000,"y":3,
       "align":"center","rect":[0,0,52,16],"color":"#3EE08A"}]}'

# list custom apps
curl -s http://<device-ip>/api/customList | jq .
# {"apps":["hello"],"count":1}

# remove it (empty object)
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' -d '{}'
```

Like every other endpoint this is unauthenticated, and the same CORS gap
applies: the preflight approves the cross-origin `POST`, so any web page can
put content on the display or remove apps (see [SECURITY.md](SECURITY.md)).
PixDeck ignores the response body; its format is not documented here.

---

## Navigation and input

The device can be driven remotely the same way the front buttons do it. Three
endpoints, all `POST`, all verified against `appVer 1.1.1`.

### `/switchApp` — jump to a built-in app

Body `{"type": <type>, "index": <n>}`. `type` is one of `tools`, `social`,
`calendar` (the three built-in app groups). `index` is the **1-based position
within that group's list** as returned by `/getToolsConfig`, `/getSocial` or
`/getCalendar` — so for `tools`, `1` = weather, `2` = clock … `9` = ipshow.

```bash
curl -s -X POST http://<device-ip>/switchApp \
  -H 'Content-Type: application/json' -d '{"type":"tools","index":2}'
# {"code":200,"message":"app switched","data":{"type":"tools","index":2}}
```

- `index` is 1-based; `0` returns `{"code":400,"message":"Invalid app index"}`.
- Both `type` and `index` are required; a bad `type` gives `Invalid app type`.
- Pointing at a **disabled** tool does not error — the device coerces to an
  enabled app (targeting weather, disabled here, landed on clock). Enabled
  targets (`clock`, `ipshow`) switched exactly.
- After a manual switch the carousel eventually resumes on its own timer.

### `/api/switchDiyApp?name=<app>` — jump to a custom app

Selects one of the custom (DIY) apps from `/api/customList` by name.

```bash
curl -s -X POST 'http://<device-ip>/api/switchDiyApp?name=popsquares'
# {"code":200,"message":"app switch requested","data":{"name":"popsquares","index":100}}
```

Missing `name` returns `{"code":400,"message":"Missing query parameter: name"}`.
The device also subscribes to `<prefix>/switchDiyApp` on MQTT for the same
action (see [MQTT.md](MQTT.md)).

### `/keyEvent` — inject a button or knob event

Body `{"key": <key>, "event": <event>}`, optional `"source"` (a free label
echoed to `logcat`). This simulates the physical controls:

| `key` | `event` values |
|-------|----------------|
| `left`, `middle`, `right` | `shortPress`, `longPress` |
| `knob` | `shortPress`, `longPress`, `cw`, `ccw` |

```bash
curl -s -X POST http://<device-ip>/keyEvent \
  -H 'Content-Type: application/json' -d '{"key":"knob","event":"cw"}'
# {"code":200,"message":"event accepted"}
```

- `cw` / `ccw` are knob-only; on another key the device replies
  `cw event only supports knob`.
- An unknown key or event gives `Invalid key or event`; a missing one gives
  `Missing required parameter: key` / `event`.

All three are unauthenticated and, like the rest of the API, forgeable
cross-origin from any web page (see [SECURITY.md](SECURITY.md)).

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
