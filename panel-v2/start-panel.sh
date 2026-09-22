#!/bin/bash
# start-panel.sh: bring up the panel-v2 console with the tokens sorted out, so the invocation need not
# be remembered. runs the proxy in the foreground; ctrl-c stops everything it started.
#
#   panel-v2/start-panel.sh [host[:port]] [--port N] [--token-file FILE] [--serial S] [--mock] [--open]
#
#   host           the device address. optional: the clocks announce themselves over mdns, so when
#                  it is left out the lan is asked. exactly one clock is used; several are listed
#                  and none is chosen, because choosing among them is the mistake this is meant to
#                  avoid -- the console has the list and remembers the one you used last. with no
#                  clock found the wlan0 address is read from adb, and failing that the console
#                  still starts, with its device field empty
#   --port N       local port for the proxy (default 8777)
#   --token-file   the token file pulled from /data/tc002/state/credentials/tokens; when
#                  omitted, tokens-<host> (the file tc002-up.sh writes per clock) is used if
#                  present in . or .., then ./tokens or ../tokens, otherwise the tokens are
#                  pulled over adb into memory (nothing written to disk). they are durable, so a
#                  pulled file keeps working across reboots. the proxy also reads every
#                  tokens-<host> file beside the one it was given, so the page can switch clocks
#                  with ?host= and each request carries that clock's tokens
#   --serial S     adb serial when several devices are attached
#   --mock         no device: start mock-device.py (default port 18080, --mock-port to change) with
#                  a shared token file and point the console at it
#   --open         open the console in the default browser once the proxy is up
#
# the preview renderer (panel-v2/tc002-panel.wasm) and the mock's catalogue
# (panel-v2/scenes.json) are rebuilt from runtime/src on every start when zig is installed, so
# the console always previews the current scene code against the current catalogue.
#
# any python3 on PATH, apple's as the fallback. the proxy binds 127.0.0.1 but the calls it makes
# to the clock are lan calls, and macos 15+ gates those per binary: under a third-party python
# they fail until the terminal app holds the local network grant, and they fail as "cannot reach"
# rather than as a permission error. apple's /usr/bin/python3 is exempt from the gate, which is
# why it is the fallback rather than the rule (see README's macos note).
set -eu
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
invoked_from=$PWD          # kept before the cd below, so token files beside you are still found
cd "$(dirname "$self")"
PY=$(command -v python3 || true)
[ -x "$PY" ] || PY=/usr/bin/python3

host="" port=8777 token_file="" serial="" mock=0 mock_port=18080 open_browser=0
while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    --token-file) token_file="$2"; shift 2 ;;
    --serial) serial="$2"; shift 2 ;;
    --mock) mock=1; shift ;;
    --mock-port) mock_port="$2"; shift 2 ;;
    --open) open_browser=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {if ($0 ~ /^# apple/) exit; sub(/^# ?/, ""); print}' "$self"; exit 0 ;;
    -*) echo "start-panel.sh: unknown option $1" >&2; exit 2 ;;
    *) host="$1"; shift ;;
  esac
done

# the preview draws with the runtime's own renderer, cross-compiled to wasm from runtime/src, and
# the mock serves the /scenes catalogue generated from the same tables. the wasm is not committed,
# the catalogue is; refreshing both here means a stale catalogue shows up in `git status`.
if command -v zig >/dev/null 2>&1; then
  ( cd ../runtime && zig build wasm scenes ) || { echo "start-panel.sh: zig build wasm scenes failed" >&2; exit 1; }
elif [ ! -f tc002-panel.wasm ]; then
  echo "start-panel.sh: zig is not installed and tc002-panel.wasm has never been built;" >&2
  echo "                the console will load but the preview cannot draw" >&2
fi

adb_cmd=(adb)
[ -n "$serial" ] && adb_cmd+=(-s "$serial")

pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
# a trap that only cleans up does not stop anything: bash runs it and carries straight on, so a
# signal arriving during startup was swallowed and whatever had not been spawned yet still was --
# and it then had nothing to stop it. the handlers exit, with the signal's own status.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# the clocks advertise themselves, so an address is a convenience rather than a requirement.
# this runs only when one was not given, and only in the no-mock path.
# TC002_LISTER points at a different lister; the suite stubs discovery with it.
lister=${TC002_LISTER:-../tc002-devices.py}
discover_host() {
  [ -f "$lister" ] || return 0
  local json
  # mdns only: no adb probes, so nothing shells into a clock just to fill in an address
  json=$("$PY" "$lister" --json --no-listen --no-adb 2>/dev/null) || return 0
  # exit status says which of the three happened, because "none" and "several" need different
  # words from the caller and the address alone cannot tell them apart: 0 one, 3 several, 4 none
  "$PY" -c '
import json, sys
rows = [r for r in json.loads(sys.argv[1] or "[]") if r.get("kind") == "runtime" and r.get("ip")]
def octets(r):
    p = r["ip"].split(".")
    return [int(x) for x in p] if len(p) == 4 and all(x.isdigit() for x in p) else [999]
rows.sort(key=octets)   # by octet: .111 before .68 as text reads as a muddle
name = lambda r: (r.get("name") or "").removesuffix(".local") or "unnamed"
# one is an answer; several are a question, and answering it here by taking the first is exactly
# the silent mis-addressing the lister was written to stop
if len(rows) == 1:
    print(rows[0]["ip"])
    print("start-panel.sh: device %s (%s), found on the lan" % (rows[0]["ip"], name(rows[0])), file=sys.stderr)
elif rows:
    print("start-panel.sh: %d clocks on the lan, so none is assumed -- pick one in the console:"
          % len(rows), file=sys.stderr)
    for r in rows:
        print("    %s  %s" % (r["ip"], name(r)), file=sys.stderr)
    sys.exit(3)
else:
    sys.exit(4)
' "$json"
}

serve_args=("$port")
if [ "$mock" = 1 ]; then
  # the mock creates the token file when it is missing; the proxy reads the same file
  token_file="${token_file:-mock-tokens}"
  "$PY" mock-device.py --port "$mock_port" --token-file "$token_file" &
  pids+=($!)
  host="127.0.0.1:$mock_port"
  for _ in $(seq 1 50); do [ -s "$token_file" ] && break; sleep 0.1; done
  serve_args+=(--token-file "$token_file")
else
  several=0
  if [ -z "$host" ]; then
    host=$(discover_host) || [ "$?" = 3 ] && [ -z "$host" ] && several=1
  fi
  if [[ -z $token_file ]]; then
    bare_host=${host%%:*}
    candidates=(tokens ../tokens)
    [[ -n $bare_host ]] && candidates=("tokens-$bare_host" "../tokens-$bare_host" "${candidates[@]}")
    for f in "${candidates[@]}"; do [[ -s $f ]] && token_file=$f && break; done
  fi
  if [ -n "$token_file" ]; then
    serve_args+=(--token-file "$token_file")
  else
    # no single token file, but the per-clock ones may be sitting beside us. the proxy reads those
    # per request, so handing it the directory is enough for a console with no clock chosen yet --
    # which is exactly where several clocks on the lan leaves us
    token_dir=""
    for d in . .. "$invoked_from"; do
      if compgen -G "$d/tokens-*" >/dev/null 2>&1; then token_dir=$d; break; fi
    done
    if [ -n "$token_dir" ]; then
      echo "start-panel.sh: per-clock token files in $token_dir/" >&2
      serve_args+=(--token-dir "$token_dir")
    else
      echo "start-panel.sh: no token file found (./tokens or ../tokens); pulling the tokens over adb" >&2
      serve_args+=(--adb-pull)
      [ -n "$serial" ] && serve_args+=(--serial "$serial")
    fi
  fi
  if [ -z "$host" ]; then
    host="$("${adb_cmd[@]}" shell ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1 || true)"
    if [ -n "$host" ]; then
      echo "start-panel.sh: device address from adb: $host" >&2
    elif [ "$several" = 0 ]; then
      # not a failure: the console's device field lists what the lan is advertising and refreshes
      # when it is focused, so it opens perfectly well without being told an address. said only
      # when nothing was found -- the several-clocks case has already listed them, and telling
      # someone nothing was found straight after naming two of them is just wrong
      echo "start-panel.sh: no clock found on the lan or over adb; pick or type one in the console" >&2
    fi
  fi
fi

url="http://127.0.0.1:$port/${host:+?host=$host}"
echo "console: $url"
if [ "$open_browser" = 1 ]; then
  ( for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/tokens" && break; sleep 0.1; done; open "$url" ) &
fi
exec_pid=""
"$PY" serve.py "${serve_args[@]}" &
exec_pid=$!
pids+=("$exec_pid")
wait "$exec_pid"
