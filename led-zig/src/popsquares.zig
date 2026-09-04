const std = @import("std");
const frame = @import("frame.zig");

pub const level_max: f32 = 127.0;
pub const dt_max: f32 = 0.5;
pub const spent: f32 = 1e-4;

pub const Options = struct {
    pop_seconds: f32 = 2.0,
    alive: f32 = 1.0,
    dim: f32 = 0.25,
    dim_min: i32 = 0,
    dim_max: i32 = 127,
    tint_fraction: f32 = 0.15,
    tint: [3]u8 = .{ 58, 110, 165 },
};

pub const State = struct {
    levels: [frame.pixel_count]f32,
    ranks: [frame.pixel_count]f32,
    tinted: [frame.pixel_count]u8,
    rng: u32,

    pub fn init(options: Options, seed: u32) State {
        var state: State = undefined;
        state.rng = if (seed == 0) 0x9e3779b9 else seed;

        for (0..frame.pixel_count) |index| {
            state.levels[index] = uniform(&state.rng, 0.0, level_max);
            state.ranks[index] = unit(&state.rng);
            state.tinted[index] = @intFromBool(unit(&state.rng) < options.tint_fraction);
        }

        return state;
    }

    pub fn step(state: *State, options: Options, elapsed: f32) void {
        const clamped_elapsed = std.math.clamp(elapsed, 0.0, dt_max);
        const pop_seconds = if (options.pop_seconds > 0.0) options.pop_seconds else 1.0;
        const drop = level_max * clamped_elapsed / pop_seconds;

        for (0..frame.pixel_count) |index| {
            if (state.ranks[index] >= options.alive) {
                state.levels[index] = 0.0;
                continue;
            }

            state.levels[index] -= drop;
            if (state.levels[index] <= spent) state.rearm(index, options);
        }
    }

    pub fn render(state: *const State, options: Options, rgb: *frame.Rgb) void {
        const white = [3]u8{ 255, 255, 255 };

        for (0..frame.pixel_count) |index| {
            const fraction = std.math.clamp(state.levels[index] / level_max, 0.0, 1.0);
            const color = if (state.tinted[index] != 0) options.tint else white;
            const offset = index * 3;
            rgb[offset] = @intFromFloat(@as(f32, @floatFromInt(color[0])) * fraction);
            rgb[offset + 1] = @intFromFloat(@as(f32, @floatFromInt(color[1])) * fraction);
            rgb[offset + 2] = @intFromFloat(@as(f32, @floatFromInt(color[2])) * fraction);
        }
    }

    fn rearm(state: *State, index: usize, options: Options) void {
        const dim_low = @min(options.dim_min, options.dim_max);
        const dim_high = @max(options.dim_min, options.dim_max);
        state.levels[index] = if (unit(&state.rng) < options.dim)
            uniform(&state.rng, @floatFromInt(dim_low), @floatFromInt(dim_high))
        else
            level_max;
        state.tinted[index] = @intFromBool(unit(&state.rng) < options.tint_fraction);
    }
};

fn xorshift32(random: *u32) u32 {
    var value = random.*;
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    random.* = value;
    return value;
}

fn unit(random: *u32) f32 {
    const top_24_bits = xorshift32(random) >> 8;
    return @as(f32, @floatFromInt(top_24_bits)) * (1.0 / 16_777_216.0);
}

fn uniform(random: *u32, low: f32, high: f32) f32 {
    return low + (high - low) * unit(random);
}

fn fillLevels(state: *State, value: f32) void {
    @memset(&state.levels, value);
}

test "options defaults match the c simulation" {
    const options = Options{};
    try std.testing.expectEqual(@as(f32, 2.0), options.pop_seconds);
    try std.testing.expectEqual(@as(f32, 1.0), options.alive);
    try std.testing.expectEqual(@as(f32, 0.25), options.dim);
    try std.testing.expectEqual(@as(i32, 0), options.dim_min);
    try std.testing.expectEqual(@as(i32, 127), options.dim_max);
    try std.testing.expectEqual(@as(f32, 0.15), options.tint_fraction);
    try std.testing.expectEqual([3]u8{ 58, 110, 165 }, options.tint);
}

test "init is deterministic and keeps values in range" {
    const options = Options{};
    const first = State.init(options, 7);
    const second = State.init(options, 7);
    const other = State.init(options, 8);

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&first), std.mem.asBytes(&second));
    try std.testing.expect(!std.meta.eql(first, other));
    for (first.levels) |level| try std.testing.expect(level >= 0.0 and level <= level_max);
    for (first.ranks) |rank| try std.testing.expect(rank >= 0.0 and rank < 1.0);
    var tinted_count: usize = 0;
    for (first.tinted) |tinted| {
        try std.testing.expect(tinted <= 1);
        tinted_count += tinted;
    }
    try std.testing.expect(tinted_count > 60 and tinted_count < 200);
}

test "zero seed is remapped and produces varying initial levels" {
    const options = Options{};
    const state = State.init(options, 0);
    const remapped = State.init(options, 0x9e3779b9);

    try std.testing.expectEqualDeep(state, remapped);
    var different = false;
    for (state.levels[1..]) |level| different = different or level != state.levels[0];
    try std.testing.expect(different);
}

