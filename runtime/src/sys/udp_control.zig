//! the one ancillary record requested by the mdns udp socket (linux IP_RECVTTL).
const std = @import("std");

// linux cmsghdr followed by an integer, including native trailing alignment.
// the cmsghdr length itself excludes trailing padding (20 bytes on 64-bit,
// 16 bytes on the device); the control buffer includes it.
pub const TtlControl = extern struct {
    len: usize = 0,
    level: c_int = 0,
    kind: c_int = 0,
    value: c_int = 0,

    pub fn ttl(self: TtlControl, used: usize, flags: u32) ?u8 {
        const required = @offsetOf(TtlControl, "value") + @sizeOf(c_int);
        if (flags & 8 != 0 or used < required or self.len != required or self.len > used) return null;
        if (self.level != 0 or self.kind != 2 or self.value < 0 or self.value > 255) return null;
        return @intCast(self.value);
    }
};

test "ttl ancillary metadata is bounded and must be complete" {
    var control = TtlControl{ .len = @offsetOf(TtlControl, "value") + @sizeOf(c_int), .level = 0, .kind = 2, .value = 255 };
    try std.testing.expectEqual(@as(?u8, 255), control.ttl(@sizeOf(TtlControl), 0));
    try std.testing.expectEqual(@as(?u8, null), control.ttl(control.len - 1, 0));
    try std.testing.expectEqual(@as(?u8, null), control.ttl(@sizeOf(TtlControl), 8));
    control.value = 254;
    try std.testing.expectEqual(@as(?u8, 254), control.ttl(@sizeOf(TtlControl), 0));
    control.kind = 12;
    try std.testing.expectEqual(@as(?u8, null), control.ttl(@sizeOf(TtlControl), 0));
}
