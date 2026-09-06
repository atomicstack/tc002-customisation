//! linux input_event decoding for the device layout (armv7, 32-bit time fields, 16 bytes), and
//! the keycode map for the tc002's polled gpio keys. pure; the file descriptors live elsewhere.
const std = @import("std");

pub const event_size = 16;

pub const EV_SYN: u16 = 0;
pub const EV_KEY: u16 = 1;
pub const EV_REL: u16 = 2;
pub const EV_ABS: u16 = 3;

pub const Event = struct { sec: i32, usec: i32, type: u16, code: u16, value: i32 };

/// which keycode is which physical control. gpio_keys_1 reports KEY_UP (103), KEY_LEFT (105),
/// KEY_RIGHT (106) and KEY_DOWN (108); the assignment below is the working guess until measured
/// on the device (see the plan's task 11) and can be overridden on the command line.
pub const KeyMap = struct { left: u16 = 105, middle: u16 = 103, right: u16 = 106, knob: u16 = 108 };

test "decode reads the 16-byte little-endian device layout" {
    const bytes = [16]u8{ 0x39, 0x30, 0x00, 0x00, 0xa0, 0x86, 0x01, 0x00, 0x01, 0x00, 0x69, 0x00, 0x01, 0x00, 0x00, 0x00 };
    const e = decode(&bytes);
    try std.testing.expectEqual(@as(i32, 12345), e.sec);
    try std.testing.expectEqual(@as(i32, 100000), e.usec);
    try std.testing.expectEqual(EV_KEY, e.type);
    try std.testing.expectEqual(@as(u16, 105), e.code);
    try std.testing.expectEqual(@as(i32, 1), e.value);
}

test "encode is the inverse of decode" {
    const e = Event{ .sec = -1, .usec = 7, .type = EV_ABS, .code = 0, .value = -12345 };
    const bytes = encode(e);
    try std.testing.expectEqual(e, decode(&bytes));
}

test "keymap parses four comma-separated keycodes and rejects anything else" {
    const km = try parseKeyMap("105,103,106,108");
    try std.testing.expectEqual(KeyMap{}, km);
    const other = try parseKeyMap("1,2,3,4");
    try std.testing.expectEqual(@as(u16, 4), other.knob);
    try std.testing.expectError(error.InvalidKeyMap, parseKeyMap("1,2,3"));
    try std.testing.expectError(error.InvalidKeyMap, parseKeyMap("1,2,3,x"));
    try std.testing.expectError(error.InvalidKeyMap, parseKeyMap("1,2,3,4,5"));
}

pub fn decode(bytes: *const [event_size]u8) Event {
    return .{
        .sec = std.mem.readInt(i32, bytes[0..4], .little),
        .usec = std.mem.readInt(i32, bytes[4..8], .little),
        .type = std.mem.readInt(u16, bytes[8..10], .little),
        .code = std.mem.readInt(u16, bytes[10..12], .little),
        .value = std.mem.readInt(i32, bytes[12..16], .little),
    };
}

pub fn encode(e: Event) [event_size]u8 {
    var b: [event_size]u8 = undefined;
    std.mem.writeInt(i32, b[0..4], e.sec, .little);
    std.mem.writeInt(i32, b[4..8], e.usec, .little);
    std.mem.writeInt(u16, b[8..10], e.type, .little);
    std.mem.writeInt(u16, b[10..12], e.code, .little);
    std.mem.writeInt(i32, b[12..16], e.value, .little);
    return b;
}

/// "left,middle,right,knob" as decimal keycodes.
pub fn parseKeyMap(text: []const u8) error{InvalidKeyMap}!KeyMap {
    var it = std.mem.splitScalar(u8, text, ',');
    var codes: [4]u16 = undefined;
    for (&codes) |*c| {
        const part = it.next() orelse return error.InvalidKeyMap;
        c.* = std.fmt.parseInt(u16, part, 10) catch return error.InvalidKeyMap;
    }
    if (it.next() != null) return error.InvalidKeyMap;
    return .{ .left = codes[0], .middle = codes[1], .right = codes[2], .knob = codes[3] };
}
