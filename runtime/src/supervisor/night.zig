//! the night brightness schedule: what the panel should be showing at this instant, given where it
//! is and what the sun is doing there. pure.
//!
//! the day is a polyline through four anchors. dimming starts a lead time before sunset and is
//! finished by civil dusk; brightening starts at civil dawn and is finished a lead time after
//! sunrise. between the anchors the brightness is interpolated, so the panel follows the sky down
//! and back up rather than stepping. the two ends mirror each other, which is why the lead sits
//! before sunset in the evening and after sunrise in the morning.
//!
//! a brightness set by hand suppresses the schedule until the next ramp begins: turn it up at
//! midnight and it stays up until dawn, turn it down in the afternoon and the evening ramp takes
//! it from there.
const std = @import("std");
const solar = @import("../sys/solar.zig");
const sntp = @import("sntp.zig");

pub const Settings = struct {
    enabled: bool = false,
    /// the settings' own brightness, which is what daylight means
    day: u8 = 100,
    night: u8 = 10,
    /// how long before sunset the dimming starts, and how long after sunrise it finishes
    lead_s: u32 = 20 * 60,
};

pub const Phase = enum {
    day,
    to_night,
    night,
    to_day,

    pub fn text(self: Phase) []const u8 {
        return switch (self) {
            .day => "day",
            .to_night => "to_night",
            .night => "night",
            .to_day => "to_day",
        };
    }
};

pub const Plan = struct {
    phase: Phase,
    brightness: u8,
    /// when the next ramp begins, which is how long a hand-set brightness holds for
    next_ramp_at: ?i64 = null,
};

/// a wall clock below this has not been set: the runtime starts at the 1970 epoch and stays there
/// until sntp answers, and a schedule run against 1970 would dim at the wrong time of day.
pub const clock_set_floor = sntp.build_reference_unix_s;

const day_anchors = 4;
const days = 3; // yesterday, today and tomorrow, so every instant is bracketed

const Anchor = struct { at: i64, level: u8 };

pub const Schedule = struct {
    settings: Settings = .{},
    /// where the device is: from the timezone's own reference point, or set by hand
    point: ?solar.Point = null,
    /// a hand-set brightness stands until this instant
    override_until: ?i64 = null,

    /// what the schedule wants on the panel now; null when it has nothing to say, because it is
    /// off, has no location, the clock has not been set, or a hand-set brightness still stands.
    pub fn target(self: *Schedule, now_unix: i64) ?u8 {
        const p = self.plan(now_unix) orelse return null;
        if (self.override_until) |until| {
            if (now_unix < until) return null;
            self.override_until = null;
        }
        return p.brightness;
    }

    /// a brightness arrived from somewhere else (the knob, the api, mqtt): stand aside until the
    /// next ramp begins. with no next ramp to wait for the schedule simply resumes.
    pub fn hold(self: *Schedule, now_unix: i64) void {
        const p = self.plan(now_unix) orelse return;
        self.override_until = p.next_ramp_at;
    }

    /// the whole picture, for the api and the logs: null when the schedule is not running.
    pub fn plan(self: *const Schedule, now_unix: i64) ?Plan {
        if (!self.settings.enabled) return null;
        if (now_unix < clock_set_floor) return null;
        const point = self.point orelse return null;

        var buf: [days * day_anchors]Anchor = undefined;
        var n: usize = 0;
        var polar_level: ?u8 = null;
        const today = @divFloor(now_unix, 86400);
        for (0..days) |i| {
            const d = solar.day((today - 1 + @as(i64, @intCast(i))) * 86400 + 43200, point);
            const dawn = d.dawn orelse {
                if (i == 1) polar_level = if (d.sun_up) self.settings.day else self.settings.night;
                continue;
            };
            const sunrise = d.sunrise orelse {
                if (i == 1) polar_level = if (d.sun_up) self.settings.day else self.settings.night;
                continue;
            };
            const sunset = d.sunset.?;
            const dusk = d.dusk.?;
            const lead: i64 = self.settings.lead_s;
            var up_at = sunrise + lead;
            var down_at = sunset - lead;
            if (up_at > down_at) { // a day too short to reach full brightness: peak at solar noon
                up_at = @divFloor(up_at + down_at, 2);
                down_at = up_at;
            }
            buf[n] = .{ .at = dawn, .level = self.settings.night };
            buf[n + 1] = .{ .at = up_at, .level = self.settings.day };
            buf[n + 2] = .{ .at = down_at, .level = self.settings.day };
            buf[n + 3] = .{ .at = dusk, .level = self.settings.night };
            n += day_anchors;
        }
        const anchors = buf[0..n];
        if (anchors.len == 0) return .{
            // the sun did not cross the horizon at all today: hold whichever level it implies
            .phase = if (polar_level == self.settings.day) .day else .night,
            .brightness = polar_level orelse self.settings.night,
        };

        const level = self.levelAt(anchors, now_unix);
        return .{ .phase = level.phase, .brightness = level.brightness, .next_ramp_at = nextRamp(anchors, now_unix) };
    }

    fn levelAt(self: *const Schedule, anchors: []const Anchor, now_unix: i64) struct { phase: Phase, brightness: u8 } {
        if (now_unix <= anchors[0].at) return .{ .phase = settled(anchors[0].level, self.settings), .brightness = anchors[0].level };
        const last = anchors[anchors.len - 1];
        if (now_unix >= last.at) return .{ .phase = settled(last.level, self.settings), .brightness = last.level };
        for (anchors[0 .. anchors.len - 1], anchors[1..]) |a, b| {
            if (now_unix < a.at or now_unix >= b.at) continue;
            if (a.level == b.level) return .{ .phase = settled(a.level, self.settings), .brightness = a.level };
            const span = b.at - a.at;
            const gone = now_unix - a.at;
            const from: i64 = a.level;
            const to: i64 = b.level;
            const value = from + @divTrunc((to - from) * gone * 2 + @as(i64, if (to > from) span else -span), span * 2);
            return .{
                .phase = if (to < from) .to_night else .to_day,
                .brightness = @intCast(std.math.clamp(value, 1, 100)),
            };
        }
        unreachable;
    }

    fn settled(level: u8, s: Settings) Phase {
        return if (level == s.day) .day else .night;
    }

    /// the start of the next ramp after `now`: the anchor that begins a change of level.
    fn nextRamp(anchors: []const Anchor, now_unix: i64) ?i64 {
        for (anchors[0 .. anchors.len - 1], anchors[1..]) |a, b| {
            if (a.at > now_unix and a.level != b.level) return a.at;
        }
        return null;
    }
};

