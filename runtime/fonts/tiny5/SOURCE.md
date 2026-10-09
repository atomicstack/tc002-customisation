# tiny5

- upstream: https://github.com/Gissio/font_tiny5 (designed by stefan schmidt; google fonts: https://fonts.google.com/specimen/Tiny5)
- commit: 42560bb39e6c5daddc958bf0c5df1c04ccedbe9e, fetched 2026-10-09
- files: `fonts/bdf/Tiny5.bdf`, `Tiny5Duo.bdf`, `Tiny5Mono.bdf`, `OFL.txt`
- licence: sil open font license 1.1 (see `OFL.txt`)

the bdfs are vendored untouched. `runtime/tools/gen-fonts.py` turns them into
`runtime/src/scene/faces.bin`.
