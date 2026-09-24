//! scene arbitration: the base scene (art, clock, ip) plus at most one temporary overlay
//! (notification, raw frame, stream arming). owns the applied state revision. pure.
//!
//! rules from the design: a base selection clears any overlay; a new notification or raw frame
//! replaces the existing overlay unless stacked; expiry promotes the next queued notification or
//! reveals the current base; stream arming waits two
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
pub const notification = @import("notification.zig");

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

test "a stream frame shows at once, expires on its own, and never bumps the revision" {
    var a = Arbiter.init(.clock, .popsquares, 1, tz.utc);
    var frame = geometry.black_rgb;
    frame[0] = 0x7f;
    const before = a.revision;

    // a frame is not a state change: sixty revisions a second would make the number meaningless
    try std.testing.expectEqual(Result{ .applied = before }, a.apply(.{ .stream = .{ .rgb = &frame, .timeout_ms = 500 } }, 0));
    try std.testing.expect(a.overlay == .raw);
    try std.testing.expectEqual(before, a.revision);
    try std.testing.expectEqual(@as(u32, 1), a.stream_frames);

    // still up just before the deadline, gone just after: that is the deadman a dead script needs
    a.tick(400 * std.time.ns_per_ms, 0);
    try std.testing.expect(a.overlay == .raw);
    a.tick(501 * std.time.ns_per_ms, 0);
    try std.testing.expect(a.overlay == .none);

    // two frames between one present is a coalesce, counted rather than hidden
    _ = a.apply(.{ .stream = .{ .rgb = &frame, .timeout_ms = 500 } }, 600 * std.time.ns_per_ms);
    _ = a.apply(.{ .stream = .{ .rgb = &frame, .timeout_ms = 500 } }, 601 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 1), a.stream_coalesced);

    // and the user still wins: a base selection clears the stream
    _ = a.apply(.{ .set_base = .clock }, 700 * std.time.ns_per_ms);
    try std.testing.expect(a.overlay == .none);
}

test "every applied statement is reported once, with the revision it produced" {
    var a = fresh();
    try std.testing.expect(a.takeApplied() == null); // nothing has been applied yet

    _ = a.apply(.{ .brightness = 40 }, 1 * s_ns);
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(Statement.Kind.brightness, st.kind);
    try std.testing.expectEqual(@as(u8, 40), st.brightness);
    try std.testing.expectEqual(a.revision, st.revision);
    try std.testing.expectEqual(@as(u64, 1 * s_ns), st.at_ns);

    // taking it clears it: one report per statement, never a repeat
    try std.testing.expect(a.takeApplied() == null);
}

test "a command that does not move the revision reports no statement" {
    var a = fresh();
    _ = a.takeApplied();

    _ = a.apply(.{ .power = true }, 0); // already on: applied, but nothing changed
    try std.testing.expect(a.takeApplied() == null);

    _ = a.apply(.time_corrected, 0); // redraws, never a state change
    try std.testing.expect(a.takeApplied() == null);

    // a stream frame deliberately does not bump the revision, which is also what keeps sixty
    // frames a second out of the event stream
    var frame = geometry.black_rgb;
    _ = a.apply(.{ .stream = .{ .rgb = &frame, .timeout_ms = 500 } }, 0);
    try std.testing.expect(a.takeApplied() == null);
}

test "a button press reports the statement it produced, not the button" {
    var a = fresh(); // starts on art
    _ = a.takeApplied();

    a.action(.left, 5 * s_ns); // left selects the clock
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(Statement.Kind.set_base, st.kind);
    try std.testing.expectEqual(Base.clock, st.base);
    try std.testing.expectEqual(@as(u64, 5 * s_ns), st.at_ns);
}

test "a statement carries what was resolved, not what was asked for" {
    var a = fresh(); // art, popsquares
    _ = a.takeApplied();

    // the knob asks for "the next generator", never for one by name; the statement names the one
    // it landed on, which is the whole point for a mirror replaying it
    a.action(.rotate_cw, 0);
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(Statement.Kind.select_generator, st.kind);
    try std.testing.expectEqual(a.art.generator, st.generator);
    try std.testing.expect(st.generator != .popsquares);
}

test "a notification statement carries its text, colour and duration" {
    var a = fresh();
    _ = a.takeApplied();

    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 7 } }, 0);
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(Statement.Kind.notify, st.kind);
    try std.testing.expectEqualStrings("hi", st.textSlice());
    try std.testing.expectEqual(white, st.colour);
    try std.testing.expectEqual(@as(u16, 7), st.duration_s);
}

test "only the newest statement is held: a mirror that missed one resyncs from the revision" {
    var a = fresh();
    _ = a.takeApplied();

    _ = a.apply(.{ .brightness = 10 }, 0);
    _ = a.apply(.{ .brightness = 20 }, 1);
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(@as(u8, 20), st.brightness);
    try std.testing.expectEqual(a.revision, st.revision);
    try std.testing.expect(a.takeApplied() == null);
}

test "an overlay expiring is a statement too, not an unexplained revision gap" {
    var a = fresh();
    _ = a.apply(.{ .notify = .{ .text = "hi", .colour = white, .duration_s = 2 } }, 0);
    _ = a.takeApplied();

    // expiry moves the revision from inside `tick`, not `applyWith`. without its own statement a
    // mirror would see the number jump for no reason it could name, and resync for every
    // notification that ever ended.
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
    const st = a.takeApplied() orelse return error.NothingReported;
    try std.testing.expectEqual(Statement.Kind.overlay_expired, st.kind);
    try std.testing.expectEqual(a.revision, st.revision);
    try std.testing.expectEqual(@as(u64, 3 * s_ns), st.at_ns);
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
    try std.testing.expect(a.cadence(1788739200 * s_ns + 5 * s_ns) == .at_wall_ns); // a set clock: 5 s past the epoch is one that has never been set
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
    try std.testing.expectEqual(scene.Generator.terrain, a.art.generator);
    a.action(.rotate_cw, 0);
    try std.testing.expectEqual(scene.Generator.popsquares, a.art.generator); // all the way round
    var before: geometry.Rgb = undefined;
    a.render(0, &before);
    // holding the showing base's own button opens its settings, which take every control
    a.action(.middle_long, 0);
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

    // and neither emits a statement -- not because they are filtered out, but because they never
    // moved the revision in the first place. so a mirror following the event stream sees no event
    // *and no gap*: a dhcp renewal or an sntp correction costs it nothing at all. a replica that
    // wants the new address reads it from `/status`, which is where the address lives.
    try std.testing.expectEqual(@as(u32, 0), a.revision);
    try std.testing.expect(a.takeApplied() == null);
}

