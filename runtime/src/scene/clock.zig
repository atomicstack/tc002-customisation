//! the clock scene: local time in one of four digit fonts, painted in a solid colour or a subtle
//! gradient, redrawn at wall-second boundaries. wall time comes in as nanoseconds since the unix
//! epoch; the timezone is a validated posix rule.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const tz = @import("tz.zig");
const scene = @import("scene.zig");

pub const Font = clockfont.Font;
pub const ColourMode = enum(u8) { solid = 0, gradient = 1 };
/// re-exported so callers reach every part of a clock style through this module
pub const DigitStyle = clockfont.DigitStyle;
pub const Gradient = enum(u8) { horizontal = 0, vertical = 1, diagonal = 2 };

/// the default `spread`: the whole requested gradient is shown. a smaller value bounds how far
/// any channel of the end colour may sit from the start colour, for a subtler ramp.
pub const default_spread: u8 = 255;

/// what the clock can be told, for the settings menus and the api. the order is the storage order.
pub const params = [_]param.Param{
    .{ .name = "face", .kind = .choice, .choices = param.choicesOf(Font), .default = 0 },
    .{ .name = "colour", .kind = .colour, .default = 0xffffff },
    .{ .name = "shade", .kind = .choice, .choices = param.choicesOf(ColourMode), .default = 0 },
    .{ .name = "colour 2", .kind = .colour, .default = 0xffffff },
    .{ .name = "gradient", .kind = .choice, .choices = param.choicesOf(Gradient), .default = 0 },
    .{ .name = "spread", .kind = .number, .min = 0, .max = 255, .step = 15, .default = default_spread },
    .{ .name = "digits", .kind = .choice, .choices = param.choicesOf(clockfont.DigitStyle), .default = 0 },
    .{ .name = "fade", .kind = .toggle, .default = 0 },
};

pub fn getParam(style: Style, index: usize) u32 {
    return switch (index) {
        0 => @intFromEnum(style.font),
        1 => param.rgbValue(style.colour),
        2 => @intFromEnum(style.mode),
        3 => param.rgbValue(style.colour2),
        4 => @intFromEnum(style.gradient),
        5 => style.spread,
        6 => @intFromEnum(style.digit),
        7 => @intFromBool(style.fade),
        else => 0,
    };
}

pub fn setParam(style: *Style, index: usize, value: u32) void {
    switch (index) {
        0 => style.font = @enumFromInt(@min(value, params[0].choices.len - 1)),
        1 => style.colour = param.valueRgb(value),
        2 => style.mode = @enumFromInt(@min(value, params[2].choices.len - 1)),
        3 => style.colour2 = param.valueRgb(value),
        4 => style.gradient = @enumFromInt(@min(value, params[4].choices.len - 1)),
        5 => style.spread = @intCast(@min(value, 255)),
        6 => style.digit = @enumFromInt(@min(value, params[6].choices.len - 1)),
        7 => style.fade = value != 0,
        else => {},
    }
}

pub const Style = struct {
    font: Font = .classic,
    mode: ColourMode = .solid,
    colour: [3]u8 = .{ 255, 255, 255 },
    colour2: [3]u8 = .{ 255, 255, 255 },
    gradient: Gradient = .horizontal,
    spread: u8 = default_spread,
    /// solid, hollow or with a shadow; only the fonts with a body take any notice
    digit: clockfont.DigitStyle = .solid,
    /// the block face's digits turn into the next second's over the end of each second, instead
    /// of switching at the boundary. see `fade_ns`.
    fade: bool = false,

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
        if (p.digit) |v| self.digit = v;
        if (p.fade) |v| self.fade = v;
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
    digit: ?clockfont.DigitStyle = null,
    fade: ?bool = null,
};

/// "hh:mm:ss" in the classic font is 47 px wide and 7 px tall; centred on the 52x16 panel.
pub const text_x: i32 = 2;
pub const text_y: i32 = 4;

