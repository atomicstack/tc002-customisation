//! the battery drawn at the size of the whole panel.
//!
//! the 8x8 glyph in `icons.zig` is for a document that has other things in it. this is for the
//! moments when the battery *is* the message -- the clock coming off its dock, the charge falling
//! through a threshold -- and at 52x16 there is room to say it properly: an outline, a terminal,
//! and a fill bar that is as long as the charge is.
//!
//! pure, and tested on the pixels it lights rather than by eye, because the author cannot see the
//! panel from here.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const icons = @import("icons.zig");

// the whole drawing is `body_x0 .. cap_x1` wide and has to sit centred on a 52-wide panel, so the
// span must be even: 46 here, leaving 3 clear either side. it used to span 1..47, which is 1 clear
// on the left and 4 on the right -- visibly off, and reported from a real panel. the case and the
// fill keep their old sizes; the nub gave up the pixel, because it is the part that can spare one.
/// the case: a one-pixel outline with a gap inside it before the fill starts
pub const body_x0 = 3;
pub const body_y0 = 1;
pub const body_x1 = 46; // inclusive
pub const body_y1 = 14; // inclusive
/// the nub on the positive end
pub const cap_x0 = 47;
pub const cap_x1 = 48;
pub const cap_y0 = 5;
pub const cap_y1 = 10;
/// where the charge is drawn, one pixel clear of the outline all round
pub const fill_x0 = 5;
pub const fill_y0 = 3;
pub const fill_w = 40;
pub const fill_h = 10;

fn put(rgb: *geometry.Rgb, x: usize, y: usize, colour: [3]u8) void {
    if (x >= geometry.width or y >= geometry.height) return;
    const o = geometry.pixelOffset(x, y);
    rgb[o] = colour[0];
    rgb[o + 1] = colour[1];
    rgb[o + 2] = colour[2];
}

/// how many columns of fill a charge earns. rounded to nearest so that 1% is a visible sliver
/// rather than nothing, and 99% is not indistinguishable from full.
pub fn fillWidth(pct: u8) usize {
    const p: usize = @min(pct, 100);
    if (p == 0) return 0;
    const w = (p * fill_w + 50) / 100;
    return @max(w, 1);
}

/// the whole panel: case, terminal, and the charge inside it.
///
/// `pct` is the charge to draw *now*, which during a notice's opening animation is less than the
/// real reading -- the easing lives with the clock, in `supervisor/battery_notice.zig`, and this
/// only ever draws a moment. `plug_alpha` fades the plug glyph in over whatever is beneath it;
/// zero draws none at all.
pub fn draw(rgb: *geometry.Rgb, pct: u8, colour: [3]u8, plug_alpha: u8) void {
    var x: usize = body_x0;
    while (x <= body_x1) : (x += 1) {
        put(rgb, x, body_y0, colour);
        put(rgb, x, body_y1, colour);
    }
    var y: usize = body_y0;
    while (y <= body_y1) : (y += 1) {
        put(rgb, body_x0, y, colour);
        put(rgb, body_x1, y, colour);
    }
    y = cap_y0;
    while (y <= cap_y1) : (y += 1) {
        var cx: usize = cap_x0;
        while (cx <= cap_x1) : (cx += 1) put(rgb, cx, y, colour);
    }

    const w = fillWidth(pct);
    var fx: usize = 0;
    while (fx < w) : (fx += 1) {
        var fy: usize = 0;
        while (fy < fill_h) : (fy += 1) put(rgb, fill_x0 + fx, fill_y0 + fy, colour);
    }

    if (plug_alpha == 0) return;
    // white over the fill rather than the fill's own colour: it has to read as a symbol on top of
    // a solid bar, and at 8x8 an outline would not survive. it fades in by mixing with whatever is
    // already under it, so it arrives out of the bar rather than on top of a hole in it.
    const index = icons.indexOf("plug") orelse return;
    const art = icons.bitmaps[index];
    const px = fill_x0 + (fill_w - icons.size) / 2;
    const py = fill_y0 + (fill_h - icons.size) / 2;
    for (art, 0..) |row, iy| {
        for (0..icons.size) |ix| {
            if (row & (@as(u8, 0x80) >> @intCast(ix)) == 0) continue;
            blendWhite(rgb, px + ix, py + iy, plug_alpha);
        }
    }
}

/// mix the pixel already there towards white by `alpha`
fn blendWhite(rgb: *geometry.Rgb, x: usize, y: usize, alpha: u8) void {
    if (x >= geometry.width or y >= geometry.height) return;
    const o = geometry.pixelOffset(x, y);
    const a: u16 = alpha;
    for (0..3) |c| {
        const under: u16 = rgb[o + c];
        rgb[o + c] = @intCast(under + ((255 - under) * a) / 255);
    }
}

// -- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const amber: [3]u8 = .{ 0xff, 0xcc, 0x22 };

fn lit(rgb: *const geometry.Rgb, x: usize, y: usize) bool {
    const o = geometry.pixelOffset(x, y);
    return rgb[o] != 0 or rgb[o + 1] != 0 or rgb[o + 2] != 0;
}

