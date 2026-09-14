//! the on-disk form of the api tokens. the file is text so it can be read, copied and pasted into
//! a shell by hand:
//!
//!     control=<64 hex>
//!     admin=<64 hex>
//!
//! it used to be 64 raw bytes, control then admin, which no consumer ever wanted: the wire form is
//! hex either way, so every reader encoded it first, and a shell could not hold it at all. reading
//! still accepts the raw form so an existing install keeps its tokens; the supervisor rewrites it
//! in place on the next start. labelling each token is what stops the older file's real hazard --
//! the two halves are interchangeable to look at, and picking the wrong one silently grants admin,
//! because an admin token satisfies a control route.
const std = @import("std");
const api = @import("api.zig");
const clients = @import("clients.zig");

pub const Credentials = api.Credentials;
const hex_len = api.token_len * 2;

const control_key = "control=";
const admin_key = "admin=";
const client_key = "client=";
pub const legacy_len = api.token_len * 2; // 64 raw bytes: control then admin
pub const encoded_len = control_key.len + hex_len + 1 + admin_key.len + hex_len + 1;
/// one client line is `client=<name>,<scope|scope|...>,<64 hex>\n`, with the scope set written as
/// names rather than a bitmask: this file's whole point is that a person can read it, and `0x2f`
/// tells them nothing about what they are looking at.
const client_line_max = client_key.len + clients.name_max + 1 + clients.text_max + 1 + hex_len + 1;
/// the whole file at capacity, which is what the supervisor's read and write buffers must hold
pub const encoded_max = encoded_len + clients.max_clients * client_line_max;

pub const Parsed = struct {
    creds: Credentials,
    clients: clients.Store,
    /// true when read from the raw 64-byte form, so the caller can rewrite it as text
    legacy: bool,
};

/// write the text form. `out` must hold `encoded_max` bytes.
pub fn encode(creds: Credentials, store: *const clients.Store, out: []u8) []const u8 {
    std.debug.assert(out.len >= encoded_len + store.len * client_line_max);
    var w: usize = 0;
    for ([_]struct { key: []const u8, tok: api.Token }{
        .{ .key = control_key, .tok = creds.control },
        .{ .key = admin_key, .tok = creds.admin },
    }) |e| {
        @memcpy(out[w..][0..e.key.len], e.key);
        w += e.key.len;
        w += (std.fmt.bufPrint(out[w..], "{x}", .{&e.tok}) catch unreachable).len;
        out[w] = '\n';
        w += 1;
    }
    for (store.entries[0..store.len]) |c| {
        @memcpy(out[w..][0..client_key.len], client_key);
        w += client_key.len;
        var scope_buf: [clients.text_max]u8 = undefined;
        w += (std.fmt.bufPrint(out[w..], "{s},{s},{x}\n", .{ c.name.slice(), clients.renderSet(c.scopes, &scope_buf), &c.token }) catch unreachable).len;
    }
    return out[0..w];
}

fn hexToken(text: []const u8) ?api.Token {
    if (text.len != hex_len) return null;
    var tok: api.Token = undefined;
    _ = std.fmt.hexToBytes(&tok, text) catch return null;
    return tok;
}

/// read either form. lenient about line endings and a missing final newline; strict about
/// everything else, because a half-understood credentials file must not half-work.
pub fn parse(bytes: []const u8) ?Parsed {
    if (bytes.len == legacy_len) return .{
        .creds = .{ .control = bytes[0..api.token_len].*, .admin = bytes[api.token_len..][0..api.token_len].* },
        .clients = .{},
        .legacy = true,
    };
    var control: ?api.Token = null;
    var admin: ?api.Token = null;
    var store = clients.Store{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, control_key)) {
            if (control != null) return null; // a duplicate key is ambiguous, not a preference
            control = hexToken(line[control_key.len..]) orelse return null;
        } else if (std.mem.startsWith(u8, line, admin_key)) {
            if (admin != null) return null;
            admin = hexToken(line[admin_key.len..]) orelse return null;
        } else if (std.mem.startsWith(u8, line, client_key)) {
            // `<name>,<scopes>,<64 hex>`. a client line that is not wholly understood refuses the
            // whole file, like every other line here -- including a scope name this build does not
            // know, because granting less than the file says is worse than refusing to start.
            var field = std.mem.splitScalar(u8, line[client_key.len..], ',');
            const name = field.next() orelse return null;
            const scope_text = field.next() orelse return null;
            const token_text = field.next() orelse return null;
            if (field.next() != null) return null;
            const scopes = clients.parseSet(scope_text) orelse return null;
            store.add(name, scopes, hexToken(token_text) orelse return null, 0) catch return null;
        } else return null; // an unknown line means a format we do not understand
    }
    return .{
        .creds = .{ .control = control orelse return null, .admin = admin orelse return null },
        .clients = store,
        .legacy = false,
    };
}

const testing = std.testing;
const sample = Credentials{ .control = [_]u8{0xab} ** 32, .admin = [_]u8{0xcd} ** 32 };
const empty_store = clients.Store{};

