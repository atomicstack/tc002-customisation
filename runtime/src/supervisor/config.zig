//! the supervisor's durable settings: fixed-size fields, validated patches that bump a revision,
//! an optional expected revision to reject lost updates, json persistence, and an explicit
//! little-endian ipc encoding so netd never sees the file. pure.
const std = @import("std");
const api = @import("../net/api.zig");
const clock = @import("../scene/clock.zig");
const clockfont = @import("../scene/clockfont.zig");
const param = @import("../scene/param.zig");
const scene = @import("../scene/scene.zig");
const ip = @import("../scene/ip.zig");
const ntfy_url = @import("../ntfy/url.zig");
const tz = @import("../scene/tz.zig");
const solar = @import("../sys/solar.zig");
const night = @import("night.zig");

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

/// the ntfy subscription (https://docs.ntfy.sh/subscribe/api/): the official service or a
/// self-hosted server. the token and password are secrets: never returned by the api.
pub const Ntfy = struct {
    enabled: bool = false,
    url: Text = .{},
    topic: Text = .{},
    token: Text = .{},
    username: Text = .{},
    password: Text = .{},
    duration_s: u16 = 10,
    insecure: bool = false,
};

pub const Config = struct {
    revision: u32 = 0,
    saved_revision: u32 = 0,
    brightness: u8 = 100,
    /// index into base_names: the clock, so a cold start never shows the art generator
    base: u8 = base_clock,
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
    ntfy: Ntfy = .{},
    clock_font: u8 = 0,
    clock_colour_mode: u8 = 0,
    clock_colour: [3]u8 = .{ 255, 255, 255 },
    clock_colour2: [3]u8 = .{ 255, 255, 255 },
    clock_gradient: u8 = 0,
    clock_spread: u8 = clock.default_spread,
    clock_digit: u8 = 0,
    ip_mode: u8 = 0,
    /// the night brightness schedule: off by default, so a device that has never been told where
    /// it is behaves exactly as it did before
    night: bool = false,
    night_brightness: u8 = 10,
    /// how long before sunset the dimming starts, and how long after sunrise it finishes
    night_lead_min: u8 = 20,
    /// a location pinned by hand, in hundredths of a degree; null takes the timezone's own
    latitude: ?i16 = null,
    longitude: ?i16 = null,
    /// the generators' own parameters: generic slots, because a generator is pluggable and has no
    /// settings fields of its own. the clock and the ip scene keep their named ones.
    generator_params: [param.owner_count]param.Values = scene.generator_defaults,

    /// the ip scene's layout (unknown stored values fall back to the default).
    pub fn ipMode(self: *const Config) ip.Mode {
        return enumOr(ip.Mode, self.ip_mode, .lines);
    }

    /// the clock style these settings describe (unknown stored values fall back to defaults).
    pub fn clockStyle(self: *const Config) clock.Style {
        return .{
            .font = enumOr(clock.Font, self.clock_font, .classic),
            .mode = enumOr(clock.ColourMode, self.clock_colour_mode, .solid),
            .colour = self.clock_colour,
            .colour2 = self.clock_colour2,
            .gradient = enumOr(clock.Gradient, self.clock_gradient, .horizontal),
            .spread = self.clock_spread,
            .digit = enumOr(clockfont.DigitStyle, self.clock_digit, .solid),
        };
    }

    /// the posix rule the renderer gets: the timezone text itself if it is a rule, or the rule
    /// behind an iana zone name; "UTC0" if the stored text is neither.
    pub fn tzRule(self: *const Config) []const u8 {
        return tz.resolve(self.timezone.slice()) orelse "UTC0";
    }

    /// where the schedule thinks the device is: a location pinned by hand, or failing that the
    /// reference point of the configured iana zone. null when neither is available, which is what
    /// a bare posix rule and the `Etc/*` zones leave you with.
    pub fn point(self: *const Config) ?solar.Point {
        if (self.latitude) |lat| {
            if (self.longitude) |lon| return .{ .lat_c = lat, .lon_c = lon };
        }
        const p = tz.pointFor(self.timezone.slice()) orelse return null;
        return .{ .lat_c = p.lat_c, .lon_c = p.lon_c };
    }

    /// true when the location comes from the timezone rather than from a pinned pair
    pub fn locationAuto(self: *const Config) bool {
        return self.latitude == null or self.longitude == null;
    }

    pub fn nightSettings(self: *const Config) night.Settings {
        return .{
            .enabled = self.night,
            .day = self.brightness,
            .night = self.night_brightness,
            .lead_s = @as(u32, self.night_lead_min) * 60,
        };
    }

    pub const PatchError = error{ RevisionConflict, TooLong, Invalid };

    /// apply a validated patch; every accepted patch is one revision.
    pub fn patch(self: *Config, p: api.ConfigPatch) PatchError!void {
        if (p.expected_revision) |want| if (want != self.revision) return error.RevisionConflict;
        var next = self.*;
        if (p.brightness) |v| next.brightness = v;
        if (p.base) |b| next.base = @intFromEnum(b);
        if (p.generator) |g| next.generator = @intFromEnum(g);
        if (p.timezone) |t| {
            try next.timezone.set(t);
            if (tz.resolve(t) == null) return error.Invalid;
        }
        if (p.ntp_server) |s| next.ntp_server = s;
        if (p.ntp_interval_s) |v| next.ntp_interval_s = v;
        if (p.frame_timeout_ms) |v| next.frame_timeout_ms = v;
        if (p.metrics_interval_s) |v| next.metrics_interval_s = v;
        if (p.discovery) |v| next.discovery = v;
        if (p.discovery_prefix) |v| try next.discovery_prefix.set(v);
        if (p.clock_font) |v| next.clock_font = @intFromEnum(v);
        if (p.clock_colour_mode) |v| next.clock_colour_mode = @intFromEnum(v);
        if (p.clock_colour) |v| next.clock_colour = v;
        if (p.clock_colour2) |v| next.clock_colour2 = v;
        if (p.clock_gradient) |v| next.clock_gradient = @intFromEnum(v);
        if (p.clock_spread) |v| next.clock_spread = v;
        if (p.clock_digit) |v| next.clock_digit = @intFromEnum(v);
        for (p.generator_params) |rp| {
            if (rp.owner >= param.owner_count or rp.slot >= param.max_per_owner) return error.Invalid;
            next.generator_params[rp.owner][rp.slot] = rp.value;
        }
        if (p.ip_mode) |v| next.ip_mode = @intFromEnum(v);
        if (p.night) |v| next.night = v;
        if (p.night_brightness) |v| {
            if (v < 1 or v > 100) return error.Invalid;
            next.night_brightness = v;
        }
        if (p.night_lead_min) |v| {
            if (v > api.max_night_lead_min) return error.Invalid;
            next.night_lead_min = v;
        }
        // dropping back to the timezone first, so a patch that sets both wins
        if (p.location_auto) |v| if (v) {
            next.latitude = null;
            next.longitude = null;
        };
        if (p.location) |l| {
            if (@abs(l.lat_c) > 9000 or @abs(l.lon_c) > 18000) return error.Invalid;
            next.latitude = l.lat_c;
            next.longitude = l.lon_c;
        }
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

    pub fn patchNtfy(self: *const Config, p: api.NtfyPut) PatchError!Ntfy {
        var next = self.ntfy;
        if (p.enabled) |v| next.enabled = v;
        if (p.url) |v| try next.url.set(v);
        if (p.topic) |v| try next.topic.set(v);
        if (p.token) |v| try next.token.set(v);
        if (p.username) |v| try next.username.set(v);
        if (p.password) |v| try next.password.set(v);
        if (p.duration_s) |v| next.duration_s = v;
        if (p.insecure) |v| next.insecure = v;
        if (next.url.len > 0) _ = ntfy_url.parse(next.url.slice()) catch return error.Invalid;
        if (next.duration_s < 1 or next.duration_s > 300) return error.Invalid;
        if (next.enabled and (next.url.len == 0 or next.topic.len == 0)) return error.Invalid;
        return next;
    }

    /// apply a validated ntfy patch (see `patchNtfy`); bumps the revision.
    pub fn setNtfy(self: *Config, next: Ntfy) void {
        self.ntfy = next;
        self.revision += 1;
    }

    pub fn originPolicy(self: *const Config) api.OriginPolicy {
        var policy = api.OriginPolicy{};
        for (self.origins[0..self.origin_count], 0..) |*o, i| policy.allowed[i] = o.slice();
        policy.count = self.origin_count;
        return policy;
    }
};

fn enumOr(comptime E: type, value: u8, default: E) E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (f.value == value) return @enumFromInt(f.value);
    return default;
}

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
/// schema, revisions, brightness/base/generator, timezone, ntp, intervals, discovery, origins,
/// mqtt, the clock style, the night schedule
pub const encoded_len = 1 + 4 + 4 + 3 + text_wire + 5 + 4 + 2 + 4 + 1 + text_wire + 1 + api.max_origins * text_wire + 1 + text_wire + 2 + 4 * text_wire + 1 + 12 + 8 + 1 + 5 * text_wire + 2 + 1 + param.owner_count * param.max_per_owner * 4;

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
    out[o] = c.clock_font;
    out[o + 1] = c.clock_colour_mode;
    out[o + 2 ..][0..3].* = c.clock_colour;
    out[o + 5 ..][0..3].* = c.clock_colour2;
    out[o + 8] = c.clock_gradient;
    out[o + 9] = c.clock_spread;
    out[o + 10] = c.ip_mode;
    out[o + 11] = c.clock_digit;
    o += 12;
    out[o] = @intFromBool(c.night);
    out[o + 1] = c.night_brightness;
    out[o + 2] = c.night_lead_min;
    out[o + 3] = @intFromBool(c.latitude != null and c.longitude != null);
    std.mem.writeInt(i16, out[o + 4 ..][0..2], c.latitude orelse 0, .little);
    std.mem.writeInt(i16, out[o + 6 ..][0..2], c.longitude orelse 0, .little);
    o += 8;
    out[o] = @intFromBool(c.ntfy.enabled);
    o += 1;
    putText(out, &o, c.ntfy.url);
    putText(out, &o, c.ntfy.topic);
    putText(out, &o, c.ntfy.token);
    putText(out, &o, c.ntfy.username);
    putText(out, &o, c.ntfy.password);
    std.mem.writeInt(u16, out[o..][0..2], c.ntfy.duration_s, .little);
    o += 2;
    out[o] = @intFromBool(c.ntfy.insecure);
    o += 1;
    for (c.generator_params) |slots| {
        for (slots) |v| {
            std.mem.writeInt(u32, out[o..][0..4], v, .little);
            o += 4;
        }
    }
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
    o += 1;
    c.clock_font = in[o];
    c.clock_colour_mode = in[o + 1];
    c.clock_colour = in[o + 2 ..][0..3].*;
    c.clock_colour2 = in[o + 5 ..][0..3].*;
    c.clock_gradient = in[o + 8];
    c.clock_spread = in[o + 9];
    c.ip_mode = in[o + 10];
    c.clock_digit = in[o + 11];
    o += 12;
    c.night = in[o] != 0;
    c.night_brightness = in[o + 1];
    c.night_lead_min = in[o + 2];
    if (in[o + 3] != 0) {
        c.latitude = std.mem.readInt(i16, in[o + 4 ..][0..2], .little);
        c.longitude = std.mem.readInt(i16, in[o + 6 ..][0..2], .little);
    }
    o += 8;
    c.ntfy.enabled = in[o] != 0;
    o += 1;
    c.ntfy.url = try getText(in, &o);
    c.ntfy.topic = try getText(in, &o);
    c.ntfy.token = try getText(in, &o);
    c.ntfy.username = try getText(in, &o);
    c.ntfy.password = try getText(in, &o);
    c.ntfy.duration_s = std.mem.readInt(u16, in[o..][0..2], .little);
    o += 2;
    c.ntfy.insecure = in[o] != 0;
    o += 1;
    for (&c.generator_params, 0..) |*slots, gi| {
        for (slots) |*v| {
            v.* = std.mem.readInt(u32, in[o..][0..4], .little);
            o += 4;
        }
        if (scene.slotsUnset(slots.*)) slots.* = scene.generator_defaults[gi];
    }
    return c;
}

