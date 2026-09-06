//! completed request ids and their results, kept for sixty seconds so a retried command returns
//! the original result instead of repeating a side effect. fixed capacity: when full, new discrete
//! actions are rejected rather than weakening the window.
const std = @import("std");
const messages = @import("messages.zig");

const s_ns = std.time.ns_per_s;

test "a completed id returns its original result inside the window" {
    var c = Cache{};
    try std.testing.expect(c.lookup(5, 0) == null);
    try std.testing.expect(c.insert(5, .applied, 3, 0));
    const e = c.lookup(5, 30 * s_ns).?;
    try std.testing.expectEqual(messages.Status.applied, e.status);
    try std.testing.expectEqual(@as(u32, 3), e.revision);
    try std.testing.expect(c.lookup(5, 60 * s_ns) == null);
}

test "the cache is bounded and frees expired entries on insert" {
    var c = Cache{};
    var i: u64 = 0;
    while (i < Cache.capacity) : (i += 1) try std.testing.expect(c.insert(i, .applied, 0, i));
    try std.testing.expect(!c.insert(1000, .applied, 0, Cache.capacity));
    try std.testing.expect(c.lookup(1000, Cache.capacity) == null);
    try std.testing.expect(c.insert(1000, .applied, 0, 60 * s_ns + 10));
    try std.testing.expect(c.lookup(0, 60 * s_ns + 10) == null);
    try std.testing.expect(c.lookup(1000, 60 * s_ns + 10) != null);
}

pub const Entry = struct { id: u64, status: messages.Status, revision: u32, at_ns: u64 };

pub const Cache = struct {
    pub const capacity = 128;
    pub const ttl_ns: u64 = 60 * s_ns;

    entries: [capacity]Entry = undefined,
    len: usize = 0,

    fn expired(e: Entry, now_ns: u64) bool {
        return now_ns -| e.at_ns >= ttl_ns;
    }

    pub fn lookup(self: *const Cache, id: u64, now_ns: u64) ?Entry {
        for (self.entries[0..self.len]) |e| if (e.id == id and !expired(e, now_ns)) return e;
        return null;
    }

    fn sweep(self: *Cache, now_ns: u64) void {
        var w: usize = 0;
        for (self.entries[0..self.len]) |e| {
            if (!expired(e, now_ns)) {
                self.entries[w] = e;
                w += 1;
            }
        }
        self.len = w;
    }

    /// whether a new discrete action can be remembered; when not, it must be rejected rather
    /// than applied without a deduplication record.
    pub fn available(self: *Cache, now_ns: u64) bool {
        self.sweep(now_ns);
        return self.len < capacity;
    }

    /// remember a completed request; false when the cache is full of live entries.
    pub fn insert(self: *Cache, id: u64, status: messages.Status, revision: u32, now_ns: u64) bool {
        self.sweep(now_ns);
        if (self.len == capacity) return false;
        self.entries[self.len] = .{ .id = id, .status = status, .revision = revision, .at_ns = now_ns };
        self.len += 1;
        return true;
    }
};

test "available reports room after sweeping expired entries" {
    var c = Cache{};
    var i: u64 = 0;
    while (i < Cache.capacity) : (i += 1) _ = c.insert(i, .applied, 0, 0);
    try std.testing.expect(!c.available(1));
    try std.testing.expect(c.available(61 * s_ns));
}
