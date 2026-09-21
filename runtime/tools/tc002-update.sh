#!/usr/bin/env bash
# tc002-update.sh: put a build on a clock. there are two kinds of update, and the flag says which:
#
#   --in-place   an update with NO reboot. the binaries go to /tmp/tc002 over adb and the runtime
#                restarts in place: about fifteen seconds, the panel dark for three of them, and
#                the previous build is back on the next power cycle, because /tmp is a ramdisk.
#                for trying a build.
#   --flash      an update WITH a reboot. an image built for the res partition is written by the
#                vendor's own flasher and the clock reboots into it: about a minute, the panel
#                blank for ten to fifteen seconds of it, and permanent until the next flash.
#                for keeping a build.
#
# every update, of either kind, puts "updating" on the panel before the panel is taken away.
#
#   runtime/tools/tc002-update.sh --in-place [--device IP[:PORT]] [--no-build]
#                                            [--keep-settings|--reset-settings] [--tz ZONE]
#                                            [--ntp IP|none] [--font NAME] [--base NAME]
#   runtime/tools/tc002-update.sh --flash    [--device IP[:PORT]] [--no-build]
#                                            [--base-image DUMP|UPDATE.img] [--no-backup] [--lan]
#                                            [--yes] [--work DIR]
#
#   --device        adb address (default 10.0.0.111:5555; env TC002_DEVICE). a bare ip or host name
#                   gets :5555, which is the serial adb gives a tcp transport
#   --no-build      push what is in runtime/zig-out. the two modes need different builds (the
#                   flashed supervisor has /res/bin compiled in) and they share zig-out, so the
#                   payload is checked to be the right kind and the wrong one is refused
#   in-place only   --tz/--ntp/--font/--base provision a clock that has no durable settings;
#                   --keep-settings leaves whatever it has alone; --reset-settings overwrites it
#   flash only      --base-image is the res dump or vendor image to build from (default: a fresh
#                   dump of this clock's res, which only works while it still carries
#                   lib/libzkgui.so; a stock dump from ~/tc002-firmware otherwise). --no-backup
#                   skips the flasher's own backup, --lan flashes over wifi without waiting for
#                   a usb cable, --yes skips the typed confirmation, --work is where dumps and
#                   images go (default ~/tc002-onboard)
#
# tc002-up.sh is this script's --in-place mode under its old name. a first-time clock, still on
# the stock app, goes through tc002-onboard.sh instead, which adopts and fingerprints it first.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$RUNTIME/.." && pwd)
RUN=$HERE/tc002-run.sh
CTL=$HERE/tc002ctl.py
PY=/usr/bin/python3   # apple's python reaches the lan without the local-network prompt
[[ -x $PY ]] || PY=python3

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }
die()   { echo "tc002-update.sh: $*" >&2; exit 1; }
usage_error() { usage >&2; echo >&2; echo "tc002-update.sh: $*" >&2; exit 2; }
say()   { echo "== $*"; }
warn()  { echo "   warning: $*" >&2; }

mode=""
device=${TC002_DEVICE:-10.0.0.111:5555}
build=1
# in-place
tz=${TC002_TZ:-Europe/Amsterdam}
ntp=${TC002_NTP:-10.0.0.136}
font=${TC002_FONT:-block}
base=clock
settings=1
# flash
base_image=""
flash_args=()
work=${TC002_WORK:-$HOME/tc002-onboard}

while (( $# > 0 )); do
    case "$1" in
        --in-place)       [[ -z $mode ]] || usage_error "one mode: --in-place or --flash, not both"; mode=in-place; shift ;;
        --flash)          [[ -z $mode ]] || usage_error "one mode: --in-place or --flash, not both"; mode=flash; shift ;;
        --device)         device=$2; shift 2 ;;
        --no-build)       build=0; shift ;;
        --tz)             tz=$2; shift 2 ;;
        --ntp)            ntp=$2; shift 2 ;;
        --font)           font=$2; shift 2 ;;
        --base)           base=$2; shift 2 ;;
        --keep-settings)  settings=0; shift ;;
        --reset-settings) settings=2; shift ;;
        --base-image)     base_image=$2; shift 2 ;;
        --no-backup)      flash_args+=(--no-backup); shift ;;
        --lan)            flash_args+=(--lan); shift ;;
        --yes|-y)         flash_args+=(--yes); shift ;;
        --work)           work=$2; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage_error "unknown option $1" ;;
    esac
