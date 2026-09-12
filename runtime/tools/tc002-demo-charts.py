#!/usr/bin/env python3
"""tc002-demo-charts.py: sparklines and bars, which is what a panel this shape is actually for.

the three sparkline styles, autoscaling against a fixed range, thresholds that recolour the samples
that cross them, the sweep that draws a line in when its data changes, and the compact hex form for
samples. the last step runs live: it patches new samples every hold and lets the sweep replay, which
is the shape a real integration takes -- push the layout once, then send numbers.

  tc002-demo-charts.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

the panel it found is put back at the end, canvas and all.
"""
import math, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-charts.py"

WAVE = [int(50 + 45 * math.sin(i / 4.0)) for i in range(52)]
CLIMB = [int(5 + i * 1.8) for i in range(52)]
SPIKY = [20, 24, 22, 28, 90, 30, 26, 24, 60, 28, 25, 27, 30, 95, 33, 29]

REEL = [
    ("line", "one pixel per column, joined so a steep change is a line rather than two dots", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "line"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "line", "colour": "40ffc0", "data": WAVE},
    ]),
    ("bars", "filled from the value down, which reads better for counts", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "bars"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "bars", "colour": "40a0ff", "data": WAVE},
    ]),
    ("area", "the same, filled solid", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "area"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "area", "colour": "8060ff", "data": WAVE},
    ]),
    ("autoscale", "with no min and max it scales to whatever the samples span, so a flat line is flat", [
        {"type": "sparkline", "at": [0, 0], "size": [52, 7], "style": "line", "colour": "ffc000", "data": [40, 41, 40, 42, 41, 40, 41]},
        {"type": "sparkline", "at": [0, 9], "size": [52, 7], "style": "line", "colour": "ff6000", "data": [0, 30, 60, 90, 60, 30, 0]},
    ]),
    ("fixed-range", "the same two samples again, both pinned to 0..100: now they are comparable", [
        {"type": "sparkline", "at": [0, 0], "size": [52, 7], "style": "line", "colour": "ffc000", "min": 0, "max": 100,
         "data": [40, 41, 40, 42, 41, 40, 41]},
        {"type": "sparkline", "at": [0, 9], "size": [52, 7], "style": "line", "colour": "ff6000", "min": 0, "max": 100,
         "data": [0, 30, 60, 90, 60, 30, 0]},
    ]),
    ("threshold", "samples at or above the threshold draw in the other colour", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "over 50"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "bars", "colour": "40a0ff",
         "min": 0, "max": 100, "threshold": 50, "over": "ff4000", "data": SPIKY},
    ]),
    ("sweep", "a sweep draws it in from the left, and starts again whenever the data changes", [
        {"type": "sparkline", "at": [0, 2], "size": [52, 12], "style": "area", "colour": "40ff60",
         "data": CLIMB, "animate": {"kind": "sweep", "ms": 2000}},
    ]),
    ("hex", "the same samples as data_hex: 52 of them cost 208 characters as digits, 104 as hex", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "505050", "text": "data_hex"},
        {"type": "sparkline", "at": [0, 6], "size": [52, 10], "style": "bars", "colour": "ff8040",
         "data_hex": "".join(f"{v:02x}" for v in WAVE)},
    ]),
    ("mixed", "a reading, a level and a history, which is most of what a dashboard ever needs", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "606060", "text": "living room"},
        {"type": "text", "at": [0, 5], "font": "small", "colour": "ffffff", "text": "20.4C"},
        {"type": "bar", "at": [34, 6], "size": [18, 3], "value": 62, "colour": "40a0ff", "background": "101820"},
        {"type": "sparkline", "at": [0, 13], "size": [52, 3], "style": "bars", "colour": "208040",
         "min": 0, "max": 100, "data": WAVE[:26]},
    ]),
    ("live", "the layout goes once and then only numbers move: five patches, no pixels", [
        {"type": "text", "at": [0, 0], "font": "mini", "colour": "606060", "text": "live"},
        {"id": "n", "type": "text", "at": [0, 5], "font": "small", "colour": "ffffff", "text": "--"},
        {"id": "lvl", "type": "bar", "at": [34, 6], "size": [18, 3], "value": 0, "colour": "40a0ff", "background": "101820"},
        {"id": "g", "type": "sparkline", "at": [0, 13], "size": [52, 3], "style": "bars", "colour": "40ff60",
         "min": 0, "max": 100, "data": [0], "animate": {"kind": "sweep", "ms": 600}},
    ]),
]


def step(dev, item, args):
    name, detail, elements = item
    dev.put(elements)
    if name != "live":
        return detail
    # the point of the whole feature: the layout is already there, so only values travel
    history = []
    for i in range(5):
        value = int(50 + 40 * math.sin(i / 1.5))
        history = (history + [value])[-26:]
        dev.patch([
            {"id": "n", "text": f"{value / 4:.1f}C"},
            {"id": "lvl", "value": value},
            {"id": "g", "data": history},
        ])
        time.sleep(args.hold)
    return f"{detail}  (5 patches of three values each)"


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, REEL, step))
