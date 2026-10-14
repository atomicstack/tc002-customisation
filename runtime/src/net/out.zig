const std = @import("std");

/// a bounded text builder for json responses; overflow is remembered, never written past the end.
pub const Out = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    pub fn add(self: *Out, s: []const u8) void {
        if (self.len + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    pub fn fmt(self: *Out, comptime f: []const u8, args: anytype) void {
        const r = std.fmt.bufPrint(self.buf[self.len..], f, args) catch {
            self.overflow = true;
            return;
        };
        self.len += r.len;
    }

    pub fn str(self: *Out, s: []const u8) void {
        self.add("\"");
        for (s) |c| switch (c) {
            '"' => self.add("\\\""),
            '\\' => self.add("\\\\"),
            0...0x1f => self.fmt("\\u{x:0>4}", .{c}),
            else => self.add(&[1]u8{c}),
        };
        self.add("\"");
    }

    pub fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};