const sydney = solar.Point{ .lat_c = -3387, .lon_c = 15122 };

/// the solar day of 2026-09-11 in sydney, straight from the calculator the schedule uses, so these
/// tests are about the ramp rather than about the astronomy (which solar.zig tests on its own)
const spring = solar.day(20707 * 86400 + 43200, sydney);
const test_lead = 20 * 60;

fn schedule() Schedule {
    return .{ .settings = .{ .enabled = true, .day = 50, .night = 10, .lead_s = test_lead }, .point = sydney };
}

test "the evening ramp starts before sunset and finishes at dusk" {
    var s = schedule();
    const start = spring.sunset.? - test_lead;
    const end = spring.dusk.?;
    try std.testing.expectEqual(@as(u8, 50), s.plan(start - 60).?.brightness);
    try std.testing.expectEqual(Phase.day, s.plan(start - 60).?.phase);
    try std.testing.expectEqual(@as(u8, 50), s.plan(start).?.brightness);
    try std.testing.expectEqual(@as(u8, 10), s.plan(end).?.brightness);
    try std.testing.expectEqual(@as(u8, 10), s.plan(end + 3600).?.brightness);
    try std.testing.expectEqual(Phase.night, s.plan(end + 3600).?.phase);

    // halfway through the window is halfway between the two levels
    const halfway = s.plan(@divFloor(start + end, 2)).?;
    try std.testing.expectEqual(Phase.to_night, halfway.phase);
    try std.testing.expectEqual(@as(u8, 30), halfway.brightness);
    // and it only ever falls
    var t: i64 = start;
    var previous: u8 = 50;
    while (t <= end) : (t += 30) {
        const b = s.plan(t).?.brightness;
        try std.testing.expect(b <= previous);
        previous = b;
    }
    try std.testing.expectEqual(@as(u8, 10), previous);
}

