//! digit fonts for the clock scene: the built-in 5x7 font, a 3x5 `mini`, a seven-segment 5x9
//! `segment` generated from a segment table, `big` (the 5x7 digits scaled to 10x14) and `block`,
//! the stock clock's face: 6x10 digits with two-pixel strokes and a 2x2-dot colon. glyphs are
//! fixed-size alpha maps; the blit takes a painter so a gradient is a colour function over the
//! text, not a property of the font. pure.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");

/// `hires` is a layout of the clock scene (classic time, a bar, mini milliseconds) that borrows the
/// classic glyphs here.
pub const Font = enum(u8) { classic = 0, mini = 1, segment = 2, big = 3, block = 4, hires = 5 };
pub const font_count: u8 = @typeInfo(Font).@"enum".fields.len;

pub const max_h = 14;
pub const max_w = 10;

/// one glyph: `w` columns, `h` rows, an alpha level per pixel (255 = fully lit).
pub const Glyph = struct { w: u8, h: u8, a: [max_h][max_w]u8 };

const blank = Glyph{ .w = 0, .h = 0, .a = [_][max_w]u8{[_]u8{0} ** max_w} ** max_h };

pub fn glyphHeight(f: Font) u8 {
    return switch (f) {
        .classic, .hires => 7,
        .mini => 5,
        .segment => 9,
        .big => 14,
        .block => 10,
    };
}

/// columns between glyphs.
pub fn gap(f: Font) u8 {
    return if (f == .big) 2 else 1;
}

fn fromArt(comptime w: u8, comptime h: u8, comptime art: [h]*const [w:0]u8) Glyph {
    var g = blank;
    g.w = w;
    g.h = h;
    for (art, 0..) |row, r| {
        for (row, 0..) |ch, c| {
            if (ch == '#') g.a[r][c] = 255;
        }
    }
    return g;
}

// mini: 3x5 digits, a one-column colon, a slash for the date line
const mini_digits = [10]Glyph{
    fromArt(3, 5, .{ "###", "#.#", "#.#", "#.#", "###" }),
    fromArt(3, 5, .{ ".#.", "##.", ".#.", ".#.", "###" }),
    fromArt(3, 5, .{ "###", "..#", "###", "#..", "###" }),
    fromArt(3, 5, .{ "###", "..#", "###", "..#", "###" }),
    fromArt(3, 5, .{ "#.#", "#.#", "###", "..#", "..#" }),
    fromArt(3, 5, .{ "###", "#..", "###", "..#", "###" }),
    fromArt(3, 5, .{ "###", "#..", "###", "#.#", "###" }),
    fromArt(3, 5, .{ "###", "..#", "..#", "..#", "..#" }),
    fromArt(3, 5, .{ "###", "#.#", "###", "#.#", "###" }),
    fromArt(3, 5, .{ "###", "#.#", "###", "..#", "###" }),
};
const mini_colon = fromArt(1, 5, .{ ".", "#", ".", "#", "." });
const mini_slash = fromArt(3, 5, .{ "..#", "..#", ".#.", "#..", "#.." });
const mini_space = fromArt(3, 5, .{ "...", "...", "...", "...", "..." });
const mini_dot = fromArt(1, 5, .{ ".", ".", ".", ".", "#" });

// segment: seven segments a..g on a 5x9 cell, digits from the usual table
const Segments = packed struct(u7) { a: bool, b: bool, c: bool, d: bool, e: bool, f: bool, g: bool };
const segment_table = [10]Segments{
    .{ .a = true, .b = true, .c = true, .d = true, .e = true, .f = true, .g = false },
    .{ .a = false, .b = true, .c = true, .d = false, .e = false, .f = false, .g = false },
    .{ .a = true, .b = true, .c = false, .d = true, .e = true, .f = false, .g = true },
    .{ .a = true, .b = true, .c = true, .d = true, .e = false, .f = false, .g = true },
    .{ .a = false, .b = true, .c = true, .d = false, .e = false, .f = true, .g = true },
    .{ .a = true, .b = false, .c = true, .d = true, .e = false, .f = true, .g = true },
    .{ .a = true, .b = false, .c = true, .d = true, .e = true, .f = true, .g = true },
    .{ .a = true, .b = true, .c = true, .d = false, .e = false, .f = false, .g = false },
    .{ .a = true, .b = true, .c = true, .d = true, .e = true, .f = true, .g = true },
    .{ .a = true, .b = true, .c = true, .d = true, .e = false, .f = true, .g = true },
};

