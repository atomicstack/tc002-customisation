//! the `/api/v1` surface as pure logic: bearer authentication with constant-time comparison,
//! the origin policy, route matching, request bodies into typed operations, and results into
//! response bodies. netd owns the sockets and the relay; this module never blocks.
const std = @import("std");
const http = @import("http.zig");
const json = @import("json.zig");
const geometry = @import("../panel/geometry.zig");
const arbiter = @import("../scene/arbiter.zig");
const scene = @import("../scene/scene.zig");
const actions = @import("../input/actions.zig");
const clock = @import("../scene/clock.zig");
const transition = @import("../panel/transition.zig");

pub const token_len = 32;
pub const Token = [token_len]u8;
pub const Credentials = struct { control: Token, admin: Token };

pub const Authority = enum { none, control, admin };

pub fn authenticate(creds: *const Credentials, authorization: ?[]const u8) Authority {
    const header = authorization orelse return .none;
    if (header.len != 7 + token_len * 2 or !std.mem.eql(u8, header[0..7], "Bearer ")) return .none;
    var presented: Token = undefined;
    _ = std.fmt.hexToBytes(&presented, header[7..]) catch return .none;
    // compare against both tokens unconditionally so timing does not reveal which one matched
    const is_admin = std.crypto.timing_safe.eql(Token, presented, creds.admin);
    const is_control = std.crypto.timing_safe.eql(Token, presented, creds.control);
    if (is_admin) return .admin;
    if (is_control) return .control;
    return .none;
}

pub const max_origins = 4;
pub const OriginPolicy = struct {
    allowed: [max_origins][]const u8 = .{ "", "", "", "" },
    count: u8 = 0,

    /// no origin header (a non-browser client) is allowed; a browser origin only if listed exactly.
    pub fn allows(self: *const OriginPolicy, origin: ?[]const u8) bool {
        const o = origin orelse return true;
        for (self.allowed[0..self.count]) |a| if (std.mem.eql(u8, a, o)) return true;
        return false;
    }
};

pub const Base = arbiter.Base;

pub const ActionKind = enum { brightness, reseed, arm_stream, power };

pub const Op = union(enum) {
    status,
    scenes,
    set_scene: struct { base: Base, generator: ?scene.Generator, seed: ?u32, style: ?clock.StylePatch, transition: ?transition.Spec, request_id: u64, epoch: ?u32 },
    action: struct { kind: ActionKind, brightness: ?u8, seed: ?u32, power: ?bool, request_id: u64, epoch: u32 },
    /// the framebuffer as shown; `raw` = octets instead of the json document
    screen: struct { raw: bool },
    /// a page of the supervisor's log ring after this sequence number
    logs: struct { after: u32 },
    /// a remote control event: the same paths as a physical press
    input: struct { control: actions.Control, event: actions.EdgeEvent, steps: u8, request_id: u64, epoch: u32 },
    notify: struct { text: []const u8, colour: [3]u8, duration_s: u16, transition: ?transition.Spec, request_id: u64, epoch: u32 },
    frame: struct { rgb: *const geometry.Rgb, duration_s: u16, transition: ?transition.Spec, request_id: u64, epoch: u32 },
    config_get,
    config_patch: ConfigPatch,
    config_save: struct { revision: ?u32 },
    mqtt_get,
    mqtt_put: MqttPut,
    mqtt_status,
    streams_create,
    streams_palette,
    streams_delete,
};

pub const ConfigPatch = struct {
    brightness: ?u8 = null,
    base: ?Base = null,
    generator: ?scene.Generator = null,
    timezone: ?[]const u8 = null,
    ntp_server: ?[4]u8 = null,
    ntp_interval_s: ?u32 = null,
    frame_timeout_ms: ?u16 = null,
    metrics_interval_s: ?u32 = null,
    discovery: ?bool = null,
    discovery_prefix: ?[]const u8 = null,
    expected_revision: ?u32 = null,
    clock_font: ?clock.Font = null,
    clock_colour_mode: ?clock.ColourMode = null,
    clock_colour: ?[3]u8 = null,
    clock_colour2: ?[3]u8 = null,
    clock_gradient: ?clock.Gradient = null,
    clock_spread: ?u8 = null,
};

pub const MqttPut = struct {
    enabled: ?bool = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    tls: ?bool = null,
};

/// what a request becomes before any i/o: an operation or an immediate error response.
pub const Route = union(enum) {
    op: Op,
    reject: Reject,
};

pub const Reject = struct { status: u16, code: []const u8, message: []const u8 };

pub const Arena = [json.arena_size]u8;

