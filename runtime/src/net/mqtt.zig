//! mqtt 3.1.1 as pure logic: the packet codec (connect with will and credentials, connack,
//! publish qos 0/1, puback, subscribe/suback, pingreq/pingresp, disconnect) and a client state
//! machine driven by monotonic time (keepalive, ping timeout, bounded reconnect backoff with
//! jitter). the tcp socket lives in netd.
const std = @import("std");

pub const max_packet = 4096;

pub const PacketType = enum(u4) { connect = 1, connack = 2, publish = 3, puback = 4, subscribe = 8, suback = 9, pingreq = 12, pingresp = 13, disconnect = 14 };

pub const Error = error{ Overflow, Malformed, Incomplete };

fn writeRemainingLength(out: []u8, len: usize) Error!usize {
    var n: usize = 0;
    var v = len;
    while (true) {
        if (n >= 4 or n >= out.len) return error.Overflow;
        var byte: u8 = @intCast(v % 128);
        v /= 128;
        if (v > 0) byte |= 0x80;
        out[n] = byte;
        n += 1;
        if (v == 0) return n;
    }
}

/// returns (length, bytes used) or Incomplete when the prefix is not all there yet.
pub fn readRemainingLength(buf: []const u8) Error!struct { len: usize, used: usize } {
    var multiplier: usize = 1;
    var value: usize = 0;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return error.Incomplete;
        if (i >= 4) return error.Malformed;
        const byte = buf[i];
        value += (byte & 0x7f) * multiplier;
        multiplier *= 128;
        i += 1;
        if (byte & 0x80 == 0) return .{ .len = value, .used = i };
    }
}

fn writeString(out: []u8, s: []const u8) Error!usize {
    if (s.len > 0xffff or out.len < 2 + s.len) return error.Overflow;
    std.mem.writeInt(u16, out[0..2], @intCast(s.len), .big);
    @memcpy(out[2 .. 2 + s.len], s);
    return 2 + s.len;
}

fn readString(buf: []const u8) Error!struct { s: []const u8, used: usize } {
    if (buf.len < 2) return error.Malformed;
    const n = std.mem.readInt(u16, buf[0..2], .big);
    if (buf.len < 2 + n) return error.Malformed;
    return .{ .s = buf[2 .. 2 + n], .used = 2 + n };
}

fn frame(out: []u8, first_byte: u8, payload_len: usize) Error!usize {
    // the caller has written the variable header + payload at out[5..]; move it behind the real header
    var len_buf: [4]u8 = undefined;
    const len_n = try writeRemainingLength(&len_buf, payload_len);
    const total = 1 + len_n + payload_len;
    if (total > out.len) return error.Overflow;
    std.mem.copyForwards(u8, out[1 + len_n .. total], out[5 .. 5 + payload_len]);
    out[0] = first_byte;
    @memcpy(out[1 .. 1 + len_n], len_buf[0..len_n]);
    return total;
}

pub const Will = struct { topic: []const u8, payload: []const u8, retain: bool = true, qos: u2 = 1 };

pub const ConnectOptions = struct {
    client_id: []const u8,
    keepalive_s: u16 = 30,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    will: ?Will = null,
    clean_session: bool = true,
};

pub fn encodeConnect(out: []u8, o: ConnectOptions) Error!usize {
    if (out.len < 5) return error.Overflow;
    var p: usize = 5;
    p += try writeString(out[p..], "MQTT");
    if (out.len < p + 4) return error.Overflow;
    out[p] = 4; // protocol level 3.1.1
    var flags: u8 = 0;
    if (o.clean_session) flags |= 0x02;
    if (o.will) |w| {
        flags |= 0x04 | (@as(u8, w.qos) << 3);
        if (w.retain) flags |= 0x20;
    }
    if (o.password != null) flags |= 0x40;
    if (o.username != null) flags |= 0x80;
    out[p + 1] = flags;
    std.mem.writeInt(u16, out[p + 2 ..][0..2], o.keepalive_s, .big);
    p += 4;
    p += try writeString(out[p..], o.client_id);
    if (o.will) |w| {
        p += try writeString(out[p..], w.topic);
        p += try writeString(out[p..], w.payload);
    }
    if (o.username) |u| p += try writeString(out[p..], u);
    if (o.password) |pw| p += try writeString(out[p..], pw);
    return frame(out, @as(u8, @intFromEnum(PacketType.connect)) << 4, p - 5);
}