test "the text form round-trips and is exactly what a shell would expect to read" {
    var buf: [encoded_len]u8 = undefined;
    const text = encode(sample, &empty_store, &buf);
    try testing.expectEqualStrings("control=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n", text);
    const p = parse(text).?;
    try testing.expectEqual(sample, p.creds);
    try testing.expect(!p.legacy);
}

test "the raw 64-byte form still reads, and says so" {
    var raw: [legacy_len]u8 = undefined;
    @memcpy(raw[0..32], &sample.control);
    @memcpy(raw[32..64], &sample.admin);
    const p = parse(&raw).?;
    try testing.expectEqual(sample, p.creds);
    try testing.expect(p.legacy);
}

test "reading tolerates line endings and a missing final newline" {
    try testing.expectEqual(sample, parse("control=" ++ "ab" ** 32 ++ "\r\nadmin=" ++ "cd" ** 32).?.creds);
    try testing.expectEqual(sample, parse("\ncontrol=" ++ "ab" ** 32 ++ "\n\nadmin=" ++ "cd" ** 32 ++ "\n\n").?.creds);
}

test "order does not matter, because a file a human edited need not keep ours" {
    try testing.expectEqual(sample, parse("admin=" ++ "cd" ** 32 ++ "\ncontrol=" ++ "ab" ** 32 ++ "\n").?.creds);
}

test "anything half-understood is refused rather than half-applied" {
    try testing.expect(parse("") == null);
    try testing.expect(parse("control=" ++ "ab" ** 32 ++ "\n") == null); // no admin
    try testing.expect(parse("admin=" ++ "cd" ** 32 ++ "\n") == null); // no control
    try testing.expect(parse("control=" ++ "ab" ** 31 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n") == null); // short
    try testing.expect(parse("control=" ++ "zz" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n") == null); // not hex
    try testing.expect(parse("control=" ++ "ab" ** 32 ++ "\ncontrol=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n") == null); // duplicate
    try testing.expect(parse("token=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n") == null); // unknown key
    try testing.expect(parse("control=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\njunk\n") == null);
}

test "the two forms cannot be confused for one another" {
    // the raw form is 64 bytes and the text form is 144; nothing is both.
    try testing.expect(legacy_len != encoded_len);
    var buf: [encoded_len]u8 = undefined;
    try testing.expectEqual(@as(usize, encoded_len), encode(sample, &empty_store, &buf).len);
}

test "client lines round-trip alongside the built-in tokens" {
    const kitchen = clients.Scope.notify.bit() | clients.Scope.display.bit();
    const wall = clients.Scope.status.bit();
    var store = clients.Store{};
    try store.add("kitchen", kitchen, [_]u8{0x11} ** 32, 1000);
    try store.add("wall", wall, [_]u8{0x22} ** 32, 1001);
    var buf: [encoded_max]u8 = undefined;
    const text = encode(sample, &store, &buf);
    // the scope set is written the way it is meant to be read, in enum order
    try testing.expect(std.mem.indexOf(u8, text, "client=kitchen,notify|display," ++ "11" ** 32 ++ "\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "client=wall,status," ++ "22" ** 32 ++ "\n") != null);
    const p = parse(text).?;
    try testing.expectEqual(sample, p.creds);
    try testing.expectEqual(@as(usize, 2), p.clients.len);
    try testing.expectEqual(wall, p.clients.find("wall").?.scopes);
    try testing.expectEqual(kitchen, p.clients.find("kitchen").?.scopes);
}

test "a scope name this build does not know refuses the whole file" {
    // granting less than the file says is a silent downgrade of someone's integration; refusing to
    // start is loud, and the log ring says which file could not be read.
    const line = "control=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\nclient=x,notify|teleport," ++ "11" ** 32 ++ "\n";
    try testing.expect(parse(line) == null);
}

test "a file with no client lines is still valid, and yields an empty store" {
    const p = parse("control=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n").?;
    try testing.expectEqual(@as(usize, 0), p.clients.len);
}

test "the raw legacy form yields an empty store rather than failing" {
    var raw: [legacy_len]u8 = undefined;
    @memcpy(raw[0..32], &sample.control);
    @memcpy(raw[32..64], &sample.admin);
    const p = parse(&raw).?;
    try testing.expect(p.legacy);
    try testing.expectEqual(@as(usize, 0), p.clients.len);
}

test "a malformed client line refuses the whole file" {
    const base = "control=" ++ "ab" ** 32 ++ "\nadmin=" ++ "cd" ** 32 ++ "\n";
    try testing.expect(parse(base ++ "client=kitchen,control\n") == null); // no token
    try testing.expect(parse(base ++ "client=kitchen,wizard," ++ "11" ** 32 ++ "\n") == null); // unknown role
    try testing.expect(parse(base ++ "client=,control," ++ "11" ** 32 ++ "\n") == null); // empty name
    try testing.expect(parse(base ++ "client=has space,control," ++ "11" ** 32 ++ "\n") == null);
    try testing.expect(parse(base ++ "client=a,control," ++ "11" ** 31 ++ "\n") == null); // short token
    try testing.expect(parse(base ++ "client=dup,read," ++ "11" ** 32 ++ "\nclient=dup,read," ++ "22" ** 32 ++ "\n") == null);
}
