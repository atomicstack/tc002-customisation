#!/usr/bin/env python3
"""tc002-demo-lint.py: check what every demo would send, without a device.

walks each `tc002-demo-*.py` reel and puts its documents through the same rules the runtime does --
the element and pool limits, which fields each type accepts, ids, colours, sample counts and
whether an animation suits the element carrying it. it exists because the first draft of the shapes
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

def check(where, elements, problems):
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
        biggest = max(biggest, check(f"{mod_name}/{name}", elements, problems))
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
