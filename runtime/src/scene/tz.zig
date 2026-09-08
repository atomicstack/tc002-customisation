//! posix tz rules (`std offset [dst [offset] [,start[/time],end[/time]]]`) with `Mm.w.d` transition
//! rules, and utc -> local conversion. posix sign convention: `AEST-10` is utc+10.
const std = @import("std");

test "a bare utc rule has no dst" {
    const r = try parse("UTC0");
    try std.testing.expectEqual(@as(i32, 0), r.std_offset_s);
    try std.testing.expect(r.dst == null);
    try std.testing.expectEqual(@as(i64, 123), localFromUtc(r, 123));
}

test "a fixed positive offset with a name" {
    const r = try parse("JST-9");
    try std.testing.expectEqual(@as(i32, 9 * 3600), r.std_offset_s);
    const h = try parse("IST-5:30");
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), h.std_offset_s);
}

test "sydney: southern hemisphere dst with an end-of-rule time" {
    const r = try parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try std.testing.expectEqual(@as(i32, 10 * 3600), r.std_offset_s);
    try std.testing.expectEqual(@as(i32, 11 * 3600), r.dst.?.offset_s);
    // 2026-01-15t00:00z is summer (+11), 2026-07-15t00:00z is winter (+10)
    try std.testing.expectEqual(@as(i64, 1768435200 + 11 * 3600), localFromUtc(r, 1768435200));
    try std.testing.expectEqual(@as(i64, 1784073600 + 10 * 3600), localFromUtc(r, 1784073600));
    // dst starts 2026-10-04 02:00 aest = 2026-10-03t16:00z
    try std.testing.expectEqual(@as(i32, 10 * 3600), utcOffsetAt(r, 1791043199));
    try std.testing.expectEqual(@as(i32, 11 * 3600), utcOffsetAt(r, 1791043200));
    // dst ends 2026-04-05 03:00 aedt = 2026-04-04t16:00z
    try std.testing.expectEqual(@as(i32, 11 * 3600), utcOffsetAt(r, 1775318399));
    try std.testing.expectEqual(@as(i32, 10 * 3600), utcOffsetAt(r, 1775318400));
}

test "new york: northern hemisphere dst, default dst offset and default 02:00 time" {
    const r = try parse("EST5EDT,M3.2.0,M11.1.0");
    try std.testing.expectEqual(@as(i32, -5 * 3600), r.std_offset_s);
    try std.testing.expectEqual(@as(i32, -4 * 3600), r.dst.?.offset_s);
    // 2026-07-01t00:00z is summer (-4)
    try std.testing.expectEqual(@as(i64, 1782864000 - 4 * 3600), localFromUtc(r, 1782864000));
    // dst starts 2026-03-08 02:00 est = 07:00z; days since epoch: 2026-03-08 = 20520
    try std.testing.expectEqual(@as(i32, -5 * 3600), utcOffsetAt(r, 20520 * 86400 + 7 * 3600 - 1));
    try std.testing.expectEqual(@as(i32, -4 * 3600), utcOffsetAt(r, 20520 * 86400 + 7 * 3600));
}

test "malformed rules are rejected" {
    try std.testing.expectError(error.InvalidRule, parse(""));
    try std.testing.expectError(error.InvalidRule, parse("A1"));
    try std.testing.expectError(error.InvalidRule, parse("AEST-10AEDT"));
    try std.testing.expectError(error.InvalidRule, parse("AEST-10AEDT,M13.1.0,M4.1.0"));
    try std.testing.expectError(error.InvalidRule, parse("AEST-30"));
    try std.testing.expectError(error.InvalidRule, parse("AEST-10,M10.1.0,M4.1.0"));
}

test "civil date helpers round trip" {
    try std.testing.expectEqual(@as(i64, 20454), daysFromCivil(2026, 1, 1));
    const c = civilFromDays(20454 + 275);
    try std.testing.expectEqual(@as(i32, 2026), c.year);
    try std.testing.expectEqual(@as(u8, 10), c.month);
    try std.testing.expectEqual(@as(u8, 3), c.day);
    try std.testing.expectEqual(@as(u8, 4), weekday(20454)); // 2026-01-01 is a thursday (0 = sunday)
}

