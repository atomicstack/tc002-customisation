//! scene arbitration: the base scene (art, clock, ip) plus at most one temporary overlay
//! (notification, raw frame, stream arming). owns the applied state revision. pure.
//!
//! rules from the design: a base selection clears any overlay; a new notification or raw frame
//! replaces the existing overlay; expiry reveals the current base; stream arming waits two
//! seconds for a session and then falls back; rotary selects the generator in art and changes
//! brightness in clock/ip; a short knob press reseeds art; a long one arms streaming.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const transition = @import("../panel/transition.zig");
const scene = @import("scene.zig");
const font = @import("font.zig");
const tz = @import("tz.zig");
const clock = @import("clock.zig");
const ip = @import("ip.zig");

const white = [3]u8{ 255, 255, 255 };
const s_ns = std.time.ns_per_s;

fn fresh() Arbiter {
    return Arbiter.init(.art, .popsquares, 1, tz.utc);
}

fn expectRejected(res: Result, why: Reject) !void {
    switch (res) {
        .rejected => |r| try std.testing.expectEqual(why, r),
        .applied => return error.TestUnexpectedResult,
    }
}

test "notification bounds: 128 printable ascii characters, 1..300 seconds" {
    var a = fresh();
    const long = [_]u8{'x'} ** 129;
    try expectRejected(a.apply(.{ .notify = .{ .text = &long, .colour = white, .duration_s = 5 } }, 0), .invalid_text);
    try expectRejected(a.apply(.{ .notify = .{ .text = "a\x01b", .colour = white, .duration_s = 5 } }, 0), .invalid_text);
    try expectRejected(a.apply(.{ .notify = .{ .text = "ok", .colour = white, .duration_s = 0 } }, 0), .invalid_duration);
    try expectRejected(a.apply(.{ .notify = .{ .text = "ok", .colour = white, .duration_s = 301 } }, 0), .invalid_duration);
    try std.testing.expectEqual(@as(u32, 0), a.revision);
    const ok = [_]u8{'y'} ** 128;
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .notify = .{ .text = &ok, .colour = white, .duration_s = 300 } }, 0));
}

test "an accepted notification renders centred text, marks dirty, and expires to the base" {
    var a = fresh();
    try std.testing.expect(a.takeDirty()); // the initial frame is pending
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 2 } }, 1 * s_ns));
    try std.testing.expect(a.takeDirty());
    try std.testing.expect(!a.takeDirty());
    var rgb: geometry.Rgb = undefined;
    a.render(0, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 20, 4, "hi", white);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expect(a.cadence(0) == .idle);
    a.tick(2 * s_ns + 999_999_999, 0);
    try std.testing.expect(a.overlay == .notify);
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
    try std.testing.expectEqual(@as(u32, 2), a.revision);
    try std.testing.expect(a.takeDirty());
    try std.testing.expect(a.cadence(0) == .continuous);
}

test "long notifications scroll with continuous cadence and bounded offset" {
    var a = fresh();
    _ = a.apply(.{ .notify = .{ .text = "this text is far wider than the panel", .colour = white, .duration_s = 60 } }, 0);
    try std.testing.expectEqual(scene.Cadence{ .continuous = scroll_period_ns }, a.cadence(0));
    var first: geometry.Rgb = undefined;
    a.tick(0, 0);
    a.render(0, &first);
    a.tick(10 * scroll_period_ns, 0);
    var later: geometry.Rgb = undefined;
    a.render(0, &later);
    try std.testing.expect(!std.mem.eql(u8, &first, &later));
    a.tick(59 * s_ns, 0);
    try std.testing.expect(a.overlay == .notify);
}

