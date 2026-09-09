#!/usr/bin/env python3
"""tc002ctl: host client for the custom runtime's /api/v1 (plaintext isolated-lan profile).

usage:
  tc002ctl.py -s <device-ip> [--token-file FILE | --token HEX] <command> [args]

commands:
  status                              renderer, network, time, mqtt state
  scenes                              scene and generator catalogue
  scene <art|clock|ip> [--generator NAME] [--seed N]
        [--font classic|mini|segment|big|block|hires] [--colour-mode solid|gradient] [--colour rrggbb]
        [--colour2 rrggbb] [--gradient horizontal|vertical|diagonal] [--spread 0..255]   transient clock style
        [--transition EFFECT] [--direction left|right|up|down] [--transition-ms 0..5000]
        [--ip-mode lines|mini|scroll|big]   transient ip layout (two centred lines, one mini line,
                                            a scrolling line, big scrolling digits)
  brightness <1..100>                 transient brightness
  reseed [N]                          reseed the art
  arm-stream                          arm stream mode (two-second wait)
  notify <text> [--colour rrggbb] [--duration S] [--transition EFFECT] [--direction D] [--transition-ms N]
        [--exit reverse|same|none]
  frame <file.rgb|--colour rrggbb> [--duration S] [--transition EFFECT] [--direction D] [--transition-ms N]
        [--exit reverse|same|none]        2496 raw rgb888 bytes
  transition effects (scene, notify, frame): fade cut slide swipe_out swipe_in collapse expand wipe
                                      dissolve split_out split_in blinds flip rain rain_random; the
                                      direction is the way the moving content travels. --exit says how
                                      a notification or frame leaves: reverse (the paired effect backing
                                      out the way it came, default), same (the paired effect continuing
                                      the same way), none (a cut)
  power <on|off>                      display power (fades to and from black)
  input <control> <event> [--steps N] press a control remotely: left|middle|right|knob with
                                      press|release|click (knob also long); rotary with cw|ccw
  screen [--out FILE] [--ascii]       the framebuffer as shown: metadata, raw rgb to a file, or a preview
  logs [after] [--follow]             the log ring after a sequence number; --follow polls every second
  config                              effective settings (admin token needed for patch/save)
  config-set key=value ...            patch settings; keys: brightness base generator timezone ntp_server
                                      ntp_interval_s frame_timeout_ms metrics_interval_s discovery discovery_prefix
                                      clock_font clock_colour_mode clock_colour clock_colour2 clock_gradient
                                      clock_spread ip_mode; timezone takes a posix rule or an iana name (Europe/Amsterdam)
  config-save [revision]              write the settings file, optionally only at that revision
  mqtt                                broker settings (password never returned)
  mqtt-set key=value ...              keys: enabled host port username password client_id prefix tls
  ntfy                                the ntfy subscription: settings (no secrets) and live status
  ntfy-set key=value ... [--ca-file PEM]   keys: enabled url topic token username password duration_s
                                      insecure; --ca-file installs a pem certificate to trust as well as
                                      the built-in isrg root x1 (--ca-file '' removes it)
  mqtt-status                         connection state

the token file holds 64 raw bytes (control token then admin token) as written by the supervisor,
or 64 hex characters of one token. everything travels in plain http on this profile: an observer
on the network can read the token. use it only on an isolated lan.
"""
import argparse, base64, json, os, secrets, sys, time, urllib.error, urllib.request

def load_token(args, want_admin):
    if args.token:
        return args.token
    path = args.token_file or os.environ.get("TC002_TOKEN_FILE")
    if not path:
        sys.exit("a token is required: --token HEX or --token-file FILE (or TC002_TOKEN_FILE)")
    data = open(path, "rb").read()
    if len(data) == 64:
        return (data[32:] if want_admin else data[:32]).hex()
    text = data.decode().strip()
    if len(text) == 64:
        return text
    sys.exit("token file must hold 64 raw bytes (control+admin) or 64 hex characters")

def call(args, method, path, body=None, content_type="application/json", token=None, query=""):
    url = f"http://{args.server}/api/v1{path}{('?' + query) if query else ''}"
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