test "a transition away from the canvas carries the frame it last showed, not the document as it stands" {
    var a = fresh();
    _ = a.apply(.{ .set_base = .canvas }, 0);
    _ = a.takeTransition(); // the renderer ran the arrival, so the next change captures the canvas
    // one lit pixel is a whole document; render it, and that is what the panel is showing
    try a.canvas.doc.add(.{ .box = .{ .x = 10, .y = 5 }, .colour = white, .body = .pixel });
    var shown: geometry.Rgb = undefined;
    a.render(0, &shown);
    const lit = (5 * geometry.width + 10) * 3;
    try std.testing.expectEqual(@as(u8, 255), shown[lit]);

    // the document goes before the scene does, which is the order a client naturally writes:
    // clear what you put there, then hand the panel back. the outgoing layer must not notice.
    a.canvas.doc.clear();
    _ = a.apply(.{ .set_base = .clock }, 0);
    var old: geometry.Rgb = undefined;
    try std.testing.expect(a.renderOutgoing(0, &old));
    try std.testing.expectEqualSlices(u8, &shown, &old);
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

/// how long a notification or a raw frame may be asked to stay up. the console cannot know how
/// much of a running notification is left, so it asks for the maximum and lets the arbiter expire it.
pub const min_duration_s: u16 = 1;
pub const max_duration_s: u16 = 300;

pub const Notify = notification.Entry;
pub const Raw = struct { rgb: geometry.Rgb, until_ns: u64, transition: transition.Spec };

pub const Overlay = union(enum) { none, notify: Notify, raw: Raw, stream_arming: u64 };

/// what was showing when the running transition began. the renderer composites it as the
/// effect's old layer, live: the art keeps stepping, the clock ticking, a notification scrolling.
pub const Outgoing = struct { base: Base, generator: scene.Generator, overlay: Overlay, clock_style: clock.Style, notify_canvas: canvas.State = .{} };

pub const Command = union(enum) {
    set_base: Base,
    select_generator: scene.Generator,
    notify: struct { text: []const u8, colour: [3]u8, duration_s: u16, name: []const u8 = "", stack: bool = false, hold: bool = false, doc: ?*const canvas.Document = null },
    dismiss_notify: []const u8,
    raw: struct { rgb: *const geometry.Rgb, duration_s: u16 },
    /// one frame of a stream: the same overlay slot as `raw`, a deadline in milliseconds rather
    /// than seconds, and no revision bump
    stream: struct { rgb: *const geometry.Rgb, timeout_ms: u16 },
    brightness: u8,
    /// the same, eased on the panel over `ms` from wherever the panel is; the target is the
    /// state at once, the ease is presentation. the night schedule uses it, so its first level
    /// after a boot arrives the way an evening does rather than as a step
    brightness_ramp: struct { value: u8, ms: u16 },
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

/// what the arbiter just applied, in a form that survives leaving this process: a mirror applies
/// the same statement and lands on the same revision. **resolved, not requested** -- the generator
/// the knob arrived at, the seed the arbiter actually took, the style after the patch. that is what
/// lets a replica replay it with no special cases.
///
/// big payloads are described rather than carried: a `raw` frame says how long the overlay holds,
/// not which pixels, because 2,496 bytes per statement would not fit the ipc and a mirror that
/// wants the pixels can read `/screen`.
pub const Statement = struct {
    pub const Kind = enum(u8) {
        set_base = 0,
        select_generator = 1,
        notify = 2,
        raw = 3,
        brightness = 4,
        reseed = 5,
        arm_stream = 6,
        power = 7,
        set_clock_style = 8,
        set_ip_mode = 9,
        /// an overlay reached its deadline and the next notification or base came back. it moves the
        /// revision from inside `tick` rather than `applyWith`, and it is a real state change, so
        /// it gets a statement of its own instead of leaving a mirror with an unexplained gap.
        overlay_expired = 10,
        dismiss_notify = 11,
    };
    pub const text_max = 128;

    kind: Kind,
    /// the revision this statement produced; a mirror that skips one sees the gap here
    revision: u32 = 0,
    /// when it was applied, on the renderer's monotonic clock
    at_ns: u64 = 0,

    base: Base = .clock,
    generator: scene.Generator = .popsquares,
    seed: u32 = 0,
    brightness: u8 = 0,
    power: bool = true,
    ip_mode: ip.Mode = .lines,
    style: clock.Style = .{},
    /// how long a notification or raw frame holds the overlay
    duration_s: u16 = 0,
    colour: [3]u8 = .{ 0, 0, 0 },
    name: notification.Name = .{},
    stack: bool = false,
    hold: bool = false,
    text_len: u8 = 0,
    text: [text_max]u8 = [_]u8{0} ** text_max,
    /// the notification is a document; `text` is its summary
    rich: bool = false,
    /// a brightness that eases over this many milliseconds; 0 lands at once
    ramp_ms: u16 = 0,

    pub fn textSlice(self: *const Statement) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub const Reject = enum { invalid_text, invalid_duration, invalid_brightness, invalid_name, invalid_elements, queue_full };
pub const Result = union(enum) { applied: u32, rejected: Reject };

pub const Arbiter = struct {
    base: Base,
    overlay: Overlay = .none,
    notifications: notification.Waiting = .{},
    revision: u32 = 0,
    brightness: u8 = 100,
    /// a brightness ramp in flight: from what level, since when, for how long
    brightness_from: u8 = 100,
    brightness_ramp_at: ?u64 = null,
    brightness_ramp_ns: u64 = 0,
    power: bool = true,
    /// frames accepted on the stream, and how many were overwritten before they could be shown
    stream_frames: u32 = 0,
    stream_coalesced: u32 = 0,

    /// set whenever the visible output changed; the renderer takes it to redraw immediately.
    dirty: bool = true,
    /// the statement last applied, waiting to be taken. only the newest is held: a consumer that
    /// misses one sees a revision gap and resyncs, which is cheaper than a queue that can overrun.
    applied: ?Statement = null,
    /// set when what is shown changes to something else (base, generator, a notification
    /// starting or ending, a restyle of the showing clock); the renderer takes it to run the
    /// effect. raw frames switch at once unless their request names an effect.
    pending: ?transition.Spec = null,
    /// the transition a change gets when the request names none (the renderer sets its duration)
    default_transition: transition.Spec = .{},
    /// the scene the pending transition leaves, kept live until the renderer reports it finished
    outgoing: ?Outgoing = null,
    /// the last frame the canvas scene rendered. the other bases are re-rendered live for their
    /// outgoing layer, which keeps a departing clock ticking; the canvas cannot be, because the
    /// document behind it belongs to a client that has usually already replaced or cleared it by
    /// the time the transition runs. so the canvas layer leaves as the frame it last showed.
    canvas_frame: geometry.Rgb = geometry.black_rgb,
    last_tick_ns: u64 = 0,
    art: scene.Art,
    clock: clock.State,
    /// the ip address: no longer a base scene, but the device menu has a page for it and the
    /// layout is still a setting, so the state and its four renderings stay here
    ip: ip.State = .{},
    canvas: canvas.State = .{},
    /// the active rich notification's document and animation clocks; empty while a text one shows
    notify_canvas: canvas.State = .{},
    /// the settings menu, drawn over everything and taking every control while it is open
    menu_state: ?menu.Menu = null,
    /// what the menu wants the supervisor to do; the renderer takes it and sends it up
    menu_request: ?menu.Request = null,
    /// the device readouts the info page shows, as last pushed
    device: menu.Status = .{},
    /// when the dial last changed the page of the showing scene; the indicator fades from here
    pages_at: ?u64 = null,
    /// when the clock was last synced; the clock face's separators pulse once from here
    separator_pulse_at: ?u64 = null,

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
        return .{ .base = self.base, .generator = self.art.generator, .overlay = self.overlay, .clock_style = self.clock.style, .notify_canvas = self.notify_canvas };
    }

    /// the renderer finished (or cut short) the transition: the old layer is no longer needed
    pub fn transitionDone(self: *Arbiter) void {
        self.outgoing = null;
    }

    /// the old layer of the running transition, rendered live; false when there is none
    pub fn renderOutgoing(self: *const Arbiter, wall_ns: u64, rgb: *geometry.Rgb) bool {
        const o = self.outgoing orelse return false;
        switch (o.overlay) {
            .notify => |n| if (n.doc != null) o.notify_canvas.renderWith(&self.canvas.sprites, self.last_tick_ns, rgb) else self.renderNotify(&n, rgb),
            .raw => |r| rgb.* = r.rgb,
            .stream_arming, .none => {
                switch (o.base) {
                    .art => self.art.renderGenerator(o.generator, rgb),
                    .clock => self.clock.renderWith(o.clock_style, wall_ns, self.brightness, rgb),
                    .canvas => rgb.* = self.canvas_frame,
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
        return d >= min_duration_s and d <= max_duration_s;
    }

    pub fn apply(self: *Arbiter, cmd: Command, now_ns: u64) Result {
        return self.applyWith(cmd, null, now_ns);
    }

    /// apply a command whose request named a transition (`spec`), or none (the default). a
    /// command that starts a transition remembers what was showing as the outgoing layer.
    pub fn applyWith(self: *Arbiter, cmd: Command, spec: ?transition.Spec, now_ns: u64) Result {
        const before = self.capture();
        const was_pending = self.pending != null;
        const revision_before = self.revision;
        const res = self.applyInner(cmd, spec, now_ns);
        if (!was_pending and self.pending != null) self.outgoing = before;
        // every command from every source reaches this one function, so this is the only place a
        // statement has to be recorded. a command that changed nothing left the revision alone and
        // is not a statement -- that is what keeps stream frames and clock ticks off the wire.
        if (self.revision != revision_before) self.recordApplied(cmd, now_ns);
        return res;
    }

    fn recordApplied(self: *Arbiter, cmd: Command, now_ns: u64) void {
        var st = Statement{ .kind = undefined, .revision = self.revision, .at_ns = now_ns };
        switch (cmd) {
            .set_base => {
                st.kind = .set_base;
                st.base = self.base;
            },
            .select_generator => {
                st.kind = .select_generator;
                st.generator = self.art.generator;
            },
            .notify => |n| {
                st.kind = .notify;
                st.colour = n.colour;
                st.duration_s = n.duration_s;
                st.name = notification.Name.init(n.name);
                st.stack = n.stack;
                st.hold = n.hold;
                st.rich = n.doc != null;
                st.text_len = @intCast(@min(n.text.len, Statement.text_max));
                @memcpy(st.text[0..st.text_len], n.text[0..st.text_len]);
            },
            .dismiss_notify => |name| {
                st.kind = .dismiss_notify;
                st.name = notification.Name.init(name);
            },
            .raw => |r| {
                st.kind = .raw;
                st.duration_s = r.duration_s;
            },
            .brightness => {
                st.kind = .brightness;
                st.brightness = self.brightness;
            },
            .brightness_ramp => |r| {
                st.kind = .brightness;
                st.brightness = self.brightness;
                st.ramp_ms = if (self.brightness_ramp_at != null) r.ms else 0;
            },
            .reseed => {
                st.kind = .reseed;
                st.seed = self.art.seed;
            },
            .arm_stream => st.kind = .arm_stream,
            .power => {
                st.kind = .power;
                st.power = self.power;
            },
            .set_clock_style => {
                st.kind = .set_clock_style;
                st.style = self.clock.style;
            },
            .set_ip_mode => {
                st.kind = .set_ip_mode;
                st.ip_mode = self.ip.mode;
            },
            // these never move the revision, so they never reach here: a stream frame is not a
            // state change, and a clock correction or a new ip address only redraws
            .stream, .time_corrected, .ip_changed => return,
        }
        self.applied = st;
    }

    /// take the statement last applied, if one is waiting. mirrors `takeDirty` and
    /// `takeTransition`: the renderer drains it once per loop and forwards it.
    pub fn takeApplied(self: *Arbiter) ?Statement {
        const a = self.applied;
        self.applied = null;
        return a;
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
                self.notifications.len = 0;
                self.overlay = .none;
                self.notify_canvas = .{};
                return .{ .applied = self.bump() };
            },
            .select_generator => |g| {
                // a generator named alongside a base change must not replace that change's slide
                if (g != self.art.generator and self.pending == null) self.mark(spec);
                self.art.select(g);
                return .{ .applied = self.bump() };
            },
            .notify => |n| {
                if (n.doc) |d| {
                    if (d.empty()) return .{ .rejected = .invalid_elements };
                } else if (n.text.len == 0) return .{ .rejected = .invalid_text };
                if (n.text.len > 128) return .{ .rejected = .invalid_text };
                for (n.text) |c| if (c < 0x20 or c > 0x7e) return .{ .rejected = .invalid_text };
                if (!validDuration(n.duration_s)) return .{ .rejected = .invalid_duration };
                if (n.name.len != 0 and !notification.validName(n.name)) return .{ .rejected = .invalid_name };
                const t = spec orelse self.default_transition;
                var o = Notify{ .text = undefined, .len = @intCast(n.text.len), .colour = n.colour, .name = notification.Name.init(n.name), .duration_s = n.duration_s, .hold = n.hold, .since_ns = now_ns, .until_ns = now_ns + @as(u64, n.duration_s) * s_ns, .transition = t, .doc = if (n.doc) |d| d.* else null };
                @memcpy(o.text[0..n.text.len], n.text);
                if (n.stack and self.overlay == .notify) {
                    if (!self.notifications.push(o)) return .{ .rejected = .queue_full };
                    self.revision +%= 1;
                    return .{ .applied = self.revision };
                }
                self.overlay = .{ .notify = o };
                self.activateNotification(&o, now_ns);
                self.pending = t;
                return .{ .applied = self.bump() };
            },
            .dismiss_notify => |name| {
                if (name.len != 0 and !notification.validName(name)) return .{ .rejected = .invalid_name };
                if (self.overlay == .notify and (name.len == 0 or std.mem.eql(u8, name, self.overlay.notify.name.slice()))) {
                    self.advanceNotification(now_ns);
                    return .{ .applied = self.bump() };
                }
                if (name.len != 0) for (self.notifications.entries[0..self.notifications.len], 0..) |*n, i| {
                    if (std.mem.eql(u8, name, n.name.slice())) {
                        _ = self.notifications.remove(i);
                        self.revision +%= 1;
                        return .{ .applied = self.revision };
                    }
                };
                return .{ .applied = self.revision };
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
                self.notifications.len = 0;
                self.notify_canvas = .{};
                self.overlay = .{ .raw = .{ .rgb = r.rgb.*, .until_ns = now_ns + @as(u64, r.duration_s) * s_ns, .transition = t } };
                if (!t.instant()) self.pending = t;
                return .{ .applied = self.bump() };
            },
            .stream => |st| {
                // a frame already waiting to be presented is being overwritten: that is a coalesce,
                // and counting it is the difference between "the device is slow" and "you are
                // sending faster than sixty a second, which it cannot show"
                if (self.dirty and self.overlay == .raw) self.stream_coalesced +|= 1;
                self.notifications.len = 0;
                self.notify_canvas = .{};
                self.overlay = .{ .raw = .{ .rgb = st.rgb.*, .until_ns = now_ns + @as(u64, st.timeout_ms) * std.time.ns_per_ms, .transition = transition.Spec.cut } };
                self.stream_frames +|= 1;
                self.dirty = true;
                // deliberately not bump(): a frame is not a state change, and sixty of them a
                // second would leave the revision meaning nothing at all
                return .{ .applied = self.revision };
            },
            .brightness => |b| {
                if (b < 1 or b > 100) return .{ .rejected = .invalid_brightness };
                self.brightness = b;
                self.brightness_ramp_at = null;
                return .{ .applied = self.bump() };
            },
            .brightness_ramp => |r| {
                if (r.value < 1 or r.value > 100) return .{ .rejected = .invalid_brightness };
                // from wherever the panel is right now, which mid-ramp is not the old target
                self.brightness_from = self.shownAt(now_ns);
                self.brightness = r.value;
                if (r.ms == 0) {
                    self.brightness_ramp_at = null;
                } else {
                    self.brightness_ramp_at = now_ns;
                    self.brightness_ramp_ns = @as(u64, r.ms) * std.time.ns_per_ms;
                }
                return .{ .applied = self.bump() };
            },
            .reseed => |seed| {
                self.art.reseed(seed);
                return .{ .applied = self.bump() };
            },
            .arm_stream => {
                self.notifications.len = 0;
                self.notify_canvas = .{};
                self.overlay = .{ .stream_arming = now_ns + arming_wait_ns };
                return .{ .applied = self.bump() };
            },
            .time_corrected => {
                // a redraw, never a state change; and one pulse of the separators, so a sync is
                // visible on the face without being a notification
                self.dirty = true;
                self.separator_pulse_at = now_ns;
                return .{ .applied = self.revision };
            },
            .ip_changed => |addr| {
                if (self.ip.set(addr)) self.dirty = true;
                return .{ .applied = self.revision };
            },
        }
    }

    pub fn action(self: *Arbiter, a: scene.Action, now_ns: u64) void {
        // holding a base button is the same gesture wherever you are, menu open or not: it shows
        // that base and opens its settings. a hold is never a menu keystroke, so nothing collides,
        // and holding another base's button walks straight from one scene's settings to the next.
        switch (a) {
            .left_long => return self.baseSettings(.clock, now_ns),
            .middle_long => return self.baseSettings(.art, now_ns),
            .right_long => return self.baseSettings(.canvas, now_ns),
            else => {},
        }
        if (self.menu_state != null) return self.menuAction(a, now_ns);
        switch (a) {
            .left => _ = self.apply(.{ .set_base = .clock }, now_ns),
            .middle => _ = self.apply(.{ .set_base = .art }, now_ns),
            .right => _ = self.apply(.{ .set_base = .canvas }, now_ns),
            .left_long, .middle_long, .right_long => unreachable, // answered above
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
            // the dial's click belongs to whatever is showing; its hold is the device's own menu
            .knob_short => self.sceneClick(now_ns),
            .knob_long => self.openMenu(now_ns),
        }
    }

    /// show a base and open its settings: one gesture, so the settings you are editing are always
    /// the settings of the thing you are looking at.
    fn baseSettings(self: *Arbiter, base: Base, now_ns: u64) void {
        _ = self.apply(.{ .set_base = base }, now_ns);
        self.openSceneMenu(now_ns);
    }

    /// what a click on the dial means to the scene that is showing.
    ///
    /// it used to open the scene menu, which is now a hold on that scene's own button -- and that
    /// left the click free for the scene itself, which is where a click on a picture belongs. art
    /// takes a new seed from it. the clock and the canvas have nothing to do with one yet, and this
    /// is the seam where that goes.
    fn sceneClick(self: *Arbiter, now_ns: u64) void {
        switch (self.base) {
            .art => _ = self.apply(.{ .reseed = self.art.seed *% 1664525 +% 1013904223 }, now_ns),
            .clock, .canvas => {},
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

    /// the separators' alpha at this instant: 255 unless a sync pulse is running
    fn separatorAlpha(self: *const Arbiter, now_ns: u64) u8 {
        const at = self.separator_pulse_at orelse return 255;
        return clock.pulseAlpha(now_ns -| at);
    }

    /// frames are wanted for the whole pulse, including the one that settles the face after it
    fn separatorPulsing(self: *const Arbiter, now_ns: u64) bool {
        const at = self.separator_pulse_at orelse return false;
        return now_ns -| at < clock.pulse_ns;
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
        var values: param.PageValues = [_]u32{0} ** param.max_per_page;
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
            .knob_long => return, // the device menu is not reachable from inside a menu
            .left_long, .middle_long, .right_long => unreachable, // answered before the menu sees it
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
            // the menu has done its job, and it has to get out of the way: `render` gives the menu
            // the panel ahead of every overlay, so leaving it open painted over the supervisor's
            // "rebooting..." frame on every frame of the way down. the answer was yes; the device
            // is going.
            .reboot => self.menu_state = null,
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
        if (self.brightness_ramp_at) |at| if (now_ns >= at + self.brightness_ramp_ns) {
            self.brightness_ramp_at = null;
        };
        const dt_s = @as(f32, @floatFromInt(dt_ns)) / @as(f32, s_ns);
        self.art.step(dt_s);
        // an outgoing generator keeps moving through its transition
        if (self.outgoing) |o| if (o.generator != self.art.generator) self.art.stepGenerator(o.generator, dt_s);
        const until: ?u64 = switch (self.overlay) {
            .notify => |n| if (n.hold) null else n.until_ns,
            .raw => |r| r.until_ns,
            .stream_arming => |u| u,
            .none => null,
        };
        if (until) |u| if (now_ns >= u) {
            _ = self.expireOverlay(now_ns);
        };
    }

    /// expire exactly one overlay, either from the local timer or an authoritative mirror event.
    /// mirror events may precede a locally calculated deadline after a late frame promoted it.
    pub fn expireOverlay(self: *Arbiter, now_ns: u64) bool {
        if (self.overlay == .none) return false;
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
        if (self.overlay == .notify) self.advanceNotification(now_ns) else self.overlay = .none;
        _ = self.bump();
        self.applied = .{ .kind = .overlay_expired, .revision = self.revision, .at_ns = now_ns };
        if (!was_pending and self.pending != null) self.outgoing = before;
        return true;
    }

    /// when the current overlay expires, so the loop can arm a timer for it.
    pub fn nextExpiryNs(self: *const Arbiter) ?u64 {
        return switch (self.overlay) {
            .notify => |n| if (n.hold) null else n.until_ns,
            .raw => |r| r.until_ns,
            .stream_arming => |u| u,
            .none => null,
        };
    }

    /// promote one waiting entry at the time it actually becomes visible.
    fn advanceNotification(self: *Arbiter, now_ns: u64) void {
        const current = self.overlay.notify;
        if (self.notifications.len > 0) {
            var next = self.notifications.remove(0);
            next.since_ns = now_ns;
            next.until_ns = now_ns + @as(u64, next.duration_s) * s_ns;
            self.overlay = .{ .notify = next };
            self.activateNotification(&next, now_ns);
            self.pending = next.transition;
        } else {
            self.overlay = .none;
            self.notify_canvas = .{};
            self.pending = current.transition.outgoing();
        }
    }

    /// a document notification starts its animations the moment it is shown, whether it arrived
    /// now or waited in the queue: an arrival animation that ran out while waiting would be lost
    fn activateNotification(self: *Arbiter, e: *const Notify, now_ns: u64) void {
        self.notify_canvas = .{};
        if (e.doc) |d| self.notify_canvas.install(d, now_ns);
    }

    /// the brightness the panel shows: the target, or a point on the way to it while a ramp runs
    pub fn shownBrightness(self: *const Arbiter) u8 {
        return self.shownAt(self.last_tick_ns);
    }

    fn shownAt(self: *const Arbiter, now_ns: u64) u8 {
        const at = self.brightness_ramp_at orelse return self.brightness;
        const elapsed = now_ns -| at;
        if (elapsed >= self.brightness_ramp_ns or self.brightness_ramp_ns == 0) return self.brightness;
        const from: i64 = self.brightness_from;
        const to: i64 = self.brightness;
        const p: i64 = @intCast(elapsed * 256 / self.brightness_ramp_ns);
        return @intCast(from + @divTrunc((to - from) * p, 256));
    }

    fn renderBase(self: *Arbiter, wall_ns: u64, rgb: *geometry.Rgb) void {
        switch (self.base) {
            .art => self.art.render(rgb),
            .clock => self.clock.renderPulsed(self.clock.style, wall_ns, self.separatorAlpha(self.last_tick_ns), self.brightness, rgb),
            .canvas => {
                self.canvas.render(self.last_tick_ns, rgb);
                self.canvas_frame = rgb.*;
            },
        }
    }

    pub fn render(self: *Arbiter, wall_ns: u64, rgb: *geometry.Rgb) void {
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
        if (n.doc != null) {
            self.notify_canvas.renderWith(&self.canvas.sprites, self.last_tick_ns, rgb);
            return;
        }
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
        // so does a brightness easing towards its target
        if (self.brightness_ramp_at != null) return .{ .continuous = scene.frame_period_ns };
        // so does a separator pulse, which the clock's own once-a-second cadence would miss entirely
        if (self.base == .clock and self.separatorPulsing(self.last_tick_ns)) return .{ .continuous = scene.frame_period_ns };
        return switch (self.overlay) {
            .notify => |n| if (n.doc != null) self.notify_canvas.cadence(self.last_tick_ns) else if (font.textWidth(n.text[0..n.len]) > geometry.width) .{ .continuous = scroll_period_ns } else .idle,
            .raw => .idle,
            .stream_arming, .none => switch (self.base) {
                .art => self.art.cadence(),
                .clock => self.clock.cadence(wall_ns),
                .canvas => self.canvas.cadence(self.last_tick_ns),
            },
        };
    }
};

test "a hold opens that base's settings, and the dial's click belongs to the scene" {
    var a = fresh();

    // holding a base button is one gesture doing the whole job: show that base, open its settings
    a.action(.left_long, 0);
    try std.testing.expect(a.base == .clock);
    try std.testing.expect(a.menuOpen());
    try std.testing.expectEqual(menu.Kind.scene, a.menu_state.?.kind);

    // and it works from inside another scene's settings, so the three holds walk between them
    a.action(.right_long, 0);
    try std.testing.expect(a.base == .canvas);
    try std.testing.expect(a.menuOpen());
    try std.testing.expectEqual(menu.Kind.scene, a.menu_state.?.kind);
    a.action(.middle, 0); // back out
    try std.testing.expect(!a.menuOpen());

    // the dial's click is the scene's own now. art takes a new seed from it and no menu opens --
    // opening one is what the hold is for.
    a.action(.middle, 0);
    try std.testing.expect(a.base == .art);
    const seed = a.art.seed;
    a.action(.knob_short, 0);
    try std.testing.expect(a.art.seed != seed);
    try std.testing.expect(!a.menuOpen());

    // the clock has nothing to do with a click yet, and quietly does nothing rather than surprising
    a.action(.left, 0);
    a.action(.knob_short, 0);
    try std.testing.expect(a.base == .clock);
    try std.testing.expect(!a.menuOpen());

    // and the dial's hold is still the device's own menu
    a.action(.knob_long, 0);
    try std.testing.expect(a.menuOpen());
    try std.testing.expectEqual(menu.Kind.device, a.menu_state.?.kind);
}

test "confirming a reboot closes the menu, so the notice that follows is not drawn under it" {
    // the menu outranks every overlay in `render`, and a reboot is confirmed *from* the menu. so
    // while the menu stayed open the supervisor's "rebooting..." frame went out, was accepted, and
    // was painted over by the menu on every frame. matt watched the panel through a reboot and saw
    // no banner; /screen returned the menu frame for the whole window.
    var a = fresh();
    a.openMenu(0);
    a.menu_state.?.item = .reboot;
    a.action(.knob_short, 0); // opens the "reboot?" dialogue, defaulting to no
    try std.testing.expect(a.menu_state != null);
    a.action(.rotate_cw, 10 * std.time.ns_per_ms); // no -> yes
    a.action(.knob_short, 20 * std.time.ns_per_ms); // confirm
    try std.testing.expect(a.takeMenuRequest().? == .reboot);
    try std.testing.expect(a.menu_state == null); // and the menu is gone

    // so a frame pushed after it is what the panel shows
    var frame = geometry.black_rgb;
    frame[0] = 200;
    try std.testing.expect(a.apply(.{ .raw = .{ .rgb = &frame, .duration_s = 3 } }, 30 * std.time.ns_per_ms) == .applied);
    var rgb: geometry.Rgb = undefined;
    a.render(30 * std.time.ns_per_ms, &rgb);
    try std.testing.expectEqualSlices(u8, &frame, &rgb);
}

test "answering no to a reboot leaves the menu open, and asks for nothing" {
    var a = fresh();
    a.openMenu(0);
    a.menu_state.?.item = .reboot;
    a.action(.knob_short, 0);
    a.action(.knob_short, 10 * std.time.ns_per_ms); // the dialogue defaults to no
    try std.testing.expect(a.takeMenuRequest() == null);
    try std.testing.expect(a.menu_state != null);
}

test "a time correction pulses the clock's separators once and then leaves the face as it was" {
    var a = Arbiter.init(.clock, .popsquares, 1, tz.utc);
    const wall: u64 = 1_800_000_000 * std.time.ns_per_s + 300 * std.time.ns_per_ms;
    const t0: u64 = 10 * std.time.ns_per_s;
    a.tick(t0, wall);
    var before = geometry.black_rgb;
    a.render(wall, &before);
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = clock.nextBoundaryWallNs(wall) }, a.cadence(wall));
    _ = a.apply(.time_corrected, t0);
    // mid-pulse: frames every period, and the face differs from the steady one
    a.tick(t0 + clock.pulse_ns / 2, wall);
    try std.testing.expectEqual(scene.Cadence{ .continuous = scene.frame_period_ns }, a.cadence(wall));
    var mid = geometry.black_rgb;
    a.render(wall, &mid);
    try std.testing.expect(!std.mem.eql(u8, &before, &mid));
    // over: back to the boundary cadence and the identical frame
    a.tick(t0 + clock.pulse_ns + std.time.ns_per_ms, wall);
    try std.testing.expectEqual(scene.Cadence{ .at_wall_ns = clock.nextBoundaryWallNs(wall) }, a.cadence(wall));
    var after = geometry.black_rgb;
    a.render(wall, &after);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

fn queuedTestCommand(text: []const u8, name: []const u8, stack: bool, hold: bool, seconds: u16) Command {
    return .{ .notify = .{ .text = text, .colour = white, .duration_s = seconds, .name = name, .stack = stack, .hold = hold } };
}

fn dismissForTest(a: *Arbiter, name: []const u8, now: u64) Result {
    return a.apply(.{ .dismiss_notify = name }, now);
}

test "queued notification waits and gets its full duration after promotion" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("first", "a", false, false, 2), 0);
    _ = a.takeTransition();
    _ = a.takeDirty();
    _ = a.apply(queuedTestCommand("second", "b", true, false, 3), s_ns);
    try std.testing.expectEqualStrings("first", a.overlay.notify.text[0..a.overlay.notify.len]);
    try std.testing.expect(a.takeTransition() == null);
    a.tick(2 * s_ns, 0);
    try std.testing.expectEqualStrings("second", a.overlay.notify.text[0..a.overlay.notify.len]);
    a.tick(4 * s_ns, 0);
    try std.testing.expect(a.overlay == .notify);
    a.tick(5 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
}

test "held notification survives time and dismissal reveals the waiting one" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("held", "door", false, true, 1), 0);
    a.tick(3600 * s_ns, 0);
    try std.testing.expect(a.overlay == .notify);
    _ = a.apply(queuedTestCommand("next", "next", true, false, 2), 3600 * s_ns);
    _ = dismissForTest(&a, "door", 3601 * s_ns);
    try std.testing.expectEqualStrings("next", a.overlay.notify.text[0..a.overlay.notify.len]);
    a.tick(3603 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
}

test "named dismissal removes a waiting notification without disturbing the active one" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("first", "a", false, true, 1), 0);
    _ = a.apply(queuedTestCommand("second", "b", true, false, 2), 0);
    _ = dismissForTest(&a, "b", 0);
    try std.testing.expectEqualStrings("first", a.overlay.notify.text[0..a.overlay.notify.len]);
    _ = dismissForTest(&a, "a", 0);
    try std.testing.expect(a.overlay == .none);
}

