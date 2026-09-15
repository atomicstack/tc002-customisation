//! the compile-time scene interface shared by generators and the arbiter.
//!
//! scenes are pure: they take a seed and elapsed time, render into an rgb buffer, and handle
//! normalized actions. they can never open hardware or network resources.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const popsquares = @import("popsquares.zig");
const plasma = @import("plasma.zig");
const cube = @import("cube.zig");
const terrain = @import("terrain.zig");

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
/// what a control did, in the arbiter's own terms. the three base buttons have a tap and a hold:
/// the tap selects a base and the hold opens that base's settings, which is why the dial's click is
/// free for the showing scene to use.
pub const Action = enum { left, middle, right, left_long, middle_long, right_long, knob_short, knob_long, rotate_cw, rotate_ccw };

pub const Generator = enum(u8) { popsquares = 0, plasma = 1, cube = 2, terrain = 3 };
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

// art's table is its own parameter followed by the showing generator's, concatenated at compile
// time so no slice has to be built at runtime
const params_popsquares = art_params ++ popsquares.params;
const params_plasma = art_params ++ plasma.params;
const params_cube = art_params ++ cube.params;
const params_terrain = art_params ++ terrain.params;

/// each generator's declared defaults, laid out the way the settings store them. a generator's
/// parameters are not all zero by default (the cube starts blue, at 100% zoom), so a settings file
/// that has never had them written must fall back to these rather than to zeros.
pub const generator_defaults: [param.owner_count]param.Values = blk: {
    var out: [param.owner_count]param.Values = undefined;
    for (0..param.owner_count) |i| {
        const own = paramsFor(@enumFromInt(@as(u8, @intCast(i))))[art_params.len..];
        out[i] = param.defaults(own);
    }
    break :blk out;
};

/// a generator whose slots are all zero has never been written: no generator's defaults are all
/// zero, and the minimums (speed 1, zoom 40) make an all-zero set impossible to reach by editing.
pub fn slotsUnset(slots: param.Values) bool {
    for (slots) |v| if (v != 0) return false;
    return true;
}

/// what art can be told while this generator is showing
pub fn paramsFor(g: Generator) []const param.Param {
    return switch (g) {
        .popsquares => &params_popsquares,
        .plasma => &params_plasma,
        .cube => &params_cube,
        .terrain => &params_terrain,
    };
}

/// the art base scene: one of the compile-time generators, selectable and reseedable.
pub const Art = struct {
    generator: Generator,
    seed: u32,
    popsquares: popsquares.State,
    plasma: plasma.State,
    cube: cube.State,
    terrain: terrain.State,

    pub fn init(g: Generator, seed: u32) Art {
        return .{
            .generator = g,
            .seed = seed,
            .popsquares = popsquares.State.init(seed),
            .plasma = plasma.State.init(seed),
            .cube = cube.State.init(seed),
            .terrain = terrain.State.init(seed),
        };
    }

    /// a reseed lays out a new panel but keeps how each generator has been set up
    pub fn reseed(self: *Art, seed: u32) void {
        self.seed = seed;
        self.popsquares = popsquares.State.initWith(self.popsquares.values, seed);
        self.plasma = plasma.State.init(seed);
        const kept = self.cube.values;
        self.cube = cube.State.init(seed);
        self.cube.values = kept;
        const terrain_kept = self.terrain.values;
        self.terrain = terrain.State.init(seed);
        self.terrain.values = terrain_kept;
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

    pub fn params(self: *const Art) []const param.Param {
        return paramsFor(self.generator);
    }

    pub fn getParam(self: *const Art, index: usize) u32 {
        if (index == 0) return @intFromEnum(self.generator);
        const i = index - art_params.len;
        return switch (self.generator) {
            .popsquares => self.popsquares.getParam(i),
            .plasma => self.plasma.getParam(i),
            .cube => self.cube.getParam(i),
            .terrain => self.terrain.getParam(i),
        };
    }

    pub fn setParam(self: *Art, index: usize, value: u32) void {
        if (index == 0) {
            self.select(@enumFromInt(@min(value, art_params[0].choices.len - 1)));
            return;
        }
        const i = index - art_params.len;
        switch (self.generator) {
            .popsquares => self.popsquares.setParam(i, value),
            .plasma => self.plasma.setParam(i, value),
            .cube => self.cube.setParam(i, value),
            .terrain => self.terrain.setParam(i, value),
        }
    }

    pub fn step(self: *Art, dt_s: f32) void {
        self.stepGenerator(self.generator, dt_s);
    }

    /// step one generator: the one showing, or an outgoing one kept moving through a transition
    pub fn stepGenerator(self: *Art, g: Generator, dt_s: f32) void {
        switch (g) {
            .popsquares => self.popsquares.step(dt_s),
            .plasma => self.plasma.step(dt_s),
            .cube => self.cube.step(dt_s),
            .terrain => self.terrain.step(dt_s),
        }
    }

    pub fn render(self: *const Art, rgb: *geometry.Rgb) void {
        self.renderGenerator(self.generator, rgb);
    }

    pub fn renderGenerator(self: *const Art, g: Generator, rgb: *geometry.Rgb) void {
        switch (g) {
            .popsquares => self.popsquares.render(rgb),
            .plasma => self.plasma.render(rgb),
            .cube => self.cube.render(rgb),
            .terrain => self.terrain.render(rgb),
        }
    }

    pub fn cadence(self: *const Art) Cadence {
        _ = self;
        return .{ .continuous = frame_period_ns };
    }
};

// --- shared motion ------------------------------------------------------------------------------

/// a full turn of sine, scaled to thousandths and built at compile time: `@sin` lowers to a libm
/// call this binary cannot link, and the cube learned the same lesson. it lives here rather than in
/// `canvas.zig` because the clock's unsynced pulse wants the same curve, and two tables would be
/// two curves the moment one of them was tuned.
const sine = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]i16 = undefined;
    for (&table, 0..) |*v, i| {
        const a = @as(f64, @floatFromInt(i)) * std.math.tau / 256.0;
        v.* = @intFromFloat(@round(@sin(a) * 1000.0));
    }
    break :blk table;
};