pub const PublishOptions = struct { topic: []const u8, payload: []const u8, qos: u2 = 0, retain: bool = false, packet_id: u16 = 0, dup: bool = false };

pub fn encodePublish(out: []u8, o: PublishOptions) Error!usize {
    if (out.len < 5) return error.Overflow;
    var p: usize = 5;
    p += try writeString(out[p..], o.topic);
    if (o.qos > 0) {
        if (out.len < p + 2) return error.Overflow;
        std.mem.writeInt(u16, out[p..][0..2], o.packet_id, .big);
        p += 2;
    }
    if (out.len < p + o.payload.len) return error.Overflow;
    @memcpy(out[p .. p + o.payload.len], o.payload);
    p += o.payload.len;
    var first: u8 = @as(u8, @intFromEnum(PacketType.publish)) << 4;
    if (o.dup) first |= 0x08;
    first |= @as(u8, o.qos) << 1;
    if (o.retain) first |= 0x01;
    return frame(out, first, p - 5);
}

pub fn encodePuback(out: []u8, packet_id: u16) Error!usize {
    if (out.len < 4) return error.Overflow;
    out[0] = @as(u8, @intFromEnum(PacketType.puback)) << 4;
    out[1] = 2;
    std.mem.writeInt(u16, out[2..4], packet_id, .big);
    return 4;
}

pub fn encodeSubscribe(out: []u8, packet_id: u16, topics: []const []const u8, qos: u2) Error!usize {
    if (out.len < 5) return error.Overflow;
    var p: usize = 5;
    if (out.len < p + 2) return error.Overflow;
    std.mem.writeInt(u16, out[p..][0..2], packet_id, .big);
    p += 2;
    for (topics) |t| {
        p += try writeString(out[p..], t);
        if (out.len < p + 1) return error.Overflow;
        out[p] = qos;
        p += 1;
    }
    return frame(out, (@as(u8, @intFromEnum(PacketType.subscribe)) << 4) | 0x02, p - 5);
}

pub fn encodePingreq(out: []u8) Error!usize {
    if (out.len < 2) return error.Overflow;
    out[0] = @as(u8, @intFromEnum(PacketType.pingreq)) << 4;
    out[1] = 0;
    return 2;
}

pub fn encodeDisconnect(out: []u8) Error!usize {
    if (out.len < 2) return error.Overflow;
    out[0] = @as(u8, @intFromEnum(PacketType.disconnect)) << 4;
    out[1] = 0;
    return 2;
}

pub const Packet = union(enum) {
    connack: struct { session_present: bool, return_code: u8 },
    publish: struct { topic: []const u8, payload: []const u8, qos: u2, retain: bool, dup: bool, packet_id: u16 },
    puback: u16,
    suback: struct { packet_id: u16, return_codes: []const u8 },
    pingresp,
    other: u4,
};

pub const Decoded = struct { packet: Packet, used: usize };

/// decode one packet from the front of `buf`; Incomplete when more bytes are needed.
pub fn decode(buf: []const u8) Error!Decoded {
    if (buf.len < 2) return error.Incomplete;
    const first = buf[0];
    const rl = try readRemainingLength(buf[1..]);
    const start = 1 + rl.used;
    if (rl.len > max_packet) return error.Malformed;
    if (buf.len < start + rl.len) return error.Incomplete;
    const body = buf[start .. start + rl.len];
    const used = start + rl.len;
    const kind: u4 = @intCast(first >> 4);
    switch (kind) {
        @intFromEnum(PacketType.connack) => {
            if (body.len != 2) return error.Malformed;
            return .{ .packet = .{ .connack = .{ .session_present = body[0] & 1 == 1, .return_code = body[1] } }, .used = used };
        },
        @intFromEnum(PacketType.publish) => {
            const qos: u2 = @intCast((first >> 1) & 0x3);
            if (qos == 3) return error.Malformed;
            const t = try readString(body);
            var p = t.used;
            var packet_id: u16 = 0;
            if (qos > 0) {
                if (body.len < p + 2) return error.Malformed;
                packet_id = std.mem.readInt(u16, body[p..][0..2], .big);
                p += 2;
            }
            return .{ .packet = .{ .publish = .{ .topic = t.s, .payload = body[p..], .qos = qos, .retain = first & 1 == 1, .dup = first & 0x08 != 0, .packet_id = packet_id } }, .used = used };
        },
        @intFromEnum(PacketType.puback) => {
            if (body.len != 2) return error.Malformed;
            return .{ .packet = .{ .puback = std.mem.readInt(u16, body[0..2], .big) }, .used = used };
        },
        @intFromEnum(PacketType.suback) => {
            if (body.len < 3) return error.Malformed;
            return .{ .packet = .{ .suback = .{ .packet_id = std.mem.readInt(u16, body[0..2], .big), .return_codes = body[2..] } }, .used = used };
        },
        @intFromEnum(PacketType.pingresp) => {
            if (body.len != 0) return error.Malformed;
            return .{ .packet = .pingresp, .used = used };
        },
        else => return .{ .packet = .{ .other = kind }, .used = used },
    }
}

