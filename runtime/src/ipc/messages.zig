//! typed payloads for the renderer <-> supervisor channel, as one tagged union with fixed-size
//! big-endian encodings, plus the dedup-relevant result status.
const std = @import("std");
const codec = @import("codec.zig");
const geometry = @import("../panel/geometry.zig");
const config = @import("../supervisor/config.zig");
const api = @import("../net/api.zig");

test "every message kind round-trips through a packet" {
    var frame = Frame{ .duration_s = 9, .rgb = geometry.black_rgb };
    frame.rgb[2495] = 0x5a;
    const all = [_]Message{
        .{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } },
        .ready,
        .{ .result = .{ .status = .applied, .revision = 41 } },
        .{ .set_base = .{ .base = 1, .generator = 1, .seed = 0xdeadbeef } },
        .{ .notify = Notify.init("hello, panel", .{ 1, 2, 3 }, 30) },
        .{ .frame = frame },
        .{ .brightness = .{ .value = 55 } },
        .{ .reseed = .{ .seed = 12 } },
        .arm_stream,
        .time_corrected,
        .{ .ip_changed = .{ .present = 1, .addr = .{ 10, 0, 0, 111 } } },
        .stop,
        .{ .credentials = .{ .control = [_]u8{0x11} ** 32, .admin = [_]u8{0x22} ** 32 } },
        .{ .config = blk: {
            var c = config.Config{};
            try c.patch(.{ .brightness = 9, .timezone = "JST-9", .ntp_server = .{ 1, 2, 3, 4 } });
            break :blk c;
        } },
        .config_get,
        .{ .config_patch = try ConfigPatch.fromApi(.{ .brightness = 3, .timezone = "UTC0", .expected_revision = 5 }) },
        .{ .config_save = .{ .has_revision = 1, .revision = 6 } },
        .{ .save_result = .{ .status = .conflict, .saved_revision = 5 } },
        .{ .mqtt_put = try MqttPut.fromApi(.{ .host = "10.0.0.2", .password = "Pw", .enabled = true }) },
        .status_get,
        .{ .status = .{ .renderer_state = 2, .epoch = 3, .revision = 4, .presented = 5, .base = 1, .brightness = 77, .uptime_s = 8, .mem_available_kb = 14000, .cpu_pct = 12, .fps_x10 = 599, .ip_present = 1, .ip = .{ 10, 0, 0, 111 }, .config_revision = 2, .saved_revision = 1, .boot_id = 0xabcd, .sample_age_ms = 40 } },
    };
    var buf: [codec.max_message]u8 = undefined;
    for (all) |m| {
        const packet = try encodePacket(m, 0x0102030405060708, 3, &buf);
        const p = try decodePacket(packet);
        try std.testing.expectEqual(@as(u64, 0x0102030405060708), p.request_id);
        try std.testing.expectEqual(@as(u32, 3), p.epoch);
        try std.testing.expectEqualDeep(m, p.message);
    }
}

test "fixed hex vectors" {
    var buf: [codec.max_message]u8 = undefined;
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } }, 1, 2, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "01" ++ "0000" ++ "0000000000000001" ++ "00000002" ++ "0011" ++ "0000" ++ "1122334455667788" ++ "00000007" ++ "02" ++ "00000000"), hb);
    const st = try encodePacket(.stop, 0, 9, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "18" ++ "0000" ++ "0000000000000000" ++ "00000009" ++ "0000" ++ "0000"), st);
    const nt = try encodePacket(.{ .notify = Notify.init("hi", .{ 0xff, 0x80, 0x00 }, 300) }, 0, 0, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "11" ++ "0000" ++ "0000000000000000" ++ "00000000" ++ "0008" ++ "0000" ++ "ff8000" ++ "012c" ++ "02" ++ "6869"), nt);
    const fr = try encodePacket(.{ .frame = .{ .duration_s = 1, .rgb = geometry.black_rgb } }, 0, 0, &buf);
    try std.testing.expectEqual(@as(usize, codec.header_len + 2 + geometry.rgb_bytes), fr.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.frame)), fr[5]);
}

