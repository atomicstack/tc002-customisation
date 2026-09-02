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

It also phones home to `api.ulanzistudio.com` over **plain HTTP** for weather,
social counts, calendars and the update check — see
[Cloud authentication](#cloud-authentication).

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
  [Security observations](#security-observations).

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

---

## Cloud authentication

Besides the local API, the firmware talks **outbound** to Ulanzi's cloud, and
three keys in `/data/setting.ini` exist only for that:

| `setting.ini` key | What it is |
|-------------------|------------|
| `secretKey` | 32-hex per-device credential, issued by the cloud at registration |
| `authToken` | HS256 JWT (claims `deviceSn`, `pid`, `ts`, `exp`), 2-hour lifetime |
| `authRefreshToken` | 32-hex refresh credential, 7-day lifetime |
| `tokenExpireTime`, `refreshTokenExpireTime` | unix expiry of the two above |

The logic is `awtrix::AuthManager` (`src/awtrix/http/AuthManager.cpp`) inside
the app library `/res/lib/libzkgui.so`. The base URL is hardcoded:

```
http://api.ulanzistudio.com/api/uclock
```

### Flow

1. **Register** — `POST /device/register` with `{deviceSn, macAddress,
   initTimestamp}`. No credential is required. The response carries
   `secretKey`, which the device stores.
2. **Token** — `POST /auth/token` with `deviceSn`, a unix timestamp and

   ```
   signature = md5(secretKey + deviceSn + timestamp)   # lowercase hex
   ```

   The response carries the JWT, a `refreshToken` and `expireIn` (7200 s).
   The formula was confirmed by recomputing a signature the device had logged.
3. **Refresh** — when the JWT is expiring, `POST /auth/refresh` with the refresh
   token returns a new JWT (and sometimes a new refresh token). If that fails
   the device signs a fresh `/auth/token`; if *that* fails it re-registers. A
   changed serial or MAC also clears the stored auth state.

### What the token is for

Every cloud call carries `Authorization: Bearer <authToken>` and, from the
adjacent string table, a `DeviceSN` header:

| Cloud path | Used by |
|------------|---------|
| `/weather/weatherInfo` | weather app (`city`) |
| `/follower/<platform>` | social apps' follower counts (`uid`) |
| `/tokenInfo`, `/authorizeUrl` | social OAuth status and login |
| `/caldav/fetchServerEvents` | iCloud / Feishu / DingTalk / WeCom calendars — sends `serverUrl`, `period` and the stored `username` / `password`; **the cloud performs the CalDAV fetch** |
| `/caldav/fetchWebCalEvents` | Google / Outlook calendars (`url`) |
| `/firmware/checkUpdate` | the local `/checkUpdate` endpoint |

Nothing local depends on these keys: the HTTP API, the web pages and MQTT never
read them, no local endpoint returns them, and Ulanzi Studio does not reference
them either.

### Observations

- **Plain HTTP.** The base URL is `http://`, and `api.ulanzistudio.com` answers
  on port 80 without redirecting to HTTPS. `logcat` shows successful
  registration, token issue and weather fetches against it. So the secret key
  (in the register response), every bearer token, and any CalDAV
  username/password cross the internet unencrypted. This is inferred from the
  URL, the server's behaviour and the logs, not from a packet capture.
- **The secret key is logged.** `AuthManager` prints it to `logcat` at
  registration and again inside `calculateSignature`. Anyone with adb reads it.
- **Registration is unauthenticated** and needs only serial + MAC, both of
  which the local `/getBase` hands to anyone on the LAN. Whether a repeat
  registration rotates the key was **not tested**, since doing so could
  invalidate a live device's credential.
- **Calendar credentials leave your network.** Configuring a CalDAV provider
  means Ulanzi's server receives the server URL and password and does the
  fetch on the device's behalf.

### Mitigation

If weather, social counts, calendars and the update check are not needed, block
the device's outbound internet at the router. The local API and MQTT do not
involve the cloud, so they should keep working; running the device that way has
not been tested here for side effects such as retry spam in `logcat`.

---

## Security observations

These are properties of the device, not of anything installed on the Mac:

1. **No authentication on any endpoint.** Anyone on the LAN can read and write
   every setting, including triggering `/resetConfig` and `/update`.
2. **Credentials are returned in plaintext.** `/getCalendar` returns calendar
   `password` fields and `/getSocial` returns OAuth `token` values in clear
   text over unencrypted HTTP.
3. **No TLS.** Everything is plain HTTP on port 80.
4. **adb is open on 5555** with no pairing step, and `adbd` runs as **root** —
   everything on the device runs as uid 0 with no privilege separation.
5. **The wifi PSK is stored in cleartext** in `/data/setting.ini` at mode `0666`
   (world readable and writable), alongside the device serial and social tokens.
   It is *not* exposed over HTTP — every endpoint was checked for the literal
   value — but anyone who can reach port 5555 gets a root shell and can read it.
6. **Writes are forgeable from any web page.** The device ignores `Origin`,
   accepts JSON bodies sent as `text/plain`, and approves `POST` in its CORS
   preflight (see [HTTP API](#http-api)). So a page on any website can fire
   `/resetConfig`, `/update`, `/setWifiConfig` or `/setMqttConfig` at the device
   from a visitor's browser with no user interaction — the browser hides the
   reply, but the device has already acted. Verified with a no-op cross-origin
   `POST /setConfig` from `Origin: http://evil.example`: `200`, saved. Nothing on
   the device prevents this. Some browsers' private-network-access protections
   may, but that varies by browser and version and was not tested here.
7. **All cloud traffic is plain HTTP.** Device registration, bearer tokens,
   and any CalDAV username/password you configure go to
   `api.ulanzistudio.com` unencrypted. See
   [Cloud authentication](#cloud-authentication).
8. **The cloud secret key is logged in cleartext** to `logcat`, which is
   readable over the unauthenticated adb.
9. **Cloud registration is unauthenticated.** It needs only the serial and
   MAC, which `/getBase` gives to anyone on the LAN. The consequence of a
   third party re-registering your device was not tested.

Reasonable mitigation: put the device on an isolated IoT VLAN/SSID and
restrict which hosts may reach it. That also bounds the cross-site write
exposure to browsers on the hosts you let through. If you don't use the
cloud-backed apps, also block its outbound internet, and avoid giving it
calendar credentials you care about.

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
`authRefreshToken`) — see [Cloud authentication](#cloud-authentication).

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

## Initial setup / adoption (replacing Ulanzi Studio)

A factory-fresh TC002 with no stored wifi credentials boots into **setup-AP
mode** instead of joining a network:

- It runs `hostapd` + `dnsmasq` and hosts a WPA2 access point **`U-Clock`**
  (channel 6, broadcast SSID). The AP name is in `getprop` as
  `persist.sys.softap.ssid`; `persist.softap.on` is `1` in this mode, `0` once
  joined.
- On that AP it is the gateway at **`192.168.1.1`** and hands out DHCP leases
  from `192.168.1.101`-`192.168.1.200` (`/etc/dnsmasq.conf`). This is the
  `192.168.1.x` address shown on the display at first power-on.
- The same HTTP server runs, so the setup pages `wifiConfig.html` /
  `wifiSave.html` are reachable at `http://192.168.1.1/`.

**Join it to a network** — `POST /setWifiConfig`:

```json
{"ssid": "<your-wifi>", "password": "<your-wifi-password>"}
```

Returns `{"code":200}` on success, after which the device drops the AP and
joins the target network. The web UI then redirects to `/wifi/result`.

**Discovery once on the LAN.** Ulanzi Studio finds devices by UDP broadcast
(the app has a `discoverTC002` routine over `QUdpSocket`), but the device does
**not** advertise mDNS/Bonjour in station mode, and udp/36202 on the device is
an ephemeral client socket, not a responder. The robust, protocol-independent
method is an HTTP sweep: any host answering `GET /getBase` with a JSON object
carrying `{devSn, mac, mcuVer, appVer, ssid, ip}` is a TC002. `tc002-adopt.py`
does exactly this.

```bash
# find devices already on your wifi
/usr/bin/python3 tc002-adopt.py discover --subnet 10.0.0

# adopt a factory-fresh device (after joining its "U-Clock" ap)
/usr/bin/python3 tc002-adopt.py adopt --ssid <your-wifi>
```

The macOS side of joining the `U-Clock` AP is manual (or scriptable with
`networksetup -setairportnetwork`), because the device's on-AP `wpa_psk` is a
pre-derived 64-hex key rather than a passphrase.

> **Verification status:** discovery is verified end-to-end against a live
> device. The `setWifiConfig` call is documented from the firmware's own
> `wifiConfig.html` (payload shape, `code==200`, `/wifi/result` redirect) but
> has **not** been executed here, since it would drop the test device off the
> network. Confirm against a factory-fresh unit before relying on it.

---

## Tools in this repo

- **`panel/index.html`** — English control panel for the device. Serve it locally
  and open it in a browser:

  ```bash
  cd panel && /usr/bin/python3 serve.py 8777
  # then open http://127.0.0.1:8777  (override target with ?host=<device-ip>)
  ```

  `serve.py` serves the page and proxies `/api/<device-ip>/<endpoint>` through to
  the device, so the browser only ever talks to its own origin. A plain
  `http.server` will *not* work — see the CORS note above.

  Covers display/general settings, MQTT (with live connection status), the nine
  built-in apps, and LED current gain behind a confirmation. It reads current
  values and merges edits into the full object before posting, so unshown fields
  are preserved. Note it must be served over `http://` from your own machine —
  `/usr/bin/python3` is used deliberately because Homebrew binaries are blocked by
  Local Network Privacy.

- **`tc002-adopt.py`** — discovers TC002 devices on the LAN by HTTP fingerprint
  and joins a factory-fresh one to wifi via `/setWifiConfig`, replacing the
  Ulanzi Studio desktop app for setup. See the adoption section above.

- **`mqtt-check.py`** — verifies mosquitto credentials by reading the raw MQTT
  CONNACK return code. Prompts for the password with echo off so it never reaches
  a transcript or shell history.

  ```bash
  /usr/bin/python3 mqtt-check.py <broker-ip> 1883
  ```

  `code=0` means valid. Note **mosquitto returns `5` (not authorized) rather than
  the spec's `4`** for bad credentials, so treat `5` as "wrong username/password".

---

## References

- [UlanziTechnology/Ulanzi-U-Clock-TC002](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002)
- [FlyThings ADB docs](https://zkswe.github.io/flythings-doc/en/adb_debug.html)
