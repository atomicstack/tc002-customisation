//! tc002-ntfy: the ntfy subscriber (https://docs.ntfy.sh/subscribe/api/). the supervisor spawns
//! it as uid 1001 with the ipc socket on fd 3 and sends the settings once; it then keeps a json
//! stream open to the topic, over plain http or tls 1.3 (the isrg root x1 is built in for the
//! official service and any server with a let's encrypt certificate; an extra ca or `insecure`
//! covers a self-hosted one), and turns each message into a notification for the panel. blocking
//! io in a process of its own: reconnects with backoff, `since=<last id>` catches up after a gap.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const messages = @import("ipc/messages.zig");
const codec = @import("ipc/codec.zig");
const config = @import("supervisor/config.zig");
const ntfy_url = @import("ntfy/url.zig");
const http = @import("ntfy/http.zig");
const message = @import("ntfy/message.zig");
const tls = std.crypto.tls;

/// ISRG Root X1 (sha256 96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6),
/// valid to 2035: the root of ntfy.sh's chain and of every let's encrypt certificate
const root_x1 = @embedFile("ntfy/isrg-root-x1.der");
const supervisor_fd: sys.Fd = 3;
/// ntfy sends a keepalive every 45 s: twice that without a byte means the stream is dead
const read_timeout_s: u32 = 90;
const max_backoff_s: u64 = 60;

var packet_buf: [codec.max_message]u8 = undefined;
var out_buf: [codec.max_message]u8 = undefined;
var heap: [256 * 1024]u8 = undefined;
var sock_rbuf: [tls.Client.min_buffer_len]u8 = undefined;
var sock_wbuf: [tls.Client.min_buffer_len]u8 = undefined;
var tls_rbuf: [tls.Client.min_buffer_len]u8 = undefined;
var tls_wbuf: [tls.Client.min_buffer_len]u8 = undefined;
var line_buf: [4096]u8 = undefined;
var arena_buf: [4096]u8 = undefined;
var der_buf: [4096]u8 = undefined;

const State = struct {
    cfg: messages.NtfyConfig,
    count: u32 = 0,
    last_id: [message.max_id]u8 = undefined,
    last_id_len: u8 = 0,
};

pub const Failure = error{ BadUrl, Dns, Connect, Tls, Certificate, Unauthorized, NotFound, HttpStatus, Stream, Request };

fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&req, null);
}

fn send(msg: messages.Message) void {
    const packet = messages.encodePacket(msg, 0, 0, &out_buf) catch return;
    sys.sendPacket(supervisor_fd, packet) catch {};
}

fn report(state: u8, count: u32, err: []const u8) void {
    send(.{ .ntfy_status = .{ .state = state, .messages = count, .err = config.Text.init(err[0..@min(err.len, config.text_max)]) } });
}

/// the settings arrive as the first packet on fd 3
fn waitConfig() !messages.NtfyConfig {
    while (true) {
        const packet = (try sys.recvPacket(supervisor_fd, &packet_buf)) orelse {
            sleepMs(20);
            continue;
        };
        const p = messages.decodePacket(packet) catch continue;
        switch (p.message) {
            .ntfy_config => |c| return c,
            else => {},
        }
    }
}

fn failureText(e: Failure) []const u8 {
    return switch (e) {
        error.BadUrl => "bad url",
        error.Dns => "dns lookup failed",
        error.Connect => "connect failed",
        error.Tls => "tls handshake failed",
        error.Certificate => "certificate rejected",
        error.Unauthorized => "unauthorized: check the token or password",
        error.NotFound => "not found: check the url and topic",
        error.HttpStatus => "unexpected http status",
        error.Stream => "stream error or timeout",
        error.Request => "request failed",
    };
}

fn resolve(io: std.Io, host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host, port)) |a| return a else |_| {}
    const hn = try std.Io.net.HostName.init(host);
    var qbuf: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&qbuf);
    try hn.lookup(io, &queue, .{ .port = port, .family = .ip4 });
    var addr: ?std.Io.net.IpAddress = null;
    while (queue.getOne(io)) |r| {
        switch (r) {
            .address => |a| if (addr == null) {
                addr = a;
            },
            .canonical_name => {},
        }
    } else |_| {}
    return addr orelse error.NoAddress;
}

/// the der certificates of a pem text, appended to the bundle one by one
fn addPem(bundle: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, pem: []const u8, now_sec: i64) !void {
    var rest = pem;
    while (std.mem.indexOf(u8, rest, "-----BEGIN CERTIFICATE-----")) |start| {
        const body_start = start + "-----BEGIN CERTIFICATE-----".len;
        const end = std.mem.indexOf(u8, rest[body_start..], "-----END CERTIFICATE-----") orelse return error.BadPem;
        const body = rest[body_start .. body_start + end];
        var compact_len: usize = 0;
        for (body) |ch| if (!std.ascii.isWhitespace(ch)) {
            if (compact_len == der_buf.len) return error.BadPem;
            der_buf[compact_len] = ch;
            compact_len += 1;
        };
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(der_buf[0..compact_len]);
        const at: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.resize(gpa, bundle.bytes.items.len + decoded_len);
        try std.base64.standard.Decoder.decode(bundle.bytes.items[at..], der_buf[0..compact_len]);
        try bundle.parseCert(gpa, at, now_sec);
        rest = rest[body_start + end + "-----END CERTIFICATE-----".len ..];
    }
}

fn addDer(bundle: *std.crypto.Certificate.Bundle, gpa: std.mem.Allocator, der: []const u8, now_sec: i64) !void {
    const at: u32 = @intCast(bundle.bytes.items.len);
    try bundle.bytes.appendSlice(gpa, der);
    try bundle.parseCert(gpa, at, now_sec);
}

