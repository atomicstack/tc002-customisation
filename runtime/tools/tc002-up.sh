#!/bin/bash
# tc002-up.sh: bring the custom runtime up on the tc002 in one go: connect adb, build and push
# the binaries, start the supervisor, pull the api tokens for the console. the binaries live in
# tmpfs, so after a reboot (the stock app comes back on its own) this is the way back to the
# runtime; the settings and the tokens are durable and come back on their own.
#
#   runtime/tools/tc002-up.sh [--device IP[:PORT]] [--tz ZONE] [--ntp IP|none] [--font NAME]
#                             [--base NAME] [--no-build] [--keep-settings] [--reset-settings]
#
#   --device IP[:PORT]  adb address (default 10.0.0.111:5555; env TC002_DEVICE)
#   --tz ZONE           iana zone name or posix rule (default Europe/Amsterdam; env TC002_TZ)
#   --ntp IP            sntp server, ipv4 (default 10.0.0.136, the home assistant host; env
#                       TC002_NTP); "none" leaves the clock unsynchronised
#   --font NAME         clock font: classic, mini, segment, big, block or hires (default block)
#   --base NAME         scene to show: clock, art or ip (default clock)
#   --no-build          push the binaries already in runtime/zig-out instead of building first
#   --keep-settings     leave the settings alone
#   --reset-settings    apply --tz/--ntp/--font/--base over the device's durable settings. without
#                       it, a device that already has durable settings keeps them, and only a
#                       device with none is provisioned from these options
#
# the device lock is taken under your user name (env TC002_AGENT) so agents sharing the device
# see who holds it; it stays held while the runtime runs. `runtime/tools/tc002-run.sh stop`
# hands the panel back to the stock app and releases it.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$RUNTIME/.." && pwd)
RUN=$HERE/tc002-run.sh
CTL=$HERE/tc002ctl.py
PY=/usr/bin/python3   # apple's python reaches the lan without the local-network prompt
[ -x "$PY" ] || PY=python3

device=${TC002_DEVICE:-10.0.0.111:5555}
tz=${TC002_TZ:-Europe/Amsterdam}
ntp=${TC002_NTP:-10.0.0.136}
font=${TC002_FONT:-block}
base=clock
build=1
settings=1
while [ $# -gt 0 ]; do
    case "$1" in
        --device) device=$2; shift 2 ;;
        --tz) tz=$2; shift 2 ;;
        --ntp) ntp=$2; shift 2 ;;
        --font) font=$2; shift 2 ;;
        --base) base=$2; shift 2 ;;
        --no-build) build=0; shift ;;
        --keep-settings) settings=0; shift ;;
        --reset-settings) settings=2; shift ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "tc002-up.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
export TC002_AGENT=${TC002_AGENT:-$(id -un)}
ip=${device%%:*}

die() { echo "tc002-up.sh: $*" >&2; exit 1; }
say() { echo "== $*"; }

say "adb"
if ! adb get-state >/dev/null 2>&1; then
    adb connect "$device" >/dev/null 2>&1 || true
    n=0
    while ! adb get-state >/dev/null 2>&1; do
        n=$((n + 1)); [ "$n" -ge 40 ] && die "no adb device at $device (is the clock on the network?)"
        sleep 0.25
    done
fi
echo "connected: $(adb get-serialno 2>/dev/null)"

if adb shell "ps" | grep -q 'tc002-supervisor'; then
    say "a runtime is already running; stopping it first"
    "$RUN" stop >/dev/null 2>&1 || true
fi

say "binaries"
if [ "$build" = 1 ]; then
    out=$("$RUN" push 2>&1) || { echo "$out"; die "build or push failed"; }
else
    out=$(TC002_NO_BUILD=1 "$RUN" push 2>&1) || { echo "$out"; die "push failed"; }
fi
adb shell "ls -la /tmp/tc002" | tr -d '\r' | grep -E 'tc002d|tc002-supervisor|tc002-netd' | awk '{print "   " $5 " " $9}'

say "start (tz $tz)"
"$RUN" start --profile dev --tz "$tz" 2>&1 | grep -E 'supervisor running|ready|exited|error' | sed 's/^/   /'
sleep 2

say "tokens -> $ROOT/tokens (mode 0600; the console's start-panel.sh finds them there)"
adb pull /data/tc002/state/credentials/tokens "$ROOT/tokens" >/dev/null 2>&1 ||
    adb pull /tmp/tc002/credentials/tokens "$ROOT/tokens" >/dev/null 2>&1 ||
    die "could not pull the tokens (did the supervisor start?)"
chmod 600 "$ROOT/tokens"

if [ "$settings" = 1 ] && [ -n "$(adb shell "ls /data/tc002/state/config/config.json 2>/dev/null" | tr -d '\r\n')" ]; then
    settings=0
    say "settings: the device has durable settings; leaving them alone (--reset-settings to overwrite)"
fi
if [ "$settings" != 0 ]; then
    say "settings"
    ntp_arg=""
    [ "$ntp" != none ] && ntp_arg="ntp_server=$ntp"
    "$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens" config-set timezone="$tz" base="$base" clock_font="$font" $ntp_arg >/dev/null || die "settings were rejected (check --tz, --font, --ntp)"
    "$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens" config-save >/dev/null || die "settings could not be saved"
    echo "   timezone=$tz base=$base clock_font=$font ntp=$ntp (saved)"
fi

sleep 3
say "status"
"$PY" "$CTL" -s "$ip" --token-file "$ROOT/tokens" status | "$PY" -c '
import json, sys
d = json.load(sys.stdin)
print("   renderer", d.get("renderer"), "| base", d.get("base"), "| clock font", (d.get("clock") or {}).get("font"), "| time", (d.get("time") or {}).get("state"), "| ip", (d.get("network") or {}).get("ip"))
'
echo
echo "console:  $ROOT/panel-v2/start-panel.sh --open"
echo "stop:     $RUN stop"
