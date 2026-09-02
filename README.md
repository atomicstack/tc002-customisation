# tc002-customisation

customising and controlling the [ulanzi tc002](https://www.ulanzi.com/en-eu/products/tc002-pixbar-smart-pixel-clock-ii)
pixel clock over its local network, without the ulanzi studio desktop app.

the tc002 runs linux on a sigmastar ssd21x soc and exposes an unauthenticated
http api on port 80 plus root `adbd` on port 5555. everything here talks to
those directly, so you can set the device up, control it, and drive the display
without installing anything from ulanzi.

## what's here

docs, one topic each:

| doc | what it covers |
|-----|----------------|
| [`HTTP-API.md`](HTTP-API.md) | the local http api on port 80: cors behaviour, every endpoint with examples, led current gain, and the web ui language dead end |
| [`DEVICE.md`](DEVICE.md) | what's inside: soc, kernel, partitions, the stripped busybox, root adb, flashing and recovery, and how it keeps time |
| [`SETUP.md`](SETUP.md) | the setup-ap, discovery and adoption flow that replaces ulanzi studio |
| [`CLOUD.md`](CLOUD.md) | what the device sends to ulanzi's cloud, how it authenticates, and why that's a problem |
| [`MQTT.md`](MQTT.md) | driving the 52×16 display over a broker you control |
| [`CUSTOM-APP.md`](CUSTOM-APP.md) | the custom-app frame payload shared by http and mqtt: text, draw primitives, bitmaps, gifs, lifecycle |
| [`SECURITY.md`](SECURITY.md) | every security observation in one place, with mitigations |

tools:

| file | what it is |
|------|-----------|
| [`tc002-adopt.py`](tc002-adopt.py) | discover tc002 devices on the lan and join a factory-fresh one to wifi — replaces ulanzi studio for setup |
| [`panel/`](panel/) | an english web control panel for the device (the stock ui is chinese-only) |
| [`mqtt-check.py`](mqtt-check.py) | verify mosquitto broker credentials from the raw mqtt connack code |

related: [pixdeck](https://github.com/cailurus/PixDeck) is a working stock-firmware
client for the custom-app protocol over both http and mqtt — its `pixbar_core.py`
and `plugins/` are the source for most of [`CUSTOM-APP.md`](CUSTOM-APP.md).

## quick start

everything uses apple's `/usr/bin/python3` deliberately — see
[the local network gotcha](#a-note-on-macos) below.

**find a device already on your wifi**

```bash
/usr/bin/python3 tc002-adopt.py discover --subnet 10.0.0
```

**control it in english**

```bash
cd panel && /usr/bin/python3 serve.py 8777
# open http://127.0.0.1:8777  (override the target with ?host=<device-ip>)
```

the panel covers display/general settings, mqtt (with live connection status),
the nine built-in apps, and led current-gain calibration behind a confirmation.
it reads current values and merges edits into the full object before posting,
so unshown fields are preserved. `serve.py` serves the page and proxies
`/api/<device-ip>/<endpoint>` through to the device, so the browser only ever
talks to its own origin: the device only returns cors headers on preflights
and 404s, never on real 200 responses, so a browser can't read from it directly
and a plain `http.server` will not work (see the
[cors note](HTTP-API.md#http-api)).

**adopt a factory-fresh device**

a device with no stored wifi credentials hosts a wpa2 ap called `U-Clock` and
serves `192.168.1.x`. join that network, then:

```bash
/usr/bin/python3 tc002-adopt.py adopt --ssid <your-wifi>
```

the full flow is in [`SETUP.md`](SETUP.md).

**verify your mqtt broker credentials**

```bash
/usr/bin/python3 mqtt-check.py <broker-ip> 1883
```

prompts for the password with echo off so it never reaches a transcript or
shell history. `code=0` means valid. note that mosquitto returns `5` (not
authorized) rather than the spec's `4` for bad credentials, so treat `5` as
"wrong username/password".

## what's been established

the device:

- **soc / os** — sigmastar ssd21x, linux 4.9.84, ~32 mb ram, squashfs root.
  the app layer is the flythings stack (`zkdaemon` / `zkdisplay` / `zkgui`).
  ([`DEVICE.md`](DEVICE.md))
- **http api (port 80, no auth)** — read/write of every setting via json
  endpoints (`getConfig`/`setConfig`, `getMqttConfig`/`setMqttConfig`,
  `getToolsConfig`, `getCalendar`, `getSocial`, `setWifiConfig`,
  `setLedRegister`, and destructive `update`/`resetConfig`), plus the display
  itself via `api/custom` / `api/customList`, and remote navigation via
  `switchApp` / `switchDiyApp` / `keyEvent` — no broker needed.
  ([`HTTP-API.md`](HTTP-API.md))
- **adb (port 5555)** — wifi only (usb is mass-storage); gives a **root** shell,
  though busybox is stripped to almost nothing and `/data` is the only
  persistent writable mount. ([`DEVICE.md`](DEVICE.md))
- **mqtt** — the other way to drive the 52×16 display without ulanzi studio;
  custom-app topic `[prefix]/custom/[app]` with the same `{duration,text,image,draw}`
  payload as `api/custom`. ([`MQTT.md`](MQTT.md), [`CUSTOM-APP.md`](CUSTOM-APP.md))
- **setup** — factory-fresh devices come up as the `U-Clock` softap on
  `192.168.1.1`; `POST /setWifiConfig` joins them to a network.
  ([`SETUP.md`](SETUP.md))
- **time** — no rtc; the app's own sntp client steps the clock from four
  hardcoded chinese ntp ips at boot and about every 2 h. no api to set it, but
  `adb shell date -s` works. ([`DEVICE.md`](DEVICE.md#time))
- **cloud** — the device registers itself with `api.ulanzistudio.com` over
  plain http and keeps a per-device secret key plus a bearer/refresh token pair
  in `setting.ini`. weather, social counts, calendars and the update check all
  go through that api, and caldav credentials are sent to it for server-side
  fetching. ([`CLOUD.md`](CLOUD.md))

security caveats worth knowing before you put one on your main network: no auth
on anything, writes forgeable from any web page you visit (the device ignores
`Origin`), root adb with no pairing, the wifi psk stored in cleartext in a
world-readable file on the device, and all cloud traffic (calendar passwords
included) sent unencrypted. an isolated iot vlan/ssid is the sensible
home for it. full detail in [`SECURITY.md`](SECURITY.md).

## a note on macos

on macos 15+ (sequoia), local network privacy gates lan access **per binary**.
apple's own binaries (`/usr/bin/curl`, `/usr/bin/python3`, `/sbin/ping`,
`/usr/bin/nc`) are exempt; homebrew- and third-party-installed binaries
(including a properly signed `adb`) are blocked until the **terminal app** is
granted permission, and the denial surfaces as a misleading network error,
never a permission error:

| tool | symptom |
|------|---------|
| `adb connect` | `failed to connect to '<ip>:5555': No route to host` |
| `nmap` | `Host seems down` / all ports `filtered (host-unreach)` |

that split is the diagnostic: if `/usr/bin/curl` works and
`/opt/homebrew/bin/nmap` does not, it is the permission, not the network. it is
also why the tools here call `/usr/bin/python3` explicitly.

**fix:** system settings → privacy & security → local network → enable your
terminal app, then **fully quit and relaunch it** (the permission is evaluated
at process launch; a new tab is not enough).

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
```

## status

- discovery, the control panel, the mqtt checker, and all documented read
  endpoints are **verified against a live device**.
- the `adopt` / `setWifiConfig` write path is documented from the firmware's own
  setup page but **not executed** here, since it would drop the test device off
  the network. confirm it against a factory-fresh unit before relying on it.

## disclaimer

unofficial, reverse-engineered from a device on the local network and from the
ulanzi studio installer. not affiliated with or endorsed by ulanzi. the http api
and adb access it relies on are undocumented and may change or break in a
firmware update. you are responsible for what you do to your own hardware —
`resetConfig`, `update`, and `setLedRegister` in particular can disrupt or
degrade the device. recovery to factory firmware is holding the reset button
during power-up.

## references

- [UlanziTechnology/Ulanzi-U-Clock-TC002](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002)
- [FlyThings ADB docs](https://zkswe.github.io/flythings-doc/en/adb_debug.html)
