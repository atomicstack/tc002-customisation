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
const ip = @import("../scene/ip.zig");
const canvas = @import("../scene/canvas.zig");
const icons = @import("../scene/icons.zig");
const param = @import("../scene/param.zig");
const cube = @import("../scene/cube.zig");
const popsquares = @import("../scene/popsquares.zig");
const plasma = @import("../scene/plasma.zig");
const ntfy_url = @import("../ntfy/url.zig");

/// a generator parameter once its scene and name have been looked up in the declared tables
pub const ResolvedParam = struct { owner: u8, slot: u8, value: u32 };
/// the most a single settings patch may carry
pub const max_params_per_patch = 8;

/// where a request's resolved parameters live between parsing and the ipc encoding. one request
/// is handled at a time, so a single buffer is enough.
var arena_params: [max_params_per_patch]ResolvedParam = undefined;

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
    ntfy_get,
    ntfy_put: NtfyPut,
    streams_create,
    streams_palette,
    streams_delete,
    canvas_get,
    /// the whole document, by value: it is about two kilobytes and a request handles one
    canvas_put: canvas.Document,
    canvas_patch: canvas.Patch,
    canvas_clear,
    icons,
    sprite_list,
    sprite_put: canvas.Sprite,
    sprite_delete: canvas.Id,
};

/// a location pinned by hand, in hundredths of a degree
pub const Location = struct { lat_c: i16, lon_c: i16 };

/// two hours of lead is already longer than any twilight the night schedule adds it to
pub const max_night_lead_min = 120;

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
    clock_digit: ?clock.DigitStyle = null,
    /// resolved generator parameters: which generator, which slot in its table, and the value
    generator_params: []const ResolvedParam = &.{},
    ip_mode: ?ip.Mode = null,
    night: ?bool = null,
    night_brightness: ?u8 = null,
    night_lead_min: ?u8 = null,
    location: ?Location = null,
    /// true drops a pinned location and goes back to the timezone's own reference point
    location_auto: ?bool = null,
};

/// a pem certificate for a self-hosted ntfy: at most this many bytes (a root ca is 1.3-2 kb)
pub const max_ca = 3500;

pub const NtfyPut = struct {
    enabled: ?bool = null,
    url: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    duration_s: ?u16 = null,
    insecure: ?bool = null,
    /// a pem certificate to trust as well as the public roots; "" removes it
    ca: ?[]const u8 = null,
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
const ClockBody = struct { font: ?[]const u8 = null, colour_mode: ?[]const u8 = null, colour: ?[]const u8 = null, colour2: ?[]const u8 = null, gradient: ?[]const u8 = null, spread: ?u8 = null, digits: ?[]const u8 = null };
/// one generator parameter in a settings patch. the value is always a string and the scene's own
/// table says how to read it: a choice by its name, a colour as rrggbb, a number in decimal, a
/// toggle as on or off. `GET /scenes` publishes the table, so a client needs nothing else.
const GenParamBody = struct { scene: []const u8, name: []const u8, value: []const u8 };
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
    clock_digit: ?[]const u8 = null,
    generator_params: ?[]const GenParamBody = null,
    ip_mode: ?[]const u8 = null,
    night: ?bool = null,
    night_brightness: ?u8 = null,
    night_lead_min: ?u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    location_auto: ?bool = null,
};
/// one element of a pushed document. the strict parser cannot do a tagged union, so every field
/// any element type takes lives here and `allowedField` refuses the ones that do not belong to the
/// type given: `{"type":"rect","text":"hi"}` is a mistake worth hearing about, not a field to drop.
const ElementBody = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    /// read-only: `GET /canvas` publishes how long ago this element's animation clock started, and
    /// a client that reads a document and puts it back sends it straight back. accepted so that
    /// round trip works, and then ignored -- the device owns when an animation started.
    age_ms: ?u32 = null,
    at: ?[2]i16 = null,
    size: ?[2]i16 = null,
    tile: ?u8 = null,
    row: ?u8 = null,
    of: ?u8 = null,
    colour: ?[]const u8 = null,
    text: ?[]const u8 = null,
    font: ?[]const u8 = null,
    @"align": ?[]const u8 = null,
    filled: ?bool = null,
    to: ?[2]i16 = null,
    r: ?u8 = null,
    value: ?u8 = null,
    background: ?[]const u8 = null,
    vertical: ?bool = null,
    data: ?[]const u8 = null,
    data_hex: ?[]const u8 = null,
    style: ?[]const u8 = null,
    min: ?u8 = null,
    max: ?u8 = null,
    threshold: ?u8 = null,
    over: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    sprite: ?[]const u8 = null,
    label: ?[]const u8 = null,
    /// a tile's reading. it is not `value` because a bar's `value` is a number and the strict
    /// parser gives a field one type.
    value_text: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    animate: ?AnimateBody = null,
};
const AnimateBody = struct { kind: []const u8, ms: ?u16 = null, phase: ?u8 = null, amount: ?u8 = null, axis: ?[]const u8 = null };
const CanvasBody = struct { elements: []const ElementBody };
/// a patch names elements by id and carries only what changed. it is a list rather than an object
/// keyed by id because the parser resolves field names at compile time and the ids belong to the
/// client -- the same reason `generator_params` is a list.
const ValueBody = struct {
    id: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    data_hex: ?[]const u8 = null,
    value: ?u8 = null,
    colour: ?[]const u8 = null,
};
const PatchBody = struct { values: []const ValueBody };
const SaveBody = struct { revision: ?u32 = null };
const NtfyBody = struct { enabled: ?bool = null, url: ?[]const u8 = null, topic: ?[]const u8 = null, token: ?[]const u8 = null, username: ?[]const u8 = null, password: ?[]const u8 = null, duration_s: ?u16 = null, insecure: ?bool = null, ca: ?[]const u8 = null };
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
        error.TooLarge => .{ .reject = .{ .status = 413, .code = "body_too_large", .message = "json bodies are limited to 8192 bytes" } },
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

const base_names_message = "base must be clock, art or canvas";

// --- the canvas -------------------------------------------------------------------------------

const CanvasRoute = union(enum) { op: canvas.Document, reject: Reject };
const CanvasPatchRoute = union(enum) { op: canvas.Patch, reject: Reject };

fn canvasBad(code: []const u8, message: []const u8) Reject {
    return .{ .status = 400, .code = code, .message = message };
}

