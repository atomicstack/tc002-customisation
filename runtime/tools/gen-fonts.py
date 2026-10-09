#!/usr/bin/env python3
"""turn the vendored pixel fonts in runtime/fonts/ into src/scene/faces.bin and faces.zig.

stdlib only: three readers (bdf, windows .fon, opentype bitmap .otb) and one output format, so
builds never need the sources or a font library. run from anywhere:

    python3 runtime/tools/gen-fonts.py
"""
import collections
import os
import struct

# one glyph as a reader returns it. rows are `h` ints with bit `w - 1` leftmost; `y` is the top
# row of the glyph counted down from the top of the source's cell (its ascent line); `x` is the
# left bearing from the pen; `advance` already holds the font's own gap between glyphs.
Glyph = collections.namedtuple('Glyph', 'cp x y w h advance rows')

# cp437 to unicode, with the graphic characters ibm drew in 0x01..0x1f and 0x7f
_LOW = [None, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022, 0x25D8, 0x25CB, 0x25D9,
        0x2642, 0x2640, 0x266A, 0x266B, 0x263C, 0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7,
        0x25AC, 0x21A8, 0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC]
CP437 = _LOW + list(range(0x20, 0x7F)) + [0x2302] + [ord(bytes([b]).decode('cp437')) for b in range(0x80, 0x100)]
assert len(CP437) == 256


def _slurp(path, mode='rb'):
    with open(path, mode, **({} if 'b' in mode else {'encoding': 'latin-1'})) as f:
        return f.read()


def _bdf_rows(hexrows, w):
    nbytes = (w + 7) // 8
    return [int(r[:nbytes * 2], 16) >> (nbytes * 8 - w) if w else 0 for r in hexrows]


def read_bdf(path):
    """(cell height, glyphs) from a bdf; the cell is the font's ascent plus its descent."""
    lines = _slurp(path, 'r').split('\n')
    ascent = descent = None
    glyphs, i = [], 0
    while i < len(lines):
        parts = lines[i].split()
        if parts[:1] == ['FONT_ASCENT']:
            ascent = int(parts[1])
        elif parts[:1] == ['FONT_DESCENT']:
            descent = int(parts[1])
        elif parts[:1] == ['STARTCHAR']:
            props = {}
            while not lines[i].startswith('BITMAP'):
                k, *v = lines[i].split()
                props[k] = v
                i += 1
            i += 1
            hexrows = []
            while not lines[i].startswith('ENDCHAR'):
                hexrows.append(lines[i].strip())
                i += 1
            cp = int(props['ENCODING'][0])
            if cp >= 0:
                w, h, bx, by = map(int, props['BBX'])
                adv = int(props['DWIDTH'][0])
                glyphs.append(Glyph(cp, bx, ascent - (by + h), w, h, adv, _bdf_rows(hexrows, w)))
        i += 1
    if ascent is None or descent is None:
        raise ValueError(f'{path}: no FONT_ASCENT/FONT_DESCENT')
    return ascent + descent, glyphs


def read_fon(path):
    """(cell height, glyphs) from a windows .fon: an ne container around one fnt v2/v3 resource,
    in cp437, mapped to unicode. byte 0x00 is dropped."""
    d = _slurp(path)
    ne = struct.unpack_from('<H', d, 0x3C)[0]
    rt = ne + struct.unpack_from('<H', d, ne + 0x24)[0]
    shift = struct.unpack_from('<H', d, rt)[0]
    p = rt + 2
    while True:
        rtype, count = struct.unpack_from('<HH', d, p)
        p += 8
        if rtype == 0:
            raise ValueError(f'{path}: no font resource')
        for _ in range(count):
            off = struct.unpack_from('<H', d, p)[0]
            p += 12
            if rtype == 0x8008:
                return _fnt(d[off << shift:], path)


