#!/usr/bin/env python3
"""tc002-demo-tiles.py: status tiles, the composite an integration reaches for first.

a tile is a glyph, a label and a reading, and the one place the device makes a layout decision for
you: given about twenty pixels of width it puts the glyph on the left with the label over the value;
narrower than that the label is dropped rather than squeezed into two characters, and the value goes
under the glyph. the reel shows the same tile at four widths so the switch is visible, then a live
one where only the readings move.

  tc002-demo-tiles.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

the panel it found is put back at the end, canvas and all.
"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-tiles.py"


def tile(at, size, icon, label, value, colour, accent="404040", **extra):
    el = {"type": "tile", "at": at, "size": size, "icon": icon, "label": label,
          "value_text": value, "colour": colour, "accent": accent}
    el.update(extra)
    return el


REEL = [
    ("full-width", "the whole panel: glyph left, label over value", [
        tile([0, 0], [52, 16], "thermometer", "lounge", "21.4C", "ff8000"),
    ]),
    ("halves", "two across: still wide enough for the label", [
        tile([0, 0], [26, 16], "thermometer", "in", "21.4", "ff8000"),
        tile([26, 0], [26, 16], "cloud-rain", "out", "9.2", "40a0ff"),
    ]),
    ("thirds", "17 px each: too narrow for a label, so it goes and the value sits under the glyph", [
        {"type": "tile", "tile": 0, "of": 3, "icon": "thermometer", "label": "in", "value_text": "21", "colour": "ff8000"},
        {"type": "tile", "tile": 1, "of": 3, "icon": "droplet", "label": "hum", "value_text": "48", "colour": "40a0ff"},
        {"type": "tile", "tile": 2, "of": 3, "icon": "cloud-rain", "label": "out", "value_text": "9", "colour": "40ff80"},
    ]),
    ("quarters", "four across, at the edge of legibility", [
        {"type": "tile", "tile": i, "of": 4, "icon": ic, "label": lb, "value_text": v, "colour": c}
        for i, (ic, lb, v, c) in enumerate((
            ("sun", "uv", "3", "ffc000"),
            ("droplet", "hum", "48", "40a0ff"),
            ("flame", "gas", "12", "ff6040"),
            ("bulb", "on", "6", "ffff80"),
        ))
    ]),
    ("rows", "stacked, and 8 px is too short for two lines, so each keeps its reading", [
        {"type": "tile", "row": 0, "of": 2, "icon": "house", "label": "inside", "value_text": "21.4C", "colour": "ff8000", "accent": "404040"},
        {"type": "tile", "row": 1, "of": 2, "icon": "cloud-snow", "label": "outside", "value_text": "-1.2C", "colour": "40c0ff", "accent": "404040"},
    ]),
    ("accent", "the label takes the accent colour, the value the element's; the glyph follows the value", [
        tile([0, 0], [52, 16], "bulb", "kitchen", "on", "ffff40", accent="806000"),
    ]),
    ("icons", "any of the built-in icons; the glyph is tinted, so it fits whatever the tile is doing", [
        {"type": "tile", "tile": 0, "of": 3, "icon": "battery-half", "label": "bat", "value_text": "64", "colour": "40ff80"},
        {"type": "tile", "tile": 1, "of": 3, "icon": "wifi", "label": "net", "value_text": "-52", "colour": "40a0ff"},
        {"type": "tile", "tile": 2, "of": 3, "icon": "bell", "label": "msg", "value_text": "3", "colour": "ffc000"},
    ]),
    ("animated", "a tile animates like anything else: this one pulses when it matters", [
        tile([0, 0], [52, 16], "warning", "boiler", "fault", "ff4040", accent="602020",
             animate={"kind": "pulse", "ms": 1200}),
    ]),
    ("live", "the readings change and nothing else does: five patches against one layout", [
        {"id": "a", "type": "tile", "tile": 0, "of": 3, "icon": "thermometer", "label": "in", "value_text": "--", "colour": "ff8000"},
        {"id": "b", "type": "tile", "tile": 1, "of": 3, "icon": "droplet", "label": "hum", "value_text": "--", "colour": "40a0ff"},
        {"id": "c", "type": "tile", "tile": 2, "of": 3, "icon": "bulb", "label": "lux", "value_text": "--", "colour": "ffff80"},
    ]),
]


def step(dev, item, args):
    name, detail, elements = item
    dev.put(elements)
    if name != "live":
        return detail
    for i in range(5):
        dev.patch([
            {"id": "a", "text": f"{20 + i}"},
            {"id": "b", "text": f"{45 + i * 2}"},
            {"id": "c", "text": f"{i * 17}"},
        ])
        time.sleep(args.hold)
    return f"{detail}  (a patch's text replaces a tile's value, never its label)"


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step))
