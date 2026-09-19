# Flashing a TC002 with the replacement runtime

Everything needed to take a clock from its box to the custom runtime, including
the steps that are easy to miss and the ones that make a working device look
broken.

> **What this costs you.** The runtime replaces the stock application. While it
> runs there is no Ulanzi Studio, no cloud client and no stock HTTP API — only
> one process can usefully own `spidev0.0`, so the two cannot coexist
> ([`LED-SPI.md`](LED-SPI.md)). The backup taken during the process is how you
> undo that, and it is the only copy of *your* unit's vendor application.

---

## 1. What you need

**On your computer**

| | why | install |
|---|---|---|
| `adb` | the only way in; the device ships with adbd open and root on `:5555` | `brew install android-platform-tools` · `apt install adb` |
| `python3` | the image tool and the adoption/control scripts | ships with macOS at `/usr/bin/python3` |
| `squashfs-tools` | `res` is a squashfs; your image is repacked locally | `brew install squashfs-tools` · `apt install squashfs-tools` |
| `zig` **0.16.0 exactly** | **only from a git checkout** — see below | `brew install zig` |

**"No compiler" is true only from a release tarball.** The tarball carries the
ARM binaries and the static busybox prebuilt. From a **git checkout**,
`tc002-mkimage.sh` detects `build.zig` and builds the payload itself, so you
need zig 0.16.0 exactly — the build panics on any other version — and one
`runtime/tools/tc002-mkbusybox.sh` run to produce the busybox and its applet
list.