def _fnt(f, path):
    version = struct.unpack_from('<H', f, 0)[0]
    if version not in (0x200, 0x300):
        raise ValueError(f'{path}: fnt version {version:#x}')
    height = struct.unpack_from('<H', f, 0x58)[0]
    first, last = f[0x5F], f[0x60]
    table, entry = {0x200: (0x76, 4), 0x300: (0x94, 6)}[version]
    glyphs = []
    for c in range(first, last + 1):
        e = table + (c - first) * entry
        w = struct.unpack_from('<H', f, e)[0]
        o = struct.unpack_from('<H' if version == 0x200 else '<I', f, e + 2)[0]
        stripes = (w + 7) // 8
        rows = []
        for r in range(height):
            v = 0
            for s in range(stripes):  # column-major: all rows of each 8-pixel stripe in turn
                v = (v << 8) | f[o + s * height + r]
            rows.append(v >> (stripes * 8 - w))
        if c == 0:
            continue
        glyphs.append(Glyph(CP437[c], 0, 0, w, height, w, rows))
    return height, glyphs


def read_otb(path):
    """(cell height, glyphs) from an opentype bitmap font with one strike: cmap 4 or 12, eblc
    index format 1 with ebdt image format 2, or index format 2 with image format 5. anything else
    is refused rather than guessed at."""
    d = _slurp(path)
    n = struct.unpack_from('>H', d, 4)[0]
    tables = {}
    for i in range(n):
        tag, _, off, _ = struct.unpack_from('>4sIII', d, 12 + 16 * i)
        tables[tag.decode()] = off
    cmap = _cmap(d, tables['cmap'], path)
    eblc, ebdt = tables['EBLC'], tables['EBDT']
    if struct.unpack_from('>I', d, eblc + 4)[0] != 1:
        raise ValueError(f'{path}: expected exactly one strike')
    st = eblc + 8
    ista, _, nsub = struct.unpack_from('>III', d, st)
    asc, desc = struct.unpack_from('>bb', d, st + 16)
    bitmaps = {}
    for k in range(nsub):
        first, last, add = struct.unpack_from('>HHI', d, eblc + ista + 8 * k)
        h = eblc + ista + add
        ifmt, imgfmt, imgoff = struct.unpack_from('>HHI', d, h)
        if ifmt == 1 and imgfmt == 2:
            for gid in range(first, last + 1):
                a, b = struct.unpack_from('>II', d, h + 8 + 4 * (gid - first))
                if b > a:
                    p = ebdt + imgoff + a
                    gh, gw, bx, by, adv = struct.unpack_from('>BBbbB', d, p)
                    bitmaps[gid] = (gw, gh, bx, by, adv, _bits(d, p + 5, gw, gh))
        elif ifmt == 2 and imgfmt == 5:
            size = struct.unpack_from('>I', d, h + 8)[0]
            gh, gw, hbx, hby, hadv = struct.unpack_from('>BBbbB', d, h + 12)
            for gid in range(first, last + 1):
                p = ebdt + imgoff + size * (gid - first)
                bitmaps[gid] = (gw, gh, hbx, hby, hadv, _bits(d, p, gw, gh))
        else:
            raise ValueError(f'{path}: unsupported eblc index {ifmt} / ebdt image {imgfmt}')
    glyphs = []
    for cp, gid in sorted(cmap.items()):
        if gid in bitmaps:
            gw, gh, bx, by, adv, rows = bitmaps[gid]
            glyphs.append(Glyph(cp, bx, asc - by, gw, gh, adv, rows))
    return asc - desc, glyphs