// json persistence (the supervisor's file; netd never sees it)

const FileForm = struct {
    schema: u8 = 1,
    revision: u32 = 0,
    brightness: u8 = 100,
    base: []const u8 = base_names[base_clock],
    generator: []const u8 = "popsquares",
    timezone: []const u8 = "UTC0",
    ntp_server: ?[]const u8 = null,
    ntp_interval_s: u32 = 300,
    frame_timeout_ms: u16 = 500,
    metrics_interval_s: u32 = 30,
    discovery: bool = false,
    discovery_prefix: []const u8 = "homeassistant",
    origins: []const []const u8 = &.{},
    clock_font: []const u8 = "classic",
    clock_colour_mode: []const u8 = "solid",
    clock_colour: []const u8 = "ffffff",
    clock_colour2: []const u8 = "ffffff",
    clock_gradient: []const u8 = "horizontal",
    clock_spread: u8 = clock.default_spread,
    clock_digit: []const u8 = "solid",
    generator_params: [param.owner_count]param.Values = scene.generator_defaults,
    ip_mode: []const u8 = "lines",
    night: bool = false,
    night_brightness: u8 = 10,
    night_lead_min: u8 = 20,
    latitude: ?i16 = null,
    longitude: ?i16 = null,
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
    ntfy: struct {
        enabled: bool = false,
        url: []const u8 = "",
        topic: []const u8 = "",
        token: []const u8 = "",
        username: []const u8 = "",
        password: []const u8 = "",
        duration_s: u16 = 10,
        insecure: bool = false,
    } = .{},
};

