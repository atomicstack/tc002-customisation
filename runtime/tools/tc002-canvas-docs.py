#!/usr/bin/env python3
"""tc002-canvas-docs.py: photograph the panel for CANVAS.md.

drives the device through a catalogue of canvas documents and saves what the panel actually shows:
a png per still, an animated gif per motion. nothing here is drawn on this machine -- every pixel
came off `GET /screen`, so the document cannot drift from the picture of it.

  tc002-canvas-docs.py -s <device-ip> [--token-file FILE] [--out DIR] [--only NAME,NAME]
                       [--scale N] [--fps N] [--seconds S] [--list]

the panel it found is put back at the end, canvas and all. the gifs need ffmpeg on this machine;
the stills do not (the png encoder is twenty lines at the bottom of this file).
"""
import argparse, math, os, shutil, struct, subprocess, sys, tempfile, time, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002ctl, tc002demo  # noqa: e402

NAME = "tc002-canvas-docs.py"
W, H = 52, 16
DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "screenshots", "canvas")


# ---- the pictures the sprite examples use, generated here so the script is self-contained ----

def blank(side):
    return bytearray(side * side * 3)


def put(buf, side, x, y, rgb):
    if 0 <= x < side and 0 <= y < side:
        o = (y * side + x) * 3
        buf[o], buf[o + 1], buf[o + 2] = rgb


def ring(side=8):
    buf, c = blank(side), (side - 1) / 2
    for y in range(side):
        for x in range(side):
            if c - 1.8 < math.hypot(x - c, y - c) <= c:
                put(buf, side, x, y, (255, 0, 200))
    return buf


