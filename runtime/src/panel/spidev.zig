//! the panel's linux side: spidev writes framed by a gpio latch pulse, exactly as libzkgui.so does
//! it: gpio 35 low, 1 ms, write 3072 bytes, 1 ms, gpio 35 high. the latch is always released,
//! even after a failed write.
const std = @import("std");
const sys = @import("../sys/linux.zig");
const geometry = @import("geometry.zig");

const linux = std.os.linux;

pub const spi_hz: u32 = 10_000_000;
pub const pulse_ns: u64 = 1_000_000;

const spi_ioc_wr_mode = linux.IOCTL.IOW('k', 1, u8);
const spi_ioc_wr_bits_per_word = linux.IOCTL.IOW('k', 3, u8);
const spi_ioc_wr_max_speed_hz = linux.IOCTL.IOW('k', 4, u32);

pub const Device = struct {
    spi: sys.Fd,
    gpio: sys.Fd,
    pulse_ns: u64 = pulse_ns,

    pub fn open(spi_path: [*:0]const u8, gpio_path: [*:0]const u8) sys.Error!Device {
        const spi = try sys.open(spi_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        errdefer sys.close(spi);
        var mode: u8 = 0;
        var bits: u8 = 8;
        var hz: u32 = spi_hz;
        _ = try sys.ioctl(spi, spi_ioc_wr_mode, @intFromPtr(&mode));
        _ = try sys.ioctl(spi, spi_ioc_wr_bits_per_word, @intFromPtr(&bits));
        _ = try sys.ioctl(spi, spi_ioc_wr_max_speed_hz, @intFromPtr(&hz));
        const gpio = try sys.open(gpio_path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        return .{ .spi = spi, .gpio = gpio };
    }

    /// one pulsed transfer; returns the bytes written by spidev.
    pub fn writeFrame(self: *Device, frame: *const geometry.Frame) sys.Error!usize {
        try sys.pwriteByte(self.gpio, '0');
        sys.nanosleep(self.pulse_ns);
        const result = sys.write(self.spi, frame);
        sys.nanosleep(self.pulse_ns);
        sys.pwriteByte(self.gpio, '1') catch {};
        return result;
    }

    pub fn close(self: *Device) void {
        sys.close(self.spi);
        sys.close(self.gpio);
        self.spi = -1;
        self.gpio = -1;
    }
};
