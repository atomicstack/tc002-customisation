#!/usr/bin/python3
"""local server for the tc002 custom-runtime console (panel-v2).

serves index.html and proxies /api/<host>/v1/<path> to http://<host>/api/v1/<path>, adding the
bearer token the route needs, so the browser never holds a secret and only ever talks to this
origin (the runtime emits no cors headers, so direct browser->device fetches are blocked anyway).

tokens: --token-file FILE   the 64 raw bytes the supervisor writes (control token, then admin),
                            as pulled with `adb pull /data/tc002/state/credentials/tokens`
        --adb-pull          pull that file over adb at startup into memory (nothing on disk)
        --serial S          the adb serial/host:port to pull from, when several are connected
without either the page loads but every proxied call fails 503 no_token.

usage: serve.py [port] [--token-file FILE | --adb-pull [--serial S]]     default port 8777

run with apple's python3 (/usr/bin/python3): homebrew binaries are denied lan access by macos
local network privacy. binds 127.0.0.1 only.
"""
import argparse, functools, http.server, json, os, re, socketserver, subprocess, sys, tempfile, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TOKENS = {"control": None, "admin": None}
# routes that take the admin token; everything else on /api/v1 takes control
ADMIN_ROUTES = {("PATCH", "config"), ("POST", "config/save"), ("GET", "mqtt"), ("PUT", "mqtt"), ("GET", "ntfy"), ("PUT", "ntfy"),
                # replacing a canvas or a sprite is admin; reading, patching values and clearing are control
                ("PUT", "canvas")}
# host may carry a port (host:1234) so the mock or a device behind a forward works
PATH_RE = re.compile(r"^/api/([0-9a-zA-Z.\-]+(?::\d+)?)/v1/([A-Za-z0-9_\-]+(?:/[A-Za-z0-9_\-]+)*)(?:\?(.*))?$")
DEVICE_TIMEOUT_S = 10
# the only static files this server will hand back; everything else not under /api/ or /tokens is 404
STATIC_ALLOW = {"/", "/index.html", "/sim-wasm.js", "/tc002-panel.wasm"}


def parse_tokens(data):
    """the token file is exactly 64 raw bytes: control then admin."""
    if len(data) != 64:
        raise ValueError("token file must hold exactly 64 raw bytes (control token then admin token)")
    return data[:32].hex(), data[32:].hex()


def load_token_file(path):
    with open(path, "rb") as f:
        control, admin = parse_tokens(f.read())
    return {"control": control, "admin": admin}


# where the runtime keeps its credentials: the durable state directory first, then the volatile
# one it falls back to when /data cannot be used (RUNTIME.md, "settings, credentials, the listener")
TOKEN_PATHS = ("/data/tc002/state/credentials/tokens", "/tmp/tc002/credentials/tokens")


def adb_pull(serial=None):
    """pull the token file into memory via a temporary directory; nothing is left on disk."""
    with tempfile.TemporaryDirectory() as d:
        target = os.path.join(d, "tokens")
        problems = []
        for path in TOKEN_PATHS:
            cmd = ["adb"] + (["-s", serial] if serial else []) + ["pull", path, target]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                return load_token_file(target)
            problems.append(f"{path}: {(r.stderr or r.stdout).strip()}")
        raise RuntimeError("adb pull failed:\n  " + "\n  ".join(problems))


def token_for(method, endpoint):
    if method == "PUT" and endpoint.startswith("sprites/"):
        return "admin"   # a sprite slot is a path family, so it cannot sit in the set above
    return "admin" if (method, endpoint) in ADMIN_ROUTES else "control"


def rewrite(path):
    """'/api/<host>/v1/<endpoint>[?query]' -> (host, endpoint, query), or None."""
    m = PATH_RE.match(path)
    if not m:
        return None
    return m.group(1), m.group(2), m.group(3) or ""