const base_names = [_][]const u8{ "art", "clock", "ip" };
/// the base scene of a device with no settings file: a power cycle wipes /tmp, and the first
/// frame after a cold start must be the clock rather than a flash of the art generator.
const base_clock: u8 = 1;
const generator_names = [_][]const u8{ "popsquares", "plasma" };

fn nameIndex(names: []const []const u8, name: []const u8) ?u8 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return null;
}

pub const file_max = 4096; // the generators' parameter slots pushed the document past 2 kb

/// render the config as json for the config file.
pub fn toJson(c: *const Config, out: []u8) error{Overflow}![]u8 {
    var w = std.Io.Writer.fixed(out);
    var origins_buf: [api.max_origins][]const u8 = undefined;
    for (c.origins[0..c.origin_count], 0..) |*o, i| origins_buf[i] = o.slice();
    var ntp_buf: [16]u8 = undefined;
    const ntp: ?[]const u8 = if (c.ntp_server) |s| (std.fmt.bufPrint(&ntp_buf, "{d}.{d}.{d}.{d}", .{ s[0], s[1], s[2], s[3] }) catch unreachable) else null;
    var colour_buf: [6]u8 = undefined;
    var colour2_buf: [6]u8 = undefined;
    const form = FileForm{
        .clock_font = @tagName(enumOr(clock.Font, c.clock_font, .classic)),
        .clock_colour_mode = @tagName(enumOr(clock.ColourMode, c.clock_colour_mode, .solid)),
        .clock_colour = std.fmt.bufPrint(&colour_buf, "{x:0>2}{x:0>2}{x:0>2}", .{ c.clock_colour[0], c.clock_colour[1], c.clock_colour[2] }) catch unreachable,
        .clock_colour2 = std.fmt.bufPrint(&colour2_buf, "{x:0>2}{x:0>2}{x:0>2}", .{ c.clock_colour2[0], c.clock_colour2[1], c.clock_colour2[2] }) catch unreachable,
        .clock_gradient = @tagName(enumOr(clock.Gradient, c.clock_gradient, .horizontal)),
        .clock_spread = c.clock_spread,
        .clock_digit = @tagName(enumOr(clockfont.DigitStyle, c.clock_digit, .solid)),
        .generator_params = c.generator_params,
        .ip_mode = @tagName(enumOr(ip.Mode, c.ip_mode, .lines)),
        .night = c.night,
        .night_brightness = c.night_brightness,
        .night_lead_min = c.night_lead_min,
        .latitude = c.latitude,
        .longitude = c.longitude,
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
        .ntfy = .{
            .enabled = c.ntfy.enabled,
            .url = c.ntfy.url.slice(),
            .topic = c.ntfy.topic.slice(),
            .token = c.ntfy.token.slice(),
            .username = c.ntfy.username.slice(),
            .password = c.ntfy.password.slice(),
            .duration_s = c.ntfy.duration_s,
            .insecure = c.ntfy.insecure,
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
    c.night = f.night;
    if (f.night_brightness < 1 or f.night_brightness > 100) return error.Invalid;
    c.night_brightness = f.night_brightness;
    if (f.night_lead_min > api.max_night_lead_min) return error.Invalid;
    c.night_lead_min = f.night_lead_min;
    if (f.latitude) |v| if (@abs(v) > 9000) return error.Invalid;
    if (f.longitude) |v| if (@abs(v) > 18000) return error.Invalid;
    c.latitude = f.latitude;
    c.longitude = f.longitude;
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
    c.ntfy.enabled = f.ntfy.enabled;
    try c.ntfy.url.set(f.ntfy.url);
    try c.ntfy.topic.set(f.ntfy.topic);
    try c.ntfy.token.set(f.ntfy.token);
    try c.ntfy.username.set(f.ntfy.username);
    try c.ntfy.password.set(f.ntfy.password);
    c.ntfy.duration_s = f.ntfy.duration_s;
    c.ntfy.insecure = f.ntfy.insecure;
    if (c.ntfy.url.len > 0) _ = ntfy_url.parse(c.ntfy.url.slice()) catch return error.Invalid;
    if (c.ntfy.duration_s < 1 or c.ntfy.duration_s > 300) return error.Invalid;
    c.clock_font = @intFromEnum(api.enumByName(clock.Font, f.clock_font) orelse return error.Invalid);
    c.clock_colour_mode = @intFromEnum(api.enumByName(clock.ColourMode, f.clock_colour_mode) orelse return error.Invalid);
    c.clock_colour = api.parseColour(f.clock_colour) orelse return error.Invalid;
    c.clock_colour2 = api.parseColour(f.clock_colour2) orelse return error.Invalid;
    c.clock_gradient = @intFromEnum(api.enumByName(clock.Gradient, f.clock_gradient) orelse return error.Invalid);
    c.clock_spread = f.clock_spread;
    c.clock_digit = @intFromEnum(api.enumByName(clockfont.DigitStyle, f.clock_digit) orelse return error.Invalid);
    c.generator_params = f.generator_params;
    for (&c.generator_params, 0..) |*slots, i| if (scene.slotsUnset(slots.*)) {
        slots.* = scene.generator_defaults[i];
    };
    c.ip_mode = @intFromEnum(api.enumByName(ip.Mode, f.ip_mode) orelse return error.Invalid);
    if (tz.resolve(f.timezone) == null) return error.Invalid;
    return c;
}

test "ntfy patches validate the url, the topic and the duration" {
    var c = Config{};
    try std.testing.expectError(error.Invalid, c.patchNtfy(.{ .enabled = true }));
    try std.testing.expectError(error.Invalid, c.patchNtfy(.{ .url = "ntfy.sh" }));
    try std.testing.expectError(error.Invalid, c.patchNtfy(.{ .duration_s = 0 }));
    const n = try c.patchNtfy(.{ .url = "http://10.0.0.5:8080/ntfy", .topic = "t", .enabled = true });
    try std.testing.expect(n.enabled);
    c.setNtfy(n);
    try std.testing.expectEqual(@as(u32, 1), c.revision);
    const off = try c.patchNtfy(.{ .enabled = false });
    try std.testing.expectEqualStrings("t", off.topic.slice());
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
    try std.testing.expectError(error.Invalid, c.patch(.{ .timezone = "Mars/Olympus" }));
    try std.testing.expectEqual(@as(u32, 2), c.revision); // a failed patch changes nothing
    try c.patch(.{ .timezone = "Europe/Amsterdam" });
    try std.testing.expectEqualStrings("Europe/Amsterdam", c.timezone.slice());
    try std.testing.expectEqualStrings("CET-1CEST,M3.5.0,M10.5.0/3", c.tzRule());
    try c.patch(.{ .timezone = "JST-9", .clock_spread = 80 });
    try std.testing.expectEqualStrings("JST-9", c.tzRule());
    try std.testing.expectEqual(@as(u8, 80), c.clockStyle().spread);
    try std.testing.expectError(error.Invalid, c.patchMqtt(.{ .enabled = true }));
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .password = "S3cret" });
    try std.testing.expectEqual(@as(u32, 5), c.revision);
    try std.testing.expectEqualStrings("S3cret", c.mqtt.password.slice());
}