// client state machine

pub const State = enum { disconnected, connecting, waiting_connack, connected, backoff };

pub const Directive = enum { none, open_socket, send_connect, send_subscribe, send_ping, close, notify_connected, notify_disconnected };

pub const min_backoff_ns: u64 = 1 * std.time.ns_per_s;
pub const max_backoff_ns: u64 = 60 * std.time.ns_per_s;
pub const connect_timeout_ns: u64 = 10 * std.time.ns_per_s;

pub const Client = struct {
    state: State = .disconnected,
    enabled: bool = false,
    keepalive_ns: u64 = 30 * std.time.ns_per_s,
    deadline_ns: u64 = 0,
    next_ping_ns: u64 = 0,
    ping_outstanding: bool = false,
    backoff_ns: u64 = min_backoff_ns,
    reconnects: u32 = 0,
    rng: u32 = 0x2545f491,
    next_packet_id: u16 = 1,

    fn jitter(self: *Client, base: u64) u64 {
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        // up to +25 %
        return base + (base / 4) * (x % 1000) / 1000;
    }

    pub fn packetId(self: *Client) u16 {
        const id = self.next_packet_id;
        self.next_packet_id = if (id == 0xffff) 1 else id + 1;
        return id;
    }

    pub fn enable(self: *Client, now_ns: u64) void {
        self.enabled = true;
        if (self.state == .disconnected) {
            self.state = .backoff;
            self.deadline_ns = now_ns; // connect at once
        }
    }

    pub fn disable(self: *Client) Directive {
        self.enabled = false;
        const was_up = self.state == .connected or self.state == .waiting_connack or self.state == .connecting;
        self.state = .disconnected;
        return if (was_up) .close else .none;
    }

    /// the socket is connected at tcp level (or the connect failed).
    pub fn onSocket(self: *Client, ok: bool, now_ns: u64) Directive {
        if (self.state != .connecting) return .none;
        if (!ok) return self.fail(now_ns);
        self.state = .waiting_connack;
        self.deadline_ns = now_ns + connect_timeout_ns;
        return .send_connect;
    }

    pub fn onConnack(self: *Client, return_code: u8, now_ns: u64) Directive {
        if (self.state != .waiting_connack) return .none;
        if (return_code != 0) return self.fail(now_ns);
        self.state = .connected;
        self.backoff_ns = min_backoff_ns;
        self.ping_outstanding = false;
        self.next_ping_ns = now_ns + self.keepalive_ns;
        return .send_subscribe;
    }

    pub fn onPingresp(self: *Client) void {
        self.ping_outstanding = false;
    }

    /// any packet from the broker counts as liveness.
    pub fn onTraffic(self: *Client, now_ns: u64) void {
        if (self.state == .connected) self.next_ping_ns = now_ns + self.keepalive_ns;
    }

    /// the socket closed or errored.
    pub fn onClosed(self: *Client, now_ns: u64) Directive {
        if (self.state == .disconnected or self.state == .backoff) return .none;
        const was_connected = self.state == .connected;
        _ = self.fail(now_ns);
        return if (was_connected) .notify_disconnected else .none;
    }

    fn fail(self: *Client, now_ns: u64) Directive {
        self.reconnects += 1;
        self.state = .backoff;
        self.deadline_ns = now_ns + self.jitter(self.backoff_ns);
        self.backoff_ns = @min(self.backoff_ns * 2, max_backoff_ns);
        return .close;
    }

    pub fn reconnectDelayS(self: *const Client, now_ns: u64) u32 {
        return if (self.state == .backoff) @intCast((self.deadline_ns -| now_ns) / std.time.ns_per_s) else 0;
    }

    pub fn poll(self: *Client, now_ns: u64) Directive {
        if (!self.enabled) return .none;
        switch (self.state) {
            .disconnected => {},
            .backoff => if (now_ns >= self.deadline_ns) {
                self.state = .connecting;
                self.deadline_ns = now_ns + connect_timeout_ns;
                return .open_socket;
            },
            .connecting, .waiting_connack => if (now_ns >= self.deadline_ns) return self.fail(now_ns),
            .connected => {
                if (self.ping_outstanding and now_ns >= self.deadline_ns) {
                    _ = self.fail(now_ns);
                    return .notify_disconnected;
                }
                if (!self.ping_outstanding and now_ns >= self.next_ping_ns) {
                    self.ping_outstanding = true;
                    self.deadline_ns = now_ns + self.keepalive_ns / 2;
                    self.next_ping_ns = now_ns + self.keepalive_ns;
                    return .send_ping;
                }
            },
        }
        return .none;
    }

    /// when the next `poll` could produce something, for timer arming.
    pub fn nextDeadline(self: *const Client) ?u64 {
        if (!self.enabled) return null;
        return switch (self.state) {
            .disconnected => null,
            .backoff, .connecting, .waiting_connack => self.deadline_ns,
            .connected => if (self.ping_outstanding) self.deadline_ns else self.next_ping_ns,
        };
    }
};

