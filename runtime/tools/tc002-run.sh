#!/bin/bash
# volatile device runs of the custom runtime, over adb, under the shared advisory lock.
#
#   tc002-run.sh push                 build and push tc002d, tc002-supervisor and the bootstrap to /tmp/tc002/
#                                     (TC002_NO_BUILD=1 pushes what is in zig-out without building)
#   tc002-run.sh start [sup-opts...]  lock, stop the stock app, start the supervisor detached (logs in /tmp/tc002/)
#   tc002-run.sh status               processes, properties, tail of the logs (no lock needed)
#   tc002-run.sh stop                 sigterm the supervisor, restart the stock app, release the lock
#   tc002-run.sh restore              stop, then remove /tmp/tc002 and /tmp/EasyUI.cfg (stock state)
#
# nothing here survives a reboot: everything lives in the device's tmpfs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
LOCK=$HERE/tc002-lock.sh
DEV=/tmp/tc002

die() { echo "$*" >&2; exit 1; }
need_adb() { adb get-state >/dev/null 2>&1 || die "no adb device: adb connect <device-ip> first"; }
dsh() { adb shell "$@" | tr -d '\r'; }

wait_for() { # wait_for <seconds> <shell-test>
    local n=0
    while [ "$n" -lt "$(( $1 * 4 ))" ]; do
        adb shell "$2" >/dev/null 2>&1 && return 0
        sleep 0.25; n=$((n + 1))
    done
    return 1
}

stock_stop() {
    adb shell "setprop ctl.stop zkswe" >/dev/null
    wait_for 10 '[ -z "$(ps | grep -v grep | grep zkgui)" ]' || die "the stock app did not exit"
}

stock_start() {
    adb shell "setprop ctl.start zkswe" >/dev/null
    if wait_for 10 'ps | grep -v grep | grep -q zkgui'; then
        echo "stock app: $(dsh getprop init.svc.zkswe)"
    else
        echo "warning: the stock app did not come back" >&2
    fi
}

case "${1:-status}" in
  push)
    need_adb
    if [ -z "${TC002_NO_BUILD:-}" ]; then
        (cd "$RUNTIME" && zig build && zig build check) || die "build failed"
    fi
    [ -x "$RUNTIME/zig-out/bin/tc002-supervisor" ] || die "no binaries in $RUNTIME/zig-out; build first"
    # replacing the binaries under another agent's live run truncates mapped executables on tmpfs
    # (netd died that way on 2026-09-07), so the push itself runs under the lock
    "$LOCK" acquire "tc002-run.sh push: replacing binaries in $DEV" 120 || exit 1
    adb shell "mkdir -p $DEV" >/dev/null
    for f in bin/tc002d bin/tc002-supervisor bin/tc002-netd bin/tc002-ntfy bin/tc002-berryd lib/libtc002-bootstrap.so; do
        adb push "$RUNTIME/zig-out/$f" "$DEV/$(basename "$f")" >/dev/null || { "$LOCK" release "push of $f failed"; die "push of $f failed"; }
    done
    adb shell "chmod 755 $DEV/tc002d $DEV/tc002-supervisor $DEV/tc002-netd $DEV/tc002-ntfy $DEV/tc002-berryd" >/dev/null
    dsh "ls -la $DEV"
    "$LOCK" release "push done ($(basename "$(cd "$RUNTIME/.." && git branch --show-current 2>/dev/null || echo unknown)"))"
    ;;
  start)
    shift
    need_adb
    "$LOCK" acquire "tc002-run.sh start: custom runtime on the panel" 300 || exit 1
    stock_stop
    adb shell "rm -f $DEV/supervisor.log; trap '' HUP; $DEV/tc002-supervisor $* </dev/null >$DEV/supervisor.log 2>&1 & echo \$! >$DEV/supervisor.pid"
    sleep 2
    if adb shell "kill -0 \$(cat $DEV/supervisor.pid) 2>/dev/null"; then
        echo "supervisor running (pid $(dsh cat $DEV/supervisor.pid)) with: $*"
        dsh "cat $DEV/supervisor.log" | grep -v -E 'inherited (fd|env)|arg [0-9]'
    else
        echo "the supervisor exited immediately:"; dsh "cat $DEV/supervisor.log"
        stock_start
        "$LOCK" release "start failed, stock app restarted"
        exit 1
    fi
    ;;
  status)
    need_adb
    echo "stock app: $(dsh getprop init.svc.zkswe)   sys.zkapp.state: $(dsh getprop sys.zkapp.state)   persist.sys.zkdebug: $(dsh getprop persist.sys.zkdebug)"
    dsh "ps" | grep -E 'tc002|zkgui' || echo "no custom or stock app processes"
    dsh "cat $DEV/supervisor.log 2>/dev/null" | tail -n 12
    "$LOCK" status
    ;;
  stop|restore)
    need_adb
    if adb shell "kill -TERM \$(cat $DEV/supervisor.pid 2>/dev/null) 2>/dev/null"; then
        wait_for 6 "[ -z \"\$(ps | grep -v grep | grep tc002-supervisor)\" ]" || echo "warning: the supervisor did not exit" >&2
        dsh "cat $DEV/supervisor.log 2>/dev/null" | tail -n 4
    else
        echo "no supervisor running"
    fi
    adb shell "kill -TERM \$(ps | grep -v grep | grep tc002d | while read p rest; do echo \$p; done) 2>/dev/null" >/dev/null 2>&1
    if [ "$1" = restore ]; then
        adb shell "umount /res/etc/EasyUI.cfg 2>/dev/null; rm -rf $DEV /tmp/EasyUI.cfg" >/dev/null
        echo "removed $DEV and /tmp/EasyUI.cfg"
    fi
    stock_start
    "$LOCK" release "$1 done, stock app restarted"
    ;;
  *)
    echo "usage: tc002-run.sh push | start [supervisor options...] | status | stop | restore" >&2
    exit 2
    ;;
esac
