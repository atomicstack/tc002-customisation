//! rolling rainbow terrain, adapted from the pixoo reference for a wide, shallow panel.
//! a seeded height field scrolls towards the camera. near columns hide farther ones; the
//! remaining sky stays black. no mesh, heap allocation, gif decoder or runtime trigonometry.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const param = @import("param.zig");

pub const params = [_]param.Param{
    .{ .name = "speed", .kind = .number, .min = 1, .max = 20, .step = 1, .default = 6 },
    .{ .name = "height", .kind = .number, .min = 40, .max = 180, .step = 10, .default = 100 },
    .{ .name = "colour drift", .kind = .number, .min = 0, .max = 60, .step = 5, .default = 15 },
};

const Sample = struct { value: f32, dx: f32, dz: f32 };

fn mix(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// periodic lattice hashing makes wrapping the travel coordinate seamless, including octave two.
fn lattice(seed: u32, x: i32, z: i32) f32 {
    const xi: u32 = @intCast(@mod(x, 256));
    const zi: u32 = @intCast(@mod(z, 256));
    var h = seed ^ (xi *% 0x9e3779b9) ^ (zi *% 0x85ebca6b);
    h = (h ^ (h >> 16)) *% 0x7feb352d;
    h = (h ^ (h >> 15)) *% 0x846ca68b;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h >> 8)) * (2.0 / 16777216.0) - 1.0;
}

/// cubic interpolation and its slope, used for both the hills and their directional lighting.
fn noise(seed: u32, x: f32, z: f32) Sample {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    const fx = x - @floor(x);
    const fz = z - @floor(z);
    const sx = fx * fx * (3 - 2 * fx);
    const sz = fz * fz * (3 - 2 * fz);
    const a = lattice(seed, ix, iz);
    const b = lattice(seed, ix + 1, iz);
    const c = lattice(seed, ix, iz + 1);
    const d = lattice(seed, ix + 1, iz + 1);
    return .{
        .value = mix(mix(a, b, sx), mix(c, d, sx), sz),
        .dx = mix(b - a, d - c, sz) * 6 * fx * (1 - fx),
        .dz = (mix(c, d, sx) - mix(a, b, sx)) * 6 * fz * (1 - fz),
    };
}

pub const State = struct {
    seed: u32,
    travel: f32 = 0,
    hue: f32 = 0,
    values: param.Values = param.defaults(&params),

    pub fn init(seed: u32) State {
        return .{ .seed = seed };
    }

    pub fn getParam(self: *const State, i: usize) u32 {
        return if (i < params.len) self.values[i] else 0;
    }

    pub fn setParam(self: *State, i: usize, v: u32) void {
        if (i < params.len) self.values[i] = params[i].clamp(v);
    }

    pub fn step(self: *State, dt_s: f32) void {
        const dt = std.math.clamp(dt_s, 0, 0.5);
        // bounded phases retain subpixel movement after days of continuous operation.
        self.travel = @mod(self.travel + dt * @as(f32, @floatFromInt(self.values[0])) * 0.06, 256);
        self.hue = @mod(self.hue + dt * @as(f32, @floatFromInt(self.values[2])) * (256.0 / 360.0), 256);
    }

    fn field(self: *const State, x: f32, z: f32) Sample {
        const a = noise(self.seed, x, z);
        const b = noise(self.seed ^ 0xa511e9b3, x * 2, z * 2);
        const height = @as(f32, @floatFromInt(self.values[1])) / 100;
        return .{
            .value = (a.value * 2.7 + b.value) * height,
            .dx = (a.dx * 2.7 + b.dx * 2) * height,
            .dz = (a.dz * 2.7 + b.dz * 2) * height,
        };
    }

    pub fn render(self: *const State, rgb: *geometry.Rgb) void {
        rgb.* = geometry.black_rgb;
        for (0..geometry.width) |x| {
            const ray = (@as(f32, @floatFromInt(x)) - 25.5) / 22;
            var ceiling: usize = geometry.height;
            var z: f32 = 1;
            while (z < 16 and ceiling > 2) : (z += 0.08 + z * 0.025) {
                const h = self.field(ray * z * 0.26, z * 0.26 + self.travel);
                // preserve two rows of sky even with the tallest hills selected.
                const projected = 3 + (5.3 - h.value) * 8 / z;
                const top: usize = @intFromFloat(std.math.clamp(@floor(projected), 2, geometry.height));
                if (top >= ceiling) continue;
                const hue: u8 = @intFromFloat(@mod(155 - h.value * 48 + self.hue, 256));
                const colour = param.hueRgb(hue);
                const light = std.math.clamp(0.90 + h.dx * 0.040 - h.dz * 0.030, 0.60, 1.0);
                const fog = 1 - 0.45 * (z / 16) * (z / 16);
                for (top..ceiling) |y| {
                    const offset = geometry.pixelOffset(x, y);
                    for (colour, 0..) |channel, i| rgb[offset + i] = @intFromFloat(@as(f32, @floatFromInt(channel)) * light * fog);
                }
                ceiling = top;
            }
        }
    }
};
