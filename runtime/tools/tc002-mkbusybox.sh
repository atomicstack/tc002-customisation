#!/bin/bash
# tc002-mkbusybox.sh: build a static armv7 busybox from source, for the persistent-install image.
#
#   runtime/tools/tc002-mkbusybox.sh [workdir] [out]
#
# the runtime's boot path needs a shell, `insmod`, `ifconfig`, `route` and above all **`udhcpc`**,
# which the device's own busybox does not have. rather than take somebody's prebuilt binary and put
# it in flash, this builds one from a pinned, checksummed upstream tarball.
#
# **zig is the whole toolchain.** the repo already pins zig 0.16 for the runtime, and `zig cc` is a
# cross compiler with musl and linux headers in the box, so there is no new dependency here -- no
# docker, no crosstool, no homebrew binutils, and nothing downloaded but the busybox source.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ZIG=${ZIG:-zig}

VERSION=1.38.0
# from busybox.net/downloads/busybox-$VERSION.tar.bz2.sha256, and checked again below
SHA256=34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2
URL=https://busybox.net/downloads/busybox-$VERSION.tar.bz2

WORK=${1:-${TMPDIR:-/tmp}/tc002-busybox}
OUT=${2:-$WORK/busybox-armv7}
TARGET=arm-linux-musleabihf

# the applets that go in the image. the first group is what the boot path actually calls
# (tc002-netup.sh and the udhcpc callback); the second is the handful of things that make the
# device debuggable at all, because the stock busybox resolves almost nothing -- there is no grep,
# sed, head, tail or wc on this device, which is a real tax on every investigation.
APPLETS_BOOT="SH_IS_ASH ASH ASH_OPTIMIZE_FOR_SIZE FEATURE_SH_MATH
              UDHCPC INSMOD RMMOD LSMOD IFCONFIG FEATURE_IFCONFIG_STATUS FEATURE_IFCONFIG_HW
              ROUTE SLEEP CAT KILL ECHO TEST PIDOF"
APPLETS_DEBUG="GREP SED HEAD TAIL WC LS PS DF FREE MKDIR RM CP MV LN CHMOD SYNC DMESG
               MOUNT UMOUNT TR CUT SORT UNIQ TOUCH DATE HEXDUMP MD5SUM SHA256SUM
               FEATURE_FANCY_HEAD FEATURE_FANCY_TAIL FEATURE_PS_LONG FEATURE_DATE_ISOFMT
               FEATURE_HUMAN_READABLE"
# non-applet switches that are not optional:
#  BUSYBOX -- the multiplexer itself. `allnoconfig` turns it off, and without it the binary only
#             works through argv[0] symlinks: `busybox insmod ...`, which is how every boot script
#             calls it, answers "applet not found". this was the one silent trap in the build.
#  STATIC  -- /res carries no libc for it.
#  LFS     -- musl's off_t is 64-bit on 32-bit arm, and busybox static-asserts that its own uoff_t
#             matches. without this the build stops at "BUG_off_t_size_is_misdetected".
REQUIRED="BUSYBOX STATIC LFS"

say() { echo "== $*"; }
mkdir -p "$WORK"; cd "$WORK"

TAR=busybox-$VERSION.tar.bz2
if [ ! -f "$TAR" ]; then
    say "fetch $URL"
    # apple's curl: macos 15 gates lan access per binary, and this one is never the problem
    /usr/bin/curl -sSL --max-time 300 -o "$TAR" "$URL"
fi
say "verify the tarball"
GOT=$(shasum -a 256 "$TAR" | cut -d' ' -f1)
[ "$GOT" = "$SHA256" ] || { echo "sha256 mismatch: got $GOT, want $SHA256" >&2; exit 1; }

SRC=$WORK/busybox-$VERSION
rm -rf "$SRC"; tar xjf "$TAR"
cd "$SRC"

# kconfig's own tools are built for THIS machine, and on macos they want libintl for gettext.
# KBUILD_NO_NLS is upstream's switch for that: lkc.h then defines gettext() as the identity.
HOSTFLAGS="-DKBUILD_NO_NLS -w"
say "configure (allnoconfig, then only what we asked for)"
make allnoconfig HOSTCC="$ZIG cc" HOSTCFLAGS="$HOSTFLAGS" >/dev/null

enable() {
    for k in $1; do
        if grep -q "^# CONFIG_$k is not set" .config; then
            sed -i.bak "s/^# CONFIG_$k is not set/CONFIG_$k=y/" .config && rm -f .config.bak
        elif ! grep -q "^CONFIG_$k=" .config; then
            echo "CONFIG_$k=y" >> .config
        fi
    done
}
enable "$REQUIRED"; enable "$APPLETS_BOOT"; enable "$APPLETS_DEBUG"
# `|| true` is not sloppiness: `yes` is killed by SIGPIPE the moment oldconfig stops reading, so
# under `set -o pipefail` the pipeline reports 141 and takes the script down with it. what actually
# matters is checked immediately below.
yes "" | make oldconfig HOSTCC="$ZIG cc" HOSTCFLAGS="$HOSTFLAGS" >/dev/null 2>&1 || true

for k in $REQUIRED; do
    grep -q "^CONFIG_$k=y" .config || { echo "CONFIG_$k did not stick" >&2; exit 1; }
done

# AR/LD: busybox wants gnu-style `ar rcs` (with no members, for an empty dir) and a relocatable
# `ld -r`. macos ships bsd ar and a linker that does neither, so use zig's llvm-ar and drive the
# relocatable link through zig cc. SKIP_STRIP because busybox calls strip with gnu options macos
# strip rejects -- and lld has already stripped the output, so there is nothing left to do.
say "cross-compile for $TARGET"
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" \
    CC="$ZIG cc -target $TARGET" \
    HOSTCC="$ZIG cc" HOSTCFLAGS="$HOSTFLAGS" \
    AR="$ZIG ar" LD="$ZIG cc -target $TARGET -nostdlib" \
    SKIP_STRIP=y >/dev/null

[ -f busybox_unstripped ] || { echo "no binary was produced" >&2; exit 1; }
cp busybox_unstripped "$OUT"
chmod 0755 "$OUT"

say "built $OUT"
file "$OUT" 2>/dev/null || true
echo "   $(wc -c < "$OUT" | tr -d ' ') bytes, $(grep -c '^CONFIG_.*=y' .config) config symbols"
echo "   applets: $(sed -n 's/^CONFIG_\([A-Z0-9_]*\)=y$/\1/p' .config | wc -l | tr -d ' ') enabled"
echo
echo "this is not installed anywhere. the image build takes it as an input, and nothing here"
echo "writes to the device or to /res."