fn segmentGlyph(s: Segments) Glyph {
    var g = blank;
    g.w = 5;
    g.h = 9;
    const bar_rows = [_]struct { on: bool, r: usize }{ .{ .on = s.a, .r = 0 }, .{ .on = s.g, .r = 4 }, .{ .on = s.d, .r = 8 } };
    for (bar_rows) |b| if (b.on) {
        for (1..4) |c| g.a[b.r][c] = 255;
    };
    for (1..4) |r| {
        if (s.f) g.a[r][0] = 255;
        if (s.b) g.a[r][4] = 255;
    }
    for (5..8) |r| {
        if (s.e) g.a[r][0] = 255;
        if (s.c) g.a[r][4] = 255;
    }
    return g;
}

const segment_digits: [10]Glyph = blk: {
    var out: [10]Glyph = undefined;
    for (segment_table, 0..) |s, i| out[i] = segmentGlyph(s);
    break :blk out;
};
const segment_colon = fromArt(1, 9, .{ ".", ".", "#", ".", ".", ".", "#", ".", "." });
const segment_space = fromArt(5, 9, .{ ".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", "....." });

/// the built-in font's glyph as a `Glyph`, optionally scaled by two.
fn classicGlyph(c: u8, comptime scale: u8) Glyph {
    const src = font.glyph(c);
    var g = blank;
    g.w = font.glyph_w * scale;
    g.h = font.glyph_h * scale;
    for (src, 0..) |row, r| {
        for (0..font.glyph_w) |col| {
            if ((row >> @intCast(font.glyph_w - 1 - col)) & 1 != 0) {
                for (0..scale) |ky| for (0..scale) |kx| {
                    g.a[r * scale + ky][col * scale + kx] = 255;
                };
            }
        }
    }
    return g;
}

/// the big colon: four-by-four dots so "hh:mm" spans exactly the 52 columns.
const big_colon = fromArt(4, 14, .{ "....", "....", "####", "####", "####", "####", "....", "....", "####", "####", "####", "####", "....", "...." });

// block: the stock clock's face. seven segments with two-pixel strokes on a 6x10 cell, corners
// filled where bars meet, a 1 with a flag and a base as the stock face draws it, a 2x2-dot colon.
fn blockGlyph(s: Segments) Glyph {
    var g = blank;
    g.w = 6;
    g.h = 10;
    const bars = [_]struct { on: bool, r: usize }{ .{ .on = s.a, .r = 0 }, .{ .on = s.g, .r = 4 }, .{ .on = s.d, .r = 8 } };
    for (bars) |b| if (b.on) {
        for (0..6) |c| {
            g.a[b.r][c] = 255;
            g.a[b.r + 1][c] = 255;
        }
    };
    for (0..6) |r| {
        if (s.f) g.a[r][0..2].* = .{ 255, 255 };
        if (s.b) g.a[r][4..6].* = .{ 255, 255 };
    }
    for (4..10) |r| {
        if (s.e) g.a[r][0..2].* = .{ 255, 255 };
        if (s.c) g.a[r][4..6].* = .{ 255, 255 };
    }
    return g;
}

const block_digits: [10]Glyph = blk: {
    var out: [10]Glyph = undefined;
    for (segment_table, 0..) |s, i| out[i] = blockGlyph(s);
    // the stock 1: the flag is a one-pixel staircase down and to the left of the bar's top
    out[1] = fromArt(6, 10, .{ "..##..", ".###..", "####..", "..##..", "..##..", "..##..", "..##..", "..##..", "######", "######" });
    break :blk out;
};
const block_colon = fromArt(2, 10, .{ "..", "..", "##", "##", "..", "..", "##", "##", "..", ".." });
const block_space = fromArt(6, 10, .{ "......", "......", "......", "......", "......", "......", "......", "......", "......", "......" });

/// the glyph for a character in a font; characters a font lacks draw as a blank cell.
pub fn glyph(f: Font, c: u8) Glyph {
    switch (f) {
        .classic, .hires => return classicGlyph(c, 1),
        .big => return if (c == ':') big_colon else classicGlyph(c, 2),
        .mini => {
            if (c >= '0' and c <= '9') return mini_digits[c - '0'];
            if (c == ':') return mini_colon;
            if (c == '/') return mini_slash;
            if (c == '.') return mini_dot;
            return mini_space;
        },
        .segment => {
            if (c >= '0' and c <= '9') return segment_digits[c - '0'];
            if (c == ':') return segment_colon;
            return segment_space;
        },
        .block => {
            if (c >= '0' and c <= '9') return block_digits[c - '0'];
            if (c == ':') return block_colon;
            return block_space;
        },
    }
}

