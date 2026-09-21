#!/usr/bin/env bash
# tc002-mkrelease.sh: build a release tarball a non-developer can use.
#
#   ./tc002-mkrelease.sh [version] [outdir]
#
# the point of this file is that the people flashing a clock should not need a
# compiler. it builds the armv7 binaries and the static busybox here, once, and
# packs them with the scripts and the docs into a tree that `tc002-onboard.sh`
# can drive with nothing installed but adb, python3 and squashfs-tools.
#
# **it does not ship a flashable image, and cannot.** the `res` partition
# carries the vendor's `lib/libzkgui.so`, and that file differs between units --
# two clocks measured here are sixteen days apart. every user's image is built
# on their own machine from a dump of their own device. see FINGERPRINTS.md.
#
# zig 0.16 is required HERE and nowhere downstream. publishing is deliberately
# manual: this script prints the `gh release create` line, it does not run it.

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=${1:-$(git -C "$HERE" describe --tags --always --dirty 2>/dev/null || echo dev)}
OUTDIR=${2:-$HERE/dist}
NAME="tc002-runtime-$VERSION"
STAGE="$OUTDIR/$NAME"

say() { printf '== %s\n' "$*"; }

say "version $VERSION"
command -v zig >/dev/null || { echo "need zig 0.16 to build the payload" >&2; exit 1; }

# -Dbin_dir and -Dnetup are not optional here. they are compiled in: the flashed
# supervisor spawns its five children by absolute path and never sees an
# argument, and -Dnetup turns on the bring-up a flashed install must do itself.
# a plain `zig build` produces a payload that flashes and then does nothing.
say "build the armv7 binaries for /res/bin"
( cd "$HERE/runtime" && zig build -Dbin_dir=/res/bin -Dnetup=true \
                     && zig build -Dbin_dir=/res/bin -Dnetup=true check )

if [ ! -f "$HERE/runtime/zig-out/bin/busybox" ] || [ ! -s "$HERE/runtime/zig-out/bin/busybox.applets" ]; then
  say "build the static busybox (the device's own has no dd, grep, md5sum...)"
  "$HERE/runtime/tools/tc002-mkbusybox.sh" "$OUTDIR/busybox-build" "$HERE/runtime/zig-out/bin/busybox"
fi
[ -s "$HERE/runtime/zig-out/bin/busybox.applets" ] || { echo "no busybox.applets beside the binary" >&2; exit 1; }

say "check the payload is armv7, static, and built for /res/bin"
LC_ALL=C grep -qa '/res/bin' "$HERE/runtime/zig-out/bin/tc002-supervisor" \
  || { echo "the supervisor has no /res/bin in it -- -Dbin_dir did not take" >&2; exit 1; }
for b in tc002-supervisor tc002d tc002-netd tc002-ntfy tc002-audiod tc002-berryd busybox; do
  f="$HERE/runtime/zig-out/bin/$b"
  [ -f "$f" ] || { echo "missing binary: $b" >&2; exit 1; }
  file "$f" | grep -q 'ARM' || { echo "$b is not an arm binary -- built for the host by mistake?" >&2; exit 1; }
done
file "$HERE/runtime/zig-out/lib/libtc002-bootstrap.so" | grep -q 'ARM' \
  || { echo "the bootstrap is not an arm shared object" >&2; exit 1; }

say "assemble $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/runtime/tools" "$STAGE/runtime/boot" \
         "$STAGE/runtime/zig-out/bin" "$STAGE/runtime/zig-out/lib" "$STAGE/docs"

# the driver, and the two scripts it calls
cp "$HERE/tc002-onboard.sh" "$HERE/tc002-ap-probe.sh" \
   "$HERE/tc002-devices.py" "$STAGE/"
# both mkimage and flash resolve this as $ROOT/tc002-update-img.py
cp "$HERE/tc002-update-img.py" "$STAGE/"
cp "$HERE/runtime/tools/tc002-update.sh" "$HERE/runtime/tools/tc002-up.sh" "$HERE/runtime/tools/tc002-run.sh" \
   "$HERE/runtime/tools/tc002-lock.sh" "$STAGE/runtime/tools/"
cp "$HERE/runtime/tools/tc002-mkimage.sh" "$HERE/runtime/tools/tc002-flash.sh" \
   "$HERE/runtime/tools/tc002ctl.py" "$STAGE/runtime/tools/"
