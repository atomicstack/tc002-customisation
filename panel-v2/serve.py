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
# the endpoint segments allow dots because a client token name may contain one
# (`home.assistant` is a likely name), and DELETE /tokens/<name> carries it in the path
# a segment may contain dots but never start with one, so `home.assistant` is a legal token
# name while `..` and `.hidden` are not paths at all. the runtime's own name rule forbids a
# leading dot for the same reason, so this is the same constraint in the same place
PATH_RE = re.compile(r"^/api/([0-9a-zA-Z.\-]+(?::\d+)?)/v1/([A-Za-z0-9_\-][A-Za-z0-9._\-]*(?:/[A-Za-z0-9_\-][A-Za-z0-9._\-]*)*)(?:\?(.*))?$")
DEVICE_TIMEOUT_S = 10
# longer than the device's sse keepalive, so a quiet stream is not read as a dead one
STREAM_TIMEOUT_S = 30
EVENTS_ENDPOINT = "events"
# the only static files this server will hand back; everything else not under /api/ or /tokens is 404
STATIC_ALLOW = {"/", "/index.html", "/sim-wasm.js", "/tc002-panel.wasm",
                "/scripts-model.js", "/scripts-editor.js", "/scripts-editor.css"}


def parse_tokens(data):
    """the token file is `control=<64 hex>` / `admin=<64 hex>` lines, or the older 64 raw bytes."""
    if len(data) == 64:
        return data[:32].hex(), data[32:].hex()
    found = {}
    try:
        text = data.decode()
    except UnicodeDecodeError:
        raise ValueError("token file is neither 64 raw bytes nor the labelled text form")
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        key, sep, value = line.partition("=")
        # `client=<name>,<scope|scope|...>,<64 hex>` rows appear once a named token is issued. this
        # console only ever uses the two built-in secrets, but it must not choke on the others --
        # raising here meant one issued token stopped start-panel.sh starting at all.
        if key == "client":
            continue
        if sep != "=" or key not in ("control", "admin") or key in found:
            raise ValueError(f"token file has an unexpected line: {key[:16]!r}")
        if len(value) != 64 or any(c not in "0123456789abcdefABCDEF" for c in value):
            raise ValueError(f"the {key} token must be 64 hex characters")
        found[key] = value.lower()
    if "control" not in found or "admin" not in found:
        raise ValueError("token file must define both control and admin")
    return found["control"], found["admin"]


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
    if endpoint.startswith("berry/scripts/"):
        # every per-script route is the `scripts` scope, **reading included** -- which the control
        # token does not hold. this used to escalate only PUT/DELETE/POST, so the editor's "read
        # source from the device" 403'd. listing (`berry/scripts`, no slash) is `status`.
        return "admin"
    if endpoint.startswith("sprites/") and method in ("PUT", "DELETE"):
        return "admin"   # both are the `content` scope; a sprite slot is a path family
    if endpoint == "tokens" or endpoint.startswith("tokens/"):
        return "admin"   # every client-token route is admin, listing included
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

    def _proxy_stream(self, req, host):
        """forward an event stream chunk by chunk for as long as both ends are up.

        no content-length and no buffering: the browser's EventSource wants each frame as it is
        written. the read timeout is deliberately longer than the device's keepalive interval, so a
        quiet stream is not mistaken for a dead one; a genuinely dead device fails the read and the
        loop ends, which is what frees netd's slot on the other side."""
        try:
            r = urllib.request.urlopen(req, timeout=STREAM_TIMEOUT_S)
        except urllib.error.HTTPError as e:
            payload = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type") or "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            return self.wfile.write(payload)
        except Exception as e:
            return self._json(502, {"error": "proxy", "message": f"cannot reach {host}: {e}"})
        with r:
            self.send_response(r.status)
            self.send_header("Content-Type", r.headers.get("Content-Type") or "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            date = r.headers.get("Date")
            if date:
                self.send_header("X-Device-Date", date)
                self.send_header("Access-Control-Expose-Headers", "X-Device-Date")
            self.end_headers()
            try:
                while True:
                    chunk = r.read1(4096) if hasattr(r, "read1") else r.read(1)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass    # the browser went away; closing r releases the device's slot
            except Exception:
                pass

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
            # an event stream never ends, so it cannot be read into a buffer and forwarded whole
            # the way every other response is. hold it open and pump it instead.
            if endpoint == EVENTS_ENDPOINT:
                return self._proxy_stream(req, host)
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
            # index.html and sim-wasm.js change together, so a browser holding an old copy of one
            # against a new copy of the other fails in a way that reads as a code bug. drop any
            # revalidation the browser offers and mark the answer uncacheable: this is a tool on
            # localhost, and a stale asset costs far more than the fetch does
            self.headers.replace_header("If-Modified-Since", "") if "If-Modified-Since" in self.headers else None
            self.headers.replace_header("If-None-Match", "") if "If-None-Match" in self.headers else None
            self._static = True
            return super().do_GET()
        return self._json(404, {"error": "not_found", "message": f"no such route: {path}"})

    def end_headers(self):
        # only the static path: the proxy and the json helpers send their own Cache-Control
        if getattr(self, "_static", False):
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

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
