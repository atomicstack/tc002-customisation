//! scene transitions, pure: how the frame that was on the panel gives way to the scene's new
//! output. a `Spec` names an effect, a direction and a duration; `Transition` runs one over
//! monotonic time; `composite` is the per-effect blend at a given progress. integer maths on the
//! rgb bytes, no allocation. the renderer keeps a frame cadence while `apply` reports one running.
//!
//! direction is the way the moving content travels: slide left moves everything left with the new
//! content entering from the right; swipe in left pulls the new content in from the right edge over
//! the old; swipe out left pushes the old content off the left edge, revealing the new underneath.
const std = @import("std");
const geometry = @import("geometry.zig");

const ns_per_ms: u64 = 1_000_000;
const W: i32 = geometry.width;
const H: i32 = geometry.height;
const cx: i32 = W / 2;
const cy: i32 = H / 2;

pub const Effect = enum(u8) {
    fade = 0,
    cut,
    slide,
    swipe_out,
    swipe_in,
    collapse,
    expand,
    wipe,
    dissolve,
    split_out,
    split_in,
    blinds,
    flip,
    rain,
    rain_random,

    /// the effect that takes away what this one brought in
    pub fn paired(self: Effect) Effect {
        return switch (self) {
            .swipe_in => .swipe_out,
            .swipe_out => .swipe_in,
            .split_in => .split_out,
            .split_out => .split_in,
            .expand => .collapse,
            .collapse => .expand,
            else => self,
        };
    }

    /// the direction used when a request names none
    pub fn naturalDirection(self: Effect) Direction {
        return switch (self) {
            .rain, .rain_random => .down,
            else => .left,
        };
    }
};

pub const Direction = enum(u8) {
    left = 0,
    right,
    up,
    down,

    pub fn opposite(self: Direction) Direction {
        return switch (self) {
            .left => .right,
            .right => .left,
            .up => .down,
            .down => .up,
        };
    }

    fn horizontal(self: Direction) bool {
        return self == .left or self == .right;
    }
};

/// how an overlay (a notification, a pushed frame) leaves: the paired effect backing out the way
/// it came, the paired effect continuing the same way, or no animation at all.
pub const Exit = enum(u8) {
    reverse = 0,
    same,
    none,
};

pub const default_duration_ns: u64 = 500 * ns_per_ms;
pub const max_duration_ms: u32 = 5000;

pub const Spec = struct {
    effect: Effect = .fade,
    direction: Direction = .left,
    duration_ns: u64 = default_duration_ns,
    exit: Exit = .reverse,

    pub const cut: Spec = .{ .effect = .cut, .duration_ns = 0 };

    /// the transition that takes an overlay away, according to `exit`
    pub fn outgoing(self: Spec) Spec {
        return switch (self.exit) {
            .reverse => .{ .effect = self.effect.paired(), .direction = self.direction.opposite(), .duration_ns = self.duration_ns, .exit = self.exit },
            .same => .{ .effect = self.effect.paired(), .direction = self.direction, .duration_ns = self.duration_ns, .exit = self.exit },
            .none => cut,
        };
    }

    pub fn instant(self: Spec) bool {
        return self.effect == .cut or self.duration_ns == 0;
    }
};

pub const Transition = struct {
    spec: Spec = .{},
    from: geometry.Rgb = geometry.black_rgb,
    start: ?u64 = null,

    /// the scene changed: remember what is on the panel now and run `spec` towards the new output.
    /// an instant spec (cut, zero duration) shows the new output at once and cancels any run.
    pub fn begin(self: *Transition, current: *const geometry.Rgb, spec: Spec, now_ns: u64) void {
        if (spec.instant()) {
            self.start = null;
            return;
        }
        self.spec = spec;
        self.from = current.*;
        self.start = now_ns;
    }

    pub fn active(self: *const Transition) bool {
        return self.start != null;
    }

    /// composite the remembered frame and `in` into `out` for `now`; true while still running. the
    /// frame produced on the iteration that completes a run is exactly `in`.
    pub fn apply(self: *Transition, in: *const geometry.Rgb, out: *geometry.Rgb, now_ns: u64) bool {
        return self.applyFrom(&self.from, in, out, now_ns);
    }

    /// the same with a live old layer instead of the remembered frame
    pub fn applyFrom(self: *Transition, old: *const geometry.Rgb, in: *const geometry.Rgb, out: *geometry.Rgb, now_ns: u64) bool {
        const s = self.start orelse {
            out.* = in.*;
            return false;
        };
        const elapsed = now_ns -| s;
        if (elapsed >= self.spec.duration_ns) {
            self.start = null;
            out.* = in.*;
            return false;
        }
        composite(self.spec.effect, self.spec.direction, old, in, out, @intCast(elapsed * 256 / self.spec.duration_ns));
        return true;
    }
};

