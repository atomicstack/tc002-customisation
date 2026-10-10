//! one line of text drawn across the whole panel, for the moments the supervisor has something to
//! say and no scene to say it in.
//!
//! this exists for the reboot notice. the panel holds its last latched frame while nothing is
//! driving it, so a word put up immediately before the device goes down stays on the glass for the
//! whole dark stretch -- which is the difference between a clock that is rebooting and a clock that
//! has died. `batteryart.zig` is the same idea for a picture; this is the one for a word.
//!
//! the face is tiny5, the update notices' face, and it is **proportional**, so there is no
//! character count that always fits: `fits` measures the actual string, and a string that does
//! not fit is refused rather than drawn off the edge. the word is centred on its ink, both ways:
//! tiny5's letters sit in rows 3 to 9 of an 11-row cell, so centring the cell would put it high.
//!
//! pure, and tested on the pixels it lights.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const clockfont = @import("clockfont.zig");
const typeface = @import("face.zig");

/// the face the banner is set in
pub const face: typeface.Face = .{ .imported = .tiny5 };

/// whether `text` fits, and so whether `draw` will put anything on the panel
pub fn fits(text: []const u8) bool {
    return typeface.lineWidth(face, text) <= geometry.width;
}

/// the left edge that centres `text`'s ink, clamped to the panel so a wide string cannot start
/// negative
pub fn originX(text: []const u8) i32 {
    const w: i32 = @intCast(typeface.lineWidth(face, text));
    return @max(0, @divFloor(geometry.width - w, 2));
}

/// draw `text` centred on a black panel. a string too wide for the face is **not drawn at all**:
/// half a word is worse than none, and the caller is choosing a constant, not relaying input.
pub fn draw(rgb: *geometry.Rgb, text: []const u8, colour: [3]u8) void {
    rgb.* = geometry.black_rgb;
    if (!fits(text)) return;
    // set at the top, then moved down so the ink, not the cell, is centred
    var set = geometry.black_rgb;
    typeface.blit(&set, originX(text), 0, face, text, clockfont.Solid{ .colour = colour });
    const row_bytes = geometry.width * 3;
    var top: ?usize = null;
    var bottom: usize = 0;
    for (0..geometry.height) |y| {
        const row = set[y * row_bytes ..][0..row_bytes];
        if (std.mem.allEqual(u8, row, 0)) continue;
        if (top == null) top = y;
        bottom = y;
    }
    const first = top orelse return;
    const to = (geometry.height - (bottom - first + 1)) / 2;
    for (first..bottom + 1) |y| {
        @memcpy(rgb[(y - first + to) * row_bytes ..][0..row_bytes], set[y * row_bytes ..][0..row_bytes]);
    }
}

// tests

const testing = std.testing;

fn litCount(rgb: *const geometry.Rgb) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < rgb.len) : (i += 3) {
        if (rgb[i] != 0 or rgb[i + 1] != 0 or rgb[i + 2] != 0) n += 1;
    }
    return n;
}

fn litColumns(rgb: *const geometry.Rgb) struct { first: ?usize, last: ?usize } {
    var first: ?usize = null;
    var last: ?usize = null;
    for (0..geometry.width) |x| {
        var any = false;
        for (0..geometry.height) |y| {
            const o = geometry.pixelOffset(x, y);
            if (rgb[o] != 0 or rgb[o + 1] != 0 or rgb[o + 2] != 0) any = true;
        }
        if (any) {
            if (first == null) first = x;
            last = x;
        }
    }
    return .{ .first = first, .last = last };
}

test "the reboot notice fits, and an overlong string is measured as not fitting" {
    try testing.expect(fits("Rebooting..."));
    try testing.expect(!fits("rebooting, please wait a moment"));
    try testing.expect(fits(""));
}

test "fits is measured, not counted: the face is proportional" {
    // narrow glyphs buy room that a character count would not know about, which is why `fits`
    // measures. these two are the same length and need not both fit.
    const wide = "wwwwwwwwwwwwww";
    const thin = "iiiiiiiiiiiiii";
    try testing.expectEqual(wide.len, thin.len);
    try testing.expect(typeface.lineWidth(face, thin) < typeface.lineWidth(face, wide));
}

test "a banner is centred, and its margins differ by at most a pixel" {
    var rgb: geometry.Rgb = geometry.black_rgb;
    draw(&rgb, "Rebooting...", .{ 0x3a, 0x6e, 0xa5 });
    const cols = litColumns(&rgb);
    const left = cols.first orelse return error.NothingDrawn;
    const right = geometry.width - 1 - (cols.last orelse return error.NothingDrawn);
    // the advance leaves a blank trailing column in the glyph cell, so the right margin can be one
    // wider than the left. anything beyond that is a centring bug, which is how the battery icon
    // was found to be off.
    try testing.expect(right >= left);
    try testing.expect(right - left <= 1);
}

