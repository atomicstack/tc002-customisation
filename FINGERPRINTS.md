# Ulanzi TC002 — flash fingerprints, so you can tell whether your unit matches

Checksums taken from one real device on 2026-09-15, so anyone doing the same
work can answer the question that actually matters before flashing anything:
**is my device the same as the one these notes were written against?**

> **These are the *stock* values, recorded before that device was flashed.**
> Its `mtd3` now holds the custom runtime, so re-reading `res` on it today will
> not reproduce anything in this file. The stock partition is preserved in the
> backup taken beforehand. That is the whole reason to take one: dump `mtd3`
> **before** your first flash, because afterwards the original is gone from the
> device and no amount of checking can bring it back.

It is worth checking, and a second unit has now proved why. A factory-fresh
TC002 measured on 2026-09-19 is **bit-identical to this one in bootloader,
kernel, rootfs and MISC, and carries a different `res`** — an application build
sixteen days older. Two TC002s bought at different times are not necessarily
running the same `res`. The unit here also does **not** match the `update.img`
that ships on its own UDISK partition, which is older still.

Identity of the reference unit:

| | |
|---|---|
| `ro.product.model` | `Zkswe_SSD21X_SPINOR` |
| `ro.build.fingerprint` | `ZKOS,flythings(see www.zkswe.com)` |
| `ro.build.date` | `20260527` |
| `ro.build.version.release` | `flythingsV2.1` |
| kernel | `Linux 4.9.84 #1624 SMP PREEMPT Wed May 27 13:08:02 UTC 2026` |
| flash | 32 MiB SPI **NOR**, 64 KiB erase blocks (`/sys/class/mtd/mtd3/type` = `nor`, `oobsize` 0) |

## The quickest check: the `res` squashfs superblock

If you check one thing, check this. It is four fields at the start of the
partition and it pins the firmware revision exactly.

| field | offset | value here |
|---|---|---|
| magic | 0x00 | `hsqs` |
| inode count | 0x04 | **234** |
| mkfs timestamp | 0x08 | **0x6a882f3d** |
| bytes used | 0x28 | **2787758** |

```sh
# on the device. note the mtd nodes do NOT exist in /dev until you make them
busybox mknod /dev/mtdblock3 b 31 3
busybox dd if=/dev/mtdblock3 bs=1 count=64 2>/dev/null | busybox hexdump -C
```

A different inode count or mkfs timestamp means a different `res` revision from
this one, and every `res`-derived hash below will differ for you. That is not a
fault — it just means these notes describe a different build than yours, and you
should take your own baseline before flashing.

## Two units, side by side

Unit A is the reference throughout this file. Unit B is a factory-fresh unit
bought later and measured on 2026-09-19, before anything was written to it.

| | unit A | unit B |
|---|---|---|
| `ro.build.date` / kernel `#1624` build stamp | `20260527` / `Wed May 27 13:08:02 UTC 2026` | **identical** |
| mtd0 `BOOT0` | `abbf8b99…` | **identical** |
| mtd1 `KERNEL` | `e244f7b4…` | **identical** |
| mtd2 `rootfs` | `76f51deb…` | **identical** |
| mtd5 `MISC` | `5c4e0bbf…` | **identical** |
| `res` inode count | 234 | **233** |
| `res` mkfs timestamp | `0x6a882f3d` (2026-08-21) | **`0x6a72b2cb` (2026-08-05)** |
| `res` bytes used | 2,787,758 | **2,781,142** |
| files in `/res` | 222 | **221** |
| `/res` aggregate md5 | `41296ccc…` | **`b42e7f2e…`** |
| `lib/libzkgui.so` | 7,484,524 / `64d7dc6f…` | **7,464,044 / `de15dd84…`** |
| `etc/EasyUI.cfg` | `e0c101f7…` | **identical** |
| UDISK `update.img` | 2,781,756 / `ba255466…` | **identical** |
| `appVer` / `mcuVer` (`GET /getBase`) | — | `1.0.8` / `V1.0.17` |

Two conclusions worth keeping:

- **The base system is stable across units.** Bootloader, kernel, rootfs and
  MISC matched byte for byte, so those four hashes are meaningful comparisons
  and a mismatch in any of them means something genuinely differs.
- **`res` is not.** Of the 222/221 files, 220 are common; unit A has
  `ui/app_icons/tools_focus_clock.png` and `ui/font_image/t_9_L.png`, unit B has
  `ui/font_image/t_10_L.png` instead. `etc/EasyUI.cfg` — the loader config the
  custom runtime's takeover depends on — is identical on both, which is the one
  piece of good news for portability.

