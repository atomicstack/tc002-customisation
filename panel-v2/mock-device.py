#!/usr/bin/python3
"""a stand-in for the tc002 custom runtime's /api/v1, for developing and screenshotting panel-v2
without a device. bearer auth, epoch and revision bookkeeping, overlays that expire, settings with
revisions and conflicts, mqtt settings, the clock style (durable defaults and the transient scene block);
error bodies in the runtime's shape. not the runtime.

usage: mock-device.py [--port 8080] [--token-file FILE]
  --token-file   64 raw bytes (control token then admin token); created with random tokens when
                 the file does not exist, so `serve.py --token-file` can read the same file.
  POST /mock/restart (no auth) bumps the epoch, like a renderer restart.
  POST /mock/persist {"enabled":bool} (no auth) turns the write to flash off, the one thing that
                 can leave revision ahead of saved_revision.

binds 127.0.0.1. point the console at 127.0.0.1:<port>.
"""
import http.server, json, os, re, secrets, socketserver, sys, threading, time
from urllib.parse import urlsplit, parse_qs

BASES = ["art", "clock", "ip"]
GENERATORS = ["popsquares", "plasma", "cube"]
CUBE_PARAMS = [
    {"name": "palette", "kind": "choice", "default": 0, "choices": ["mono", "poly"]},
    {"name": "colour", "kind": "colour", "default": 0x30a0ff},
    {"name": "hue drift", "kind": "number", "default": 0, "min": 0, "max": 60, "step": 5},
    {"name": "background", "kind": "colour", "default": 0},
    {"name": "spin", "kind": "choice", "default": 2, "choices": ["single", "series", "parallel"]},
    {"name": "speed", "kind": "number", "default": 6, "min": 1, "max": 20, "step": 1},
    {"name": "zoom", "kind": "number", "default": 100, "min": 40, "max": 200, "step": 10},
]
CLOCK_FONTS = ["classic", "mini", "segment", "big", "block", "hires"]
IP_MODES = ["lines", "mini", "scroll", "big"]
CLOCK_COLOUR_MODES = ["solid", "gradient"]
CLOCK_GRADIENTS = ["horizontal", "vertical", "diagonal"]
CLOCK_DIGITS = ["solid", "outline", "shadow"]   # only the faces with a body (block, big) honour it
CLOCK_MAX_SPREAD = 255          # the clamp is the `spread` parameter now, not a fixed 96
DEFAULT_SPREAD = 255
DEFAULT_CLOCK = {"font": "classic", "colour_mode": "solid", "colour": "ffffff", "colour2": "ffffff",
                 "gradient": "horizontal", "spread": DEFAULT_SPREAD, "digits": "solid"}


def choice(name, choices, default=0):
    return {"name": name, "kind": "choice", "default": default, "choices": list(choices)}
# every scene declares what it can be told; popsquares and plasma declare nothing of their own
SCENES = {"bases": BASES,
          "generators": [{"index": 0, "name": "popsquares", "parameters": []},
                         {"index": 1, "name": "plasma", "parameters": []},
                         {"index": 2, "name": "cube", "parameters": CUBE_PARAMS}],
          "parameters": {
              "art": [choice("scene", GENERATORS)],
              "clock": [choice("face", CLOCK_FONTS), {"name": "colour", "kind": "colour", "default": 0xffffff},
                        choice("shade", CLOCK_COLOUR_MODES), {"name": "colour 2", "kind": "colour", "default": 0xffffff},
                        choice("gradient", CLOCK_GRADIENTS),
                        {"name": "spread", "kind": "number", "default": DEFAULT_SPREAD, "min": 0, "max": 255, "step": 15},
                        choice("digits", CLOCK_DIGITS)],
              "ip": [choice("layout", IP_MODES)],
          },
          "clock": {"fonts": CLOCK_FONTS, "colour_modes": CLOCK_COLOUR_MODES, "gradients": CLOCK_GRADIENTS,
                    "spread": [0, 255], "max_spread": CLOCK_MAX_SPREAD},
          "ip": {"modes": IP_MODES},
          "notify": {"text_max": 128, "duration_s": [1, 300]}, "frame": {"bytes": 2496, "duration_s": [1, 300]},
          "transitions": {"effects": ["fade", "cut", "slide", "swipe_out", "swipe_in", "collapse", "expand", "wipe", "dissolve",
                                      "split_out", "split_in", "blinds", "flip", "rain", "rain_random"],
                          "directions": ["left", "right", "up", "down"], "exits": ["reverse", "same", "none"], "duration_ms": [0, 5000]}}
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