done
[[ -n $mode ]] || usage_error "say which kind of update: --in-place (no reboot, gone on power cycle) or --flash (reboots, permanent)"

export TC002_AGENT=${TC002_AGENT:-$(id -un)}
# adb connect supplies this default itself; -s and the child scripts need it explicitly
[[ $device == *:* ]] || device="$device:5555"
ip=${device%%:*}
export TC002_DEVICE="$device"

# every adb call names the device: with two clocks attached a bare call fails, and connect and
# disconnect take the address as an argument instead of -s
adb() {
    case "${1:-}" in
        connect|disconnect|start-server|kill-server|devices) command adb "$@" ;;
        *) command adb -s "$device" "$@" ;;
    esac
}
dsh() { adb shell "$@" | tr -d '\r'; }

# the token file for this clock: the one the last update wrote for it, else the shared one
token_file() {
    for f in "$ROOT/tokens-$ip" "$ROOT/tokens"; do
        [[ -s $f ]] && { echo "$f"; return 0; }
    done
    return 1
}

# what runtime/zig-out was built for. the flashed supervisor spawns its children by absolute path
# under /res/bin, which is compiled in; an in-place one has /tmp/tc002 instead. pushing one
# where the other belongs is a crash loop that looks like a broken binary.
payload_kind() {
    local sup=$RUNTIME/zig-out/bin/tc002-supervisor
    [[ -f $sup ]] || { echo none; return; }
    if LC_ALL=C grep -qa '/res/bin' "$sup"; then echo flash; else echo in-place; fi
}

# "updating" on the panel, so nobody watches the clock go dark unexplained. the in-place update
# gives the notification a moment to fade in, then halts the old runtime without the black frame
# a stop paints, so the led controller keeps the notice on the glass until the new renderer's
# first frame replaces it; the flasher draws its own pulsing "Updating..." for the longer blank
# it causes. a clock with no token yet (a first run) is told about in the log.
notice() {
    local tf
    if ! tf=$(token_file); then
        warn "no token file for $ip yet, so no \"updating\" notice on the panel this time"
        return 0
    fi
    "$PY" "$CTL" -s "$ip" --token-file "$tf" notify "updating" --duration 20 >/dev/null 2>&1 \
        && say "panel reads \"updating\"" \
        || warn "could not put the notice on the panel (is the runtime up?)"
}

connect() {
    say "adb"
    if ! adb get-state >/dev/null 2>&1; then
        adb connect "$device" >/dev/null 2>&1 || true
        local n=0
        while ! adb get-state >/dev/null 2>&1; do
            (( n++ )); (( n >= 40 )) && die "no adb device at $device (is the clock on the network?)"
            sleep 0.25
        done
    fi
    echo "connected: $(adb get-serialno 2>/dev/null)"
}