class Handler(http.server.SimpleHTTPRequestHandler):
    def _json(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _tokens(self):
        t = self.server.tokens
        return self._json(200, {"control": t["control"] is not None, "admin": t["admin"] is not None})

    def _proxy(self, method):
        parts = rewrite(self.path)
        if not parts:
            return self._json(400, {"error": "bad_proxy_path", "message": "expected /api/<host>/v1/<endpoint>"})
        host, endpoint, query = parts
        kind = token_for(method, endpoint)
        token = self.server.tokens[kind]
        if token is None:
            return self._json(503, {"error": "no_token", "message": f"serve.py has no {kind} token; restart it with --token-file or --adb-pull"})
        url = f"http://{host}/api/v1/{endpoint}" + (f"?{query}" if query else "")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        req = urllib.request.Request(url, data=body, method=method)
        # the token is added here; whatever the browser sent as authorization is dropped
        req.add_header("Authorization", f"Bearer {token}")
        if body is not None:
            req.add_header("Content-Type", self.headers.get("Content-Type") or "application/json")
        try:
            with urllib.request.urlopen(req, timeout=DEVICE_TIMEOUT_S) as r:
                payload, status, ctype, device_date = r.read(), r.status, r.headers.get("Content-Type") or "application/json", r.headers.get("Date")
        except urllib.error.HTTPError as e:
            payload, status, ctype, device_date = e.read(), e.code, e.headers.get("Content-Type") or "application/json", e.headers.get("Date")
        except Exception as e:
            payload, status, ctype, device_date = json.dumps({"error": "proxy", "message": f"cannot reach {host}: {e}"}).encode(), 502, "application/json", None
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        # the device's own Date, kept under a name of its own: send_response writes a Date header
        # from this machine's clock, and the console wants the panel's, to put the previewed clock
        # on the device's second rather than the laptop's
        if device_date:
            self.send_header("X-Device-Date", device_date)
            self.send_header("Access-Control-Expose-Headers", "X-Device-Date")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/api/"):
            return self._proxy("GET")
        path = self.path.split("?")[0]
        if path == "/tokens":
            return self._tokens()
        if path in STATIC_ALLOW:
            return super().do_GET()
        return self._json(404, {"error": "not_found", "message": f"no such route: {path}"})

    def do_POST(self):
        if self.path.startswith("/api/"):
            return self._proxy("POST")
        self.send_error(405)

    def do_PUT(self):
        if self.path.startswith("/api/"):
            return self._proxy("PUT")
        self.send_error(405)

    def do_PATCH(self):
        if self.path.startswith("/api/"):
            return self._proxy("PATCH")
        self.send_error(405)

    def do_DELETE(self):
        # the canvas and the sprite slots are the routes that use it
        if self.path.startswith("/api/"):
            return self._proxy("DELETE")
        self.send_error(405)

    def log_message(self, fmt, *a):
        sys.stderr.write("  %s\n" % (fmt % a))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_server(port, tokens, directory=HERE):
    handler = functools.partial(Handler, directory=directory)
    server = Server(("127.0.0.1", port), handler)
    server.tokens = tokens
    return server


def parse_args(argv):
    p = argparse.ArgumentParser(prog="serve.py", description="local server for the tc002 custom-runtime console")
    p.add_argument("port", nargs="?", type=int, default=8777)
    p.add_argument("--token-file", metavar="FILE")
    p.add_argument("--adb-pull", action="store_true")
    p.add_argument("--serial", metavar="S")
    return p.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    tokens = dict(TOKENS)
    if args.token_file:
        tokens = load_token_file(args.token_file)
    elif args.adb_pull:
        tokens = adb_pull(args.serial)
    with make_server(args.port, tokens) as httpd:
        have = ", ".join(k for k in ("control", "admin") if tokens[k]) or "none"
        print(f"panel-v2 on http://127.0.0.1:{args.port}  (proxying /api/<device-ip>/v1/<endpoint>; tokens: {have})", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (RuntimeError, OSError, ValueError) as e:
        sys.exit(f"serve.py: {e}")
