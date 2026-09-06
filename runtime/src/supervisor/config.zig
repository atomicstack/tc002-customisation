//! the supervisor's durable settings: fixed-size fields, validated patches that bump a revision,
//! an optional expected revision to reject lost updates, json persistence, and an explicit
//! little-endian ipc encoding so netd never sees the file. pure.
const std = @import("std");
const api = @import("../net/api.zig");

pub const text_max = 64;

pub const Text = struct {
    bytes: [text_max]u8 = [_]u8{0} ** text_max,
    len: u8 = 0,

    pub fn init(s: []const u8) Text {
        var t = Text{};
        t.set(s) catch unreachable;
        return t;
    }

    pub fn set(self: *Text, s: []const u8) error{TooLong}!void {
        if (s.len > text_max) return error.TooLong;
        @memset(&self.bytes, 0);
        @memcpy(self.bytes[0..s.len], s);
        self.len = @intCast(s.len);
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Mqtt = struct {
    enabled: bool = false,
    host: Text = .{},
    port: u16 = 1883,
    username: Text = .{},
    password: Text = .{},
    client_id: Text = .{},
    prefix: Text = .{},
    tls: bool = false,
};

pub const Config = struct {
    revision: u32 = 0,
    saved_revision: u32 = 0,
    brightness: u8 = 100,
    base: u8 = 0,
    generator: u8 = 0,
    timezone: Text = Text.init("UTC0"),
    ntp_server: ?[4]u8 = null,
    ntp_interval_s: u32 = 300,
    frame_timeout_ms: u16 = 500,
    metrics_interval_s: u32 = 30,
    discovery: bool = false,
    discovery_prefix: Text = Text.init("homeassistant"),
    origins: [api.max_origins]Text = .{ .{}, .{}, .{}, .{} },
    origin_count: u8 = 0,
    mqtt: Mqtt = .{},

    pub const PatchError = error{ RevisionConflict, TooLong, Invalid };

    /// apply a validated patch; every accepted patch is one revision.
    pub fn patch(self: *Config, p: api.ConfigPatch) PatchError!void {
        if (p.expected_revision) |want| if (want != self.revision) return error.RevisionConflict;
        var next = self.*;
        if (p.brightness) |v| next.brightness = v;
        if (p.base) |b| next.base = @intFromEnum(b);
        if (p.generator) |g| next.generator = @intFromEnum(g);
        if (p.timezone) |t| try next.timezone.set(t);
        if (p.ntp_server) |s| next.ntp_server = s;
        if (p.ntp_interval_s) |v| next.ntp_interval_s = v;
        if (p.frame_timeout_ms) |v| next.frame_timeout_ms = v;
        if (p.metrics_interval_s) |v| next.metrics_interval_s = v;
        if (p.discovery) |v| next.discovery = v;
        if (p.discovery_prefix) |v| try next.discovery_prefix.set(v);
        next.revision = self.revision + 1;
        self.* = next;
    }

    pub fn patchMqtt(self: *Config, p: api.MqttPut) PatchError!void {
        var next = self.mqtt;
        if (p.enabled) |v| next.enabled = v;
        if (p.host) |v| try next.host.set(v);
        if (p.port) |v| next.port = v;
        if (p.username) |v| try next.username.set(v);
        if (p.password) |v| try next.password.set(v);
        if (p.client_id) |v| try next.client_id.set(v);
        if (p.prefix) |v| try next.prefix.set(v);
        if (p.tls) |v| next.tls = v;
        if (next.enabled and next.host.len == 0) return error.Invalid;
        self.mqtt = next;
        self.revision += 1;
    }

    pub fn originPolicy(self: *const Config) api.OriginPolicy {
        var policy = api.OriginPolicy{};
        for (self.origins[0..self.origin_count], 0..) |*o, i| policy.allowed[i] = o.slice();
        policy.count = self.origin_count;
        return policy;
    }
};

// ipc encoding: explicit little-endian fields, fixed layout, schema byte first.

pub const schema_version: u8 = 1;

fn putText(out: []u8, off: *usize, t: Text) void {
    out[off.*] = t.len;
    @memcpy(out[off.* + 1 .. off.* + 1 + text_max], &t.bytes);
    off.* += 1 + text_max;
}

fn getText(in: []const u8, off: *usize) error{BadPayload}!Text {
    var t = Text{};
    t.len = in[off.*];
    if (t.len > text_max) return error.BadPayload;
    @memcpy(&t.bytes, in[off.* + 1 .. off.* + 1 + text_max]);
    off.* += 1 + text_max;
    return t;
}

const text_wire = 1 + text_max;
/// schema, revisions, brightness/base/generator, timezone, ntp, intervals, discovery, origins, mqtt
pub const encoded_len = 1 + 4 + 4 + 3 + text_wire + 5 + 4 + 2 + 4 + 1 + text_wire + 1 + api.max_origins * text_wire + 1 + text_wire + 2 + 4 * text_wire + 1;

pub fn encode(c: *const Config, out: *[encoded_len]u8) void {
    var o: usize = 0;
    out[o] = schema_version;
    o += 1;
    std.mem.writeInt(u32, out[o..][0..4], c.revision, .little);
    o += 4;
    std.mem.writeInt(u32, out[o..][0..4], c.saved_revision, .little);
    o += 4;
    out[o] = c.brightness;
    out[o + 1] = c.base;
    out[o + 2] = c.generator;
    o += 3;
    putText(out, &o, c.timezone);
    out[o] = if (c.ntp_server != null) 1 else 0;
    out[o + 1 ..][0..4].* = c.ntp_server orelse .{ 0, 0, 0, 0 };
    o += 5;
    std.mem.writeInt(u32, out[o..][0..4], c.ntp_interval_s, .little);
    o += 4;
    std.mem.writeInt(u16, out[o..][0..2], c.frame_timeout_ms, .little);
    o += 2;
    std.mem.writeInt(u32, out[o..][0..4], c.metrics_interval_s, .little);
    o += 4;
    out[o] = @intFromBool(c.discovery);
    o += 1;
    putText(out, &o, c.discovery_prefix);
    out[o] = c.origin_count;
    o += 1;
    for (c.origins) |t| putText(out, &o, t);
    out[o] = @intFromBool(c.mqtt.enabled);
    o += 1;
    putText(out, &o, c.mqtt.host);
    std.mem.writeInt(u16, out[o..][0..2], c.mqtt.port, .little);
    o += 2;
    putText(out, &o, c.mqtt.username);
    putText(out, &o, c.mqtt.password);
    putText(out, &o, c.mqtt.client_id);
    putText(out, &o, c.mqtt.prefix);
    out[o] = @intFromBool(c.mqtt.tls);
    o += 1;
    std.debug.assert(o == encoded_len);
}

pub fn decode(in: []const u8) error{BadPayload}!Config {
    if (in.len != encoded_len or in[0] != schema_version) return error.BadPayload;
    var c = Config{};
    var o: usize = 1;
    c.revision = std.mem.readInt(u32, in[o..][0..4], .little);
    o += 4;
    c.saved_revision = std.mem.readInt(u32, in[o..][0..4], .little);
    o += 4;
    c.brightness = in[o];
    c.base = in[o + 1];
    c.generator = in[o + 2];
    o += 3;
    c.timezone = try getText(in, &o);
    c.ntp_server = if (in[o] != 0) in[o + 1 ..][0..4].* else null;
    o += 5;
    c.ntp_interval_s = std.mem.readInt(u32, in[o..][0..4], .little);
    o += 4;
    c.frame_timeout_ms = std.mem.readInt(u16, in[o..][0..2], .little);
    o += 2;
    c.metrics_interval_s = std.mem.readInt(u32, in[o..][0..4], .little);
    o += 4;
    c.discovery = in[o] != 0;
    o += 1;
    c.discovery_prefix = try getText(in, &o);
    c.origin_count = in[o];
    if (c.origin_count > api.max_origins) return error.BadPayload;
    o += 1;
    for (&c.origins) |*t| t.* = try getText(in, &o);
    c.mqtt.enabled = in[o] != 0;
    o += 1;
    c.mqtt.host = try getText(in, &o);
    c.mqtt.port = std.mem.readInt(u16, in[o..][0..2], .little);
    o += 2;
    c.mqtt.username = try getText(in, &o);
    c.mqtt.password = try getText(in, &o);
    c.mqtt.client_id = try getText(in, &o);
    c.mqtt.prefix = try getText(in, &o);
    c.mqtt.tls = in[o] != 0;
    return c;
}

// json persistence (the supervisor's file; netd never sees it)

const FileForm = struct {
    schema: u8 = 1,
    revision: u32 = 0,
    brightness: u8 = 100,
    base: []const u8 = "art",
    generator: []const u8 = "popsquares",
    timezone: []const u8 = "UTC0",
    ntp_server: ?[]const u8 = null,
    ntp_interval_s: u32 = 300,
    frame_timeout_ms: u16 = 500,
    metrics_interval_s: u32 = 30,
    discovery: bool = false,
    discovery_prefix: []const u8 = "homeassistant",
    origins: []const []const u8 = &.{},
    mqtt: struct {
        enabled: bool = false,
        host: []const u8 = "",
        port: u16 = 1883,
        username: []const u8 = "",
        password: []const u8 = "",
        client_id: []const u8 = "",
        prefix: []const u8 = "",
        tls: bool = false,
    } = .{},
};

const base_names = [_][]const u8{ "art", "clock", "ip" };
const generator_names = [_][]const u8{ "popsquares", "plasma" };

fn nameIndex(names: []const []const u8, name: []const u8) ?u8 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return null;
}

pub const file_max = 2048;

/// render the config as json for the config file.
pub fn toJson(c: *const Config, out: []u8) error{Overflow}![]u8 {
    var w = std.Io.Writer.fixed(out);
    var origins_buf: [api.max_origins][]const u8 = undefined;
    for (c.origins[0..c.origin_count], 0..) |*o, i| origins_buf[i] = o.slice();
    var ntp_buf: [16]u8 = undefined;
    const ntp: ?[]const u8 = if (c.ntp_server) |s| (std.fmt.bufPrint(&ntp_buf, "{d}.{d}.{d}.{d}", .{ s[0], s[1], s[2], s[3] }) catch unreachable) else null;
    const form = FileForm{
        .revision = c.revision,
        .brightness = c.brightness,
        .base = base_names[@min(c.base, base_names.len - 1)],
        .generator = generator_names[@min(c.generator, generator_names.len - 1)],
        .timezone = c.timezone.slice(),
        .ntp_server = ntp,
        .ntp_interval_s = c.ntp_interval_s,
        .frame_timeout_ms = c.frame_timeout_ms,
        .metrics_interval_s = c.metrics_interval_s,
        .discovery = c.discovery,
        .discovery_prefix = c.discovery_prefix.slice(),
        .origins = origins_buf[0..c.origin_count],
        .mqtt = .{
            .enabled = c.mqtt.enabled,
            .host = c.mqtt.host.slice(),
            .port = c.mqtt.port,
            .username = c.mqtt.username.slice(),
            .password = c.mqtt.password.slice(),
            .client_id = c.mqtt.client_id.slice(),
            .prefix = c.mqtt.prefix.slice(),
            .tls = c.mqtt.tls,
        },
    };
    std.json.Stringify.value(form, .{}, &w) catch return error.Overflow;
    return w.buffered();
}

/// parse a config file; unknown or malformed content yields the defaults with an error.
pub fn fromJson(bytes: []const u8, arena: []u8) error{ Invalid, TooLong }!Config {
    var fba = std.heap.FixedBufferAllocator.init(arena);
    const f = std.json.parseFromSliceLeaky(FileForm, fba.allocator(), bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch return error.Invalid;
    if (f.schema != 1) return error.Invalid;
    var c = Config{};
    c.revision = f.revision;
    c.saved_revision = f.revision;
    if (f.brightness < 1 or f.brightness > 100) return error.Invalid;
    c.brightness = f.brightness;
    c.base = nameIndex(&base_names, f.base) orelse return error.Invalid;
    c.generator = nameIndex(&generator_names, f.generator) orelse return error.Invalid;
    try c.timezone.set(f.timezone);
    c.ntp_server = if (f.ntp_server) |s| (api.parseIpv4(s) orelse return error.Invalid) else null;
    c.ntp_interval_s = f.ntp_interval_s;
    c.frame_timeout_ms = f.frame_timeout_ms;
    c.metrics_interval_s = f.metrics_interval_s;
    c.discovery = f.discovery;
    try c.discovery_prefix.set(f.discovery_prefix);
    if (f.origins.len > api.max_origins) return error.Invalid;
    for (f.origins, 0..) |o, i| try c.origins[i].set(o);
    c.origin_count = @intCast(f.origins.len);
    c.mqtt.enabled = f.mqtt.enabled;
    try c.mqtt.host.set(f.mqtt.host);
    c.mqtt.port = f.mqtt.port;
    try c.mqtt.username.set(f.mqtt.username);
    try c.mqtt.password.set(f.mqtt.password);
    try c.mqtt.client_id.set(f.mqtt.client_id);
    try c.mqtt.prefix.set(f.mqtt.prefix);
    c.mqtt.tls = f.mqtt.tls;
    return c;
}

test "patches validate, bump the revision, and honour the expected revision" {
    var c = Config{};
    try c.patch(.{ .brightness = 40, .timezone = "JST-9", .ntp_server = .{ 10, 0, 0, 5 } });
    try std.testing.expectEqual(@as(u32, 1), c.revision);
    try std.testing.expectEqual(@as(u8, 40), c.brightness);
    try std.testing.expectEqualStrings("JST-9", c.timezone.slice());
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, c.ntp_server.?);
    try std.testing.expectError(error.RevisionConflict, c.patch(.{ .brightness = 50, .expected_revision = 0 }));
    try std.testing.expectEqual(@as(u8, 40), c.brightness);
    try c.patch(.{ .brightness = 50, .expected_revision = 1 });
    try std.testing.expectEqual(@as(u32, 2), c.revision);
    const long = [_]u8{'x'} ** 65;
    try std.testing.expectError(error.TooLong, c.patch(.{ .timezone = &long }));
    try std.testing.expectEqual(@as(u32, 2), c.revision); // a failed patch changes nothing
    try std.testing.expectError(error.Invalid, c.patchMqtt(.{ .enabled = true }));
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .password = "S3cret" });
    try std.testing.expectEqual(@as(u32, 3), c.revision);
    try std.testing.expectEqualStrings("S3cret", c.mqtt.password.slice());
}