test "notification queue capacity refuses overflow without losing an accepted entry" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("active", "a", true, true, 1), 0);
    for (0..notification.capacity - 1) |_| _ = a.apply(queuedTestCommand("waiting", "b", true, false, 1), 0);
    const revision = a.revision;
    try expectRejected(a.apply(queuedTestCommand("overflow", "c", true, false, 1), 0), .queue_full);
    try std.testing.expectEqual(revision, a.revision);
    try std.testing.expectEqual(notification.capacity - 1, a.notifications.len);
    try std.testing.expectEqualStrings("active", a.overlay.notify.text[0..a.overlay.notify.len]);
    // the original replacement operation still works when every slot is occupied.
    _ = a.apply(queuedTestCommand("replacement", "r", false, true, 1), 0);
    try std.testing.expectEqual(notification.capacity - 1, a.notifications.len);
    _ = dismissForTest(&a, "", 0);
    try std.testing.expectEqualStrings("waiting", a.overlay.notify.text[0..a.overlay.notify.len]);
}

test "named dismissal is first-match and missing names do not move revision" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("one", "same", true, true, 1), 0);
    _ = a.apply(queuedTestCommand("two", "same", true, true, 1), 0);
    const revision = a.revision;
    _ = a.takeApplied();
    _ = dismissForTest(&a, "absent", 0);
    try std.testing.expectEqual(revision, a.revision);
    try std.testing.expect(a.takeApplied() == null);
    _ = dismissForTest(&a, "same", 0);
    try std.testing.expectEqualStrings("two", a.overlay.notify.text[0..a.overlay.notify.len]);
    const st = a.takeApplied().?;
    try std.testing.expectEqual(Statement.Kind.dismiss_notify, st.kind);
    try std.testing.expectEqualStrings("same", st.name.slice());
    try std.testing.expectEqual(revision + 1, st.revision);
}

