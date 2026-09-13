//! the fixed heap one berry vm allocates from.
//!
//! berry asks its host for malloc/realloc/free and will happily keep asking: a script that builds
//! a list in a loop is a script that allocates until something says no. on a device with 16 mb
//! free and a clock to keep, that "no" has to come from us at a bound we chose, not from the
//! kernel when it is already too late. so the vm gets one buffer, and this is the allocator over
//! it: when it is full, berry sees a malloc failure and raises, the script dies, and nothing else
//! on the device notices.
//!
//! an implicit free list with eight-byte headers. first fit, split on allocate, coalesce forward
//! on free and everywhere when an allocation would otherwise fail. that last part is the reason
//! there is no free-list threading: a lazy full coalesce costs one walk at exactly the moment a
//! walk is about to be worth it, and keeps the structure something a person can hold in their head.
const std = @import("std");

test "an empty arena hands out aligned blocks and tracks what it gave" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    try std.testing.expectEqual(@as(usize, 0), a.used);

    const p = a.alloc(30).?;
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(p) % 8);
    // 30 rounds up to 32, plus the eight-byte header
    try std.testing.expectEqual(@as(usize, 40), a.used);
    try std.testing.expectEqual(@as(usize, 40), a.high_water);
}

test "a freed block is handed out again" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const first = a.alloc(64).?;
    a.free(first);
    try std.testing.expectEqual(@as(usize, 0), a.used);
    const second = a.alloc(64).?;
    try std.testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
}

test "allocating splits a larger free block rather than swallowing it" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const big = a.alloc(512).?;
    a.free(big);
    const small = a.alloc(8).?;
    try std.testing.expectEqual(@intFromPtr(big), @intFromPtr(small));
    // the remainder is still available
    const rest = a.alloc(400).?;
    try std.testing.expect(@intFromPtr(rest) > @intFromPtr(small));
}

test "a full arena refuses instead of overrunning" {
    var buf: [128]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const p = a.alloc(64).?;
    _ = p;
    try std.testing.expect(a.alloc(64) == null);
    try std.testing.expectEqual(@as(u32, 1), a.failures);
}

test "freeing neighbours lets a large request through again" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const a1 = a.alloc(200).?;
    const a2 = a.alloc(200).?;
    const a3 = a.alloc(200).?;
    try std.testing.expect(a.alloc(400) == null);
    a.free(a1);
    a.free(a2);
    a.free(a3);
    // three adjacent free blocks have to become one before this can succeed
    try std.testing.expect(a.alloc(600) != null);
}

test "realloc grows, keeps the bytes, and shrinks in place" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const p = a.alloc(16).?;
    for (0..16) |i| p[i] = @truncate(i);

    const grown = a.realloc(p, 16, 128).?;
    for (0..16) |i| try std.testing.expectEqual(@as(u8, @truncate(i)), grown[i]);

    const shrunk = a.realloc(grown, 128, 32).?;
    try std.testing.expectEqual(@intFromPtr(grown), @intFromPtr(shrunk));
    for (0..16) |i| try std.testing.expectEqual(@as(u8, @truncate(i)), shrunk[i]);
}

test "realloc of nothing allocates, and realloc to nothing frees" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const p = a.realloc(null, 0, 64).?;
    try std.testing.expect(a.used > 0);
    try std.testing.expect(a.realloc(p, 64, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), a.used);
}

test "high water survives a free, because it is what sizing decisions need" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const p = a.alloc(256).?;
    const peak = a.high_water;
    a.free(p);
    try std.testing.expectEqual(@as(usize, 0), a.used);
    try std.testing.expectEqual(peak, a.high_water);
}


test "sizeOf reports the block a pointer belongs to, which is what c realloc cannot pass" {
    var buf: [1024]u8 align(8) = undefined;
    var a = Arena.init(&buf);
    const p = a.alloc(30).?;
    // the request rounds up, and the block is what the arena actually owns
    try std.testing.expectEqual(@as(usize, 32), a.sizeOf(p));
}

/// eight bytes, which is also the alignment every payload gets: berry stores doubles.
const Header = extern struct {
    /// payload bytes, always a multiple of `alignment`
    size: u32,
    /// 1 when this block is available. a word rather than a bit so the header stays eight bytes
    /// and every payload after it is eight-aligned.
    free: u32,
};

pub const alignment = 8;
pub const header_len = @sizeOf(Header);

comptime {
    std.debug.assert(header_len == alignment);
}

