#!/usr/bin/env python3
"""tc002-demo.py: a demo reel of every transition effect, played on the device over the http api
from this machine. each effect gets a scene change (clock <-> art) that arrives with the effect,
then a labelled notification that arrives with it and leaves with its paired exit the other way.
the reel ends by putting back the scene that was showing; durable settings are never touched.

  tc002-demo.py -s <device-ip> [--token-file FILE | --token HEX] [options]

  --ms N          transition duration in ms, 0..5000 (default 800)
  --exit MODE     how each notification leaves: reverse (the paired effect backing out the way it
                  came, default), same (the paired effect continuing the same way), none (a cut)
  --hold S        seconds each notification stays before it leaves, 1..300 (default 2)
  --only LIST     a comma-separated subset of effects, played in that order
  --loop          play the reel again until interrupted (ctrl-c restores the scene)
  --no-scenes     notifications only: leave the base scene alone
  --list          print the reel (effect, direction, label) and exit

labels are at most 8 characters so they sit still in the notification font (52 px wide, 6 px per
character); the terminal prints the full effect name as each step plays.
"""
import argparse, json, os, secrets, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002ctl  # noqa: e402  (the request and token helpers of the host client)

# effect, direction (none = the effect's natural one), panel label, notification colour
REEL = [
    ("fade", None, "fade", "ffffff"),
    ("cut", None, "cut", "ffc000"),
    ("slide", "left", "slide", "00ff80"),
    ("swipe_out", "up", "swipeout", "20a0ff"),
    ("swipe_in", "right", "swipe in", "ff40a0"),
    ("collapse", None, "collapse", "ff4000"),
    ("expand", None, "expand", "40ff40"),
    ("wipe", "down", "wipe", "c040ff"),
    ("dissolve", None, "dissolve", "ffff40"),
    ("split_out", "left", "splitout", "40c0ff"),
    ("split_in", "up", "split in", "ff8040"),
    ("blinds", "down", "blinds", "80ff80"),
    ("flip", "left", "flip", "ff60ff"),
    ("rain", "down", "rain", "60c0ff"),
    ("rain_random", "down", "rain rnd", "ffa0ff"),
]
OTHER_BASE = {"clock": "art", "art": "clock", "ip": "clock"}


def die(msg):
    sys.exit(f"tc002-demo.py: {msg}")


def request(args, token, method, path, body=None, query=""):
    status, raw = tc002ctl.call(args, method, path, body, token=token, query=query)
    if status != 200:
        try:
            doc = json.loads(raw)
            detail = f"{doc.get('error')}: {doc.get('message')}"
        except ValueError:
            detail = raw.decode(errors="replace")[:120]
        die(f"{method} {path} failed ({status}) {detail}")
    return json.loads(raw) if raw else {}


def describe(effect, direction, ms):
    return f"{effect}{' ' + direction if direction else ''}, {ms} ms"


def set_scene(args, token, base, generator, effect=None, direction=None, ms=None):
    body = {"base": base, "request_id": secrets.token_hex(8)}
    if base == "art" and generator:
        body["generator"] = generator
    if effect:
        body["transition"] = effect
        body["transition_ms"] = ms
        if direction:
            body["direction"] = direction
    request(args, token, "PUT", "/scene", body)


def notify(args, token, text, colour, hold, effect, direction, ms, exit_mode):
    body = {"text": text, "colour": colour, "duration_s": hold, "transition": effect, "transition_ms": ms, "exit": exit_mode,
            "request_id": secrets.token_hex(8), "epoch": tc002ctl.epoch(args, token)}
    if direction:
        body["direction"] = direction
    request(args, token, "POST", "/notify", body)


def play(args, token, reel, start_base, generator):
    base = start_base
    for effect, direction, label, colour in reel:
        if not args.no_scenes:
            base = OTHER_BASE[base]
            print(f"  scene -> {base:5s}  {describe(effect, direction, args.ms)}")
            set_scene(args, token, base, generator, effect, direction, args.ms)
            time.sleep(args.ms / 1000 + 0.7)
        leaves = {"reverse": "leaves the other way", "same": "leaves the same way", "none": "cuts away"}[args.exit]
        print(f"  notify {label!r:11s} {describe(effect, direction, args.ms)}; {leaves}")
        notify(args, token, label, colour, args.hold, effect, direction, args.ms, args.exit)
        time.sleep(args.hold + args.ms / 1000 + 0.4)
    return base


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("-s", "--server", required=True)
    ap.add_argument("--token")
    ap.add_argument("--token-file")
    ap.add_argument("--ms", type=int, default=800)
    ap.add_argument("--hold", type=int, default=2)
    ap.add_argument("--exit", default="reverse", choices=["reverse", "same", "none"])
    ap.add_argument("--only")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--no-scenes", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    a = ap.parse_args()
    if a.help:
        print(__doc__.strip())
        return 0
    if a.list:
        for effect, direction, label, colour in REEL:
            print(f"{effect:12s} {direction or '(natural)':10s} {label!r:11s} #{colour}")
        return 0
    if not 0 <= a.ms <= 5000:
        die("--ms must be 0..5000")
    if not 1 <= a.hold <= 300:
        die("--hold must be 1..300")
    reel = REEL
    if a.only:
        by_name = {e[0]: e for e in REEL}
        wanted = [w.strip() for w in a.only.split(",") if w.strip()]
        unknown = [w for w in wanted if w not in by_name]
        if unknown:
            die(f"unknown effect(s) {', '.join(unknown)}; the reel knows {', '.join(by_name)}")
        reel = [by_name[w] for w in wanted]

    token = tc002ctl.load_token(a, False)
    catalogue = request(a, token, "GET", "/scenes").get("transitions", {}).get("effects")
    if not catalogue:
        die("the runtime on the device lists no transitions (older build?)")
    missing = [e[0] for e in reel if e[0] not in catalogue]
    if missing:
        die(f"the device does not know {', '.join(missing)}")
    status = request(a, token, "GET", "/status")
    start_base, generator = status.get("base", "clock"), status.get("generator") or "plasma"
    if status.get("power") is False:
        print("note: display power is off; the reel will play unseen (tc002ctl.py power on)")
    print(f"demo reel: {len(reel)} effects, {a.ms} ms each, notifications hold {a.hold} s and exit {a.exit}; starting from {start_base}")
    base = start_base
    try:
        while True:
            base = play(a, token, reel, base, generator)
            if not a.loop:
                break
            print("  again")
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        if base != start_base:
            print(f"  scene -> {start_base} (fade), as it was")
            set_scene(a, token, start_base, generator, "fade", None, a.ms)
    return 0


if __name__ == "__main__":
    sys.exit(main())