test "scene frame and stream takeover clear pending notifications but power does not" {
    var frame = geometry.black_rgb;
    const commands = [_]Command{ .{ .set_base = .clock }, .{ .raw = .{ .rgb = &frame, .duration_s = 1 } }, .{ .stream = .{ .rgb = &frame, .timeout_ms = 100 } }, .arm_stream };
    for (commands) |cmd| {
        var a = fresh();
        _ = a.apply(queuedTestCommand("one", "a", true, true, 1), 0);
        _ = a.apply(queuedTestCommand("two", "b", true, true, 1), 0);
        _ = a.apply(cmd, 0);
        try std.testing.expectEqual(@as(usize, 0), a.notifications.len);
        a.tick(400 * s_ns, 0);
        try std.testing.expect(a.overlay == .none);
    }
    var a = fresh();
    _ = a.apply(queuedTestCommand("one", "a", true, true, 1), 0);
    _ = a.apply(queuedTestCommand("two", "b", true, false, 1), 0);
    _ = a.apply(.{ .power = false }, 0);
    a.tick(400 * s_ns, 0);
    try std.testing.expectEqualStrings("one", a.overlay.notify.text[0..a.overlay.notify.len]);
    try std.testing.expectEqual(@as(usize, 1), a.notifications.len);
}

