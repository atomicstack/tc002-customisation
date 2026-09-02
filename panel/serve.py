#!/usr/bin/python3
"""Local server for the TC002 panel.

Serves index.html and proxies /api/<device-ip>/<endpoint> to the device, so the
browser only ever talks to this origin. The device does not send CORS headers on
real responses, so direct browser->device fetches are blocked; this sidesteps it.

Run with Apple's python3 (/usr/bin/python3) — Homebrew binaries are denied LAN
access by macOS Local Network Privacy.
"""
import http.server, socketserver, urllib.request, urllib.error, json, sys, re

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8777
HOST_RE = re.compile(r"^/api/([0-9a-zA-Z.\-]+)/(.+)$")


class Handler(http.server.SimpleHTTPRequestHandler):
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
    with Server(("127.0.0.1", PORT), Handler) as httpd:
        print(f"panel on http://127.0.0.1:{PORT}  (proxying /api/<device-ip>/<endpoint>)")
        httpd.serve_forever()
