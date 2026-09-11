//! scene parameters: every scene declares what it can be told, and nothing else needs to know what
//! any of it means. the on-panel menus, the `/scenes` catalogue and the web console all walk the
//! same tables, so a new scene writes one table and gets settings everywhere.
//!
//! a value is always a u32: a choice is its index, a number is itself, a colour is 0x00RRGGBB and
//! a toggle is 0 or 1.
const std = @import("std");

/// the most parameters one scene may declare; the settings reserve this many slots for each
pub const max_per_owner = 8;

pub const Kind = enum(u8) { choice, number, colour, toggle };

/// who owns a set of generic parameter slots. the clock and the ip scene are fixed parts of the
/// runtime and have named settings of their own; generators are pluggable, so their parameters
/// live in these slots instead. the order is the storage layout, so new generators go on the end.
pub const Owner = enum(u8) { popsquares = 0, plasma = 1, cube = 2 };

pub const owner_count = @typeInfo(Owner).@"enum".fields.len;

pub const Param = struct {
    name: []const u8,
    kind: Kind,
    /// choice: what the values are called, in order
    choices: []const []const u8 = &.{},
    /// number: the inclusive range and what one detent moves
    min: i32 = 0,
    max: i32 = 1,
    step: i32 = 1,
    default: u32 = 0,
    /// false keeps it off the panel: some things are hopeless on a dial and belong in the console
    on_panel: bool = true,

    pub fn count(self: Param) usize {
        return switch (self.kind) {
            .choice => self.choices.len,
            .toggle => 2,
            .number => @intCast(@divTrunc(self.max - self.min, self.step) + 1),
            .colour => hue_steps,
        };
    }

    /// pull a value into what this parameter can actually hold
    pub fn clamp(self: Param, v: u32) u32 {
        return switch (self.kind) {
            .choice => if (self.choices.len == 0) 0 else @min(v, self.choices.len - 1),
            .toggle => @intFromBool(v != 0),
            .colour => v & 0xffffff,
            .number => blk: {
                const i: i32 = @bitCast(v);
                break :blk @bitCast(std.math.clamp(i, self.min, self.max));
            },
        };
    }

    /// one detent: choices and toggles wrap, numbers stop at their ends, colours walk the hue wheel
    pub fn stepped(self: Param, v: u32, forward: bool) u32 {
        return switch (self.kind) {
            .choice, .toggle => blk: {
                const n = self.count();
                if (n == 0) break :blk 0;
                const i: usize = @min(v, n - 1);
                break :blk @intCast(if (forward) (i + 1) % n else (i + n - 1) % n);
            },
            .number => blk: {
                const i: i32 = @bitCast(self.clamp(v));
                const next = if (forward) i + self.step else i - self.step;
                break :blk @bitCast(std.math.clamp(next, self.min, self.max));
            },
            .colour => blk: {
                // snap to the wheel's own positions first: the rgb the console may have set is
                // not exactly on one, and converting back and forth would otherwise drift
                const h = snapHue(hueOf(self.clamp(v)));
                const next: u8 = if (forward) h +% hue_step else h -% hue_step;
                break :blk rgbValue(hueRgb(next));
            },
        };
    }

    /// what the menu shows under the name
    pub fn valueText(self: Param, v: u32, buf: []u8) []const u8 {
        return switch (self.kind) {
            .choice => if (self.choices.len == 0) "?" else self.choices[@min(v, self.choices.len - 1)],
            .toggle => if (v != 0) "on" else "off",
            .number => std.fmt.bufPrint(buf, "{d}", .{@as(i32, @bitCast(self.clamp(v)))}) catch "?",
            .colour => std.fmt.bufPrint(buf, "{x:0>6}", .{self.clamp(v)}) catch "?",
        };
    }
};

// colours: the panel edits hue only, at full saturation and value, so one dial covers the circle

/// detents for a whole turn of the wheel
pub const hue_steps: usize = 32;
const hue_step: u8 = @intCast(256 / hue_steps);