test "waiting dismissal keeps the transition and display timer unchanged" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("one", "a", true, false, 3), 0);
    _ = a.takeTransition();
    _ = a.takeDirty();
    _ = a.apply(queuedTestCommand("two", "b", true, true, 1), s_ns);
    _ = dismissForTest(&a, "b", 2 * s_ns);
    try std.testing.expect(a.takeTransition() == null);
    try std.testing.expect(!a.takeDirty());
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.overlay == .none);
    try std.testing.expectEqual(Statement.Kind.overlay_expired, a.takeApplied().?.kind);
}

fn richDoc(text: []const u8) canvas.Document {
    var d = canvas.Document{};
    const span = d.addText(text) catch unreachable;
    d.add(.{ .id = canvas.Id.init("t"), .box = .{ .x = 0, .y = 5, .w = 52, .h = 5 }, .colour = .{ 255, 128, 0 }, .body = .{ .text = .{ .span = span, .face = .mini, .alignment = .centre } }, .anim = .{ .kind = .typewriter, .ms = 1000 } }) catch unreachable;
    return d;
}

fn richCommand(doc: *const canvas.Document, name: []const u8, stack: bool, hold: bool, seconds: u16) Command {
    return .{ .notify = .{ .text = "", .colour = white, .duration_s = seconds, .name = name, .stack = stack, .hold = hold, .doc = doc } };
}