// json wire schemas (request bodies)
const ClockBody = struct { font: ?[]const u8 = null, colour_mode: ?[]const u8 = null, colour: ?[]const u8 = null, colour2: ?[]const u8 = null, gradient: ?[]const u8 = null, spread: ?u8 = null };
const SceneBody = struct { base: []const u8, generator: ?[]const u8 = null, seed: ?u32 = null, clock: ?ClockBody = null, transition: ?[]const u8 = null, direction: ?[]const u8 = null, transition_ms: ?u32 = null, exit: ?[]const u8 = null, request_id: []const u8, epoch: ?u32 = null };
const ActionBody = struct { action: []const u8, brightness: ?u8 = null, seed: ?u32 = null, power: ?bool = null, request_id: []const u8, epoch: u32 };
const InputBody = struct { control: []const u8, event: []const u8, steps: u8 = 1, request_id: []const u8, epoch: u32 };
const NotifyBody = struct { text: []const u8, colour: ?[]const u8 = null, duration_s: u16 = 5, transition: ?[]const u8 = null, direction: ?[]const u8 = null, transition_ms: ?u32 = null, exit: ?[]const u8 = null, request_id: []const u8, epoch: u32 };
const ConfigBody = struct {
    brightness: ?u8 = null,
    base: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    ntp_server: ?[]const u8 = null,
    ntp_interval_s: ?u32 = null,
    frame_timeout_ms: ?u16 = null,
    metrics_interval_s: ?u32 = null,
    discovery: ?bool = null,
    discovery_prefix: ?[]const u8 = null,
    expected_revision: ?u32 = null,
    clock_font: ?[]const u8 = null,
    clock_colour_mode: ?[]const u8 = null,
    clock_colour: ?[]const u8 = null,
    clock_colour2: ?[]const u8 = null,
    clock_gradient: ?[]const u8 = null,
    clock_spread: ?u8 = null,
};
const SaveBody = struct { revision: ?u32 = null };
const MqttBody = struct {
    enabled: ?bool = null,
    host: ?[]const u8 = null,
    port: ?u16 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    tls: ?bool = null,
};

fn bad(code: []const u8, message: []const u8) Route {
    return .{ .reject = .{ .status = 400, .code = code, .message = message } };
}

fn jsonError(e: json.Error) Route {
    return switch (e) {
        error.TooLarge => .{ .reject = .{ .status = 413, .code = "body_too_large", .message = "json bodies are limited to 4096 bytes" } },
        error.TooDeep => bad("body_too_deep", "json nesting is limited to eight levels"),
        error.UnknownField => bad("unknown_field", "the body contains a field the schema does not define"),
        error.DuplicateField => bad("duplicate_field", "the body repeats a field"),
        error.MissingField => bad("missing_field", "a required field is absent"),
        error.InvalidJson => bad("invalid_json", "the body is not valid json for this schema"),
    };
}

pub fn parseRequestId(text: []const u8) ?u64 {
    if (text.len == 0 or text.len > 16) return null;
    return std.fmt.parseInt(u64, text, 16) catch null;
}

fn parseBase(text: []const u8) ?Base {
    if (std.mem.eql(u8, text, "art")) return .art;
    if (std.mem.eql(u8, text, "clock")) return .clock;
    if (std.mem.eql(u8, text, "ip")) return .ip;
    return null;
}

pub fn generatorName(g: scene.Generator) []const u8 {
    return @tagName(g);
}

fn parseGenerator(text: []const u8) ?scene.Generator {
    inline for (@typeInfo(scene.Generator).@"enum".fields) |f| if (std.mem.eql(u8, text, f.name)) return @enumFromInt(f.value);
    return null;
}

pub fn parseColour(text: []const u8) ?[3]u8 {
    const s = if (text.len == 7 and text[0] == '#') text[1..] else text;
    if (s.len != 6) return null;
    var out: [3]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return null;
    return out;
}

fn isJson(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    const semi = std.mem.indexOfScalar(u8, ct, ';') orelse ct.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, ct[0..semi], " "), "application/json");
}

fn isOctets(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, ct, " "), "application/octet-stream");
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

const Endpoint = struct { method: http.Method, path: []const u8, authority: Authority };

