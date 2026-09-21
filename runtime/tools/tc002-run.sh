#!/bin/bash
# volatile device runs of the custom runtime, over adb, under the shared advisory lock.
#
#   tc002-run.sh push [--staged]      build and push tc002d, tc002-supervisor and the bootstrap to /tmp/tc002/
#                                     (TC002_NO_BUILD=1 pushes what is in zig-out without building).
#                                     --staged pushes to /tmp/tc002.new/ instead, beside a running
#                                     runtime, for `halt` to swap in: the panel keeps pulsing meanwhile
#   tc002-run.sh start [sup-opts...]  lock, stop the stock app, start the supervisor detached (logs in /tmp/tc002/)
#   tc002-run.sh status               processes, properties, tail of the logs (no lock needed)
#   tc002-run.sh stop                 sigterm the supervisor, restart the stock app, release the lock
#   tc002-run.sh halt                 for an update: kill the runtime without the black frame a sigterm
#                                     paints and without restarting zkswe, so whatever is on the glass
#                                     (the "Updating..." notice) stays until the next runtime draws; then
#                                     rename a staged /tmp/tc002.new/ into place, if there is one
#   tc002-run.sh restore              stop, then remove /tmp/tc002 and /tmp/EasyUI.cfg (stock state)
#
# nothing here survives a reboot: everything lives in the device's tmpfs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=$(cd "$HERE/.." && pwd)
LOCK=$HERE/tc002-lock.sh
DEV=/tmp/tc002

die() { echo "$*" >&2; exit 1; }

# with two clocks attached a bare `adb shell` fails with "more than one
# device/emulator". TC002_DEVICE names the one meant; without it the old
# single-device behaviour is kept, which is right when there is only one.
adb() {
    case "${1:-}" in
        connect|disconnect|start-server|kill-server|devices) command adb "$@" ;;
        *) if [ -n "${TC002_DEVICE:-}" ]; then command adb -s "$TC002_DEVICE" "$@"; else command adb "$@"; fi ;;
    esac
}

need_adb() {
    # the hint is for the case where the variable is *unset*: with two clocks attached a bare
    # adb call fails, and naming one is the fix. when it is set, say which clock was meant.
    adb get-state >/dev/null 2>&1 || die "no adb device${TC002_DEVICE:+ at $TC002_DEVICE}: adb connect <device-ip> first${TC002_DEVICE:-
(several clocks attached? export TC002_DEVICE=<ip>:5555 to name one)}"
}
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
    TARGET=$DEV
    [ "${2:-}" = --staged ] && TARGET=$DEV.new
    if [ -z "${TC002_NO_BUILD:-}" ]; then
        (cd "$RUNTIME" && zig build && zig build check) || die "build failed"
    fi
    [ -x "$RUNTIME/zig-out/bin/tc002-supervisor" ] || die "no binaries in $RUNTIME/zig-out; build first"
    # replacing the binaries under another agent's live run truncates mapped executables on tmpfs
    # (netd died that way on 2026-09-07), so the push itself runs under the lock
    "$LOCK" acquire "tc002-run.sh push: binaries into $TARGET on ${TC002_DEVICE:-the connected clock}" 120 || exit 1
    # 0711: netd, ntfy and berryd run as uid 1001 and have to *search* this
    # directory to exec themselves out of it. without the x bit the exec fails
    # with 127 and the supervisor respawns them forever, which reads as a crash
    # loop in a binary that is fine. the supervisor creates it 0711 too, but a
    # directory left by an older flashed runtime is 0700, and mkdir -p keeps it.
    # not 0755: the credentials fallback lives under here, so it stays unlistable.
    adb shell "mkdir -p $TARGET && chmod 711 $TARGET" >/dev/null
    for f in bin/tc002d bin/tc002-supervisor bin/tc002-netd bin/tc002-ntfy bin/tc002-berryd bin/tc002-audiod lib/libtc002-bootstrap.so; do
        adb push "$RUNTIME/zig-out/$f" "$TARGET/$(basename "$f")" >/dev/null || { "$LOCK" release "push of $f failed"; die "push of $f failed"; }
    done
    adb shell "chmod 755 $TARGET/tc002d $TARGET/tc002-supervisor $TARGET/tc002-netd $TARGET/tc002-ntfy $TARGET/tc002-berryd $TARGET/tc002-audiod" >/dev/null
    dsh "ls -la $TARGET"
    "$LOCK" release "push done into $TARGET on ${TC002_DEVICE:-the connected clock} ($(basename "$(cd "$RUNTIME/.." && git branch --show-current 2>/dev/null || echo unknown)"))"
    ;;
  start)
    shift
    need_adb
    "$LOCK" acquire "tc002-run.sh start: custom runtime on the panel of ${TC002_DEVICE:-the connected clock}" 300 || exit 1
    stock_stop
    adb shell "rm -f $DEV/supervisor.log; trap '' HUP; $DEV/tc002-supervisor $* </dev/null >$DEV/supervisor.log 2>&1 & echo \$! >$DEV/supervisor.pid"
    sleep 2
    if adb shell "kill -0 \$(cat $DEV/supervisor.pid) 2>/dev/null"; then
        echo "supervisor running (pid $(dsh cat $DEV/supervisor.pid)) with: $*"
        dsh "cat $DEV/supervisor.log" | grep -v -E 'inherited (fd|env)|arg [0-9]'
    else
        echo "the supervisor exited immediately:"; dsh "cat $DEV/supervisor.log"
        stock_start
        "$LOCK" release "start failed on ${TC002_DEVICE:-the connected clock}, stock app restarted"
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
  halt)
    # the led controller keeps the last frame it was given. a sigterm makes the renderer paint a
    # paced black frame on the way out, which is right for handing the panel back and wrong for
    # an update, where the "updating" notice should sit on the glass through the gap. so: kill,
    # every process, netd included (it holds port 80, which the next supervisor has to bind).
    need_adb
    adb shell "kill -KILL \$(cat $DEV/supervisor.pid 2>/dev/null) 2>/dev/null; kill -KILL \$(ps | grep -v grep | grep -E 'tc002d|tc002-netd|tc002-ntfy|tc002-audiod|tc002-berryd' | while read p rest; do echo \$p; done) 2>/dev/null; true" >/dev/null 2>&1
    wait_for 3 "[ -z \"\$(ps | grep -v grep | grep -E 'tc002-supervisor|tc002-netd')\" ]" || echo "warning: the runtime did not go away" >&2
    # a staged push is swapped in now, by renames on the same tmpfs: the old binaries are unmapped,
    # and nothing has to be copied while the panel waits
    adb shell "if [ -d $DEV.new ]; then mkdir -p $DEV && chmod 711 $DEV && for f in $DEV.new/*; do mv -f \$f $DEV/; done && rmdir $DEV.new; fi" >/dev/null 2>&1
    "$LOCK" release "halt done on ${TC002_DEVICE:-the connected clock}: runtime killed, staged binaries in, panel left as it was"
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
    "$LOCK" release "$1 done on ${TC002_DEVICE:-the connected clock}, stock app restarted"
    ;;
  *)
    echo "usage: tc002-run.sh push [--staged] | start [supervisor options...] | status | stop | halt | restore" >&2
    exit 2
    ;;
esac
