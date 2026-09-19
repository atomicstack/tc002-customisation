#!/usr/bin/env bash
# tc002-onboard.sh: take a tc002 from its box to the custom runtime, in one command.
#
#   ./tc002-onboard.sh [--wifi-ssid NAME] [--device IP[:PORT]] [--flash] [--yes]
#                      [--work DIR] [--no-adopt]
#
# by default this does everything EXCEPT write to flash: it finds or adopts the
# device, checks it is what these notes were written against, records a
# fingerprint you can keep, takes a verified backup of the `res` partition and
# builds your image from it. it then prints the one command that flashes. pass
# --flash to go all the way in a single run; either way the write is gated on a
# typed confirmation unless --yes.
#
# **why your image is built here and not shipped.** the `res` partition carries
# `lib/libzkgui.so`, the vendor application, and that file differs between units
# -- two clocks measured here run application builds sixteen days apart. so a
# prebuilt image would silently install another device's vendor app. the image
# is assembled from a dump of YOUR device, which is the same dump that serves as
# your way back. see FINGERPRINTS.md.
#
# **what flashing costs you.** the custom runtime replaces the stock
# application: the ulanzi app, the cloud client and the stock http api are gone
# while it runs. the backup this script takes is how you undo that.
#
# requires: adb, python3, squashfs-tools (mksquashfs/unsquashfs). no zig, no
# compiler -- the armv7 binaries ship prebuilt. macos and linux both work; only
# the automatic "join the setup ap" step is macos-only, and on linux you are
# walked through it by hand.

set -u

SELF=$(cd "$(dirname "$0")" && pwd)
RUNTIME_DIR="$SELF/runtime"
TOOLS="$RUNTIME_DIR/tools"
PAYLOAD="$RUNTIME_DIR/zig-out"
WORK="$HOME/tc002-onboard"
DEV=""
WIFI_SSID=""
DO_FLASH=0
ASSUME_YES=0
NO_ADOPT=0
OS=$(uname -s)

while [ $# -gt 0 ]; do
  case "$1" in
    --wifi-ssid) WIFI_SSID="$2"; shift 2 ;;
    --device)    DEV="$2"; shift 2 ;;
    --work)      WORK="$2"; shift 2 ;;
    --flash)     DO_FLASH=1; shift ;;
    --yes)       ASSUME_YES=1; shift ;;
    --no-adopt)  NO_ADOPT=1; shift ;;
    -h|--help)   sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

ADB=$(command -v adb || true)
PY=$(command -v python3 || true)
[ -x /usr/bin/python3 ] && PY=/usr/bin/python3   # apple's is exempt from the lan privacy gate

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
say()  { printf '   %s\n' "$*"; }
die()  { printf '\n   !! %s\n' "$*" >&2; exit 1; }
dsh()  { "$ADB" -s "$DEV" shell "$@" 2>&1 | tr -d '\r'; }

# ---------------------------------------------------------------- host preflight
step "host preflight"
[ -n "$ADB" ] || die "no adb on PATH. install android platform-tools."
[ -n "$PY"  ] || die "no python3 on PATH."
for t in mksquashfs unsquashfs; do
  command -v "$t" >/dev/null || die "no $t on PATH. install squashfs-tools:
     macos:  brew install squashfs-tools
     debian: sudo apt install squashfs-tools"
done
say "adb        $ADB"
say "python3    $PY"
say "squashfs   $(command -v mksquashfs)"

MISSING=""
for b in tc002-supervisor tc002d tc002-netd tc002-ntfy tc002-audiod tc002-berryd busybox; do
  [ -f "$PAYLOAD/bin/$b" ] || MISSING="$MISSING $b"
done
[ -f "$PAYLOAD/lib/libtc002-bootstrap.so" ] || MISSING="$MISSING libtc002-bootstrap.so"
[ -z "$MISSING" ] || die "the runtime payload is incomplete, missing:$MISSING
     in a release tarball these ship prebuilt under runtime/zig-out/.
     in a source checkout, run: (cd runtime && zig build) && runtime/tools/tc002-mkbusybox.sh"
