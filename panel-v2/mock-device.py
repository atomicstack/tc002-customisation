#!/usr/bin/python3
"""a stand-in for the tc002 custom runtime's /api/v1, for developing and screenshotting panel-v2
without a device. bearer auth, epoch and revision bookkeeping, overlays that expire, settings with
revisions and conflicts, mqtt settings; error bodies in the runtime's shape. not the runtime.

usage: mock-device.py [--port 8080] [--token-file FILE]
  --token-file   64 raw bytes (control token then admin token); created with random tokens when
                 the file does not exist, so `serve.py --token-file` can read the same file.
  POST /mock/restart (no auth) bumps the epoch, like a renderer restart.

binds 127.0.0.1. point the console at 127.0.0.1:<port>.
"""
import http.server, json, os, re, secrets, socketserver, sys, threading, time
from urllib.parse import urlsplit, parse_qs

BASES = ["art", "clock", "ip"]
GENERATORS = ["popsquares", "plasma"]
SCENES = {"bases": BASES,
          "generators": [{"index": 0, "name": "popsquares", "parameters": {"seed": "u32"}},
                         {"index": 1, "name": "plasma", "parameters": {"seed": "u32"}}],
          "notify": {"text_max": 128, "duration_s": [1, 300]}, "frame": {"bytes": 2496, "duration_s": [1, 300]}}
PRINTABLE = re.compile(r"^[\x20-\x7e]{1,128}$")
HEX_ID = re.compile(r"^[0-9a-fA-F]{1,16}$")

# physical controls (RUNTIME.md "physical controls"): which events each control accepts
CONTROL_EVENTS = {
    "left": {"press", "release", "click"},
    "middle": {"press", "release", "click"},
    "right": {"press", "release", "click"},
    "knob": {"press", "release", "click", "long"},
    "rotary": {"cw", "ccw"},
}
STEPPED_EVENTS = {"cw", "ccw"}

# a plausible seeded boot history for the log ring, oldest first
SEED_LOG_LINES = [
    "tc002-supervisor 1000 info profile: isolated-lan",
    "tc002-supervisor 1004 info credentials written",
    "tc002-supervisor 1012 info netd listening on 0.0.0.0:80",
    "tc002-supervisor 1015 info spawned renderer pid 5 epoch 1",
    "tc002d 1020 info dry-run: modelling the panel only",
    "tc002d 1022 info scene: art",
    "tc002-supervisor 1500 info wlan0 address 10.0.0.111",
    "tc002-supervisor 2000 info metrics sample: mem 16084kb cpu 4%",
    "tc002-supervisor 5000 info discovery disabled",
    "tc002-supervisor 7000 info metrics sample: mem 16072kb cpu 5%",
    "tc002-supervisor 12000 info metrics sample: mem 16068kb cpu 5%",
    "tc002-supervisor 17000 info metrics sample: mem 16064kb cpu 4%",
    "tc002-supervisor 22000 info metrics sample: mem 16060kb cpu 5%",
    "tc002-supervisor 27000 info metrics sample: mem 16058kb cpu 5%",
    "tc002-supervisor 32000 info metrics sample: mem 16055kb cpu 4%",
    "tc002-supervisor 37000 info metrics sample: mem 16050kb cpu 5%",
    "tc002-supervisor 42000 info metrics sample: mem 16049kb cpu 5%",
    "tc002-supervisor 47000 info metrics sample: mem 16047kb cpu 4%",
    "tc002-supervisor 52000 info metrics sample: mem 16044kb cpu 5%",
    "tc002-supervisor 57000 info metrics sample: mem 16040kb cpu 5%",
]


