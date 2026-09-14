//! when a device running on its own cell should put itself away.
//!
//! pure: the supervisor feeds it a reading and a clock, and acts on what comes back. the numbers
//! are the stock firmware's own, recovered from the vendor app during the reverse engineering and
//! recorded in `README.md`: warn below 3,600 mv, and below 3,550 mv run a thirty-second countdown
//! and then power off, skipped while usb power is present. matching them is deliberate -- they came
//! from the people who knew this cell and this board's brownout point, and nothing here has been
//! validated against a real discharge.
//!
//! three rules are this file's own, and they all say the same thing: **silence is not a low
//! battery.**
//!
//!   - a reading only counts if the mcu answered recently. the supervisor's poll loop keeps the
//!     last value when the link goes quiet, so a stale 3.4 v would otherwise power off a clock
//!     that is sitting happily on a charger.
//!   - losing the link cancels a countdown in progress rather than continuing it. we could not see
//!     a usb cable being plugged in either -- and the power-off itself goes *through* the mcu, so
//!     a link we cannot hear is a link we cannot use.
//!   - one low reading is not enough. the pack voltage is a raw adc value scaled by a float, read
//!     while the panel is drawing, so a single sample can dip under load.
const std = @import("std");

/// the supervisor's sentinels for a reading it does not have
pub const unknown_mv: u16 = 0xffff;
pub const usb_unknown: u8 = 255;

/// the stock firmware's emergency threshold
pub const default_shutdown_mv: u16 = 3550;
/// and its countdown
pub const default_grace_s: u16 = 30;
/// the stock app warns fifty millivolts before it acts, so the warning threshold is derived rather
/// than being a second setting: two independent knobs can be set the wrong way round, and then
/// this file has to decide what someone meant.
pub const low_margin_mv: u16 = 50;
/// how far a reading has to recover before a warning or a countdown clears. a cell sitting exactly
/// on a threshold would otherwise flap between states at the poll rate.
pub const clear_margin_mv: u16 = 30;
/// consecutive confirmed readings at or below the threshold before the countdown starts
pub const confirm_samples: u8 = 2;

pub const Settings = struct {
    enabled: bool = true,
    shutdown_mv: u16 = default_shutdown_mv,
    grace_s: u16 = default_grace_s,

    /// the warning threshold, always above the shutdown one by construction
    pub fn lowMv(self: Settings) u16 {
        return self.shutdown_mv +| low_margin_mv;
    }
};

pub const Reading = struct {
    millivolts: u16 = unknown_mv,
    /// 1 on usb power, 0 on the cell, 255 unknown. unknown counts as "on the cell": the mcu
    /// answers both in one poll, so a usb state we do not have alongside a battery reading we do
    /// means something is wrong with the link, and `fresh` is what catches that.
    usb: u8 = usb_unknown,
    /// the mcu answered recently enough for this reading to mean anything
    fresh: bool = false,
};

pub const Phase = enum { ok, low, critical };

/// why a countdown stopped, so the log line can say
pub const Cancel = enum { usb, recovered, stale, disabled };

pub const Event = union(enum) {
    none,
    /// crossed into the warning band, carrying the reading
    low: u16,
    /// climbed back out of it
    recovered,
    /// the countdown is running; the seconds left, reported when the number changes
    countdown: u16,
    cancelled: Cancel,
    /// put the device away now
    shutdown,
};

