//! the client side of one http/1.1 response over any `std.Io.Reader`: the status line and the
//! few headers that matter, then the body as a stream of lines, with chunked transfer encoding
//! unwrapped. pure; tested on fixed readers.
const std = @import("std");
const Reader = std.Io.Reader;

pub const Head = struct { status: u16, chunked: bool = false, content_length: ?u64 = null };

pub const Error = error{ BadResponse, ReadFailed, EndOfStream, StreamTooLong, LineTooLong };

fn takeLine(r: *Reader) Error![]const u8 {
    const raw = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
        error.StreamTooLong => return error.StreamTooLong,
    };
    return std.mem.trimEnd(u8, raw, "\r\n");
}

/// the status line and the headers, up to and including the blank line
pub fn readHead(r: *Reader) Error!Head {
    const status_line = try takeLine(r);
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.BadResponse;
    var it = std.mem.splitScalar(u8, status_line, ' ');
    _ = it.next();
    const code_text = it.next() orelse return error.BadResponse;
    var head = Head{ .status = std.fmt.parseInt(u16, code_text, 10) catch return error.BadResponse };
    var count: u32 = 0;
    while (true) {
        const line = try takeLine(r);
        if (line.len == 0) break;
        count += 1;
        if (count > 64) return error.BadResponse;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            head.chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            head.content_length = std.fmt.parseInt(u64, value, 10) catch return error.BadResponse;
        }
    }
    return head;
}

/// the body as lines: chunk framing is removed, a missing length means "until the stream ends".
pub const Body = struct {
    r: *Reader,
    chunked: bool,
    /// bytes left in the current chunk (chunked) or in the whole body (with a length)
    remaining: u64,
    bounded: bool,
    done: bool = false,
    first_chunk: bool = true,

    pub fn init(r: *Reader, head: Head) Body {
        return .{ .r = r, .chunked = head.chunked, .remaining = if (head.chunked) 0 else (head.content_length orelse 0), .bounded = !head.chunked and head.content_length != null };
    }

    fn nextByte(self: *Body) Error!?u8 {
        if (self.done) return null;
        if (self.chunked) {
            if (self.remaining == 0) {
                if (!self.first_chunk) _ = try takeLine(self.r); // the crlf after the previous chunk
                self.first_chunk = false;
                const size_line = try takeLine(self.r);
                const size_text = if (std.mem.indexOfScalar(u8, size_line, ';')) |i| size_line[0..i] else size_line;
                self.remaining = std.fmt.parseInt(u64, std.mem.trim(u8, size_text, " \t"), 16) catch return error.BadResponse;
                if (self.remaining == 0) {
                    // trailers up to the final blank line
                    while (true) {
                        const t = takeLine(self.r) catch break;
                        if (t.len == 0) break;
                    }
                    self.done = true;
                    return null;
                }
            }
        } else if (self.bounded) {
            if (self.remaining == 0) {
                self.done = true;
                return null;
            }
        }
        const b = self.r.takeByte() catch |e| switch (e) {
            error.EndOfStream => {
                self.done = true;
                return null;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        if (self.chunked or self.bounded) self.remaining -= 1;
        return b;
    }

    /// the next line without its newline, or null once the body has ended
    pub fn nextLine(self: *Body, buf: []u8) Error!?[]const u8 {
        var n: usize = 0;
        while (true) {
            const b = (try self.nextByte()) orelse {
                if (n == 0) return null;
                return buf[0..n];
            };
            if (b == '\n') return buf[0..n];
            if (b == '\r') continue;
            if (n == buf.len) return error.LineTooLong;
            buf[n] = b;
            n += 1;
        }
    }
};

test "a chunked json stream comes out as lines" {
    var r: Reader = .fixed("HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\"\r\n8\r\n:1}\n{\"b\"\r\n4;ext\r\n:2}\n\r\n0\r\n\r\n");
    const head = try readHead(&r);
    try std.testing.expectEqual(@as(u16, 200), head.status);
    try std.testing.expect(head.chunked);
    var body = Body.init(&r, head);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("{\"a\":1}", (try body.nextLine(&buf)).?);
    try std.testing.expectEqualStrings("{\"b\":2}", (try body.nextLine(&buf)).?);
    try std.testing.expect((try body.nextLine(&buf)) == null);
    try std.testing.expect((try body.nextLine(&buf)) == null);
}

test "a bounded body, an unbounded one and bad heads" {
    var r: Reader = .fixed("HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nnot here\nignored");
    const head = try readHead(&r);
    try std.testing.expectEqual(@as(u16, 404), head.status);
    try std.testing.expectEqual(@as(?u64, 9), head.content_length);
    var body = Body.init(&r, head);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("not here", (try body.nextLine(&buf)).?);
    try std.testing.expect((try body.nextLine(&buf)) == null);
    var r2: Reader = .fixed("HTTP/1.0 200 OK\r\n\r\nline one\nlast");
    const h2 = try readHead(&r2);
    var b2 = Body.init(&r2, h2);
    try std.testing.expectEqualStrings("line one", (try b2.nextLine(&buf)).?);
    try std.testing.expectEqualStrings("last", (try b2.nextLine(&buf)).?);
    try std.testing.expect((try b2.nextLine(&buf)) == null);
    var r3: Reader = .fixed("SMTP 220 hi\r\n\r\n");
    try std.testing.expectError(error.BadResponse, readHead(&r3));
    var r4: Reader = .fixed("HTTP/1.1 200 OK\r\n\r\n" ++ "x" ** 40 ++ "\n");
    const h4 = try readHead(&r4);
    var b4 = Body.init(&r4, h4);
    try std.testing.expectError(error.LineTooLong, b4.nextLine(&buf));
}