pub const Arena = struct {
    buf: []align(alignment) u8,
    /// arena bytes consumed, headers included -- berry makes many small allocations and eight
    /// bytes of header each is the difference between a number that means something and one that
    /// flatters
    used: usize = 0,
    /// the most `used` has ever been: what a person sizing the arena actually needs to know
    high_water: usize = 0,
    /// allocations refused because nothing fit. a script that dies for want of memory should be
    /// visible in `/status` rather than a mystery.
    failures: u32 = 0,

    pub fn init(buf: []align(alignment) u8) Arena {
        std.debug.assert(buf.len > header_len);
        var a = Arena{ .buf = buf };
        a.headerAt(0).* = .{ .size = @intCast(roundDown(buf.len - header_len)), .free = 1 };
        return a;
    }

    fn headerAt(self: *Arena, offset: usize) *Header {
        return @ptrCast(@alignCast(&self.buf[offset]));
    }

    fn roundUp(n: usize) usize {
        return (n + alignment - 1) & ~@as(usize, alignment - 1);
    }

    fn roundDown(n: usize) usize {
        return n & ~@as(usize, alignment - 1);
    }

    /// null when nothing fits, which berry turns into a malloc failure and a raised exception
    pub fn alloc(self: *Arena, want: usize) ?[*]u8 {
        const need = roundUp(@max(want, alignment));
        if (self.take(need)) |p| return p;
        // nothing fit as things stand: merge every adjacent pair of free blocks and try once more.
        // doing this lazily means a free costs no walk until a walk is about to be worth it.
        self.coalesce();
        if (self.take(need)) |p| return p;
        self.failures +|= 1;
        return null;
    }

    fn take(self: *Arena, need: usize) ?[*]u8 {
        var offset: usize = 0;
        while (offset + header_len <= self.buf.len) {
            const h = self.headerAt(offset);
            const size = h.size;
            if (h.free == 1 and size >= need) {
                // split when the remainder could hold a header and a minimum payload
                if (size >= need + header_len + alignment) {
                    const rest = self.headerAt(offset + header_len + need);
                    rest.* = .{ .size = @intCast(size - need - header_len), .free = 1 };
                    h.size = @intCast(need);
                }
                h.free = 0;
                self.used += header_len + h.size;
                if (self.used > self.high_water) self.high_water = self.used;
                return @ptrCast(&self.buf[offset + header_len]);
            }
            offset += header_len + size;
        }
        return null;
    }

    fn coalesce(self: *Arena) void {
        var offset: usize = 0;
        while (offset + header_len <= self.buf.len) {
            const h = self.headerAt(offset);
            if (h.free == 1) {
                var next_off = offset + header_len + h.size;
                while (next_off + header_len <= self.buf.len) {
                    const next = self.headerAt(next_off);
                    if (next.free != 1) break;
                    h.size += header_len + next.size;
                    next_off = offset + header_len + h.size;
                }
            }
            offset += header_len + h.size;
        }
    }

    /// the payload size of a block this arena returned. c's `realloc` is not told the old size,
    /// so the header is where that fact lives.
    pub fn sizeOf(self: *Arena, ptr: [*]u8) usize {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buf.ptr) - header_len;
        return self.headerAt(offset).size;
    }

    /// `ptr` must be something this arena returned
    pub fn free(self: *Arena, ptr: [*]u8) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.buf.ptr) - header_len;
        const h = self.headerAt(offset);
        std.debug.assert(h.free == 0);
        self.used -= header_len + h.size;
        h.free = 1;
        // cheap forward merge; the backward direction waits for `coalesce`
        const next_off = offset + header_len + h.size;
        if (next_off + header_len <= self.buf.len) {
            const next = self.headerAt(next_off);
            if (next.free == 1) h.size += header_len + next.size;
        }
    }

    /// berry's realloc: `old_len` is what it believes it asked for, which may be less than the
    /// block it actually holds. null means either a refusal or a request for nothing.
    pub fn realloc(self: *Arena, ptr: ?[*]u8, old_len: usize, want: usize) ?[*]u8 {
        const p = ptr orelse return self.alloc(want);
        if (want == 0) {
            self.free(p);
            return null;
        }
        const offset = @intFromPtr(p) - @intFromPtr(self.buf.ptr) - header_len;
        const h = self.headerAt(offset);
        const need = roundUp(@max(want, alignment));
        if (need <= h.size) {
            // shrinking: give the tail back when there is enough of it to be a block
            if (h.size >= need + header_len + alignment) {
                const rest = self.headerAt(offset + header_len + need);
                rest.* = .{ .size = @intCast(h.size - need - header_len), .free = 1 };
                self.used -= h.size - need;
                h.size = @intCast(need);
            }
            return p;
        }
        const fresh = self.alloc(want) orelse return null;
        const carry = @min(old_len, h.size);
        @memcpy(fresh[0..carry], p[0..carry]);
        self.free(p);
        return fresh;
    }
};
