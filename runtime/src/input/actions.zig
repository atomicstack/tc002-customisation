//! maps raw evdev events to normalized physical actions: button releases become left/middle/right,
//! the knob push becomes a short press on release or a long press once held past the threshold,
//! and rotary absolute-value transitions become cw/ccw steps. pure; fed with monotonic time.
const std = @import("std");
const evdev = @import("evdev.zig");
const scene = @import("../scene/scene.zig");

test "a button press and release yields one action on release" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    m.feed(key(105, 1), 0, &q);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.feed(key(105, 0), 50_000_000, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.left}, q.slice());
    q.clear();
    m.feed(key(103, 1), 0, &q);
    m.feed(key(103, 0), 1, &q);
    m.feed(key(106, 1), 0, &q);
    m.feed(key(106, 0), 1, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{ .middle, .right }, q.slice());
}

test "a short knob press is reported on release, a long one once while held" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    m.feed(key(108, 1), 0, &q);
    m.feed(key(108, 0), 200_000_000, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_short}, q.slice());
    q.clear();
    m.feed(key(108, 1), 1_000_000_000, &q);
    m.poll(1_500_000_000, &q);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.poll(1_800_000_000, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
    m.poll(2_500_000_000, &q);
    m.feed(key(108, 0), 3_000_000_000, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
}

test "rotary absolute transitions become steps, including wrap-around" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    m.feed(abs(10), 0, &q);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.feed(abs(11), 1, &q);
    m.feed(abs(12), 2, &q);
    m.feed(abs(11), 3, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{ .rotate_cw, .rotate_cw, .rotate_ccw }, q.slice());
    q.clear();
    m.feed(abs(255), 4, &q);
    q.clear();
    m.feed(abs(0), 5, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.rotate_cw}, q.slice());
    q.clear();
    m.feed(abs(255), 6, &q);
    try std.testing.expectEqualSlices(scene.Action, &.{.rotate_ccw}, q.slice());
}

test "unknown keys and repeats are ignored and the queue is bounded" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    m.feed(key(999, 1), 0, &q);
    m.feed(key(999, 0), 1, &q);
    m.feed(key(105, 2), 2, &q); // autorepeat
    try std.testing.expectEqual(@as(usize, 0), q.len);
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        m.feed(key(105, 1), i * 10, &q);
        m.feed(key(105, 0), i * 10 + 1, &q);
    }
    try std.testing.expectEqual(@as(usize, ActionQueue.capacity), q.len);
    try std.testing.expectEqual(@as(u32, 12 - ActionQueue.capacity), q.dropped);
}

fn key(code: u16, value: i32) evdev.Event {
    return .{ .sec = 0, .usec = 0, .type = evdev.EV_KEY, .code = code, .value = value };
}

fn abs(value: i32) evdev.Event {
    return .{ .sec = 0, .usec = 0, .type = evdev.EV_ABS, .code = 0, .value = value };
}

/// a small fixed queue of actions produced by one batch of events; overflow drops and counts.
pub const ActionQueue = struct {
    pub const capacity = 8;
    items: [capacity]scene.Action = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *ActionQueue, a: scene.Action) bool {
        if (self.len == capacity) {
            self.dropped += 1;
            return false;
        }
        self.items[self.len] = a;
        self.len += 1;
        return true;
    }

    pub fn slice(self: *const ActionQueue) []const scene.Action {
        return self.items[0..self.len];
    }

    pub fn clear(self: *ActionQueue) void {
        self.len = 0;
    }
};

pub const Mapper = struct {
    keymap: evdev.KeyMap,
    long_press_ns: u64 = 700_000_000,
    knob_down_since: ?u64 = null,
    knob_long_sent: bool = false,
    last_abs: ?i32 = null,

    pub fn init(keymap: evdev.KeyMap) Mapper {
        return .{ .keymap = keymap };
    }

    pub fn feed(self: *Mapper, ev: evdev.Event, now_ns: u64, out: *ActionQueue) void {
        switch (ev.type) {
            evdev.EV_KEY => {
                if (ev.value == 2) return; // autorepeat carries no new intent
                const down = ev.value != 0;
                const km = self.keymap;
                if (ev.code == km.knob) {
                    if (down) {
                        self.knob_down_since = now_ns;
                        self.knob_long_sent = false;
                    } else {
                        if (self.knob_down_since != null and !self.knob_long_sent) _ = out.push(.knob_short);
                        self.knob_down_since = null;
                    }
                } else if (!down) {
                    if (ev.code == km.left) {
                        _ = out.push(.left);
                    } else if (ev.code == km.middle) {
                        _ = out.push(.middle);
                    } else if (ev.code == km.right) {
                        _ = out.push(.right);
                    }
                }
            },
            evdev.EV_ABS => {
                if (self.last_abs) |prev| {
                    // the knob driver reports an absolute counter; treat it as 8-bit for wrap-around
                    var delta = ev.value - prev;
                    if (delta > 127) delta -= 256 else if (delta < -127) delta += 256;
                    while (delta > 0) : (delta -= 1) _ = out.push(.rotate_cw);
                    while (delta < 0) : (delta += 1) _ = out.push(.rotate_ccw);
                }
                self.last_abs = ev.value;
            },
            else => {},
        }
    }

    /// called every loop iteration: a knob held past the threshold yields one long press.
    pub fn poll(self: *Mapper, now_ns: u64, out: *ActionQueue) void {
        if (self.knob_down_since) |since| {
            if (!self.knob_long_sent and now_ns - since >= self.long_press_ns) {
                self.knob_long_sent = true;
                _ = out.push(.knob_long);
            }
        }
    }
};
