//! scene arbitration: the base scene (art, clock, ip) plus at most one temporary overlay
//! (notification, raw frame, stream arming). owns the applied state revision. pure.
//!
//! rules from the design: a base selection clears any overlay; a new notification or raw frame
//! replaces the existing overlay; expiry reveals the current base; stream arming waits two
//! seconds for a session and then falls back; rotary selects the generator in art and changes
//! clock faces in the clock and layouts in ip; a short knob press reseeds art; a long one arms streaming.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const transition = @import("../panel/transition.zig");
const scene = @import("scene.zig");
const font = @import("font.zig");
const tz = @import("tz.zig");
const clock = @import("clock.zig");
const ip = @import("ip.zig");
const menu = @import("menu.zig");
const canvas = @import("canvas.zig");
const pages = @import("pages.zig");
const param = @import("param.zig");

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
    a.action(.left, 0);
    try std.testing.expect(a.base == .clock);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(clock.Font.mini, a.clock.style.font); // the knob pages the faces
    a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(clock.Font.classic, a.clock.style.font);
    a.action(.right, 0);
    try std.testing.expect(a.base == .canvas);
    a.action(.rotate_ccw, 0); // a canvas has no pages of its own, so the dial does nothing
    try std.testing.expect(a.base == .canvas);
    a.action(.middle, 0);
    try std.testing.expect(a.base == .art);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.plasma, a.art.generator);
    try std.testing.expectEqual(@as(u8, 100), a.brightness);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.cube, a.art.generator);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.popsquares, a.art.generator); // all the way round
    var before: geometry.Rgb = undefined;
    a.render(0, &before);
    // a short knob press opens the showing scene's settings, which take every control
    a.action(.knob_short, 0);
    try std.testing.expect(a.menuOpen());
    try std.testing.expectEqual(menu.Kind.scene, a.menu_state.?.kind);
    var after: geometry.Rgb = undefined;
    a.render(0, &after);
    try std.testing.expect(!std.mem.eql(u8, &before, &after));
    a.action(.right, 0); // a button inside the menu edits, it does not change the base
    try std.testing.expect(a.base == .art);
    a.action(.middle, 0); // middle backs out
    try std.testing.expect(!a.menuOpen());
    // and a long press opens the device's own menu instead
    a.action(.knob_long, 0);
    try std.testing.expect(a.menuOpen());
    try std.testing.expectEqual(menu.Kind.device, a.menu_state.?.kind);
    a.action(.middle, 0);
    _ = a.apply(.arm_stream, 0); // the stream is armed through the api now, not the knob
    try std.testing.expect(a.overlay == .stream_arming);
    _ = a.apply(.{ .notify = .{ .text = "x", .colour = white, .duration_s = 5 } }, 0);
    a.action(.left, 0); // a scene-changing action cancels the overlay
    try std.testing.expect(a.overlay == .none);
    var i: u32 = 0;
    while (i < 40) : (i += 1) a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(clock.Font.segment, a.clock.style.font); // 40 steps back around six faces
    try std.testing.expectEqual(@as(u8, 100), a.brightness); // the knob leaves brightness alone
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
    _ = a.apply(.{ .set_base = .clock }, 0); // art -> clock: the clock's button is the left one
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .right, .duration_ns = 7 }, a.takeTransition().?);
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

