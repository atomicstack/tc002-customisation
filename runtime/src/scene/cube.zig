//! a solid rotating cube, shaded rather than flat: each face takes one brightness from its own
//! normal against a fixed light, so the form reads as three dimensional on sixteen rows.
//!
//! back faces are culled, which for a convex solid is the whole of the depth problem: no sorting.
//! the trigonometry comes from a comptime table, so nothing calls into libm at runtime.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const param = @import("param.zig");

pub const params = [_]param.Param{
    .{ .name = "palette", .kind = .choice, .choices = &.{ "mono", "poly" }, .default = 0 },
    .{ .name = "colour", .kind = .colour, .default = 0x30a0ff },
    .{ .name = "hue drift", .kind = .number, .min = 0, .max = 60, .step = 5, .default = 0 },
    .{ .name = "background", .kind = .colour, .default = 0x000000 },
    .{ .name = "spin", .kind = .choice, .choices = &.{ "single", "series", "parallel" }, .default = 2 },
    .{ .name = "speed", .kind = .number, .min = 1, .max = 20, .step = 1, .default = 6 },
};

const Palette = enum(u8) { mono = 0, poly = 1 };
const Spin = enum(u8) { single = 0, series = 1, parallel = 2 };

/// a full turn in angle units, so the table index is just the top bits
const turn: u32 = 1 << 16;
const table_len = 1024;

const sine: [table_len]f32 = blk: {
    @setEvalBranchQuota(40000);
    var t: [table_len]f32 = undefined;
    for (&t, 0..) |*e, i| e.* = @floatCast(@sin(@as(f64, @floatFromInt(i)) * std.math.tau / @as(f64, table_len)));
    break :blk t;
};

fn sinOf(a: u32) f32 {
    return sine[(a % turn) * table_len / turn];
}

fn cosOf(a: u32) f32 {
    return sinOf(a +% turn / 4);
}

const Vec = struct {
    x: f32,
    y: f32,
    z: f32,

    fn dot(a: Vec, b: Vec) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
};

/// the eight corners of a cube of side two, centred on the origin
const corners = [8]Vec{
    .{ .x = -1, .y = -1, .z = -1 },
    .{ .x = 1, .y = -1, .z = -1 },
    .{ .x = 1, .y = 1, .z = -1 },
    .{ .x = -1, .y = 1, .z = -1 },
    .{ .x = -1, .y = -1, .z = 1 },
    .{ .x = 1, .y = -1, .z = 1 },
    .{ .x = 1, .y = 1, .z = 1 },
    .{ .x = -1, .y = 1, .z = 1 },
};

/// each face as four corners wound the same way, with its outward normal
const Face = struct { idx: [4]u8, normal: Vec };
const faces = [6]Face{
    .{ .idx = .{ 0, 1, 2, 3 }, .normal = .{ .x = 0, .y = 0, .z = -1 } },
    .{ .idx = .{ 5, 4, 7, 6 }, .normal = .{ .x = 0, .y = 0, .z = 1 } },
    .{ .idx = .{ 4, 0, 3, 7 }, .normal = .{ .x = -1, .y = 0, .z = 0 } },
    .{ .idx = .{ 1, 5, 6, 2 }, .normal = .{ .x = 1, .y = 0, .z = 0 } },
    .{ .idx = .{ 4, 5, 1, 0 }, .normal = .{ .x = 0, .y = -1, .z = 0 } },
    .{ .idx = .{ 3, 2, 6, 7 }, .normal = .{ .x = 0, .y = 1, .z = 0 } },
};

/// up, to the left and towards the viewer, normalised
const light = Vec{ .x = -0.485, .y = 0.728, .z = -0.485 };
/// how lit the faces turned away from the light still are
const ambient: f32 = 0.28;

/// the camera sits this far back, and the projection is scaled to fill the sixteen rows
const camera: f32 = 4.2;
const focal: f32 = 17.0;