pub fn rgbValue(c: [3]u8) u32 {
    return (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
}

pub fn valueRgb(v: u32) [3]u8 {
    return .{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
}

/// the colour wheel at full saturation and value
pub fn hueRgb(h: u8) [3]u8 {
    const region: u8 = h / 43;
    const remainder: u32 = @as(u32, h - region * 43) * 6;
    const q: u8 = @intCast(255 -| remainder);
    const t: u8 = @intCast(@min(remainder, 255));
    return switch (region) {
        0 => .{ 255, t, 0 },
        1 => .{ q, 255, 0 },
        2 => .{ 0, 255, t },
        3 => .{ 0, q, 255 },
        4 => .{ t, 0, 255 },
        else => .{ 255, 0, q },
    };
}

/// the nearest position of the wheel, so stepping is stable however the colour was set
pub fn snapHue(h: u8) u8 {
    const rounded = (@as(u32, h) + hue_step / 2) / hue_step * hue_step;
    return @intCast(rounded % 256);
}

/// where a colour sits on the wheel, so the dial picks up near what the console set
pub fn hueOf(v: u32) u8 {
    const c = valueRgb(v);
    const r: i32 = c[0];
    const g: i32 = c[1];
    const b: i32 = c[2];
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const span = max - min;
    if (span == 0) return 0; // grey has no hue; start the wheel at red
    const sixth: i32 = 43; // a sixth of the 0..255 circle
    // the sector, plus how far along it the other two channels place the colour. signed, because
    // that offset runs either way from the sector's start.
    const h: i32 = if (max == r)
        (g - b) * sixth
    else if (max == g)
        2 * sixth * span + (b - r) * sixth
    else
        4 * sixth * span + (r - g) * sixth;
    const wrapped = @mod(@divTrunc(h, span), 256);
    return @intCast(wrapped);
}

/// an enum's field names as a choices list, so a table follows the enum it stands for
pub fn choicesOf(comptime E: type) []const []const u8 {
    comptime {
        const fields = @typeInfo(E).@"enum".fields;
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| names[i] = f.name;
        const frozen = names;
        return &frozen;
    }
}

/// the values of one owner, as the settings hold them
pub const Values = [max_per_owner]u32;

/// fill in every declared default
pub fn defaults(table: []const Param) Values {
    var v: Values = [_]u32{0} ** max_per_owner;
    for (table, 0..) |p, i| {
        if (i >= max_per_owner) break;
        v[i] = p.clamp(p.default);
    }
    return v;
}

/// the index of a named parameter, for the api and the settings file
pub fn indexOf(table: []const Param, name: []const u8) ?usize {
    for (table, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

// tests

const example = [_]Param{
    .{ .name = "palette", .kind = .choice, .choices = &.{ "mono", "poly" }, .default = 1 },
    .{ .name = "speed", .kind = .number, .min = 1, .max = 20, .step = 1, .default = 8 },
    .{ .name = "colour", .kind = .colour, .default = 0xff8000 },
    .{ .name = "trails", .kind = .toggle, .default = 1 },
};

test "each kind clamps whatever it is handed" {
    try std.testing.expectEqual(@as(u32, 1), example[0].clamp(9)); // past the last choice
    try std.testing.expectEqual(@as(u32, 20), example[1].clamp(99)); // past the range
    try std.testing.expectEqual(@as(u32, 1), example[1].clamp(0)); // below it
    try std.testing.expectEqual(@as(u32, 0xabcdef), example[2].clamp(0xffabcdef)); // rgb only
    try std.testing.expectEqual(@as(u32, 1), example[3].clamp(7)); // anything but zero is on
}

test "a detent wraps a choice and stops a number at its ends" {
    try std.testing.expectEqual(@as(u32, 0), example[0].stepped(1, true)); // wraps round
    try std.testing.expectEqual(@as(u32, 1), example[0].stepped(0, false));
    try std.testing.expectEqual(@as(u32, 9), example[1].stepped(8, true));
    try std.testing.expectEqual(@as(u32, 20), example[1].stepped(20, true)); // stops
    try std.testing.expectEqual(@as(u32, 1), example[1].stepped(1, false)); // stops
    try std.testing.expectEqual(@as(u32, 0), example[3].stepped(1, true)); // a toggle flips
}

test "the hue wheel comes back round to where it started" {
    const start = rgbValue(hueRgb(0));
    var v = start;
    for (0..hue_steps) |_| v = example[2].stepped(v, true);
    try std.testing.expectEqual(start, v);
    // and it passes through the primaries on the way
    var seen_green = false;
    var seen_blue = false;
    v = start;
    for (0..hue_steps) |_| {
        const c = valueRgb(v);
        if (c[1] > 200 and c[0] < 60 and c[2] < 60) seen_green = true;
        if (c[2] > 200 and c[0] < 60 and c[1] < 60) seen_blue = true;
        v = example[2].stepped(v, true);
    }
    try std.testing.expect(seen_green and seen_blue);
}

test "a colour set anywhere lands the wheel near it rather than at red" {
    // the console can set any rgb; the dial should carry on from there
    for ([_][3]u8{ .{ 255, 0, 0 }, .{ 0, 255, 0 }, .{ 0, 0, 255 }, .{ 255, 255, 0 }, .{ 0, 255, 255 } }) |c| {
        const h = hueOf(rgbValue(c));
        const back = hueRgb(h);
        var close: usize = 0;
        for (0..3) |i| {
            const d = @abs(@as(i32, back[i]) - @as(i32, c[i]));
            if (d <= 40) close += 1;
        }
        try std.testing.expectEqual(@as(usize, 3), close);
    }
    try std.testing.expectEqual(@as(u8, 0), hueOf(rgbValue(.{ 128, 128, 128 }))); // grey has none
}

test "defaults and lookup come from the table" {
    const v = defaults(&example);
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 8), v[1]);
    try std.testing.expectEqual(@as(u32, 0xff8000), v[2]);
    try std.testing.expectEqual(@as(?usize, 2), indexOf(&example, "colour"));
    try std.testing.expectEqual(@as(?usize, null), indexOf(&example, "nope"));
}

test "the value text says something useful for every kind" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("poly", example[0].valueText(1, &buf));
    try std.testing.expectEqualStrings("8", example[1].valueText(8, &buf));
    try std.testing.expectEqualStrings("ff8000", example[2].valueText(0xff8000, &buf));
    try std.testing.expectEqualStrings("on", example[3].valueText(1, &buf));
}
