# Ulanzi TC002 — initial setup / adoption (replacing Ulanzi Studio)

How a factory-fresh TC002 gets onto your wifi, how to find it once it's there,
and how `tc002-adopt.py` does both without the Ulanzi Studio desktop app. The
endpoints involved are in `HTTP-API.md`.

> Identifiers (serial, MAC, SSID) are replaced with placeholders.

---

**If you just want it adopted and running the custom runtime**, none of the
below has to be done by hand — `./tc002-onboard.sh --wifi-ssid <your network>`
does the adoption, the safety checks, the backup and the image build in one
command, and [`INSTALL.md`](INSTALL.md) is the full walkthrough including
dependencies and the timezone/NTP step. The rest of this file is what adoption
is doing, and how to do it by hand.

A factory-fresh TC002 with no stored wifi credentials boots into **setup-AP
mode** instead of joining a network:

- It runs `hostapd` + `dnsmasq` and hosts a WPA2 access point **`U-Clock`**
  (channel 6, `hw_mode=g`, broadcast SSID). The AP name is in `getprop` as
  `persist.sys.softap.ssid`; `persist.softap.on` is `1` in this mode, `0` once
  joined.
- **The passphrase is `12345678`, on every unit.** `libzknet.so` stores no key:
  it derives one with `PKCS5_PBKDF2_HMAC_SHA1` from `persist.sys.softap.pwd`
  over the SSID, and falls back to `12345678` when that property is empty —
  which is how it ships. Since the SSID is fixed too, the derived 64-hex
  `wpa_psk` in `/data/misc/wifi/hostapd.conf` is **identical on every TC002**,
  which is why the key is a literal in no binary yet opens any clock's AP. See
  "The setup AP is not a security boundary" below.
- On that AP it is the gateway at **`192.168.100.1`** and hands out DHCP leases
  from `192.168.100.x` with a one-hour lease, serving itself as both router and
  DNS. **`/etc/dnsmasq.conf` is not what runs** — it says
  `192.168.1.101`-`192.168.1.200`, and `libzknet.so` carries both subnets; the
  measured one is `192.168.100.x`.
- The same HTTP server runs, so the setup pages are reachable — but in setup-AP
  mode **every** request answers `301`, captive-portal style, so a client has to
  follow redirects. A bare `GET` that does not is how you get a row of empty
  `301`s and learn nothing.

**Join it to a network** — `POST /setWifiConfig`:

```json
{"ssid": "<your-wifi>", "password": "<your-wifi-password>"}
```

Verified against a factory-fresh unit on 2026-09-19. The reply carries more
than the `code` the setup page checks:

```json
{"code":200,"message":"WiFi config accepted","data":{"ssid":"zero","accepted":true}}
```

The device then drops the AP and joins the target network, flipping
`persist.softap.on` to `0` and `persist.wifi.on` to `1`. The web UI redirects to
`/wifi/result`. The clock is 2.4 GHz only, so the target must be a 2.4 GHz
network — pointing it at a 5 GHz-only SSID fails after the call has already
returned `200`.

**Discovery once on the LAN.** A joined device **announces itself by UDP
broadcast**: about once a second it sends, from an ephemeral source port, a
datagram to **port 55555** with the payload

```
Ulanzi TC002 <mac-tail>:<mac>:<serial>:<flag>
```

where `<mac-tail>` is the last four hex digits of the MAC (the same suffix the
default MQTT prefix uses), `<mac>` is the full 12-hex MAC, `<serial>` is
`devSn`, and `<flag>` is `true`/`false` (the firmware derives it from its
Bluetooth service; it read `true` here with BLE up, and its exact meaning is
not established). This is what Ulanzi Studio's `discoverTC002` listens for.
The port is a literal in the firmware's `UdpBroadcaster` constructor, and the
format was confirmed by capturing packets on the LAN. The stock firmware has
**no** mDNS/Bonjour; the custom runtime does (`tc002-<mac>.local`, see
[`RUNTIME.md`](RUNTIME.md#discovery-mdns)), but it is not running on a
factory-fresh device, so nothing here changes for adoption.

`tc002-adopt.py discover` listens on udp/55555 for a few seconds, then confirms
each announced device with `GET /getBase` (which adds the IP, SSID and firmware
versions). If nothing is heard, because the host is on another VLAN or the AP
filters broadcasts, `--sweep` probes every host on the /24 over HTTP: any host
answering `/getBase` with `{devSn, mac, mcuVer, appVer, ssid, ip}` is a TC002.
The sweep is opt-in, never a silent fallback: it is 254 connections that every
device on the network sees. (A clock running the custom runtime needs none of
this: it answers mDNS, see [`RUNTIME.md`](RUNTIME.md#discovery-mdns).)

```bash
# find devices already on your wifi (listen, then confirm; ~3 s)
/usr/bin/python3 tc002-adopt.py discover

# sweep only, e.g. from another vlan (~4 s for a /24)
/usr/bin/python3 tc002-adopt.py discover --sweep --no-listen --subnet 10.0.0

# adopt a factory-fresh device (after joining its "U-Clock" ap)
/usr/bin/python3 tc002-adopt.py adopt --ssid <your-wifi>
```

**It does not broadcast while in setup-AP mode.** Measured 2026-09-19: 25 s of
silence on udp/55555 while joined to `U-Clock` (udp/6666 and 9999 as controls),
then the announcements start within seconds of it joining the target network. So
discovery is only ever useful *after* adoption; there is nothing to listen for
before it. A `dns-sd` browse on the AP turned up only the listening host's own
services, consistent with the stock firmware having no mDNS either.

Joining the `U-Clock` AP needs no special handling: the passphrase is
`12345678` (above), so `networksetup -setairportnetwork en0 U-Clock 12345678`
does it, as does typing it into any wifi menu. `tc002-ap-probe.sh` automates the
whole visit — join, probe, fingerprint, adopt, and put the host's own wifi back.

## The setup AP is not a security boundary

It looks like WPA2 and it is not one in practice. The passphrase is a firmware
constant, the SSID is a firmware constant, so the derived key is the same on
every TC002 ever shipped, and a fresh clock hosts that AP by default until it is
adopted. Anyone in range can join it and reach the full HTTP API, which is
unauthenticated — including `setWifiConfig`, which lets them move the clock onto
a network they control. The owner's own adoption then hands over their wifi
password in cleartext over plain HTTP. Treat adoption as something to do
promptly, and on a network you trust.

> **Verification status:** discovery and `setWifiConfig` are both verified
> end-to-end against a live device — the latter on a factory-fresh second unit
> on 2026-09-19, which is also where the AP passphrase, the `192.168.100.x`
> subnet, the `301` behaviour and the absence of setup-mode broadcasts were
> measured. The raw run is reproducible with `tc002-ap-probe.sh`.