fn litPixels(rgb: *const geometry.Rgb) usize {
    var n: usize = 0;
    for (rgb) |v| n += @intFromBool(v != 0);
    return n;
}

test "a rich notification draws its document and records a rich statement" {
    var a = fresh();
    const doc = richDoc("hello");
    try std.testing.expect(a.apply(richCommand(&doc, "", false, false, 5), 0) == .applied);
    const st = a.takeApplied().?;
    try std.testing.expectEqual(Statement.Kind.notify, st.kind);
    try std.testing.expect(st.rich);
    try std.testing.expectEqual(@as(u8, 0), st.text_len);
    a.tick(2 * s_ns, 0);
    var rgb: geometry.Rgb = undefined;
    a.render(0, &rgb);
    try std.testing.expect(litPixels(&rgb) > 0);
    // orange, from the element, not white from the notify colour
    var orange = false;
    var i: usize = 0;
    while (i < rgb.len) : (i += 3) if (rgb[i] == 255 and rgb[i + 1] == 128 and rgb[i + 2] == 0) {
        orange = true;
    };
    try std.testing.expect(orange);
}

test "a rich notification without text or elements is invalid, and text stays bounded" {
    var a = fresh();
    try expectRejected(a.apply(.{ .notify = .{ .text = "", .colour = white, .duration_s = 5 } }, 0), .invalid_text);
    const empty = canvas.Document{};
    try expectRejected(a.apply(richCommand(&empty, "", false, false, 5), 0), .invalid_elements);
}