test "raw frames validate duration, replace a notification, and a base selection clears overlays" {
    var a = fresh();
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 10 } }, 0);
    var frame = geometry.black_rgb;
    frame[0] = 200;
    try expectRejected(a.apply(.{ .raw = .{ .rgb = &frame, .duration_s = 0 } }, 0), .invalid_duration);
    try std.testing.expectEqual(Result{ .applied = 2 }, a.apply(.{ .raw = .{ .rgb = &frame, .duration_s = 3 } }, 0));
    try std.testing.expect(a.overlay == .raw);
    var rgb: geometry.Rgb = undefined;
    a.render(0, &rgb);
    try std.testing.expectEqualSlices(u8, &frame, &rgb);
    try std.testing.expectEqual(Result{ .applied = 3 }, a.apply(.{ .set_base = .clock }, 0));
    try std.testing.expect(a.overlay == .none);
    try std.testing.expect(a.base == .clock);
    try std.testing.expect(a.cadence(5 * s_ns) == .at_wall_ns);
}

test "stream arming is an overlay that expires after two seconds" {
    var a = fresh();
    _ = a.apply(.arm_stream, 10 * s_ns);
    try std.testing.expect(a.overlay == .stream_arming);
    a.tick(11 * s_ns, 0);
    try std.testing.expect(a.overlay == .stream_arming);
    a.tick(12 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
}

test "physical actions: buttons select the base, rotary and knob depend on the base" {
    var a = fresh();
    a.action(.middle, 0);
    try std.testing.expect(a.base == .clock);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(@as(u8, 100), a.brightness); // clamped at the top
    a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(@as(u8, 95), a.brightness);
    a.action(.right, 0);
    try std.testing.expect(a.base == .ip);
    a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(@as(u8, 90), a.brightness);
    a.action(.left, 0);
    try std.testing.expect(a.base == .art);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.plasma, a.art.generator);
    try std.testing.expectEqual(@as(u8, 90), a.brightness);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.popsquares, a.art.generator);
    var before: geometry.Rgb = undefined;
    a.render(0, &before);
    a.action(.knob_short, 0);
    var after: geometry.Rgb = undefined;
    a.render(0, &after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
    a.action(.knob_long, 0);
    try std.testing.expect(a.overlay == .stream_arming);
    _ = a.apply(.{ .notify = .{ .text = "x", .colour = white, .duration_s = 5 } }, 0);
    a.action(.middle, 0); // a scene-changing action cancels the overlay
    try std.testing.expect(a.overlay == .none);
    var i: u32 = 0;
    while (i < 40) : (i += 1) a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(@as(u8, 1), a.brightness); // never fully off from the knob
}

test "transitions mark scene changes and notification edges, never raw frames or repeats" {
    var a = fresh();
    try std.testing.expect(a.takeTransition() == null);
    _ = a.apply(.{ .set_base = .art }, 0); // already art: no transition
    try std.testing.expect(a.takeTransition() == null);
    _ = a.apply(.{ .set_base = .clock }, 0);
    try std.testing.expect(a.takeTransition() != null);
    try std.testing.expect(a.takeTransition() == null);
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, 0);
    try std.testing.expect(a.takeTransition() != null);
    a.tick(1 * s_ns, 0); // expiry reveals the base
    try std.testing.expect(a.takeTransition() != null);
    var frame = geometry.black_rgb;
    _ = a.apply(.{ .raw = .{ .rgb = &frame, .duration_s = 2 } }, 2 * s_ns);
    try std.testing.expect(a.takeTransition() == null);
    a.tick(4 * s_ns, 0); // a raw frame ends without a fade
    try std.testing.expect(a.takeTransition() == null);
    _ = a.apply(.{ .set_base = .art }, 0);
    _ = a.takeTransition();
    a.action(.rotate_cw, 0); // generator change in art
    try std.testing.expect(a.takeTransition() != null);
    _ = a.apply(.{ .reseed = 5 }, 0);
    _ = a.apply(.{ .brightness = 50 }, 0);
    try std.testing.expect(a.takeTransition() == null);
}