say "payload    $(ls "$PAYLOAD/bin" | wc -l | tr -d ' ') binaries + bootstrap, prebuilt armv7"

if [ -f "$SELF/MANIFEST.sha256" ]; then
  if (cd "$SELF" && shasum -a 256 -c MANIFEST.sha256 >/dev/null 2>&1); then
    say "manifest   verified"
  else
    die "MANIFEST.sha256 does not match the files on disk. re-download the release."
  fi
fi
mkdir -p "$WORK" || die "cannot create $WORK"
say "workdir    $WORK"

# ------------------------------------------------------------- find the device
step "find the device"
find_device() {
  "$PY" "$SELF/tc002-adopt.py" discover 2>/dev/null \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1
}
if [ -z "$DEV" ]; then
  say "listening for a tc002 already on this network..."
  FOUND=$(find_device)
  if [ -n "$FOUND" ]; then
    DEV="$FOUND:5555"
    say "found $FOUND"
  elif [ "$NO_ADOPT" = "1" ]; then
    die "nothing found, and --no-adopt was given."
  else
    say "nothing answered. the clock is probably still hosting its setup ap."
    [ -n "$WIFI_SSID" ] || die "to adopt it, re-run with --wifi-ssid <your 2.4ghz network>.
     the tc002 has no 5 ghz radio, so a 5 ghz-only ssid will fail after the
     device has already accepted the credentials."
    if [ "$OS" = "Darwin" ]; then
      say "adopting it over its setup ap. this takes THIS machine off your network"
      say "for a minute or two, and puts it back afterwards."
      "$SELF/tc002-ap-probe.sh" --adopt-only --wifi-ssid "$WIFI_SSID" \
          --busybox "$PAYLOAD/bin/busybox" --out "$WORK/adopt.log" || die "adoption failed; see $WORK/adopt.log"
    else
      say "automatic ap joining is macos-only. do this by hand:"
      say "  1. join the wifi network 'U-Clock'. the password is 12345678 on every unit."
      say "  2. press enter here."
      read -r _
      say "sending your network's credentials to 192.168.100.1 ..."
      printf '  password for wifi network %s (hidden): ' "$WIFI_SSID"
      read -rs WPASS; printf '\n'
      RESP=$(W_SSID="$WIFI_SSID" W_PSK="$WPASS" "$PY" -c 'import json,os,sys;sys.stdout.write(json.dumps({"ssid":os.environ["W_SSID"],"password":os.environ["W_PSK"]}))' \
             | curl -sL -m 20 -X POST -H 'Content-Type: application/json' --data-binary @- http://192.168.100.1/setWifiConfig)
      WPASS=""
      echo "$RESP" | grep -q '"code"[[:space:]]*:[[:space:]]*200' || die "the device rejected the credentials: $RESP"
      say "accepted. rejoin your normal network, then press enter."
      read -r _
    fi
    say "looking for it on your network..."
    for i in 1 2 3 4 5 6; do
      FOUND=$(find_device); [ -n "$FOUND" ] && break; sleep 5
    done
    [ -n "$FOUND" ] || die "adopted, but it never appeared on the network. check your router."
    DEV="$FOUND:5555"
    say "found $FOUND"
  fi
fi
"$ADB" connect "$DEV" >/dev/null 2>&1
sleep 1
dsh 'echo ok' | grep -q ok || die "no adb shell on $DEV"
say "adb        $DEV"

# ------------------------------------------------------------ device preflight
step "device preflight"
MODEL=$(dsh 'getprop ro.product.model')
[ "$MODEL" = "Zkswe_SSD21X_SPINOR" ] || die "this is not a tc002: ro.product.model = '$MODEL'"
SN=""
say "model      $MODEL"
say "build      $(dsh 'getprop ro.build.date') / $(dsh 'getprop ro.build.version.release')"

"$ADB" -s "$DEV" push "$PAYLOAD/bin/busybox" /tmp/busybox >/dev/null 2>&1 \
  || die "could not push busybox to the device"
dsh 'chmod 755 /tmp/busybox' >/dev/null
# busybox dispatches on argv[0]; it MUST be called busybox or every applet fails
dsh '/tmp/busybox true' >/dev/null 2>&1 || die "the pushed busybox does not run on this device"
say "busybox    pushed to /tmp/busybox (tmpfs; gone on the next power cycle)"

# ro.serialno is empty on this firmware. devSn comes from the stock http api,
# which only answers before the runtime replaces it; the wlan0 mac always works.
SN=$(curl -sL -m 4 "http://${DEV%%:*}/getBase" 2>/dev/null \
     | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("devSn","") or "")
except Exception: print("")' 2>/dev/null)
[ -n "$SN" ] || SN=$(dsh '/tmp/busybox cat /sys/class/net/wlan0/address 2>/dev/null' | tr -d ':' | tr -d ' ')
[ -n "$SN" ] || SN=unknown
say "serial     $SN"

MTD=$(dsh 'cat /proc/mtd')
echo "$MTD" | grep -q '"res"'    || die "no partition named res in /proc/mtd; this layout is not the one these notes describe"
echo "$MTD" | grep -q '"rootfs"' || die "no rootfs partition in /proc/mtd"
RESLINE=$(echo "$MTD" | grep '"res"')
say "partitions $(echo "$MTD" | grep -c '^mtd') found; res = $(echo "$RESLINE" | awk '{print $1 $2}')"

FP="$WORK/fingerprint-$SN.txt"
{
  echo "tc002 fingerprint, $(date), device $DEV, sn $SN"
  echo "ro.build.date          = $(dsh 'getprop ro.build.date')"
  echo "ro.build.version       = $(dsh 'getprop ro.build.version.release')"
  echo "kernel                 = $(dsh '/tmp/busybox uname -a')"
  echo "res superblock         :"
  dsh '/tmp/busybox mknod /dev/mtdblock3 b 31 3 2>/dev/null; /tmp/busybox dd if=/dev/mtdblock3 bs=1 count=64 2>/dev/null | /tmp/busybox hexdump -C'
  echo "res files              = $(dsh 'cd /res && /tmp/busybox find . -type f | /tmp/busybox wc -l')"
  echo "res aggregate md5      = $(dsh 'cd /res && /tmp/busybox find . -type f | /tmp/busybox sort | /tmp/busybox xargs /tmp/busybox md5sum | /tmp/busybox md5sum')"
  echo "libzkgui.so            = $(dsh '/tmp/busybox sha256sum /res/lib/libzkgui.so')"
  echo "EasyUI.cfg             = $(dsh '/tmp/busybox sha256sum /res/etc/EasyUI.cfg')"
  echo "udisk update.img       = $(dsh '/tmp/busybox md5sum /mnt/storage/update.img 2>/dev/null')"
} > "$FP"
say "fingerprint recorded to $FP"
say "           compare it against FINGERPRINTS.md; a mismatch is not a fault,"
say "           it means your unit ships a different res revision than the notes."

DATAFREE=$(dsh '/tmp/busybox df -k /data | /tmp/busybox tail -1' | awk '{print $4}')
say "/data free ${DATAFREE:-?} kb"
# the flasher stages the image on /data because it has to survive the reboot it
# causes. a fresh device has room; one that has been used may not.
case "$DATAFREE" in
  ''|*[!0-9]*) say "           could not read free space; the flash may fail late if /data is full" ;;
  *) [ "$DATAFREE" -lt 5200 ] && say "           WARNING: the flasher stages a ~4.4 mb image here. this is tight." ;;
