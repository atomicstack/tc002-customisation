//! the ip scene: the ipv4 address in one of four modes, or `no ip` when nothing is configured.
//! `lines` puts the first two octets (with a trailing dot) over the last two, each line centred;
//! `mini` fits the whole address on one line of 3x5 digits with one-pixel dots; `scroll` uses the
//! 5x7 font on one line and scrolls it when it is wider than the panel; `big` uses the 10x14
//! digits and scrolls. the static modes redraw only on a change, the scrolling ones once per step.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const scene = @import("scene.zig");

/// one pixel of scroll per period (the notification scroll's pace)
pub const scroll_period_ns: u64 = 33_333_333;

pub const Mode = enum(u8) { lines = 0, mini = 1, scroll = 2, big = 3 };

/// what the ip scene can be told
pub const params = [_]param.Param{
    .{ .name = "layout", .kind = .choice, .choices = param.choicesOf(Mode), .default = 0 },
    // the scene's colour has nowhere durable to live yet, so it waits for the generic slots
};

pub const State = struct {
    addr: ?[4]u8 = null,
    colour: [3]u8 = .{ 255, 255, 255 },
    mode: Mode = .lines,

    /// returns true when the address actually changed (the caller redraws only then).
    pub fn set(self: *State, addr: ?[4]u8) bool {
        const changed = !std.meta.eql(self.addr, addr);
        self.addr = addr;
        return changed;
    }

    pub fn getParam(self: *const State, index: usize) u32 {
        return switch (index) {
            0 => @intFromEnum(self.mode),
            1 => param.rgbValue(self.colour),
            else => 0,
        };
    }

    pub fn setParam(self: *State, index: usize, value: u32) void {
        switch (index) {
            0 => _ = self.setMode(@enumFromInt(@min(value, params[0].choices.len - 1))),
            1 => self.colour = param.valueRgb(value),
            else => {},
        }
    }

    /// returns true when the mode actually changed.
    pub fn setMode(self: *State, mode: Mode) bool {
        const changed = self.mode != mode;
        self.mode = mode;
        return changed;
    }

    pub fn render(self: *const State, now_ns: u64, rgb: *geometry.Rgb) void {
        self.renderWith(self.mode, now_ns, rgb);
    }

    /// render in a given mode: the outgoing layer of a layout change keeps the old one
    pub fn renderWith(self: *const State, mode: Mode, now_ns: u64, rgb: *geometry.Rgb) void {
        rgb.* = geometry.black_rgb;
        const a = self.addr orelse {
            font.blit(rgb, 11, 4, "no ip", self.colour);
            return;
        };
        var buf: [15]u8 = undefined;
        const painter = clockfont.Solid{ .colour = self.colour };
        switch (mode) {
            .lines => {
                var b1: [9]u8 = undefined;
                var b2: [8]u8 = undefined;
                const l1 = std.fmt.bufPrint(&b1, "{d}.{d}.", .{ a[0], a[1] }) catch unreachable;
                const l2 = std.fmt.bufPrint(&b2, "{d}.{d}", .{ a[2], a[3] }) catch unreachable;
                font.blit(rgb, centred(font.textWidth(l1)), 0, l1, self.colour);
                font.blit(rgb, centred(font.textWidth(l2)), 8, l2, self.colour);
            },
            .mini => {
                const t = text(a, &buf);
                clockfont.blit(rgb, centred(clockfont.textWidth(.mini, t)), 5, .mini, t, painter);
            },
            .scroll => {
                const t = text(a, &buf);
                const w = font.textWidth(t);
                font.blit(rgb, if (w <= geometry.width) centred(w) else scrolled(w, now_ns), 4, t, self.colour);
            },
            .big => {
                const t = text(a, &buf);
                const w = clockfont.textWidth(.big, t);
                clockfont.blit(rgb, if (w <= geometry.width) centred(w) else scrolled(w, now_ns), 1, .big, t, painter);
            },
        }
    }

    pub fn cadence(self: *const State) scene.Cadence {
        const a = self.addr orelse return .idle;
        var buf: [15]u8 = undefined;
        const t = text(a, &buf);
        const scrolling = switch (self.mode) {
            .lines, .mini => false,
            .scroll => font.textWidth(t) > geometry.width,
            .big => clockfont.textWidth(.big, t) > geometry.width,
        };
        return if (scrolling) .{ .continuous = scroll_period_ns } else .idle;
    }
};