/// which fields each element type has a use for. anything else set on it is a mistake: an
/// integration that thinks it is setting a radius on a rectangle should hear that it is not.
fn allowedField(kind: canvas.Kind, comptime name: []const u8) bool {
    const eq = struct {
        fn f(comptime a: []const u8, comptime b: []const u8) bool {
            return comptime std.mem.eql(u8, a, b);
        }
    }.f;
    if (eq(name, "type") or eq(name, "id") or eq(name, "at") or eq(name, "size") or
        eq(name, "tile") or eq(name, "row") or eq(name, "of") or eq(name, "colour") or eq(name, "animate") or
        eq(name, "age_ms")) return true;
    return switch (kind) {
        .text => eq(name, "text") or eq(name, "font") or eq(name, "align"),
        .rect => eq(name, "filled"),
        .line => eq(name, "to"),
        .circle => eq(name, "r") or eq(name, "filled"),
        .pixel => false,
        .bar => eq(name, "value") or eq(name, "background") or eq(name, "vertical"),
        .sparkline => eq(name, "data") or eq(name, "data_hex") or eq(name, "style") or
            eq(name, "min") or eq(name, "max") or eq(name, "threshold") or eq(name, "over"),
        .icon => eq(name, "icon"),
        .sprite => eq(name, "sprite"),
        .tile => eq(name, "icon") or eq(name, "sprite") or eq(name, "label") or eq(name, "value_text") or eq(name, "accent"),
    };
}

/// samples as an array of numbers, or as hex for a document that would not otherwise fit: 52
/// samples cost 208 characters as json digits and 104 as hex
fn parseSamples(b: *const ElementBody, out: []u8) ?[]const u8 {
    if (b.data) |d| {
        if (d.len > out.len) return null;
        @memcpy(out[0..d.len], d);
        return out[0..d.len];
    }
    const hex = b.data_hex orelse return out[0..0];
    if (hex.len % 2 != 0 or hex.len / 2 > out.len) return null;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        out[i / 2] = (hexDigit(hex[i]) orelse return null) * 16 + (hexDigit(hex[i + 1]) orelse return null);
    }
    return out[0 .. hex.len / 2];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn parseBox(b: *const ElementBody) ?canvas.Box {
    if (b.tile != null and b.row != null) return null;
    if ((b.tile != null or b.row != null) and (b.at != null or b.size != null)) return null;
    if (b.tile) |n| return canvas.Box.tile(n, b.of orelse return null);
    if (b.row) |n| return canvas.Box.row(n, b.of orelse return null);
    if (b.of != null) return null; // `of` without a tile or row says nothing
    var box = canvas.Box{};
    if (b.at) |a| {
        box.x = a[0];
        box.y = a[1];
    }
    if (b.size) |sz| {
        if (sz[0] < 0 or sz[1] < 0) return null;
        box.w = sz[0];
        box.h = sz[1];
    }
    return box;
}

