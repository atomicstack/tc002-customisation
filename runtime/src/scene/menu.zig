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
const param = @import("param.zig");
const scene = @import("scene.zig");

pub const Item = enum(u8) {
    brightness = 0,
    night,
    night_level,
    display_off,
    new_seed,
    mqtt,
    ntfy,
    info,
    reboot,
    exit,

    pub fn label(self: Item) []const u8 {
        return switch (self) {
            .brightness => "brightness",
            .night => "night",
            .night_level => "night level",
            .display_off => "display off",
            .new_seed => "new seed",
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
            .brightness, .night, .night_level, .mqtt, .ntfy, .info => true,
            else => false,
        };
    }
};

pub const count = @typeInfo(Item).@"enum".fields.len;

/// the readouts of the info page, in the order the knob walks them
pub const Readout = enum(u8) { address = 0, wifi, battery, time, uptime };

const readout_count = @typeInfo(Readout).@"enum".fields.len;

pub const State = enum { browsing, adjusting, confirming };

/// which menu this is: the device's own settings, or the parameters of the showing scene
pub const Kind = enum { device, scene };

/// an input, whatever produced it: the knob turns and clicks, the buttons step and back out
pub const Input = enum { next, prev, click, step_up, step_down, back };

/// what the menu wants done. the renderer previews it and passes the durable ones up.
pub const Request = union(enum) {
    none,
    close,
    /// a parameter of the showing scene, by its index in that scene's table
    scene_param: struct { index: u8, value: u32 },
    brightness: u8,
    night: bool,
    night_level: u8,
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
    night: bool = false,
    night_level: u8 = 10,
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
    /// the settings the menu toggles; pushed with the rest so the menu opens showing the truth
    mqtt_on: bool = false,
    ntfy_on: bool = false,
    night_on: bool = false,
    night_level: u8 = 10,
    /// the schedule needs a place before it can work out when the sun sets there
    night_placed: bool = false,
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
    kind: Kind = .device,
    /// scene menus only: the table being walked and the values as they stand
    table: []const param.Param = &.{},
    values: param.Values = [_]u32{0} ** param.max_per_owner,
    /// scene menus only: which entry is showing; table.len is the exit at the end
    entry: usize = 0,
    item: Item = .brightness,
    state: State = .browsing,
    settings: Values = .{},
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
        return .{ .kind = .device, .settings = values, .status = status, .last_input_ns = now, .scroll_start_ns = now, .pages_at = now };
    }

    /// the settings of whatever scene is showing, walked straight off its declared table
    pub fn openScene(table: []const param.Param, values: param.Values, now: u64) Menu {
        return .{ .kind = .scene, .table = table, .values = values, .last_input_ns = now, .scroll_start_ns = now, .pages_at = now };
    }

    /// how many things this menu walks, the exit included
    pub fn entries(self: *const Menu) usize {
        return switch (self.kind) {
            .device => count,
            .scene => self.table.len + 1,
        };
    }

    fn onExit(self: *const Menu) bool {
        return self.kind == .scene and self.entry >= self.table.len;
    }

    fn current(self: *const Menu) ?param.Param {
        if (self.kind != .scene or self.onExit()) return null;
        return self.table[self.entry];
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
        if (self.kind == .scene) {
            const p = self.current() orelse return .none;
            const next = p.stepped(self.values[self.entry], forward);
            self.values[self.entry] = next;
            const r = Request{ .scene_param = .{ .index = @intCast(self.entry), .value = next } };
            self.stage(r, now);
            return r;
        }
        switch (self.item) {
            .brightness => {
                const v = self.settings.brightness;
                const next: u8 = if (forward) (if (v >= 100) 100 else v + 10) else (if (v <= 10) 10 else v - 10);
                self.settings.brightness = next;
                self.stage(.{ .brightness = next }, now);
                return .{ .brightness = next };
            },
            .night => {
                self.settings.night = !self.settings.night;
                self.stage(.{ .night = self.settings.night }, now);
                return .{ .night = self.settings.night };
            },
            .night_level => {
                // in fives, but the last step down is to 1: the panel is still legible there and a
                // dark bedroom is what the whole schedule is for
                const v = self.settings.night_level;
                const next: u8 = if (forward) (if (v < 5) 5 else @min(100, v + 5)) else (if (v <= 5) 1 else v - 5);
                self.settings.night_level = next;
                self.stage(.{ .night_level = next }, now);
                return .{ .night_level = next };
            },
            .mqtt => {
                self.settings.mqtt = !self.settings.mqtt;
                self.stage(.{ .mqtt = self.settings.mqtt }, now);
                return .{ .mqtt = self.settings.mqtt };
            },
            .ntfy => {
                self.settings.ntfy = !self.settings.ntfy;
                self.stage(.{ .ntfy = self.settings.ntfy }, now);
                return .{ .ntfy = self.settings.ntfy };
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
        if (self.kind == .scene and self.state != .confirming) return self.sceneInput(ev, now);
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

    /// a scene menu walks its table: the same gestures, fewer kinds of thing to land on
    fn sceneInput(self: *Menu, ev: Input, now: u64) Request {
        switch (self.state) {
            .adjusting => switch (ev) {
                .next, .step_up => return self.step(true, now),
                .prev, .step_down => return self.step(false, now),
                .click, .back => {
                    self.state = .browsing;
                    self.commitNow();
                    return .none;
                },
            },
            else => switch (ev) {
                .next, .prev => {
                    self.commitNow();
                    const n = self.entries();
                    self.entry = if (ev == .next) (self.entry + 1) % n else (self.entry + n - 1) % n;
                    self.pages_at = now;
                    return .none;
                },
                .step_up => return self.step(true, now),
                .step_down => return self.step(false, now),
                .back => {
                    self.commitNow();
                    return .close;
                },
                .click => {
                    if (self.onExit()) {
                        self.commitNow();
                        return .close;
                    }
                    self.state = .adjusting;
                    return .none;
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
            drawLine(rgb, 1, "reboot?", dim, now, self.scroll_start_ns);
            clockfont.blit(rgb, 12, 9, .mini, "no", clockfont.Solid{ .colour = if (self.confirm_yes) dim else bright });
            clockfont.blit(rgb, 30, 9, .mini, "yes", clockfont.Solid{ .colour = if (self.confirm_yes) warn else dim });
            return;
        }
        const colour = if (self.state == .adjusting) amber else bright;
        var buf: [24]u8 = undefined;
        if (self.kind == .scene) {
            const name = if (self.onExit()) "exit" else self.table[self.entry].name;
            drawLine(rgb, 1, name, dim, now, self.scroll_start_ns);
            if (self.current()) |p| {
                if (p.kind == .colour) {
                    // a swatch, because six hex digits tell you nothing about a colour
                    swatch(rgb, param.valueRgb(self.values[self.entry]), self.state == .adjusting);
                } else {
                    drawLine(rgb, 9, p.valueText(self.values[self.entry], &buf), colour, now, self.scroll_start_ns);
                }
            } else {
                drawLine(rgb, 9, "click", colour, now, self.scroll_start_ns);
            }
            pages.draw(rgb, self.entries(), self.entry, pages.alphaAt(now -| self.pages_at));
            return;
        }
        drawLine(rgb, 1, self.item.label(), dim, now, self.scroll_start_ns);
        const text = self.valueText(&buf);
        drawLine(rgb, 9, text, colour, now, self.scroll_start_ns);
        if (self.state == .adjusting and (self.item == .brightness or self.item == .night_level)) {
            const level = if (self.item == .brightness) self.settings.brightness else self.settings.night_level;
            const lit = @as(usize, level) * geometry.width / 100;
            for (0..lit) |x| setPixel(rgb, @intCast(x), 15, colour);
        } else {
            // one dot per item, the current one solid, up only for a while after the last move
            pages.draw(rgb, count, @intFromEnum(self.item), pages.alphaAt(now -| self.pages_at));
        }
    }

    fn valueText(self: *const Menu, buf: []u8) []const u8 {
        return switch (self.item) {
            .brightness => std.fmt.bufPrint(buf, "{d}%", .{self.settings.brightness}) catch "?",
            // on with nowhere to be is the one state worth explaining: the timezone names no
            // place (a bare posix rule) and no latitude and longitude have been set
            .night => if (!self.settings.night) "off" else if (self.status.night_placed) "on" else "no place",
            .night_level => std.fmt.bufPrint(buf, "{d}%", .{self.settings.night_level}) catch "?",
            .mqtt => if (self.settings.mqtt) "on" else "off",
            .ntfy => if (self.settings.ntfy) "on" else "off",
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

/// a block of the colour itself, framed while it is being changed so the edit is obvious
fn swatch(rgb: *geometry.Rgb, c: [3]u8, editing: bool) void {
    const x0: usize = 9;
    const x1: usize = geometry.width - 9;
    for (9..14) |y| {
        for (x0..x1) |x| setPixel(rgb, @intCast(x), @intCast(y), c);
    }
    // always framed: a black colour is a legitimate choice and would otherwise look like an
    // empty screen. the frame turns amber while it is being changed, like any other value.
    const edge = if (editing) amber else dim;
    for (x0 - 1..x1 + 1) |x| {
        setPixel(rgb, @intCast(x), 8, edge);
        setPixel(rgb, @intCast(x), 14, edge);
    }
    for (8..15) |y| {
        setPixel(rgb, @intCast(x0 - 1), @intCast(y), edge);
        setPixel(rgb, @intCast(x1), @intCast(y), edge);
    }
}

/// one line in the 3x5 font, centred, scrolling when it is too wide. the menus use the same small
/// font as the mini clock and the mini ip line: the 5x7 is uncomfortably large read close up.
fn drawLine(rgb: *geometry.Rgb, y: i32, text: []const u8, colour: [3]u8, now: u64, since: u64) void {
    const painter = clockfont.Solid{ .colour = colour };
    const w: i32 = @intCast(clockfont.textWidth(.mini, text));
    if (w <= geometry.width) {
        clockfont.blit(rgb, @divTrunc(geometry.width - w, 2), y, .mini, text, painter);
        return;
    }
    const span = w + 8;
    const elapsed_ms = (now -| since) / ns_per_ms;
    const shift: i32 = @intCast((elapsed_ms / 40) % @as(u64, @intCast(span)));
    clockfont.blit(rgb, 1 - shift, y, .mini, text, painter);
    clockfont.blit(rgb, 1 - shift + span, y, .mini, text, painter);
}

// tests

const ms = 1_000_000;

fn opened() Menu {
    return Menu.open(.{ .brightness = 50, .clock_font = .block, .generator = .popsquares, .ip_mode = .lines, .mqtt = true, .ntfy = false }, .{}, 0);
}

const demo_table = [_]param.Param{
    .{ .name = "shape", .kind = .choice, .choices = &.{ "cube", "ball" }, .default = 0 },
    .{ .name = "speed", .kind = .number, .min = 1, .max = 5, .step = 1, .default = 2 },
    .{ .name = "colour", .kind = .colour, .default = 0xff0000 },
};

test "a scene menu walks a table it has never seen before" {
    var m = Menu.openScene(&demo_table, .{ 0, 2, 0xff0000, 0, 0, 0, 0, 0 }, 0);
    try std.testing.expectEqual(@as(usize, 4), m.entries()); // three parameters and the exit
    try std.testing.expectEqualStrings("shape", m.table[m.entry].name);

    // click to edit, turn to change: the preview comes straight back
    const first = m.input(.click, 0);
    try std.testing.expect(first == .none);
    try std.testing.expectEqual(State.adjusting, m.state);
    const preview = m.input(.next, ms);
    try std.testing.expect(preview == .scene_param and preview.scene_param.value == 1);
    try std.testing.expectEqual(@as(u32, 1), m.values[0]);
    // and, as everywhere else, one request when it settles rather than one per detent
    try std.testing.expect(m.takeReady() == .none);
    _ = m.tick(ms + commit_delay_ns);
    const settled = m.takeReady();
    try std.testing.expect(settled == .scene_param and settled.scene_param.index == 0);

    // a number stops at its ends
    _ = m.input(.click, 0); // back to browsing
    _ = m.input(.next, 0); // speed
    for (0..6) |_| _ = m.input(.step_up, 0);
    try std.testing.expectEqual(@as(u32, 5), m.values[1]);

    // the exit is the last entry and closes
    m.entry = m.table.len;
    try std.testing.expect(m.input(.click, 0) == .close);
}

test "a colour parameter draws the colour rather than its digits" {
    var m = Menu.openScene(&demo_table, .{ 0, 2, 0x00ff00, 0, 0, 0, 0, 0 }, 0);
    m.entry = 2;
    var rgb: geometry.Rgb = undefined;
    m.render(pages.fade_in_ns, &rgb);
    const o = geometry.pixelOffset(geometry.width / 2, 10);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, [3]u8{ rgb[o], rgb[o + 1], rgb[o + 2] });
    // turning walks the wheel, so the swatch changes but stays fully saturated
    _ = m.input(.click, 0);
    _ = m.input(.next, ms);
    m.render(pages.fade_in_ns, &rgb);
    const after = [3]u8{ rgb[o], rgb[o + 1], rgb[o + 2] };
    try std.testing.expect(!std.mem.eql(u8, &[3]u8{ 0, 255, 0 }, &after));
    try std.testing.expectEqual(@as(u8, 255), @max(after[0], @max(after[1], after[2])));
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
    m.item = .display_off;
    try std.testing.expect(m.input(.click, 0) == .power_off);

    m = opened();
    m.item = .exit;
    try std.testing.expect(m.input(.click, 0) == .close);

    m = opened();
    m.item = .new_seed;
    try std.testing.expect(m.input(.click, 0) == .reseed);

    m = opened();
    m.item = .brightness; // an adjustable enters adjusting rather than acting
    try std.testing.expect(m.input(.click, 0) == .none);
    try std.testing.expectEqual(State.adjusting, m.state);
}

test "the night schedule's two items: a toggle and a level that reaches down to one" {
    var m = opened();
    m.item = .night;
    var buf: [16]u8 = undefined;
    m.settings.night = true;
    try std.testing.expectEqualStrings("no place", m.valueText(&buf)); // on, but the timezone names nowhere
    m.status.night_placed = true;
    try std.testing.expectEqualStrings("on", m.valueText(&buf));
    m.settings.night = false;
    try std.testing.expectEqualStrings("off", m.valueText(&buf));
    try std.testing.expect(m.input(.click, 0) == .none); // adjustable, so it enters adjusting
    try std.testing.expect(m.input(.next, ms) == .night);
    try std.testing.expect(m.settings.night);
    try std.testing.expect(m.input(.next, 2 * ms) == .night); // and back off again
    try std.testing.expect(!m.settings.night);

    m = opened();
    m.item = .night_level;
    m.settings.night_level = 10;
    _ = m.input(.click, 0);
    var t: u64 = 0;
    for (0..3) |_| {
        t += 40 * ms;
        _ = m.input(.prev, t);
    }
    try std.testing.expectEqual(@as(u8, 1), m.settings.night_level); // 10, 5, 1, and it stops there
    _ = m.input(.next, t + ms);
    try std.testing.expectEqual(@as(u8, 5), m.settings.night_level);
    // one request when it settles, like every other value
    _ = m.tick(t + ms + commit_delay_ns);
    const settled = m.takeReady();
    try std.testing.expect(settled == .night_level and settled.night_level == 5);
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
    try std.testing.expectEqual(@as(u8, 80), m.settings.brightness);
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
    try std.testing.expectEqual(@as(u8, 100), m.settings.brightness);
}

test "brightness stops at its ends" {
    var m = opened();
    m.settings.brightness = 20;
    _ = m.input(.click, 0);
    _ = m.input(.prev, 0);
    _ = m.input(.prev, 0);
    try std.testing.expectEqual(@as(u8, 10), m.settings.brightness);
    m.settings.brightness = 90;
    _ = m.input(.next, 0);
    _ = m.input(.next, 0);
    try std.testing.expectEqual(@as(u8, 100), m.settings.brightness);
}

test "the buttons change a value in place without entering adjusting" {
    var m = opened();
    m.item = .mqtt;
    const r = m.input(.step_up, 0);
    try std.testing.expect(r == .mqtt and r.mqtt == false); // opened() has mqtt on
    try std.testing.expectEqual(State.browsing, m.state); // still browsing
    _ = m.tick(commit_delay_ns);
    try std.testing.expect(m.takeReady() == .mqtt);
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
