# Flashing a TC002 with the replacement runtime

Everything needed to take a clock from its box to the custom runtime, including
the steps that are easy to miss and the one that makes a working device look
broken.

> **What this costs you.** The runtime replaces the stock application. While it
> runs there is no Ulanzi Studio, no cloud client and no stock HTTP API. The
> backup taken during the process is how you undo that, and it is the only copy
> of *your* unit's vendor application.

---

## 1. What you need

**On your computer**

| | why | install |
|---|---|---|
| `adb` | the only way in; the device speaks nothing else | `brew install android-platform-tools` · `apt install adb` |
| `python3` | the image tool and the adoption/control scripts | ships with macOS at `/usr/bin/python3` |
| `squashfs-tools` | `res` is a squashfs; your image is repacked locally | `brew install squashfs-tools` · `apt install squashfs-tools` |

**No compiler.** A release tarball carries the ARM binaries prebuilt. `zig` is
needed only to *build* a release (`./tc002-mkrelease.sh`), never to flash one.

> **On macOS, use Apple's `/usr/bin/python3`.** macOS 15+ gates LAN access per
> binary, and Homebrew's python and adb are gated. It surfaces as a misleading
> network error — "no route to host" — never as a permission error. See the
> macOS note in `README.md`.

**On the device** — nothing. A static busybox ships in the tarball and is pushed
to `/tmp` when needed, because the stock firmware has no `dd`, `grep`, `md5sum`,
`head`, `tail` or `wc`.

**What you must know before starting**

- **A 2.4 GHz SSID and its password.** The TC002 has no 5 GHz radio. Pointing it
  at a 5 GHz-only network fails *after* it has already accepted the credentials.
- **Your timezone**, as an IANA name (`Europe/Amsterdam`, `America/New_York`).

## 2. Why your image is built on your machine

The `res` partition carries the vendor application `lib/libzkgui.so`, and **that
file differs between units** — the two clocks measured for these notes run
application builds sixteen days apart. A prebuilt image would install one
owner's vendor app onto another's device.

So the image is assembled from a dump of *your* `res`, and that dump doubles as
your way back. This is also why the backup is not optional and not skippable:
it is an input to the build. See `FINGERPRINTS.md`.

## 3. The whole thing, in one command

```bash
./tc002-onboard.sh --wifi-ssid <your 2.4 GHz network>
```

It will ask for your timezone, offering this machine's setting as a default.
It then:

1. **finds the clock**, adopting it off its `U-Clock` setup AP if it is still
   factory-fresh (the AP passphrase is `12345678` on every unit — see
   `SETUP.md`, and note that this means the AP is not a security boundary);
2. **checks the device** is the hardware these notes describe, and records a
   fingerprint you can keep and compare against `FINGERPRINTS.md`;
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

## 4. Timezone and NTP — the step that looks like a failure

**A freshly flashed runtime has no settings at all.** No timezone, no NTP
server. A clock that cannot know the time shows **a blinking separator and no
digits**, which reads as a failed flash and is not one.

`tc002-onboard.sh --flash` provisions both for you. If you flash by hand, do it
yourself:

```bash
runtime/tools/tc002ctl.py -s <device-ip> --token-file <tokens> \
    config-set timezone=Europe/Amsterdam ntp_server=162.159.200.123
runtime/tools/tc002ctl.py -s <device-ip> --token-file <tokens> config-save
```

The device's API tokens are written to `/data/tc002/state/credentials/tokens`;
pull them with `adb`. `config-save` is what makes the settings survive a power
cycle — **the binaries live in flash, but the settings live on `/data`, and an
unsaved change is lost on reboot.**

> **`ntp_server` must be a dotted IPv4 address.** The runtime has no DNS
> resolver, so `pool.ntp.org` is not a valid value and the API will reject it.

Chosen automatically, in order: `162.159.200.123` (time.cloudflare.com anycast),
`216.239.35.0` (time.google.com), then your gateway. Public first on purpose —
a router that answers NTP is not necessarily a router that knows the time. The
gateway remains the fallback for a LAN with no route out. `--ntp none` skips it.

## 5. Getting back to stock

The backup in your work directory is the only copy of your unit's stock
application. Write it back with:

```bash
runtime/tools/tc002-flash.sh <your-backup>.bin
```

The device's own reset button also recovers, but it reflashes
`/mnt/storage/update.img`, which on every unit measured here is **older than
what the device shipped with** — it recovers by downgrading. See
`FINGERPRINTS.md`.

## 6. Things that look broken and are not

| symptom | what it is |
|---|---|
| Blinking separator, no digits | No timezone/NTP set. Section 4. |
| No USB device appears at all | A factory-fresh unit boots with `otg_role` at `usb_host` for the USB-stick workflow, so it presents no gadget. Writing `usb_device` to `/sys/bus/platform/devices/soc:usbotg/otg_role` makes it appear immediately, with no replug. |
| USB adb gone after a reboot | Documented kernel behaviour: the `usb-scan` kthread walks the port device→null→host ~3.5 s into boot, stranding the host's view. Unplug and replug the cable. Wifi returns on its own. See `DEVICE.md`. |
| Settings lost after a power cycle | You did not run `config-save`. |
| Flash succeeded but the panel is stale | The runtime's binaries are in flash; a reboot brings them back on their own. |

## 7. Building a release yourself

```bash
./tc002-mkrelease.sh            # needs zig 0.16; writes dist/
```

It builds the ARM binaries **with `-Dbin_dir=/res/bin -Dnetup=true`** — these
are compiled in, and a payload built without them flashes cleanly and then
cannot find its own children, with nothing to say so. It also builds the static
busybox and its applet list, writes `MANIFEST.sha256`, and tars the lot.
Publishing is manual; the script prints the `gh release create` line.
