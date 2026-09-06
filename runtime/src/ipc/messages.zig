//! typed payloads for the renderer <-> supervisor channel, as one tagged union with fixed-size
//! big-endian encodings, plus the dedup-relevant result status.
const std = @import("std");
const codec = @import("codec.zig");
const geometry = @import("../panel/geometry.zig");

test "every message kind round-trips through a packet" {
    var frame = Frame{ .duration_s = 9, .rgb = geometry.black_rgb };
    frame.rgb[2495] = 0x5a;
    const all = [_]Message{
        .{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } },
        .ready,
        .{ .result = .{ .status = .applied, .revision = 41 } },
        .{ .set_base = .{ .base = 1, .generator = 1, .seed = 0xdeadbeef } },
        .{ .notify = Notify.init("hello, panel", .{ 1, 2, 3 }, 30) },
        .{ .frame = frame },
        .{ .brightness = .{ .value = 55 } },
        .{ .reseed = .{ .seed = 12 } },
        .arm_stream,
        .time_corrected,
        .{ .ip_changed = .{ .present = 1, .addr = .{ 10, 0, 0, 111 } } },
        .stop,
    };
    var buf: [codec.max_message]u8 = undefined;
    for (all) |m| {
        const packet = try encodePacket(m, 0x0102030405060708, 3, &buf);
        const p = try decodePacket(packet);
        try std.testing.expectEqual(@as(u64, 0x0102030405060708), p.request_id);
        try std.testing.expectEqual(@as(u32, 3), p.epoch);
        try std.testing.expectEqualDeep(m, p.message);
    }
}

test "fixed hex vectors" {
    var buf: [codec.max_message]u8 = undefined;
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } }, 1, 2, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "01" ++ "0000" ++ "0000000000000001" ++ "00000002" ++ "000d" ++ "0000" ++ "1122334455667788" ++ "00000007" ++ "02"), hb);
    const st = try encodePacket(.stop, 0, 9, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "18" ++ "0000" ++ "0000000000000000" ++ "00000009" ++ "0000" ++ "0000"), st);
    const nt = try encodePacket(.{ .notify = Notify.init("hi", .{ 0xff, 0x80, 0x00 }, 300) }, 0, 0, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "11" ++ "0000" ++ "0000000000000000" ++ "00000000" ++ "0008" ++ "0000" ++ "ff8000" ++ "012c" ++ "02" ++ "6869"), nt);
    const fr = try encodePacket(.{ .frame = .{ .duration_s = 1, .rgb = geometry.black_rgb } }, 0, 0, &buf);
    try std.testing.expectEqual(@as(usize, codec.header_len + 2 + geometry.rgb_bytes), fr.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.frame)), fr[5]);
}

test "malformed payloads are rejected" {
    var buf: [codec.max_message]u8 = undefined;
    var src: [codec.max_message]u8 = undefined;
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 1, .revision = 1, .state = 1 } }, 0, 0, &src);
    const short = try codec.encode(.{ .kind = @intFromEnum(Kind.heartbeat), .request_id = 0, .epoch = 0, .payload_len = 12 }, hb[codec.header_len .. codec.header_len + 12], &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short));
    const unknown = try codec.encode(.{ .kind = 200, .request_id = 0, .epoch = 0, .payload_len = 0 }, "", &buf);
    try std.testing.expectError(error.UnknownKind, decodePacket(unknown));
    // a notify claiming 200 text bytes
    const long_notify = try codec.encode(.{ .kind = @intFromEnum(Kind.notify), .request_id = 0, .epoch = 0, .payload_len = 6 + 200 }, &([_]u8{ 0, 0, 0, 0, 5, 200 } ++ [_]u8{'a'} ** 200), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(long_notify));
    // a frame one byte short
    const short_frame = try codec.encode(.{ .kind = @intFromEnum(Kind.frame), .request_id = 0, .epoch = 0, .payload_len = 2497 }, &([_]u8{0} ** 2497), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short_frame));
    // trailing bytes on a fixed-size message
    const trailing = try codec.encode(.{ .kind = @intFromEnum(Kind.stop), .request_id = 0, .epoch = 0, .payload_len = 1 }, "x", &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(trailing));
}

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

pub const Kind = enum(u8) {
    heartbeat = 1,
    ready = 2,
    result = 3,
    set_base = 16,
    notify = 17,
    frame = 18,
    brightness = 19,
    reseed = 20,
    arm_stream = 21,
    time_corrected = 22,
    ip_changed = 23,
    stop = 24,
};

pub const Status = enum(u8) { applied = 0, rejected = 1, overload = 2, stale_epoch = 3, expired = 4, unavailable = 5 };

pub const Heartbeat = struct { presented: u64, revision: u32, state: u8 };
pub const Result = struct { status: Status, revision: u32 };
pub const SetBase = struct { base: u8, generator: u8, seed: u32 };
pub const Frame = struct { duration_s: u16, rgb: geometry.Rgb };
pub const Brightness = struct { value: u8 };
pub const Reseed = struct { seed: u32 };
pub const IpChanged = struct { present: u8, addr: [4]u8 };