test "the morning ramp is the mirror of it: dawn to sunrise plus the lead" {
    var s = schedule();
    const dawn = spring.dawn.?;
    const up = spring.sunrise.? + test_lead;
    try std.testing.expectEqual(@as(u8, 10), s.plan(dawn - 60).?.brightness);
    try std.testing.expectEqual(@as(u8, 10), s.plan(dawn).?.brightness);
    try std.testing.expectEqual(Phase.to_day, s.plan(dawn + 60).?.phase);
    try std.testing.expectEqual(@as(u8, 50), s.plan(up).?.brightness);
    try std.testing.expectEqual(Phase.day, s.plan(up + 60).?.phase);
    // the two ramps last the same length of time, being the same distances either side
    const morning = up - dawn;
    const evening = spring.dusk.? - (spring.sunset.? - test_lead);
    try std.testing.expect(@abs(morning - evening) < 60);
}

test "a hand-set brightness holds until the next ramp begins" {
    var s = schedule();
    // turned up in the middle of the night: the schedule says nothing until dawn
    const midnight = spring.dusk.? + 4 * 3600;
    const tomorrow = solar.day(20708 * 86400 + 43200, sydney);
    s.hold(midnight);
    try std.testing.expectEqual(tomorrow.dawn.?, s.override_until.?);
    try std.testing.expect(s.target(midnight) == null);
    try std.testing.expect(s.target(midnight + 3 * 3600) == null);
    try std.testing.expectEqual(@as(u8, 10), s.target(s.override_until.? + 1).?);
    try std.testing.expect(s.override_until == null); // and it is spent

    // turned down during the day: the evening ramp takes over
    var d = schedule();
    const afternoon = spring.sunset.? - 3 * 3600;
    d.hold(afternoon);
    try std.testing.expectEqual(spring.sunset.? - test_lead, d.override_until.?);
    try std.testing.expect(d.target(afternoon + 3600) == null);
    try std.testing.expectEqual(@as(u8, 50), d.target(spring.sunset.? - test_lead).?);
}

test "the schedule says nothing when it is off, unplaced, or the clock has not been set" {
    var off = schedule();
    off.settings.enabled = false;
    try std.testing.expect(off.target(spring.sunset.?) == null);

    var unplaced = schedule();
    unplaced.point = null;
    try std.testing.expect(unplaced.target(spring.sunset.?) == null);

    var cold = schedule();
    try std.testing.expect(cold.target(60) == null); // 1970, before sntp has answered
    try std.testing.expect(cold.target(clock_set_floor - 1) == null);
    try std.testing.expect(cold.target(clock_set_floor + 86400) != null);
}

test "a polar day holds daylight and a polar night holds the night level" {
    const tromso = solar.Point{ .lat_c = 6965, .lon_c = 1896 };
    var s = Schedule{ .settings = .{ .enabled = true, .day = 60, .night = 5 }, .point = tromso };
    const midsummer = 20990 * 86400 + 43200; // 2027-06-21
    try std.testing.expectEqual(@as(u8, 60), s.plan(midsummer).?.brightness);
    try std.testing.expectEqual(Phase.day, s.plan(midsummer).?.phase);
    const midwinter = 21173 * 86400 + 43200; // 2027-12-21
    try std.testing.expectEqual(@as(u8, 5), s.plan(midwinter).?.brightness);
    try std.testing.expectEqual(Phase.night, s.plan(midwinter).?.phase);
    // the polar night has no ramp to wait for, so a hand-set brightness is not held at all
    s.hold(midwinter);
    try std.testing.expect(s.override_until == null);
    try std.testing.expectEqual(@as(u8, 5), s.target(midwinter).?);
}

test "every brightness on the way through a year is between the two levels" {
    var s = schedule();
    var t: i64 = 1788220800; // 2026-09-01
    while (t < 1788220800 + 365 * 86400) : (t += 137) {
        const b = s.plan(t).?.brightness;
        try std.testing.expect(b >= 10 and b <= 50);
    }
    // a day at 70 degrees north, where the ramps meet and the panel never reaches full daylight
    var arctic = Schedule{ .settings = .{ .enabled = true, .day = 50, .night = 10, .lead_s = 3 * 3600 }, .point = .{ .lat_c = 7000, .lon_c = 0 } };
    t = 20790 * 86400; // early december: under four hours of civil daylight
    while (t < 20790 * 86400 + 86400) : (t += 137) {
        const b = arctic.plan(t).?.brightness;
        try std.testing.expect(b >= 10 and b <= 50);
    }
}
