//! the scripts a device keeps, as one durable blob.
//!
//! not a directory of `.be` files: `sys/linux.zig` has no `readdir`, and a directory cannot be
//! updated atomically, so a power cut between two writes could leave a half-written set. one file
//! written with `saveFileAtomic` is the same discipline `config/canvas.bin` already follows.
//!
//! and not a fixed number of slots either. an earlier draft said "eight scripts of 4 kb", a number
//! borrowed from the sprite store, where eight is eight because each sprite is a fixed-size rgb
//! buffer the renderer composites at 60 fps. scripts are variable-length text that gets compiled
//! once, so the only real bounds are physical: a script has to reach berryd in one ipc datagram,
//! and the whole store has to fit a buffer the supervisor can write atomically. the count is then
//! whatever fits, and a full store reports bytes rather than "no free slot".
const std = @import("std");

test "a script goes in and comes back" {
    var s = Store{};
    try s.put("autoexec", "print('hello')");
    try std.testing.expectEqualStrings("print('hello')", s.get("autoexec").?);
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expect(s.get("missing") == null);
}

test "putting the same name again replaces it rather than growing the store" {
    var s = Store{};
    try s.put("rules", "var a = 1");
    const first = s.used();
    try s.put("rules", "var a = 2");
    try std.testing.expectEqual(@as(usize, 1), s.count());
    try std.testing.expectEqualStrings("var a = 2", s.get("rules").?);
    try std.testing.expectEqual(first, s.used());
}

test "removing frees the bytes back" {
    var s = Store{};
    try s.put("a", "1234567890");
    try s.put("b", "abc");
    const with_both = s.used();
    try std.testing.expect(s.remove("a"));
    try std.testing.expect(s.used() < with_both);
    try std.testing.expect(s.get("a") == null);
    try std.testing.expectEqualStrings("abc", s.get("b").?);
    try std.testing.expect(!s.remove("a"));
}

test "the bounds are the physical ones, and each says which" {
    var s = Store{};
    const long_name = "x" ** (name_max + 1);
    try std.testing.expectError(error.NameTooLong, s.put(long_name, "1"));
    try std.testing.expectError(error.EmptyName, s.put("", "1"));

    var big: [script_max + 1]u8 = undefined;
    @memset(&big, 'x');
    try std.testing.expectError(error.ScriptTooLong, s.put("big", &big));
}

test "a full store refuses with room left over rather than half-writing" {
    var s = Store{};
    var chunk: [script_max]u8 = undefined;
    @memset(&chunk, 'x');
    var i: usize = 0;
    var names: [16][3]u8 = undefined;
    while (i < names.len) : (i += 1) {
        names[i] = .{ 's', @intCast('0' + i / 10), @intCast('0' + i % 10) };
        s.put(&names[i], &chunk) catch break;
    }
    // whatever fit, the next one is refused and the store is still coherent
    try std.testing.expectError(error.NoSpace, s.put("overflow", &chunk));
    try std.testing.expect(s.used() <= budget);
    try std.testing.expect(s.count() > 0);
    try std.testing.expectEqualStrings(&chunk, s.get(&names[0]).?);
}

test "entries keep their insertion order, so a listing is stable" {
    var s = Store{};
    try s.put("first", "1");
    try s.put("second", "2");
    try s.put("third", "3");
    var it = s.iterate();
    try std.testing.expectEqualStrings("first", it.next().?.name);
    try std.testing.expectEqualStrings("second", it.next().?.name);
    try std.testing.expectEqualStrings("third", it.next().?.name);
    try std.testing.expect(it.next() == null);
}

test "the file round-trips, and junk is refused rather than half-read" {
    var s = Store{};
    try s.put("autoexec", "print('boot')");
    try s.put("rules", "var x = 2")    ;
    var file: [budget + 64]u8 = undefined;
    const bytes = s.save(&file);

    var back = Store{};
    try back.load(bytes);
    try std.testing.expectEqual(@as(usize, 2), back.count());
    try std.testing.expectEqualStrings("print('boot')", back.get("autoexec").?);
    try std.testing.expectEqualStrings("var x = 2", back.get("rules").?);

    var wrong_magic: [16]u8 = undefined;
    @memcpy(wrong_magic[0..4], "XXXX");
    try std.testing.expectError(error.BadFile, back.load(&wrong_magic));
    try std.testing.expectError(error.BadFile, back.load(bytes[0 .. bytes.len - 3]));
    // an empty store is a legitimate file, not a failure
    var empty = Store{};
    const none = empty.save(&file);
    try back.load(none);
    try std.testing.expectEqual(@as(usize, 0), back.count());
}

/// a script must reach berryd in one ipc datagram (`codec.max_message` is 8,192) and there is no
/// chunking: this runtime already refused that trade once, for canvas documents, because a
/// half-applied document is worse than a rejected one.
pub const script_max = 8000;
/// a name is a path segment in `PUT /berry/scripts/{name}` and a token in the log ring
pub const name_max = 32;
/// the whole store. four times this is the vm's arena, so a completely full store still leaves
/// room for the scripts to actually work in.
pub const budget = 64 * 1024;

/// a script name as it travels over ipc: fixed width, because every buffer here is.
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