test "patch wire forms map back to the api view" {
    const w = try ConfigPatch.fromApi(.{ .brightness = 3, .timezone = "JST-9", .ntp_server = .{ 9, 9, 9, 9 } });
    const a = w.toApi();
    try std.testing.expectEqual(@as(?u8, 3), a.brightness);
    try std.testing.expectEqualStrings("JST-9", a.timezone.?);
    try std.testing.expectEqual([4]u8{ 9, 9, 9, 9 }, a.ntp_server.?);
    try std.testing.expectEqual(@as(?u32, null), a.expected_revision);
    try std.testing.expectEqual(@as(?bool, null), a.discovery);
    const m = try MqttPut.fromApi(.{ .host = "10.0.0.2", .tls = false });
    const ma = m.toApi();
    try std.testing.expectEqualStrings("10.0.0.2", ma.host.?);
    try std.testing.expectEqual(@as(?bool, false), ma.tls);
    try std.testing.expectEqual(@as(?[]const u8, null), ma.password);
}

test "malformed payloads are rejected" {
    var buf: [codec.max_message]u8 = undefined;
    var src: [codec.max_message]u8 = undefined;
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 1, .revision = 1, .state = 1 } }, 0, 0, &src);
    const short = try codec.encode(.{ .kind = @intFromEnum(Kind.heartbeat), .request_id = 0, .epoch = 0, .payload_len = 12 }, hb[codec.header_len .. codec.header_len + 12], &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short));
    const unknown = try codec.encode(.{ .kind = 200, .request_id = 0, .epoch = 0, .payload_len = 0 }, "", &buf);
    try std.testing.expectError(error.UnknownKind, decodePacket(unknown));
    // a notify claiming 200 text bytes
    const long_notify = try codec.encode(.{ .kind = @intFromEnum(Kind.notify), .request_id = 0, .epoch = 0, .payload_len = 6 + 200 }, &([_]u8{ 0, 0, 0, 0, 5, 200 } ++ [_]u8{'a'} ** 200), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(long_notify));
    // a frame one byte short
    const short_frame = try codec.encode(.{ .kind = @intFromEnum(Kind.frame), .request_id = 0, .epoch = 0, .payload_len = 2497 }, &([_]u8{0} ** 2497), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short_frame));
    // trailing bytes on a fixed-size message
    const trailing = try codec.encode(.{ .kind = @intFromEnum(Kind.stop), .request_id = 0, .epoch = 0, .payload_len = 1 }, "x", &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(trailing));
}

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

pub const Kind = enum(u8) {
    heartbeat = 1,
    ready = 2,
    result = 3,
    set_base = 16,
    notify = 17,
    frame = 18,
    brightness = 19,
    reseed = 20,
    arm_stream = 21,
    time_corrected = 22,
    ip_changed = 23,
    stop = 24,
    // supervisor <-> netd
    credentials = 32,
    config = 33,
    config_get = 34,
    config_patch = 35,
    config_save = 36,
    save_result = 37,
    mqtt_put = 38,
    status_get = 39,
    status = 40,
};

pub const Status = enum(u8) { applied = 0, rejected = 1, overload = 2, stale_epoch = 3, expired = 4, unavailable = 5, timeout = 6, conflict = 7 };

pub const Heartbeat = struct { presented: u64, revision: u32, state: u8, base: u8 = 0, generator: u8 = 0, overlay: u8 = 0, brightness: u8 = 0 };
pub const Result = struct { status: Status, revision: u32 };
pub const SetBase = struct { base: u8, generator: u8, seed: u32 };
pub const Frame = struct { duration_s: u16, rgb: geometry.Rgb };
pub const Brightness = struct { value: u8 };
pub const Reseed = struct { seed: u32 };
pub const IpChanged = struct { present: u8, addr: [4]u8 };