/// a whole document, or the first thing wrong with it
fn parseCanvas(body: []const ElementBody, doc: *canvas.Document) CanvasRoute {
    if (body.len > canvas.max_elements) return .{ .reject = canvasBad("too_many_elements", "a document holds at most 24 elements") };
    for (body) |*b| {
        const kind = enumByName(canvas.Kind, b.type) orelse
            return .{ .reject = canvasBad("invalid_element_type", "type must be text, rect, line, circle, pixel, bar or sparkline") };
        inline for (@typeInfo(ElementBody).@"struct".fields) |f| {
            if (comptime @typeInfo(f.type) == .optional) {
                if (@field(b, f.name) != null and !allowedField(kind, f.name)) {
                    return .{ .reject = canvasBad("invalid_element_field", "that field does not belong to that element type") };
                }
            }
        }
        if (b.id) |id| if (id.len == 0 or id.len > canvas.id_max) {
            return .{ .reject = canvasBad("invalid_element_id", "an id is 1 to 8 characters") };
        };
        const box = parseBox(b) orelse return .{ .reject = canvasBad("invalid_placement", "give at (and size), or tile/row with of; not both") };
        var e = canvas.Element{ .id = if (b.id) |id| canvas.Id.init(id) else .{}, .box = box, .body = .pixel };
        if (b.colour) |c| e.colour = parseColour(c) orelse return .{ .reject = canvasBad("invalid_colour", "colour must be rrggbb hex") };
        if (b.animate) |a| {
            const motion = enumByName(canvas.Motion, a.kind) orelse
                return .{ .reject = canvasBad("invalid_motion", "kind must be hue, bounce, scramble, scroll, blink, pulse, typewriter or sweep") };
            if (motion == .none) return .{ .reject = canvasBad("invalid_motion", "leave animate out rather than asking for none") };
            // an animation that only makes sense on some kinds says so rather than doing nothing
            const suits = switch (motion) {
                .scramble, .typewriter, .scroll => kind == .text,
                .sweep => kind == .sparkline,
                else => true,
            };
            if (!suits) return .{ .reject = canvasBad("invalid_motion", "that motion does not suit that element type") };
            if (a.ms) |ms| if (ms == 0) return .{ .reject = canvasBad("invalid_motion", "ms must be at least 1") };
            if (a.phase) |ph| if (ph > 100) return .{ .reject = canvasBad("invalid_motion", "phase is 0..100") };
            e.anim = .{
                .kind = motion,
                .ms = a.ms orelse switch (motion) {
                    .scroll => 33, // the pace a notification scrolls at
                    .hue => 8000,
                    else => 1000,
                },
                .phase = a.phase orelse 0,
                .amount = a.amount orelse switch (motion) {
                    .bounce => 2,
                    .blink => 50,
                    else => 0,
                },
                .axis_x = if (a.axis) |ax| std.mem.eql(u8, ax, "x") else false,
            };
            if (a.axis) |ax| if (!std.mem.eql(u8, ax, "x") and !std.mem.eql(u8, ax, "y")) {
                return .{ .reject = canvasBad("invalid_motion", "axis must be x or y") };
            };
        }
        switch (kind) {
            .text => {
                const text = b.text orelse return .{ .reject = canvasBad("missing_text", "a text element needs text") };
                const span = doc.addText(text) catch return .{ .reject = canvasBad("document_full", "the document's text does not fit") };
                e.body = .{ .text = .{
                    .span = span,
                    .face = if (b.font) |f| (enumByName(canvas.Font, f) orelse return .{ .reject = canvasBad("invalid_font", "font must be small, mini, block or big") }) else .small,
                    .alignment = if (b.@"align") |a| (enumByName(canvas.Align, a) orelse return .{ .reject = canvasBad("invalid_align", "align must be left, centre or right") }) else .left,
                } };
            },
            .rect => e.body = .{ .rect = .{ .filled = b.filled orelse false } },
            .line => {
                const to = b.to orelse return .{ .reject = canvasBad("missing_to", "a line needs to") };
                e.body = .{ .line = .{ .x2 = to[0], .y2 = to[1] } };
            },
            .circle => e.body = .{ .circle = .{ .r = b.r orelse 1, .filled = b.filled orelse false } },
            .pixel => e.body = .pixel,
            .bar => e.body = .{ .bar = .{
                .value = b.value orelse 0,
                .background = if (b.background) |c| (parseColour(c) orelse return .{ .reject = canvasBad("invalid_colour", "background must be rrggbb hex") }) else .{ 0, 0, 0 },
                .vertical = b.vertical orelse false,
            } },
            .icon => {
                const name = b.icon orelse return .{ .reject = canvasBad("missing_icon", "an icon element needs icon") };
                e.body = .{ .icon = .{ .index = icons.indexOf(name) orelse return .{ .reject = canvasBad("unknown_icon", "no icon by that name; GET /icons lists them") } } };
            },
            .sprite => {
                const id = b.sprite orelse return .{ .reject = canvasBad("missing_sprite", "a sprite element needs sprite") };
                if (id.len == 0 or id.len > canvas.id_max) return .{ .reject = canvasBad("invalid_sprite_id", "a sprite id is 1 to 8 characters") };
                e.body = .{ .sprite = .{ .id = canvas.Id.init(id) } };
            },
            .tile => {
                var t: @FieldType(canvas.Body, "tile") = .{};
                if (b.icon) |name| t.icon = icons.indexOf(name) orelse return .{ .reject = canvasBad("unknown_icon", "no icon by that name; GET /icons lists them") };
                if (b.sprite) |id| {
                    if (id.len == 0 or id.len > canvas.id_max) return .{ .reject = canvasBad("invalid_sprite_id", "a sprite id is 1 to 8 characters") };
                    t.sprite_id = canvas.Id.init(id);
                }
                if (b.icon == null and b.sprite == null) return .{ .reject = canvasBad("missing_icon", "a tile needs an icon or a sprite") };
                if (b.label) |l| t.label = doc.addText(l) catch return .{ .reject = canvasBad("document_full", "the document's text does not fit") };
                const value = b.value_text orelse return .{ .reject = canvasBad("missing_value", "a tile needs value_text") };
                t.value = doc.addText(value) catch return .{ .reject = canvasBad("document_full", "the document's text does not fit") };
                if (b.accent) |cc| t.accent = parseColour(cc) orelse return .{ .reject = canvasBad("invalid_colour", "accent must be rrggbb hex") };
                e.body = .{ .tile = t };
            },
            .sparkline => {
                var samples: [canvas.samples_max]u8 = undefined;
                const got = parseSamples(b, &samples) orelse return .{ .reject = canvasBad("invalid_data", "data is up to 52 samples of 0..255, or data_hex of twice as many hex digits") };
                const span = doc.addData(got) catch return .{ .reject = canvasBad("document_full", "the document's sample data does not fit") };
                e.body = .{ .sparkline = .{
                    .span = span,
                    .style = if (b.style) |st| (enumByName(canvas.Style, st) orelse return .{ .reject = canvasBad("invalid_style", "style must be line, bars or area") }) else .line,
                    .min = b.min orelse 0,
                    .max = b.max orelse 0,
                    .threshold = b.threshold orelse 0,
                    .over = if (b.over) |c| (parseColour(c) orelse return .{ .reject = canvasBad("invalid_colour", "over must be rrggbb hex") }) else .{ 255, 0, 0 },
                } };
            },
        }
        doc.add(e) catch return .{ .reject = canvasBad("too_many_elements", "a document holds at most 24 elements") };
    }
    return .{ .op = doc.* };
}

fn parseCanvasPatch(body: []const ValueBody) CanvasPatchRoute {
    if (body.len > canvas.max_elements) return .{ .reject = canvasBad("too_many_values", "a patch carries at most 24 values") };
    var p = canvas.Patch{};
    for (body) |*v| {
        if (v.id.len == 0 or v.id.len > canvas.id_max) return .{ .reject = canvasBad("invalid_element_id", "an id is 1 to 8 characters") };
        var u = canvas.Update{ .id = canvas.Id.init(v.id) };
        if (v.text) |t| {
            if (t.len > canvas.patch_bytes_max) return .{ .reject = canvasBad("text_too_long", "a patched string is at most 64 characters") };
            u.has |= canvas.Field.text;
            u.len = @intCast(t.len);
            @memcpy(u.bytes[0..t.len], t);
        }
        if (v.data != null or v.data_hex != null) {
            if (u.has & canvas.Field.text != 0) return .{ .reject = canvasBad("invalid_element_field", "an element takes text or data, not both") };
            var samples: [canvas.samples_max]u8 = undefined;
            const eb = ElementBody{ .type = "sparkline", .data = v.data, .data_hex = v.data_hex };
            const got = parseSamples(&eb, &samples) orelse return .{ .reject = canvasBad("invalid_data", "data is up to 52 samples of 0..255, or data_hex of twice as many hex digits") };
            if (got.len > canvas.patch_bytes_max) return .{ .reject = canvasBad("invalid_data", "a patched sparkline carries at most 64 samples") };
            u.has |= canvas.Field.data;
            u.len = @intCast(got.len);
            @memcpy(u.bytes[0..got.len], got);
        }
        if (v.value) |n| {
            u.has |= canvas.Field.value;
            u.value = n;
        }
        if (v.colour) |c| {
            u.has |= canvas.Field.colour;
            u.colour = parseColour(c) orelse return .{ .reject = canvasBad("invalid_colour", "colour must be rrggbb hex") };
        }
        if (u.has == 0) return .{ .reject = canvasBad("empty_value", "a value must change something") };
        p.add(u) catch return .{ .reject = canvasBad("too_many_values", "a patch carries at most 24 values") };
    }
    return .{ .op = p };
}