test "a request's transition is remembered and the exit pairs it in reverse" {
    var a = fresh();
    a.default_transition = .{ .duration_ns = 7 };
    _ = a.apply(.{ .set_base = .clock }, 0);
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .left, .duration_ns = 7 }, a.takeTransition().?);
    const swipe = transition.Spec{ .effect = .swipe_in, .direction = .left, .duration_ns = 3 };
    _ = a.applyWith(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, swipe, 0);
    try std.testing.expectEqual(swipe, a.takeTransition().?);
    a.tick(1 * s_ns, 0);
    try std.testing.expectEqual(transition.Spec{ .effect = .swipe_out, .direction = .right, .duration_ns = 3 }, a.takeTransition().?);
    var frame = geometry.black_rgb;
    _ = a.apply(.{ .raw = .{ .rgb = &frame, .duration_s = 1 } }, 2 * s_ns); // no request effect: a cut
    try std.testing.expect(a.takeTransition() == null);
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.takeTransition() == null);
    _ = a.applyWith(.{ .raw = .{ .rgb = &frame, .duration_s = 1 } }, .{ .effect = .expand }, 4 * s_ns);
    try std.testing.expectEqual(transition.Effect.expand, a.takeTransition().?.effect);
    a.tick(5 * s_ns, 0);
    try std.testing.expectEqual(transition.Effect.collapse, a.takeTransition().?.effect);
    _ = a.applyWith(.{ .set_base = .art }, transition.Spec.cut, 0);
    try std.testing.expectEqual(transition.Effect.cut, a.takeTransition().?.effect);
    // exit modes: `same` keeps the direction, `none` cuts
    const same = transition.Spec{ .effect = .slide, .direction = .up, .duration_ns = 3, .exit = .same };
    _ = a.applyWith(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, same, 6 * s_ns);
    _ = a.takeTransition();
    a.tick(7 * s_ns, 0);
    try std.testing.expectEqual(same, a.takeTransition().?);
    _ = a.applyWith(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, .{ .effect = .expand, .exit = .none }, 8 * s_ns);
    _ = a.takeTransition();
    a.tick(9 * s_ns, 0);
    try std.testing.expectEqual(transition.Effect.cut, a.takeTransition().?.effect);
}

test "the default between base scenes is a slide that follows their order" {
    var a = fresh(); // art
    _ = a.apply(.{ .set_base = .clock }, 0);
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .left }, a.takeTransition().?);
    _ = a.apply(.{ .set_base = .ip }, 0);
    try std.testing.expectEqual(transition.Direction.left, a.takeTransition().?.direction);
    _ = a.apply(.{ .set_base = .art }, 0);
    try std.testing.expectEqual(transition.Direction.right, a.takeTransition().?.direction);
    a.action(.right, 0); // the buttons take the same path
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .left }, a.takeTransition().?);
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, 0);
    _ = a.takeTransition();
    _ = a.apply(.{ .set_base = .ip }, 0); // the same base: only the overlay leaves, with the default fade
    try std.testing.expectEqual(transition.Effect.fade, a.takeTransition().?.effect);
    _ = a.applyWith(.{ .set_base = .clock }, transition.Spec.cut, 0); // a request still decides
    try std.testing.expectEqual(transition.Effect.cut, a.takeTransition().?.effect);
}

test "a clock restyle merges fields, bumps only on change, and cross-fades while the clock shows" {
    var a = fresh();
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.{ .set_clock_style = .{} }, 0));
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .set_clock_style = .{ .font = .big } }, 0));
    _ = a.takeTransition();
    try std.testing.expect(a.takeTransition() == null); // art is showing: no visible change, no fade
    _ = a.apply(.{ .set_base = .clock }, 0);
    _ = a.takeTransition();
    try std.testing.expectEqual(Result{ .applied = 3 }, a.apply(.{ .set_clock_style = .{ .colour = .{ 1, 2, 3 } } }, 0));
    try std.testing.expect(a.takeTransition() != null);
    try std.testing.expectEqual(clock.Font.big, a.clock.style.font);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, a.clock.style.colour);
    try std.testing.expectEqual(Result{ .applied = 3 }, a.apply(.{ .set_clock_style = .{ .colour = .{ 1, 2, 3 } } }, 0));
}