/// authority per route: control tokens also permit control routes with an admin token.
const endpoints = [_]Endpoint{
    .{ .method = .GET, .path = "/api/v1/status", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/scenes", .authority = .control },
    .{ .method = .PUT, .path = "/api/v1/scene", .authority = .control },
    .{ .method = .POST, .path = "/api/v1/action", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/config", .authority = .control },
    .{ .method = .PATCH, .path = "/api/v1/config", .authority = .admin },
    .{ .method = .POST, .path = "/api/v1/config/save", .authority = .admin },
    .{ .method = .POST, .path = "/api/v1/notify", .authority = .control },
    .{ .method = .POST, .path = "/api/v1/frame", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/mqtt", .authority = .admin },
    .{ .method = .PUT, .path = "/api/v1/mqtt", .authority = .admin },
    .{ .method = .GET, .path = "/api/v1/mqtt/status", .authority = .control },
    .{ .method = .POST, .path = "/api/v1/streams", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/screen", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/logs", .authority = .control },
    .{ .method = .POST, .path = "/api/v1/input", .authority = .control },
};

fn sufficient(have: Authority, need: Authority) bool {
    return switch (need) {
        .none => true,
        .control => have == .control or have == .admin,
        .admin => have == .admin,
    };
}

/// classify a complete request. `body` is exactly `content-length` bytes.
pub fn route(req: http.Request, body: []const u8, creds: *const Credentials, origins: *const OriginPolicy, arena: *Arena) Route {
    // origin first: reject disallowed origins before any work
    if (!origins.allows(req.origin)) return .{ .reject = .{ .status = 403, .code = "origin_denied", .message = "this origin is not allowed" } };
    // path and method
    var path_known = false;
    var matched: ?Endpoint = null;
    const streams_prefix = "/api/v1/streams/";
    if (std.mem.startsWith(u8, req.path, streams_prefix)) {
        path_known = true;
        const rest = req.path[streams_prefix.len..];
        if (req.method == .DELETE and std.mem.indexOfScalar(u8, rest, '/') == null) matched = .{ .method = .DELETE, .path = "/api/v1/streams/{id}", .authority = .control };
        if (req.method == .PUT and std.mem.endsWith(u8, rest, "/palette")) matched = .{ .method = .PUT, .path = "/api/v1/streams/{id}/palette", .authority = .control };
    } else {
        for (endpoints) |e| {
            if (std.mem.eql(u8, e.path, req.path)) {
                path_known = true;
                if (e.method == req.method) matched = e;
            }
        }
    }
    const ep = matched orelse return .{ .reject = if (path_known) .{ .status = 405, .code = "method_not_allowed", .message = "this route does not accept that method" } else .{ .status = 404, .code = "not_found", .message = "no such route" } };
    // authentication applies to reads as well as writes
    const authority = authenticate(creds, req.authorization);
    if (authority == .none) return .{ .reject = .{ .status = 401, .code = "unauthorized", .message = "a valid bearer token is required" } };
    if (!sufficient(authority, ep.authority)) return .{ .reject = .{ .status = 403, .code = "forbidden", .message = "this route requires the admin token" } };

    if (std.mem.eql(u8, ep.path, "/api/v1/status")) return .{ .op = .status };
    if (std.mem.eql(u8, ep.path, "/api/v1/scenes")) return .{ .op = .scenes };
    if (std.mem.eql(u8, ep.path, "/api/v1/config") and req.method == .GET) return .{ .op = .config_get };
    if (std.mem.eql(u8, ep.path, "/api/v1/mqtt") and req.method == .GET) return .{ .op = .mqtt_get };
    if (std.mem.eql(u8, ep.path, "/api/v1/mqtt/status")) return .{ .op = .mqtt_status };
    if (std.mem.eql(u8, ep.path, "/api/v1/screen")) {
        const format = queryValue(req.query, "format") orelse "json";
        if (std.mem.eql(u8, format, "raw")) return .{ .op = .{ .screen = .{ .raw = true } } };
        if (std.mem.eql(u8, format, "json")) return .{ .op = .{ .screen = .{ .raw = false } } };
        return bad("invalid_format", "format must be json or raw");
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/logs")) {
        const after_text = queryValue(req.query, "after") orelse "0";
        const after = std.fmt.parseInt(u32, after_text, 10) catch return bad("invalid_after", "after must be a sequence number");
        return .{ .op = .{ .logs = .{ .after = after } } };
    }
    if (std.mem.startsWith(u8, ep.path, "/api/v1/streams")) return .{ .op = if (req.method == .DELETE) .streams_delete else if (req.method == .PUT) .streams_palette else .streams_create };

    if (std.mem.eql(u8, ep.path, "/api/v1/frame")) {
        if (!isOctets(req.content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "frames are application/octet-stream" } };
        return parseFrame(req.query, body);
    }
    // everything below is json
    if (!isJson(req.content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "this route takes application/json" } };
    if (std.mem.eql(u8, ep.path, "/api/v1/scene")) return parseBody(.scene, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/action")) return parseBody(.action, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/notify")) return parseBody(.notify, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/config")) return parseBody(.config_patch, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/config/save")) return parseBody(.config_save, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/mqtt")) return parseBody(.mqtt_put, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/input")) return parseBody(.input, body, arena);
    return .{ .reject = .{ .status = 404, .code = "not_found", .message = "no such route" } };
}


pub const BodyKind = enum { scene, action, notify, config_patch, config_save, mqtt_put, input };

pub fn enumByName(comptime E: type, text: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (std.mem.eql(u8, text, f.name)) return @enumFromInt(f.value);
    return null;
}

/// a raw frame: exactly 2,496 rgb bytes, with duration, request id and epoch in the query.
pub fn parseFrame(query: []const u8, body: []const u8) Route {
    if (body.len != geometry.rgb_bytes) return bad("invalid_frame", "a frame is exactly 2496 rgb888 bytes");
    const duration_text = queryValue(query, "duration_s") orelse return bad("missing_duration", "duration_s is required in the query");
    const duration = std.fmt.parseInt(u16, duration_text, 10) catch return bad("invalid_duration", "duration_s must be 1..300");
    if (duration < 1 or duration > 300) return bad("invalid_duration", "duration_s must be 1..300");
    const rid = parseRequestId(queryValue(query, "request_id") orelse "") orelse return bad("missing_request_id", "request_id (hex) is required in the query");
    const epoch_text = queryValue(query, "epoch") orelse return bad("missing_epoch", "epoch is required in the query");
    const epoch = std.fmt.parseInt(u32, epoch_text, 10) catch return bad("invalid_epoch", "epoch must be a number");
    var ms: ?u32 = null;
    if (queryValue(query, "transition_ms")) |t| ms = std.fmt.parseInt(u32, t, 10) catch return bad("invalid_transition_ms", "transition_ms must be 0..5000");
    const spec = switch (parseTransition(queryValue(query, "transition"), queryValue(query, "direction"), ms, queryValue(query, "exit"), .cut)) {
        .reject => |j| return .{ .reject = j },
        .op => |t| t,
    };
    return .{ .op = .{ .frame = .{ .rgb = body[0..geometry.rgb_bytes], .duration_s = duration, .transition = spec, .request_id = rid, .epoch = epoch } } };
}