pub fn nextBoundaryWallNs(wall_ns: u64) u64 {
    return (wall_ns / std.time.ns_per_s + 1) * std.time.ns_per_s;
}

// --- the clock that has not been set yet ---------------------------------------------------------
//
// this device has no usable rtc, so it boots at the unix epoch and stays there until the first sntp
// reply lands. in Europe/Amsterdam that reads `01:00:00`, which is a plausible-looking lie: it is a
// time, it ticks, and someone glancing at the panel has no way to tell it is wrong.
//
// so until the clock has been set, the digits are not drawn at all -- only the separators, pulsing
// once a second. that says "waiting" in a way a wrong time cannot, and it needs nothing pushed from
// the supervisor: a wall clock still down at the epoch *is* the signal, and the moment sntp steps
// it the clock appears by itself.

/// any wall time before this has never been set: 2020-01-01T00:00:00Z, chosen because it is long
/// after any plausible build and long before any plausible clock.
pub const unset_before_utc_s: i64 = 1_577_836_800;

/// has this clock never been told what time it is?
pub fn isUnset(wall_ns: u64) bool {
    return @as(i64, @intCast(wall_ns / std.time.ns_per_s)) < unset_before_utc_s;
}

/// replace every digit with a space, in place, leaving `:` and `/` where they are. the faces are
/// proportional, so a space is not a digit's width and the separators shuffle inward -- which is
/// wanted: what is left should look like a placeholder, not like a clock with its numbers stolen.
pub fn blankDigits(text: []u8) void {
    for (text) |*c| {
        if (c.* >= '0' and c.* <= '9') c.* = ' ';
    }
}

/// the separator pulse on a time sync: one breath, 600 ms long, down to a floor and back. it is
/// a wink rather than a notification, and it never reaches black for the same reason the unset
/// clock's breathing does not: a separator that vanishes reads as a fault.
pub const pulse_ns: u64 = 600 * std.time.ns_per_ms;
pub const pulse_floor: u8 = 24;

/// the separators' alpha `elapsed_ns` into a pulse: 255 at both ends, `pulse_floor` in the middle,
/// straight lines between (no libm here), and 255 for good once the pulse is over.
pub fn pulseAlpha(elapsed_ns: u64) u8 {
    if (elapsed_ns >= pulse_ns) return 255;
    const half = pulse_ns / 2;
    const from_mid = if (elapsed_ns < half) half - elapsed_ns else elapsed_ns - half;
    const span: u64 = 255 - pulse_floor;
    return @intCast(pulse_floor + span * from_mid / half);
}

// --- the fade ------------------------------------------------------------------------------------
//
// with `fade` on, the block face does not switch its digits at the second boundary: over the last
// `fade_ns` of each second every digit that is about to change fades into the next one, pixel by
// pixel, and lands on the new time exactly as the second turns. the strokes the two digits share
// stay lit throughout; only the difference moves. timed to the boundary rather than from it so the
// panel never reads a stale time: at every instant it shows either the current second or a
// blend on its way to the next.

/// how long before the second turns the digits start to turn with it
pub const fade_ns: u64 = 400 * std.time.ns_per_ms;

/// is the face fading at this wall instant: only the block face, only once the clock is set,
/// and only inside the window before the next boundary
pub fn fadeActive(style: Style, wall_ns: u64) bool {
    if (!style.fade or style.font != .block or isUnset(wall_ns)) return false;
    return wall_ns % std.time.ns_per_s >= std.time.ns_per_s - fade_ns;
}

/// how far through the window this instant is, 0..255, eased
pub fn fadeProgress(wall_ns: u64) u8 {
    const into = wall_ns % std.time.ns_per_s -| (std.time.ns_per_s - fade_ns);
    return fadeEase(@intCast(@min(into * 255 / fade_ns, 255)));
}

/// smoothstep on 0..255: 3t^2 - 2t^3, in integers, so the digits ease out of one shape and into
/// the next instead of snapping into motion (no libm here)
pub fn fadeEase(t: u8) u8 {
    const x: u32 = t;
    return @intCast(x * x * (3 * 255 - 2 * x) / (255 * 255));
}

