//! the `/api/v1` surface as pure logic: bearer authentication with constant-time comparison,
//! the origin policy, route matching, request bodies into typed operations, and results into
//! response bodies. netd owns the sockets and the relay; this module never blocks.
const std = @import("std");
const http = @import("http.zig");
const clients = @import("clients.zig");
const json = @import("json.zig");
const geometry = @import("../panel/geometry.zig");
const arbiter = @import("../scene/arbiter.zig");
const scene = @import("../scene/scene.zig");
const actions = @import("../input/actions.zig");
const clock = @import("../scene/clock.zig");
const transition = @import("../panel/transition.zig");
const ip = @import("../scene/ip.zig");
const canvas = @import("../scene/canvas.zig");
const sound_store = @import("../sound/store.zig");
const icons = @import("../scene/icons.zig");
const param = @import("../scene/param.zig");
const cube = @import("../scene/cube.zig");
const terrain = @import("../scene/terrain.zig");
const popsquares = @import("../scene/popsquares.zig");
const plasma = @import("../scene/plasma.zig");
const ntfy_url = @import("../ntfy/url.zig");
const berry_store = @import("../berry/store.zig");

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

/// none < read < control < admin. internal to this file -- never serialised, never stored -- so
/// a new rung costs nothing in compatibility.
/// the two built-in secrets as scope sets.
///
/// `admin` is everything. `control` is the operating set: see it, say something, change what is on
/// the panel, drive the controls. it does **not** carry `content`, `scripts`, `settings` or
/// `tokens` -- storing things and reconfiguring the device are a different kind of act.
///
/// it does carry `input`, and `input` is worth knowing about: injecting button events reaches the
/// device menu, and the menu can change brightness, the night schedule, the ip layout, mqtt and
/// ntfy on or off, and reboot -- `display`, `settings` and `reboot` over http. so `input` reaches
/// past `settings`, not merely as far. that is not new and holding this secret always implied
/// it. what is new is that a *named* token can now be issued without `input`, which is the only
/// way that reach was ever going to be refusable.
pub const admin_scopes: clients.Set = clients.all;
pub const control_scopes: clients.Set = clients.Scope.status.bit() | clients.Scope.screen.bit() |
    clients.Scope.logs.bit() | clients.Scope.notify.bit() | clients.Scope.display.bit() |
    clients.Scope.sound.bit() | clients.Scope.input.bit();

/// what a presented token turned out to be: the scopes it holds, and, for a named token, which
/// client it is. an empty set is an unauthenticated request -- there is no scope worth zero bits.
pub const Auth = struct { scopes: clients.Set = 0, client: ?clients.Name = null };

pub fn authenticate(creds: *const Credentials, store: *const clients.Store, authorization: ?[]const u8) Auth {
    const header = authorization orelse return .{};
    if (header.len != 7 + token_len * 2 or !std.mem.eql(u8, header[0..7], "Bearer ")) return .{};
    var presented: Token = undefined;
    _ = std.fmt.hexToBytes(&presented, header[7..]) catch return .{};
    // compare against everything unconditionally so timing reveals neither which token matched
    // nor how many clients exist
    const is_admin = std.crypto.timing_safe.eql(Token, presented, creds.admin);
    const is_control = std.crypto.timing_safe.eql(Token, presented, creds.control);
    const hit = store.match(presented);
    if (is_admin) return .{ .scopes = admin_scopes };
    if (is_control) return .{ .scopes = control_scopes };
    if (hit) |i| {
        const c = &store.entries[i];
        return .{ .scopes = c.scopes, .client = c.name };
    }
    return .{};
}

pub const max_origins = 4;
pub const OriginPolicy = struct {
    allowed: [max_origins][]const u8 = .{ "", "", "", "" },
    count: u8 = 0,

    /// the reference page is served by this same plaintext listener. allow its browser origin,
    /// while retaining the explicit allowlist for other origins; bearer auth is still required.
    pub fn allowsRequest(self: *const OriginPolicy, req: http.Request) bool {
        if (self.allows(req.origin)) return true;
        const host = req.host orelse return false;
        const origin = req.origin orelse return true;
        if (host.len == 0 or host.len > 255) return false;
        for (host) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != ':' and c != '[' and c != ']') return false;
        }
        return std.mem.startsWith(u8, origin, "http://") and std.mem.eql(u8, origin[7..], host);
    }

    /// no origin header (a non-browser client) is allowed; other origins must be listed exactly.
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
    action: struct { kind: ActionKind, brightness: ?u8, seed: ?u32, power: ?bool, request_id: u64, epoch: ?u32 },
    /// the framebuffer as shown; `raw` = octets instead of the json document
    screen: struct { raw: bool },
    /// a page of the supervisor's log ring after this sequence number
    logs: struct { after: u32 },
    /// subscribe to every statement this device applies, as an sse stream that does not end
    events,
    /// the stored sounds
    sound_list,
    /// one chunk of a sound on its way to the store; `final` commits what has been assembled
    sound_put: struct { name: []const u8, offset: u32, final: bool, data: []const u8 },
    sound_delete: struct { name: []const u8 },
    client_list,
    client_add: struct { name: []const u8, scopes: clients.Set },
    client_remove: struct { name: []const u8 },
    client_rotate: struct { name: []const u8, scopes: ?clients.Set },
    sound_play: struct { name: []const u8, volume: ?u8, loop: bool },
    sound_stop,
    /// a remote control event: the same paths as a physical press
    input: struct { control: actions.Control, event: actions.InputRequest, steps: u8, request_id: u64, epoch: ?u32 },
    dismiss_notify: struct { name: []const u8, request_id: u64, epoch: ?u32 },
    /// `doc` set makes it a rich notification: the document is drawn and `text` is its summary
    notify: struct { text: []const u8, colour: [3]u8, duration_s: u16, name: []const u8, stack: bool, hold: bool, transition: ?transition.Spec, request_id: u64, epoch: ?u32, doc: ?canvas.Document = null },
    frame: struct { rgb: *const geometry.Rgb, duration_s: u16, transition: ?transition.Spec, request_id: u64, epoch: ?u32 },
    config_get,
    config_patch: ConfigPatch,
    config_save: struct { revision: ?u32 },
    /// reboot the device: the menu's own path, behind its "rebooting..." notice. its own scope,
    /// its own route, and deliberately not a body kind, so the mqtt command topics cannot reach it
    reboot: struct { request_id: u64 },
    mqtt_get,
    mqtt_put: MqttPut,
    mqtt_status,
    ntfy_get,
    ntfy_put: NtfyPut,
    streams_create,
    streams_palette,
    streams_delete,
    canvas_get,
    /// the whole document, by value: it is about two kilobytes and a request handles one.
    /// `persist` false shows it without writing it to flash
    canvas_put: struct { doc: canvas.Document, persist: bool },
    canvas_patch: canvas.Patch,
    canvas_clear,
    icons,
    sprite_list,
    /// the interpreter's own status, from the snapshot netd already holds
    berry_status,
    /// what is in the store: names, sizes, and how much room is left
    berry_list,
    /// a script's source, compiled before it is stored
    berry_put: struct { name: []const u8, source: []const u8 },
    berry_delete: struct { name: []const u8 },
    berry_get: struct { name: []const u8 },
    berry_run: struct { name: []const u8 },
    sprite_put: canvas.Sprite,
    sprite_delete: canvas.Id,
};

/// a location pinned by hand, in hundredths of a degree
pub const Location = struct { lat_c: i16, lon_c: i16 };

/// two hours of lead is already longer than any twilight the night schedule adds it to
pub const max_night_lead_min = 120;
/// the heap a berry vm may be given. the floor is what the interpreter needs to boot (about 4 kb)
/// with room to do something; the ceiling is what src/berry/vm.zig reserves statically.
pub const sound_volume_min: u8 = 1;
pub const sound_volume_max: u8 = 100;
/// the low-battery thresholds a caller may set. the floor is well under the cell's empty voltage
/// and the ceiling under its full one, so neither end can be set to "always" or "never" by
/// accident; `power.zig` carries the numbers the stock firmware used.
pub const battery_shutdown_mv_min: u16 = 3000;
pub const battery_shutdown_mv_max: u16 = 4000;
/// five minutes of countdown is already far longer than a cell at 3.55 v has to spare
pub const battery_grace_s_max: u16 = 300;
pub const berry_heap_kb_min: u16 = 16;
pub const berry_heap_kb_max: u16 = 256;
/// how long one handler may run. the ceiling stays well under the two seconds of silence that make
/// the supervisor treat berryd as wedged, so the two watchdogs cannot fight each other.
pub const berry_handler_ms_min: u16 = 10;
pub const berry_handler_ms_max: u16 = 1000;

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
    discovery_controls: ?bool = null,
    mdns: ?bool = null,
    discovery_prefix: ?[]const u8 = null,
    expected_revision: ?u32 = null,
    clock_font: ?clock.Font = null,
    clock_colour_mode: ?clock.ColourMode = null,
    clock_colour: ?[3]u8 = null,
    clock_colour2: ?[3]u8 = null,
    clock_gradient: ?clock.Gradient = null,
    clock_spread: ?u8 = null,
    clock_digit: ?clock.DigitStyle = null,
    clock_fade: ?bool = null,
    /// resolved generator parameters: which generator, which slot in its table, and the value
    generator_params: []const ResolvedParam = &.{},
    ip_mode: ?ip.Mode = null,
    night: ?bool = null,
    night_brightness: ?u8 = null,
    night_lead_min: ?u8 = null,
    location: ?Location = null,
    /// true drops a pinned location and goes back to the timezone's own reference point
    location_auto: ?bool = null,
    berry_enabled: ?bool = null,
    sound_enabled: ?bool = null,
    sound_volume: ?u8 = null,
    berry_heap_kb: ?u16 = null,
    battery_shutdown: ?bool = null,
    battery_shutdown_mv: ?u16 = null,
    battery_grace_s: ?u16 = null,
    berry_handler_ms: ?u16 = null,
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
const ClockBody = struct { font: ?[]const u8 = null, colour_mode: ?[]const u8 = null, colour: ?[]const u8 = null, colour2: ?[]const u8 = null, gradient: ?[]const u8 = null, spread: ?u8 = null, digits: ?[]const u8 = null, fade: ?bool = null };
/// one generator parameter in a settings patch. the value is always a string and the scene's own
/// table says how to read it: a choice by its name, a colour as rrggbb, a number in decimal, a
/// toggle as on or off. `GET /scenes` publishes the table, so a client needs nothing else.
const GenParamBody = struct { scene: []const u8, name: []const u8, value: []const u8 };
const TokensBody = struct { name: []const u8, scopes: []const []const u8 };
const RotateBody = struct { scopes: ?[]const []const u8 = null };

/// every scope name, for the one error message that has to list them
const scope_names = blk: {
    var out: []const u8 = "";
    for (@typeInfo(clients.Scope).@"enum".fields, 0..) |f, i| {
        out = out ++ (if (i == 0) "" else ", ") ++ f.name;
    }
    break :blk out;
};