/// a json body for one of the schemas; shared by http routes and mqtt command topics.
pub fn parseBody(kind: BodyKind, body: []const u8, arena: *Arena) Route {
    switch (kind) {
        .scene => {
            const b = json.parse(SceneBody, body, arena) catch |e| return jsonError(e);
            const base = parseBase(b.base) orelse return bad("invalid_base", "base must be art, clock or ip");
            const generator: ?scene.Generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null;
            const rid = parseRequestId(b.request_id) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits");
            var style: ?clock.StylePatch = null;
            if (b.clock) |cb| {
                switch (parseClockStyle(cb.font, cb.colour_mode, cb.colour, cb.colour2, cb.gradient, cb.spread)) {
                    .reject => |j| return .{ .reject = j },
                    .op => |op| style = op,
                }
            }
            const spec = switch (parseTransition(b.transition, b.direction, b.transition_ms, b.exit, .fade)) {
                .reject => |j| return .{ .reject = j },
                .op => |t| t,
            };
            return .{ .op = .{ .set_scene = .{ .base = base, .generator = generator, .seed = b.seed, .style = style, .transition = spec, .request_id = rid, .epoch = b.epoch } } };
        },
        .action => {
            const b = json.parse(ActionBody, body, arena) catch |e| return jsonError(e);
            const rid = parseRequestId(b.request_id) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits");
            var kind_found: ?ActionKind = null;
            inline for (@typeInfo(ActionKind).@"enum".fields) |f| if (std.mem.eql(u8, b.action, f.name)) {
                kind_found = @enumFromInt(f.value);
            };
            const k = kind_found orelse return bad("invalid_action", "unknown action");
            if (k == .brightness) {
                const v = b.brightness orelse return bad("missing_brightness", "brightness is required for that action");
                if (v < 1 or v > 100) return bad("invalid_brightness", "brightness must be 1..100");
            }
            if (k == .power and b.power == null) return bad("missing_power", "power (true or false) is required for that action");
            return .{ .op = .{ .action = .{ .kind = k, .brightness = b.brightness, .seed = b.seed, .power = b.power, .request_id = rid, .epoch = b.epoch } } };
        },
        .input => {
            const b = json.parse(InputBody, body, arena) catch |e| return jsonError(e);
            const control = enumByName(actions.Control, b.control) orelse return bad("invalid_control", "control must be left, middle, right, knob or rotary");
            const event = enumByName(actions.EdgeEvent, b.event) orelse return bad("invalid_event", "event must be press, release, click, long, cw or ccw");
            const rotary = control == .rotary;
            const turning = event == .cw or event == .ccw;
            if (rotary != turning) return bad("invalid_event", "cw and ccw belong to the rotary; buttons take press, release, click or long");
            if (event == .long and control != .knob) return bad("invalid_event", "only the knob has a long press");
            if (b.steps < 1 or b.steps > 16) return bad("invalid_steps", "steps must be 1..16");
            if (b.steps != 1 and !turning) return bad("invalid_steps", "steps applies to cw and ccw only");
            const rid = parseRequestId(b.request_id) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits");
            return .{ .op = .{ .input = .{ .control = control, .event = event, .steps = b.steps, .request_id = rid, .epoch = b.epoch } } };
        },
        .notify => {
            const b = json.parse(NotifyBody, body, arena) catch |e| return jsonError(e);
            if (b.text.len == 0 or b.text.len > 128) return bad("invalid_text", "text must be 1..128 printable ascii characters");
            for (b.text) |c| if (c < 0x20 or c > 0x7e) return bad("invalid_text", "text must be 1..128 printable ascii characters");
            if (b.duration_s < 1 or b.duration_s > 300) return bad("invalid_duration", "duration_s must be 1..300");
            const colour = if (b.colour) |c| (parseColour(c) orelse return bad("invalid_colour", "colour must be rrggbb hex")) else [3]u8{ 255, 255, 255 };
            const rid = parseRequestId(b.request_id) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits");
            const spec = switch (parseTransition(b.transition, b.direction, b.transition_ms, b.exit, .fade)) {
                .reject => |j| return .{ .reject = j },
                .op => |t| t,
            };
            return .{ .op = .{ .notify = .{ .text = b.text, .colour = colour, .duration_s = b.duration_s, .transition = spec, .request_id = rid, .epoch = b.epoch } } };
        },
        .config_patch => {
            const b = json.parse(ConfigBody, body, arena) catch |e| return jsonError(e);
            if (b.brightness) |v| if (v < 1 or v > 100) return bad("invalid_brightness", "brightness must be 1..100");
            if (b.timezone) |t| if (t.len == 0 or t.len > 64) return bad("invalid_timezone", "timezone must be 1..64 characters");
            if (b.ntp_interval_s) |v| if (v != 300 and v != 600) return bad("invalid_ntp_interval", "ntp_interval_s must be 300 or 600");
            if (b.frame_timeout_ms) |v| if (v < 100 or v > 2000) return bad("invalid_frame_timeout", "frame_timeout_ms must be 100..2000");
            if (b.metrics_interval_s) |v| if (v != 0 and (v < 10 or v > 3600)) return bad("invalid_metrics_interval", "metrics_interval_s must be 0 (off) or 10..3600");
            if (b.discovery_prefix) |p| if (p.len == 0 or p.len > 64) return bad("invalid_discovery_prefix", "discovery_prefix must be 1..64 characters");
            const ntp: ?[4]u8 = if (b.ntp_server) |s| (parseIpv4(s) orelse return bad("invalid_ntp_server", "ntp_server must be a dotted ipv4 address")) else null;
            const style = switch (parseClockStyle(b.clock_font, b.clock_colour_mode, b.clock_colour, b.clock_colour2, b.clock_gradient, b.clock_spread)) {
                .reject => |j| return .{ .reject = j },
                .op => |op| op,
            };
            return .{ .op = .{ .config_patch = .{
                .clock_font = style.font,
                .clock_colour_mode = style.mode,
                .clock_colour = style.colour,
                .clock_colour2 = style.colour2,
                .clock_gradient = style.gradient,
                .clock_spread = style.spread,
                .brightness = b.brightness,
                .base = if (b.base) |t| (parseBase(t) orelse return bad("invalid_base", "base must be art, clock or ip")) else null,
                .generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null,
                .timezone = b.timezone,
                .ntp_server = ntp,
                .ntp_interval_s = b.ntp_interval_s,
                .frame_timeout_ms = b.frame_timeout_ms,
                .metrics_interval_s = b.metrics_interval_s,
                .discovery = b.discovery,
                .discovery_prefix = b.discovery_prefix,
                .expected_revision = b.expected_revision,
            } } };
        },
        .config_save => {
            const b = if (body.len == 0) SaveBody{} else json.parse(SaveBody, body, arena) catch |e| return jsonError(e);
            return .{ .op = .{ .config_save = .{ .revision = b.revision } } };
        },
        .mqtt_put => {
            const b = json.parse(MqttBody, body, arena) catch |e| return jsonError(e);
            if (b.host) |h| if (h.len == 0 or h.len > 64 or parseIpv4(h) == null) return bad("invalid_host", "host must be a dotted ipv4 address in this profile");
            if (b.port) |p| if (p == 0) return bad("invalid_port", "port must be 1..65535");
            inline for (.{ "username", "password", "client_id", "prefix" }) |name| {
                if (@field(b, name)) |v| if (v.len > 64) return bad("invalid_" ++ name, name ++ " must be at most 64 characters");
            }
            return .{ .op = .{ .mqtt_put = .{ .enabled = b.enabled, .host = b.host, .port = b.port, .username = b.username, .password = b.password, .client_id = b.client_id, .prefix = b.prefix, .tls = b.tls } } };
        },
    }
}