/// the pulse the separators breathe at while the clock is unset: one turn a second, 0..255.
///
/// deeper than the canvas `pulse` (which floors at 65%) because this is the only thing on the
/// panel and has to read as a heartbeat from across a room, but it still never reaches zero -- a
/// pulse that vanishes reads as a fault rather than as waiting.
pub fn unsetAlpha(wall_ns: u64) u8 {
    const ms: u64 = (wall_ns / std.time.ns_per_ms) % 1000;
    const turn: u8 = @truncate((ms * 256) / 1000);
    const s = scene.sin1000(turn); // -1000..1000
    const scale: i32 = 575 + @divTrunc(s * 425, 1000); // 150..1000 in thousandths
    return @intCast(@divTrunc(@as(i32, 255) * scale, 1000));
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

/// one line of text, where it goes and which glyphs draw it; `to` is what it is fading into
const Line = struct { x: i32, y: i32, text: []const u8, font: Font, to: ?[]const u8 = null };

/// two colons in the time and a slash in the mini date line; room for one more
const max_separators = 4;

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
    fn paint(rgb: *geometry.Rgb, lines: []const Line, bar: ?i32, painter: anytype, digit: clockfont.DigitStyle, t: u8) void {
        for (lines) |l| {
            if (l.to) |to| clockfont.blitBlend(rgb, l.x, l.y, l.font, l.text, to, t, painter, digit) else clockfont.blitStyled(rgb, l.x, l.y, l.font, l.text, painter, digit);
        }
        if (bar) |fill| {
            var x: i32 = 0;
            while (x < fill) : (x += 1) rgb[geometry.pixelOffset(@intCast(x), @intCast(hires_bar_row))..][0..3].* = painter.at(x, hires_bar_row);
        }
    }

    pub fn render(self: *const State, wall_ns: u64, rgb: *geometry.Rgb) void {
        self.renderWith(self.style, wall_ns, rgb);
    }

    /// the face with its separators at `alpha`: 255 is the plain face, anything less is a moment of
    /// a sync pulse. the digits are never touched; an unset clock has its own breathing and no pulse.
    pub fn renderPulsed(self: *const State, style: Style, wall_ns: u64, alpha: u8, rgb: *geometry.Rgb) void {
        self.renderWith(style, wall_ns, rgb);
        if (alpha == 255 or isUnset(wall_ns)) return;
        var boxes: [max_separators]Box = undefined;
        for (boxes[0..self.separatorBoxes(style, wall_ns, &boxes)]) |b| {
            var y = @max(b.y0, 0);
            while (y <= @min(b.y1, geometry.height - 1)) : (y += 1) {
                var x = @max(b.x0, 0);
                while (x <= @min(b.x1, geometry.width - 1)) : (x += 1) {
                    const p = rgb[geometry.pixelOffset(@intCast(x), @intCast(y))..][0..3];
                    p.* = clockfont.scaled(p.*, alpha);
                }
            }
        }
    }

    /// is this led part of a separator glyph (`:` or `/`) of the face at this instant
    pub fn inSeparator(self: *const State, wall_ns: u64, x: i32, y: i32) bool {
        var boxes: [max_separators]Box = undefined;
        for (boxes[0..self.separatorBoxes(self.style, wall_ns, &boxes)]) |b| {
            if (x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1) return true;
        }
        return false;
    }

    /// the boxes the separators are drawn in, in panel coordinates: each `:` or `/` of each line,
    /// one led wider and taller when the digit style casts a shadow, since the shadow is drawn
    /// one led down and right of the glyph.
    fn separatorBoxes(self: *const State, style: Style, wall_ns: u64, out: *[max_separators]Box) usize {
        const utc_s: i64 = @intCast(wall_ns / std.time.ns_per_s);
        const local_s = tz.localFromUtc(self.rule, utc_s);
        var tbuf: [8]u8 = undefined;
        var dbuf: [5]u8 = undefined;
        var mbuf: [3]u8 = undefined;
        const time_text = formatTime(local_s, &tbuf);
        const date_text = formatDate(local_s, &dbuf);
        const ms: u32 = @intCast((wall_ns % std.time.ns_per_s) / std.time.ns_per_ms);
        const ms_text = std.fmt.bufPrint(&mbuf, "{d:0>3}", .{ms}) catch unreachable;
        var storage: [2]Line = undefined;
        const lines = layout(style, time_text, date_text, ms_text, &storage);
        const shadow: i32 = if (style.digit == .shadow) 1 else 0;
        var n: usize = 0;
        for (lines) |l| {
            for (l.text, 0..) |ch, i| {
                if (ch != ':' and ch != '/') continue;
                if (n == out.len) return n;
                const before = clockfont.textWidth(l.font, l.text[0..i]) + if (i > 0) @as(u32, clockfont.gap(l.font)) else 0;
                const g = clockfont.glyph(l.font, ch);
                const x0 = l.x + @as(i32, @intCast(before));
                out[n] = .{ .x0 = x0, .y0 = l.y, .x1 = x0 + @as(i32, g.w) - 1 + shadow, .y1 = l.y + @as(i32, g.h) - 1 + shadow };
                n += 1;
            }
        }
        return n;
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
        const unset = isUnset(wall_ns);
        if (unset) {
            blankDigits(tbuf[0..time_text.len]);
            blankDigits(dbuf[0..date_text.len]);
            blankDigits(mbuf[0..ms_text.len]);
        }
        var storage: [2]Line = undefined;
        const lines = layout(style, time_text, date_text, ms_text, &storage);
        // fading: the time line is on its way to the next second's text
        var next_buf: [8]u8 = undefined;
        var t: u8 = 0;
        if (fadeActive(style, wall_ns)) {
            storage[0].to = formatTime(tz.localFromUtc(self.rule, utc_s + 1), &next_buf);
            t = fadeProgress(wall_ns);
        }
        rgb.* = geometry.black_rgb;
        const hires = style.font == .hires;
        // the hires bar is the current second drawn as a sweep; with no second worth drawing it is
        // just a bright line implying progress that is not happening.
        const bar: ?i32 = if (hires and !unset) @intCast(ms * geometry.width / 1000) else null;
        if (unset) {
            // one flat colour for both modes: a gradient across two colons is not a gradient, and
            // the pulse is the only thing the eye should be reading here.
            const dim = clockfont.scaled(style.colour, unsetAlpha(wall_ns));
            paint(rgb, lines, bar, clockfont.Solid{ .colour = dim }, style.digit, 0);
            return;
        }
        switch (style.mode) {
            .solid => paint(rgb, lines, bar, clockfont.Solid{ .colour = style.colour }, style.digit, t),
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
                paint(rgb, lines, bar, painter, style.digit, t);
            },
        }
    }

    /// the clock redraws at the next whole second; the hires layout wants every frame, and so does
    /// an unset clock, whose separators are breathing rather than ticking; a fading block face
    /// wants them through the end of each second
    pub fn cadence(self: *const State, wall_ns: u64) scene.Cadence {
        if (self.style.font == .hires or isUnset(wall_ns)) return .{ .continuous = scene.frame_period_ns };
        const boundary = nextBoundaryWallNs(wall_ns);
        // a fading face draws every frame through the window, and otherwise sleeps until the
        // window opens rather than until the second turns
        if (self.style.fade and self.style.font == .block) {
            if (fadeActive(self.style, wall_ns)) return .{ .continuous = scene.frame_period_ns };
            return .{ .at_wall_ns = boundary - fade_ns };
        }
        return .{ .at_wall_ns = boundary };
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
    const wall_ns: u64 = test_wall_base + (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 700_000_000;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, text_x, text_y, "13:05:06", c.style.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = test_wall_base + (4 * 3600 + 5 * 60 + 7) * std.time.ns_per_s }, c.cadence(wall_ns));
}

