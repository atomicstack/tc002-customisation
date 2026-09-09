//! one line of a ntfy json stream (https://docs.ntfy.sh/subscribe/api/): the event kind, and
//! for a message the text the panel shows and its colour by priority. pure.
const std = @import("std");

pub const max_text = 128;
pub const max_id = 32;

pub const Event = enum { message, keepalive, open, other };

pub const Notification = struct {
    id: [max_id]u8 = [_]u8{0} ** max_id,
    id_len: u8 = 0,
    text: [max_text]u8 = [_]u8{0} ** max_text,
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

/// copy printable ascii into `out`, folding whitespace to a space, replacing other characters
/// (one per utf-8 sequence) with '?', stopping at the capacity; returns the length
fn sanitise(out: []u8, parts: []const []const u8) usize {
    var n: usize = 0;
    for (parts) |part| {
        for (part) |b| {
            if (n == out.len) return n;
            if (b >= 0x20 and b <= 0x7e) {
                out[n] = b;
                n += 1;
            } else if (b == '\n' or b == '\r' or b == '\t') {
                out[n] = ' ';
                n += 1;
            } else if (b >= 0xc0 or b < 0x20) {
                out[n] = '?';
                n += 1;
            } // 0x80..0xbf: continuation bytes of a sequence already replaced
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
    // trim the spaces folding may have left at the ends
    const trimmed = std.mem.trim(u8, n.text[0..n.len], " ");
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

test "text is printable ascii, folded, replaced and bounded; an empty message is dropped" {
    var arena: [4096]u8 = undefined;
    const u = try parse("{\"event\":\"message\",\"message\":\"caf\\u00e9\\n\\ttime \\ud83d\\ude00!\"}", &arena);
    try std.testing.expectEqualStrings("caf?  time ?!", u.notification.?.textSlice());
    const long = "{\"event\":\"message\",\"message\":\"" ++ "x" ** 200 ++ "\"}";
    const l = try parse(long, &arena);
    try std.testing.expectEqual(@as(u8, max_text), l.notification.?.len);
    const e = try parse("{\"event\":\"message\",\"message\":\"  \\n \"}", &arena);
    try std.testing.expect(e.notification == null);
    try std.testing.expectEqual([3]u8{ 96, 96, 96 }, colourFor(1));
    try std.testing.expectEqual([3]u8{ 255, 128, 0 }, colourFor(4));
}
