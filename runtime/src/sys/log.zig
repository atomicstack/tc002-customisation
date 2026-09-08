//! a bounded, allocation-free logger: one write(2) per line, prefixed with a utc timestamp
//! (`[2026-09-08 04:36:30.00001]`, tens of microseconds, zero-padded so the width never
//! changes), the program name and the level. every message is lowercase by convention.
const std = @import("std");
const builtin = @import("builtin");
const civil = @import("civil.zig");

pub var program: []const u8 = "tc002";

/// an optional in-process consumer of every emitted line (without its newline), used by the
/// supervisor to feed its ring; the line is still written to stderr first.
pub var sink: ?*const fn ([]const u8) void = null;

/// unix time in nanoseconds from the realtime clock; zero where there is none (host tests).
fn nowRealtimeNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    if (ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const timestamp_len = "[2026-09-08 04:36:30.00001]".len;

/// `[yyyy-mm-dd hh:mm:ss.fffff]` in utc; the fraction is tens of microseconds, zero-padded.
pub fn formatTimestamp(buf: *[timestamp_len]u8, unix_ns: u64) []const u8 {
    const secs = unix_ns / 1_000_000_000;
    const frac = (unix_ns % 1_000_000_000) / 10_000;
    const date = civil.civilFromDays(@intCast(secs / 86400));
    const sod = secs % 86400;
    return std.fmt.bufPrint(buf, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>5}]", .{ @as(u32, @intCast(date.year)), date.month, date.day, sod / 3600, (sod / 60) % 60, sod % 60, frac }) catch unreachable;
}

test "timestamps are utc with a fixed width" {
    var buf: [timestamp_len]u8 = undefined;
    try std.testing.expectEqualStrings("[2026-09-08 04:36:30.00001]", formatTimestamp(&buf, 1788842190 * std.time.ns_per_s + 10_000));
    try std.testing.expectEqualStrings("[1970-01-01 00:00:00.00000]", formatTimestamp(&buf, 0));
    try std.testing.expectEqualStrings("[2024-02-29 23:59:59.99999]", formatTimestamp(&buf, 1709251199 * std.time.ns_per_s + 999_999_999));
}

fn writeAll(bytes: []const u8) void {
    if (builtin.os.tag != .linux) {
        std.debug.print("{s}", .{bytes});
        return;
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.os.linux.write(2, bytes[off..].ptr, bytes.len - off);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return;
        off += rc;
    }
}

fn emit(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [320]u8 = undefined;
    var ts: [timestamp_len]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "{s} {s} {s} ", .{ formatTimestamp(&ts, nowRealtimeNs()), program, level }) catch return;
    const body = std.fmt.bufPrint(buf[head.len..], fmt ++ "\n", args) catch blk: {
        // the message did not fit: keep what did and mark the cut
        const tail = " ...\n";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf[head.len..];
    };
    writeAll(buf[0 .. head.len + body.len]);
    if (sink) |s| s(buf[0 .. head.len + body.len - 1]);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit("info", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit("warn", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit("error", fmt, args);
}