test "ipc encoding round-trips every field" {
    var c = Config{};
    try c.patch(.{ .brightness = 7, .base = .clock, .generator = .plasma, .timezone = "EST5EDT,M3.2.0,M11.1.0", .ntp_server = .{ 1, 2, 3, 4 }, .ntp_interval_s = 600, .frame_timeout_ms = 250, .metrics_interval_s = 0, .discovery = true, .discovery_prefix = "ha" });
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .port = 8883, .username = "u", .password = "p", .client_id = "cid", .prefix = "tc002/x", .tls = true });
    c.origins[0] = Text.init("http://panel.local");
    c.origin_count = 1;
    c.saved_revision = 1;
    var buf: [encoded_len]u8 = undefined;
    encode(&c, &buf);
    const d = try decode(&buf);
    try std.testing.expectEqualDeep(c, d);
    var short = buf;
    short[0] = 9;
    try std.testing.expectError(error.BadPayload, decode(&short));
    try std.testing.expectError(error.BadPayload, decode(buf[0 .. encoded_len - 1]));
}

test "json persistence round-trips and rejects junk" {
    var c = Config{};
    try c.patch(.{ .brightness = 33, .base = .ip, .timezone = "AEST-10AEDT,M10.1.0,M4.1.0/3", .ntp_server = .{ 10, 0, 0, 5 } });
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .username = "tc002", .password = "Pw1", .prefix = "tc002/dev" });
    c.origins[0] = Text.init("http://panel");
    c.origin_count = 1;
    var out: [file_max]u8 = undefined;
    const text = try toJson(&c, &out);
    var arena: [4096]u8 = undefined;
    const back = try fromJson(text, &arena);
    try std.testing.expectEqual(c.revision, back.revision);
    try std.testing.expectEqual(c.revision, back.saved_revision);
    try std.testing.expectEqual(@as(u8, 33), back.brightness);
    try std.testing.expectEqual(@as(u8, 2), back.base);
    try std.testing.expectEqualStrings("AEST-10AEDT,M10.1.0,M4.1.0/3", back.timezone.slice());
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, back.ntp_server.?);
    try std.testing.expectEqualStrings("Pw1", back.mqtt.password.slice());
    try std.testing.expectEqualStrings("http://panel", back.origins[0].slice());
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"brightness\":0}", &arena));
    try std.testing.expectError(error.Invalid, fromJson("not json", &arena));
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"bogus\":1}", &arena));
}

test "origin policy is derived from the config" {
    var c = Config{};
    c.origins[0] = Text.init("http://a");
    c.origin_count = 1;
    const p = c.originPolicy();
    try std.testing.expect(p.allows("http://a"));
    try std.testing.expect(!p.allows("http://b"));
    try std.testing.expect(p.allows(null));
}
