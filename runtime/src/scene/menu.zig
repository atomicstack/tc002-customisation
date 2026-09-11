//! the on-device settings menu: one item at a time on a 52x16 panel, driven by the knob.
//!
//! the knob click opens it, turning moves between items, and a click acts on the one showing.
//! the three buttons work too: left and right change a value in place, middle backs out. every
//! change applies at once as a live preview and is committed a moment later, so a knob spin sends
//! one request rather than one per detent, and the settings file is written once per burst.
//!
//! this module is pure: it renders into a buffer and returns what it wants done. the renderer
//! applies the preview and forwards the request to the supervisor, which owns the settings.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const ip = @import("ip.zig");
const pages = @import("pages.zig");
const scene = @import("scene.zig");

pub const Item = enum(u8) {
    brightness = 0,
    display_off,
    clock_face,
    art_scene,
    ip_layout,
    new_seed,
    mqtt,
    ntfy,
    info,
    reboot,
    exit,

    pub fn label(self: Item) []const u8 {
        return switch (self) {
            .brightness => "bright",
            .display_off => "sleep",
            .clock_face => "face",
            .art_scene => "art",
            .ip_layout => "ip",
            .new_seed => "seed",
            .mqtt => "mqtt",
            .ntfy => "ntfy",
            .info => "info",
            .reboot => "reboot",
            .exit => "exit",
        };
    }

    /// items whose value the knob or the left/right buttons can change
    fn adjustable(self: Item) bool {
        return switch (self) {
            .brightness, .clock_face, .art_scene, .ip_layout, .mqtt, .ntfy, .info => true,
            else => false,
        };
    }
};

pub const count = @typeInfo(Item).@"enum".fields.len;

/// the readouts of the info page, in the order the knob walks them
pub const Readout = enum(u8) { address = 0, wifi, battery, time, uptime };

const readout_count = @typeInfo(Readout).@"enum".fields.len;

pub const State = enum { browsing, adjusting, confirming };

/// an input, whatever produced it: the knob turns and clicks, the buttons step and back out
pub const Input = enum { next, prev, click, step_up, step_down, back };

/// what the menu wants done. the renderer previews it and passes the durable ones up.
pub const Request = union(enum) {
    none,
    close,
    brightness: u8,
    clock_font: clockfont.Font,
    generator: scene.Generator,
    ip_mode: ip.Mode,
    mqtt: bool,
    ntfy: bool,
    power_off,
    reseed,
    reboot,
};

/// the settings the menu shows and edits, as they are when it opens
pub const Values = struct {
    brightness: u8 = 100,
    clock_font: clockfont.Font = .classic,
    generator: scene.Generator = .popsquares,
    ip_mode: ip.Mode = .lines,
    mqtt: bool = false,
    ntfy: bool = false,
};

/// what the info page reads; the supervisor pushes it, so any field may be unknown
pub const Status = struct {
    address: ?[4]u8 = null,
    battery_pct: u8 = 255,
    usb: u8 = 255,
    wifi_quality: u8 = 255,
    wifi_dbm: i16 = -32768,
    time_synced: bool = false,
    uptime_s: u32 = 0,
    /// the two settings the menu toggles; pushed with the rest so the menu opens showing the truth
    mqtt_on: bool = false,
    ntfy_on: bool = false,
};

const ns_per_ms = 1_000_000;
/// a value settles this long after the last change, then one request goes up
pub const commit_delay_ns = 700 * ns_per_ms;
/// with nothing touched for this long the menu closes, keeping whatever is on the panel
pub const idle_close_ns = 15_000 * ns_per_ms;

const dim: [3]u8 = .{ 96, 96, 96 };
const bright: [3]u8 = .{ 255, 255, 255 };
const amber: [3]u8 = .{ 255, 128, 0 };
const warn: [3]u8 = .{ 255, 32, 32 };

