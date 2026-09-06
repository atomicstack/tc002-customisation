//! popsquares: every cell holds a level 0..127 that counts down and snaps back to full (or, now
//! and then, to a random dim level) when spent. a fixed per-cell rank decides whether the cell
//! takes part at all. some pops use the tint colour instead of white.
//!
//! pure and deterministic for a given seed. ported from led/popsquares.c, itself a port of the
//! pixdeck plugin and the popsquares_tc002 processing sketch.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const scene = @import("scene.zig");

test "the same seed renders the same bytes" {
    var a = State.init(.{}, 1);
    var b = State.init(.{}, 1);
    var ra: geometry.Rgb = undefined;
    var rb: geometry.Rgb = undefined;
    a.render(.{}, &ra);
    b.render(.{}, &rb);
    try std.testing.expectEqualSlices(u8, &ra, &rb);
}

test "cells re-arm after a full pop" {
    const o = Options{};
    var s = State.init(o, 3);
    var rose = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const before = s.level;
        s.step(o, o.pop_s / 4.0);
        for (before, s.level) |b, a| if (a > b) {
            rose = true;
        };
    }
    try std.testing.expect(rose);
}

test "no alive cells renders black" {
    const o = Options{ .alive = 0 };
    var s = State.init(o, 5);
    s.step(o, 0.01);
    var rgb: geometry.Rgb = undefined;
    s.render(o, &rgb);
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &rgb);
}

test "a long pause is credited as at most half a second" {
    const o = Options{};
    var a = State.init(o, 7);
    var b = State.init(o, 7);
    a.step(o, 10.0);
    b.step(o, dt_max);
    try std.testing.expectEqualSlices(f32, &a.level, &b.level);
}

pub const level_max: f32 = 127.0;
/// longest wall-clock gap credited to one step.
pub const dt_max: f32 = 0.5;
/// float decay rarely lands on exactly 0; anything this close is spent.
pub const spent: f32 = 1e-4;

/// the pixdeck plugin's defaults: pop 2 s, everything alive, 25% dim re-arms over the full range,
/// 15% tinted, tint = steel blue.
pub const Options = struct {
    pop_s: f32 = 2.0,
    alive: f32 = 1.0,
    dim: f32 = 0.25,
    dim_lo: u8 = 0,
    dim_hi: u8 = 127,
    tint_frac: f32 = 0.15,
    tint: [3]u8 = .{ 58, 110, 165 },
};

pub const State = struct {
    level: [geometry.pixels]f32,
    rank: [geometry.pixels]f32,
    tinted: [geometry.pixels]bool,
    rng: scene.Rng,

    /// fresh panel: random starting levels so the first frame is already mid-pop, fixed ranks,
    /// tinted flags drawn at tint_frac.
    pub fn init(o: Options, seed: u32) State {
        var s: State = undefined;
        s.rng = scene.Rng.init(seed);
        for (0..geometry.pixels) |i| {
            s.level[i] = s.rng.range(0.0, level_max);
            s.rank[i] = s.rng.unit();
            s.tinted[i] = s.rng.unit() < o.tint_frac;
        }
        return s;
    }

    /// a spent cell usually snaps back to full; sometimes it comes back dim, which is the twinkle.
    fn rearm(self: *State, i: usize, o: Options) void {
        const lo: f32 = @floatFromInt(@min(o.dim_lo, o.dim_hi));
        const hi: f32 = @floatFromInt(@max(o.dim_lo, o.dim_hi));
        self.level[i] = if (self.rng.unit() < o.dim) self.rng.range(lo, hi) else level_max;
        self.tinted[i] = self.rng.unit() < o.tint_frac;
    }

    /// advance every cell by dt seconds of wall time (clamped to dt_max).
    pub fn step(self: *State, o: Options, dt_s: f32) void {
        const dt = std.math.clamp(dt_s, 0.0, dt_max);
        const pop: f32 = if (o.pop_s > 0.0) o.pop_s else 1.0;
        const drop = level_max * dt / pop; // a full pop lasts pop_s seconds at any frame rate
        for (0..geometry.pixels) |i| {
            if (self.rank[i] >= o.alive) {
                self.level[i] = 0.0; // this led sits the animation out
                continue;
            }
            self.level[i] -= drop;
            if (self.level[i] <= spent) self.rearm(i, o);
        }
    }

    /// row-major r,g,b: white or tint scaled by level / 127.
    pub fn render(self: *const State, o: Options, rgb: *geometry.Rgb) void {
        const white = [3]u8{ 255, 255, 255 };
        for (0..geometry.pixels) |i| {
            const f = std.math.clamp(self.level[i] / level_max, 0.0, 1.0);
            const c = if (self.tinted[i]) o.tint else white;
            inline for (0..3) |k| rgb[i * 3 + k] = @intFromFloat(@as(f32, @floatFromInt(c[k])) * f);
        }
    }
};