/// midnight utc on 2026-09-07, and a whole number of days, so a time-of-day added to it renders
/// exactly as it would have on its own. the render tests used to use a bare time-of-day, which is
/// 1970 and now draws as a clock that has never been set -- see `isUnset`.
const test_wall_base: u64 = 1788739200 * std.time.ns_per_s;

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
    const wall_ns: u64 = test_wall_base + (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 417_000_000;
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
    const wall_ns: u64 = test_wall_base + (8 * 3600 + 8 * 60 + 8) * std.time.ns_per_s;
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
    const wall_ns: u64 = test_wall_base + (8 * 3600 + 8 * 60 + 8) * std.time.ns_per_s;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    const b = litBox(&rgb);
    try std.testing.expectEqual(Box{ .x0 = 2, .y0 = 3, .x1 = 48, .y1 = 12 }, b);
}

test "a clock that has never been set is recognised by its own wall time" {
    // the device comes up at the unix epoch -- the supervisor's own first log lines are stamped
    // 1970-01-01 -- so a wall clock still down there has never been told what time it is.
    try std.testing.expect(isUnset(0));
    try std.testing.expect(isUnset(1_000 * std.time.ns_per_s));
    try std.testing.expect(!isUnset(@as(u64, 1_789_000_000) * std.time.ns_per_s)); // 2026
}