pub const Notify = struct {
    colour: [3]u8,
    duration_s: u16,
    len: u8,
    text: [128]u8,

    pub fn init(text: []const u8, colour: [3]u8, duration_s: u16) Notify {
        var n = Notify{ .colour = colour, .duration_s = duration_s, .len = @intCast(text.len), .text = [_]u8{0} ** 128 };
        @memcpy(n.text[0..text.len], text);
        return n;
    }

    pub fn slice(self: *const Notify) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Message = union(Kind) {
    heartbeat: Heartbeat,
    ready,
    result: Result,
    set_base: SetBase,
    notify: Notify,
    frame: Frame,
    brightness: Brightness,
    reseed: Reseed,
    arm_stream,
    time_corrected,
    ip_changed: IpChanged,
    stop,
};

pub const Packet = struct { request_id: u64, epoch: u32, message: Message };
pub const Error = codec.DecodeError || error{ UnknownKind, BadPayload };

fn encodePayload(msg: Message, out: []u8) usize {
    switch (msg) {
        .heartbeat => |h| {
            std.mem.writeInt(u64, out[0..8], h.presented, .big);
            std.mem.writeInt(u32, out[8..12], h.revision, .big);
            out[12] = h.state;
            return 13;
        },
        .ready, .arm_stream, .time_corrected, .stop => return 0,
        .result => |r| {
            out[0] = @intFromEnum(r.status);
            std.mem.writeInt(u32, out[1..5], r.revision, .big);
            return 5;
        },
        .set_base => |s| {
            out[0] = s.base;
            out[1] = s.generator;
            std.mem.writeInt(u32, out[2..6], s.seed, .big);
            return 6;
        },
        .notify => |n| {
            out[0..3].* = n.colour;
            std.mem.writeInt(u16, out[3..5], n.duration_s, .big);
            out[5] = n.len;
            @memcpy(out[6 .. 6 + @as(usize, n.len)], n.text[0..n.len]);
            return 6 + @as(usize, n.len);
        },
        .frame => |f| {
            std.mem.writeInt(u16, out[0..2], f.duration_s, .big);
            @memcpy(out[2 .. 2 + geometry.rgb_bytes], &f.rgb);
            return 2 + geometry.rgb_bytes;
        },
        .brightness => |b| {
            out[0] = b.value;
            return 1;
        },
        .reseed => |r| {
            std.mem.writeInt(u32, out[0..4], r.seed, .big);
            return 4;
        },
        .ip_changed => |i| {
            out[0] = i.present;
            out[1..5].* = i.addr;
            return 5;
        },
    }
}

pub fn encodePacket(msg: Message, request_id: u64, epoch: u32, out: []u8) error{Overflow}![]u8 {
    var payload: [codec.max_payload]u8 = undefined;
    const n = encodePayload(msg, &payload);
    return codec.encode(.{ .kind = @intFromEnum(msg), .request_id = request_id, .epoch = epoch, .payload_len = @intCast(n) }, payload[0..n], out);
}

/// a non-exhaustive-safe integer -> enum conversion: null for values without a tag.
pub fn enumFromInt(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (f.value == value) return @enumFromInt(f.value);
    return null;
}

fn fixed(p: []const u8, n: usize) error{BadPayload}![]const u8 {
    if (p.len != n) return error.BadPayload;
    return p;
}

pub fn decodePacket(bytes: []const u8) Error!Packet {
    const d = try codec.decode(bytes);
    const kind = enumFromInt(Kind, d.header.kind) orelse return error.UnknownKind;
    const p = d.payload;
    const message: Message = switch (kind) {
        .heartbeat => blk: {
            const b = try fixed(p, 13);
            break :blk .{ .heartbeat = .{ .presented = std.mem.readInt(u64, b[0..8], .big), .revision = std.mem.readInt(u32, b[8..12], .big), .state = b[12] } };
        },
        .ready => blk: {
            _ = try fixed(p, 0);
            break :blk .ready;
        },
        .result => blk: {
            const b = try fixed(p, 5);
            const status = enumFromInt(Status, b[0]) orelse return error.BadPayload;
            break :blk .{ .result = .{ .status = status, .revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .set_base => blk: {
            const b = try fixed(p, 6);
            break :blk .{ .set_base = .{ .base = b[0], .generator = b[1], .seed = std.mem.readInt(u32, b[2..6], .big) } };
        },
        .notify => blk: {
            if (p.len < 6) return error.BadPayload;
            const len = p[5];
            if (len == 0 or len > 128 or p.len != 6 + @as(usize, len)) return error.BadPayload;
            break :blk .{ .notify = Notify.init(p[6..], p[0..3].*, std.mem.readInt(u16, p[3..5], .big)) };
        },
        .frame => blk: {
            const b = try fixed(p, 2 + geometry.rgb_bytes);
            break :blk .{ .frame = .{ .duration_s = std.mem.readInt(u16, b[0..2], .big), .rgb = b[2..][0..geometry.rgb_bytes].* } };
        },
        .brightness => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .brightness = .{ .value = b[0] } };
        },
        .reseed => blk: {
            const b = try fixed(p, 4);
            break :blk .{ .reseed = .{ .seed = std.mem.readInt(u32, b[0..4], .big) } };
        },
        .arm_stream => blk: {
            _ = try fixed(p, 0);
            break :blk .arm_stream;
        },
        .time_corrected => blk: {
            _ = try fixed(p, 0);
            break :blk .time_corrected;
        },
        .ip_changed => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .ip_changed = .{ .present = b[0], .addr = b[1..5].* } };
        },
        .stop => blk: {
            _ = try fixed(p, 0);
            break :blk .stop;
        },
    };
    return .{ .request_id = d.header.request_id, .epoch = d.header.epoch, .message = message };
}