test "the fill is as long as the charge, and never rounds a real charge away to nothing" {
    try testing.expectEqual(@as(usize, 0), fillWidth(0));
    try testing.expectEqual(@as(usize, 1), fillWidth(1)); // a sliver, not nothing
    try testing.expectEqual(@as(usize, 2), fillWidth(4)); // under the blink threshold
    try testing.expectEqual(@as(usize, 8), fillWidth(20));
    try testing.expectEqual(@as(usize, 20), fillWidth(50));
    try testing.expectEqual(@as(usize, 36), fillWidth(89));
    try testing.expectEqual(@as(usize, fill_w), fillWidth(100));
    try testing.expectEqual(@as(usize, fill_w), fillWidth(255)); // an unknown charge cannot overrun
}

test "the case is drawn whatever the charge, so an empty battery still looks like one" {
    var rgb = geometry.black_rgb;
    draw(&rgb, 0, amber, 0);
    try testing.expect(lit(&rgb, body_x0, body_y0)); // corners
    try testing.expect(lit(&rgb, body_x1, body_y1));
    try testing.expect(lit(&rgb, body_x0, body_y1));
    try testing.expect(lit(&rgb, body_x1, body_y0));
    try testing.expect(lit(&rgb, cap_x0, cap_y0)); // the terminal
    try testing.expect(lit(&rgb, cap_x1, cap_y1));
    try testing.expect(!lit(&rgb, fill_x0, fill_y0)); // and nothing inside it
    // it stays on the panel: the far corner is beyond the case and must be dark
    try testing.expect(!lit(&rgb, geometry.width - 1, geometry.height - 1));
}

test "a full battery fills to the end of the interior and no further" {
    var rgb = geometry.black_rgb;
    draw(&rgb, 100, amber, 0);
    try testing.expect(lit(&rgb, fill_x0, fill_y0));
    try testing.expect(lit(&rgb, fill_x0 + fill_w - 1, fill_y0 + fill_h - 1));
    // the gap between the fill and the outline survives, or the picture is a solid block
    try testing.expect(!lit(&rgb, fill_x0 + fill_w, fill_y0));
    try testing.expect(!lit(&rgb, body_x0 + 1, body_y0 + 1));
}

test "charging puts the plug over the fill, and only when charging" {
    const centre_x = fill_x0 + (fill_w - icons.size) / 2;
    const centre_y = fill_y0 + (fill_h - icons.size) / 2;

    var plain = geometry.black_rgb;
    draw(&plain, 100, amber, 0);
    const o = geometry.pixelOffset(centre_x + 3, centre_y + 2);
    try testing.expectEqual(amber, [3]u8{ plain[o], plain[o + 1], plain[o + 2] });

    var charged = geometry.black_rgb;
    draw(&charged, 100, amber, 255);
    // the plug's own pixels go white; the bar around it keeps its colour
    try testing.expectEqual([3]u8{ 0xff, 0xff, 0xff }, [3]u8{ charged[o], charged[o + 1], charged[o + 2] });
    const edge = geometry.pixelOffset(fill_x0, fill_y0);
    try testing.expectEqual(amber, [3]u8{ charged[edge], charged[edge + 1], charged[edge + 2] });
}

test "a plug still reads on an empty battery, where there is no fill under it" {
    var rgb = geometry.black_rgb;
    draw(&rgb, 0, amber, 255);
    const centre_x = fill_x0 + (fill_w - icons.size) / 2;
    const centre_y = fill_y0 + (fill_h - icons.size) / 2;
    try testing.expect(lit(&rgb, centre_x + 3, centre_y + 2));
}

test "the plug fades in rather than appearing, mixing with whatever is under it" {
    const centre_x = fill_x0 + (fill_w - icons.size) / 2;
    const centre_y = fill_y0 + (fill_h - icons.size) / 2;
    const o = geometry.pixelOffset(centre_x + 3, centre_y + 2);

    var none = geometry.black_rgb;
    draw(&none, 100, amber, 0);
    try testing.expectEqual(amber, [3]u8{ none[o], none[o + 1], none[o + 2] });

    var half = geometry.black_rgb;
    draw(&half, 100, amber, 128);
    // halfway between the bar and white: brighter than the bar on every channel, not yet white
    try testing.expect(half[o] > amber[0] or amber[0] == 255);
    try testing.expect(half[o + 1] > amber[1]);
    try testing.expect(half[o + 2] > amber[2]);
    try testing.expect(half[o + 2] < 255);

    var full = geometry.black_rgb;
    draw(&full, 100, amber, 255);
    try testing.expectEqual([3]u8{ 0xff, 0xff, 0xff }, [3]u8{ full[o], full[o + 1], full[o + 2] });
}

test "the battery sits centred on the panel" {
    // reported from the device: the icon looked off-centre. it was -- the drawing spanned x=1..47,
    // one pixel clear on the left and four on the right, which at 52 wide is visible. the vertical
    // was always right. this asserts the margins rather than the constants, so it keeps holding if
    // the artwork is redrawn.
    const left = body_x0;
    const right = geometry.width - 1 - cap_x1;
    try testing.expectEqual(left, right);

    const top = body_y0;
    const bottom = geometry.height - 1 - body_y1;
    try testing.expectEqual(top, bottom);

    // and the fill stays centred inside the case it lives in
    try testing.expectEqual(fill_x0 - body_x0, body_x1 - (fill_x0 + fill_w - 1));
}
