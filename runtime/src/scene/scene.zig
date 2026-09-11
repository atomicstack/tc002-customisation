//! the compile-time scene interface shared by generators and the arbiter.
//!
//! scenes are pure: they take a seed and elapsed time, render into an rgb buffer, and handle
//! normalized actions. they can never open hardware or network resources.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const popsquares = @import("popsquares.zig");
const plasma = @import("plasma.zig");

/// how a scene wants to be redrawn.
pub const Cadence = union(enum) {
    /// redraw every `period` ns (one transfer per deadline).
    continuous: u64,
    /// redraw once when the wall clock reaches this value (an isolated update).
    at_wall_ns: u64,
    /// nothing to redraw until an external change.
    idle,
};

/// normalized physical actions; no required action uses a button combination.
pub const Action = enum { left, middle, right, knob_short, knob_long, rotate_cw, rotate_ccw };

pub const Generator = enum(u8) { popsquares = 0, plasma = 1 };
pub const generator_count: u8 = @typeInfo(Generator).@"enum".fields.len;

pub const frame_period_ns: u64 = 16_666_667; // 60 hz

/// xorshift32; seed 0 is remapped to a fixed non-zero seed.
pub const Rng = struct {
    state: u32,

    pub fn init(seed: u32) Rng {
        return .{ .state = if (seed == 0) 0x9e3779b9 else seed };
    }

    pub fn next(self: *Rng) u32 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        return x;
    }

    /// uniform in [0, 1) with 24 bits of resolution.
    pub fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 8)) * (1.0 / 16777216.0);
    }

    pub fn range(self: *Rng, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.unit();
    }
};

test "rng is deterministic and never returns zero for a zero seed" {
    var a = Rng.init(0);
    var b = Rng.init(0);
    try std.testing.expectEqual(a.next(), b.next());
    try std.testing.expect(a.state != 0);
    var c = Rng.init(42);
    const u = c.unit();
    try std.testing.expect(u >= 0.0 and u < 1.0);
}

test "art cadence is continuous at 60 hz for every generator" {
    var art = Art.init(.popsquares, 1);
    try std.testing.expectEqual(Cadence{ .continuous = frame_period_ns }, art.cadence());
    art.select(.plasma);
    try std.testing.expectEqual(Cadence{ .continuous = frame_period_ns }, art.cadence());
}

test "selecting plasma renders exactly what a fresh plasma state renders" {
    var art = Art.init(.popsquares, 9);
    art.select(.plasma);
    art.step(0.1);
    var from_art: geometry.Rgb = undefined;
    art.render(&from_art);
    var direct = plasma.State.init(9);
    direct.step(0.1);
    var from_direct: geometry.Rgb = undefined;
    direct.render(&from_direct);
    try std.testing.expectEqualSlices(u8, &from_direct, &from_art);
}

test "reseeding art changes the popsquares output" {
    var art = Art.init(.popsquares, 1);
    var a: geometry.Rgb = undefined;
    art.render(&a);
    art.reseed(2);
    var b: geometry.Rgb = undefined;
    art.render(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

/// art's own parameter, ahead of whichever generator is showing: the generator itself
pub const art_params = [_]param.Param{
    .{ .name = "scene", .kind = .choice, .choices = param.choicesOf(Generator), .default = 0 },
};

/// the art base scene: one of the compile-time generators, selectable and reseedable.
pub const Art = struct {
    generator: Generator,
    options: popsquares.Options = .{},
    seed: u32,
    popsquares: popsquares.State,
    plasma: plasma.State,

    pub fn init(g: Generator, seed: u32) Art {
        return .{
            .generator = g,
            .seed = seed,
            .popsquares = popsquares.State.init(.{}, seed),
            .plasma = plasma.State.init(seed),
        };
    }

    pub fn reseed(self: *Art, seed: u32) void {
        self.seed = seed;
        self.popsquares = popsquares.State.init(self.options, seed);
        self.plasma = plasma.State.init(seed);
    }

    pub fn select(self: *Art, g: Generator) void {
        self.generator = g;
    }

    /// the generator after (or before) the current one in the catalogue
    pub fn neighbour(self: *const Art, forward: bool) Generator {
        const n: u8 = @intFromEnum(self.generator);
        const next: u8 = if (forward) (n + 1) % generator_count else (n + generator_count - 1) % generator_count;
        return @enumFromInt(next);
    }

    pub fn nextGenerator(self: *Art, forward: bool) void {
        self.generator = self.neighbour(forward);
    }

    /// the parameters of the showing generator, after art's own
    pub fn generatorParams(self: *const Art) []const param.Param {
        return switch (self.generator) {
            .popsquares => &popsquares.params,
            .plasma => &plasma.params,
        };
    }

    pub fn getParam(self: *const Art, index: usize) u32 {
        if (index == 0) return @intFromEnum(self.generator);
        return 0; // no generator declares one yet
    }

    pub fn setParam(self: *Art, index: usize, value: u32) void {
        if (index == 0) self.select(@enumFromInt(@min(value, art_params[0].choices.len - 1)));
    }

    pub fn step(self: *Art, dt_s: f32) void {
        self.stepGenerator(self.generator, dt_s);
    }

    /// step one generator: the one showing, or an outgoing one kept moving through a transition
    pub fn stepGenerator(self: *Art, g: Generator, dt_s: f32) void {
        switch (g) {
            .popsquares => self.popsquares.step(self.options, dt_s),
            .plasma => self.plasma.step(dt_s),
        }
    }

    pub fn render(self: *const Art, rgb: *geometry.Rgb) void {
        self.renderGenerator(self.generator, rgb);
    }

    pub fn renderGenerator(self: *const Art, g: Generator, rgb: *geometry.Rgb) void {
        switch (g) {
            .popsquares => self.popsquares.render(self.options, rgb),
            .plasma => self.plasma.render(rgb),
        }
    }

    pub fn cadence(self: *const Art) Cadence {
        _ = self;
        return .{ .continuous = frame_period_ns };
    }
};