def gradient(side, a, b):
    buf = blank(side)
    for y in range(side):
        for x in range(side):
            t = (x + y) / (2 * (side - 1))
            put(buf, side, x, y, tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    return buf


def face(side=8):
    buf = blank(side)
    for y in range(side):
        for x in range(side):
            if math.hypot(x - 3.5, y - 3.5) <= 3.6:
                put(buf, side, x, y, (255, 210, 0))
    for x, y in ((2, 2), (5, 2)):
        put(buf, side, x, y, (0, 0, 0))
    for x in range(2, 6):
        put(buf, side, x, 5, (0, 0, 0))
    put(buf, side, 1, 4, (0, 0, 0))
    put(buf, side, 6, 4, (0, 0, 0))
    return buf


def globe(side=16):
    buf, c = blank(side), (side - 1) / 2
    for y in range(side):
        for x in range(side):
            dx, dy = x - c, y - c
            if math.hypot(dx, dy) > c:
                continue
            lit = max(0.0, 1.0 - math.hypot(dx + 3, dy + 3) / (side * 0.9))
            put(buf, side, x, y, (int(40 + 120 * lit), int(90 + 150 * lit), int(180 + 70 * lit)))
    return buf


SPRITES = {"ring": ring(), "warm": gradient(8, (255, 200, 0), (255, 0, 80)),
           "cool": gradient(8, (0, 200, 255), (80, 0, 255)), "face": face(), "earth": globe()}

WAVE = [int(50 + 45 * math.sin(i / 4.0)) for i in range(52)]
SPIKY = [20, 24, 22, 28, 90, 30, 26, 24, 60, 28, 25, 27, 30, 95, 33, 29]


# ---- the catalogue: (name, elements) for a still, and the same plus seconds for a motion ----

def digits(face_name, text, y):
    return [{"type": "text", "at": [1, y], "font": face_name, "colour": "ffffff", "text": text}]


STILLS = [
    ("fonts", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "8090a0", "text": "mini 3x5 abc"},
        {"type": "text", "at": [0, 7], "font": "small", "colour": "ffffff", "text": "small"},
        {"type": "text", "at": [36, 9], "font": "mini", "colour": "8090a0", "text": "5x7"},
    ]),
    ("font-small", [{"type": "text", "at": [0, 1], "font": "small", "colour": "ffffff", "text": "abcdefgh"},
                    {"type": "text", "at": [0, 9], "font": "small", "colour": "8090a0", "text": "!?#%&*()"}]),
    ("font-mini", [{"type": "text", "at": [0, 1], "font": "mini", "colour": "ffffff", "text": "abcdefghijkl"},
                   {"type": "text", "at": [0, 9], "font": "mini", "colour": "8090a0", "text": "mnopqrstuvwx"}]),
    ("numerals-small", digits("small", "01234567", 1) + digits("small", "89", 9)),
    ("numerals-mini", digits("mini", "0123456789", 1) + digits("mini", "12:34", 9)),
    ("numerals-block", [{"type": "text", "at": [1, 3], "font": "block", "colour": "40a0ff", "text": "12:34"}]),
    ("numerals-big", [{"type": "text", "at": [2, 1], "font": "big", "colour": "ffc000", "text": "21"},
                      {"type": "text", "at": [28, 5], "font": "small", "colour": "ffffff", "text": "deg"}]),
    ("align", [
        {"type": "text", "at": [0, 0], "size": [52, 5], "font": "mini", "align": "left", "colour": "ff4040", "text": "left"},
        {"type": "text", "at": [0, 6], "size": [52, 5], "font": "mini", "align": "centre", "colour": "40ff40", "text": "centre"},
        {"type": "text", "at": [0, 11], "size": [52, 5], "font": "mini", "align": "right", "colour": "4080ff", "text": "right"},
    ]),
    ("rect", [
        {"type": "rect", "at": [2, 2], "size": [20, 12], "colour": "40a0ff"},
        {"type": "rect", "at": [28, 4], "size": [20, 8], "colour": "ff8000", "filled": True},
    ]),
    ("line", [{"type": "line", "at": [0, 15], "to": [8 + i * 8, 0], "colour": c}
              for i, c in enumerate(("ff0000", "ff8000", "ffff00", "40ff40", "40a0ff", "c040ff"))]),
    ("circle", [
        {"type": "circle", "at": [12, 8], "r": 7, "colour": "40a0ff"},
        {"type": "circle", "at": [32, 8], "r": 7, "colour": "ffffff", "filled": True},
        {"type": "circle", "at": [46, 8], "r": 4, "colour": "ff4080"},
    ]),
    ("pixel", [{"type": "pixel", "at": [(i * 7) % 52, (i * 5) % 16], "colour": c}
               for i, c in enumerate(("ff0000", "ff8000", "ffff00", "40ff40", "40a0ff", "c040ff",
                                      "ffffff", "ff4080", "40ffc0", "8060ff") * 2)]),
    ("bar-horizontal", [
        {"type": "text", "at": [0, 1], "font": "mini", "colour": "606060", "text": "cpu"},
        {"type": "bar", "at": [16, 2], "size": [36, 3], "value": 25, "colour": "40ff40", "background": "102010"},
        {"type": "text", "at": [0, 6], "font": "mini", "colour": "606060", "text": "mem"},
        {"type": "bar", "at": [16, 7], "size": [36, 3], "value": 60, "colour": "ffc000", "background": "201810"},
        {"type": "text", "at": [0, 11], "font": "mini", "colour": "606060", "text": "disk"},
        {"type": "bar", "at": [16, 12], "size": [36, 3], "value": 93, "colour": "ff4040", "background": "201010"},
    ]),
    ("bar-vertical", [{"type": "bar", "at": [2 + i * 7, 0], "size": [5, 16], "value": v,
                       "colour": "30a0ff", "background": "101820", "vertical": True}
                      for i, v in enumerate((10, 25, 40, 55, 70, 85, 100))]),
    ("sparkline-line", [{"type": "sparkline", "at": [0, 1], "size": [52, 14], "style": "line", "colour": "40ffc0", "data": WAVE}]),
    ("sparkline-bars", [{"type": "sparkline", "at": [0, 1], "size": [52, 14], "style": "bars", "colour": "40a0ff", "data": WAVE}]),
    ("sparkline-area", [{"type": "sparkline", "at": [0, 1], "size": [52, 14], "style": "area", "colour": "8060ff", "data": WAVE}]),
    ("sparkline-threshold", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "606060", "text": "over 50"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "bars", "colour": "40a0ff",
         "min": 0, "max": 100, "threshold": 50, "over": "ff4000", "data": SPIKY},
    ]),
    ("tile-wide", [{"type": "tile", "at": [0, 0], "size": [52, 16], "icon": "thermometer",
                    "label": "lounge", "value_text": "21.4C", "colour": "ff8000", "accent": "505050"}]),
    ("tile-thirds", [{"type": "tile", "tile": i, "of": 3, "icon": ic, "label": lb, "value_text": v, "colour": c}
                     for i, (ic, lb, v, c) in enumerate((("thermometer", "in", "21", "ff8000"),
                                                         ("droplet", "hum", "48", "40a0ff"),
                                                         ("cloud-rain", "out", "9", "40ff80")))]),
    ("tile-rows", [{"type": "tile", "row": i, "of": 2, "icon": ic, "label": lb, "value_text": v, "colour": c, "accent": "404040"}
                   for i, (ic, lb, v, c) in enumerate((("house", "inside", "21.4C", "ff8000"),
                                                        ("cloud-snow", "outside", "-1.2C", "40c0ff")))]),
    ("sprites", [
        {"type": "sprite", "at": [1, 4], "sprite": "ring"},
        {"type": "sprite", "at": [11, 4], "sprite": "warm"},
        {"type": "sprite", "at": [21, 4], "sprite": "cool"},
        {"type": "sprite", "at": [31, 4], "sprite": "face"},
        {"type": "text", "at": [41, 6], "font": "mini", "colour": "606060", "text": "8x8"},
    ]),
    ("sprite-large", [
        {"type": "sprite", "at": [18, 0], "sprite": "earth"},
        {"type": "text", "at": [0, 5], "font": "mini", "colour": "606060", "text": "16"},
        {"type": "text", "at": [40, 5], "font": "mini", "colour": "606060", "text": "x16"},
    ]),
    ("layout-tiles", [{"type": "rect", "tile": i, "of": 4, "colour": c, "filled": True}
                      for i, c in enumerate(("40a0ff", "ff8040", "40ff80", "ffc000"))]),
    ("layout-rows", [{"type": "rect", "row": i, "of": 4, "colour": c, "filled": True}
                     for i, c in enumerate(("40a0ff", "ff8040", "40ff80", "ffc000"))]),
    ("layout-boxes", [
        {"type": "rect", "at": [0, 0], "size": [26, 16], "colour": "101820", "filled": True},
        {"type": "text", "at": [0, 5], "size": [26, 7], "font": "mini", "align": "centre", "colour": "ffffff", "text": "centre"},
        {"type": "rect", "at": [28, 0], "size": [24, 16], "colour": "201010", "filled": True},
        {"type": "text", "at": [29, 5], "size": [23, 7], "font": "mini", "colour": "ffffff", "text": "cut off here"},
    ]),
    ("layout-draw-order", [
        {"type": "rect", "at": [4, 2], "size": [20, 12], "colour": "ff0000", "filled": True},
        {"type": "rect", "at": [16, 4], "size": [20, 10], "colour": "00ff00", "filled": True},
        {"type": "rect", "at": [28, 6], "size": [20, 8], "colour": "0000ff", "filled": True},
    ]),
    ("layout-layers", [
        {"type": "rect", "at": [0, 0], "size": [52, 16], "colour": "080c14", "filled": True},
        {"type": "sparkline", "at": [0, 4], "size": [52, 12], "style": "area", "colour": "16304a",
         "data": [30, 45, 40, 60, 75, 65, 55, 70, 85, 95, 80, 90]},
        {"type": "text", "at": [1, 0], "font": "mini", "colour": "8090a0", "text": "load"},
        {"type": "text", "at": [36, 0], "font": "mini", "colour": "ffffff", "text": "90%"},
    ]),
    ("dashboard", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "506070", "text": "amsterdam"},
        {"type": "icon", "at": [44, 0], "icon": "cloud-rain", "colour": "40a0ff"},
        {"type": "text", "at": [0, 5], "font": "block", "colour": "ffffff", "text": "9"},
        {"type": "text", "at": [16, 6], "font": "mini", "colour": "808080", "text": "deg"},
        {"type": "sparkline", "at": [28, 11], "size": [24, 5], "style": "bars", "colour": "205070",
         "min": 0, "max": 100, "data": [40, 45, 50, 60, 55, 50, 45]},
    ]),
]

