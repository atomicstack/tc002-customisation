//! popsquares: every cell holds a level 0..127 that counts down and snaps back to full (or, now
//! and then, to a random dim level) when spent. a fixed per-cell rank decides whether the cell
//! takes part at all. some pops use the tint colour instead of white.
//!
//! pure and deterministic for a given seed. ported from led/popsquares.c, itself a port of the
//! pixdeck plugin and the popsquares_tc002 processing sketch.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const scene = @import("scene.zig");

test "the same seed renders the same bytes" {
    var a = State.init(1);
    var b = State.init(1);
    var ra: geometry.Rgb = undefined;
    var rb: geometry.Rgb = undefined;
    a.render(&ra);
    b.render(&rb);
    try std.testing.expectEqualSlices(u8, &ra, &rb);
}

test "cells re-arm after a full pop" {
    var s = State.init(3);
    var rose = false;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const before = s.level;
        s.step(s.options().pop_s / 4.0);
        for (before, s.level) |b, a| if (a > b) {
            rose = true;
        };
    }
    try std.testing.expect(rose);
}

test "no alive cells renders black" {
    var s = State.init(5);
    s.setParam(1, 0); // alive 0%
    s.step(0.01);
    var rgb: geometry.Rgb = undefined;
    s.render(&rgb);
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &rgb);
}

test "a long pause is credited as at most half a second" {
    var a = State.init(7);
    var b = State.init(7);
    a.step(10.0);
    b.step(dt_max);
    try std.testing.expectEqualSlices(f32, &a.level, &b.level);
}

test "the declared defaults are the options this generator has always had" {
    // the sketch's sliders became parameters without changing what the panel does
    const o = optionsOf(param.defaults(&params));
    try std.testing.expectEqual(Options{}, o);
}

test "the parameters reach the simulation" {
    var s = State.init(11);
    s.setParam(0, 500); // a half-second pop
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.options().pop_s, 1e-6);
    s.setParam(2, 100); // every re-arm is a dim one
    s.setParam(3, 20);
    s.setParam(4, 20); // ... landing on exactly 20% of full
    try std.testing.expectEqual(@as(u8, 25), s.options().dim_lo);
    try std.testing.expectEqual(@as(u8, 25), s.options().dim_hi);
    s.step(1.0); // a whole pop at that speed, so every cell has re-armed at least once
    s.step(1.0);
    for (s.level) |l| try std.testing.expect(l <= 25.0 + spent);

    // the tint fraction and colour: all of it, in red. a cell's colour is rolled when it pops,
    // the way the sketch does it, so the panel has to turn over once before it is all red
    var t = State.init(13);
    t.setParam(0, 250);
    t.setParam(5, 100);
    t.setParam(6, 0xff0000);
    t.step(dt_max); // a whole pop, so every cell re-arms
    t.step(0.01);
    var rgb: geometry.Rgb = undefined;
    t.render(&rgb);
    var lit: usize = 0;
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] == 0 and rgb[i * 3 + 1] == 0 and rgb[i * 3 + 2] == 0) continue;
        lit += 1;
        try std.testing.expectEqual(@as(u8, 0), rgb[i * 3 + 1]); // no green
        try std.testing.expectEqual(@as(u8, 0), rgb[i * 3 + 2]); // and no blue
    }
    try std.testing.expect(lit > 100);
}

test "a value out of range is pulled back in" {
    var s = State.init(17);
    s.setParam(0, 1_000_000);
    try std.testing.expectEqual(@as(u32, 20000), s.getParam(0));
    s.setParam(1, 250);
    try std.testing.expectEqual(@as(u32, 100), s.getParam(1));
    try std.testing.expectEqual(@as(u32, 0), s.getParam(params.len)); // nothing beyond the table
}

pub const level_max: f32 = 127.0;
/// longest wall-clock gap credited to one step.
pub const dt_max: f32 = 0.5;
/// float decay rarely lands on exactly 0; anything this close is spent.
pub const spent: f32 = 1e-4;

/// the pixdeck plugin's defaults: pop 2 s, everything alive, 25% dim re-arms over the full range,
/// 15% tinted, tint = steel blue. this is the working form of `params` below, not a second set of
/// settings: every field is derived from a declared parameter.
pub const Options = struct {
    pop_s: f32 = 2.0,
    alive: f32 = 1.0,
    dim: f32 = 0.25,
    dim_lo: u8 = 0,
    dim_hi: u8 = 127,
    tint_frac: f32 = 0.15,
    tint: [3]u8 = .{ 58, 110, 165 },
};