pub const Policy = struct {
    phase: Phase = .ok,
    /// consecutive confirmed readings at or below the shutdown threshold
    below: u8 = 0,
    deadline_ns: u64 = 0,
    last_left_s: u16 = 0,
    /// a shutdown is asked for once. the supervisor is on its way down after that, and a second
    /// one would be a second power-off command racing the first.
    spent: bool = false,

    fn clear(self: *Policy) void {
        self.phase = .ok;
        self.below = 0;
        self.deadline_ns = 0;
        self.last_left_s = 0;
    }

    /// seconds left, rounded up, so a countdown shows 30 rather than 29 the instant it starts
    fn leftS(self: *const Policy, now_ns: u64) u16 {
        if (now_ns >= self.deadline_ns) return 0;
        const ns = self.deadline_ns - now_ns;
        return @intCast((ns + std.time.ns_per_s - 1) / std.time.ns_per_s);
    }

    pub fn update(self: *Policy, cfg: Settings, r: Reading, now_ns: u64) Event {
        if (self.spent) return .none;

        if (!cfg.enabled) {
            const was = self.phase;
            self.clear();
            return if (was == .critical) .{ .cancelled = .disabled } else .none;
        }

        // the cable wins over every reading: charging is the answer to a low battery
        if (r.usb == 1) {
            const was = self.phase;
            self.clear();
            return if (was == .critical) .{ .cancelled = .usb } else .none;
        }

        if (!r.fresh or r.millivolts == unknown_mv) {
            const was = self.phase;
            self.below = 0;
            if (was == .critical) {
                self.clear();
                return .{ .cancelled = .stale };
            }
            return .none;
        }

        const mv = r.millivolts;

        if (mv <= cfg.shutdown_mv) {
            if (self.below < confirm_samples) self.below += 1;
            if (self.phase != .critical) {
                // one dip under load is not a flat battery; two in a row is. but a first dip is
                // already inside the warning band by definition, so say so rather than sitting on
                // it -- the countdown is what needs confirming, not the fact of a low cell.
                if (self.below < confirm_samples) {
                    if (self.phase == .ok) {
                        self.phase = .low;
                        return .{ .low = mv };
                    }
                    return .none;
                }
                self.phase = .critical;
                self.deadline_ns = now_ns + @as(u64, cfg.grace_s) * std.time.ns_per_s;
                self.last_left_s = cfg.grace_s;
                if (cfg.grace_s == 0) {
                    self.spent = true;
                    return .shutdown;
                }
                return .{ .countdown = cfg.grace_s };
            }
            if (now_ns >= self.deadline_ns) {
                self.spent = true;
                return .shutdown;
            }
            const left = self.leftS(now_ns);
            if (left != self.last_left_s) {
                self.last_left_s = left;
                return .{ .countdown = left };
            }
            return .none;
        }

        self.below = 0;

        // a countdown only stops once the reading has climbed clear of the threshold, not the
        // moment it touches it from below
        if (self.phase == .critical) {
            if (mv < cfg.shutdown_mv +| clear_margin_mv) {
                if (now_ns >= self.deadline_ns) {
                    self.spent = true;
                    return .shutdown;
                }
                const left = self.leftS(now_ns);
                if (left != self.last_left_s) {
                    self.last_left_s = left;
                    return .{ .countdown = left };
                }
                return .none;
            }
            self.clear();
            self.phase = .low;
            return .{ .cancelled = .recovered };
        }

        if (mv <= cfg.lowMv()) {
            if (self.phase == .ok) {
                self.phase = .low;
                return .{ .low = mv };
            }
            return .none;
        }

        if (self.phase == .low and mv >= cfg.lowMv() +| clear_margin_mv) {
            self.clear();
            return .recovered;
        }
        return .none;
    }
};

// -- tests -------------------------------------------------------------------------------------

const testing = std.testing;
const s_ns = std.time.ns_per_s;

fn onCell(mv: u16) Reading {
    return .{ .millivolts = mv, .usb = 0, .fresh = true };
}

test "a healthy cell says nothing at all" {
    var p = Policy{};
    const cfg = Settings{};
    try testing.expect(p.update(cfg, onCell(4100), 0) == .none);
    try testing.expect(p.update(cfg, onCell(3900), 30 * s_ns) == .none);
    try testing.expectEqual(Phase.ok, p.phase);
}

test "the warning band is entered once, not on every reading in it" {
    var p = Policy{};
    const cfg = Settings{};
    // 3,600 and below is the warning band: shutdown_mv + low_margin_mv
    try testing.expectEqual(@as(u16, 3600), cfg.lowMv());
    const first = p.update(cfg, onCell(3580), 0);
    try testing.expectEqual(@as(u16, 3580), first.low);
    try testing.expect(p.update(cfg, onCell(3575), 30 * s_ns) == .none);
    try testing.expectEqual(Phase.low, p.phase);

    // and it clears only once the reading is clear of it, not the moment it touches the boundary
    try testing.expect(p.update(cfg, onCell(3610), 60 * s_ns) == .none);
    try testing.expect(p.update(cfg, onCell(3640), 90 * s_ns) == .recovered);
    try testing.expectEqual(Phase.ok, p.phase);
}

test "one reading under the threshold is a dip; two is a flat battery" {
    var p = Policy{};
    const cfg = Settings{};
    // the first sample below only warns -- the panel drawing can pull the pack down for a moment
    const first = p.update(cfg, onCell(3540), 0);
    try testing.expectEqual(@as(u16, 3540), first.low);
    try testing.expectEqual(Phase.low, p.phase);

    const second = p.update(cfg, onCell(3540), 30 * s_ns);
    try testing.expectEqual(@as(u16, 30), second.countdown);
    try testing.expectEqual(Phase.critical, p.phase);
}

test "the countdown runs down, reports each second once, and then shuts down" {
    var p = Policy{};
    const cfg = Settings{};
    _ = p.update(cfg, onCell(3500), 0);
    try testing.expectEqual(@as(u16, 30), p.update(cfg, onCell(3500), 1 * s_ns).countdown);

    try testing.expectEqual(@as(u16, 20), p.update(cfg, onCell(3500), 11 * s_ns).countdown);
    // the same second twice is not news
    try testing.expect(p.update(cfg, onCell(3500), 11 * s_ns + 1) == .none);
    try testing.expectEqual(@as(u16, 1), p.update(cfg, onCell(3500), 30 * s_ns).countdown);
    try testing.expect(p.update(cfg, onCell(3500), 31 * s_ns) == .shutdown);

    // and it is asked for exactly once: the device is on its way down, and a second power-off
    // command would race the first
    try testing.expect(p.update(cfg, onCell(3500), 32 * s_ns) == .none);
    try testing.expect(p.update(cfg, onCell(4100), 40 * s_ns) == .none);
}

