//! deadline scheduling for the render loop: intended deadlines, no catch-up bursts, wall-clock
//! targets converted to the monotonic clock. pure.
const std = @import("std");
const scene = @import("../scene/scene.zig");

/// a wall-clock target expressed on the monotonic clock, given one paired reading of both clocks.
pub fn wallToMono(now_mono: u64, wall_now: u64, wall_target: u64) u64 {
    return if (wall_target >= wall_now) now_mono + (wall_target - wall_now) else now_mono -| (wall_now - wall_target);
}

/// the next render deadline after a redraw at `deadline` given the scene's cadence. a continuous
/// scene advances from the intended deadline and, when we have fallen behind, resynchronises to
/// now instead of bursting; a wall-clock scene targets its boundary; idle scenes have no deadline.
pub fn nextDeadline(cadence: scene.Cadence, deadline: u64, now_mono: u64, wall_now: u64) ?u64 {
    return switch (cadence) {
        .continuous => |period| blk: {
            const next = deadline + period;
            break :blk if (next < now_mono) now_mono else next;
        },
        .at_wall_ns => |wall_target| wallToMono(now_mono, wall_now, wall_target),
        .idle => null,
    };
}

/// the deadline after a redraw: a running fade wants the next frame one period from now
/// whatever the scene's own cadence says (a clock's next wall-second boundary would freeze the
/// fade until then); otherwise the scene decides.
pub fn afterRedraw(fading: bool, cadence: scene.Cadence, deadline: u64, now_mono: u64, wall_now: u64) ?u64 {
    if (fading) return now_mono + scene.frame_period_ns;
    return nextDeadline(cadence, deadline, now_mono, wall_now);
}

test "a fade that starts from an isolated scene schedules the next frame one period from now" {
    // the clock's next boundary is 900 ms away; a fade must not wait for it
    const boundary: u64 = 2_000_000_000;
    try std.testing.expectEqual(@as(?u64, 1_100_000_000 + scene.frame_period_ns), afterRedraw(true, .{ .at_wall_ns = boundary }, boundary, 1_100_000_000, 1_100_000_000));
    try std.testing.expectEqual(@as(?u64, boundary), afterRedraw(false, .{ .at_wall_ns = boundary }, boundary, 1_100_000_000, 1_100_000_000));
    try std.testing.expectEqual(@as(?u64, 1_000_000_000 + scene.frame_period_ns), afterRedraw(true, .idle, 0, 1_000_000_000, 0));
}

/// an overlay expiry is a wake-up, not a render deadline: when the scene is idle nothing else
/// would tick the arbiter at that moment, so the loop has to force a redraw. a scene with a
/// deadline of its own (continuous art, a scrolling notification) ticks on the next frame anyway.
pub fn expiryNeedsRedraw(expiry: ?u64, render_deadline: ?u64, now_mono: u64) bool {
    const e = expiry orelse return false;
    return now_mono >= e and render_deadline == null;
}

/// the earliest of up to four optional monotonic instants (timer arming).
pub fn earliest(a: ?u64, b: ?u64, c: ?u64, d: ?u64) ?u64 {
    var best: ?u64 = null;
    for ([_]?u64{ a, b, c, d }) |v| if (v) |t| {
        if (best == null or t < best.?) best = t;
    };
    return best;
}

test "continuous deadlines advance by the period and resync after an overrun" {
    try std.testing.expectEqual(@as(?u64, 1_016_666_667), nextDeadline(.{ .continuous = 16_666_667 }, 1_000_000_000, 1_005_000_000, 0));
    try std.testing.expectEqual(@as(?u64, 1_100_000_000), nextDeadline(.{ .continuous = 16_666_667 }, 1_000_000_000, 1_100_000_000, 0));
}

test "wall targets map onto the monotonic clock in both directions" {
    try std.testing.expectEqual(@as(u64, 15), wallToMono(10, 100, 105));
    try std.testing.expectEqual(@as(u64, 5), wallToMono(10, 100, 95));
    try std.testing.expectEqual(@as(u64, 0), wallToMono(10, 100, 50));
    try std.testing.expectEqual(@as(?u64, 500), nextDeadline(.{ .at_wall_ns = 2000 }, 0, 100, 1600));
    try std.testing.expectEqual(@as(?u64, null), nextDeadline(.idle, 0, 100, 1600));
}

test "earliest picks the minimum of the present values" {
    try std.testing.expectEqual(@as(?u64, 3), earliest(null, 7, 3, null));
    try std.testing.expectEqual(@as(?u64, null), earliest(null, null, null, null));
}

test "an expiry with no render deadline forces a redraw; a scheduled scene handles its own" {
    try std.testing.expect(expiryNeedsRedraw(100, null, 100));
    try std.testing.expect(expiryNeedsRedraw(100, null, 150));
    try std.testing.expect(!expiryNeedsRedraw(100, null, 99));
    try std.testing.expect(!expiryNeedsRedraw(100, 120, 100));
    try std.testing.expect(!expiryNeedsRedraw(null, null, 100));
}
