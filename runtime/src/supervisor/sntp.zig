//! a minimal sntp client (rfc 4330) as pure logic: the 48-byte ntpv4 unicast request, reply
//! validation, offset and round-trip delay from the four timestamps, era resolution against an
//! explicit build-date reference, and the poll/backoff state machine driven by monotonic time.
//! the udp socket and the clock syscalls live in the supervisor.
//!
//! trust boundary: unauthenticated sntp from a local server the user configured. a reply is
//! accepted only when it comes back on the connected socket (the kernel filters the peer), echoes
//! our originate timestamp, carries a synchronised stratum 1..15 server, has nonzero server
//! stamps, a plausible date and a round trip under one second.
const std = @import("std");

const ns_per_s: u64 = std.time.ns_per_s;

pub const port: u16 = 123;
pub const packet_len = 48;
/// seconds from the ntp epoch (1900-01-01) to the unix epoch (1970-01-01).
pub const ntp_unix_offset_s: u64 = 2_208_988_800;
/// the era reference: 2026-09-01T00:00:00Z, the build date of this client. a 32-bit ntp second is
/// resolved to the era in which it lands within ±68 years of the reference, so an uninitialised
/// wall clock (1970 after a cold boot) can never pick the wrong era.
pub const build_reference_unix_s: u64 = 1_788_220_800;
/// server dates are accepted within this span after the build reference.
pub const plausible_span_s: u64 = 20 * 365 * 86_400;
pub const request_timeout_ns: u64 = 2 * ns_per_s;
pub const max_delay_ns: u64 = 1 * ns_per_s;
/// offsets at or above this are stepped with clock_settime; smaller ones are slewed.
pub const step_threshold_ns: u64 = 128 * std.time.ns_per_ms;
pub const first_backoff_ns: u64 = 2 * ns_per_s;
pub const stale_floor_ns: u64 = 3600 * ns_per_s;

pub const Timestamp = struct {
    sec: u32,
    frac: u32,

    pub fn isZero(self: Timestamp) bool {
        return self.sec == 0 and self.frac == 0;
    }

    pub fn eql(a: Timestamp, b: Timestamp) bool {
        return a.sec == b.sec and a.frac == b.frac;
    }

    /// era-truncated ntp format of a unix time in nanoseconds.
    pub fn fromUnixNs(unix_ns: u64) Timestamp {
        const s = unix_ns / ns_per_s + ntp_unix_offset_s;
        const ns = unix_ns % ns_per_s;
        return .{ .sec = @truncate(s), .frac = @intCast((ns << 32) / ns_per_s) };
    }

    /// unix nanoseconds, with the era chosen so the result lies within ±2^31 s of `ref_unix_s`.
    pub fn toUnixNs(self: Timestamp, ref_unix_s: u64) u64 {
        const base: u64 = ref_unix_s + ntp_unix_offset_s;
        const half: u64 = 1 << 31;
        const span: u64 = 1 << 32;
        var cand: u64 = ((base >> 32) << 32) | self.sec;
        if (cand + half < base) cand += span else if (cand >= base + half) cand -|= span;
        const unix_s = cand -| ntp_unix_offset_s;
        return unix_s * ns_per_s + ((@as(u64, self.frac) * ns_per_s) >> 32);
    }

    pub fn write(self: Timestamp, out: *[8]u8) void {
        std.mem.writeInt(u32, out[0..4], self.sec, .big);
        std.mem.writeInt(u32, out[4..8], self.frac, .big);
    }

    pub fn read(in: *const [8]u8) Timestamp {
        return .{ .sec = std.mem.readInt(u32, in[0..4], .big), .frac = std.mem.readInt(u32, in[4..8], .big) };
    }
};

/// the era reference to resolve replies against: the wall clock when it is plausible, the build
/// date otherwise (an unset clock says 1970; a corrupt one could say anything).
pub fn eraReference(now_unix_s: u64) u64 {
    if (now_unix_s >= build_reference_unix_s and now_unix_s < build_reference_unix_s + plausible_span_s) return now_unix_s;
    return build_reference_unix_s;
}