pub const Menu = struct {
    item: Item = .brightness,
    state: State = .browsing,
    values: Values = .{},
    status: Status = .{},
    readout: Readout = .address,
    /// the highlighted answer of the reboot dialogue; it starts on no every time
    confirm_yes: bool = false,
    /// when the pending change should be sent up, if one is pending
    commit_at: ?u64 = null,
    /// what to send when it settles
    pending: Request = .none,
    /// a change that has settled and is waiting to be taken and sent up, exactly once
    ready: Request = .none,
    last_input_ns: u64 = 0,
    scroll_start_ns: u64 = 0,
    /// when the item last changed; the dot row fades in from there and away again
    pages_at: u64 = 0,

    pub fn open(values: Values, status: Status, now: u64) Menu {
        return .{ .values = values, .status = status, .last_input_ns = now, .scroll_start_ns = now, .pages_at = now };
    }

    fn touch(self: *Menu, now: u64) void {
        self.last_input_ns = now;
        self.scroll_start_ns = now;
    }

    fn stage(self: *Menu, r: Request, now: u64) void {
        self.pending = r;
        self.commit_at = now + commit_delay_ns;
    }

    /// a staged change is done being fiddled with: move it where the caller will find it. called
    /// when it settles, on a click, on walking to another item and on the way out.
    fn commitNow(self: *Menu) void {
        if (self.pending != .none) self.ready = self.pending;
        self.pending = .none;
        self.commit_at = null;
    }

    /// the settled change, once. a preview never comes out of here, so a knob spin sends one
    /// request rather than one per detent.
    pub fn takeReady(self: *Menu) Request {
        const r = self.ready;
        self.ready = .none;
        return r;
    }

    /// step the current item's value; the change previews at once and is staged for the commit
    fn step(self: *Menu, forward: bool, now: u64) Request {
        switch (self.item) {
            .brightness => {
                const v = self.values.brightness;
                const next: u8 = if (forward) (if (v >= 100) 100 else v + 10) else (if (v <= 10) 10 else v - 10);
                self.values.brightness = next;
                self.stage(.{ .brightness = next }, now);
                return .{ .brightness = next };
            },
            .clock_face => {
                self.values.clock_font = cycle(clockfont.Font, self.values.clock_font, forward);
                self.stage(.{ .clock_font = self.values.clock_font }, now);
                return .{ .clock_font = self.values.clock_font };
            },
            .art_scene => {
                self.values.generator = cycle(scene.Generator, self.values.generator, forward);
                self.stage(.{ .generator = self.values.generator }, now);
                return .{ .generator = self.values.generator };
            },
            .ip_layout => {
                self.values.ip_mode = cycle(ip.Mode, self.values.ip_mode, forward);
                self.stage(.{ .ip_mode = self.values.ip_mode }, now);
                return .{ .ip_mode = self.values.ip_mode };
            },
            .mqtt => {
                self.values.mqtt = !self.values.mqtt;
                self.stage(.{ .mqtt = self.values.mqtt }, now);
                return .{ .mqtt = self.values.mqtt };
            },
            .ntfy => {
                self.values.ntfy = !self.values.ntfy;
                self.stage(.{ .ntfy = self.values.ntfy }, now);
                return .{ .ntfy = self.values.ntfy };
            },
            .info => {
                self.readout = cycle(Readout, self.readout, forward);
                return .none;
            },
            else => return .none,
        }
    }

    pub fn input(self: *Menu, ev: Input, now: u64) Request {
        self.touch(now);
        switch (self.state) {
            .confirming => {
                switch (ev) {
                    .next, .prev, .step_up, .step_down => self.confirm_yes = !self.confirm_yes,
                    .back => self.state = .browsing,
                    .click => {
                        const yes = self.confirm_yes;
                        self.state = .browsing;
                        self.confirm_yes = false;
                        if (yes) return .reboot;
                    },
                }
                return .none;
            },
            .adjusting => switch (ev) {
                .next, .step_up => return self.step(true, now),
                .prev, .step_down => return self.step(false, now),
                .click, .back => {
                    self.state = .browsing;
                    self.commitNow();
                    return .none;
                },
            },
            .browsing => switch (ev) {
                // the knob walks the list; a value is left where it is
                .next, .prev => {
                    self.commitNow(); // a half-changed item is not abandoned by walking on
                    self.item = cycle(Item, self.item, ev == .next);
                    self.pages_at = now;
                    return .none;
                },
                // the buttons change the showing item's value without entering adjusting
                .step_up => return self.step(true, now),
                .step_down => return self.step(false, now),
                .back => {
                    self.commitNow();
                    return .close;
                },
                .click => switch (self.item) {
                    .exit => {
                        self.commitNow();
                        return .close;
                    },
                    .display_off => return .power_off,
                    .new_seed => return .reseed,
                    .reboot => {
                        self.state = .confirming;
                        self.confirm_yes = false;
                        return .none;
                    },
                    .mqtt, .ntfy => return self.step(true, now),
                    else => {
                        if (self.item.adjustable()) self.state = .adjusting;
                        return .none;
                    },
                },
            },
        }
    }

    /// time passing: a staged change settles, and an untouched menu closes
    pub fn tick(self: *Menu, now: u64) Request {
        if (self.commit_at) |at| if (now >= at) self.commitNow();
        if (now -| self.last_input_ns >= idle_close_ns) {
            self.commitNow(); // what is on the panel is what is kept
            if (self.state == .confirming) {
                // a timeout answers no, and the menu still goes away
                self.state = .browsing;
                self.confirm_yes = false;
            }
            return .close;
        }
        return .none;
    }

    /// the menu redraws while a value scrolls or a dialogue is up
    pub fn animated(self: *const Menu) bool {
        return self.state == .adjusting or self.state == .confirming or self.item == .info;
    }

    /// the dot row is still fading, so the menu needs frames even if nothing else moves
    pub fn indicatorShowing(self: *const Menu, now: u64) bool {
        return pages.alphaAt(now -| self.pages_at) > 0;
    }

    pub fn render(self: *const Menu, now: u64, rgb: *geometry.Rgb) void {
        @memset(rgb, 0);
        if (self.state == .confirming) {
            drawLine(rgb, 0, "reboot?", dim, now, self.scroll_start_ns);
            font.blit(rgb, 6, 8, "no", if (self.confirm_yes) dim else bright);
            font.blit(rgb, 28, 8, "yes", if (self.confirm_yes) warn else dim);
            return;
        }
        drawLine(rgb, 0, self.item.label(), dim, now, self.scroll_start_ns);
        var buf: [24]u8 = undefined;
        const text = self.valueText(&buf);
        const colour = if (self.state == .adjusting) amber else bright;
        drawLine(rgb, 8, text, colour, now, self.scroll_start_ns);
        if (self.state == .adjusting and self.item == .brightness) {
            const lit = @as(usize, self.values.brightness) * geometry.width / 100;
            for (0..lit) |x| setPixel(rgb, @intCast(x), 15, colour);
        } else {
            // one dot per item, the current one solid, up only for a while after the last move
            pages.draw(rgb, count, @intFromEnum(self.item), pages.alphaAt(now -| self.pages_at));
        }
    }

    fn valueText(self: *const Menu, buf: []u8) []const u8 {
        return switch (self.item) {
            .brightness => std.fmt.bufPrint(buf, "{d}%", .{self.values.brightness}) catch "?",
            .clock_face => @tagName(self.values.clock_font),
            .art_scene => @tagName(self.values.generator),
            .ip_layout => @tagName(self.values.ip_mode),
            .mqtt => if (self.values.mqtt) "on" else "off",
            .ntfy => if (self.values.ntfy) "on" else "off",
            .info => self.readoutText(buf),
            .display_off => "click",
            .new_seed => "click",
            .reboot => "click",
            .exit => "click",
        };
    }

    fn readoutText(self: *const Menu, buf: []u8) []const u8 {
        const s = self.status;
        return switch (self.readout) {
            .address => if (s.address) |a| (std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch "?") else "no address",
            .wifi => if (s.wifi_quality != 255) (std.fmt.bufPrint(buf, "wifi {d}%", .{s.wifi_quality}) catch "?") else "wifi ?",
            .battery => if (s.battery_pct != 255)
                (std.fmt.bufPrint(buf, "bat {d}%{s}", .{ s.battery_pct, if (s.usb == 1) " usb" else "" }) catch "?")
            else if (s.usb == 1) "usb power" else "bat ?",
            .time => if (s.time_synced) "time synced" else "time unset",
            .uptime => uptimeText(s.uptime_s, buf),
        };
    }
};