class Reject(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def load_or_create_tokens(path):
    if os.path.exists(path):
        data = open(path, "rb").read()
        if len(data) != 64:
            raise ValueError("token file must hold exactly 64 raw bytes")
    else:
        data = secrets.token_bytes(64)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    return data[:32].hex(), data[32:].hex()


def parse_ipv4(s):
    parts = s.split(".")
    if len(parts) != 4 or not all(p.isdigit() and 0 < len(p) <= 3 and int(p) <= 255 for p in parts):
        return None
    return s


def parse_colour(s):
    s = s[1:] if len(s) == 7 and s.startswith("#") else s
    if not re.fullmatch(r"[0-9a-fA-F]{6}", s):
        return None
    return s.lower()


class Device:
    def __init__(self, control, admin):
        self.control, self.admin = control, admin
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.boot_id = secrets.token_hex(4)
        self.epoch, self.revision = 1, 0
        self.base, self.generator, self.brightness = "art", "popsquares", 100
        self.power = True
        self.overlay, self.overlay_until = "none", 0.0
        self.presented_base, self.presented_at = 0, self.started
        self.restarts = 0
        self.log_seq = 0
        self.log_lines = []
        for line in SEED_LOG_LINES:
            self._append_log(line)
        self.config = {"revision": 0, "saved_revision": 0, "brightness": 100, "base": "art", "generator": "popsquares",
                       "timezone": "UTC0", "ntp_server": None, "ntp_interval_s": 300, "frame_timeout_ms": 500,
                       "metrics_interval_s": 30, "discovery": False, "discovery_prefix": "homeassistant", "origins": []}
        self.mqtt = {"enabled": False, "host": "", "port": 1883, "username": "", "password": "", "client_id": "", "prefix": "", "tls": False}
        self.reconnects = 0

    # bookkeeping

    def bump(self):
        self.revision += 1
        return self.revision

    def tick(self):
        if self.overlay != "none" and time.monotonic() >= self.overlay_until:
            self.overlay = "none"
            self.bump()

    def presented(self):
        now = time.monotonic()
        if self.base == "art" and self.overlay == "none":
            self.presented_base += int((now - self.presented_at) * 60)
        self.presented_at = now
        return self.presented_base

    def restart(self):
        self.epoch += 1
        self.revision = 0
        self.overlay = "none"
        self.restarts += 1

    def set_overlay(self, kind, duration_s):
        self.overlay = kind
        self.overlay_until = time.monotonic() + duration_s
        return self.bump()

    def _append_log(self, text):
        self.log_seq += 1
        self.log_lines.append((self.log_seq, text))
        if len(self.log_lines) > 64:
            self.log_lines.pop(0)

    def log(self, text):
        ms = int((time.monotonic() - self.started) * 1000)
        self._append_log(f"tc002d {ms} info {text}")

    # documents

    def status(self):
        self.tick()
        fps = 59.9 if self.base == "art" and self.overlay == "none" else None
        return {"epoch": self.epoch, "revision": self.revision, "renderer": "running", "base": self.base,
                "generator": self.generator, "overlay": self.overlay, "brightness": self.brightness,
                "power": self.power,
                "presented": self.presented(), "fps": fps, "uptime_s": int(time.monotonic() - self.started),
                "memory_available_kb": 16084, "cpu_pct": 5, "restarts": self.restarts,
                "network": {"ip": "10.0.0.111"}, "time": {"state": "unsynced", "age_s": None},
                "config_revision": self.config["revision"], "saved_revision": self.config["saved_revision"],
                "transport": "plaintext", "mqtt": self.mqtt_status(), "boot_id": self.boot_id, "sample_age_ms": 200}

    def logs(self, after):
        lines = [{"seq": s, "text": t} for s, t in self.log_lines if s > after][:16]
        next_seq = lines[-1]["seq"] if lines else after
        return {"next": next_seq, "lines": lines}

    def config_doc(self):
        c = self.config
        return {"revision": c["revision"], "saved_revision": c["saved_revision"], "brightness": c["brightness"],
                "base": c["base"], "generator": c["generator"], "timezone": c["timezone"],
                "ntp": {"server": c["ntp_server"], "interval_s": c["ntp_interval_s"]},
                "frame_timeout_ms": c["frame_timeout_ms"], "metrics_interval_s": c["metrics_interval_s"],
                "discovery": {"enabled": c["discovery"], "prefix": c["discovery_prefix"]}, "allowed_origins": list(c["origins"])}

    def mqtt_doc(self):
        m = self.mqtt
        return {"enabled": m["enabled"], "host": m["host"], "port": m["port"], "username": m["username"],
                "client_id": m["client_id"], "prefix": m["prefix"] or "tc002", "tls": m["tls"], "password_set": bool(m["password"])}

    def mqtt_status(self):
        m = self.mqtt
        if m["enabled"] and m["host"] and not m["tls"]:
            return {"enabled": True, "connected": True, "state": "connected", "reconnect_delay_s": 0, "reconnects": self.reconnects, "last_error": ""}
        if m["enabled"] and m["tls"]:
            return {"enabled": True, "connected": False, "state": "disconnected", "reconnect_delay_s": 0, "reconnects": self.reconnects, "last_error": "tls is not available in this build"}
        return {"enabled": False, "connected": False, "state": "disconnected", "reconnect_delay_s": 0, "reconnects": self.reconnects, "last_error": ""}

    # commands (all validated; every accepted one bumps the renderer revision)

    def check_epoch(self, epoch, required):
        if epoch is None:
            if required:
                raise Reject(400, "missing_field", "a required field is absent")
            return
        if epoch != self.epoch:
            raise Reject(409, "stale_epoch", "the renderer epoch changed; read status and retry")

    def set_scene(self, body):
        base = body.get("base")
        if base not in BASES:
            raise Reject(400, "invalid_base", "base must be art, clock or ip")
        gen = body.get("generator")
        if gen is not None and gen not in GENERATORS:
            raise Reject(400, "invalid_generator", "unknown generator")
        self.check_epoch(body.get("epoch"), False)
        self.base, self.overlay = base, "none"
        if base == "art" and gen:
            self.generator = gen
        self.log(f"scene: {base}")
        return self.bump()

    def action(self, body):
        self.check_epoch(body.get("epoch"), True)
        kind = body.get("action")
        if kind == "brightness":
            v = body.get("brightness")
            if v is None:
                raise Reject(400, "missing_brightness", "brightness is required for that action")
            if not isinstance(v, int) or v < 1 or v > 100:
                raise Reject(400, "invalid_brightness", "brightness must be 1..100")
            self.brightness = v
            self.log(f"brightness: {v}")
            return self.bump()
        if kind == "reseed":
            self.log("reseed")
            return self.bump()
        if kind == "arm_stream":
            self.log("stream arming")
            return self.set_overlay("stream_arming", 2)
        if kind == "power":
            v = body.get("power")
            if not isinstance(v, bool):
                raise Reject(400, "invalid_power", "power must be true or false")
            self.power = v
            self.log(f"power: {'on' if v else 'off'}")
            return self.bump()
        raise Reject(400, "invalid_action", "unknown action")

    def notify(self, body):
        text = body.get("text", "")
        if not isinstance(text, str) or not PRINTABLE.match(text):
            raise Reject(400, "invalid_text", "text must be 1..128 printable ascii characters")
        d = body.get("duration_s", 5)
        if not isinstance(d, int) or d < 1 or d > 300:
            raise Reject(400, "invalid_duration", "duration_s must be 1..300")
        if body.get("colour") is not None and parse_colour(body["colour"]) is None:
            raise Reject(400, "invalid_colour", "colour must be rrggbb hex")
        self.check_epoch(body.get("epoch"), True)
        self.log("notification")
        return self.set_overlay("notify", d)

    def input(self, body):
        control = body.get("control")
        if control not in CONTROL_EVENTS:
            raise Reject(400, "invalid_control", "control must be left, middle, right, knob or rotary")
        event = body.get("event")
        if event not in CONTROL_EVENTS[control]:
            raise Reject(400, "invalid_event", "that event is not valid for this control")
        steps = body.get("steps", 1)
        if event in STEPPED_EVENTS:
            if not isinstance(steps, int) or isinstance(steps, bool) or not 1 <= steps <= 16:
                raise Reject(400, "invalid_steps", "steps must be 1..16")
        self.check_epoch(body.get("epoch"), True)
        self.log(f"input: {control} {event}")
        if event == "long":
            # knob long press: arm streaming, as a physical hold would
            return self.set_overlay("stream_arming", 2)
        if event in ("click", "release"):
            if control in ("left", "middle", "right"):
                self.base = {"left": "art", "middle": "clock", "right": "ip"}[control]
                self.overlay = "none"
            elif control == "knob" and self.base == "art":
                pass  # reseed the art; the mock does not track a seed to change
        elif event in STEPPED_EVENTS:
            if self.base == "art":
                idx = GENERATORS.index(self.generator)
                idx = (idx + steps) % len(GENERATORS) if event == "cw" else (idx - steps) % len(GENERATORS)
                self.generator = GENERATORS[idx]
            else:
                delta = 5 * steps if event == "cw" else -5 * steps
                self.brightness = max(1, min(100, self.brightness + delta))
        # event == "press": no effect, still an accepted input
        return self.bump()

    def frame(self, query, body):
        if len(body) != 2496:
            raise Reject(400, "invalid_frame", "a frame is exactly 2496 rgb888 bytes")
        try:
            d = int(query["duration_s"][0])
        except (KeyError, ValueError):
            raise Reject(400, "missing_duration", "duration_s is required in the query")
        if d < 1 or d > 300:
            raise Reject(400, "invalid_duration", "duration_s must be 1..300")
        rid = query.get("request_id", [""])[0]
        if not HEX_ID.match(rid):
            raise Reject(400, "missing_request_id", "request_id (hex) is required in the query")
        try:
            epoch = int(query["epoch"][0])
        except (KeyError, ValueError):
            raise Reject(400, "missing_epoch", "epoch is required in the query")
        self.check_epoch(epoch, True)
        return self.set_overlay("frame", d), rid

    def patch_config(self, body):
        c = self.config
        want = body.get("expected_revision")
        if want is not None and want != c["revision"]:
            raise Reject(409, "revision_conflict", "the expected revision does not match")
        nxt = dict(c)
        if "brightness" in body:
            if not isinstance(body["brightness"], int) or not 1 <= body["brightness"] <= 100:
                raise Reject(400, "invalid_brightness", "brightness must be 1..100")
            nxt["brightness"] = body["brightness"]
        if "base" in body:
            if body["base"] not in BASES:
                raise Reject(400, "invalid_base", "base must be art, clock or ip")
            nxt["base"] = body["base"]
        if "generator" in body:
            if body["generator"] not in GENERATORS:
                raise Reject(400, "invalid_generator", "unknown generator")
            nxt["generator"] = body["generator"]
        if "timezone" in body:
            if not isinstance(body["timezone"], str) or not 1 <= len(body["timezone"]) <= 64:
                raise Reject(400, "invalid_timezone", "timezone must be 1..64 characters")
            nxt["timezone"] = body["timezone"]
        if "ntp_server" in body and body["ntp_server"] is not None:
            if parse_ipv4(str(body["ntp_server"])) is None:
                raise Reject(400, "invalid_ntp_server", "ntp_server must be a dotted ipv4 address")
            nxt["ntp_server"] = body["ntp_server"]
        # a null ntp_server is silently ignored, not stored: the device's patch struct has a plain
        # optional string field, so it cannot tell an explicit null from an absent field and keeps
        # the old value either way; the mock matches that instead of clearing it to none
        if "ntp_interval_s" in body:
            if body["ntp_interval_s"] not in (300, 600):
                raise Reject(400, "invalid_ntp_interval", "ntp_interval_s must be 300 or 600")
            nxt["ntp_interval_s"] = body["ntp_interval_s"]
        if "frame_timeout_ms" in body:
            if not isinstance(body["frame_timeout_ms"], int) or not 100 <= body["frame_timeout_ms"] <= 2000:
                raise Reject(400, "invalid_frame_timeout", "frame_timeout_ms must be 100..2000")
            nxt["frame_timeout_ms"] = body["frame_timeout_ms"]
        if "metrics_interval_s" in body:
            v = body["metrics_interval_s"]
            if not isinstance(v, int) or (v != 0 and not 10 <= v <= 3600):
                raise Reject(400, "invalid_metrics_interval", "metrics_interval_s must be 0 (off) or 10..3600")
            nxt["metrics_interval_s"] = v
        if "discovery" in body:
            if not isinstance(body["discovery"], bool):
                raise Reject(400, "invalid_json", "the body is not valid json for this schema")
            nxt["discovery"] = body["discovery"]
        if "discovery_prefix" in body:
            if not isinstance(body["discovery_prefix"], str) or not 1 <= len(body["discovery_prefix"]) <= 64:
                raise Reject(400, "invalid_discovery_prefix", "discovery_prefix must be 1..64 characters")
            nxt["discovery_prefix"] = body["discovery_prefix"]
        nxt["revision"] = c["revision"] + 1
        self.config = nxt
        # live effects, as the supervisor applies them
        if nxt["brightness"] != c["brightness"]:
            self.brightness = nxt["brightness"]; self.bump()
        if nxt["base"] != c["base"] or nxt["generator"] != c["generator"]:
            self.base, self.generator, self.overlay = nxt["base"], nxt["generator"], "none"; self.bump()

    def save_config(self, body):
        want = body.get("revision")
        if want is not None and want != self.config["revision"]:
            raise Reject(409, "revision_conflict", "the expected revision does not match")
        self.config["saved_revision"] = self.config["revision"]
        return self.config["saved_revision"]

    def put_mqtt(self, body):
        m = dict(self.mqtt)
        if "host" in body:
            if not isinstance(body["host"], str) or not 1 <= len(body["host"]) <= 64 or parse_ipv4(body["host"]) is None:
                raise Reject(400, "invalid_host", "host must be a dotted ipv4 address in this profile")
            m["host"] = body["host"]
        if "port" in body:
            if not isinstance(body["port"], int) or not 1 <= body["port"] <= 65535:
                raise Reject(400, "invalid_port", "port must be 1..65535")
            m["port"] = body["port"]
        for k in ("username", "password", "client_id", "prefix"):
            if k in body:
                if not isinstance(body[k], str) or len(body[k]) > 64:
                    raise Reject(400, f"invalid_{k}", f"{k} must be at most 64 characters")
                m[k] = body[k]
        for k in ("enabled", "tls"):
            if k in body:
                if not isinstance(body[k], bool):
                    raise Reject(400, "invalid_json", "the body is not valid json for this schema")
                m[k] = body[k]
        if m["enabled"] and not m["host"]:
            raise Reject(400, "rejected", "the settings were rejected")
        self.mqtt = m
        self.config["revision"] += 1


# request schemas: allowed and required keys, as the runtime's strict json enforces
SCHEMAS = {
    "scene": ({"base", "generator", "seed", "request_id", "epoch"}, {"base", "request_id"}),
    "action": ({"action", "brightness", "seed", "power", "request_id", "epoch"}, {"action", "request_id", "epoch"}),
    "input": ({"control", "event", "steps", "request_id", "epoch"}, {"control", "event", "request_id", "epoch"}),
    "notify": ({"text", "colour", "duration_s", "request_id", "epoch"}, {"text", "request_id", "epoch"}),
    "config": ({"brightness", "base", "generator", "timezone", "ntp_server", "ntp_interval_s", "frame_timeout_ms",
                "metrics_interval_s", "discovery", "discovery_prefix", "expected_revision"}, set()),
    "config/save": ({"revision"}, set()),
    "mqtt": ({"enabled", "host", "port", "username", "password", "client_id", "prefix", "tls"}, set()),
}

ROUTES = {("GET", "status"): "control", ("GET", "scenes"): "control", ("PUT", "scene"): "control",
          ("POST", "action"): "control", ("POST", "input"): "control", ("GET", "logs"): "control",
          ("GET", "config"): "control", ("PATCH", "config"): "admin",
          ("POST", "config/save"): "admin", ("POST", "notify"): "control", ("POST", "frame"): "control",
          ("GET", "mqtt"): "admin", ("PUT", "mqtt"): "admin", ("GET", "mqtt/status"): "control"}


def route_lookup(method, endpoint):
    """(authority, known) for an endpoint, mirroring the runtime's route(): stream routes are a
    path family (`streams`, `streams/{id}`, `streams/{id}/palette`) matched by pattern, not by an
    exact (method, endpoint) pair, so they cannot live in the ROUTES table."""
    if endpoint == "streams":
        return ("control" if method == "POST" else None), True
    if endpoint.startswith("streams/"):
        rest = endpoint[len("streams/"):]
        if "/" not in rest:
            return ("control" if method == "DELETE" else None), True
        if rest.endswith("/palette"):
            return ("control" if method == "PUT" else None), True
        return None, True
    known = {e for _, e in ROUTES}
    return ROUTES.get((method, endpoint)), endpoint in known


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, status, obj):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, status, code, message, rid=0):
        self._send(status, {"error": code, "message": message, "request_id": "%016x" % rid})

    def _applied(self, revision, rid):
        self._send(200, {"status": "applied", "revision": revision, "epoch": self.server.device.epoch, "request_id": "%016x" % rid})

    def _json_body(self, schema):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        if n > 4096:
            raise Reject(413, "body_too_large", "json bodies are limited to 4096 bytes")
        ct = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ct != "application/json":
            raise Reject(415, "unsupported_media_type", "this route takes application/json")
        if not raw and schema in ("config/save",):
            return {}
        try:
            body = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise Reject(400, "invalid_json", "the body is not valid json for this schema")
        if not isinstance(body, dict):
            raise Reject(400, "invalid_json", "the body is not valid json for this schema")
        allowed, required = SCHEMAS[schema]
        if set(body) - allowed:
            raise Reject(400, "unknown_field", "the body contains a field the schema does not define")
        if required - set(body):
            raise Reject(400, "missing_field", "a required field is absent")
        return body

    def _rid(self, body):
        rid = body.get("request_id", "")
        if not isinstance(rid, str) or not HEX_ID.match(rid):
            raise Reject(400, "invalid_request_id", "request_id must be 1..16 hex digits")
        return int(rid, 16)

    def _handle(self, method):
        d = self.server.device
        u = urlsplit(self.path)
        path, query = u.path, parse_qs(u.query)
        if path == "/mock/restart" and method == "POST":
            with d.lock:
                d.restart()
            return self._send(200, {"epoch": d.epoch})
        if not path.startswith("/api/v1/"):
            return self._error(404, "not_found", "no such route")
        endpoint = path[len("/api/v1/"):]
        if self.headers.get("Origin"):
            return self._error(403, "origin_denied", "this origin is not allowed")
        need, known = route_lookup(method, endpoint)
        if need is None:
            return self._error(405 if known else 404, "method_not_allowed" if known else "not_found",
                               "this route does not accept that method" if known else "no such route")
        auth = self.headers.get("Authorization") or ""
        have = "admin" if auth == f"Bearer {d.admin}" else "control" if auth == f"Bearer {d.control}" else None
        if have is None:
            return self._error(401, "unauthorized", "a valid bearer token is required")
        if need == "admin" and have != "admin":
            return self._error(403, "forbidden", "this route requires the admin token")
        if endpoint == "streams" or endpoint.startswith("streams/"):
            return self._error(503, "not_implemented", "stream sessions are not available in this release")
        try:
            with d.lock:
                if endpoint == "status":
                    return self._send(200, d.status())
                if endpoint == "scenes":
                    return self._send(200, SCENES)
                if endpoint == "scene":
                    body = self._json_body("scene"); rid = self._rid(body)
                    return self._applied(d.set_scene(body), rid)
                if endpoint == "action":
                    body = self._json_body("action"); rid = self._rid(body)
                    return self._applied(d.action(body), rid)
                if endpoint == "input":
                    body = self._json_body("input"); rid = self._rid(body)
                    return self._applied(d.input(body), rid)
                if endpoint == "logs":
                    raw = query.get("after", [None])[0]
                    if raw is None or not raw.isdigit():
                        raise Reject(400, "invalid_after", "after must be a non-negative integer")
                    return self._send(200, d.logs(int(raw)))
                if endpoint == "notify":
                    body = self._json_body("notify"); rid = self._rid(body)
                    return self._applied(d.notify(body), rid)
                if endpoint == "frame":
                    ct = (self.headers.get("Content-Type") or "").strip().lower()
                    if ct != "application/octet-stream":
                        raise Reject(415, "unsupported_media_type", "frames are application/octet-stream")
                    n = int(self.headers.get("Content-Length") or 0)
                    rev, rid = d.frame(query, self.rfile.read(n))
                    return self._applied(rev, int(rid, 16))
                if endpoint == "config" and method == "GET":
                    return self._send(200, d.config_doc())
                if endpoint == "config":
                    d.patch_config(self._json_body("config"))
                    return self._send(200, d.config_doc())
                if endpoint == "config/save":
                    saved = d.save_config(self._json_body("config/save"))
                    return self._send(200, {"status": "saved", "saved_revision": saved})
                if endpoint == "mqtt" and method == "GET":
                    return self._send(200, d.mqtt_doc())
                if endpoint == "mqtt":
                    d.put_mqtt(self._json_body("mqtt"))
                    return self._send(200, d.mqtt_doc())
                if endpoint == "mqtt/status":
                    return self._send(200, d.mqtt_status())
        except Reject as e:
            return self._error(e.status, e.code, e.message)
        return self._error(404, "not_found", "no such route")

    def do_GET(self): self._handle("GET")
    def do_POST(self): self._handle("POST")
    def do_PUT(self): self._handle("PUT")
    def do_PATCH(self): self._handle("PATCH")
    def do_DELETE(self): self._handle("DELETE")

    def log_message(self, fmt, *a):
        sys.stderr.write("  mock %s\n" % (fmt % a))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def make_server(port, device):
    server = Server(("127.0.0.1", port), Handler)
    server.device = device
    return server


def main(argv):
    port = int(argv[argv.index("--port") + 1]) if "--port" in argv else 8080
    path = argv[argv.index("--token-file") + 1] if "--token-file" in argv else "mock-tokens"
    control, admin = load_or_create_tokens(path)
    with make_server(port, Device(control, admin)) as httpd:
        print(f"mock tc002 runtime on http://127.0.0.1:{port}/api/v1  tokens in {path}  (POST /mock/restart bumps the epoch)", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, ValueError) as e:
        sys.exit(f"mock-device.py: {e}")