test "power is a command that bumps the revision only when it changes" {
    var a = fresh();
    try std.testing.expect(a.power);
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.{ .power = true }, 0));
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .power = false }, 0));
    try std.testing.expect(!a.power);
    try std.testing.expect(a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .power = false }, 0));
    try std.testing.expect(!a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 2 }, a.apply(.{ .power = true }, 0));
    try std.testing.expect(a.takeTransition() == null);
}

test "brightness and reseed commands" {
    var a = fresh();
    try expectRejected(a.apply(.{ .brightness = 0 }, 0), .invalid_brightness);
    try expectRejected(a.apply(.{ .brightness = 101 }, 0), .invalid_brightness);
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .brightness = 40 }, 0));
    try std.testing.expectEqual(@as(u8, 40), a.brightness);
    try std.testing.expectEqual(Result{ .applied = 2 }, a.apply(.{ .reseed = 77 }, 0));
    try std.testing.expectEqual(@as(u32, 77), a.art.seed);
}

test "ip and time updates redraw without changing the revision" {
    var a = fresh();
    _ = a.apply(.{ .set_base = .ip }, 0);
    _ = a.takeDirty();
    var rgb: geometry.Rgb = undefined;
    a.render(0, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 11, 4, "no ip", white);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .ip_changed = .{ 10, 0, 0, 5 } }, 0));
    try std.testing.expect(a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .ip_changed = .{ 10, 0, 0, 5 } }, 0));
    try std.testing.expect(!a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.time_corrected, 0));
    try std.testing.expect(a.takeDirty());
}

pub const scroll_period_ns: u64 = 33_333_333;
const arming_wait_ns: u64 = 2 * s_ns;
const brightness_step: u8 = 5;

pub const Base = enum(u8) { art = 0, clock = 1, ip = 2 };

pub const Notify = struct { text: [128]u8, len: u8, colour: [3]u8, since_ns: u64, until_ns: u64, transition: transition.Spec };
pub const Raw = struct { rgb: geometry.Rgb, until_ns: u64, transition: transition.Spec };

pub const Overlay = union(enum) { none, notify: Notify, raw: Raw, stream_arming: u64 };

pub const Command = union(enum) {
    set_base: Base,
    select_generator: scene.Generator,
    notify: struct { text: []const u8, colour: [3]u8, duration_s: u16 },
    raw: struct { rgb: *const geometry.Rgb, duration_s: u16 },
    brightness: u8,
    reseed: u32,
    arm_stream,
    time_corrected,
    ip_changed: ?[4]u8,
    /// display power: off keeps every scene decision but the renderer shows black.
    power: bool,
    /// a partial restyle of the clock (font, colours); a visible change cross-fades.
    set_clock_style: clock.StylePatch,
};

pub const Reject = enum { invalid_text, invalid_duration, invalid_brightness };
pub const Result = union(enum) { applied: u32, rejected: Reject };