esac

if dsh '/tmp/busybox ls /mnt/storage/update.img' | grep -q update.img; then
  say ""
  say "NOTE: /mnt/storage/update.img exists, and an empty persist.zkupgrade.dir"
  say "      means the reset button reflashes THAT image -- which on both units"
  say "      measured here is an older firmware than the device shipped with."
  say "      the reset button recovers, but it also downgrades."
fi

# -------------------------------------------------------------------- backup
step "back up the res partition (this is your way back)"
BACKUP="$WORK/mtd3-res-$SN-$(date +%Y%m%d-%H%M%S).bin"
say "reading 8 mib from mtd3 in 2 mib chunks (tmpfs is small; do not stage it whole)"
: > "$BACKUP"
for off in 0 2048 4096 6144; do
  dsh "/tmp/busybox dd if=/dev/mtdblock3 of=/tmp/chunk bs=1024 skip=$off count=2048 2>/dev/null" >/dev/null
  "$ADB" -s "$DEV" pull /tmp/chunk "$WORK/.chunk" >/dev/null 2>&1 || die "could not pull chunk at $off kb"
  cat "$WORK/.chunk" >> "$BACKUP"
  printf '\r   pulled %s of 8 mib' "$((off/1024 + 2))"
done
rm -f "$WORK/.chunk"; dsh '/tmp/busybox rm -f /tmp/chunk' >/dev/null
echo ""
say "backup     $BACKUP ($(wc -c < "$BACKUP" | tr -d ' ') bytes)"