fn uptimeText(seconds: u32, buf: []u8) []const u8 {
    const days = seconds / 86400;
    const hours = (seconds % 86400) / 3600;
    const minutes = (seconds % 3600) / 60;
    if (days > 0) return std.fmt.bufPrint(buf, "up {d}d {d}h", .{ days, hours }) catch "?";
    if (hours > 0) return std.fmt.bufPrint(buf, "up {d}h {d}m", .{ hours, minutes }) catch "?";
    return std.fmt.bufPrint(buf, "up {d}m", .{minutes}) catch "?";
}

fn cycle(comptime E: type, v: E, forward: bool) E {
    const n = @typeInfo(E).@"enum".fields.len;
    const i: usize = @intFromEnum(v);
    const next = if (forward) (i + 1) % n else (i + n - 1) % n;
    return @enumFromInt(next);
}

fn setPixel(rgb: *geometry.Rgb, x: i32, y: i32, colour: [3]u8) void {
    if (x < 0 or y < 0 or x >= geometry.width or y >= geometry.height) return;
    const i = (@as(usize, @intCast(y)) * geometry.width + @as(usize, @intCast(x))) * 3;
    rgb[i] = colour[0];
    rgb[i + 1] = colour[1];
    rgb[i + 2] = colour[2];
}

/// one line of text in the only font with letters, centred, scrolling when it is too wide
fn drawLine(rgb: *geometry.Rgb, y: i32, text: []const u8, colour: [3]u8, now: u64, since: u64) void {
    const w: i32 = @intCast(font.textWidth(text));
    if (w <= geometry.width) {
        font.blit(rgb, @divTrunc(geometry.width - w, 2), y, text, colour);
        return;
    }
    const span = w + 8;
    const elapsed_ms = (now -| since) / ns_per_ms;
    const shift: i32 = @intCast((elapsed_ms / 40) % @as(u64, @intCast(span)));
    font.blit(rgb, 1 - shift, y, text, colour);
    font.blit(rgb, 1 - shift + span, y, text, colour);
}