def show(status, raw):
    try:
        doc = json.loads(raw)
        print(json.dumps(doc, indent=2, sort_keys=True))
    except ValueError:
        print(raw.decode(errors="replace"))
    return 0 if status < 400 else 1

def epoch(args, token):
    status, raw = call(args, "GET", "/status", token=token)
    if status != 200:
        sys.exit(f"cannot read status ({status}): {raw.decode(errors='replace')}")
    return json.loads(raw)["epoch"]

def transition_fields(a):
    return {k: v for k, v in (("transition", a.transition), ("direction", a.direction), ("transition_ms", a.transition_ms), ("exit", a.exit)) if v is not None}

def kv(pairs):
    out = {}
    for p in pairs:
        if "=" not in p:
            sys.exit(f"expected key=value, got {p}")
        k, v = p.split("=", 1)
        if v in ("true", "false"):
            out[k] = v == "true"
        elif v.lstrip("-").isdigit():
            out[k] = int(v)
        else:
            out[k] = v
    return out

def main():
    ap = argparse.ArgumentParser(description="tc002 custom runtime client", usage=__doc__)
    ap.add_argument("-s", "--server", required=True, help="device ip or ip:port")
    ap.add_argument("--token")
    ap.add_argument("--token-file")
    ap.add_argument("--admin", action="store_true", help="use the admin token from the token file")
    ap.add_argument("command")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--generator")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--colour", default=None)
    ap.add_argument("--duration", type=int, default=5)
    ap.add_argument("--steps", type=int, default=1)
    ap.add_argument("--out")
    ap.add_argument("--ascii", action="store_true")
    ap.add_argument("--follow", action="store_true")
    ap.add_argument("--font")
    ap.add_argument("--colour-mode")
    ap.add_argument("--colour2")
    ap.add_argument("--gradient")
    ap.add_argument("--spread", type=int)
    ap.add_argument("--transition")
    ap.add_argument("--direction")
    ap.add_argument("--transition-ms", type=int, dest="transition_ms")
    ap.add_argument("--exit")
    ap.add_argument("--ip-mode", dest="ip_mode")
    ap.add_argument("--ca-file", dest="ca_file")
    a = ap.parse_args()
    admin_commands = {"config-set", "config-save", "mqtt", "mqtt-set", "ntfy", "ntfy-set"}
    token = load_token(a, a.admin or a.command in admin_commands)
    rid = secrets.token_hex(8)
    c = a.command
    if c == "status":
        return show(*call(a, "GET", "/status", token=token))
    if c == "scenes":
        return show(*call(a, "GET", "/scenes", token=token))
    if c == "scene":
        body = {"base": a.args[0], "request_id": rid}
        if a.generator: body["generator"] = a.generator
        if a.seed is not None: body["seed"] = a.seed
        style = {k: v for k, v in (("font", a.font), ("colour_mode", a.colour_mode), ("colour", a.colour), ("colour2", a.colour2), ("gradient", a.gradient), ("spread", a.spread)) if v is not None}
        if style: body["clock"] = style
        if a.ip_mode: body["ip"] = {"mode": a.ip_mode}
        body.update(transition_fields(a))
        return show(*call(a, "PUT", "/scene", body, token=token))
    if c in ("brightness", "reseed", "arm-stream"):
        body = {"action": {"brightness": "brightness", "reseed": "reseed", "arm-stream": "arm_stream"}[c], "request_id": rid, "epoch": epoch(a, token)}
        if c == "brightness": body["brightness"] = int(a.args[0])
        if c == "reseed" and a.args: body["seed"] = int(a.args[0])
        return show(*call(a, "POST", "/action", body, token=token))
    if c == "power":
        if not a.args or a.args[0] not in ("on", "off"):
            sys.exit("power takes on or off")
        body = {"action": "power", "power": a.args[0] == "on", "request_id": rid, "epoch": epoch(a, token)}
        return show(*call(a, "POST", "/action", body, token=token))
    if c == "input":
        if len(a.args) != 2:
            sys.exit("input takes <control> <event>")
        body = {"control": a.args[0], "event": a.args[1], "request_id": rid, "epoch": epoch(a, token)}
        if a.steps != 1: body["steps"] = a.steps
        return show(*call(a, "POST", "/input", body, token=token))
    if c == "screen":
        if a.out:
            status, raw = call(a, "GET", "/screen", token=token, query="format=raw")
            if status != 200:
                return show(status, raw)
            open(a.out, "wb").write(raw)
            print(f"wrote {len(raw)} bytes to {a.out}")
            return 0
        status, raw = call(a, "GET", "/screen", token=token)
        if status != 200:
            return show(status, raw)
        doc = json.loads(raw)
        rgb = base64.b64decode(doc.pop("rgb_base64"))
        lit = sum(1 for i in range(0, len(rgb), 3) if rgb[i] or rgb[i + 1] or rgb[i + 2])
        doc["lit_pixels"] = lit
        print(json.dumps(doc, indent=2, sort_keys=True))
        if a.ascii:
            w, h = doc["width"], doc["height"]
            for y in range(h):
                row = ""
                for x in range(w):
                    o = (y * w + x) * 3
                    row += f"\x1b[48;2;{rgb[o]};{rgb[o+1]};{rgb[o+2]}m  "
                print(row + "\x1b[0m")
        return 0
    if c == "logs":
        after = int(a.args[0]) if a.args else 0
        while True:
            status, raw = call(a, "GET", "/logs", token=token, query=f"after={after}")
            if status != 200:
                return show(status, raw)
            doc = json.loads(raw)
            for line in doc["lines"]:
                print(f"{line['seq']:6d} {line['text']}")
            if doc["lines"] and doc["next"] != after:
                after = doc["next"]
                continue  # more pages may follow
            if not a.follow:
                return 0
            time.sleep(1)
    if c == "notify":
        body = {"text": " ".join(a.args), "duration_s": a.duration, "request_id": rid, "epoch": epoch(a, token)}
        if a.colour: body["colour"] = a.colour
        body.update(transition_fields(a))
        return show(*call(a, "POST", "/notify", body, token=token))
    if c == "frame":
        if a.colour:
            rgb = bytes.fromhex(a.colour) * 832
        else:
            rgb = open(a.args[0], "rb").read()
        if len(rgb) != 2496:
            sys.exit("a frame is exactly 2496 bytes")
        q = f"duration_s={a.duration}&request_id={rid}&epoch={epoch(a, token)}"
        q += "".join(f"&{k}={v}" for k, v in transition_fields(a).items())
        return show(*call(a, "POST", "/frame", rgb, content_type="application/octet-stream", token=token, query=q))
    if c == "config":
        return show(*call(a, "GET", "/config", token=token))
    if c == "config-set":
        return show(*call(a, "PATCH", "/config", kv(a.args), token=token))
    if c == "config-save":
        body = {"revision": int(a.args[0])} if a.args else {}
        return show(*call(a, "POST", "/config/save", body, token=token))
    if c == "mqtt":
        return show(*call(a, "GET", "/mqtt", token=token))
    if c == "ntfy":
        return show(*call(a, "GET", "/ntfy", token=token))
    if c == "ntfy-set":
        body = kv(a.args)
        for key in ("enabled", "insecure"):
            if key in body and isinstance(body[key], str): body[key] = body[key].lower() in ("1", "true", "yes", "on")
        if "duration_s" in body and isinstance(body["duration_s"], str): body["duration_s"] = int(body["duration_s"])
        if a.ca_file is not None:
            body["ca"] = open(a.ca_file).read() if a.ca_file else ""
        return show(*call(a, "PUT", "/ntfy", body, token=token))
    if c == "mqtt-set":
        return show(*call(a, "PUT", "/mqtt", kv(a.args), token=token))
    if c == "mqtt-status":
        return show(*call(a, "GET", "/mqtt/status", token=token))
    sys.exit(f"unknown command {c}")

if __name__ == "__main__":
    sys.exit(main())
