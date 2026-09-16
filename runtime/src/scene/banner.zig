//! one line of text drawn across the whole panel, for the moments the supervisor has something to
//! say and no scene to say it in.
//!
//! this exists for the reboot notice. the panel holds its last latched frame while nothing is
//! driving it, so a word put up immediately before the device goes down stays on the glass for the
//! whole dark stretch -- which is the difference between a clock that is rebooting and a clock that
//! has died. `batteryart.zig` is the same idea for a picture; this is the one for a word.
//!
//! the `mini` face is 5 rows tall and **proportional** -- glyph widths differ and `clockfont.gap`
//! puts one column between them -- so there is no character count that always fits, and `fits`
//! measures the actual string. a string that does not fit is refused rather than drawn off the
//! edge. the face carries one set of letterforms for both cases, so case here is for whoever reads
//! the source.
//!
//! pure, and tested on the pixels it lights.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const clockfont = @import("clockfont.zig");

/// the face the banner is set in
pub const face: clockfont.Font = .mini;

/// whether `text` fits, and so whether `draw` will put anything on the panel
pub fn fits(text: []const u8) bool {
    return clockfont.textWidth(face, text) <= geometry.width;
}

/// the left edge that centres `text`, clamped to the panel so a wide string cannot start negative
pub fn originX(text: []const u8) i32 {
    const w: i32 = @intCast(clockfont.textWidth(face, text));
    return @max(0, @divFloor(geometry.width - w, 2));
}

/// the top edge that centres the face vertically
pub fn originY() i32 {
    return @divFloor(geometry.height - @as(i32, clockfont.glyphHeight(face)), 2);
}

/// draw `text` centred on a black panel. a string too wide for the face is **not drawn at all**:
/// half a word is worse than none, and the caller is choosing a constant, not relaying input.
pub fn draw(rgb: *geometry.Rgb, text: []const u8, colour: [3]u8) void {
    rgb.* = geometry.black_rgb;
    if (!fits(text)) return;
    clockfont.blit(rgb, originX(text), originY(), face, text, clockfont.Solid{ .colour = colour });
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
    try testing.expect(fits("rebooting..."));
    try testing.expect(!fits("rebooting, please wait a moment"));
    try testing.expect(fits(""));
}

test "fits is measured, not counted: the face is proportional" {
    // narrow glyphs buy room that a character count would not know about, which is why `fits`
    // measures. these two are the same length and need not both fit.
    const wide = "wwwwwwwwwwwwww";
    const thin = "iiiiiiiiiiiiii";
    try testing.expectEqual(wide.len, thin.len);
    try testing.expect(clockfont.textWidth(face, thin) <= clockfont.textWidth(face, wide));
}

test "a banner is centred, and its margins differ by at most a pixel" {
    var rgb: geometry.Rgb = geometry.black_rgb;
    draw(&rgb, "rebooting...", .{ 0x3a, 0x6e, 0xa5 });
    const cols = litColumns(&rgb);
    const left = cols.first orelse return error.NothingDrawn;
    const right = geometry.width - 1 - (cols.last orelse return error.NothingDrawn);
    // the advance leaves a blank trailing column in the glyph cell, so the right margin can be one
    // wider than the left. anything beyond that is a centring bug, which is how the battery icon
    // was found to be off.
    try testing.expect(right >= left);
    try testing.expect(right - left <= 1);
}

test "a banner is vertically centred in the panel" {
    try testing.expectEqual(@as(i32, 5), originY()); // (16 - 5) / 2, floored
}

test "the banner is drawn in the colour it is given, and nothing else is lit" {
    var rgb: geometry.Rgb = geometry.black_rgb;
    const blue = [3]u8{ 0x3a, 0x6e, 0xa5 };
    draw(&rgb, "rebooting...", blue);
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
