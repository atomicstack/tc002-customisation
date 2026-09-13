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

pub const Credentials = api.Credentials;
const hex_len = api.token_len * 2;

const control_key = "control=";
const admin_key = "admin=";
pub const legacy_len = api.token_len * 2; // 64 raw bytes: control then admin
pub const encoded_len = control_key.len + hex_len + 1 + admin_key.len + hex_len + 1;

pub const Parsed = struct {
    creds: Credentials,
    /// true when read from the raw 64-byte form, so the caller can rewrite it as text
    legacy: bool,
};

/// write the text form. `out` must hold `encoded_len` bytes.
pub fn encode(creds: Credentials, out: []u8) []const u8 {
    std.debug.assert(out.len >= encoded_len);
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
        .legacy = true,
    };
    var control: ?api.Token = null;
    var admin: ?api.Token = null;
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
        } else return null; // an unknown line means a format we do not understand
    }
    return .{ .creds = .{ .control = control orelse return null, .admin = admin orelse return null }, .legacy = false };
}

const testing = std.testing;
const sample = Credentials{ .control = [_]u8{0xab} ** 32, .admin = [_]u8{0xcd} ** 32 };

test "the text form round-trips and is exactly what a shell would expect to read" {
    var buf: [encoded_len]u8 = undefined;
    const text = encode(sample, &buf);
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
    try testing.expectEqual(@as(usize, encoded_len), encode(sample, &buf).len);
}