test "the night schedule's settings, and where the device thinks it is" {
    var c = Config{};
    try std.testing.expect(!c.night); // off until asked for, so nothing changes for anyone else
    try std.testing.expect(c.point() == null); // and utc0 is nowhere

    // the timezone alone places the device
    try c.patch(.{ .timezone = "Australia/Sydney", .night = true, .night_brightness = 12, .night_lead_min = 30 });
    try std.testing.expect(c.locationAuto());
    try std.testing.expectEqual(@as(i16, -3387), c.point().?.lat_c);
    const s = c.nightSettings();
    try std.testing.expect(s.enabled);
    try std.testing.expectEqual(@as(u8, 100), s.day); // daylight is the settings' own brightness
    try std.testing.expectEqual(@as(u8, 12), s.night);
    try std.testing.expectEqual(@as(u32, 30 * 60), s.lead_s);

    // a pinned location wins, and giving it back to the timezone restores the zone's own point
    try c.patch(.{ .location = .{ .lat_c = -3143, .lon_c = 15291 } });
    try std.testing.expect(!c.locationAuto());
    try std.testing.expectEqual(@as(i16, -3143), c.point().?.lat_c);
    try c.patch(.{ .location_auto = true });
    try std.testing.expectEqual(@as(i16, -3387), c.point().?.lat_c);
    // both at once: the pinned pair wins over the fallback in the same patch
    try c.patch(.{ .location_auto = true, .location = .{ .lat_c = 100, .lon_c = 200 } });
    try std.testing.expectEqual(@as(i16, 100), c.point().?.lat_c);

    // a bare posix rule names no place, so the schedule has nothing to go on without a pin
    try c.patch(.{ .location_auto = true, .timezone = "AEST-10AEDT,M10.1.0,M4.1.0/3" });
    try std.testing.expect(c.point() == null);

    const before = c.revision;
    try std.testing.expectError(error.Invalid, c.patch(.{ .night_brightness = 0 }));
    try std.testing.expectError(error.Invalid, c.patch(.{ .night_brightness = 101 }));
    try std.testing.expectError(error.Invalid, c.patch(.{ .night_lead_min = 121 }));
    try std.testing.expectError(error.Invalid, c.patch(.{ .location = .{ .lat_c = 9001, .lon_c = 0 } }));
    try std.testing.expectError(error.Invalid, c.patch(.{ .location = .{ .lat_c = 0, .lon_c = -18001 } }));
    try std.testing.expectEqual(before, c.revision); // a rejected patch changes nothing
}

