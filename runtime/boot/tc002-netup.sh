#!/bin/sh
# tc002-netup.sh DIR [RUNDIR] : bring wlan0 up the way the stock app's NetManager does, for a
# runtime that booted without the stock app. idempotent: each step is skipped if already satisfied,
# so it is safe whether or not the vendor loader already loaded the driver and started the
# supplicant before the bootstrap took over. run by the supervisor at boot and again on a network
# loss; udhcpc is left as a daemon so leases renew. DIR holds busybox, this script and the udhcpc
# callback (the binaries' directory, read-only on a flashed image). RUNDIR is a writable directory
# for the udhcpc pidfile (defaults to /tmp/tc002).
DIR="${1:-/res/bin}"
RUNDIR="${2:-/tmp/tc002}"
BB="$DIR/busybox"
export BB
IF=wlan0
PIDF="$RUNDIR/udhcpc.pid"
MOD=/lib/modules/4.9.84
log() { echo "netup: $*"; }

# 1. the aic8800 wifi driver, if nothing loaded it yet (it lives on the untouched rootfs)
if [ ! -d /sys/class/net/$IF ]; then
  log "loading aic8800 driver"
  "$BB" insmod "$MOD/aic8800_bsp.ko" 2>&1
  "$BB" insmod "$MOD/aic8800_fdrv.ko" 2>&1
  n=0; while [ ! -d /sys/class/net/$IF ] && [ $n -lt 20 ]; do "$BB" sleep 1; n=$((n+1)); done
fi
[ -d /sys/class/net/$IF ] || { log "wlan0 never appeared"; exit 1; }
"$BB" ifconfig $IF up 2>/dev/null

# 2. wpa_supplicant (an init service) reads the persistent /data/misc/wifi/wpa_supplicant.conf.
#    only start it if it is NOT already running: a running supplicant reassociates on its own, and
#    killing it mid-associate (which is the normal state for the first seconds of a cold boot, and
#    on every retry while a slow AP is still associating) only delays the link. restart it only
#    when it has actually died.
if [ "$(/bin/getprop init.svc.wpa_supplicant)" != running ]; then
  log "wpa_supplicant not running; starting it"
  /bin/setprop ctl.start wpa_supplicant
fi

# 3. wait for association (the driver reports carrier)
n=0; while [ "$("$BB" cat /sys/class/net/$IF/carrier 2>/dev/null)" != 1 ] && [ $n -lt 30 ]; do "$BB" sleep 1; n=$((n+1)); done
log "carrier=$("$BB" cat /sys/class/net/$IF/carrier 2>/dev/null) after ${n}s"

# 4. dhcp: kill any udhcpc a previous run left behind, tracked by pidfile. busybox runs udhcpc as
#    a multi-call applet whose process name stays "busybox", so killall/pkill by name do NOT match
#    it; the pidfile is the reliable handle. without this, daemons accumulate across every restart
#    and their competing DHCP (with release-on-exit) can wedge the link. then start a fresh one
#    with -b (forks to background after the first attempt) and -p (writes its daemon pid).
if [ -f "$PIDF" ]; then
  old=$("$BB" cat "$PIDF" 2>/dev/null)
  [ -n "$old" ] && "$BB" kill "$old" 2>/dev/null && "$BB" sleep 1
fi
# no -R: a udhcpc that dies (or is killed) must NOT deconfigure wlan0. without -R it exits without
# releasing the lease or running the deconfig hook, so the interface keeps its address until the
# lease expires, which gives the supervisor's retry time to bring a fresh client up. releasing on
# exit would set wlan0 to 0.0.0.0 and drop the link.
"$BB" udhcpc -i $IF -s "$DIR/tc002-udhcpc.script" -b -t 10 -T 3 -p "$PIDF"
log "udhcpc started (pidfile $PIDF)"
