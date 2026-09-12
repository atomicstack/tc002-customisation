//! tc002-ipcbench: what one message between two processes costs on this device, measured rather
//! than assumed.
//!
//! `tc002-ipcprobe` answered how *large* a datagram this kernel will carry. this answers how
//! *fast*, which is the question that decides whether a component can live in a process of its own
//! and still drive the panel: a scene that renders somewhere else has to get 2,496 bytes of pixels
//! to the renderer inside a 16.7 ms frame, and every hop is a copy, a wakeup and possibly a move
//! across the two cortex-a7 cores.
//!
//! it forks a peer over the same `SOCK_SEQPACKET` socketpair the runtime uses and measures:
//!
//!   - round-trip latency at 64 bytes (a command), 2,520 bytes (a whole frame packet) and
//!     `codec.max_message`, with the peer blocked in `recvfrom`
//!   - the same round trip with the sender waiting in `epoll_wait`, which is the loop every
//!     process in this runtime actually runs
//!   - one-way frame throughput with the peer draining as fast as it can: frames per second and
//!     megabytes per second, with the socket buffer providing the backpressure
//!
//! each of those runs twice: both processes pinned to one core, then pinned to different cores.
//! the pair is the interesting number here, because a berry vm on the second core is the whole
//! point of putting it in another process.
//!
//! nothing outside the process is touched: no device node, no file, no property.
const std = @import("std");
const sys = @import("sys/linux.zig");
const codec = @import("ipc/codec.zig");
const geometry = @import("panel/geometry.zig");
const linux = std.os.linux;

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

/// a whole frame as it travels: the 24-byte ipc header plus 52x16 rgb
const frame_packet = 24 + geometry.rgb_bytes;

const iters = 2000;
const warmup = 200;
const stream_frames = 3000;

var send_buf: [codec.max_message]u8 = undefined;
var recv_buf: [codec.max_message]u8 = undefined;
var samples: [iters]u64 = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    var line: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch return;
    _ = sys.write(1, text) catch {};
}

// -- blocking primitives: the runtime's own sockets are non-blocking behind epoll, so the bench
// -- opens its own pair and waits in the kernel rather than spinning, which would burn the core
// -- the peer is being measured on.

fn pairBlocking() ?[2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &fds);
    if (sys.errno(rc) != .SUCCESS) return null;
    return fds;
}

fn sendNow(fd: i32, bytes: []const u8) bool {
    while (true) {
        const rc = linux.sendto(fd, bytes.ptr, bytes.len, linux.MSG.NOSIGNAL, null, 0);
        switch (sys.errno(rc)) {
            .SUCCESS => return rc == bytes.len,
            .INTR => continue,
            else => return false,
        }
    }
}

fn recvNow(fd: i32, buf: []u8) ?usize {
    while (true) {
        const rc = linux.recvfrom(fd, buf.ptr, buf.len, 0, null, null);
        switch (sys.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else rc,
            .INTR => continue,
            else => return null,
        }
    }
}

/// pin this process to one core. false when the kernel refuses, which the caller reports rather
/// than hides: an unpinned run measures something else.
fn pinTo(cpu: u5) bool {
    const mask: usize = @as(usize, 1) << cpu;
    const rc = linux.syscall3(.sched_setaffinity, 0, @sizeOf(usize), @intFromPtr(&mask));
    return sys.errno(rc) == .SUCCESS;
}

// -- statistics

const Stats = struct {
    min: u64,
    p50: u64,
    p90: u64,
    p99: u64,
    max: u64,
    mean: u64,

    fn of(xs: []u64) Stats {
        std.mem.sort(u64, xs, {}, std.sort.asc(u64));
        var total: u64 = 0;
        for (xs) |x| total += x;
        return .{
            .min = xs[0],
            .p50 = xs[xs.len / 2],
            .p90 = xs[xs.len * 90 / 100],
            .p99 = xs[xs.len * 99 / 100],
            .max = xs[xs.len - 1],
            .mean = total / xs.len,
        };
    }

    fn report(self: Stats, label: []const u8) void {
        out("  {s:<34} min {d:>5}  p50 {d:>5}  p90 {d:>5}  p99 {d:>6}  max {d:>7}  mean {d:>5} us\n", .{
            label,
            self.min / 1000,
            self.p50 / 1000,
            self.p90 / 1000,
            self.p99 / 1000,
            self.max / 1000,
            self.mean / 1000,
        });
    }

    /// the same numbers in nanoseconds, for the sub-microsecond cases
    fn reportNs(self: Stats, label: []const u8) void {
        out("  {s:<34} min {d:>5}  p50 {d:>5}  p90 {d:>5}  p99 {d:>6}  max {d:>7}  mean {d:>5} ns\n", .{
            label, self.min, self.p50, self.p90, self.p99, self.max, self.mean,
        });
    }
};

// -- the peer

const stop_sentinel = 1;

fn childEcho(fd: i32, cpu: ?u5) noreturn {
    if (cpu) |c| _ = pinTo(c);
    var buf: [codec.max_message]u8 = undefined;
    while (true) {
        const n = recvNow(fd, &buf) orelse sys.exit(0);
        if (n == stop_sentinel) sys.exit(0);
        if (!sendNow(fd, buf[0..n])) sys.exit(0);
    }
}

fn childDrain(fd: i32, cpu: ?u5) noreturn {
    if (cpu) |c| _ = pinTo(c);
    var buf: [codec.max_message]u8 = undefined;
    var count: u32 = 0;
    while (true) {
        const n = recvNow(fd, &buf) orelse break;
        if (n == stop_sentinel) break;
        count += 1;
    }
    var reply: [4]u8 = undefined;
    std.mem.writeInt(u32, &reply, count, .little);
    _ = sendNow(fd, &reply);
    sys.exit(0);
}

