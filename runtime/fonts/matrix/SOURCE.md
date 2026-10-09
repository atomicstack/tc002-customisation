# matrix fonts

- upstream: https://github.com/trip5/Matrix-Fonts
- commit: fbd3b6c471f479efa05a83f867a0ece7920b1aa4, fetched 2026-10-09
- files: `6-series/Matrix{Chunky,Light}6{,X}.bdf`, `8-series/Matrix{Chunky,Light}8{,X,x6}.bdf`, `LICENSE`
- licence: mit (see `LICENSE`)

the bdfs are vendored untouched. `runtime/tools/gen-fonts.py` turns them into
`runtime/src/scene/faces.bin`.
