//! plasma: the classic sum-of-sines effect, integer only (a 256-entry sine table), so it is cheap
//! on the cortex-a7 and deterministic for a seed. it exists to prove the scene interface with a
//! second generator.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const scene = @import("scene.zig");

test "the same seed renders the same bytes and different seeds differ" {
    var a = State.init(4);
    var b = State.init(4);
    var c = State.init(5);
    var ra: geometry.Rgb = undefined;
    var rb: geometry.Rgb = undefined;
    var rc: geometry.Rgb = undefined;
    a.render(&ra);
    b.render(&rb);
    c.render(&rc);
    try std.testing.expectEqualSlices(u8, &ra, &rb);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rc));
}

test "the frame is not black and stepping changes it" {
    var s = State.init(1);
    var before: geometry.Rgb = undefined;
    s.render(&before);
    try std.testing.expect(!std.mem.eql(u8, &geometry.black_rgb, &before));
    s.step(0.1);
    var after: geometry.Rgb = undefined;
    s.render(&after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

const sine: [256]u8 = blk: {
    @setEvalBranchQuota(8000);
    var t: [256]u8 = undefined;
    for (&t, 0..) |*e, i| {
        const a = @as(f64, @floatFromInt(i)) * std.math.tau / 256.0;
        e.* = @intFromFloat(@round((@sin(a) + 1.0) * 127.5));
    }
    break :blk t;
};

pub const State = struct {
    t: u32 = 0,
    acc: f32 = 0.0,
    phase: u8,
    speed: u8,

    pub fn init(seed: u32) State {
        var r = scene.Rng.init(seed);
        return .{ .phase = @truncate(r.next()), .speed = @intCast(1 + (r.next() % 3)) };
    }

    /// advance the animation clock by dt seconds (clamped to half a second), 60 ticks per second
    /// times the seeded speed; fractional ticks accumulate so tiny steps still move.
    pub fn step(self: *State, dt_s: f32) void {
        const d = std.math.clamp(dt_s, 0.0, 0.5);
        self.acc += d * 60.0 * @as(f32, @floatFromInt(self.speed));
        const whole = @floor(self.acc);
        self.t +%= @intFromFloat(whole);
        self.acc -= whole;
    }

    pub fn render(self: *const State, rgb: *geometry.Rgb) void {
        const t: u8 = @truncate(self.t);
        for (0..geometry.height) |y| {
            for (0..geometry.width) |x| {
                const xi: u8 = @intCast(x * 4);
                const yi: u8 = @intCast(y * 12);
                const v: u16 = @as(u16, sine[xi +% t]) + sine[yi +% (t *% 2) +% self.phase] + sine[(xi +% yi) / 2 +% t];
                const c: u8 = @intCast(v / 3);
                const i = geometry.pixelOffset(x, y);
                rgb[i] = sine[c];
                rgb[i + 1] = sine[c +% 85];
                rgb[i + 2] = sine[c +% 170];
            }
        }
    }
};
