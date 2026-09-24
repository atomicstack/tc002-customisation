#!/usr/bin/env bash
# tc002-notice.sh: the one "Updating..." the panel shows for every kind of update.
#
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> show
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> restore [--once]
#
# `show` posts the notice as a **held notification named `updating`**: a canvas document (the
# `mini` face -- 3x5, fits 13 characters; "Updating..." is 11, and it has one case, so the capital
# is for the reader of this script -- centred, orange, pulsing every 1.6 s) under the notification
# lifecycle, held until dismissed. it used to be the canvas base, back when a notification could
# only be a line of text and expired on its own timer; that left "Updating..." as the canvas
# document, on flash, for the canvas button to show for ever after. a notification lives in the
# renderer's memory: the restart that ends an in-place update, or the reboot that ends a flash,
# drops it by itself, and nothing on the clock is changed to show it or to take it down.
#
# it pulses because a frozen panel and a dead one look identical, and the pulse is the difference:
# while the runtime is alive it visibly breathes, which says "working, wait" rather than "crashed";
# the moment the renderer dies it freezes on whatever brightness it had, and the panel holds that
# latched frame, word and all, for the rest of the update.
#
# `restore` dismisses the notice by name, for the case where the runtime that showed it is still
# the one running (a flash that was refused, an in-place update that stopped before the halt). on
# a fresh runtime there is nothing to dismiss and the call is a successful no-op, so callers run it
# unconditionally. it retries for half a minute, because after a flash the runtime is a fresh boot
# away; `--once` is one attempt, for a caller with its own loop (the flasher re-forwards the port
# each time). CURL overrides the curl binary (tests; apple's is the default because macos gates lan
# access per binary).
set -euo pipefail
CURL=${CURL:-/usr/bin/curl}
host=${1:?host}; tokens=${2:?token file}; verb=${3:?show|restore}; shift 3

token_of() { sed -n "s/^admin=\([0-9a-fA-F]\{64\}\)$/\1/p" "$tokens" | head -1; }
api() { # api <method> <path> [body]
    local m=$1 path=$2 body=${3:-}
    if [[ -n $body ]]; then
        "$CURL" -s -m 5 -X "$m" "http://$host/api/v1$path" -H "Authorization: Bearer $admin" -H "Content-Type: application/json" -d "$body"
    else
        "$CURL" -s -m 5 -X "$m" "http://$host/api/v1$path" -H "Authorization: Bearer $admin"
    fi
}

[[ -f $tokens ]] || { echo "tc002-notice.sh: no token file $tokens" >&2; exit 1; }
admin=$(token_of)
[[ -n $admin ]] || { echo "tc002-notice.sh: no admin token in $tokens" >&2; exit 1; }

case "$verb" in
  show)
    api POST /notify '{"name":"updating","hold":true,"elements":[
        {"id":"l1","type":"text","at":[0,5],"size":[52,5],"font":"mini","align":"centre","colour":"ff8000",
         "text":"Updating...","animate":{"kind":"pulse","ms":1600}}]}' | grep -q applied \
        || { echo "tc002-notice.sh: the runtime did not take the notice" >&2; exit 1; }
    sleep 1   # let it be drawn and latched before anything kills the renderer
    ;;
  restore)
    once=0; [[ ${1:-} == --once ]] && once=1
    tries=10; (( once )) && tries=1
    for _ in $(seq 1 "$tries"); do
        if api POST /notify/dismiss '{"name":"updating"}' 2>/dev/null | grep -q applied; then exit 0; fi
        (( once )) || sleep 3
    done
    echo "tc002-notice.sh: could not reach $host to take the notice down; a restart drops it anyway" >&2
    exit 1
    ;;
  *) echo "tc002-notice.sh: show or restore" >&2; exit 2 ;;
esac
