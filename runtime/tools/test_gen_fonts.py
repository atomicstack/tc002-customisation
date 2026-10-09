"""the font generator: its three readers against the vendored files, and its output.

run: python3 -I -m unittest test_gen_fonts -v   (from runtime/tools)
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, '..', 'fonts')
_spec = importlib.util.spec_from_file_location('gen_fonts', os.path.join(HERE, 'gen-fonts.py'))
gf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gf)


def art(g):
    return [''.join('#' if r >> (g.w - 1 - c) & 1 else '.' for c in range(g.w)) for r in g.rows]


def by_cp(glyphs):
    return {g.cp: g for g in glyphs}


class Readers(unittest.TestCase):
    def test_bdf_counts(self):
        for name, n in [('matrix/MatrixChunky6.bdf', 441), ('matrix/MatrixLight8.bdf', 731),
                        ('matrix/MatrixChunky8x6.bdf', 463), ('tiny5/Tiny5.bdf', 1941),
                        ('tiny5/Tiny5Mono.bdf', 2286)]:
            _, glyphs = gf.read_bdf(os.path.join(FONTS, name))
            self.assertEqual(len(glyphs), n, name)

    def test_bdf_places_glyphs_from_the_cell_top(self):
        h, glyphs = gf.read_bdf(os.path.join(FONTS, 'matrix/MatrixChunky8.bdf'))
        g = by_cp(glyphs)
        self.assertEqual(h, 8)
        top = g[ord('A')]
        self.assertGreaterEqual(top.y, 0)
        self.assertLessEqual(top.y + top.h, h)
        self.assertGreater(g[ord('g')].y + g[ord('g')].h, top.y + top.h)  # a descender drops below

    def test_fon_phoenix_matches_the_screenshot(self):
        h, glyphs = gf.read_fon(os.path.join(FONTS, 'int10h/Bm437_Phoenix_BIOS.FON'))
        g = by_cp(glyphs)
        self.assertEqual(h, 8)
        self.assertEqual(len(glyphs), 255)  # 0x00 dropped
        self.assertEqual(art(g[0x263A])[:3], ['.######.', '#......#', '#.#..#.#'])  # 0x01 ☺
        self.assertEqual(art(g[ord('A')])[:4], ['..###...', '.##.##..', '##...##.', '##...##.'])
        self.assertIn(0x00E9, g)  # 0x82 é
        self.assertIn(0x03B1, g)  # 0xe0 α
        self.assertIn(0x2302, g)  # 0x7f ⌂

    def test_fon_cells(self):
        for name, h in [('Bm437_Phoenix_BIOS-2y.FON', 16), ('Bm437_PhoenixVGA_8x14.FON', 14),
                        ('Bm437_IBM_DOS_ISO8.FON', 16), ('Bm437_ApricotXenC.FON', 14),
                        ('Bm437_Robotron_A7100.FON', 16)]:
            cell, glyphs = gf.read_fon(os.path.join(FONTS, 'int10h', name))
            self.assertEqual(cell, h, name)
            self.assertTrue(all(g.advance == 8 for g in glyphs), name)

    def test_otb_ibm_vga(self):
        h, glyphs = gf.read_otb(os.path.join(FONTS, 'int10h/BmPlus_IBM_VGA_8x16.otb'))
        g = by_cp(glyphs)
        self.assertEqual(h, 16)
        self.assertEqual(len(glyphs), 787)
        self.assertIn(0x0416, g)  # cyrillic zhe
        self.assertTrue(any(r for r in g[ord('A')].rows))
        self.assertTrue(all(g.advance == 8 for g in glyphs))

    def test_cp437_table(self):
        self.assertEqual(gf.CP437[0x01], 0x263A)
        self.assertEqual(gf.CP437[0x7F], 0x2302)
        self.assertEqual(gf.CP437[0x82], 0x00E9)
        self.assertEqual(gf.CP437[0xFF], 0x00A0)
        self.assertEqual(gf.CP437[0x41], 0x41)


FACE_NAMES = ['chunky6', 'chunky6x', 'light6', 'light6x', 'chunky8', 'chunky8x', 'chunky8x6',
              'light8', 'light8x', 'light8x6', 'tiny5', 'tiny5-duo', 'tiny5-mono', 'phoenix',
              'phoenix-2y', 'phoenix-8x14', 'ibm-iso8', 'apricot-xenc', 'robotron-a7100', 'ibm-vga']
SRC = os.path.join(HERE, '..', 'src', 'scene')


class Output(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.faces = gf.load_all()  # [(name, trimmed height, [Glyph])]
        cls.blob, cls.zig = gf.render(cls.faces)

    def test_names_in_order(self):
        self.assertEqual([f[0] for f in self.faces], FACE_NAMES)

    def test_trimmed_heights(self):
        h = {n: hh for n, hh, _ in self.faces}
        self.assertEqual(h['chunky6'], 6)
        self.assertEqual(h['chunky8'], 8)
        self.assertEqual(h['robotron-a7100'], 11)  # a 16-row cell whose text sits in rows 2..12
        self.assertEqual(h['ibm-iso8'], 15)  # ascii alone spans rows 0..14: `^` on top, descenders below
        self.assertEqual(h['tiny5'], 11)  # 7 rows of ascii; `å` reaches two above, the cedilla one below
        self.assertEqual(h['phoenix'], 8)
        for n, hh, glyphs in self.faces:
            for g in glyphs:
                self.assertTrue(0 <= g.y and g.y + g.h <= hh, (n, hex(g.cp)))

    def test_ascii_present_everywhere(self):
        for n, _, glyphs in self.faces:
            cps = {g.cp for g in glyphs}
            self.assertTrue(all(c in cps for c in range(0x20, 0x7F)), n)

    def test_index_is_sorted_and_unique(self):
        for n, _, glyphs in self.faces:
            cps = [g.cp for g in glyphs]
            self.assertEqual(cps, sorted(set(cps)), n)

    def test_blob_under_ceiling(self):
        self.assertLessEqual(len(self.blob), 256 * 1024)

    def test_committed_files_are_current(self):
        with open(os.path.join(SRC, 'faces.bin'), 'rb') as f:
            self.assertEqual(f.read(), self.blob)
        with open(os.path.join(SRC, 'faces.zig')) as f:
            self.assertEqual(f.read(), self.zig)

    def test_deterministic(self):
        self.assertEqual(gf.render(gf.load_all()), (self.blob, self.zig))


if __name__ == '__main__':
    unittest.main()