/// pixel width of a string: glyph widths plus the gaps between them.
pub fn textWidth(f: Font, text: []const u8) u32 {
    var w: u32 = 0;
    for (text, 0..) |c, i| {
        if (i > 0) w += gap(f);
        w += glyph(f, c).w;
    }
    return w;
}

/// a colour at an alpha level: 255 leaves it untouched, 0 is black.
pub fn scaled(colour: [3]u8, alpha: u8) [3]u8 {
    const gain: u32 = @as(u32, alpha) + (alpha >> 7);
    var out: [3]u8 = undefined;
    for (colour, &out) |c, *o| o.* = @intCast((@as(u32, c) * gain) >> 8);
    return out;
}

/// draw text with its top-left at (x0, y0); every lit pixel takes its colour from
/// `painter.at(x, y)`, dimmed by the glyph's alpha. pixels outside the panel are skipped.
pub fn blit(rgb: *geometry.Rgb, x0: i32, y0: i32, f: Font, text: []const u8, painter: anytype) void {
    var x = x0;
    for (text, 0..) |c, i| {
        if (i > 0) x += gap(f);
        const g = glyph(f, c);
        for (0..g.h) |r| {
            const y = y0 + @as(i32, @intCast(r));
            if (y >= 0 and y < geometry.height) {
                for (0..g.w) |col| {
                    const a = g.a[r][col];
                    if (a == 0) continue;
                    const px = x + @as(i32, @intCast(col));
                    if (px < 0 or px >= geometry.width) continue;
                    const o = geometry.pixelOffset(@intCast(px), @intCast(y));
                    rgb[o..][0..3].* = scaled(painter.at(px, y), a);
                }
            }
        }
        x += g.w;
    }
}

/// a painter with one colour.
pub const Solid = struct {
    colour: [3]u8,
    pub fn at(self: Solid, x: i32, y: i32) [3]u8 {
        _ = x;
        _ = y;
        return self.colour;
    }
};

// tests

