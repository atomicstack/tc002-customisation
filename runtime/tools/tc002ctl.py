#!/usr/bin/env python3
"""tc002ctl: host client for the custom runtime's /api/v1 (plaintext isolated-lan profile).

usage:
  tc002ctl.py -s <device-ip> [--token-file FILE | --token HEX] <command> [args]

commands:
  status                              renderer, network, time, mqtt state
  scenes                              scene and generator catalogue
  scene <art|clock|ip> [--generator NAME] [--seed N]
  brightness <1..100>                 transient brightness
  reseed [N]                          reseed the art
  arm-stream                          arm stream mode (two-second wait)
  notify <text> [--colour rrggbb] [--duration S]
  frame <file.rgb|--colour rrggbb> [--duration S]   2496 raw rgb888 bytes
  config                              effective settings (admin token needed for patch/save)
  config-set key=value ...            patch settings; keys: brightness base generator timezone ntp_server
                                      ntp_interval_s frame_timeout_ms metrics_interval_s discovery discovery_prefix
  config-save [revision]              write the settings file, optionally only at that revision
  mqtt                                broker settings (password never returned)
  mqtt-set key=value ...              keys: enabled host port username password client_id prefix tls
  mqtt-status                         connection state

the token file holds 64 raw bytes (control token then admin token) as written by the supervisor,
or 64 hex characters of one token. everything travels in plain http on this profile: an observer
on the network can read the token. use it only on an isolated lan.
"""
import argparse, json, os, secrets, sys, urllib.error, urllib.request

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
    a = ap.parse_args()
    admin_commands = {"config-set", "config-save", "mqtt", "mqtt-set"}
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
        return show(*call(a, "PUT", "/scene", body, token=token))
    if c in ("brightness", "reseed", "arm-stream"):
        body = {"action": {"brightness": "brightness", "reseed": "reseed", "arm-stream": "arm_stream"}[c], "request_id": rid, "epoch": epoch(a, token)}
        if c == "brightness": body["brightness"] = int(a.args[0])
        if c == "reseed" and a.args: body["seed"] = int(a.args[0])
        return show(*call(a, "POST", "/action", body, token=token))
    if c == "notify":
        body = {"text": " ".join(a.args), "duration_s": a.duration, "request_id": rid, "epoch": epoch(a, token)}
        if a.colour: body["colour"] = a.colour
        return show(*call(a, "POST", "/notify", body, token=token))
    if c == "frame":
        if a.colour:
            rgb = bytes.fromhex(a.colour) * 832
        else:
            rgb = open(a.args[0], "rb").read()
        if len(rgb) != 2496:
            sys.exit("a frame is exactly 2496 bytes")
        q = f"duration_s={a.duration}&request_id={rid}&epoch={epoch(a, token)}"
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
    if c == "mqtt-set":
        return show(*call(a, "PUT", "/mqtt", kv(a.args), token=token))
    if c == "mqtt-status":
        return show(*call(a, "GET", "/mqtt/status", token=token))
    sys.exit(f"unknown command {c}")

if __name__ == "__main__":
    sys.exit(main())