SETTING_TO_STYLE = {"digit": "digits"}


GENERATOR_PARAMS = {"popsquares": [], "plasma": [], "cube": CUBE_PARAMS}
MAX_PARAMS_PER_PATCH = 8


def param_default(p):
    """a parameter's default in the shape /config reports: a choice by name, a colour as six hex
    digits, a number in decimal, a toggle as on or off."""
    if p["kind"] == "choice":
        return p["choices"][p["default"]]
    if p["kind"] == "colour":
        return "%06x" % p["default"]
    if p["kind"] == "toggle":
        return "on" if p["default"] else "off"
    return p["default"]


def parse_param_value(p, text):
    """the value a patch sends, always a string, in the shape the report uses. None is a refusal."""
    if not isinstance(text, str):
        return None
    if p["kind"] == "choice":
        return text if text in p["choices"] else None
    if p["kind"] == "toggle":
        return "on" if text in ("on", "true") else "off" if text in ("off", "false") else None
    if p["kind"] == "colour":
        return parse_colour(text)
    try:
        v = int(text, 10)
    except ValueError:
        return None
    return v if p["min"] <= v <= p["max"] else None


def resolve_generator_params(entries):
    """validate a whole list before anything is written: an unknown scene, an unknown name or a
    value that does not fit its kind refuses the request and leaves the settings alone."""
    if not isinstance(entries, list):
        raise Reject(400, "invalid_json", "the body is not valid json for this schema")
    if len(entries) > MAX_PARAMS_PER_PATCH:
        raise Reject(400, "too_many_params", "at most eight generator parameters per request")
    out = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"scene", "name", "value"}:
            raise Reject(400, "invalid_json", "the body is not valid json for this schema")
        table = GENERATOR_PARAMS.get(entry["scene"])
        if table is None:
            raise Reject(400, "invalid_scene", "scene must name a generator")
        p = next((q for q in table if q["name"] == entry["name"]), None)
        if p is None:
            raise Reject(400, "invalid_param", "no such parameter on that scene")
        value = parse_param_value(p, entry["value"])
        if value is None:
            raise Reject(400, "invalid_param_value", "the value does not fit that parameter")
        out.append((entry["scene"], entry["name"], value))
    return out


def parse_clock_style(fields):
    """the clock style fields by their bare names (font, colour_mode, colour, colour2, gradient, spread),
    validated with the runtime's codes; shared by the scene block and the settings patch. the
    caller strips the `clock_` prefix of the settings keys. unknown keys are the scene block's
    strict schema."""
    out = {}
    for key, value in fields.items():
        if key == "font":
            if value not in CLOCK_FONTS:
                raise Reject(400, "invalid_font", "font must be classic, mini, segment or big")
        elif key == "colour_mode":
            if value not in CLOCK_COLOUR_MODES:
                raise Reject(400, "invalid_colour_mode", "colour_mode must be solid or gradient")
        elif key in ("colour", "colour2"):
            value = parse_colour(str(value))
            if value is None:
                raise Reject(400, "invalid_" + key, key + " must be rrggbb hex")
        elif key == "gradient":
            if value not in CLOCK_GRADIENTS:
                raise Reject(400, "invalid_gradient", "gradient must be horizontal, vertical or diagonal")
        elif key == "digits":
            if value not in CLOCK_DIGITS:
                raise Reject(400, "invalid_digits", "digits must be solid, outline or shadow")
        elif key == "spread":
            # a u8 on the wire, so anything outside 0..255 fails the device's json parse
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 255:
                raise Reject(400, "invalid_json", "the body is not valid json for this schema")
        else:
            raise Reject(400, "unknown_field", "the body contains a field the schema does not define")
        out[key] = value
    return out