/// the sliders of the `popsquares_tc002` processing sketch, as parameters. the sketch's other
/// sliders (led gap, corner, off level, panel brightness, and the glow) simulate the physical
/// panel this actually runs on, so they have nothing to set here.
///
/// the one change of unit is the sketch's `decay`, which counts levels lost per frame and so means
/// something different at every frame rate: a whole pop in milliseconds says the same thing and
/// survives a dropped frame. the sketch's 0.1 to 8 covers roughly 20 s down to 0.26 s.
/// `dim floor` and `dim ceiling` are its `level_min` and `level_max` as a percentage of full.
pub const params = [_]param.Param{
    .{ .name = "pop ms", .kind = .number, .min = 250, .max = 20000, .step = 250, .default = 2000 },
    .{ .name = "alive", .kind = .number, .min = 0, .max = 100, .step = 5, .default = 100 },
    .{ .name = "dim chance", .kind = .number, .min = 0, .max = 100, .step = 5, .default = 25 },
    .{ .name = "dim floor", .kind = .number, .min = 0, .max = 100, .step = 5, .default = 0 },
    .{ .name = "dim ceiling", .kind = .number, .min = 0, .max = 100, .step = 5, .default = 100 },
    .{ .name = "tint", .kind = .number, .min = 0, .max = 100, .step = 5, .default = 15 },
    .{ .name = "tint colour", .kind = .colour, .default = 0x3a6ea5 },
};

fn fraction(pct: u32) f32 {
    return @as(f32, @floatFromInt(@min(pct, 100))) / 100.0;
}

/// a percentage of the 0..127 level a cell counts down from
fn levelOf(pct: u32) u8 {
    return @intFromFloat(@round(fraction(pct) * level_max));
}

/// the working form of a set of parameter values
pub fn optionsOf(v: param.Values) Options {
    return .{
        .pop_s = @as(f32, @floatFromInt(@max(1, v[0]))) / 1000.0,
        .alive = fraction(v[1]),
        .dim = fraction(v[2]),
        .dim_lo = levelOf(v[3]),
        .dim_hi = levelOf(v[4]),
        .tint_frac = fraction(v[5]),
        .tint = param.valueRgb(v[6]),
    };
}

pub const State = struct {
    pub fn getParam(self: *const State, index: usize) u32 {
        return if (index < params.len) self.values[index] else 0;
    }

    pub fn setParam(self: *State, index: usize, value: u32) void {
        if (index < params.len) self.values[index] = params[index].clamp(value);
    }

    values: param.Values,
    level: [geometry.pixels]f32,
    rank: [geometry.pixels]f32,
    tinted: [geometry.pixels]bool,
    rng: scene.Rng,

    pub fn init(seed: u32) State {
        return initWith(param.defaults(&params), seed);
    }

    /// fresh panel: random starting levels so the first frame is already mid-pop, fixed ranks,
    /// tinted flags drawn at tint_frac.
    pub fn initWith(values: param.Values, seed: u32) State {
        var s: State = undefined;
        s.values = values;
        const o = optionsOf(values);
        s.rng = scene.Rng.init(seed);
        for (0..geometry.pixels) |i| {
            s.level[i] = s.rng.range(0.0, level_max);
            s.rank[i] = s.rng.unit();
            s.tinted[i] = s.rng.unit() < o.tint_frac;
        }
        return s;
    }

    pub fn options(self: *const State) Options {
        return optionsOf(self.values);
    }

    /// a spent cell usually snaps back to full; sometimes it comes back dim, which is the twinkle.
    fn rearm(self: *State, i: usize, o: Options) void {
        const lo: f32 = @floatFromInt(@min(o.dim_lo, o.dim_hi));
        const hi: f32 = @floatFromInt(@max(o.dim_lo, o.dim_hi));
        self.level[i] = if (self.rng.unit() < o.dim) self.rng.range(lo, hi) else level_max;
        self.tinted[i] = self.rng.unit() < o.tint_frac;
    }

    /// advance every cell by dt seconds of wall time (clamped to dt_max).
    pub fn step(self: *State, dt_s: f32) void {
        const o = self.options();
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
    pub fn render(self: *const State, rgb: *geometry.Rgb) void {
        const o = self.options();
        const white = [3]u8{ 255, 255, 255 };
        for (0..geometry.pixels) |i| {
            const f = std.math.clamp(self.level[i] / level_max, 0.0, 1.0);
            const c = if (self.tinted[i]) o.tint else white;
            inline for (0..3) |k| rgb[i * 3 + k] = @intFromFloat(@as(f32, @floatFromInt(c[k])) * f);
        }
    }
};