fn parseBase(text: []const u8) ?Base {
    if (std.mem.eql(u8, text, "clock")) return .clock;
    if (std.mem.eql(u8, text, "art")) return .art;
    if (std.mem.eql(u8, text, "canvas")) return .canvas;
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
    .{ .method = .GET, .path = "/api/v1/icons", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/sprites", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/canvas", .authority = .control },
    .{ .method = .PUT, .path = "/api/v1/canvas", .authority = .admin },
    .{ .method = .PATCH, .path = "/api/v1/canvas", .authority = .control },
    .{ .method = .DELETE, .path = "/api/v1/canvas", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/mqtt", .authority = .admin },
    .{ .method = .PUT, .path = "/api/v1/mqtt", .authority = .admin },
    .{ .method = .GET, .path = "/api/v1/mqtt/status", .authority = .control },
    .{ .method = .GET, .path = "/api/v1/ntfy", .authority = .admin },
    .{ .method = .PUT, .path = "/api/v1/ntfy", .authority = .admin },
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
    const sprites_prefix = "/api/v1/sprites/";
    if (std.mem.startsWith(u8, req.path, sprites_prefix)) {
        path_known = true;
        const rest = req.path[sprites_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) {
            if (req.method == .PUT) matched = .{ .method = .PUT, .path = "/api/v1/sprites/{id}", .authority = .admin };
            if (req.method == .DELETE) matched = .{ .method = .DELETE, .path = "/api/v1/sprites/{id}", .authority = .control };
        }
    }
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
    if (std.mem.eql(u8, ep.path, "/api/v1/icons")) return .{ .op = .icons };
    if (std.mem.eql(u8, ep.path, "/api/v1/sprites")) return .{ .op = .sprite_list };
    if (std.mem.eql(u8, ep.path, "/api/v1/sprites/{id}")) {
        const id = req.path["/api/v1/sprites/".len..];
        if (id.len > canvas.id_max) return bad("invalid_sprite_id", "a sprite id is 1 to 8 characters");
        for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') {
            return bad("invalid_sprite_id", "a sprite id is letters, digits, dash and underscore");
        };
        if (req.method == .DELETE) return .{ .op = .{ .sprite_delete = canvas.Id.init(id) } };
        return parseSprite(id, req.content_type, body);
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/canvas") and req.method == .GET) return .{ .op = .canvas_get };
    if (std.mem.eql(u8, ep.path, "/api/v1/canvas") and req.method == .DELETE) return .{ .op = .canvas_clear };
    if (std.mem.eql(u8, ep.path, "/api/v1/mqtt") and req.method == .GET) return .{ .op = .mqtt_get };
    if (std.mem.eql(u8, ep.path, "/api/v1/ntfy") and req.method == .GET) return .{ .op = .ntfy_get };
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
    if (std.mem.eql(u8, ep.path, "/api/v1/ntfy")) return parseBody(.ntfy_put, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/input")) return parseBody(.input, body, arena);
    if (std.mem.eql(u8, ep.path, "/api/v1/canvas")) return parseBody(if (req.method == .PUT) .canvas_put else .canvas_patch, body, arena);
    return .{ .reject = .{ .status = 404, .code = "not_found", .message = "no such route" } };
}


pub const BodyKind = enum { scene, action, notify, config_patch, config_save, mqtt_put, ntfy_put, input, canvas_put, canvas_patch };

pub fn enumByName(comptime E: type, text: []const u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (std.mem.eql(u8, text, f.name)) return @enumFromInt(f.value);
    return null;
}

/// a sprite: raw rgb888, square-ish, with the side lengths inferred from how many bytes arrived,
/// the way a frame infers nothing because it is only ever one size. 8x8 is 192 bytes and 16x16 is
/// 768; octets rather than base64 because `POST /frame` already proved the path.
pub fn parseSprite(id: []const u8, content_type: ?[]const u8, body: []const u8) Route {
    if (!isOctets(content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "a sprite is application/octet-stream" } };
    var sp = canvas.Sprite{ .id = canvas.Id.init(id) };
    switch (body.len) {
        8 * 8 * 3 => {
            sp.w = 8;
            sp.h = 8;
        },
        16 * 16 * 3 => {
            sp.w = 16;
            sp.h = 16;
        },
        else => return bad("invalid_sprite", "a sprite is 192 bytes (8x8) or 768 bytes (16x16) of rgb888"),
    }
    @memcpy(sp.rgb[0..body.len], body);
    return .{ .op = .{ .sprite_put = sp } };
}

/// the built-in icon names, as a catalogue a console can build a picker from
pub const icons_body = blk: {
    var out: []const u8 = "{\"size\":8,\"names\":[";
    for (icons.set, 0..) |icon, i| {
        out = out ++ (if (i > 0) "," else "") ++ "\"" ++ icon.name ++ "\"";
    }
    break :blk out ++ "]}";
};

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
            const base = parseBase(b.base) orelse return bad("invalid_base", base_names_message);
            const generator: ?scene.Generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null;
            const rid = parseRequestId(b.request_id) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits");
            var style: ?clock.StylePatch = null;
            if (b.clock) |cb| {
                switch (parseClockStyle(cb.font, cb.colour_mode, cb.colour, cb.colour2, cb.gradient, cb.spread, cb.digits)) {
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
            const style = switch (parseClockStyle(b.clock_font, b.clock_colour_mode, b.clock_colour, b.clock_colour2, b.clock_gradient, b.clock_spread, b.clock_digit)) {
                .reject => |j| return .{ .reject = j },
                .op => |op| op,
            };
            const ip_mode: ?ip.Mode = if (b.ip_mode) |t| (enumByName(ip.Mode, t) orelse return bad("invalid_ip_mode", "ip_mode must be lines, mini, scroll or big")) else null;
            if (b.night_brightness) |v| if (v < 1 or v > 100) return bad("invalid_night_brightness", "night_brightness must be 1..100");
            if (b.night_lead_min) |v| if (v > max_night_lead_min) return bad("invalid_night_lead", "night_lead_min must be 0..120");
            const location = switch (parseLocation(b.latitude, b.longitude)) {
                .reject => |j| return .{ .reject = j },
                .op => |v| v,
            };
            const gen_params = if (b.generator_params) |list| switch (parseGeneratorParams(list, arena_params[0..])) {
                .reject => |j| return .{ .reject = j },
                .op => |v| v,
            } else &.{};
            return .{ .op = .{ .config_patch = .{
                .generator_params = gen_params,
                .ip_mode = ip_mode,
                .clock_font = style.font,
                .clock_colour_mode = style.mode,
                .clock_colour = style.colour,
                .clock_colour2 = style.colour2,
                .clock_gradient = style.gradient,
                .clock_spread = style.spread,
                .clock_digit = style.digit,
                .brightness = b.brightness,
                .base = if (b.base) |t| (parseBase(t) orelse return bad("invalid_base", base_names_message)) else null,
                .generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null,
                .timezone = b.timezone,
                .ntp_server = ntp,
                .ntp_interval_s = b.ntp_interval_s,
                .frame_timeout_ms = b.frame_timeout_ms,
                .metrics_interval_s = b.metrics_interval_s,
                .discovery = b.discovery,
                .discovery_prefix = b.discovery_prefix,
                .expected_revision = b.expected_revision,
                .night = b.night,
                .night_brightness = b.night_brightness,
                .night_lead_min = b.night_lead_min,
                .location = location,
                .location_auto = b.location_auto,
            } } };
        },
        .canvas_put => {
            const b = json.parse(CanvasBody, body, arena) catch |e| return jsonError(e);
            var doc = canvas.Document{};
            return switch (parseCanvas(b.elements, &doc)) {
                .reject => |j| .{ .reject = j },
                .op => |d| .{ .op = .{ .canvas_put = d } },
            };
        },
        .canvas_patch => {
            const b = json.parse(PatchBody, body, arena) catch |e| return jsonError(e);
            return switch (parseCanvasPatch(b.values)) {
                .reject => |j| .{ .reject = j },
                .op => |p| .{ .op = .{ .canvas_patch = p } },
            };
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
        .ntfy_put => {
            const b = json.parse(NtfyBody, body, arena) catch |e| return jsonError(e);
            if (b.url) |u| {
                if (u.len > 64) return bad("invalid_url", "url must be at most 64 characters");
                if (u.len > 0) _ = ntfy_url.parse(u) catch return bad("invalid_url", "url must be http://host[:port][/prefix] or https://host[:port][/prefix]");
            }
            if (b.topic) |t| {
                if (t.len > 64) return bad("invalid_topic", "topic must be 1..64 characters of letters, digits, _ and -");
                for (t) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return bad("invalid_topic", "topic must be 1..64 characters of letters, digits, _ and -");
            }
            inline for (.{ "token", "username", "password" }) |name| {
                if (@field(b, name)) |v| if (v.len > 64) return bad("invalid_" ++ name, name ++ " must be at most 64 characters");
            }
            if (b.duration_s) |d| if (d < 1 or d > 300) return bad("invalid_duration", "duration_s must be 1..300");
            if (b.ca) |ca| if (ca.len > max_ca or (ca.len > 0 and std.mem.indexOf(u8, ca, "-----BEGIN CERTIFICATE-----") == null)) return bad("invalid_ca", "ca must be a pem certificate of at most 3500 bytes, or empty to remove it");
            return .{ .op = .{ .ntfy_put = .{ .enabled = b.enabled, .url = b.url, .topic = b.topic, .token = b.token, .username = b.username, .password = b.password, .duration_s = b.duration_s, .insecure = b.insecure, .ca = b.ca } } };
        },
    }
}

/// the five clock style strings, shared by `/scene` and the settings patch.
const StyleRoute = union(enum) { op: clock.StylePatch, reject: Reject };
/// read a parameter's value the way its own kind says it should be read
fn parseParamValue(p: param.Param, text: []const u8) ?u32 {
    return switch (p.kind) {
        .choice => blk: {
            for (p.choices, 0..) |c, i| if (std.mem.eql(u8, c, text)) break :blk @as(u32, @intCast(i));
            break :blk null;
        },
        .toggle => if (std.mem.eql(u8, text, "on") or std.mem.eql(u8, text, "true"))
            @as(u32, 1)
        else if (std.mem.eql(u8, text, "off") or std.mem.eql(u8, text, "false"))
            @as(u32, 0)
        else
            null,
        .colour => if (parseColour(text)) |c| param.rgbValue(c) else null,
        .number => blk: {
            const v = std.fmt.parseInt(i32, text, 10) catch break :blk null;
            if (v < p.min or v > p.max) break :blk null;
            break :blk @bitCast(v);
        },
    };
}

/// resolve `[{scene, name, value}]` against the declared tables, rejecting anything unknown
fn parseGeneratorParams(body: []const GenParamBody, out: []ResolvedParam) ParamsRoute {
    if (body.len > out.len) return .{ .reject = .{ .status = 400, .code = "too_many_params", .message = "at most eight generator parameters per request" } };
    for (body, 0..) |entry, i| {
        const g = enumByName(scene.Generator, entry.scene) orelse return .{ .reject = .{ .status = 400, .code = "invalid_scene", .message = "scene must name a generator" } };
        const table = scene.paramsFor(g);
        // art's own parameter sits at the front of that table; a generator's start after it
        const own = table[scene.art_params.len..];
        const slot = param.indexOf(own, entry.name) orelse return .{ .reject = .{ .status = 400, .code = "invalid_param", .message = "no such parameter on that scene" } };
        const value = parseParamValue(own[slot], entry.value) orelse return .{ .reject = .{ .status = 400, .code = "invalid_param_value", .message = "the value does not fit that parameter" } };
        out[i] = .{ .owner = @intFromEnum(g), .slot = @intCast(slot), .value = value };
    }
    return .{ .op = out[0..body.len] };
}

const ParamsRoute = union(enum) { op: []const ResolvedParam, reject: Reject };

fn parseClockStyle(font_text: ?[]const u8, mode_text: ?[]const u8, colour_text: ?[]const u8, colour2_text: ?[]const u8, gradient_text: ?[]const u8, spread: ?u8, digit_text: ?[]const u8) StyleRoute {
    var p = clock.StylePatch{ .spread = spread };
    if (font_text) |s| p.font = enumByName(clock.Font, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_font", .message = font_names_message } };
    if (mode_text) |s| p.mode = enumByName(clock.ColourMode, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour_mode", .message = "colour_mode must be solid or gradient" } };
    if (colour_text) |s| p.colour = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour", .message = "colour must be rrggbb hex" } };
    if (colour2_text) |s| p.colour2 = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour2", .message = "colour2 must be rrggbb hex" } };
    if (gradient_text) |s| p.gradient = enumByName(clock.Gradient, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_gradient", .message = "gradient must be horizontal, vertical or diagonal" } };
    if (digit_text) |s| p.digit = enumByName(clock.DigitStyle, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_digits", .message = "digits must be solid, outline or shadow" } };
    return .{ .op = p };
}

/// the four transition fields shared by `/scene`, `/notify` and `/frame`: none given means the
/// renderer's default; an effect without a direction takes the effect's natural one; a
/// missing duration is 500 ms; a missing exit backs out the way it came.
const TransitionRoute = union(enum) { op: ?transition.Spec, reject: Reject };
const LocationRoute = union(enum) { op: ?Location, reject: Reject };

/// a location pinned by hand: degrees in, hundredths out. both halves or neither, because half a
/// location is no location, and the timezone's own point is the fallback either way.
fn parseLocation(lat: ?f64, lon: ?f64) LocationRoute {
    if (lat == null and lon == null) return .{ .op = null };
    const a = lat orelse return .{ .reject = .{ .status = 400, .code = "invalid_location", .message = "latitude and longitude go together" } };
    const o = lon orelse return .{ .reject = .{ .status = 400, .code = "invalid_location", .message = "latitude and longitude go together" } };
    if (!(a >= -90.0 and a <= 90.0)) return .{ .reject = .{ .status = 400, .code = "invalid_latitude", .message = "latitude must be -90..90" } };
    if (!(o >= -180.0 and o <= 180.0)) return .{ .reject = .{ .status = 400, .code = "invalid_longitude", .message = "longitude must be -180..180" } };
    return .{ .op = .{ .lat_c = @intFromFloat(@round(a * 100.0)), .lon_c = @intFromFloat(@round(o * 100.0)) } };
}
fn parseTransition(effect_text: ?[]const u8, direction_text: ?[]const u8, ms: ?u32, exit_text: ?[]const u8, natural: transition.Effect) TransitionRoute {
    if (effect_text == null and direction_text == null and ms == null and exit_text == null) return .{ .op = null };
    const exit = if (exit_text) |t| (enumByName(transition.Exit, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_exit", .message = "exit must be reverse, same or none" } }) else .reverse;
    const effect = if (effect_text) |t| (enumByName(transition.Effect, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_transition", .message = effect_names_message } }) else natural;
    const direction = if (direction_text) |t| (enumByName(transition.Direction, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_direction", .message = "direction must be left, right, up or down" } }) else effect.naturalDirection();
    if (ms) |v| if (v > transition.max_duration_ms) return .{ .reject = .{ .status = 400, .code = "invalid_transition_ms", .message = "transition_ms must be 0..5000" } };
    return .{ .op = .{ .effect = effect, .direction = direction, .duration_ns = if (ms) |v| @as(u64, v) * 1_000_000 else transition.default_duration_ns, .exit = exit } };
}

const effect_names_message = "transition must be one of " ++ namesList(transition.Effect);
const font_names_message = "font must be one of " ++ namesList(clock.Font);

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

/// one scene's declared parameters, as json: the contract the console builds its own ui from,
/// so nothing outside the runtime needs to know what a cube is.
fn paramsJson(comptime table: []const param.Param) []const u8 {
    comptime {
        var out: []const u8 = "[";
        for (table, 0..) |p, i| {
            if (i > 0) out = out ++ ",";
            out = out ++ "{\"name\":\"" ++ p.name ++ "\",\"kind\":\"" ++ @tagName(p.kind) ++ "\",\"default\":" ++ std.fmt.comptimePrint("{d}", .{p.default});
            if (!p.on_panel) out = out ++ ",\"on_panel\":false";
            switch (p.kind) {
                .choice => {
                    out = out ++ ",\"choices\":[";
                    for (p.choices, 0..) |c, k| {
                        if (k > 0) out = out ++ ",";
                        out = out ++ "\"" ++ c ++ "\"";
                    }
                    out = out ++ "]";
                },
                .number => out = out ++ std.fmt.comptimePrint(",\"min\":{d},\"max\":{d},\"step\":{d}", .{ p.min, p.max, p.step }),
                .colour, .toggle => {},
            }
            out = out ++ "}";
        }
        const frozen = out ++ "]";
        return frozen;
    }
}

/// the `scenes` document is static.
pub const scenes_body = "{\"bases\":" ++ namesJson(Base) ++ ",\"generators\":[" ++
    "{\"index\":0,\"name\":\"popsquares\",\"parameters\":" ++ paramsJson(&popsquares.params) ++ "}," ++
    "{\"index\":1,\"name\":\"plasma\",\"parameters\":" ++ paramsJson(&plasma.params) ++ "}," ++
    "{\"index\":2,\"name\":\"cube\",\"parameters\":" ++ paramsJson(&cube.params) ++ "}]," ++
    "\"parameters\":{\"art\":" ++ paramsJson(&scene.art_params) ++ ",\"clock\":" ++ paramsJson(&clock.params) ++ ",\"canvas\":" ++ paramsJson(&canvas.params) ++ "}," ++
    "\"clock\":{\"fonts\":" ++ namesJson(clock.Font) ++ ",\"colour_modes\":[\"solid\",\"gradient\"],\"digits\":" ++ namesJson(clock.DigitStyle) ++ ",\"gradients\":[\"horizontal\",\"vertical\",\"diagonal\"],\"spread\":[0,255],\"max_spread\":255},\"ip\":{\"modes\":" ++ namesJson(ip.Mode) ++ "},\"notify\":{\"text_max\":128,\"duration_s\":[1,300]},\"frame\":{\"bytes\":2496,\"duration_s\":[1,300]},\"transitions\":{\"effects\":" ++ namesJson(transition.Effect) ++ ",\"directions\":" ++ namesJson(transition.Direction) ++ ",\"exits\":" ++ namesJson(transition.Exit) ++ ",\"duration_ms\":[0,5000]}}";

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

test "the ip layout is a setting only: there is no ip base to put it on" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    // the scene retired when the canvas took the third button; the address moved to the device menu
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"ip\",\"request_id\":\"7\"}", &c, &origins, &arena), 400, "invalid_base");
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"base\":\"ip\"}", &c, &origins, &arena), 400, "invalid_base");
    const canvas_base = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"canvas\",\"request_id\":\"7\"}", &c, &origins, &arena);
    try std.testing.expectEqual(Base.canvas, canvas_base.op.set_scene.base);
    // but the layout itself is untouched: same key, same four values, and the catalogue still
    // publishes them from the enum, independently of the base list
    const cp = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ip_mode\":\"mini\"}", &c, &origins, &arena);
    try std.testing.expectEqual(ip.Mode.mini, cp.op.config_patch.ip_mode.?);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ip_mode\":\"huge\"}", &c, &origins, &arena), 400, "invalid_ip_mode");
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"ip\":{\"modes\":[\"lines\",\"mini\",\"scroll\",\"big\"]}") != null);
    try std.testing.expect(std.mem.startsWith(u8, scenes_body, "{\"bases\":[\"clock\",\"art\",\"canvas\"],"));
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"canvas\":[]") != null); // the canvas declares nothing yet
}

