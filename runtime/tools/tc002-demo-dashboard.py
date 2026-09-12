#!/usr/bin/env python3
"""tc002-demo-dashboard.py: the whole point, in one script.

four dashboards a real integration might push -- weather, energy, transport, a server -- each sent
once as a layout and then fed nothing but numbers. the terminal prints the bytes each push and each
patch costs, which is the argument for the whole feature: a layout is a couple of hundred bytes
sent once, and an update is a couple of dozen.

  tc002-demo-dashboard.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]
  --updates N   how many value patches each dashboard gets (default 6)

nothing here is made up on the device: every number is generated on this machine, the way home
assistant or a script of yours would. the panel it found is put back at the end, canvas and all.
"""
import json, math, os, random, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-dashboard.py"


def weather():
    return [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "506070", "text": "amsterdam"},
        {"id": "ic", "type": "icon", "at": [44, 0], "icon": "cloud-rain", "colour": "40a0ff"},
        {"id": "t", "type": "text", "at": [0, 5], "font": "big", "colour": "ffffff", "text": "9"},
        {"id": "u", "type": "text", "at": [22, 6], "font": "mini", "colour": "808080", "text": "deg"},
        {"id": "g", "type": "sparkline", "at": [22, 11], "size": [30, 5], "style": "bars", "colour": "205070",
         "min": 0, "max": 100, "data": [40, 45, 50, 60, 55, 50, 45]},
    ]


def energy():
    return [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "506070", "text": "power"},
        {"id": "now", "type": "text", "at": [0, 5], "font": "small", "colour": "ffc000", "text": "0.0kW"},
        {"id": "bar", "type": "bar", "at": [0, 13], "size": [52, 3], "value": 0, "colour": "ffc000", "background": "201800"},
        {"id": "sun", "type": "tile", "at": [30, 0], "size": [22, 12], "icon": "sun", "label": "solar",
         "value_text": "0.0", "colour": "40ff80", "accent": "404040"},
    ]


def transport():
    return [
        {"type": "icon", "at": [0, 0], "icon": "train", "colour": "40a0ff"},
        {"type": "text", "at": [10, 0], "font": "mini", "colour": "506070", "text": "centraal"},
        {"id": "a", "type": "text", "at": [10, 6], "font": "small", "colour": "ffffff", "text": "--"},
        {"id": "b", "type": "text", "at": [10, 11], "font": "mini", "colour": "808080", "text": "--"},
        {"id": "w", "type": "icon", "at": [42, 4], "icon": "clock", "colour": "404040"},
    ]


def server():
    return [
        {"id": "c", "type": "tile", "tile": 0, "of": 3, "icon": "signal", "label": "cpu", "value_text": "0", "colour": "40ff80"},
        {"id": "m", "type": "tile", "tile": 1, "of": 3, "icon": "house", "label": "mem", "value_text": "0", "colour": "40a0ff"},
        {"id": "d", "type": "tile", "tile": 2, "of": 3, "icon": "lock", "label": "disk", "value_text": "0", "colour": "ffc000"},
    ]


REEL = [
    ("weather", "a reading big enough to read across the room, an icon and a history", weather),
    ("energy", "a live figure, a bar for the fraction and a tile for the other source", energy),
    ("transport", "two departures and a state glyph, which is mostly text and patches cheaply", transport),
    ("server", "three tiles, the shape a status board takes", server),
]

FEEDS = {
    "weather": lambda i: [
        {"id": "t", "text": str(8 + (i % 4))},
            {"id": "ic", "colour": "40a0ff" if i % 2 else "6080a0"},
        {"id": "g", "data": [max(0, min(100, 50 + int(30 * math.sin((i + n) / 2.0)))) for n in range(12)]},
    ],
    "energy": lambda i: [
        {"id": "now", "text": f"{1.0 + i * 0.4:.1f}kW"},
        {"id": "bar", "value": min(100, 15 + i * 14)},
        {"id": "sun", "text": f"{0.6 + i * 0.3:.1f}"},
    ],
    "transport": lambda i: [
        {"id": "a", "text": f"{4 + i} min"},
        {"id": "b", "text": f"then {12 + i}"},
    ],
    "server": lambda i: [
        {"id": "c", "text": str(20 + (i * 13) % 70)},
        {"id": "m", "text": str(55 + (i * 7) % 30)},
        {"id": "d", "text": str(70 + i)},
    ],
}


def step(dev, item, args):
    name, detail, build = item
    elements = build()
    layout_bytes = len(json.dumps({"elements": elements}))
    dev.put(elements)
    patch_bytes = 0
    updates = getattr(args, "updates", 6)
    for i in range(updates):
        values = FEEDS[name](i)
        patch_bytes = len(json.dumps({"values": values}))
        dev.patch(values)
        time.sleep(args.hold)
    return f"{detail}\n{'':<16}layout {layout_bytes} bytes once, then {updates} patches of {patch_bytes}"


def more_args(ap):
    ap.add_argument("--updates", type=int, default=6, help="value patches per dashboard (default 6)")


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step, extra_args=more_args))