test "an unset clock blanks its digits and keeps its separators" {
    var buf: [8]u8 = undefined;
    const text = formatTime(3661, &buf); // 01:01:01
    try std.testing.expectEqualStrings("01:01:01", text);
    blankDigits(buf[0..text.len]);
    try std.testing.expectEqualStrings("  :  :  ", buf[0..text.len]);
}

test "blanking leaves the date's slash and empties the milliseconds outright" {
    var d: [5]u8 = undefined;
    const date = formatDate(0, &d);
    blankDigits(d[0..date.len]);
    try std.testing.expectEqualStrings("  /  ", d[0..date.len]);
    var m = [_]u8{ '0', '4', '2' };
    blankDigits(&m);
    try std.testing.expectEqualStrings("   ", &m);
}

test "the unset pulse turns once a second and never goes fully dark" {
    var lowest: u16 = 1000;
    var highest: u16 = 0;
    var ms: u64 = 0;
    while (ms < 1000) : (ms += 10) {
        const a = unsetAlpha(ms * std.time.ns_per_ms);
        lowest = @min(lowest, a);
        highest = @max(highest, a);
    }
    try std.testing.expect(lowest > 0); // a pulse that vanishes reads as a fault
    try std.testing.expect(highest >= 250);
    try std.testing.expect(highest - lowest > 150); // but it is clearly a pulse

    // one turn per second: the same point in the next second is the same brightness
    try std.testing.expectEqual(unsetAlpha(250 * std.time.ns_per_ms), unsetAlpha(1250 * std.time.ns_per_ms));
    try std.testing.expectEqual(unsetAlpha(0), unsetAlpha(std.time.ns_per_s));
}

test "an unset clock lights only its separators, and far fewer pixels than a set one" {
    var unset_rgb: geometry.Rgb = geometry.black_rgb;
    var set_rgb: geometry.Rgb = geometry.black_rgb;
    const s = State.init(tz.utc);
    // brightest point of the pulse, so the comparison is not measuring the envelope
    s.render(250 * std.time.ns_per_ms, &unset_rgb);
    s.render(@as(u64, 1_789_000_000) * std.time.ns_per_s + 250 * std.time.ns_per_ms, &set_rgb);
    var unset_lit: usize = 0;
    var set_lit: usize = 0;
    var i: usize = 0;
    while (i < unset_rgb.len) : (i += 3) {
        if (unset_rgb[i] != 0 or unset_rgb[i + 1] != 0 or unset_rgb[i + 2] != 0) unset_lit += 1;
        if (set_rgb[i] != 0 or set_rgb[i + 1] != 0 or set_rgb[i + 2] != 0) set_lit += 1;
    }
    try std.testing.expect(unset_lit > 0); // the separators are there
    try std.testing.expect(set_lit > unset_lit * 3); // and nothing else is
}

