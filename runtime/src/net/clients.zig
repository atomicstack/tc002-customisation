//! named api tokens: one per integration, so a caller is an identity rather than an anonymous
//! holder of one of two shared secrets. the store is fixed-capacity like every buffer here.
const std = @import("std");
const api = @import("api.zig");
const http = @import("http.zig");

const testing = std.testing;

/// what a token may do, one bit each.
///
/// this replaced a `read`/`control` ladder, which could not express the thing almost every
/// integration actually wants: a token that may raise a notification and nothing else. the scopes
/// are the route table's own groupings rather than a taxonomy invented for them -- each one is a
/// set of routes that arrive together in practice.
///
/// `admin` is not a scope. an admin token is one that holds every bit, and `tokens` is the bit no
/// named client may be granted: a token that can mint tokens can mint itself more, and revoking it
/// would stop meaning anything.
pub const Scope = enum(u4) {
    /// the safe reads: status, scenes, icons, settings, the canvas, the sprite and sound lists
    status = 0,
    /// `GET /screen`. the one read that returns what is on the panel rather than how it is set up
    screen = 1,
    /// the log ring and the event stream. the ring carries whatever any component printed,
    /// including a script's own `print`, so it is the read that can show what nobody published
    logs = 2,
    /// `POST /notify`, and nothing else. the token you give a script that has something to say
    notify = 3,
    /// what is on the panel right now: the scene, brightness, power, a frame, a canvas update
    display = 4,
    /// the speaker. a sound in a bedroom is a different kind of consent from a pixel
    sound = 5,
    /// `POST /input`. **this reaches the device menu**, and through it brightness, the night
    /// schedule, the ip layout, mqtt and ntfy on or off, and a reboot -- `display`, `settings`
    /// and `reboot` over http. granting it grants those and more; see SECURITY.md
    input = 6,
    /// stored assets: sprites, sounds and a whole canvas document. durable, but not dangerous
    content = 7,
    /// the berry script store, and running one. a script drives the panel for as long as it likes
    scripts = 8,
    /// durable device configuration, and the only place credentials live
    settings = 9,
    /// the token routes themselves. held by the admin token alone
    tokens = 10,
    /// `POST /reboot`, and nothing else. the one route that takes the clock off the network for
    /// a minute, so it is its own bit: a token that may reboot need not be able to reconfigure
    reboot = 11,

    pub fn bit(self: Scope) Set {
        return @as(Set, 1) << @intFromEnum(self);
    }
};

/// a set of scopes. `u16` holds every bit with room for four more.
pub const Set = u16;

pub const count = @typeInfo(Scope).@"enum".fields.len;
/// every bit: what the admin token holds
pub const all: Set = (@as(Set, 1) << count) - 1;
/// what a named client may hold. minting is the one thing that cannot be delegated
pub const grantable: Set = all & ~Scope.tokens.bit();

pub fn has(set: Set, scope: Scope) bool {
    return set & scope.bit() != 0;
}

/// the widest a scope set is in the credentials file, as `a|b|c`
pub const text_max = blk: {
    var n: usize = 0;
    for (@typeInfo(Scope).@"enum".fields) |f| n += f.name.len + 1;
    break :blk n;
};

/// a scope set as the credentials file holds it: names joined by `|`, because that file's whole
/// point is that a person can read it. an empty set writes as `-`, which is not a scope name.
pub fn renderSet(set: Set, out: *[text_max]u8) []const u8 {
    var w: usize = 0;
    for (std.enums.values(Scope)) |scope| {
        if (!has(set, scope)) continue;
        if (w > 0) {
            out[w] = '|';
            w += 1;
        }
        const name = @tagName(scope);
        @memcpy(out[w..][0..name.len], name);
        w += name.len;
    }
    if (w == 0) {
        out[0] = '-';
        return out[0..1];
    }
    return out[0..w];
}

/// the inverse. an unknown name fails the whole set rather than being skipped: a credentials file
/// written by a newer build would otherwise quietly grant less than it says, which is the kind of
/// difference nobody notices until the integration stops working.
pub fn parseSet(text: []const u8) ?Set {
    if (text.len == 0) return null;
    if (std.mem.eql(u8, text, "-")) return 0;
    var set: Set = 0;
    var it = std.mem.splitScalar(u8, text, '|');
    while (it.next()) |part| {
        const scope = std.meta.stringToEnum(Scope, part) orelse return null;
        set |= scope.bit();
    }
    return set;
}