pub const Request = struct { bytes: [packet_len]u8, sent: Timestamp };

/// li 0, version 4, mode 3 (client); only the transmit timestamp is set: our seconds with a random
/// fraction, which the server echoes back as the originate timestamp.
pub fn buildRequest(now_unix_ns: u64, nonce: u32) Request {
    var r = Request{ .bytes = [_]u8{0} ** packet_len, .sent = Timestamp.fromUnixNs(now_unix_ns) };
    r.sent.frac = nonce;
    r.bytes[0] = 0x23;
    r.sent.write(r.bytes[40..48]);
    return r;
}

pub const Reply = struct { offset_ns: i64, delay_ns: i64, stratum: u8, leap: u2, server_unix_ns: u64 };
pub const Reject = enum { short, version, mode, alarm, stratum, kiss_rate, kiss_deny, kiss_other, originate, zero_stamp, implausible_date, delay };
pub const Verdict = union(enum) { ok: Reply, rejected: Reject };

pub fn rejectText(r: Reject) []const u8 {
    return switch (r) {
        .short => "short packet",
        .version => "unsupported version",
        .mode => "not a server reply",
        .alarm => "server clock unsynchronised (li 3)",
        .stratum => "unusable stratum",
        .kiss_rate => "kiss-o'-death rate",
        .kiss_deny => "kiss-o'-death deny",
        .kiss_other => "kiss-o'-death",
        .originate => "originate timestamp mismatch",
        .zero_stamp => "zero server timestamp",
        .implausible_date => "implausible server date",
        .delay => "round trip too long or negative",
    };
}

