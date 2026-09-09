//! maps raw evdev events to normalized physical actions: button releases become left/middle/right,
//! the knob push becomes a short press on release or a long press once held past the threshold,
//! and rotary absolute-value transitions become cw/ccw steps. pure; fed with monotonic time.
const std = @import("std");
const evdev = @import("evdev.zig");
const scene = @import("../scene/scene.zig");

test "a button press and release yields one action on release" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(103, 1), 0, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.feed(key(103, 0), 50_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.left}, q.slice());
    q.clear();
    m.feed(key(105, 1), 0, &q, &e);
    m.feed(key(105, 0), 1, &q, &e);
    m.feed(key(106, 1), 0, &q, &e);
    m.feed(key(106, 0), 1, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{ .middle, .right }, q.slice());
}

test "a short knob press is reported on release, a long one once while held" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(108, 1), 0, &q, &e);
    m.feed(key(108, 0), 200_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_short}, q.slice());
    q.clear();
    m.feed(key(108, 1), 1_000_000_000, &q, &e);
    m.poll(1_500_000_000, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.poll(1_800_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
    m.poll(2_500_000_000, &q, &e);
    m.feed(key(108, 0), 3_000_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
}

test "rotary absolute transitions become steps, including wrap-around" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(abs(10), 0, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.feed(abs(11), 1, &q, &e);
    m.feed(abs(12), 2, &q, &e);
    m.feed(abs(11), 3, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{ .rotate_cw, .rotate_cw, .rotate_ccw }, q.slice());
    q.clear();
    m.feed(abs(255), 4, &q, &e);
    q.clear();
    m.feed(abs(0), 5, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.rotate_cw}, q.slice());
    q.clear();
    m.feed(abs(255), 6, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.rotate_ccw}, q.slice());
}

test "unknown keys and repeats are ignored and the queue is bounded" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(999, 1), 0, &q, &e);
    m.feed(key(999, 0), 1, &q, &e);
    m.feed(key(103, 2), 2, &q, &e); // autorepeat
    try std.testing.expectEqual(@as(usize, 0), q.len);
    var i: u32 = 0;
    while (i < 12) : (i += 1) {
        m.feed(key(103, 1), i * 10, &q, &e);
        m.feed(key(103, 0), i * 10 + 1, &q, &e);
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

/// the physical controls as reported outward and as remote injection targets.
pub const Control = enum(u8) { left = 0, middle = 1, right = 2, knob = 3, rotary = 4 };

/// what happened on a control. buttons and the knob report press/release (the knob also `long`
/// once held past the threshold); the rotary reports one cw/ccw per detent. `click` exists only
/// as an injection request (press then release).
pub const EdgeEvent = enum(u8) { release = 0, press = 1, click = 2, long = 3, cw = 4, ccw = 5 };

/// one outward event: the control, what it did, and the rotary position after it.
pub const Edge = struct { control: Control, event: EdgeEvent, position: i32 };

/// a bounded queue of edges from one batch of events; overflow drops and counts.
pub const EdgeQueue = struct {
    pub const capacity = 16;
    items: [capacity]Edge = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *EdgeQueue, e: Edge) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.items[self.len] = e;
        self.len += 1;
    }

    pub fn slice(self: *const EdgeQueue) []const Edge {
        return self.items[0..self.len];
    }
};

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
    /// detents since start, cw positive; reported with every rotary edge.
    position: i32 = 0,
    /// the last keycode that matched nothing, for the renderer to log; 0 = none.
    unmapped_code: u16 = 0,
    /// the last mapped key that went down, for the renderer's log (cleared when logged)
    last_press: ?struct { code: u16, control: Control } = null,

    pub fn init(keymap: evdev.KeyMap) Mapper {
        return .{ .keymap = keymap };
    }

    fn controlOf(self: *const Mapper, code: u16) ?Control {
        const km = self.keymap;
        if (code == km.left) return .left;
        if (code == km.middle) return .middle;
        if (code == km.right) return .right;
        if (code == km.knob) return .knob;
        return null;
    }

    fn step(self: *Mapper, cw: bool, out: *ActionQueue, edges: *EdgeQueue) void {
        self.position +%= if (cw) 1 else -1;
        _ = out.push(if (cw) .rotate_cw else .rotate_ccw);
        edges.push(.{ .control = .rotary, .event = if (cw) .cw else .ccw, .position = self.position });
    }

    /// physical or injected evdev events become actions for the arbiter and edges for the network.
    pub fn feed(self: *Mapper, ev: evdev.Event, now_ns: u64, out: *ActionQueue, edges: *EdgeQueue) void {
        switch (ev.type) {
            evdev.EV_KEY => {
                if (ev.value == 2) return; // autorepeat carries no new intent
                const down = ev.value != 0;
                const control = self.controlOf(ev.code) orelse {
                    if (down) self.unmapped_code = ev.code;
                    return;
                };
                edges.push(.{ .control = control, .event = if (down) .press else .release, .position = self.position });
                if (down) self.last_press = .{ .code = ev.code, .control = control };
                if (control == .knob) {
                    if (down) {
                        self.knob_down_since = now_ns;
                        self.knob_long_sent = false;
                    } else {
                        if (self.knob_down_since != null and !self.knob_long_sent) _ = out.push(.knob_short);
                        self.knob_down_since = null;
                    }
                } else if (!down) {
                    _ = out.push(switch (control) {
                        .left => .left,
                        .middle => .middle,
                        else => .right,
                    });
                }
            },
            evdev.EV_ABS => {
                if (self.last_abs) |prev| {
                    // the knob driver reports an absolute counter; treat it as 8-bit for wrap-around
                    var delta = ev.value - prev;
                    if (delta > 127) delta -= 256 else if (delta < -127) delta += 256;
                    while (delta > 0) : (delta -= 1) self.step(true, out, edges);
                    while (delta < 0) : (delta += 1) self.step(false, out, edges);
                }
                self.last_abs = ev.value;
            },
            else => {},
        }
    }

    /// called every loop iteration: a knob held past the threshold yields one long press.
    pub fn poll(self: *Mapper, now_ns: u64, out: *ActionQueue, edges: *EdgeQueue) void {
        if (self.knob_down_since) |since| {
            if (!self.knob_long_sent and now_ns - since >= self.long_press_ns) {
                self.knob_long_sent = true;
                _ = out.push(.knob_long);
                edges.push(.{ .control = .knob, .event = .long, .position = self.position });
            }
        }
    }

    /// a remote request: the same paths as physical input, so it produces the same actions and
    /// edges. `steps` applies to the rotary only.
    pub fn inject(self: *Mapper, control: Control, event: EdgeEvent, steps: u8, now_ns: u64, out: *ActionQueue, edges: *EdgeQueue) bool {
        const km = self.keymap;
        const code: u16 = switch (control) {
            .left => km.left,
            .middle => km.middle,
            .right => km.right,
            .knob => km.knob,
            .rotary => 0,
        };
        switch (event) {
            .press, .release => {
                if (control == .rotary) return false;
                self.feed(key(code, if (event == .press) 1 else 0), now_ns, out, edges);
            },
            .click => {
                if (control == .rotary) return false;
                self.feed(key(code, 1), now_ns, out, edges);
                self.feed(key(code, 0), now_ns, out, edges);
            },
            .long => {
                if (control != .knob) return false;
                self.feed(key(code, 1), now_ns, out, edges);
                self.knob_long_sent = true;
                _ = out.push(.knob_long);
                edges.push(.{ .control = .knob, .event = .long, .position = self.position });
                self.feed(key(code, 0), now_ns, out, edges);
            },
            .cw, .ccw => {
                if (control != .rotary or steps == 0 or steps > 16) return false;
                var n: u8 = 0;
                while (n < steps) : (n += 1) self.step(event == .cw, out, edges);
            },
        }
        return true;
    }
};