// tests

fn hex(comptime h: []const u8) [h.len / 2]u8 {
    var out: [h.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, h) catch unreachable;
    return out;
}

test "connect packet with will and credentials matches the specification layout" {
    var out: [128]u8 = undefined;
    const n = try encodeConnect(&out, .{ .client_id = "tc002", .keepalive_s = 30, .username = "u", .password = "p", .will = .{ .topic = "t/a", .payload = "offline" } });
    const expected = hex("10" ++ "25" ++ "00044d515454" ++ "04" ++ "ee" ++ "001e" ++ "00057463303032" ++ "0003742f61" ++ "00076f66666c696e65" ++ "000175" ++ "000170");
    try std.testing.expectEqualSlices(u8, &expected, out[0..n]);
}

test "publish, puback, subscribe, ping and disconnect encode; decode round-trips" {
    var out: [256]u8 = undefined;
    const p0 = try encodePublish(&out, .{ .topic = "a/b", .payload = "hi", .retain = true });
    try std.testing.expectEqualSlices(u8, &hex("31" ++ "07" ++ "0003612f62" ++ "6869"), out[0..p0]);
    const p1 = try encodePublish(&out, .{ .topic = "a/b", .payload = "hi", .qos = 1, .packet_id = 0x1234 });
    try std.testing.expectEqualSlices(u8, &hex("32" ++ "09" ++ "0003612f62" ++ "1234" ++ "6869"), out[0..p1]);
    const d = try decode(out[0..p1]);
    try std.testing.expectEqualStrings("a/b", d.packet.publish.topic);
    try std.testing.expectEqualStrings("hi", d.packet.publish.payload);
    try std.testing.expectEqual(@as(u16, 0x1234), d.packet.publish.packet_id);
    try std.testing.expectEqual(@as(u2, 1), d.packet.publish.qos);
    try std.testing.expectEqual(p1, d.used);
    const pa = try encodePuback(&out, 7);
    try std.testing.expectEqualSlices(u8, &hex("40020007"), out[0..pa]);
    try std.testing.expectEqual(@as(u16, 7), (try decode(out[0..pa])).packet.puback);
    const s = try encodeSubscribe(&out, 1, &.{ "x/cmd/scene", "x/cmd/action" }, 1);
    try std.testing.expectEqual(@as(u8, 0x82), out[0]);
    try std.testing.expectEqual(s, @as(usize, 2 + out[1]));
    try std.testing.expectEqualSlices(u8, &hex("c000"), out[0..try encodePingreq(&out)]);
    try std.testing.expectEqualSlices(u8, &hex("e000"), out[0..try encodeDisconnect(&out)]);
    const ca = try decode(&hex("20020000"));
    try std.testing.expectEqual(@as(u8, 0), ca.packet.connack.return_code);
    const sa = try decode(&hex("9003000101"));
    try std.testing.expectEqualSlices(u8, &.{1}, sa.packet.suback.return_codes);
    try std.testing.expect((try decode(&hex("d000"))).packet == .pingresp);
}

