//! the local command channel's framing: one packet per SOCK_SEQPACKET message, explicit big-endian
//! fields, at most 4,096 bytes in total. sizes are bounded, never padded to the maximum.
//!
//!   offset  size  field
//!        0     4  magic "TCI1"
//!        4     1  version (1)
//!        5     1  message kind
//!        6     2  reserved (0)
//!        8     8  request id
//!       16     4  renderer epoch
//!       20     2  payload length
//!       22     2  reserved (0)
//!       24     n  payload
const std = @import("std");

pub const magic = "TCI1";
pub const version: u8 = 1;
pub const header_len = 24;
pub const max_message = 4096;
pub const max_payload = max_message - header_len;

pub const Header = struct { kind: u8, request_id: u64, epoch: u32, payload_len: u16 };
pub const Decoded = struct { header: Header, payload: []const u8 };
pub const DecodeError = error{ Truncated, BadMagic, BadVersion, BadLength, Reserved };

const fixture_header = Header{ .kind = 1, .request_id = 0x0102030405060708, .epoch = 0x0a0b0c0d, .payload_len = 3 };
const fixture_hex = "54434931" ++ "01" ++ "01" ++ "0000" ++ "0102030405060708" ++ "0a0b0c0d" ++ "0003" ++ "0000" ++ "616263";

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "encode matches the fixture and decode round-trips it" {
    var buf: [64]u8 = undefined;
    const packet = try encode(fixture_header, "abc", &buf);
    try std.testing.expectEqualSlices(u8, &unhex(fixture_hex), packet);
    const d = try decode(packet);
    try std.testing.expectEqual(fixture_header, d.header);
    try std.testing.expectEqualStrings("abc", d.payload);
}

test "decode rejects short, foreign, mis-sized and reserved-bit packets" {
    const good = unhex(fixture_hex);
    try std.testing.expectError(error.Truncated, decode(good[0..23]));
    var bad_magic = good;
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, decode(&bad_magic));
    var bad_version = good;
    bad_version[4] = 2;
    try std.testing.expectError(error.BadVersion, decode(&bad_version));
    var bad_len = good;
    bad_len[21] = 5;
    try std.testing.expectError(error.BadLength, decode(&bad_len));
    try std.testing.expectError(error.BadLength, decode(good[0..26]));
    var reserved = good;
    reserved[7] = 1;
    try std.testing.expectError(error.Reserved, decode(&reserved));
}

test "encode bounds the payload and the output buffer" {
    var big: [max_payload + 1]u8 = undefined;
    @memset(&big, 0);
    var out: [max_message + 8]u8 = undefined;
    try std.testing.expectError(error.Overflow, encode(fixture_header, &big, &out));
    const exact = try encode(fixture_header, big[0..max_payload], &out);
    try std.testing.expectEqual(@as(usize, max_message), exact.len);
    var small: [30]u8 = undefined;
    try std.testing.expectError(error.Overflow, encode(fixture_header, big[0..10], &small));
}

/// write a packet; the payload length is taken from `payload`, not from `h.payload_len`.
pub fn encode(h: Header, payload: []const u8, out: []u8) error{Overflow}![]u8 {
    const total = header_len + payload.len;
    if (payload.len > max_payload or out.len < total) return error.Overflow;
    out[0..4].* = magic.*;
    out[4] = version;
    out[5] = h.kind;
    std.mem.writeInt(u16, out[6..8], 0, .big);
    std.mem.writeInt(u64, out[8..16], h.request_id, .big);
    std.mem.writeInt(u32, out[16..20], h.epoch, .big);
    std.mem.writeInt(u16, out[20..22], @intCast(payload.len), .big);
    std.mem.writeInt(u16, out[22..24], 0, .big);
    @memcpy(out[header_len..total], payload);
    return out[0..total];
}

/// parse one packet exactly: the declared payload length must match the bytes received.
pub fn decode(bytes: []const u8) DecodeError!Decoded {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    if (bytes[4] != version) return error.BadVersion;
    if (std.mem.readInt(u16, bytes[6..8], .big) != 0 or std.mem.readInt(u16, bytes[22..24], .big) != 0) return error.Reserved;
    const len = std.mem.readInt(u16, bytes[20..22], .big);
    if (bytes.len - header_len != len) return error.BadLength;
    return .{
        .header = .{
            .kind = bytes[5],
            .request_id = std.mem.readInt(u64, bytes[8..16], .big),
            .epoch = std.mem.readInt(u32, bytes[16..20], .big),
            .payload_len = len,
        },
        .payload = bytes[header_len..],
    };
}