/// the widest a scope list can render, as `"a","b",...`
const scope_list_max = blk: {
    var n: usize = 0;
    for (@typeInfo(Scope).@"enum".fields) |f| n += f.name.len + 3; // quotes and a comma
    break :blk n;
};

/// a name is a path segment in `DELETE /api/v1/tokens/{name}` and a token in the log ring
pub const name_max = 32;

/// as many named tokens as the device will hold.
///
/// this is **chosen**, and the assertion below is what keeps it honest. it used to be derived --
/// the response buffer divided by the widest json row -- which had the right instinct and the
/// wrong direction: a device must not accept what it cannot then show you, but that is an
/// invariant to check, not a way to pick a number. deriving it gave 99, which is not a number
/// anyone wanted for a desk clock, and it was not free: ninety-nine slots cost 8.7 kb of store in
/// netd and again in the supervisor, and 11.3 kb of credentials-file buffer. it also meant a
/// cosmetic change to the listing silently changed how many tokens the device could hold, which is
/// exactly what widening a row for scopes would have done -- 99 down to 57.
///
/// sixteen is more integrations than this clock will have. the comptime check below is the rule
/// the derivation was reaching for, stated directly.
pub const max_clients = 16;

/// a listing row at its widest: a full-length name, every scope named, and both timestamps at the
/// full width of the type even though they are unix seconds and never will be.
const listing_row_max = "{\"name\":\"\",\"scopes\":[],\"created_s\":-9223372036854775808,\"last_used_s\":-9223372036854775808},".len + name_max + scope_list_max;
const listing_envelope = "{\"clients\":[],\"max\":65535}".len;

