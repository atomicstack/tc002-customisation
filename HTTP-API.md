# Ulanzi TC002 — local HTTP API

The unauthenticated HTTP API the device serves on port 80, reverse-engineered
from a TC002 (Pixbar Smart Pixel Clock II) on the local network plus static
analysis of `Mac_Apple_Ulanzi_Studio_V3.3.6_20260831.pkg`.

The other documents in this repository are listed in the README.

Device under test: `appVer 1.1.1`, `mcuVer V1.0.17`.

> Identifiers below (serial, MAC, SSID, credentials) are replaced with
> placeholders. Substitute your own from `GET /getBase`.

**How each entry was established.** Every endpoint carries a *source* line:

- **live** — exercised against the device; the shapes shown are what it sent.
- **web ui** — request shape taken from the JavaScript in the stock settings
  pages (`/res/ui/web/*.html`), which is what the device's own UI sends.
- **firmware** — reconstructed from the parameter names and messages in the
  request handler (`ConfigWebServer::doTask` in `/res/lib/libzkgui.so`); not
  exercised, usually because the call is destructive.

---

## HTTP API

Base: `http://<device-ip>/`. No auth, no CSRF token, no rate limiting.

### Conventions

- **Bodies are JSON**; a few endpoints take query parameters instead. The
  request `Content-Type` is not checked.
- **Getters return a bare object.** Everything else returns an envelope
  `{"code": <n>, "message": "<text>"[, "data": {...}]}`.
- **Errors mostly come with HTTP 200.** A validation failure is `{"code": 400,
  "message": "..."}` and a lookup failure `{"code": 404, ...}`, both on an HTTP
  `200`. Check `code`, not the status line. The exceptions: `/diyFile` uses a
  real HTTP 404, the wrong method on a known path is an HTTP `404` with
  `text/plain` body `Error 404: Not Found`, and an unknown path is a `301` to
  `/settings/general`.
- **Response `Content-Type`** is `application/json; charset=utf-8`
  (`/getToolsConfig` omits the charset).
- **No partial GETs, no pagination, no versioning.** Every getter returns the
  whole object.

### CORS: cross-origin reads are blocked, cross-origin writes are not

The device sends `Access-Control-Allow-Origin: *` on `OPTIONS` preflights and
on `404` responses, but **real `200` responses carry no CORS headers at all**.
Measured against `appVer 1.1.1` with `Origin: http://evil.example`:

| Request | Status | `Access-Control-*` headers |
|---------|-------:|----------------------------|
| `GET /getConfig` | 200 | none |
| `POST /setConfig` | 200 | none — but the write is applied |
| `OPTIONS /setConfig` (preflight, with `Access-Control-Request-Method`) | 200 | `Allow-Origin: *`, `Allow-Methods: POST`, `Allow-Headers: content-type`, `Max-Age: 60` |
| `OPTIONS /setConfig` (bare, no CORS request headers) | 404 | `Allow-Origin: *` |
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
  but the device has already acted on the request. See `SECURITY.md`.

Verifying with `curl -I` is misleading — the device 404s `HEAD`, and that error
response *does* carry the header. Check a real `GET`:

```bash
curl -s -i -H 'Origin: http://localhost' http://<device-ip>/getConfig | grep -i access-control
# (no output — the header is absent on 200 responses)
```

### Endpoint index

