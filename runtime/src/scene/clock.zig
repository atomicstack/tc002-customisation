//! the clock scene: local time in one of four digit fonts, painted in a solid colour or a subtle
//! gradient, redrawn at wall-second boundaries. wall time comes in as nanoseconds since the unix
//! epoch; the timezone is a validated posix rule.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const tz = @import("tz.zig");
const scene = @import("scene.zig");

pub const Font = clockfont.Font;
pub const ColourMode = enum(u8) { solid = 0, gradient = 1 };
pub const Gradient = enum(u8) { horizontal = 0, vertical = 1, diagonal = 2 };

/// the default `spread`: the whole requested gradient is shown. a smaller value bounds how far
/// any channel of the end colour may sit from the start colour, for a subtler ramp.
pub const default_spread: u8 = 255;

pub const Style = struct {
    font: Font = .classic,
    mode: ColourMode = .solid,
    colour: [3]u8 = .{ 255, 255, 255 },
    colour2: [3]u8 = .{ 255, 255, 255 },
    gradient: Gradient = .horizontal,
    spread: u8 = default_spread,

    /// the gradient end after the spread bound.
    pub fn effectiveColour2(self: Style) [3]u8 {
        var out: [3]u8 = undefined;
        for (self.colour, self.colour2, &out) |a, b, *o| {
            const lo: i32 = @as(i32, a) - self.spread;
            const hi: i32 = @as(i32, a) + self.spread;
            o.* = @intCast(std.math.clamp(@as(i32, b), @max(lo, 0), @min(hi, 255)));
        }
        return out;
    }

    pub fn apply(self: *Style, p: StylePatch) void {
        if (p.font) |v| self.font = v;
        if (p.mode) |v| self.mode = v;
        if (p.colour) |v| self.colour = v;
        if (p.colour2) |v| self.colour2 = v;
        if (p.gradient) |v| self.gradient = v;
        if (p.spread) |v| self.spread = v;
    }
};

/// a partial style, as a transient `/scene` request or a settings change carries it.
pub const StylePatch = struct {
    font: ?Font = null,
    mode: ?ColourMode = null,
    colour: ?[3]u8 = null,
    colour2: ?[3]u8 = null,
    gradient: ?Gradient = null,
    spread: ?u8 = null,
};

/// "hh:mm:ss" in the classic font is 47 px wide and 7 px tall; centred on the 52x16 panel.
pub const text_x: i32 = 2;
pub const text_y: i32 = 4;

pub fn nextBoundaryWallNs(wall_ns: u64) u64 {
    return (wall_ns / std.time.ns_per_s + 1) * std.time.ns_per_s;
}

/// local seconds since the epoch -> "hh:mm:ss".
pub fn formatTime(local_s: i64, buf: *[8]u8) []const u8 {
    const sod: u32 = @intCast(@mod(local_s, 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ sod / 3600, (sod / 60) % 60, sod % 60 }) catch unreachable;
}

/// local seconds since the epoch -> "dd/mm".
pub fn formatDate(local_s: i64, buf: *[5]u8) []const u8 {
    const civil = tz.civilFromDays(@divFloor(local_s, 86400));
    return std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}", .{ civil.day, civil.month }) catch unreachable;
}

/// an inclusive pixel box.
const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// colour as a function of position over the text box: start on one side, end on the other.
const GradientPainter = struct {
    c1: [3]u8,
    c2: [3]u8,
    box: Box,
    dir: Gradient,

    pub fn at(self: GradientPainter, x: i32, y: i32) [3]u8 {
        const w: i32 = @max(self.box.x1 - self.box.x0, 1);
        const h: i32 = @max(self.box.y1 - self.box.y0, 1);
        const fx: i32 = std.math.clamp(@divTrunc((x - self.box.x0) * 256, w), 0, 256);
        const fy: i32 = std.math.clamp(@divTrunc((y - self.box.y0) * 256, h), 0, 256);
        const t: i32 = switch (self.dir) {
            .horizontal => fx,
            .vertical => fy,
            .diagonal => @divTrunc(fx + fy, 2),
        };
        var out: [3]u8 = undefined;
        for (self.c1, self.c2, &out) |a, b, *o| o.* = @intCast(@as(i32, a) + @divTrunc((@as(i32, b) - @as(i32, a)) * t, 256));
        return out;
    }
};

