//! bounded notification storage; the arbiter owns display timing and transitions.
const std = @import("std");
const transition = @import("../panel/transition.zig");
const canvas = @import("canvas.zig");

pub const capacity = 8;
pub const name_max = 32;

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub const Name = struct {
    len: u8 = 0,
    bytes: [name_max]u8 = [_]u8{0} ** name_max,

    pub fn init(s: []const u8) Name {
        std.debug.assert(s.len <= name_max);
        var n = Name{ .len = @intCast(s.len) };
        @memcpy(n.bytes[0..s.len], s);
        return n;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Entry = struct {
    text: [128]u8,
    len: u8,
    colour: [3]u8,
    duration_s: u16 = 5,
    name: Name = .{},
    hold: bool = false,
    since_ns: u64,
    until_ns: u64,
    transition: transition.Spec,
    /// a document to draw instead of the text; the text is then only the summary
    doc: ?canvas.Document = null,
};

/// the active entry is the arbiter's overlay, leaving seven slots for waiting entries.
pub const Waiting = struct {
    entries: [capacity - 1]Entry = undefined,
    len: usize = 0,

    pub fn push(self: *Waiting, e: Entry) bool {
        if (self.len == self.entries.len) return false;
        self.entries[self.len] = e;
        self.len += 1;
        return true;
    }

    pub fn remove(self: *Waiting, i: usize) Entry {
        std.debug.assert(i < self.len);
        const e = self.entries[i];
        std.mem.copyForwards(Entry, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
        self.len -= 1;
        return e;
    }
};
