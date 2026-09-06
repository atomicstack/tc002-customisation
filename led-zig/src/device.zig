const std = @import("std");
const frame = @import("frame.zig");

pub const spi_path = "/dev/spidev0.0";
pub const gpio_path = "/sys/class/gpio/gpio35/value";
pub const spi_hz: u32 = 10_000_000;
pub const pulse_us: i64 = 1_000;

const File = std.Io.File;
const linux = std.os.linux;

const spi_ioc_wr_mode = linux.IOCTL.IOW('k', 1, u8);
const spi_ioc_wr_bits_per_word = linux.IOCTL.IOW('k', 3, u8);
const spi_ioc_wr_max_speed_hz = linux.IOCTL.IOW('k', 4, u32);

pub const Device = struct {
    io: std.Io,
    spi: ?File,
    gpio: ?File,
    pulse: std.Io.Duration = .fromMicroseconds(pulse_us),

    pub fn init(io: std.Io, spi_name: []const u8, gpio_name: []const u8) !Device {
        const spi = try std.Io.Dir.openFileAbsolute(io, spi_name, .{ .mode = .read_write });
        errdefer spi.close(io);

        var mode: u8 = 0;
        var bits: u8 = 8;
        var speed: u32 = spi_hz;
        try configure(io, spi, spi_ioc_wr_mode, &mode);
        try configure(io, spi, spi_ioc_wr_bits_per_word, &bits);
        try configure(io, spi, spi_ioc_wr_max_speed_hz, &speed);

        const gpio = try std.Io.Dir.openFileAbsolute(io, gpio_name, .{ .mode = .write_only });
        errdefer gpio.close(io);

        return .{ .io = io, .spi = spi, .gpio = gpio };
    }

    pub fn deinit(self: *Device) void {
        if (self.spi) |file| {
            file.close(self.io);
            self.spi = null;
        }
        if (self.gpio) |file| {
            file.close(self.io);
            self.gpio = null;
        }
    }

    pub fn writeFrame(self: *Device, data: *const frame.Frame) !usize {
        try self.setLatch(false);
        var release_needed = true;
        defer if (release_needed) {
            std.Io.sleep(self.io, self.pulse, .awake) catch {};
            self.setLatch(true) catch {};
        };

        try std.Io.sleep(self.io, self.pulse, .awake);
        const spi = self.spi orelse return error.DeviceClosed;
        const written = try spi.writeStreaming(self.io, &.{}, &.{data[0..]}, 1);
        try std.Io.sleep(self.io, self.pulse, .awake);
        try self.setLatch(true);
        release_needed = false;
        return written;
    }

    fn setLatch(self: *Device, high: bool) !void {
        const gpio = self.gpio orelse return error.DeviceClosed;
        var seek_buffer: [1]u8 = undefined;
        var writer = gpio.writerStreaming(self.io, &seek_buffer);
        try writer.seekTo(0);

        const value = [1]u8{if (high) '1' else '0'};
        const written = try gpio.writeStreaming(self.io, &.{}, &.{value[0..]}, 1);
        if (written != value.len) return error.ShortGpioWrite;
    }
};

fn configure(io: std.Io, file: File, request: u32, value: *anyopaque) !void {
    const result = (try io.operate(.{ .device_io_control = .{
        .file = file,
        .code = request,
        .arg = value,
    } })).device_io_control;
    if (result < 0) return error.SpiConfigureFailed;
}

test "spi ioctl requests match linux spidev abi" {
    try std.testing.expectEqual(@as(u32, 0x40016b01), spi_ioc_wr_mode);
    try std.testing.expectEqual(@as(u32, 0x40016b03), spi_ioc_wr_bits_per_word);
    try std.testing.expectEqual(@as(u32, 0x40046b04), spi_ioc_wr_max_speed_hz);
}

test "frame type is exactly one panel transfer" {
    try std.testing.expectEqual(@as(usize, 3072), @sizeOf(frame.Frame));
}
