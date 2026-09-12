#!/usr/bin/env python3
"""tc002-demo-lint.py: check what every demo would send, without a device.

walks each `tc002-demo-*.py` reel and puts its documents through the same rules the runtime does --
the element and pool limits, which fields each type accepts, ids, colours, sample counts and
whether an animation suits the element carrying it -- and where the ink actually lands: text that
runs off an edge, two pieces of text on the same pixels, a tile label too wide for its tile. a step
whose point is to run off an edge names itself in the demo's `LINT_ALLOW`. it exists because the first draft of the shapes
reel asked for 26 elements against a limit of 24, and that is the sort of mistake worth catching on
this machine rather than on the panel.

  tc002-demo-lint.py            (from the repository root, or anywhere: paths are resolved here)

exits non-zero with a list if anything would be refused.
"""
import os
import importlib.util, json, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

COMMON = {"type", "id", "at", "size", "tile", "row", "of", "colour", "animate"}
PER_TYPE = {
    "text": {"text", "font", "align"}, "rect": {"filled"}, "line": {"to"},
    "circle": {"r", "filled"}, "pixel": set(),
    "bar": {"value", "background", "vertical"},
    "sparkline": {"data", "data_hex", "style", "min", "max", "threshold", "over"},
    "icon": {"icon"}, "sprite": {"sprite"},
    "tile": {"icon", "sprite", "label", "value_text", "accent"},
}
MOTIONS = {"hue", "bounce", "scramble", "scroll", "blink", "pulse", "typewriter", "sweep"}
ONLY_ON = {"scramble": {"text"}, "typewriter": {"text"}, "scroll": {"text"}, "sweep": {"sparkline"}}
REQUIRED = {"text": {"text"}, "line": {"to"}, "icon": {"icon"}, "sprite": {"sprite"}, "tile": {"value_text"}}

def colour_ok(v):
    return isinstance(v, str) and len(v) == 6 and all(c in "0123456789abcdefABCDEF" for c in v)

PANEL_W, PANEL_H = 52, 16
# advance per character and height, as the device's own faces measure them (font.zig, clockfont.zig)
FACES = {"small": (6, 7), "mini": (4, 5), "block": (7, 10), "big": (12, 14)}
GLYPH = 8  # a built-in icon, and the smaller of the two sprite sizes


def text_w(face, text):
    adv, _ = FACES[face]
    return 0 if not text else len(text) * adv - (adv - {"small": 5, "mini": 3, "block": 6, "big": 10}[face])


def box_of(e):
    """the element's box in pixels, however it was expressed"""
    if "tile" in e:
        m = max(1, e.get("of", 1)); i = min(e["tile"], m - 1)
        x0, x1 = i * PANEL_W // m, (i + 1) * PANEL_W // m
        return x0, 0, x1 - x0, PANEL_H
    if "row" in e:
        m = max(1, e.get("of", 1)); i = min(e["row"], m - 1)
        y0, y1 = i * PANEL_H // m, (i + 1) * PANEL_H // m
        return 0, y0, PANEL_W, y1 - y0
    x, y = e.get("at", [0, 0])
    w, h = e.get("size", [0, 0])
    return x, y, w, h


def extent(e):
    """where a text element actually puts ink, or None when it is not text"""
    if e.get("type") != "text":
        return None
    face = e.get("font", "small")
    if face not in FACES:
        return None
    x, y, w, h = box_of(e)
    tw, th = text_w(face, e["text"]), FACES[face][1]
    a = e.get("animate") or {}
    if a.get("kind") == "bounce":
        amount = a.get("amount", 2)
        if a.get("axis") == "x":
            x -= amount; tw += 2 * amount
        else:
            y -= amount; th += 2 * amount
    if w > 0:  # an explicit box is a declaration that clipping is intended
        tw = min(tw, w)
        if e.get("align") == "centre":
            x += (w - tw) // 2
        elif e.get("align") == "right":
            x += w - tw
    return x, y, tw, th, bool(w > 0), a.get("kind")


def overlaps(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]