/// a scope list from a request body. `tokens` is refused by name rather than quietly dropped: a
/// caller asking for it has a mistaken idea of what it is about to get.
const ScopeError = enum { unknown, empty, minting };
fn scopeSet(names: []const []const u8) union(enum) { set: clients.Set, err: ScopeError } {
    if (names.len == 0) return .{ .err = .empty };
    var set: clients.Set = 0;
    for (names) |n| {
        const scope = std.meta.stringToEnum(clients.Scope, n) orelse return .{ .err = .unknown };
        if (scope == .tokens) return .{ .err = .minting };
        set |= scope.bit();
    }
    return .{ .set = set };
}
const SceneBody = struct { base: []const u8, generator: ?[]const u8 = null, seed: ?u32 = null, clock: ?ClockBody = null, transition: ?[]const u8 = null, direction: ?[]const u8 = null, transition_ms: ?u32 = null, exit: ?[]const u8 = null, easing: ?[]const u8 = null, request_id: ?[]const u8 = null, epoch: ?u32 = null };
const ActionBody = struct { action: []const u8, brightness: ?u8 = null, seed: ?u32 = null, power: ?bool = null, request_id: ?[]const u8 = null, epoch: ?u32 = null };
const InputBody = struct { control: []const u8, event: []const u8, steps: u8 = 1, request_id: ?[]const u8 = null, epoch: ?u32 = null };
const DismissNotifyBody = struct { name: ?[]const u8 = null, request_id: ?[]const u8 = null, epoch: ?u32 = null };
const NotifyBody = struct { name: ?[]const u8 = null, stack: bool = false, hold: bool = false, text: ?[]const u8 = null, elements: ?[]const ElementBody = null, colour: ?[]const u8 = null, duration_s: u16 = 5, transition: ?[]const u8 = null, direction: ?[]const u8 = null, transition_ms: ?u32 = null, exit: ?[]const u8 = null, easing: ?[]const u8 = null, request_id: ?[]const u8 = null, epoch: ?u32 = null };
/// `{"name":"chime"}` to play, `{"stop":true}` to stop. volume is optional and means "louder or
/// quieter than the setting, just for this one".
const SoundBody = struct { name: ?[]const u8 = null, volume: ?u8 = null, loop: ?bool = null, stop: ?bool = null };

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
    discovery_controls: ?bool = null,
    mdns: ?bool = null,
    discovery_prefix: ?[]const u8 = null,
    expected_revision: ?u32 = null,
    clock_font: ?[]const u8 = null,
    clock_colour_mode: ?[]const u8 = null,
    clock_colour: ?[]const u8 = null,
    clock_colour2: ?[]const u8 = null,
    clock_gradient: ?[]const u8 = null,
    clock_spread: ?u8 = null,
    clock_digit: ?[]const u8 = null,
    clock_fade: ?bool = null,
    generator_params: ?[]const GenParamBody = null,
    ip_mode: ?[]const u8 = null,
    night: ?bool = null,
    night_brightness: ?u8 = null,
    night_lead_min: ?u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    location_auto: ?bool = null,
    berry_enabled: ?bool = null,
    berry_heap_kb: ?u16 = null,
    battery_shutdown: ?bool = null,
    battery_shutdown_mv: ?u16 = null,
    battery_grace_s: ?u16 = null,
    berry_handler_ms: ?u16 = null,
    sound_enabled: ?bool = null,
    sound_volume: ?u8 = null,
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
    data: ?SampleData = null,
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
/// how a sparkline's samples arrived. zig's json parser fills a `[]const u8` from a json *string*
/// exactly as readily as from an array of numbers, so `{"data":"1,2,3"}` used to become five
/// samples of 49,44,50,44,51 -- the digits and the commas -- and drew a plausible-looking wrong
/// picture. anything hand-rolling json falls into that, and a silent wrong answer is the worst
/// kind, so `data` keeps which form it came in as and a string is refused by name. `data_hex` is
/// the supported way to carry samples as a string.
const SampleData = union(enum) {
    list: []const u8,
    text: []const u8,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !SampleData {
        const as_text = (try source.peekNextTokenType()) == .string;
        const bytes = try std.json.innerParse([]const u8, allocator, source, options);
        return if (as_text) .{ .text = bytes } else .{ .list = bytes };
    }
};

const AnimateBody = struct { kind: []const u8, ms: ?u16 = null, phase: ?u8 = null, amount: ?u8 = null, axis: ?[]const u8 = null };
const CanvasBody = struct { elements: []const ElementBody, persist: bool = true };
/// a patch names elements by id and carries only what changed. it is a list rather than an object
/// keyed by id because the parser resolves field names at compile time and the ids belong to the
/// client -- the same reason `generator_params` is a list.
const ValueBody = struct {
    id: []const u8,
    text: ?[]const u8 = null,
    data: ?SampleData = null,
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

fn jsonError(e: json.Error, where: json.Where, arena: *Arena) Route {
    return switch (e) {
        error.TooLarge => .{ .reject = .{ .status = 413, .code = "body_too_large", .message = "json bodies are limited to 8192 bytes" } },
        error.TooDeep => bad("body_too_deep", "json nesting is limited to eight levels"),
        error.UnknownField => bad("unknown_field", "the body contains a field the schema does not define"),
        error.DuplicateField => bad("duplicate_field", "the body repeats a field"),
        error.MissingField => bad("missing_field", "a required field is absent"),
        error.OutOfRange => bad("value_out_of_range", named(arena, where.field, "is outside the range this field allows", "a number is outside the range its field allows")),
        error.NotWhole => bad("value_not_whole", named(arena, where.field, "must be a whole number", "a number in the body must be whole")),
        error.InvalidJson => bad("invalid_json", "the body is not valid json for this schema"),
    };
}

/// "<field> <tail>", or `otherwise` when the parser could not name a field. the text is built in
/// the request arena, which the failed parse has just finished with: a body is parsed once per
/// request and a rejection ends that request, so nothing else in the response points into the
/// arena at this moment. a second parse in the same request would break that.
fn named(arena: *Arena, field: []const u8, tail: []const u8, otherwise: []const u8) []const u8 {
    if (field.len == 0) return otherwise;
    return std.fmt.bufPrint(arena, "{s} {s}", .{ field, tail }) catch otherwise;
}

/// ids the device mints for a client that sent none. the renderer's deduplication window matches
/// on the id alone, so a minted id must never land on one a client chose: the top bit is reserved
/// for the device, which puts every minted id out of reach of a counter or a hand-picked number.
pub const generated_mask: u64 = @as(u64, 1) << 63;

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
const SampleError = error{
    /// samples given as a json string, which is `data_hex`'s job
    NotAList,
    /// too many samples, or hex that is not hex
    Malformed,
};

fn parseSamples(b: *const ElementBody, out: []u8) SampleError![]const u8 {
    if (b.data) |d| {
        const list = switch (d) {
            .text => return error.NotAList,
            .list => |l| l,
        };
        if (list.len > out.len) return error.Malformed;
        @memcpy(out[0..list.len], list);
        return out[0..list.len];
    }
    const hex = b.data_hex orelse return out[0..0];
    if (hex.len % 2 != 0 or hex.len / 2 > out.len) return error.Malformed;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        out[i / 2] = (hexDigit(hex[i]) orelse return error.Malformed) * 16 + (hexDigit(hex[i + 1]) orelse return error.Malformed);
    }
    return out[0 .. hex.len / 2];
}

