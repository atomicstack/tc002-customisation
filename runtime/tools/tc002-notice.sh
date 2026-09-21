#!/usr/bin/env bash
# tc002-notice.sh: the one "Updating..." the panel shows for every kind of update.
#
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> show
#   runtime/tools/tc002-notice.sh <host[:port]> <token-file> restore <scene> [--once]
#
# `show` draws the notice and prints the scene the clock was showing, as `base` or `base:generator`,
# so the caller can hand it back to `restore` once the update is over. it is drawn as the canvas
# base, not a notification: a notification expires on its own timer and this has to last as long
# as the update does. the panel holds its last latched frame while nothing drives it, so whatever
# is on the glass when the runtime dies is what stays there through the gap.
#
# the style is fixed here and nowhere else: the `mini` face (3x5, fits 13 characters; "Updating..."
# is 11, and it has one case, so the capital is for the reader of this script), centred, orange,
# pulsing every 1.6 s. it pulses because a frozen panel and a dead one look identical, and the
# pulse is the difference: while the runtime is alive it visibly breathes, which says "working,
# wait" rather than "crashed"; the moment the renderer dies it freezes on whatever brightness it
# had, and that frame carries the word for the rest of the update.
#
# `restore` retries for half a minute, because after a flash the runtime is a fresh boot away;
# `--once` is one attempt, for a caller with its own loop (the flasher re-forwards the port each
# time). CURL overrides the curl binary (tests; apple's is the default because macos gates lan
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
    status=$(api GET /status || true)
    base=$(printf '%s' "$status" | sed -n 's/.*"base":"\([a-z]*\)".*/\1/p')
    generator=$(printf '%s' "$status" | sed -n 's/.*"generator":"\([a-z]*\)".*/\1/p')
    [[ -n $base ]] || { echo "tc002-notice.sh: could not read the current scene from $host" >&2; exit 1; }
    api PUT /canvas '{"elements":[
        {"id":"l1","type":"text","at":[0,5],"size":[52,5],"font":"mini","align":"centre","colour":"ff8000",
         "text":"Updating...","animate":{"kind":"pulse","ms":1600}}]}' >/dev/null
    api PUT /scene '{"base":"canvas"}' >/dev/null
    sleep 1   # let it be drawn and latched before anything kills the renderer
    if [[ $base == art && -n $generator ]]; then echo "$base:$generator"; else echo "$base"; fi
    ;;
  restore)
    scene=${1:?scene, as printed by show}; shift
    once=0; [[ ${1:-} == --once ]] && once=1
    base=${scene%%:*}
    body="{\"base\":\"$base\""
    [[ $scene == *:* ]] && body="$body,\"generator\":\"${scene#*:}\""
    body="$body}"
    tries=10; (( once )) && tries=1
    for (( i = 0; i < tries; i++ )); do
        if api PUT /scene "$body" 2>/dev/null | grep -q applied; then exit 0; fi
        (( once )) || sleep 3
    done
    echo "tc002-notice.sh: could not put the panel back to $scene; it may still read Updating..." >&2
    exit 1
    ;;
  *) echo "tc002-notice.sh: show or restore" >&2; exit 2 ;;
esac
