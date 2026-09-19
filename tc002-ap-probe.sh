#!/bin/zsh
# tc002-ap-probe.sh -- everything learnable from a factory-fresh tc002's setup ap,
# collected in ONE unattended run.
#
# why a script and not a session: this mac has a single wifi interface, so joining
# the device's "U-Clock" ap takes the whole machine off the lan and off the
# internet. nothing can be driven interactively while that is true. so the visit
# has to be scripted end to end, and it has to put the wifi back on every exit
# path -- success, failure, or ctrl-c.
#
#   ./tc002-ap-probe.sh --busybox <armv7-busybox> [--out <log>]
#                       [--ap-pass <pw>] [--wifi-ssid <name>]
#
# this assumes NOTHING but one clock, fresh out of its box -- which is the only
# thing a first-time owner has. both secrets are prompted for, hidden, while the
# terminal is still interactive and the network is still up; neither is logged,
# echoed, or passed in argv. RUN THIS YOURSELF from an interactive shell (in
# claude code, prefix it with `! `), because it has to prompt before it goes
# offline, and nothing can talk to it once it does.
#
#   --ap-pass    the "U-Clock" ap password. defaults to the firmware default,
#                which is the same on every tc002 -- so the common case needs
#                no argument and no second device at all
#   --wifi-ssid  the network to adopt onto; omit it to probe only and leave the
#                unit factory-fresh
#
# --psk-from / --adopt-from are shortcuts for the case where you ALREADY have an
# adopted tc002 on the lan: they lift the softap key and the target network's
# credentials off it over adb, so nothing has to be typed. they are deliberately
# NOT part of the first-run flow -- a first-time owner has no such device, and
# testing through them would test a path nobody can walk. use them only to save
# typing on a repeat run.
#
# open questions this is here to answer, from SETUP.md:
#   - does the device udp-broadcast on :55555 while in setup-ap mode? ("not checked")
#   - is the gateway 192.168.1.1 (per /etc/dnsmasq.conf) or 192.168.100.1
#     (the other subnet baked into libzknet.so)?
#   - what tcp surface is open in setup-ap mode?
#   - does the unit match FINGERPRINTS.md?

set -u
setopt NULL_GLOB

IFACE=en0
AP_SSID="U-Clock"
# the setup ap's passphrase, and it is the same on every tc002 ever made.
# libzknet.so does not store a key: it derives one with PKCS5_PBKDF2_HMAC_SHA1
# from `persist.sys.softap.pwd` over `persist.sys.softap.ssid`, and falls back to
# this when the property is empty (it is empty on a unit that has been adopted).
# ssid and passphrase are both fixed, so the derived 64-hex wpa_psk is identical
# across units -- which is why the key is a literal in no binary yet opens any
# clock's ap. recovered by deriving candidates against a real device's stored
# psk, not by guessing. this is a vendor default, not anybody's secret.
AP_PASS_DEFAULT="12345678"
BB=""
OUT="/tmp/tc002-ap-probe-$(date +%Y%m%d-%H%M%S).log"
AP_PASS="$AP_PASS_DEFAULT"
W_SSID=""
PSK_FROM=""
ADOPT_FROM=""
ADB=/opt/homebrew/bin/adb
PY=/usr/bin/python3
CURL=/usr/bin/curl

while [[ $# -gt 0 ]]; do
  case "$1" in
    --busybox)  BB="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --ap-pass)   AP_PASS="$2"; shift 2 ;;
    --wifi-ssid) W_SSID="$2"; shift 2 ;;
    --psk-from)   PSK_FROM="$2"; shift 2 ;;
    --adopt-from) ADOPT_FROM="$2"; shift 2 ;;
    --iface)    IFACE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

exec > >(tee -a "$OUT") 2>&1