test "remaining length encoding and incomplete or malformed input" {
    var b: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try writeRemainingLength(&b, 321));
    try std.testing.expectEqualSlices(u8, &hex("c102"), b[0..2]);
    const r = try readRemainingLength(&hex("c102"));
    try std.testing.expectEqual(@as(usize, 321), r.len);
    try std.testing.expectError(error.Incomplete, decode(&hex("30")));
    try std.testing.expectError(error.Incomplete, decode(&hex("3005000361")));
    try std.testing.expectError(error.Malformed, decode(&hex("2003000000")));
    try std.testing.expectError(error.Malformed, decode(&hex("30ffffffff80")));
    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.Overflow, encodePublish(&tiny, .{ .topic = "a", .payload = "b" }));
}

test "client: connect, keepalive pings, ping timeout, bounded backoff with jitter" {
    const s = std.time.ns_per_s;
    var c = Client{};
    try std.testing.expectEqual(Directive.none, c.poll(0));
    c.enable(0);
    try std.testing.expectEqual(Directive.open_socket, c.poll(0));
    try std.testing.expectEqual(Directive.send_connect, c.onSocket(true, 100));
    try std.testing.expectEqual(Directive.send_subscribe, c.onConnack(0, 200));
    try std.testing.expectEqual(State.connected, c.state);
    try std.testing.expectEqual(Directive.none, c.poll(29 * s));
    try std.testing.expectEqual(Directive.send_ping, c.poll(31 * s));
    c.onPingresp();
    c.onTraffic(31 * s);
    try std.testing.expectEqual(Directive.none, c.poll(45 * s));
    try std.testing.expectEqual(Directive.send_ping, c.poll(62 * s));
    // no pingresp within half the keepalive: the connection is dead
    try std.testing.expectEqual(Directive.notify_disconnected, c.poll(78 * s));
    try std.testing.expectEqual(State.backoff, c.state);
    try std.testing.expect(c.deadline_ns >= 78 * s + 1 * s and c.deadline_ns <= 78 * s + 1250 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 2 * s), c.backoff_ns);
    // repeated failures double up to sixty seconds
    var t: u64 = 80 * s;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try std.testing.expectEqual(Directive.open_socket, c.poll(t));
        try std.testing.expectEqual(Directive.close, c.onSocket(false, t));
        t = c.deadline_ns;
    }
    try std.testing.expectEqual(@as(u64, 60 * s), c.backoff_ns);
    try std.testing.expect(c.reconnects >= 9);
    // a successful connection resets the backoff
    try std.testing.expectEqual(Directive.open_socket, c.poll(t));
    _ = c.onSocket(true, t);
    _ = c.onConnack(0, t);
    try std.testing.expectEqual(@as(u64, 1 * s), c.backoff_ns);
    try std.testing.expectEqual(Directive.close, c.disable());
    try std.testing.expectEqual(Directive.none, c.poll(t + 100 * s));
}

test "a rejected connack and a connect timeout back off" {
    const s = std.time.ns_per_s;
    var c = Client{};
    c.enable(0);
    _ = c.poll(0);
    _ = c.onSocket(true, 0);
    try std.testing.expectEqual(Directive.close, c.onConnack(5, 1 * s));
    try std.testing.expectEqual(State.backoff, c.state);
    var d = Client{};
    d.enable(0);
    _ = d.poll(0);
    try std.testing.expectEqual(Directive.none, d.poll(9 * s));
    try std.testing.expectEqual(Directive.close, d.poll(10 * s));
    try std.testing.expectEqual(@as(u16, 1), d.packetId());
    try std.testing.expectEqual(@as(u16, 2), d.packetId());
}
