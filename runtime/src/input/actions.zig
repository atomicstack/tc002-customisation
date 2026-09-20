//! maps raw evdev events to normalized physical actions: button releases become left/middle/right,
//! the knob push becomes a short press on release or a long press once held past the threshold,
//! and the knob driver's state codes become cw/ccw steps. pure; fed with monotonic time.
const std = @import("std");
const evdev = @import("evdev.zig");
const scene = @import("../scene/scene.zig");

test "a button press and release yields one action on release" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(108, 1), 0, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.feed(key(108, 0), 50_000_000, &q, &e);
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
    m.feed(key(103, 1), 0, &q, &e);
    m.feed(key(103, 0), 200_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_short}, q.slice());
    q.clear();
    m.feed(key(103, 1), 1_000_000_000, &q, &e);
    m.poll(1_500_000_000, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    m.poll(1_800_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
    m.poll(2_500_000_000, &q, &e);
    m.feed(key(103, 0), 3_000_000_000, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());
}

test "rotary state codes become one step per detent, the way the knob actually turns" {
    // which pair is which was inferred in 2026-09-09 from the order of a test sequence and was
    // backwards: matt turned the knob clockwise in the menu on 2026-09-11 and it walked the items
    // leftwards. 8 then 1 is a clockwise detent, 13 then 11 counter-clockwise.
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(abs(8), 0, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len); // the first half of a pair is not a step
    m.feed(abs(1), 1, &q, &e);
    m.feed(abs(13), 2, &q, &e);
    m.feed(abs(11), 3, &q, &e);
    m.feed(abs(11), 4, &q, &e); // a pair whose first half was lost still counts once
    try std.testing.expectEqualSlices(scene.Action, &.{ .rotate_cw, .rotate_ccw, .rotate_ccw }, q.slice());
    try std.testing.expectEqual(@as(i32, -1), m.position);
    try std.testing.expectEqual(EdgeEvent.cw, e.slice()[0].event);
    q.clear();
    m.feed(abs(7), 5, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
    try std.testing.expectEqual(@as(?i32, 7), m.abs_unexpected);
}

test "unknown keys and repeats are ignored and the queue is bounded" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    m.feed(key(999, 1), 0, &q, &e);
    m.feed(key(999, 0), 1, &q, &e);
    m.feed(key(108, 2), 2, &q, &e); // autorepeat
    try std.testing.expectEqual(@as(usize, 0), q.len);
    const over = 4;   // enough past the bound to prove it holds, whatever the bound is
    var i: u32 = 0;
    while (i < ActionQueue.capacity + over) : (i += 1) {
        m.feed(key(108, 1), i * 10, &q, &e);
        m.feed(key(108, 0), i * 10 + 1, &q, &e);
    }
    try std.testing.expectEqual(@as(usize, ActionQueue.capacity), q.len);
    try std.testing.expectEqual(@as(u32, over), q.dropped);
}

test "a whole turn is applied: the steps the api accepts all reach the arbiter" {
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    // `POST /api/v1/input` accepts a turn of up to `max_steps` detents and answers `applied`. a
    // queue too small for one holds the first few, counts the rest as dropped and says nothing
    // further, so the panel stops short of where the caller asked for and the reply still reads
    // as success
    try std.testing.expect(m.inject(.rotary, .cw, max_steps, 0, &q, &e));
    try std.testing.expectEqual(@as(usize, max_steps), q.len);
    try std.testing.expectEqual(@as(u32, 0), q.dropped);
    try std.testing.expectEqual(@as(i32, max_steps), m.position);
}

fn key(code: u16, value: i32) evdev.Event {
    return .{ .sec = 0, .usec = 0, .type = evdev.EV_KEY, .code = code, .value = value };
}

fn abs(value: i32) evdev.Event {
    return .{ .sec = 0, .usec = 0, .type = evdev.EV_ABS, .code = 0, .value = value };
}

/// the physical controls as reported outward and as remote injection targets.
pub const Control = enum(u8) { left = 0, middle = 1, right = 2, knob = 3, rotary = 4 };

/// how many of those are buttons that can be held. the rotary is a dial with no press, and it is
/// last in the enum so that the buttons are exactly `0..button_count`.
pub const button_count = @intFromEnum(Control.rotary);

/// what happened on a control, and the whole of what one can report: every button and the knob
/// report press and release, any of them reports `long` once held past the threshold, and the
/// rotary reports one cw/ccw per detent.
///
/// `click` is not here, and never was reachable: nothing has ever pushed a click edge, because a
/// click is two edges -- injecting one produces a press and a release. it was only ever a name in
/// this enum, which meant a script or an mqtt consumer could wait for a click for ever and nothing
/// would say why. it is a request rather than an event and lives in `InputRequest`, where it can
/// be asked for and cannot be awaited.
///
/// the numbering is this type's own wire encoding and is contiguous. it briefly kept a hole at 2
/// where `click` had been, out of a habit of not moving wire values under deployed binaries -- but
/// nothing outside this repository speaks it, and a gap that exists to commemorate a mistake is
/// just a second mistake. `inject_input` carries an `InputRequest` and `input` carries an
/// `EdgeEvent`, so the two numberings are independent and neither has to leave room for the other.
pub const EdgeEvent = enum(u8) { release = 0, press = 1, long = 2, cw = 3, ccw = 4 };

/// what `POST /api/v1/input` and the mqtt `cmd/input` topic accept: every edge a control can
/// report, plus `click` -- a press and a release asked for in one call, which reports as those two
/// edges and no third thing.
pub const InputRequest = enum(u8) { release = 0, press = 1, click = 2, long = 3, cw = 4, ccw = 5 };

/// one outward event: the control, what it did, and the rotary position after it.
pub const Edge = struct { control: Control, event: EdgeEvent, position: i32 };

/// the most detents one injected turn may ask for. the api validates against this and the mapper
/// enforces it, so the two bounds cannot drift apart.
pub const max_steps: u8 = 16;

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
    /// a whole injected turn has to fit: `POST /api/v1/input` accepts up to `max_steps` detents
    /// and answers `applied`, so a queue shorter than that would drop the rest of a turn the
    /// caller was told had been applied. at eight it did, silently, for every turn past eight
    pub const capacity = max_steps;
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
    /// when each button went down and whether its long press has already been reported, indexed by
    /// `Control`. the rotary has no hold, so its slot is never used.
    down_since: [button_count]?u64 = [_]?u64{null} ** button_count,
    long_sent: [button_count]bool = [_]bool{false} ** button_count,
    /// detents since start, cw positive; reported with every rotary edge.
    position: i32 = 0,
    /// the last keycode that matched nothing, for the renderer to log; 0 = none.
    unmapped_code: u16 = 0,
    /// the last mapped key that went down, for the renderer's log (cleared when logged)
    last_press: ?struct { code: u16, control: Control } = null,
    /// a rotary value outside the known codes, for the renderer's log (cleared when logged)
    abs_unexpected: ?i32 = null,

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
                const i = @intFromEnum(control);
                if (down) {
                    self.down_since[i] = now_ns;
                    self.long_sent[i] = false;
                    return;
                }
                // a release the mapper never saw the press for is not a press: it is a button that
                // was already held when the runtime started, and acting on it would move the panel
                // for something the user did before this process existed.
                const pressed = self.down_since[i] != null;
                const was_long = self.long_sent[i];
                self.down_since[i] = null;
                // the short action belongs to a short press. a long one has already reported itself
                // as its own gesture, and firing both would leave a hold indistinguishable in
                // effect from a tap -- which is what made the long press useless before it existed.
                if (!pressed or was_long) return;
                _ = out.push(switch (control) {
                    .left => .left,
                    .middle => .middle,
                    .right => .right,
                    else => .knob_short,
                });
            },
            evdev.EV_ABS => {
                // the vendor's knob driver reports state codes on ABS_X, not a counter: one
                // detent is a pair of events, 8 then 1 turning clockwise and 13 then 11
                // counter-clockwise. the second value of each pair is the step; anything else is
                // remembered for the log. (the pairs were measured on 2026-09-09 but assigned to
                // the two directions by inference, the wrong way round; matt caught it on
                // 2026-09-11 when a clockwise turn walked the menu leftwards.)
                switch (ev.value) {
                    1 => self.step(true, out, edges),
                    11 => self.step(false, out, edges),
                    8, 13 => {},
                    else => self.abs_unexpected = ev.value,
                }
            },
            else => {},
        }
    }

    /// the action a hold on each button carries. the knob's opens the device menu, as it always
    /// has; the other three open the settings of the base they select, so the gesture a button has
    /// is the tap-then-hold pair for one scene rather than three unrelated things.
    fn longActionOf(control: Control) scene.Action {
        return switch (control) {
            .left => .left_long,
            .middle => .middle_long,
            .right => .right_long,
            else => .knob_long,
        };
    }

    /// called every loop iteration: any button held past the threshold yields one long press, once.
    pub fn poll(self: *Mapper, now_ns: u64, out: *ActionQueue, edges: *EdgeQueue) void {
        for (0..button_count) |i| {
            const since = self.down_since[i] orelse continue;
            if (self.long_sent[i] or now_ns - since < self.long_press_ns) continue;
            self.long_sent[i] = true;
            const control: Control = @enumFromInt(i);
            _ = out.push(longActionOf(control));
            edges.push(.{ .control = control, .event = .long, .position = self.position });
        }
    }

    /// a remote request: the same paths as physical input, so it produces the same actions and
    /// edges. `steps` applies to the rotary only.
    ///
    /// this takes an `InputRequest` rather than an `EdgeEvent` because `click` can be asked for and
    /// cannot happen: it goes out as a press and a release, which is what a click is.
    pub fn inject(self: *Mapper, control: Control, event: InputRequest, steps: u8, now_ns: u64, out: *ActionQueue, edges: *EdgeQueue) bool {
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
                if (control == .rotary) return false;
                self.feed(key(code, 1), now_ns, out, edges);
                self.long_sent[@intFromEnum(control)] = true;
                _ = out.push(longActionOf(control));
                edges.push(.{ .control = control, .event = .long, .position = self.position });
                self.feed(key(code, 0), now_ns, out, edges);
            },
            .cw, .ccw => {
                if (control != .rotary or steps == 0 or steps > max_steps) return false;
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
    m.feed(key(108, 1), 0, &q, &e);
    m.feed(key(108, 0), 1, &q, &e);
    m.feed(abs(13), 2, &q, &e);
    m.feed(abs(11), 2, &q, &e); // one counter-clockwise detent
    m.feed(abs(11), 3, &q, &e); // another, its first half lost
    m.feed(abs(8), 4, &q, &e);
    m.feed(abs(1), 4, &q, &e); // one clockwise detent
    m.feed(key(103, 1), 5, &q, &e);
    m.poll(1_000_000_000, &q, &e);
    m.feed(key(103, 0), 1_100_000_000, &q, &e);
    m.feed(key(999, 1), 6, &q, &e);
    const expected = [_]Edge{
        .{ .control = .left, .event = .press, .position = 0 },
        .{ .control = .left, .event = .release, .position = 0 },
        .{ .control = .rotary, .event = .ccw, .position = -1 },
        .{ .control = .rotary, .event = .ccw, .position = -2 },
        .{ .control = .rotary, .event = .cw, .position = -1 },
        .{ .control = .knob, .event = .press, .position = -1 },
        .{ .control = .knob, .event = .long, .position = -1 },
        .{ .control = .knob, .event = .release, .position = -1 },
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
    try std.testing.expect(!m.inject(.rotary, .long, 1, 0, &q, &e));
    try std.testing.expect(!m.inject(.rotary, .cw, 17, 0, &q, &e));
    try std.testing.expect(!m.inject(.left, .cw, 1, 0, &q, &e));
}

test "a click is a request and never an edge" {
    // nothing has ever pushed a click edge. the three buttons and the knob report press and
    // release, the knob adds long once it is held, and the rotary reports detents -- that is the
    // whole of what a control does. `click` sat in the reported vocabulary regardless, so a script
    // or an mqtt consumer could wait for one for ever and nothing would ever say why.
    //
    // it is a request: one press and one release asked for in a single call, which reports as
    // those two edges. so it belongs where it can be asked for and not where it can be awaited.
    try std.testing.expect(std.meta.stringToEnum(EdgeEvent, "click") == null);
    try std.testing.expect(std.meta.stringToEnum(InputRequest, "click") != null);

    // and asking for one produces exactly the two edges it is made of
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};
    try std.testing.expect(m.inject(.middle, .click, 1, 0, &q, &e));
    const both = [_]Edge{
        .{ .control = .middle, .event = .press, .position = 0 },
        .{ .control = .middle, .event = .release, .position = 0 },
    };
    try std.testing.expectEqualSlices(Edge, &both, e.slice());
}