/// the five clock style strings, shared by `/scene` and the settings patch.
const StyleRoute = union(enum) { op: clock.StylePatch, reject: Reject };
fn parseClockStyle(font_text: ?[]const u8, mode_text: ?[]const u8, colour_text: ?[]const u8, colour2_text: ?[]const u8, gradient_text: ?[]const u8, spread: ?u8) StyleRoute {
    var p = clock.StylePatch{ .spread = spread };
    if (font_text) |s| p.font = enumByName(clock.Font, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_font", .message = "font must be classic, mini, segment, big or block" } };
    if (mode_text) |s| p.mode = enumByName(clock.ColourMode, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour_mode", .message = "colour_mode must be solid or gradient" } };
    if (colour_text) |s| p.colour = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour", .message = "colour must be rrggbb hex" } };
    if (colour2_text) |s| p.colour2 = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour2", .message = "colour2 must be rrggbb hex" } };
    if (gradient_text) |s| p.gradient = enumByName(clock.Gradient, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_gradient", .message = "gradient must be horizontal, vertical or diagonal" } };
    return .{ .op = p };
}

/// the four transition fields shared by `/scene`, `/notify` and `/frame`: none given means the
/// renderer's default; an effect without a direction takes the effect's natural one; a
/// missing duration is 500 ms; a missing exit backs out the way it came.
const TransitionRoute = union(enum) { op: ?transition.Spec, reject: Reject };
fn parseTransition(effect_text: ?[]const u8, direction_text: ?[]const u8, ms: ?u32, exit_text: ?[]const u8, natural: transition.Effect) TransitionRoute {
    if (effect_text == null and direction_text == null and ms == null and exit_text == null) return .{ .op = null };
    const exit = if (exit_text) |t| (enumByName(transition.Exit, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_exit", .message = "exit must be reverse, same or none" } }) else .reverse;
    const effect = if (effect_text) |t| (enumByName(transition.Effect, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_transition", .message = effect_names_message } }) else natural;
    const direction = if (direction_text) |t| (enumByName(transition.Direction, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_direction", .message = "direction must be left, right, up or down" } }) else effect.naturalDirection();
    if (ms) |v| if (v > transition.max_duration_ms) return .{ .reject = .{ .status = 400, .code = "invalid_transition_ms", .message = "transition_ms must be 0..5000" } };
    return .{ .op = .{ .effect = effect, .direction = direction, .duration_ns = if (ms) |v| @as(u64, v) * 1_000_000 else transition.default_duration_ns, .exit = exit } };
}

const effect_names_message = "transition must be one of " ++ namesList(transition.Effect);

/// an enum's tag names as a json array, built at comptime so the catalogue cannot drift
fn namesJson(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (std.meta.fields(E), 0..) |f, i| out = out ++ (if (i == 0) "\"" else ",\"") ++ f.name ++ "\"";
        return out ++ "]";
    }
}

fn namesList(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (std.meta.fields(E), 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f.name;
        return out;
    }
}

pub fn parseIpv4(text: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, text, '.');
    for (&out) |*o| {
        const part = it.next() orelse return null;
        if (part.len == 0 or part.len > 3) return null;
        o.* = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    if (it.next() != null) return null;
    return out;
}

/// the `scenes` document is static.
pub const scenes_body = "{\"bases\":[\"art\",\"clock\",\"ip\"],\"generators\":[{\"index\":0,\"name\":\"popsquares\",\"parameters\":{\"seed\":\"u32\"}},{\"index\":1,\"name\":\"plasma\",\"parameters\":{\"seed\":\"u32\"}}],\"clock\":{\"fonts\":[\"classic\",\"mini\",\"segment\",\"big\",\"block\"],\"colour_modes\":[\"solid\",\"gradient\"],\"gradients\":[\"horizontal\",\"vertical\",\"diagonal\"],\"spread\":[0,255],\"max_spread\":255},\"notify\":{\"text_max\":128,\"duration_s\":[1,300]},\"frame\":{\"bytes\":2496,\"duration_s\":[1,300]},\"transitions\":{\"effects\":" ++ namesJson(transition.Effect) ++ ",\"directions\":" ++ namesJson(transition.Direction) ++ ",\"exits\":" ++ namesJson(transition.Exit) ++ ",\"duration_ms\":[0,5000]}}";

// tests

fn testCreds() Credentials {
    var c: Credentials = undefined;
    @memset(&c.control, 0x11);
    @memset(&c.admin, 0x22);
    return c;
}

const control_header = "Bearer " ++ "11" ** 32;
const admin_header = "Bearer " ++ "22" ** 32;

fn testReq(method: http.Method, path: []const u8, query: []const u8, auth: ?[]const u8, ct: ?[]const u8, origin: ?[]const u8) http.Request {
    return .{ .method = method, .path = path, .query = query, .authorization = auth, .content_type = ct, .origin = origin, .head_len = 0 };
}

fn expectReject(r: Route, status: u16, code: []const u8) !void {
    switch (r) {
        .reject => |j| {
            try std.testing.expectEqual(status, j.status);
            try std.testing.expectEqualStrings(code, j.code);
        },
        .op => return error.TestUnexpectedResult,
    }
}

test "authentication is constant-time bearer matching of either token" {
    const c = testCreds();
    try std.testing.expectEqual(Authority.control, authenticate(&c, control_header));
    try std.testing.expectEqual(Authority.admin, authenticate(&c, admin_header));
    try std.testing.expectEqual(Authority.none, authenticate(&c, null));
    try std.testing.expectEqual(Authority.none, authenticate(&c, "Bearer " ++ "11" ** 31 ++ "12"));
    try std.testing.expectEqual(Authority.none, authenticate(&c, "Basic " ++ "11" ** 32));
    try std.testing.expectEqual(Authority.none, authenticate(&c, "Bearer zz" ++ "11" ** 31));
}

test "status codes: origin, route, method, credentials, authority" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    try expectReject(route(testReq(.GET, "/api/v1/status", "", control_header, null, "http://evil"), "", &c, &origins, &arena), 403, "origin_denied");
    origins.allowed[0] = "http://panel";
    origins.count = 1;
    try std.testing.expect(route(testReq(.GET, "/api/v1/status", "", control_header, null, "http://panel"), "", &c, &origins, &arena) == .op);
    try expectReject(route(testReq(.GET, "/api/v1/nope", "", control_header, null, null), "", &c, &origins, &arena), 404, "not_found");
    try expectReject(route(testReq(.DELETE, "/api/v1/status", "", control_header, null, null), "", &c, &origins, &arena), 405, "method_not_allowed");
    try expectReject(route(testReq(.GET, "/api/v1/status", "", null, null, null), "", &c, &origins, &arena), 401, "unauthorized");
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", control_header, "application/json", null), "{}", &c, &origins, &arena), 403, "forbidden");
    try std.testing.expect(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{}", &c, &origins, &arena) == .op);
    try std.testing.expect(route(testReq(.GET, "/api/v1/status", "", admin_header, null, null), "", &c, &origins, &arena).op == .status);
}

test "transition fields become a spec with the effect's natural direction and 500 ms" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const s = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"transition\":\"swipe_in\",\"request_id\":\"7\"}", &c, &origins, &arena);
    try std.testing.expectEqual(transition.Spec{ .effect = .swipe_in, .direction = .left, .duration_ns = 500_000_000 }, s.op.set_scene.transition.?);
    const n = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"rain\",\"transition_ms\":1200}", &c, &origins, &arena);
    try std.testing.expectEqual(transition.Spec{ .effect = .rain, .direction = .down, .duration_ns = 1_200_000_000 }, n.op.notify.transition.?);
    const d = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"direction\":\"up\"}", &c, &origins, &arena);
    try std.testing.expectEqual(transition.Spec{ .effect = .fade, .direction = .up, .duration_ns = 500_000_000 }, d.op.notify.transition.?);
    const none = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1}", &c, &origins, &arena);
    try std.testing.expect(none.op.notify.transition == null);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"warp\"}", &c, &origins, &arena), 400, "invalid_transition");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"direction\":\"sideways\",\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_direction");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"transition_ms\":5001,\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_transition_ms");
    const frame = [_]u8{7} ** geometry.rgb_bytes;
    const f = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition=expand&transition_ms=0", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena);
    try std.testing.expectEqual(transition.Spec{ .effect = .expand, .direction = .left, .duration_ns = 0 }, f.op.frame.transition.?);
    const plain = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena);
    try std.testing.expect(plain.op.frame.transition == null);
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition_ms=x", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena), 400, "invalid_transition_ms");
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"transitions\":{\"effects\":[\"fade\",\"cut\",\"slide\",\"swipe_out\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, scenes_body, "\"directions\":[\"left\",\"right\",\"up\",\"down\"],\"exits\":[\"reverse\",\"same\",\"none\"],\"duration_ms\":[0,5000]}}"));
    const e = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"swipe_in\",\"exit\":\"same\"}", &c, &origins, &arena);
    try std.testing.expectEqual(transition.Exit.same, e.op.notify.transition.?.exit);
    try std.testing.expectEqual(transition.Exit.reverse, n.op.notify.transition.?.exit);
    const only_exit = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"exit\":\"none\"}", &c, &origins, &arena);
    try std.testing.expectEqual(transition.Spec{ .effect = .fade, .direction = .left, .duration_ns = 500_000_000, .exit = .none }, only_exit.op.notify.transition.?);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"exit\":\"back\"}", &c, &origins, &arena), 400, "invalid_exit");
    const fe = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition=slide&exit=none", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena);
    try std.testing.expectEqual(transition.Exit.none, fe.op.frame.transition.?.exit);
}