MOTION = [
    ("anim-hue", 3.0, [
        {"type": "text", "at": [2, 1], "font": "small", "colour": "ff0000", "text": "hue",
         "animate": {"kind": "hue", "ms": 3000}},
        {"type": "text", "at": [2, 9], "font": "small", "colour": "00ff00", "text": "shift",
         "animate": {"kind": "hue", "ms": 3000, "phase": 50}},
    ]),
    ("anim-pulse", 3.6, [{"type": "text", "at": [6, 4], "font": "small", "colour": "40a0ff",
                          "text": "breathe", "animate": {"kind": "pulse", "ms": 1800}}]),
    ("anim-blink", 3.6, [
        {"type": "text", "at": [0, 5], "font": "mini", "colour": "ff4040", "text": "one",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50}},
        {"type": "text", "at": [18, 5], "font": "mini", "colour": "ffc000", "text": "two",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50, "phase": 33}},
        {"type": "text", "at": [33, 5], "font": "mini", "colour": "40ff40", "text": "three",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50, "phase": 66}},
    ]),
    ("anim-bounce", 2.8, [
        {"type": "text", "at": [2, 6], "font": "mini", "colour": "ff8000", "text": "up",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4}},
        {"type": "text", "at": [16, 6], "font": "mini", "colour": "ff8000", "text": "and",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4, "phase": 33}},
        {"type": "text", "at": [34, 6], "font": "mini", "colour": "ff8000", "text": "down",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4, "phase": 66}},
    ]),
    ("anim-bounce-x", 3.2, [{"type": "text", "at": [14, 5], "font": "small", "colour": "c040ff",
                             "text": "side", "animate": {"kind": "bounce", "ms": 1600, "amount": 6, "axis": "x"}}]),
    ("anim-scramble", 3.0, [{"type": "text", "at": [2, 4], "font": "small", "colour": "ffffff",
                             "text": "SCRAMBLE", "animate": {"kind": "scramble", "ms": 2500}}]),
    ("anim-typewriter", 3.0, [
        {"type": "text", "at": [0, 1], "font": "small", "colour": "40ff40", "text": "typing",
         "animate": {"kind": "typewriter", "ms": 2000}},
        {"type": "text", "at": [0, 10], "font": "mini", "colour": "40ff40", "text": "one by one",
         "animate": {"kind": "typewriter", "ms": 2800}},
    ]),
    ("anim-scroll", 4.0, [{"type": "text", "at": [0, 4], "size": [52, 8], "font": "small", "colour": "40ffc0",
                           "text": "an integration sends data, not pixels",
                           "animate": {"kind": "scroll", "ms": 33}}]),
    ("anim-sweep", 2.6, [{"type": "sparkline", "at": [0, 2], "size": [52, 12], "style": "area", "colour": "40ff60",
                          "data": [int(5 + i * 1.8) for i in range(52)],
                          "animate": {"kind": "sweep", "ms": 2000}}]),
    ("anim-together", 3.6, [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "ff0000", "text": "hue", "animate": {"kind": "hue", "ms": 2000}},
        {"type": "text", "at": [18, 0], "font": "mini", "colour": "ffffff", "text": "blink", "animate": {"kind": "blink", "ms": 900}},
        {"type": "text", "at": [41, 0], "font": "mini", "colour": "40ff40", "text": "pls", "animate": {"kind": "pulse", "ms": 1500}},
        {"type": "text", "at": [0, 7], "font": "small", "colour": "40a0ff", "text": "SETTLE", "animate": {"kind": "scramble", "ms": 2500}},
        {"type": "text", "at": [41, 9], "font": "mini", "colour": "ffc000", "text": "bnc", "animate": {"kind": "bounce", "ms": 1100, "amount": 2}},
    ]),
]