fn litRows(rgb: *const geometry.Rgb) struct { first: ?usize, last: ?usize } {
    var first: ?usize = null;
    var last: ?usize = null;
    for (0..geometry.height) |y| {
        var any = false;
        for (0..geometry.width) |x| {
            const o = geometry.pixelOffset(x, y);
            if (rgb[o] != 0 or rgb[o + 1] != 0 or rgb[o + 2] != 0) any = true;
        }
        if (any) {
            if (first == null) first = y;
            last = y;
        }
    }
    return .{ .first = first, .last = last };
}

test "a banner is vertically centred on its ink, not on its face's cell" {
    // tiny5's cell is 11 rows and the letters sit in rows 3 to 9 of it, so centring the cell put
    // the word visibly high
    var rgb: geometry.Rgb = geometry.black_rgb;
    draw(&rgb, "Rebooting...", .{ 255, 255, 255 });
    const rows = litRows(&rgb);
    const top = rows.first orelse return error.NothingDrawn;
    const bottom = geometry.height - 1 - (rows.last orelse return error.NothingDrawn);
    try testing.expect(@max(top, bottom) - @min(top, bottom) <= 1);
}

test "the reboot notice is set in tiny5, like the update notices" {
    // matt, 2026-10-10: "Flashing..." and "Working..." are tiny5; the reboot notice was still
    // the old mini face. the banner's ink is tiny5's own, moved, and nothing else
    var rgb: geometry.Rgb = geometry.black_rgb;
    draw(&rgb, "Rebooting...", .{ 255, 255, 255 });
    var ref: geometry.Rgb = geometry.black_rgb;
    typeface.blit(&ref, 0, 0, .{ .imported = .tiny5 }, "Rebooting...", clockfont.Solid{ .colour = .{ 255, 255, 255 } });
    const a = .{ litColumns(&rgb), litRows(&rgb) };
    const b = .{ litColumns(&ref), litRows(&ref) };
    const dx: i32 = @as(i32, @intCast(a[0].first orelse return error.NothingDrawn)) - @as(i32, @intCast(b[0].first.?));
    const dy: i32 = @as(i32, @intCast(a[1].first orelse return error.NothingDrawn)) - @as(i32, @intCast(b[1].first.?));
    for (0..geometry.height) |y| for (0..geometry.width) |x| {
        const sx = @as(i32, @intCast(x)) - dx;
        const sy = @as(i32, @intCast(y)) - dy;
        const want = sx >= 0 and sy >= 0 and sx < geometry.width and sy < geometry.height and ref[geometry.pixelOffset(@intCast(sx), @intCast(sy))] != 0;
        try testing.expectEqual(want, rgb[geometry.pixelOffset(x, y)] != 0);
    };
}

test "the banner is drawn in the colour it is given, and nothing else is lit" {
    var rgb: geometry.Rgb = geometry.black_rgb;
    const blue = [3]u8{ 0x3a, 0x6e, 0xa5 };
    draw(&rgb, "Rebooting...", blue);
    try testing.expect(litCount(&rgb) > 0);
    var i: usize = 0;
    while (i < rgb.len) : (i += 3) {
        const px = rgb[i .. i + 3];
        if (px[0] == 0 and px[1] == 0 and px[2] == 0) continue;
        try testing.expectEqualSlices(u8, &blue, px);
    }
}

test "a string too wide to fit leaves the panel black rather than drawing half of it" {
    var rgb: geometry.Rgb = geometry.black_rgb;
    draw(&rgb, "this is far too long for the panel", .{ 255, 255, 255 });
    try testing.expectEqual(@as(usize, 0), litCount(&rgb));
}

test "draw clears whatever was on the frame before it" {
    var rgb: geometry.Rgb = undefined;
    @memset(&rgb, 0xff);
    draw(&rgb, "ok", .{ 0x3a, 0x6e, 0xa5 });
    try testing.expect(litCount(&rgb) < geometry.width * geometry.height);
}

test "a banner drawn at compile time is the one drawn at run time" {
    // the supervisor draws its reboot notice at compile time, which keeps the imported faces out
    // of its binary; that only holds while drawing still evaluates at compile time
    const at_compile_time = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var frame: geometry.Rgb = geometry.black_rgb;
        draw(&frame, "Rebooting...", .{ 58, 110, 165 });
        break :blk frame;
    };
    var at_run_time: geometry.Rgb = undefined;
    draw(&at_run_time, "Rebooting...", .{ 58, 110, 165 });
    try testing.expectEqualSlices(u8, &at_compile_time, &at_run_time);
    try testing.expect(litCount(&at_run_time) > 0);
}