def _bits(d, p, w, h):
    """rows from bit-aligned data: msb first, no padding between rows."""
    total = w * h
    if total == 0:
        return [0] * h
    raw = int.from_bytes(d[p:p + (total + 7) // 8], 'big') >> ((-total) % 8)
    return [(raw >> (w * (h - 1 - r))) & ((1 << w) - 1) for r in range(h)]


def _cmap(d, o, path):
    best = None
    for i in range(struct.unpack_from('>H', d, o + 2)[0]):
        plat, enc, so = struct.unpack_from('>HHI', d, o + 4 + 8 * i)
        fmt = struct.unpack_from('>H', d, o + so)[0]
        if (plat, enc) in ((3, 10), (0, 4), (0, 6)) and fmt == 12:
            best = (o + so, 12)
        elif (plat, enc) in ((3, 1), (0, 3)) and fmt == 4 and (best is None or best[1] != 12):
            best = (o + so, 4)
    if best is None:
        raise ValueError(f'{path}: no unicode cmap')
    q, fmt = best
    out = {}
    if fmt == 4:
        seg = struct.unpack_from('>H', d, q + 6)[0] // 2
        ends = struct.unpack_from(f'>{seg}H', d, q + 14)
        starts = struct.unpack_from(f'>{seg}H', d, q + 16 + 2 * seg)
        deltas = struct.unpack_from(f'>{seg}h', d, q + 16 + 4 * seg)
        ro_at = q + 16 + 6 * seg
        ranges = struct.unpack_from(f'>{seg}H', d, ro_at)
        for s, (a, b, dl, ro) in enumerate(zip(starts, ends, deltas, ranges)):
            if a == 0xFFFF:
                continue
            for c in range(a, b + 1):
                if ro == 0:
                    gid = (c + dl) & 0xFFFF
                else:
                    gid = struct.unpack_from('>H', d, ro_at + 2 * s + ro + 2 * (c - a))[0]
                    gid = (gid + dl) & 0xFFFF if gid else 0
                if gid:
                    out[c] = gid
    else:
        ngroups = struct.unpack_from('>I', d, q + 12)[0]
        for g in range(ngroups):
            a, b, gid0 = struct.unpack_from('>III', d, q + 16 + 12 * g)
            for c in range(a, b + 1):
                out[c] = gid0 + c - a
    return out


HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'fonts')
OUT = os.path.join(HERE, '..', 'src', 'scene')

# (name, reader, file) in wire order. the canvas and clock font enums append these names in this
# order, so this list only ever grows at the end.
FACES = [
    ('chunky6', read_bdf, 'matrix/MatrixChunky6.bdf'),
    ('chunky6x', read_bdf, 'matrix/MatrixChunky6X.bdf'),
    ('light6', read_bdf, 'matrix/MatrixLight6.bdf'),
    ('light6x', read_bdf, 'matrix/MatrixLight6X.bdf'),
    ('chunky8', read_bdf, 'matrix/MatrixChunky8.bdf'),
    ('chunky8x', read_bdf, 'matrix/MatrixChunky8X.bdf'),
    ('chunky8x6', read_bdf, 'matrix/MatrixChunky8x6.bdf'),
    ('light8', read_bdf, 'matrix/MatrixLight8.bdf'),
    ('light8x', read_bdf, 'matrix/MatrixLight8X.bdf'),
    ('light8x6', read_bdf, 'matrix/MatrixLight8x6.bdf'),
    ('tiny5', read_bdf, 'tiny5/Tiny5.bdf'),
    ('tiny5-duo', read_bdf, 'tiny5/Tiny5Duo.bdf'),
    ('tiny5-mono', read_bdf, 'tiny5/Tiny5Mono.bdf'),
    ('phoenix', read_fon, 'int10h/Bm437_Phoenix_BIOS.FON'),
    ('phoenix-2y', read_fon, 'int10h/Bm437_Phoenix_BIOS-2y.FON'),
    ('phoenix-8x14', read_fon, 'int10h/Bm437_PhoenixVGA_8x14.FON'),
    ('ibm-iso8', read_fon, 'int10h/Bm437_IBM_DOS_ISO8.FON'),
    ('apricot-xenc', read_fon, 'int10h/Bm437_ApricotXenC.FON'),
    ('robotron-a7100', read_fon, 'int10h/Bm437_Robotron_A7100.FON'),
    ('ibm-vga', read_otb, 'int10h/BmPlus_IBM_VGA_8x16.otb'),
]


def _text_cp(cp):
    """the characters a line box is measured from: printable ascii and latin-1"""
    return 0x20 <= cp <= 0x7E or 0xA0 <= cp <= 0xFF


def _ink(g):
    """(first, last) lit row in cell coordinates, or None for a blank glyph"""
    lit = [r for r, v in enumerate(g.rows) if v]
    return (g.y + lit[0], g.y + lit[-1]) if lit else None


def trim(glyphs):
    """(height, glyphs) cropped to the union of the ink rows of ascii and latin-1. a 16-row cell
    whose text sits in rows 2..12 becomes an 11-row face; anything reaching outside those rows
    (box drawing, full blocks) is clipped to them. each glyph is also cropped to its own ink."""
    spans = [s for g in glyphs if _text_cp(g.cp) for s in [_ink(g)] if s]
    top, bottom = min(s[0] for s in spans), max(s[1] for s in spans)
    out = []
    for g in glyphs:
        rows = [(g.y + r, v) for r, v in enumerate(g.rows) if top <= g.y + r <= bottom]
        lit = [i for i, (_, v) in enumerate(rows) if v]
        if not lit:
            out.append(Glyph(g.cp, 0, 0, 0, 0, g.advance, []))
            continue
        rows = rows[lit[0]:lit[-1] + 1]
        out.append(Glyph(g.cp, g.x, rows[0][0] - top, g.w, len(rows), g.advance, [v for _, v in rows]))
    return bottom - top + 1, out


def load_all():
    """[(name, height, glyphs sorted by codepoint)] for every face in FACES"""
    faces = []
    for name, reader, rel in FACES:
        _, glyphs = reader(os.path.join(FONTS, rel))
        unique = {g.cp: g for g in glyphs}  # the last of a duplicated encoding wins
        height, trimmed = trim([unique[c] for c in sorted(unique)])
        faces.append((name, height, trimmed))
    return faces


def _pack_rows(g):
    total = g.w * g.h
    v = 0
    for r in g.rows:
        v = (v << g.w) | r
    v <<= (-total) % 8
    return v.to_bytes((total + 7) // 8, 'big') if total else b''


def _ident(name):
    return name if name.replace('_', '').isalnum() and not name[0].isdigit() else f'@"{name}"'


def render(faces):
    """(faces.bin, faces.zig). per face: an index of 11-byte entries sorted by codepoint -- cp u24
    be, x i8, y i8, w u8, h u8, advance u8, bits u24 be (from the face's bitmap area) -- then the
    bitmaps, w*h bits msb first, each glyph starting on a byte."""
    blob, metrics = bytearray(), []
    for name, height, glyphs in faces:
        bitmaps, index = bytearray(), bytearray()
        for g in glyphs:
            if not (-128 <= g.x <= 127 and 0 <= g.y <= 127 and g.w < 256 and g.h < 256 and g.advance < 256):
                raise ValueError(f'{name}: glyph {g.cp:#x} does not fit an index entry')
            index += g.cp.to_bytes(3, 'big') + struct.pack('>bbBBB', g.x, g.y, g.w, g.h, g.advance)
            index += len(bitmaps).to_bytes(3, 'big')
            bitmaps += _pack_rows(g)
        metrics.append((height, len(glyphs), len(blob), len(blob) + len(index)))
        blob += index + bitmaps
    lines = [
        '//! generated by runtime/tools/gen-fonts.py from runtime/fonts/; do not edit by hand.',
        '//! the imported faces in wire order, and where each one sits in faces.bin. face.zig reads',
        '//! the blob and describes its layout.',
        '',
        'pub const Name = enum(u8) { ' + ', '.join(_ident(f[0]) for f in faces) + ' };',
        '',
        '/// `height` is the trimmed line box; `index` and `bitmaps` are byte offsets into `blob`',
        'pub const Metrics = struct { height: u8, count: u16, index: u32, bitmaps: u32 };',
        '',
        'pub const metrics = [_]Metrics{',
    ]
    for (name, *_), (h, n, i, b) in zip(faces, metrics):
        lines.append(f'    .{{ .height = {h}, .count = {n}, .index = {i}, .bitmaps = {b} }}, // {name}')
    lines += ['};', '', 'pub const blob: []const u8 = @embedFile("faces.bin");', '']
    return bytes(blob), '\n'.join(lines)


def main():
    faces = load_all()
    blob, zig = render(faces)
    with open(os.path.join(OUT, 'faces.bin'), 'wb') as f:
        f.write(blob)
    with open(os.path.join(OUT, 'faces.zig'), 'w') as f:
        f.write(zig)
    for name, height, glyphs in faces:
        print(f'{name:16} {height:2} rows {len(glyphs):5} glyphs')
    print(f'faces.bin: {len(blob)} bytes ({len(blob) / 1024:.1f} kib), {len(faces)} faces')


if __name__ == '__main__':
    main()