test "a cable cancels a countdown, and charging never shuts anything down" {
    var p = Policy{};
    const cfg = Settings{};
    _ = p.update(cfg, onCell(3500), 0);
    _ = p.update(cfg, onCell(3500), 1 * s_ns);
    try testing.expectEqual(Phase.critical, p.phase);

    const plugged = Reading{ .millivolts = 3500, .usb = 1, .fresh = true };
    try testing.expectEqual(Cancel.usb, p.update(cfg, plugged, 5 * s_ns).cancelled);
    try testing.expectEqual(Phase.ok, p.phase);

    // a flat cell on a charger stays put however long it is watched
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(p.update(cfg, plugged, (10 + i) * s_ns) == .none);
    }
}

test "silence is not a low battery" {
    var p = Policy{};
    const cfg = Settings{};
    // the supervisor keeps the last reading when the mcu stops answering, so a stale value must
    // not be allowed to accumulate into a shutdown
    const stale = Reading{ .millivolts = 3400, .usb = 0, .fresh = false };
    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        try testing.expect(p.update(cfg, stale, i * s_ns) == .none);
    }
    try testing.expectEqual(Phase.ok, p.phase);

    // nor a reading the mcu never gave us
    const nothing = Reading{ .millivolts = unknown_mv, .usb = usb_unknown, .fresh = true };
    try testing.expect(p.update(cfg, nothing, 60 * s_ns) == .none);
}

test "losing the link mid-countdown cancels it, because the power-off goes through that link" {
    var p = Policy{};
    const cfg = Settings{};
    _ = p.update(cfg, onCell(3500), 0);
    _ = p.update(cfg, onCell(3500), 1 * s_ns);
    try testing.expectEqual(Phase.critical, p.phase);

    const stale = Reading{ .millivolts = 3500, .usb = 0, .fresh = false };
    try testing.expectEqual(Cancel.stale, p.update(cfg, stale, 5 * s_ns).cancelled);
    try testing.expectEqual(Phase.ok, p.phase);
    // and it does not quietly resume on the next silent tick
    try testing.expect(p.update(cfg, stale, 40 * s_ns) == .none);
}

test "a cell that recovers under its own steam cancels the countdown" {
    var p = Policy{};
    const cfg = Settings{};
    _ = p.update(cfg, onCell(3500), 0);
    _ = p.update(cfg, onCell(3500), 1 * s_ns);

    // still inside the hysteresis band: the countdown keeps running and keeps reporting
    try testing.expectEqual(@as(u16, 29), p.update(cfg, onCell(3560), 2 * s_ns).countdown);
    try testing.expectEqual(Phase.critical, p.phase);

    // clear of it: cancelled, and left in the warning band rather than declared healthy
    try testing.expectEqual(Cancel.recovered, p.update(cfg, onCell(3585), 3 * s_ns).cancelled);
    try testing.expectEqual(Phase.low, p.phase);
}

test "disabled does nothing, and cancels a countdown that was already running" {
    var p = Policy{};
    var cfg = Settings{};
    _ = p.update(cfg, onCell(3500), 0);
    _ = p.update(cfg, onCell(3500), 1 * s_ns);
    try testing.expectEqual(Phase.critical, p.phase);

    cfg.enabled = false;
    try testing.expectEqual(Cancel.disabled, p.update(cfg, onCell(3400), 2 * s_ns).cancelled);
    var i: u64 = 0;
    while (i < 50) : (i += 1) {
        try testing.expect(p.update(cfg, onCell(3200), (3 + i) * s_ns) == .none);
    }
}

test "a zero grace shuts down the moment it is confirmed, and never reports a countdown" {
    var p = Policy{};
    const cfg = Settings{ .grace_s = 0 };
    try testing.expect(p.update(cfg, onCell(3500), 0) == .low);
    try testing.expect(p.update(cfg, onCell(3500), 1 * s_ns) == .shutdown);
}

test "a threshold of someone's own choosing is honoured, warning band and all" {
    var p = Policy{};
    const cfg = Settings{ .shutdown_mv = 3700, .grace_s = 10 };
    try testing.expectEqual(@as(u16, 3750), cfg.lowMv());
    try testing.expect(p.update(cfg, onCell(3800), 0) == .none); // above the warning band
    try testing.expectEqual(@as(u16, 3740), p.update(cfg, onCell(3740), 1 * s_ns).low);
    _ = p.update(cfg, onCell(3690), 2 * s_ns);
    try testing.expectEqual(@as(u16, 10), p.update(cfg, onCell(3690), 3 * s_ns).countdown);
}
