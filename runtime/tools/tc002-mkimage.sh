#!/bin/bash
# tc002-mkimage.sh: assemble a flashable-shaped `res` image carrying the custom runtime.
#
#   runtime/tools/tc002-mkimage.sh <stock update.img|res.sqsh> <out UPDATE.img> [workdir]
#
# ############################################################################################
# # WHAT THIS PRODUCES IS NOT SAFE TO FLASH YET. it assembles and validates; it does not      #
# # install, and nothing in this repo writes to /res.                                         #
# #                                                                                           #
# # a flashed runtime needs four things that are NOT in this tree yet, each of which turns a   #
# # bad boot into a device with no way back in (see FIRMWARE.md):                              #
# #   1. the boot-failure counter and stock-config fallback, so three bad boots hand the panel #
# #      back to the vendor app on their own;                                                  #
# #   2. yielding to a pending upgrade, or the reset button's reflash -- the last recovery     #
# #      route -- stops working;                                                               #
# #   3. wifi bring-up at cold boot, because the loader we replace is what starts it, and adb  #
# #      over wifi is the only verified way back in;                                           #
# #   4. exporting gpio 35 and waiting for spidev, or the renderer cannot open the panel.      #
# #                                                                                           #
# # it also builds the runtime with this tree's default paths (/tmp/tc002), not /res/bin, so   #
# # the binaries inside would not find each other. use this for the size budget and to         #
# # rehearse the pipeline, not for a device.                                                   #
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

say "build the runtime"
( cd "$RUNTIME" && "$ZIG" build && "$ZIG" build check )

say "build busybox from source"
BB="$WORK/busybox/busybox-armv7"
[ -f "$BB" ] || "$HERE/tc002-mkbusybox.sh" "$WORK/busybox" "$BB" >/dev/null

say "add the runtime, the bootstrap and busybox"
cp "$RUNTIME"/zig-out/bin/tc002-supervisor "$RUNTIME"/zig-out/bin/tc002d \
   "$RUNTIME"/zig-out/bin/tc002-netd "$RUNTIME"/zig-out/bin/tc002-ntfy "$RES/bin/"
cp "$BB" "$RES/bin/busybox"
cp "$RUNTIME"/zig-out/lib/libtc002-bootstrap.so "$RES/lib/"

# 0755 on the files AND the directories holding them: netd and ntfy run as uid 1001 and cannot
# traverse or exec through the stock 0770 owned by 1000:1000. root is unaffected either way, which
# is why this only shows up once something unprivileged has to start.
say "permissions: 0755 on what we added and on the directories above it"
chmod 0755 "$RES"/bin/tc002-supervisor "$RES"/bin/tc002d "$RES"/bin/tc002-netd \
           "$RES"/bin/tc002-ntfy "$RES"/bin/busybox "$RES"/lib/libtc002-bootstrap.so
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

  NOT SAFE TO FLASH. this image is assembled and validated, not installed.
  before any device sees it, the boot machinery in FIRMWARE.md has to exist:
  the boot-failure counter and stock fallback, yielding to a pending upgrade
  so the reset button still works, wifi bring-up at cold boot (adb over wifi
  is the only verified way back in), and the gpio-35 panel gate. the runtime
  in it is also built for /tmp/tc002 rather than /res/bin.
WARN
