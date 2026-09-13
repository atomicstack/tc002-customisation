//! the sounds a device keeps, as one durable blob on `/data`.
//!
//! the same discipline as `berry/store.zig` and `config/canvas.bin`: one file written with
//! `saveFileAtomic`, not a directory, because `sys/linux.zig` has no `readdir` and a directory
//! cannot be updated atomically. the codec is deliberately the same shape as the script store's,
//! but the two are separate modules rather than one generic one -- their bounds differ by two
//! orders of magnitude, and the reasons for those bounds are the interesting part of each.
//!
//! sounds are big enough to change two things the script store never had to face:
//!
//! - **they do not fit an ipc datagram.** a script reaches berryd whole in one 8 kb packet; a
//!   sound cannot, so `tc002-audiod` reads this file itself. it can, because `/dev/mi_ao` is
//!   root-only and so audiod is root anyway -- the same trade the renderer makes for spidev.
//! - **they do not fit an http body.** netd caps a request body at 8 kb, and raising that would
//!   cost the cap times eight connection slots in static buffers. so a sound arrives in chunks and
//!   is assembled here, which is what `putChunk` is for.
const std = @import("std");

/// one sound. 192 kb is six seconds of 16-bit 16 khz mono, or twenty-four of 8-bit 8 khz -- past
/// the point where a pixel clock is a pixel clock rather than a speaker.
pub const sound_max = 192 * 1024;
/// the whole store, and the supervisor's static save buffer with it. 0.7% of this device's ram.
pub const budget = 256 * 1024;
/// a name is a path segment in `PUT /api/v1/sounds/{name}` and a token in the log ring
pub const name_max = 32;
/// how much of a sound arrives in one `putChunk`. bounded by the ipc datagram that carries it to
/// the supervisor, not by http: netd relays the body it received and adds a header of its own.
pub const chunk_max = 4096;

pub const Error = error{ NameInvalid, TooLarge, NoRoom, NotFound, BadOffset };

/// what a name may contain: a path segment and a log token, so it stays to characters that survive
/// both without quoting. (the same rule as a script name, deliberately -- a user should not have to
/// learn two.)
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    // a leading dot would look like a path trick even though nothing here is a path
    return name[0] != '.';
}

