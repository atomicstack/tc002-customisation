//! the battery notice: a coloured icon on the panel when the cell is worth mentioning.
//!
//! pure, like `power.zig` beside it, and for the same reason -- the interesting part is *when* to
//! say something and *what* it should look like, and neither of those needs a panel to decide.
//! the supervisor draws the icon and pushes it; this says which icon, what colour, and for how
//! long.
//!
//! it fires on three kinds of moment, all of them only while the device is actually running on its
//! cell: the cable coming out, and the charge falling through a threshold on the way down. rising
//! back through a threshold says nothing -- a clock that flashed at you while it was charging
//! would be noise.
const std = @import("std");
const power = @import("power.zig");

pub const pct_unknown: u8 = 255;

/// the bands. "green over 50, yellow down to 20, red below that, and red blinking under 5."
pub const green_above: u8 = 50;
pub const yellow_above: u8 = 20;
pub const blink_below: u8 = 5;

pub const green: [3]u8 = .{ 0x22, 0xcc, 0x44 };
pub const yellow: [3]u8 = .{ 0xff, 0xcc, 0x22 };
pub const red: [3]u8 = .{ 0xff, 0x33, 0x22 };

/// how long a notice stands. long enough to look up at, short enough not to be in the way.
pub const show_ns: u64 = 4 * std.time.ns_per_s;
/// half a blink: on for this long, then off for this long
pub const blink_half_ns: u64 = 400 * std.time.ns_per_ms;

/// what fired, so the log line can say why the panel lit up
pub const Trigger = enum { unplugged, below_50, below_20, below_5 };

pub const Style = struct {
    /// a name from `scene/icons.zig`; the glyph is monochrome and takes `colour`
    icon: []const u8,
    colour: [3]u8,
    blink: bool,
};

/// the icon follows the same bands as the colour, so the glyph and the tint never disagree
pub fn styleFor(pct: u8) Style {
    if (pct > green_above) return .{ .icon = "battery-full", .colour = green, .blink = false };
    if (pct >= yellow_above) return .{ .icon = "battery-half", .colour = yellow, .blink = false };
    if (pct >= blink_below) return .{ .icon = "battery-low", .colour = red, .blink = false };
    return .{ .icon = "battery-empty", .colour = red, .blink = true };
}

pub const Notices = struct {
    last_usb: u8 = power.usb_unknown,
    last_pct: u8 = pct_unknown,
    started_ns: u64 = 0,
    until_ns: u64 = 0,
    /// the charge the showing notice was raised at, so the icon does not change under the viewer
    showing_pct: u8 = pct_unknown,

    /// feed it a reading; it answers with the trigger that fired, if one did.
    pub fn update(self: *Notices, r: power.Reading, pct: u8, now_ns: u64) ?Trigger {
        // the same rule as the shutdown policy: a reading the mcu has not confirmed recently is
        // not a reading. a stale one would flash the panel at a charge that may be hours old.
        if (!r.fresh or pct == pct_unknown) return null;

        const was_usb = self.last_usb;
        const was_pct = self.last_pct;
        self.last_usb = r.usb;
        self.last_pct = pct;

        // on the charger there is nothing to warn about, and climbing back through a threshold is
        // good news rather than news
        if (r.usb != 0) return null;

        const trigger: ?Trigger = blk: {
            // the lowest threshold crossed wins: falling past two at once is the more urgent one
            if (was_pct != pct_unknown) {
                if (was_pct >= blink_below and pct < blink_below) break :blk .below_5;
                if (was_pct >= yellow_above and pct < yellow_above) break :blk .below_20;
                if (was_pct >= green_above and pct < green_above) break :blk .below_50;
            }
            if (was_usb == 1) break :blk .unplugged;
            break :blk null;
        };

        if (trigger) |t| {
            self.started_ns = now_ns;
            self.until_ns = now_ns + show_ns;
            self.showing_pct = pct;
            return t;
        }
        return null;
    }

    pub fn active(self: *const Notices, now_ns: u64) bool {
        return now_ns < self.until_ns;
    }

    /// the blink phase. a notice that does not blink is simply always visible.
    pub fn visible(self: *const Notices, now_ns: u64) bool {
        if (!self.active(now_ns)) return false;
        if (!styleFor(self.showing_pct).blink) return true;
        const half = (now_ns -| self.started_ns) / blink_half_ns;
        return half % 2 == 0;
    }

    pub fn style(self: *const Notices) Style {
        return styleFor(self.showing_pct);
    }

    /// stop showing, without waiting the notice out: the cable going back in answers the question
    pub fn clear(self: *Notices) void {
        self.until_ns = 0;
        self.started_ns = 0;
    }
};

// -- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s_ns = std.time.ns_per_s;

fn onCell() power.Reading {
    return .{ .millivolts = 3900, .usb = 0, .fresh = true };
}
fn plugged() power.Reading {
    return .{ .millivolts = 3900, .usb = 1, .fresh = true };
}