pub const State = struct {
    ax: u32 = 0,
    ay: u32 = 0,
    az: u32 = 0,
    /// which axis the `series` mode is turning, and how long it has been on it
    axis: u8 = 0,
    axis_ns: u64 = 0,
    /// the drifting hue offset, in the same units as a colour's hue
    hue: f32 = 0,
    values: param.Values = param.defaults(&params),

    pub fn init(seed: u32) State {
        // the seed only decides where it starts, so a reseed turns it to a new face
        return .{
            .ax = (seed *% 2654435761) % turn,
            .ay = (seed *% 40503) % turn,
            .az = (seed *% 2246822519) % turn,
        };
    }

    pub fn getParam(self: *const State, index: usize) u32 {
        return if (index < params.len) self.values[index] else 0;
    }

    pub fn setParam(self: *State, index: usize, value: u32) void {
        if (index < params.len) self.values[index] = params[index].clamp(value);
    }

    fn palette(self: *const State) Palette {
        return @enumFromInt(@min(self.values[0], 1));
    }

    fn spin(self: *const State) Spin {
        return @enumFromInt(@min(self.values[4], 2));
    }

    fn speed(self: *const State) f32 {
        return @floatFromInt(@max(1, self.values[5]));
    }

    /// how long `series` spends on one axis before handing over
    const axis_hold_ns: u64 = 4 * std.time.ns_per_s;

    pub fn step(self: *State, dt_s: f32) void {
        const dt = std.math.clamp(dt_s, 0.0, 0.5);
        // a turn every eight seconds at speed one, so the top of the range is brisk but readable
        const base = dt * self.speed() * @as(f32, turn) / 48.0;
        const d: u32 = @intFromFloat(@max(0.0, base));
        switch (self.spin()) {
            .single => self.ay +%= d,
            .parallel => {
                self.ax +%= d * 3 / 5;
                self.ay +%= d;
                self.az +%= d * 2 / 7;
            },
            .series => {
                switch (self.axis) {
                    0 => self.ax +%= d,
                    1 => self.ay +%= d,
                    else => self.az +%= d,
                }
                self.axis_ns += @intFromFloat(dt * std.time.ns_per_s);
                if (self.axis_ns >= axis_hold_ns) {
                    self.axis_ns = 0;
                    self.axis = (self.axis + 1) % 3;
                }
            },
        }
        const drift: f32 = @floatFromInt(self.values[2]);
        if (drift > 0) self.hue = @mod(self.hue + dt * drift * 256.0 / 360.0, 256.0);
    }

    fn rotate(self: *const State, v: Vec) Vec {
        const sx = sinOf(self.ax);
        const cx = cosOf(self.ax);
        const sy = sinOf(self.ay);
        const cy = cosOf(self.ay);
        const sz = sinOf(self.az);
        const cz = cosOf(self.az);
        // x, then y, then z
        const y1 = v.y * cx - v.z * sx;
        const z1 = v.y * sx + v.z * cx;
        const x2 = v.x * cy + z1 * sy;
        const z2 = -v.x * sy + z1 * cy;
        const x3 = x2 * cz - y1 * sz;
        const y3 = x2 * sz + y1 * cz;
        return .{ .x = x3, .y = y3, .z = z2 };
    }

    fn project(v: Vec) [2]f32 {
        const z = v.z + camera;
        const d = if (z < 0.5) 0.5 else z;
        return .{
            @as(f32, geometry.width) / 2.0 + focal * v.x / d,
            @as(f32, geometry.height) / 2.0 - focal * v.y / d,
        };
    }

    /// the colour of one face: the chosen colour in mono, a hue per face in poly, both shaded
    fn faceColour(self: *const State, face: usize, lit: f32) [3]u8 {
        const base = switch (self.palette()) {
            .mono => param.valueRgb(self.values[1]),
            .poly => blk: {
                const h = param.hueOf(self.values[1]);
                const spread: f32 = @floatFromInt(face * 256 / faces.len);
                break :blk param.hueRgb(@intFromFloat(@mod(@as(f32, @floatFromInt(h)) + spread + self.hue, 256.0)));
            },
        };
        const shade = if (self.palette() == .mono and self.values[2] > 0) blk: {
            // a mono cube still drifts, by moving the colour itself round the wheel
            const h = param.hueOf(self.values[1]);
            break :blk param.hueRgb(@intFromFloat(@mod(@as(f32, @floatFromInt(h)) + self.hue, 256.0)));
        } else base;
        var out: [3]u8 = undefined;
        for (0..3) |i| out[i] = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(shade[i])) * lit));
        return out;
    }

    pub fn render(self: *const State, rgb: *geometry.Rgb) void {
        const bg = param.valueRgb(self.values[3]);
        for (0..geometry.width * geometry.height) |i| {
            rgb[i * 3] = bg[0];
            rgb[i * 3 + 1] = bg[1];
            rgb[i * 3 + 2] = bg[2];
        }
        var turned: [8]Vec = undefined;
        for (corners, 0..) |c, i| turned[i] = self.rotate(c);
        for (faces, 0..) |f, fi| {
            const n = self.rotate(f.normal);
            // the face's own position decides whether it points at the camera
            var centre = Vec{ .x = 0, .y = 0, .z = 0 };
            for (f.idx) |i| {
                centre.x += turned[i].x / 4.0;
                centre.y += turned[i].y / 4.0;
                centre.z += (turned[i].z + camera) / 4.0;
            }
            if (n.dot(centre) >= 0) continue; // turned away: nothing to draw
            const lit = ambient + (1.0 - ambient) * @max(0.0, n.dot(light));
            var quad: [4][2]f32 = undefined;
            for (f.idx, 0..) |i, k| quad[k] = project(turned[i]);
            fillQuad(rgb, quad, self.faceColour(fi, lit));
        }
    }
};

