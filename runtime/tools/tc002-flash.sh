#!/bin/bash
# tc002-flash.sh: flash an UPDATE.img to the device's `res` partition, over usb where possible.
#
#   runtime/tools/tc002-flash.sh <UPDATE.img> [--lan] [--no-backup] [--yes]
#                                [--tokens=FILE] [--no-notice]
#
# this writes to flash. it is the only script in this repo that does.
#
# **why usb and not wifi.** the flash sequence stops `zkswe` and the device reboots partway
# through. wifi on this device is brought up by whatever owns the panel -- the stock app, or our
# runtime -- so the lan transport can disappear at exactly the moment the flash is running, and a
# half-finished flash with no way in is the one outcome worth engineering against. usb does not
# depend on the network, the panel owner, or the supplicant.
#
# the catch is that the usb otg controller boots in **host** mode on this device and nothing in the
# stock boot changes it, so the adb gadget the vendor configured is unreachable until something
# writes `usb_device` to otg_role. this script does that over the lan first, waits for the gadget to
# enumerate, and then uses usb for the flash itself. (a flashed runtime sets the role itself at
# startup -- `--usb-role`, default `device` -- so after this succeeds usb comes back on its own.)
#
# staging goes to /data, not /tmp: the flasher's first pass restarts the app and this device reboots
# partway through, and /tmp is a tmpfs, so an image staged there is gone before the write happens.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PY=${PY:-/usr/bin/python3}
IMGTOOL="$ROOT/tc002-update-img.py"
BACKUP_DIR=${TC002_BACKUP_DIR:-$HOME/tc002-firmware/mtd-backup-$(date +%Y%m%d)}
LAN=${TC002_DEVICE:-10.0.0.111:5555}

say()  { echo "== $*"; }
warn() { echo "   warning: $*" >&2; }
die()  { echo "error: $*" >&2; exit 1; }

IMG=""; FORCE_LAN=0; SKIP_BACKUP=0; ASSUME_YES=0; TOKENS=${TC002_TOKENS:-tokens}; NOTICE=1
for a in "$@"; do
    case "$a" in
        --no-notice)  NOTICE=0 ;;
        --tokens=*)   TOKENS=${a#--tokens=} ;;
        --lan)        FORCE_LAN=1 ;;
        --no-backup)  SKIP_BACKUP=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        -h|--help)    sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           die "unknown option $a" ;;
        *)            IMG=$a ;;
    esac
done
[ -n "$IMG" ] || { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -f "$IMG" ] || die "no such image: $IMG"

# ---------------------------------------------------------------- the image
say "check the image"
"$PY" "$IMGTOOL" inspect "$IMG" | sed 's/^/   /'
"$PY" "$IMGTOOL" inspect "$IMG" | grep -q '^verdict: the device would accept this image' \
    || die "the image tool will not vouch for this file; not flashing it"

# ------------------------------------------------------------- the transport
adb start-server >/dev/null 2>&1 || true
adb connect "$LAN" >/dev/null 2>&1 || true

usb_serial() {
    # a usb transport is any device line that is not host:port
    adb devices | awk 'NR>1 && $2=="device" && $1 !~ /:[0-9]+$/ {print $1; exit}'
}
lan_ok() { adb -s "$LAN" shell true >/dev/null 2>&1; }