test "edges report every press and release, long holds, and rotary steps with the position" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(103, 1), 0, &q, &e);
    m.feed(key(103, 0), 1, &q, &e);
    m.feed(abs(10), 2, &q, &e);
    m.feed(abs(12), 3, &q, &e);
    m.feed(abs(11), 4, &q, &e);
    m.feed(key(108, 1), 5, &q, &e);
    m.poll(1_000_000_000, &q, &e);
    m.feed(key(108, 0), 1_100_000_000, &q, &e);
    m.feed(key(999, 1), 6, &q, &e);
    const expected = [_]Edge{
        .{ .control = .left, .event = .press, .position = 0 },
        .{ .control = .left, .event = .release, .position = 0 },
        .{ .control = .rotary, .event = .cw, .position = 1 },
        .{ .control = .rotary, .event = .cw, .position = 2 },
        .{ .control = .rotary, .event = .ccw, .position = 1 },
        .{ .control = .knob, .event = .press, .position = 1 },
        .{ .control = .knob, .event = .long, .position = 1 },
        .{ .control = .knob, .event = .release, .position = 1 },
    };
    try std.testing.expectEqualSlices(Edge, &expected, e.slice());
    try std.testing.expectEqual(@as(u16, 999), m.unmapped_code);
}

test "injected events take the physical paths and validate their shape" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    try std.testing.expect(m.inject(.middle, .click, 1, 0, &q, &e));
    try std.testing.expectEqualSlices(scene.Action, &.{.middle}, q.slice());
    try std.testing.expectEqual(@as(usize, 2), e.len);
    q.clear();
    e = .{};
    try std.testing.expect(m.inject(.rotary, .ccw, 3, 0, &q, &e));
    try std.testing.expectEqualSlices(scene.Action, &.{ .rotate_ccw, .rotate_ccw, .rotate_ccw }, q.slice());
    try std.testing.expectEqual(@as(i32, -3), e.slice()[2].position);
    q.clear();
    e = .{};
    try std.testing.expect(m.inject(.knob, .long, 1, 0, &q, &e));
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
    try std.testing.expectEqual(@as(usize, 3), e.len);
    q.clear();
    e = .{};
    try std.testing.expect(m.inject(.knob, .press, 1, 0, &q, &e));
    try std.testing.expect(m.inject(.knob, .release, 1, 100_000_000, &q, &e));
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_short}, q.slice());
    try std.testing.expect(!m.inject(.rotary, .click, 1, 0, &q, &e));
    try std.testing.expect(!m.inject(.left, .long, 1, 0, &q, &e));
    try std.testing.expect(!m.inject(.rotary, .cw, 17, 0, &q, &e));
    try std.testing.expect(!m.inject(.left, .cw, 1, 0, &q, &e));
}
