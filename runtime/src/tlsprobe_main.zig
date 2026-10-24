//! tc002-tlsprobe: makes one MQTT connection to a real broker over `net/tls_link.zig`, the same path
//! netd uses. It connects without blocking, runs the handshake, sends a CONNECT through the link and
//! prints the broker's CONNACK, timing each step.
//!
//!   tc002-tlsprobe <ipv4> <port> <ca.pem> [username password-file]
//!
//! Without credentials, a broker that requires them answers with return code 5 (not authorised).
//! That still proves the whole path works: a record each way, decrypted and parsed. It's a
//! diagnostic tool, built on request and never installed on the device.
const std = @import("std");
const sys = @import("sys/linux.zig");
const api = @import("net/api.zig");
const mqtt = @import("net/mqtt.zig");
const tls_link = @import("net/tls_link.zig");
const linux = std.os.linux;

pub const std_options: std.Options = .{ .enable_segfault_handler = false };

var link: tls_link.Link = .{};
var ca_buf: [api.max_ca]u8 = undefined;
var pw_buf: [128]u8 = undefined;

fn out(comptime fmt: []const u8, args: anytype) void {
    var line: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt ++ "\n", args) catch return;
    _ = sys.write(1, text) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    out("error: " ++ fmt, args);
    return 1;
}

fn msSince(t0: u64) u64 {
    return (sys.monotonicNs() - t0) / std.time.ns_per_ms;
}

/// Waits up to `ms` for `events` on `fd`.
fn waitFor(fd: sys.Fd, events: i16, ms: i32) bool {
    var p = [_]linux.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const rc = linux.poll(&p, 1, ms);
    return sys.errno(rc) == .SUCCESS and rc > 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len != 4 and argv.len != 6) return fail("usage: tc002-tlsprobe <ipv4> <port> <ca.pem> [username password-file]", .{});
    const host = std.mem.span(argv[1]);
    const addr = api.parseIpv4(host) orelse return fail("not a dotted IPv4 address: {s}", .{host});
    const port = std.fmt.parseInt(u16, std.mem.span(argv[2]), 10) catch return fail("bad port", .{});
    const ca = sys.readFile(argv[3], &ca_buf) catch |e| return fail("cannot read {s}: {s}", .{ argv[3], sys.errText(e) });
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    if (argv.len == 6) {
        username = std.mem.span(argv[4]);
        const pw = sys.readFile(argv[5], &pw_buf) catch |e| return fail("cannot read the password file: {s}", .{sys.errText(e)});
        password = std.mem.trimEnd(u8, pw, "\r\n");
    }

    const t0 = sys.monotonicNs();
    const fd = sys.tcpConnect(addr, port) catch |e| return fail("connect: {s}", .{sys.errText(e)});
    defer sys.close(fd);
    if (!waitFor(fd, linux.POLL.OUT, 5000) or !sys.socketConnected(fd)) return fail("TCP connect to {s}:{d} failed", .{ host, port });
    out("TCP connected in {d} ms", .{msSince(t0)});

    const t1 = sys.monotonicNs();
    link.handshake(fd, ca, host) catch |e| return fail("{s} ({s})", .{ tls_link.handshakeErrorText(e), link.last_error });
    out("TLS handshake in {d} ms: {s}", .{ msSince(t1), @tagName(link.client.tls_version) });

    var pkt: [512]u8 = undefined;
    const n = mqtt.encodeConnect(&pkt, .{ .client_id = "tc002-tlsprobe", .keepalive_s = 30, .username = username, .password = password }) catch return fail("CONNECT packet too large", .{});
    const t2 = sys.monotonicNs();
    var off: usize = 0;
    while (off < n) off += link.encrypt(pkt[off..n]) catch return fail("encrypt failed", .{});
    while (true) {
        link.send() catch |e| switch (e) {
            error.WouldBlock => {
                _ = waitFor(fd, linux.POLL.OUT, 5000);
                continue;
            },
            else => return fail("send failed", .{}),
        };
        break;
    }

    var in: [256]u8 = undefined;
    var have: usize = 0;
    while (true) {
        const got = link.read(in[have..]) catch |e| switch (e) {
            error.WouldBlock => {
                if (!waitFor(fd, linux.POLL.IN, 5000)) return fail("no reply from the broker in 5 s", .{});
                continue;
            },
            error.Closed => return fail("the broker closed the connection after {d} bytes", .{have}),
            else => return fail("read failed: {s}", .{link.last_error}),
        };
        have += got;
        const d = mqtt.decode(in[0..have]) catch |e| switch (e) {
            error.Incomplete => continue,
            else => return fail("malformed reply", .{}),
        };
        switch (d.packet) {
            .connack => |c| {
                out("CONNACK in {d} ms: return code {d}{s}", .{ msSince(t2), c.return_code, if (c.return_code == 0) " (accepted)" else if (c.return_code == 5) " (not authorised)" else "" });
                return 0;
            },
            else => return fail("expected a CONNACK", .{}),
        }
    }
}
