//! renders the battery notice as it actually animates and writes each frame out as hex, so a
//! picture of the motion can be made without a device. the drawing is `scene/batteryart.zig` and
//! the timing is `supervisor/battery_notice.zig` -- both the real ones, because a preview that is
//! a second implementation of the thing being previewed is worth nothing.
//!
//!   zig run src/battery_preview_main.zig 2> frames.hex
const std = @import("std");
const geometry = @import("panel/geometry.zig");
const batteryart = @import("scene/batteryart.zig");
const notice = @import("supervisor/battery_notice.zig");

const ms = std.time.ns_per_ms;

/// one strip per scenario: the notice raised at t=0 and sampled every 100 ms, which is exactly how
/// often the supervisor pushes a frame.
const Strip = struct { name: []const u8, pct: u8, charging: bool, frames: usize };

const strips = [_]Strip{
    .{ .name = "discharge-89", .pct = 89, .charging = false, .frames = 9 },
    .{ .name = "discharge-35", .pct = 35, .charging = false, .frames = 9 },
    .{ .name = "charge-89", .pct = 89, .charging = true, .frames = 12 },
    .{ .name = "charge-30", .pct = 30, .charging = true, .frames = 12 },
    .{ .name = "discharge-4-blink", .pct = 4, .charging = false, .frames = 16 },
};

pub fn main() void {
    for (strips) |s| {
        var n = notice.Notices{};
        const from = notice.Reading{ .millivolts = 3900, .usb = if (s.charging) 0 else 1, .fresh = true };
        const to = notice.Reading{ .millivolts = 3900, .usb = if (s.charging) 1 else 0, .fresh = true };
        _ = n.update(from, s.pct, 0);
        _ = n.update(to, s.pct, 0);

        var i: usize = 0;
        while (i < s.frames) : (i += 1) {
            const t = i * 100 * ms;
            var rgb = geometry.black_rgb;
            if (n.visible(t)) {
                batteryart.draw(&rgb, n.fillNow(t), n.style().colour, n.plugAlpha(t));
            }
            std.debug.print("{s}-{d:0>2} ", .{ s.name, i });
            for (rgb) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
        }
    }
}