> **On macOS, use Apple's `/usr/bin/python3`.** macOS 15+ gates LAN access per
> binary, and Homebrew's python and adb are gated. It surfaces as a misleading
> network error — "no route to host" — never as a permission error. Grant the
> terminal under Privacy & Security → Local Network, then **fully quit and
> relaunch it**; permission is evaluated at process start. See the macOS note in
> [`README.md`](README.md#a-note-on-macos).

**On the device** — nothing. A static busybox is pushed to `/tmp` when needed,
because the stock shell resolves almost nothing: no `dd`, `grep`, `md5sum`,
`head`, `tail` or `wc` ([`FINGERPRINTS.md`](FINGERPRINTS.md) has the canonical
list). It must be pushed **under the name `busybox`** — it dispatches on
`argv[0]`, so a copy called `bb` answers every invocation with
`bb: applet not found`.

**Before you start**

- **A 2.4 GHz SSID and its password.** The TC002 has no 5 GHz radio. Pointing it
  at a 5 GHz-only network fails *after* it has already accepted the credentials.
- **Your timezone.** An IANA name (`Europe/Amsterdam`, matched
  case-insensitively against 597 zones) or a POSIX TZ rule
  (`AEST-10AEDT,M10.1.0,M4.1.0/3`). A POSIX rule names no place, so the
  night-brightness schedule has no location unless you also pin `latitude` and
  `longitude` ([`RUNTIME.md`](RUNTIME.md)).
- **Mains power, not battery.** The firmware shuts down below 3550 mV after a
  30 s countdown, and that countdown is skipped only while on USB power. Do not
  flash a nearly-flat clock.
- **Adopt before you flash.** Wifi credentials live in `/data`, which a `res`
  flash does not touch — but the runtime cannot run the setup-AP flow itself, so
  a factory-fresh device still needs the stock app to join a network first.

`adb connect <device-ip>:5555` is how the host reaches it once it is on wifi.

## 2. Why your image is built on your machine

The `res` partition carries the vendor application `lib/libzkgui.so`, and **that
file differs between units** — the two clocks measured for these notes run
application builds sixteen days apart. A prebuilt image would install one
owner's vendor app onto another's device.

So the image is assembled from a dump of *your* `res`, and that dump doubles as
your way back. This is why the backup is neither optional nor skippable: it is
an input to the build. See [`FINGERPRINTS.md`](FINGERPRINTS.md).

## 3. The whole thing, in one command

```bash
./tc002-onboard.sh --wifi-ssid <your 2.4 GHz network>
```

It asks for your timezone, offering this machine's setting as a default. It
then:

1. **finds the clock**, adopting it off its `U-Clock` setup AP if it is still
   factory-fresh. The AP passphrase is `12345678` on every unit, the clock is
   the gateway at **`192.168.100.1`**, and in that mode every HTTP request
   answers `301`, so a manual `curl` needs `-L`. See [`SETUP.md`](SETUP.md) —
   and note this means the AP is not a security boundary;
2. **checks the device** and records a fingerprint. **Compare it against
   [`FINGERPRINTS.md`](FINGERPRINTS.md) before going further** — a mismatch is
   not a fault, but it means your unit ships a different `res` revision than
   these notes describe;
3. **backs up `res`** and refuses to continue unless the dump unpacks and
   contains `lib/libzkgui.so`;
4. **builds your image** from that dump;
5. **stops.** Nothing has been written to flash. It prints the command that
   would.

Add `--flash` to go all the way in one run. The write is still gated on typing
`flash`, unless you pass `--yes`.

```bash
./tc002-onboard.sh --wifi-ssid <ssid> --tz Europe/Amsterdam --flash
```

Useful flags: `--device IP[:PORT]` to skip discovery, `--no-adopt` if it is
already on your wifi, `--work DIR` for where the backup and image land
(default `~/tc002-onboard`), `--ntp IP|auto|none`, `--tz ZONE`.

**What the flash looks like.** Prefer the USB cable if you have one: the
sequence stops `zkswe` and wifi is brought up by whatever owns the panel, so the
LAN transport can vanish at exactly the wrong moment. **The device reboots
itself partway through — do not power it off.** The vendor code shows no
progress animation, so the panel simply freezes on whatever frame was latched.
The write plus reboot takes about twenty seconds, and the LAN is back in about
sixteen.

**Confirm it worked** by listing `/res/bin`: if `tc002-supervisor` is there, it
took. `/data/.zkupgraderec` is not a usable check. Take the backup with `dd` and
`adb pull` — **never `adb shell cat`**, which silently corrupts binaries on this
adbd, and never stage a partition-sized file in the device's 16 MiB tmpfs.

## 4. Timezone and NTP — the step that looks like a failure

**The device has no RTC.** Its clock starts at the 1970 epoch on *every* boot
and is only ever set over the network. A freshly flashed runtime has no
`ntp_server` — the default is none — so the renderer sees a clock that has
never been set and draws **a blinking separator and no digits**. That reads as a
failed flash and is not one.

To be precise about which setting does what: **the NTP server is what makes
digits appear at all**; the timezone only makes them the *right* digits. The
timezone default is `UTC0`, so a clock with NTP and no timezone shows correct
UTC time, while a clock with a timezone and no NTP shows nothing.

`tc002-onboard.sh --flash` sets both. If you flash by hand:

```bash
adb pull /data/tc002/state/credentials/tokens tokens
runtime/tools/tc002ctl.py -s <device-ip> --token-file tokens \
    config-set timezone=Europe/Amsterdam ntp_server=162.159.200.123
```

**You do not need to save.** Every accepted settings write is persisted at once;
confirm it by seeing `saved_revision` match `revision` in the reply.
`config-save` remains as a force-write, and forgetting it costs nothing.

> **`ntp_server` must be a dotted IPv4 address.** The runtime has no DNS
> resolver, so `pool.ntp.org` is rejected. (The stock firmware has the same
> property for a different reason — its seven servers are IP literals parsed
> with `inet_addr`.) `ntp_interval_s` is 300 or 600, default 300.

Chosen automatically, in order: `162.159.200.123` (time.cloudflare.com anycast),
`216.239.35.0` (time.google.com), then your gateway. Well-known public services
first on purpose — both are anycast with stable addresses, and a router that
answers NTP is not necessarily a router that knows the time. The gateway remains
the fallback for a LAN with no route out. `--ntp none` skips it.

If you firewall the clock, **leave UDP/123 open to whatever server you set**, or
it returns to 1970 on the next reboot.

## 5. Getting back to stock

The backup in your work directory is a raw partition dump. The flasher takes a
packed `UPDATE.img` and will refuse anything it cannot vouch for, so pack it
first:

```bash
/usr/bin/python3 tc002-update-img.py pack <your-backup>.bin stock-UPDATE.img
runtime/tools/tc002-flash.sh stock-UPDATE.img
```

The device's own reset button is a different thing and a blunter one: a five
second hold **wipes `/data`** — settings, wifi credentials, the runtime's API
tokens and the ntfy CA — and then reflashes `/mnt/storage/update.img` if one is
present, which on every unit measured here is **older than what the device
shipped with**. It recovers by downgrading, and it is not the stock
`/resetConfig` endpoint, which only clears settings and is gone once the runtime
is running.

## 6. Things that look broken and are not

| symptom | what it is |
|---|---|
| Blinking separator, no digits | No NTP server set. Section 4. |
| Panel frozen during the flash | Expected — the vendor code draws no progress. About twenty seconds. |
| Time is right but in the wrong zone | Timezone unset; it defaults to `UTC0`. |
| No USB device appears at all | A factory-fresh unit settles with `otg_role` at `usb_host` and presents no gadget. Writing `usb_device` to `/sys/bus/platform/devices/soc:usbotg/otg_role` brings it up immediately, no replug. If `otg_role` already reads `usb_device`, the write does nothing — that is not your problem. |
| USB adb gone after a reboot | The `usb-scan` kthread walks the port device→null→host ~3.5 s into boot, stranding the host's view. Unplug and replug. Wifi returns on its own in about sixteen seconds. See [`DEVICE.md`](DEVICE.md). |
| Nothing on the network after a flash | Nothing in `/etc/init.rc` loads the wifi driver — the panel owner does. Plug the cable in and use USB adb. |
| The stock app came back by itself | The bootstrap counts boot failures and hands the panel back after three, clearing the count after sixty healthy seconds. Self-healing, not a brick. A first boot that never gets an address also hands back after 120 s. |
| Settings gone after a power cycle | They are written at once, so this means the write failed — check `saved_revision` against `revision`, or that `/data` is mounted. A reset-button hold also wipes `/data` entirely. |
| Scripting does nothing | Berry is off by default and `tc002-berryd` is not spawned until you enable it. See [`SCRIPTING.md`](SCRIPTING.md). |

## 7. Building a release yourself

```bash
./tc002-mkrelease.sh            # needs zig 0.16.0 exactly; writes dist/
```

It builds the ARM binaries **with `-Dbin_dir=/res/bin -Dnetup=true`** — these
are compiled in, and a payload built without them flashes cleanly and then
cannot find its own children, with nothing to say so. It also builds the static
busybox and its applet list, writes `MANIFEST.sha256`, and tars the lot.
Publishing is manual; the script prints the `gh release create` line.

## 8. Afterwards

**Do not publish your partition dumps.** `mtd6` (`data`) holds
`wpa_supplicant.conf` with your wifi PSK in the clear, plus any API tokens;
`mtd4` (`config`) is per-device. The `res` dump is the only one safe to share.

The runtime's API has **no TLS** — tokens travel in plain HTTP and plain MQTT.
It is built for an isolated LAN or an IoT VLAN, not a hostile network. Read
[`SECURITY.md`](SECURITY.md) before exposing it to anything.

The console is `panel-v2/start-panel.sh`, and it looks for a `tokens` file
beside it:

```bash
cp ~/tc002-onboard/tokens ./tokens && panel-v2/start-panel.sh --open
```