DEV=""
if [ "$FORCE_LAN" -eq 0 ]; then
    DEV=$(usb_serial || true)
    if [ -z "$DEV" ]; then
        if lan_ok; then
            say "no usb transport yet; putting the otg controller into device mode over the lan"
            # otg_role is a plain write. do NOT read the usb_device/usb_host/usb_null files next to
            # it to find out the current role: they are actions, and reading one performs it.
            adb -s "$LAN" shell "echo usb_device > /sys/bus/platform/devices/soc:usbotg/otg_role" >/dev/null 2>&1 || true
            for _ in $(seq 1 15); do
                sleep 1
                DEV=$(usb_serial || true)
                [ -n "$DEV" ] && break
            done
            if [ -z "$DEV" ]; then
                # the role write takes, but the gadget only re-attaches when the port sees a fresh
                # connect. if the cable stayed plugged in across a reboot -- which resets the role
                # to usb_host -- the host's view of the port never changed, and nothing will
                # enumerate until someone unplugs it. measured: a replug fixes it every time.
                say "the otg role is set, but the gadget has not re-attached"
                echo "   >>> unplug the usb cable and plug it back in, then press enter (or ctrl-c to use the lan)"
                read -r _ </dev/tty || true
                for _ in $(seq 1 20); do
                    sleep 1
                    DEV=$(usb_serial || true)
                    [ -n "$DEV" ] && break
                done
            fi
        fi
    fi
fi
if [ -n "$DEV" ]; then
    say "using the usb transport ($DEV)"
else
    lan_ok || die "no device: neither usb nor $LAN answers"
    DEV=$LAN
    if [ "$FORCE_LAN" -eq 1 ]; then
        say "using the lan transport ($DEV), as asked"
    else
        warn "no usb transport available; falling back to $DEV."
        warn "the flash reboots the device and wifi may not come back on its own."
        warn "plug in a usb cable and re-run if you can -- see the header of this script."
    fi
fi
sh_() { adb -s "$DEV" shell "$@" 2>/dev/null | tr -d '\r'; }

BB=$(sh_ "ls /tmp/busybox 2>/dev/null" || true)   # optional; only used for nicer output

# ------------------------------------------------------------------ backup
RES_BACKUP="$BACKUP_DIR/mtd3-res.bin"
if [ "$SKIP_BACKUP" -eq 1 ]; then
    warn "--no-backup: not taking one. the way back from a bad flash is your problem."
elif [ -s "$RES_BACKUP" ]; then
    say "res backup already present: $RES_BACKUP"
else
    say "backing up the res partition to $RES_BACKUP"
    mkdir -p "$BACKUP_DIR"
    # the mtd nodes do not exist in /dev on this device; make the one we need.
    adb -s "$DEV" shell "mknod /dev/mtdblock3 b 31 3 2>/dev/null; true" >/dev/null 2>&1
    : > "$RES_BACKUP"
    off=0
    # 2 mib at a time: never stage a partition-sized file in the device's 16 mib tmpfs
    while [ "$off" -lt 8192 ]; do
        n=2048; [ $((off + n)) -gt 8192 ] && n=$((8192 - off))
        adb -s "$DEV" shell "dd if=/dev/mtdblock3 of=/tmp/.flashchunk bs=1024 skip=$off count=$n 2>/dev/null" >/dev/null 2>&1 </dev/null
        adb -s "$DEV" pull /tmp/.flashchunk "$BACKUP_DIR/.chunk" >/dev/null 2>&1 </dev/null
        cat "$BACKUP_DIR/.chunk" >> "$RES_BACKUP"
        off=$((off + n))
    done
    adb -s "$DEV" shell "rm -f /tmp/.flashchunk" >/dev/null 2>&1 </dev/null
    rm -f "$BACKUP_DIR/.chunk"
    say "backed up $(wc -c < "$RES_BACKUP" | tr -d ' ') bytes"
    if command -v unsquashfs >/dev/null 2>&1; then
        tmpd=$(mktemp -d)
        if unsquashfs -d "$tmpd/res" "$RES_BACKUP" >/dev/null 2>&1 && [ -f "$tmpd/res/lib/libzkgui.so" ]; then
            say "backup verified: it unpacks and holds the stock libzkgui.so"
        else
            rm -rf "$tmpd"; die "the backup does not unpack -- refusing to flash without a way back"
        fi
        rm -rf "$tmpd"
    else
        warn "no unsquashfs here, so the backup was written but not verified"
    fi