# --------------------------------------------------------------------------------- in-place
in_place() {
    say "in-place update of $device: no reboot, and gone on the next power cycle"
    if (( build )); then
        say "build (for /tmp/tc002)"
        ( cd "$RUNTIME" && zig build && zig build check ) || die "build failed"
    fi
    case "$(payload_kind)" in
        in-place) ;;
        flash) die "runtime/zig-out is a flash payload (it has /res/bin compiled in); build again without --no-build, or use --flash" ;;
        none)  die "no binaries in $RUNTIME/zig-out; build first, or drop --no-build" ;;
    esac
    connect
    if dsh "ps" | grep -q 'tc002-supervisor'; then
        notice
        sleep 1.5   # the notice fades in; from here the glass keeps it through the gap
        say "halting the running runtime (the notice stays on the panel until the new one draws)"
        "$RUN" halt >/dev/null 2>&1 || true
    else
        warn "no runtime is running on $ip, so nothing to show the notice on"
    fi
    say "push"
    local out
    out=$(TC002_NO_BUILD=1 "$RUN" push 2>&1) || { echo "$out"; die "push failed"; }
    dsh "ls -la /tmp/tc002" | grep -E 'tc002d|tc002-supervisor|tc002-netd' | awk '{print "   " $5 " " $9}' || true
    say "start (tz $tz)"
    "$RUN" start --profile dev --tz "$tz" 2>&1 | grep -E 'supervisor running|ready|exited|error' | sed 's/^/   /' || true
    sleep 2
    # two token files: `tokens` is the last clock updated, what a one-clock setup has always used;
    # `tokens-<host>` is this clock's own, so two clocks do not overwrite each other's and the
    # console picks the right one per host
    say "tokens -> $ROOT/tokens and $ROOT/tokens-$ip (mode 0600)"
    local f
    for f in "$ROOT/tokens" "$ROOT/tokens-$ip"; do
        adb pull /data/tc002/state/credentials/tokens "$f" >/dev/null 2>&1 ||
            adb pull /tmp/tc002/credentials/tokens "$f" >/dev/null 2>&1 ||
            die "could not pull the tokens (did the supervisor start?)"
        chmod 600 "$f"
    done
    if (( settings == 1 )) && [[ -n $(dsh "ls /data/tc002/state/config/config.json 2>/dev/null" | tr -d '\n') ]]; then
        settings=0
        say "settings: the clock has durable settings; leaving them alone (--reset-settings to overwrite)"
    fi
    if (( settings != 0 )); then
        say "settings"
        local ntp_arg=""
        [[ $ntp != none ]] && ntp_arg="ntp_server=$ntp"
        "$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens-$ip" config-set timezone="$tz" base="$base" clock_font="$font" $ntp_arg >/dev/null || die "settings were rejected (check --tz, --font, --ntp)"
        "$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens-$ip" config-save >/dev/null || die "settings could not be saved"
        echo "   timezone=$tz base=$base clock_font=$font ntp=$ntp (saved)"
    fi
    sleep 3
    say "status"
    "$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens-$ip" status | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("   build", d.get("build"), "| renderer", d.get("renderer"), "| base", d.get("base"), "| clock font", (d.get("clock") or {}).get("font"), "| time", (d.get("time") or {}).get("state"), "| ip", (d.get("network") or {}).get("ip"))
'
    echo
    echo "this build runs from /tmp until the next power cycle; --flash keeps one."
    echo "console:  $ROOT/panel-v2/start-panel.sh $ip --open"
}