// tests

const ms = 1_000_000;

fn opened() Menu {
    return Menu.open(.{ .brightness = 50, .clock_font = .block, .generator = .popsquares, .ip_mode = .lines, .mqtt = true, .ntfy = false }, .{}, 0);
}

test "the knob walks the list, wrapping, and exit sits one click back from the top" {
    var m = opened();
    try std.testing.expectEqual(Item.brightness, m.item);
    _ = m.input(.prev, 0);
    try std.testing.expectEqual(Item.exit, m.item);
    _ = m.input(.next, 0);
    try std.testing.expectEqual(Item.brightness, m.item);
    for (0..count) |_| _ = m.input(.next, 0);
    try std.testing.expectEqual(Item.brightness, m.item); // all the way round
}

test "a click acts on the item showing" {
    var m = opened();
    _ = m.input(.next, 0); // display off
    try std.testing.expectEqual(Item.display_off, m.item);
    try std.testing.expect(m.input(.click, 0) == .power_off);

    m = opened();
    m.item = .exit;
    try std.testing.expect(m.input(.click, 0) == .close);

    m = opened();
    m.item = .new_seed;
    try std.testing.expect(m.input(.click, 0) == .reseed);

    m = opened();
    m.item = .clock_face; // an adjustable enters adjusting rather than acting
    try std.testing.expect(m.input(.click, 0) == .none);
    try std.testing.expectEqual(State.adjusting, m.state);
}

