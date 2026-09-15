# Ulanzi TC002 — flash fingerprints, so you can tell whether your unit matches

Checksums taken from one real device on 2026-09-15, so anyone doing the same
work can answer the question that actually matters before flashing anything:
**is my device the same as the one these notes were written against?**

It is worth checking. The unit these were taken from does **not** match the
`update.img` that ships on its own UDISK partition — that image is an older
firmware revision. Two TC002s bought at different times are not necessarily
running the same `res`.

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

`/mnt/storage` is the **default** `sys.zkupgrade.dir`. So an upgrade triggered
without overriding the directory — the reset-button reflash, a `flag=255` recipe
that forgets `dir` — installs that stale image and **downgrades the device**,
`libzkgui.so` included. Worth knowing before you treat the reset button as your
safety net: it recovers, but to an older firmware than you were running.

## Taking your own baseline

Do this **before** flashing anything. The mtd nodes do not exist in `/dev` on
this device, and nothing in the stock boot creates them.

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