test "a base change slides the way its button sits on the panel" {
    // the buttons are laid out left, middle, right and select clock, art, canvas, which is also
    // the enum's order: moving to a scene whose button is further right brings it in from the
    // right. the two were once different and reading one as the other sent every slide between
    // the clock and the art the wrong way.
    const cases = [_]struct { from: Base, to: Base, dir: transition.Direction }{
        .{ .from = .clock, .to = .art, .dir = .left },
        .{ .from = .clock, .to = .canvas, .dir = .left },
        .{ .from = .art, .to = .canvas, .dir = .left },
        .{ .from = .art, .to = .clock, .dir = .right },
        .{ .from = .canvas, .to = .clock, .dir = .right },
        .{ .from = .canvas, .to = .art, .dir = .right },
    };
    for (cases) |c| {
        var a = Arbiter.init(c.from, .popsquares, 1, tz.utc);
        _ = a.apply(.{ .set_base = c.to }, 0);
        const got = a.takeTransition().?;
        try std.testing.expectEqual(transition.Effect.slide, got.effect);
        try std.testing.expectEqual(c.dir, got.direction);
    }
    // and the same through the buttons themselves
    var a = Arbiter.init(.art, .popsquares, 1, tz.utc);
    a.action(.left, 0); // art -> clock, one to the left
    try std.testing.expectEqual(transition.Direction.right, a.takeTransition().?.direction);
    a.action(.middle, 0); // clock -> art, one to the right
    try std.testing.expectEqual(transition.Direction.left, a.takeTransition().?.direction);
    a.action(.right, 0); // art -> ip, one to the right
    try std.testing.expectEqual(transition.Direction.left, a.takeTransition().?.direction);
    a.action(.middle, 0); // ip -> art, one to the left
    try std.testing.expectEqual(transition.Direction.right, a.takeTransition().?.direction);
}

test "the dial raises a page indicator in every scene it pages, and it fades away" {
    // compared against the same scene drawn without an indicator, because popsquares already
    // lights the whole bottom row and counting lit pixels would say nothing there
    const row_of = struct {
        fn get(rgb: *const geometry.Rgb) [geometry.width * 3]u8 {
            var out: [geometry.width * 3]u8 = undefined;
            for (0..geometry.width) |x| {
                const i = geometry.pixelOffset(x, pages.row);
                out[x * 3] = rgb[i];
                out[x * 3 + 1] = rgb[i + 1];
                out[x * 3 + 2] = rgb[i + 2];
            }
            return out;
        }
    };
    var rgb: geometry.Rgb = undefined;
    var plain: geometry.Rgb = undefined;
    for ([_]Base{ .art, .clock }) |b| {
        var a = Arbiter.init(b, .popsquares, 1, tz.utc);
        a.action(.rotate_cw, 0); // the dial pages this scene, so the indicator comes up
        a.tick(pages.fade_in_ns, 0);
        a.render(0, &rgb);
        a.renderBase(0, &plain);
        try std.testing.expect(!std.mem.eql(u8, &row_of.get(&rgb), &row_of.get(&plain)));
        try std.testing.expect(a.cadence(0) == .continuous);
        // and it goes again on its own, giving the row back to the scene
        a.tick(pages.total_ns, 0);
        a.render(0, &rgb);
        a.renderBase(0, &plain);
        try std.testing.expectEqualSlices(u8, &row_of.get(&plain), &row_of.get(&rgb));
    }
    // a notification is not something the dial pages, so it never gets one
    var a = fresh();
    a.action(.rotate_cw, 0);
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 5 } }, 0);
    a.tick(pages.fade_in_ns, 0);
    a.render(0, &rgb);
    a.renderNotify(&a.overlay.notify, &plain);
    try std.testing.expectEqualSlices(u8, &plain, &rgb);
}