/// one line of text, where it goes and which glyphs draw it.
const Line = struct { x: i32, y: i32, text: []const u8, font: Font };

/// the hires layout: the time on rows 0..6, a bar on row 8 filling through each second, the
/// milliseconds in mini digits on rows 10..14
const hires_bar_row: i32 = 8;
const hires_ms_y: i32 = 10;

pub const State = struct {
    rule: tz.Rule,
    style: Style = .{},

    pub fn init(rule: tz.Rule) State {
        return .{ .rule = rule };
    }

    fn centre(f: Font, text: []const u8) i32 {
        return @divFloor(geometry.width - @as(i32, @intCast(clockfont.textWidth(f, text))), 2);
    }

    /// where each font puts its text: everything centred, `mini` adds the date underneath,
    /// `big` shows hours and minutes only.
    fn layout(style: Style, time_text: []const u8, date_text: []const u8, ms_text: []const u8, lines: *[2]Line) []const Line {
        const f = style.font;
        switch (f) {
            .classic, .segment, .block => {
                lines[0] = .{ .x = centre(f, time_text), .y = @divFloor(geometry.height - @as(i32, clockfont.glyphHeight(f)), 2), .text = time_text, .font = f };
                return lines[0..1];
            },
            .big => {
                lines[0] = .{ .x = centre(f, time_text[0..5]), .y = 1, .text = time_text[0..5], .font = f };
                return lines[0..1];
            },
            .mini => {
                lines[0] = .{ .x = centre(f, time_text), .y = 2, .text = time_text, .font = f };
                lines[1] = .{ .x = centre(f, date_text), .y = 9, .text = date_text, .font = f };
                return lines[0..2];
            },
            .hires => {
                lines[0] = .{ .x = centre(.classic, time_text), .y = 0, .text = time_text, .font = .classic };
                lines[1] = .{ .x = centre(.mini, ms_text), .y = hires_ms_y, .text = ms_text, .font = .mini };
                return lines[0..2];
            },
        }
    }

    /// draw the lines and, for hires, the bar of the current second
    fn paint(rgb: *geometry.Rgb, lines: []const Line, bar: ?i32, painter: anytype) void {
        for (lines) |l| clockfont.blit(rgb, l.x, l.y, l.font, l.text, painter);
        if (bar) |fill| {
            var x: i32 = 0;
            while (x < fill) : (x += 1) rgb[geometry.pixelOffset(@intCast(x), @intCast(hires_bar_row))..][0..3].* = painter.at(x, hires_bar_row);
        }
    }

    pub fn render(self: *const State, wall_ns: u64, rgb: *geometry.Rgb) void {
        self.renderWith(self.style, wall_ns, rgb);
    }

    /// render with a given style: the outgoing layer of a restyle transition keeps the old one
    pub fn renderWith(self: *const State, style: Style, wall_ns: u64, rgb: *geometry.Rgb) void {
        const utc_s: i64 = @intCast(wall_ns / std.time.ns_per_s);
        const local_s = tz.localFromUtc(self.rule, utc_s);
        var tbuf: [8]u8 = undefined;
        var dbuf: [5]u8 = undefined;
        const time_text = formatTime(local_s, &tbuf);
        const date_text = formatDate(local_s, &dbuf);
        const ms: u32 = @intCast((wall_ns % std.time.ns_per_s) / std.time.ns_per_ms);
        var mbuf: [3]u8 = undefined;
        const ms_text = std.fmt.bufPrint(&mbuf, "{d:0>3}", .{ms}) catch unreachable;
        var storage: [2]Line = undefined;
        const lines = layout(style, time_text, date_text, ms_text, &storage);
        rgb.* = geometry.black_rgb;
        const hires = style.font == .hires;
        const bar: ?i32 = if (hires) @intCast(ms * geometry.width / 1000) else null;
        switch (style.mode) {
            .solid => paint(rgb, lines, bar, clockfont.Solid{ .colour = style.colour }),
            .gradient => {
                var box = Box{ .x0 = geometry.width, .y0 = geometry.height, .x1 = -1, .y1 = -1 };
                for (lines) |l| {
                    box.x0 = @min(box.x0, l.x);
                    box.y0 = @min(box.y0, l.y);
                    box.x1 = @max(box.x1, l.x + @as(i32, @intCast(clockfont.textWidth(l.font, l.text))) - 1);
                    box.y1 = @max(box.y1, l.y + @as(i32, clockfont.glyphHeight(l.font)) - 1);
                }
                if (hires) box = .{ .x0 = 0, .y0 = 0, .x1 = geometry.width - 1, .y1 = hires_ms_y + 4 }; // the bar spans the panel
                const painter = GradientPainter{ .c1 = style.colour, .c2 = style.effectiveColour2(), .box = box, .dir = style.gradient };
                paint(rgb, lines, bar, painter);
            },
        }
    }

    /// the clock redraws at the next whole second; the hires layout wants every frame
    pub fn cadence(self: *const State, wall_ns: u64) scene.Cadence {
        if (self.style.font == .hires) return .{ .continuous = scene.frame_period_ns };
        return .{ .at_wall_ns = nextBoundaryWallNs(wall_ns) };
    }
};