/// sin(turns) in thousandths, turns being 0..255 around the circle
pub fn sin1000(turn: u8) i32 {
    return sine[turn];
}

test "the sine table turns once and comes back" {
    try std.testing.expectEqual(@as(i32, 0), sin1000(0));
    try std.testing.expectEqual(@as(i32, 1000), sin1000(64));
    try std.testing.expectEqual(@as(i32, 0), sin1000(128));
    try std.testing.expectEqual(@as(i32, -1000), sin1000(192));
}

test "terrain is seeded, animated, and fills the panel beneath a black sky" {
    const g = std.meta.stringToEnum(Generator, "terrain") orelse return error.MissingTerrain;
    var a = Art.init(g, 7);
    var b = Art.init(g, 7);
    var c = Art.init(g, 19);
    var ra: geometry.Rgb = undefined;
    var rb: geometry.Rgb = undefined;
    var rc: geometry.Rgb = undefined;
    a.render(&ra);
    b.render(&rb);
    c.render(&rc);
    try std.testing.expectEqualSlices(u8, &ra, &rb);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rc));
    try std.testing.expectEqualSlices(u8, geometry.black_rgb[0 .. geometry.width * 3], ra[0 .. geometry.width * 3]);
    for (0..geometry.width) |x| {
        const offset = geometry.pixelOffset(x, geometry.height - 1);
        try std.testing.expect(ra[offset] != 0 or ra[offset + 1] != 0 or ra[offset + 2] != 0);
    }
    a.step(0.25);
    a.render(&rb);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
    try std.testing.expectEqual(Cadence{ .continuous = frame_period_ns }, a.cadence());
    a.select(.popsquares);
    try std.testing.expectEqual(g, a.neighbour(false));
    a.select(g);
    try std.testing.expectEqual(Generator.popsquares, a.neighbour(true));
}

test "terrain controls change the frame and survive reseeding" {
    const g = std.meta.stringToEnum(Generator, "terrain") orelse return error.MissingTerrain;
    var a = Art.init(g, 42);
    var before: geometry.Rgb = undefined;
    var after: geometry.Rgb = undefined;
    a.render(&before);
    a.setParam(2, 160); // taller hills
    a.render(&after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
    a.setParam(1, 12);
    a.setParam(3, 35);
    a.reseed(99);
    try std.testing.expectEqual(@as(u32, 12), a.getParam(1));
    try std.testing.expectEqual(@as(u32, 160), a.getParam(2));
    try std.testing.expectEqual(@as(u32, 35), a.getParam(3));
    a.setParam(1, 0);
    try std.testing.expectEqual(@as(u32, 1), a.getParam(1));
    a.setParam(2, 10000);
    try std.testing.expectEqual(@as(u32, 180), a.getParam(2));
}

test "terrain ignores negative time and accumulates small time steps" {
    const g = std.meta.stringToEnum(Generator, "terrain") orelse return error.MissingTerrain;
    var a = Art.init(g, 7);
    var before: geometry.Rgb = undefined;
    var after: geometry.Rgb = undefined;
    a.render(&before);
    a.step(-1);
    a.render(&after);
    try std.testing.expectEqualSlices(u8, &before, &after);
    for (0..250) |_| a.step(0.001);
    a.render(&after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}
