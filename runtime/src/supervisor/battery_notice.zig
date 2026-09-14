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

/// the reading this and the shutdown policy share
pub const Reading = power.Reading;

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
/// how long the charge takes to fill in when a notice appears. long enough to read as movement,
/// short enough that the reading is settled well inside the four seconds the notice stands.
pub const fill_ns: u64 = 700 * std.time.ns_per_ms;
/// and how long the plug takes to arrive once it starts
pub const plug_fade_ns: u64 = 350 * std.time.ns_per_ms;

/// the ease on the fill. smoothstep: flat at both ends, quickest in the middle, and nothing in it
/// but multiplication -- there is no libm on this device, so anything with a sine in it would not
/// link.
fn smoothstep(t: f32) f32 {
    const c = std.math.clamp(t, 0.0, 1.0);
    return c * c * (3.0 - 2.0 * c);
}

/// what fired, so the log line can say why the panel lit up
pub const Trigger = enum { unplugged, plugged_in, below_50, below_20, below_5 };

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
    /// the charge the showing notice was raised at, so the picture does not change under the viewer
    showing_pct: u8 = pct_unknown,
    /// whether the showing notice is the one that says power came back
    charging: bool = false,
    /// when the plug began to arrive, latched the first time the fill reaches the midpoint or the
    /// fill finishes -- whichever comes first, which for a cell under half full is the finish
    plug_from_ns: u64 = 0,

    /// feed it a reading; it answers with the trigger that fired, if one did.
    pub fn update(self: *Notices, r: power.Reading, pct: u8, now_ns: u64) ?Trigger {
        // the same rule as the shutdown policy: a reading the mcu has not confirmed recently is
        // not a reading. a stale one would flash the panel at a charge that may be hours old.
        if (!r.fresh or pct == pct_unknown) return null;

        const was_usb = self.last_usb;
        const was_pct = self.last_pct;
        self.last_usb = r.usb;
        self.last_pct = pct;

        // power coming back is worth a picture of its own. it replaces whatever warning was up,
        // which is better than merely clearing it: the question the warning asked is answered.
        if (r.usb == 1) {
            if (was_usb == 0) {
                self.started_ns = now_ns;
                self.until_ns = now_ns + show_ns;
                self.showing_pct = pct;
                self.charging = true;
                self.plug_from_ns = 0;
                return .plugged_in;
            }
            return null;
        }
        if (r.usb != 0) return null; // unknown: say nothing rather than guess

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
            self.charging = false;
            self.plug_from_ns = 0;
            return t;
        }
        return null;
    }

    pub fn active(self: *const Notices, now_ns: u64) bool {
        return now_ns < self.until_ns;
    }

    /// the blink phase. a notice that does not blink is simply always visible.
    ///
    /// a charging notice never blinks, however flat the cell is: the alarm has been answered, and
    /// flashing red at someone who has just plugged the clock in is telling them off for fixing it.
    pub fn visible(self: *const Notices, now_ns: u64) bool {
        if (!self.active(now_ns)) return false;
        if (self.charging or !styleFor(self.showing_pct).blink) return true;
        // let the fill finish before any blinking starts: a bar that is growing and flashing at
        // the same time reads as a fault rather than a measurement
        const since = now_ns -| self.started_ns;
        if (since < fill_ns) return true;
        const half = (since - fill_ns) / blink_half_ns;
        return half % 2 == 0;
    }

    /// the charge to draw *now*: eased from nothing up to the real reading over `fill_ns`, so the
    /// bar arrives rather than appearing. every notice animates -- each one is the icon being shown
    /// afresh, which is the moment worth drawing.
    pub fn fillNow(self: *const Notices, now_ns: u64) u8 {
        const since = now_ns -| self.started_ns;
        if (since >= fill_ns) return self.showing_pct;
        const t = @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(fill_ns));
        const grown = smoothstep(t) * @as(f32, @floatFromInt(self.showing_pct));
        return @intFromFloat(grown);
    }

    /// how far in the plug is, 0 to 255.
    ///
    /// it starts the moment the growing bar passes the midpoint of the battery, or when the bar
    /// stops growing, whichever comes first -- for a cell under half full the bar never reaches the
    /// midpoint, so the end of the fill is what releases it. latched on first sight rather than
    /// solved for: the panel is redrawn ten times a second and smoothstep has no cheap inverse.
    pub fn plugAlpha(self: *Notices, now_ns: u64) u8 {
        if (!self.charging) return 0;
        if (self.plug_from_ns == 0) {
            const reached_midpoint = self.fillNow(now_ns) >= green_above;
            const fill_done = now_ns -| self.started_ns >= fill_ns;
            if (!reached_midpoint and !fill_done) return 0;
            self.plug_from_ns = now_ns;
        }
        const since = now_ns -| self.plug_from_ns;
        if (since >= plug_fade_ns) return 255;
        return @intCast((since * 255) / plug_fade_ns);
    }

    pub fn style(self: *const Notices) Style {
        return styleFor(self.showing_pct);
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
    // the phase is measured from the end of the fill, not from the start of the notice
    const from = 1 * s_ns + fill_ns;
    try testing.expect(n.visible(from)); // on
    try testing.expect(!n.visible(from + blink_half_ns)); // off
    try testing.expect(n.visible(from + 2 * blink_half_ns)); // on again
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

test "plugging back in replaces the warning rather than merely clearing it" {
    var n = Notices{};
    _ = n.update(onCell(), 60, 0);
    try testing.expectEqual(Trigger.below_20, n.update(onCell(), 10, 1 * s_ns).?); // past both
    try testing.expect(n.active(2 * s_ns));
    try testing.expect(!n.charging);

    // the question the warning asked is answered, so the answer is what goes on the panel
    try testing.expectEqual(Trigger.plugged_in, n.update(plugged(), 10, 2 * s_ns).?);
    try testing.expect(n.charging);
    try testing.expect(n.active(3 * s_ns));
    // and the fill starts again from nothing, because this is a new thing being said
    try testing.expectEqual(@as(u8, 0), n.fillNow(2 * s_ns));
}

test "the charge grows in rather than appearing, and settles on the real reading" {
    var n = Notices{};
    _ = n.update(plugged(), 80, 0);
    _ = n.update(onCell(), 80, 1 * s_ns);
    const t0 = 1 * s_ns;

    try testing.expectEqual(@as(u8, 0), n.fillNow(t0)); // nothing at the start
    // smoothstep is flat at both ends, so the first tenth has barely moved and the middle is quick
    const tenth = n.fillNow(t0 + fill_ns / 10);
    const half = n.fillNow(t0 + fill_ns / 2);
    const most = n.fillNow(t0 + fill_ns * 9 / 10);
    try testing.expect(tenth < 5);
    try testing.expectEqual(@as(u8, 40), half); // exactly half the reading at the midpoint
    try testing.expect(most > 74 and most < 80);
    try testing.expect(tenth < half and half < most);

    try testing.expectEqual(@as(u8, 80), n.fillNow(t0 + fill_ns)); // and it lands on the truth
    try testing.expectEqual(@as(u8, 80), n.fillNow(t0 + 2 * fill_ns));
}

test "the plug waits for the bar to pass the midpoint, then fades" {
    var n = Notices{};
    _ = n.update(onCell(), 90, 0);
    _ = n.update(plugged(), 90, 1 * s_ns); // power back at 90%
    const t0 = 1 * s_ns;
    try testing.expect(n.charging);

    try testing.expectEqual(@as(u8, 0), n.plugAlpha(t0)); // the bar has not reached halfway
    try testing.expectEqual(@as(u8, 0), n.plugAlpha(t0 + fill_ns / 4));

    // find the instant the plug is released rather than guessing it: smoothstep is symmetric in
    // time but the battery is not -- at 90% the bar crosses the midpoint a little after the
    // halfway mark, and the rule is about the bar's position, not the clock's.
    var released: u64 = 0;
    var t: u64 = t0;
    while (t <= t0 + fill_ns) : (t += 5 * std.time.ns_per_ms) {
        if (n.plugAlpha(t) > 0) {
            released = t;
            break;
        }
    }
    try testing.expect(released > t0 + fill_ns / 2); // after halfway in time
    try testing.expect(released < t0 + fill_ns); // but before the bar stops growing
    try testing.expect(n.fillNow(released) >= green_above); // and the bar really had passed it

    try testing.expect(n.plugAlpha(released + plug_fade_ns / 2) > 100);
    try testing.expectEqual(@as(u8, 255), n.plugAlpha(released + plug_fade_ns));
}

test "a cell under half full releases the plug when the bar stops, not at the midpoint" {
    var n = Notices{};
    _ = n.update(onCell(), 30, 0);
    _ = n.update(plugged(), 30, 1 * s_ns);
    const t0 = 1 * s_ns;

    // the bar never reaches the midpoint of the battery, so nothing can be released by it
    try testing.expect(n.fillNow(t0 + fill_ns) < green_above);
    try testing.expectEqual(@as(u8, 0), n.plugAlpha(t0 + fill_ns / 2));
    try testing.expectEqual(@as(u8, 0), n.plugAlpha(t0 + fill_ns - 1));
    // the end of the fill is what lets it in
    try testing.expectEqual(@as(u8, 0), n.plugAlpha(t0 + fill_ns));
    try testing.expectEqual(@as(u8, 255), n.plugAlpha(t0 + fill_ns + plug_fade_ns));
}

test "a discharging notice never grows a plug, however long it is watched" {
    var n = Notices{};
    _ = n.update(plugged(), 90, 0);
    _ = n.update(onCell(), 90, 1 * s_ns);
    var i: u64 = 0;
    while (i < 40) : (i += 1) {
        try testing.expectEqual(@as(u8, 0), n.plugAlpha(1 * s_ns + i * 100 * std.time.ns_per_ms));
    }
}

test "blinking waits for the fill, so a growing bar is never also a flashing one" {
    var n = Notices{};
    _ = n.update(onCell(), 50, 0);
    _ = n.update(onCell(), 3, 1 * s_ns); // under five percent: this one blinks
    const t0 = 1 * s_ns;
    try testing.expect(styleFor(3).blink);
    // solid while it grows
    try testing.expect(n.visible(t0));
    try testing.expect(n.visible(t0 + fill_ns / 2));
    try testing.expect(n.visible(t0 + fill_ns - 1));
    // and only then does it start flashing
    try testing.expect(n.visible(t0 + fill_ns));
    try testing.expect(!n.visible(t0 + fill_ns + blink_half_ns));
    try testing.expect(n.visible(t0 + fill_ns + 2 * blink_half_ns));
}
