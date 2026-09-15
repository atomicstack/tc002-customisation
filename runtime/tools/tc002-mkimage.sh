#!/bin/bash
# tc002-mkimage.sh: assemble a flashable-shaped `res` image carrying the custom runtime.
#
#   runtime/tools/tc002-mkimage.sh <stock update.img|res.sqsh> <out UPDATE.img> [workdir]
#
# ############################################################################################
# # WHAT THIS PRODUCES HAS NEVER BEEN FLASHED. it assembles and validates; it does not         #
# # install, and nothing in this repo writes to /res.                                          #
# #                                                                                            #
# # the four pieces of boot machinery a flashed runtime needs all exist now, and the runtime   #
# # in the image is built for /res/bin rather than /tmp/tc002 (see below). what is still       #
# # missing is the only thing that cannot be built: a device that has come up from this image  #
# # and been recovered from it. of the four, wifi bring-up is the one resting on reasoning     #
# # rather than a measurement, because exercising it live restarts wpa_supplicant and adb is   #
# # that link. see FIRMWARE.md for what was verified and how.                                  #
# ############################################################################################
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$RUNTIME/.." && pwd)
IMGTOOL="$ROOT/tc002-update-img.py"
ZIG=${ZIG:-zig}
PY=${PY:-/usr/bin/python3}