/// where one output pixel comes from
const Src = union(enum) { old: [2]i32, new: [2]i32, black };

/// blend `old` and `new` into `out` at progress `p`: 0 is all old, 256 would be all new.
pub fn composite(effect: Effect, dir: Direction, old: *const geometry.Rgb, new: *const geometry.Rgb, out: *geometry.Rgb, p: u32) void {
    switch (effect) {
        .cut => {
            out.* = new.*;
            return;
        },
        .fade => {
            for (old, new, out) |o, n, *d| d.* = @intCast((@as(u32, o) * (256 - p) + @as(u32, n) * p) >> 8);
            return;
        },
        else => {},
    }
    var y: i32 = 0;
    while (y < H) : (y += 1) {
        var x: i32 = 0;
        while (x < W) : (x += 1) {
            const o = geometry.pixelOffset(@intCast(x), @intCast(y));
            switch (sample(effect, dir, x, y, p)) {
                .old => |s| out[o..][0..3].* = old[geometry.pixelOffset(@intCast(s[0]), @intCast(s[1]))..][0..3].*,
                .new => |s| out[o..][0..3].* = new[geometry.pixelOffset(@intCast(s[0]), @intCast(s[1]))..][0..3].*,
                .black => @memset(out[o..][0..3], 0),
            }
        }
    }
}

fn axisLen(dir: Direction) i32 {
    return if (dir.horizontal()) W else H;
}

/// the displacement of content that has travelled `off` pixels in `dir`
fn delta(dir: Direction, off: i32) [2]i32 {
    return switch (dir) {
        .left => .{ -off, 0 },
        .right => .{ off, 0 },
        .up => .{ 0, -off },
        .down => .{ 0, off },
    };
}

fn inBounds(x: i32, y: i32) bool {
    return x >= 0 and x < W and y >= 0 and y < H;
}

/// a source position one panel beyond an edge, folded back onto the panel
fn wrap(x: i32, y: i32) [2]i32 {
    return .{ if (x < 0) x + W else if (x >= W) x - W else x, if (y < 0) y + H else if (y >= H) y - H else y };
}

fn scaled(p: u32, len: i32) i32 {
    return @intCast(p * @as(u32, @intCast(len)) / 256);
}

fn hash(x: u32, y: u32) u8 {
    var h: u32 = (x *% 0x9E3779B1) ^ (y *% 0x85EBCA77);
    h ^= h >> 16;
    h *%= 0x7FEB352D;
    h ^= h >> 15;
    h *%= 0x846CA68B;
    h ^= h >> 16;
    return @truncate(h >> 8);
}

