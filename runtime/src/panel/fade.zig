//! presentation fades, pure: a transition from the frame that was on the panel to the scene's new
//! output (any effect from `transition.zig`; the default is a cross-fade) and a power ramp between
//! the output and black. integer maths on the rgb bytes before brightness and the level curve are
//! applied; no allocation. the renderer drives it with monotonic time and forces a continuous
//! cadence while `apply` reports a fade in progress.
const std = @import("std");
const geometry = @import("geometry.zig");
const transition = @import("transition.zig");

const ns_per_ms: u64 = 1_000_000;

pub const Fader = struct {
    /// the duration of the default cross-fade (`beginCross`)
    crossfade_ns: u64 = 500 * ns_per_ms,
    power_ns: u64 = 600 * ns_per_ms,
    cross: transition.Transition = .{},
    power_on: bool = true,
    /// the output level right now, 255 = full, 0 = dark.
    level: u8 = 255,
    level_from: u8 = 255,
    power_start: ?u64 = null,

    /// the scene changed: cross-fade from what is on the panel now to the new output.
    pub fn beginCross(self: *Fader, current: *const geometry.Rgb, now_ns: u64) void {
        self.begin(current, .{ .effect = .fade, .duration_ns = self.crossfade_ns }, now_ns);
    }

    /// the scene changed: run `spec` from what is on the panel now to the new output.
    pub fn begin(self: *Fader, current: *const geometry.Rgb, spec: transition.Spec, now_ns: u64) void {
        self.cross.begin(current, spec, now_ns);
    }

    pub fn setPower(self: *Fader, on: bool, now_ns: u64) void {
        if (self.power_on == on) return;
        self.power_on = on;
        if (self.power_ns == 0) {
            self.level = if (on) 255 else 0;
            self.power_start = null;
            return;
        }
        self.level_from = self.level;
        self.power_start = now_ns;
    }

    pub fn active(self: *const Fader) bool {
        return self.cross.active() or self.power_start != null;
    }

    /// the panel is off and the ramp has finished: nothing needs redrawing until power returns.
    pub fn dark(self: *const Fader) bool {
        return !self.power_on and self.level == 0 and self.power_start == null;
    }

    /// composite `in` into `out` for `now`; returns true while a fade is still running. the frame
    /// produced on the iteration that completes a fade is exact (the caller latches it).
    pub fn apply(self: *Fader, in: *const geometry.Rgb, out: *geometry.Rgb, now_ns: u64) bool {
        _ = self.cross.apply(in, out, now_ns);
        if (self.power_start) |s| {
            const elapsed = now_ns -| s;
            const target: i64 = if (self.power_on) 255 else 0;
            if (elapsed >= self.power_ns) {
                self.level = @intCast(target);
                self.power_start = null;
            } else {
                const from: i64 = self.level_from;
                self.level = @intCast(from + @divTrunc((target - from) * @as(i64, @intCast(elapsed)), @as(i64, @intCast(self.power_ns))));
            }
        }
        const level: u32 = self.level;
        // a ramp that has just started is still running at full level: the caller must keep the
        // frame cadence so the next frame actually advances it
        if (level == 255) return self.active();
        // 255 maps to a full 256/256 so a lit panel is bit-exact; 0 maps to black
        const gain: u32 = level + (level >> 7);
        for (out) |*o| o.* = @intCast((@as(u32, o.*) * gain) >> 8);
        return self.active();
    }
};

fn filled(v: u8) geometry.Rgb {
    var rgb: geometry.Rgb = undefined;
    @memset(&rgb, v);
    return rgb;
}

test "without a fade the output is the input and nothing is active" {
    var f = Fader{};
    const in = filled(200);
    var out: geometry.Rgb = undefined;
    try std.testing.expect(!f.apply(&in, &out, 0));
    try std.testing.expectEqualSlices(u8, &in, &out);
    try std.testing.expect(!f.active());
    try std.testing.expect(!f.dark());
}

