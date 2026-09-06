//! the pixel mcu's serial protocol (recovered from the vendor library's `PixelMcuProto::McuParse`):
//!
//!   FF 55 <cmd> <len> <payload[len]> <sum_hi> <sum_lo>
//!
//! the checksum is the 16-bit sum of every byte from the FF header through the last payload byte,
//! sent big-endian; payloads are at most 32 bytes. replies use the same framing with the same
//! command byte. commands seen in the library: 01 queryMicValue, 02 queryUsbState,
//! 03 queryBatteryPower (reply: one byte, then a 16-bit big-endian value that the vendor scales by
//! 1.3235 to get millivolts), 04 setAutoMicReport(bool), 10 powerOff, 11 queryMcuVersion,
//! 13 led register (three bytes). the firmware-upload commands are deliberately absent.
//! pure: framing, parsing and a stream synchroniser; the uart lives in the supervisor.
const std = @import("std");

pub const max_payload = 32;
pub const max_frame = 4 + max_payload + 2;

pub const Command = enum(u8) {
    query_mic = 0x01,
    query_usb = 0x02,
    query_battery = 0x03,
    set_auto_mic_report = 0x04,
    power_off = 0x10,
    query_version = 0x11,
    led_register = 0x13,
};

/// the vendor's millivolt scale for the 16-bit battery reading (float constant in libzkgui.so).
pub const battery_scale: f32 = 1.3235294;

pub fn checksum(bytes: []const u8) u16 {
    var sum: u16 = 0;
    for (bytes) |b| sum +%= b;
    return sum;
}

/// build a frame into `out`; returns the bytes to send.
pub fn encode(out: []u8, cmd: u8, payload: []const u8) error{Overflow}![]u8 {
    if (payload.len > max_payload or out.len < 6 + payload.len) return error.Overflow;
    out[0] = 0xff;
    out[1] = 0x55;
    out[2] = cmd;
    out[3] = @intCast(payload.len);
    @memcpy(out[4 .. 4 + payload.len], payload);
    const sum = checksum(out[0 .. 4 + payload.len]);
    std.mem.writeInt(u16, out[4 + payload.len ..][0..2], sum, .big);
    return out[0 .. 6 + payload.len];
}

pub const Frame = struct { cmd: u8, payload: []const u8, used: usize };
pub const DecodeError = error{ Incomplete, BadHeader, BadLength, BadChecksum };

/// parse one frame from the front of `buf`.
pub fn decode(buf: []const u8) DecodeError!Frame {
    if (buf.len < 4) return error.Incomplete;
    if (buf[0] != 0xff or buf[1] != 0x55) return error.BadHeader;
    const len: usize = buf[3];
    if (len > max_payload) return error.BadLength;
    if (buf.len < 6 + len) return error.Incomplete;
    const expected = std.mem.readInt(u16, buf[4 + len ..][0..2], .big);
    if (checksum(buf[0 .. 4 + len]) != expected) return error.BadChecksum;
    return .{ .cmd = buf[2], .payload = buf[4 .. 4 + len], .used = 6 + len };
}

