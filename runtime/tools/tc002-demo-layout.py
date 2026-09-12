#!/usr/bin/env python3
"""tc002-demo-layout.py: where things go on 52x16, which is the part of a panel this small that
needs the most thought.

absolute pixels, the tile and row shorthands that divide the panel without gaps or rounding errors,
what a box does to the thing inside it, clipping at the edges, and the order elements draw in. the
last step animates an element in from off-panel, which is the reason placement clips rather than
refuses.

  tc002-demo-layout.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

the panel it found is put back at the end, canvas and all.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-layout.py"
SHADES = ("40a0ff", "ff8040", "40ff80", "ffc000", "c040ff", "ff4080")

REEL = [
    ("absolute", "at [x,y] and size [w,h], in pixels, top-left corner", [
        {"type": "rect", "at": [0, 0], "size": [16, 8], "colour": "40a0ff", "filled": True},
        {"type": "rect", "at": [18, 4], "size": [16, 8], "colour": "ff8040", "filled": True},
        {"type": "rect", "at": [36, 8], "size": [16, 8], "colour": "40ff80", "filled": True},
    ]),
    ("tiles-2", "tile n of 2: the panel split in half, no gap and no overlap", [
        {"type": "rect", "tile": i, "of": 2, "colour": SHADES[i], "filled": True} for i in range(2)
    ]),
    ("tiles-3", "thirds. 52 does not divide by three, so the device does the rounding", [
        {"type": "rect", "tile": i, "of": 3, "colour": SHADES[i], "filled": True} for i in range(3)
    ]),
    ("tiles-4", "quarters", [
        {"type": "rect", "tile": i, "of": 4, "colour": SHADES[i], "filled": True} for i in range(4)
    ]),
    ("tiles-6", "sixths, which is about as narrow as a column can usefully be", [
        {"type": "rect", "tile": i, "of": 6, "colour": SHADES[i], "filled": True} for i in range(6)
    ]),
    ("rows", "row n of m does the same the other way", [
        {"type": "rect", "row": i, "of": 4, "colour": SHADES[i], "filled": True} for i in range(4)
    ]),
    ("grid", "columns and rows together: a tile for the column, an explicit box for the row", [
        {"type": "rect", "at": [c * 17 + 1, r * 8 + 1], "size": [15, 6], "colour": SHADES[(c + r) % len(SHADES)], "filled": True}
        for r in range(2)
        for c in range(3)
    ]),
    ("box-effects", "a box is not just a position: it aligns what is in it and cuts off what is not", [
        {"type": "rect", "at": [0, 0], "size": [26, 16], "colour": "101820", "filled": True},
        {"type": "text", "at": [0, 5], "size": [26, 7], "font": "mini", "align": "centre", "colour": "ffffff", "text": "centred"},
        {"type": "rect", "at": [28, 0], "size": [24, 16], "colour": "201010", "filled": True},
        {"type": "text", "at": [28, 5], "size": [24, 7], "font": "mini", "colour": "ffffff", "text": "cut off here"},
    ]),
    ("clipping", "anything may be placed off the panel; what fits is drawn", [
        {"type": "circle", "at": [0, 0], "r": 8, "colour": "40a0ff"},
        {"type": "circle", "at": [51, 15], "r": 8, "colour": "ff8040"},
        {"type": "text", "at": [-10, 5], "font": "small", "colour": "ffffff", "text": "half gone"},
    ]),
    ("draw-order", "elements draw in the order given, so the last one wins where they meet", [
        {"type": "rect", "at": [4, 2], "size": [20, 12], "colour": "ff0000", "filled": True},
        {"type": "rect", "at": [16, 4], "size": [20, 10], "colour": "00ff00", "filled": True},
        {"type": "rect", "at": [28, 6], "size": [20, 8], "colour": "0000ff", "filled": True},
    ]),
    ("layers", "which is what lets a document build up: ground, then chart, then labels on top", [
        {"type": "rect", "at": [0, 0], "size": [52, 16], "colour": "080c14", "filled": True},
        {"type": "sparkline", "at": [0, 4], "size": [52, 12], "style": "area", "colour": "16304a",
         "data": [30, 45, 40, 60, 75, 65, 55, 70, 85, 95, 80, 90]},
        {"type": "text", "at": [1, 0], "font": "mini", "colour": "8090a0", "text": "load"},
        {"type": "text", "at": [36, 0], "font": "mini", "colour": "ffffff", "text": "90%"},
    ]),
    ("from-off-panel", "placement clips rather than refusing, so a thing can be animated in from outside", [
        {"type": "text", "at": [0, 4], "size": [52, 8], "font": "small", "colour": "40ffc0",
         "text": "                    arriving from the right", "animate": {"kind": "scroll", "ms": 40}},
    ]),
]


def step(dev, item, args):
    _, detail, elements = item
    dev.put(elements)
    return detail


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step))
