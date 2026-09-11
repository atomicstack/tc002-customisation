//! the panel console's renderer, as one wasm module.
//!
//! the browser preview used to be a hand-written javascript port of the font, the clock fonts and
//! colour styles, the posix tz rules, the ip and notification layouts and the generators — five
//! hundred lines that had to be re-synchronised by hand every time a scene changed. this compiles
//! the real `scene.Arbiter` to wasm32-freestanding instead, so the preview runs the device's own
//! pixels and there is nothing left to keep in sync.
//!
//! the boundary is deliberately javascript-shaped: times cross as f64 milliseconds rather than
//! u64 nanoseconds (a u64 parameter reaches js as a BigInt, which infects every caller), strings
//! and frames cross through one scratch buffer, and every enum crosses as its numeric value.
const std = @import("std");
const geometry = @import("panel/geometry.zig");
const pack = @import("panel/pack.zig");
const scene = @import("scene/scene.zig");
const arbiter = @import("scene/arbiter.zig");
const clock = @import("scene/clock.zig");
const clockfont = @import("scene/clockfont.zig");
const ip = @import("scene/ip.zig");
const tz = @import("scene/tz.zig");
const param = @import("scene/param.zig");

const ms_per_ns: f64 = 1_000_000.0;

/// f64 milliseconds to u64 nanoseconds, saturating at zero (the arbiter's clocks are unsigned).
fn toNs(ms: f64) u64 {
    if (!(ms > 0)) return 0;
    return @intFromFloat(ms * ms_per_ns);
}

fn toMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / ms_per_ns;
}

var out_rgb: geometry.Rgb = geometry.black_rgb;
/// strings in, frames in, catalogue names out; one buffer, never two calls deep
var scratch: [4096]u8 = undefined;
var lut: pack.Lut = undefined;
var arb: arbiter.Arbiter = undefined;
var rule: tz.Rule = tz.utc;

// ---- memory windows ----

export fn framePtr() [*]u8 {
    return &out_rgb;
}
export fn frameLen() u32 {
    return geometry.rgb_bytes;
}
export fn scratchPtr() [*]u8 {
    return &scratch;
}
export fn scratchLen() u32 {
    return scratch.len;
}
export fn lutPtr() [*]u8 {
    return &lut;
}
export fn panelWidth() u32 {
    return geometry.width;
}
export fn panelHeight() u32 {
    return geometry.height;
}

// ---- the firmware level curve (panel/pack.zig) ----

/// fill the lut window with the curve for one brightness; the console paints through it.
export fn buildLut(brightness: u32) void {
    lut = pack.buildLut(@intCast(@min(brightness, 255)));
}

// ---- lifecycle ----

export fn init(base: u32, generator: u32, seed: u32) void {
    rule = tz.utc;
    arb = arbiter.Arbiter.init(baseOf(base), generatorOf(generator), seed, rule);
}

/// advance to `now_ms`, render the wall-clock instant `wall_ms`, and report when to come back:
/// milliseconds until the next redraw, or -1 when nothing changes until an external event.
export fn frame(now_ms: f64, wall_ms: f64) f64 {
    const now_ns = toNs(now_ms);
    const wall_ns = toNs(wall_ms);
    arb.tick(now_ns, wall_ns);
    arb.render(wall_ns, &out_rgb);
    return switch (arb.cadence(wall_ns)) {
        .continuous => |period| toMs(period),
        .at_wall_ns => |at| @max(0, toMs(at) - wall_ms),
        .idle => -1,
    };
}

// ---- commands ----

fn baseOf(v: u32) arbiter.Base {
    return if (v < 3) @enumFromInt(v) else .art;
}
fn generatorOf(v: u32) scene.Generator {
    return if (v < scene.generator_count) @enumFromInt(v) else .popsquares;
}

export fn setBase(v: u32, now_ms: f64) void {
    _ = arb.apply(.{ .set_base = baseOf(v) }, toNs(now_ms));
}
export fn setGenerator(v: u32, now_ms: f64) void {
    _ = arb.apply(.{ .select_generator = generatorOf(v) }, toNs(now_ms));
}
export fn setBrightness(v: u32, now_ms: f64) void {
    _ = arb.apply(.{ .brightness = @intCast(@min(v, 255)) }, toNs(now_ms));
}
export fn setPower(on: u32, now_ms: f64) void {
    _ = arb.apply(.{ .power = on != 0 }, toNs(now_ms));
}
export fn reseed(seed: u32, now_ms: f64) void {
    _ = arb.apply(.{ .reseed = seed }, toNs(now_ms));
}
/// `has` false means no address configured, which the scene draws as `no ip`
export fn setIp(has: u32, a: u32, b: u32, c: u32, d: u32, now_ms: f64) void {
    const addr: ?[4]u8 = if (has != 0) .{ @intCast(a & 0xff), @intCast(b & 0xff), @intCast(c & 0xff), @intCast(d & 0xff) } else null;
    _ = arb.apply(.{ .ip_changed = addr }, toNs(now_ms));
}
export fn setIpMode(v: u32, now_ms: f64) void {
    const mode: ip.Mode = if (v < 4) @enumFromInt(v) else .lines;
    _ = arb.apply(.{ .set_ip_mode = mode }, toNs(now_ms));
}

