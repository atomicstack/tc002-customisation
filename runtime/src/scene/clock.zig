//! the clock scene: hh:mm:ss in the built-in font, redrawn at wall-second boundaries. wall time
//! comes in as nanoseconds since the unix epoch; the timezone is a validated posix rule.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const tz = @import("tz.zig");
const scene = @import("scene.zig");

test "the next boundary is the next whole wall second" {
    try std.testing.expectEqual(@as(u64, 2_000_000_000), nextBoundaryWallNs(1_500_000_000));
    try std.testing.expectEqual(@as(u64, 3_000_000_000), nextBoundaryWallNs(2_000_000_000));
}

test "time of day is formatted as hh:mm:ss in local time" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("13:05:09", formatTime(13 * 3600 + 5 * 60 + 9, &buf));
    try std.testing.expectEqualStrings("00:00:00", formatTime(86400 * 3, &buf));
    try std.testing.expectEqualStrings("23:59:59", formatTime(-1, &buf));
}

test "render equals a direct blit of the formatted local time and cadence is the next boundary" {
    const rule = try tz.parse("JST-9");
    const c = State.init(rule);
    const wall_ns: u64 = (4 * 3600 + 5 * 60 + 6) * std.time.ns_per_s + 700_000_000;
    var rgb = geometry.black_rgb;
    c.render(wall_ns, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, text_x, text_y, "13:05:06", c.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = (4 * 3600 + 5 * 60 + 7) * std.time.ns_per_s }, c.cadence(wall_ns));
}

/// "hh:mm:ss" is 47 px wide and 7 px tall; centre it on the 52x16 panel.
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

pub const State = struct {
    rule: tz.Rule,
    colour: [3]u8 = .{ 255, 255, 255 },

    pub fn init(rule: tz.Rule) State {
        return .{ .rule = rule };
    }

    pub fn render(self: *const State, wall_ns: u64, rgb: *geometry.Rgb) void {
        const utc_s: i64 = @intCast(wall_ns / std.time.ns_per_s);
        var buf: [8]u8 = undefined;
        const text = formatTime(tz.localFromUtc(self.rule, utc_s), &buf);
        rgb.* = geometry.black_rgb;
        font.blit(rgb, text_x, text_y, text, self.colour);
    }

    pub fn cadence(self: *const State, wall_ns: u64) scene.Cadence {
        _ = self;
        return .{ .at_wall_ns = nextBoundaryWallNs(wall_ns) };
    }
};
