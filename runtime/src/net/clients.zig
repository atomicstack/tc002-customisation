//! named api tokens: one per integration, so a caller is an identity rather than an anonymous
//! holder of one of two shared secrets. the store is fixed-capacity like every buffer here.
const std = @import("std");
const api = @import("api.zig");

const testing = std.testing;

/// read observes, control also changes things. admin is deliberately not a role a client can
/// hold: a named token that could be admin could mint itself more, and revocation would stop
/// meaning much. the wire encoding is `@intFromEnum`, so the order is part of the protocol.
pub const Role = enum(u8) { read = 0, control = 1 };

/// a name is a path segment in `DELETE /api/v1/tokens/{name}` and a token in the log ring
pub const name_max = 32;

/// placeholder until task 7 derives it from the listing that has to fit one response
pub const max_clients = 120;

/// a client name as it travels over ipc: fixed width, because every buffer here is.
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

/// what a name may contain. `berry/store.zig`'s rule minus the comma, because the credentials
/// file separates a client's fields with one.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    // a leading dot would make a name that looks like a path trick even though nothing here is a path
    return name[0] != '.';
}

pub const Client = struct {
    name: Name = .{},
    role: Role = .read,
    token: api.Token = [_]u8{0} ** api.token_len,
    created_s: i64 = 0,
    last_used_s: i64 = 0,
};

pub const Store = struct {
    entries: [max_clients]Client = [_]Client{.{}} ** max_clients,
    len: usize = 0,

    pub fn find(self: *const Store, name: []const u8) ?*const Client {
        for (self.entries[0..self.len]) |*c| if (std.mem.eql(u8, c.name.slice(), name)) return c;
        return null;
    }

    pub fn add(self: *Store, name: []const u8, role: Role, token: api.Token, now_s: i64) error{ NameTaken, StoreFull, InvalidName }!void {
        if (!validName(name)) return error.InvalidName;
        if (self.find(name) != null) return error.NameTaken;
        if (self.len == max_clients) return error.StoreFull;
        self.entries[self.len] = .{ .name = Name.init(name), .role = role, .token = token, .created_s = now_s, .last_used_s = 0 };
        self.len += 1;
    }

    pub fn remove(self: *Store, name: []const u8) bool {
        for (self.entries[0..self.len], 0..) |*c, i| {
            if (!std.mem.eql(u8, c.name.slice(), name)) continue;
            // order is not meaningful, so close the gap with the last entry rather than shifting
            self.entries[i] = self.entries[self.len - 1];
            self.entries[self.len - 1] = .{};
            self.len -= 1;
            return true;
        }
        return false;
    }

    /// which client presented this token, sweeping every slot with no early exit so timing
    /// reveals neither which one matched nor how many exist.
    pub fn match(self: *const Store, presented: api.Token) ?usize {
        var hit: ?usize = null;
        for (self.entries[0..self.len], 0..) |c, i| {
            if (std.crypto.timing_safe.eql(api.Token, presented, c.token)) hit = i;
        }
        return hit;
    }
};


test "a store holds named clients and refuses a duplicate or a full store" {
    var s = Store{};
    try s.add("kitchen", .control, [_]u8{1} ** 32, 100);
    try testing.expectError(error.NameTaken, s.add("kitchen", .read, [_]u8{2} ** 32, 101));
    try testing.expectEqual(Role.control, s.find("kitchen").?.role);
    try testing.expect(s.find("absent") == null);
    var i: usize = 1;
    while (i < max_clients) : (i += 1) {
        var buf: [8]u8 = undefined;
        try s.add(std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable, .read, [_]u8{@intCast(i & 0xff)} ** 32, 100);
    }
    try testing.expectError(error.StoreFull, s.add("one-too-many", .read, [_]u8{9} ** 32, 100));
}

test "removing frees the slot and does not disturb the others" {
    var s = Store{};
    try s.add("a", .read, [_]u8{1} ** 32, 100);
    try s.add("b", .control, [_]u8{2} ** 32, 100);
    try testing.expect(s.remove("a"));
    try testing.expect(!s.remove("a"));
    try testing.expect(s.find("a") == null);
    try testing.expectEqual(Role.control, s.find("b").?.role);
    try testing.expectEqual(@as(usize, 1), s.len);
}

test "a token matches its own client and nothing else" {
    var s = Store{};
    try s.add("a", .read, [_]u8{1} ** 32, 100);
    try s.add("b", .control, [_]u8{2} ** 32, 100);
    try testing.expectEqual(@as(?usize, 0), s.match([_]u8{1} ** 32));
    try testing.expectEqual(@as(?usize, 1), s.match([_]u8{2} ** 32));
    try testing.expect(s.match([_]u8{3} ** 32) == null);
}

test "names are path segments and log tokens, so they stay boring" {
    try testing.expect(validName("kitchen"));
    try testing.expect(validName("home-assistant.bins"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("x" ** (name_max + 1)));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("has space"));
    try testing.expect(!validName("slash/es"));
    try testing.expect(!validName("comma,s"));
}

test "an invalid name never reaches the store" {
    var s = Store{};
    try testing.expectError(error.InvalidName, s.add("has space", .read, [_]u8{1} ** 32, 100));
    try testing.expectEqual(@as(usize, 0), s.len);
}