test "the device menu carries the ip layout in and back out again" {
    var a = fresh();
    _ = a.apply(.{ .set_ip_mode = .big }, 0);
    a.openMenu(0);
    try std.testing.expectEqual(ip.Mode.big, a.menu_state.?.settings.ip_mode); // it opens showing the truth
    a.menu_state.?.item = .ip;
    a.action(.knob_short, 0); // a click opens it for editing
    a.action(.rotate_cw, 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(ip.Mode.lines, a.ip.mode); // previewed at once, wrapping past big
    const r = a.takeMenuRequest();
    try std.testing.expect(r == null); // and nothing has gone up yet
    a.tick(menu.commit_delay_ns + 20 * std.time.ns_per_ms, 0);
    const settled = a.takeMenuRequest().?;
    try std.testing.expect(settled == .ip_mode and settled.ip_mode == .lines);
}

test "in the menu a clockwise detent moves right through the items" {
    // the dot row reads left to right, so a clockwise detent walks it rightwards. the driver
    // reports the detent that does that as rotate_cw since the state-code pairs were corrected.
    var a = fresh();
    a.openMenu(0);
    try std.testing.expectEqual(menu.Item.brightness, a.menu_state.?.item);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(menu.Item.ip, a.menu_state.?.item);
    a.action(.rotate_ccw, 0); // and counter-clockwise goes back
    try std.testing.expectEqual(menu.Item.brightness, a.menu_state.?.item);
    a.action(.rotate_ccw, 0); // wrapping backwards off the top lands on exit
    try std.testing.expectEqual(menu.Item.exit, a.menu_state.?.item);
}

test "the default between base scenes is a slide, and a request still overrides it" {
    var a = fresh(); // art
    _ = a.apply(.{ .set_base = .clock }, 0); // the clock's button is left of art's
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .right }, a.takeTransition().?);
    _ = a.apply(.{ .set_base = .canvas }, 0);
    try std.testing.expectEqual(transition.Direction.left, a.takeTransition().?.direction);
    _ = a.apply(.{ .set_base = .art }, 0);
    try std.testing.expectEqual(transition.Direction.right, a.takeTransition().?.direction);
    a.action(.right, 0); // the buttons take the same path
    try std.testing.expectEqual(transition.Spec{ .effect = .slide, .direction = .left }, a.takeTransition().?);
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, 0);
    _ = a.takeTransition();
    _ = a.apply(.{ .set_base = .canvas }, 0); // the same base: only the overlay leaves, with the default fade
    try std.testing.expectEqual(transition.Effect.fade, a.takeTransition().?.effect);
    _ = a.applyWith(.{ .set_base = .clock }, transition.Spec.cut, 0); // a request still decides
    try std.testing.expectEqual(transition.Effect.cut, a.takeTransition().?.effect);
    // a base change with a generator in the same request keeps the slide
    _ = a.apply(.{ .set_base = .art }, 0);
    _ = a.apply(.{ .select_generator = if (a.art.generator == .plasma) .popsquares else .plasma }, 0);
    try std.testing.expectEqual(transition.Effect.slide, a.takeTransition().?.effect);
    _ = a.apply(.{ .select_generator = if (a.art.generator == .plasma) .popsquares else .plasma }, 0); // alone: the fade
    try std.testing.expectEqual(transition.Effect.fade, a.takeTransition().?.effect);
}

test "the outgoing scene stays live through a transition and is dropped when it ends" {
    var a = fresh(); // art, popsquares
    var old: geometry.Rgb = undefined;
    var direct: geometry.Rgb = undefined;
    try std.testing.expect(!a.renderOutgoing(0, &old));
    _ = a.apply(.{ .set_base = .clock }, 0);
    try std.testing.expect(a.takeTransition() != null);
    try std.testing.expectEqual(Base.art, a.outgoing.?.base);
    try std.testing.expect(a.renderOutgoing(0, &old));
    a.art.render(&direct);
    try std.testing.expectEqualSlices(u8, &direct, &old);
    a.tick(100_000_000, 0); // the art moves on and the old layer follows it
    try std.testing.expect(a.renderOutgoing(0, &old));
    a.art.render(&direct);
    try std.testing.expectEqualSlices(u8, &direct, &old);
    a.transitionDone();
    try std.testing.expect(!a.renderOutgoing(0, &old));
    // a notification: the base is the outgoing layer; at its expiry the notification is
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 1 } }, 100_000_000);
    try std.testing.expectEqual(Base.clock, a.outgoing.?.base);
    try std.testing.expect(a.outgoing.?.overlay == .none);
    _ = a.takeTransition();
    a.transitionDone();
    a.tick(2 * s_ns, 0);
    try std.testing.expect(a.outgoing.?.overlay == .notify);
    try std.testing.expect(a.renderOutgoing(0, &old));
    var expected = geometry.black_rgb;
    font.blit(&expected, 20, 4, "hi", white);
    try std.testing.expectEqualSlices(u8, &expected, &old);
    _ = a.takeTransition();
    a.transitionDone();
    // a generator change keeps the old generator stepping alongside the new one
    _ = a.apply(.{ .set_base = .art }, 2 * s_ns);
    _ = a.takeTransition();
    a.transitionDone();
    _ = a.apply(.{ .select_generator = .plasma }, 2 * s_ns);
    try std.testing.expectEqual(scene.Generator.popsquares, a.outgoing.?.generator);
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.renderOutgoing(0, &old));
    a.art.renderGenerator(.popsquares, &direct);
    try std.testing.expectEqualSlices(u8, &direct, &old);
    // a second command while one is pending keeps the first outgoing layer
    _ = a.apply(.{ .set_base = .clock }, 3 * s_ns);
    try std.testing.expectEqual(scene.Generator.popsquares, a.outgoing.?.generator);
    try std.testing.expectEqual(Base.art, a.outgoing.?.base);
}

