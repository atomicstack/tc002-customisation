//! tc002-memdump: a maintenance tool (root, over adb) that streams a snapshot of one process's
//! memory to stdout: /proc/<pid>/maps, smaps, status and statm as text, then every readable
//! mapping's bytes from /proc/<pid>/mem and its per-page residency bits from /proc/<pid>/pagemap.
//! nothing is written to the device. the process keeps running; the snapshot may tear.
//!
//! container (little-endian): magic "TCMD", u32 version 1, then records of
//!   u8 kind, u64 length, payload
//!   kinds: 1 maps text, 2 smaps text, 3 status text, 4 statm text,
//!          5 mapping: u64 start, u64 end, [4]u8 perms, u64 offset, u16 path_len, path, u64 data_len, data
//!          6 pagemap: u64 start, u64 end, u64 entries[(end-start)/4096]
const std = @import("std");
const sys = @import("sys/linux.zig");
const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };


const chunk = 64 * 1024;
const max_mapping = 16 * 1024 * 1024;
var buf: [chunk]u8 = undefined;
var text_buf: [64 * 1024]u8 = undefined;

fn out(bytes: []const u8) void {
    sys.writeAll(1, bytes) catch sys.exit(3);
}

fn outInt(comptime T: type, v: T) void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    out(&b);
}

fn record(kind: u8, len: u64) void {
    out(&[1]u8{kind});
    outInt(u64, len);
}

fn textRecord(kind: u8, comptime name: []const u8, pid: i32) void {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/" ++ name, .{pid}) catch return;
    const text = sys.readFile(p, &text_buf) catch return;
    record(kind, text.len);
    out(text);
}

fn parseHex(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 16) catch null;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const raw = init.args.vector;
    if (raw.len < 2) {
        sys.writeAll(2, "usage: tc002-memdump <pid> > dump.bin\n") catch {};
        return 2;
    }
    const pid = std.fmt.parseInt(i32, std.mem.span(raw[1]), 10) catch return 2;
    out("TCMD");
    outInt(u32, 1);
    textRecord(1, "maps", pid);
    textRecord(2, "smaps", pid);
    textRecord(3, "status", pid);
    textRecord(4, "statm", pid);

    var path: [64]u8 = undefined;
    const maps_path = std.fmt.bufPrintZ(&path, "/proc/{d}/maps", .{pid}) catch return 1;
    const maps = sys.readFile(maps_path, &text_buf) catch return 1;
    const mem_fd = sys.open(std.fmt.bufPrintZ(&path, "/proc/{d}/mem", .{pid}) catch return 1, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch {
        sys.writeAll(2, "cannot open mem\n") catch {};
        return 1;
    };
    const pagemap_fd = sys.open(std.fmt.bufPrintZ(&path, "/proc/{d}/pagemap", .{pid}) catch return 1, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch -1;

    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse continue;
        const perms = fields.next() orelse continue;
        const offset_text = fields.next() orelse continue;
        _ = fields.next(); // dev
        _ = fields.next(); // inode
        const mpath = fields.rest();
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = parseHex(range[0..dash]) orelse continue;
        const end = parseHex(range[dash + 1 ..]) orelse continue;
        const offset = parseHex(offset_text) orelse 0;
        if (end <= start or end - start > max_mapping or perms.len < 4 or perms[0] != 'r') continue;
        const trimmed = std.mem.trim(u8, mpath, " ");
        // read the bytes first into a decision: mappings that refuse (vectors, io) are recorded empty
        var data_len: u64 = 0;
        var probe = start;
        while (probe < end) {
            const want: usize = @intCast(@min(end - probe, chunk));
            const rc = linux.pread(mem_fd, &buf, want, @intCast(probe));
            if (sys.errno(rc) != .SUCCESS or rc == 0) break;
            data_len += rc;
            probe += rc;
        }
        var perm4: [4]u8 = .{ '-', '-', '-', '-' };
        @memcpy(&perm4, perms[0..4]);
        record(5, 8 + 8 + 4 + 8 + 2 + trimmed.len + 8 + data_len);
        outInt(u64, start);
        outInt(u64, end);
        out(&perm4);
        outInt(u64, offset);
        outInt(u16, @intCast(trimmed.len));
        out(trimmed);
        outInt(u64, data_len);
        var pos = start;
        var remaining = data_len;
        while (remaining > 0) {
            const want: usize = @intCast(@min(remaining, chunk));
            const rc = linux.pread(mem_fd, &buf, want, @intCast(pos));
            if (sys.errno(rc) != .SUCCESS or rc == 0) {
                // the mapping changed under us: pad so the container stays consistent
                @memset(buf[0..want], 0);
                out(buf[0..want]);
                remaining -= want;
                pos += want;
                continue;
            }
            out(buf[0..rc]);
            remaining -= rc;
            pos += rc;
        }
        if (pagemap_fd >= 0) {
            const pages = (end - start) / 4096;
            record(6, 8 + 8 + pages * 8);
            outInt(u64, start);
            outInt(u64, end);
            var page: u64 = 0;
            while (page < pages) {
                const n: usize = @intCast(@min(pages - page, chunk / 8));
                const rc = linux.pread(pagemap_fd, &buf, n * 8, @intCast((start / 4096 + page) * 8));
                if (sys.errno(rc) != .SUCCESS or rc != n * 8) {
                    @memset(buf[0 .. n * 8], 0);
                }
                out(buf[0 .. n * 8]);
                page += n;
            }
        }
    }
    return 0;
}
