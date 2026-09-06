//! tc002-memdump: a maintenance tool (root, over adb) that streams a snapshot of one process's
//! memory to stdout: /proc/<pid>/maps, smaps, status and statm as text, then every readable
//! mapping's bytes from /proc/<pid>/mem and its per-page residency bits from /proc/<pid>/pagemap.
//! nothing is written to the device. the process keeps running; the snapshot may tear.
//!
//! container (little-endian): magic "TCMD", u32 version 2, then records of
//!   u8 kind, u64 length, payload
//!   kinds: 1 maps text, 2 smaps text, 3 status text, 4 statm text,
//!          6 pagemap: u64 start, u64 end, u64 entries[(end-start)/4096]
//!          7 sparse mapping: u64 start, u64 end, [4]u8 perms, u64 offset, u16 path_len, path,
//!                            u64 npages, then per page: u8 present (1) followed by 4096 bytes, or 0
//! with a second argument `hex`, the container is hex-encoded with a newline every 128 bytes so it
//! survives `adb shell` (strip cr/lf and decode on the host).
const std = @import("std");
const sys = @import("sys/linux.zig");
const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };


const chunk = 64 * 1024;
const max_mapping = 512 * 1024 * 1024;
var buf: [chunk]u8 = undefined;
var text_buf: [64 * 1024]u8 = undefined;

var hex_mode = false;
var hex_col: usize = 0;
var hex_buf: [chunk * 2 + chunk / 64]u8 = undefined;
const hex_digits = "0123456789abcdef";

fn out(bytes: []const u8) void {
    if (!hex_mode) {
        sys.writeAll(1, bytes) catch sys.exit(3);
        return;
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(bytes.len - off, chunk);
        var w: usize = 0;
        for (bytes[off .. off + n]) |b| {
            hex_buf[w] = hex_digits[b >> 4];
            hex_buf[w + 1] = hex_digits[b & 15];
            w += 2;
            hex_col += 1;
            if (hex_col == 128) {
                hex_buf[w] = '\n';
                w += 1;
                hex_col = 0;
            }
        }
        sys.writeAll(1, hex_buf[0..w]) catch sys.exit(3);
        off += n;
    }
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
    hex_mode = raw.len > 2 and std.mem.eql(u8, std.mem.span(raw[2]), "hex");
    out("TCMD");
    outInt(u32, 2);
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
        const pages: u64 = (end - start) / 4096;
        // residency first: only present pages are read and transferred
        var present_count: u64 = 0;
        var page: u64 = 0;
        while (page < pages) {
            const n: usize = @intCast(@min(pages - page, chunk / 8));
            const rc = if (pagemap_fd >= 0) linux.pread(pagemap_fd, &buf, n * 8, @intCast((start / 4096 + page) * 8)) else 0;
            if (pagemap_fd < 0 or sys.errno(rc) != .SUCCESS or rc != n * 8) {
                // no pagemap: treat every page as present so nothing is silently lost
                @memset(buf[0 .. n * 8], 0xff);
            }
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const entry = std.mem.readInt(u64, buf[i * 8 ..][0..8], .little);
                if (entry >> 63 != 0) present_count += 1;
            }
            page += n;
        }
        var perm4: [4]u8 = .{ '-', '-', '-', '-' };
        @memcpy(&perm4, perms[0..4]);
        record(7, 8 + 8 + 4 + 8 + 2 + trimmed.len + 8 + pages + present_count * 4096);
        outInt(u64, start);
        outInt(u64, end);
        out(&perm4);
        outInt(u64, offset);
        outInt(u16, @intCast(trimmed.len));
        out(trimmed);
        outInt(u64, pages);
        page = 0;
        while (page < pages) : (page += 1) {
            var entry: u64 = 0xffff_ffff_ffff_ffff;
            if (pagemap_fd >= 0) {
                var e: [8]u8 = undefined;
                const rc = linux.pread(pagemap_fd, &e, 8, @intCast((start / 4096 + page) * 8));
                if (sys.errno(rc) == .SUCCESS and rc == 8) entry = std.mem.readInt(u64, &e, .little);
            }
            if (entry >> 63 == 0) {
                out(&[1]u8{0});
                continue;
            }
            out(&[1]u8{1});
            const rc = linux.pread(mem_fd, &buf, 4096, @intCast(start + page * 4096));
            if (sys.errno(rc) != .SUCCESS or rc != 4096) @memset(buf[0..4096], 0);
            out(buf[0..4096]);
        }
        if (pagemap_fd >= 0) {
            record(6, 8 + 8 + pages * 8);
            outInt(u64, start);
            outInt(u64, end);
            page = 0;
            while (page < pages) {
                const n: usize = @intCast(@min(pages - page, chunk / 8));
                const rc = linux.pread(pagemap_fd, &buf, n * 8, @intCast((start / 4096 + page) * 8));
                if (sys.errno(rc) != .SUCCESS or rc != n * 8) @memset(buf[0 .. n * 8], 0);
                out(buf[0 .. n * 8]);
                page += n;
            }
        }
    }
    if (hex_mode and hex_col != 0) sys.writeAll(1, "\n") catch {};
    return 0;
}