test "ntfy settings are admin-only and validated" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const p = route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"enabled\":true,\"url\":\"https://ntfy.sh\",\"topic\":\"tc002-alerts\",\"token\":\"tk_abc\",\"duration_s\":12,\"ca\":\"-----BEGIN CERTIFICATE-----\\nAA==\\n-----END CERTIFICATE-----\"}", &c, &origins, &arena);
    try std.testing.expectEqualStrings("tc002-alerts", p.op.ntfy_put.topic.?);
    try std.testing.expectEqual(@as(?u16, 12), p.op.ntfy_put.duration_s);
    try std.testing.expect(p.op.ntfy_put.ca.?.len > 20);
    try std.testing.expect(route(testReq(.GET, "/api/v1/ntfy", "", admin_header, null, null), "", &c, &origins, &arena).op == .ntfy_get);
    try expectReject(route(testReq(.GET, "/api/v1/ntfy", "", control_header, null, null), "", &c, &origins, &arena), 403, "forbidden");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"url\":\"ntfy.sh\"}", &c, &origins, &arena), 400, "invalid_url");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"topic\":\"has space\"}", &c, &origins, &arena), 400, "invalid_topic");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"duration_s\":0}", &c, &origins, &arena), 400, "invalid_duration");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"ca\":\"not a pem\"}", &c, &origins, &arena), 400, "invalid_ca");
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

