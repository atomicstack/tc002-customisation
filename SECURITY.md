# Ulanzi TC002 — security observations

Findings about the device itself, collected while reverse-engineering it, with
the mitigations that follow from them. This is not a vulnerability-disclosure
policy for this repository.

These are properties of the device, not of anything installed on the Mac:

1. **The setup AP is not a security boundary, and its key is the same on every
   unit.** A factory-fresh device hosts a WPA2 access point `U-Clock` until it
   is adopted. `libzknet.so` stores no key: it derives one with
   `PKCS5_PBKDF2_HMAC_SHA1` from `persist.sys.softap.pwd` over
   `persist.sys.softap.ssid`, and falls back to the constant **`12345678`** when
   that property is empty — which is how it ships. Both inputs are firmware
   constants, so the derived 64-hex `wpa_psk` in `/data/misc/wifi/hostapd.conf`
   is **identical on every TC002**, which is why the key appears as a literal in
   no binary yet opens any unit's AP. Anyone **in radio range** — no LAN access
   needed — can join and reach the whole unauthenticated HTTP API on
   `192.168.100.1`, including `POST /setWifiConfig`, which moves the clock onto
   a network they control. Recovered by deriving candidates against one unit's
   stored key and confirmed by opening a different unit's AP
   ([`SETUP.md`](SETUP.md)). Adopt promptly, on a network you trust; flashing
   the runtime ([`INSTALL.md`](INSTALL.md)) removes the stock setup flow
   entirely.

