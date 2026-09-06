//! the physical maintenance gesture: the knob held for three seconds grants fifteen monotonic
//! minutes of adb; a repeat during the grant extends it; expiry revokes. the supervisor owns the
//! deadline even if a child fails. pure state machine.
const std = @import("std");

const s_ns = std.time.ns_per_s;
const min_ns = 60 * s_ns;

test "a three-second hold grants once; the grant expires after fifteen minutes" {
    var g = Gesture{};
    g.onKey(true, 0);
    try std.testing.expectEqual(Directive.none, g.poll(2 * s_ns + 999_000_000));
    try std.testing.expectEqual(Directive.grant, g.poll(3 * s_ns));
    try std.testing.expect(g.active(3 * s_ns));
    try std.testing.expectEqual(Directive.none, g.poll(3 * s_ns + 100_000_000));
    g.onKey(false, 4 * s_ns);
    try std.testing.expectEqual(Directive.none, g.poll(15 * min_ns + 3 * s_ns - 1));
    try std.testing.expectEqual(Directive.revoke, g.poll(15 * min_ns + 3 * s_ns));
    try std.testing.expect(!g.active(15 * min_ns + 3 * s_ns));
    try std.testing.expectEqual(Directive.none, g.poll(20 * min_ns));
}

test "a second hold during a grant extends it" {
    var g = Gesture{};
    g.onKey(true, 0);
    try std.testing.expectEqual(Directive.grant, g.poll(3 * s_ns));
    g.onKey(false, 4 * s_ns);
    g.onKey(true, 100 * s_ns);
    try std.testing.expectEqual(Directive.grant, g.poll(103 * s_ns));
    g.onKey(false, 104 * s_ns);
    try std.testing.expectEqual(Directive.none, g.poll(15 * min_ns + 3 * s_ns));
    try std.testing.expectEqual(Directive.revoke, g.poll(15 * min_ns + 103 * s_ns));
}

test "a short tap and a key that was already held at startup are handled" {
    var g = Gesture{};
    g.onKey(true, 0);
    g.onKey(false, 1 * s_ns);
    try std.testing.expectEqual(Directive.none, g.poll(5 * s_ns));
    var held = Gesture{};
    held.onKey(true, 10 * s_ns); // reported by EVIOCGKEY at startup
    try std.testing.expectEqual(Directive.grant, held.poll(13 * s_ns));
}

pub const Directive = enum { none, grant, revoke };

pub const Gesture = struct {
    hold_ns: u64 = 3 * s_ns,
    grant_ns: u64 = 15 * min_ns,
    pressed_since: ?u64 = null,
    recognised: bool = false,
    granted_until: ?u64 = null,

    pub fn onKey(self: *Gesture, down: bool, now_ns: u64) void {
        if (down) {
            if (self.pressed_since == null) {
                self.pressed_since = now_ns;
                self.recognised = false;
            }
        } else {
            self.pressed_since = null;
        }
    }

    pub fn active(self: *const Gesture, now_ns: u64) bool {
        return if (self.granted_until) |u| now_ns < u else false;
    }

    pub fn poll(self: *Gesture, now_ns: u64) Directive {
        if (self.pressed_since) |since| {
            if (!self.recognised and now_ns - since >= self.hold_ns) {
                self.recognised = true;
                self.granted_until = now_ns + self.grant_ns;
                return .grant;
            }
        }
        if (self.granted_until) |until| {
            if (now_ns >= until) {
                self.granted_until = null;
                return .revoke;
            }
        }
        return .none;
    }
};