test "the night schedule's fields, and a location that has to arrive in one piece" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const req = testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null);
    const p = route(req, "{\"night\":true,\"night_brightness\":8,\"night_lead_min\":45,\"latitude\":-33.87,\"longitude\":151.215}", &c, &origins, &arena);
    try std.testing.expectEqual(@as(?bool, true), p.op.config_patch.night);
    try std.testing.expectEqual(@as(?u8, 8), p.op.config_patch.night_brightness);
    try std.testing.expectEqual(@as(?u8, 45), p.op.config_patch.night_lead_min);
    try std.testing.expectEqual(@as(i16, -3387), p.op.config_patch.location.?.lat_c);
    try std.testing.expectEqual(@as(i16, 15122), p.op.config_patch.location.?.lon_c); // rounded, not truncated
    const off = route(req, "{\"night\":false,\"location_auto\":true}", &c, &origins, &arena);
    try std.testing.expectEqual(@as(?bool, false), off.op.config_patch.night);
    try std.testing.expectEqual(@as(?bool, true), off.op.config_patch.location_auto);
    try std.testing.expect(off.op.config_patch.location == null);

    try expectReject(route(req, "{\"night_brightness\":0}", &c, &origins, &arena), 400, "invalid_night_brightness");
    try expectReject(route(req, "{\"night_brightness\":101}", &c, &origins, &arena), 400, "invalid_night_brightness");
    try expectReject(route(req, "{\"night_lead_min\":121}", &c, &origins, &arena), 400, "invalid_night_lead");
    try expectReject(route(req, "{\"latitude\":-33.87}", &c, &origins, &arena), 400, "invalid_location");
    try expectReject(route(req, "{\"longitude\":151.21}", &c, &origins, &arena), 400, "invalid_location");
    try expectReject(route(req, "{\"latitude\":-91,\"longitude\":0}", &c, &origins, &arena), 400, "invalid_latitude");
    try expectReject(route(req, "{\"latitude\":0,\"longitude\":181}", &c, &origins, &arena), 400, "invalid_longitude");
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