/// scanline fill of a convex quad, which is what a cube's face projects to
fn fillQuad(rgb: *geometry.Rgb, q: [4][2]f32, colour: [3]u8) void {
    var top: f32 = q[0][1];
    var bottom: f32 = q[0][1];
    for (q[1..]) |p| {
        top = @min(top, p[1]);
        bottom = @max(bottom, p[1]);
    }
    var y: i32 = @intFromFloat(@floor(top));
    const last: i32 = @intFromFloat(@ceil(bottom));
    while (y <= last) : (y += 1) {
        if (y < 0 or y >= geometry.height) continue;
        const row: f32 = @as(f32, @floatFromInt(y)) + 0.5;
        var lo: f32 = 1e9;
        var hi: f32 = -1e9;
        for (0..4) |i| {
            const a = q[i];
            const b = q[(i + 1) % 4];
            if ((a[1] <= row and b[1] > row) or (b[1] <= row and a[1] > row)) {
                const t = (row - a[1]) / (b[1] - a[1]);
                const x = a[0] + t * (b[0] - a[0]);
                lo = @min(lo, x);
                hi = @max(hi, x);
            }
        }
        if (hi < lo) continue;
        var x: i32 = @intFromFloat(@floor(lo + 0.5));
        const end: i32 = @intFromFloat(@floor(hi - 0.5));
        while (x <= end) : (x += 1) {
            if (x < 0 or x >= geometry.width) continue;
            const o = geometry.pixelOffset(@intCast(x), @intCast(y));
            rgb[o] = colour[0];
            rgb[o + 1] = colour[1];
            rgb[o + 2] = colour[2];
        }
    }
}

// tests

fn litPixels(rgb: *const geometry.Rgb) usize {
    var n: usize = 0;
    for (0..geometry.width * geometry.height) |i| {
        if (rgb[i * 3] != 0 or rgb[i * 3 + 1] != 0 or rgb[i * 3 + 2] != 0) n += 1;
    }
    return n;
}

