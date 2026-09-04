#!/usr/bin/python3
"""Local server for the TC002 panel.

Serves index.html and proxies /api/<device-ip>/<endpoint> to the device, so the
browser only ever talks to this origin. The device does not send CORS headers on
real responses, so direct browser->device fetches are blocked; this sidesteps it.

It also listens for the device's discovery broadcast (udp/55555, about once a
second, "Ulanzi TC002 <mac-tail>:<mac>:<serial>:<flag>") in a background
thread and serves what it has heard at GET /discover, so the page can find the
device without being told its address. Pass --no-discover to skip that.

Usage: serve.py [port] [--no-discover]        default port 8777

Run with Apple's python3 (/usr/bin/python3) — Homebrew binaries are denied LAN
access by macOS Local Network Privacy.
"""
import http.server, socketserver, urllib.request, urllib.error, json, sys, re, socket, threading, time

ARGS = sys.argv[1:]
NO_DISCOVER = "--no-discover" in ARGS
PORT = next((int(a) for a in ARGS if a.isdigit()), 8777)
# host may carry a port (host:1234) so a mock or a device behind a forward works
HOST_RE = re.compile(r"^/api/([0-9a-zA-Z.\-]+(?::\d+)?)/(.+)$")

# mirrors tc002-adopt.py; kept inline so the panel stays a single directory
BROADCAST_PORT = 55555
BROADCAST_RE = re.compile(
    r"^Ulanzi TC002 (?P<tail>[0-9a-f]{4}):(?P<mac>[0-9a-f]{12}):(?P<sn>[A-Za-z0-9]+):(?P<flag>true|false)$")
SEEN_MAX_AGE = 10.0   # a device not heard for this long is dropped from /discover


class Announcer(threading.Thread):
    """Collects TC002 broadcast announcements for as long as the server runs."""

    def __init__(self):
        super().__init__(name="tc002-announcer", daemon=True)
        self.seen = {}          # ip -> {"mac","sn","flag","last"}
        self.lock = threading.Lock()
        self.error = None

    def run(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except (AttributeError, OSError):
            pass
        try:
            s.bind(("0.0.0.0", BROADCAST_PORT))
        except OSError as e:
            self.error = f"cannot listen on udp/{BROADCAST_PORT}: {e}"
            return
        while True:
            try:
                data, (ip, _port) = s.recvfrom(1024)
            except OSError:
                continue
            m = BROADCAST_RE.match(data.decode("utf-8", "replace").strip())
            if not m:
                continue
            with self.lock:
                self.seen[ip] = {"mac": m["mac"], "sn": m["sn"], "flag": m["flag"] == "true",
                                 "last": time.time()}

    def snapshot(self):
        now = time.time()
        with self.lock:
            fresh = {ip: d for ip, d in self.seen.items() if now - d["last"] <= SEEN_MAX_AGE}
            self.seen = fresh
            return [{"ip": ip, "mac": d["mac"], "sn": d["sn"], "flag": d["flag"],
                     "age": round(now - d["last"], 1)}
                    for ip, d in sorted(fresh.items(), key=lambda kv: kv[1]["last"], reverse=True)]


ANNOUNCER = None if NO_DISCOVER else Announcer()


class Handler(http.server.SimpleHTTPRequestHandler):
    def _json(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _discover(self):
        if ANNOUNCER is None:
            return self._json(200, {"listening": False, "error": "discovery disabled (--no-discover)",
                                    "port": BROADCAST_PORT, "devices": []})
        return self._json(200, {"listening": ANNOUNCER.error is None, "error": ANNOUNCER.error,
                                "port": BROADCAST_PORT, "devices": ANNOUNCER.snapshot()})

    def _proxy(self, method):
        m = HOST_RE.match(self.path)
        if not m:
            self.send_error(400, "bad proxy path")
            return
        target_host, endpoint = m.group(1), m.group(2)
        url = f"http://{target_host}/{endpoint}"
        body = None
        if method == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n) if n else b""
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                payload, status = r.read(), r.status
        except urllib.error.HTTPError as e:
            payload, status = e.read(), e.code
        except Exception as e:
            payload = json.dumps({"error": str(e)}).encode()
            status = 502
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/api/"):
            return self._proxy("GET")
        if self.path.split("?")[0] == "/discover":
            return self._discover()
        return super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/"):
            return self._proxy("POST")
        self.send_error(405)

    def log_message(self, fmt, *a):
        sys.stderr.write("  %s\n" % (fmt % a))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if ANNOUNCER is not None:
        ANNOUNCER.start()
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        note = "discovery off" if ANNOUNCER is None else f"listening for broadcasts on udp/{BROADCAST_PORT}"
        print(f"panel on http://127.0.0.1:{PORT}  (proxying /api/<device-ip>/<endpoint>; {note})", flush=True)
        httpd.serve_forever()