fn sample(effect: Effect, dir: Direction, x: i32, y: i32, p: u32) Src {
    switch (effect) {
        .slide, .swipe_out, .swipe_in, .wipe => {
            const d = delta(dir, scaled(p, axisLen(dir)));
            const sx = x - d[0];
            const sy = y - d[1];
            const covered = inBounds(sx, sy); // the travelling old content still covers this pixel
            return switch (effect) {
                .slide => if (covered) .{ .old = .{ sx, sy } } else .{ .new = wrap(sx, sy) },
                .swipe_out => if (covered) .{ .old = .{ sx, sy } } else .{ .new = .{ x, y } },
                .swipe_in => if (covered) .{ .old = .{ x, y } } else .{ .new = wrap(sx, sy) },
                else => if (covered) .{ .old = .{ x, y } } else .{ .new = .{ x, y } },
            };
        },
        .collapse, .expand => {
            // a rectangle shrinking to (collapse) or growing from (expand) the centre, both axes
            // meeting there together; the old content sits inside it for collapse, the new for expand
            const q: u32 = if (effect == .collapse) 256 - p else p;
            const hw = scaled(q, cx);
            const hh = scaled(q, cy);
            const inside = x >= cx - hw and x < cx + hw and y >= cy - hh and y < cy + hh;
            return if (inside == (effect == .collapse)) .{ .old = .{ x, y } } else .{ .new = .{ x, y } };
        },
        .split_out, .split_in => {
            const horizontal = dir.horizontal();
            const c = if (horizontal) cx else cy;
            const a = if (horizontal) x else y; // the coordinate along the split axis
            const off = scaled(p, c);
            if (effect == .split_out) {
                // both halves of the old content slide away from the centre line
                const sa = if (a < c) a + off else a - off;
                const covered = if (a < c) sa < c else sa >= c;
                if (!covered) return .{ .new = .{ x, y } };
                return .{ .old = if (horizontal) .{ sa, y } else .{ x, sa } };
            }
            // both halves of the new content slide in from the edges and meet at the centre
            const sa: ?i32 = if (a < off) a - off + c else if (a >= 2 * c - off) a + off - c else null;
            const s = sa orelse return .{ .old = .{ x, y } };
            return .{ .new = if (horizontal) .{ s, y } else .{ x, s } };
        },
        .blinds => {
            // four slats perpendicular to the direction, each wiping that way at once
            const slat = @divTrunc(axisLen(dir), 4);
            const a = if (dir.horizontal()) x else y;
            const l = @mod(a, slat);
            const lead = switch (dir) {
                .right, .down => l,
                .left, .up => slat - 1 - l,
            };
            const done = @as(u32, @intCast(lead)) * 256 < p * @as(u32, @intCast(slat));
            return if (done) .{ .new = .{ x, y } } else .{ .old = .{ x, y } };
        },
        .flip => {
            // the first half squashes the old content to the centre line of the axis, the second
            // grows the new content out of it; the rest of the panel is dark meanwhile
            const horizontal = dir.horizontal();
            const c = if (horizontal) cx else cy;
            const a = if (horizontal) x else y;
            const q: i32 = if (p < 128) @intCast(128 - p) else @intCast(p - 128);
            const hw = @divTrunc(q * c, 128);
            if (a < c - hw or a >= c + hw) return .black;
            const sa = std.math.clamp(c + @divTrunc((a - c) * 128, q), 0, 2 * c - 1);
            const s: [2]i32 = if (horizontal) .{ sa, y } else .{ x, sa };
            return if (p < 128) .{ .old = s } else .{ .new = s };
        },
        .rain, .rain_random => {
            // lines perpendicular to the direction fall that way, revealing the new content; the
            // starts spread over the first 60 % of the run, then each line drops over 40 % of it,
            // accelerating. staggered starts run along the panel; random ones follow a hash
            const horizontal = dir.horizontal();
            const lines: u32 = if (horizontal) H else W;
            const i: u32 = @intCast(if (horizontal) y else x);
            const spread: u32 = 154;
            const fall: u32 = 102;
            const start: u32 = if (effect == .rain) i * spread / (lines - 1) else @as(u32, hash(i, 7)) * spread / 255;
            const q: u32 = if (p <= start) 0 else @min((p - start) * 256 / fall, 256);
            const d = delta(dir, scaled(q * q / 256, axisLen(dir)));
            const sx = x - d[0];
            const sy = y - d[1];
            return if (inBounds(sx, sy)) .{ .old = .{ sx, sy } } else .{ .new = .{ x, y } };
        },
        .dissolve => return if (hash(@intCast(x), @intCast(y)) < p) .{ .new = .{ x, y } } else .{ .old = .{ x, y } },
        .fade, .cut => unreachable,
    }
}

// ---- tests: frames marked with their own coordinates so every remap can be checked exactly

const old_tag: u8 = 1;
const new_tag: u8 = 2;

fn marked(tag: u8) geometry.Rgb {
    var rgb: geometry.Rgb = undefined;
    for (0..geometry.height) |y| for (0..geometry.width) |x| {
        const o = geometry.pixelOffset(x, y);
        rgb[o] = @intCast(x);
        rgb[o + 1] = @intCast(y);
        rgb[o + 2] = tag;
    };
    return rgb;
}

