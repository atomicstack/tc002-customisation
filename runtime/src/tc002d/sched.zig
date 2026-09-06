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