test "a canvas document is parsed whole, with every field checked against its element type" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const put = testReq(.PUT, "/api/v1/canvas", "", admin_header, "application/json", null);
    const r = route(put,
        \\{"elements":[
        \\ {"id":"hdr","type":"text","at":[0,0],"font":"mini","colour":"808080","text":"living room"},
        \\ {"id":"t","type":"text","tile":2,"of":3,"align":"centre","font":"big","text":"21"},
        \\ {"id":"g","type":"sparkline","at":[0,13],"size":[52,3],"style":"bars","data":[1,9,4],"threshold":8,"over":"ff0000"},
        \\ {"type":"line","at":[0,12],"to":[51,12],"colour":"202020"},
        \\ {"id":"b","type":"bar","row":3,"of":4,"value":60,"background":"101010"}]}
    , &c, &origins, &arena);
    const d = r.op.canvas_put;
    try std.testing.expectEqual(@as(u8, 5), d.count);
    try std.testing.expectEqualStrings("living room", d.textOf(d.elements[0].body.text.span));
    try std.testing.expectEqual(canvas.Font.big, d.elements[1].body.text.face);
    try std.testing.expectEqual(canvas.Align.centre, d.elements[1].body.text.alignment);
    try std.testing.expectEqual(canvas.Box.tile(2, 3), d.elements[1].box);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 9, 4 }, d.dataOf(d.elements[2].body.sparkline.span));
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, d.elements[2].body.sparkline.over);
    try std.testing.expectEqual(@as(i16, 51), d.elements[3].body.line.x2);
    try std.testing.expect(d.elements[3].id.len == 0); // decoration needs no id
    try std.testing.expectEqual(@as(u8, 60), d.elements[4].body.bar.value);

    // samples as hex, for a document that would not otherwise fit
    const hexed = route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data_hex\":\"01090f\"}]}", &c, &origins, &arena);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 9, 15 }, hexed.op.canvas_put.dataOf(hexed.op.canvas_put.elements[0].body.sparkline.span));

    // a field that does not belong to the type is a mistake worth hearing about
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"text\":\"hi\"}]}", &c, &origins, &arena), 400, "invalid_element_field");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"bar\",\"r\":4}]}", &c, &origins, &arena), 400, "invalid_element_field");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"filled\":true}]}", &c, &origins, &arena), 400, "invalid_element_field");
    // and so is a nonsense value
    try expectReject(route(put, "{\"elements\":[{\"type\":\"blob\"}]}", &c, &origins, &arena), 400, "invalid_element_type");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\"}]}", &c, &origins, &arena), 400, "missing_text");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"line\",\"at\":[0,0]}]}", &c, &origins, &arena), 400, "missing_to");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"font\":\"comic\"}]}", &c, &origins, &arena), 400, "invalid_font");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"colour\":\"nope\"}]}", &c, &origins, &arena), 400, "invalid_colour");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"id\":\"far_too_long\"}]}", &c, &origins, &arena), 400, "invalid_element_id");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data_hex\":\"abc\"}]}", &c, &origins, &arena), 400, "invalid_data");
    // placement: one way or the other, not both, and `of` means nothing alone
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"tile\":1,\"of\":3,\"at\":[0,0]}]}", &c, &origins, &arena), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"tile\":1}]}", &c, &origins, &arena), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"of\":3}]}", &c, &origins, &arena), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"size\":[-1,4]}]}", &c, &origins, &arena), 400, "invalid_placement");
}