fn at(rgb: *const geometry.Rgb, x: usize, y: usize) [3]u8 {
    return rgb[geometry.pixelOffset(x, y)..][0..3].*;
}

fn run(effect: Effect, dir: Direction, p: u32) geometry.Rgb {
    const old = marked(old_tag);
    const new = marked(new_tag);
    var out: geometry.Rgb = undefined;
    composite(effect, dir, &old, &new, &out, p);
    return out;
}

fn expectPx(out: *const geometry.Rgb, x: usize, y: usize, sx: u8, sy: u8, tag: u8) !void {
    try std.testing.expectEqual([3]u8{ sx, sy, tag }, at(out, x, y));
}

fn expectBlack(out: *const geometry.Rgb, x: usize, y: usize) !void {
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(out, x, y));
}

fn countNew(out: *const geometry.Rgb) usize {
    var n: usize = 0;
    for (0..geometry.height) |y| for (0..geometry.width) |x| {
        if (at(out, x, y)[2] == new_tag) n += 1;
    };
    return n;
}

test "cut and fade" {
    const out = run(.cut, .left, 0);
    try std.testing.expectEqualSlices(u8, &marked(new_tag), &out);
    var a: geometry.Rgb = undefined;
    @memset(&a, 10);
    var b: geometry.Rgb = undefined;
    @memset(&b, 200);
    var mid: geometry.Rgb = undefined;
    composite(.fade, .left, &a, &b, &mid, 128);
    try std.testing.expectEqual(@as(u8, 105), mid[0]);
}

test "every effect shows only the old frame at the start" {
    inline for (std.meta.fields(Effect)) |f| {
        const e: Effect = @enumFromInt(f.value);
        if (e == .cut) continue;
        const out = run(e, .left, 0);
        try std.testing.expectEqual(@as(usize, 0), countNew(&out));
    }
}

test "slide moves both frames in tandem" {
    const out = run(.slide, .left, 128); // 26 px travelled
    try expectPx(&out, 0, 5, 26, 5, old_tag);
    try expectPx(&out, 25, 5, 51, 5, old_tag);
    try expectPx(&out, 26, 5, 0, 5, new_tag);
    try expectPx(&out, 51, 5, 25, 5, new_tag);
    const down = run(.slide, .down, 128); // 8 px
    try expectPx(&down, 3, 0, 3, 8, new_tag);
    try expectPx(&down, 3, 8, 3, 0, old_tag);
    try expectPx(&down, 3, 15, 3, 7, old_tag);
}

test "swipe out slides the old frame off a stationary new one; swipe in the reverse" {
    const out = run(.swipe_out, .left, 128);
    try expectPx(&out, 0, 5, 26, 5, old_tag);
    try expectPx(&out, 30, 5, 30, 5, new_tag);
    const in = run(.swipe_in, .left, 128);
    try expectPx(&in, 0, 5, 0, 5, old_tag);
    try expectPx(&in, 26, 5, 0, 5, new_tag);
    try expectPx(&in, 51, 5, 25, 5, new_tag);
    const right = run(.swipe_in, .right, 64); // 13 px in from the left edge
    try expectPx(&right, 0, 2, 39, 2, new_tag);
    try expectPx(&right, 12, 2, 51, 2, new_tag);
    try expectPx(&right, 13, 2, 13, 2, old_tag);
}

test "wipe reveals the new frame behind a moving edge, nothing travels" {
    const left = run(.wipe, .left, 128);
    try expectPx(&left, 0, 5, 0, 5, old_tag);
    try expectPx(&left, 25, 5, 25, 5, old_tag);
    try expectPx(&left, 26, 5, 26, 5, new_tag);
    const down = run(.wipe, .down, 128);
    try expectPx(&down, 7, 0, 7, 0, new_tag);
    try expectPx(&down, 7, 7, 7, 7, new_tag);
    try expectPx(&down, 7, 8, 7, 8, old_tag);
}