test "an unset clock redraws every frame so the pulse moves; a set one waits for the second" {
    const s = State.init(tz.utc);
    try std.testing.expectEqual(scene.Cadence{ .continuous = scene.frame_period_ns }, s.cadence(0));
    const synced = @as(u64, 1_789_000_000) * std.time.ns_per_s;
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = nextBoundaryWallNs(synced) }, s.cadence(synced));
}

test "a separator pulse dims only the separators, and full strength is no pulse at all" {
    const rule = try tz.parse("JST-9");
    var c = State.init(rule);
    const wall_ns: u64 = test_wall_base + (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 700_000_000;
    for ([_]Font{ .classic, .mini, .big, .block }) |f| {
        c.style.font = f;
        var plain = geometry.black_rgb;
        c.render(wall_ns, &plain);
        var full = geometry.black_rgb;
        c.renderPulsed(c.style, wall_ns, 255, &full);
        try std.testing.expectEqualSlices(u8, &plain, &full);
        var dark = geometry.black_rgb;
        c.renderPulsed(c.style, wall_ns, 0, &dark);
        // something changed, and everything that changed sits inside a separator glyph's box
        var changed: usize = 0;
        for (0..geometry.height) |y| for (0..geometry.width) |x| {
            const i = (y * geometry.width + x) * 3;
            if (std.mem.eql(u8, plain[i..][0..3], dark[i..][0..3])) continue;
            changed += 1;
            try std.testing.expect(c.inSeparator(wall_ns, @intCast(x), @intCast(y)));
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, dark[i..][0..3]); // alpha 0 is black
        };
        try std.testing.expect(changed > 0);
    }
}

test "the pulse is one breath: full, down to the floor, and back within its length" {
    try std.testing.expectEqual(@as(u8, 255), pulseAlpha(0));
    try std.testing.expectEqual(pulse_floor, pulseAlpha(pulse_ns / 2));
    try std.testing.expectEqual(@as(u8, 255), pulseAlpha(pulse_ns));
    try std.testing.expectEqual(@as(u8, 255), pulseAlpha(pulse_ns * 10));
    try std.testing.expect(pulseAlpha(pulse_ns / 4) < 255 and pulseAlpha(pulse_ns / 4) > pulse_floor);
}

test "fade is the clock's eighth parameter, a toggle, off by default" {
    try std.testing.expectEqual(@as(usize, 8), params.len);
    try std.testing.expectEqualStrings("fade", params[7].name);
    try std.testing.expectEqual(param.Kind.toggle, params[7].kind);
    var s = Style{};
    try std.testing.expect(!s.fade);
    try std.testing.expectEqual(@as(u32, 0), getParam(s, 7));
    setParam(&s, 7, 1);
    try std.testing.expect(s.fade);
    try std.testing.expectEqual(@as(u32, 1), getParam(s, 7));
    s.apply(.{ .fade = false });
    try std.testing.expect(!s.fade);
}