/// what a name may contain. it is a path segment in `PUT /berry/scripts/{name}` and a token in the
/// log ring, so it stays to characters that survive both without quoting.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    // a leading dot would make a name that looks like a path trick even though nothing here is a path
    return name[0] != '.';
}

test "names are path segments and log tokens, so they stay boring" {
    try std.testing.expect(validName("autoexec"));
    try std.testing.expect(validName("rules.doorbell"));
    try std.testing.expect(validName("a-b_c9"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("x" ** (name_max + 1)));
    try std.testing.expect(!validName("has space"));
    try std.testing.expect(!validName("../escape"));
    try std.testing.expect(!validName(".hidden"));
    try std.testing.expect(!validName("sl/ash"));
}

const magic = "TCBS";
const version: u8 = 1;
const header_len = 5;

pub const PutError = error{ EmptyName, NameTooLong, BadName, ScriptTooLong, NoSpace };

pub const Entry = struct { name: []const u8, source: []const u8 };

/// entries live packed exactly as they are written to the file, so saving is a copy and loading is
/// a validation pass. `name_len:u8, name, source_len:u16, source`, in insertion order.
pub const Store = struct {
    bytes: [budget]u8 = undefined,
    len: usize = 0,

    pub fn used(self: *const Store) usize {
        return self.len;
    }

    pub fn capacity(_: *const Store) usize {
        return budget;
    }

    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        var it = self.iterate();
        while (it.next() != null) n += 1;
        return n;
    }

    pub const Iterator = struct {
        store: *const Store,
        offset: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            if (self.offset >= self.store.len) return null;
            const b = self.store.bytes[0..self.store.len];
            const name_len = b[self.offset];
            const name_at = self.offset + 1;
            const src_len = std.mem.readInt(u16, b[name_at + name_len ..][0..2], .little);
            const src_at = name_at + name_len + 2;
            self.offset = src_at + src_len;
            return .{ .name = b[name_at..][0..name_len], .source = b[src_at..][0..src_len] };
        }
    };

    pub fn iterate(self: *const Store) Iterator {
        return .{ .store = self };
    }

    pub fn get(self: *const Store, name: []const u8) ?[]const u8 {
        var it = self.iterate();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e.source;
        return null;
    }

    /// add or replace. the old entry goes first, so replacing never needs room for both.
    pub fn put(self: *Store, name: []const u8, source: []const u8) PutError!void {
        if (name.len == 0) return error.EmptyName;
        if (name.len > name_max) return error.NameTooLong;
        if (!validName(name)) return error.BadName;
        if (source.len > script_max) return error.ScriptTooLong;
        _ = self.remove(name);
        const need = 1 + name.len + 2 + source.len;
        if (self.len + need > budget) return error.NoSpace;
        var o = self.len;
        self.bytes[o] = @intCast(name.len);
        o += 1;
        @memcpy(self.bytes[o..][0..name.len], name);
        o += name.len;
        std.mem.writeInt(u16, self.bytes[o..][0..2], @intCast(source.len), .little);
        o += 2;
        @memcpy(self.bytes[o..][0..source.len], source);
        self.len += need;
    }

    /// true when something was there
    pub fn remove(self: *Store, name: []const u8) bool {
        var offset: usize = 0;
        while (offset < self.len) {
            const name_len = self.bytes[offset];
            const name_at = offset + 1;
            const src_len = std.mem.readInt(u16, self.bytes[name_at + name_len ..][0..2], .little);
            const entry_len = 1 + @as(usize, name_len) + 2 + src_len;
            if (std.mem.eql(u8, self.bytes[name_at..][0..name_len], name)) {
                const tail = offset + entry_len;
                std.mem.copyForwards(u8, self.bytes[offset..], self.bytes[tail..self.len]);
                self.len -= entry_len;
                return true;
            }
            offset += entry_len;
        }
        return false;
    }

    pub fn clear(self: *Store) void {
        self.len = 0;
    }

    /// the file: magic, version, then the packed entries exactly as they are held
    pub fn save(self: *const Store, out: []u8) []u8 {
        @memcpy(out[0..4], magic);
        out[4] = version;
        @memcpy(out[header_len..][0..self.len], self.bytes[0..self.len]);
        return out[0 .. header_len + self.len];
    }

    /// replace the contents from a file. a file that does not parse whole is refused outright:
    /// half a script set is worse than none, because it looks like a deliberate one.
    pub fn load(self: *Store, file: []const u8) error{BadFile}!void {
        if (file.len < header_len) return error.BadFile;
        if (!std.mem.eql(u8, file[0..4], magic) or file[4] != version) return error.BadFile;
        const body = file[header_len..];
        if (body.len > budget) return error.BadFile;
        // validate before keeping anything
        var offset: usize = 0;
        while (offset < body.len) {
            if (offset + 1 > body.len) return error.BadFile;
            const name_len = body[offset];
            if (name_len == 0 or name_len > name_max) return error.BadFile;
            if (offset + 1 + name_len + 2 > body.len) return error.BadFile;
            const src_len = std.mem.readInt(u16, body[offset + 1 + name_len ..][0..2], .little);
            if (src_len > script_max) return error.BadFile;
            const entry_len = 1 + @as(usize, name_len) + 2 + src_len;
            if (offset + entry_len > body.len) return error.BadFile;
            offset += entry_len;
        }
        @memcpy(self.bytes[0..body.len], body);
        self.len = body.len;
    }
};