test "collapse shrinks the old frame to the centre; expand grows the new one out of it" {
    const c = run(.collapse, .left, 128); // half extents 13 and 4
    try expectPx(&c, 26, 8, 26, 8, old_tag);
    try expectPx(&c, 13, 8, 13, 8, old_tag);
    try expectPx(&c, 12, 8, 12, 8, new_tag);
    try expectPx(&c, 26, 4, 26, 4, old_tag);
    try expectPx(&c, 26, 3, 26, 3, new_tag);
    try expectPx(&c, 26, 11, 26, 11, old_tag);
    try expectPx(&c, 26, 12, 26, 12, new_tag);
    const e = run(.expand, .left, 128);
    try expectPx(&e, 26, 8, 26, 8, new_tag);
    try expectPx(&e, 12, 8, 12, 8, old_tag);
    try expectPx(&e, 26, 3, 26, 3, old_tag);
    try std.testing.expectEqual(@as(usize, 26 * 8), countNew(&e));
    try std.testing.expectEqual(@as(usize, geometry.pixels - 26 * 8), countNew(&c));
}

test "split out parts the old frame at the centre; split in closes the new one over it" {
    const out = run(.split_out, .left, 128); // 13 px each way
    try expectPx(&out, 0, 5, 13, 5, old_tag);
    try expectPx(&out, 12, 5, 25, 5, old_tag);
    try expectPx(&out, 13, 5, 13, 5, new_tag);
    try expectPx(&out, 38, 5, 38, 5, new_tag);
    try expectPx(&out, 39, 5, 26, 5, old_tag);
    try expectPx(&out, 51, 5, 38, 5, old_tag);
    const in = run(.split_in, .left, 128);
    try expectPx(&in, 0, 5, 13, 5, new_tag);
    try expectPx(&in, 12, 5, 25, 5, new_tag);
    try expectPx(&in, 13, 5, 13, 5, old_tag);
    try expectPx(&in, 38, 5, 38, 5, old_tag);
    try expectPx(&in, 39, 5, 26, 5, new_tag);
    try expectPx(&in, 51, 5, 38, 5, new_tag);
    const vertical = run(.split_out, .up, 128); // 4 px each way
    try expectPx(&vertical, 9, 0, 9, 4, old_tag);
    try expectPx(&vertical, 9, 4, 9, 4, new_tag);
    try expectPx(&vertical, 9, 15, 9, 11, old_tag);
}

test "blinds wipe four slats at once" {
    const down = run(.blinds, .down, 128); // two of the four rows of each slat
    try expectPx(&down, 3, 0, 3, 0, new_tag);
    try expectPx(&down, 3, 1, 3, 1, new_tag);
    try expectPx(&down, 3, 2, 3, 2, old_tag);
    try expectPx(&down, 3, 4, 3, 4, new_tag);
    try expectPx(&down, 3, 7, 3, 7, old_tag);
    const up = run(.blinds, .up, 128);
    try expectPx(&up, 3, 0, 3, 0, old_tag);
    try expectPx(&up, 3, 3, 3, 3, new_tag);
    const right = run(.blinds, .right, 128); // strips of 13 columns, 7 done in each (6.5 rounds up)
    try expectPx(&right, 0, 3, 0, 3, new_tag);
    try expectPx(&right, 6, 3, 6, 3, new_tag);
    try expectPx(&right, 7, 3, 7, 3, old_tag);
    try expectPx(&right, 13, 3, 13, 3, new_tag);
}

test "flip squashes the old frame to the centre line then grows the new one" {
    const a = run(.flip, .left, 64); // old at half width
    try expectPx(&a, 26, 5, 26, 5, old_tag);
    try expectPx(&a, 14, 5, 2, 5, old_tag);
    try expectBlack(&a, 12, 5);
    try expectBlack(&a, 51, 5);
    const mid = run(.flip, .left, 128);
    try expectBlack(&mid, 26, 8);
    const b = run(.flip, .left, 192); // new at half width
    try expectPx(&b, 26, 5, 26, 5, new_tag);
    try expectPx(&b, 14, 5, 2, 5, new_tag);
    try expectBlack(&b, 12, 5);
    const v = run(.flip, .up, 64); // vertical axis, half height
    try expectPx(&v, 9, 8, 9, 8, old_tag);
    try expectPx(&v, 9, 4, 9, 0, old_tag);
    try expectBlack(&v, 9, 3);
}