/// every field of the clock style at once; -1 in any slot leaves that field alone.
export fn setClockStyle(font: i32, mode: i32, gradient: i32, spread: i32, digit: i32, colour: i32, colour2: i32, now_ms: f64) void {
    var patch: clock.StylePatch = .{};
    if (font >= 0 and font < 6) patch.font = @enumFromInt(@as(u8, @intCast(font)));
    if (mode >= 0 and mode < 2) patch.mode = @enumFromInt(@as(u8, @intCast(mode)));
    if (gradient >= 0 and gradient < 3) patch.gradient = @enumFromInt(@as(u8, @intCast(gradient)));
    if (spread >= 0) patch.spread = @intCast(@min(spread, 255));
    if (digit >= 0 and digit < 3) patch.digit = @enumFromInt(@as(u8, @intCast(digit)));
    if (colour >= 0) patch.colour = rgbOf(colour);
    if (colour2 >= 0) patch.colour2 = rgbOf(colour2);
    _ = arb.apply(.{ .set_clock_style = patch }, toNs(now_ms));
}

fn rgbOf(v: i32) [3]u8 {
    const u: u32 = @bitCast(v);
    return .{ @intCast((u >> 16) & 0xff), @intCast((u >> 8) & 0xff), @intCast(u & 0xff) };
}

/// the notification text is the first `len` bytes of scratch. returns 0 when the arbiter
/// rejected it (bad text or duration), 1 when it took.
export fn notify(len: u32, colour: i32, duration_s: u32, now_ms: f64) u32 {
    const text = scratch[0..@min(len, scratch.len)];
    return switch (arb.apply(.{ .notify = .{
        .text = text,
        .colour = rgbOf(colour),
        .duration_s = @intCast(@min(duration_s, 65535)),
    } }, toNs(now_ms))) {
        .applied => 1,
        .rejected => 0,
    };
}

/// a raw frame: rgb_bytes of scratch, shown for `duration_s`.
export fn rawFrame(duration_s: u32, now_ms: f64) u32 {
    const rgb: *const geometry.Rgb = @ptrCast(scratch[0..geometry.rgb_bytes]);
    return switch (arb.apply(.{ .raw = .{ .rgb = rgb, .duration_s = @intCast(@min(duration_s, 65535)) } }, toNs(now_ms))) {
        .applied => 1,
        .rejected => 0,
    };
}

/// parse a posix tz string from the first `len` bytes of scratch and give it to the clock.
/// returns the standard utc offset in seconds, or -1 when the rule does not parse
/// (offsets are reported as seconds east, so a failure is told apart by `tzOk`).
var tz_ok: bool = true;
export fn setTz(len: u32) i32 {
    const text = scratch[0..@min(len, scratch.len)];
    rule = tz.parse(text) catch {
        tz_ok = false;
        rule = tz.utc;
        arb.clock = clock.State.init(rule);
        return -1;
    };
    tz_ok = true;
    arb.clock = clock.State.init(rule);
    return rule.std_offset_s;
}
export fn tzOk() u32 {
    return @intFromBool(tz_ok);
}

// ---- input, so the preview can drive the menu the way the dial does ----

export fn action(a: u32, now_ms: f64) void {
    if (a >= @typeInfo(scene.Action).@"enum".fields.len) return;
    arb.action(@enumFromInt(@as(u8, @intCast(a))), toNs(now_ms));
}
export fn openMenu(now_ms: f64) void {
    arb.openMenu(toNs(now_ms));
}
export fn menuOpen() u32 {
    return @intFromBool(arb.menuOpen());
}

// ---- what changed, so the console can mirror the device's own bookkeeping ----

export fn revision() u32 {
    return arb.revision;
}
export fn takeDirty() u32 {
    return @intFromBool(arb.takeDirty());
}
/// the effect of the pending transition, or 255 when none is pending. taking it also clears it.
export fn takeTransition() u32 {
    const spec = arb.takeTransition() orelse return 255;
    return @intFromEnum(spec.effect);
}
export fn transitionDone() void {
    arb.transitionDone();
}

// ---- catalogues, so the console's fallback lists come from the source too ----

fn enumNames(comptime E: type) []const u8 {
    comptime var buf: []const u8 = "";
    inline for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        buf = buf ++ (if (i == 0) "" else ",") ++ f.name;
    }
    return buf;
}

fn copyOut(text: []const u8) u32 {
    const n = @min(text.len, scratch.len);
    @memcpy(scratch[0..n], text[0..n]);
    return @intCast(n);
}

/// comma-separated names written into scratch; returns the byte length.
export fn generatorNames() u32 {
    return copyOut(enumNames(scene.Generator));
}
export fn clockFontNames() u32 {
    return copyOut(enumNames(clockfont.Font));
}
export fn clockModeNames() u32 {
    return copyOut(enumNames(clock.ColourMode));
}
export fn gradientNames() u32 {
    return copyOut(enumNames(clock.Gradient));
}
export fn digitStyleNames() u32 {
    return copyOut(enumNames(clockfont.DigitStyle));
}
export fn ipModeNames() u32 {
    return copyOut(enumNames(ip.Mode));
}
export fn baseNames() u32 {
    return copyOut(enumNames(arbiter.Base));
}
export fn notifyMaxSeconds() u32 {
    return arbiter.max_duration_s;
}
export fn clockDefaultSpread() u32 {
    return clock.default_spread;
}

// ---- scene parameters, which the console renders as sliders ----

export fn sceneParamCount() u32 {
    return @intCast(arb.sceneParams().len);
}
export fn getSceneParam(index: u32) u32 {
    return arb.getSceneParam(index);
}
export fn setSceneParam(index: u32, value: u32) void {
    arb.setSceneParam(index, value);
}
/// "name,kind,min,max,step,default" for one parameter, written into scratch.
export fn sceneParamInfo(index: u32) u32 {
    const params = arb.sceneParams();
    if (index >= params.len) return 0;
    const p = params[index];
    const written = std.fmt.bufPrint(&scratch, "{s},{s},{d},{d},{d},{d}", .{ p.name, @tagName(p.kind), p.min, p.max, p.step, p.default }) catch return 0;
    return @intCast(written.len);
}
