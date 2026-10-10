#!/usr/bin/env bash
# tc002-notice.sh: the notice the panel shows for every kind of update: "Updating..." for an
# in-place update, "Flashing..." for a flash (the flasher passes the word).
#
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> show [text [staging|image BYTES]]
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> restore [--once]
#
# `show` posts the notice as a **held notification named `updating`**: a canvas document (the
# word in the `tiny5` face, white, centred, pulsing every 1.6 s, over a bar the clock fills itself
# when a watch is given; `mini` on its own for a runtime too old for the bar) under the notification
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
    # 13 characters fit either face; the word goes into json as is, so no quotes or backslashes
    text=${1:-Updating...}
    [[ ${#text} -le 13 && $text != *[\"\\]* ]] || { echo "tc002-notice.sh: the notice must be 13 plain characters at most" >&2; exit 2; }
    # a bar under the word, filled by the clock itself from what has arrived of a transfer: it
    # measures the staging directory or the staged image every 100 ms and eases to each reading.
    # the watch is a name, never a path; the bytes are what the transfer will total
    watch=${2:-}; bytes=${3:-}
    if [[ -n $watch ]]; then
        [[ ($watch == staging || $watch == image) && $bytes =~ ^[1-9][0-9]*$ ]] \
            || { echo "tc002-notice.sh: watch is staging or image, followed by the bytes it will total" >&2; exit 2; }
    fi
    # the word in tiny5, white and breathing: its line box starts two rows above the panel so the
    # ink of all three words (Updating..., Flashing..., Working...) sits on rows 1-7, in the same
    # place whichever is showing. rows 8-9 empty, 10-15 the bar: four rows of white inside a
    # one-pixel border of 0a0a0a, which lands just above the led driver's floor of 50 and still
    # lights down to about 10% brightness
    word='{"id":"l1","type":"text","at":[0,-2],"size":[52,11],"font":"tiny5","align":"centre","colour":"ffffff",
           "text":"'"$text"'","animate":{"kind":"pulse","ms":1600}}'
    frame='{"id":"frame","type":"rect","at":[0,10],"size":[52,6],"colour":"0a0a0a"}'
    bar='{"id":"bar","type":"bar","at":[1,11],"size":[50,4],"colour":"ffffff",
          "watch":"'"$watch"'","bytes":'"${bytes:-0}"'}'
    # the word alone, in mini: a runtime that predates the watching bar may predate tiny5 as well
    alone='{"id":"l1","type":"text","at":[0,5],"size":[52,5],"font":"mini","align":"centre","colour":"ffffff",
           "text":"'"$text"'","animate":{"kind":"pulse","ms":1600}}'
    # a runtime older than the watching bar refuses the field; it still gets the word on its own
    if [[ -n $watch ]] && api POST /notify '{"name":"updating","hold":true,"elements":['"$word"','"$frame"','"$bar"']}' | grep -q applied; then
        :
    else
        api POST /notify '{"name":"updating","hold":true,"elements":['"$alone"']}' | grep -q applied \
            || { echo "tc002-notice.sh: the runtime did not take the notice" >&2; exit 1; }
    fi
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
