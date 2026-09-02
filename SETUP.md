# Ulanzi TC002 — initial setup / adoption (replacing Ulanzi Studio)

How a factory-fresh TC002 gets onto your wifi, how to find it once it's there,
and how `tc002-adopt.py` does both without the Ulanzi Studio desktop app. Part
of [tc002-customisation](README.md); the endpoints involved are in
[HTTP-API.md](HTTP-API.md).

> Identifiers (serial, MAC, SSID) are replaced with placeholders.

---

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