test "rain drops columns with staggered or random starts" {
    const early = run(.rain, .down, 100);
    try expectPx(&early, 51, 5, 51, 5, old_tag); // the last column has not started
    try expectPx(&early, 0, 15, 0, 0, old_tag); // the first has dropped 15 rows, one from gone
    try expectPx(&early, 0, 14, 0, 14, new_tag);
    const late = run(.rain, .down, 255);
    try std.testing.expectEqual(@as(usize, 16), blk: {
        var n: usize = 0;
        for (0..16) |y| if (at(&late, 0, y)[2] == new_tag) {
            n += 1;
        };
        break :blk n;
    });
    try expectPx(&late, 51, 15, 51, 0, old_tag); // the last column is one row from gone
    const random = run(.rain_random, .down, 128);
    const staggered = run(.rain, .down, 128);
    try std.testing.expect(!std.mem.eql(u8, &random, &staggered));
    try std.testing.expect(countNew(&random) > 100);
    const sideways = run(.rain, .left, 255);
    try expectPx(&sideways, 1, 15, 51, 15, old_tag); // the last row has travelled 50 of 52 columns
    try expectPx(&sideways, 2, 15, 2, 15, new_tag);
}

test "dissolve switches pixels in a fixed order" {
    const half = run(.dissolve, .left, 128);
    const n = countNew(&half);
    try std.testing.expect(n > 330 and n < 500);
    try std.testing.expectEqualSlices(u8, &half, &run(.dissolve, .left, 128));
    const late = run(.dissolve, .left, 255);
    try std.testing.expect(countNew(&late) > 820);
}

test "exits pair the effect and reverse, continue or cut according to the exit mode" {
    const s = Spec{ .effect = .swipe_in, .direction = .left, .duration_ns = 7 };
    try std.testing.expectEqual(Spec{ .effect = .swipe_out, .direction = .right, .duration_ns = 7 }, s.outgoing());
    const same = Spec{ .effect = .swipe_in, .direction = .left, .duration_ns = 7, .exit = .same };
    try std.testing.expectEqual(Spec{ .effect = .swipe_out, .direction = .left, .duration_ns = 7, .exit = .same }, same.outgoing());
    try std.testing.expect((Spec{ .effect = .expand, .exit = .none }).outgoing().instant());
    try std.testing.expectEqual(Effect.collapse, (Spec{ .effect = .expand }).outgoing().effect);
    try std.testing.expectEqual(Direction.down, (Spec{ .direction = .up }).outgoing().direction);
    try std.testing.expectEqual(Effect.fade, (Spec{}).outgoing().effect);
    try std.testing.expect(Spec.cut.instant());
    try std.testing.expectEqual(Direction.down, Effect.rain.naturalDirection());
}

test "a transition runs over its duration and ends exactly on the new frame" {
    var t = Transition{};
    const old = marked(old_tag);
    const new = marked(new_tag);
    var out: geometry.Rgb = undefined;
    t.begin(&old, Spec.cut, 0);
    try std.testing.expect(!t.active());
    try std.testing.expect(!t.apply(&new, &out, 0));
    try std.testing.expectEqualSlices(u8, &new, &out);
    t.begin(&old, .{ .effect = .wipe, .direction = .right, .duration_ns = 1_000_000_000 }, 5_000_000_000);
    try std.testing.expect(t.apply(&new, &out, 5_000_000_000));
    try std.testing.expectEqualSlices(u8, &old, &out);
    try std.testing.expect(t.apply(&new, &out, 5_500_000_000));
    try expectPx(&out, 0, 0, 0, 0, new_tag);
    try expectPx(&out, 26, 0, 26, 0, old_tag);
    try std.testing.expect(!t.apply(&new, &out, 6_000_000_000));
    try std.testing.expectEqualSlices(u8, &new, &out);
    try std.testing.expect(!t.active());
    // a live old layer replaces the remembered frame
    t.begin(&old, .{ .effect = .wipe, .direction = .right, .duration_ns = 1_000_000_000 }, 0);
    var live = marked(9);
    try std.testing.expect(t.applyFrom(&live, &new, &out, 500_000_000));
    try expectPx(&out, 26, 0, 26, 0, 9);
    try expectPx(&out, 0, 0, 0, 0, new_tag);
    live = marked(8);
    try std.testing.expect(t.applyFrom(&live, &new, &out, 600_000_000));
    try expectPx(&out, 40, 0, 40, 0, 8);
}