test "notify and scene bodies become typed operations with validation" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const r = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json; charset=utf-8", null), "{\"text\":\"hello\",\"colour\":\"#ff8000\",\"duration_s\":30,\"request_id\":\"a1b2\",\"epoch\":3}", &c, &origins, &arena);
    try std.testing.expectEqualStrings("hello", r.op.notify.text);
    try std.testing.expectEqual([3]u8{ 0xff, 0x80, 0x00 }, r.op.notify.colour);
    try std.testing.expectEqual(@as(u64, 0xa1b2), r.op.notify.request_id);
    try std.testing.expectEqual(@as(u32, 3), r.op.notify.epoch);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "text/plain", null), "{}", &c, &origins, &arena), 415, "unsupported_media_type");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"extra\":1}", &c, &origins, &arena), 400, "unknown_field");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"duration_s\":301}", &c, &origins, &arena), 400, "invalid_duration");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"zz\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_request_id");
    const s = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"generator\":\"plasma\",\"seed\":9,\"request_id\":\"7\"}", &c, &origins, &arena);
    try std.testing.expectEqual(Base.art, s.op.set_scene.base);
    try std.testing.expectEqual(scene.Generator.plasma, s.op.set_scene.generator.?);
    try std.testing.expectEqual(@as(?u32, null), s.op.set_scene.epoch);
    try std.testing.expect(s.op.set_scene.style == null);
    const cs = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"big\",\"colour_mode\":\"gradient\",\"colour\":\"ff8000\",\"colour2\":\"#ffc000\"},\"request_id\":\"7\"}", &c, &origins, &arena);
    try std.testing.expectEqual(clock.Font.big, cs.op.set_scene.style.?.font.?);
    try std.testing.expectEqual(clock.ColourMode.gradient, cs.op.set_scene.style.?.mode.?);
    try std.testing.expectEqual([3]u8{ 0xff, 0xc0, 0x00 }, cs.op.set_scene.style.?.colour2.?);
    try std.testing.expect(cs.op.set_scene.style.?.gradient == null);
    try std.testing.expect(cs.op.set_scene.style.?.spread == null);
    const sp = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"block\",\"spread\":120},\"request_id\":\"7\"}", &c, &origins, &arena);
    try std.testing.expectEqual(clock.Font.block, sp.op.set_scene.style.?.font.?);
    try std.testing.expectEqual(@as(?u8, 120), sp.op.set_scene.style.?.spread);
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"spread\":300},\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_json");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"comic\"},\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_font");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"gradient\":\"radial\"},\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_gradient");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"colour\":\"red\"},\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_colour");
    const a = route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"brightness\",\"brightness\":40,\"request_id\":\"8\",\"epoch\":2}", &c, &origins, &arena);
    try std.testing.expectEqual(ActionKind.brightness, a.op.action.kind);
    const pw = route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"power\",\"power\":false,\"request_id\":\"9\",\"epoch\":2}", &c, &origins, &arena);
    try std.testing.expectEqual(ActionKind.power, pw.op.action.kind);
    try std.testing.expectEqual(@as(?bool, false), pw.op.action.power);
    try expectReject(route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"power\",\"request_id\":\"9\",\"epoch\":2}", &c, &origins, &arena), 400, "missing_power");
    try expectReject(route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"brightness\",\"brightness\":0,\"request_id\":\"8\",\"epoch\":2}", &c, &origins, &arena), 400, "invalid_brightness");
}