test "ipc encoding round-trips every field" {
    var c = Config{};
    try c.patch(.{ .brightness = 7, .base = .clock, .generator = .plasma, .timezone = "EST5EDT,M3.2.0,M11.1.0", .ntp_server = .{ 1, 2, 3, 4 }, .ntp_interval_s = 600, .frame_timeout_ms = 250, .metrics_interval_s = 0, .discovery = true, .discovery_prefix = "ha", .clock_font = .segment, .clock_colour_mode = .gradient, .clock_colour = .{ 1, 2, 3 }, .clock_colour2 = .{ 4, 5, 6 }, .clock_gradient = .diagonal, .clock_spread = 12, .ip_mode = .scroll, .night = true, .night_brightness = 12, .night_lead_min = 35, .location = .{ .lat_c = -3387, .lon_c = 15122 } });
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .port = 8883, .username = "u", .password = "p", .client_id = "cid", .prefix = "tc002/x", .tls = true });
    c.origins[0] = Text.init("http://panel.local");
    c.origin_count = 1;
    c.setNtfy(try c.patchNtfy(.{ .enabled = true, .url = "https://ntfy.sh", .topic = "alerts", .token = "tk_secret", .duration_s = 7, .insecure = true }));
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
    try c.patch(.{ .brightness = 33, .base = .ip, .timezone = "AEST-10AEDT,M10.1.0,M4.1.0/3", .ntp_server = .{ 10, 0, 0, 5 }, .clock_font = .big, .clock_colour = .{ 0xff, 0x80, 0x00 }, .clock_colour_mode = .gradient, .ip_mode = .big, .night = true, .night_brightness = 8, .night_lead_min = 0, .location = .{ .lat_c = 5151, .lon_c = -13 } });
    try c.patchMqtt(.{ .enabled = true, .host = "10.0.0.2", .username = "tc002", .password = "Pw1", .prefix = "tc002/dev" });
    c.origins[0] = Text.init("http://panel");
    c.origin_count = 1;
    var out: [file_max]u8 = undefined;
    c.setNtfy(try c.patchNtfy(.{ .enabled = true, .url = "https://ntfy.sh", .topic = "alerts", .token = "tk_secret", .duration_s = 7, .insecure = true }));
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
    try std.testing.expectEqual(clock.Font.big, back.clockStyle().font);
    try std.testing.expect(back.night);
    try std.testing.expectEqual(@as(u8, 8), back.night_brightness);
    try std.testing.expectEqual(@as(u8, 0), back.night_lead_min);
    try std.testing.expectEqual(@as(i16, 5151), back.latitude.?);
    try std.testing.expectEqual(@as(i16, -13), back.longitude.?);
    try std.testing.expectEqual(clock.ColourMode.gradient, back.clockStyle().mode);
    try std.testing.expectEqual(ip.Mode.big, back.ipMode());
    try std.testing.expectEqualStrings("alerts", back.ntfy.topic.slice());
    try std.testing.expectEqualStrings("tk_secret", back.ntfy.token.slice());
    try std.testing.expectEqual(@as(u16, 7), back.ntfy.duration_s);
    try std.testing.expect(back.ntfy.enabled and back.ntfy.insecure);
    try std.testing.expectEqual([3]u8{ 0xff, 0x80, 0x00 }, back.clockStyle().colour);
    try std.testing.expectEqual(clock.default_spread, back.clockStyle().spread);
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"timezone\":\"Nowhere/Land\"}", &arena));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"clock_colour\":\"ff8000\"") != null);
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"clock_font\":\"comic\"}", &arena));
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"ip_mode\":\"huge\"}", &arena));
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"clock_colour\":\"red\"}", &arena));
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"brightness\":0}", &arena));
    try std.testing.expectError(error.Invalid, fromJson("not json", &arena));
    try std.testing.expectError(error.Invalid, fromJson("{\"schema\":1,\"bogus\":1}", &arena));
}

