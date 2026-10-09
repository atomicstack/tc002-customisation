//! one line of a ntfy json stream (https://docs.ntfy.sh/subscribe/api/): the event kind, and
//! for a message the text the panel shows and its colour by priority. pure.
const std = @import("std");
// zig 0.17 removed `**`; `@splat` covers one element, this covers a longer unit
const repeat = @import("../repeat.zig");
const face = @import("../scene/face.zig");

pub const max_text = 128;
pub const max_id = 32;

pub const Event = enum { message, keepalive, open, other };

pub const Notification = struct {
    id: [max_id]u8 = @splat(0),
    id_len: u8 = 0,
    text: [max_text]u8 = @splat(0),
    len: u8 = 0,
    colour: [3]u8 = .{ 255, 255, 255 },

    pub fn textSlice(self: *const Notification) []const u8 {
        return self.text[0..self.len];
    }
    pub fn idSlice(self: *const Notification) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const Parsed = struct { event: Event, notification: ?Notification };

const Line = struct {
    id: []const u8 = "",
    event: []const u8 = "",
    message: []const u8 = "",
    title: []const u8 = "",
    priority: u8 = 3,
};

/// min and low are dim, default is white, high is orange, urgent is red
pub fn colourFor(priority: u8) [3]u8 {
    return switch (priority) {
        0, 1 => .{ 96, 96, 96 },
        2 => .{ 160, 160, 160 },
        4 => .{ 255, 128, 0 },
        5 => .{ 255, 32, 32 },
        else => .{ 255, 255, 255 },
    };
}

/// copy the text into `out` as the panel takes it: utf-8 kept whole, a line break kept, other
/// whitespace folded to a space, del, the c1 controls and anything malformed replaced with `?`,
/// stopping at the capacity before a character that would not fit whole; returns the length
fn sanitise(out: []u8, parts: []const []const u8) usize {
    var n: usize = 0;
    for (parts) |part| {
        var i: usize = 0;
        while (i < part.len) {
            const len = std.unicode.utf8ByteSequenceLength(part[i]) catch 0;
            const whole = len > 0 and i + len <= part.len and std.unicode.utf8ValidateSlice(part[i .. i + len]);
            const cp: u21 = if (whole) std.unicode.utf8Decode(part[i .. i + len]) catch unreachable else 0xfffd;
            const bytes: []const u8 = if (!whole) "?" else switch (cp) {
                '\n' => "\n",
                0x09, 0x0d => " ",
                0...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f...0x9f => "?",
                else => part[i .. i + len],
            };
            if (n + bytes.len > out.len) return n;
            @memcpy(out[n..][0..bytes.len], bytes);
            n += bytes.len;
            i += if (whole) len else 1;
        }
    }
    return n;
}

/// `arena` holds the parsed strings; 4 kb is plenty for a ntfy line
pub fn parse(line: []const u8, arena: []u8) error{Invalid}!Parsed {
    var fba = std.heap.FixedBufferAllocator.init(arena);
    const l = std.json.parseFromSliceLeaky(Line, fba.allocator(), line, .{ .ignore_unknown_fields = true }) catch return error.Invalid;
    const event: Event = if (std.mem.eql(u8, l.event, "message")) .message else if (std.mem.eql(u8, l.event, "keepalive")) .keepalive else if (std.mem.eql(u8, l.event, "open")) .open else .other;
    if (event != .message) return .{ .event = event, .notification = null };
    var n = Notification{ .colour = colourFor(l.priority) };
    n.len = @intCast(if (l.title.len > 0) sanitise(&n.text, &.{ l.title, ": ", l.message }) else sanitise(&n.text, &.{l.message}));
    // trim the spaces and line breaks left at the ends
    const trimmed = std.mem.trim(u8, n.text[0..n.len], " \n");
    if (trimmed.len == 0) return .{ .event = event, .notification = null };
    std.mem.copyForwards(u8, n.text[0..trimmed.len], trimmed);
    n.len = @intCast(trimmed.len);
    n.id_len = @intCast(@min(l.id.len, max_id));
    @memcpy(n.id[0..n.id_len], l.id[0..n.id_len]);
    return .{ .event = event, .notification = n };
}

test "a message with a title and a priority becomes coloured text; other events carry nothing" {
    var arena: [4096]u8 = undefined;
    const m = try parse("{\"id\":\"abc123\",\"time\":1,\"expires\":2,\"event\":\"message\",\"topic\":\"t\",\"title\":\"Door\",\"message\":\"open\",\"priority\":5,\"tags\":[\"warning\"],\"click\":\"https://x\"}", &arena);
    try std.testing.expectEqual(Event.message, m.event);
    try std.testing.expectEqualStrings("Door: open", m.notification.?.textSlice());
    try std.testing.expectEqualStrings("abc123", m.notification.?.idSlice());
    try std.testing.expectEqual([3]u8{ 255, 32, 32 }, m.notification.?.colour);
    const k = try parse("{\"id\":\"k\",\"event\":\"keepalive\",\"topic\":\"t\"}", &arena);
    try std.testing.expectEqual(Event.keepalive, k.event);
    try std.testing.expect(k.notification == null);
    const plain = try parse("{\"id\":\"p\",\"event\":\"message\",\"message\":\"hello\"}", &arena);
    try std.testing.expectEqualStrings("hello", plain.notification.?.textSlice());
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, plain.notification.?.colour);
    try std.testing.expectError(error.Invalid, parse("not json", &arena));
}

test "text keeps its utf-8 and its line breaks, folds other whitespace and is bounded; an empty message is dropped" {
    var arena: [4096]u8 = undefined;
    const u = try parse("{\"event\":\"message\",\"message\":\"caf\\u00e9 20\\u00b0C\\n\\ttime \\ud83d\\ude00!\"}", &arena);
    try std.testing.expectEqualStrings("café 20°C\n time 😀!", u.notification.?.textSlice());
    try std.testing.expect(face.validText(u.notification.?.textSlice()));
    // what the panel would refuse becomes something it takes: del and the c1 controls are a `?`
    const c = try parse("{\"event\":\"message\",\"message\":\"a\\u007fb\\u0085c\\rd\"}", &arena);
    try std.testing.expectEqualStrings("a?b?c d", c.notification.?.textSlice());
    try std.testing.expect(face.validText(c.notification.?.textSlice()));
    // a limit falling inside a character stops before it rather than cutting it in half
    const cut = try parse("{\"event\":\"message\",\"message\":\"" ++ repeat.bytes("x", max_text - 1) ++ "\\u00e9\"}", &arena);
    try std.testing.expectEqual(@as(u8, max_text - 1), cut.notification.?.len);
    try std.testing.expect(face.validText(cut.notification.?.textSlice()));
    const long = "{\"event\":\"message\",\"message\":\"" ++ repeat.bytes("x", 200) ++ "\"}";
    const l = try parse(long, &arena);
    try std.testing.expectEqual(@as(u8, max_text), l.notification.?.len);
    const e = try parse("{\"event\":\"message\",\"message\":\"  \\n \"}", &arena);
    try std.testing.expect(e.notification == null);
    try std.testing.expectEqual([3]u8{ 96, 96, 96 }, colourFor(1));
    try std.testing.expectEqual([3]u8{ 255, 128, 0 }, colourFor(4));
}
