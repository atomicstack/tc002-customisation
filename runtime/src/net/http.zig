//! a bounded http/1.1 request parser and response writer. one request per connection, headers
//! limited to 4,096 bytes, no chunked requests, no content or transfer encodings, every response
//! carries `connection: close`. pure: the sockets live in netd.
//!
//! that last part holds for every response *this* module builds. the one response that does not end
//! -- the event stream -- writes its own head in `sse.zig`, because it can carry neither a
//! content-length it cannot know nor a close it must not do.
const std = @import("std");

pub const max_head = 4096;

pub const Method = enum { GET, PUT, POST, PATCH, DELETE, other };

pub const Request = struct {
    method: Method,
    path: []const u8,
    query: []const u8,
    host: ?[]const u8 = null,
    content_length: ?usize = null,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    origin: ?[]const u8 = null,
    /// bytes consumed by the head including the blank line
    head_len: usize,
};

pub const ParseError = error{ Incomplete, TooLarge, Malformed, Unsupported };

test "a get with headers parses" {
    const r = try parseHead("GET /api/v1/status?x=1 HTTP/1.1\r\nHost: tc002.local\r\nAuthorization: Bearer abc\r\nOrigin: http://panel\r\n\r\n");
    try std.testing.expectEqual(Method.GET, r.method);
    try std.testing.expectEqualStrings("/api/v1/status", r.path);
    try std.testing.expectEqualStrings("x=1", r.query);
    try std.testing.expectEqualStrings("tc002.local", r.host.?);
    try std.testing.expectEqualStrings("Bearer abc", r.authorization.?);
    try std.testing.expectEqualStrings("http://panel", r.origin.?);
    try std.testing.expectEqual(@as(?usize, null), r.content_length);
    try std.testing.expectEqual(@as(usize, 103), r.head_len);
}

test "header names are case-insensitive and a post carries its length and type" {
    const r = try parseHead("POST /api/v1/notify HTTP/1.1\r\ncontent-length: 12\r\nCONTENT-TYPE: application/json\r\n\r\n{\"text\":\"x\"}");
    try std.testing.expectEqual(Method.POST, r.method);
    try std.testing.expectEqual(@as(?usize, 12), r.content_length);
    try std.testing.expectEqualStrings("application/json", r.content_type.?);
    try std.testing.expectEqualStrings("", r.query);
}

test "incomplete, oversized, malformed and unsupported heads" {
    try std.testing.expectError(error.Incomplete, parseHead("GET / HTTP/1.1\r\nHost: a\r\n"));
    var big: [max_head + 1]u8 = undefined;
    @memset(&big, 'a');
    try std.testing.expectError(error.TooLarge, parseHead(&big));
    try std.testing.expectError(error.Malformed, parseHead("GET /\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET status HTTP/1.1\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET / HTTP/1.1\r\nno-colon\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET / HTTP/1.1\r\nContent-Length: 12x\r\n\r\n"));
    try std.testing.expectError(error.Malformed, parseHead("GET / HTTP/1.1\r\n folded: 1\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("POST / HTTP/1.1\r\nContent-Encoding: gzip\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("POST / HTTP/1.1\r\nExpect: 100-continue\r\n\r\n"));
    try std.testing.expectError(error.Unsupported, parseHead("GET / HTTP/2.0\r\n\r\n"));
    const other = try parseHead("BREW / HTTP/1.1\r\n\r\n");
    try std.testing.expectEqual(Method.other, other.method);
}

test "responses are exact bytes with connection close" {
    var out: [256]u8 = undefined;
    const r = writeResponse(&out, 200, "application/json", "{\"ok\":true}");
    try std.testing.expectEqualStrings("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 11\r\nconnection: close\r\ncache-control: no-store\r\n\r\n{\"ok\":true}", r);
    var body: [128]u8 = undefined;
    const e = errorBody(&body, "invalid_input", "duration must be 1..300", 0x1234);
    try std.testing.expectEqualStrings("{\"error\":\"invalid_input\",\"message\":\"duration must be 1..300\",\"request_id\":\"0000000000001234\"}", e);
    try std.testing.expectEqualStrings("Payload Too Large", reason(413));
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

pub fn parseHead(buf: []const u8) ParseError!Request {
    const end = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse {
        return if (buf.len >= max_head) error.TooLarge else error.Incomplete;
    };
    if (end + 4 > max_head) return error.TooLarge;
    const head = buf[0..end];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return error.Malformed;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_text = parts.next() orelse return error.Malformed;
    const target = parts.next() orelse return error.Malformed;
    const version = parts.next() orelse return error.Malformed;
    if (parts.next() != null) return error.Malformed;
    if (method_text.len == 0 or target.len == 0 or target[0] != '/') return error.Malformed;
    if (!std.mem.eql(u8, version, "HTTP/1.1") and !std.mem.eql(u8, version, "HTTP/1.0")) return error.Unsupported;
    const method: Method = if (std.mem.eql(u8, method_text, "GET")) .GET else if (std.mem.eql(u8, method_text, "PUT")) .PUT else if (std.mem.eql(u8, method_text, "POST")) .POST else if (std.mem.eql(u8, method_text, "PATCH")) .PATCH else if (std.mem.eql(u8, method_text, "DELETE")) .DELETE else .other;
    const q = std.mem.indexOfScalar(u8, target, '?');
    var r = Request{
        .method = method,
        .path = if (q) |i| target[0..i] else target,
        .query = if (q) |i| target[i + 1 ..] else "",
        .head_len = end + 4,
    };
    var seen_length = false;
    while (lines.next()) |line| {
        if (line.len == 0) return error.Malformed;
        if (line[0] == ' ' or line[0] == '\t') return error.Malformed; // obsolete folding
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.Malformed;
        const name = line[0..colon];
        const value = trim(line[colon + 1 ..]);
        if (name.len == 0) return error.Malformed;
        if (eqlIgnoreCase(name, "content-length")) {
            if (seen_length) return error.Malformed;
            seen_length = true;
            if (value.len == 0 or value.len > 8) return error.Malformed;
            r.content_length = std.fmt.parseInt(usize, value, 10) catch return error.Malformed;
        } else if (eqlIgnoreCase(name, "host")) {
            r.host = value;
        } else if (eqlIgnoreCase(name, "content-type")) {
            r.content_type = value;
        } else if (eqlIgnoreCase(name, "authorization")) {
            r.authorization = value;
        } else if (eqlIgnoreCase(name, "origin")) {
            r.origin = value;
        } else if (eqlIgnoreCase(name, "transfer-encoding") or eqlIgnoreCase(name, "content-encoding") or eqlIgnoreCase(name, "expect")) {
            return error.Unsupported;
        }
    }
    return r;
}

pub fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

/// a complete response into `out`; the body is copied. returns the bytes to send.
pub fn writeResponse(out: []u8, status: u16, content_type: []const u8, body: []const u8) []u8 {
    const head = std.fmt.bufPrint(out, "HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\ncache-control: no-store\r\n\r\n", .{ status, reason(status), content_type, body.len }) catch return out[0..0];
    const n = @min(body.len, out.len - head.len);
    @memcpy(out[head.len .. head.len + n], body[0..n]);
    return out[0 .. head.len + n];
}

/// the json error body: stable lowercase code, readable message, request id; no secrets.
pub fn errorBody(out: []u8, code: []const u8, message: []const u8, request_id: u64) []u8 {
    return std.fmt.bufPrint(out, "{{\"error\":\"{s}\",\"message\":\"{s}\",\"request_id\":\"{x:0>16}\"}}", .{ code, message, request_id }) catch out[0..0];
}