ICONS_PER_PAGE = 5
ICON_COLOURS = ("ffffff", "40a0ff", "40ff80", "ffc000", "ff6060")


def icon_page(chunk):
    """the glyphs alone, evenly spaced. their names go in the prose: the panel is 52 px wide and
    "cloud-rain" is 39 of them in the smallest face, so a name under each icon can only be a
    clipped stump -- five of those read as one long piece of nonsense."""
    els = []
    for n, name in enumerate(chunk):
        els.append({"type": "icon", "at": [2 + n * 10, 4], "icon": name,
                    "colour": ICON_COLOURS[n % len(ICON_COLOURS)]})
    return els


# ---- png, and gif by way of ffmpeg ----

def png(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9))
                + chunk(b"IEND", b""))


def scaled_rows(frame, scale):
    """nearest-neighbour, because a panel pixel is a pixel and should look like one"""
    rows = []
    for y in range(H):
        src = frame[y * W * 3:(y + 1) * W * 3]
        line = bytearray()
        for x in range(W):
            line += src[x * 3:x * 3 + 3] * scale
        for _ in range(scale):
            rows.append(line)
    return rows


def save_png(path, frame, scale):
    png(path, W * scale, H * scale, scaled_rows(frame, scale))


def save_gif(path, frames, scale, fps):
    """ffmpeg builds a palette from the whole clip, which a hue sweep needs"""
    tmp = tempfile.mkdtemp(prefix="tc002gif")
    try:
        for i, f in enumerate(frames):
            save_png(os.path.join(tmp, f"f{i:04d}.png"), f, scale)
        cmd = ["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", os.path.join(tmp, "f%04d.png"),
               "-filter_complex", "[0:v]split[a][b];[a]palettegen=max_colors=255[p];[b][p]paletteuse=dither=none",
               "-loop", "0", path]
        subprocess.run(cmd, check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---- driving the panel ----

def grab(dev):
    status, raw = tc002ctl.call(dev.args, "GET", "/screen", None, token=dev.control, query="format=raw")
    if status != 200 or len(raw) != W * H * 3:
        sys.exit(f"{NAME}: screen grab failed ({status}, {len(raw)} bytes)")
    return raw


def progress(sock, line):
    if not sock:
        return
    try:
        import socket as s
        with s.socket(s.AF_UNIX, s.SOCK_STREAM) as c:
            c.settimeout(2)
            c.connect(sock)
            c.sendall(line.encode())
            c.shutdown(s.SHUT_WR)
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--server", required=True)
    ap.add_argument("--token", help="64 hex characters of one token")
    ap.add_argument("--token-file", help="the 64-byte token file the supervisor wrote")
    ap.add_argument("--admin", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--out", default=DEFAULT_OUT, help="where the images go")
    ap.add_argument("--only", help="a comma-separated subset of names")
    ap.add_argument("--scale", type=int, default=6, help="how many screen pixels to a panel pixel (default 6)")
    ap.add_argument("--fps", type=int, default=15, help="gif frame rate (default 15)")
    ap.add_argument("--settle", type=float, default=0.45, help="seconds to let a still settle (default 0.45)")
    ap.add_argument("--progress-socket", help=argparse.SUPPRESS)
    ap.add_argument("--list", action="store_true", help="print the catalogue and exit")
    args = ap.parse_args()

    dev = tc002demo.Device(args, NAME)
    names = [n for n, _ in STILLS] + [n for n, _, _ in MOTION]
    if args.list:
        print("\n".join(names + ["icons-page-N (one per five icons the device has)"]))
        return 0
    want = set(w.strip() for w in args.only.split(",")) if args.only else None

    icon_names = dev.icons().get("names") or []
    pages = [icon_names[i:i + ICONS_PER_PAGE] for i in range(0, len(icon_names), ICONS_PER_PAGE)]
    total = len(STILLS) + len(MOTION) + len(pages)
    progress(args.progress_socket, f"@set-total {total}\n@value 0\n@phase-name capture\n")
    os.makedirs(args.out, exist_ok=True)

    was_base = dev.status().get("base", "clock")
    was_canvas = dev.get().get("elements", [])
    for sid, rgb in SPRITES.items():
        dev.put_sprite(sid, rgb)
    dev.show_canvas()
    done = 0
    try:
        for name, els in STILLS:
            done += 1
            if want and name not in want:
                continue
            dev.put(els)
            time.sleep(args.settle)
            save_png(os.path.join(args.out, f"{name}.png"), grab(dev), args.scale)
            print(f"  {name}.png")
            progress(args.progress_socket, f"@value {done}\n")
        for i, chunk in enumerate(pages, 1):
            done += 1
            name = f"icons-page-{i}"
            if want and name not in want:
                continue
            dev.put(icon_page(chunk))
            time.sleep(args.settle)
            save_png(os.path.join(args.out, f"{name}.png"), grab(dev), args.scale)
            print(f"  {name}.png  ({', '.join(chunk)})")
            progress(args.progress_socket, f"@value {done}\n")
        for name, seconds, els in MOTION:
            done += 1
            if want and name not in want:
                continue
            dev.put(els)
            frames, period = [], 1.0 / args.fps
            start = time.monotonic()
            while time.monotonic() - start < seconds:
                due = start + len(frames) * period
                gap = due - time.monotonic()
                if gap > 0:
                    time.sleep(gap)
                frames.append(grab(dev))
            save_gif(os.path.join(args.out, f"{name}.gif"), frames, args.scale, args.fps)
            print(f"  {name}.gif  ({len(frames)} frames at {args.fps} fps)")
            progress(args.progress_socket, f"@value {done}\n")
    finally:
        dev.request("PUT", "/scene", {"base": was_base, "request_id": os.urandom(8).hex()})
        if was_canvas:
            dev.put(was_canvas)
        else:
            dev.clear()
        held = {s["id"] for s in dev.sprites().get("sprites", [])}
        for sid in SPRITES:
            if sid in held:
                dev.delete_sprite(sid)
        print(f"  put back: {was_base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