pub const Arbiter = struct {
    base: Base,
    overlay: Overlay = .none,
    revision: u32 = 0,
    brightness: u8 = 100,
    power: bool = true,
    /// set whenever the visible output changed; the renderer takes it to redraw immediately.
    dirty: bool = true,
    /// set when what is shown changes to something else (base, generator, a notification
    /// starting or ending, a restyle of the showing clock); the renderer takes it to run the
    /// effect. raw frames switch at once unless their request names an effect.
    pending: ?transition.Spec = null,
    /// the transition a change gets when the request names none (the renderer sets its duration)
    default_transition: transition.Spec = .{},
    last_tick_ns: u64 = 0,
    art: scene.Art,
    clock: clock.State,
    ip: ip.State = .{},

    pub fn init(base: Base, generator: scene.Generator, seed: u32, rule: tz.Rule) Arbiter {
        return .{ .base = base, .art = scene.Art.init(generator, seed), .clock = clock.State.init(rule) };
    }

    fn bump(self: *Arbiter) u32 {
        self.revision += 1;
        self.dirty = true;
        return self.revision;
    }

    pub fn takeDirty(self: *Arbiter) bool {
        const d = self.dirty;
        self.dirty = false;
        return d;
    }

    pub fn takeTransition(self: *Arbiter) ?transition.Spec {
        const t = self.pending;
        self.pending = null;
        return t;
    }

    fn mark(self: *Arbiter, spec: ?transition.Spec) void {
        self.pending = spec orelse self.default_transition;
    }

    fn validDuration(d: u16) bool {
        return d >= 1 and d <= 300;
    }

    pub fn apply(self: *Arbiter, cmd: Command, now_ns: u64) Result {
        return self.applyWith(cmd, null, now_ns);
    }

    /// apply a command whose request named a transition (`spec`), or none (the default).
    pub fn applyWith(self: *Arbiter, cmd: Command, spec: ?transition.Spec, now_ns: u64) Result {
        switch (cmd) {
            .set_base => |b| {
                if (b != self.base) {
                    // between the base scenes the default is a slide that follows their order:
                    // forward (art, clock, ip) to the left, back to the right, like pages
                    const forward = @intFromEnum(b) > @intFromEnum(self.base);
                    self.pending = spec orelse .{ .effect = .slide, .direction = if (forward) .left else .right, .duration_ns = self.default_transition.duration_ns };
                } else if (self.overlay != .none) self.mark(spec);
                self.base = b;
                self.overlay = .none;
                return .{ .applied = self.bump() };
            },
            .select_generator => |g| {
                if (g != self.art.generator) self.mark(spec);
                self.art.select(g);
                return .{ .applied = self.bump() };
            },
            .notify => |n| {
                if (n.text.len == 0 or n.text.len > 128) return .{ .rejected = .invalid_text };
                for (n.text) |c| if (c < 0x20 or c > 0x7e) return .{ .rejected = .invalid_text };
                if (!validDuration(n.duration_s)) return .{ .rejected = .invalid_duration };
                const t = spec orelse self.default_transition;
                var o = Notify{ .text = undefined, .len = @intCast(n.text.len), .colour = n.colour, .since_ns = now_ns, .until_ns = now_ns + @as(u64, n.duration_s) * s_ns, .transition = t };
                @memcpy(o.text[0..n.text.len], n.text);
                self.overlay = .{ .notify = o };
                self.pending = t;
                return .{ .applied = self.bump() };
            },
            .power => |on| {
                if (on == self.power) return .{ .applied = self.revision };
                self.power = on;
                return .{ .applied = self.bump() };
            },
            .set_clock_style => |p| {
                const before = self.clock.style;
                self.clock.style.apply(p);
                if (std.meta.eql(before, self.clock.style)) return .{ .applied = self.revision };
                if (self.base == .clock and self.overlay == .none) self.mark(spec);
                return .{ .applied = self.bump() };
            },
            .raw => |r| {
                if (!validDuration(r.duration_s)) return .{ .rejected = .invalid_duration };
                const t = spec orelse transition.Spec.cut;
                self.overlay = .{ .raw = .{ .rgb = r.rgb.*, .until_ns = now_ns + @as(u64, r.duration_s) * s_ns, .transition = t } };
                if (!t.instant()) self.pending = t;
                return .{ .applied = self.bump() };
            },
            .brightness => |b| {
                if (b < 1 or b > 100) return .{ .rejected = .invalid_brightness };
                self.brightness = b;
                return .{ .applied = self.bump() };
            },
            .reseed => |seed| {
                self.art.reseed(seed);
                return .{ .applied = self.bump() };
            },
            .arm_stream => {
                self.overlay = .{ .stream_arming = now_ns + arming_wait_ns };
                return .{ .applied = self.bump() };
            },
            .time_corrected => {
                self.dirty = true;
                return .{ .applied = self.revision };
            },
            .ip_changed => |addr| {
                if (self.ip.set(addr)) self.dirty = true;
                return .{ .applied = self.revision };
            },
        }
    }

    pub fn action(self: *Arbiter, a: scene.Action, now_ns: u64) void {
        switch (a) {
            .left => _ = self.apply(.{ .set_base = .art }, now_ns),
            .middle => _ = self.apply(.{ .set_base = .clock }, now_ns),
            .right => _ = self.apply(.{ .set_base = .ip }, now_ns),
            .rotate_cw, .rotate_ccw => switch (self.base) {
                .art => {
                    self.art.nextGenerator(a == .rotate_cw);
                    self.mark(null);
                    _ = self.bump();
                },
                .clock, .ip => {
                    const b: i32 = @as(i32, self.brightness) + if (a == .rotate_cw) @as(i32, brightness_step) else -@as(i32, brightness_step);
                    self.brightness = @intCast(std.math.clamp(b, 1, 100));
                    _ = self.bump();
                },
            },
            .knob_short => if (self.base == .art) {
                _ = self.apply(.{ .reseed = self.art.seed *% 1664525 +% 1013904223 }, now_ns);
            },
            .knob_long => _ = self.apply(.arm_stream, now_ns),
        }
    }

    /// advance time: expire overlays and step the art animation.
    pub fn tick(self: *Arbiter, now_ns: u64, wall_ns: u64) void {
        _ = wall_ns;
        const dt_ns = now_ns -| self.last_tick_ns;
        self.last_tick_ns = now_ns;
        self.art.step(@as(f32, @floatFromInt(dt_ns)) / @as(f32, s_ns));
        const until: ?u64 = switch (self.overlay) {
            .notify => |n| n.until_ns,
            .raw => |r| r.until_ns,
            .stream_arming => |u| u,
            .none => null,
        };
        if (until) |u| if (now_ns >= u) {
            // an overlay leaves with the paired effect travelling the other way
            switch (self.overlay) {
                .notify => |n| self.pending = n.transition.outgoing(),
                .raw => |r| if (!r.transition.instant()) {
                    self.pending = r.transition.outgoing();
                },
                else => {},
            }
            self.overlay = .none;
            _ = self.bump();
        };
    }

    /// when the current overlay expires, so the loop can arm a timer for it.
    pub fn nextExpiryNs(self: *const Arbiter) ?u64 {
        return switch (self.overlay) {
            .notify => |n| n.until_ns,
            .raw => |r| r.until_ns,
            .stream_arming => |u| u,
            .none => null,
        };
    }

    fn renderBase(self: *const Arbiter, wall_ns: u64, rgb: *geometry.Rgb) void {
        switch (self.base) {
            .art => self.art.render(rgb),
            .clock => self.clock.render(wall_ns, rgb),
            .ip => self.ip.render(rgb),
        }
    }

    pub fn render(self: *const Arbiter, wall_ns: u64, rgb: *geometry.Rgb) void {
        switch (self.overlay) {
            .notify => |n| {
                rgb.* = geometry.black_rgb;
                const text = n.text[0..n.len];
                const w: i32 = @intCast(font.textWidth(text));
                if (w <= geometry.width) {
                    font.blit(rgb, @divFloor(geometry.width - w, 2), 4, text, n.colour);
                } else {
                    // scroll in from the right edge, one pixel per period, wrapping after the text has left
                    const span: u64 = @intCast(w + geometry.width);
                    const steps = (self.last_tick_ns -| n.since_ns) / scroll_period_ns;
                    const x: i32 = geometry.width - @as(i32, @intCast(steps % span));
                    font.blit(rgb, x, 4, text, n.colour);
                }
            },
            .raw => |r| rgb.* = r.rgb,
            .stream_arming, .none => self.renderBase(wall_ns, rgb),
        }
    }

    pub fn cadence(self: *const Arbiter, wall_ns: u64) scene.Cadence {
        return switch (self.overlay) {
            .notify => |n| if (font.textWidth(n.text[0..n.len]) > geometry.width) .{ .continuous = scroll_period_ns } else .idle,
            .raw => .idle,
            .stream_arming, .none => switch (self.base) {
                .art => self.art.cadence(),
                .clock => self.clock.cadence(wall_ns),
                .ip => self.ip.cadence(),
            },
        };
    }
};
