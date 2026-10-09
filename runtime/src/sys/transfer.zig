//! what the renderer measures for a bar that watches a transfer (canvas.Watch): the paths, fixed
//! here so no caller ever names one, and the walk over a getdents64 buffer. pure; the syscalls
//! are in linux.zig.
const std = @import("std");

/// where an in-place update stages the next build (tools/tc002-run.sh push --staged)
pub const staging_dir = "/tmp/tc002.new";
/// where a flash stages its image (tools/tc002-flash.sh)
pub const image_path = "/data/update.img";

/// how often a watched transfer is measured
pub const poll_ns: u64 = 100 * std.time.ns_per_ms;

pub const dt_reg = 8;

/// the regular files in a buffer of linux_dirent64 records, one name at a time
pub const Entries = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn next(self: *Entries) ?[:0]const u8 {
        while (self.pos + 19 <= self.buf.len) {
            const rec = self.buf[self.pos..];
            const reclen = std.mem.readInt(u16, rec[16..18], .little);
            if (reclen < 20 or self.pos + reclen > self.buf.len) return null;
            self.pos += reclen;
            if (rec[18] != dt_reg) continue;
            const name = rec[19..reclen];
            const len = std.mem.indexOfScalar(u8, name, 0) orelse continue;
            return name[0..len :0];
        }
        return null;
    }
};

fn record(out: []u8, kind: u8, name: []const u8) usize {
    const reclen = std.mem.alignForward(usize, 19 + name.len + 1, 8);
    @memset(out[0..reclen], 0);
    std.mem.writeInt(u16, out[16..18], @intCast(reclen), .little);
    out[18] = kind;
    @memcpy(out[19..][0..name.len], name);
    return reclen;
}

test "the walk yields the regular files and skips the directories" {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    n += record(buf[n..], 4, ".");
    n += record(buf[n..], 4, "..");
    n += record(buf[n..], dt_reg, "tc002d");
    n += record(buf[n..], dt_reg, "libtc002-bootstrap.so");
    var it = Entries{ .buf = buf[0..n] };
    try std.testing.expectEqualStrings("tc002d", it.next().?);
    try std.testing.expectEqualStrings("libtc002-bootstrap.so", it.next().?);
    try std.testing.expect(it.next() == null);
}
