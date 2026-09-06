//! panel geometry: 52x16 rgb888 pixels, sent as 16 rows of 156 rgb bytes plus 36 zero bytes.
const std = @import("std");

pub const width = 52;
pub const height = 16;
pub const pixels = width * height; // 832
pub const rgb_bytes = pixels * 3; // 2496
pub const row_bytes = 192; // 52 * 3 + 36 zero bytes
pub const frame_bytes = height * row_bytes; // 3072

pub const Rgb = [rgb_bytes]u8;
pub const Frame = [frame_bytes]u8;

pub const black_rgb: Rgb = [_]u8{0} ** rgb_bytes;

pub fn pixelOffset(x: usize, y: usize) usize {
    return (y * width + x) * 3;
}

test "geometry matches the wire format" {
    try std.testing.expectEqual(832, pixels);
    try std.testing.expectEqual(2496, @sizeOf(Rgb));
    try std.testing.expectEqual(3072, @sizeOf(Frame));
    try std.testing.expectEqual(@as(usize, 3 * 52 + 3), pixelOffset(1, 1));
}