const ms = std.time.ns_per_ms;
const s_ns = std.time.ns_per_s;

test "every button has a long press, and a hold is not also a tap" {
    // the knob has had one since the beginning and the other three had nothing: holding left was a
    // press that happened to take a while, so a script could not tell a hold from a tap and the
    // panel changed base either way. now the hold is its own gesture on all four.
    var m = Mapper.init(.{});
    var q = ActionQueue{};
    var e = EdgeQueue{};

    // a short press still selects the clock, because a tap is what that action is for
    m.feed(key(108, 1), 0, &q, &e);
    m.poll(100 * ms, &q, &e);
    m.feed(key(108, 0), 200 * ms, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.left}, q.slice());

    // held past the threshold it reports `long` once, however long it is held after that
    q.clear();
    e = .{};
    m.feed(key(108, 1), 1 * s_ns, &q, &e);
    m.poll(1 * s_ns + 600 * ms, &q, &e);
    try std.testing.expectEqual(@as(usize, 1), e.len); // the press; not yet long
    m.poll(1 * s_ns + 800 * ms, &q, &e);
    m.poll(1 * s_ns + 900 * ms, &q, &e);
    m.poll(3 * s_ns, &q, &e);
    m.feed(key(108, 0), 4 * s_ns, &q, &e);
    const held = [_]Edge{
        .{ .control = .left, .event = .press, .position = 0 },
        .{ .control = .left, .event = .long, .position = 0 },
        .{ .control = .left, .event = .release, .position = 0 },
    };
    try std.testing.expectEqualSlices(Edge, &held, e.slice());
    // the hold carries its own action and not the tap's: holding left opens the clock's settings,
    // it does not also select the clock the way a tap does
    try std.testing.expectEqualSlices(scene.Action, &.{.left_long}, q.slice());

    // the knob keeps its own action, which is the device menu
    q.clear();
    e = .{};
    m.feed(key(103, 1), 5 * s_ns, &q, &e);
    m.poll(6 * s_ns, &q, &e);
    m.feed(key(103, 0), 7 * s_ns, &q, &e);
    try std.testing.expectEqualSlices(scene.Action, &.{.knob_long}, q.slice());

    // a release the mapper never saw the press for is not a press
    q.clear();
    e = .{};
    m.feed(key(106, 0), 8 * s_ns, &q, &e);
    try std.testing.expectEqual(@as(usize, 0), q.len);
}


test "both input vocabularies are contiguous, and neither leaves room for the other" {
    // each is its own wire encoding -- `input` carries an EdgeEvent and `inject_input` an
    // InputRequest -- so they are pinned separately and neither needs a hole in it.
    inline for (@typeInfo(EdgeEvent).@"enum".fields, 0..) |f, i| {
        try std.testing.expectEqual(i, f.value);
    }
    inline for (@typeInfo(InputRequest).@"enum".fields, 0..) |f, i| {
        try std.testing.expectEqual(i, f.value);
    }
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EdgeEvent.long));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(InputRequest.click));
}
