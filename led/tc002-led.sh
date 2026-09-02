#!/bin/bash
# run the native popsquares binary on a tc002 over adb.
#
#   tc002-led.sh start [popsquares options...]   stop the stock app, push the binary, start it
#   tc002-led.sh stop                            stop the binary (it blanks the panel), restart the stock app
#   tc002-led.sh status                          what is running, plus the binary's log
#
# the stock app (init service `zkswe`, the zkgui process) owns /dev/spidev0.0 and gpio35, so it is
# stopped while the binary runs; the http api is down for that time. everything lives in the
# device's /tmp, which is a tmpfs: after a reboot the device comes up as stock, run `start` again.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/popsquares
DEV_BIN=/tmp/popsquares
PIDF=/tmp/popsquares.pid
LOGF=/tmp/popsquares.log

die() { echo "$*" >&2; exit 1; }

need_adb() {
    adb get-state >/dev/null 2>&1 || die "no adb device: adb connect <device-ip> first"
}

start_stock_app() {
    adb shell "setprop ctl.start zkswe"
    sleep 3
    echo "stock app: $(adb shell getprop init.svc.zkswe | tr -d '\r')"
}

case "${1:-status}" in
  start)
    shift
    [ -x "$BIN" ] || die "no binary at $BIN — run: make -C $HERE"
    need_adb
    adb shell "kill \$(cat $PIDF 2>/dev/null) 2>/dev/null; rm -f $PIDF"
    adb push "$BIN" "$DEV_BIN" >/dev/null || die "adb push failed"
    adb shell "chmod 755 $DEV_BIN; setprop ctl.stop zkswe"
    sleep 1
    # detach from the adb pty: ignore hup, no stdin, log to a file, remember the pid
    adb shell "trap '' HUP; $DEV_BIN $* </dev/null >$LOGF 2>&1 & echo \$! >$PIDF"
    sleep 1
    if adb shell "kill -0 \$(cat $PIDF) 2>/dev/null"; then
        echo "popsquares running (pid $(adb shell cat $PIDF | tr -d '\r')) with: $*"
    else
        echo "popsquares exited immediately:"; adb shell "cat $LOGF"
        start_stock_app
        exit 1
    fi
    ;;
  stop)
    need_adb
    adb shell "kill \$(cat $PIDF 2>/dev/null) 2>/dev/null && echo 'sent sigterm' || echo 'not running'"
    sleep 1
    adb shell "cat $LOGF 2>/dev/null; rm -f $PIDF"
    start_stock_app
    ;;
  status)
    need_adb
    echo "stock app: $(adb shell getprop init.svc.zkswe | tr -d '\r')"
    if adb shell "kill -0 \$(cat $PIDF 2>/dev/null) 2>/dev/null"; then
        echo "popsquares: running (pid $(adb shell cat $PIDF | tr -d '\r'))"
    else
        echo "popsquares: not running"
    fi
    adb shell "cat $LOGF 2>/dev/null"
    ;;
  *)
    echo "usage: tc002-led.sh start [popsquares options...] | stop | status"
    exit 2
    ;;
esac
