#!/bin/bash
# start-panel.sh: bring up the panel-v2 console with the tokens sorted out, so the invocation need not
# be remembered. runs the proxy in the foreground; ctrl-c stops everything it started.
#
#   panel-v2/start-panel.sh [host[:port]] [--port N] [--token-file FILE] [--serial S] [--mock] [--open]
#
#   host           the device address; when omitted and a device is attached over adb, the wlan0
#                  address is read from it
#   --port N       local port for the proxy (default 8777)
#   --token-file   the 64-byte token file pulled from /data/tc002/state/credentials/tokens; when
#                  omitted, ./tokens or ../tokens is used if present, otherwise the tokens are
#                  pulled over adb into memory (nothing written to disk). they are durable, so a
#                  pulled file keeps working across reboots
#   --serial S     adb serial when several devices are attached
#   --mock         no device: start mock-device.py (default port 18080, --mock-port to change) with
#                  a shared token file and point the console at it
#   --open         open the console in the default browser once the proxy is up
#
# apple's /usr/bin/python3 is used on purpose: on macos 15+ third-party binaries are gated for
# local network access per binary, apple's are not (see CLAUDE.md / README).
set -eu
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$self")"
PY=/usr/bin/python3
[ -x "$PY" ] || PY=python3

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

adb_cmd=(adb)
[ -n "$serial" ] && adb_cmd+=(-s "$serial")

pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM

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
  if [ -z "$token_file" ]; then
    for f in tokens ../tokens; do [ -s "$f" ] && token_file="$f" && break; done
  fi
  if [ -n "$token_file" ]; then
    serve_args+=(--token-file "$token_file")
  else
    echo "start-panel.sh: no token file found (./tokens or ../tokens); pulling the tokens over adb" >&2
    serve_args+=(--adb-pull)
    [ -n "$serial" ] && serve_args+=(--serial "$serial")
  fi
  if [ -z "$host" ]; then
    host="$("${adb_cmd[@]}" shell ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1 || true)"
    if [ -z "$host" ]; then
      echo "start-panel.sh: no device address: pass it as the first argument (adb could not read wlan0)" >&2
      exit 1
    fi
    echo "start-panel.sh: device address from adb: $host" >&2
  fi
fi

url="http://127.0.0.1:$port/?host=$host"
echo "console: $url"
if [ "$open_browser" = 1 ]; then
  ( for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/tokens" && break; sleep 0.1; done; open "$url" ) &
fi
exec_pid=""
"$PY" serve.py "${serve_args[@]}" &
exec_pid=$!
pids+=("$exec_pid")
wait "$exec_pid"