[ $# -ge 2 ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
STOCK=$1; OUT=$2; WORK=${3:-${TMPDIR:-/tmp}/tc002-image}
command -v mksquashfs >/dev/null || { echo "need squashfs-tools (brew install squashfs-tools)" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "need squashfs-tools (unsquashfs)" >&2; exit 1; }
say() { echo "== $*"; }

mkdir -p "$WORK"
SQSH="$WORK/stock-res.sqsh"
say "take the stock res out of $STOCK"
if "$PY" "$IMGTOOL" inspect "$STOCK" >/dev/null 2>&1; then
    "$PY" "$IMGTOOL" unpack "$STOCK" "$SQSH" >/dev/null
else
    cp "$STOCK" "$SQSH"   # already a squashfs (an mtd3 dump reads the same way)
fi

RES="$WORK/res-root"; rm -rf "$RES"
say "unpack it"
unsquashfs -d "$RES" "$SQSH" >/dev/null
# the fallback the recovery path points at has to survive: without it, handing back to the vendor
# app hands back to nothing. this is the check that matters most in the whole script.
[ -f "$RES/lib/libzkgui.so" ] || { echo "the stock libzkgui.so is not in this res -- wrong input image" >&2; exit 1; }

# -Dbin_dir is what makes these binaries work from flash. the bootstrap execs the supervisor with
# only `--from-bootstrap`, and the supervisor spawns five children by absolute path, so a flashed
# runtime never sees a command-line argument: every path it uses is compiled in here. -Dnetup turns
# on the bring-up a flashed install has to do for itself, the loader we replace being what used to.
say "build the runtime for /res/bin"
( cd "$RUNTIME" && "$ZIG" build -Dbin_dir=/res/bin -Dnetup=true && "$ZIG" build -Dbin_dir=/res/bin -Dnetup=true check )

say "build busybox from source"
BB="$WORK/busybox/busybox-armv7"
[ -f "$BB" ] || "$HERE/tc002-mkbusybox.sh" "$WORK/busybox" "$BB" >/dev/null

# all six, not four: audiod and berryd are spawned by absolute path like the rest, and an image
# missing them is one where `sound.enabled` and `berry.enabled` fail at the exec with no other sign.
# the boot scripts go in beside busybox because that is the single directory the supervisor hands
# the bring-up -- `busybox sh <dir>/tc002-netup.sh <dir> <writable dir>`.
say "add the runtime, the bootstrap, busybox and the boot scripts"
cp "$RUNTIME"/zig-out/bin/tc002-supervisor "$RUNTIME"/zig-out/bin/tc002d \
   "$RUNTIME"/zig-out/bin/tc002-netd "$RUNTIME"/zig-out/bin/tc002-ntfy \
   "$RUNTIME"/zig-out/bin/tc002-audiod "$RUNTIME"/zig-out/bin/tc002-berryd "$RES/bin/"
cp "$BB" "$RES/bin/busybox"
cp "$RUNTIME"/boot/tc002-netup.sh "$RUNTIME"/boot/tc002-udhcpc.script "$RES/bin/"
cp "$RUNTIME"/zig-out/lib/libtc002-bootstrap.so "$RES/lib/"

# a syntax check under the host's /bin/sh. it is not the ash that will run them -- that binary is
# armv7 and cannot execute here -- so it catches a typo, not a busybox-specific incompatibility.
# the real check is `busybox sh -n` on the device, which is how these two were cleared.
for f in tc002-netup.sh tc002-udhcpc.script; do
    /bin/sh -n "$RES/bin/$f" || { echo "$f does not parse" >&2; exit 1; }
done

# 0755 on the files AND the directories holding them: netd and ntfy run as uid 1001 and cannot
# traverse or exec through the stock 0770 owned by 1000:1000. root is unaffected either way, which
# is why this only shows up once something unprivileged has to start.
say "permissions: 0755 on what we added and on the directories above it"
chmod 0755 "$RES"/bin/tc002-supervisor "$RES"/bin/tc002d "$RES"/bin/tc002-netd \
           "$RES"/bin/tc002-ntfy "$RES"/bin/tc002-audiod "$RES"/bin/tc002-berryd \
           "$RES"/bin/busybox "$RES"/bin/tc002-netup.sh "$RES"/bin/tc002-udhcpc.script \
           "$RES"/lib/libtc002-bootstrap.so
chmod 0755 "$RES" "$RES/bin" "$RES/lib" "$RES/etc"

say "point the loader at our bootstrap"
"$PY" - "$RES/etc/EasyUI.cfg" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
if "/res/lib/libtc002-bootstrap.so" in s:
    sys.exit(0)
if "/res/lib/libzkgui.so" not in s:
    sys.exit("EasyUI.cfg does not point at libzkgui.so; refusing to guess")
open(p, "w").write(s.replace("/res/lib/libzkgui.so", "/res/lib/libtc002-bootstrap.so"))
PYEOF
grep -q libtc002-bootstrap "$RES/etc/EasyUI.cfg"

say "repack"
SQ="$WORK/res-custom.sqsh"; rm -f "$SQ"
mksquashfs "$RES" "$SQ" -comp xz -b 131072 -no-xattrs -force-uid 1000 -force-gid 1000 -noappend >/dev/null
SZ=$(wc -c < "$SQ" | tr -d ' '); LIMIT=$((8 * 1024 * 1024))
[ "$SZ" -le "$LIMIT" ] || { echo "image is $SZ bytes; the res partition is $LIMIT" >&2; exit 1; }

say "wrap in the container and check it"
"$PY" "$IMGTOOL" pack "$SQ" "$OUT" --template "$STOCK" >/dev/null 2>&1 || "$PY" "$IMGTOOL" pack "$SQ" "$OUT" >/dev/null
"$PY" "$IMGTOOL" inspect "$OUT"

echo "   $OUT -- $(wc -c < "$OUT" | tr -d ' ') bytes, $((100 * SZ / LIMIT))% of the res partition"
cat <<'WARN'

  NEVER FLASHED. this image is assembled and validated, not installed.
  the boot machinery it depends on exists and is described in FIRMWARE.md --
  the boot-failure counter and stock fallback, yielding to a pending upgrade
  so the reset button still works, wifi bring-up at cold boot, and the gpio-35
  panel gate -- and the runtime in it is built for /res/bin. what no build can
  supply is a device that has come up from an image like this one and been
  recovered from it. the wifi bring-up in particular has never been run: adb is
  over the link it restarts.
WARN