test "a queued rich notification starts its animation when promoted, not when queued" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("first", "a", false, false, 1), 0);
    const doc = richDoc("second");
    _ = a.apply(richCommand(&doc, "b", true, false, 5), 0);
    // the typewriter is 1000 ms long; at promotion (t = 1 s) it is at its start
    a.tick(1 * s_ns, 0);
    try std.testing.expect(a.overlay == .notify and a.overlay.notify.doc != null);
    try std.testing.expectEqual(@as(u32, 0), a.notify_canvas.clocks.docAgeMs(1 * s_ns));
    var early: geometry.Rgb = undefined;
    a.render(0, &early);
    a.tick(1 * s_ns + 900 * std.time.ns_per_ms, 0);
    var late: geometry.Rgb = undefined;
    a.render(0, &late);
    try std.testing.expect(litPixels(&late) > litPixels(&early));
}

test "a rich notification leaving through a transition keeps its own document on the outgoing layer" {
    var a = fresh();
    const first = richDoc("AAAAAAAAAA");
    _ = a.apply(richCommand(&first, "a", false, false, 5), 0);
    // the renderer ran the arrival effect
    a.pending = null;
    a.transitionDone();
    a.tick(2 * s_ns, 0);
    var shown: geometry.Rgb = undefined;
    a.render(0, &shown);
    const second = richDoc("B");
    _ = a.apply(richCommand(&second, "b", false, false, 5), 2 * s_ns);
    try std.testing.expect(a.outgoing != null);
    var out: geometry.Rgb = undefined;
    try std.testing.expect(a.renderOutgoing(0, &out));
    // the outgoing layer is the first document, fully typed, not the second at its first frame
    try std.testing.expectEqualSlices(u8, &shown, &out);
    var now: geometry.Rgb = undefined;
    a.render(0, &now);
    try std.testing.expect(litPixels(&now) < litPixels(&out));
}

