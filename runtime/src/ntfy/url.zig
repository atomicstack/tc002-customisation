//! the ntfy server url: `http://` or `https://`, a host name or address, an optional port and an
//! optional path prefix (a self-hosted ntfy behind a reverse proxy). pure.
const std = @import("std");

pub const Url = struct { tls: bool, host: []const u8, port: u16, prefix: []const u8 };

pub const Error = error{Invalid};

pub fn parse(text: []const u8) Error!Url {
    var rest = text;
    var tls = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        tls = true;
        rest = rest[8..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest[7..];
    } else return error.Invalid;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    var prefix = rest[slash..];
    while (prefix.len > 0 and prefix[prefix.len - 1] == '/') prefix = prefix[0 .. prefix.len - 1];
    if (std.mem.indexOfAny(u8, prefix, "?# ") != null) return error.Invalid;
    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.Invalid;
        if (port == 0) return error.Invalid;
    }
    if (host.len == 0 or host.len > 253) return error.Invalid;
    for (host) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-')) return error.Invalid;
    return .{ .tls = tls, .host = host, .port = port, .prefix = prefix };
}

test "the official service, a self-hosted server with a port and a prefix, and bad urls" {
    const a = try parse("https://ntfy.sh");
    try std.testing.expect(a.tls);
    try std.testing.expectEqualStrings("ntfy.sh", a.host);
    try std.testing.expectEqual(@as(u16, 443), a.port);
    try std.testing.expectEqualStrings("", a.prefix);
    const b = try parse("http://10.0.0.5:8080/ntfy/");
    try std.testing.expect(!b.tls);
    try std.testing.expectEqualStrings("10.0.0.5", b.host);
    try std.testing.expectEqual(@as(u16, 8080), b.port);
    try std.testing.expectEqualStrings("/ntfy", b.prefix);
    try std.testing.expectEqual(@as(u16, 80), (try parse("http://ntfy.home.lan")).port);
    for ([_][]const u8{ "ftp://x", "https://", "http://host:0", "http://ho st", "ntfy.sh", "http://host/a?b", "http://host:99999" }) |bad| {
        try std.testing.expectError(error.Invalid, parse(bad));
    }
}
