//! a bounded, allocation-free logger: one write(2) per line, prefixed with the program name and
//! monotonic milliseconds. every message is lowercase by convention.
const std = @import("std");
const builtin = @import("builtin");

pub var program: []const u8 = "tc002";

/// an optional in-process consumer of every emitted line (without its newline), used by the
/// supervisor to feed its ring; the line is still written to stderr first.
pub var sink: ?*const fn ([]const u8) void = null;

fn nowMs() u64 {
    if (builtin.os.tag != .linux) return 0;
    const linux = std.os.linux;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
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
    const head = std.fmt.bufPrint(&buf, "{s} {d} {s} ", .{ program, nowMs(), level }) catch return;
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