test "frames are raw octets with query parameters; oversized json is 413" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const frame = [_]u8{7} ** geometry.rgb_bytes;
    const r = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena);
    try std.testing.expectEqual(@as(u16, 5), r.op.frame.duration_s);
    try std.testing.expectEqual(@as(u8, 7), r.op.frame.rgb[100]);
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), frame[0..100], &c, &origins, &arena), 400, "invalid_frame");
    try expectReject(route(testReq(.POST, "/api/v1/frame", "request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &origins, &arena), 400, "missing_duration");
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5", control_header, "application/json", null), &frame, &c, &origins, &arena), 415, "unsupported_media_type");
    const big = [_]u8{' '} ** (json.max_body + 1);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), &big, &c, &origins, &arena), 413, "body_too_large");
}

test "config, mqtt and streams routes" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const p = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"brightness\":30,\"timezone\":\"AEST-10AEDT,M10.1.0,M4.1.0/3\",\"ntp_server\":\"10.0.0.5\",\"ntp_interval_s\":300,\"expected_revision\":4}", &c, &origins, &arena);
    try std.testing.expectEqual(@as(?u8, 30), p.op.config_patch.brightness);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, p.op.config_patch.ntp_server.?);
    try std.testing.expectEqual(@as(?u32, 4), p.op.config_patch.expected_revision);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ntp_server\":\"time.example\"}", &c, &origins, &arena), 400, "invalid_ntp_server");
    const cp = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_font\":\"segment\",\"clock_colour_mode\":\"gradient\",\"clock_colour\":\"00ff80\",\"clock_gradient\":\"vertical\"}", &c, &origins, &arena);
    try std.testing.expectEqual(clock.Font.segment, cp.op.config_patch.clock_font.?);
    try std.testing.expectEqual(clock.Gradient.vertical, cp.op.config_patch.clock_gradient.?);
    try std.testing.expect(cp.op.config_patch.clock_colour2 == null);
    const sp2 = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_spread\":64,\"timezone\":\"Europe/Amsterdam\"}", &c, &origins, &arena);
    try std.testing.expectEqual(@as(?u8, 64), sp2.op.config_patch.clock_spread);
    try std.testing.expectEqualStrings("Europe/Amsterdam", sp2.op.config_patch.timezone.?);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_colour_mode\":\"rainbow\"}", &c, &origins, &arena), 400, "invalid_colour_mode");
    try std.testing.expect(route(testReq(.POST, "/api/v1/config/save", "", admin_header, "application/json", null), "", &c, &origins, &arena).op == .config_save);
    const m = route(testReq(.PUT, "/api/v1/mqtt", "", admin_header, "application/json", null), "{\"host\":\"10.0.0.2\",\"port\":1883,\"username\":\"tc002\",\"password\":\"Secret1\",\"enabled\":true}", &c, &origins, &arena);
    try std.testing.expectEqualStrings("Secret1", m.op.mqtt_put.password.?);
    try expectReject(route(testReq(.GET, "/api/v1/mqtt", "", control_header, null, null), "", &c, &origins, &arena), 403, "forbidden");
    try std.testing.expect(route(testReq(.GET, "/api/v1/mqtt/status", "", control_header, null, null), "", &c, &origins, &arena).op == .mqtt_status);
    try std.testing.expect(route(testReq(.POST, "/api/v1/streams", "", control_header, "application/json", null), "{}", &c, &origins, &arena).op == .streams_create);
    try std.testing.expect(route(testReq(.DELETE, "/api/v1/streams/abcd", "", control_header, null, null), "", &c, &origins, &arena).op == .streams_delete);
    try std.testing.expect(route(testReq(.PUT, "/api/v1/streams/abcd/palette", "", control_header, "application/octet-stream", null), "", &c, &origins, &arena).op == .streams_palette);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 111 }, parseIpv4("10.0.0.111").?);
    try std.testing.expect(parseIpv4("10.0.0") == null);
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
}

