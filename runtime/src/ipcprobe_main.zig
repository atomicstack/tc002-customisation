//! tc002-ipcprobe: the largest datagram this kernel will carry over the ipc socket, measured on
//! the device rather than assumed from the host.
//!
//! every protocol decision in this runtime is bounded by that number: `codec.max_message` sizes
//! every packet buffer in four binaries, and a document that does not fit one datagram has to be
//! chunked, which costs atomicity. linux bounds an AF_UNIX SOCK_SEQPACKET datagram by the socket's
//! send buffer, and the default is a `/proc/sys/net` tunable rather than a constant, so the answer
//! belongs to the device.
//!
//! it creates the same socketpair the supervisor uses (`socketpairSeqpacket`, so the flags match),
//! sends a filled datagram at each size and reads it back, checking the length and the bytes. the
//! first size that fails is the ceiling. nothing outside the process is touched.
const std = @import("std");
const sys = @import("sys/linux.zig");
const codec = @import("ipc/codec.zig");
const linux = std.os.linux;

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const sizes = [_]usize{ 1024, 2048, 4096, codec.max_message, 16384, 32768, 65536, 131072, 262144 };

var send_buf: [sizes[sizes.len - 1]]u8 = undefined;
var recv_buf: [sizes[sizes.len - 1]]u8 = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    var line: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch return;
    _ = sys.write(1, text) catch {};
}

/// send one datagram of `n` bytes and read it back: true when every byte survived intact
fn roundTrip(a: sys.Fd, b: sys.Fd, n: usize) !bool {
    // a pattern that catches truncation and misalignment, not just a wrong length
    for (send_buf[0..n], 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    sys.sendPacket(a, send_buf[0..n]) catch |e| {
        out("  {d:>6} bytes: send failed, {s}\n", .{ n, @errorName(e) });
        return false;
    };
    const got = sys.recvPacket(b, &recv_buf) catch |e| {
        out("  {d:>6} bytes: receive failed, {s}\n", .{ n, @errorName(e) });
        return false;
    } orelse {
        out("  {d:>6} bytes: nothing arrived\n", .{n});
        return false;
    };
    if (got.len != n or !std.mem.eql(u8, got, send_buf[0..n])) {
        out("  {d:>6} bytes: came back {d} bytes and {s}\n", .{ n, got.len, if (got.len == n) "altered" else "truncated" });
        return false;
    }
    out("  {d:>6} bytes: ok\n", .{n});
    return true;
}

pub fn main(_: std.process.Init.Minimal) u8 {
    const fds = sys.socketpairSeqpacket() catch |e| {
        out("socketpair failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    var sndbuf: u32 = 0;
    var len: u32 = @sizeOf(u32);
    const rc = linux.getsockopt(fds[0], linux.SOL.SOCKET, linux.SO.SNDBUF, @ptrCast(&sndbuf), &len);
    if (sys.errno(rc) == .SUCCESS) out("SO_SNDBUF {d} bytes\n", .{sndbuf}) else out("SO_SNDBUF unavailable\n", .{});
    out("codec.max_message is {d}; a datagram of each size, sent and read back:\n", .{codec.max_message});

    var largest: usize = 0;
    for (sizes) |n| {
        if (roundTrip(fds[0], fds[1], n) catch false) largest = n else break;
    }
    out("largest datagram that round-tripped: {d} bytes\n", .{largest});
    if (largest >= codec.max_message) {
        out("verdict: the ipc limit of {d} fits with {d} bytes to spare\n", .{ codec.max_message, largest - codec.max_message });
        return 0;
    }
    out("verdict: THE IPC LIMIT OF {d} DOES NOT FIT; the largest is {d}\n", .{ codec.max_message, largest });
    return 1;
}