test "a knob spin previews every step but sends one request when it settles" {
    var m = opened();
    _ = m.input(.click, 0); // adjust the brightness
    try std.testing.expectEqual(State.adjusting, m.state);
    var t: u64 = 0;
    for (0..3) |_| {
        t += 40 * ms;
        const r = m.input(.next, t);
        try std.testing.expect(r == .brightness); // the preview follows every detent
    }
    try std.testing.expectEqual(@as(u8, 80), m.values.brightness);
    // nothing has gone up yet, and nothing goes up until the value settles
    _ = m.tick(t + 100 * ms);
    try std.testing.expect(m.takeReady() == .none);
    _ = m.tick(t + commit_delay_ns);
    const settled = m.takeReady();
    try std.testing.expect(settled == .brightness and settled.brightness == 80);
    // and only once
    _ = m.tick(t + 10 * commit_delay_ns);
    try std.testing.expect(m.takeReady() == .none);
}

test "every detent previews but only the settled value is ever handed over" {
    // the device wrote the settings file once per detent before the preview and the commit were
    // told apart: three clicks of the knob produced three writes.
    var m = opened();
    _ = m.input(.click, 0);
    var t: u64 = 0;
    var handed: usize = 0;
    for (0..5) |_| {
        t += 30 * ms;
        _ = m.input(.next, t);
        if (m.takeReady() != .none) handed += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), handed);
    _ = m.tick(t + commit_delay_ns);
    try std.testing.expect(m.takeReady() != .none);
    try std.testing.expectEqual(@as(u8, 100), m.values.brightness);
}

test "brightness stops at its ends" {
    var m = opened();
    m.values.brightness = 20;
    _ = m.input(.click, 0);
    _ = m.input(.prev, 0);
    _ = m.input(.prev, 0);
    try std.testing.expectEqual(@as(u8, 10), m.values.brightness);
    m.values.brightness = 90;
    _ = m.input(.next, 0);
    _ = m.input(.next, 0);
    try std.testing.expectEqual(@as(u8, 100), m.values.brightness);
}

test "the buttons change a value in place without entering adjusting" {
    var m = opened();
    m.item = .ip_layout;
    const r = m.input(.step_up, 0);
    try std.testing.expect(r == .ip_mode and r.ip_mode == .mini);
    try std.testing.expectEqual(State.browsing, m.state); // still browsing
    _ = m.tick(commit_delay_ns);
    try std.testing.expect(m.takeReady() == .ip_mode);
    // and middle backs out of the menu entirely
    try std.testing.expect(m.input(.back, 0) == .close);
}

test "moving off a half-changed item still sends the change" {
    var m = opened();
    m.item = .mqtt;
    _ = m.input(.step_down, 0); // mqtt off, staged
    try std.testing.expect(m.input(.next, 10 * ms) == .none); // walk on before it settled
    const carried = m.takeReady();
    try std.testing.expect(carried == .mqtt and carried.mqtt == false);
    try std.testing.expectEqual(Item.ntfy, m.item);
    _ = m.tick(10 * commit_delay_ns);
    try std.testing.expect(m.takeReady() == .none); // not sent twice
}

test "reboot asks first, defaults to no, and a timeout answers no" {
    var m = opened();
    m.item = .reboot;
    try std.testing.expect(m.input(.click, 0) == .none);
    try std.testing.expectEqual(State.confirming, m.state);
    try std.testing.expect(!m.confirm_yes);
    try std.testing.expect(m.input(.click, ms) == .none); // no was highlighted
    try std.testing.expectEqual(State.browsing, m.state);

    _ = m.input(.click, 2 * ms); // ask again
    _ = m.input(.next, 3 * ms); // highlight yes
    try std.testing.expect(m.confirm_yes);
    try std.testing.expect(m.input(.click, 4 * ms) == .reboot);

    _ = m.input(.click, 5 * ms); // ask again and walk away
    const timed_out = m.tick(5 * ms + idle_close_ns);
    try std.testing.expect(timed_out == .close);
    try std.testing.expectEqual(State.browsing, m.state);
}