test "a rich notification has the canvas cadence and a text one keeps its own" {
    var a = fresh();
    const doc = richDoc("x");
    _ = a.apply(richCommand(&doc, "", false, false, 5), 0);
    try std.testing.expect(a.cadence(0) == .continuous); // the typewriter is running
    a.tick(3 * s_ns, 0);
    try std.testing.expect(a.cadence(0) == .idle); // and has finished
    _ = a.apply(queuedTestCommand("short", "", false, false, 5), 3 * s_ns);
    try std.testing.expect(a.cadence(0) == .idle);
}

test "a text notification is unchanged by the document field" {
    var a = fresh();
    _ = a.apply(queuedTestCommand("hi", "", false, false, 5), 0);
    try std.testing.expect(a.overlay.notify.doc == null);
    const st = a.takeApplied().?;
    try std.testing.expect(!st.rich);
    try std.testing.expectEqualStrings("hi", st.textSlice());
}

test "a ramped brightness eases what is shown while the target is reported at once" {
    // on the clock base, whose own cadence is once a second, so the ramp's continuous frames show
    var a = Arbiter.init(.clock, .popsquares, 1, tz.utc);
    // a set clock, or the unset face's blinking separator is a continuous cadence of its own
    const wall: u64 = 1_700_000_000 * s_ns;
    _ = a.apply(.{ .brightness = 100 }, 0);
    try std.testing.expectEqual(@as(u8, 100), a.shownBrightness());
    _ = a.takeApplied();
    _ = a.apply(.{ .brightness_ramp = .{ .value = 20, .ms = 2000 } }, 10 * s_ns);
    // the target is the state; the ease is presentation
    try std.testing.expectEqual(@as(u8, 20), a.brightness);
    const st = a.takeApplied().?;
    try std.testing.expectEqual(Statement.Kind.brightness, st.kind);
    try std.testing.expectEqual(@as(u8, 20), st.brightness);
    try std.testing.expectEqual(@as(u16, 2000), st.ramp_ms);
    a.tick(10 * s_ns, 0);
    try std.testing.expectEqual(@as(u8, 100), a.shownBrightness());
    try std.testing.expect(a.cadence(wall) == .continuous);
    a.tick(11 * s_ns, 0);
    const mid = a.shownBrightness();
    try std.testing.expect(mid > 20 and mid < 100);
    try std.testing.expectEqual(@as(u8, 60), mid);
    a.tick(12 * s_ns, 0);
    try std.testing.expectEqual(@as(u8, 20), a.shownBrightness());
    try std.testing.expect(a.cadence(wall) != .continuous);
    // an instant brightness lands at once and cancels a ramp in flight
    _ = a.apply(.{ .brightness_ramp = .{ .value = 80, .ms = 2000 } }, 20 * s_ns);
    _ = a.apply(.{ .brightness = 50 }, 21 * s_ns);
    a.tick(21 * s_ns, 0);
    try std.testing.expectEqual(@as(u8, 50), a.shownBrightness());
    // a ramp that starts during a ramp eases from where the panel is, not from the old target
    _ = a.apply(.{ .brightness_ramp = .{ .value = 100, .ms = 1000 } }, 30 * s_ns);
    a.tick(30 * s_ns + 500 * std.time.ns_per_ms, 0);
    try std.testing.expectEqual(@as(u8, 75), a.shownBrightness());
    _ = a.apply(.{ .brightness_ramp = .{ .value = 1, .ms = 1000 } }, 30 * s_ns + 500 * std.time.ns_per_ms);
    a.tick(31 * s_ns, 0);
    try std.testing.expectEqual(@as(u8, 38), a.shownBrightness()); // halfway from 75 to 1, the floor of the range
    // a ramp of zero is a plain brightness
    _ = a.apply(.{ .brightness_ramp = .{ .value = 33, .ms = 0 } }, 40 * s_ns);
    a.tick(40 * s_ns, 0);
    try std.testing.expectEqual(@as(u8, 33), a.shownBrightness());
}
