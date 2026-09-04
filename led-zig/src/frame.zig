const std = @import("std");

pub const width = 52;
pub const height = 16;
pub const pixel_count = width * height;
pub const row_bytes = 192;
pub const frame_bytes = height * row_bytes;

pub const Rgb = [pixel_count * 3]u8;
pub const Frame = [frame_bytes]u8;

pub fn remap(value: u8) u8 {
    if (value == 0) return 0;
    const product: u16 = (@as(u16, value) - 1) * 205;
    return @intCast(50 + ((product >> 1) / 127));
}

pub fn pack(rgb: *const Rgb, brightness: i32, output: *Frame) void {
    const clamped_brightness = std.math.clamp(brightness, 0, 100);

    for (0..height) |y| {
        const rgb_offset = y * width * 3;
        const frame_offset = y * row_bytes;

        for (0..width * 3) |x| {
            const scaled: u8 = @intCast(@divTrunc(
                @as(i32, rgb[rgb_offset + x]) * clamped_brightness,
                100,
            ));
            output[frame_offset + x] = remap(scaled);
        }
        @memset(output[frame_offset + width * 3 .. frame_offset + row_bytes], 0);
    }
}

fn referenceRemap(value: u8) u8 {
    if (value == 0) return 0;
    const product = (@as(u32, value) - 1) * 205;
    return @intCast(50 + (product / 2) / 127);
}

fn setPixel(rgb: *Rgb, x: usize, y: usize, r: u8, g: u8, b: u8) void {
    const offset = (y * width + x) * 3;
    rgb[offset] = r;
    rgb[offset + 1] = g;
    rgb[offset + 2] = b;
}

test "frame geometry matches the wire format" {
    try std.testing.expectEqual(52, width);
    try std.testing.expectEqual(16, height);
    try std.testing.expectEqual(832, pixel_count);
    try std.testing.expectEqual(192, row_bytes);
    try std.testing.expectEqual(3072, frame_bytes);
    try std.testing.expectEqual(2496, @sizeOf(Rgb));
    try std.testing.expectEqual(3072, @sizeOf(Frame));
}

test "remap has firmware curve endpoints" {
    try std.testing.expectEqual(@as(u8, 0), remap(0));
    try std.testing.expectEqual(@as(u8, 50), remap(1));
    try std.testing.expectEqual(@as(u8, 50), remap(2));
    try std.testing.expectEqual(@as(u8, 51), remap(3));
    try std.testing.expectEqual(@as(u8, 152), remap(128));
    try std.testing.expectEqual(@as(u8, 255), remap(255));
}

test "remap agrees with the firmware expression for every input" {
    for (0..256) |value| {
        try std.testing.expectEqual(referenceRemap(@intCast(value)), remap(@intCast(value)));
    }
}

test "pack places corners and clears every row padding byte" {
    var rgb = std.mem.zeroes(Rgb);
    var frame: Frame = undefined;

    setPixel(&rgb, 0, 0, 1, 2, 3);
    setPixel(&rgb, width - 1, 0, 255, 0, 0);
    setPixel(&rgb, 0, height - 1, 0, 255, 0);
    setPixel(&rgb, width - 1, height - 1, 0, 0, 255);

    pack(&rgb, 100, &frame);

    try std.testing.expectEqual(@as(u8, 50), frame[0]);
    try std.testing.expectEqual(@as(u8, 50), frame[1]);
    try std.testing.expectEqual(@as(u8, 51), frame[2]);
    try std.testing.expectEqual(@as(u8, 255), frame[(width - 1) * 3]);
    try std.testing.expectEqual(@as(u8, 255), frame[(height - 1) * row_bytes + 1]);
    try std.testing.expectEqual(@as(u8, 255), frame[(height - 1) * row_bytes + (width - 1) * 3 + 2]);

    for (0..height) |y| {
        for (width * 3..row_bytes) |x| {
            try std.testing.expectEqual(@as(u8, 0), frame[y * row_bytes + x]);
        }
    }
}

test "pack applies brightness before remapping" {
    var rgb: Rgb = undefined;
    @memset(&rgb, 200);
    var frame: Frame = undefined;

    pack(&rgb, 50, &frame);
    try std.testing.expectEqual(@as(u8, 129), frame[0]);
    try std.testing.expectEqual(@as(u8, 129), frame[40 * 3 + 2]);

    pack(&rgb, 0, &frame);
    for (frame) |value| try std.testing.expectEqual(@as(u8, 0), value);

    pack(&rgb, 100, &frame);
    try std.testing.expectEqual(referenceRemap(200), frame[0]);
}

test "pack clamps brightness to the supported range" {
    var rgb: Rgb = undefined;
    @memset(&rgb, 200);
    var frame: Frame = undefined;

    pack(&rgb, -1, &frame);
    for (frame) |value| try std.testing.expectEqual(@as(u8, 0), value);

    pack(&rgb, 101, &frame);
    try std.testing.expectEqual(referenceRemap(200), frame[0]);
}

test "pack overwrites a dirty destination" {
    var rgb = std.mem.zeroes(Rgb);
    var frame: Frame = undefined;
    @memset(&frame, 0xff);

    pack(&rgb, 100, &frame);
    for (frame) |value| try std.testing.expectEqual(@as(u8, 0), value);
}