/// a sound name as it travels over ipc: fixed width, because every buffer here is.
pub const Name = struct {
    bytes: [name_max]u8 = [_]u8{0} ** name_max,
    len: u8 = 0,

    pub fn init(text: []const u8) Name {
        var n = Name{};
        n.len = @intCast(@min(text.len, name_max));
        @memcpy(n.bytes[0..n.len], text[0..n.len]);
        return n;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const magic = "TCSS"; // tc002 sound store
pub const version: u8 = 1;

/// `magic`, `version`, then packed records of `name_len:u8, name, data_len:u32, data` in insertion
/// order. no index and no padding: the whole thing is walked, and it holds at most a few dozen
/// entries.
pub const Store = struct {
    buf: [budget]u8 = undefined,
    len: usize = 0,

    pub const Entry = struct { name: []const u8, data: []const u8 };

    pub const Iterator = struct {
        s: *const Store,
        o: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.o + 1 > self.s.len) return null;
            const nlen = self.s.buf[self.o];
            const nstart = self.o + 1;
            if (nstart + nlen + 4 > self.s.len) return null;
            const dlen = std.mem.readInt(u32, self.s.buf[nstart + nlen ..][0..4], .little);
            const dstart = nstart + nlen + 4;
            if (dstart + dlen > self.s.len) return null;
            self.o = dstart + dlen;
            return .{ .name = self.s.buf[nstart .. nstart + nlen], .data = self.s.buf[dstart .. dstart + dlen] };
        }
    };

    pub fn iterate(self: *const Store) Iterator {
        return .{ .s = self };
    }

    pub fn count(self: *const Store) usize {
        var it = self.iterate();
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        return n;
    }

    /// bytes of the budget in use, records and all
    pub fn used(self: *const Store) usize {
        return self.len;
    }

    pub fn get(self: *const Store, name: []const u8) ?[]const u8 {
        var it = self.iterate();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
        return null;
    }

    fn findRecord(self: *const Store, name: []const u8) ?struct { start: usize, end: usize } {
        var o: usize = 0;
        while (o < self.len) {
            const nlen = self.buf[o];
            const nstart = o + 1;
            if (nstart + nlen + 4 > self.len) return null;
            const dlen = std.mem.readInt(u32, self.buf[nstart + nlen ..][0..4], .little);
            const end = nstart + nlen + 4 + dlen;
            if (end > self.len) return null;
            if (std.mem.eql(u8, self.buf[nstart .. nstart + nlen], name)) return .{ .start = o, .end = end };
            o = end;
        }
        return null;
    }

    pub fn remove(self: *Store, name: []const u8) bool {
        const r = self.findRecord(name) orelse return false;
        const tail = self.len - r.end;
        std.mem.copyForwards(u8, self.buf[r.start..][0..tail], self.buf[r.end..self.len]);
        self.len = r.start + tail;
        return true;
    }

    /// replace (or add) a whole sound at once. the chunked path ends here too.
    pub fn put(self: *Store, name: []const u8, data: []const u8) Error!void {
        if (!validName(name)) return Error.NameInvalid;
        if (data.len > sound_max) return Error.TooLarge;
        const record = 1 + name.len + 4 + data.len;
        // measure against the store as it will be *after* the old copy goes, so replacing a sound
        // with one the same size always fits
        const freed = if (self.findRecord(name)) |r| r.end - r.start else 0;
        if (self.len - freed + record > budget) return Error.NoRoom;
        _ = self.remove(name);
        var o = self.len;
        self.buf[o] = @intCast(name.len);
        o += 1;
        @memcpy(self.buf[o..][0..name.len], name);
        o += name.len;
        std.mem.writeInt(u32, self.buf[o..][0..4], @intCast(data.len), .little);
        o += 4;
        @memcpy(self.buf[o..][0..data.len], data);
        self.len = o + data.len;
    }

    pub fn save(self: *const Store, out: []u8) usize {
        @memcpy(out[0..4], magic);
        out[4] = version;
        @memcpy(out[5..][0..self.len], self.buf[0..self.len]);
        return 5 + self.len;
    }

    /// an unreadable file is an empty store with a warning, never a refusal to start: a device
    /// whose sounds will not load should still tell the time.
    pub fn load(self: *Store, bytes: []const u8) bool {
        self.len = 0;
        if (bytes.len < 5) return false;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return false;
        if (bytes[4] != version) return false;
        const body = bytes[5..];
        if (body.len > budget) return false;
        @memcpy(self.buf[0..body.len], body);
        self.len = body.len;
        // walk it once: a truncated tail is dropped rather than served as a record
        var o: usize = 0;
        var good: usize = 0;
        while (o < self.len) {
            const nlen = self.buf[o];
            const nstart = o + 1;
            if (nstart + nlen + 4 > self.len) break;
            const dlen = std.mem.readInt(u32, self.buf[nstart + nlen ..][0..4], .little);
            const end = nstart + nlen + 4 + dlen;
            if (end > self.len) break;
            o = end;
            good = end;
        }
        self.len = good;
        return true;
    }
};

/// a sound being uploaded. one at a time: uploads are rare, and a second staging buffer would cost
/// more than the feature.
pub const Upload = struct {
    name: Name = .{},
    buf: [sound_max]u8 = undefined,
    len: usize = 0,
    active: bool = false,

    pub fn begin(self: *Upload, name: []const u8) Error!void {
        if (!validName(name)) return Error.NameInvalid;
        self.name = Name.init(name);
        self.len = 0;
        self.active = true;
    }

    /// append one chunk. `offset` must be exactly what has already landed, so a retried or
    /// reordered chunk is refused rather than silently corrupting the sound -- the uploader knows
    /// how to recover, the device cannot.
    pub fn chunk(self: *Upload, offset: usize, bytes: []const u8) Error!void {
        if (!self.active) return Error.NotFound;
        if (bytes.len > chunk_max) return Error.TooLarge;
        if (offset != self.len) return Error.BadOffset;
        if (self.len + bytes.len > sound_max) return Error.TooLarge;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn slice(self: *const Upload) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn cancel(self: *Upload) void {
        self.active = false;
        self.len = 0;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a sound goes in and comes back" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    try s.put("chime", "abcd");
    try testing.expectEqualStrings("abcd", s.get("chime").?);
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expect(s.get("missing") == null);
}

test "putting the same name again replaces it rather than growing the store" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    try s.put("chime", "aaaa");
    const first = s.used();
    try s.put("chime", "bbbb");
    try testing.expectEqual(@as(usize, 1), s.count());
    try testing.expectEqualStrings("bbbb", s.get("chime").?);
    try testing.expectEqual(first, s.used());
}

test "removing frees the bytes back and keeps the rest readable" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    try s.put("a", "1234567890");
    try s.put("b", "xyz");
    const both = s.used();
    try testing.expect(s.remove("a"));
    try testing.expect(s.used() < both);
    try testing.expect(s.get("a") == null);
    try testing.expectEqualStrings("xyz", s.get("b").?); // the survivor moved and is still intact
    try testing.expect(!s.remove("a"));
}