# the gate that matters: a backup that does not unpack is not a backup
unsquashfs -l "$BACKUP" 2>/dev/null | grep -q 'lib/libzkgui.so' \
  || die "the backup does not unpack, or does not contain lib/libzkgui.so.
     refusing to go further: without a good backup there is no way back.
     nothing has been written to your device."
say "verified   it unpacks and contains lib/libzkgui.so"

# --------------------------------------------------------------------- build
step "build your image from your own res"
IMG="$WORK/RUNTIME-$SN-$(date +%Y%m%d).img"
"$TOOLS/tc002-mkimage.sh" "$BACKUP" "$IMG" "$WORK/mkimage" >"$WORK/mkimage.log" 2>&1 \
  || { tail -20 "$WORK/mkimage.log"; die "image build failed; full log at $WORK/mkimage.log"; }
say "image      $IMG ($(wc -c < "$IMG" | tr -d ' ') bytes)"
say "           built from YOUR device's res, so it carries YOUR libzkgui.so"

# --------------------------------------------------------------------- flash
if [ "$DO_FLASH" != "1" ]; then
  step "stopping here, because this is the step that writes flash"
  say "everything is ready and nothing has been written to your device."
  say ""
  say "to flash, run:"
  say "  $TOOLS/tc002-flash.sh $IMG"
  say ""
  say "or re-run this script with --flash to do it in one go."
  say "your way back, if you ever want the stock app: $BACKUP"
  exit 0
fi

step "flash"
say "this writes to flash. the stock application is replaced by the custom"
say "runtime, and the device reboots itself partway through."
say "your way back is $BACKUP"
if [ "$ASSUME_YES" != "1" ]; then
  printf '\n   type "flash" to continue: '
  read -r ANS
  [ "$ANS" = "flash" ] || { say "not confirmed; nothing written."; exit 0; }
fi
"$TOOLS/tc002-flash.sh" "$IMG" --yes || die "the flash reported a failure. your backup is at $BACKUP"

# -------------------------------------------------------------------- verify
step "verify"
sleep 5
for i in 1 2 3 4 5 6 7 8; do
  "$ADB" connect "$DEV" >/dev/null 2>&1
  if dsh '/tmp/busybox ls /res/bin/tc002-supervisor 2>/dev/null' | grep -q tc002-supervisor; then
    say "the runtime is on flash and /res/bin/tc002-supervisor is present"
    break
  fi
  sleep 10
done
say ""
say "done. the console is panel-v2/start-panel.sh, and the api tokens live on"
say "the device at /data/tc002/state/. keep $BACKUP somewhere safe -- it is the"
say "only copy of your unit's stock application."