test "screen, logs and input routes" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    try std.testing.expect(!route(testReq(.GET, "/api/v1/screen", "", control_header, null, null), "", &c, &origins, &arena).op.screen.raw);
    try std.testing.expect(route(testReq(.GET, "/api/v1/screen", "format=raw", control_header, null, null), "", &c, &origins, &arena).op.screen.raw);
    try expectReject(route(testReq(.GET, "/api/v1/screen", "format=png", control_header, null, null), "", &c, &origins, &arena), 400, "invalid_format");
    try std.testing.expectEqual(@as(u32, 0), route(testReq(.GET, "/api/v1/logs", "", control_header, null, null), "", &c, &origins, &arena).op.logs.after);
    try std.testing.expectEqual(@as(u32, 41), route(testReq(.GET, "/api/v1/logs", "after=41", control_header, null, null), "", &c, &origins, &arena).op.logs.after);
    try expectReject(route(testReq(.GET, "/api/v1/logs", "after=x", control_header, null, null), "", &c, &origins, &arena), 400, "invalid_after");
    try expectReject(route(testReq(.GET, "/api/v1/logs", "", null, null, null), "", &c, &origins, &arena), 401, "unauthorized");
    const i = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"ccw\",\"steps\":3,\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena);
    try std.testing.expectEqual(actions.Control.rotary, i.op.input.control);
    try std.testing.expectEqual(actions.EdgeEvent.ccw, i.op.input.event);
    try std.testing.expectEqual(@as(u8, 3), i.op.input.steps);
    const k = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"knob\",\"event\":\"long\",\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena);
    try std.testing.expectEqual(actions.EdgeEvent.long, k.op.input.event);
    try std.testing.expectEqual(@as(u8, 1), k.op.input.steps);
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"left\",\"event\":\"cw\",\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_event");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"left\",\"event\":\"long\",\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_event");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"click\",\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_event");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"middle\",\"event\":\"click\",\"steps\":2,\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_steps");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"cw\",\"steps\":17,\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_steps");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"pedal\",\"event\":\"click\",\"request_id\":\"c\",\"epoch\":1}", &c, &origins, &arena), 400, "invalid_control");
}
