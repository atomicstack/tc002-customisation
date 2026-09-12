#!/usr/bin/env python3
"""tc002-demo-shapes.py: the drawing primitives, one step at a time, on the device over the api.

rectangles outlined and filled, lines at every angle, circles, single pixels, and bars horizontal
and vertical. the point of the reel is that an integration never composes pixels: each step is a
short json document the device draws.

  tc002-demo-shapes.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

the panel it found is put back at the end, canvas and all.
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-shapes.py"
W, H = 52, 16

REEL = [
    ("rect-outline", "a one-pixel outline: the default", [
        {"type": "rect", "at": [2, 2], "size": [22, 12], "colour": "40a0ff"},
        {"type": "rect", "at": [28, 5], "size": [20, 6], "colour": "ff8000"},
    ]),
    ("rect-filled", "the same two, filled", [
        {"type": "rect", "at": [2, 2], "size": [22, 12], "colour": "40a0ff", "filled": True},
        {"type": "rect", "at": [28, 5], "size": [20, 6], "colour": "ff8000", "filled": True},
    ]),
    ("rect-clipped", "half off the panel: what fits is drawn, the rest simply is not", [
        {"type": "rect", "at": [-8, -4], "size": [20, 12], "colour": "ff4040", "filled": True},
        {"type": "rect", "at": [44, 10], "size": [20, 12], "colour": "40ff40", "filled": True},
    ]),
    ("lines", "bresenham, so a diagonal has no gaps whichever way it runs", [
        {"type": "line", "at": [0, 0], "to": [51, 15], "colour": "ffffff"},
        {"type": "line", "at": [0, 15], "to": [51, 0], "colour": "ff00ff"},
        {"type": "line", "at": [26, 0], "to": [26, 15], "colour": "00ffff"},
        {"type": "line", "at": [0, 8], "to": [51, 8], "colour": "ffff00"},
    ]),
    ("line-fan", "every angle out of one corner", [
        {"type": "line", "at": [0, 15], "to": [x, 0], "colour": c}
        for x, c in ((0, "ff0000"), (10, "ff8000"), (20, "ffff00"), (30, "00ff00"), (40, "0080ff"), (51, "8000ff"))
    ]),
    ("circles", "midpoint circles; `at` is the centre", [
        {"type": "circle", "at": [10, 8], "r": 7, "colour": "40a0ff"},
        {"type": "circle", "at": [26, 8], "r": 5, "colour": "ffffff", "filled": True},
        {"type": "circle", "at": [40, 8], "r": 3, "colour": "ff4080"},
        {"type": "circle", "at": [48, 4], "r": 1, "colour": "ffff00", "filled": True},
    ]),
    ("pixels", "the cheap escape hatch: one pixel, wherever you like (24 elements, the document limit)", [
        {"type": "pixel", "at": [x, (x * 7) % H], "colour": f"{(x * 5) % 256:02x}a0ff"}
        for x in range(0, 48, 2)
    ]),
    ("bars", "a value 0..100 in its box, with a background for the empty part", [
        {"type": "text", "at": [0, 1], "font": "mini", "colour": "606060", "text": "cpu"},
        {"type": "bar", "at": [16, 2], "size": [36, 3], "value": 25, "colour": "40ff40", "background": "102010"},
        {"type": "text", "at": [0, 6], "font": "mini", "colour": "606060", "text": "mem"},
        {"type": "bar", "at": [16, 7], "size": [36, 3], "value": 60, "colour": "ffc000", "background": "201810"},
        {"type": "text", "at": [0, 11], "font": "mini", "colour": "606060", "text": "disk"},
        {"type": "bar", "at": [16, 12], "size": [36, 3], "value": 93, "colour": "ff4040", "background": "201010"},
    ]),
    ("bars-vertical", "vertical bars fill from the bottom, which is where a level belongs", [
        {"type": "bar", "at": [2 + i * 7, 0], "size": [5, 16], "value": v, "colour": "30a0ff", "background": "101820"}
        for i, v in enumerate((10, 25, 40, 55, 70, 85, 100))
    ]),
    ("edges", "the four corners and the full border, to show the panel's exact extent", [
        {"type": "rect", "at": [0, 0], "size": [52, 16], "colour": "203040"},
        {"type": "pixel", "at": [0, 0], "colour": "ff0000"},
        {"type": "pixel", "at": [51, 0], "colour": "00ff00"},
        {"type": "pixel", "at": [0, 15], "colour": "0000ff"},
        {"type": "pixel", "at": [51, 15], "colour": "ffff00"},
    ]),
]


def step(dev, item, args):
    _, detail, elements = item
    dev.put(elements)
    return f"{detail}  ({len(elements)} element{'s' if len(elements) != 1 else ''})"


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step))