test "the block face fades into the next second's digits through the end of the second, and is exactly the next second at the boundary" {
    var c = State.init(tz.utc);
    c.style.font = .block;
    const sec = test_wall_base + (8 * 3600 + 8 * 60 + 9) * std.time.ns_per_s; // 08:08:09 -> 08:08:10: both seconds digits change
    var plain_09 = geometry.black_rgb;
    var plain_10 = geometry.black_rgb;
    c.render(sec + 100 * std.time.ns_per_ms, &plain_09);
    c.render(sec + std.time.ns_per_s, &plain_10);

    c.style.fade = true;
    var frame = geometry.black_rgb;
    c.render(sec + 100 * std.time.ns_per_ms, &frame); // long before the window: the plain face
    try std.testing.expectEqualSlices(u8, &plain_09, &frame);
    c.render(sec + std.time.ns_per_s - fade_ns, &frame); // the window opens on the old digits
    try std.testing.expectEqualSlices(u8, &plain_09, &frame);
    c.render(sec + std.time.ns_per_s, &frame); // and closes on the new ones, exactly
    try std.testing.expectEqualSlices(u8, &plain_10, &frame);

    // halfway: neither face, and everything that differs from the old face sits in the two
    // seconds digits (columns 36..48 of the block layout); the hours, minutes and colons hold still
    c.render(sec + std.time.ns_per_s - fade_ns / 2, &frame);
    try std.testing.expect(!std.mem.eql(u8, &plain_09, &frame));
    try std.testing.expect(!std.mem.eql(u8, &plain_10, &frame));
    var changed: usize = 0;
    for (0..geometry.height) |y| for (0..geometry.width) |x| {
        const i = (y * geometry.width + x) * 3;
        if (std.mem.eql(u8, plain_09[i..][0..3], frame[i..][0..3])) continue;
        changed += 1;
        try std.testing.expect(x >= 36);
    };
    try std.testing.expect(changed > 0);
}

test "the fade moves every frame: two instants inside the window draw differently" {
    var c = State.init(tz.utc);
    c.style = .{ .font = .block, .fade = true };
    const sec = test_wall_base + (8 * 3600 + 8 * 60 + 9) * std.time.ns_per_s;
    var a = geometry.black_rgb;
    var b = geometry.black_rgb;
    c.render(sec + std.time.ns_per_s - fade_ns / 2, &a);
    c.render(sec + std.time.ns_per_s - fade_ns / 4, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "fade only touches the block face, and never an unset clock" {
    const sec = test_wall_base + (8 * 3600 + 8 * 60 + 9) * std.time.ns_per_s;
    const mid = sec + std.time.ns_per_s - fade_ns / 2;
    for ([_]Font{ .classic, .mini, .segment, .big, .hires }) |f| {
        var c = State.init(tz.utc);
        c.style.font = f;
        var plain = geometry.black_rgb;
        c.render(mid, &plain);
        c.style.fade = true;
        var fading = geometry.black_rgb;
        c.render(mid, &fading);
        try std.testing.expectEqualSlices(u8, &plain, &fading);
        try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = nextBoundaryWallNs(mid) }, State.init(tz.utc).cadence(mid));
    }
    var unset = State.init(tz.utc);
    unset.style = .{ .font = .block, .fade = true };
    try std.testing.expect(!fadeActive(unset.style, std.time.ns_per_s - fade_ns / 2));
}

test "a fading block clock wants one redraw when the window opens, then every frame until the second turns" {
    var c = State.init(tz.utc);
    c.style = .{ .font = .block, .fade = true };
    const sec = test_wall_base + (8 * 3600 + 8 * 60 + 9) * std.time.ns_per_s;
    const window = sec + std.time.ns_per_s - fade_ns;
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = window }, c.cadence(sec + 100 * std.time.ns_per_ms));
    try std.testing.expectEqual(scene.Cadence{ .continuous = scene.frame_period_ns }, c.cadence(window));
    try std.testing.expectEqual(scene.Cadence{ .continuous = scene.frame_period_ns }, c.cadence(sec + std.time.ns_per_s - 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = window + std.time.ns_per_s }, c.cadence(sec + std.time.ns_per_s));
    c.style.fade = false;
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = sec + std.time.ns_per_s }, c.cadence(sec + 100 * std.time.ns_per_ms));
}

test "the fade eases: it starts and ends gently rather than at full speed" {
    try std.testing.expectEqual(@as(u8, 0), fadeEase(0));
    try std.testing.expectEqual(@as(u8, 255), fadeEase(255));
    try std.testing.expect(fadeEase(32) < 32); // slow off the mark
    try std.testing.expect(fadeEase(223) > 223); // and slow into the finish
    try std.testing.expect(fadeEase(128) > 120 and fadeEase(128) < 136); // symmetric about the middle
}
