//! pure frame packing: brightness scaling, the firmware level curve, and row padding.
//! the stock library maps every byte before sending: 0 stays 0, 1..255 land on 50..255
//! (the led driver has a floor of 50), and brightness is applied before the curve.
const std = @import("std");
const geometry = @import("geometry.zig");

pub const Lut = [256]u8;

test "remap follows the firmware curve" {
    try std.testing.expectEqual(@as(u8, 0), remap(0));
    try std.testing.expectEqual(@as(u8, 50), remap(1));
    try std.testing.expectEqual(@as(u8, 255), remap(255));
    try std.testing.expectEqual(@as(u8, 152), remap(128)); // 50 + ((127*205)>>1)/127 = 50 + 102
}

test "pack scales by brightness before the curve and zeroes the padding" {
    var rgb: geometry.Rgb = undefined;
    @memset(&rgb, 200);
    var out: geometry.Frame = undefined;
    @memset(&out, 0xff);
    pack(&rgb, 50, &out);
    try std.testing.expectEqual(remap(100), out[0]);
    try std.testing.expectEqual(remap(100), out[155]);
    for (out[156..192]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqual(remap(100), out[15 * 192 + 155]);
    try std.testing.expectEqual(@as(u8, 0), out[3071]);
}

test "brightness is clamped to 100 and zero stays zero" {
    var rgb: geometry.Rgb = undefined;
    @memset(&rgb, 0);
    rgb[3] = 255;
    var out: geometry.Frame = undefined;
    pack(&rgb, 255, &out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 255), out[3]);
}

test "a cached lut gives the same result as pack" {
    var rgb: geometry.Rgb = undefined;
    for (&rgb, 0..) |*b, i| b.* = @truncate(i * 7);
    var a: geometry.Frame = undefined;
    var b: geometry.Frame = undefined;
    pack(&rgb, 33, &a);
    const lut = buildLut(33);
    packWithLut(&rgb, &lut, &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

/// the firmware's level curve: 0 stays 0, 1..255 land on 50..255.
/// libzkgui.so computes 50 + (((v-1)*205) >> 1) / 127 with a magic multiply.
pub fn remap(v: u8) u8 {
    if (v == 0) return 0;
    const half: u32 = ((@as(u32, v) - 1) * 205) >> 1;
    return @intCast(50 + half / 127);
}

/// lookup table for one brightness level (0..100, clamped): scale then curve.
pub fn buildLut(brightness: u8) Lut {
    const b: u32 = @min(brightness, 100);
    var lut: Lut = undefined;
    for (&lut, 0..) |*e, v| e.* = remap(@intCast(v * b / 100));
    return lut;
}

/// pack a row-major rgb888 image into one spi transfer using a prebuilt lut.
/// every byte of the frame is written, including the 36 zero bytes of row padding.
pub fn packWithLut(rgb: *const geometry.Rgb, lut: *const Lut, out: *geometry.Frame) void {
    for (0..geometry.height) |y| {
        const src = rgb[y * geometry.width * 3 ..][0 .. geometry.width * 3];
        const dst = out[y * geometry.row_bytes ..][0..geometry.row_bytes];
        for (src, dst[0 .. geometry.width * 3]) |s, *d| d.* = lut[s];
        @memset(dst[geometry.width * 3 ..], 0);
    }
}

/// convenience for callers without a cached lut.
pub fn pack(rgb: *const geometry.Rgb, brightness: u8, out: *geometry.Frame) void {
    const lut = buildLut(brightness);
    packWithLut(rgb, &lut, out);
}