fn saturate(v: i128) i64 {
    return @intCast(std.math.clamp(v, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// validate a reply against the request it answers. `t1`/`t4` are our wall clock at send and
/// receive in unix nanoseconds; `ref_unix_s` resolves the server's 32-bit seconds to an era.
pub fn parseReply(bytes: []const u8, sent: Timestamp, t1_unix_ns: u64, t4_unix_ns: u64, ref_unix_s: u64) Verdict {
    if (bytes.len < packet_len) return .{ .rejected = .short };
    const li: u2 = @intCast(bytes[0] >> 6);
    const vn: u3 = @intCast((bytes[0] >> 3) & 7);
    const mode: u3 = @intCast(bytes[0] & 7);
    const stratum = bytes[1];
    if (vn != 3 and vn != 4) return .{ .rejected = .version };
    if (mode != 4) return .{ .rejected = .mode };
    if (stratum == 0) {
        const code = bytes[12..16];
        if (std.mem.eql(u8, code, "RATE")) return .{ .rejected = .kiss_rate };
        if (std.mem.eql(u8, code, "DENY") or std.mem.eql(u8, code, "RSTR")) return .{ .rejected = .kiss_deny };
        return .{ .rejected = .kiss_other };
    }
    if (li == 3) return .{ .rejected = .alarm };
    if (stratum > 15) return .{ .rejected = .stratum };
    const originate = Timestamp.read(bytes[24..32]);
    if (!originate.eql(sent)) return .{ .rejected = .originate };
    const receive = Timestamp.read(bytes[32..40]);
    const transmit = Timestamp.read(bytes[40..48]);
    if (receive.isZero() or transmit.isZero()) return .{ .rejected = .zero_stamp };
    const t2 = receive.toUnixNs(ref_unix_s);
    const t3 = transmit.toUnixNs(ref_unix_s);
    const lo = build_reference_unix_s * ns_per_s;
    const hi = (build_reference_unix_s + plausible_span_s) * ns_per_s;
    if (t3 < lo or t3 >= hi or t2 < lo or t2 >= hi or t3 < t2) return .{ .rejected = .implausible_date };
    const a: i128 = @as(i128, t2) - @as(i128, t1_unix_ns);
    const b: i128 = @as(i128, t3) - @as(i128, t4_unix_ns);
    const delay: i128 = (@as(i128, t4_unix_ns) - @as(i128, t1_unix_ns)) - (@as(i128, t3) - @as(i128, t2));
    if (delay < 0 or delay > max_delay_ns) return .{ .rejected = .delay };
    return .{ .ok = .{ .offset_ns = saturate(@divTrunc(a + b, 2)), .delay_ns = saturate(delay), .stratum = stratum, .leap = li, .server_unix_ns = t3 } };
}

pub const Correction = enum { step, slew };

pub fn correctionFor(offset_ns: i64) Correction {
    const magnitude: u64 = @intCast(if (offset_ns < 0) -offset_ns else offset_ns);
    return if (magnitude >= step_threshold_ns) .step else .slew;
}

pub const Phase = enum { idle, due, awaiting, denied };
pub const Directive = enum { none, send, timeout };
pub const TimeState = struct { state: u8, age_s: u32 };

/// the poll/backoff state machine. the caller opens the socket for `server`, sends when `poll`
/// says so, reports replies and network state, and reads `timeState` for the snapshot.
pub const Client = struct {
    server: ?[4]u8 = null,
    interval_ns: u64 = 300 * ns_per_s,
    phase: Phase = .idle,
    network_up: bool = false,
    next_ns: u64 = 0,
    deadline_ns: u64 = 0,
    sent: Timestamp = .{ .sec = 0, .frac = 0 },
    t1_unix_ns: u64 = 0,
    attempt: u8 = 0,
    last_success_ns: ?u64 = null,
    last_offset_ns: i64 = 0,
    last_delay_ns: i64 = 0,
    last_stratum: u8 = 0,
    successes: u32 = 0,
    failures: u32 = 0,
    rate_kisses: u32 = 0,

    /// (re)configure: a new server or interval starts a fresh cycle; null disables.
    pub fn configure(self: *Client, server: ?[4]u8, interval_s: u32, now_ns: u64) void {
        self.server = server;
        self.interval_ns = @as(u64, interval_s) * ns_per_s;
        self.attempt = 0;
        self.phase = if (server == null) .idle else .due;
        self.next_ns = now_ns;
    }

    pub fn setNetwork(self: *Client, up: bool, now_ns: u64) void {
        if (up and !self.network_up and self.phase == .due) self.next_ns = now_ns; // sync promptly
        self.network_up = up;
    }

    fn backoff(self: *Client, now_ns: u64) void {
        self.attempt +|= 1;
        const shift: u6 = @intCast(@min(self.attempt - 1, 20));
        const delay = @min(first_backoff_ns << shift, self.interval_ns);
        self.next_ns = now_ns + delay;
        self.phase = .due;
    }

    /// `send` when a request is due (call `onSent` after sending); `timeout` when the outstanding
    /// request expired (backoff already applied).
    pub fn poll(self: *Client, now_ns: u64) Directive {
        switch (self.phase) {
            .idle, .denied => return .none,
            .awaiting => {
                if (now_ns < self.deadline_ns) return .none;
                self.failures +|= 1;
                self.backoff(now_ns);
                return .timeout;
            },
            .due => {
                if (!self.network_up or self.server == null or now_ns < self.next_ns) return .none;
                return .send;
            },
        }
    }

    pub fn onSent(self: *Client, sent: Timestamp, t1_unix_ns: u64, now_ns: u64) void {
        self.sent = sent;
        self.t1_unix_ns = t1_unix_ns;
        self.phase = .awaiting;
        self.deadline_ns = now_ns + request_timeout_ns;
    }

    /// a datagram arrived on the connected socket (so it is from the configured peer).
    pub fn onReply(self: *Client, bytes: []const u8, t4_unix_ns: u64, now_ns: u64) Verdict {
        if (self.phase != .awaiting) return .{ .rejected = .originate };
        const ref = eraReference(t4_unix_ns / ns_per_s);
        const v = parseReply(bytes, self.sent, self.t1_unix_ns, t4_unix_ns, ref);
        switch (v) {
            .ok => |r| {
                self.successes +|= 1;
                self.attempt = 0;
                self.last_success_ns = now_ns;
                self.last_offset_ns = r.offset_ns;
                self.last_delay_ns = r.delay_ns;
                self.last_stratum = r.stratum;
                self.phase = .due;
                self.next_ns = now_ns + self.interval_ns;
            },
            .rejected => |why| {
                self.failures +|= 1;
                switch (why) {
                    .kiss_deny => self.phase = .denied,
                    .kiss_rate => {
                        self.rate_kisses +|= 1;
                        self.phase = .due;
                        self.next_ns = now_ns + 2 * self.interval_ns;
                    },
                    else => self.backoff(now_ns),
                }
            },
        }
        return v;
    }

    /// the socket reported an error (icmp unreachable): treat like a rejected reply.
    pub fn onSocketError(self: *Client, now_ns: u64) void {
        if (self.phase != .awaiting) return;
        self.failures +|= 1;
        self.backoff(now_ns);
    }

    /// 0 unsynced, 1 synced, 2 stale (no success within max(three intervals, one hour)).
    pub fn timeState(self: *const Client, now_ns: u64) TimeState {
        const last = self.last_success_ns orelse return .{ .state = 0, .age_s = 0xffffffff };
        const age = now_ns -| last;
        const stale_after = @max(3 * self.interval_ns, stale_floor_ns);
        return .{ .state = if (age > stale_after) 2 else 1, .age_s = @intCast(@min(age / ns_per_s, 0xfffffffe)) };
    }

    /// when the next poll wants to run, for timer arming.
    pub fn nextDeadline(self: *const Client) ?u64 {
        return switch (self.phase) {
            .awaiting => self.deadline_ns,
            .due => if (self.network_up and self.server != null) self.next_ns else null,
            .idle, .denied => null,
        };
    }
};

// tests

const ref_2026: u64 = build_reference_unix_s + 10 * 86_400; // 2026-09-11

fn serverReply(sent: Timestamp, t2_unix_ns: u64, t3_unix_ns: u64, stratum: u8, li: u2) [packet_len]u8 {
    var b = [_]u8{0} ** packet_len;
    b[0] = (@as(u8, li) << 6) | (4 << 3) | 4;
    b[1] = stratum;
    b[12..16].* = "GPS ".*;
    Timestamp.fromUnixNs(t3_unix_ns - 1000).write(b[16..24]); // reference: whatever
    sent.write(b[24..32]);
    Timestamp.fromUnixNs(t2_unix_ns).write(b[32..40]);
    Timestamp.fromUnixNs(t3_unix_ns).write(b[40..48]);
    return b;
}

test "the request is li 0 version 4 mode 3 with our transmit stamp at offset 40" {
    const now: u64 = ref_2026 * ns_per_s + 250_000_000;
    const r = buildRequest(now, 0xdeadbeef);
    try std.testing.expectEqual(@as(u8, 0x23), r.bytes[0]);
    for (r.bytes[1..40]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(@as(u32, @truncate(ref_2026 + ntp_unix_offset_s)), r.sent.sec);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), r.sent.frac);
    try std.testing.expectEqual(r.sent, Timestamp.read(r.bytes[40..48]));
}

test "timestamps round-trip through the ntp format losing at most one nanosecond" {
    const now: u64 = ref_2026 * ns_per_s + 123_456_789;
    const ts = Timestamp.fromUnixNs(now);
    const back = ts.toUnixNs(ref_2026);
    try std.testing.expect(back <= now and now - back <= 1);
    try std.testing.expectEqual(now / ns_per_s * ns_per_s, (Timestamp{ .sec = ts.sec, .frac = 0 }).toUnixNs(ref_2026));
}

test "era rollover: seconds past 2036-02-07 resolve forward, old stamps resolve back" {
    const rollover_unix: u64 = 2_085_978_496; // ntp second 2^32 = 2036-02-07T06:28:16Z
    // a reference just after the rollover, a stamp with a tiny ntp second: era 1
    const after = Timestamp{ .sec = 5, .frac = 0 };
    try std.testing.expectEqual((rollover_unix + 5) * ns_per_s, after.toUnixNs(rollover_unix + 60));
    // a reference just before the rollover, a stamp with a huge ntp second: still era 0
    const before = Timestamp{ .sec = 0xffff_fff0, .frac = 0 };
    try std.testing.expectEqual((rollover_unix - 16) * ns_per_s, before.toUnixNs(rollover_unix - 60));
    // a reference before the rollover but a stamp already past it (server slightly ahead): era 1
    try std.testing.expectEqual((rollover_unix + 5) * ns_per_s, after.toUnixNs(rollover_unix - 60));
    // and the other way round
    try std.testing.expectEqual((rollover_unix - 16) * ns_per_s, before.toUnixNs(rollover_unix + 60));
}

test "the era reference is the wall clock only when it is plausible" {
    try std.testing.expectEqual(build_reference_unix_s, eraReference(0));
    try std.testing.expectEqual(build_reference_unix_s, eraReference(946_684_800)); // 2000
    try std.testing.expectEqual(ref_2026, eraReference(ref_2026));
    try std.testing.expectEqual(build_reference_unix_s, eraReference(build_reference_unix_s + plausible_span_s + 1));
}

test "offset and delay come from all four timestamps" {
    const t1: u64 = ref_2026 * ns_per_s;
    const sent = Timestamp.fromUnixNs(t1);
    // the server is 2.5 s ahead of us; 6 ms each way on the wire; 1 ms in the server
    const t2 = t1 + 2_500_000_000 + 6_000_000;
    const t3 = t2 + 1_000_000;
    const t4 = t1 + 13_000_000;
    const reply = serverReply(sent, t2, t3, 3, 0);
    const v = parseReply(&reply, sent, t1, t4, ref_2026);
    const ok = v.ok;
    try std.testing.expectEqual(@as(u8, 3), ok.stratum);
    try std.testing.expect(ok.offset_ns >= 2_499_999_000 and ok.offset_ns <= 2_500_001_000);
    try std.testing.expect(ok.delay_ns >= 11_999_000 and ok.delay_ns <= 12_001_000);
    try std.testing.expectEqual(Correction.step, correctionFor(ok.offset_ns));
    try std.testing.expectEqual(Correction.slew, correctionFor(-127_999_999));
    try std.testing.expectEqual(Correction.step, correctionFor(-128_000_000));
}

test "a cold-booted clock (1970) still computes the offset to a 2026 server" {
    const t1: u64 = 1000 * ns_per_s; // the kernel's clock a moment after boot
    const sent = Timestamp.fromUnixNs(t1);
    const t2 = ref_2026 * ns_per_s;
    const t3 = t2 + 500_000;
    const t4 = t1 + 8_000_000;
    const reply = serverReply(sent, t2, t3, 2, 0);
    const v = parseReply(&reply, sent, t1, t4, eraReference(t4 / ns_per_s));
    const ok = v.ok;
    const expected: i128 = @as(i128, t2) - @as(i128, t1);
    try std.testing.expect(@as(i128, ok.offset_ns) - expected > -10_000_000 and @as(i128, ok.offset_ns) - expected < 10_000_000);
    try std.testing.expect(ok.delay_ns >= 7_400_000 and ok.delay_ns <= 7_600_000);
}

test "replies are rejected for every documented reason" {
    const t1: u64 = ref_2026 * ns_per_s;
    const sent = Timestamp.fromUnixNs(t1);
    const t2 = t1 + 3_000_000;
    const t3 = t2 + 100_000;
    const t4 = t1 + 6_000_000;
    const good = serverReply(sent, t2, t3, 3, 0);
    try std.testing.expect(parseReply(&good, sent, t1, t4, ref_2026) == .ok);
    try std.testing.expectEqual(Reject.short, parseReply(good[0..47], sent, t1, t4, ref_2026).rejected);
    var b = good;
    b[0] = (2 << 3) | 4;
    try std.testing.expectEqual(Reject.version, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    b[0] = (4 << 3) | 3;
    try std.testing.expectEqual(Reject.mode, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    b[0] = (3 << 6) | (4 << 3) | 4;
    try std.testing.expectEqual(Reject.alarm, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    b[1] = 16;
    try std.testing.expectEqual(Reject.stratum, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    b[1] = 0;
    b[12..16].* = "RATE".*;
    try std.testing.expectEqual(Reject.kiss_rate, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b[12..16].* = "DENY".*;
    try std.testing.expectEqual(Reject.kiss_deny, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b[12..16].* = "RSTR".*;
    try std.testing.expectEqual(Reject.kiss_deny, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b[12..16].* = "INIT".*;
    try std.testing.expectEqual(Reject.kiss_other, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    b[31] ^= 1;
    try std.testing.expectEqual(Reject.originate, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    b = good;
    @memset(b[40..48], 0);
    try std.testing.expectEqual(Reject.zero_stamp, parseReply(&b, sent, t1, t4, ref_2026).rejected);
    // a server stuck in 2010
    const old = serverReply(sent, 1_262_304_000 * ns_per_s, 1_262_304_000 * ns_per_s + 1000, 3, 0);
    try std.testing.expectEqual(Reject.implausible_date, parseReply(&old, sent, t1, t4, ref_2026).rejected);
    // transmit before receive
    const backwards = serverReply(sent, t2, t2 - 1_000_000, 3, 0);
    try std.testing.expectEqual(Reject.implausible_date, parseReply(&backwards, sent, t1, t4, ref_2026).rejected);
    // round trip of 1.5 s
    try std.testing.expectEqual(Reject.delay, parseReply(&good, sent, t1, t1 + 1_500_000_000, ref_2026).rejected);
    // the server claims to have held the packet longer than our round trip: negative delay
    const slow = serverReply(sent, t2, t2 + 10_000_000, 3, 0);
    try std.testing.expectEqual(Reject.delay, parseReply(&slow, sent, t1, t4, ref_2026).rejected);
}

test "the client waits for the network, syncs promptly, then polls every interval" {
    var c = Client{};
    c.configure(.{ 10, 0, 0, 136 }, 300, 0);
    try std.testing.expectEqual(Directive.none, c.poll(0)); // no network yet
    c.setNetwork(true, 5 * ns_per_s);
    try std.testing.expectEqual(Directive.send, c.poll(5 * ns_per_s));
    const t1: u64 = ref_2026 * ns_per_s;
    const req = buildRequest(t1, 7);
    c.onSent(req.sent, t1, 5 * ns_per_s);
    try std.testing.expectEqual(Directive.none, c.poll(5 * ns_per_s + 1));
    const reply = serverReply(req.sent, t1 + 3_000_000, t1 + 3_100_000, 3, 0);
    const v = c.onReply(&reply, t1 + 6_000_000, 5 * ns_per_s + 6_000_000);
    try std.testing.expect(v == .ok);
    try std.testing.expectEqual(@as(u32, 1), c.successes);
    try std.testing.expectEqual(TimeState{ .state = 1, .age_s = 0 }, c.timeState(5 * ns_per_s + 6_000_000));
    try std.testing.expectEqual(Directive.none, c.poll(304 * ns_per_s));
    try std.testing.expectEqual(Directive.send, c.poll(305 * ns_per_s + 6_000_000));
    // nothing for an hour: stale; the floor is one hour even at a 300 s interval
    try std.testing.expectEqual(@as(u8, 1), c.timeState(3600 * ns_per_s).state);
    try std.testing.expectEqual(@as(u8, 2), c.timeState(3606 * ns_per_s + 1).state);
    c.configure(null, 300, 0);
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(@as(?u64, null), c.nextDeadline());
}

test "timeouts back off 2, 4, 8 ... seconds, capped at the interval; a success resets" {
    var c = Client{};
    c.configure(.{ 10, 0, 0, 136 }, 300, 0);
    c.setNetwork(true, 0);
    var now: u64 = 0;
    const expected = [_]u64{ 2, 4, 8, 16, 32, 64, 128, 256, 300, 300 };
    for (expected) |delay_s| {
        try std.testing.expectEqual(Directive.send, c.poll(now));
        c.onSent(.{ .sec = 1, .frac = 1 }, 0, now);
        try std.testing.expectEqual(Directive.none, c.poll(now + request_timeout_ns - 1));
        try std.testing.expectEqual(Directive.timeout, c.poll(now + request_timeout_ns));
        try std.testing.expectEqual(now + request_timeout_ns + delay_s * ns_per_s, c.next_ns);
        now = c.next_ns;
    }
    try std.testing.expectEqual(@as(u32, expected.len), c.failures);
    try std.testing.expectEqual(@as(u8, 0), c.timeState(now).state);
    // a success resets the attempt counter
    try std.testing.expectEqual(Directive.send, c.poll(now));
    const t1: u64 = ref_2026 * ns_per_s;
    const req = buildRequest(t1, 1);
    c.onSent(req.sent, t1, now);
    const reply = serverReply(req.sent, t1 + 1_000_000, t1 + 1_100_000, 4, 0);
    try std.testing.expect(c.onReply(&reply, t1 + 2_000_000, now + 2_000_000) == .ok);
    try std.testing.expectEqual(@as(u8, 0), c.attempt);
    try std.testing.expectEqual(now + 2_000_000 + 300 * ns_per_s, c.next_ns);
}

test "kiss-o'-death: rate doubles the wait, deny stops polling until reconfigured" {
    var c = Client{};
    c.configure(.{ 10, 0, 0, 136 }, 300, 0);
    c.setNetwork(true, 0);
    _ = c.poll(0);
    const t1: u64 = ref_2026 * ns_per_s;
    const req = buildRequest(t1, 1);
    c.onSent(req.sent, t1, 0);
    var kiss = serverReply(req.sent, t1 + 1000, t1 + 2000, 0, 0);
    kiss[12..16].* = "RATE".*;
    try std.testing.expectEqual(Reject.kiss_rate, c.onReply(&kiss, t1 + 5000, 1000).rejected);
    try std.testing.expectEqual(@as(u64, 1000 + 600 * ns_per_s), c.next_ns);
    try std.testing.expectEqual(@as(u32, 1), c.rate_kisses);
    c.next_ns = 1000;
    _ = c.poll(1000);
    c.onSent(req.sent, t1, 1000);
    kiss[12..16].* = "DENY".*;
    try std.testing.expectEqual(Reject.kiss_deny, c.onReply(&kiss, t1 + 5000, 2000).rejected);
    try std.testing.expectEqual(Phase.denied, c.phase);
    try std.testing.expectEqual(Directive.none, c.poll(10_000 * ns_per_s));
    c.configure(.{ 10, 0, 0, 136 }, 600, 20_000 * ns_per_s);
    try std.testing.expectEqual(Directive.send, c.poll(20_000 * ns_per_s));
    // a reply that arrives when nothing is outstanding is ignored as an originate mismatch
    c.configure(.{ 10, 0, 0, 136 }, 600, 0);
    try std.testing.expectEqual(Reject.originate, c.onReply(&kiss, t1, 0).rejected);
}