2. **No authentication on any endpoint.** Anyone on the LAN can read and write
   every setting, including triggering `/resetConfig` and `/update`. `/update`
   takes the firmware **download URL and checksum from the request body**, so
   it will fetch and flash whatever it is pointed at, and the flasher
   **checks no signature**, only a device code, a crc and an md5 that anyone
   can compute ([`FIRMWARE.md`](FIRMWARE.md#the-updateimg-container)), so a
   LAN neighbour can put arbitrary code on the device. `/setSn` likewise
   lets anyone rewrite the device serial.
3. **Credentials are returned in plaintext.** `/getCalendar` returns calendar
   `password` fields and `/getSocial` returns OAuth `token` values in clear
   text over unencrypted HTTP.
4. **No TLS.** Everything is plain HTTP on port 80.

5. **adb is open on 5555, and over the usb cable** with no pairing step, and `adbd` runs as **root** —
   everything on the device runs as uid 0 with no privilege separation.
6. **The wifi PSK is stored in cleartext** in `/data/setting.ini` at mode `0666`
   (world readable and writable), alongside the device serial and social tokens,
   and the `/setWifiConfig` handler **also logs it in clear to `logcat`**
   (`Saving WiFi - SSID: %s, pwd = %s`). It is *not* exposed over HTTP — every
   endpoint was checked for the literal value — but anyone who can reach port
   5555 gets a root shell and can read both. Note also that it is not readable
   *back* over HTTP but it is **sent** in the clear during adoption, over the
   shared-key AP in item 1.
7. **Writes are forgeable from any web page.** The device ignores `Origin`,
   accepts JSON bodies sent as `text/plain`, and approves `POST` in its CORS
   preflight (see [HTTP-API.md](HTTP-API.md#http-api)). So a page on any
   website can fire `/resetConfig`, `/update`, `/setWifiConfig` or
   `/setMqttConfig` at the device from a visitor's browser with no user
   interaction — the browser hides the reply, but the device has already acted.
   Verified with a no-op cross-origin `POST /setConfig` from
   `Origin: http://evil.example`: `200`, saved. Nothing on the device prevents
   this. Some browsers' private-network-access protections may, but that
   varies by browser and version and was not tested here. The display itself
   is in the same position: `POST /api/custom?name=<app>` (see
   [HTTP-API.md](HTTP-API.md#custom-apps)) lets any LAN host — or any web page
   a LAN user visits — put arbitrary text or images on the clock, or wipe a
   custom app by posting `{}`.
8. **All cloud traffic is plain HTTP.** Device registration, bearer tokens,
   and any CalDAV username/password you configure go to
   `api.ulanzistudio.com` unencrypted. See `CLOUD.md`.
9. **The cloud secret key is logged in cleartext** to `logcat`, which is
   readable over the unauthenticated adb.
10. **Cloud registration is unauthenticated.** It needs only the serial and
   MAC, which `/getBase` gives to anyone on the LAN, and which the device
   also **broadcasts to the whole segment every second** on udp/55555 (see
   `SETUP.md`), so no request is even needed. The consequence of a
   third party re-registering your device was not tested.

Reasonable mitigation: put the device on an isolated IoT VLAN/SSID and
restrict which hosts may reach it. That also bounds the cross-site write
exposure to browsers on the hosts you let through. If you don't use the
cloud-backed apps, also block its outbound internet, and avoid giving it
calendar credentials you care about.

## the custom runtime (`runtime/`)

while the custom runtime described in [`RUNTIME.md`](RUNTIME.md) is running,
the stock app and its unauthenticated api are not, and the picture changes:

- **the clock advertises itself over mdns.** `netd` answers for
  `tc002-<full mac>.local` and `_tc002._tcp`, so anyone on the lan can enumerate
  the clocks on it and learn each one's mac and address without authenticating;
  `dns-sd -B _tc002._tcp` is enough. that is the point of the feature, and it
  discloses nothing the stock firmware's udp/55555 broadcast did not already,
  but it is one more reason the clock belongs on a network you control. the
  responder's ownership rules (a source port of 5353 and an observed ttl of 255)
  keep off-link packets from renaming it, and are not authentication: another
  host on the same link can claim the name. it is on by default; the `mdns`
  setting turns it off, which withdraws the name from every cache on the lan.
  see [`RUNTIME.md`](RUNTIME.md#discovery-mdns).
- **every api route needs a bearer token**, including reads. two random
  256-bit tokens (control and admin) are generated per runtime directory,
  compared in constant time, stored at mode 0600 under `/data/tc002/state/credentials/`
  (directory 0700) — **on the jffs2 partition, not tmpfs**, so they survive a power cycle and are
  cleared only by a factory reset,
  and never logged or returned. durable settings and the mqtt password need
  the admin token; the password is never returned by the api. the file is
  labelled text (`control=<64 hex>` / `admin=<64 hex>`) so that choosing a
  token is deliberate: **an admin token satisfies control routes too**, so an
  integration handed the wrong one is over-privileged and nothing says so.
  **named client tokens** ([`RUNTIME.md`](RUNTIME.md#scopes)) give an integration
  its own credential: issued by `POST /api/v1/tokens` under the admin token,
  revocable one at a time by `DELETE /api/v1/tokens/{name}`, taking effect on the
  next request with no restart. a client token holds a **set of scopes** rather
  than a rank — `notify` alone is a token that can raise a notification and do
  nothing else — and never `tokens`, so it cannot mint more of itself. a command
  from one is named in the log ring, and the secret is returned exactly once.
  **`input` is the scope to grant deliberately**: injecting button events drives
  the physical ui, and the knob's hold opens the device menu, which reaches
  brightness, the night schedule, the ip layout, mqtt and ntfy on or off — which
  `display` and `settings` gate over http — **and a reboot, which has no http
  route at all**: `ActionKind` is `brightness reseed arm_stream power`. so
  `/input` reaches *past* `settings` here rather than merely as far. that was
  always true of any token that could post to `/input`; scopes are what make it
  refusable.
  gap: the two built-in tokens still have no rotation — changing either means
  deleting the file and restarting, which invalidates every client at once.
- **browser writes require bearer authentication and an allowed origin.** the
  device-hosted `/api/docs` page may call its own origin (`http://` plus the
  request host). any other `Origin` needs the explicit allow list, empty by
  default. no cors headers or cookie credentials are used. reference assets
  are public and contain no device state; every `/api/v1` route is authenticated.
  the destructive stock endpoints (`update`, `resetConfig`, `setWifiConfig`,
  `setSn`) do not exist.
- **writable home-assistant discovery is separately opt-in.** `discovery_controls`
  defaults to false. enabling it also grants broker writers access to an explicit
  allowlist of durable clock/time/night settings. mqtt cannot set the opt-in or
  change discovery, credentials, script execution, battery or other privileged
  settings. turning it off refuses those durable writes and removes the writable
  discovery records. existing transient mqtt controls keep their existing behavior.
- **the network daemon is unprivileged.** `tc002-netd` runs as uid 1001 with
  two inherited descriptors and no access to the token or settings files.
  gap: `/dev/socket/property_service` is world-writable on this init, so the
  uid change alone does not deny it the property service.
- **scripts run on the device, and that is the largest thing a token buys.**
  the berry interpreter ([`SCRIPTING.md`](SCRIPTING.md)) is **off by default** and
  `tc002-berryd` is not spawned until `berry.enabled`. storing a script needs the
  **admin** token, not the control token, because a script drives the panel
  indefinitely where a notification is one event. there is deliberately **no
  `eval` route**: nothing accepts source and runs it without storing it, so there
  is no separate arbitrary-code surface to gate. what a stored script can reach is
  bounded by construction rather than by policy — it runs as uid 1001 with **no
  network descriptor** (it cannot bind, connect or resolve), **no filesystem**
  (`BE_USE_FILE_SYSTEM` is off, `be_filelib.c` is not compiled in, and the entry
  points the linker still wants refuse), and **no binding to settings, tokens or
  credentials**. a fixed heap and a handler deadline mean a runaway script is
  stopped inside its own vm, and a wedged one is a process the supervisor kills.
  gap: scripts are stored in clear on `/data`, readable by root, and anyone with
  the admin token can replace `autoexec`, which runs on every start.
- **still no tls.** the tokens travel in plain http and plain mqtt; anyone on
  the network path can read them. the build reports `transport: plaintext`
  and is intended for an isolated lan only.
- **adb can be gated by a physical gesture.** in the `hardened` profile the
  supervisor turns `adbd` off at boot and on for fifteen minutes when the
  knob is held for three seconds; the default `dev` profile leaves adbd as
  it is. neither has been exercised on the device yet.
- **the cloud client is gone** with the stock app: nothing talks to
  `api.ulanzistudio.com`, and no calendar or social credentials are sent
  anywhere. the clock is set by the runtime's own sntp client against a server
  you configure, which is unauthenticated — see `RUNTIME.md`.

the mqtt password, when set, is written in clear to the runtime's settings
file (`/data/tc002/state/config/config.json`, mode 0600, root only). ~~tmpfs~~ — **✗ it is the
persistent jffs2 partition**, so a plaintext broker password now survives reboots in flash rather
than vanishing with tmpfs. that is a change in exposure, not just in path.
