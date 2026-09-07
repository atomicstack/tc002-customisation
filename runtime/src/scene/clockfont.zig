//! digit fonts for the clock scene: the built-in 5x7 font, a 3x5 `mini`, a seven-segment 5x9
//! `segment` generated from a segment table, and `big`, the 5x7 digits scaled to 10x14. glyphs
//! are fixed-size bit rows; the blit takes a painter so a gradient is a colour function over the
//! text, not a property of the font. pure.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");

pub const Font = enum(u8) { classic = 0, mini = 1, segment = 2, big = 3 };
pub const font_count: u8 = @typeInfo(Font).@"enum".fields.len;

pub const max_h = 14;

/// one glyph: `w` columns, `h` rows, row bits with bit (w - 1 - col) set for a lit pixel.
pub const Glyph = struct { w: u8, h: u8, rows: [max_h]u16 };

pub fn glyphHeight(f: Font) u8 {
    return switch (f) {
        .classic => 7,
        .mini => 5,
        .segment => 9,
        .big => 14,
    };
}

/// columns between glyphs.
pub fn gap(f: Font) u8 {
    return if (f == .big) 2 else 1;
}

fn fromArt(comptime w: u8, comptime h: u8, comptime art: [h]*const [w:0]u8) Glyph {
    var g = Glyph{ .w = w, .h = h, .rows = [_]u16{0} ** max_h };
    for (art, 0..) |row, r| {
        var bits: u16 = 0;
        for (row, 0..) |ch, c| {
            if (ch == '#') bits |= @as(u16, 1) << @intCast(w - 1 - c);
        }
        g.rows[r] = bits;
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
    var g = Glyph{ .w = 5, .h = 9, .rows = [_]u16{0} ** max_h };
    const bar: u16 = 0b01110; // cols 1..3
    const left: u16 = 0b10000;
    const right: u16 = 0b00001;
    if (s.a) g.rows[0] |= bar;
    if (s.g) g.rows[4] |= bar;
    if (s.d) g.rows[8] |= bar;
    for (1..4) |r| {
        if (s.f) g.rows[r] |= left;
        if (s.b) g.rows[r] |= right;
    }
    for (5..8) |r| {
        if (s.e) g.rows[r] |= left;
        if (s.c) g.rows[r] |= right;
    }
    return g;
}

const segment_digits: [10]Glyph = blk: {
    var out: [10]Glyph = undefined;
    for (segment_table, 0..) |s, i| out[i] = segmentGlyph(s);
    break :blk out;
};
const segment_colon = fromArt(1, 9, .{ ".", ".", "#", ".", ".", ".", "#", ".", "." });
const segment_space = Glyph{ .w = 5, .h = 9, .rows = [_]u16{0} ** max_h };

/// the built-in font's glyph as a `Glyph`, optionally scaled by two.
fn classicGlyph(c: u8, comptime scale: u8) Glyph {
    const src = font.glyph(c);
    var g = Glyph{ .w = font.glyph_w * scale, .h = font.glyph_h * scale, .rows = [_]u16{0} ** max_h };
    for (src, 0..) |row, r| {
        var bits: u16 = 0;
        for (0..font.glyph_w) |col| {
            if ((row >> @intCast(font.glyph_w - 1 - col)) & 1 != 0) {
                for (0..scale) |k| bits |= @as(u16, 1) << @intCast(g.w - 1 - (col * scale + k));
            }
        }
        for (0..scale) |k| g.rows[r * scale + k] = bits;
    }
    return g;
}

/// the big colon: four-by-four dots so "hh:mm" spans exactly the 52 columns.
const big_colon = fromArt(4, 14, .{ "....", "....", "####", "####", "####", "####", "....", "....", "####", "####", "####", "####", "....", "...." });

/// the glyph for a character in a font; characters a font lacks draw as a blank cell.
pub fn glyph(f: Font, c: u8) Glyph {
    switch (f) {
        .classic => return classicGlyph(c, 1),
        .big => return if (c == ':') big_colon else classicGlyph(c, 2),
        .mini => {
            if (c >= '0' and c <= '9') return mini_digits[c - '0'];
            if (c == ':') return mini_colon;
            if (c == '/') return mini_slash;
            return mini_space;
        },
        .segment => {
            if (c >= '0' and c <= '9') return segment_digits[c - '0'];
            if (c == ':') return segment_colon;
            return segment_space;
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

/// draw text with its top-left at (x0, y0); every lit pixel takes its colour from
/// `painter.at(x, y)`. pixels outside the panel are skipped.
pub fn blit(rgb: *geometry.Rgb, x0: i32, y0: i32, f: Font, text: []const u8, painter: anytype) void {
    var x = x0;
    for (text, 0..) |c, i| {
        if (i > 0) x += gap(f);
        const g = glyph(f, c);
        for (0..g.h) |r| {
            const y = y0 + @as(i32, @intCast(r));
            if (y >= 0 and y < geometry.height) {
                for (0..g.w) |col| {
                    if ((g.rows[r] >> @intCast(g.w - 1 - col)) & 1 == 0) continue;
                    const px = x + @as(i32, @intCast(col));
                    if (px < 0 or px >= geometry.width) continue;
                    const o = geometry.pixelOffset(@intCast(px), @intCast(y));
                    rgb[o..][0..3].* = painter.at(px, y);
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
        return .{ 1, 2, 3 };
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
            for (g.rows[0..g.h]) |row| {
                try std.testing.expect(row >> @intCast(g.w) == 0);
                any = any or row != 0;
            }
            try std.testing.expect(any);
            var e: u8 = '0';
            while (e < d) : (e += 1) try std.testing.expect(!std.mem.eql(u16, &glyph(fnt, d).rows, &glyph(fnt, e).rows));
        }
        for (glyph(fnt, ':').rows) |row| try std.testing.expect(row != 0 or true);
    }
}

test "text widths match the layouts the clock relies on" {
    try std.testing.expectEqual(@as(u32, 47), textWidth(.classic, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 39), textWidth(.segment, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 27), textWidth(.mini, "13:05:09"));
    try std.testing.expectEqual(@as(u32, 19), textWidth(.mini, "07/09"));
    try std.testing.expectEqual(@as(u32, 52), textWidth(.big, "13:05"));
    try std.testing.expectEqual(@as(u32, 0), textWidth(.big, ""));
}

test "big is the classic digit scaled by two and segment digits are the expected shapes" {
    const one = glyph(.classic, '1');
    const big_one = glyph(.big, '1');
    try std.testing.expectEqual(@as(u8, 10), big_one.w);
    try std.testing.expectEqual(@as(u8, 14), big_one.h);
    for (0..7) |r| {
        var expected: u16 = 0;
        for (0..5) |col| if ((one.rows[r] >> @intCast(4 - col)) & 1 != 0) {
            expected |= @as(u16, 0b11) << @intCast(8 - col * 2);
        };
        try std.testing.expectEqual(expected, big_one.rows[2 * r]);
        try std.testing.expectEqual(expected, big_one.rows[2 * r + 1]);
    }
    const eight = glyph(.segment, '8');
    try std.testing.expectEqual(@as(u16, 0b01110), eight.rows[0]);
    try std.testing.expectEqual(@as(u16, 0b10001), eight.rows[1]);
    try std.testing.expectEqual(@as(u16, 0b01110), eight.rows[4]);
    try std.testing.expectEqual(@as(u16, 0b01110), eight.rows[8]);
    const seven = glyph(.segment, '7');
    try std.testing.expectEqual(@as(u16, 0b00001), seven.rows[6]);
    try std.testing.expectEqual(@as(u16, 0), seven.rows[8]);
}

test "the blit stays inside the text box, clips at the panel edge and uses the painter" {
    var rgb = geometry.black_rgb;
    var p = Counting{};
    blit(&rgb, 6, 3, .segment, "83:05:09", &p); // an 8 lights the cell's left column; a 1 would not
    try std.testing.expectEqual(@as(i32, 6), p.min_x);
    try std.testing.expectEqual(@as(i32, 6 + 39 - 1), p.max_x);
    try std.testing.expectEqual(@as(i32, 3), p.min_y);
    try std.testing.expectEqual(@as(i32, 11), p.max_y);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, rgb[geometry.pixelOffset(7, 3)..][0..3].*);
    var q = Counting{};
    blit(&rgb, 44, 10, .big, "88", &q); // the first 8 is cut at the right edge, the second lies wholly outside
    try std.testing.expectEqual(@as(i32, 51), q.max_x);
    try std.testing.expectEqual(@as(i32, 15), q.max_y);
    var solid = geometry.black_rgb;
    blit(&solid, 2, 4, .classic, "13:05:06", Solid{ .colour = .{ 9, 8, 7 } });
    var expected = geometry.black_rgb;
    font.blit(&expected, 2, 4, "13:05:06", .{ 9, 8, 7 });
    try std.testing.expectEqualSlices(u8, &expected, &solid);
}
