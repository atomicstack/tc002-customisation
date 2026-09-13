#!/usr/bin/env /usr/bin/python3
"""regenerate vendor/berry/generate/ from the vendored sources and our berry_conf.h.

berry's `coc` builds the constant string table and the fixed class tables that the interpreter
would otherwise construct at startup. this repository commits that output instead, exactly as
src/scene/zones.zig is committed from gen-zones.py: a build never needs python, and a berry bump
shows up as a reviewable diff rather than as something that happens silently on someone's machine.

run it from runtime/ after changing port/berry_conf.h or bumping the vendored tree:

    tools/gen-berry-const.py [--berry ~/git_tree/berry]

the module switches in berry_conf.h decide what coc emits, so the committed output and the config
have to be regenerated together.
"""
import argparse
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
VENDOR = HERE.parent / "vendor" / "berry"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--berry",
        default=str(pathlib.Path.home() / "git_tree" / "berry"),
        help="an upstream berry checkout, for tools/coc (not vendored: it is a build-time tool)",
    )
    args = ap.parse_args()

    coc = pathlib.Path(args.berry).expanduser() / "tools" / "coc" / "coc"
    if not coc.exists():
        print(f"coc not found at {coc}", file=sys.stderr)
        print("pass --berry <path to a berry checkout>", file=sys.stderr)
        return 1

    out = VENDOR / "generate"
    out.mkdir(parents=True, exist_ok=True)
    for stale in out.glob("*.h"):
        stale.unlink()

    subprocess.run(
        [
            "/usr/bin/python3",
            str(coc),
            "-o",
            str(out),
            str(VENDOR / "src"),
            str(VENDOR / "port"),
            "-c",
            str(VENDOR / "port" / "berry_conf.h"),
        ],
        check=True,
    )

    made = sorted(p.name for p in out.glob("*.h"))
    print(f"wrote {len(made)} headers into {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
