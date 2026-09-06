# Ulanzi TC002 — security observations

Findings about the device itself, collected while reverse-engineering it, with
the mitigations that follow from them. This is not a vulnerability-disclosure
policy for this repository.

These are properties of the device, not of anything installed on the Mac:

1. **No authentication on any endpoint.** Anyone on the LAN can read and write
   every setting, including triggering `/resetConfig` and `/update`. `/update`
   takes the firmware **download URL and checksum from the request body**, so
   it will fetch and flash whatever it is pointed at; whether the image is
   signature-checked before flashing was not established. `/setSn` likewise
   lets anyone rewrite the device serial.
2. **Credentials are returned in plaintext.** `/getCalendar` returns calendar
   `password` fields and `/getSocial` returns OAuth `token` values in clear
   text over unencrypted HTTP.
3. **No TLS.** Everything is plain HTTP on port 80.
4. **adb is open on 5555** with no pairing step, and `adbd` runs as **root** —
   everything on the device runs as uid 0 with no privilege separation.
5. **The wifi PSK is stored in cleartext** in `/data/setting.ini` at mode `0666`
   (world readable and writable), alongside the device serial and social tokens,
   and the `/setWifiConfig` handler **also logs it in clear to `logcat`**
   (`Saving WiFi - SSID: %s, pwd = %s`). It is *not* exposed over HTTP — every
   endpoint was checked for the literal value — but anyone who can reach port
   5555 gets a root shell and can read both.
6. **Writes are forgeable from any web page.** The device ignores `Origin`,
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
7. **All cloud traffic is plain HTTP.** Device registration, bearer tokens,
   and any CalDAV username/password you configure go to
   `api.ulanzistudio.com` unencrypted. See `CLOUD.md`.
8. **The cloud secret key is logged in cleartext** to `logcat`, which is
   readable over the unauthenticated adb.
9. **Cloud registration is unauthenticated.** It needs only the serial and
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

- **every api route needs a bearer token**, including reads. two random
  256-bit tokens (control and admin) are generated per runtime directory,
  compared in constant time, stored at mode 0600 under `/tmp/tc002/credentials/`,
  and never logged or returned. durable settings and the mqtt password need
  the admin token; the password is never returned by the api.
- **browser writes are refused.** a request carrying an `Origin` header is
  answered `403` unless the origin is on an explicit allow list (empty by
  default), and no cors headers are ever emitted. the destructive stock
  endpoints (`update`, `resetConfig`, `setWifiConfig`, `setSn`) do not exist.
- **the network daemon is unprivileged.** `tc002-netd` runs as uid 1001 with
  two inherited descriptors and no access to the token or settings files.
  gap: `/dev/socket/property_service` is world-writable on this init, so the
  uid change alone does not deny it the property service.
- **still no tls.** the tokens travel in plain http and plain mqtt; anyone on
  the network path can read them. the build reports `transport: plaintext`
  and is intended for an isolated lan only.
- **adb can be gated by a physical gesture.** in the `hardened` profile the
  supervisor turns `adbd` off at boot and on for fifteen minutes when the
  knob is held for three seconds; the default `dev` profile leaves adbd as
  it is. neither has been exercised on the device yet.
- **the cloud client is gone** with the stock app: nothing talks to
  `api.ulanzistudio.com`, and no calendar or social credentials are sent
  anywhere. (nothing syncs the clock either; see `RUNTIME.md`.)

the mqtt password, when set, is written in clear to the runtime's settings
file (`/tmp/tc002/config/config.json`, mode 0600, root only, tmpfs).