pub const Notify = struct {
    colour: [3]u8,
    duration_s: u16,
    len: u8,
    text: [128]u8,

    pub fn init(text: []const u8, colour: [3]u8, duration_s: u16) Notify {
        var n = Notify{ .colour = colour, .duration_s = duration_s, .len = @intCast(text.len), .text = [_]u8{0} ** 128 };
        @memcpy(n.text[0..text.len], text);
        return n;
    }

    pub fn slice(self: *const Notify) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Credentials = api.Credentials;

/// a config patch on the wire: presence flags plus fixed fields.
pub const ConfigPatch = struct {
    has: u16 = 0,
    brightness: u8 = 0,
    base: u8 = 0,
    generator: u8 = 0,
    timezone: config.Text = .{},
    ntp_server: [4]u8 = .{ 0, 0, 0, 0 },
    ntp_interval_s: u32 = 0,
    frame_timeout_ms: u16 = 0,
    metrics_interval_s: u32 = 0,
    discovery: u8 = 0,
    discovery_prefix: config.Text = .{},
    expected_revision: u32 = 0,

    pub const F = struct {
        pub const brightness: u16 = 1 << 0;
        pub const base: u16 = 1 << 1;
        pub const generator: u16 = 1 << 2;
        pub const timezone: u16 = 1 << 3;
        pub const ntp_server: u16 = 1 << 4;
        pub const ntp_interval_s: u16 = 1 << 5;
        pub const frame_timeout_ms: u16 = 1 << 6;
        pub const metrics_interval_s: u16 = 1 << 7;
        pub const discovery: u16 = 1 << 8;
        pub const discovery_prefix: u16 = 1 << 9;
        pub const expected_revision: u16 = 1 << 10;
    };

    pub const wire_len = 2 + 3 + 65 + 4 + 4 + 2 + 4 + 1 + 65 + 4;

    pub fn fromApi(p: api.ConfigPatch) error{TooLong}!ConfigPatch {
        var w = ConfigPatch{};
        if (p.brightness) |v| {
            w.has |= F.brightness;
            w.brightness = v;
        }
        if (p.base) |v| {
            w.has |= F.base;
            w.base = @intFromEnum(v);
        }
        if (p.generator) |v| {
            w.has |= F.generator;
            w.generator = @intFromEnum(v);
        }
        if (p.timezone) |v| {
            w.has |= F.timezone;
            try w.timezone.set(v);
        }
        if (p.ntp_server) |v| {
            w.has |= F.ntp_server;
            w.ntp_server = v;
        }
        if (p.ntp_interval_s) |v| {
            w.has |= F.ntp_interval_s;
            w.ntp_interval_s = v;
        }
        if (p.frame_timeout_ms) |v| {
            w.has |= F.frame_timeout_ms;
            w.frame_timeout_ms = v;
        }
        if (p.metrics_interval_s) |v| {
            w.has |= F.metrics_interval_s;
            w.metrics_interval_s = v;
        }
        if (p.discovery) |v| {
            w.has |= F.discovery;
            w.discovery = @intFromBool(v);
        }
        if (p.discovery_prefix) |v| {
            w.has |= F.discovery_prefix;
            try w.discovery_prefix.set(v);
        }
        if (p.expected_revision) |v| {
            w.has |= F.expected_revision;
            w.expected_revision = v;
        }
        return w;
    }

    /// the api view again; slices point into `self`.
    pub fn toApi(self: *const ConfigPatch) api.ConfigPatch {
        const h = self.has;
        return .{
            .brightness = if (h & F.brightness != 0) self.brightness else null,
            .base = if (h & F.base != 0) (enumFromInt(api.Base, self.base) orelse null) else null,
            .generator = if (h & F.generator != 0) (enumFromInt(@import("../scene/scene.zig").Generator, self.generator) orelse null) else null,
            .timezone = if (h & F.timezone != 0) self.timezone.slice() else null,
            .ntp_server = if (h & F.ntp_server != 0) self.ntp_server else null,
            .ntp_interval_s = if (h & F.ntp_interval_s != 0) self.ntp_interval_s else null,
            .frame_timeout_ms = if (h & F.frame_timeout_ms != 0) self.frame_timeout_ms else null,
            .metrics_interval_s = if (h & F.metrics_interval_s != 0) self.metrics_interval_s else null,
            .discovery = if (h & F.discovery != 0) self.discovery != 0 else null,
            .discovery_prefix = if (h & F.discovery_prefix != 0) self.discovery_prefix.slice() else null,
            .expected_revision = if (h & F.expected_revision != 0) self.expected_revision else null,
        };
    }
};

pub const MqttPut = struct {
    has: u8 = 0,
    enabled: u8 = 0,
    host: config.Text = .{},
    port: u16 = 0,
    username: config.Text = .{},
    password: config.Text = .{},
    client_id: config.Text = .{},
    prefix: config.Text = .{},
    tls: u8 = 0,

    pub const F = struct {
        pub const enabled: u8 = 1 << 0;
        pub const host: u8 = 1 << 1;
        pub const port: u8 = 1 << 2;
        pub const username: u8 = 1 << 3;
        pub const password: u8 = 1 << 4;
        pub const client_id: u8 = 1 << 5;
        pub const prefix: u8 = 1 << 6;
        pub const tls: u8 = 1 << 7;
    };

    pub const wire_len = 1 + 1 + 65 + 2 + 4 * 65 + 1;

    pub fn fromApi(p: api.MqttPut) error{TooLong}!MqttPut {
        var w = MqttPut{};
        if (p.enabled) |v| {
            w.has |= F.enabled;
            w.enabled = @intFromBool(v);
        }
        if (p.host) |v| {
            w.has |= F.host;
            try w.host.set(v);
        }
        if (p.port) |v| {
            w.has |= F.port;
            w.port = v;
        }
        if (p.username) |v| {
            w.has |= F.username;
            try w.username.set(v);
        }
        if (p.password) |v| {
            w.has |= F.password;
            try w.password.set(v);
        }
        if (p.client_id) |v| {
            w.has |= F.client_id;
            try w.client_id.set(v);
        }
        if (p.prefix) |v| {
            w.has |= F.prefix;
            try w.prefix.set(v);
        }
        if (p.tls) |v| {
            w.has |= F.tls;
            w.tls = @intFromBool(v);
        }
        return w;
    }

    pub fn toApi(self: *const MqttPut) api.MqttPut {
        const h = self.has;
        return .{
            .enabled = if (h & F.enabled != 0) self.enabled != 0 else null,
            .host = if (h & F.host != 0) self.host.slice() else null,
            .port = if (h & F.port != 0) self.port else null,
            .username = if (h & F.username != 0) self.username.slice() else null,
            .password = if (h & F.password != 0) self.password.slice() else null,
            .client_id = if (h & F.client_id != 0) self.client_id.slice() else null,
            .prefix = if (h & F.prefix != 0) self.prefix.slice() else null,
            .tls = if (h & F.tls != 0) self.tls != 0 else null,
        };
    }
};

pub const ConfigSave = struct { has_revision: u8, revision: u32 };
pub const SaveResult = struct { status: Status, saved_revision: u32 };

/// the supervisor's snapshot of everything netd reports over http and mqtt.
pub const StatusSnapshot = struct {
    renderer_state: u8 = 0, // 0 none, 1 starting, 2 running, 3 stopping
    epoch: u32 = 0,
    revision: u32 = 0,
    presented: u64 = 0,
    base: u8 = 0,
    generator: u8 = 0,
    overlay: u8 = 0,
    brightness: u8 = 0,
    uptime_s: u32 = 0,
    mem_available_kb: u32 = 0,
    cpu_pct: u8 = 255, // 255 = unknown
    rss_supervisor_kb: u32 = 0,
    rss_renderer_kb: u32 = 0,
    rss_netd_kb: u32 = 0,
    restarts: u32 = 0,
    fps_x10: u16 = 0,
    ip_present: u8 = 0,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    time_state: u8 = 0, // 0 unsynced, 1 synced, 2 stale
    time_age_s: u32 = 0xffffffff,
    config_revision: u32 = 0,
    saved_revision: u32 = 0,
    boot_id: u32 = 0,
    sample_age_ms: u32 = 0,

    pub const wire_len = 1 + 4 + 4 + 8 + 4 + 4 + 4 + 1 + 4 + 4 + 4 + 4 + 2 + 1 + 4 + 1 + 4 + 4 + 4 + 4 + 4;
};

pub const Message = union(Kind) {
    heartbeat: Heartbeat,
    ready,
    result: Result,
    set_base: SetBase,
    notify: Notify,
    frame: Frame,
    brightness: Brightness,
    reseed: Reseed,
    arm_stream,
    time_corrected,
    ip_changed: IpChanged,
    stop,
    credentials: Credentials,
    config: config.Config,
    config_get,
    config_patch: ConfigPatch,
    config_save: ConfigSave,
    save_result: SaveResult,
    mqtt_put: MqttPut,
    status_get,
    status: StatusSnapshot,
};

pub const Packet = struct { request_id: u64, epoch: u32, message: Message };
pub const Error = codec.DecodeError || error{ UnknownKind, BadPayload };

fn encodePayload(msg: Message, out: []u8) usize {
    switch (msg) {
        .heartbeat => |h| {
            std.mem.writeInt(u64, out[0..8], h.presented, .big);
            std.mem.writeInt(u32, out[8..12], h.revision, .big);
            out[12] = h.state;
            out[13] = h.base;
            out[14] = h.generator;
            out[15] = h.overlay;
            out[16] = h.brightness;
            return 17;
        },
        .ready, .arm_stream, .time_corrected, .stop, .config_get, .status_get => return 0,
        .credentials => |c| {
            out[0..32].* = c.control;
            out[32..64].* = c.admin;
            return 64;
        },
        .config => |c| {
            config.encode(&c, out[0..config.encoded_len]);
            return config.encoded_len;
        },
        .config_patch => |p| {
            var o: usize = 0;
            std.mem.writeInt(u16, out[o..][0..2], p.has, .little);
            o += 2;
            out[o] = p.brightness;
            out[o + 1] = p.base;
            out[o + 2] = p.generator;
            o += 3;
            putText(out, &o, p.timezone);
            out[o..][0..4].* = p.ntp_server;
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], p.ntp_interval_s, .little);
            o += 4;
            std.mem.writeInt(u16, out[o..][0..2], p.frame_timeout_ms, .little);
            o += 2;
            std.mem.writeInt(u32, out[o..][0..4], p.metrics_interval_s, .little);
            o += 4;
            out[o] = p.discovery;
            o += 1;
            putText(out, &o, p.discovery_prefix);
            std.mem.writeInt(u32, out[o..][0..4], p.expected_revision, .little);
            o += 4;
            return o;
        },
        .config_save => |c| {
            out[0] = c.has_revision;
            std.mem.writeInt(u32, out[1..5], c.revision, .big);
            return 5;
        },
        .save_result => |r| {
            out[0] = @intFromEnum(r.status);
            std.mem.writeInt(u32, out[1..5], r.saved_revision, .big);
            return 5;
        },
        .mqtt_put => |m| {
            var o: usize = 0;
            out[o] = m.has;
            out[o + 1] = m.enabled;
            o += 2;
            putText(out, &o, m.host);
            std.mem.writeInt(u16, out[o..][0..2], m.port, .little);
            o += 2;
            putText(out, &o, m.username);
            putText(out, &o, m.password);
            putText(out, &o, m.client_id);
            putText(out, &o, m.prefix);
            out[o] = m.tls;
            o += 1;
            return o;
        },
        .status => |st| {
            var o: usize = 0;
            out[o] = st.renderer_state;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.epoch, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.revision, .big);
            o += 4;
            std.mem.writeInt(u64, out[o..][0..8], st.presented, .big);
            o += 8;
            out[o] = st.base;
            out[o + 1] = st.generator;
            out[o + 2] = st.overlay;
            out[o + 3] = st.brightness;
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.uptime_s, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.mem_available_kb, .big);
            o += 4;
            out[o] = st.cpu_pct;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_supervisor_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_renderer_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_netd_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.restarts, .big);
            o += 4;
            std.mem.writeInt(u16, out[o..][0..2], st.fps_x10, .big);
            o += 2;
            out[o] = st.ip_present;
            o += 1;
            out[o..][0..4].* = st.ip;
            o += 4;
            out[o] = st.time_state;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.time_age_s, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.config_revision, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.saved_revision, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.boot_id, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.sample_age_ms, .big);
            o += 4;
            return o;
        },
        .result => |r| {
            out[0] = @intFromEnum(r.status);
            std.mem.writeInt(u32, out[1..5], r.revision, .big);
            return 5;
        },
        .set_base => |s| {
            out[0] = s.base;
            out[1] = s.generator;
            std.mem.writeInt(u32, out[2..6], s.seed, .big);
            return 6;
        },
        .notify => |n| {
            out[0..3].* = n.colour;
            std.mem.writeInt(u16, out[3..5], n.duration_s, .big);
            out[5] = n.len;
            @memcpy(out[6 .. 6 + @as(usize, n.len)], n.text[0..n.len]);
            return 6 + @as(usize, n.len);
        },
        .frame => |f| {
            std.mem.writeInt(u16, out[0..2], f.duration_s, .big);
            @memcpy(out[2 .. 2 + geometry.rgb_bytes], &f.rgb);
            return 2 + geometry.rgb_bytes;
        },
        .brightness => |b| {
            out[0] = b.value;
            return 1;
        },
        .reseed => |r| {
            std.mem.writeInt(u32, out[0..4], r.seed, .big);
            return 4;
        },
        .ip_changed => |i| {
            out[0] = i.present;
            out[1..5].* = i.addr;
            return 5;
        },
    }
}

