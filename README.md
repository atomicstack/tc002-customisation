# tc002-customisation

customising and controlling the [ulanzi tc002](https://www.ulanzi.com/en-eu/products/tc002-pixbar-smart-pixel-clock-ii)
pixel clock over its local network, without the ulanzi studio desktop app.

the tc002 runs linux on a sigmastar ssd21x soc and exposes an unauthenticated
http api on port 80 plus root `adbd` on port 5555. everything here talks to
those directly, so you can set the device up, control it, and drive the display
without installing anything from ulanzi.

## what's here

| file | what it is |
|------|-----------|
| [`HTTP-API.md`](HTTP-API.md) | the reference: full http api, mqtt, adb, device internals, security notes, and the setup/adoption flow. start here. |
| [`tc002-adopt.py`](tc002-adopt.py) | discover tc002 devices on the lan and join a factory-fresh one to wifi — replaces ulanzi studio for setup |
| [`panel/`](panel/) | an english web control panel for the device (the stock ui is chinese-only) |
| [`mqtt-check.py`](mqtt-check.py) | verify mosquitto broker credentials from the raw mqtt connack code |

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
the nine built-in apps, and led current-gain calibration. it serves the page
and proxies api calls through itself, because the device only returns cors
headers on preflights and 404s, never on real 200 responses — a browser can't
read from it directly.

**adopt a factory-fresh device**

a device with no stored wifi credentials hosts a wpa2 ap called `U-Clock` and
serves `192.168.1.x`. join that network, then:

```bash
/usr/bin/python3 tc002-adopt.py adopt --ssid <your-wifi>
```

## what's been established

the device:

- **soc / os** — sigmastar ssd21x, linux 4.9.84, ~32 mb ram, squashfs root.
  the app layer is the flythings stack (`zkdaemon` / `zkdisplay` / `zkgui`).
- **http api (port 80, no auth)** — read/write of every setting via json
  endpoints (`getConfig`/`setConfig`, `getMqttConfig`/`setMqttConfig`,
  `getToolsConfig`, `getCalendar`, `getSocial`, `setWifiConfig`,
  `setLedRegister`, and destructive `update`/`resetConfig`).
- **adb (port 5555)** — wifi only (usb is mass-storage); gives a **root** shell,
  though busybox is stripped to almost nothing and `/data` is the only
  persistent writable mount.
- **mqtt** — the supported way to drive the 52×16 display without ulanzi studio;
  custom-app topic `[prefix]/custom/[app]` with a `{duration,text,image,draw}`
  payload.
- **setup** — factory-fresh devices come up as the `U-Clock` softap on
  `192.168.1.1`; `POST /setWifiConfig` joins them to a network.

security caveats worth knowing before you put one on your main network: no auth
on anything, writes forgeable from any web page you visit (the device ignores
`Origin`), root adb with no pairing, and the wifi psk stored in cleartext in a
world-readable file on the device. an isolated iot vlan/ssid is the sensible
home for it. full detail in [`HTTP-API.md`](HTTP-API.md#security-observations).

## a note on macos

on macos 15+ (sequoia), local network privacy gates lan access **per binary**.
apple's own binaries (`/usr/bin/curl`, `/usr/bin/python3`, `/sbin/ping`) are
exempt; homebrew- and third-party-installed binaries (including a properly
signed `adb`) are blocked, and the denial surfaces as a misleading
`no route to host` / `host is down`, never a permission error. that's why the
tools here call `/usr/bin/python3` explicitly. for `adb`, grant your terminal
app local network access in system settings and fully relaunch it.

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