class Device:
    def __init__(self, control, admin):
        self.control, self.admin = control, admin
        self.lock = threading.Lock()
        self.started = time.monotonic()
        self.boot_id = secrets.token_hex(4)
        self.epoch, self.revision = 1, 0
        self.base, self.generator, self.brightness = "art", "popsquares", 100
        self.power = True
        self.clock = dict(DEFAULT_CLOCK)   # the effective style: the durable defaults, or a transient scene block over them
        self.ip_mode = "lines"
        self.overlay, self.overlay_until = "none", 0.0
        self.presented_base, self.presented_at = 0, self.started
        self.restarts = 0
        self.log_seq = 0
        self.log_lines = []
        for line in SEED_LOG_LINES:
            self._append_log(line)
        self.config = {"revision": 0, "saved_revision": 0, "brightness": 100, "base": "art", "generator": "popsquares",
                       "timezone": "UTC0", "ntp_server": None, "ntp_interval_s": 300, "frame_timeout_ms": 500,
                       "metrics_interval_s": 30, "discovery": False, "discovery_prefix": "homeassistant", "origins": [],
                       "clock": dict(DEFAULT_CLOCK), "ip_mode": "lines",
                       "generators": {g: {p["name"]: param_default(p) for p in table}
                                      for g, table in GENERATOR_PARAMS.items()}}
        self.mqtt = {"enabled": False, "host": "", "port": 1883, "username": "", "password": "", "client_id": "", "prefix": "", "tls": False}
        self.ntfy = {"enabled": False, "url": "", "topic": "", "token": "", "username": "", "password": "", "duration_s": 10, "insecure": False, "ca": ""}
        self.ntfy_messages = 0
        # the device persists every accepted settings write before replying; off simulates that
        # write failing, which is the only way revision and saved_revision can drift apart
        self.persist = True
        self.reconnects = 0

    # bookkeeping

    def bump(self):
        self.revision += 1
        return self.revision

    def persist_settings(self):
        """every accepted settings write reaches flash before the reply, so saved_revision follows
        the revision on its own (RUNTIME.md, "settings, credentials, the listener")."""
        if self.persist:
            self.config["saved_revision"] = self.config["revision"]

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
        self.clock = dict(self.config["clock"])   # a fresh renderer gets the durable style
        self.ip_mode = self.config["ip_mode"]
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

    def log(self, text, proc="tc002d"):
        ms = int((time.monotonic() - self.started) * 1000)
        self._append_log(f"{proc} {ms} info {text}")

    # documents

    def status(self):
        self.tick()
        fps = 59.9 if self.base == "art" and self.overlay == "none" else None
        return {"epoch": self.epoch, "revision": self.revision, "renderer": "running", "base": self.base,
                "generator": self.generator, "overlay": self.overlay, "brightness": self.brightness,
                "power": self.power,
                "clock": dict(self.clock), "ip_mode": self.ip_mode,
                "presented": self.presented(), "fps": fps, "uptime_s": int(time.monotonic() - self.started),
                "memory_available_kb": 16084, "memory_total_kb": 35840, "memory_free_kb": 9216,
                "tmpfs_used_kb": 1024, "tmpfs_total_kb": 17920,
                "flash_used_kb": 2304, "flash_total_kb": 61440,
                "cpu_pct": 5, "restarts": self.restarts,
                "network": {"ip": "10.0.0.111"}, "time": {"state": "unsynced", "age_s": None},
                "config_revision": self.config["revision"], "saved_revision": self.config["saved_revision"],
                "transport": "plaintext", "mqtt": self.mqtt_status(), "ntfy": self.ntfy_doc()["status"],
                "boot_id": self.boot_id, "sample_age_ms": 200}

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
                "discovery": {"enabled": c["discovery"], "prefix": c["discovery_prefix"]}, "clock": dict(c["clock"]),
                "generators": {g: dict(v) for g, v in c["generators"].items()},
                "ip_mode": c["ip_mode"],
                "allowed_origins": list(c["origins"])}

    def mqtt_doc(self):
        m = self.mqtt
        return {"enabled": m["enabled"], "host": m["host"], "port": m["port"], "username": m["username"],
                "client_id": m["client_id"], "prefix": m["prefix"] or "tc002", "tls": m["tls"], "password_set": bool(m["password"])}

    def ntfy_doc(self):
        n = self.ntfy
        state = "subscribed" if n["enabled"] and n["url"] and n["topic"] else "off"
        return {"enabled": n["enabled"], "url": n["url"], "topic": n["topic"], "username": n["username"],
                "token_set": bool(n["token"]), "password_set": bool(n["password"]), "duration_s": n["duration_s"],
                "insecure": n["insecure"], "ca_set": bool(n["ca"]),
                "status": {"state": state, "messages": self.ntfy_messages, "error": ""}}

    def put_ntfy(self, body):
        n = dict(self.ntfy)
        for k in ("url", "topic", "token", "username", "password"):
            if k in body:
                if not isinstance(body[k], str) or len(body[k]) > 64:
                    raise Reject(400, f"invalid_{k}", f"{k} must be at most 64 characters")
                n[k] = body[k]
        if n["url"] and not (n["url"].startswith("http://") or n["url"].startswith("https://")):
            raise Reject(400, "invalid_url", "url must be http://host[:port][/prefix] or https://host[:port][/prefix]")
        if "duration_s" in body:
            if not isinstance(body["duration_s"], int) or not 1 <= body["duration_s"] <= 300:
                raise Reject(400, "invalid_duration", "duration_s must be 1..300")
            n["duration_s"] = body["duration_s"]
        for k in ("enabled", "insecure"):
            if k in body:
                if not isinstance(body[k], bool):
                    raise Reject(400, "invalid_json", "the body is not valid json for this schema")
                n[k] = body[k]
        if "ca" in body:
            ca = body["ca"]
            if not isinstance(ca, str) or len(ca) > 3500 or (ca and "-----BEGIN CERTIFICATE-----" not in ca):
                raise Reject(400, "invalid_ca", "ca must be a pem certificate of at most 3500 bytes, or empty to remove it")
            n["ca"] = ca
        if n["enabled"] and not (n["url"] and n["topic"]):
            raise Reject(400, "rejected", "the settings were rejected")
        self.ntfy = n
        self.config["revision"] += 1
        self.persist_settings()
        self.log(f"ntfy settings applied: enabled {n['enabled']} url {n['url']!r} topic {n['topic']!r}", proc="tc002-supervisor")

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
        block = body.get("clock")
        if block is not None and not isinstance(block, dict):
            raise Reject(400, "invalid_json", "the body is not valid json for this schema")
        style = parse_clock_style(block) if block else {}
        self.check_epoch(body.get("epoch"), False)
        self.base, self.overlay = base, "none"
        if base == "art" and gen:
            self.generator = gen
        # a transient restyle merges field by field over the effective style, whatever the base is
        self.clock.update(style)
        ipb = body.get("ip")
        if ipb is not None:
            if not isinstance(ipb, dict) or set(ipb) - {"mode"}:
                raise Reject(400, "invalid_json", "the body is not valid json for this schema")
            if "mode" in ipb:
                if ipb["mode"] not in IP_MODES:
                    raise Reject(400, "invalid_ip_mode", "ip mode must be lines, mini, scroll or big")
                self.ip_mode = ipb["mode"]
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
        if not isinstance(steps, int) or isinstance(steps, bool) or not 1 <= steps <= 16:
            raise Reject(400, "invalid_steps", "steps must be 1..16")
        if steps != 1 and event not in STEPPED_EVENTS:
            raise Reject(400, "invalid_steps", "steps applies to cw and ccw only")
        self.check_epoch(body.get("epoch"), True)
        self.log(f"input: {control} {event}")
        if event == "long":
            # knob long press: arm streaming, as a physical hold would
            return self.set_overlay("stream_arming", 2)
        if event in ("click", "release"):
            if control in ("left", "middle", "right"):
                self.base = {"left": "clock", "middle": "art", "right": "ip"}[control]
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
        self.log(f"frame {d} s")
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
        if "ip_mode" in body:
            if body["ip_mode"] not in IP_MODES:
                raise Reject(400, "invalid_ip_mode", "ip_mode must be lines, mini, scroll or big")
            nxt["ip_mode"] = body["ip_mode"]
            self.ip_mode = body["ip_mode"]
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
        resolved = resolve_generator_params(body["generator_params"]) if "generator_params" in body else []
        if resolved:
            gens = {g: dict(v) for g, v in c["generators"].items()}
            for scene_name, name, value in resolved:
                gens[scene_name][name] = value
            nxt["generators"] = gens
        clock_keys = {k: v for k, v in body.items() if k.startswith("clock_")}
        if clock_keys:
            # the settings call it clock_digit, the scene block calls it digits
            style = parse_clock_style({SETTING_TO_STYLE.get(k[len("clock_"):], k[len("clock_"):]): v
                                       for k, v in clock_keys.items()})
            nxt["clock"] = {**c["clock"], **style}
        nxt["revision"] = c["revision"] + 1
        self.config = nxt
        # live effects, as the supervisor applies them
        if nxt["brightness"] != c["brightness"]:
            self.brightness = nxt["brightness"]; self.bump()
        if nxt["base"] != c["base"] or nxt["generator"] != c["generator"]:
            self.base, self.generator, self.overlay = nxt["base"], nxt["generator"], "none"; self.bump()
        if nxt["clock"] != c["clock"]:
            # the supervisor sends the whole durable style, so a transient scene block is replaced
            self.clock = dict(nxt["clock"]); self.bump()
        self.persist_settings()
        self.log(f"configuration applied, revision {nxt['revision']}", proc="tc002-supervisor")

    def save_config(self, body):
        want = body.get("revision")
        if want is not None and want != self.config["revision"]:
            raise Reject(409, "revision_conflict", "the expected revision does not match")
        self.config["saved_revision"] = self.config["revision"]
        self.log(f"configuration saved, revision {self.config['saved_revision']}", proc="tc002-supervisor")
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
        self.persist_settings()
        self.log("mqtt settings applied", proc="tc002-netd")