/// one connection: subscribe and forward messages until the stream ends or fails
fn subscribe(st: *State) Failure!void {
    const n = &st.cfg.ntfy;
    const u = ntfy_url.parse(n.url.slice()) catch return error.BadUrl;
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const gpa = fba.allocator();

    const address = resolve(io, u.host, u.port) catch return error.Dns;
    var stream = address.connect(io, .{ .mode = .stream }) catch return error.Connect;
    defer stream.close(io);
    // a dead stream shows as a read that times out
    const tv = linux.timeval{ .sec = read_timeout_s, .usec = 0 };
    _ = linux.setsockopt(stream.socket.handle, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    var sr = stream.reader(io, &sock_rbuf);
    var sw = stream.writer(io, &sock_wbuf);

    var client: tls.Client = undefined;
    var reader: *std.Io.Reader = &sr.interface;
    var writer: *std.Io.Writer = &sw.interface;
    if (u.tls) {
        const now = std.Io.Timestamp.now(io, .real);
        const now_sec: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
        var bundle: std.crypto.Certificate.Bundle = .empty;
        addDer(&bundle, gpa, root_x1, now_sec) catch return error.Certificate;
        if (st.cfg.ca_len > 0) addPem(&bundle, gpa, st.cfg.caSlice(), now_sec) catch return error.Certificate;
        var lock: std.Io.RwLock = .init;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.randomSecure(&entropy) catch return error.Tls;
        client = tls.Client.init(&sr.interface, &sw.interface, .{
            .host = if (n.insecure) .no_verification else .{ .explicit = u.host },
            .ca = if (n.insecure) .no_verification else .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } },
            .write_buffer = &tls_wbuf,
            .read_buffer = &tls_rbuf,
            .entropy = &entropy,
            .realtime_now = now,
        }) catch |e| {
            const name = @errorName(e);
            log.warn("tls: {s}", .{name});
            return if (std.mem.indexOf(u8, name, "Certificate") != null or e == error.TlsAlert) error.Certificate else error.Tls;
        };
        reader = &client.reader;
        writer = &client.writer;
    }

    // the request: the topic's json stream, catching up from the last message seen
    var req: [1024]u8 = undefined;
    var auth_buf: [200]u8 = undefined;
    var auth: []const u8 = "";
    if (n.token.len > 0) {
        auth = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}\r\n", .{n.token.slice()}) catch return error.Request;
    } else if (n.username.len > 0) {
        var pair: [130]u8 = undefined;
        const p = std.fmt.bufPrint(&pair, "{s}:{s}", .{ n.username.slice(), n.password.slice() }) catch return error.Request;
        var enc: [176]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&enc, p);
        auth = std.fmt.bufPrint(&auth_buf, "Authorization: Basic {s}\r\n", .{b64}) catch return error.Request;
    }
    var since_buf: [48]u8 = undefined;
    const since: []const u8 = if (st.last_id_len > 0) (std.fmt.bufPrint(&since_buf, "?since={s}", .{st.last_id[0..st.last_id_len]}) catch "") else "";
    const text = std.fmt.bufPrint(&req, "GET {s}/{s}/json{s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: tc002-ntfy\r\nAccept: application/x-ndjson\r\n{s}Connection: keep-alive\r\n\r\n", .{ u.prefix, n.topic.slice(), since, u.host, auth }) catch return error.Request;
    writer.writeAll(text) catch return error.Request;
    writer.flush() catch return error.Request;
    sw.interface.flush() catch return error.Request;

    const head = http.readHead(reader) catch return error.Stream;
    switch (head.status) {
        200 => {},
        401, 403 => return error.Unauthorized,
        404 => return error.NotFound,
        else => {
            log.warn("http status {d}", .{head.status});
            return error.HttpStatus;
        },
    }
    log.info("subscribed to {s}/{s}{s}", .{ u.host, n.topic.slice(), since });
    report(2, st.count, "");
    var body = http.Body.init(reader, head);
    while (body.nextLine(&line_buf) catch return error.Stream) |line| {
        if (line.len == 0) continue;
        const parsed = message.parse(line, &arena_buf) catch {
            log.warn("unreadable line ({d} bytes)", .{line.len});
            continue;
        };
        if (parsed.event != .message) continue;
        const note = parsed.notification orelse continue;
        st.last_id_len = note.id_len;
        @memcpy(st.last_id[0..note.id_len], note.idSlice());
        send(.{ .notify = messages.Notify.init(note.textSlice(), note.colour, n.duration_s, .{}) });
        st.count += 1;
        log.info("message {d}: {d} characters, priority colour {x:0>2}{x:0>2}{x:0>2}", .{ st.count, note.len, note.colour[0], note.colour[1], note.colour[2] });
        report(2, st.count, "");
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = init;
    log.program = "tc002-ntfy";
    var st = State{ .cfg = waitConfig() catch |e| {
        log.err("no settings received: {s}", .{sys.errText(e)});
        return 1;
    } };
    if (!st.cfg.ntfy.enabled) {
        report(0, 0, "");
        return 0;
    }
    var backoff_s: u64 = 1;
    while (true) {
        report(1, st.count, "");
        const started = sys.monotonicNs();
        if (subscribe(&st)) |_| {
            log.info("stream closed by the server; reconnecting", .{});
            backoff_s = 1;
            sleepMs(1000);
        } else |e| {
            const text = failureText(e);
            log.warn("{s}; retrying in {d} s", .{ text, backoff_s });
            report(3, st.count, text);
            sleepMs(backoff_s * 1000);
            // a long-lived connection that then failed starts the backoff over
            backoff_s = if (sys.monotonicNs() - started > 60 * std.time.ns_per_s) 1 else @min(backoff_s * 2, max_backoff_s);
        }
    }
}
