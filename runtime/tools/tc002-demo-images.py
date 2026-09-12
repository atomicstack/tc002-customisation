#!/usr/bin/env python3
"""tc002-demo-images.py: uploading pictures to the device and drawing them.

the built-in icons are monochrome and take the element's colour. anything that needs colours of its
own is a sprite: 8x8 or 16x16 of raw rgb888, uploaded as octets and referenced by id. the pictures
here are generated on this machine rather than shipped as files, so the script is self-contained and
you can see exactly what a sprite is -- three bytes a pixel, row by row, no header.

  tc002-demo-images.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

black is transparent, which is what lets a sprite sit over something else. the eight slots and any
sprite this script uploaded are cleared at the end, and the panel goes back to what it was.
"""
import math, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-images.py"
MINE = ("ring", "warm", "cool", "face", "big")


def blank(side):
    return bytearray(side * side * 3)


def put(buf, side, x, y, rgb):
    if 0 <= x < side and 0 <= y < side:
        o = (y * side + x) * 3
        buf[o], buf[o + 1], buf[o + 2] = rgb


def ring(side=8):
    """a hollow circle, to show that black really is transparent"""
    buf = blank(side)
    c = (side - 1) / 2
    for y in range(side):
        for x in range(side):
            d = math.hypot(x - c, y - c)
            if c - 1.8 < d <= c:
                put(buf, side, x, y, (255, 0, 200))
    return buf


def gradient(side, a, b):
    """a two-colour ramp: the thing a monochrome icon cannot do"""
    buf = blank(side)
    for y in range(side):
        for x in range(side):
            t = (x + y) / (2 * (side - 1))
            put(buf, side, x, y, tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    return buf


def face(side=8):
    """a smiley, drawn at the size rather than shrunk to it, which is the whole argument"""
    buf = blank(side)
    for y in range(side):
        for x in range(side):
            d = math.hypot(x - 3.5, y - 3.5)
            if d <= 3.6:
                put(buf, side, x, y, (255, 210, 0))
    for x, y in ((2, 2), (5, 2)):
        put(buf, side, x, y, (0, 0, 0))
    for x in range(2, 6):
        put(buf, side, x, 5, (0, 0, 0))
    put(buf, side, 1, 4, (0, 0, 0))
    put(buf, side, 6, 4, (0, 0, 0))
    return buf


def globe(side=16):
    """16x16, the larger of the two sizes: a shaded ball"""
    buf = blank(side)
    c = (side - 1) / 2
    for y in range(side):
        for x in range(side):
            dx, dy = x - c, y - c
            d = math.hypot(dx, dy)
            if d > c:
                continue
            lit = max(0.0, 1.0 - math.hypot(dx + 3, dy + 3) / (side * 0.9))
            put(buf, side, x, y, (int(40 + 120 * lit), int(90 + 150 * lit), int(180 + 70 * lit)))
    return buf


REEL = [
    ("upload", "five pictures generated here and sent as octets; the size is inferred from the length", None),
    ("ring", "8x8, and black is transparent: the panel shows through the middle", [
        {"type": "rect", "at": [0, 0], "size": [52, 16], "colour": "101820", "filled": True},
        {"type": "sprite", "at": [4, 4], "sprite": "ring"},
        {"type": "sprite", "at": [22, 4], "sprite": "ring"},
        {"type": "sprite", "at": [40, 4], "sprite": "ring"},
    ]),
    ("gradients", "two ramps, which is what a monochrome icon cannot do", [
        {"type": "sprite", "at": [10, 4], "sprite": "warm"},
        {"type": "sprite", "at": [34, 4], "sprite": "cool"},
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "own colours"},
    ]),
    ("face", "a smiley drawn at 8x8 rather than shrunk to it, which is the argument against emoji", [
        {"type": "sprite", "at": [22, 4], "sprite": "face"},
    ]),
    ("big", "16x16 fills the panel's height", [
        {"type": "sprite", "at": [18, 0], "sprite": "big"},
        {"type": "text", "at": [0, 5], "font": "mini", "colour": "606060", "text": "16"},
        {"type": "text", "at": [40, 5], "font": "mini", "colour": "606060", "text": "x16"},
    ]),
    ("animated", "a sprite animates like anything else: these bounce out of step", [
        {"type": "sprite", "at": [4, 4], "sprite": "face", "animate": {"kind": "bounce", "ms": 1200, "amount": 4}},
        {"type": "sprite", "at": [22, 4], "sprite": "face", "animate": {"kind": "bounce", "ms": 1200, "amount": 4, "phase": 33}},
        {"type": "sprite", "at": [40, 4], "sprite": "face", "animate": {"kind": "bounce", "ms": 1200, "amount": 4, "phase": 66}},
    ]),
    ("in-a-tile", "a tile takes a sprite in place of an icon", [
        {"type": "tile", "at": [0, 0], "size": [52, 16], "sprite": "big", "label": "earth",
         "value_text": "online", "colour": "80ff80", "accent": "505050"},
    ]),
    ("mixed", "an uploaded picture beside a built-in icon: same document, different sources", [
        {"type": "sprite", "at": [2, 4], "sprite": "face"},
        {"type": "icon", "at": [14, 4], "icon": "heart", "colour": "ff4060"},
        {"type": "icon", "at": [26, 4], "icon": "star", "colour": "ffc000"},
        {"type": "sprite", "at": [38, 4], "sprite": "ring"},
    ]),
]


def setup(dev):
    """upload the pictures before the reel starts, so every step can name one"""
    dev.put_sprite("ring", ring())
    dev.put_sprite("warm", gradient(8, (255, 200, 0), (255, 0, 80)))
    dev.put_sprite("cool", gradient(8, (0, 200, 255), (80, 0, 255)))
    dev.put_sprite("face", face())
    dev.put_sprite("big", globe())


def teardown(dev):
    """take back the slots this script used, and only those"""
    held = {s["id"] for s in dev.sprites().get("sprites", [])}
    for name in MINE:
        if name in held:
            dev.delete_sprite(name)


def step(dev, item, args):
    name, detail, elements = item
    if name == "upload":
        listing = dev.sprites()
        sizes = ", ".join(f"{s['id']} {s['width']}x{s['height']}" for s in listing.get("sprites", []))
        dev.put([
            {"type": "text", "at": [0, 0], "font": "mini", "colour": "606060", "text": "uploaded"},
            {"type": "sprite", "at": [2, 6], "sprite": "ring"},
            {"type": "sprite", "at": [12, 6], "sprite": "warm"},
            {"type": "sprite", "at": [22, 6], "sprite": "cool"},
            {"type": "sprite", "at": [32, 6], "sprite": "face"},
            {"type": "text", "at": [41, 8], "font": "mini", "colour": "505050", "text": f"{len(listing.get('sprites', []))}/{listing.get('slots')}"},
        ])
        return f"{detail}: {sizes}"
    dev.put(elements)
    return detail


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step, extra_setup=setup, extra_teardown=teardown))