/// the same answer wherever samples are read, so the put and the patch route agree
fn sampleReject(e: SampleError) Reject {
    return switch (e) {
        error.NotAList => canvasBad("invalid_data", "data is a list of numbers; for samples as a string use data_hex"),
        error.Malformed => canvasBad("invalid_data", "data is up to 52 samples of 0..255, or data_hex of twice as many hex digits"),
    };
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
                const got = parseSamples(b, &samples) catch |bad_data| return .{ .reject = sampleReject(bad_data) };
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
            const got = parseSamples(&eb, &samples) catch |e| return .{ .reject = sampleReject(e) };
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

const Endpoint = struct { method: http.Method, path: []const u8, scope: clients.Scope };

/// the one scope each route needs. there is no hierarchy any more: a token holds a set and a route
/// names a bit, so "may raise a notification and nothing else" is a thing that can be said.
const endpoints = [_]Endpoint{
    .{ .method = .GET, .path = "/api/v1/status", .scope = .status },
    .{ .method = .GET, .path = "/api/v1/scenes", .scope = .status },
    .{ .method = .PUT, .path = "/api/v1/scene", .scope = .display },
    .{ .method = .POST, .path = "/api/v1/action", .scope = .display },
    .{ .method = .GET, .path = "/api/v1/config", .scope = .status },
    .{ .method = .PATCH, .path = "/api/v1/config", .scope = .settings },
    .{ .method = .POST, .path = "/api/v1/config/save", .scope = .settings },
    .{ .method = .POST, .path = "/api/v1/reboot", .scope = .reboot },
    .{ .method = .POST, .path = "/api/v1/notify", .scope = .notify },
    .{ .method = .POST, .path = "/api/v1/notify/dismiss", .scope = .notify },
    .{ .method = .POST, .path = "/api/v1/frame", .scope = .display },
    .{ .method = .GET, .path = "/api/v1/icons", .scope = .status },
    .{ .method = .GET, .path = "/api/v1/sprites", .scope = .status },
    .{ .method = .GET, .path = "/api/v1/canvas", .scope = .status },
    .{ .method = .PUT, .path = "/api/v1/canvas", .scope = .content },
    .{ .method = .PATCH, .path = "/api/v1/canvas", .scope = .display },
    .{ .method = .DELETE, .path = "/api/v1/canvas", .scope = .display },
    .{ .method = .GET, .path = "/api/v1/mqtt", .scope = .settings },
    .{ .method = .PUT, .path = "/api/v1/mqtt", .scope = .settings },
    .{ .method = .GET, .path = "/api/v1/mqtt/status", .scope = .status },
    .{ .method = .GET, .path = "/api/v1/ntfy", .scope = .settings },
    .{ .method = .PUT, .path = "/api/v1/ntfy", .scope = .settings },
    .{ .method = .POST, .path = "/api/v1/streams", .scope = .display },
    .{ .method = .GET, .path = "/api/v1/screen", .scope = .screen },
    .{ .method = .GET, .path = "/api/v1/logs", .scope = .logs },
    .{ .method = .GET, .path = "/api/v1/events", .scope = .logs },
    .{ .method = .GET, .path = "/api/v1/sounds", .scope = .status },
    .{ .method = .POST, .path = "/api/v1/sound", .scope = .sound },
    .{ .method = .GET, .path = "/api/v1/berry", .scope = .status },
    .{ .method = .GET, .path = "/api/v1/berry/scripts", .scope = .status },
    .{ .method = .POST, .path = "/api/v1/input", .scope = .input },
    // named client tokens. admin for all three: issuing is how access is granted, and a token
    // that could issue tokens would make revocation meaningless.
    .{ .method = .GET, .path = "/api/v1/tokens", .scope = .tokens },
    .{ .method = .POST, .path = "/api/v1/tokens", .scope = .tokens },
};

/// `text/plain`, with or without a charset parameter
fn isText(content_type: ?[]const u8) bool {
    const ct = content_type orelse return false;
    return std.ascii.startsWithIgnoreCase(std.mem.trim(u8, ct, " "), "text/plain");
}

fn sufficient(have: clients.Set, need: clients.Scope) bool {
    return clients.has(have, need);
}

/// classify a complete request. `body` is exactly `content-length` bytes.
pub fn route(req: http.Request, body: []const u8, creds: *const Credentials, store: *const clients.Store, origins: *const OriginPolicy, arena: *Arena, generated_id: u64) Route {
    // filled in by a failed body parse, so the rejection can name the field that was wrong
    var where = json.Where{};
    // origin first: reject disallowed origins before any work
    if (!origins.allowsRequest(req)) return .{ .reject = .{ .status = 403, .code = "origin_denied", .message = "this origin is not allowed" } };
    // path and method
    var path_known = false;
    var matched: ?Endpoint = null;
    const sprites_prefix = "/api/v1/sprites/";
    if (std.mem.startsWith(u8, req.path, sprites_prefix)) {
        path_known = true;
        const rest = req.path[sprites_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) {
            if (req.method == .PUT) matched = .{ .method = .PUT, .path = "/api/v1/sprites/{id}", .scope = .content };
            if (req.method == .DELETE) matched = .{ .method = .DELETE, .path = "/api/v1/sprites/{id}", .scope = .content };
        }
    }
    const tokens_prefix = "/api/v1/tokens/";
    if (std.mem.startsWith(u8, req.path, tokens_prefix)) {
        path_known = true;
        const rest = req.path[tokens_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) {
            if (req.method == .DELETE) matched = .{ .method = .DELETE, .path = "/api/v1/tokens/{name}", .scope = .tokens };
        } else if (std.mem.endsWith(u8, rest, "/rotate") and std.mem.count(u8, rest, "/") == 1) {
            if (req.method == .POST) matched = .{ .method = .POST, .path = "/api/v1/tokens/{name}/rotate", .scope = .tokens };
        }
    }
    const sounds_prefix = "/api/v1/sounds/";
    if (std.mem.startsWith(u8, req.path, sounds_prefix)) {
        path_known = true;
        const rest = req.path[sounds_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) {
            // admin for both, like a script: a stored sound plays on a device somebody lives with,
            // long after the request that stored it
            if (req.method == .PUT) matched = .{ .method = .PUT, .path = "/api/v1/sounds/{name}", .scope = .content };
            if (req.method == .DELETE) matched = .{ .method = .DELETE, .path = "/api/v1/sounds/{name}", .scope = .content };
        }
    }
    const scripts_prefix = "/api/v1/berry/scripts/";
    if (std.mem.startsWith(u8, req.path, scripts_prefix)) {
        path_known = true;
        const rest = req.path[scripts_prefix.len..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) {
            // both are admin: a script can drive the panel and publish to the broker, which is a
            // different thing to hand out than the ability to read what is on the screen
            // reading a script is control, matching the list: a split where a token may enumerate
            // names but not read them protects little, and an editor needs admin to save anyway.
            if (req.method == .GET) matched = .{ .method = .GET, .path = "/api/v1/berry/scripts/{name}", .scope = .scripts };
            if (req.method == .PUT) matched = .{ .method = .PUT, .path = "/api/v1/berry/scripts/{name}", .scope = .scripts };
            if (req.method == .DELETE) matched = .{ .method = .DELETE, .path = "/api/v1/berry/scripts/{name}", .scope = .scripts };
        } else if (std.mem.endsWith(u8, rest, "/run") and std.mem.count(u8, rest, "/") == 1) {
            // admin, like writing one: running a stored script is asking it to drive the panel now
            if (req.method == .POST) matched = .{ .method = .POST, .path = "/api/v1/berry/scripts/{name}/run", .scope = .scripts };
        }
    }
    const streams_prefix = "/api/v1/streams/";
    if (std.mem.startsWith(u8, req.path, streams_prefix)) {
        path_known = true;
        const rest = req.path[streams_prefix.len..];
        if (req.method == .DELETE and std.mem.indexOfScalar(u8, rest, '/') == null) matched = .{ .method = .DELETE, .path = "/api/v1/streams/{id}", .scope = .display };
        if (req.method == .PUT and std.mem.endsWith(u8, rest, "/palette")) matched = .{ .method = .PUT, .path = "/api/v1/streams/{id}/palette", .scope = .display };
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
    const held = authenticate(creds, store, req.authorization).scopes;
    if (held == 0) return .{ .reject = .{ .status = 401, .code = "unauthorized", .message = "a valid bearer token is required" } };
    if (!sufficient(held, ep.scope)) return .{ .reject = .{ .status = 403, .code = "forbidden", .message = "this token does not hold the scope this route needs" } };

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
    if (std.mem.eql(u8, ep.path, "/api/v1/berry")) return .{ .op = .berry_status };
    if (std.mem.eql(u8, ep.path, "/api/v1/berry/scripts")) return .{ .op = .berry_list };
    if (std.mem.eql(u8, ep.path, "/api/v1/berry/scripts/{name}/run")) {
        const rest = req.path[scripts_prefix.len..];
        const name = rest[0 .. rest.len - "/run".len];
        if (!berry_store.validName(name)) return bad("invalid_script_name", "a script name is 1..32 of letters, digits, -, _ or .");
        // a run carries no source. accepting one would make this an eval route, and there
        // deliberately is not one -- see SECURITY.md.
        if (body.len != 0) return bad("unexpected_body", "a run takes no body; the stored script is what runs");
        return .{ .op = .{ .berry_run = .{ .name = name } } };
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/berry/scripts/{name}")) {
        const name = req.path["/api/v1/berry/scripts/".len..];
        if (!berry_store.validName(name)) return bad("invalid_script_name", "a name is 1 to 32 characters of letters, digits, dash, underscore and dot");
        if (req.method == .GET) return .{ .op = .{ .berry_get = .{ .name = name } } };
        if (req.method == .DELETE) return .{ .op = .{ .berry_delete = .{ .name = name } } };
        if (!isText(req.content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "a script is text/plain" } };
        if (body.len > berry_store.script_max) return .{ .reject = .{ .status = 413, .code = "body_too_large", .message = "a script is at most 8000 bytes" } };
        return .{ .op = .{ .berry_put = .{ .name = name, .source = body } } };
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
    if (std.mem.eql(u8, ep.path, "/api/v1/events")) return .{ .op = .events };
    if (std.mem.eql(u8, ep.path, "/api/v1/tokens")) {
        if (req.method == .GET) return .{ .op = .client_list };
        const b = json.parse(TokensBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
        if (!clients.validName(b.name)) return bad("invalid_name", "a name is 1..32 of letters, digits, -, _ or . and may not start with a dot");
        const scopes = switch (scopeSet(b.scopes)) {
            .set => |v| v,
            .err => |e| return switch (e) {
                .unknown => bad("invalid_scope", "scopes must be drawn from " ++ scope_names),
                .empty => bad("invalid_scope", "a token with no scopes could do nothing; name at least one"),
                .minting => bad("invalid_scope", "tokens is the admin token's alone: a token that could mint tokens could mint itself more"),
            },
        };
        return .{ .op = .{ .client_add = .{ .name = b.name, .scopes = scopes } } };
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/tokens/{name}/rotate")) {
        const rest = req.path[tokens_prefix.len..];
        const name = rest[0 .. rest.len - "/rotate".len];
        if (!clients.validName(name)) return bad("invalid_name", "a name is 1..32 of letters, digits, -, _ or . and may not start with a dot");
        // an empty body rotates the secret and leaves the scopes alone
        if (body.len == 0) return .{ .op = .{ .client_rotate = .{ .name = name, .scopes = null } } };
        const b = json.parse(RotateBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
        const scopes: ?clients.Set = if (b.scopes) |names| switch (scopeSet(names)) {
            .set => |v| v,
            .err => |e| return switch (e) {
                .unknown => bad("invalid_scope", "scopes must be drawn from " ++ scope_names),
                .empty => bad("invalid_scope", "a token with no scopes could do nothing; name at least one"),
                .minting => bad("invalid_scope", "tokens is the admin token's alone: a token that could mint tokens could mint itself more"),
            },
        } else null;
        return .{ .op = .{ .client_rotate = .{ .name = name, .scopes = scopes } } };
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/tokens/{name}")) {
        const name = req.path[tokens_prefix.len..];
        // control and admin are not clients: they are not in this namespace at all, so a request
        // to revoke one is a request about something that does not exist here.
        if (!clients.validName(name)) return bad("invalid_name", "a name is 1..32 of letters, digits, -, _ or . and may not start with a dot");
        return .{ .op = .{ .client_remove = .{ .name = name } } };
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/sounds")) return .{ .op = .sound_list };
    if (std.mem.eql(u8, ep.path, "/api/v1/sound")) return parseBody(.sound, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/sounds/{name}")) {
        const name = req.path[sounds_prefix.len..];
        if (!sound_store.validName(name)) return bad("invalid_name", "a sound name is 1..32 of letters, digits, -, _ or .");
        if (req.method == .DELETE) return .{ .op = .{ .sound_delete = .{ .name = name } } };
        const offset_text = queryValue(req.query, "offset") orelse "0";
        const offset = std.fmt.parseInt(u32, offset_text, 10) catch return bad("invalid_offset", "offset must be a byte count");
        if (body.len > sound_store.chunk_max) return bad("body_too_large", "a sound arrives in chunks of at most 4096 bytes");
        const final = std.mem.eql(u8, queryValue(req.query, "final") orelse "0", "1");
        return .{ .op = .{ .sound_put = .{ .name = name, .offset = offset, .final = final, .data = body } } };
    }
    if (std.mem.eql(u8, ep.path, "/api/v1/logs")) {
        const after_text = queryValue(req.query, "after") orelse "0";
        const after = std.fmt.parseInt(u32, after_text, 10) catch return bad("invalid_after", "after must be a sequence number");
        return .{ .op = .{ .logs = .{ .after = after } } };
    }
    if (std.mem.startsWith(u8, ep.path, "/api/v1/streams")) return .{ .op = if (req.method == .DELETE) .streams_delete else if (req.method == .PUT) .streams_palette else .streams_create };

    if (std.mem.eql(u8, ep.path, "/api/v1/frame")) {
        if (!isOctets(req.content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "frames are application/octet-stream" } };
        return parseFrame(req.query, body, generated_id);
    }
    // a reboot takes no body; an empty one or `{}` are the same request
    if (std.mem.eql(u8, ep.path, "/api/v1/reboot")) return .{ .op = .{ .reboot = .{ .request_id = generated_id } } };
    // everything below is json
    if (!isJson(req.content_type)) return .{ .reject = .{ .status = 415, .code = "unsupported_media_type", .message = "this route takes application/json" } };
    if (std.mem.eql(u8, ep.path, "/api/v1/scene")) return parseBody(.scene, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/action")) return parseBody(.action, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/notify/dismiss")) return parseBody(.dismiss_notify, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/notify")) return parseBody(.notify, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/config")) return parseBody(.config_patch, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/config/save")) return parseBody(.config_save, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/mqtt")) return parseBody(.mqtt_put, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/ntfy")) return parseBody(.ntfy_put, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/input")) return parseBody(.input, body, arena, generated_id);
    if (std.mem.eql(u8, ep.path, "/api/v1/canvas")) return parseBody(if (req.method == .PUT) .canvas_put else .canvas_patch, body, arena, generated_id);
    return .{ .reject = .{ .status = 404, .code = "not_found", .message = "no such route" } };
}

pub const BodyKind = enum { scene, action, notify, dismiss_notify, config_patch, config_save, mqtt_put, ntfy_put, input, canvas_put, canvas_patch, sound };

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
pub fn parseFrame(query: []const u8, body: []const u8, generated_id: u64) Route {
    if (body.len != geometry.rgb_bytes) return bad("invalid_frame", "a frame is exactly 2496 rgb888 bytes");
    const duration_text = queryValue(query, "duration_s") orelse return bad("missing_duration", "duration_s is required in the query");
    const duration = std.fmt.parseInt(u16, duration_text, 10) catch return bad("invalid_duration", "duration_s must be 1..300");
    if (duration < 1 or duration > 300) return bad("invalid_duration", "duration_s must be 1..300");
    const rid = if (queryValue(query, "request_id")) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
    var epoch: ?u32 = null;
    if (queryValue(query, "epoch")) |t| epoch = std.fmt.parseInt(u32, t, 10) catch return bad("invalid_epoch", "epoch must be a number");
    var ms: ?u32 = null;
    if (queryValue(query, "transition_ms")) |t| ms = std.fmt.parseInt(u32, t, 10) catch return bad("invalid_transition_ms", "transition_ms must be 0..5000");
    const spec = switch (parseTransition(queryValue(query, "transition"), queryValue(query, "direction"), ms, queryValue(query, "exit"), queryValue(query, "easing"), .cut)) {
        .reject => |j| return .{ .reject = j },
        .op => |t| t,
    };
    return .{ .op = .{ .frame = .{ .rgb = body[0..geometry.rgb_bytes], .duration_s = duration, .transition = spec, .request_id = rid, .epoch = epoch } } };
}

/// a json body for one of the schemas; shared by http routes and mqtt command topics.
pub fn parseBody(kind: BodyKind, body: []const u8, arena: *Arena, generated_id: u64) Route {
    // filled in by a failed body parse, so the rejection can name the field that was wrong
    var where = json.Where{};
    switch (kind) {
        .scene => {
            const b = json.parse(SceneBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            const base = parseBase(b.base) orelse return bad("invalid_base", base_names_message);
            const generator: ?scene.Generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null;
            const rid = if (b.request_id) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
            var style: ?clock.StylePatch = null;
            if (b.clock) |cb| {
                switch (parseClockStyle(cb.font, cb.colour_mode, cb.colour, cb.colour2, cb.gradient, cb.spread, cb.digits, cb.fade)) {
                    .reject => |j| return .{ .reject = j },
                    .op => |op| style = op,
                }
            }
            const spec = switch (parseTransition(b.transition, b.direction, b.transition_ms, b.exit, b.easing, .fade)) {
                .reject => |j| return .{ .reject = j },
                .op => |t| t,
            };
            return .{ .op = .{ .set_scene = .{ .base = base, .generator = generator, .seed = b.seed, .style = style, .transition = spec, .request_id = rid, .epoch = b.epoch } } };
        },
        .action => {
            const b = json.parse(ActionBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            const rid = if (b.request_id) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
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
            const b = json.parse(InputBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            const control = enumByName(actions.Control, b.control) orelse return bad("invalid_control", "control must be left, middle, right, knob or rotary");
            const event = enumByName(actions.InputRequest, b.event) orelse return bad("invalid_event", "event must be press, release, click, long, cw or ccw");
            const rotary = control == .rotary;
            const turning = event == .cw or event == .ccw;
            if (rotary != turning) return bad("invalid_event", "cw and ccw belong to the rotary; buttons take press, release, click or long");
            if (b.steps < 1 or b.steps > actions.max_steps) return bad("invalid_steps", "steps must be 1..16");
            if (b.steps != 1 and !turning) return bad("invalid_steps", "steps applies to cw and ccw only");
            const rid = if (b.request_id) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
            return .{ .op = .{ .input = .{ .control = control, .event = event, .steps = b.steps, .request_id = rid, .epoch = b.epoch } } };
        },
        .sound => {
            const b = json.parse(SoundBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            if (b.stop) |st| if (st) return .{ .op = .sound_stop };
            const name = b.name orelse return bad("missing_field", "name, or stop:true");
            if (!sound_store.validName(name)) return bad("invalid_name", "a sound name is 1..32 of letters, digits, -, _ or .");
            if (b.volume) |v| if (v < 1 or v > 100) return bad("invalid_volume", "volume must be 1..100");
            return .{ .op = .{ .sound_play = .{ .name = name, .volume = b.volume, .loop = b.loop orelse false } } };
        },
        .dismiss_notify => {
            const b = json.parse(DismissNotifyBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            if (b.name) |name| if (!arbiter.notification.validName(name)) return bad("invalid_name", "a notification name is 1..255 letters, digits, _ or -");
            const rid = if (b.request_id) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
            return .{ .op = .{ .dismiss_notify = .{ .name = b.name orelse "", .request_id = rid, .epoch = b.epoch } } };
        },
        .notify => {
            const b = json.parse(NotifyBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            if (b.name) |name| if (!arbiter.notification.validName(name)) return bad("invalid_name", "a notification name is 1..255 letters, digits, _ or -");
            // a document makes the text optional: it is then the summary the events carry
            var doc: ?canvas.Document = null;
            if (b.elements) |els| {
                if (els.len == 0) return bad("invalid_elements", "a rich notification has at least one element");
                var d = canvas.Document{};
                switch (parseCanvas(els, &d)) {
                    .reject => |j| return .{ .reject = j },
                    .op => |parsed| doc = parsed,
                }
            }
            const text = b.text orelse "";
            if (doc == null and text.len == 0) return bad("invalid_text", "text must be 1..128 printable ascii characters");
            if (text.len > 128) return bad("invalid_text", "text must be 1..128 printable ascii characters");
            for (text) |c| if (c < 0x20 or c > 0x7e) return bad("invalid_text", "text must be 1..128 printable ascii characters");
            if (b.duration_s < 1 or b.duration_s > 300) return bad("invalid_duration", "duration_s must be 1..300");
            const colour = if (b.colour) |c| (parseColour(c) orelse return bad("invalid_colour", "colour must be rrggbb hex")) else [3]u8{ 255, 255, 255 };
            const rid = if (b.request_id) |t| (parseRequestId(t) orelse return bad("invalid_request_id", "request_id must be 1..16 hex digits")) else generated_id;
            const spec = switch (parseTransition(b.transition, b.direction, b.transition_ms, b.exit, b.easing, .fade)) {
                .reject => |j| return .{ .reject = j },
                .op => |t| t,
            };
            return .{ .op = .{ .notify = .{ .text = text, .colour = colour, .duration_s = b.duration_s, .name = b.name orelse "", .stack = b.stack, .hold = b.hold, .transition = spec, .request_id = rid, .epoch = b.epoch, .doc = doc } } };
        },
        .config_patch => {
            const b = json.parse(ConfigBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            if (b.brightness) |v| if (v < 1 or v > 100) return bad("invalid_brightness", "brightness must be 1..100");
            if (b.timezone) |t| if (t.len == 0 or t.len > 64) return bad("invalid_timezone", "timezone must be 1..64 characters");
            if (b.ntp_interval_s) |v| if (v != 300 and v != 600) return bad("invalid_ntp_interval", "ntp_interval_s must be 300 or 600");
            if (b.frame_timeout_ms) |v| if (v < 100 or v > 2000) return bad("invalid_frame_timeout", "frame_timeout_ms must be 100..2000");
            if (b.metrics_interval_s) |v| if (v != 0 and (v < 10 or v > 3600)) return bad("invalid_metrics_interval", "metrics_interval_s must be 0 (off) or 10..3600");
            if (b.discovery_prefix) |p| if (p.len == 0 or p.len > 64) return bad("invalid_discovery_prefix", "discovery_prefix must be 1..64 characters");
            const ntp: ?[4]u8 = if (b.ntp_server) |s| (parseIpv4(s) orelse return bad("invalid_ntp_server", "ntp_server must be a dotted ipv4 address")) else null;
            const style = switch (parseClockStyle(b.clock_font, b.clock_colour_mode, b.clock_colour, b.clock_colour2, b.clock_gradient, b.clock_spread, b.clock_digit, b.clock_fade)) {
                .reject => |j| return .{ .reject = j },
                .op => |op| op,
            };
            const ip_mode: ?ip.Mode = if (b.ip_mode) |t| (enumByName(ip.Mode, t) orelse return bad("invalid_ip_mode", "ip_mode must be lines, mini, scroll or big")) else null;
            if (b.night_brightness) |v| if (v < 1 or v > 100) return bad("invalid_night_brightness", "night_brightness must be 1..100");
            if (b.night_lead_min) |v| if (v > max_night_lead_min) return bad("invalid_night_lead", "night_lead_min must be 0..120");
            if (b.berry_heap_kb) |v| if (v < berry_heap_kb_min or v > berry_heap_kb_max) return bad("invalid_berry_heap", "berry_heap_kb must be 16..256");
            if (b.battery_shutdown_mv) |v| if (v < battery_shutdown_mv_min or v > battery_shutdown_mv_max) return bad("invalid_battery_shutdown_mv", "battery_shutdown_mv must be 3000..4000");
            if (b.battery_grace_s) |v| if (v > battery_grace_s_max) return bad("invalid_battery_grace", "battery_grace_s must be 0..300");
            if (b.berry_handler_ms) |v| if (v < berry_handler_ms_min or v > berry_handler_ms_max) return bad("invalid_berry_handler", "berry_handler_ms must be 10..1000");
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
                .clock_fade = style.fade,
                .brightness = b.brightness,
                .base = if (b.base) |t| (parseBase(t) orelse return bad("invalid_base", base_names_message)) else null,
                .generator = if (b.generator) |g| (parseGenerator(g) orelse return bad("invalid_generator", "unknown generator")) else null,
                .timezone = b.timezone,
                .ntp_server = ntp,
                .ntp_interval_s = b.ntp_interval_s,
                .frame_timeout_ms = b.frame_timeout_ms,
                .metrics_interval_s = b.metrics_interval_s,
                .discovery = b.discovery,
                .discovery_controls = b.discovery_controls,
                .mdns = b.mdns,
                .discovery_prefix = b.discovery_prefix,
                .expected_revision = b.expected_revision,
                .night = b.night,
                .night_brightness = b.night_brightness,
                .night_lead_min = b.night_lead_min,
                .location = location,
                .location_auto = b.location_auto,
                .berry_enabled = b.berry_enabled,
                .berry_heap_kb = b.berry_heap_kb,
                .battery_shutdown = b.battery_shutdown,
                .battery_shutdown_mv = b.battery_shutdown_mv,
                .battery_grace_s = b.battery_grace_s,
                .berry_handler_ms = b.berry_handler_ms,
                .sound_enabled = b.sound_enabled,
                .sound_volume = b.sound_volume,
            } } };
        },
        .canvas_put => {
            const b = json.parse(CanvasBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            var doc = canvas.Document{};
            return switch (parseCanvas(b.elements, &doc)) {
                .reject => |j| .{ .reject = j },
                .op => |d| .{ .op = .{ .canvas_put = .{ .doc = d, .persist = b.persist } } },
            };
        },
        .canvas_patch => {
            const b = json.parse(PatchBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            return switch (parseCanvasPatch(b.values)) {
                .reject => |j| .{ .reject = j },
                .op => |p| .{ .op = .{ .canvas_patch = p } },
            };
        },
        .config_save => {
            const b = if (body.len == 0) SaveBody{} else json.parse(SaveBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            return .{ .op = .{ .config_save = .{ .revision = b.revision } } };
        },
        .mqtt_put => {
            const b = json.parse(MqttBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
            if (b.host) |h| if (h.len == 0 or h.len > 64 or parseIpv4(h) == null) return bad("invalid_host", "host must be a dotted ipv4 address in this profile");
            if (b.port) |p| if (p == 0) return bad("invalid_port", "port must be 1..65535");
            inline for (.{ "username", "password", "client_id", "prefix" }) |name| {
                if (@field(b, name)) |v| if (v.len > 64) return bad("invalid_" ++ name, name ++ " must be at most 64 characters");
            }
            return .{ .op = .{ .mqtt_put = .{ .enabled = b.enabled, .host = b.host, .port = b.port, .username = b.username, .password = b.password, .client_id = b.client_id, .prefix = b.prefix, .tls = b.tls } } };
        },
        .ntfy_put => {
            const b = json.parse(NtfyBody, body, arena, &where) catch |e| return jsonError(e, where, arena);
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

/// the clock style fields, shared by `/scene` and the settings patch.
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

fn parseClockStyle(font_text: ?[]const u8, mode_text: ?[]const u8, colour_text: ?[]const u8, colour2_text: ?[]const u8, gradient_text: ?[]const u8, spread: ?u8, digit_text: ?[]const u8, fade: ?bool) StyleRoute {
    var p = clock.StylePatch{ .spread = spread, .fade = fade };
    if (font_text) |s| p.font = enumByName(clock.Font, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_font", .message = font_names_message } };
    if (mode_text) |s| p.mode = enumByName(clock.ColourMode, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour_mode", .message = "colour_mode must be solid or gradient" } };
    if (colour_text) |s| p.colour = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour", .message = "colour must be rrggbb hex" } };
    if (colour2_text) |s| p.colour2 = parseColour(s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_colour2", .message = "colour2 must be rrggbb hex" } };
    if (gradient_text) |s| p.gradient = enumByName(clock.Gradient, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_gradient", .message = "gradient must be horizontal, vertical or diagonal" } };
    if (digit_text) |s| p.digit = enumByName(clock.DigitStyle, s) orelse return .{ .reject = .{ .status = 400, .code = "invalid_digits", .message = "digits must be solid, outline or shadow" } };
    return .{ .op = p };
}

/// the five transition fields shared by `/scene`, `/notify` and `/frame`: none given means the
/// renderer's default; an effect without a direction takes the effect's natural one; a
/// missing duration is 500 ms; a missing exit backs out the way it came; a missing easing is
/// linear.
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
fn parseTransition(effect_text: ?[]const u8, direction_text: ?[]const u8, ms: ?u32, exit_text: ?[]const u8, easing_text: ?[]const u8, natural: transition.Effect) TransitionRoute {
    if (effect_text == null and direction_text == null and ms == null and exit_text == null and easing_text == null) return .{ .op = null };
    const easing = if (easing_text) |t| (enumByName(transition.Easing, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_easing", .message = easing_names_message } }) else .linear;
    const exit = if (exit_text) |t| (enumByName(transition.Exit, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_exit", .message = "exit must be reverse, same or none" } }) else .reverse;
    const effect = if (effect_text) |t| (enumByName(transition.Effect, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_transition", .message = effect_names_message } }) else natural;
    const direction = if (direction_text) |t| (enumByName(transition.Direction, t) orelse return .{ .reject = .{ .status = 400, .code = "invalid_direction", .message = "direction must be left, right, up or down" } }) else effect.naturalDirection();
    if (ms) |v| if (v > transition.max_duration_ms) return .{ .reject = .{ .status = 400, .code = "invalid_transition_ms", .message = "transition_ms must be 0..5000" } };
    return .{ .op = .{ .effect = effect, .direction = direction, .duration_ns = if (ms) |v| @as(u64, v) * 1_000_000 else transition.default_duration_ns, .exit = exit, .easing = easing } };
}

const effect_names_message = "transition must be one of " ++ namesList(transition.Effect);
const easing_names_message = "easing must be one of " ++ namesList(transition.Easing);
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
    "{\"index\":2,\"name\":\"cube\",\"parameters\":" ++ paramsJson(&cube.params) ++ "}," ++
    "{\"index\":3,\"name\":\"terrain\",\"parameters\":" ++ paramsJson(&terrain.params) ++ "}]," ++
    "\"parameters\":{\"art\":" ++ paramsJson(&scene.art_params) ++ ",\"clock\":" ++ paramsJson(&clock.params) ++ ",\"canvas\":" ++ paramsJson(&canvas.params) ++ "}," ++
    "\"clock\":{\"fonts\":" ++ namesJson(clock.Font) ++ ",\"colour_modes\":[\"solid\",\"gradient\"],\"digits\":" ++ namesJson(clock.DigitStyle) ++ ",\"gradients\":[\"horizontal\",\"vertical\",\"diagonal\"],\"spread\":[0,255],\"max_spread\":255},\"ip\":{\"modes\":" ++ namesJson(ip.Mode) ++ "},\"notify\":{\"text_max\":128,\"duration_s\":[1,300]},\"frame\":{\"bytes\":2496,\"duration_s\":[1,300]},\"transitions\":{\"effects\":" ++ namesJson(transition.Effect) ++ ",\"directions\":" ++ namesJson(transition.Direction) ++ ",\"exits\":" ++ namesJson(transition.Exit) ++ ",\"easings\":" ++ namesJson(transition.Easing) ++ ",\"duration_ms\":[0,5000]}}";

// tests

fn testCreds() Credentials {
    var c: Credentials = undefined;
    @memset(&c.control, 0x11);
    @memset(&c.admin, 0x22);
    return c;
}

/// what netd would have minted for a request that carried no id of its own.
const test_minted: u64 = generated_mask | 0x5ee;
/// most route tests predate named clients and care only about the built-in tokens
const no_clients = clients.Store{};
const control_header = "Bearer " ++ "11" ** 32;
const admin_header = "Bearer " ++ "22" ** 32;

fn testReq(method: http.Method, path: []const u8, query: []const u8, auth: ?[]const u8, ct: ?[]const u8, origin: ?[]const u8) http.Request {
    return .{ .method = method, .path = path, .query = query, .authorization = auth, .content_type = ct, .origin = origin, .head_len = 0 };
}

test "notification queue options are accepted by the public route" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const r = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"door open\",\"name\":\"door\",\"stack\":true,\"hold\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(r == .op);
}

test "notification dismissal is accepted by the public route" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const r = route(testReq(.POST, "/api/v1/notify/dismiss", "", control_header, "application/json", null), "{\"name\":\"door\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(r == .op);
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

/// `expectReject`, and the message has to mention `says` -- for rejections whose whole point is
/// naming the field the client got wrong.
fn expectRejectSaying(r: Route, status: u16, code: []const u8, says: []const u8) !void {
    try expectReject(r, status, code);
    const m = r.reject.message;
    if (std.mem.indexOf(u8, m, says) == null) {
        std.debug.print("message \"{s}\" does not mention \"{s}\"\n", .{ m, says });
        return error.TestUnexpectedResult;
    }
}

test "the event stream is a control-authority get, and nothing else" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const r = route(testReq(.GET, "/api/v1/events", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(r == .op and r.op == .events);

    // reading every statement the device applies is a control-authority thing to do, and it is a
    // read: there is nothing to post to it
    try expectReject(route(testReq(.GET, "/api/v1/events", "", null, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 401, "unauthorized");
    try expectReject(route(testReq(.POST, "/api/v1/events", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 405, "method_not_allowed");
}

test "the sound routes: reads are control, writing a sound is admin" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};

    const list = route(testReq(.GET, "/api/v1/sounds", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(list == .op and list.op == .sound_list);

    // storing a sound is admin, for the same reason a script is: it plays on a device somebody
    // lives with, long after the request that stored it
    try expectReject(route(testReq(.PUT, "/api/v1/sounds/chime", "offset=0", control_header, "application/octet-stream", null), "RIFF", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.DELETE, "/api/v1/sounds/chime", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");

    const put = route(testReq(.PUT, "/api/v1/sounds/chime", "offset=0", admin_header, "application/octet-stream", null), "RIFF", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(put == .op and put.op == .sound_put);
    try std.testing.expectEqualStrings("chime", put.op.sound_put.name);
    try std.testing.expectEqual(@as(u32, 0), put.op.sound_put.offset);
    try std.testing.expect(!put.op.sound_put.final);
    try std.testing.expectEqualStrings("RIFF", put.op.sound_put.data);
}

test "an upload names the offset it believes it is at, and says when it is done" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};

    const mid = route(testReq(.PUT, "/api/v1/sounds/chime", "offset=4096", admin_header, "application/octet-stream", null), "abcd", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(u32, 4096), mid.op.sound_put.offset);
    try std.testing.expect(!mid.op.sound_put.final);

    const last = route(testReq(.PUT, "/api/v1/sounds/chime", "offset=8192&final=1", admin_header, "application/octet-stream", null), "z", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(last.op.sound_put.final);

    // an offset that is not a number is refused rather than treated as zero, which would silently
    // overwrite the beginning of the sound
    try expectReject(route(testReq(.PUT, "/api/v1/sounds/chime", "offset=x", admin_header, "application/octet-stream", null), "a", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_offset");
    // and a name that is not a name
    try expectReject(route(testReq(.PUT, "/api/v1/sounds/has%20space", "offset=0", admin_header, "application/octet-stream", null), "a", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_name");
}

test "playing a sound is control, and stopping needs no name" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const play = route(testReq(.POST, "/api/v1/sound", "", control_header, "application/json", null), "{\"name\":\"chime\",\"volume\":80,\"loop\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(play == .op and play.op == .sound_play);
    try std.testing.expectEqualStrings("chime", play.op.sound_play.name);
    try std.testing.expectEqual(@as(?u8, 80), play.op.sound_play.volume);
    try std.testing.expect(play.op.sound_play.loop);

    const stop = route(testReq(.POST, "/api/v1/sound", "", control_header, "application/json", null), "{\"stop\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(stop == .op and stop.op == .sound_stop);

    try expectReject(route(testReq(.POST, "/api/v1/sound", "", control_header, "application/json", null), "{\"name\":\"chime\",\"volume\":0}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_volume");
}

test "authentication is constant-time bearer matching of either token" {
    const c = testCreds();
    try std.testing.expectEqual(control_scopes, authenticate(&c, &no_clients, control_header).scopes);
    try std.testing.expectEqual(admin_scopes, authenticate(&c, &no_clients, admin_header).scopes);
    try std.testing.expectEqual(@as(clients.Set, 0), authenticate(&c, &no_clients, null).scopes);
    try std.testing.expectEqual(@as(clients.Set, 0), authenticate(&c, &no_clients, "Bearer " ++ "11" ** 31 ++ "12").scopes);
    try std.testing.expectEqual(@as(clients.Set, 0), authenticate(&c, &no_clients, "Basic " ++ "11" ** 32).scopes);
    try std.testing.expectEqual(@as(clients.Set, 0), authenticate(&c, &no_clients, "Bearer zz" ++ "11" ** 31).scopes);
}

test "status codes: origin, route, method, credentials, authority" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    try expectReject(route(testReq(.GET, "/api/v1/status", "", control_header, null, "http://evil"), "", &c, &no_clients, &origins, &arena, test_minted), 403, "origin_denied");
    origins.allowed[0] = "http://panel";
    origins.count = 1;
    try std.testing.expect(route(testReq(.GET, "/api/v1/status", "", control_header, null, "http://panel"), "", &c, &no_clients, &origins, &arena, test_minted) == .op);
    try expectReject(route(testReq(.GET, "/api/v1/nope", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 404, "not_found");
    try expectReject(route(testReq(.DELETE, "/api/v1/status", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 405, "method_not_allowed");
    try expectReject(route(testReq(.GET, "/api/v1/status", "", null, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 401, "unauthorized");
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", control_header, "application/json", null), "{}", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
    try std.testing.expect(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{}", &c, &no_clients, &origins, &arena, test_minted) == .op);
    try std.testing.expect(route(testReq(.GET, "/api/v1/status", "", admin_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .status);
}

test "transition fields become a spec with the effect's natural direction and 500 ms" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const s = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"transition\":\"swipe_in\",\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .swipe_in, .direction = .left, .duration_ns = 500_000_000 }, s.op.set_scene.transition.?);
    const n = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"rain\",\"transition_ms\":1200}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .rain, .direction = .down, .duration_ns = 1_200_000_000 }, n.op.notify.transition.?);
    const d = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"direction\":\"up\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .fade, .direction = .up, .duration_ns = 500_000_000 }, d.op.notify.transition.?);
    const none = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(none.op.notify.transition == null);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"warp\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_transition");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"direction\":\"sideways\",\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_direction");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"transition_ms\":5001,\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_transition_ms");
    const frame = [_]u8{7} ** geometry.rgb_bytes;
    const f = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition=expand&transition_ms=0", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .expand, .direction = .left, .duration_ns = 0 }, f.op.frame.transition.?);
    const plain = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(plain.op.frame.transition == null);
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition_ms=x", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_transition_ms");
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"transitions\":{\"effects\":[\"fade\",\"cut\",\"slide\",\"swipe_out\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, scenes_body, "\"directions\":[\"left\",\"right\",\"up\",\"down\"],\"exits\":[\"reverse\",\"same\",\"none\"],\"easings\":[\"linear\",\"ease_in\",\"ease_out\",\"ease_in_out\"],\"duration_ms\":[0,5000]}}"));
    const e = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"swipe_in\",\"exit\":\"same\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Exit.same, e.op.notify.transition.?.exit);
    try std.testing.expectEqual(transition.Exit.reverse, n.op.notify.transition.?.exit);
    const only_exit = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"exit\":\"none\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .fade, .direction = .left, .duration_ns = 500_000_000, .exit = .none }, only_exit.op.notify.transition.?);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"exit\":\"back\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_exit");
    const fe = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&transition=slide&exit=none", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Exit.none, fe.op.frame.transition.?.exit);
}

test "easing is one more optional transition field on scenes, notifications and frames" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const s = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"transition\":\"ripple\",\"easing\":\"ease_out\",\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .ripple, .direction = .left, .duration_ns = 500_000_000, .easing = .ease_out }, s.op.set_scene.transition.?);
    const n = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"easing\":\"ease_in_out\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .fade, .direction = .left, .duration_ns = 500_000_000, .easing = .ease_in_out }, n.op.notify.transition.?);
    const r = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"transition\":\"random\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .random, .direction = .left, .duration_ns = 500_000_000 }, r.op.notify.transition.?);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"easing\":\"bouncy\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_easing");
    const frame = [_]u8{7} ** geometry.rgb_bytes;
    const f = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&easing=ease_in", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(transition.Spec{ .effect = .cut, .direction = .left, .easing = .ease_in }, f.op.frame.transition.?);
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1&easing=x", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_easing");
}

test "the ip layout is a setting only: there is no ip base to put it on" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    // the scene retired when the canvas took the third button; the address moved to the device menu
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"ip\",\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_base");
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"base\":\"ip\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_base");
    const canvas_base = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"canvas\",\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(Base.canvas, canvas_base.op.set_scene.base);
    // but the layout itself is untouched: same key, same four values, and the catalogue still
    // publishes them from the enum, independently of the base list
    const cp = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ip_mode\":\"mini\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(ip.Mode.mini, cp.op.config_patch.ip_mode.?);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ip_mode\":\"huge\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_ip_mode");
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"ip\":{\"modes\":[\"lines\",\"mini\",\"scroll\",\"big\"]}") != null);
    try std.testing.expect(std.mem.startsWith(u8, scenes_body, "{\"bases\":[\"clock\",\"art\",\"canvas\"],"));
    try std.testing.expect(std.mem.indexOf(u8, scenes_body, "\"canvas\":[]") != null); // the canvas declares nothing yet
}

test "ntfy settings are admin-only and validated" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const p = route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"enabled\":true,\"url\":\"https://ntfy.sh\",\"topic\":\"tc002-alerts\",\"token\":\"tk_abc\",\"duration_s\":12,\"ca\":\"-----BEGIN CERTIFICATE-----\\nAA==\\n-----END CERTIFICATE-----\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("tc002-alerts", p.op.ntfy_put.topic.?);
    try std.testing.expectEqual(@as(?u16, 12), p.op.ntfy_put.duration_s);
    try std.testing.expect(p.op.ntfy_put.ca.?.len > 20);
    try std.testing.expect(route(testReq(.GET, "/api/v1/ntfy", "", admin_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .ntfy_get);
    try expectReject(route(testReq(.GET, "/api/v1/ntfy", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"url\":\"ntfy.sh\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_url");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"topic\":\"has space\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_topic");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"duration_s\":0}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_duration");
    try expectReject(route(testReq(.PUT, "/api/v1/ntfy", "", admin_header, "application/json", null), "{\"ca\":\"not a pem\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_ca");
}

test "notify and scene bodies become typed operations with validation" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const r = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json; charset=utf-8", null), "{\"text\":\"hello\",\"colour\":\"#ff8000\",\"duration_s\":30,\"request_id\":\"a1b2\",\"epoch\":3}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("hello", r.op.notify.text);
    try std.testing.expectEqual([3]u8{ 0xff, 0x80, 0x00 }, r.op.notify.colour);
    try std.testing.expectEqual(@as(u64, 0xa1b2), r.op.notify.request_id);
    try std.testing.expectEqual(@as(u32, 3), r.op.notify.epoch);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "text/plain", null), "{}", &c, &no_clients, &origins, &arena, test_minted), 415, "unsupported_media_type");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"extra\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "unknown_field");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"1\",\"epoch\":1,\"duration_s\":301}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_duration");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"zz\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_request_id");
    const s = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"art\",\"generator\":\"plasma\",\"seed\":9,\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(Base.art, s.op.set_scene.base);
    try std.testing.expectEqual(scene.Generator.plasma, s.op.set_scene.generator.?);
    try std.testing.expectEqual(@as(?u32, null), s.op.set_scene.epoch);
    try std.testing.expect(s.op.set_scene.style == null);
    const cs = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"big\",\"colour_mode\":\"gradient\",\"colour\":\"ff8000\",\"colour2\":\"#ffc000\"},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(clock.Font.big, cs.op.set_scene.style.?.font.?);
    try std.testing.expectEqual(clock.ColourMode.gradient, cs.op.set_scene.style.?.mode.?);
    try std.testing.expectEqual([3]u8{ 0xff, 0xc0, 0x00 }, cs.op.set_scene.style.?.colour2.?);
    try std.testing.expect(cs.op.set_scene.style.?.gradient == null);
    try std.testing.expect(cs.op.set_scene.style.?.spread == null);
    const sp = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"block\",\"spread\":120},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(clock.Font.block, sp.op.set_scene.style.?.font.?);
    const sm = route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"fade\":true},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?bool, true), sm.op.set_scene.style.?.fade);
    try std.testing.expectEqual(@as(?clock.Font, null), sm.op.set_scene.style.?.font);
    try std.testing.expectEqual(@as(?u8, 120), sp.op.set_scene.style.?.spread);
    // 300 does not fit spread's u8; the rejection says which field, not just "not valid json"
    try expectRejectSaying(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"spread\":300},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "spread");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"font\":\"comic\"},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_font");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"gradient\":\"radial\"},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_gradient");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", control_header, "application/json", null), "{\"base\":\"clock\",\"clock\":{\"colour\":\"red\"},\"request_id\":\"7\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_colour");
    const a = route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"brightness\",\"brightness\":40,\"request_id\":\"8\",\"epoch\":2}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(ActionKind.brightness, a.op.action.kind);
    const pw = route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"power\",\"power\":false,\"request_id\":\"9\",\"epoch\":2}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(ActionKind.power, pw.op.action.kind);
    try std.testing.expectEqual(@as(?bool, false), pw.op.action.power);
    try expectReject(route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"power\",\"request_id\":\"9\",\"epoch\":2}", &c, &no_clients, &origins, &arena, test_minted), 400, "missing_power");
    try expectReject(route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"brightness\",\"brightness\":0,\"request_id\":\"8\",\"epoch\":2}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_brightness");
}

test "frames are raw octets with query parameters; oversized json is 413" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const frame = [_]u8{7} ** geometry.rgb_bytes;
    const r = route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(u16, 5), r.op.frame.duration_s);
    try std.testing.expectEqual(@as(u8, 7), r.op.frame.rgb[100]);
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=ab&epoch=1", control_header, "application/octet-stream", null), frame[0..100], &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_frame");
    try expectReject(route(testReq(.POST, "/api/v1/frame", "request_id=ab&epoch=1", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, test_minted), 400, "missing_duration");
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5", control_header, "application/json", null), &frame, &c, &no_clients, &origins, &arena, test_minted), 415, "unsupported_media_type");
    const big = [_]u8{' '} ** (json.max_body + 1);
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), &big, &c, &no_clients, &origins, &arena, test_minted), 413, "body_too_large");
}

test "the night schedule's fields, and a location that has to arrive in one piece" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const req = testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null);
    const p = route(req, "{\"night\":true,\"night_brightness\":8,\"night_lead_min\":45,\"latitude\":-33.87,\"longitude\":151.215}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?bool, true), p.op.config_patch.night);
    try std.testing.expectEqual(@as(?u8, 8), p.op.config_patch.night_brightness);
    try std.testing.expectEqual(@as(?u8, 45), p.op.config_patch.night_lead_min);
    try std.testing.expectEqual(@as(i16, -3387), p.op.config_patch.location.?.lat_c);
    try std.testing.expectEqual(@as(i16, 15122), p.op.config_patch.location.?.lon_c); // rounded, not truncated
    const off = route(req, "{\"night\":false,\"location_auto\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?bool, false), off.op.config_patch.night);
    try std.testing.expectEqual(@as(?bool, true), off.op.config_patch.location_auto);
    try std.testing.expect(off.op.config_patch.location == null);

    try expectReject(route(req, "{\"night_brightness\":0}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_night_brightness");
    try expectReject(route(req, "{\"night_brightness\":101}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_night_brightness");
    try expectReject(route(req, "{\"night_lead_min\":121}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_night_lead");
    try expectReject(route(req, "{\"latitude\":-33.87}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_location");
    try expectReject(route(req, "{\"longitude\":151.21}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_location");
    try expectReject(route(req, "{\"latitude\":-91,\"longitude\":0}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_latitude");
    try expectReject(route(req, "{\"latitude\":0,\"longitude\":181}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_longitude");
}

test "config, mqtt and streams routes" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const p = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"brightness\":30,\"timezone\":\"AEST-10AEDT,M10.1.0,M4.1.0/3\",\"ntp_server\":\"10.0.0.5\",\"ntp_interval_s\":300,\"expected_revision\":4}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?u8, 30), p.op.config_patch.brightness);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 5 }, p.op.config_patch.ntp_server.?);
    try std.testing.expectEqual(@as(?u32, 4), p.op.config_patch.expected_revision);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"ntp_server\":\"time.example\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_ntp_server");
    const cp = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_font\":\"segment\",\"clock_colour_mode\":\"gradient\",\"clock_colour\":\"00ff80\",\"clock_gradient\":\"vertical\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(clock.Font.segment, cp.op.config_patch.clock_font.?);
    try std.testing.expectEqual(clock.Gradient.vertical, cp.op.config_patch.clock_gradient.?);
    try std.testing.expect(cp.op.config_patch.clock_colour2 == null);
    const sp2 = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_spread\":64,\"timezone\":\"Europe/Amsterdam\"}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?u8, 64), sp2.op.config_patch.clock_spread);
    const sm2 = route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_fade\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(?bool, true), sm2.op.config_patch.clock_fade);
    try std.testing.expectEqual(@as(?bool, null), sp2.op.config_patch.clock_fade);
    try std.testing.expectEqualStrings("Europe/Amsterdam", sp2.op.config_patch.timezone.?);
    try expectReject(route(testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null), "{\"clock_colour_mode\":\"rainbow\"}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_colour_mode");
    try std.testing.expect(route(testReq(.POST, "/api/v1/config/save", "", admin_header, "application/json", null), "", &c, &no_clients, &origins, &arena, test_minted).op == .config_save);
    // a reboot is its own route with its own scope: the admin token has it, control does not, and
    // an empty body or `{}` both do. it is not a body kind, so mqtt's command parser cannot reach it
    try std.testing.expect(route(testReq(.POST, "/api/v1/reboot", "", admin_header, "application/json", null), "", &c, &no_clients, &origins, &arena, test_minted).op == .reboot);
    try std.testing.expect(route(testReq(.POST, "/api/v1/reboot", "", admin_header, "application/json", null), "{}", &c, &no_clients, &origins, &arena, test_minted).op == .reboot);
    try expectReject(route(testReq(.POST, "/api/v1/reboot", "", control_header, "application/json", null), "", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.POST, "/api/v1/reboot", "", null, "application/json", null), "", &c, &no_clients, &origins, &arena, test_minted), 401, "unauthorized");
    try expectReject(route(testReq(.GET, "/api/v1/reboot", "", admin_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 405, "method_not_allowed");
    const m = route(testReq(.PUT, "/api/v1/mqtt", "", admin_header, "application/json", null), "{\"host\":\"10.0.0.2\",\"port\":1883,\"username\":\"tc002\",\"password\":\"Secret1\",\"enabled\":true}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("Secret1", m.op.mqtt_put.password.?);
    try expectReject(route(testReq(.GET, "/api/v1/mqtt", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
    try std.testing.expect(route(testReq(.GET, "/api/v1/mqtt/status", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .mqtt_status);
    try std.testing.expect(route(testReq(.POST, "/api/v1/streams", "", control_header, "application/json", null), "{}", &c, &no_clients, &origins, &arena, test_minted).op == .streams_create);
    try std.testing.expect(route(testReq(.DELETE, "/api/v1/streams/abcd", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .streams_delete);
    try std.testing.expect(route(testReq(.PUT, "/api/v1/streams/abcd/palette", "", control_header, "application/octet-stream", null), "", &c, &no_clients, &origins, &arena, test_minted).op == .streams_palette);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 111 }, parseIpv4("10.0.0.111").?);
    try std.testing.expect(parseIpv4("10.0.0") == null);
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
}

test "screen, logs and input routes" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    try std.testing.expect(!route(testReq(.GET, "/api/v1/screen", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op.screen.raw);
    try std.testing.expect(route(testReq(.GET, "/api/v1/screen", "format=raw", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op.screen.raw);
    try expectReject(route(testReq(.GET, "/api/v1/screen", "format=png", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_format");
    try std.testing.expectEqual(@as(u32, 0), route(testReq(.GET, "/api/v1/logs", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op.logs.after);
    try std.testing.expectEqual(@as(u32, 41), route(testReq(.GET, "/api/v1/logs", "after=41", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op.logs.after);
    try expectReject(route(testReq(.GET, "/api/v1/logs", "after=x", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_after");
    try expectReject(route(testReq(.GET, "/api/v1/logs", "", null, null, null), "", &c, &no_clients, &origins, &arena, test_minted), 401, "unauthorized");
    const i = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"ccw\",\"steps\":3,\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(actions.Control.rotary, i.op.input.control);
    try std.testing.expectEqual(actions.InputRequest.ccw, i.op.input.event);
    try std.testing.expectEqual(@as(u8, 3), i.op.input.steps);
    const k = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"knob\",\"event\":\"long\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(actions.InputRequest.long, k.op.input.event);
    try std.testing.expectEqual(@as(u8, 1), k.op.input.steps);
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"left\",\"event\":\"cw\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_event");
    // a long press is no longer the knob's alone: every button reports one, so the route takes one
    const l = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"left\",\"event\":\"long\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(actions.Control.left, l.op.input.control);
    try std.testing.expectEqual(actions.InputRequest.long, l.op.input.event);
    // but the rotary is a dial: it has nothing to hold
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"long\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_event");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"click\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_event");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"middle\",\"event\":\"click\",\"steps\":2,\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_steps");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"rotary\",\"event\":\"cw\",\"steps\":17,\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_steps");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"pedal\",\"event\":\"click\",\"request_id\":\"c\",\"epoch\":1}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_control");
}

test "a turn asked for over the api arrives at the arbiter whole" {
    // the route, the mapper and the arbiter in one line, because the bound that matters is the
    // one that spans them: the body says how many detents, the mapper turns them into actions and
    // the arbiter walks a page per action. the queue between the last two used to be shorter than
    // the number the route accepts, so a turn was answered `applied` and half of it thrown away.
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const body = "{\"control\":\"rotary\",\"event\":\"cw\",\"steps\":16,\"request_id\":\"c\",\"epoch\":1}";
    const r = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), body, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqual(@as(u8, actions.max_steps), r.op.input.steps);

    var m = actions.Mapper.init(.{});
    var queue = actions.ActionQueue{};
    var edges = actions.EdgeQueue{};
    try std.testing.expect(m.inject(r.op.input.control, r.op.input.event, r.op.input.steps, 0, &queue, &edges));
    try std.testing.expectEqual(@as(u32, 0), queue.dropped);

    var a = arbiter.Arbiter.init(.art, .popsquares, 1, @import("../scene/tz.zig").utc);
    const before = a.revision;
    for (queue.slice()) |act| a.action(act, 0);
    // one revision per detent: the art base pages through its generators, and every page is a
    // statement of its own
    try std.testing.expectEqual(@as(u32, before + actions.max_steps), a.revision);
}

test "samples given as a json string are refused, rather than read as the bytes of the digits" {
    // zig's json parser fills a `[]const u8` from a json *string* exactly as readily as from an
    // array of numbers, so `{"data":"1,2,3"}` used to become five samples of 49,44,50,44,51 -- the
    // digits and the commas -- and drew a plausible-looking wrong picture. anything hand-rolling
    // json falls into this, and a silent wrong answer is the worst kind. `data_hex` is the
    // supported way to carry samples as a string.
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const put = testReq(.PUT, "/api/v1/canvas", "", admin_header, "application/json", null);
    try expectReject(route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data\":\"1,2,3\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_data");
    // the same trap on the patch route, which takes samples by element id
    const patch = testReq(.PATCH, "/api/v1/canvas", "", admin_header, "application/json", null);
    try expectReject(route(patch, "{\"values\":[{\"id\":\"g\",\"data\":\"1,2,3\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_data");
    // and a list of numbers still parses
    const good = route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data\":[1,2,3]}]}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, good.op.canvas_put.doc.dataOf(good.op.canvas_put.doc.elements[0].body.sparkline.span));
}

test "a number the schema cannot hold names the field it was given for" {
    // out of range or fractional numbers used to answer `invalid_json`, "the body is not valid
    // json for this schema" -- which names neither the field nor what was wrong with it. the
    // parser knows where it gave up, so the field it was inside is worth saying out loud.
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const put = testReq(.PUT, "/api/v1/canvas", "", admin_header, "application/json", null);
    try expectRejectSaying(route(put, "{\"elements\":[{\"type\":\"circle\",\"r\":300}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "r");
    try expectRejectSaying(route(put, "{\"elements\":[{\"type\":\"circle\",\"r\":-3}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "r");
    try expectRejectSaying(route(put, "{\"elements\":[{\"type\":\"circle\",\"r\":2.5}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_not_whole", "r");
    // a number nested inside a list still names the field that holds the list
    try expectRejectSaying(route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data\":[1,2,300]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "data");
    try expectRejectSaying(route(put, "{\"elements\":[{\"type\":\"rect\",\"at\":[0,40000]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "at");
    // not canvas-specific: every body's numbers go through the same parser
    const cfg = testReq(.PATCH, "/api/v1/config", "", admin_header, "application/json", null);
    try expectRejectSaying(route(cfg, "{\"brightness\":900}", &c, &no_clients, &origins, &arena, test_minted), 400, "value_out_of_range", "brightness");
    // a syntax error has no field to name and keeps the message it had
    try expectReject(route(put, "{\"elements\":[{\"type\":\"circle\",", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_json");
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
    , &c, &no_clients, &origins, &arena, test_minted);
    const d = r.op.canvas_put.doc;
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
    const hexed = route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data_hex\":\"01090f\"}]}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 9, 15 }, hexed.op.canvas_put.doc.dataOf(hexed.op.canvas_put.doc.elements[0].body.sparkline.span));

    // a field that does not belong to the type is a mistake worth hearing about
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"text\":\"hi\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_field");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"bar\",\"r\":4}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_field");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"filled\":true}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_field");
    // and so is a nonsense value
    try expectReject(route(put, "{\"elements\":[{\"type\":\"blob\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_type");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "missing_text");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"line\",\"at\":[0,0]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "missing_to");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"font\":\"comic\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_font");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"colour\":\"nope\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_colour");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"id\":\"far_too_long\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_id");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"sparkline\",\"data_hex\":\"abc\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_data");
    // placement: one way or the other, not both, and `of` means nothing alone
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"tile\":1,\"of\":3,\"at\":[0,0]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"tile\":1}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"of\":3}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_placement");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"size\":[-1,4]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_placement");
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
    , &c, &no_clients, &origins, &arena, test_minted);
    const d = r.op.canvas_put.doc;
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
    const r = route(patch, "{\"values\":[{\"id\":\"t\",\"text\":\"21.1C\"},{\"id\":\"g\",\"data\":[4,5]},{\"id\":\"b\",\"value\":70,\"colour\":\"00ff00\"}]}", &c, &no_clients, &origins, &arena, test_minted);
    const p = r.op.canvas_patch;
    try std.testing.expectEqual(@as(u8, 3), p.count);
    try std.testing.expectEqualStrings("21.1C", p.items[0].slice());
    try std.testing.expectEqual(canvas.Field.text, p.items[0].has);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 4, 5 }, p.items[1].slice());
    try std.testing.expectEqual(canvas.Field.value | canvas.Field.colour, p.items[2].has);
    try std.testing.expectEqual(@as(u8, 70), p.items[2].value);

    try expectReject(route(patch, "{\"values\":[{\"id\":\"t\"}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "empty_value");
    try expectReject(route(patch, "{\"values\":[{\"id\":\"\",\"value\":1}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_id");
    try expectReject(route(patch, "{\"values\":[{\"id\":\"t\",\"text\":\"x\",\"data\":[1]}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_element_field");

    // reading is control, replacing the whole document is admin
    try std.testing.expect(route(testReq(.GET, "/api/v1/canvas", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .canvas_get);
    try std.testing.expect(route(testReq(.DELETE, "/api/v1/canvas", "", control_header, null, null), "", &c, &no_clients, &origins, &arena, test_minted).op == .canvas_clear);
    try expectReject(route(testReq(.PUT, "/api/v1/canvas", "", control_header, "application/json", null), "{\"elements\":[]}", &c, &no_clients, &origins, &arena, test_minted), 403, "forbidden");
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
    , &c, &no_clients, &origins, &arena, test_minted);
    const d = r.op.canvas_put.doc;
    try std.testing.expectEqual(canvas.Motion.scramble, d.elements[0].anim.kind);
    try std.testing.expectEqual(@as(u16, 600), d.elements[0].anim.ms);
    try std.testing.expectEqual(@as(u16, 8000), d.elements[1].anim.ms); // a hue turns slowly by default
    try std.testing.expect(d.elements[2].anim.axis_x);
    try std.testing.expectEqual(@as(u8, 50), d.elements[2].anim.phase);
    try std.testing.expectEqual(canvas.Motion.sweep, d.elements[3].anim.kind);

    // a motion that cannot mean anything for that element is refused rather than ignored
    try expectReject(route(put, "{\"elements\":[{\"type\":\"rect\",\"animate\":{\"kind\":\"scramble\"}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"text\",\"text\":\"x\",\"animate\":{\"kind\":\"sweep\"}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"wobble\"}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"none\"}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"blink\",\"ms\":0}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"blink\",\"phase\":101}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
    try expectReject(route(put, "{\"elements\":[{\"type\":\"pixel\",\"animate\":{\"kind\":\"bounce\",\"axis\":\"z\"}}]}", &c, &no_clients, &origins, &arena, test_minted), 400, "invalid_motion");
}

test "a command without a request id or an epoch is accepted and given a minted id" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const minted: u64 = generated_mask | 9;

    // the shape an apple shortcut or a one-line curl actually sends: no ceremony at all.
    const n = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"bins out\"}", &c, &no_clients, &origins, &arena, minted);
    try std.testing.expectEqualStrings("bins out", n.op.notify.text);
    try std.testing.expectEqual(minted, n.op.notify.request_id);
    try std.testing.expectEqual(@as(?u32, null), n.op.notify.epoch);

    const p = route(testReq(.POST, "/api/v1/action", "", control_header, "application/json", null), "{\"action\":\"power\",\"power\":false}", &c, &no_clients, &origins, &arena, minted);
    try std.testing.expectEqual(ActionKind.power, p.op.action.kind);
    try std.testing.expectEqual(false, p.op.action.power.?);
    try std.testing.expectEqual(minted, p.op.action.request_id);
    try std.testing.expectEqual(@as(?u32, null), p.op.action.epoch);

    const i = route(testReq(.POST, "/api/v1/input", "", control_header, "application/json", null), "{\"control\":\"middle\",\"event\":\"click\"}", &c, &no_clients, &origins, &arena, minted);
    try std.testing.expectEqual(minted, i.op.input.request_id);
    try std.testing.expectEqual(@as(?u32, null), i.op.input.epoch);

    var frame: [geometry.rgb_bytes]u8 = undefined;
    const f = route(testReq(.POST, "/api/v1/frame", "duration_s=5", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, minted);
    try std.testing.expectEqual(minted, f.op.frame.request_id);
    try std.testing.expectEqual(@as(?u32, null), f.op.frame.epoch);
}

test "an id or epoch that is present but malformed is still refused" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const minted: u64 = generated_mask | 1;
    // omitting a field asks the device to choose; sending rubbish is still a client error.
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"zz\"}", &c, &no_clients, &origins, &arena, minted), 400, "invalid_request_id");
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"text\":\"x\",\"request_id\":\"\"}", &c, &no_clients, &origins, &arena, minted), 400, "invalid_request_id");
    var frame: [geometry.rgb_bytes]u8 = undefined;
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&request_id=zz", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, minted), 400, "invalid_request_id");
    try expectReject(route(testReq(.POST, "/api/v1/frame", "duration_s=5&epoch=x", control_header, "application/octet-stream", null), &frame, &c, &no_clients, &origins, &arena, minted), 400, "invalid_epoch");
}

test "a minted id cannot collide with the small ids a person picks by hand" {
    // the renderer's dedup window matches on the id alone, so a minted id landing on one a client
    // chose would hand that client somebody else's result. the reserved top bit makes it impossible
    // for every id a human or a counter would produce.
    try std.testing.expect(generated_mask | 1 > std.math.maxInt(u63));
    var i: u64 = 0;
    while (i < 4096) : (i += 1) try std.testing.expect(parseRequestId(std.fmt.bufPrint(&idbuf, "{x}", .{i}) catch unreachable).? != (generated_mask | i));
}
var idbuf: [16]u8 = undefined;

/// the endpoint table entry for a method and path, for tests that assert how a route is classified
fn endpointFor(method: http.Method, path: []const u8) ?Endpoint {
    for (endpoints) |ep| if (ep.method == method and std.mem.eql(u8, ep.path, path)) return ep;
    return null;
}

test "a route asks for one bit, and a token either holds it or does not" {
    // there is no ladder any more: holding `settings` does not imply `notify`, and that is the
    // whole point -- a token can be given exactly one job.
    const only_notify = clients.Scope.notify.bit();
    try std.testing.expect(sufficient(only_notify, .notify));
    try std.testing.expect(!sufficient(only_notify, .status));
    try std.testing.expect(!sufficient(only_notify, .display));
    try std.testing.expect(sufficient(admin_scopes, .tokens));
    try std.testing.expect(!sufficient(control_scopes, .tokens));
    // the shared control secret operates the device but does not reconfigure or store
    try std.testing.expect(sufficient(control_scopes, .input));
    try std.testing.expect(!sufficient(control_scopes, .settings));
    try std.testing.expect(!sufficient(control_scopes, .scripts));
    try std.testing.expect(!sufficient(control_scopes, .content));
    try std.testing.expect(sufficient(control_scopes, .notify));
    try std.testing.expect(!sufficient(0, .status));
}

test "status covers observing a clock, and the other reads have scopes of their own" {
    // an explicit list, not "every get": the exclusions below are the whole point of one.
    for ([_][]const u8{
        "/api/v1/status",        "/api/v1/scenes",      "/api/v1/config",
        "/api/v1/canvas",        "/api/v1/icons",       "/api/v1/sprites",
        "/api/v1/sounds",        "/api/v1/mqtt/status", "/api/v1/berry",
        "/api/v1/berry/scripts",
    }) |p| {
        try std.testing.expectEqual(clients.Scope.status, endpointFor(.GET, p).?.scope);
    }
    // and the reads that are not "observing a clock" have scopes of their own: the log ring is a
    // history of every command including other clients', the panel's pixels are content rather
    // than configuration, and a script's source is the user's own code.
    try std.testing.expectEqual(clients.Scope.logs, endpointFor(.GET, "/api/v1/logs").?.scope);
    try std.testing.expectEqual(clients.Scope.logs, endpointFor(.GET, "/api/v1/events").?.scope);
    try std.testing.expectEqual(clients.Scope.screen, endpointFor(.GET, "/api/v1/screen").?.scope);
    // (the templated routes are matched dynamically rather than from this table; reading a
    // script's source is covered by its own test)
    try std.testing.expectEqual(clients.Scope.status, endpointFor(.GET, "/api/v1/berry").?.scope);
}

test "a client token authenticates as its own scopes and names itself" {
    const c = testCreds();
    const kitchen = clients.Scope.notify.bit() | clients.Scope.display.bit();
    var store = clients.Store{};
    try store.add("kitchen", kitchen, [_]u8{0x33} ** 32, 1000);
    try store.add("wall", clients.Scope.status.bit(), [_]u8{0x44} ** 32, 1000);

    const a = authenticate(&c, &store, "Bearer " ++ "33" ** 32);
    try std.testing.expectEqual(kitchen, a.scopes);
    try std.testing.expectEqualStrings("kitchen", a.client.?.slice());

    const b = authenticate(&c, &store, "Bearer " ++ "44" ** 32);
    try std.testing.expectEqual(clients.Scope.status.bit(), b.scopes);
    try std.testing.expectEqualStrings("wall", b.client.?.slice());

    // the built-in tokens are not clients and carry no name
    try std.testing.expectEqual(admin_scopes, authenticate(&c, &store, admin_header).scopes);
    try std.testing.expect(authenticate(&c, &store, control_header).client == null);
    try std.testing.expectEqual(@as(clients.Set, 0), authenticate(&c, &store, "Bearer " ++ "99" ** 32).scopes);
}

test "a status-only client is refused everything else, including the log ring" {
    const c = testCreds();
    var store = clients.Store{};
    try store.add("wall", clients.Scope.status.bit(), [_]u8{0x44} ** 32, 1000);
    const hdr = "Bearer " ++ "44" ** 32;
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    try expectReject(route(testReq(.POST, "/api/v1/notify", "", hdr, "application/json", null), "{\"text\":\"x\"}", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.GET, "/api/v1/logs", "", hdr, null, null), "", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.POST, "/api/v1/input", "", hdr, "application/json", null), "{\"control\":\"left\",\"event\":\"press\"}", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    // but it reads what it is for. which client asked is a property of authentication, tested
    // there: Route.op is the operation union and has no room for a field common to every variant,
    // so netd asks authenticate directly on the paths where it wants the name.
    try std.testing.expect(route(testReq(.GET, "/api/v1/status", "", hdr, null, null), "", &c, &store, &origins, &arena, test_minted) == .op);
}

test "a notify-only client can say something and do nothing else" {
    const c = testCreds();
    var store = clients.Store{};
    try store.add("kitchen", clients.Scope.notify.bit(), [_]u8{0x33} ** 32, 1000);
    const hdr = "Bearer " ++ "33" ** 32;
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    try std.testing.expect(route(testReq(.POST, "/api/v1/notify", "", hdr, "application/json", null), "{\"text\":\"x\"}", &c, &store, &origins, &arena, test_minted) == .op);
    try expectReject(route(testReq(.GET, "/api/v1/mqtt", "", hdr, null, null), "", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    // not even the status it does not need -- this is the token the old role ladder could not make
    try expectReject(route(testReq(.GET, "/api/v1/status", "", hdr, null, null), "", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(route(testReq(.PUT, "/api/v1/scene", "", hdr, "application/json", null), "{\"base\":\"clock\"}", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
}

test "the token routes are admin only, and validate before they reach the supervisor" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const R = struct {
        fn go(cc: *const Credentials, o: *const OriginPolicy, a: *Arena, m: http.Method, path: []const u8, hdr: []const u8, body: []const u8) Route {
            return route(testReq(m, path, "", hdr, if (body.len > 0) "application/json" else null, null), body, cc, &no_clients, o, a, test_minted);
        }
    };
    // admin issues, lists and revokes
    try std.testing.expect(R.go(&c, &origins, &arena, .GET, "/api/v1/tokens", admin_header, "") == .op);
    const made = R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"kitchen\",\"scopes\":[\"notify\",\"display\"]}");
    try std.testing.expectEqualStrings("kitchen", made.op.client_add.name);
    try std.testing.expectEqual(clients.Scope.notify.bit() | clients.Scope.display.bit(), made.op.client_add.scopes);
    // the scope list is validated here rather than after a round trip
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"k\",\"scopes\":[\"teleport\"]}"), 400, "invalid_scope");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"k\",\"scopes\":[]}"), 400, "invalid_scope");
    // and minting is refused by name rather than quietly dropped
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"k\",\"scopes\":[\"notify\",\"tokens\"]}"), 400, "invalid_scope");
    const gone = R.go(&c, &origins, &arena, .DELETE, "/api/v1/tokens/kitchen", admin_header, "");
    try std.testing.expectEqualStrings("kitchen", gone.op.client_remove.name);

    // a control token cannot reach any of them: issuing is how access is granted
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/tokens", control_header, ""), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", control_header, "{\"name\":\"x\",\"scopes\":[\"status\"]}"), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .DELETE, "/api/v1/tokens/x", control_header, ""), 403, "forbidden");

    // validation happens here, not after a round trip
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"has space\",\"scopes\":[\"status\"]}"), 400, "invalid_name");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\".hidden\",\"scopes\":[\"status\"]}"), 400, "invalid_name");
    // `role` is not a field any more, so a body written for the old shape is refused as such
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"ok\",\"role\":\"control\"}"), 400, "unknown_field");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens", admin_header, "{\"name\":\"ok\"}"), 400, "missing_field");
    try expectReject(R.go(&c, &origins, &arena, .DELETE, "/api/v1/tokens/has space", admin_header, ""), 400, "invalid_name");
}

test "a full store still renders a listing that fits one response" {
    // this is the whole reason max_clients is derived rather than chosen. worst case throughout:
    // every name at full length, every timestamp at full width.
    var store = clients.Store{};
    var i: usize = 0;
    while (i < clients.max_clients) : (i += 1) {
        var name: [clients.name_max]u8 = undefined;
        _ = std.fmt.bufPrint(&name, "{s}{d:0>4}", .{ "n" ** (clients.name_max - 4), i }) catch unreachable;
        try store.add(&name, clients.grantable, [_]u8{@intCast(i & 0xff)} ** 32, std.math.minInt(i64));
    }
    var buf: [http.response_buf_len]u8 = undefined;
    const listing = clients.renderList(&store, &buf);
    try std.testing.expect(listing != null);
    try std.testing.expectEqual(clients.max_clients, store.len);
    // and it really is the whole store, not a quietly shortened one
    try std.testing.expect(std.mem.indexOf(u8, listing.?, "0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, listing.?, "0000") != null);
}

test "rotation is its own route, and never a silent overwrite of create" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const R = struct {
        fn go(cc: *const Credentials, o: *const OriginPolicy, a: *Arena, m: http.Method, path: []const u8, hdr: []const u8, body: []const u8) Route {
            return route(testReq(m, path, "", hdr, if (body.len > 0) "application/json" else null, null), body, cc, &no_clients, o, a, test_minted);
        }
    };
    const bare = R.go(&c, &origins, &arena, .POST, "/api/v1/tokens/kitchen/rotate", admin_header, "");
    try std.testing.expectEqualStrings("kitchen", bare.op.client_rotate.name);
    try std.testing.expect(bare.op.client_rotate.scopes == null); // unchanged unless supplied

    const with_scopes = R.go(&c, &origins, &arena, .POST, "/api/v1/tokens/kitchen/rotate", admin_header, "{\"scopes\":[\"status\"]}");
    try std.testing.expectEqual(clients.Scope.status.bit(), with_scopes.op.client_rotate.scopes.?);

    // re-creating an existing name is still a 409 elsewhere; rotation never happens by accident
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens/kitchen/rotate", control_header, ""), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens/has space/rotate", admin_header, ""), 400, "invalid_name");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/tokens/kitchen/rotate", admin_header, "{\"scopes\":[\"admin\"]}"), 400, "invalid_scope");
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/tokens/kitchen/rotate", admin_header, ""), 405, "method_not_allowed");
}

test "a stored script can be read back, and reading source needs the scripts scope" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const R = struct {
        fn go(cc: *const Credentials, o: *const OriginPolicy, a: *Arena, m: http.Method, path: []const u8, hdr: []const u8) Route {
            return route(testReq(m, path, "", hdr, null, null), "", cc, &no_clients, o, a, test_minted);
        }
    };
    const got = R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/autoexec", admin_header);
    try std.testing.expectEqualStrings("autoexec", got.op.berry_get.name);
    // asserted through the router rather than the endpoint table, because a `{name}` route is
    // matched dynamically and does not appear in it. the operating secret lists script names --
    // that is `status` -- but does not read their source or write one.
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/autoexec", control_header), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .DELETE, "/api/v1/berry/scripts/autoexec", control_header), 403, "forbidden");
    try std.testing.expect(R.go(&c, &origins, &arena, .DELETE, "/api/v1/berry/scripts/autoexec", admin_header) == .op);
    try std.testing.expect(R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/autoexec", admin_header) == .op);
    // reading a script's source needs `scripts`, not the `status` that lists their names: with a
    // real scope set the split protects something, where under the old ladder it protected little
    var store = clients.Store{};
    try store.add("wall", clients.Scope.status.bit(), [_]u8{0x77} ** 32, 1);
    try expectReject(route(testReq(.GET, "/api/v1/berry/scripts/autoexec", "", "Bearer " ++ "77" ** 32, null, null), "", &c, &store, &origins, &arena, test_minted), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/has space", admin_header), 400, "invalid_script_name");
}

test "running a stored script is admin, and never carries source" {
    const c = testCreds();
    var arena: Arena = undefined;
    const origins = OriginPolicy{};
    const R = struct {
        fn go(cc: *const Credentials, o: *const OriginPolicy, a: *Arena, m: http.Method, path: []const u8, hdr: []const u8, body: []const u8) Route {
            return route(testReq(m, path, "", hdr, if (body.len > 0) "text/plain" else null, null), body, cc, &no_clients, o, a, test_minted);
        }
    };
    const run = R.go(&c, &origins, &arena, .POST, "/api/v1/berry/scripts/greet/run", admin_header, "");
    try std.testing.expectEqualStrings("greet", run.op.berry_run.name);
    // a run route that took a body would be the eval route SECURITY.md says does not exist
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/berry/scripts/greet/run", admin_header, "print('injected')"), 400, "unexpected_body");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/berry/scripts/greet/run", control_header, ""), 403, "forbidden");
    try expectReject(R.go(&c, &origins, &arena, .POST, "/api/v1/berry/scripts/has space/run", admin_header, ""), 400, "invalid_script_name");
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/greet/run", admin_header, ""), 405, "method_not_allowed");
    // reading the source is `scripts` now, like running it: the operating secret does neither
    try expectReject(R.go(&c, &origins, &arena, .GET, "/api/v1/berry/scripts/greet", control_header, ""), 403, "forbidden");
}

test "the device docs can execute same-origin authenticated browser requests" {
    var arena: Arena = undefined;
    var req = testReq(.POST, "/api/v1/notify", "", control_header, "application/json", "http://tc002.local:8080");
    req.host = "tc002.local:8080";
    const routed = route(req, "{\"text\":\"hello\"}", &testCreds(), &no_clients, &.{}, &arena, test_minted);
    try std.testing.expect(routed == .op);
    req.authorization = null;
    try expectReject(route(req, "{}", &testCreds(), &no_clients, &.{}, &arena, test_minted), 401, "unauthorized");
    req.authorization = control_header;
    req.origin = "http://evil.example";
    try expectReject(route(req, "{}", &testCreds(), &no_clients, &.{}, &arena, test_minted), 403, "origin_denied");
}

test "notification options validate names types durations and preserve defaults" {
    var arena: Arena = undefined;
    const legacy = parseBody(.notify, "{\"text\":\"hello\"}", &arena, test_minted).op.notify;
    try std.testing.expect(!legacy.stack and !legacy.hold);
    try std.testing.expectEqualStrings("", legacy.name);
    try std.testing.expectEqual(@as(u16, 5), legacy.duration_s);
    const queued = parseBody(.notify, "{\"text\":\"hello\",\"name\":\"door-1\",\"stack\":true,\"hold\":true}", &arena, test_minted).op.notify;
    try std.testing.expect(queued.stack and queued.hold);
    try std.testing.expectEqualStrings("door-1", queued.name);
    const longest = "n" ** 255;
    const at_most = parseBody(.notify, "{\"text\":\"x\",\"name\":\"" ++ longest ++ "\"}", &arena, test_minted).op.notify;
    try std.testing.expectEqualStrings(longest, at_most.name);
    const dismissed = parseBody(.dismiss_notify, "{\"name\":\"" ++ longest ++ "\"}", &arena, test_minted).op.dismiss_notify;
    try std.testing.expectEqualStrings(longest, dismissed.name);
    for ([_][]const u8{ "", "bad/name", "a b", longest ++ "n" }) |name| {
        var buf: [512]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"text\":\"x\",\"name\":\"{s}\"}}", .{name});
        try expectReject(parseBody(.notify, body, &arena, test_minted), 400, "invalid_name");
        const dismiss = try std.fmt.bufPrint(&buf, "{{\"name\":\"{s}\"}}", .{name});
        try expectReject(parseBody(.dismiss_notify, dismiss, &arena, test_minted), 400, "invalid_name");
    }
    const wrong_type = parseBody(.notify, "{\"text\":\"hello\",\"stack\":\"yes\"}", &arena, test_minted);
    try std.testing.expect(wrong_type == .reject);
    try expectReject(parseBody(.notify, "{\"text\":\"x\",\"hold\":true,\"duration_s\":0}", &arena, test_minted), 400, "invalid_duration");
    const current = parseBody(.dismiss_notify, "{}", &arena, test_minted).op.dismiss_notify;
    try std.testing.expectEqualStrings("", current.name);
    try std.testing.expectEqual(test_minted, current.request_id);
}

test "notification dismissal requires notify scope" {
    const c = testCreds();
    var store = clients.Store{};
    var origins = OriginPolicy{};
    var arena: Arena = undefined;
    try store.add("notifier", clients.Scope.notify.bit(), [_]u8{0x33} ** 32, 1000);
    const auth = "Bearer " ++ ("33" ** 32);
    const r = route(testReq(.POST, "/api/v1/notify/dismiss", "", auth, "application/json", null), "{}", &c, &store, &origins, &arena, test_minted);
    try std.testing.expect(r == .op);
    try expectReject(route(testReq(.POST, "/api/v1/notify/dismiss", "", null, "application/json", null), "{}", &c, &store, &origins, &arena, test_minted), 401, "unauthorized");
}

test "a notification may be a document, with the text as its summary or absent" {
    const c = testCreds();
    var arena: Arena = undefined;
    var origins = OriginPolicy{};
    const rich = "{\"elements\":[{\"type\":\"text\",\"at\":[0,5],\"size\":[52,5],\"font\":\"mini\",\"align\":\"centre\",\"text\":\"Updating...\",\"animate\":{\"kind\":\"pulse\",\"ms\":1600}}],\"name\":\"updating\",\"hold\":true}";
    const r = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), rich, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expect(r == .op);
    try std.testing.expect(r.op.notify.doc != null);
    try std.testing.expectEqual(@as(u8, 1), r.op.notify.doc.?.count);
    try std.testing.expectEqualStrings("", r.op.notify.text);
    try std.testing.expect(r.op.notify.hold);
    const summarised = "{\"text\":\"parcel\",\"elements\":[{\"type\":\"rect\",\"at\":[0,0],\"size\":[52,16],\"colour\":\"00ff00\"}]}";
    const s = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), summarised, &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("parcel", s.op.notify.text);
    const empty = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"elements\":[]}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("invalid_elements", empty.reject.code);
    const wrong = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{\"elements\":[{\"type\":\"blob\",\"at\":[0,0]}]}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("invalid_element_type", wrong.reject.code);
    const textless = route(testReq(.POST, "/api/v1/notify", "", control_header, "application/json", null), "{}", &c, &no_clients, &origins, &arena, test_minted);
    try std.testing.expectEqualStrings("invalid_text", textless.reject.code);
}

test "a canvas put may decline to persist" {
    var arena: Arena = undefined;
    const t = parseBody(.canvas_put, "{\"elements\":[{\"type\":\"rect\",\"at\":[0,0],\"size\":[4,4]}],\"persist\":false}", &arena, 0);
    try std.testing.expect(!t.op.canvas_put.persist);
    try std.testing.expectEqual(@as(u8, 1), t.op.canvas_put.doc.count);
    const d = parseBody(.canvas_put, "{\"elements\":[{\"type\":\"rect\",\"at\":[0,0],\"size\":[4,4]}]}", &arena, 0);
    try std.testing.expect(d.op.canvas_put.persist);
}