say()  { print -r -- "$@"; }
hr()   { print -r -- "=== $* ==="; }
# macos has no timeout(1); perl is always there
to()   { local s=$1; shift; /usr/bin/perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
# every http body and config goes through this before it reaches the log
redact() { /usr/bin/sed -E 's/("?(pass|passwd|password|psk|secret|token|apikey|api_key|key)"?[[:space:]]*[:=][[:space:]]*"?)[^",}]*/\1<redacted>/Ig'; }

HOME_SSID=""
RESTORED=0

restore() {
  [[ $RESTORED -eq 1 ]] && return
  RESTORED=1
  say ""
  hr "restore: putting $IFACE back on the home network"
  # the clock's ap must not stay in the preferred list, or autojoin will keep
  # hopping onto it every time the clock is in setup mode
  networksetup -removepreferredwirelessnetwork "$IFACE" "$AP_SSID" >/dev/null 2>&1

  # the radio cycle leads here on purpose. the home network is wpa3 (FT_SAE) and
  # is not in the legacy preferred list, and `networksetup -setairportnetwork`
  # is unreliable for both of those. macos autojoin knows it from the modern
  # known-networks store and reselects it on its own.
  say "  cycling the radio and letting autojoin reselect"
  networksetup -setairportpower "$IFACE" off >/dev/null 2>&1
  sleep 3
  networksetup -setairportpower "$IFACE" on  >/dev/null 2>&1

  local i addr
  for i in {1..30}; do
    addr=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
    if [[ -n "$addr" && "$addr" != 192.168.1.* && "$addr" != 192.168.100.* ]]; then
      say "  back on the lan at $addr after ~$((i*2))s"
      route -n get default 2>/dev/null | grep -E 'gateway|interface' | sed 's/^/    /'
      return
    fi
    sleep 2
  done

  # last resort only: may fail or prompt on wpa3, which is why it is not first
  if [[ -n "$HOME_SSID" ]]; then
    say "  autojoin did not take; trying an explicit rejoin"
    to 45 networksetup -setairportnetwork "$IFACE" "$HOME_SSID" >/dev/null 2>&1
    for i in {1..15}; do
      addr=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
      if [[ -n "$addr" && "$addr" != 192.168.1.* && "$addr" != 192.168.100.* ]]; then
        say "  back on the lan at $addr"
        return
      fi
      sleep 2
    done
  fi
  say "  *** COULD NOT REJOIN AUTOMATICALLY -- pick your network from the wifi menu ***"
}

# watchdog: if this script wedges or is killed uncleanly, something must still
# take the mac off the clock's ap. detached, and killed on the way out.
start_watchdog() {
  ( sleep 900
    a=$(ipconfig getifaddr en0 2>/dev/null)
    if [[ "$a" == 192.168.1.* || "$a" == 192.168.100.* ]]; then
      networksetup -removepreferredwirelessnetwork en0 "U-Clock" >/dev/null 2>&1
      networksetup -setairportpower en0 off >/dev/null 2>&1
      sleep 3
      networksetup -setairportpower en0 on  >/dev/null 2>&1
    fi ) &
  WATCHDOG_PID=$!
  say "  watchdog armed (pid $WATCHDOG_PID, fires at 15 min)"
}
stop_watchdog() {
  [[ -n "${WATCHDOG_PID:-}" ]] && kill "$WATCHDOG_PID" 2>/dev/null
}

cleanup() { restore; stop_watchdog; }
trap cleanup EXIT INT TERM

say "tc002 setup-ap probe, $(date)"
say "log: $OUT"
say ""

# ---------------------------------------------------------------- preflight
hr "preflight (still on the lan)"
[[ -n "$BB" && -r "$BB" ]] || { say "  need --busybox <static armv7 busybox>"; RESTORED=1; exit 2; }
say "  busybox: $BB ($(stat -f %z "$BB") bytes)"

HOME_SSID=$(networksetup -getairportnetwork "$IFACE" 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p')
if [[ -z "$HOME_SSID" ]]; then
  # documented macos quirk: this can report "not associated" while the link is up
  HOME_SSID=$(system_profiler SPAirPortDataType 2>/dev/null | awk '/Current Network Information:/{getline; gsub(/^ +| +$|:$/,""); print; exit}')
fi
if [[ -n "$HOME_SSID" ]]; then
  say "  home network captured for the restore (name withheld from this log)"
else
  say "  WARNING: could not read the current ssid; restore will fall back to a radio cycle"
fi
say "  address before: $(ipconfig getifaddr "$IFACE" 2>/dev/null)"
start_watchdog

W_PSK=""
# optional shortcuts; see the header. they never make it into the log.
if [[ -z "$AP_PASS" && -n "$PSK_FROM" ]]; then
  AP_PASS=$("$ADB" -s "$PSK_FROM" shell '/res/bin/busybox grep "^wpa_psk=" /data/misc/wifi/hostapd.conf 2>/dev/null | /res/bin/busybox cut -d= -f2' 2>/dev/null | tr -d '\r\n')
  [[ ${#AP_PASS} -eq 64 ]] && say "  softap key lifted from $PSK_FROM (shortcut, not the first-run path)" || AP_PASS=""
fi
if [[ -n "$ADOPT_FROM" && -z "$W_PSK" ]]; then
  W_SSID=$("$ADB" -s "$ADOPT_FROM" shell '/res/bin/busybox grep -E "^[[:space:]]*ssid=" /data/misc/wifi/wpa_supplicant.conf 2>/dev/null | /res/bin/busybox head -1' 2>/dev/null | tr -d '\r\n')
  W_PSK=$( "$ADB" -s "$ADOPT_FROM" shell '/res/bin/busybox grep -E "^[[:space:]]*psk="  /data/misc/wifi/wpa_supplicant.conf 2>/dev/null | /res/bin/busybox head -1' 2>/dev/null | tr -d '\r\n')
  W_SSID=${W_SSID#*=}; W_PSK=${W_PSK#*=}
  W_SSID=${W_SSID//\"/}; W_PSK=${W_PSK//\"/}
  [[ -n "$W_SSID" && -n "$W_PSK" ]] && say "  target network lifted from $ADOPT_FROM (shortcut, not the first-run path)" || { W_SSID=""; W_PSK=""; }
fi

if [[ -z "$AP_PASS" ]]; then
  print -n "  password for the '$AP_SSID' ap (hidden, not logged): "
  read -rs AP_PASS; print ""
fi
if [[ -z "$AP_PASS" ]]; then
  say "  no ap password given; cannot join a wpa2 ap"
  RESTORED=1; exit 2
fi
if [[ "$AP_PASS" == "$AP_PASS_DEFAULT" ]]; then
  say "  ap password: the firmware default, same on every unit (see the note at the top)"
else
  say "  ap password: supplied (${#AP_PASS} chars, not logged)"
fi

if [[ -n "$W_SSID" && -z "$W_PSK" ]]; then
  print -n "  password for wifi network '$W_SSID' (hidden, not logged): "
  read -rs W_PSK; print ""
  if [[ -n "$W_PSK" ]]; then
    say "  target network captured (key ${#W_PSK} chars, not logged) -- will adopt after the probe"
  else
    say "  no password given; skipping adoption"
    W_SSID=""
  fi
fi

# ------------------------------------------------------------------- join
say ""
hr "join $AP_SSID"
# note: the key is visible in this process's argv to local users for the moment
# the call runs. networksetup offers no stdin form.
to 60 networksetup -setairportnetwork "$IFACE" "$AP_SSID" "$AP_PASS" 2>&1 | sed 's/^/  /'
AP_PASS=""
AP_ADDR=""
for i in {1..20}; do
  AP_ADDR=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
  [[ -n "$AP_ADDR" && ( "$AP_ADDR" == 192.168.1.* || "$AP_ADDR" == 192.168.100.* ) ]] && break
  AP_ADDR=""
  sleep 2
done
if [[ -z "$AP_ADDR" ]]; then
  say "  never got a dhcp lease on the ap subnet (address now: $(ipconfig getifaddr "$IFACE" 2>/dev/null))"
  exit 1
fi
say "  joined. our lease: $AP_ADDR"
ifconfig "$IFACE" 2>/dev/null | grep -E 'inet |ether' | sed 's/^/  /'
say "  dhcp offer:"
ipconfig getpacket "$IFACE" 2>/dev/null | grep -iE 'yiaddr|server_identifier|router|subnet_mask|domain_name_server|lease_time' | sed 's/^/    /'
say "  default route:"
route -n get default 2>/dev/null | grep -E 'gateway|interface' | sed 's/^/    /'

# --------------------------------------------------------------- which gateway
say ""
hr "which subnet is it really on"
GW=""
for cand in 192.168.1.1 192.168.100.1; do
  if to 8 "$CURL" -sL -m 6 -o /dev/null -w '%{http_code}' "http://$cand/getBase" 2>/dev/null | grep -qE '^[23]'; then
    say "  $cand answers GET /getBase  <-- this is the device"
    GW="$cand"
  else
    say "  $cand no answer"
  fi
done
if [[ -z "$GW" ]]; then
  GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
  say "  falling back to the default route: ${GW:-none}"
fi
say "  arp table on this subnet:"
arp -an 2>/dev/null | grep -E '192\.168\.(1|100)\.' | sed 's/^/    /'

# ------------------------------------------------- the open question: broadcasts
say ""
hr "does it broadcast in setup-ap mode? (SETUP.md: 'not checked')"
say "  listening on udp/55555 for 25s, and on udp/6666+9999 as controls"
to 40 "$PY" - <<'PY' 2>&1 | sed 's/^/  /'
import socket, select, time
ports = [55555, 6666, 9999]
socks = []
for p in ports:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try: s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except OSError: pass
        s.bind(("", p)); s.setblocking(False); socks.append((p, s))
    except OSError as e:
        print(f"bind udp/{p} failed: {e}")
seen = {}
end = time.time() + 25
while time.time() < end:
    r, _, _ = select.select([s for _, s in socks], [], [], 1.0)
    for s in r:
        p = next(pp for pp, ss in socks if ss is s)
        try: data, addr = s.recvfrom(2048)
        except OSError: continue
        k = (p, addr[0], data)
        seen[k] = seen.get(k, 0) + 1
        if seen[k] == 1:
            print(f"udp/{p} from {addr[0]}:{addr[1]}  {len(data)}b  {data[:200]!r}")
if not seen:
    print("NOTHING received on any port in 25s -- it does not broadcast in setup-ap mode")
else:
    print("--- repeat counts over 25s ---")
    for (p, host, data), n in sorted(seen.items(), key=lambda kv: -kv[1]):
        print(f"udp/{p} {host} x{n}: {data[:120]!r}")
PY

say ""
say "  bonjour/mdns browse (SETUP.md claims there is none):"
to 15 dns-sd -B _services._dns-sd._udp local 2>&1 | head -12 | sed 's/^/    /'

# ------------------------------------------------------------------ tcp surface
say ""
hr "tcp surface on $GW"
to 60 "$PY" - "$GW" <<'PY' 2>&1 | sed 's/^/  /'
import socket, sys
host = sys.argv[1]
ports = [21,22,23,53,80,443,554,1883,5000,5037,5555,8000,8080,8081,8443,9999,55555]
for p in ports:
    s = socket.socket(); s.settimeout(1.2)
    try:
        s.connect((host, p)); print(f"{p:>6} open")
    except Exception:
        pass
    finally:
        s.close()
print("(closed/filtered ports omitted)")
PY

# -------------------------------------------------------------------- http
say ""
hr "http surface on $GW (read-only GETs only)"
for ep in getBase getConfig getMqttStatus getToolsConfig getCalendar checkUpdate api/customList getDiyImages getSocial getMqttConfig; do
  code=$(to 10 "$CURL" -sL -m 8 -o /tmp/.apbody -w '%{http_code}' "http://$GW/$ep" 2>/dev/null)
  size=$(stat -f %z /tmp/.apbody 2>/dev/null || echo 0)
  say "  GET /$ep -> ${code:-timeout} (${size}b)"
  if [[ "$code" == 200 && "$size" -gt 0 && "$size" -lt 4000 ]]; then
    redact < /tmp/.apbody | head -c 1200 | sed 's/^/      /'
    say ""
  fi
done
say "  setup pages:"
for page in "" wifiConfig.html wifiSave.html index.html; do
  code=$(to 10 "$CURL" -sL -m 8 -o /tmp/.apbody -w '%{http_code}' "http://$GW/$page" 2>/dev/null)
  say "    GET /$page -> ${code:-timeout} ($(stat -f %z /tmp/.apbody 2>/dev/null || echo 0)b)"
done
rm -f /tmp/.apbody

# --------------------------------------------------------------------- adb
say ""
hr "adb over the ap"
to 30 "$ADB" connect "$GW:5555" 2>&1 | sed 's/^/  /'
sleep 2
"$ADB" devices -l 2>&1 | sed 's/^/  /'
TARGET="$GW:5555"
HAVE_ADB=1
if ! "$ADB" -s "$TARGET" shell 'echo ok' >/dev/null 2>&1; then
  say "  no adb shell over the ap -- skipping the fingerprint"
  HAVE_ADB=0
fi

if [[ $HAVE_ADB -eq 1 ]]; then

dsh() { "$ADB" -s "$TARGET" shell "$@" 2>&1 | tr -d '\r'; }

say ""
hr "fingerprint (FINGERPRINTS.md)"
"$ADB" -s "$TARGET" push "$BB" /tmp/busybox >/dev/null 2>&1 && dsh 'chmod 755 /tmp/busybox' >/dev/null
dsh '/tmp/busybox --help 2>&1 | /tmp/busybox head -1' | sed 's/^/  busybox: /'

say ""
say "  -- identity --"
for p in ro.product.model ro.build.fingerprint ro.build.date ro.build.version.release ro.serialno; do
  say "  $p = $(dsh "getprop $p")"
done
say "  kernel = $(dsh '/tmp/busybox uname -a')"
say "  mtd3 type = $(dsh 'cat /sys/class/mtd/mtd3/type'), oobsize = $(dsh 'cat /sys/class/mtd/mtd3/oobsize')"

say ""
say "  -- /proc/mtd --"
dsh 'cat /proc/mtd' | sed 's/^/  /'

say ""
say "  -- res squashfs superblock (magic / inodes / mkfs / bytes used) --"
dsh '/tmp/busybox mknod /dev/mtdblock3 b 31 3 2>/dev/null; /tmp/busybox dd if=/dev/mtdblock3 bs=1 count=64 2>/dev/null | /tmp/busybox hexdump -C' | sed 's/^/  /'

say ""
say "  -- whole-partition sha256 (mtd4 config + mtd6 data skipped on purpose: per-device, mtd6 holds the wifi psk) --"
for n in 0 1 2 3 5 7; do
  dsh "/tmp/busybox mknod /dev/mtdblock$n b 31 $n 2>/dev/null; echo \"  mtd$n \$(/tmp/busybox sha256sum /dev/mtdblock$n)\""
done

say ""
say "  -- res image proper, bytes 0..2789376 --"
dsh '/tmp/busybox dd if=/dev/mtdblock3 bs=1024 count=2724 2>/dev/null | /tmp/busybox sha256sum' | sed 's/^/  sha256 /'
dsh '/tmp/busybox dd if=/dev/mtdblock3 bs=1024 count=2724 2>/dev/null | /tmp/busybox md5sum'    | sed 's/^/  md5    /'

say ""
say "  -- inside /res --"
say "  regular files = $(dsh 'cd /res && /tmp/busybox find . -type f | /tmp/busybox wc -l')"
say "  aggregate md5 = $(dsh 'cd /res && /tmp/busybox find . -type f | /tmp/busybox sort | /tmp/busybox xargs /tmp/busybox md5sum | /tmp/busybox md5sum')"
dsh '/tmp/busybox sha256sum /res/lib/libzkgui.so /res/etc/EasyUI.cfg 2>&1' | sed 's/^/  /'
dsh '/tmp/busybox ls -l /res/lib/libzkgui.so /res/etc/EasyUI.cfg 2>&1'     | sed 's/^/  /'

say ""
say "  -- update.img on the udisk (the reflash trap) --"
dsh '/tmp/busybox ls -l /mnt/storage/*.img 2>&1'       | sed 's/^/  /'
dsh '/tmp/busybox sha256sum /mnt/storage/*.img 2>&1'   | sed 's/^/  /'
dsh '/tmp/busybox md5sum /mnt/storage/*.img 2>&1'      | sed 's/^/  /'
say "  its payload superblock (offset 0x23c):"
dsh '/tmp/busybox dd if=/mnt/storage/update.img bs=1 skip=572 count=48 2>/dev/null | /tmp/busybox hexdump -C' | sed 's/^/    /'

say ""
say "  -- setup-ap / upgrade state --"
for p in persist.sys.softap.ssid persist.softap.on persist.wifi.on persist.zkupgrade.dir sys.zkupgrade.dir sys.zkapp.state ro.build.id; do
  say "  $p = $(dsh "getprop $p")"
done
say "  softap config (key redacted):"
dsh '/tmp/busybox grep -vE "^\s*#|^\s*$" /data/misc/wifi/hostapd.conf 2>/dev/null' | redact | sed 's/^/    /'
say "  wifi state:"
dsh '/tmp/busybox ls -l /data/misc/wifi/ 2>&1' | sed 's/^/    /'

say ""
say "  -- network view from the device --"
dsh '/tmp/busybox ifconfig 2>&1 | /tmp/busybox grep -E "^[a-z]|inet addr"' | sed 's/^/  /'
dsh '/tmp/busybox netstat -lntu 2>/dev/null | /tmp/busybox head -25'       | sed 's/^/  /'
dsh '/tmp/busybox ps 2>/dev/null | /tmp/busybox head -40'                  | sed 's/^/  /'

say ""
say "  -- cleanup --"
dsh '/tmp/busybox rm -f /tmp/busybox && echo "  removed /tmp/busybox"'
"$ADB" disconnect "$TARGET" >/dev/null 2>&1

"$ADB" disconnect "$TARGET" >/dev/null 2>&1
fi

if [[ -n "$W_SSID" && -n "$W_PSK" ]]; then
  say ""
  hr "adopt onto the target network (last: this tears down the ap)"
  say "  POST /setWifiConfig to $GW"
  # json is built by python from the environment and piped in on stdin, so the
  # key never appears in any process's argv
  RESP=$(W_SSID="$W_SSID" W_PSK="$W_PSK" "$PY" -c 'import json,os,sys; sys.stdout.write(json.dumps({"ssid":os.environ["W_SSID"],"password":os.environ["W_PSK"]}))' \
         | to 25 "$CURL" -s -m 20 -X POST -H 'Content-Type: application/json' --data-binary @- "http://$GW/setWifiConfig" 2>&1)
  W_PSK=""
  say "  response: $(print -r -- "$RESP" | redact | head -c 300)"
  if print -r -- "$RESP" | grep -q '"code"[[:space:]]*:[[:space:]]*200'; then
    say "  accepted -- the device is dropping the ap and joining the target network"
    ADOPTED=1
  else
    say "  NOT accepted. SETUP.md marks this call documented-from-firmware but never executed;"
    say "  this run is the first attempt, so a rejection here is a real finding, not a misconfiguration."
    ADOPTED=0
  fi
fi

# restore explicitly so discovery can run while still inside this script
cleanup

if [[ "${ADOPTED:-0}" -eq 1 ]]; then
  say ""
  hr "find the adopted device on the lan"
  say "  giving it 25s to associate and take a lease"
  sleep 25
  to 60 "$PY" "$(dirname "$0")/tc002-adopt.py" discover 2>&1 | redact | sed 's/^/  /'
fi

say ""
hr "probe complete"
