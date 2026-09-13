//! named api tokens: one per integration, so a caller is an identity rather than an anonymous
//! holder of one of two shared secrets. the store is fixed-capacity like every buffer here.
const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");

const testing = std.testing;

/// read observes, control also changes things. admin is deliberately not a role a client can
/// hold: a named token that could be admin could mint itself more, and revocation would stop
/// meaning much. the wire encoding is `@intFromEnum`, so the order is part of the protocol.
pub const Role = enum(u8) { read = 0, control = 1 };

/// a name is a path segment in `DELETE /api/v1/tokens/{name}` and a token in the log ring
pub const name_max = 32;

/// a listing row at its widest: a full-length name and both timestamps at full width.
const listing_row_max = "{\"name\":\"\",\"role\":\"control\",\"created_s\":-9223372036854775808,\"last_used_s\":-9223372036854775808},".len + name_max;
const listing_envelope = "{\"clients\":[],\"max\":65535}".len + 512; // plus room for the http head

/// as many clients as `GET /api/v1/tokens` can return in one response. this is the constraint that
/// actually binds -- not the ipc packet, which clients do not travel in as a set -- and it is the
/// same rule the response buffer itself was sized by: a device must not accept something it cannot
/// then show you. derived, so that adding a field to the row lowers this rather than silently
/// truncating a reply.
pub const max_clients = (http.response_buf_len - listing_envelope) / listing_row_max;

comptime {
    std.debug.assert(max_clients >= 16);
}

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

/// render the listing. returns null rather than a truncated reply if it would not fit, which is
/// the failure `max_clients` exists to make impossible -- so a null here means the derivation
/// above is wrong, not that the caller asked for too much.
pub fn renderList(store: *const Store, out: []u8) ?[]const u8 {
    var w: usize = 0;
    const put = struct {
        fn f(buf: []u8, at: *usize, comptime f_: []const u8, args: anytype) bool {
            const r = std.fmt.bufPrint(buf[at.*..], f_, args) catch return false;
            at.* += r.len;
            return true;
        }
    }.f;
    if (!put(out, &w, "{{\"clients\":[", .{})) return null;
    for (store.entries[0..store.len], 0..) |c, i| {
        if (!put(out, &w, "{s}{{\"name\":\"{s}\",\"role\":\"{s}\",\"created_s\":{d},\"last_used_s\":{d}}}", .{
            if (i > 0) "," else "",
            c.name.slice(),
            @tagName(c.role),
            c.created_s,
            c.last_used_s,
        })) return null;
    }
    if (!put(out, &w, "],\"max\":{d}}}", .{max_clients})) return null;
    return out[0..w];
}

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

    /// replace a client's secret in place. rotation is not create-then-revoke: at capacity there
    /// is no free slot, so that shape cannot rotate the token you would most need to, and it is
    /// two calls where a failure between them leaves either two live secrets or a dead client.
    /// `created_s` moves to now, because for a credential the age that matters is the secret's;
    /// `last_used_s` resets to zero, which is then a useful signal that nothing has picked the new
    /// secret up yet. the role is unchanged unless one is supplied.
    pub fn rotate(self: *Store, name: []const u8, token: api.Token, now_s: i64, role: ?Role) bool {
        for (self.entries[0..self.len]) |*c| {
            if (!std.mem.eql(u8, c.name.slice(), name)) continue;
            c.token = token;
            c.created_s = now_s;
            c.last_used_s = 0;
            if (role) |r| c.role = r;
            return true;
        }
        return false;
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

test "rotation replaces the secret in place, and works when the store is full" {
    var s = Store{};
    // fill it: rotation must not need a free slot, which is exactly when it matters most
    var i: usize = 0;
    while (i < max_clients) : (i += 1) {
        var buf: [8]u8 = undefined;
        try s.add(std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable, .control, [_]u8{@intCast(i & 0xff)} ** 32, 100);
    }
    try testing.expectError(error.StoreFull, s.add("another", .read, [_]u8{9} ** 32, 200));

    const before = s.find("c0").?.*;
    try testing.expect(s.rotate("c0", [_]u8{0xee} ** 32, 500, null));
    const after = s.find("c0").?;
    try testing.expectEqual([_]u8{0xee} ** 32, after.token);
    try testing.expectEqual(@as(i64, 500), after.created_s); // the age that matters is the secret's
    try testing.expectEqual(@as(i64, 0), after.last_used_s); // nothing has picked the new one up yet
    try testing.expectEqual(before.role, after.role); // unchanged when none is supplied
    try testing.expectEqual(max_clients, s.len); // no slot consumed
    try testing.expect(s.match([_]u8{0} ** 32) == null); // the old secret is gone
    try testing.expectEqual(@as(?usize, 0), s.match([_]u8{0xee} ** 32));
}

test "rotation can change the role, and refuses a name that is not a client" {
    var s = Store{};
    try s.add("wall", .read, [_]u8{1} ** 32, 100);
    try testing.expect(s.rotate("wall", [_]u8{2} ** 32, 200, .control));
    try testing.expectEqual(Role.control, s.find("wall").?.role);
    // control and admin are not clients and are not in this namespace
    try testing.expect(!s.rotate("absent", [_]u8{3} ** 32, 200, null));
    try testing.expect(!s.rotate("control", [_]u8{3} ** 32, 200, null));
    try testing.expect(!s.rotate("admin", [_]u8{3} ** 32, 200, null));
}