> **So never flash a `res` image built for one unit to another.** The image
> carries `lib/libzkgui.so`, the vendor application, and that file differs
> between these two units. Doing so silently swaps the app for a build the
> device never shipped with. Build every image from **that device's own** `res`
> dump — which is exactly the backup `runtime/tools/tc002-flash.sh` takes before
> it writes anything.

## Partitions

`/proc/mtd` on this unit:

```
mtd0: 00050000 00010000 "BOOT0"      mtd4: 000b0000 00010000 "config"
mtd1: 001f0000 00010000 "KERNEL"     mtd5: 00040000 00010000 "MISC"
mtd2: 00450000 00010000 "rootfs"     mtd6: 00800000 00010000 "data"
mtd3: 00800000 00010000 "res"        mtd7: 00880000 00010000 "UDISK"
```

sha256 of each partition read whole:

| partition | bytes | sha256 | comparable across devices? |
|---|---|---|---|
| mtd0 BOOT0 | 327680 | `abbf8b9931fbc3f90db9f1911595e20ebdd0b9dd8b15b75f09f16ed9a5fbaead` | yes |
| mtd1 KERNEL | 2031616 | `e244f7b46644374e079d5010962a8b3c4492c7ad11f889a82dfc33b6a74b9993` | yes |
| mtd2 rootfs | 4521984 | `76f51deb0e9b299fddf9afcd16315410c15def430dec4d615064a569a47fab0a` | yes |
| mtd3 res | 8388608 | `dd1a3c6e429203f305acc90c57832e248aa577fea5ad5bdbe0f0f48a126fa297` | yes, per revision |
| mtd4 config | 720896 | `0cbe147e08fc369e11e6b27a3c83692f513bfaae771ea480079c8e87cd5383be` | **no** — per-device |
| mtd5 MISC | 262144 | `5c4e0bbf9afb2c8fe33cc402817ba4025a41cea5459931dd4d4f7060e32902c2` | probably not |
| mtd6 data | 8388608 | `eca5d54634246076cd491d21a76e53b2d338392a646e272e4a9ddc1ccdd39e01` | **no** — see the warning |
| mtd7 UDISK | 8912896 | `93951842882684cc749409a0285dc02edfa6970976a73e94e1bbfcb2c4767c97` | no — free space varies |

> **Do not publish your own `mtd6` (`data`) or share the raw partition.** It is
> the jffs2 user partition and it holds `/data/misc/wifi/wpa_supplicant.conf`
> with your **wifi psk in the clear**, plus any api tokens. Its hash is listed
> here only so the reference set is complete; it is worthless for comparison
> because it changes every time the device writes a setting. `mtd4` (`config`)
> is per-device too.

The `res` partition is only 2,787,758 bytes of squashfs followed by whatever was
there before; the trailing bytes are not erased, so a whole-partition hash is
only comparable against another dump of the *same* unit. To compare against
another device, use the superblock fields above or the image-proper hash:

```
sha256 of res bytes [0, 2789376)   c9f50608f9d61495ff5f9b242df5f03a6a01df216ca3be77b4634ca97efa7068
md5    of the same range           fb69c9c096e7683cfe2e70c955e855fa
```

## Inside `res`

222 regular files. The aggregate below is `find . -type f | sort | xargs md5sum
| md5sum` run against the mounted `/res`, which is the cheapest whole-filesystem
comparison that does not need a partition dump:

```
aggregate md5 of all 222 files     41296ccc5acce7b0a4314d14d6145ea7
```

```sh
# on the device, with a busybox that has find/sort/xargs/md5sum
cd /res && busybox find . -type f | busybox sort | busybox xargs busybox md5sum | busybox md5sum
```

> **Push that busybox under the name `busybox`.** It is a multi-call binary and
> dispatches on `argv[0]`, so a copy pushed to `/tmp/bb` answers every single
> invocation with `bb: applet not found` — which looks like a broken upload
> rather than a naming mistake, and cost a full measurement run here.

> Comparing the file *list* against an `unsquashfs`-extracted reference on macOS
> will report differences that are not there: the default filesystem is
> case-insensitive, so `a_5_L.png` and `A_5_L.png` collapse into one file on
> extraction. Use `unsquashfs -ll` to list the image without extracting it, and
> compare with `LC_ALL=C sort` — the device's busybox sorts in byte order and
> macOS `sort` does not.

Individual files worth pinning, because the flashing work depends on them:

| file | bytes | sha256 |
|---|---|---|
| `lib/libzkgui.so` | 7484524 | `64d7dc6f7c06cc4f00164b28a52e73cf0b24678a2f3360e22b4ef757818bb7e1` |
| `etc/EasyUI.cfg` | 318 | `e0c101f7e16dc8a1c8a6caf9b73b47c393faaf46c1f2dce7d9fc8c8650215dcc` |

`lib/libzkgui.so` is the one that matters most: it is the stock application, and
it is what a custom runtime's recovery path hands back to. Any image you build
must keep the copy **from your own device**, not one from somebody else's dump.

## The `update.img` on the UDISK, and why it is a trap

`/mnt/storage` (the UDISK, mtd7, vfat, mounted read-only) ships with a vendor
`update.img` at the top level. On this unit:

```
sha256  708c7844947d76877add2a679a5555f76c947a988175131c96920eff11ab99ee
md5     ba255466c14445be32f5732fb27e5d20
size    2781756 bytes  (payload 2781184, partition 3 = res)
```

Its payload's superblock is **inode count 233, mkfs 0x6a3f2ed7, bytes used
2779578** — a *different and older* revision than the `res` the device is
actually running (234 / 0x6a882f3d / 2787758, above). Unpacked, the two differ
by four changed files (`lib/libzkgui.so` and three `ui/web/*.html`) and three
that exist on one side only.

**Other units, for comparison.** Unit B carries this file *identically* —
2,781,756 bytes, md5 `ba255466…`, sha256 `708c7844…` — so the stale UDISK image
is at least common to these two. aquarat's fork records it on their device as
**2,773,564 bytes, md5 `f318f036651d6ab95ce05b25a7211c7e`, sha256
`4a5db0fe78d1be91c101e6aee7766a59d60136cd68dde2540e99a7b6fb87fc82`** —
different size, different content, different unit. Their notes suggest pulling
it to "confirm you have the same base this work was built on"; that check fails
against both devices here. Two TC002s are not necessarily carrying the same
factory image, which is the whole reason this file exists.

On unit B, fresh from the box, `persist.zkupgrade.dir` and `sys.zkupgrade.dir`
are both **empty** — so the default applies and a reset-button reflash installs
`/mnt/storage/update.img`, whose payload is dated 2026-06-27. On a unit shipped
with a 2026-08-05 `res`, that recovery path is a six-week downgrade.

`/mnt/storage` is the **default** `sys.zkupgrade.dir`. So an upgrade triggered
without overriding the directory — the reset-button reflash, a `flag=255` recipe
that forgets `dir` — installs that stale image and **downgrades the device**,
`libzkgui.so` included. Worth knowing before you treat the reset button as your
safety net: it recovers, but to an older firmware than you were running.

## Taking your own baseline

Do this **before** flashing anything. The mtd nodes do not exist in `/dev` on
this device, and nothing in the stock boot creates them.

> **Do not dump with `adb shell cat /dev/mtdblockN > out.bin`.** It is the
> obvious command and it silently corrupts the result on this adbd, which has
> no `exec-out` and mangles LF to CRLF on the way out. Measured here on a
> 9,600-byte ELF: `adb shell cat` returned 9,628 bytes with a different hash
> from the same file fetched by `adb pull`. A backup taken that way looks fine
> and fails when you need it. Use `dd` to a file and `adb pull` it, as below.

```sh
adb shell "busybox mknod /dev/mtdblock3 b 31 3"
# 2 MiB at a time: /tmp is a 16 MiB tmpfs and filling it has taken adbd down before
for off in 0 2048 4096 6144; do
  adb shell "busybox dd if=/dev/mtdblock3 of=/tmp/chunk bs=1024 skip=$off count=2048 2>/dev/null"
  adb pull /tmp/chunk chunk-$off.bin
done
adb shell "busybox rm -f /tmp/chunk"
cat chunk-0.bin chunk-2048.bin chunk-4096.bin chunk-6144.bin > mtd3-res.bin
unsquashfs -d res-check mtd3-res.bin   # it must unpack, and hold lib/libzkgui.so
```

`runtime/tools/tc002-flash.sh` does this for you and refuses to flash if the
backup does not unpack.

The stock busybox on this device resolves almost nothing — no `grep`, `sed`,
`head`, `tail`, `wc`, `dd` or `md5sum` — so most of the commands here need a
static armv7 busybox pushed to `/tmp` first.
`runtime/tools/tc002-mkbusybox.sh` builds one from a pinned upstream tarball.