// tests

test "the next boundary is the next whole wall second" {
    try std.testing.expectEqual(@as(u64, 2_000_000_000), nextBoundaryWallNs(1_500_000_000));
    try std.testing.expectEqual(@as(u64, 3_000_000_000), nextBoundaryWallNs(2_000_000_000));
}

test "time of day is formatted as hh:mm:ss in local time, the date as dd/mm" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("13:05:09", formatTime(13 * 3600 + 5 * 60 + 9, &buf));
    try std.testing.expectEqualStrings("00:00:00", formatTime(86400 * 3, &buf));
    try std.testing.expectEqualStrings("23:59:59", formatTime(-1, &buf));
    var dbuf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("07/09", formatDate(1788739200, &dbuf)); // 2026-09-06 08:00 utc as local seconds
    try std.testing.expectEqualStrings("01/01", formatDate(0, &dbuf));
}

test "the classic solid render equals a direct blit of the formatted local time; cadence is the next boundary" {
    const rule = try tz.parse("JST-9");
    const c = State.init(rule);
    const wall_ns: u64 = (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 700_000_000;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, text_x, text_y, "13:05:06", c.style.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = (4 * 3600 + 5 * 60 + 7) * std.time.ns_per_s }, c.cadence(wall_ns));
}

fn litBox(rgb: *const geometry.Rgb) Box {
    var b = Box{ .x0 = geometry.width, .y0 = geometry.height, .x1 = -1, .y1 = -1 };
    for (0..geometry.height) |y| for (0..geometry.width) |x| {
        const p = rgb[geometry.pixelOffset(x, y)..][0..3];
        if (p[0] != 0 or p[1] != 0 or p[2] != 0) {
            b.x0 = @min(b.x0, @as(i32, @intCast(x)));
            b.x1 = @max(b.x1, @as(i32, @intCast(x)));
            b.y0 = @min(b.y0, @as(i32, @intCast(y)));
            b.y1 = @max(b.y1, @as(i32, @intCast(y)));
        }
    };
    return b;
}

test "every font renders centred within its box; big drops the seconds; mini adds the date" {
    var c = State.init(tz.utc);
    const wall_ns: u64 = 1788739200 * std.time.ns_per_s + (10 * 3600 + 8 * 60 + 8) * std.time.ns_per_s; // 2026-09-06 18:08:08 utc
    var rgb = geometry.black_rgb;
    c.style.font = .segment;
    c.render(wall_ns, &rgb);
    var b = litBox(&rgb);
    try std.testing.expectEqual(Box{ .x0 = 10, .y0 = 3, .x1 = 44, .y1 = 11 }, b); // the segment 1 is its cell's right bar, so the box starts 4 columns in
    c.style.font = .big;
    c.render(wall_ns, &rgb);
    b = litBox(&rgb);
    try std.testing.expectEqual(Box{ .x0 = 2, .y0 = 1, .x1 = 51, .y1 = 14 }, b); // "18:08": the 1 starts at column 2, the last 8 ends at 51
    c.style.font = .mini;
    c.render(wall_ns, &rgb);
    b = litBox(&rgb);
    try std.testing.expectEqual(Box{ .x0 = 12, .y0 = 2, .x1 = 38, .y1 = 13 }, b);
    // the date line "06/09" sits in rows 9..13 and lights the slash's top-right pixel
    try std.testing.expect(rgb[geometry.pixelOffset(16 + 3 + 1 + 3 + 1 + 2, 9)] != 0);
}