# request schemas: allowed and required keys, as the runtime's strict json enforces
SCHEMAS = {
    "scene": ({"base", "generator", "seed", "clock", "ip", "transition", "direction", "transition_ms", "exit", "request_id", "epoch"}, {"base", "request_id"}),
    "action": ({"action", "brightness", "seed", "power", "request_id", "epoch"}, {"action", "request_id", "epoch"}),
    "input": ({"control", "event", "steps", "request_id", "epoch"}, {"control", "event", "request_id", "epoch"}),
    "notify": ({"text", "colour", "duration_s", "transition", "direction", "transition_ms", "exit", "request_id", "epoch"}, {"text", "request_id", "epoch"}),
    "config": ({"brightness", "base", "generator", "timezone", "ntp_server", "ntp_interval_s", "frame_timeout_ms",
                "metrics_interval_s", "discovery", "discovery_prefix", "expected_revision",
                "clock_font", "clock_colour_mode", "clock_colour", "clock_colour2", "clock_gradient", "clock_spread",
                "clock_digit", "ip_mode", "generator_params"}, set()),
    "config/save": ({"revision"}, set()),
    "mock/persist": ({"enabled"}, {"enabled"}),
    "mqtt": ({"enabled", "host", "port", "username", "password", "client_id", "prefix", "tls"}, set()),
    "ntfy": ({"enabled", "url", "topic", "token", "username", "password", "duration_s", "insecure", "ca"}, set()),
}