fi

# ----------------------------------------------------------------- confirm
echo
echo "  about to write $(basename "$IMG") to the res partition (mtd3) of $DEV."
echo "  this is flash. the device will reboot itself partway through."
echo "  the way back is $RES_BACKUP plus the boot-failure counter, which hands"
echo "  the panel to the stock app after three bad boots."
echo
if [ "$ASSUME_YES" -eq 0 ]; then
    printf "  type 'flash' to continue: "
    read -r reply
    [ "$reply" = "flash" ] || { echo "   nothing was written."; exit 1; }
fi


# ---------------------------------------------------------------- the notice
# put a pulsing "Updating..." on the panel before the flash starts.
#
# the device goes dark-ish for a minute and a half and then reappears, with no indication that
# anything is happening. the panel holds its last latched frame while nothing is driving it, so
# whatever is on screen when the runtime dies is what stays there for the whole write. that makes
# the message free: draw it, then trigger.
#
# it is drawn as the **canvas base**, not a notification: a notification expires on its own timer
# and this has to last as long as the flash does. the base is a persisted setting, so the previous
# one is captured first and restored at the end -- otherwise the device comes back from the reboot
# still showing "DO NOT UNPLUG" and never returns to the clock.
#
# the `mini` face is 3x5 and fits 13 characters; "Updating..." is 11. it has one set of
# letterforms for both cases, so the capital here is for the reader of this script rather than the
# panel, and it does carry `.`, so the ellipsis survives.
#
# it pulses. a frozen panel and a dead one look identical, and the pulse is the difference -- while
# the runtime is still alive it is visibly breathing, which is what says "working, wait" rather than
# "crashed". the moment the renderer dies it stops on whatever brightness it had, and that frozen
# frame carries the word for the rest of the write.
API_PORT=18099
api_ready=0
saved_base=""
saved_generator=""

api() { # api <method> <path> <token> [body]
    local m=$1 path=$2 tok=$3 body=${4:-}
    if [ -n "$body" ]; then
        /usr/bin/curl -s -m 5 -X "$m" "http://127.0.0.1:$API_PORT/api/v1$path" \
            -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "$body"
    else
        /usr/bin/curl -s -m 5 -X "$m" "http://127.0.0.1:$API_PORT/api/v1$path" \
            -H "Authorization: Bearer $tok"
    fi
}

token_of() { # token_of control|admin -- never echoed anywhere but into a header
    [ -f "$TOKENS" ] || return 1
    sed -n "s/^$1=\([0-9a-fA-F]\{64\}\)$/\1/p" "$TOKENS" | head -1
}

show_notice() {
    [ "$NOTICE" -eq 1 ] || return 0
    local admin; admin=$(token_of admin || true)
    if [ -z "$admin" ]; then
        warn "no admin token in $TOKENS; the panel will freeze with no explanation on it."
        warn "pass --tokens=FILE, or --no-notice to stop being told."
        return 0
    fi
    adb -s "$DEV" forward "tcp:$API_PORT" tcp:80 >/dev/null 2>&1 || {
        warn "could not forward the api port; skipping the on-panel notice"; return 0; }
    api_ready=1
    local status; status=$(api GET /status "$admin" || true)
    saved_base=$(printf '%s' "$status" | sed -n 's/.*"base":"\([a-z]*\)".*/\1/p')
    saved_generator=$(printf '%s' "$status" | sed -n 's/.*"generator":"\([a-z]*\)".*/\1/p')
    [ -n "$saved_base" ] || { warn "could not read the current scene; skipping the notice"; return 0; }

    api PUT /canvas "$admin" '{"elements":[
        {"id":"l1","type":"text","at":[0,5],"size":[52,5],"font":"mini","align":"centre","colour":"ff8000",
         "text":"Updating...","animate":{"kind":"pulse","ms":1600}}]}' >/dev/null
    api PUT /scene "$admin" '{"base":"canvas"}' >/dev/null
    say "panel now reads Updating... (was: $saved_base)"
    sleep 1   # let it be drawn and latched before anything kills the renderer
}