test "the bands are the ones asked for, boundaries included" {
    try testing.expectEqualStrings("battery-full", styleFor(100).icon);
    try testing.expectEqual(green, styleFor(100).colour);
    try testing.expectEqual(green, styleFor(51).colour);
    // "green when over 50" -- fifty itself is already yellow
    try testing.expectEqual(yellow, styleFor(50).colour);
    try testing.expectEqual(yellow, styleFor(20).colour);
    try testing.expectEqual(red, styleFor(19).colour);
    try testing.expectEqual(red, styleFor(5).colour);
    try testing.expect(!styleFor(5).blink);
    // "less than 5%" blinks
    try testing.expect(styleFor(4).blink);
    try testing.expectEqualStrings("battery-empty", styleFor(4).icon);
    try testing.expectEqualStrings("battery-low", styleFor(6).icon);
    try testing.expectEqualStrings("battery-half", styleFor(30).icon);
}

test "pulling the cable shows the icon for a few seconds" {
    var n = Notices{};
    try testing.expect(n.update(plugged(), 80, 0) == null); // charging: nothing to say
    try testing.expectEqual(Trigger.unplugged, n.update(onCell(), 80, 1 * s_ns).?);
    try testing.expect(n.active(1 * s_ns));
    try testing.expect(n.visible(1 * s_ns));
    try testing.expectEqual(green, n.style().colour);

    try testing.expect(n.active(4 * s_ns));
    try testing.expect(!n.active(6 * s_ns)); // four seconds and it is gone
    // and it does not fire again just for still being unplugged
    try testing.expect(n.update(onCell(), 80, 7 * s_ns) == null);
}

test "falling through a threshold flashes; climbing back through one says nothing" {
    var n = Notices{};
    _ = n.update(onCell(), 60, 0);
    try testing.expect(n.update(onCell(), 55, 1 * s_ns) == null); // still above fifty
    try testing.expectEqual(Trigger.below_50, n.update(onCell(), 49, 2 * s_ns).?);
    try testing.expectEqual(yellow, n.style().colour);

    try testing.expectEqual(Trigger.below_20, n.update(onCell(), 19, 10 * s_ns).?);
    try testing.expectEqual(red, n.style().colour);
    try testing.expect(!n.style().blink);

    try testing.expectEqual(Trigger.below_5, n.update(onCell(), 4, 20 * s_ns).?);
    try testing.expect(n.style().blink);

    // charging back up through every one of them is good news, not news
    var up = Notices{};
    _ = up.update(plugged(), 3, 0);
    try testing.expect(up.update(plugged(), 25, 1 * s_ns) == null);
    try testing.expect(up.update(plugged(), 60, 2 * s_ns) == null);
    try testing.expect(!up.active(2 * s_ns));
}

test "falling past two thresholds at once reports the more urgent one" {
    // the mcu is polled every thirty seconds, so a charge can drop past a threshold and the one
    // below it between two readings
    var n = Notices{};
    _ = n.update(onCell(), 60, 0);
    try testing.expectEqual(Trigger.below_20, n.update(onCell(), 15, 1 * s_ns).?);

    var m = Notices{};
    _ = m.update(onCell(), 60, 0);
    try testing.expectEqual(Trigger.below_5, m.update(onCell(), 2, 1 * s_ns).?);
}

test "under five percent it blinks, and the phase alternates" {
    var n = Notices{};
    _ = n.update(onCell(), 50, 0);
    _ = n.update(onCell(), 3, 1 * s_ns);
    try testing.expect(n.style().blink);
    try testing.expect(n.visible(1 * s_ns)); // on
    try testing.expect(!n.visible(1 * s_ns + blink_half_ns)); // off
    try testing.expect(n.visible(1 * s_ns + 2 * blink_half_ns)); // on again
    // and blinking stops when the notice does, rather than going on for ever
    try testing.expect(!n.visible(1 * s_ns + show_ns + 1));
}

test "a reading the mcu has not confirmed is not a reading" {
    var n = Notices{};
    const stale = power.Reading{ .millivolts = 3900, .usb = 0, .fresh = false };
    try testing.expect(n.update(stale, 60, 0) == null);
    try testing.expect(n.update(stale, 10, 1 * s_ns) == null);
    try testing.expect(!n.active(1 * s_ns));

    // nor is a charge the mcu never gave us, and it must not be mistaken for a crossing later
    var m = Notices{};
    _ = m.update(onCell(), 60, 0);
    try testing.expect(m.update(onCell(), pct_unknown, 1 * s_ns) == null);
    try testing.expectEqual(Trigger.below_50, m.update(onCell(), 40, 2 * s_ns).?);
}

test "plugging back in clears a notice that is still showing" {
    var n = Notices{};
    _ = n.update(onCell(), 60, 0);
    _ = n.update(onCell(), 10, 1 * s_ns);
    try testing.expect(n.active(2 * s_ns));
    n.clear();
    try testing.expect(!n.active(2 * s_ns));
    try testing.expect(!n.visible(2 * s_ns));
}