test "an untouched menu closes, and an adjustment in progress is kept" {
    var m = opened();
    _ = m.input(.click, 0);
    _ = m.input(.next, ms); // brightness 60, staged
    _ = m.tick(ms + commit_delay_ns);
    try std.testing.expect(m.takeReady() == .brightness);
    try std.testing.expect(m.tick(ms + idle_close_ns) == .close);
}

test "the info page walks its readouts and reads the pushed status" {
    var m = Menu.open(.{}, .{ .address = .{ 10, 0, 0, 111 }, .battery_pct = 80, .usb = 1, .wifi_quality = 49, .time_synced = true, .uptime_s = 3 * 86400 + 4 * 3600 }, 0);
    m.item = .info;
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.0.111", m.valueText(&buf));
    _ = m.input(.click, 0); // a click enters the page; the knob then walks the readouts
    try std.testing.expectEqual(State.adjusting, m.state);
    _ = m.input(.next, 0);
    try std.testing.expectEqualStrings("wifi 49%", m.valueText(&buf));
    _ = m.input(.next, 0);
    try std.testing.expectEqualStrings("bat 80% usb", m.valueText(&buf));
    _ = m.input(.next, 0);
    try std.testing.expectEqualStrings("time synced", m.valueText(&buf));
    _ = m.input(.next, 0);
    try std.testing.expectEqualStrings("up 3d 4h", m.valueText(&buf));
    _ = m.input(.next, 0); // wraps
    try std.testing.expectEqualStrings("10.0.0.111", m.valueText(&buf));
    // an unknown status says so rather than showing a wrong number
    _ = m.tick(10 * commit_delay_ns);
    try std.testing.expect(m.takeReady() == .none); // a readout is not a setting
    var blank = Menu.open(.{}, .{}, 0);
    blank.item = .info;
    try std.testing.expectEqualStrings("no address", blank.valueText(&buf));
}

test "a browsing frame shows the label, the value and the position dots" {
    var m = opened();
    var rgb: geometry.Rgb = undefined;
    const up = pages.fade_in_ns + pages.hold_ns / 2; // while the indicator is up
    m.render(up, &rgb);
    try std.testing.expect(!std.mem.eql(u8, &geometry.black_rgb, &rgb));
    // the dot row carries one dot per item
    var dots: usize = 0;
    for (0..geometry.width) |x| {
        const i = geometry.pixelOffset(x, 15);
        if (rgb[i] > 0 or rgb[i + 1] > 0 or rgb[i + 2] > 0) dots += 1;
    }
    try std.testing.expectEqual(count, dots);
    // and it goes away on its own, leaving the row to the content
    m.render(pages.total_ns, &rgb);
    for (0..geometry.width) |x| {
        const i = geometry.pixelOffset(x, 15);
        try std.testing.expectEqual(@as(u8, 0), rgb[i] | rgb[i + 1] | rgb[i + 2]);
    }
    try std.testing.expect(!m.indicatorShowing(pages.total_ns));
    // turning brings it back
    _ = m.input(.next, pages.total_ns);
    try std.testing.expect(m.indicatorShowing(pages.total_ns + pages.fade_in_ns));
    // adjusting the brightness replaces the dots with a bar and turns the value amber
    m.item = .brightness;
    _ = m.input(.click, 0);
    var adj: geometry.Rgb = undefined;
    m.render(0, &adj);
    var lit: usize = 0;
    for (0..geometry.width) |x| {
        const i = geometry.pixelOffset(x, 15);
        if (adj[i] > 0) lit += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), lit); // 50% of 52
}