# ------------------------------------------------------------------------------------ flash
flash() {
    say "flash update of $device: the clock reboots, and the result is permanent"
    command -v unsquashfs >/dev/null || die "need squashfs-tools (unsquashfs) to check the dump and build the image"
    if (( build )); then
        # -Dbin_dir and -Dnetup are compiled in: the flashed supervisor spawns its children by
        # absolute path and never sees an argument, and -Dnetup turns on the bring-up a flashed
        # install must do itself. a plain build flashes and then does nothing.
        say "build (for /res/bin)"
        ( cd "$RUNTIME" && zig build -Dbin_dir=/res/bin -Dnetup=true && zig build -Dbin_dir=/res/bin -Dnetup=true check ) || die "build failed"
    fi
    case "$(payload_kind)" in
        flash) ;;
        in-place) die "runtime/zig-out is an in-place payload (built for /tmp/tc002); build again without --no-build, or use --in-place" ;;
        none)  die "no binaries in $RUNTIME/zig-out; build first, or drop --no-build" ;;
    esac
    if [[ ! -f $RUNTIME/zig-out/bin/busybox || ! -s $RUNTIME/zig-out/bin/busybox.applets ]]; then
        say "build the static busybox the image needs"
        "$HERE/tc002-mkbusybox.sh" "$work/busybox-build" "$RUNTIME/zig-out/bin/busybox" || die "busybox build failed"
    fi
    mkdir -p "$work"
    connect
    local sn
    sn=$(dsh 'cat /sys/class/net/wlan0/address 2>/dev/null' | tr -d ': ')
    [[ -n $sn ]] || sn=unknown
    if [[ -z $base_image ]]; then
        # the image is assembled from this clock's own res, because lib/libzkgui.so differs
        # between units. a res that no longer carries it (an older image dropped it) cannot be
        # the base, and a stock dump has to be named instead.
        say "dump the res partition (8 mib, in 2 mib chunks: tmpfs is small)"
        adb push "$RUNTIME/zig-out/bin/busybox" /tmp/busybox >/dev/null 2>&1 || die "could not push busybox"
        dsh 'chmod 755 /tmp/busybox' >/dev/null
        base_image="$work/mtd3-res-$sn-$(date +%Y%m%d-%H%M%S).bin"
        : > "$base_image"
        local off
        for off in 0 2048 4096 6144; do
            dsh "/tmp/busybox dd if=/dev/mtdblock3 of=/tmp/chunk bs=1024 skip=$off count=2048 2>/dev/null" >/dev/null
            adb pull /tmp/chunk "$work/.chunk" >/dev/null 2>&1 || die "could not pull the chunk at $off kb"
            cat "$work/.chunk" >> "$base_image"
        done
        rm -f "$work/.chunk"; dsh '/tmp/busybox rm -f /tmp/chunk' >/dev/null
        echo "   $base_image ($(wc -c < "$base_image" | tr -d ' ') bytes)"
        unsquashfs -l "$base_image" 2>/dev/null | grep -q 'lib/libzkgui.so' \
            || die "this clock's res no longer carries lib/libzkgui.so, so it cannot be the base of a new image.
   pass --base-image <its stock res dump> (look in ~/tc002-firmware); the dump just taken is kept at
   $base_image"
        echo "   it unpacks and carries lib/libzkgui.so"
    else
        [[ -f $base_image ]] || die "no such base image: $base_image"
    fi
    local img="$work/RUNTIME-$sn-$(date +%Y%m%d-%H%M%S).img"
    say "build the image from $base_image"
    "$HERE/tc002-mkimage.sh" "$base_image" "$img" "$work/mkimage" > "$work/mkimage.log" 2>&1 \
        || { tail -20 "$work/mkimage.log"; die "image build failed; the log is $work/mkimage.log"; }
    echo "   $img ($(wc -c < "$img" | tr -d ' ') bytes)"
    # the flasher puts "Updating..." on the panel itself, and this script never passes --no-notice
    local tf
    tf=$(token_file) || warn "no token file for $ip; the flasher cannot put its notice on the panel"
    say "flash"
    TC002_DEVICE="$device" TC002_TOKENS="${tf:-$ROOT/tokens}" "$HERE/tc002-flash.sh" "$img" ${flash_args[@]+"${flash_args[@]}"} \
        || die "the flash reported a failure; the dump is at $base_image"
    say "verify"
    local n=0
    until adb connect "$device" >/dev/null 2>&1 && dsh 'ls /res/bin/tc002-supervisor 2>/dev/null' | grep -q tc002-supervisor; do
        (( n++ )); (( n >= 30 )) && die "the clock came back without /res/bin/tc002-supervisor; the image did not take"
        sleep 5
    done
    echo "   /res/bin/tc002-supervisor is in flash"
    if [[ -n ${tf:-} ]]; then
        sleep 8
        "$PY" "$CTL" -s "$ip" --token-file "$tf" status 2>/dev/null | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("   build", d.get("build"), "| base", d.get("base"), "| time", (d.get("time") or {}).get("state"), "| ip", (d.get("network") or {}).get("ip"))
' || warn "the api did not answer yet; give it a moment"
    fi
    echo
    echo "this build is in flash and survives power cycles. the dump it was built from: $base_image"
}

case "$mode" in
    in-place) in_place ;;
    flash)    flash ;;
esac
