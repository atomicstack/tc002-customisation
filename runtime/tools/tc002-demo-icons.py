#!/usr/bin/env python3
"""tc002-demo-icons.py: every built-in icon, five at a time with its name under it.

the set is fetched from the device rather than listed here, so this script always shows what that
build actually has. each icon is 8x8 and monochrome and takes the element's colour, which is why
they suit a panel where the palette belongs to the document rather than to the artwork.

  tc002-demo-icons.py -s <device-ip> [--token-file FILE | --token HEX] [--hold S] [--only ...]

  --only takes icon names rather than page names, and pages whatever it is given:
      tc002-demo-icons.py -s … --only sun,cloud-rain,bell,heart
  --list prints the pages and exits

the panel it found is put back at the end, canvas and all.
"""
import os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tc002demo  # noqa: e402

NAME = "tc002-demo-icons.py"
PER_PAGE = 5
COLOURS = ("ffffff", "40a0ff", "40ff80", "ffc000", "ff6060")


def elements_for(chunk):
    els = []
    for n, name in enumerate(chunk):
        x = n * 10 + 1
        els.append({"type": "icon", "at": [x, 0], "icon": name, "colour": COLOURS[n % len(COLOURS)]})
        # the name under it, in the smallest font, clipped to its own column
        els.append({"type": "text", "at": [x - 1, 9], "size": [10, 6], "font": "mini", "colour": "505050", "text": name})
    return els


def build(dev, args):
    """the reel comes from the device: a build with a different set still demos correctly"""
    names = dev.icons().get("names")
    if not names:
        tc002demo.die(NAME, "the device lists no icons (older build?)")
    if args.only:
        wanted = [w.strip() for w in args.only.split(",") if w.strip()]
        unknown = [w for w in wanted if w not in names]
        if unknown:
            tc002demo.die(NAME, f"the device has no icon called {unknown[0]!r}; it has {len(names)} others")
        names = wanted
    else:
        print(f"{NAME}: the device has {len(names)} icons at 8x8")
    return [
        (f"page-{i // PER_PAGE + 1}", ", ".join(names[i : i + PER_PAGE]), names[i : i + PER_PAGE])
        for i in range(0, len(names), PER_PAGE)
    ]


def step(dev, item, args):
    _, detail, chunk = item
    dev.put(elements_for(chunk))
    return detail


if __name__ == "__main__":
    sys.exit(tc002demo.run(NAME, __doc__, build, step))
