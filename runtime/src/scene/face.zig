//! the one interface to every face: the hand-drawn ones in font.zig and clockfont.zig and the
//! imported ones in faces.bin. text is utf-8; a codepoint a face lacks draws as u+fffd if the face
//! has it, else as `?`. the hand-drawn faces only know ascii, so anything else in them is one `?`
//! per character, not one per byte.
//!
//! faces.bin, per face (offsets in faces.zig): `count` index entries of 11 bytes sorted by
//! codepoint -- cp u24 be, x i8 (left bearing), y i8 (top row in the trimmed line box), w u8,
//! h u8, advance u8, bits u24 be (from the face's bitmap area) -- then the bitmaps, `w*h` bits msb
//! first, each glyph starting on a byte. pure: no allocation, no state.
const std = @import("std");
const testing = std.testing;
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const faces = @import("faces.zig");

const white = clockfont.Solid{ .colour = .{ 255, 255, 255 } };

test "decoding: ascii, two to four bytes, and every malformed shape becomes u+fffd" {
    var i: usize = 0;
    try testing.expectEqual(@as(u21, 'a'), nextCodepoint("a", &i));
    i = 0;
    try testing.expectEqual(@as(u21, 0xb0), nextCodepoint("\xc2\xb0", &i));
    try testing.expectEqual(@as(usize, 2), i);
    i = 0;
    try testing.expectEqual(@as(u21, 0x1d52d), nextCodepoint("\xf0\x9d\x94\xad", &i));
    for ([_][]const u8{ "\xc2", "\xe2\x82", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\x80" }) |bad| {
        i = 0;
        try testing.expectEqual(replacement, nextCodepoint(bad, &i));
        try testing.expect(i >= 1);
    }
}

test "valid text: utf-8 without control characters" {
    try testing.expect(validText("20°C ☺"));
    try testing.expect(validText("plain ascii, as ever ~"));
    try testing.expect(!validText("a\x01b"));
    try testing.expect(!validText("a\x7fb"));
    try testing.expect(!validText("\xc2\x85")); // c1 next-line
    try testing.expect(!validText("cut \xe2\x82")); // a sequence cut by a byte limit
    try testing.expect(!validText("\xff"));
}

test "builtin faces render ascii exactly as before" {
    for ([_][]const u8{ "13:05:09", "hello, panel", "abc?%" }) |s| {
        var old = geometry.black_rgb;
        var new = geometry.black_rgb;
        font.blit(&old, 3, 4, s, .{ 255, 255, 255 });
        blit(&new, 3, 4, .small, s, white);
        try testing.expectEqualSlices(u8, &old, &new);
        try testing.expectEqual(@as(u32, @intCast(font.textWidth(s))), textWidth(.small, s));
        for ([_]clockfont.Font{ .mini, .block, .big, .segment }) |cf| {
            old = geometry.black_rgb;
            new = geometry.black_rgb;
            clockfont.blit(&old, 1, 2, cf, s, white);
            const f: Face = switch (cf) {
                .mini => .mini,
                .block => .block,
                .big => .big,
                else => .segment,
            };
            blit(&new, 1, 2, f, s, white);
            try testing.expectEqualSlices(u8, &old, &new);
            try testing.expectEqual(clockfont.textWidth(cf, s), textWidth(f, s));
        }
    }
}

test "builtin face draws one ? per character, not per byte" {
    try testing.expectEqual(textWidth(.small, "20?C"), textWidth(.small, "20°C"));
    var a = geometry.black_rgb;
    var b = geometry.black_rgb;
    blit(&a, 0, 0, .small, "20?C", white);
    blit(&b, 0, 0, .small, "20°C", white);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "every imported face carries ascii and fits the panel" {
    for (std.meta.tags(faces.Name)) |n| {
        const f = Face{ .imported = n };
        try testing.expect(lineHeight(f) > 0 and lineHeight(f) <= geometry.height);
        var c: u21 = 0x21;
        while (c <= 0x7e) : (c += 1) try testing.expect(lookup(n, c) != null);
    }
}

test "line heights are the trimmed boxes" {
    try testing.expectEqual(@as(u8, 7), lineHeight(.small));
    try testing.expectEqual(@as(u8, 5), lineHeight(.mini));
    try testing.expectEqual(@as(u8, 6), lineHeight(.{ .imported = .chunky6 }));
    try testing.expectEqual(@as(u8, 8), lineHeight(.{ .imported = .phoenix }));
    try testing.expectEqual(@as(u8, 11), lineHeight(.{ .imported = .@"robotron-a7100" }));
}

test "width is the sum of advances" {
    const f = Face{ .imported = .phoenix };
    try testing.expectEqual(@as(u32, 8 * 5), textWidth(f, "12:34"));
    try testing.expectEqual(@as(u32, 8 * 3), textWidth(f, "☺°α")); // cp437's graphics are reachable
    try testing.expectEqual(@as(u32, 0), textWidth(f, ""));
}

test "a codepoint a face lacks falls back to u+fffd, then ?" {
    const f = Face{ .imported = .phoenix }; // cp437 has neither u+fffd nor cyrillic
    try testing.expect(lookup(.phoenix, 0x0416) == null);
    try testing.expectEqual(textWidth(f, "?"), textWidth(f, "Ж"));
    var a = geometry.black_rgb;
    var b = geometry.black_rgb;
    blit(&a, 0, 0, f, "?", white);
    blit(&b, 0, 0, f, "Ж", white);
    try testing.expectEqualSlices(u8, &a, &b);
    try testing.expect(lookup(.@"ibm-vga", 0x0416) != null); // pxplus has zhe
    try testing.expectEqual(@as(u32, 8), textWidth(.{ .imported = .@"ibm-vga" }, "Ж"));
}

test "a phoenix glyph lands where the source drew it" {
    // phoenix 'A' is `..###...` over `.##.##..`: its first lit row is the top of the 8-row box
    var rgb = geometry.black_rgb;
    blit(&rgb, 10, 3, .{ .imported = .phoenix }, "A", white);
    const lit = struct {
        fn at(p: *const geometry.Rgb, x: usize, y: usize) bool {
            return p[geometry.pixelOffset(x, y)] != 0;
        }
    }.at;
    try testing.expect(!lit(&rgb, 11, 3) and lit(&rgb, 12, 3) and lit(&rgb, 14, 3) and !lit(&rgb, 15, 3));
    try testing.expect(lit(&rgb, 11, 4) and !lit(&rgb, 13, 4) and lit(&rgb, 14, 4));
}

test "imported blit clips at every edge and lights the panel inside" {
    for (std.meta.tags(faces.Name)) |n| {
        var rgb = geometry.black_rgb;
        blit(&rgb, -5, -3, .{ .imported = n }, "Hi°", white);
        blit(&rgb, 47, 12, .{ .imported = n }, "xy", white);
        blit(&rgb, 300, 300, .{ .imported = n }, "far", white);
        blit(&rgb, -300, -300, .{ .imported = n }, "far", white);
        try testing.expect(!std.mem.eql(u8, &geometry.black_rgb, &rgb));
    }
}

test "names resolve to imported faces only" {
    try testing.expectEqual(faces.Name.@"tiny5-duo", byName("tiny5-duo").?);
    try testing.expect(byName("Tiny5") == null);
    try testing.expect(byName("small") == null); // the hand-drawn faces are named by their own enums
}

test "the blob stays under its ceiling" {
    try testing.expect(faces.blob.len <= 256 * 1024);
}

pub const replacement: u21 = 0xfffd;

/// every face text can be set in. the hand-drawn ones carry ascii only; `imported` are the ones in
/// faces.bin.
pub const Face = union(enum) { small, mini, block, big, segment, imported: faces.Name };

const entry_len = 11;

const Glyph = struct { x: i8, y: i8, w: u8, h: u8, advance: u8, bits: []const u8 };

/// the codepoint at `i.*`, moving `i` past it. a malformed or cut sequence is u+fffd and moves on
/// by one byte, so a broken string still advances and still draws something.
pub fn nextCodepoint(text: []const u8, i: *usize) u21 {
    const b0 = text[i.*];
    if (b0 < 0x80) {
        i.* += 1;
        return b0;
    }
    const n: usize = std.unicode.utf8ByteSequenceLength(b0) catch {
        i.* += 1;
        return replacement;
    };
    if (i.* + n > text.len) {
        i.* += 1;
        return replacement;
    }
    const cp = std.unicode.utf8Decode(text[i.*..][0..n]) catch {
        i.* += 1;
        return replacement;
    };
    i.* += n;
    return cp;
}

/// text a person may send: well-formed utf-8 with no control characters (c0, del or c1)
pub fn validText(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    var i: usize = 0;
    while (i < text.len) {
        const cp = nextCodepoint(text, &i);
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    }
    return true;
}

/// an imported face by its name; the hand-drawn faces are named by the enums that hold them
pub fn byName(name: []const u8) ?faces.Name {
    return std.meta.stringToEnum(faces.Name, name);
}

fn read24(b: *const [3]u8) u32 {
    return std.mem.readInt(u24, b, .big);
}

fn lookup(n: faces.Name, cp: u21) ?Glyph {
    const m = faces.metrics[@backingInt(n)];
    var lo: usize = 0;
    var hi: usize = m.count;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const e = faces.blob[m.index + mid * entry_len ..][0..entry_len];
        const c = read24(e[0..3]);
        if (c == cp) return .{
            .x = @bitCast(e[3]),
            .y = @bitCast(e[4]),
            .w = e[5],
            .h = e[6],
            .advance = e[7],
            .bits = faces.blob[m.bitmaps + read24(e[8..11]) ..],
        };
        if (c < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn importedGlyph(n: faces.Name, cp: u21) ?Glyph {
    return lookup(n, cp) orelse lookup(n, replacement) orelse lookup(n, '?');
}

/// the byte a hand-drawn face draws for a codepoint
fn builtinByte(cp: u21) u8 {
    return if (cp >= 0x20 and cp <= 0x7e) @intCast(cp) else '?';
}

fn clockOf(f: Face) clockfont.Font {
    return switch (f) {
        .mini => .mini,
        .block => .block,
        .big => .big,
        .segment => .segment,
        .small, .imported => unreachable,
    };
}

pub fn lineHeight(f: Face) u8 {
    return switch (f) {
        .small => font.glyph_h,
        .imported => |n| faces.metrics[@backingInt(n)].height,
        else => clockfont.glyphHeight(clockOf(f)),
    };
}

/// pixel width of a line. the hand-drawn faces measure as they always have, without a trailing
/// gap; an imported face's width is the plain sum of its advances, because each source keeps its
/// gap inside the advance.
pub fn textWidth(f: Face, text: []const u8) u32 {
    var w: u32 = 0;
    var i: usize = 0;
    var first = true;
    while (i < text.len) : (first = false) {
        const cp = nextCodepoint(text, &i);
        switch (f) {
            .small => w += if (first) font.glyph_w else font.advance,
            .imported => |n| w += if (importedGlyph(n, cp)) |g| g.advance else 0,
            else => {
                const cf = clockOf(f);
                if (!first) w += clockfont.gap(cf);
                w += clockfont.glyph(cf, builtinByte(cp)).w;
            },
        }
    }
    return w;
}

/// draw a line with its top-left at (x0, y0); every lit pixel takes `painter.at(x, y)`. pixels
/// off the panel are skipped.
pub fn blit(rgb: *geometry.Rgb, x0: i32, y0: i32, f: Face, text: []const u8, painter: anytype) void {
    var x = x0;
    var i: usize = 0;
    var first = true;
    while (i < text.len) : (first = false) {
        const cp = nextCodepoint(text, &i);
        switch (f) {
            .small => {
                if (!first) x += font.advance - font.glyph_w;
                drawSmall(rgb, x, y0, builtinByte(cp), painter);
                x += font.glyph_w;
            },
            .imported => |n| if (importedGlyph(n, cp)) |g| {
                drawImported(rgb, x, y0, g, painter);
                x += g.advance;
            },
            else => {
                const cf = clockOf(f);
                if (!first) x += clockfont.gap(cf);
                const one = [1]u8{builtinByte(cp)};
                clockfont.blit(rgb, x, y0, cf, &one, painter);
                x += clockfont.glyph(cf, one[0]).w;
            },
        }
    }
}

fn put(rgb: *geometry.Rgb, x: i32, y: i32, painter: anytype) void {
    if (x < 0 or x >= geometry.width or y < 0 or y >= geometry.height) return;
    rgb[geometry.pixelOffset(@intCast(x), @intCast(y))..][0..3].* = painter.at(x, y);
}

fn drawSmall(rgb: *geometry.Rgb, x0: i32, y0: i32, c: u8, painter: anytype) void {
    for (font.glyph(c), 0..) |row, r| {
        for (0..font.glyph_w) |col| {
            if ((row >> @intCast(font.glyph_w - 1 - col)) & 1 == 0) continue;
            put(rgb, x0 + @as(i32, @intCast(col)), y0 + @as(i32, @intCast(r)), painter);
        }
    }
}

fn drawImported(rgb: *geometry.Rgb, pen: i32, y0: i32, g: Glyph, painter: anytype) void {
    var bit: usize = 0;
    for (0..g.h) |r| {
        for (0..g.w) |c| {
            defer bit += 1;
            if ((g.bits[bit / 8] >> @intCast(7 - bit % 8)) & 1 == 0) continue;
            put(rgb, pen + g.x + @as(i32, @intCast(c)), y0 + g.y + @as(i32, @intCast(r)), painter);
        }
    }
}
