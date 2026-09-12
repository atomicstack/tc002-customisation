#!/usr/bin/env python3
"""tc002-demo-text.py: text on the panel, and the eight ways it can move.

the four fonts and what each is for, alignment inside a box, scrolling for anything too wide, and
then every animation the runtime has: the flipboard scramble, the typewriter, the hue walk, the
pulse, the blink and the bounce. an animation is *declared* on the element and ticked by the
device, so this script pushes once per step and then does nothing while the panel moves.

  tc002-demo-text.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

`--hold` matters more here than in the other reels: an animation wants a few seconds to be seen.
the panel it found is put back at the end, canvas and all.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-text.py"

REEL = [
    ("fonts", "all four: small has every character, mini is the menus', block and big are digits only", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "808080", "text": "mini 3x5 abc"},
        {"type": "text", "at": [0, 6], "font": "small", "colour": "ffffff", "text": "small 5x7"},
    ]),
    ("digits", "block and big carry digits and a colon, for a number read across a room", [
        {"type": "text", "at": [0, 0], "font": "block", "colour": "40a0ff", "text": "12:34"},
        {"type": "text", "at": [0, 11], "font": "mini", "colour": "606060", "text": "block 6x10"},
    ]),
    ("big", "the biggest face there is, ten by fourteen", [
        {"type": "text", "at": [2, 1], "font": "big", "colour": "ffc000", "text": "21"},
        {"type": "text", "at": [26, 4], "font": "small", "colour": "ffffff", "text": "deg"},
    ]),
    ("align", "left, centre and right inside a box that is the whole panel", [
        {"type": "text", "at": [0, 0], "size": [52, 5], "font": "mini", "align": "left", "colour": "ff4040", "text": "left"},
        {"type": "text", "at": [0, 6], "size": [52, 5], "font": "mini", "align": "centre", "colour": "40ff40", "text": "centre"},
        {"type": "text", "at": [0, 11], "size": [52, 5], "font": "mini", "align": "right", "colour": "4080ff", "text": "right"},
    ]),
    ("clipped", "a box narrower than its string cuts it off rather than running over its neighbour", [
        {"type": "text", "at": [0, 4], "size": [24, 8], "font": "small", "colour": "ffffff", "text": "clipped here"},
        {"type": "rect", "at": [24, 0], "size": [28, 16], "colour": "202020", "filled": True},
        {"type": "text", "at": [26, 4], "font": "mini", "colour": "808080", "text": "the box"},
    ]),
    ("scroll", "anything too wide can scroll instead, a pixel every 33 ms", [
        {"type": "text", "at": [0, 1], "size": [52, 7], "font": "small", "colour": "40ffc0",
         "text": "an integration sends data, not pixels", "animate": {"kind": "scroll", "ms": 33}},
        {"type": "text", "at": [0, 10], "font": "mini", "colour": "505050", "text": "scroll"},
    ]),
    ("scramble", "the flipboard: each character settles out of flipping glyphs, left to right", [
        {"type": "text", "at": [2, 4], "font": "small", "colour": "ffffff", "text": "SCRAMBLE",
         "animate": {"kind": "scramble", "ms": 2500}},
    ]),
    ("typewriter", "a character at a time, then it holds", [
        {"type": "text", "at": [0, 1], "font": "mini", "colour": "40ff40", "text": "typing this out",
         "animate": {"kind": "typewriter", "ms": 2000}},
        {"type": "text", "at": [0, 9], "font": "small", "colour": "40ff40", "text": "one by one",
         "animate": {"kind": "typewriter", "ms": 3000}},
    ]),
    ("hue", "the colour walks the wheel; the element keeps whatever it was given as its starting point", [
        {"type": "text", "at": [2, 1], "font": "small", "colour": "ff0000", "text": "hue shift",
         "animate": {"kind": "hue", "ms": 3000}},
        {"type": "text", "at": [2, 9], "font": "small", "colour": "00ff00", "text": "out of step",
         "animate": {"kind": "hue", "ms": 3000, "phase": 50}},
    ]),
    ("pulse", "brightness rides up and down, never quite to nothing", [
        {"type": "text", "at": [4, 4], "font": "small", "colour": "40a0ff", "text": "breathing",
         "animate": {"kind": "pulse", "ms": 1800}},
    ]),
    ("blink", "on for its duty, dark for the rest; three of them out of step", [
        {"type": "text", "at": [0, 5], "font": "mini", "colour": "ff4040", "text": "one",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50}},
        {"type": "text", "at": [18, 5], "font": "mini", "colour": "ffc000", "text": "two",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50, "phase": 33}},
        {"type": "text", "at": [36, 5], "font": "mini", "colour": "40ff40", "text": "three",
         "animate": {"kind": "blink", "ms": 1200, "amount": 50, "phase": 66}},
    ]),
    ("bounce", "up and down, or across with axis x; the phase keeps a row from moving in lockstep", [
        {"type": "text", "at": [2, 6], "font": "mini", "colour": "ff8000", "text": "up",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4}},
        {"type": "text", "at": [16, 6], "font": "mini", "colour": "ff8000", "text": "and",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4, "phase": 33}},
        {"type": "text", "at": [34, 6], "font": "mini", "colour": "ff8000", "text": "down",
         "animate": {"kind": "bounce", "ms": 1400, "amount": 4, "phase": 66}},
    ]),
    ("bounce-x", "the same motion along the other axis", [
        {"type": "text", "at": [16, 5], "font": "small", "colour": "c040ff", "text": "sideways",
         "animate": {"kind": "bounce", "ms": 1600, "amount": 6, "axis": "x"}},
    ]),
    ("all-at-once", "five animations on one panel, each on its own clock", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "ff0000", "text": "hue", "animate": {"kind": "hue", "ms": 2000}},
        {"type": "text", "at": [16, 0], "font": "mini", "colour": "ffffff", "text": "blink", "animate": {"kind": "blink", "ms": 900}},
        {"type": "text", "at": [38, 0], "font": "mini", "colour": "40ff40", "text": "pls", "animate": {"kind": "pulse", "ms": 1500}},
        {"type": "text", "at": [0, 6], "font": "small", "colour": "40a0ff", "text": "SETTLED", "animate": {"kind": "scramble", "ms": 2500}},
        {"type": "text", "at": [2, 12], "font": "mini", "colour": "ffc000", "text": "bouncing", "animate": {"kind": "bounce", "ms": 1100, "amount": 2}},
    ]),
]


def step(dev, item, args):
    _, detail, elements = item
    dev.put(elements)
    moving = [e["animate"]["kind"] for e in elements if "animate" in e]
    return f"{detail}" + (f"  [{', '.join(sorted(set(moving)))}]" if moving else "")


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step))