| Method | Path | Purpose | Source |
|--------|------|---------|--------|
| GET | [`/getBase`](#getbase) | identity and firmware versions | live |
| GET | [`/getConfig`](#getconfig--setconfig) | display and general settings | live |
| POST | [`/setConfig`](#getconfig--setconfig) | write them | live |
| GET | [`/getMqttConfig`](#getmqttconfig--setmqttconfig--getmqttstatus) | broker settings | live |
| POST | [`/setMqttConfig`](#getmqttconfig--setmqttconfig--getmqttstatus) | write them | live |
| GET | [`/getMqttStatus`](#getmqttconfig--setmqttconfig--getmqttstatus) | broker connection state | live |
| GET | [`/getToolsConfig`](#gettoolsconfig--settoolsconfig) | built-in apps: enable, order, per-app settings | live |
| POST | [`/setToolsConfig`](#gettoolsconfig--settoolsconfig) | write them (partial ok) | live / web ui |
| GET | [`/getCalendar`](#getcalendar--setcalendar) | calendar providers | live |
| POST | [`/setCalendar`](#getcalendar--setcalendar) | write them (partial ok) | web ui |
| GET | [`/getSocial`](#getsocial--setsocial) | social platforms | live |
| POST | [`/setSocial`](#getsocial--setsocial) | write them (partial ok) | web ui |
| GET | [`/social/tokenStatus`](#socialtokenstatus) | OAuth token state for a platform | live |
| GET | [`/social/authorizeUrl`](#socialauthorizeurl) | OAuth login URL, relayed from the cloud | live |
| POST | [`/api/custom`](#custom-apps) | create / replace / remove a custom app's frame | live |
| GET | [`/api/customList`](#custom-apps) | custom apps on the device | live |
| GET | [`/getDiyImages`](#getdiyimages--setdiyimages--diyfile) | DIY image slots | live |
| POST | [`/setDiyImages`](#getdiyimages--setdiyimages--diyfile) | upload / delete / reorder DIY images | firmware |
| GET | [`/diyFile`](#getdiyimages--setdiyimages--diyfile) | fetch one DIY image | live |
| POST | [`/switchApp`](#switchapp--jump-to-a-built-in-app) | show a built-in app | live |
| POST | [`/api/switchDiyApp`](#apiswitchdiyappnameapp--jump-to-a-custom-app) | show a custom app | live |
| POST | [`/keyEvent`](#keyevent--inject-a-button-or-knob-event) | simulate a button or knob | live |
| POST | [`/setLedRegister`](#setledregister) | LED driver current gain | live |
| GET | [`/checkUpdate`](#checkupdate) | ask the cloud for a firmware update | live |
| POST | [`/update`](#update) | **flash firmware — destructive** | web ui / firmware |
| POST | [`/resetConfig`](#resetconfig) | **factory reset — destructive** | web ui / firmware |
| POST | [`/setWifiConfig`](#setwificonfig) | join a wifi network | web ui / firmware |
| POST | [`/wifisave`](#wifisave) | legacy form handler for the above | firmware |
| POST | [`/setSn`](#setsn) | **rewrite the device serial** | firmware |
| POST | [`/setBluetooth`](#setbluetooth) | turn BLE on or off | firmware |
| GET | [pages and assets](#pages-and-assets) | the stock settings UI | live |

Note: `/events` — the path Ulanzi Studio's agent hooks POST to by default —
**does not exist** on this firmware; it hits the catch-all redirect. The hook
client defaults to port 80 and `/events` but both are overridable via
`--device-port` / `--device-path`, so it likely targets a FlyThings app.

---

## Device and settings

### `/getBase`

`GET`. The device's identity; also the fingerprint `tc002-adopt.py` uses to
recognise one. *Source: live.*

```json
{"devSn":"<SERIAL>","ssid":"<SSID>","ip":"10.0.0.111",
 "mac":"<MAC>","mcuVer":"V1.0.17","appVer":"1.1.1"}
```

| field | meaning |
|-------|---------|
| `devSn` | serial, up to 17 characters (writable with `/setSn`) |
| `ssid` | the wifi network it has joined |
| `ip` | its address on that network |
| `mac` | wifi MAC, 12 lowercase hex digits, no separators |
| `mcuVer` | firmware of the pixel MCU that drives the LEDs |
| `appVer` | firmware of the SoC application |

### `/getConfig` / `/setConfig`

Display and general settings. `GET` returns the object; `POST` the same object
back to change it. *Source: live (a no-op round trip was verified byte-identical).*

```json
{"brightness":{"level":"high","low":25,"mid":50,"high":100},
 "volume":0,"carouselSpeed":0,"scrollSpeed":7,"timezone":"UTC+2",
 "dateFormat":"MM/DD","showWeek":true,"weekStart":1,
 "lowBatteryAutoSleep":false}
```

| field | type | notes |
|-------|------|-------|
| `brightness.level` | `"low"` \| `"mid"` \| `"high"` | which preset is active |
| `brightness.low/mid/high` | int | percent, **5–100, and `low <= mid <= high`** (validated) |
| `volume` | int | 0–6 in the stock UI |
| `carouselSpeed` | int | seconds between automatic app changes; `0` = off |
| `scrollSpeed` | int | text scroll speed; stock default 7 |
| `timezone` | string | `"UTC+2"`, `"UTC-5"`, `"UTC+5:30"` style; applied by the app when rendering (the OS runs in UTC) |
| `dateFormat` | string | `MM/DD`, `DD/MM` or `YYYY/MM/DD` in the stock UI |
| `showWeek` | bool | weekday bar under the clock |
| `weekStart` | int | `0` = Sunday, `1` = Monday. The handler also holds `"Sun"`/`"Mon"` literals, so string forms may be accepted (not tested) |
| `lowBatteryAutoSleep` | bool | screen off when the battery is low and idle |

The stock page always posts the **whole object**; whether a partial object is
merged or wipes the missing fields was not established, so send everything.

Responses:

| `code` | `message` | when |
|-------:|-----------|------|
| 200 | `Settings saved successfully` | |
| 400 | `Invalid brightness level: must be low, mid, or high` | |
| 400 | `Invalid brightness config: level must be low/mid/high, values must be 5-100 and low <= mid <= high` | |
| 400 | `Invalid request data` | body is not a JSON object |

### `/getMqttConfig` / `/setMqttConfig` / `/getMqttStatus`

Broker settings for the MQTT client (see `MQTT.md`). *Source: live.*

```json
{"isMqtt":true,"ip":"10.0.0.136","port":"1883","mqtt_name":"<user>",
 "mqtt_pwd":"<password>","mqtt_prefix":"ulanzi","isHADiscoveryEnabled":false}
```

| field | type | notes |
|-------|------|-------|
| `isMqtt` | bool | client enabled |
| `ip` | string | broker host |
| `port` | **string** | `"1883"` by default; note it is a string, not a number |
| `mqtt_name`, `mqtt_pwd` | string | credentials; **the password is returned in clear** |
| `mqtt_prefix` | string | topic prefix, default `ulanzi`; the device subscribes under `<prefix>/custom/+` and `<prefix>/switchDiyApp` |
| `isHADiscoveryEnabled` | bool | publish Home Assistant discovery config |

`POST /setMqttConfig` with the same object → `{"code":200,"message":"MQTT
config saved successfully"}`. The client reconnects on its own; poll status.

`GET /getMqttStatus` → `{"code":200,"data":{"enabled":true,"connected":true}}`.

### `/getToolsConfig` / `/setToolsConfig`

The nine built-in apps ("tools"): which are enabled, their order, and each
one's settings. *Source: live; the partial-update shapes are what the stock
page sends.*

```json
{"toolsInfos":{
   "weather":   {"city":"Amsterdam","lat":"","lon":"","token":"",
                 "displayInfo":{"displayTemperature":true,"displayHumidity":true,
                                "displayPressure":true,"displayAqi":true},
                 "enable":false},
   "clock":     {"timeFormat":"HH:MM:SS","enable":true},
   "busy":      {"focusTime":"30","relaxTime":"5","enable":false},
   "scoreboard":{"enable":false},
   "tomato":    {"focusTime":"25","relaxTime":"5","enable":false},
   "stopwatch": {"enable":false},
   "battery":   {"lowBatteryAutoSleep":false,"enable":false},
   "soundlight":{"enable":false},
   "ipshow":    {"enable":true}},
 "toolsOrder":[1,2,3,4,5,6,7,8,9]}
```

| tool | id | settings |
|------|---:|----------|
| clock | 1 | `timeFormat`: `HH:MM:SS`, `HH:MM`, `HH:MM AM`, `HH:MM AP` (the four literals in the firmware) |
| weather | 2 | `city`, `lat`, `lon`, `token` (strings; the stock UI uses `city`), `displayInfo.display{Temperature,Humidity,Pressure,Aqi}` bools — **at least one must be true** |
| busy | 3 | `focusTime`, `relaxTime` — minutes, **as strings** |
| scoreboard | 4 | — |
| tomato (pomodoro) | 5 | `focusTime`, `relaxTime` — minutes, as strings |
| stopwatch | 6 | — |
| battery | 7 | `lowBatteryAutoSleep` bool |
| soundlight | 8 | — |
| ipshow | 9 | — |

`toolsOrder` is the carousel order as a permutation of the ids above (a unit
showing "Show IP" first reported `[9,1,2,3,4,5,6,7,8]`). **These ids are the
same numbers `/switchApp` takes as `index`.** Note the id order (clock first)
differs from the JSON key order (weather first).

`POST /setToolsConfig` accepts a **partial** object; the stock page sends one
of these per action:

```json
{"toolsInfos":{"clock":{"timeFormat":"HH:MM","enable":true}}}
{"toolsInfos":{"weather":{"enable":false}}}
{"toolsOrder":[1,9,2,3,4,5,6,7,8]}
```

Responses: `200 Tools config saved successfully`; `400 toolsOrder must contain
all indices 1-9 exactly once`; `400 Weather requires at least one display
item`. A changed `toolsOrder` takes effect in the carousel; a changed `enable`
also shows or hides the app from `/switchApp`.

### `/getCalendar` / `/setCalendar`

Calendar providers. *Source: live for the getter; the setter's shape is what the
stock page sends.*

```json
{"calendarInfos":{
   "feishu":  {"username":"","password":"","server":"","enable":true},
   "dingding":{"username":"","password":"","server":"","enable":true},
   "wecom":   {"username":"","password":"","server":"","enable":true},
   "icloud":  {"username":"","password":"","server":"","enable":true},
   "google":  {"url":"","enable":true},
   "outlook": {"url":"","enable":true}},
 "calendarOrder":[1,2,3,4,5,6]}
```

The four CalDAV providers (`feishu`, `dingding`, `wecom`, `icloud`) take
`username`, `password` and `server`; `google` and `outlook` take a public
`url` (a WebCal/ICS link). `calendarOrder` is a permutation of 1–6, presumably
in the key order shown.

**Credentials entered here are returned in clear by this endpoint and are sent
to Ulanzi's cloud, which performs the CalDAV fetch on the device's behalf** —
see `CLOUD.md` before configuring a real account.

`POST /setCalendar` is partial, one of:

```json
{"calendarInfos":{"icloud":{"username":"…","password":"…","server":"…","enable":true}}}
{"calendarInfos":{"google":{"enable":false}}}
{"calendarOrder":[2,1,3,4,5,6]}
```

Responses: `200 Calendar settings saved successfully`; `400 calendarOrder must
contain all indices 1-6 exactly once`. (The handler also reads a misspelt
`calnedarOrder` key as a fallback.)

### `/getSocial` / `/setSocial`

Social follower counters. *Source: live for the getter; setter shape from the
stock page.*

```json
{"socialInfos":{
   "xhs":{"uid":"","token":"","enable":false},
   "douyin":{"uid":"","token":"","enable":true},
   "bilibili":{"uid":"","token":"","enable":false},
   "weibo":{"uid":"","token":"","enable":false},
   "youtube":{"uid":"","token":"","enable":false},
   "instagram":{"uid":"","token":"","enable":false},
   "facebook":{"uid":"","token":"","enable":false},
   "tiktok":{"uid":"","token":"","enable":false},
   "x":{"uid":"","token":"","enable":false},
   "tokens":{}},
 "socialOrder":[1,2,3,4,5,6,7,8,9],
 "hiddenPlatforms":["xhs","facebook","x"]}
```

Each platform has `uid` (the account to count), `token` (returned in clear)
and `enable`. `socialInfos.tokens` holds OAuth tokens obtained through
`/social/authorizeUrl`, keyed by platform (empty here). `socialOrder` is a
permutation of 1–9, presumably in the key order shown. `hiddenPlatforms` lists
platforms the stock UI does not show on this unit; how it is decided (region,
firmware build) was not established.

`POST /setSocial` is partial, one of:

```json
{"socialInfos":{"youtube":{"uid":"…","token":"…","enable":true}}}
{"socialInfos":{"youtube":{"enable":false}}}
{"socialOrder":[5,1,2,3,4,6,7,8,9]}
```

Responses: `200 Social settings saved successfully`; `400 socialOrder must
contain all indices 1-9 exactly once`.

### `/social/tokenStatus`

`GET /social/tokenStatus?platform=<id>` — whether the device holds a usable
OAuth token for a platform. *Source: live.*

```json
{"code":200,"message":"ok","data":{"status":"no_token"}}
```

`data.status` is one of `no_token`, `valid`, `expired`, `pending`; a valid
token also carries `isValid` and `expireIn`. Without the parameter:
`{"code":400,"message":"Missing parameter: platform"}`.

### `/social/authorizeUrl`

`GET /social/authorizeUrl?platform=<id>` — the device asks Ulanzi's cloud
(`/authorizeUrl?platform=…&lang=zh-CN`, with its own bearer token) for an OAuth
login URL and **relays the upstream body verbatim** with a JSON content type.
*Source: live.* On this unit it returned a 4.9 KB HTML page (a cloud login/error
page), not JSON. Other replies the handler can produce: `No valid auth token`
when the device has no cloud token, and `Upstream returned <status>` on an
upstream error.

---

## Display

### Custom apps

The display can be driven directly over HTTP, without a broker: `POST
/api/custom?name=<app>` takes the same `{duration, text, image, draw}` JSON
that the MQTT topic `<prefix>/custom/<app>` takes, and `GET /api/customList`
lists what is there. This is the protocol [PixDeck](https://github.com/cailurus/PixDeck)
uses on stock firmware. The payload — text, draw primitives, bitmaps, animated
GIFs, the ASCII-only font and the no-scrolling caveat — is documented once in
`CUSTOM-APP.md`. *Source: live.*

```bash
# push a frame (creates the app on first use)
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' \
  -d '{"duration":10,"text":[{"content":"HELLO","fontHeight":10,"x":-1000,"y":3,
       "align":"center","rect":[0,0,52,16],"color":"#3EE08A"}]}'
# {"code":200,"message":"ok"}

# list custom apps
curl -s http://<device-ip>/api/customList
# {"apps":["hello"],"count":1}

# remove it (empty object)
curl -s -X POST 'http://<device-ip>/api/custom?name=hello' \
  -H 'Content-Type: application/json' -d '{}'
# {"code":200,"message":"ok"}
```

| request | reply |
|---------|-------|
| valid frame | `{"code":200,"message":"ok"}`; the app is created or replaced |
| `{}` | `{"code":200,"message":"ok"}`; the app is removed |
| a body that is not JSON | **also** `{"code":200,"message":"ok"}`, and the app is left as it was |
| no `name` query parameter | `{"code":400,"message":"Missing query parameter: name"}` |

Like every other endpoint this is unauthenticated, and the same CORS gap
applies: the preflight approves the cross-origin `POST`, so any web page can
put content on the display or remove apps (see `SECURITY.md`).

### `/getDiyImages` / `/setDiyImages` / `/diyFile`

DIY images are still pictures (PNG, JPEG or GIF) stored on the device under
`/data/diy/` and shown as a carousel group of their own. Ulanzi Studio's
PixelGrid uploads through these. *Source: live for the two getters (with no
images stored); the setter from firmware strings only.*

`GET /getDiyImages`:

```json
{"images":[],"imageOrder":[],"enable":true}
```

With images present, each `images[]` entry names at least an `index` and a
`format` (the literals the handler emits); the exact item shape was not
observed. `imageOrder` is the display order by index; `enable` gates the
whole group.

`GET /diyFile?index=<n>` returns the stored file with `Content-Type:
image/<png|jpg|jpeg|gif>`. Errors: `{"code":404,"message":"DIY image not found:
<n>"}` — on a **real HTTP 404**, unlike the rest of the API — `{"code":400,
"message":"Missing query parameter: index"}` and `{"code":400,"message":"Invalid
query parameter: index"}` for a non-numeric value.

`POST /setDiyImages` — batch upload / delete / reorder. Reconstructed shape:

```json
{"images":[{"index":1,"base64":"<image bytes, base64; a data: URI prefix is tolerated>"},
           {"index":2,"action":"delete"}],
 "imageOrder":[1],
 "enable":true}
```

- At least one of `images`, `imageOrder`, `enable` must be present
  (`At least one of images, imageOrder, or enable must be provided`).
- Each `images[]` entry needs an `index` (`Missing index`). With `base64` the
  file is sniffed for its MIME type and written as `/data/diy/<index>.<ext>`
  (`Invalid base64 data`, `Failed to write file`); the `action`/`deleted`
  literals indicate an entry can request deletion instead — the exact key
  value was not established.
- `imageOrder must contain all uploaded diy indices`.
- Reply: `{"code":200,"message":"DIY images processed successfully",
  "results":[{"index":…,"action":"saved"|"deleted",…}]}` (per-item `success`
  / `error` fields also exist).

Not exercised here, since it writes flash. `/data` is jffs2 with ~7.8 MB free.

---

## Navigation and input

The device can be driven remotely the same way the front buttons do it. Three
endpoints, all `POST`, all verified against `appVer 1.1.1`. *Source: live.*

### `/switchApp` — jump to a built-in app

Body `{"type": <type>, "index": <n>}`. `type` is one of `tools`, `social`,
`calendar` (the three built-in app groups). `index` is a **1-based index in the
device's own app order**, which is **not** the key order of `/getToolsConfig`
but **is** the id used in its `toolsOrder`. For `tools`, established by enabling
every tool and probing each index:

| index | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|-------|---|---|---|---|---|---|---|---|---|
| app | clock | weather | busy | scoreboard | tomato | stopwatch | battery | soundlight | ipshow |

Note clock and weather are swapped relative to the `/getToolsConfig` listing
(clock is the home app at index 1).

```bash
curl -s -X POST http://<device-ip>/switchApp \
  -H 'Content-Type: application/json' -d '{"type":"tools","index":1}'
# {"code":200,"message":"app switched","data":{"type":"tools","index":1}}
```

- `index` is 1-based; `0` or `>9` returns `{"code":400,"message":"Invalid app index"}`.
- Both `type` and `index` are required (`Missing required parameter: type` /
  `index`); a bad `type` gives `Invalid app type`.
- Switching to a **disabled** tool returns `{"code":404,"message":"app not
  found or disabled"}`; the device does **not** substitute another app. Only
  enabled tools switch.
- `menu manager unavailable` is a 5xx-class failure if the UI is not up.
- After a manual switch the carousel eventually resumes on its own timer.
- `social` and `calendar` use the same 1-based scheme into their own lists;
  those were not exercised here (no enabled providers on the test device).

### `/api/switchDiyApp?name=<app>` — jump to a custom app

Selects one of the custom (DIY) apps from `/api/customList` by name.

```bash
curl -s -X POST 'http://<device-ip>/api/switchDiyApp?name=popsquares'
# {"code":200,"message":"app switch requested","data":{"name":"popsquares","index":100}}
```

| reply | when |
|-------|------|
| `200 app switch requested`, `data.index` 100 | queued; the switch happens on the next UI tick |
| `400 Missing query parameter: name` | |
| `404 custom app not found` | no such app (`custom app not found or unavailable` also exists) |

The device also subscribes to `<prefix>/switchDiyApp` on MQTT for the same
action (see `MQTT.md`).

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
  `cw event only supports knob` / `ccw event only supports knob`.
- An unknown key or event gives `Invalid key or event`; a missing one gives
  `Missing required parameter: key` / `event`.

All three are unauthenticated and, like the rest of the API, forgeable
cross-origin from any web page (see `SECURITY.md`).

---

## System

### `/setLedRegister`

`POST`. Writes the LED driver's per-channel current-gain register (`0x16`,
decimal 22) through the pixel MCU. Each channel takes `0`–`63`; stock default
appears to be `30`. *Source: live.*

```json
{"rReg":22,"rVal":30,"gReg":22,"gVal":30,"bReg":22,"bVal":30}
```

Responses: `200 LED register set successfully`; `400 Invalid rReg or rVal` (and
the `g`/`b` equivalents) when a pair is missing or out of range; `400 Invalid
JSON request`.

This sets LED **drive current**, so it governs white balance and panel headroom —
useful for correcting a colour cast. Caveats:

- There is **no HTTP read-back**, so values cannot be fetched. Record what you
  have before changing anything. (The MCU protocol does have a
  `queryLedRegister`; the web layer simply does not expose it.)
- Raising gain raises drive current, which affects heat and LED lifetime.

The stock firmware ships a test harness for this at
`/res/ui/web/ledRegisterTest.html`, but it is **not routed** — every URL guess hits
the catch-all 301, so it was only ever usable by opening the file directly.

### `/checkUpdate`

`GET`. The device calls Ulanzi's cloud (`/firmware/checkUpdate`, with its
bearer token and a `DeviceSN` header) and passes the answer through. *Source:
live.* Two different replies were observed on this unit:

```json
{"needUpdate":false}                       // 2026-09-02
{"code":500,"message":"SSL certificate problem: unable to get local issuer certificate"}   // 2026-09-04
```

The stock page tolerates several shapes for a positive answer: `needUpdate` /
`hasUpdate` / `has_update` true, then either `mcu` and `app` objects with
`{version, downloadUrl | download_url, md5, size}` or those four fields flat at
the top level, plus `versionInfo`. The SSL failure is the device's HTTP client
reporting that it has no CA bundle (`not found cacert.pem` in the binary), so
any HTTPS hop fails; which part of the update path is HTTPS was not
established — the base URL is plain `http://` and the unauthenticated endpoint
does not redirect.

### `/update`

`POST`. **Flashes firmware.** Not exercised. *Source: web ui for the body,
firmware for the behaviour.*

```json
{"mcu":{"version":"…","downloadUrl":"http://…/x.fot","md5":"…","size":123},
 "app":{"version":"…","downloadUrl":"http://…/update.img","md5":"…","size":456}}
```

Either or both of `mcu` / `app`; `downloadUrl` may also be spelt
`download_url`. The device downloads to `/tmp/update_mcu.fot` and
`/tmp/update.img`, flashes, and reboots. Replies: `200 OTA update started`;
`400 Missing parameter: mcu/app.downloadUrl`; `OTA already in progress`.
Bluetooth is refused while an OTA runs.

The URL and checksum come from the caller, unauthenticated — see `SECURITY.md`.

### `/resetConfig`

`POST`, no body. **Factory reset.** Deletes `/data/setting.ini` (all settings,
wifi credentials, cloud tokens) and `/data/diy`, then reboots into setup-AP
mode. Not exercised. *Source: web ui / firmware.* Replies: `200 Config reset
successfully`; `Failed to delete config file`; `Failed to clear diy files`.

### `/setWifiConfig`

`POST {"ssid": "<1–32 chars>", "password": "<0–64 chars>"}`. Stores the
credentials, drops the setup AP if it was up, and joins the network. Reply
`{"code":200,"message":"WiFi config accepted"}` (an `accepted` field also
exists); errors `SSID is empty`, `SSID length must be 1-32`, `Password length
must be 0-64`, `Invalid request data`. *Source: web ui for the body, firmware
for the messages; not executed here, since it would drop the test device off
the network.* The full adoption flow is in `SETUP.md`.

In setup-AP mode the device runs a second, minimal server class
(`WifiConfigServer`) whose only API is this endpoint, with the same
validation; the normal server registers it too, so re-pointing an already
joined device works the same way.

The firmware **logs the SSID and password in clear** to `logcat` when this is
called (`Saving WiFi - SSID: %s, pwd = %s`) — see `SECURITY.md`.

### `/wifisave`

`POST`. The older, form-style counterpart of `/setWifiConfig`: on success it
serves the `wifiSave.html` result page, on failure an inline HTML error page.
The body encoding was not established (the current setup page does not use it;
it posts JSON to `/setWifiConfig` and then navigates to `/wifi/result`).
`GET` → 404. *Source: firmware.*

### `/setSn`

`POST {"sn": "<1–17 chars>"}`. **Rewrites the device serial** that `/getBase`
reports as `devSn` and that the cloud registration, the MQTT client id and the
discovery broadcast all use. Replies: `200 SN saved`; `400 Invalid SN: length
must be 1-17`; `Failed to write SN`. Not exercised, and don't: changing it
clears the cloud auth state. *Source: firmware.*

### `/setBluetooth`

`POST {"enable": true|false}` (the key is inferred: the handler reuses the
`enable` literal). Turns the BLE radio on or off; while advertising, the device
is named `Ulanzi TC002 <mac-tail>`. Replies: `200 Bluetooth enabled` /
`Bluetooth disabled`; `Bluetooth blocked during OTA`. Not exercised. *Source:
firmware.*

---

## Pages and assets

The stock settings UI, served from `/res/ui/web` (read-only squashfs).
*Source: live.*

| Path | Serves | Language |
|------|--------|----------|
| `/`, anything unknown | `301` → `/settings/general` | |
| `/settings/general` | `uclockConfig.html` | zh-CN |
| `/settings/info` | `uclockInfo.html` — versions, update, reset | zh-CN |
| `/settings/mqtt` | `uclockMqtt.html` | zh-CN |
| `/settings/social` | `uclockSocial.html` | zh-CN |
| `/settings/calendar` | `uclockCalendar.html` | zh-CN |
| `/settings/tools` | `uclockTools.html` | zh-CN |
| `/wifi/config` | `wifiConfig.html` — the setup form (also on the setup AP) | en |
| `/wifi/result` | `wifiSave.html` — "saved" page | en |
| `/settings/assets/common.css`, `common.js` | shared assets | |

### Web UI language

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
