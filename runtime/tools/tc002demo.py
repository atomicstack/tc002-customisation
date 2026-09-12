#!/usr/bin/env python3
"""shared helpers for the canvas demo scripts (tc002-demo-*.py): the request wrappers, the
argument parser they all take, and the save-and-restore that puts the panel back as it was.

not a demo itself. each demo imports this, declares a reel of steps and plays it.

note on flash: `PUT /canvas` is a durable change, so every step of a demo writes the document to
`config/canvas.bin` (a value `PATCH` does not). a demo run is a few dozen small writes to jffs2,
which is the same order as a session with the settings menu; it is worth knowing, not worrying
about.
"""
import argparse, json, os, secrets, sys, time

# one heartbeat and a little: how long the renderer takes to report a scene change back
settle = 0.4

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002ctl  # noqa: e402  (the request and token helpers of the host client)


def die(name, msg):
    sys.exit(f"{name}: {msg}")


class Device:
    """the canvas routes, with the token handling and error reporting done once"""

    def __init__(self, args, name):
        self.args = args
        self.name = name
        self.control = tc002ctl.load_token(args, False)
        self.admin = tc002ctl.load_token(args, True)

    def request(self, method, path, body=None, admin=False, raw_body=None):
        token = self.admin if admin else self.control
        if raw_body is not None:
            status, raw = tc002ctl.call(self.args, method, path, raw_body, content_type="application/octet-stream", token=token)
        else:
            status, raw = tc002ctl.call(self.args, method, path, body, token=token)
        if status != 200:
            detail = raw.decode(errors="replace")[:160]
            try:
                doc = json.loads(raw)
                detail = f"{doc.get('error')}: {doc.get('message')}"
            except ValueError:
                pass
            die(self.name, f"{method} {path} failed ({status}) {detail}")
        return json.loads(raw) if raw else {}

    # the canvas
    def put(self, elements):
        return self.request("PUT", "/canvas", {"elements": elements}, admin=True)

    def patch(self, values):
        return self.request("PATCH", "/canvas", {"values": values})

    def get(self):
        return self.request("GET", "/canvas")

    def clear(self):
        return self.request("DELETE", "/canvas")

    # pictures
    def put_sprite(self, sprite_id, rgb):
        return self.request("PUT", f"/sprites/{sprite_id}", raw_body=bytes(rgb), admin=True)

    def delete_sprite(self, sprite_id):
        return self.request("DELETE", f"/sprites/{sprite_id}")

    def sprites(self):
        return self.request("GET", "/sprites")

    def icons(self):
        return self.request("GET", "/icons")

    # the panel itself
    def show_canvas(self):
        self.request("PUT", "/scene", {"base": "canvas", "request_id": secrets.token_hex(8)})

    def status(self):
        return self.request("GET", "/status")


def parser(description):
    """the arguments every canvas demo takes"""
    ap = argparse.ArgumentParser(description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--server", required=True, help="device ip or ip:port")
    ap.add_argument("--token", help="64 hex characters of one token")
    ap.add_argument("--token-file", help="the 64-byte token file the supervisor wrote")
    ap.add_argument("--admin", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--hold", type=float, default=3.0, help="seconds each step stays on the panel (default 3)")
    ap.add_argument("--only", help="a comma-separated subset of steps, played in that order")
    ap.add_argument("--loop", action="store_true", help="play again until interrupted")
    ap.add_argument("--list", action="store_true", help="print the reel and exit")
    return ap


def pick(name, reel, only):
    """--only over a reel of (name, ...) tuples, keeping the order given"""
    if not only:
        return reel
    by_name = {step[0]: step for step in reel}
    steps = []
    for want in only.split(","):
        want = want.strip()
        if not want:
            continue
        if want not in by_name:
            die(name, f"unknown step {want!r}; this reel has {', '.join(by_name)}")
        steps.append(by_name[want])
    if not steps:
        die(name, "--only names no steps")
    return steps


def run(name, description, reel, step_fn, extra_setup=None, extra_teardown=None, extra_args=None):
    """the shape every demo shares: save what is showing, play the reel, put it all back.

    `step_fn(device, step, args)` draws one step and returns a line to print under its name.
    `reel` is a list of steps, or a function of (device, args) for a demo whose reel comes from the
    device -- the icons, for instance, are whatever that build actually has. a callable reel does
    its own `--only` filtering, since only it knows what the names mean.
    """
    ap = parser(description)
    if extra_args:
        extra_args(ap)
    args = ap.parse_args()
    dev_for_reel = None
    if callable(reel):
        dev_for_reel = Device(args, name)
        reel = reel(dev_for_reel, args)
    else:
        reel = pick(name, reel, args.only)
    if args.list:
        for step in reel:
            print(f"  {step[0]:<14} {step[1]}")
        return 0
    if args.hold <= 0:
        die(name, "--hold must be positive")

    dev = dev_for_reel or Device(args, name)
    # `/status` comes from the renderer's 250 ms heartbeat, so a reading taken the instant another
    # demo put its scene back is stale -- and saving a stale base means restoring the wrong one.
    time.sleep(settle)
    status = dev.status()
    if status.get("power") is False:
        print("note: the display is off, so this will play unseen (tc002ctl.py power on)")
    was_base = status.get("base", "clock")
    was_canvas = dev.get().get("elements", [])
    print(f"{name}: {len(reel)} steps, {args.hold:g} s each; the panel is on {was_base}")
    if was_canvas:
        print(f"  (a canvas of {len(was_canvas)} elements is already there; it goes back at the end)")

    try:
        if extra_setup:
            extra_setup(dev)
        dev.show_canvas()
        while True:
            for step in reel:
                detail = step_fn(dev, step, args)
                print(f"  {step[0]:<14} {detail or step[1]}")
                time.sleep(args.hold)
            if not args.loop:
                break
            print("  again")
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        if extra_teardown:
            try:
                extra_teardown(dev)
            except SystemExit:
                pass
        # the document as it was: `GET /canvas` answers in the shape a `PUT` takes, so this is
        # exactly what was there, values and all
        if was_canvas:
            dev.put(was_canvas)
        else:
            dev.clear()
        dev.request("PUT", "/scene", {"base": was_base, "request_id": secrets.token_hex(8)})
        time.sleep(settle)  # and leave it settled, so the next demo reads the truth
        print(f"  put back: {was_base}" + (f" and the canvas that was there" if was_canvas else ""))
    return 0
