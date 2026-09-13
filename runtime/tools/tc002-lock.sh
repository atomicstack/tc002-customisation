#!/bin/bash
# advisory lock shared with another agent working on the same tc002.
# append-only records in /tmp/tc002-lock.txt: "<utc-iso> <agent> <ACQUIRE|RELEASE|NOTE> <text>".
# an agent holds the lock while its last ACQUIRE/RELEASE record is an ACQUIRE younger than 30 min.
# usage: tc002-lock.sh acquire "<intent>" [timeout-seconds]   (default 900)
#        tc002-lock.sh release ["<text>"] | status | note "<text>"
set -u
LOCK=${TC002_LOCK_FILE:-/tmp/tc002-lock.txt}
AGENT=${TC002_AGENT:-runtime-agent}
STALE_S=${TC002_LOCK_STALE_S:-1800}
POLL_S=${TC002_LOCK_POLL_S:-10}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_s()   { date -u +%s; }
append()  { printf '%s %s %s %s\n' "$(now_iso)" "$AGENT" "$1" "$2" >> "$LOCK"; }

# prints "<agent> <epoch-s>" for every agent whose last ACQUIRE/RELEASE record is a live ACQUIRE.
# lines that do not parse count as an unknown agent's ACQUIRE stamped with the file's mtime.
holders() {
    [ -f "$LOCK" ] || return 0
    local mtime; mtime=$(stat -f %m "$LOCK")
    awk -v now="$(now_s)" -v stale="$STALE_S" -v mtime="$mtime" '
        function iso2s(s,  cmd, out) {
            cmd = "date -u -j -f %Y-%m-%dT%H:%M:%SZ \"" s "\" +%s 2>/dev/null"
            if ((cmd | getline out) <= 0) out = 0
            close(cmd); return out + 0
        }
        {
            if (($3 == "ACQUIRE" || $3 == "RELEASE") && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T/) { state[$2] = $3; when[$2] = iso2s($1) }
            else if ($3 == "NOTE") { }
            else if (NF > 0) { state["unknown"] = "ACQUIRE"; when["unknown"] = mtime }
        }
        END { for (a in state) if (state[a] == "ACQUIRE" && now - when[a] < stale) print a, when[a] }
    ' "$LOCK"
}

case "${1:-status}" in
  acquire)
    intent=${2:?intent required}; timeout=${3:-900}; waited=0
    while :; do
        others=$(holders | awk -v me="$AGENT" '$1 != me')
        if [ -z "$others" ]; then
            append ACQUIRE "$intent"
            sleep 1
            # if another agent appended an ACQUIRE between our read and our append, the earlier line wins
            last_release=$(awk '$3=="RELEASE"{n=NR} END{print n+0}' "$LOCK")
            earliest=$(awk -v start="$last_release" 'NR>start && $3=="ACQUIRE"{print $2; exit}' "$LOCK")
            if [ "$earliest" = "$AGENT" ]; then echo "lock acquired by $AGENT: $intent"; exit 0; fi
            append RELEASE "backing off, $earliest was first"
        else
            echo "lock held by: $(echo "$others" | tr '\n' ' ')" >&2
        fi
        [ "$waited" -ge "$timeout" ] && { echo "timed out waiting for lock" >&2; exit 1; }
        sleep "$POLL_S"; waited=$((waited + POLL_S))
    done ;;
  release) append RELEASE "${2:-done}"; echo "lock released by $AGENT" ;;
  note)    append NOTE "${2:?text required}" ;;
  status)  h=$(holders); if [ -n "$h" ]; then echo "held: $(echo "$h" | tr '\n' ' ')"; else echo "free"; fi; [ -f "$LOCK" ] && tail -n 5 "$LOCK" ;;
  *) echo "usage: tc002-lock.sh acquire <intent> [timeout-s] | release [text] | status | note <text>" >&2; exit 2 ;;
esac