test "hires shows the time, a bar through the second and the milliseconds, every frame" {
    const rule = try tz.parse("JST-9");
    var c = State.init(rule);
    c.style.font = .hires;
    const wall_ns: u64 = (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 417_000_000;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 2, 0, "13:05:06", c.style.colour);
    for (0..21) |x| expected[geometry.pixelOffset(x, 8)..][0..3].* = c.style.colour; // 417 of 1000 -> 21 of 52 columns
    clockfont.blit(&expected, 20, 10, .mini, "417", clockfont.Solid{ .colour = c.style.colour });
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(scene.Cadence{ .continuous = scene.frame_period_ns }, c.cadence(wall_ns));
    c.render(wall_ns + 500_000_000, &rgb); // 13:05:06.917: 47 of 52 columns
    try std.testing.expect(rgb[geometry.pixelOffset(46, 8)] != 0);
    try std.testing.expect(rgb[geometry.pixelOffset(47, 8)] == 0);
    c.style.mode = .gradient;
    c.style.colour2 = .{ 0, 0, 255 };
    c.render(wall_ns, &rgb);
    try std.testing.expect(rgb[geometry.pixelOffset(0, 8)] != 0); // the bar takes the gradient too
}

test "a gradient runs from the start colour to the clamped end colour across the text" {
    var c = State.init(tz.utc);
    c.style = .{ .font = .segment, .mode = .gradient, .colour = .{ 200, 0, 0 }, .colour2 = .{ 0, 255, 0 }, .gradient = .horizontal };
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, c.style.effectiveColour2()); // the default spread shows the whole ramp
    c.style.spread = 96;
    try std.testing.expectEqual([3]u8{ 104, 96, 0 }, c.style.effectiveColour2());
    const wall_ns: u64 = (8 * 3600 + 8 * 60 + 8) * std.time.ns_per_s;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    const left = rgb[geometry.pixelOffset(6, 4)..][0..3].*; // the first 0's left bar
    const right = rgb[geometry.pixelOffset(44, 4)..][0..3].*; // the last 8's right bar
    try std.testing.expectEqual([3]u8{ 200, 0, 0 }, left);
    try std.testing.expect(right[0] < 120 and right[1] > 80);
    c.style.spread = 255;
    c.render(wall_ns, &rgb);
    const far = rgb[geometry.pixelOffset(44, 4)..][0..3].*;
    try std.testing.expect(far[0] < 20 and far[1] > 230); // unbounded: nearly the end colour itself
    c.style.spread = 96;
    c.style.gradient = .vertical;
    c.render(wall_ns, &rgb);
    const top = rgb[geometry.pixelOffset(7, 3)..][0..3].*;
    const bottom = rgb[geometry.pixelOffset(7, 11)..][0..3].*;
    try std.testing.expectEqual([3]u8{ 200, 0, 0 }, top);
    try std.testing.expect(bottom[1] > 80);
    c.style.mode = .solid;
    c.render(wall_ns, &rgb);
    try std.testing.expectEqual([3]u8{ 200, 0, 0 }, rgb[geometry.pixelOffset(44, 4)..][0..3].*);
}

test "style patches merge field by field" {
    var s = Style{};
    s.apply(.{ .font = .big, .colour = .{ 1, 2, 3 } });
    try std.testing.expectEqual(Font.big, s.font);
    try std.testing.expectEqual(ColourMode.solid, s.mode);
    s.apply(.{ .mode = .gradient, .gradient = .diagonal, .spread = 64 });
    try std.testing.expectEqual(Font.big, s.font);
    try std.testing.expectEqual(Gradient.diagonal, s.gradient);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, s.colour);
    try std.testing.expectEqual(@as(u8, 64), s.spread);
}

test "the block font fills 47 of the 52 columns and ten of the rows, centred" {
    var c = State.init(tz.utc);
    c.style.font = .block;
    const wall_ns: u64 = (8 * 3600 + 8 * 60 + 8) * std.time.ns_per_s;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    const b = litBox(&rgb);
    try std.testing.expectEqual(Box{ .x0 = 2, .y0 = 3, .x1 = 48, .y1 = 12 }, b);
}