pub fn encodePacket(msg: Message, request_id: u64, epoch: u32, out: []u8) error{Overflow}![]u8 {
    var payload: [codec.max_payload]u8 = undefined;
    const n = encodePayload(msg, &payload);
    return codec.encode(.{ .kind = @intFromEnum(msg), .request_id = request_id, .epoch = epoch, .payload_len = @intCast(n) }, payload[0..n], out);
}

/// a non-exhaustive-safe integer -> enum conversion: null for values without a tag.
pub fn enumFromInt(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (f.value == value) return @enumFromInt(f.value);
    return null;
}

fn putText(out: []u8, off: *usize, t: config.Text) void {
    out[off.*] = t.len;
    @memcpy(out[off.* + 1 .. off.* + 1 + config.text_max], &t.bytes);
    off.* += 1 + config.text_max;
}

fn getText(in: []const u8, off: *usize) error{BadPayload}!config.Text {
    var t = config.Text{};
    t.len = in[off.*];
    if (t.len > config.text_max) return error.BadPayload;
    @memcpy(&t.bytes, in[off.* + 1 .. off.* + 1 + config.text_max]);
    off.* += 1 + config.text_max;
    return t;
}

fn fixed(p: []const u8, n: usize) error{BadPayload}![]const u8 {
    if (p.len != n) return error.BadPayload;
    return p;
}