test "the budget is a byte count, so the number of sounds is whatever fits" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    const big = [_]u8{0} ** (sound_max);
    try s.put("one", &big);
    // a second full-size sound does not fit in a 256 kb budget alongside the first
    try testing.expectError(Error.NoRoom, s.put("two", &big));
    // but replacing the one that is there always fits, which is the case a naive check gets wrong
    try s.put("one", &big);
    try testing.expectEqual(@as(usize, 1), s.count());
}

test "a sound larger than one sound is refused before anything is copied" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    const huge = [_]u8{0} ** (sound_max + 1);
    try testing.expectError(Error.TooLarge, s.put("big", &huge));
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "names are path segments and log tokens, so they stay boring" {
    try testing.expect(validName("chime"));
    try testing.expect(validName("door-bell_2.wav"));
    try testing.expect(!validName(""));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("has space"));
    try testing.expect(!validName("has/slash"));
    try testing.expect(!validName("a" ** (name_max + 1)));
}

test "a store round-trips through the file it is saved as" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    try s.put("a", "hello");
    try s.put("b", "world!");
    var file = testing.allocator.alloc(u8, budget + 64) catch unreachable;
    defer testing.allocator.free(file);
    const n = s.save(file);

    var back = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(back);
    back.* = .{};
    try testing.expect(back.load(file[0..n]));
    try testing.expectEqual(@as(usize, 2), back.count());
    try testing.expectEqualStrings("hello", back.get("a").?);
    try testing.expectEqualStrings("world!", back.get("b").?);
}

test "a file that is not a store, or is cut short, loads as empty rather than as garbage" {
    var s = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(s);
    s.* = .{};
    try testing.expect(!s.load("xx"));
    try testing.expect(!s.load("NOPE" ++ [_]u8{1}));
    try testing.expect(!s.load("TCSS" ++ [_]u8{99})); // a version from the future

    // a power cut mid-write: the header is good, the last record is not. the records that did land
    // are kept and the torn tail is dropped.
    try s.put("good", "12345");
    var file = testing.allocator.alloc(u8, budget + 64) catch unreachable;
    defer testing.allocator.free(file);
    const n = s.save(file);
    var back = testing.allocator.create(Store) catch unreachable;
    defer testing.allocator.destroy(back);
    back.* = .{};
    try testing.expect(back.load(file[0 .. n - 2]));
    try testing.expectEqual(@as(usize, 0), back.count()); // that one record was the torn one
}

test "an upload assembles in order and refuses a chunk that is not next" {
    var u = testing.allocator.create(Upload) catch unreachable;
    defer testing.allocator.destroy(u);
    u.* = .{};
    try u.begin("chime");
    try u.chunk(0, "abcd");
    try u.chunk(4, "efgh");
    try testing.expectEqualStrings("abcdefgh", u.slice());

    // a retry of a chunk already taken, or one that skips ahead, would corrupt the sound silently.
    // the uploader can recover from an error; the device cannot recover from bad samples.
    try testing.expectError(Error.BadOffset, u.chunk(4, "ijkl"));
    try testing.expectError(Error.BadOffset, u.chunk(99, "ijkl"));
    try testing.expectEqualStrings("abcdefgh", u.slice());
}

test "an upload is bounded by both the chunk size and the sound size" {
    var u = testing.allocator.create(Upload) catch unreachable;
    defer testing.allocator.destroy(u);
    u.* = .{};
    try testing.expectError(Error.NameInvalid, u.begin("no slashes/here"));
    try u.begin("chime");
    const over = [_]u8{0} ** (chunk_max + 1);
    try testing.expectError(Error.TooLarge, u.chunk(0, &over));
    u.cancel();
    try testing.expectError(Error.NotFound, u.chunk(0, "a"));
}