fn shades(rgb: *const geometry.Rgb) usize {
    var seen: [64][3]u8 = undefined;
    var n: usize = 0;
    outer: for (0..geometry.width * geometry.height) |i| {
        const c = [3]u8{ rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] };
        if (c[0] == 0 and c[1] == 0 and c[2] == 0) continue;
        for (seen[0..n]) |s| if (std.mem.eql(u8, &s, &c)) continue :outer;
        if (n < seen.len) {
            seen[n] = c;
            n += 1;
        }
    }
    return n;
}

test "the cube is solid, on the panel, and turns" {
    var s = State.init(3);
    var a: geometry.Rgb = undefined;
    s.render(&a);
    const lit = litPixels(&a);
    // a cube of this size fills a good part of the sixteen rows without covering the panel
    try std.testing.expect(lit > 60 and lit < geometry.width * geometry.height);
    s.step(0.5);
    var b: geometry.Rgb = undefined;
    s.render(&b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "faces are shaded, so the form reads rather than showing as a silhouette" {
    var s = State.init(1);
    s.setParam(0, 0); // mono: every face is the same colour, separated only by its shading
    s.setParam(1, 0x30a0ff);
    var rgb: geometry.Rgb = undefined;
    // a few steps in, so the cube is off-axis and more than one face shows
    s.step(0.4);
    s.render(&rgb);
    try std.testing.expect(shades(&rgb) >= 2);
}

test "back faces are culled, so at most three of the six ever draw" {
    var s = State.init(7);
    var rgb: geometry.Rgb = undefined;
    var step: u32 = 0;
    while (step < 30) : (step += 1) {
        s.setParam(0, 1); // poly, so each visible face has its own hue
        s.render(&rgb);
        try std.testing.expect(shades(&rgb) <= 3);
        s.step(0.13);
    }
}

test "the background is painted and the palette changes what is drawn" {
    var s = State.init(2);
    s.setParam(3, 0x100010); // a background that is not black
    var rgb: geometry.Rgb = undefined;
    s.render(&rgb);
    const corner = geometry.pixelOffset(0, 0);
    try std.testing.expectEqual([3]u8{ 0x10, 0, 0x10 }, [3]u8{ rgb[corner], rgb[corner + 1], rgb[corner + 2] });

    s.setParam(3, 0);
    s.setParam(0, 0);
    var mono: geometry.Rgb = undefined;
    s.render(&mono);
    s.setParam(0, 1);
    var poly: geometry.Rgb = undefined;
    s.render(&poly);
    try std.testing.expect(!std.mem.eql(u8, &mono, &poly));
}

test "the spin modes turn different numbers of axes" {
    var single = State.init(0);
    single.setParam(4, 0);
    var parallel = State.init(0);
    parallel.setParam(4, 2);
    single.step(0.2);
    parallel.step(0.2);
    try std.testing.expectEqual(@as(u32, 0), single.ax); // single turns one axis only
    try std.testing.expect(single.ay > 0);
    try std.testing.expect(parallel.ax > 0 and parallel.ay > 0 and parallel.az > 0);

    // series moves one axis at a time and hands over
    var series = State.init(0);
    series.setParam(4, 1);
    series.step(0.2);
    try std.testing.expect(series.ax > 0 and series.ay == 0);
    series.step(0.5);
    var held: u32 = 0;
    while (held < 10) : (held += 1) series.step(0.5);
    try std.testing.expect(series.ay > 0); // it has moved on
}

test "the seed decides where it starts" {
    var a = State.init(11);
    var b = State.init(12);
    var ra: geometry.Rgb = undefined;
    var rb: geometry.Rgb = undefined;
    a.render(&ra);
    b.render(&rb);
    try std.testing.expect(!std.mem.eql(u8, &ra, &rb));
    var again = State.init(11);
    var rc: geometry.Rgb = undefined;
    again.render(&rc);
    try std.testing.expectEqualSlices(u8, &ra, &rc);
}
