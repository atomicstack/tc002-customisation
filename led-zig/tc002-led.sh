#!/bin/bash
# run the zig popsquares binary on a tc002 over adb.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$HERE/zig-out/bin/popsquares
DEV_BIN=/tmp/popsquares
PIDF=/tmp/popsquares.pid
LOGF=/tmp/popsquares.log

die() { echo "$*" >&2; exit 1; }

need_adb() {
    adb get-state >/dev/null 2>&1 || die "no adb device: adb connect <device-ip> first"
}

remote_pid() {
    adb shell "cat $PIDF 2>/dev/null" | tr -d '\r'
}

is_our_pid() {
    local pid=$1
    case "$pid" in
        ""|*[!0-9]*) return 1 ;;
    esac
    local command
    command=$(adb shell "cat /proc/$pid/cmdline 2>/dev/null" | /usr/bin/tr '\000' '\012' | /usr/bin/sed -n '1p')
    [ "$command" = "$DEV_BIN" ]
}

stop_owned_process() {
    local pid
    pid=$(remote_pid)
    if is_our_pid "$pid"; then
        adb shell "kill $pid"
        return 0
    fi
    return 1
}

start_stock_app() {
    adb shell "setprop ctl.start zkswe"
    sleep 3
    echo "stock app: $(adb shell getprop init.svc.zkswe | tr -d '\r')"
}

case "${1:-status}" in
    start)
        shift
        [ -x "$BIN" ] || die "no binary at $BIN — run: zig build --build-file $HERE/build.zig"
        need_adb
        stop_owned_process >/dev/null 2>&1 || true
        adb shell "rm -f $PIDF"
        adb push "$BIN" "$DEV_BIN" >/dev/null || die "adb push failed"
        adb shell "chmod 755 $DEV_BIN; setprop ctl.stop zkswe"
        sleep 1
        remote_args=
        if [ "$#" -gt 0 ]; then
            printf -v remote_args ' %q' "$@"
        fi
        adb shell "trap '' HUP; $DEV_BIN$remote_args </dev/null >$LOGF 2>&1 & echo \$! >$PIDF"
        sleep 1
        pid=$(remote_pid)
        if is_our_pid "$pid"; then
            echo "popsquares running (pid $pid) with: $*"
        else
            echo "popsquares exited immediately:"
            adb shell "cat $LOGF"
            start_stock_app
            exit 1
        fi
        ;;
    stop)
        need_adb
        if stop_owned_process; then
            echo "sent sigterm"
        else
            echo "not running"
        fi
        sleep 1
        adb shell "cat $LOGF 2>/dev/null; rm -f $PIDF"
        start_stock_app
        ;;
    status)
        need_adb
        echo "stock app: $(adb shell getprop init.svc.zkswe | tr -d '\r')"
        pid=$(remote_pid)
        if is_our_pid "$pid"; then
            echo "popsquares: running (pid $pid)"
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