ROUTES = {("GET", "status"): "control", ("GET", "scenes"): "control", ("PUT", "scene"): "control",
          ("POST", "action"): "control", ("POST", "input"): "control", ("GET", "logs"): "control",
          ("GET", "config"): "control", ("PATCH", "config"): "admin",
          ("POST", "config/save"): "admin", ("POST", "notify"): "control", ("POST", "frame"): "control",
          ("GET", "mqtt"): "admin", ("PUT", "mqtt"): "admin", ("GET", "mqtt/status"): "control",
          ("GET", "ntfy"): "admin", ("PUT", "ntfy"): "admin"}


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
        if path == "/mock/persist" and method == "POST":
            body = self._json_body("mock/persist")
            if not isinstance(body.get("enabled"), bool):
                return self._error(400, "invalid_json", "the body is not valid json for this schema")
            with d.lock:
                d.persist = body["enabled"]
                if d.persist:
                    d.persist_settings()
            return self._send(200, {"persist": d.persist})
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
                    raw = query.get("after", ["0"])[0]
                    if not raw.isdigit():
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
                if endpoint == "ntfy" and method == "GET":
                    return self._send(200, d.ntfy_doc())
                if endpoint == "ntfy":
                    d.put_ntfy(self._json_body("ntfy"))
                    return self._send(200, d.ntfy_doc())
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