pub const Transition = struct {
    month: u8, // 1..12
    week: u8, // 1..5, 5 = last
    weekday: u8, // 0 = sunday
    time_s: i32 = 2 * 3600, // local wall time of the transition
};

pub const Dst = struct { offset_s: i32, start: Transition, end: Transition };

/// offsets are utc offsets in seconds (utc+10 = 36000), not the posix sign.
pub const Rule = struct { std_offset_s: i32, dst: ?Dst = null };

pub const utc: Rule = .{ .std_offset_s = 0 };

pub const Civil = struct { year: i32, month: u8, day: u8 };

pub const ParseError = error{InvalidRule};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn atEnd(p: *const Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *const Parser) ?u8 {
        return if (p.atEnd()) null else p.s[p.i];
    }
    fn expect(p: *Parser, c: u8) ParseError!void {
        if (p.peek() != c) return error.InvalidRule;
        p.i += 1;
    }
    /// a zone name: three or more letters, or anything in angle brackets.
    fn name(p: *Parser) ParseError!void {
        if (p.peek() == '<') {
            while (p.peek()) |c| : (p.i += 1) if (c == '>') {
                p.i += 1;
                return;
            };
            return error.InvalidRule;
        }
        const start = p.i;
        while (p.peek()) |c| : (p.i += 1) if (!std.ascii.isAlphabetic(c)) break;
        if (p.i - start < 3) return error.InvalidRule;
    }
    fn number(p: *Parser, max_digits: usize) ParseError!u32 {
        var v: u32 = 0;
        var n: usize = 0;
        while (p.peek()) |c| : (p.i += 1) {
            if (!std.ascii.isDigit(c)) break;
            if (n == max_digits) return error.InvalidRule;
            v = v * 10 + (c - '0');
            n += 1;
        }
        if (n == 0) return error.InvalidRule;
        return v;
    }
    /// `[+-]h[:mm[:ss]]` in seconds, posix sign (positive = west of utc), hours limited to `max_h`.
    fn signedTime(p: *Parser, max_h: u32) ParseError!i32 {
        var neg = false;
        if (p.peek() == '+') p.i += 1 else if (p.peek() == '-') {
            neg = true;
            p.i += 1;
        }
        const h = try p.number(3);
        if (h > max_h) return error.InvalidRule;
        var s: i32 = @intCast(h * 3600);
        if (p.peek() == ':') {
            p.i += 1;
            const m = try p.number(2);
            if (m > 59) return error.InvalidRule;
            s += @intCast(m * 60);
            if (p.peek() == ':') {
                p.i += 1;
                const sec = try p.number(2);
                if (sec > 59) return error.InvalidRule;
                s += @intCast(sec);
            }
        }
        return if (neg) -s else s;
    }
    fn transition(p: *Parser) ParseError!Transition {
        try p.expect('M');
        const m = try p.number(2);
        try p.expect('.');
        const w = try p.number(1);
        try p.expect('.');
        const d = try p.number(1);
        if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return error.InvalidRule;
        var t = Transition{ .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d) };
        if (p.peek() == '/') {
            p.i += 1;
            t.time_s = try p.signedTime(167);
        }
        return t;
    }
};

const zones = @import("zones.zig");

/// the posix rule for a timezone setting: the text itself when it parses as a rule, or the rule
/// an iana zone name (matched case-insensitively) follows from now on; null when it is neither.
/// zone rules come from the tzdata footers, so daylight saving follows each zone's current law.
pub fn resolve(text: []const u8) ?[]const u8 {
    if (parse(text)) |_| return text else |_| {}
    var rest: []const u8 = zones.blob;
    while (rest.len > 0) {
        const n = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        const after_name = rest[n + 1 ..];
        const m = std.mem.indexOfScalar(u8, after_name, 0) orelse break;
        if (std.ascii.eqlIgnoreCase(rest[0..n], text)) return after_name[0..m];
        rest = after_name[m + 1 ..];
    }
    return null;
}