pub fn decodePacket(bytes: []const u8) Error!Packet {
    const d = try codec.decode(bytes);
    const kind = enumFromInt(Kind, d.header.kind) orelse return error.UnknownKind;
    const p = d.payload;
    const message: Message = switch (kind) {
        .heartbeat => blk: {
            const b = try fixed(p, 17);
            break :blk .{ .heartbeat = .{ .presented = std.mem.readInt(u64, b[0..8], .big), .revision = std.mem.readInt(u32, b[8..12], .big), .state = b[12], .base = b[13], .generator = b[14], .overlay = b[15], .brightness = b[16] } };
        },
        .config_get => blk: {
            _ = try fixed(p, 0);
            break :blk .config_get;
        },
        .status_get => blk: {
            _ = try fixed(p, 0);
            break :blk .status_get;
        },
        .credentials => blk: {
            const b = try fixed(p, 64);
            break :blk .{ .credentials = .{ .control = b[0..32].*, .admin = b[32..64].* } };
        },
        .config => blk: {
            const b = try fixed(p, config.encoded_len);
            break :blk .{ .config = config.decode(b) catch return error.BadPayload };
        },
        .config_patch => blk: {
            const b = try fixed(p, ConfigPatch.wire_len);
            var w = ConfigPatch{};
            var o: usize = 0;
            w.has = std.mem.readInt(u16, b[o..][0..2], .little);
            o += 2;
            w.brightness = b[o];
            w.base = b[o + 1];
            w.generator = b[o + 2];
            o += 3;
            w.timezone = try getText(b, &o);
            w.ntp_server = b[o..][0..4].*;
            o += 4;
            w.ntp_interval_s = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.frame_timeout_ms = std.mem.readInt(u16, b[o..][0..2], .little);
            o += 2;
            w.metrics_interval_s = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.discovery = b[o];
            o += 1;
            w.discovery_prefix = try getText(b, &o);
            w.expected_revision = std.mem.readInt(u32, b[o..][0..4], .little);
            break :blk .{ .config_patch = w };
        },
        .config_save => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .config_save = .{ .has_revision = b[0], .revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .save_result => blk: {
            const b = try fixed(p, 5);
            const status = enumFromInt(Status, b[0]) orelse return error.BadPayload;
            break :blk .{ .save_result = .{ .status = status, .saved_revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .mqtt_put => blk: {
            const b = try fixed(p, MqttPut.wire_len);
            var m = MqttPut{};
            var o: usize = 0;
            m.has = b[o];
            m.enabled = b[o + 1];
            o += 2;
            m.host = try getText(b, &o);
            m.port = std.mem.readInt(u16, b[o..][0..2], .little);
            o += 2;
            m.username = try getText(b, &o);
            m.password = try getText(b, &o);
            m.client_id = try getText(b, &o);
            m.prefix = try getText(b, &o);
            m.tls = b[o];
            break :blk .{ .mqtt_put = m };
        },
        .status => blk: {
            const b = try fixed(p, StatusSnapshot.wire_len);
            var st = StatusSnapshot{};
            var o: usize = 0;
            st.renderer_state = b[o];
            o += 1;
            st.epoch = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.presented = std.mem.readInt(u64, b[o..][0..8], .big);
            o += 8;
            st.base = b[o];
            st.generator = b[o + 1];
            st.overlay = b[o + 2];
            st.brightness = b[o + 3];
            o += 4;
            st.uptime_s = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.mem_available_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.cpu_pct = b[o];
            o += 1;
            st.rss_supervisor_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.rss_renderer_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.rss_netd_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.restarts = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.fps_x10 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.ip_present = b[o];
            o += 1;
            st.ip = b[o..][0..4].*;
            o += 4;
            st.time_state = b[o];
            o += 1;
            st.time_age_s = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.config_revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.saved_revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.boot_id = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.sample_age_ms = std.mem.readInt(u32, b[o..][0..4], .big);
            break :blk .{ .status = st };
        },
        .ready => blk: {
            _ = try fixed(p, 0);
            break :blk .ready;
        },
        .result => blk: {
            const b = try fixed(p, 5);
            const status = enumFromInt(Status, b[0]) orelse return error.BadPayload;
            break :blk .{ .result = .{ .status = status, .revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .set_base => blk: {
            const b = try fixed(p, 6);
            break :blk .{ .set_base = .{ .base = b[0], .generator = b[1], .seed = std.mem.readInt(u32, b[2..6], .big) } };
        },
        .notify => blk: {
            if (p.len < 6) return error.BadPayload;
            const len = p[5];
            if (len == 0 or len > 128 or p.len != 6 + @as(usize, len)) return error.BadPayload;
            break :blk .{ .notify = Notify.init(p[6..], p[0..3].*, std.mem.readInt(u16, p[3..5], .big)) };
        },
        .frame => blk: {
            const b = try fixed(p, 2 + geometry.rgb_bytes);
            break :blk .{ .frame = .{ .duration_s = std.mem.readInt(u16, b[0..2], .big), .rgb = b[2..][0..geometry.rgb_bytes].* } };
        },
        .brightness => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .brightness = .{ .value = b[0] } };
        },
        .reseed => blk: {
            const b = try fixed(p, 4);
            break :blk .{ .reseed = .{ .seed = std.mem.readInt(u32, b[0..4], .big) } };
        },
        .arm_stream => blk: {
            _ = try fixed(p, 0);
            break :blk .arm_stream;
        },
        .time_corrected => blk: {
            _ = try fixed(p, 0);
            break :blk .time_corrected;
        },
        .ip_changed => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .ip_changed = .{ .present = b[0], .addr = b[1..5].* } };
        },
        .stop => blk: {
            _ = try fixed(p, 0);
            break :blk .stop;
        },
    };
    return .{ .request_id = d.header.request_id, .epoch = d.header.epoch, .message = message };
}