restore_scene() {
    [ "$api_ready" -eq 1 ] && [ -n "$saved_base" ] || return 0
    local admin; admin=$(token_of admin || true)
    [ -n "$admin" ] || return 0
    local body="{\"base\":\"$saved_base\""
    [ -n "$saved_generator" ] && [ "$saved_base" = art ] && body="$body,\"generator\":\"$saved_generator\""
    body="$body}"
    for _ in $(seq 1 10); do
        adb -s "$DEV" forward "tcp:$API_PORT" tcp:80 >/dev/null 2>&1 || true
        if api PUT /scene "$admin" "$body" 2>/dev/null | grep -q applied; then
            say "panel back to $saved_base"
            return 0
        fi
        sleep 3
    done
    warn "could not put the panel back to $saved_base -- it may still read Updating..."
    warn "fix with: tools/tc002ctl.py -s <ip> --token-file $TOKENS scene $saved_base"
}
# the restore has to happen even if the wait loop gives up or the script is interrupted, or the
# device is left permanently telling its owner not to unplug it.
trap restore_scene EXIT

# ------------------------------------------------------------------- flash
say "stage the image on /data (it has to survive the reboot the flasher causes)"
adb -s "$DEV" shell "rm -f /data/update.img" >/dev/null 2>&1
adb -s "$DEV" push "$IMG" /data/update.img
WANT=$(( $(wc -c < "$IMG" | tr -d ' ') ))
GOT=$(sh_ "ls -l /data/update.img" | awk '{print $5}')
[ "$WANT" = "$GOT" ] || die "the staged image is $GOT bytes, expected $WANT"
say "staged $GOT bytes"

show_notice

say "arm the flasher (dir before flag: the flag is the trigger and the dir must already be set)"
adb -s "$DEV" shell "setprop persist.zkupgrade.dir /data" >/dev/null 2>&1
adb -s "$DEV" shell "setprop sys.zkupgrade.dir /data" >/dev/null 2>&1
adb -s "$DEV" shell "setprop sys.zkupgrade.flag 255" >/dev/null 2>&1
say "flag=$(sh_ 'getprop sys.zkupgrade.flag') dir=$(sh_ 'getprop sys.zkupgrade.dir')"

say "restart zkswe so the loader runs its upgrade check"
adb -s "$DEV" shell "setprop ctl.stop zkswe; setprop ctl.start zkswe" >/dev/null 2>&1 || true

# ------------------------------------------------------------------ settle
say "waiting for the device to settle (up to 4 minutes)"
gone=0
for i in $(seq 1 48); do
    sleep 5
    if adb -s "$DEV" shell true >/dev/null 2>&1; then
        [ "$gone" -eq 1 ] && { say "back after about $((i * 5))s"; break; }
    else
        [ "$gone" -eq 0 ] && say "device went away at about $((i * 5))s (expected: it reboots)"
        gone=1
        adb connect "$LAN" >/dev/null 2>&1 || true
    fi
done

echo
say "what is running now"
adb connect "$LAN" >/dev/null 2>&1 || true
for t in "$(usb_serial || true)" "$LAN"; do
    [ -n "$t" ] || continue
    adb -s "$t" shell true >/dev/null 2>&1 || continue
    echo "   transport $t:"
    adb -s "$t" shell "cat /proc/uptime; ls /res/bin 2>/dev/null; getprop init.svc.zkswe" 2>/dev/null | tr -d '\r' | sed 's/^/     /'
    break
done
echo
echo "   if /res/bin lists tc002-supervisor, the runtime is flashed and this worked."
echo "   if it does not, the image did not take; nothing else changed and the device"
echo "   is still on the stock app. the backup is at $RES_BACKUP."
