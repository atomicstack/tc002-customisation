/* tc002 preview simulation: ports of the runtime's 5x7 font, the clock fonts and colour styles, posix tz
   rules, clock/ip/notification layout, the popsquares and plasma generators and the panel level curve, so the console can show
   what tc002d draws from a /status document. pure: no dom, no network. loads in a browser as
   window.TC002Sim and under node as a commonjs module. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.TC002Sim = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';
  const WIDTH = 52, HEIGHT = 16, PIXELS = WIDTH * HEIGHT, RGB_BYTES = PIXELS * 3;
  const WHITE = [255, 255, 255];
  const black = () => new Uint8Array(RGB_BYTES);
  const pixelOffset = (x, y) => (y * WIDTH + x) * 3;

  /* ---------- font (runtime/src/scene/font.zig): 0x20..0x7e, '#' = lit, bit 4 = leftmost ---------- */
  const GLYPH_SRC = [
    ['.....', '.....', '.....', '.....', '.....', '.....', '.....'], // ' '
    ['..#..', '..#..', '..#..', '..#..', '..#..', '.....', '..#..'], // !
    ['.#.#.', '.#.#.', '.#.#.', '.....', '.....', '.....', '.....'], // "
    ['.#.#.', '.#.#.', '#####', '.#.#.', '#####', '.#.#.', '.#.#.'], // #
    ['..#..', '.####', '#.#..', '.###.', '..#.#', '####.', '..#..'], // $
    ['##...', '##..#', '...#.', '..#..', '.#...', '#..##', '...##'], // %
    ['.##..', '#..#.', '#.#..', '.#...', '#.#.#', '#..#.', '.##.#'], // &
    ['.##..', '..#..', '.#...', '.....', '.....', '.....', '.....'], // '
    ['...#.', '..#..', '.#...', '.#...', '.#...', '..#..', '...#.'], // (
    ['.#...', '..#..', '...#.', '...#.', '...#.', '..#..', '.#...'], // )
    ['.....', '..#..', '#.#.#', '.###.', '#.#.#', '..#..', '.....'], // *
    ['.....', '..#..', '..#..', '#####', '..#..', '..#..', '.....'], // +
    ['.....', '.....', '.....', '.....', '.##..', '..#..', '.#...'], // ,
    ['.....', '.....', '.....', '#####', '.....', '.....', '.....'], // -
    ['.....', '.....', '.....', '.....', '.....', '.##..', '.##..'], // .
    ['.....', '....#', '...#.', '..#..', '.#...', '#....', '.....'], // /
    ['.###.', '#...#', '#..##', '#.#.#', '##..#', '#...#', '.###.'], // 0
    ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'], // 1
    ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'], // 2
    ['#####', '...#.', '..#..', '...#.', '....#', '#...#', '.###.'], // 3
    ['...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'], // 4
    ['#####', '#....', '####.', '....#', '....#', '#...#', '.###.'], // 5
    ['..##.', '.#...', '#....', '####.', '#...#', '#...#', '.###.'], // 6
    ['#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'], // 7
    ['.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'], // 8
    ['.###.', '#...#', '#...#', '.####', '....#', '...#.', '.##..'], // 9
    ['.....', '.##..', '.##..', '.....', '.##..', '.##..', '.....'], // :
    ['.....', '.##..', '.##..', '.....', '.##..', '..#..', '.#...'], // ;
    ['...#.', '..#..', '.#...', '#....', '.#...', '..#..', '...#.'], // <
    ['.....', '.....', '#####', '.....', '#####', '.....', '.....'], // =
    ['.#...', '..#..', '...#.', '....#', '...#.', '..#..', '.#...'], // >
    ['.###.', '#...#', '....#', '...#.', '..#..', '.....', '..#..'], // ?
    ['.###.', '#...#', '....#', '.####', '#.#.#', '#.#.#', '.###.'], // @
    ['.###.', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'], // A
    ['####.', '#...#', '#...#', '####.', '#...#', '#...#', '####.'], // B
    ['.###.', '#...#', '#....', '#....', '#....', '#...#', '.###.'], // C
    ['###..', '#..#.', '#...#', '#...#', '#...#', '#..#.', '###..'], // D
    ['#####', '#....', '#....', '####.', '#....', '#....', '#####'], // E
    ['#####', '#....', '#....', '####.', '#....', '#....', '#....'], // F
    ['.###.', '#...#', '#....', '#.###', '#...#', '#...#', '.####'], // G
    ['#...#', '#...#', '#...#', '#####', '#...#', '#...#', '#...#'], // H
    ['.###.', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'], // I
    ['..###', '...#.', '...#.', '...#.', '...#.', '#..#.', '.##..'], // J
    ['#...#', '#..#.', '#.#..', '##...', '#.#..', '#..#.', '#...#'], // K
    ['#....', '#....', '#....', '#....', '#....', '#....', '#####'], // L
    ['#...#', '##.##', '#.#.#', '#.#.#', '#...#', '#...#', '#...#'], // M
    ['#...#', '#...#', '##..#', '#.#.#', '#..##', '#...#', '#...#'], // N
    ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'], // O
    ['####.', '#...#', '#...#', '####.', '#....', '#....', '#....'], // P
    ['.###.', '#...#', '#...#', '#...#', '#.#.#', '#..#.', '.##.#'], // Q
    ['####.', '#...#', '#...#', '####.', '#.#..', '#..#.', '#...#'], // R
    ['.####', '#....', '#....', '.###.', '....#', '....#', '####.'], // S
    ['#####', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'], // T
    ['#...#', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'], // U
    ['#...#', '#...#', '#...#', '#...#', '#...#', '.#.#.', '..#..'], // V
    ['#...#', '#...#', '#...#', '#.#.#', '#.#.#', '#.#.#', '.#.#.'], // W
    ['#...#', '#...#', '.#.#.', '..#..', '.#.#.', '#...#', '#...#'], // X
    ['#...#', '#...#', '#...#', '.#.#.', '..#..', '..#..', '..#..'], // Y
    ['#####', '....#', '...#.', '..#..', '.#...', '#....', '#####'], // Z
    ['.###.', '.#...', '.#...', '.#...', '.#...', '.#...', '.###.'], // [
    ['.....', '#....', '.#...', '..#..', '...#.', '....#', '.....'], // backslash
    ['.###.', '...#.', '...#.', '...#.', '...#.', '...#.', '.###.'], // ]
    ['..#..', '.#.#.', '#...#', '.....', '.....', '.....', '.....'], // ^
    ['.....', '.....', '.....', '.....', '.....', '.....', '#####'], // _
    ['.#...', '..#..', '...#.', '.....', '.....', '.....', '.....'], // `
    ['.....', '.....', '.###.', '....#', '.####', '#...#', '.####'], // a
    ['#....', '#....', '#.##.', '##..#', '#...#', '#...#', '####.'], // b
    ['.....', '.....', '.###.', '#....', '#....', '#...#', '.###.'], // c
    ['....#', '....#', '.##.#', '#..##', '#...#', '#...#', '.####'], // d
    ['.....', '.....', '.###.', '#...#', '#####', '#....', '.###.'], // e
    ['..##.', '.#..#', '.#...', '###..', '.#...', '.#...', '.#...'], // f
    ['.....', '.....', '.####', '#...#', '.####', '....#', '.###.'], // g
    ['#....', '#....', '#.##.', '##..#', '#...#', '#...#', '#...#'], // h
    ['..#..', '.....', '.##..', '..#..', '..#..', '..#..', '.###.'], // i
    ['...#.', '.....', '..##.', '...#.', '...#.', '#..#.', '.##..'], // j
    ['#....', '#....', '#..#.', '#.#..', '##...', '#.#..', '#..#.'], // k
    ['.##..', '..#..', '..#..', '..#..', '..#..', '..#..', '.###.'], // l
    ['.....', '.....', '##.#.', '#.#.#', '#.#.#', '#...#', '#...#'], // m
    ['.....', '.....', '#.##.', '##..#', '#...#', '#...#', '#...#'], // n
    ['.....', '.....', '.###.', '#...#', '#...#', '#...#', '.###.'], // o
    ['.....', '.....', '####.', '#...#', '####.', '#....', '#....'], // p
    ['.....', '.....', '.####', '#...#', '.####', '....#', '....#'], // q
    ['.....', '.....', '#.##.', '##..#', '#....', '#....', '#....'], // r
    ['.....', '.....', '.###.', '#....', '.###.', '....#', '####.'], // s
    ['.#...', '.#...', '###..', '.#...', '.#...', '.#..#', '..##.'], // t
    ['.....', '.....', '#...#', '#...#', '#...#', '#..##', '.##.#'], // u
    ['.....', '.....', '#...#', '#...#', '#...#', '.#.#.', '..#..'], // v
    ['.....', '.....', '#...#', '#...#', '#.#.#', '#.#.#', '.#.#.'], // w
    ['.....', '.....', '#...#', '.#.#.', '..#..', '.#.#.', '#...#'], // x
    ['.....', '.....', '#...#', '#...#', '.####', '....#', '.###.'], // y
    ['.....', '.....', '#####', '...#.', '..#..', '.#...', '#####'], // z
    ['...#.', '..#..', '..#..', '.#...', '..#..', '..#..', '...#.'], // {
    ['..#..', '..#..', '..#..', '..#..', '..#..', '..#..', '..#..'], // |
    ['.#...', '..#..', '..#..', '...#.', '..#..', '..#..', '.#...'], // }
    ['.....', '.#...', '#.#.#', '...#.', '.....', '.....', '.....'], // ~
  ];
  const GLYPHS = GLYPH_SRC.map(rows => rows.map(row => {
    let bits = 0;
    for (let c = 0; c < 5; c++) if (row[c] === '#') bits |= 1 << (4 - c);
    return bits;
  }));
  const ADVANCE = 6;
  function glyph(code) {
    const i = (code >= 0x20 && code <= 0x7e) ? code - 0x20 : 0x3f - 0x20;
    return GLYPHS[i];
  }
  function textWidth(text) { return text.length ? text.length * ADVANCE - 1 : 0; }
  function blit(rgb, x0, y0, text, colour) {
    let x = x0;
    for (let i = 0; i < text.length; i++) {
      const g = glyph(text.charCodeAt(i));
      for (let r = 0; r < 7; r++) {
        const y = y0 + r;
        if (y < 0 || y >= HEIGHT) continue;
        for (let col = 0; col < 5; col++) {
          if (((g[r] >> (4 - col)) & 1) === 0) continue;
          const px = x + col;
          if (px < 0 || px >= WIDTH) continue;
          const o = pixelOffset(px, y);
          rgb[o] = colour[0]; rgb[o + 1] = colour[1]; rgb[o + 2] = colour[2];
        }
      }
      x += ADVANCE;
    }
  }

  /* ---------- level curve (runtime/src/panel/pack.zig): 0 stays 0, 1..255 land on 50..255 ---------- */
  function remap(v) {
    if (v === 0) return 0;
    return 50 + Math.floor((((v - 1) * 205) >> 1) / 127);
  }
  function buildLut(brightness) {
    const b = Math.min(brightness, 100);
    const lut = new Uint8Array(256);
    for (let v = 0; v < 256; v++) lut[v] = remap(Math.floor(v * b / 100));
    return lut;
  }

  /* ---------- posix tz rules (runtime/src/scene/tz.zig); offsets are utc offsets in seconds ---------- */
  const divFloor = (a, b) => Math.floor(a / b);
  const mod = (a, b) => ((a % b) + b) % b;
  const invalid = () => new Error('invalid tz rule');

  class TzParser {
    constructor(s) { this.s = s; this.i = 0; }
    atEnd() { return this.i >= this.s.length; }
    peek() { return this.atEnd() ? null : this.s[this.i]; }
    expect(c) { if (this.peek() !== c) throw invalid(); this.i++; }
    name() {
      if (this.peek() === '<') {
        while (!this.atEnd()) { if (this.s[this.i++] === '>') return; }
        throw invalid();
      }
      const start = this.i;
      while (this.peek() !== null && /[A-Za-z]/.test(this.peek())) this.i++;
      if (this.i - start < 3) throw invalid();
    }
    number(maxDigits) {
      let v = 0, n = 0;
      while (this.peek() !== null && /[0-9]/.test(this.peek())) {
        if (n === maxDigits) throw invalid();
        v = v * 10 + (this.s.charCodeAt(this.i) - 48);
        n++; this.i++;
      }
      if (n === 0) throw invalid();
      return v;
    }
    signedTime(maxH) {
      let neg = false;
      if (this.peek() === '+') this.i++;
      else if (this.peek() === '-') { neg = true; this.i++; }
      const h = this.number(3);
      if (h > maxH) throw invalid();
      let s = h * 3600;
      if (this.peek() === ':') {
        this.i++;
        const m = this.number(2);
        if (m > 59) throw invalid();
        s += m * 60;
        if (this.peek() === ':') {
          this.i++;
          const sec = this.number(2);
          if (sec > 59) throw invalid();
          s += sec;
        }
      }
      return neg ? -s : s;
    }
    transition() {
      this.expect('M');
      const month = this.number(2);
      this.expect('.');
      const week = this.number(1);
      this.expect('.');
      const wd = this.number(1);
      if (month < 1 || month > 12 || week < 1 || week > 5 || wd > 6) throw invalid();
      const t = { month, week, weekday: wd, time: 2 * 3600 };
      if (this.peek() === '/') { this.i++; t.time = this.signedTime(167); }
      return t;
    }
  }
  function tzParse(text) {
    const p = new TzParser(text);
    p.name();
    const stdPosix = p.signedTime(24);
    const rule = { stdOffset: -stdPosix + 0, dst: null };
    if (p.atEnd()) return rule;
    if (p.peek() === ',') throw invalid();
    p.name();
    let dstPosix = stdPosix - 3600;
    if (p.peek() !== null && p.peek() !== ',') dstPosix = p.signedTime(24);
    if (p.atEnd()) throw invalid();
    p.expect(',');
    const start = p.transition();
    p.expect(',');
    const end = p.transition();
    if (!p.atEnd()) throw invalid();
    rule.dst = { offset: -dstPosix + 0, start, end };
    return rule;
  }
  function daysFromCivil(year, month, day) {
    const y = month <= 2 ? year - 1 : year;
    const era = divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month > 2 ? month - 3 : month + 9;
    const doy = divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + divFloor(yoe, 4) - divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
  }
  function civilFromDays(days) {
    const z = days + 719468;
    const era = divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = divFloor(doe - divFloor(doe, 1460) + divFloor(doe, 36524) - divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + divFloor(yoe, 4) - divFloor(yoe, 100));
    const mp = divFloor(5 * doy + 2, 153);
    const day = doy - divFloor(153 * mp + 2, 5) + 1;
    const month = mp < 10 ? mp + 3 : mp - 9;
    return { year: month <= 2 ? y + 1 : y, month, day };
  }
  const weekday = days => mod(days + 4, 7);
  const isLeap = y => y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const daysInMonth = (y, m) => [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1] + (m === 2 && isLeap(y) ? 1 : 0);
  function transitionUtc(t, year, offsetBefore) {
    const first = daysFromCivil(year, t.month, 1);
    let day = 1 + mod(t.weekday + 7 - weekday(first), 7) + (t.week - 1) * 7;
    while (day > daysInMonth(year, t.month)) day -= 7;
    return (first + day - 1) * 86400 + t.time - offsetBefore;
  }
  function utcOffsetAt(rule, utcS) {
    if (!rule.dst) return rule.stdOffset;
    const year = civilFromDays(divFloor(utcS + rule.stdOffset, 86400)).year;
    const start = transitionUtc(rule.dst.start, year, rule.stdOffset);
    const end = transitionUtc(rule.dst.end, year, rule.dst.offset);
    const inDst = start < end ? (utcS >= start && utcS < end) : (utcS >= start || utcS < end);
    return inDst ? rule.dst.offset : rule.stdOffset;
  }
  const localFromUtc = (rule, utcS) => utcS + utcOffsetAt(rule, utcS);
  const TZ_UTC = { stdOffset: 0, dst: null };

  /* ---------- clock, ip, notification (clock.zig, ip.zig, arbiter.zig) ---------- */
  /* ---------- clock fonts (clockfont.zig): classic 5x7, mini 3x5, segment 5x9, big 10x14.
     a glyph is {w, h, rows} with bit (w - 1 - col) set for a lit pixel; the blit takes a painter
     (x, y) => [r, g, b] so a gradient is a colour function over the text, not a font property ---------- */
  const CLOCK_FONTS = ['classic', 'mini', 'segment', 'big'];
  const CLOCK_GLYPH_H = { classic: 7, mini: 5, segment: 9, big: 14 };
  const clockGap = font => (font === 'big' ? 2 : 1);
  function fromArt(w, art) {
    return { w, h: art.length, rows: art.map(row => { let bits = 0; for (let c = 0; c < w; c++) if (row[c] === '#') bits |= 1 << (w - 1 - c); return bits; }) };
  }
  const MINI_DIGITS = [
    ['###', '#.#', '#.#', '#.#', '###'], ['.#.', '##.', '.#.', '.#.', '###'], ['###', '..#', '###', '#..', '###'],
    ['###', '..#', '###', '..#', '###'], ['#.#', '#.#', '###', '..#', '..#'], ['###', '#..', '###', '..#', '###'],
    ['###', '#..', '###', '#.#', '###'], ['###', '..#', '..#', '..#', '..#'], ['###', '#.#', '###', '#.#', '###'],
    ['###', '#.#', '###', '..#', '###'],
  ].map(a => fromArt(3, a));
  const MINI_COLON = fromArt(1, ['.', '#', '.', '#', '.']);
  const MINI_SLASH = fromArt(3, ['..#', '..#', '.#.', '#..', '#..']);
  const MINI_SPACE = fromArt(3, ['...', '...', '...', '...', '...']);
  // seven segments a..g on a 5x9 cell: a top, g middle, d bottom bars over columns 1..3; f/b the
  // upper left/right columns, e/c the lower ones
  const SEGMENT_TABLE = ['abcdef', 'bc', 'abdeg', 'abcdg', 'bcfg', 'acdfg', 'acdefg', 'abc', 'abcdefg', 'abcdfg'];
  function segmentGlyph(segs) {
    const rows = new Array(9).fill(0);
    const bar = 0b01110, left = 0b10000, right = 0b00001;
    if (segs.includes('a')) rows[0] |= bar;
    if (segs.includes('g')) rows[4] |= bar;
    if (segs.includes('d')) rows[8] |= bar;
    for (let r = 1; r < 4; r++) { if (segs.includes('f')) rows[r] |= left; if (segs.includes('b')) rows[r] |= right; }
    for (let r = 5; r < 8; r++) { if (segs.includes('e')) rows[r] |= left; if (segs.includes('c')) rows[r] |= right; }
    return { w: 5, h: 9, rows };
  }
  const SEGMENT_DIGITS = SEGMENT_TABLE.map(segmentGlyph);
  const SEGMENT_COLON = fromArt(1, ['.', '.', '#', '.', '.', '.', '#', '.', '.']);
  const SEGMENT_SPACE = { w: 5, h: 9, rows: new Array(9).fill(0) };
  // the built-in font's glyph, optionally scaled by two
  function classicGlyph(code, scale) {
    const src = glyph(code);
    const w = 5 * scale, rows = new Array(7 * scale).fill(0);
    for (let r = 0; r < 7; r++) {
      let bits = 0;
      for (let col = 0; col < 5; col++) {
        if (((src[r] >> (4 - col)) & 1) === 0) continue;
        for (let k = 0; k < scale; k++) bits |= 1 << (w - 1 - (col * scale + k));
      }
      for (let k = 0; k < scale; k++) rows[r * scale + k] = bits;
    }
    return { w, h: 7 * scale, rows };
  }
  // the big colon: four-by-four dots so "hh:mm" spans exactly the 52 columns
  const BIG_COLON = fromArt(4, ['....', '....', '####', '####', '####', '####', '....', '....', '####', '####', '####', '####', '....', '....']);
  const isDigit = code => code >= 0x30 && code <= 0x39;
  function clockGlyph(font, code) {
    switch (font) {
      case 'big': return code === 0x3a ? BIG_COLON : classicGlyph(code, 2);
      case 'mini': return isDigit(code) ? MINI_DIGITS[code - 0x30] : code === 0x3a ? MINI_COLON : code === 0x2f ? MINI_SLASH : MINI_SPACE;
      case 'segment': return isDigit(code) ? SEGMENT_DIGITS[code - 0x30] : code === 0x3a ? SEGMENT_COLON : SEGMENT_SPACE;
      default: return classicGlyph(code, 1);
    }
  }
  function clockTextWidth(font, text) {
    let w = 0;
    for (let i = 0; i < text.length; i++) { if (i > 0) w += clockGap(font); w += clockGlyph(font, text.charCodeAt(i)).w; }
    return w;
  }
  function clockBlit(rgb, x0, y0, font, text, painter) {
    let x = x0;
    for (let i = 0; i < text.length; i++) {
      if (i > 0) x += clockGap(font);
      const g = clockGlyph(font, text.charCodeAt(i));
      for (let r = 0; r < g.h; r++) {
        const y = y0 + r;
        if (y < 0 || y >= HEIGHT) continue;
        for (let col = 0; col < g.w; col++) {
          if (((g.rows[r] >> (g.w - 1 - col)) & 1) === 0) continue;
          const px = x + col;
          if (px < 0 || px >= WIDTH) continue;
          const c = painter(px, y), o = pixelOffset(px, y);
          rgb[o] = c[0]; rgb[o + 1] = c[1]; rgb[o + 2] = c[2];
        }
      }
      x += g.w;
    }
  }

  /* ---------- clock (clock.zig): local time in a font, solid or a subtle gradient ---------- */
  const CLOCK_X = 2, CLOCK_Y = 4;   // where the classic "hh:mm:ss" lands once centred
  const CLOCK_MAX_SPREAD = 96;      // the subtlety rule: no channel of the gradient's end may differ from the start by more
  const DEFAULT_CLOCK_STYLE = { font: 'classic', colour_mode: 'solid', colour: 'ffffff', colour2: 'ffffff', gradient: 'horizontal' };
  function hexBytes(h, fallback) {
    const s = String(h == null ? '' : h).replace('#', '');
    return /^[0-9a-fA-F]{6}$/.test(s) ? [0, 2, 4].map(i => parseInt(s.slice(i, i + 2), 16)) : fallback.slice();
  }
  // a status or config `clock` object (strings, any subset) -> a complete style with byte colours
  function clockStyle(doc) {
    const d = doc || {};
    return {
      font: CLOCK_FONTS.includes(d.font) ? d.font : 'classic',
      mode: d.colour_mode === 'gradient' ? 'gradient' : 'solid',
      colour: hexBytes(d.colour, WHITE),
      colour2: hexBytes(d.colour2, WHITE),
      gradient: ['horizontal', 'vertical', 'diagonal'].includes(d.gradient) ? d.gradient : 'horizontal',
    };
  }
  // the gradient end after the subtlety rule
  function effectiveColour2(doc) {
    const s = clockStyle(doc);
    return s.colour.map((a, i) => Math.min(Math.max(s.colour2[i], Math.max(a - CLOCK_MAX_SPREAD, 0)), Math.min(a + CLOCK_MAX_SPREAD, 255)));
  }
  const pad2 = n => String(n).padStart(2, '0');
  function formatTime(localS) {
    const sod = mod(localS, 86400);
    return `${pad2(Math.floor(sod / 3600))}:${pad2(Math.floor(sod / 60) % 60)}:${pad2(sod % 60)}`;
  }
  function formatDate(localS) {
    const civil = civilFromDays(divFloor(localS, 86400));
    return `${pad2(civil.day)}/${pad2(civil.month)}`;
  }
  const clockCentre = (font, text) => Math.floor((WIDTH - clockTextWidth(font, text)) / 2);
  // where each font puts its text: everything centred, mini adds the date underneath, big shows hours and minutes only
  function clockLayout(font, timeText, dateText) {
    switch (font) {
      case 'big': { const t = timeText.slice(0, 5); return [{ x: clockCentre(font, t), y: 1, text: t }]; }
      case 'mini': return [{ x: clockCentre(font, timeText), y: 2, text: timeText }, { x: clockCentre(font, dateText), y: 9, text: dateText }];
      default: return [{ x: clockCentre(font, timeText), y: Math.floor((HEIGHT - CLOCK_GLYPH_H[font]) / 2), text: timeText }];
    }
  }
  // colour as a function of position over the text box: start on one side, end on the other
  function gradientPainter(c1, c2, box, dir) {
    const w = Math.max(box.x1 - box.x0, 1), h = Math.max(box.y1 - box.y0, 1);
    return (x, y) => {
      const fx = Math.min(Math.max(Math.trunc((x - box.x0) * 256 / w), 0), 256);
      const fy = Math.min(Math.max(Math.trunc((y - box.y0) * 256 / h), 0), 256);
      const t = dir === 'horizontal' ? fx : dir === 'vertical' ? fy : Math.trunc((fx + fy) / 2);
      return c1.map((a, i) => a + Math.trunc((c2[i] - a) * t / 256));
    };
  }
  function renderClock(rgb, wallMs, rule, styleDoc) {
    const s = clockStyle(styleDoc);
    const localS = localFromUtc(rule, Math.floor(wallMs / 1000));
    const lines = clockLayout(s.font, formatTime(localS), formatDate(localS));
    rgb.fill(0);   // like the runtime's render: the clock owns the whole frame
    let painter = () => s.colour;
    if (s.mode === 'gradient') {
      const box = { x0: WIDTH, y0: HEIGHT, x1: -1, y1: -1 };
      for (const l of lines) {
        box.x0 = Math.min(box.x0, l.x); box.y0 = Math.min(box.y0, l.y);
        box.x1 = Math.max(box.x1, l.x + clockTextWidth(s.font, l.text) - 1);
        box.y1 = Math.max(box.y1, l.y + CLOCK_GLYPH_H[s.font] - 1);
      }
      painter = gradientPainter(s.colour, effectiveColour2(styleDoc), box, s.gradient);
    }
    for (const l of lines) clockBlit(rgb, l.x, l.y, s.font, l.text, painter);
  }
  const nextSecondMs = wallMs => (Math.floor(wallMs / 1000) + 1) * 1000;
  function ipFromString(s) {
    if (typeof s !== 'string') return null;
    const parts = s.split('.');
    if (parts.length !== 4) return null;
    const out = [];
    for (const p of parts) {
      if (!/^[0-9]{1,3}$/.test(p)) return null;
      const v = parseInt(p, 10);
      if (v > 255) return null;
      out.push(v);
    }
    return out;
  }
  // the `lines` mode of the ip scene: two centred lines (the other modes show through /screen)
  function renderIp(rgb, addr) {
    if (addr) {
      const l1 = `${addr[0]}.${addr[1]}.`, l2 = `${addr[2]}.${addr[3]}`;
      blit(rgb, Math.floor((WIDTH - textWidth(l1)) / 2), 0, l1, WHITE);
      blit(rgb, Math.floor((WIDTH - textWidth(l2)) / 2), 8, l2, WHITE);
    } else {
      blit(rgb, 11, 4, 'no ip', WHITE);
    }
  }
  const SCROLL_MS = 100 / 3; // 33.333 ms per pixel, scroll_period_ns in arbiter.zig
  function renderNotify(rgb, text, colour, elapsedMs) {
    const w = textWidth(text);
    if (w <= WIDTH) {
      blit(rgb, Math.floor((WIDTH - w) / 2), 4, text, colour);
    } else {
      const span = w + WIDTH;
      const steps = Math.floor(Math.max(elapsedMs, 0) / SCROLL_MS);
      blit(rgb, WIDTH - (steps % span), 4, text, colour);
    }
  }

  /* ---------- generators (scene.zig, popsquares.zig, plasma.zig) ---------- */
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
  class Rng {
    constructor(seed) { this.state = (seed >>> 0) || 0x9e3779b9; }
    next() {
      let x = this.state;
      x = (x ^ (x << 13)) >>> 0;
      x = (x ^ (x >>> 17)) >>> 0;
      x = (x ^ (x << 5)) >>> 0;
      this.state = x;
      return x;
    }
    unit() { return (this.next() >>> 8) / 16777216; }
    range(lo, hi) { return lo + (hi - lo) * this.unit(); }
  }

  const POP_DEFAULTS = { pop_s: 2, alive: 1, dim: 0.25, dim_lo: 0, dim_hi: 127, tint_frac: 0.15, tint: [58, 110, 165] };
  const LEVEL_MAX = 127, DT_MAX = 0.5, SPENT = 1e-4;
  class Popsquares {
    constructor(seed, options) {
      this.o = Object.assign({}, POP_DEFAULTS, options || {});
      this.rng = new Rng(seed);
      this.level = new Float32Array(PIXELS);
      this.rank = new Float32Array(PIXELS);
      this.tinted = new Uint8Array(PIXELS);
      for (let i = 0; i < PIXELS; i++) {
        this.level[i] = this.rng.range(0, LEVEL_MAX);
        this.rank[i] = this.rng.unit();
        this.tinted[i] = this.rng.unit() < this.o.tint_frac ? 1 : 0;
      }
    }
    rearm(i) {
      const lo = Math.min(this.o.dim_lo, this.o.dim_hi), hi = Math.max(this.o.dim_lo, this.o.dim_hi);
      this.level[i] = this.rng.unit() < this.o.dim ? this.rng.range(lo, hi) : LEVEL_MAX;
      this.tinted[i] = this.rng.unit() < this.o.tint_frac ? 1 : 0;
    }
    step(dtS) {
      const dt = clamp(dtS, 0, DT_MAX);
      const pop = this.o.pop_s > 0 ? this.o.pop_s : 1;
      const drop = LEVEL_MAX * dt / pop;
      for (let i = 0; i < PIXELS; i++) {
        if (this.rank[i] >= this.o.alive) { this.level[i] = 0; continue; }
        this.level[i] -= drop;
        if (this.level[i] <= SPENT) this.rearm(i);
      }
    }
    render(rgb) {
      for (let i = 0; i < PIXELS; i++) {
        const f = clamp(this.level[i] / LEVEL_MAX, 0, 1);
        const c = this.tinted[i] ? this.o.tint : WHITE;
        rgb[i * 3] = Math.floor(c[0] * f); rgb[i * 3 + 1] = Math.floor(c[1] * f); rgb[i * 3 + 2] = Math.floor(c[2] * f);
      }
    }
  }

  const SINE = new Uint8Array(256);
  for (let i = 0; i < 256; i++) SINE[i] = Math.round((Math.sin(i * 2 * Math.PI / 256) + 1) * 127.5);
  class Plasma {
    constructor(seed) {
      const r = new Rng(seed);
      this.phase = r.next() & 0xff;
      this.speed = 1 + (r.next() % 3);
      this.t = 0; this.acc = 0;
    }
    step(dtS) {
      const d = clamp(dtS, 0, DT_MAX);
      this.acc += d * 60 * this.speed;
      const whole = Math.floor(this.acc);
      this.t = (this.t + whole) >>> 0;
      this.acc -= whole;
    }
    render(rgb) {
      const t = this.t & 0xff;
      for (let y = 0; y < HEIGHT; y++) for (let x = 0; x < WIDTH; x++) {
        const xi = (x * 4) & 0xff, yi = (y * 12) & 0xff;
        const v = SINE[(xi + t) & 0xff] + SINE[(yi + t * 2 + this.phase) & 0xff] + SINE[((((xi + yi) & 0xff) >> 1) + t) & 0xff];
        const c = Math.floor(v / 3);
        const i = pixelOffset(x, y);
        rgb[i] = SINE[c]; rgb[i + 1] = SINE[(c + 85) & 0xff]; rgb[i + 2] = SINE[(c + 170) & 0xff];
      }
    }
  }

  const GENERATORS = ['popsquares', 'plasma'];
  class Art {
    constructor(generator, seed) { this.generator = GENERATORS.includes(generator) ? generator : 'popsquares'; this.reseed(seed); }
    reseed(seed) { this.seed = seed >>> 0; this.popsquares = new Popsquares(this.seed); this.plasma = new Plasma(this.seed); }
    select(generator) { if (GENERATORS.includes(generator)) this.generator = generator; }
    current() { return this.generator === 'plasma' ? this.plasma : this.popsquares; }
    step(dtS) { this.current().step(dtS); }
    render(rgb) { this.current().render(rgb); }
  }

  /* ---------- compose: what the panel shows for a status document plus what this page knows ---------- */
  const FRAME_MS = 1000 / 60;
  function compose(status, local, nowMs) {
    if (local.pending) return { rgb: local.pending.slice(), cadenceMs: null, label: 'pending frame' };
    const rgb = black();
    if (status.overlay === 'frame') {
      if (local.frame) return { rgb: local.frame.slice(), cadenceMs: null, label: 'frame' };
      rgb.fill(24);
      return { rgb, cadenceMs: null, label: 'frame (contents unknown: not sent from this page)' };
    }
    if (status.overlay === 'notify') {
      if (local.notify) {
        const n = local.notify;
        renderNotify(rgb, n.text, n.colour, nowMs - n.sinceMs);
        return { rgb, cadenceMs: textWidth(n.text) > WIDTH ? SCROLL_MS : null, label: 'notification' };
      }
      return { rgb, cadenceMs: null, label: 'notification (text unknown: not sent from this page)' };
    }
    switch (status.base) {
      case 'clock': {
        renderClock(rgb, nowMs, local.tz || TZ_UTC, status.clock);
        const st = status.clock ? clockStyle(status.clock) : null;
        return { rgb, cadenceMs: nextSecondMs(nowMs) - nowMs, label: st ? `clock · ${st.font} · ${st.mode}` : 'clock' };
      }
      case 'ip': {
        const ip = status.network && status.network.ip != null ? status.network.ip : status.ip;
        renderIp(rgb, ipFromString(ip));
        return { rgb, cadenceMs: null, label: 'ip' };
      }
      default:
        if (local.art) local.art.render(rgb);
        return { rgb, cadenceMs: FRAME_MS, label: `art: ${status.generator}, same algorithm, local seed` };
    }
  }

  return { WIDTH, HEIGHT, PIXELS, RGB_BYTES, WHITE, black, pixelOffset, glyph, textWidth, blit, remap, buildLut,
    tzParse, utcOffsetAt, localFromUtc, daysFromCivil, civilFromDays, weekday, TZ_UTC,
    CLOCK_FONTS, clockGlyph, clockTextWidth, clockBlit, CLOCK_MAX_SPREAD, DEFAULT_CLOCK_STYLE, clockStyle, effectiveColour2,
    CLOCK_X, CLOCK_Y, formatTime, formatDate, renderClock, nextSecondMs, ipFromString, renderIp, SCROLL_MS, renderNotify,
    Rng, Popsquares, Plasma, Art, GENERATORS, FRAME_MS, compose };
});
