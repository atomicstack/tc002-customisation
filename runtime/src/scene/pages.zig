//! the page indicator: one dot per page along the bottom row, the current one solid.
//!
//! it is shown only just after the dial has been turned, because the panel is 52x16 and a row of
//! dots left up permanently is a row of content given away. it fades in, holds for a couple of
//! seconds and fades out.
//!
//! the colour is decided per dot from whatever is already there: the clock on white would swallow
//! white dots, so each dot takes whichever of white or black stands out against its own
//! background, and the whole thing is blended over that background by the fade.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");

const ns_per_ms = 1_000_000;
pub const fade_in_ns: u64 = 150 * ns_per_ms;
pub const hold_ns: u64 = 2_500 * ns_per_ms;
pub const fade_out_ns: u64 = 600 * ns_per_ms;
pub const total_ns: u64 = fade_in_ns + hold_ns + fade_out_ns;

/// the row the dots sit on: the last one, which every scene leaves clear or nearly so
pub const row: usize = geometry.height - 1;

/// how strongly the indicator shows, 0 gone and 255 solid, from how long ago the dial moved
pub fn alphaAt(since_ns: u64) u8 {
    if (since_ns >= total_ns) return 0;
    if (since_ns < fade_in_ns) return @intCast(since_ns * 255 / fade_in_ns);
    if (since_ns < fade_in_ns + hold_ns) return 255;
    const out = since_ns - fade_in_ns - hold_ns;
    return @intCast(255 - out * 255 / fade_out_ns);
}

fn luminance(c: [3]u8) u32 {
    return (2126 * @as(u32, c[0]) + 7152 * @as(u32, c[1]) + 722 * @as(u32, c[2])) / 10000;
}

/// white on a dark background, black on a light one
fn contrasting(bg: [3]u8) [3]u8 {
    return if (luminance(bg) < 128) .{ 255, 255, 255 } else .{ 0, 0, 0 };
}

fn mix(bg: u8, fg: u8, amount: u32) u8 {
    const a: u32 = @min(amount, 255);
    return @intCast((@as(u32, bg) * (255 - a) + @as(u32, fg) * a) / 255);
}

/// the x of each dot: evenly spread, and centred so the row looks deliberate
fn dotX(count: usize, i: usize) usize {
    if (count == 0) return 0;
    const gap = geometry.width / count;
    const margin = (geometry.width - gap * (count - 1)) / 2;
    return @min(geometry.width - 1, margin + gap * i);
}

/// draw the dots over whatever is in `rgb`. `alpha` is the fade, 0 draws nothing.
pub fn draw(rgb: *geometry.Rgb, count: usize, index: usize, alpha: u8) void {
    if (alpha == 0 or count < 2 or count > geometry.width) return;
    for (0..count) |i| {
        const x = dotX(count, i);
        const o = geometry.pixelOffset(x, row);
        const bg = [3]u8{ rgb[o], rgb[o + 1], rgb[o + 2] };
        const fg = contrasting(bg);
        // the one you are on is solid; the others are pulled most of the way back to the
        // background so the current page is obvious at a glance
        const strength: u32 = if (i == index) alpha else @as(u32, alpha) * 45 / 100;
        rgb[o] = mix(bg[0], fg[0], strength);
        rgb[o + 1] = mix(bg[1], fg[1], strength);
        rgb[o + 2] = mix(bg[2], fg[2], strength);
    }
}

// tests

const white: [3]u8 = .{ 255, 255, 255 };
const black: [3]u8 = .{ 0, 0, 0 };

fn fill(rgb: *geometry.Rgb, c: [3]u8) void {
    for (0..geometry.width * geometry.height) |i| {
        rgb[i * 3] = c[0];
        rgb[i * 3 + 1] = c[1];
        rgb[i * 3 + 2] = c[2];
    }
}

fn at(rgb: *const geometry.Rgb, x: usize) [3]u8 {
    const o = geometry.pixelOffset(x, row);
    return .{ rgb[o], rgb[o + 1], rgb[o + 2] };
}

test "the fade rises, holds and falls away to nothing" {
    try std.testing.expectEqual(@as(u8, 0), alphaAt(0));
    try std.testing.expect(alphaAt(fade_in_ns / 2) > 100 and alphaAt(fade_in_ns / 2) < 160);
    try std.testing.expectEqual(@as(u8, 255), alphaAt(fade_in_ns));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(fade_in_ns + hold_ns - 1));
    try std.testing.expect(alphaAt(fade_in_ns + hold_ns + fade_out_ns / 2) < 200);
    try std.testing.expectEqual(@as(u8, 0), alphaAt(total_ns));
    try std.testing.expectEqual(@as(u8, 0), alphaAt(total_ns * 10));
}

test "dots take whichever of white or black shows against what is behind them" {
    var rgb: geometry.Rgb = undefined;
    fill(&rgb, black);
    draw(&rgb, 4, 0, 255);
    try std.testing.expectEqual(white, at(&rgb, dotX(4, 0))); // dark background: a white dot

    fill(&rgb, white);
    draw(&rgb, 4, 0, 255);
    try std.testing.expectEqual(black, at(&rgb, dotX(4, 0))); // a white clock face: a black dot

    // and the inactive ones are pulled back towards the background either way
    fill(&rgb, black);
    draw(&rgb, 4, 0, 255);
    const inactive_on_black = at(&rgb, dotX(4, 2));
    try std.testing.expect(inactive_on_black[0] > 0 and inactive_on_black[0] < 200);
    fill(&rgb, white);
    draw(&rgb, 4, 0, 255);
    const inactive_on_white = at(&rgb, dotX(4, 2));
    try std.testing.expect(inactive_on_white[0] < 255 and inactive_on_white[0] > 60);
}

test "a faded indicator leaves the content alone" {
    var rgb: geometry.Rgb = undefined;
    const teal: [3]u8 = .{ 0, 128, 128 };
    fill(&rgb, teal);
    var untouched: geometry.Rgb = undefined;
    fill(&untouched, teal);
    draw(&rgb, 6, 3, 0); // gone: nothing is drawn at all
    try std.testing.expectEqualSlices(u8, &untouched, &rgb);
    draw(&rgb, 6, 3, 40); // barely there: close to the background, but moved
    try std.testing.expect(!std.mem.eql(u8, &untouched, &rgb));
    const faint = at(&rgb, dotX(6, 3));
    try std.testing.expect(faint[1] > 128 and faint[1] < 180);
}

test "one page draws nothing, and the dots stay inside the panel" {
    var rgb: geometry.Rgb = undefined;
    fill(&rgb, black);
    draw(&rgb, 1, 0, 255); // a single page is not worth a row of the panel
    try std.testing.expectEqual(black, at(&rgb, 0));
    for ([_]usize{ 2, 4, 6, 11, 52 }) |n| {
        for (0..n) |i| try std.testing.expect(dotX(n, i) < geometry.width);
    }
}