comptime {
    // the invariant the old derivation was trying to express: a full store still renders in one
    // response. `renderList` refuses to truncate, so if this ever fails the listing route would
    // start answering with nothing at all.
    std.debug.assert(listing_envelope + max_clients * listing_row_max <= http.response_buf_len);
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
    scopes: Set = 0,
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
        if (!put(out, &w, "{s}{{\"name\":\"{s}\",\"scopes\":[", .{ if (i > 0) "," else "", c.name.slice() })) return null;
        var first = true;
        for (std.enums.values(Scope)) |scope| {
            if (!has(c.scopes, scope)) continue;
            if (!put(out, &w, "{s}\"{s}\"", .{ if (first) "" else ",", @tagName(scope) })) return null;
            first = false;
        }
        if (!put(out, &w, "],\"created_s\":{d},\"last_used_s\":{d}}}", .{ c.created_s, c.last_used_s })) return null;
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

    pub fn add(self: *Store, name: []const u8, scopes: Set, token: api.Token, now_s: i64) error{ NameTaken, StoreFull, InvalidName }!void {
        if (!validName(name)) return error.InvalidName;
        if (self.find(name) != null) return error.NameTaken;
        if (self.len == max_clients) return error.StoreFull;
        self.entries[self.len] = .{ .name = Name.init(name), .scopes = scopes & grantable, .token = token, .created_s = now_s, .last_used_s = 0 };
        self.len += 1;
    }

    /// replace a client's secret in place. rotation is not create-then-revoke: at capacity there
    /// is no free slot, so that shape cannot rotate the token you would most need to, and it is
    /// two calls where a failure between them leaves either two live secrets or a dead client.
    /// `created_s` moves to now, because for a credential the age that matters is the secret's;
    /// `last_used_s` resets to zero, which is then a useful signal that nothing has picked the new
    /// secret up yet. the scopes are unchanged unless a set is supplied.
    pub fn rotate(self: *Store, name: []const u8, token: api.Token, now_s: i64, scopes: ?Set) bool {
        for (self.entries[0..self.len]) |*c| {
            if (!std.mem.eql(u8, c.name.slice(), name)) continue;
            c.token = token;
            c.created_s = now_s;
            c.last_used_s = 0;
            if (scopes) |sc| c.scopes = sc & grantable;
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


// the two sets the old role ladder could express, kept here only so the store's own tests read the
// way they did. the point of scopes is everything between and beside them.
const read_set: Set = Scope.status.bit();
const control_set: Set = Scope.status.bit() | Scope.display.bit();

test "a set survives the round trip through the credentials file's text form" {
    var buf: [text_max]u8 = undefined;
    try testing.expectEqualStrings("status|display", renderSet(control_set, &buf));
    try testing.expectEqual(control_set, parseSet("status|display").?);
    try testing.expectEqualStrings("-", renderSet(0, &buf));
    try testing.expectEqual(@as(Set, 0), parseSet("-").?);
    try testing.expectEqualStrings("status|screen|logs|notify|display|sound|input|content|scripts|settings|tokens|reboot", renderSet(all, &buf));
    try testing.expectEqual(all, parseSet(renderSet(all, &buf)).?);
    // an unknown name fails the whole set rather than quietly granting less than it says
    try testing.expect(parseSet("status|wat") == null);
    try testing.expect(parseSet("") == null);
}

test "minting is the one thing a named client cannot be given" {
    var s = Store{};
    try s.add("greedy", all, [_]u8{1} ** 32, 100);
    const c = s.find("greedy").?;
    try testing.expect(!has(c.scopes, .tokens));
    try testing.expect(has(c.scopes, .settings)); // everything else it asked for, it got
    try testing.expectEqual(grantable, c.scopes);
}

test "a store holds named clients and refuses a duplicate or a full store" {
    var s = Store{};
    try s.add("kitchen", control_set, [_]u8{1} ** 32, 100);
    try testing.expectError(error.NameTaken, s.add("kitchen", read_set, [_]u8{2} ** 32, 101));
    try testing.expect(has(s.find("kitchen").?.scopes, .display));
    try testing.expect(s.find("absent") == null);
    var i: usize = 1;
    while (i < max_clients) : (i += 1) {
        var buf: [8]u8 = undefined;
        try s.add(std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable, read_set, [_]u8{@intCast(i & 0xff)} ** 32, 100);
    }
    try testing.expectError(error.StoreFull, s.add("one-too-many", read_set, [_]u8{9} ** 32, 100));
}

test "removing frees the slot and does not disturb the others" {
    var s = Store{};
    try s.add("a", read_set, [_]u8{1} ** 32, 100);
    try s.add("b", control_set, [_]u8{2} ** 32, 100);
    try testing.expect(s.remove("a"));
    try testing.expect(!s.remove("a"));
    try testing.expect(s.find("a") == null);
    try testing.expect(has(s.find("b").?.scopes, .display));
    try testing.expectEqual(@as(usize, 1), s.len);
}

test "a token matches its own client and nothing else" {
    var s = Store{};
    try s.add("a", read_set, [_]u8{1} ** 32, 100);
    try s.add("b", control_set, [_]u8{2} ** 32, 100);
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
    try testing.expectError(error.InvalidName, s.add("has space", read_set, [_]u8{1} ** 32, 100));
    try testing.expectEqual(@as(usize, 0), s.len);
}

test "rotation replaces the secret in place, and works when the store is full" {
    var s = Store{};
    // fill it: rotation must not need a free slot, which is exactly when it matters most
    var i: usize = 0;
    while (i < max_clients) : (i += 1) {
        var buf: [8]u8 = undefined;
        try s.add(std.fmt.bufPrint(&buf, "c{d}", .{i}) catch unreachable, control_set, [_]u8{@intCast(i & 0xff)} ** 32, 100);
    }
    try testing.expectError(error.StoreFull, s.add("another", read_set, [_]u8{9} ** 32, 200));

    const before = s.find("c0").?.*;
    try testing.expect(s.rotate("c0", [_]u8{0xee} ** 32, 500, null));
    const after = s.find("c0").?;
    try testing.expectEqual([_]u8{0xee} ** 32, after.token);
    try testing.expectEqual(@as(i64, 500), after.created_s); // the age that matters is the secret's
    try testing.expectEqual(@as(i64, 0), after.last_used_s); // nothing has picked the new one up yet
    try testing.expectEqual(before.scopes, after.scopes); // unchanged when none is supplied
    try testing.expectEqual(max_clients, s.len); // no slot consumed
    try testing.expect(s.match([_]u8{0} ** 32) == null); // the old secret is gone
    try testing.expectEqual(@as(?usize, 0), s.match([_]u8{0xee} ** 32));
}

test "rotation can change the scopes, and refuses a name that is not a client" {
    var s = Store{};
    try s.add("wall", read_set, [_]u8{1} ** 32, 100);
    try testing.expect(s.rotate("wall", [_]u8{2} ** 32, 200, control_set));
    try testing.expect(has(s.find("wall").?.scopes, .display));
    // control and admin are not clients and are not in this namespace
    try testing.expect(!s.rotate("absent", [_]u8{3} ** 32, 200, null));
    try testing.expect(!s.rotate("control", [_]u8{3} ** 32, 200, null));
    try testing.expect(!s.rotate("admin", [_]u8{3} ** 32, 200, null));
}