const Counting = struct {
    min_x: i32 = 1000,
    max_x: i32 = -1,
    min_y: i32 = 1000,
    max_y: i32 = -1,
    lit: u32 = 0,
    fn at(self: *Counting, x: i32, y: i32) [3]u8 {
        self.min_x = @min(self.min_x, x);
        self.max_x = @max(self.max_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_y = @max(self.max_y, y);
        self.lit += 1;
        return .{ 255, 2, 3 };
    }
};

test "every digit in every font lights something inside its cell and digits differ" {
    inline for (@typeInfo(Font).@"enum".fields) |f| {
        const fnt: Font = @enumFromInt(f.value);
        var d: u8 = '0';
        while (d <= '9') : (d += 1) {
            const g = glyph(fnt, d);
            try std.testing.expectEqual(glyphHeight(fnt), g.h);
            var any = false;
            for (g.a[0..g.h]) |row| {
                for (row[g.w..]) |a| try std.testing.expectEqual(@as(u8, 0), a);
                for (row[0..g.w]) |a| any = any or a != 0;
            }
            try std.testing.expect(any);
            var e: u8 = '0';
            while (e < d) : (e += 1) try std.testing.expect(!std.meta.eql(glyph(fnt, d).a, glyph(fnt, e).a));
        }
        try std.testing.expect(glyph(fnt, ':').w > 0);
    }
}

test "text widths match the layouts the clock relies on" {
    try std.testing.expectEqual(@as(u32, 47), textWidth(.classic, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 39), textWidth(.segment, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 27), textWidth(.mini, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 19), textWidth(.mini, "07/09"));
    try std.testing.expectEqual(@as(u32, 33), textWidth(.mini, "10.0.0.111"));
    try std.testing.expectEqual(@as(u32, 52), textWidth(.big, "13:05"));
    try std.testing.expectEqual(@as(u32, 47), textWidth(.block, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 0), textWidth(.big, ""));
}

test "big is the classic digit scaled by two; segment and block digits are the expected shapes" {
    const one = glyph(.classic, '1');
    const big_one = glyph(.big, '1');
    try std.testing.expectEqual(@as(u8, 10), big_one.w);
    try std.testing.expectEqual(@as(u8, 14), big_one.h);
    for (0..7) |r| for (0..5) |c| {
        try std.testing.expectEqual(one.a[r][c], big_one.a[2 * r][2 * c]);
        try std.testing.expectEqual(one.a[r][c], big_one.a[2 * r + 1][2 * c + 1]);
    };
    const eight = glyph(.segment, '8');
    try std.testing.expectEqual([5]u8{ 0, 255, 255, 255, 0 }, eight.a[0][0..5].*);
    try std.testing.expectEqual([5]u8{ 255, 0, 0, 0, 255 }, eight.a[1][0..5].*);
    try std.testing.expectEqual([5]u8{ 0, 255, 255, 255, 0 }, eight.a[4][0..5].*);
    const seven = glyph(.segment, '7');
    try std.testing.expectEqual([5]u8{ 0, 0, 0, 0, 255 }, seven.a[6][0..5].*);
    try std.testing.expectEqual([5]u8{ 0, 0, 0, 0, 0 }, seven.a[8][0..5].*);
    // block: the stock face's 2 has a full top bar, a right upper stroke, a middle bar, a left
    // lower stroke and a full bottom bar, all two pixels thick
    const two = glyph(.block, '2');
    try std.testing.expectEqual(@as(u8, 6), two.w);
    try std.testing.expectEqual(@as(u8, 10), two.h);
    const full = [6]u8{ 255, 255, 255, 255, 255, 255 };
    try std.testing.expectEqual(full, two.a[0][0..6].*);
    try std.testing.expectEqual(full, two.a[1][0..6].*);
    try std.testing.expectEqual([6]u8{ 0, 0, 0, 0, 255, 255 }, two.a[2][0..6].*);
    try std.testing.expectEqual(full, two.a[4][0..6].*);
    try std.testing.expectEqual([6]u8{ 255, 255, 0, 0, 0, 0 }, two.a[7][0..6].*);
    try std.testing.expectEqual(full, two.a[9][0..6].*);
    const zero = glyph(.block, '0');
    try std.testing.expectEqual([6]u8{ 255, 255, 0, 0, 255, 255 }, zero.a[5][0..6].*);
    const block_one = glyph(.block, '1');
    try std.testing.expectEqual([6]u8{ 0, 0, 255, 255, 0, 0 }, block_one.a[0][0..6].*);
    try std.testing.expectEqual([6]u8{ 0, 255, 255, 255, 0, 0 }, block_one.a[1][0..6].*);
    try std.testing.expectEqual([6]u8{ 255, 255, 255, 255, 0, 0 }, block_one.a[2][0..6].*);
    try std.testing.expectEqual([6]u8{ 0, 0, 255, 255, 0, 0 }, block_one.a[3][0..6].*);
    try std.testing.expectEqual(full, block_one.a[9][0..6].*);
    const colon = glyph(.block, ':');
    try std.testing.expectEqual(@as(u8, 2), colon.w);
    try std.testing.expectEqual([2]u8{ 255, 255 }, colon.a[2][0..2].*);
    try std.testing.expectEqual([2]u8{ 0, 0 }, colon.a[4][0..2].*);
}

test "the blit stays inside the text box, clips at the panel edge, uses the painter and the alpha" {
    var rgb = geometry.black_rgb;
    var p = Counting{};
    blit(&rgb, 6, 3, .segment, "83:05:09", &p); // an 8 lights the cell's left column; a 1 would not
    try std.testing.expectEqual(@as(i32, 6), p.min_x);
    try std.testing.expectEqual(@as(i32, 6 + 39 - 1), p.max_x);
    try std.testing.expectEqual(@as(i32, 3), p.min_y);
    try std.testing.expectEqual(@as(i32, 11), p.max_y);
    try std.testing.expectEqual([3]u8{ 255, 2, 3 }, rgb[geometry.pixelOffset(7, 3)..][0..3].*);
    var q = Counting{};
    blit(&rgb, 44, 10, .big, "88", &q); // the first 8 is cut at the right edge, the second lies wholly outside
    try std.testing.expectEqual(@as(i32, 51), q.max_x);
    try std.testing.expectEqual(@as(i32, 15), q.max_y);
    var solid = geometry.black_rgb;
    blit(&solid, 2, 4, .classic, "13:05:06", Solid{ .colour = .{ 9, 8, 7 } });
    var expected = geometry.black_rgb;
    font.blit(&expected, 2, 4, "13:05:06", .{ 9, 8, 7 });
    try std.testing.expectEqualSlices(u8, &expected, &solid);
    // alpha scales the painter's colour: full alpha is exact, zero is black, half is half
    try std.testing.expectEqual([3]u8{ 200, 100, 50 }, scaled(.{ 200, 100, 50 }, 255));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, scaled(.{ 200, 100, 50 }, 0));
    try std.testing.expectEqual([3]u8{ 100, 50, 25 }, scaled(.{ 200, 100, 50 }, 128));
}