const Role = enum { echo, drain };

/// fork a peer on `peer_cpu`, returning the parent's end of the pair and the child's pid
fn spawnPeer(role: Role, peer_cpu: ?u5) ?struct { fd: i32, pid: sys.Pid } {
    const fds = pairBlocking() orelse return null;
    const pid = sys.fork() catch return null;
    if (pid == 0) {
        sys.close(fds[0]);
        switch (role) {
            .echo => childEcho(fds[1], peer_cpu),
            .drain => childDrain(fds[1], peer_cpu),
        }
    }
    sys.close(fds[1]);
    return .{ .fd = fds[0], .pid = pid };
}

fn reap(fd: i32, pid: sys.Pid) void {
    _ = sendNow(fd, send_buf[0..stop_sentinel]);
    sys.close(fd);
    var spins: u32 = 0;
    while (spins < 1000) : (spins += 1) {
        if ((sys.waitNoHang(pid) catch null) != null) return;
        sys.nanosleep(1_000_000);
    }
    sys.kill(pid, .KILL);
    _ = sys.waitNoHang(pid) catch {};
}

// -- the measurements

fn benchRtt(size: usize, peer_cpu: ?u5, use_epoll: bool) ?Stats {
    const peer = spawnPeer(.echo, peer_cpu) orelse return null;
    defer reap(peer.fd, peer.pid);

    var ep: i32 = -1;
    if (use_epoll) {
        ep = sys.epollCreate() catch return null;
        sys.epollAdd(ep, peer.fd, linux.EPOLL.IN, 0) catch return null;
    }
    defer if (use_epoll) sys.close(ep);

    for (send_buf[0..size], 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    var i: usize = 0;
    while (i < warmup + iters) : (i += 1) {
        const t0 = sys.monotonicNs();
        if (!sendNow(peer.fd, send_buf[0..size])) return null;
        if (use_epoll) {
            var events: [1]sys.Event = undefined;
            _ = sys.epollWait(ep, &events, 1000) catch return null;
        }
        const n = recvNow(peer.fd, &recv_buf) orelse return null;
        const t1 = sys.monotonicNs();
        if (n != size) return null;
        if (i >= warmup) samples[i - warmup] = t1 -| t0;
    }
    return Stats.of(samples[0..iters]);
}

fn benchStream(label: []const u8, peer_cpu: ?u5) void {
    const peer = spawnPeer(.drain, peer_cpu) orelse {
        out("  {s}: could not fork a peer\n", .{label});
        return;
    };

    for (send_buf[0..frame_packet], 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);

    const t0 = sys.monotonicNs();
    var sent: u32 = 0;
    while (sent < stream_frames) : (sent += 1) {
        if (!sendNow(peer.fd, send_buf[0..frame_packet])) break;
    }
    _ = sendNow(peer.fd, send_buf[0..stop_sentinel]);
    const got = recvNow(peer.fd, &recv_buf);
    const t1 = sys.monotonicNs();
    const drained = if (got) |n| (if (n == 4) std.mem.readInt(u32, recv_buf[0..4], .little) else 0) else 0;

    const elapsed_us = (t1 -| t0) / 1000;
    if (elapsed_us == 0 or drained == 0) {
        out("  {s}: no result\n", .{label});
    } else {
        const fps = @as(u64, drained) * 1_000_000 / elapsed_us;
        const kb_s = @as(u64, drained) * frame_packet * 1_000_000 / elapsed_us / 1024;
        const per_frame_ns = (t1 -| t0) / drained;
        out("  {s:<13} {d} frame packets in {d} ms: {d} frames/s, {d} kb/s, {d} ns per frame\n", .{ label, drained, elapsed_us / 1000, fps, kb_s, per_frame_ns });
    }
    sys.close(peer.fd);
    _ = sys.waitNoHang(peer.pid) catch {};
}

pub fn main(_: std.process.Init.Minimal) u8 {
    var cpu_buf: [64]u8 = undefined;
    const online = sys.readFile("/sys/devices/system/cpu/online", &cpu_buf) catch "unknown\n";
    out("tc002-ipcbench: one message between two processes, on this device\n", .{});
    out("cpus online: {s}", .{online});
    out("frame packet is {d} bytes ({d} rgb + 24 header); {d} round trips per row after {d} warmup\n\n", .{ frame_packet, geometry.rgb_bytes, iters, warmup });

    const pinned = pinTo(0);
    if (!pinned) out("note: sched_setaffinity refused; both rows below are unpinned\n\n", .{});

    const Row = struct { label: []const u8, size: usize, epoll: bool };
    const rows = [_]Row{
        .{ .label = "64 b, blocking recv", .size = 64, .epoll = false },
        .{ .label = "frame packet, blocking recv", .size = frame_packet, .epoll = false },
        .{ .label = "8192 b, blocking recv", .size = codec.max_message, .epoll = false },
        .{ .label = "frame packet, epoll then recv", .size = frame_packet, .epoll = true },
    };

    out("round trip, both processes on core 0:\n", .{});
    for (rows) |r| {
        _ = pinTo(0);
        if (benchRtt(r.size, 0, r.epoll)) |s| s.report(r.label) else out("  {s}: failed\n", .{r.label});
    }

    out("\nround trip, sender on core 0 and peer on core 1:\n", .{});
    for (rows) |r| {
        _ = pinTo(0);
        if (benchRtt(r.size, 1, r.epoll)) |s| s.report(r.label) else out("  {s}: failed\n", .{r.label});
    }

    out("\none-way frame stream, peer draining:\n", .{});
    _ = pinTo(0);
    benchStream("same core:", 0);
    _ = pinTo(0);
    benchStream("cross core:", 1);

    return 0;
}
