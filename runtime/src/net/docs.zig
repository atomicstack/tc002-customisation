//! bounded, public, offline reference assets. api execution still needs bearer authentication.
const std = @import("std");
pub const Asset = enum {
    page,
    script,
    style,
    openapi,
    schema,

    pub fn bytes(self: Asset) []const u8 {
        return switch (self) {
            .page => @embedFile("docs/index.html"),
            .script => @embedFile("docs/app.js"),
            .style => @embedFile("docs/style.css"),
            .openapi => @embedFile("docs/openapi.json"),
            .schema => @embedFile("docs/schema.json"),
        };
    }

    pub fn contentType(self: Asset) []const u8 {
        return switch (self) {
            .page => "text/html; charset=utf-8",
            .script => "text/javascript; charset=utf-8",
            .style => "text/css; charset=utf-8",
            .openapi => "application/json",
            .schema => "application/schema+json",
        };
    }
};
pub fn lookup(path: []const u8) ?Asset {
    const paths = .{
        .{ "/api/docs", Asset.page },            .{ "/api/docs/", Asset.page },
        .{ "/api/docs/app.js", Asset.script },   .{ "/api/docs/style.css", Asset.style },
        .{ "/api/openapi.json", Asset.openapi }, .{ "/api/schema.json", Asset.schema },
    };
    inline for (paths) |pair| if (std.mem.eql(u8, path, pair[0])) return pair[1];
    return null;
}
pub const Transfer = struct {
    body: []const u8,
    offset: usize = 0,
    pub fn next(self: *Transfer, out: []u8) []const u8 {
        const n = @min(out.len, self.body.len - self.offset);
        @memcpy(out[0..n], self.body[self.offset..][0..n]);
        self.offset += n;
        return out[0..n];
    }
};

test "only exact documentation asset paths are public" {
    try std.testing.expectEqual(@as(?Asset, .page), lookup("/api/docs"));
    try std.testing.expectEqual(@as(?Asset, .page), lookup("/api/docs/"));
    try std.testing.expectEqual(@as(?Asset, .script), lookup("/api/docs/app.js"));
    try std.testing.expectEqual(@as(?Asset, .style), lookup("/api/docs/style.css"));
    try std.testing.expectEqual(@as(?Asset, .openapi), lookup("/api/openapi.json"));
    try std.testing.expectEqual(@as(?Asset, .schema), lookup("/api/schema.json"));
    for ([_][]const u8{ "/api/v1/config", "/api/docs/../config", "/api/docs/secrets", "/api/docs.js", "/api/openapi.json/" }) |path| {
        try std.testing.expectEqual(@as(?Asset, null), lookup(path));
    }
}

test "static bodies larger than the connection buffer are sent in exact bounded chunks" {
    const payload = "a bounded buffer must still deliver the whole schema";
    var t = Transfer{ .body = payload };
    var out: [7]u8 = undefined;
    var seen: usize = 0;
    while (seen < payload.len) {
        const chunk = t.next(&out);
        try std.testing.expect(chunk.len > 0 and chunk.len <= out.len);
        try std.testing.expectEqualSlices(u8, payload[seen..][0..chunk.len], chunk);
        seen += chunk.len;
    }
    try std.testing.expectEqual(@as(usize, 0), t.next(&out).len);
    try std.testing.expectEqual(payload.len, t.offset);
}

pub fn header(out: []u8, content_type: []const u8, size: usize) []const u8 {
    return std.fmt.bufPrint(out, "HTTP/1.1 200 OK\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\ncache-control: no-store\r\nx-content-type-options: nosniff\r\nreferrer-policy: no-referrer\r\ncontent-security-policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n", .{ content_type, size }) catch out[0..0];
}

test "asset response headers declare the full length and forbid external code" {
    var out: [1024]u8 = undefined;
    const h = header(&out, "application/json", 98765);
    try std.testing.expect(std.mem.indexOf(u8, h, "content-length: 98765\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "content-type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "connect-src 'self'") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "x-content-type-options: nosniff\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, h, "\r\n\r\n"));
}