test "zone names resolve to rules that parse and follow their daylight saving" {
    try std.testing.expectEqualStrings("CET-1CEST,M3.5.0,M10.5.0/3", resolve("Europe/Amsterdam").?);
    try std.testing.expectEqualStrings("AEST-10AEDT,M10.1.0,M4.1.0/3", resolve("australia/melbourne").?);
    try std.testing.expectEqualStrings("JST-9", resolve("JST-9").?);
    try std.testing.expect(resolve("Mars/Olympus") == null);
    try std.testing.expect(resolve("") == null);
    const ams = try parse(resolve("Europe/Amsterdam").?);
    try std.testing.expectEqual(@as(i32, 2 * 3600), utcOffsetAt(ams, 1782950400)); // 2026-07-01
    try std.testing.expectEqual(@as(i32, 1 * 3600), utcOffsetAt(ams, 1768435200)); // 2026-01-15
    const kolkata = try parse(resolve("Asia/Kolkata").?);
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), utcOffsetAt(kolkata, 1782950400));
    // every generated rule must be one this parser accepts
    var rest: []const u8 = zones.blob;
    var count: u32 = 0;
    while (rest.len > 0) : (count += 1) {
        const n = std.mem.indexOfScalar(u8, rest, 0) orelse break;
        const after_name = rest[n + 1 ..];
        const m = std.mem.indexOfScalar(u8, after_name, 0) orelse break;
        _ = parse(after_name[0..m]) catch return error.TestUnexpectedResult;
        rest = after_name[m + 1 ..];
    }
    try std.testing.expectEqual(@as(u32, zones.count), count);
}

/// parse a posix tz rule. dst requires explicit `,start,end` rules; implicit us rules are rejected.
pub fn parse(text: []const u8) ParseError!Rule {
    var p = Parser{ .s = text };
    try p.name();
    const std_posix = try p.signedTime(24);
    var rule = Rule{ .std_offset_s = -std_posix };
    if (p.atEnd()) return rule;
    if (p.peek() == ',') return error.InvalidRule;
    try p.name();
    var dst_posix = std_posix - 3600; // default: one hour ahead of standard time
    if (p.peek() != null and p.peek() != ',') dst_posix = try p.signedTime(24);
    if (p.atEnd()) return error.InvalidRule;
    try p.expect(',');
    const start = try p.transition();
    try p.expect(',');
    const end = try p.transition();
    if (!p.atEnd()) return error.InvalidRule;
    rule.dst = .{ .offset_s = -dst_posix, .start = start, .end = end };
    return rule;
}

// civil calendar helpers (howard hinnant's algorithms), days relative to 1970-01-01.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = @intCast(if (m <= 2) y + 1 else y), .month = m, .day = d };
}

/// 0 = sunday. 1970-01-01 was a thursday.
pub fn weekday(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (isLeap(year)) 29 else 28,
    };
}

/// the utc instant of a transition in `year`, given the utc offset in effect just before it.
fn transitionUtc(t: Transition, year: i32, offset_before_s: i32) i64 {
    const first = daysFromCivil(year, t.month, 1);
    var day: i64 = 1 + @mod(@as(i64, t.weekday) + 7 - weekday(first), 7) + (@as(i64, t.week) - 1) * 7;
    while (day > daysInMonth(year, t.month)) day -= 7;
    return (first + day - 1) * 86400 + t.time_s - offset_before_s;
}

/// the utc offset in effect at a utc instant.
pub fn utcOffsetAt(rule: Rule, utc_s: i64) i32 {
    const dst = rule.dst orelse return rule.std_offset_s;
    const year = civilFromDays(@divFloor(utc_s + rule.std_offset_s, 86400)).year;
    const start = transitionUtc(dst.start, year, rule.std_offset_s);
    const end = transitionUtc(dst.end, year, dst.offset_s);
    const in_dst = if (start < end) (utc_s >= start and utc_s < end) else (utc_s >= start or utc_s < end);
    return if (in_dst) dst.offset_s else rule.std_offset_s;
}

pub fn localFromUtc(rule: Rule, utc_s: i64) i64 {
    return utc_s + utcOffsetAt(rule, utc_s);
}