test "the knob pages through generators, clock faces and ip layouts" {
    var a = fresh(); // art, popsquares
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.plasma, a.art.generator);
    a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(scene.Generator.popsquares, a.art.generator);
    _ = a.apply(.{ .set_base = .clock }, 0);
    _ = a.takeTransition();
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(clock.Font.mini, a.clock.style.font);
    try std.testing.expectEqual(transition.Effect.fade, a.takeTransition().?.effect); // a restyle while the clock shows
    a.action(.rotate_ccw, 0);
    a.action(.rotate_ccw, 0);
    try std.testing.expectEqual(clock.Font.hires, a.clock.style.font); // wraps around
    _ = a.apply(.{ .set_base = .canvas }, 0);
    a.action(.rotate_ccw, 0); // a canvas has no pages, so the dial leaves everything alone
    try std.testing.expectEqual(clock.Font.hires, a.clock.style.font);
    try std.testing.expectEqual(@as(u8, 100), a.brightness); // the knob no longer touches brightness
}

test "the ip layout bumps only on change and never transitions: no base renders it" {
    // the address is a page of the device menu now, so setting the layout restyles that page
    // rather than the panel. the setting and all four renderings are unchanged.
    var a = fresh();
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.{ .set_ip_mode = .lines }, 0));
    try std.testing.expectEqual(Result{ .applied = 1 }, a.apply(.{ .set_ip_mode = .big }, 0));
    try std.testing.expect(a.takeTransition() == null);
    try std.testing.expectEqual(ip.Mode.big, a.ip.mode);
    a.openMenu(0);
    try std.testing.expectEqual(Result{ .applied = 2 }, a.apply(.{ .set_ip_mode = .mini }, 0));
    try std.testing.expect(a.takeTransition() == null); // still no transition, but the menu redraws
    try std.testing.expect(a.takeDirty());
    try std.testing.expectEqual(ip.Mode.mini, a.ip.mode);
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
    a.openMenu(0); // the address lives on the menu's own page now
    a.menu_state.?.item = .ip;
    _ = a.takeDirty();
    var rgb: geometry.Rgb = undefined;
    a.render(0, &rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 11, 4, "no ip", white);
    pages.draw(&expected, menu.count, @intFromEnum(menu.Item.ip), pages.alphaAt(0));
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.{ .ip_changed = .{ 10, 0, 0, 5 } }, 0));
    try std.testing.expect(a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.{ .ip_changed = .{ 10, 0, 0, 5 } }, 0));
    try std.testing.expect(!a.takeDirty());
    try std.testing.expectEqual(Result{ .applied = 0 }, a.apply(.time_corrected, 0));
    try std.testing.expect(a.takeDirty());
}