test "a cold start with no settings file shows the clock, never art" {
    // a power cycle wipes /tmp, so the very first frame after a cold start comes from these
    // defaults. it must be the clock: art is only ever shown when it was asked for.
    const c = Config{};
    try std.testing.expectEqualStrings("clock", base_names[c.base]);

    var arena: [4096]u8 = undefined;
    const back = try fromJson("{\"schema\":1}", &arena);
    try std.testing.expectEqualStrings("clock", base_names[back.base]);
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

test "a generator's parameters round-trip, and unset ones take the declared defaults" {
    var c = Config{};
    // a fresh config already holds what each generator says its defaults are
    try std.testing.expectEqualSlices(u32, &scene.generator_defaults[2], &c.generator_params[2]);

    // a patch writes named slots and leaves the rest alone
    try c.patch(.{ .generator_params = &.{
        .{ .owner = 2, .slot = 5, .value = 12 },
        .{ .owner = 2, .slot = 6, .value = 150 },
    } });
    try std.testing.expectEqual(@as(u32, 12), c.generator_params[2][5]);
    try std.testing.expectEqual(@as(u32, 150), c.generator_params[2][6]);
    try std.testing.expectEqual(scene.generator_defaults[2][1], c.generator_params[2][1]);

    // and it survives the file
    var out: [file_max]u8 = undefined;
    const text = try toJson(&c, &out);
    var arena: [8192]u8 = undefined;
    const back = try fromJson(text, &arena);
    try std.testing.expectEqual(@as(u32, 12), back.generator_params[2][5]);
    try std.testing.expectEqual(@as(u32, 150), back.generator_params[2][6]);

    // a slot outside the table is refused rather than written past the end
    try std.testing.expectError(error.Invalid, c.patch(.{ .generator_params = &.{.{ .owner = 9, .slot = 0, .value = 1 }} }));
    try std.testing.expectError(error.Invalid, c.patch(.{ .generator_params = &.{.{ .owner = 2, .slot = 99, .value = 1 }} }));
}