/// a byte-stream synchroniser: skips garbage until a valid frame parses.
pub const Sync = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *Sync, bytes: []const u8) void {
        if (bytes.len >= self.buf.len) {
            // more than the whole buffer arrived at once: keep only the newest bytes
            self.dropped +|= @intCast(self.len + bytes.len - self.buf.len);
            @memcpy(&self.buf, bytes[bytes.len - self.buf.len ..]);
            self.len = self.buf.len;
            return;
        }
        const room = self.buf.len - self.len;
        if (bytes.len > room) {
            // shift the oldest bytes out; they are stale
            const drop = bytes.len - room;
            std.mem.copyForwards(u8, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
            self.len -= drop;
            self.dropped +|= @intCast(drop);
        }
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    /// the next complete valid frame, consuming it; null when none is available yet.
    pub fn next(self: *Sync) ?Frame {
        while (self.len > 0) {
            const r = decode(self.buf[0..self.len]) catch |e| switch (e) {
                error.Incomplete => return null,
                else => {
                    self.consume(1);
                    self.dropped +|= 1;
                    continue;
                },
            };
            return r;
        }
        return null;
    }

    pub fn consume(self: *Sync, n: usize) void {
        const k = @min(n, self.len);
        std.mem.copyForwards(u8, self.buf[0 .. self.len - k], self.buf[k..self.len]);
        self.len -= k;
    }
};

pub const Battery = struct { raw_first: u8, raw_value: u16, millivolts: u16 };

/// interpret a battery reply payload the way the vendor does.
pub fn parseBattery(payload: []const u8) ?Battery {
    if (payload.len < 3) return null;
    const raw = std.mem.readInt(u16, payload[1..3], .big);
    const mv: f32 = @as(f32, @floatFromInt(raw)) * battery_scale;
    return .{ .raw_first = payload[0], .raw_value = raw, .millivolts = @intFromFloat(@min(mv, 65535.0)) };
}

test "the vendor's four-byte queries encode with their known checksums" {
    var out: [max_frame]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x55, 0x03, 0x00, 0x01, 0x57 }, try encode(&out, @intFromEnum(Command.query_battery), ""));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x55, 0x02, 0x00, 0x01, 0x56 }, try encode(&out, @intFromEnum(Command.query_usb), ""));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x55, 0x04, 0x01, 0x00, 0x01, 0x59 }, try encode(&out, @intFromEnum(Command.set_auto_mic_report), &.{0}));
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x55, 0x11, 0x00, 0x01, 0x65 }, try encode(&out, @intFromEnum(Command.query_version), ""));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.Overflow, encode(&tiny, 1, ""));
}

test "replies decode, and every corruption is rejected" {
    var out: [max_frame]u8 = undefined;
    const f = try encode(&out, 0x03, &.{ 0x01, 0x0b, 0xb8 });
    const d = try decode(f);
    try std.testing.expectEqual(@as(u8, 0x03), d.cmd);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x0b, 0xb8 }, d.payload);
    try std.testing.expectEqual(f.len, d.used);
    try std.testing.expectError(error.Incomplete, decode(f[0 .. f.len - 1]));
    var bad = out;
    bad[f.len - 1] +%= 1;
    try std.testing.expectError(error.BadChecksum, decode(bad[0..f.len]));
    bad = out;
    bad[0] = 0xfe;
    try std.testing.expectError(error.BadHeader, decode(bad[0..f.len]));
    bad = out;
    bad[3] = 40;
    try std.testing.expectError(error.BadLength, decode(bad[0..f.len]));
}

test "the synchroniser skips garbage and mic reports and yields whole frames" {
    var s = Sync{};
    var out: [max_frame]u8 = undefined;
    const mic = try encode(&out, 0x01, &.{0x42});
    var out2: [max_frame]u8 = undefined;
    const bat = try encode(&out2, 0x03, &.{ 0x00, 0x0b, 0xb8 });
    s.push(&.{ 0x00, 0x13, 0xff });
    s.push(mic);
    s.push(bat[0..4]);
    try std.testing.expectEqual(@as(u8, 0x01), s.next().?.cmd);
    s.consume(mic.len);
    try std.testing.expect(s.next() == null); // the battery frame is incomplete
    s.push(bat[4..]);
    const f = s.next().?;
    try std.testing.expectEqual(@as(u8, 0x03), f.cmd);
    const b = parseBattery(f.payload).?;
    try std.testing.expectEqual(@as(u16, 3000), b.raw_value);
    try std.testing.expectEqual(@as(u16, 3970), b.millivolts);
    try std.testing.expect(s.dropped >= 3);
}

test "a flood larger than the buffer keeps the newest bytes" {
    var s = Sync{};
    const junk = [_]u8{0xaa} ** 300;
    s.push(&junk);
    try std.testing.expectEqual(@as(usize, 128), s.len);
    try std.testing.expect(s.next() == null);
    try std.testing.expect(s.len < 4); // whatever is left is too short to be a frame
}