pub const scroll_period_ns: u64 = 33_333_333;

/// the next (or previous) value of an enum, wrapping around
fn cycle(comptime E: type, v: E, forward: bool) E {
    const n = @typeInfo(E).@"enum".fields.len;
    const i: usize = @intFromEnum(v);
    return @enumFromInt(if (forward) (i + 1) % n else (i + n - 1) % n);
}
const arming_wait_ns: u64 = 2 * s_ns;

/// the base scenes, numbered in the order they sit across the panel, which is the order of the
/// buttons that select them: left the clock, middle the art, right the canvas. that the numbering
/// and the layout are the same thing is deliberate — they used to differ, and reading one as the
/// other sent every clock/art slide the wrong way. the numbers reach the settings file by name and
/// the ipc only between binaries deployed together, so this order is ours to choose.
pub const Base = enum(u8) {
    clock = 0,
    art = 1,
    canvas = 2,
};

pub const Notify = struct { text: [128]u8, len: u8, colour: [3]u8, since_ns: u64, until_ns: u64, transition: transition.Spec };
pub const Raw = struct { rgb: geometry.Rgb, until_ns: u64, transition: transition.Spec };

pub const Overlay = union(enum) { none, notify: Notify, raw: Raw, stream_arming: u64 };

/// what was showing when the running transition began. the renderer composites it as the
/// effect's old layer, live: the art keeps stepping, the clock ticking, a notification scrolling.
pub const Outgoing = struct { base: Base, generator: scene.Generator, overlay: Overlay, clock_style: clock.Style };

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
    /// how the ip scene lays the address out; a visible change transitions.
    set_ip_mode: ip.Mode,
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
    /// the scene the pending transition leaves, kept live until the renderer reports it finished
    outgoing: ?Outgoing = null,
    last_tick_ns: u64 = 0,
    art: scene.Art,
    clock: clock.State,
    /// the ip address: no longer a base scene, but the device menu has a page for it and the
    /// layout is still a setting, so the state and its four renderings stay here
    ip: ip.State = .{},
    canvas: canvas.State = .{},
    /// the settings menu, drawn over everything and taking every control while it is open
    menu_state: ?menu.Menu = null,
    /// what the menu wants the supervisor to do; the renderer takes it and sends it up
    menu_request: ?menu.Request = null,
    /// the device readouts the info page shows, as last pushed
    device: menu.Status = .{},
    /// when the dial last changed the page of the showing scene; the indicator fades from here
    pages_at: ?u64 = null,

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

    fn capture(self: *const Arbiter) Outgoing {
        return .{ .base = self.base, .generator = self.art.generator, .overlay = self.overlay, .clock_style = self.clock.style };
    }

    /// the renderer finished (or cut short) the transition: the old layer is no longer needed
    pub fn transitionDone(self: *Arbiter) void {
        self.outgoing = null;
    }

    /// the old layer of the running transition, rendered live; false when there is none
    pub fn renderOutgoing(self: *const Arbiter, wall_ns: u64, rgb: *geometry.Rgb) bool {
        const o = self.outgoing orelse return false;
        switch (o.overlay) {
            .notify => |n| self.renderNotify(&n, rgb),
            .raw => |r| rgb.* = r.rgb,
            .stream_arming, .none => {
                switch (o.base) {
                    .art => self.art.renderGenerator(o.generator, rgb),
                    .clock => self.clock.renderWith(o.clock_style, wall_ns, rgb),
                    .canvas => self.canvas.render(self.last_tick_ns, rgb),
                }
                // the same dots as the incoming layer, so a cross-fade leaves them crisp instead
                // of diluting them into the scene underneath
                const set = self.pageSet();
                pages.draw(rgb, set.count, set.index, self.pagesAlpha(self.last_tick_ns));
            },
        }
        return true;
    }

    fn validDuration(d: u16) bool {
        return d >= 1 and d <= 300;
    }

    pub fn apply(self: *Arbiter, cmd: Command, now_ns: u64) Result {
        return self.applyWith(cmd, null, now_ns);
    }

    /// apply a command whose request named a transition (`spec`), or none (the default). a
    /// command that starts a transition remembers what was showing as the outgoing layer.
    pub fn applyWith(self: *Arbiter, cmd: Command, spec: ?transition.Spec, now_ns: u64) Result {
        const before = self.capture();
        const was_pending = self.pending != null;
        const res = self.applyInner(cmd, spec, now_ns);
        if (!was_pending and self.pending != null) self.outgoing = before;
        return res;
    }

    fn applyInner(self: *Arbiter, cmd: Command, spec: ?transition.Spec, now_ns: u64) Result {
        switch (cmd) {
            .set_base => |b| {
                if (b != self.base) {
                    // between the base scenes the default is a slide that follows where their
                    // buttons sit: a scene further right comes in from the right, like pages
                    const forward = @intFromEnum(b) > @intFromEnum(self.base);
                    self.pending = spec orelse .{ .effect = .slide, .direction = if (forward) .left else .right, .duration_ns = self.default_transition.duration_ns };
                } else if (self.overlay != .none) self.mark(spec);
                self.base = b;
                self.overlay = .none;
                return .{ .applied = self.bump() };
            },
            .select_generator => |g| {
                // a generator named alongside a base change must not replace that change's slide
                if (g != self.art.generator and self.pending == null) self.mark(spec);
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
            .set_ip_mode => |m| {
                if (!self.ip.setMode(m)) return .{ .applied = self.revision };
                if (self.menuOpen()) self.dirty = true; // the menu's ip page is what shows it now
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
        if (self.menu_state != null) return self.menuAction(a, now_ns);
        switch (a) {
            .left => _ = self.apply(.{ .set_base = .clock }, now_ns),
            .middle => _ = self.apply(.{ .set_base = .art }, now_ns),
            .right => _ = self.apply(.{ .set_base = .canvas }, now_ns),
            // the knob pages through the current scene: generators in art, faces in the clock. a
            // canvas is whatever was pushed to it and has no pages of its own.
            .rotate_cw, .rotate_ccw => {
                switch (self.base) {
                    .art => _ = self.apply(.{ .select_generator = self.art.neighbour(a == .rotate_cw) }, now_ns),
                    .clock => _ = self.apply(.{ .set_clock_style = .{ .font = cycle(clock.Font, self.clock.style.font, a == .rotate_cw) } }, now_ns),
                    .canvas => return,
                }
                self.pages_at = now_ns;
                self.dirty = true;
            },
            // a short press is the showing scene's own settings; a long one the device's
            .knob_short => self.openSceneMenu(now_ns),
            .knob_long => self.openMenu(now_ns),
        }
    }

    /// the pages the dial walks in the showing scene, and the one it is on
    fn pageSet(self: *const Arbiter) struct { count: usize, index: usize } {
        return switch (self.base) {
            .art => .{ .count = @typeInfo(scene.Generator).@"enum".fields.len, .index = @intFromEnum(self.art.generator) },
            .clock => .{ .count = @typeInfo(clock.Font).@"enum".fields.len, .index = @intFromEnum(self.clock.style.font) },
            .canvas => .{ .count = 0, .index = 0 },
        };
    }

    /// how strongly the page indicator shows right now, 0 when it is not up
    fn pagesAlpha(self: *const Arbiter, now_ns: u64) u8 {
        const at = self.pages_at orelse return 0;
        return pages.alphaAt(now_ns -| at);
    }

    /// what the showing scene can be told. art puts its generator first, then that generator's own.
    pub fn sceneParams(self: *const Arbiter) []const param.Param {
        return switch (self.base) {
            .art => self.art.params(),
            .clock => &clock.params,
            .canvas => &canvas.params,
        };
    }

    pub fn getSceneParam(self: *const Arbiter, index: usize) u32 {
        return switch (self.base) {
            .art => self.art.getParam(index),
            .clock => clock.getParam(self.clock.style, index),
            .canvas => self.canvas.getParam(index),
        };
    }

    /// a parameter of a named generator, whichever one is showing. art's own first parameter is
    /// the generator selector, so the generator's own slots start one along.
    pub fn setGeneratorParam(self: *Arbiter, owner: u8, slot: u8, value: u32) void {
        if (owner >= @typeInfo(scene.Generator).@"enum".fields.len) return;
        const g: scene.Generator = @enumFromInt(owner);
        const was = self.art.generator;
        self.art.generator = g;
        self.art.setParam(@as(usize, slot) + scene.art_params.len, value);
        self.art.generator = was;
        if (g == was) self.dirty = true;
    }

    /// apply it to the showing scene at once: this is the preview, the settings follow on commit
    pub fn setSceneParam(self: *Arbiter, index: usize, value: u32) void {
        switch (self.base) {
            .art => self.art.setParam(index, value),
            .clock => clock.setParam(&self.clock.style, index, value),
            .canvas => self.canvas.setParam(index, value),
        }
        self.dirty = true;
    }

    pub fn menuOpen(self: *const Arbiter) bool {
        return self.menu_state != null;
    }

    /// the settings of whatever is showing, opened by a short press of the knob
    pub fn openSceneMenu(self: *Arbiter, now_ns: u64) void {
        const table = self.sceneParams();
        var values: param.Values = [_]u32{0} ** param.max_per_owner;
        for (table, 0..) |_, i| values[i] = self.getSceneParam(i);
        self.menu_state = menu.Menu.openScene(table, values, now_ns);
        self.dirty = true;
    }

    pub fn openMenu(self: *Arbiter, now_ns: u64) void {
        self.menu_state = menu.Menu.open(.{
            .brightness = self.brightness,
            .clock_font = self.clock.style.font,
            .generator = self.art.generator,
            .ip_mode = self.ip.mode,
            .mqtt = self.device.mqtt_on,
            .ntfy = self.device.ntfy_on,
            .night = self.device.night_on,
            .night_level = self.device.night_level,
        }, self.device, now_ns);
        self.dirty = true;
    }

    fn menuAction(self: *Arbiter, a: scene.Action, now_ns: u64) void {
        const ev: menu.Input = switch (a) {
            .rotate_cw => .next,
            .rotate_ccw => .prev,
            .knob_short => .click,
            .middle => .back,
            .right => .step_up,
            .left => .step_down,
            .knob_long => return, // the stream gesture stays out of the menu
        };
        const m = &(self.menu_state.?);
        self.handleMenu(m.input(ev, now_ns), now_ns);
        self.drainMenuCommit();
    }

    /// a settled change goes up exactly once; the previews that led to it never do
    fn drainMenuCommit(self: *Arbiter) void {
        const m = &(self.menu_state orelse return);
        const r = m.takeReady();
        if (r != .none) self.menu_request = r;
    }

    /// apply the preview of what the menu asked for and keep the durable part for the renderer
    fn handleMenu(self: *Arbiter, r: menu.Request, now_ns: u64) void {
        self.dirty = true;
        switch (r) {
            .none => return,
            .close => {
                self.menu_state = null;
                return;
            },
            .scene_param => |sp| {
                self.setSceneParam(sp.index, sp.value);
            },
            .brightness => |v| {
                self.brightness = v;
            },
            .clock_font => |f| {
                self.clock.style.font = f;
            },
            .generator => |g| self.art.select(g),
            .ip_mode => |m| {
                _ = self.ip.setMode(m);
            },
            .mqtt => |on| {
                self.device.mqtt_on = on;
            },
            // the schedule itself lives in the supervisor: the renderer only keeps what it shows,
            // and the brightness it decides on arrives like any other
            .night => |on| {
                self.device.night_on = on;
            },
            .night_level => |v| {
                self.device.night_level = v;
            },
            .ntfy => |on| {
                self.device.ntfy_on = on;
            },
            .power_off => {
                self.power = false;
            },
            .reseed => self.art.reseed(self.art.seed *% 1664525 +% 1013904223),
            .reboot => {},
        }
        _ = now_ns;
        // only the two actions travel up from here; a value waits until it has settled
        switch (r) {
            .power_off, .reboot => self.menu_request = r,
            else => {},
        }
    }

    /// the renderer takes what the menu asked the supervisor for
    pub fn takeMenuRequest(self: *Arbiter) ?menu.Request {
        const r = self.menu_request;
        self.menu_request = null;
        return r;
    }

    /// the supervisor's periodic push of what the info page reads
    pub fn setDeviceStatus(self: *Arbiter, st: menu.Status) void {
        self.device = st;
        if (self.menu_state) |*m| {
            m.status = st;
            if (m.item == .info) self.dirty = true;
        }
    }

    /// advance time: expire overlays and step the art animation.
    pub fn tick(self: *Arbiter, now_ns: u64, wall_ns: u64) void {
        _ = wall_ns;
        const dt_ns = now_ns -| self.last_tick_ns;
        self.last_tick_ns = now_ns;
        // the menu's own timers: a changed value settles, and an untouched menu closes
        if (self.menu_state) |*m| {
            const r = m.tick(now_ns);
            self.drainMenuCommit();
            self.handleMenu(r, now_ns);
        }
        const dt_s = @as(f32, @floatFromInt(dt_ns)) / @as(f32, s_ns);
        self.art.step(dt_s);
        // an outgoing generator keeps moving through its transition
        if (self.outgoing) |o| if (o.generator != self.art.generator) self.art.stepGenerator(o.generator, dt_s);
        const until: ?u64 = switch (self.overlay) {
            .notify => |n| n.until_ns,
            .raw => |r| r.until_ns,
            .stream_arming => |u| u,
            .none => null,
        };
        if (until) |u| if (now_ns >= u) {
            const before = self.capture();
            const was_pending = self.pending != null;
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
            if (!was_pending and self.pending != null) self.outgoing = before;
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
            .canvas => self.canvas.render(self.last_tick_ns, rgb),
        }
    }

    pub fn render(self: *const Arbiter, wall_ns: u64, rgb: *geometry.Rgb) void {
        if (self.menu_state) |*m| return m.render(self.last_tick_ns, rgb);
        switch (self.overlay) {
            .notify => |n| self.renderNotify(&n, rgb),
            .raw => |r| rgb.* = r.rgb,
            .stream_arming, .none => {
                self.renderBase(wall_ns, rgb);
                const set = self.pageSet();
                pages.draw(rgb, set.count, set.index, self.pagesAlpha(self.last_tick_ns));
            },
        }
    }

    fn renderNotify(self: *const Arbiter, n: *const Notify, rgb: *geometry.Rgb) void {
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
    }

    pub fn cadence(self: *const Arbiter, wall_ns: u64) scene.Cadence {
        // the menu redraws steadily: a value may be scrolling and the commit and idle timers run
        if (self.menu_state != null) return .{ .continuous = 40 * std.time.ns_per_ms };
        // a fading page indicator needs frames of its own, whatever the scene underneath wants
        if (self.pagesAlpha(self.last_tick_ns) > 0) return .{ .continuous = 40 * std.time.ns_per_ms };
        return switch (self.overlay) {
            .notify => |n| if (font.textWidth(n.text[0..n.len]) > geometry.width) .{ .continuous = scroll_period_ns } else .idle,
            .raw => .idle,
            .stream_arming, .none => switch (self.base) {
                .art => self.art.cadence(),
                .clock => self.clock.cadence(wall_ns),
                .canvas => self.canvas.cadence(),
            },
        };
    }
};