# mkimage copies these into the image itself
cp "$HERE/runtime/boot/tc002-netup.sh" "$HERE/runtime/boot/tc002-udhcpc.script" "$STAGE/runtime/boot/"
cp "$HERE"/runtime/zig-out/bin/tc002-supervisor "$HERE"/runtime/zig-out/bin/tc002d \
   "$HERE"/runtime/zig-out/bin/tc002-netd "$HERE"/runtime/zig-out/bin/tc002-ntfy \
   "$HERE"/runtime/zig-out/bin/tc002-audiod "$HERE"/runtime/zig-out/bin/tc002-berryd \
   "$HERE"/runtime/zig-out/bin/busybox "$HERE"/runtime/zig-out/bin/busybox.applets \
   "$STAGE/runtime/zig-out/bin/"
cp "$HERE/runtime/zig-out/lib/libtc002-bootstrap.so" "$STAGE/runtime/zig-out/lib/"
cp "$HERE/INSTALL.md" "$HERE/SETUP.md" "$HERE/FINGERPRINTS.md" "$HERE/DEVICE.md" \
   "$HERE/SECURITY.md" "$STAGE/docs/"
chmod 755 "$STAGE"/*.sh "$STAGE"/runtime/tools/*.sh "$STAGE"/runtime/zig-out/bin/* 2>/dev/null || true

cat > "$STAGE/README-FIRST.md" <<EOF
# tc002 runtime $VERSION

A replacement application for the Ulanzi TC002 pixel clock. While it runs, the
stock app is not running: no Ulanzi Studio, no cloud client, no stock HTTP API.

## What you need

\`adb\`, \`python3\`, and \`squashfs-tools\`. **No compiler** — the ARM binaries
in \`runtime/zig-out/\` are prebuilt.

    macOS:  brew install android-platform-tools squashfs-tools
    Debian: sudo apt install adb squashfs-tools

## Do this

    ./tc002-onboard.sh --wifi-ssid <your 2.4 GHz network>

It asks for your timezone, then finds your clock — adopting it off its \`U-Clock\` setup AP if it is still
factory-fresh — checks it over, records a fingerprint, takes a **verified backup
of your \`res\` partition**, and builds your image. It writes nothing to flash.
It then prints the one command that does. Add \`--flash\` to go all the way.

The clock has no 5 GHz radio, so give it a 2.4 GHz SSID.

**\`docs/INSTALL.md\` is the full walkthrough.** Read it if anything is unclear
— in particular, a freshly flashed clock has no timezone and no NTP server, and
until both are set it shows a blinking separator and no digits. That is not a
failed flash. \`--flash\` sets them for you.

## Why the image is built on your machine

The \`res\` partition carries the vendor application, \`lib/libzkgui.so\`, and
that file **differs between units** — two clocks measured for these notes run
application builds sixteen days apart. A prebuilt image would install another
device's vendor app onto yours. So your image is assembled from a dump of your
own device, and that dump is also your way back. Keep it.

## Getting back to stock

The backup \`tc002-onboard.sh\` writes into its work directory is the only copy
of your unit's stock application. \`runtime/tools/tc002-flash.sh\` will write it
back. The device's own reset button also recovers, but it reflashes
\`/mnt/storage/update.img\`, which on every unit measured here is *older* than
what the device shipped with — it recovers by downgrading.

## Security note

The setup AP is WPA2 in name only: the passphrase is \`12345678\` on every TC002,
so the key is identical across all of them, and the HTTP API behind it is
unauthenticated. Adopt your clock promptly, on a network you trust.
See \`docs/SETUP.md\`.
EOF

say "write MANIFEST.sha256"
( cd "$STAGE" && find . -type f ! -name MANIFEST.sha256 | sed 's#^\./##' | LC_ALL=C sort \
    | xargs shasum -a 256 > MANIFEST.sha256 )
( cd "$STAGE" && shasum -a 256 -c MANIFEST.sha256 >/dev/null ) || { echo "manifest self-check failed" >&2; exit 1; }

say "tar it up"
TARBALL="$OUTDIR/$NAME.tar.gz"
( cd "$OUTDIR" && tar czf "$NAME.tar.gz" "$NAME" )
shasum -a 256 "$TARBALL" | sed 's/^/   /'
printf '   %s bytes\n' "$(wc -c < "$TARBALL" | tr -d ' ')"

cat <<EOF

== done

  $TARBALL

  contents: $(find "$STAGE" -type f | wc -l | tr -d ' ') files, no compiler needed downstream.

  to publish (this script deliberately does not):

    gh release create $VERSION "$TARBALL" \\
       --title "tc002 runtime $VERSION" --notes-file <your notes>
EOF