test "rng draw order matches c golden vectors" {
    var state = State.init(.{}, 7);

    try std.testing.expectEqual(@as(u32, 0x3d653200), @as(u32, @bitCast(state.levels[0])));
    try std.testing.expectEqual(@as(u32, 0x3de04c90), @as(u32, @bitCast(state.ranks[0])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[0]);
    try std.testing.expectEqual(@as(u32, 0x42b58e59), @as(u32, @bitCast(state.levels[1])));
    try std.testing.expectEqual(@as(u32, 0x3f2a296f), @as(u32, @bitCast(state.ranks[1])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[1]);
    try std.testing.expectEqual(@as(u32, 0x40f4e40d), @as(u32, @bitCast(state.levels[2])));
    try std.testing.expectEqual(@as(u32, 0x3e3d6eec), @as(u32, @bitCast(state.ranks[2])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[2]);
    try std.testing.expectEqual(@as(u32, 0xcac154a6), state.rng);

    fillLevels(&state, 0.0);
    state.step(.{ .dim = 1.0, .dim_min = 10, .dim_max = 20 }, 0.0);

    try std.testing.expectEqual(@as(u32, 0x41505887), @as(u32, @bitCast(state.levels[0])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[0]);
    try std.testing.expectEqual(@as(u32, 0x418a41b3), @as(u32, @bitCast(state.levels[1])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[1]);
    try std.testing.expectEqual(@as(u32, 0x41893e85), @as(u32, @bitCast(state.levels[2])));
    try std.testing.expectEqual(@as(u8, 0), state.tinted[2]);
    try std.testing.expectEqual(@as(u32, 0xc9463e33), state.rng);
}

test "step decays levels per elapsed time and caps elapsed" {
    var state = State.init(.{}, 1);
    fillLevels(&state, 100.0);
    state.step(.{}, 2.0 * 10.0 / level_max);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), state.levels[0], 1e-4);

    fillLevels(&state, 100.0);
    state.step(.{ .pop_seconds = 4.0 }, 2.0 * 10.0 / level_max);
    try std.testing.expectApproxEqAbs(@as(f32, 95.0), state.levels[frame.pixel_count - 1], 1e-4);

    fillLevels(&state, 100.0);
    state.step(.{}, 100.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 - level_max * dt_max / 2.0), state.levels[0], 1e-4);
}

test "step clamps negative elapsed and uses a one second fallback pop duration" {
    var state = State.init(.{}, 2);
    fillLevels(&state, 100.0);
    state.step(.{}, -1.0);
    try std.testing.expectEqual(@as(f32, 100.0), state.levels[0]);

    state.step(.{ .pop_seconds = -1.0 }, 1.0 / level_max);
    try std.testing.expectApproxEqAbs(@as(f32, 99.0), state.levels[0], 1e-4);
}

test "spent threshold rearms cells to full or the requested dim range" {
    var full = State.init(.{}, 3);
    fillLevels(&full, spent / 2.0);
    full.step(.{ .dim = 0.0 }, 0.0);
    for (full.levels) |level| try std.testing.expectEqual(level_max, level);

    var dim = State.init(.{}, 3);
    fillLevels(&dim, spent / 2.0);
    dim.step(.{ .dim = 1.0, .dim_min = 20, .dim_max = 10 }, 0.0);
    for (dim.levels) |level| try std.testing.expect(level >= 10.0 and level <= 20.0);
}

test "rearming redraws tint flags at both extreme fractions" {
    var state = State.init(.{}, 5);
    fillLevels(&state, 0.0);
    state.step(.{ .dim = 0.0, .tint_fraction = 1.0 }, 0.0);
    for (state.tinted) |tinted| try std.testing.expectEqual(@as(u8, 1), tinted);

    fillLevels(&state, 0.0);
    state.step(.{ .dim = 0.0, .tint_fraction = 0.0 }, 0.0);
    for (state.tinted) |tinted| try std.testing.expectEqual(@as(u8, 0), tinted);
}

test "alive gates cells according to their stable ranks" {
    var state = State.init(.{}, 9);
    const ranks = state.ranks;
    fillLevels(&state, 100.0);
    state.step(.{ .alive = 0.5 }, 0.001);

    for (state.levels, ranks) |level, rank| {
        try std.testing.expectEqual(rank >= 0.5, level == 0.0);
    }
}

test "render writes row major tinted and white pixels with clamped levels" {
    var state = State.init(.{}, 11);
    fillLevels(&state, 0.0);
    state.levels[0] = level_max;
    state.tinted[0] = 1;
    state.levels[1] = level_max / 2.0;
    state.tinted[1] = 0;
    state.levels[2] = level_max * 2.0;
    state.tinted[2] = 0;
    state.levels[3] = -3.0;
    state.tinted[3] = 1;
    state.levels[4] = level_max / 2.0;
    state.tinted[4] = 1;
    state.levels[frame.width + 2] = level_max;
    state.tinted[frame.width + 2] = 0;

    var rgb: frame.Rgb = undefined;
    state.render(.{}, &rgb);

    try std.testing.expectEqualSlices(u8, &.{ 58, 110, 165 }, rgb[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 127, 127, 127 }, rgb[3..6]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, rgb[6..9]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, rgb[9..12]);
    try std.testing.expectEqualSlices(u8, &.{ 29, 55, 82 }, rgb[12..15]);
    const offset = (frame.width + 2) * 3;
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255 }, rgb[offset .. offset + 3]);
}