test "a cross-fade starts on the old frame, passes the midpoint and ends exactly on the new one" {
    var f = Fader{};
    const old = filled(0);
    const new = filled(200);
    var out: geometry.Rgb = undefined;
    f.beginCross(&old, 1_000_000_000);
    try std.testing.expect(f.apply(&new, &out, 1_000_000_000));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expect(f.apply(&new, &out, 1_250_000_000));
    try std.testing.expectEqual(@as(u8, 100), out[7]);
    try std.testing.expect(!f.apply(&new, &out, 1_500_000_000));
    try std.testing.expectEqualSlices(u8, &new, &out);
    try std.testing.expect(!f.active());
}

test "the power ramp goes to black, stays dark, and ramps back to a bit-exact frame" {
    var f = Fader{};
    const in = filled(255);
    var out: geometry.Rgb = undefined;
    f.setPower(false, 0);
    try std.testing.expect(f.active());
    try std.testing.expect(f.apply(&in, &out, 300_000_000));
    try std.testing.expect(out[0] > 100 and out[0] < 160);
    try std.testing.expect(!f.apply(&in, &out, 600_000_000));
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &out);
    try std.testing.expect(f.dark());
    f.setPower(false, 700_000_000); // idempotent
    try std.testing.expect(f.dark());
    f.setPower(true, 1_000_000_000);
    try std.testing.expect(!f.dark());
    try std.testing.expect(f.apply(&in, &out, 1_000_000_000));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expect(!f.apply(&in, &out, 1_600_000_000));
    try std.testing.expectEqualSlices(u8, &in, &out);
}

test "reversing a ramp midway continues from the current level; zero durations are immediate" {
    var f = Fader{};
    const in = filled(255);
    var out: geometry.Rgb = undefined;
    f.setPower(false, 0);
    _ = f.apply(&in, &out, 300_000_000);
    const mid = f.level;
    f.setPower(true, 300_000_000);
    _ = f.apply(&in, &out, 300_000_000);
    try std.testing.expectEqual(mid, f.level);
    try std.testing.expect(!f.apply(&in, &out, 900_000_000));
    try std.testing.expectEqual(@as(u8, 255), f.level);
    var g = Fader{ .crossfade_ns = 0, .power_ns = 0 };
    g.beginCross(&in, 0);
    try std.testing.expect(!g.active());
    g.setPower(false, 0);
    try std.testing.expect(g.dark());
    try std.testing.expect(!g.apply(&in, &out, 0));
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &out);
}

test "a directional transition runs through the fader with the power ramp on top" {
    var f = Fader{};
    const old = filled(0);
    const new = filled(200);
    var out: geometry.Rgb = undefined;
    f.begin(&old, .{ .effect = .wipe, .direction = .right, .duration_ns = 1_000_000_000 }, 0);
    try std.testing.expect(f.apply(&new, &out, 500_000_000));
    try std.testing.expectEqual(@as(u8, 200), out[0]); // left half wiped to the new frame
    try std.testing.expectEqual(@as(u8, 0), out[geometry.pixelOffset(40, 0)]);
    f.begin(&old, transition.Spec.cut, 600_000_000);
    try std.testing.expect(!f.apply(&new, &out, 600_000_000));
    try std.testing.expectEqualSlices(u8, &new, &out);
}

test "a cross-fade during a power ramp multiplies both" {
    var f = Fader{};
    const old = filled(0);
    const new = filled(200);
    var out: geometry.Rgb = undefined;
    f.setPower(false, 0);
    f.beginCross(&old, 0);
    _ = f.apply(&new, &out, 250_000_000);
    // half blended (100) at a level around 149/255
    try std.testing.expect(out[0] > 50 and out[0] < 70);
}

test "a power-off ramp reports itself running from its very first frame" {
    // the renderer applies the first frame at the instant the ramp starts. if that frame said
    // "not fading", the scene's own cadence would rule and a clock would jump to black at its
    // next second boundary instead of ramping down.
    var f = Fader{};
    const in = filled(255);
    var out: geometry.Rgb = undefined;
    try std.testing.expect(!f.apply(&in, &out, 0));
    f.setPower(false, 1_000_000_000);
    try std.testing.expect(f.apply(&in, &out, 1_000_000_000));
    try std.testing.expectEqualSlices(u8, &in, &out); // still fully lit at elapsed 0
    try std.testing.expect(f.apply(&in, &out, 1_300_000_000));
    try std.testing.expect(out[0] > 100 and out[0] < 160);
}