test "a document read back can be put back: age_ms is accepted and ignored" {
    // `GET /canvas` publishes the age of each element's animation clock so a second renderer can
    // match the phase. clients read a document and put it back -- the demo reels restore exactly
    // that way -- so the field a get emits has to be one a put will take.
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const put = testReq(.PUT, "/api/v1/canvas", "", admin_header, "application/json", null);
    const r = route(put,
        \\{"elements":[
        \\ {"id":"t","type":"text","at":[0,0],"text":"21.4C","age_ms":1840,
        \\  "animate":{"kind":"scramble","ms":2500}},
        \\ {"type":"rect","at":[0,8],"size":[10,4],"age_ms":0}]}
    , &c, &origins, &arena);
    const d = r.op.canvas_put;
    try std.testing.expectEqual(@as(u8, 2), d.count);
    try std.testing.expectEqualStrings("21.4C", d.textOf(d.elements[0].body.text.span));
    try std.testing.expectEqual(canvas.Motion.scramble, d.elements[0].anim.kind);
    // it is a reading, not a setting: nothing in the document carries it
    try std.testing.expectEqual(canvas.Motion.none, d.elements[1].anim.kind);
}

test "a canvas patch carries values by id, and the canvas routes have their own authority" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const patch = testReq(.PATCH, "/api/v1/canvas", "", control_header, "application/json", null);
    const r = route(patch, "{\"values\":[{\"id\":\"t\",\"text\":\"21.1C\"},{\"id\":\"g\",\"data\":[4,5]},{\"id\":\"b\",\"value\":70,\"colour\":\"00ff00\"}]}", &c, &origins, &arena);
    const p = r.op.canvas_patch;
    try std.testing.expectEqual(@as(u8, 3), p.count);
    try std.testing.expectEqualStrings("21.1C", p.items[0].slice());
    try std.testing.expectEqual(canvas.Field.text, p.items[0].has);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, p.items[1].slice());
    try std.testing.expectEqual(canvas.Field.value | canvas.Field.colour, p.items[2].has);
    try std.testing.expectEqual(@as(u8, 70), p.items[2].value);

    try expectReject(route(patch, "{\"values\":[{\"id\":\"t\"}]}", &c, &origins, &arena), 400, "empty_value");
    try expectReject(route(patch, "{\"values\":[{\"id\":\"\",\"value\":1}]}", &c, &origins, &arena), 400, "invalid_element_id");
    try expectReject(route(patch, "{\"values\":[{\"id\":\"t\",\"text\":\"x\",\"data\":[1]}]}", &c, &origins, &arena), 400, "invalid_element_field");

    // reading is control, replacing the whole document is admin
    try std.testing.expect(route(testReq(.GET, "/api/v1/canvas", "", control_header, null, null), "", &c, &origins, &arena).op == .canvas_get);
    try std.testing.expect(route(testReq(.DELETE, "/api/v1/canvas", "", control_header, null, null), "", &c, &origins, &arena).op == .canvas_clear);
    try expectReject(route(testReq(.PUT, "/api/v1/canvas", "", control_header, "application/json", null), "{\"elements\":[]}", &c, &origins, &arena), 403, "forbidden");
}

test "an animation is declared per element, and only where it makes sense" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const put = testReq(.PUT, "/api/v1/canvas", "", admin_header, "application/json", null);
    const r = route(put,
        \\{"elements":[
        \\ {"id":"t","type":"text","text":"21.1C","animate":{"kind":"scramble","ms":600}},
        \\ {"id":"d","type":"circle","r":3,"animate":{"kind":"hue"}},
        \\ {"id":"b","type":"bar","value":50,"animate":{"kind":"bounce","amount":3,"axis":"x","phase":50}},
        \\ {"id":"g","type":"sparkline","data":[1,2],"animate":{"kind":"sweep","ms":900}}]}
    , &c, &origins, &arena);
    const d = r.op.canvas_put;
    try std.testing.expectEqual(canvas.Motion.scramble, d.elements[0].anim.kind);
    try std.testing.expectEqual(@as(u16, 600), d.elements[0].anim.ms);
    try std.testing.expectEqual(@as(u16, 8000), d.elements[1].anim.ms); // a hue turns slowly by default
    try std.testing.expect(d.elements[2].anim.axis_x);
    try std.testing.expectEqual(@as(u8, 50), d.elements[2].anim.phase);
    try std.testing.expectEqual(canvas.Motion.sweep, d.elements[3].anim.kind);

    // a motion that cannot mean anything for that element is refused rather than ignored
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"animate\":{\"kind\":\"scramble\"}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"animate\":{\"kind\":\"sweep\"}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"wobble\"}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"none\"}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"blink\",\"ms\":0}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"blink\",\"phase\":101}}]}", &c, &origins, &arena), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"bounce\",\"axis\":\"z\"}}]}", &c, &origins, &arena), 400, "invalid_motion");
}