def check(where, elements, problems, allow=()):
    deliberate = where.split("/", 1)[1] in allow
    if len(elements) > 24:
        problems.append(f"{where}: {len(elements)} elements, the limit is 24")
    text_bytes = 0
    for n, e in enumerate(elements):
        t = e.get("type")
        if t not in PER_TYPE:
            problems.append(f"{where}[{n}]: unknown type {t!r}"); continue
        allowed = COMMON | PER_TYPE[t]
        for k in e:
            if k not in allowed:
                problems.append(f"{where}[{n}] ({t}): field {k!r} does not belong to that type")
        for k in REQUIRED.get(t, set()):
            if k not in e:
                problems.append(f"{where}[{n}] ({t}): missing required {k!r}")
        if "id" in e and not (1 <= len(e["id"]) <= 8):
            problems.append(f"{where}[{n}]: id {e['id']!r} is not 1..8 characters")
        for k in ("colour", "background", "over", "accent"):
            if k in e and not colour_ok(e[k]):
                problems.append(f"{where}[{n}]: {k}={e[k]!r} is not rrggbb")
        if ("tile" in e or "row" in e) and ("at" in e or "size" in e):
            problems.append(f"{where}[{n}]: tile/row does not combine with at/size")
        if ("tile" in e or "row" in e) and "of" not in e:
            problems.append(f"{where}[{n}]: tile/row needs of")
        if "data" in e and len(e["data"]) > 52:
            problems.append(f"{where}[{n}]: {len(e['data'])} samples, the limit is 52")
        if "data_hex" in e and len(e["data_hex"]) > 104:
            problems.append(f"{where}[{n}]: data_hex is {len(e['data_hex'])} characters, the limit is 104")
        for k in ("text", "label", "value_text"):
            if k in e:
                text_bytes += len(e[k])
        a = e.get("animate")
        if a:
            if a.get("kind") not in MOTIONS:
                problems.append(f"{where}[{n}]: unknown motion {a.get('kind')!r}")
            elif a["kind"] in ONLY_ON and t not in ONLY_ON[a["kind"]]:
                problems.append(f"{where}[{n}]: {a['kind']} does not suit a {t}")
            if a.get("phase", 0) > 100:
                problems.append(f"{where}[{n}]: phase {a['phase']} is over 100")
    # where the ink actually lands: the demos are meant to read, and the panel is 52x16. text that
    # runs off an edge or sits on its neighbour is the one mistake these reels kept making.
    ink = []
    for n, e in enumerate(elements):
        ex = extent(e)
        if ex is None:
            continue
        x, y, w, h, boxed, motion = ex
        if not boxed and motion != "scroll" and not deliberate:
            if x < 0 or x + w > PANEL_W:
                problems.append(f"{where}[{n}]: {e['text']!r} spans x {x}..{x + w - 1} and the panel is {PANEL_W} wide")
            if y < 0 or y + h > PANEL_H:
                problems.append(f"{where}[{n}]: {e['text']!r} spans y {y}..{y + h - 1} and the panel is {PANEL_H} tall")
        if motion != "scroll":
            ink.append((n, (x, y, w, h)))
    for i in range(len(ink)):
        for j in range(i + 1, len(ink)):
            if overlaps(ink[i][1], ink[j][1]):
                problems.append(f"{where}[{ink[i][0]}] and [{ink[j][0]}]: two pieces of text on the same pixels")
    # a tile lays itself out, and drops a label it cannot fit: worth knowing before the panel does it
    for n, e in enumerate(elements):
        if e.get("type") != "tile" or not e.get("label"):
            continue
        _, _, w, h = box_of(e)
        w = w or PANEL_W
        h = h or PANEL_H
        glyph = 16 if e.get("sprite") else GLYPH
        if w < glyph + 12 or h < 2 * FACES["mini"][1] + 1:
            continue  # too narrow or too short for a label at all, which the tile documents
        if text_w("mini", e["label"]) > w - (glyph + 2):
            problems.append(f"{where}[{n}]: the label {e['label']!r} is too wide for this tile and will be dropped")
    if text_bytes > 256:
        problems.append(f"{where}: {text_bytes} bytes of text, the pool is 256")
    body = len(json.dumps({"elements": elements}))
    if body > 8192:
        problems.append(f"{where}: the body is {body} bytes, the limit is 8192")
    return body

problems, biggest = [], 0
for mod_name in ("shapes", "text", "charts", "images", "layout", "tiles", "dashboard"):
    spec = importlib.util.spec_from_file_location(f"d_{mod_name}", os.path.join(HERE, f"tc002-demo-{mod_name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for stepdef in mod.REEL:
        name, _detail, payload = stepdef
        if payload is None:
            continue
        elements = payload() if callable(payload) else payload
        allow = getattr(mod, "LINT_ALLOW", ())
        biggest = max(biggest, check(f"{mod_name}/{name}", elements, problems, allow))
# the icons demo builds its pages from the device, so check its page builder directly
spec = importlib.util.spec_from_file_location("d_icons", os.path.join(HERE, "tc002-demo-icons.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
biggest = max(biggest, check("icons/page", mod.elements_for(["cloud-rain", "thermometer", "battery-full", "bluetooth", "snowflake"]), problems))

print(f"checked every document in eight demos; the largest is {biggest} bytes of json")
if problems:
    print(f"{len(problems)} problem(s):")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("all within the documented limits")
