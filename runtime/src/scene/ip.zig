//! the ip scene: the ipv4 address on two lines (first two octets with a trailing dot, then the
//! last two), or `no ip` when nothing is configured. redraws only on address changes.
const std = @import("std");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const scene = @import("scene.zig");

test "set reports only real changes" {
    var s = State{};
    try std.testing.expect(s.set(.{ 10, 0, 0, 111 }));
    try std.testing.expect(!s.set(.{ 10, 0, 0, 111 }));
    try std.testing.expect(s.set(.{ 10, 0, 0, 112 }));
    try std.testing.expect(s.set(null));
    try std.testing.expect(!s.set(null));
}

test "no address renders the no ip text" {
    const s = State{};
    var rgb = geometry.black_rgb;
    s.render(&rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 11, 4, "no ip", s.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
}

test "an address renders on two lines" {
    var s = State{};
    _ = s.set(.{ 10, 0, 0, 111 });
    var rgb = geometry.black_rgb;
    s.render(&rgb);
    var expected = geometry.black_rgb;
    font.blit(&expected, 1, 0, "10.0.", s.colour);
    font.blit(&expected, 1, 8, "0.111", s.colour);
    try std.testing.expectEqualSlices(u8, &expected, &rgb);
    try std.testing.expect(s.cadence() == .idle);
}

pub const State = struct {
    addr: ?[4]u8 = null,
    colour: [3]u8 = .{ 255, 255, 255 },

    /// returns true when the address actually changed (the caller redraws only then).
    pub fn set(self: *State, addr: ?[4]u8) bool {
        const changed = !std.meta.eql(self.addr, addr);
        self.addr = addr;
        return changed;
    }

    pub fn render(self: *const State, rgb: *geometry.Rgb) void {
        rgb.* = geometry.black_rgb;
        if (self.addr) |a| {
            var b1: [9]u8 = undefined;
            var b2: [8]u8 = undefined;
            const l1 = std.fmt.bufPrint(&b1, "{d}.{d}.", .{ a[0], a[1] }) catch unreachable;
            const l2 = std.fmt.bufPrint(&b2, "{d}.{d}", .{ a[2], a[3] }) catch unreachable;
            font.blit(rgb, 1, 0, l1, self.colour);
            font.blit(rgb, 1, 8, l2, self.colour);
        } else {
            font.blit(rgb, 11, 4, "no ip", self.colour);
        }
    }

    pub fn cadence(self: *const State) scene.Cadence {
        _ = self;
        return .idle;
    }
};