fn text(a: [4]u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch unreachable;
}

fn centred(w: anytype) i32 {
    return @divFloor(geometry.width - @as(i32, @intCast(w)), 2);
}

/// the x of a line that enters from the right edge one pixel per period and wraps after leaving
fn scrolled(w: anytype, now_ns: u64) i32 {
    const span: u64 = @intCast(@as(i32, @intCast(w)) + geometry.width);
    return geometry.width - @as(i32, @intCast((now_ns / scroll_period_ns) % span));
}

test "set and setMode report only real changes" {
    var s = State{};
    try std.testing.expect(s.set(.{ 10, 0, 0, 111 }));
    try std.testing.expect(!s.set(.{ 10, 0, 0, 111 }));
    try std.testing.expect(s.set(.{ 10, 0, 0, 112 }));
    try std.testing.expect(s.set(null));
    try std.testing.expect(!s.set(null));
    try std.testing.expect(s.setMode(.big));
    try std.testing.expect(!s.setMode(.big));
}

test "no address renders the no ip text in every mode" {
    inline for (std.meta.fields(Mode)) |f| {
        const s = State{ .mode = @enumFromInt(f.value) };
        var rgb = geometry.black_rgb;
        s.render(7_000_000_000, &rgb);
        var expected = geometry.black_rgb;
        font.blit(&expected, 11, 4, "no ip", s.colour);
        try std.testing.expectEqualSlices(u8, &expected, &rgb);
        try std.testing.expect(s.cadence() == .idle);
    }
}

test "lines renders the address on two centred lines" {
    var s = State{};
    _ = s.set(.{ 10, 0, 0, 111 });
    var rgb = geometry.black_rgb;
    s.render(0, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 11, 0, "10.0.", s.colour); // 29 px wide
    font.blit(&expected, 11, 8, "0.111", s.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expect(s.cadence() == .idle);
    _ = s.set(.{ 192, 168, 1, 20 });
    s.render(0, &rgb);
    expected = geometry.black_rgb;
    font.blit(&expected, 2, 0, "192.168.", s.colour); // 47 px
    font.blit(&expected, 14, 8, "1.20", s.colour); // 23 px
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
}

test "mini fits the address on one line with one-pixel dots" {
    var s = State{ .mode = .mini };
    _ = s.set(.{ 10, 0, 0, 111 });
    var rgb = geometry.black_rgb;
    s.render(0, &rgb);
    var expected = geometry.black_rgb;
    clockfont.blit(&expected, 9, 5, .mini, "10.0.0.111", clockfont.Solid{ .colour = s.colour }); // 33 px
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expect(s.cadence() == .idle);
    try std.testing.expectEqual(@as(u32, 53), clockfont.textWidth(.mini, "192.168.100.100")); // the widest case loses a column
}

test "scroll centres a short address and scrolls a long one" {
    var s = State{ .mode = .scroll };
    _ = s.set(.{ 1, 2, 3, 4 }); // 41 px: static
    var rgb = geometry.black_rgb;
    s.render(0, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 5, 4, "1.2.3.4", s.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expect(s.cadence() == .idle);
    _ = s.set(.{ 10, 0, 0, 111 }); // 59 px: scrolls in from the right edge
    s.render(0, &rgb);
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &rgb);
    s.render(20 * scroll_period_ns, &rgb);
    expected = geometry.black_rgb;
    font.blit(&expected, 32, 4, "10.0.0.111", s.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(scene.Cadence{ .continuous = scroll_period_ns }, s.cadence());
}

test "big scrolls any real address" {
    var s = State{ .mode = .big };
    _ = s.set(.{ 1, 2, 3, 4 }); // 7 glyphs of 10 px and 2 px gaps: 82 px
    try std.testing.expectEqual(scene.Cadence{ .continuous = scroll_period_ns }, s.cadence());
    var rgb = geometry.black_rgb;
    s.render(40 * scroll_period_ns, &rgb);
    var expected = geometry.black_rgb;
    clockfont.blit(&expected, 12, 1, .big, "1.2.3.4", clockfont.Solid{ .colour = s.colour });
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
}
