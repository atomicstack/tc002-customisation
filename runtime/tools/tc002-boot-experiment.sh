#!/bin/bash
# the volatile boot experiment: make the vendor loader dlopen our bootstrap through /tmp/EasyUI.cfg,
# observe the exec into the supervisor, then restore stock. everything lives in tmpfs.
#
#   tc002-boot-experiment.sh baseline   time the stock app from ctl.start to sys.zkapp.state=running
#   tc002-boot-experiment.sh start      push, write /tmp/EasyUI.cfg, restart zkswe through the bootstrap, show the audit
#   tc002-boot-experiment.sh status     processes, properties, supervisor log tail
#   tc002-boot-experiment.sh restore    stop zkswe, remove /tmp/EasyUI.cfg, start the stock app, verify its library
#
# the lock is held from `start` until `restore`. zkdaemon's one-shot app check ran at boot, so
# re-setting sys.zkapp.state on a warm system is harmless; nothing here is a cold-boot measurement.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LOCK=$HERE/tc002-lock.sh
RUN=$HERE/tc002-run.sh
DEV=/tmp/tc002
BOOTSTRAP=$DEV/libtc002-bootstrap.so

die() { echo "$*" >&2; exit 1; }
dsh() { adb shell "$@" | tr -d '\r'; }
procs() { dsh ps | grep -E 'zkgui|tc002' | awk '{printf "%s:%s ", $1, $5}'; echo; }

wait_gone() { for _ in $(seq 1 40); do adb shell ps | grep -q -E 'zkgui|tc002' || return 0; sleep 0.25; done; return 1; }

# stop zkswe, reset the property, start zkswe, and print uptime before/after the property is raised
timed_restart() {
    adb shell "setprop ctl.stop zkswe" >/dev/null
    wait_gone || die "the service did not stop"
    dsh "setprop sys.zkapp.state experiment; cat /proc/uptime; setprop ctl.start zkswe; n=0; while [ \"\$(getprop sys.zkapp.state)\" != running ]; do n=\$((n+1)); [ \$n -gt 20000 ] && break; done; cat /proc/uptime; getprop sys.zkapp.state" | awk 'NR==1{t0=$1} NR==2{t1=$1} NR==3{print "ctl.start -> sys.zkapp.state=" $0 " in " (t1-t0) " s"}'
}

case "${1:-status}" in
  baseline)
    "$LOCK" acquire "boot experiment baseline (stock warm restart timing)" 300 || exit 1
    timed_restart
    "$LOCK" release "baseline done"
    ;;
  start)
    "$LOCK" acquire "boot experiment: /tmp/EasyUI.cfg -> bootstrap -> supervisor" 300 || exit 1
    "$RUN" push >/dev/null || die "push failed"
    dsh cat /res/etc/EasyUI.cfg | sed "s|\"startupLibPath\":\"/res/lib/libzkgui.so\"|\"startupLibPath\":\"$BOOTSTRAP\"|" > /tmp/tc002-EasyUI.cfg
    grep -q "$BOOTSTRAP" /tmp/tc002-EasyUI.cfg || die "could not rewrite startupLibPath"
    adb push /tmp/tc002-EasyUI.cfg /tmp/EasyUI.cfg >/dev/null
    adb shell "rm -f $DEV/supervisor.log" >/dev/null
    timed_restart
    sleep 3
    echo "processes: $(procs)"
    echo "init.svc.zkswe=$(dsh getprop init.svc.zkswe)"
    dsh "cat $DEV/supervisor.log 2>/dev/null" | head -n 60
    ;;
  status)
    echo "processes: $(procs)"
    echo "init.svc.zkswe=$(dsh getprop init.svc.zkswe) sys.zkapp.state=$(dsh getprop sys.zkapp.state)"
    dsh "cat $DEV/supervisor.log 2>/dev/null" | tail -n 10
    "$LOCK" status
    ;;
  restore)
    adb shell "setprop ctl.stop zkswe" >/dev/null
    wait_gone || echo "warning: the service did not stop" >&2
    adb shell "rm -f /tmp/EasyUI.cfg" >/dev/null
    timed_restart
    sleep 2
    zpid=$(dsh ps | grep zkgui | awk '{print $1}' | head -1)
    [ -n "$zpid" ] && echo "stock zkgui pid $zpid maps $(dsh cat /proc/$zpid/maps | grep libzkgui.so | awk '{print $6}' | sort -u | tr '\n' ' ')"
    "$LOCK" release "boot experiment restored to stock"
    ;;
  *)
    echo "usage: tc002-boot-experiment.sh baseline | start | status | restore" >&2
    exit 2
    ;;
esac
