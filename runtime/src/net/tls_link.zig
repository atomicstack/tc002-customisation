//! MQTT over TLS: the standard library's TLS client, sitting between netd's non-blocking broker
//! socket and its plaintext MQTT buffers.
//!
//! netd is a single epoll loop that must never wait on a socket, but `std.crypto.tls.Client` is
//! written for blocking `std.Io` streams. The two meet at the record boundary:
//!
//!   - The handshake is the only part that needs a back-and-forth, so it runs blocking, once per
//!     connection, with a send and receive timeout on the socket. On a LAN that's a few round trips
//!     and a signature check, and a broker that stalls costs at most `handshake_timeout_s`.
//!   - After that, every record states its own length in a five-byte header. netd reads ciphertext
//!     into `input` itself, without blocking, and only asks the client to decrypt once a whole
//!     record has arrived, so the client never touches the socket.
//!   - Writes are encrypted into `output`, a plain buffer, and netd sends them the same way it sends
//!     plaintext: as much as the socket will take, and the rest on the next writable event.
//!
//! The server is checked against one PEM CA (there are no built-in roots, because a LAN broker's
//! certificate is private) and against the address netd connected to, which the certificate must
//! include as an IP subjectAltName. The runtime has no DNS resolver, so there's no other name to
//! check.
const std = @import("std");
const sys = @import("../sys/linux.zig");
const tls = std.crypto.tls;
const Certificate = std.crypto.Certificate;
const linux = std.os.linux;

/// One whole TLS record: the most the client can ask for at once.
pub const record_len = tls.Client.min_buffer_len;
pub const handshake_timeout_s = 5;
/// Certificates have validity dates and this device has no RTC, so a chain can't be checked until
/// SNTP has set the clock. The handshake isn't attempted before this time (2025-01-01).
pub const earliest_valid_s: i64 = 1735689600;

pub const HandshakeError = error{ ClockNotSet, NoCa, BadCa, Timeout, Certificate, Handshake };
pub const ReadError = error{ WouldBlock, Closed, Tls, Io };
pub const WriteError = error{ WouldBlock, Tls, Io };

pub fn handshakeErrorText(e: HandshakeError) []const u8 {
    return switch (e) {
        error.ClockNotSet => "tls waits for the clock to be set",
        error.NoCa => "tls needs a ca certificate",
        error.BadCa => "the ca certificate does not parse",
        error.Timeout => "tls handshake timed out",
        error.Certificate => "certificate rejected",
        error.Handshake => "tls handshake failed",
    };
}

/// The length of the first whole record in `buf`, or null if it hasn't all arrived yet. A header
/// claiming more than the protocol allows is returned as is, and the client then rejects it.
pub fn completeRecord(buf: []const u8) ?usize {
    if (buf.len < tls.record_header_len) return null;
    const len = tls.record_header_len + @as(usize, std.mem.readInt(u16, buf[3..5], .big));
    return if (buf.len >= len) len else null;
}

/// Appends the DER certificates from a PEM text to `bundle` and returns how many there were.
/// Anything outside the BEGIN/END CERTIFICATE markers is ignored.
pub fn addPem(bundle: *Certificate.Bundle, gpa: std.mem.Allocator, pem: []const u8, now_sec: i64, scratch: []u8) !usize {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    var rest = pem;
    var added: usize = 0;
    while (std.mem.indexOf(u8, rest, begin)) |start| {
        const body_start = start + begin.len;
        const end = std.mem.indexOf(u8, rest[body_start..], end_marker) orelse return error.BadPem;
        var compact_len: usize = 0;
        for (rest[body_start .. body_start + end]) |ch| if (!std.ascii.isWhitespace(ch)) {
            if (compact_len == scratch.len) return error.BadPem;
            scratch[compact_len] = ch;
            compact_len += 1;
        };
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(scratch[0..compact_len]);
        const at: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.resize(gpa, bundle.bytes.items.len + decoded_len);
        try std.base64.standard.Decoder.decode(bundle.bytes.items[at..], scratch[0..compact_len]);
        try bundle.parseCert(gpa, at, now_sec);
        added += 1;
        rest = rest[body_start + end + end_marker.len ..];
    }
    return added;
}

/// The state of one TLS connection. It's about 70 KB, so netd keeps exactly one, statically.
pub const Link = struct {
    fd: sys.Fd = -1,
    active: bool = false,
    timed_out: bool = false,
    /// The name of the last error the client reported, for the log.
    last_error: []const u8 = "",
    in_buf: [record_len]u8 = undefined,
    out_buf: [record_len]u8 = undefined,
    clear_in: [record_len]u8 = undefined,
    clear_out: [record_len]u8 = undefined,
    /// The CA bundle's allocations, rebuilt for every handshake.
    heap: [24 * 1024]u8 = undefined,
    der: [4096]u8 = undefined,
    input: std.Io.Reader = undefined,
    output: std.Io.Writer = undefined,
    /// How much of `output.buffered()` the socket has taken so far.
    sent: usize = 0,
    client: tls.Client = undefined,

    const reader_vtable: std.Io.Reader.VTable = .{ .stream = socketStream, .readVec = socketReadVec };
    const writer_vtable: std.Io.Writer.VTable = .{ .drain = socketDrain };

    /// Runs the handshake on a connected non-blocking socket. It blocks for at most
    /// `handshake_timeout_s` per read or write, and leaves the socket non-blocking again.
    pub fn handshake(self: *Link, fd: sys.Fd, ca_pem: []const u8, host: []const u8) HandshakeError!void {
        self.reset();
        if (ca_pem.len == 0) return error.NoCa;
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        const io = threaded.io();
        const now = std.Io.Timestamp.now(io, .real);
        const now_sec: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s));
        if (now_sec < earliest_valid_s) return error.ClockNotSet;

        var fba = std.heap.FixedBufferAllocator.init(&self.heap);
        const gpa = fba.allocator();
        var bundle: Certificate.Bundle = .empty;
        const added = addPem(&bundle, gpa, ca_pem, now_sec, &self.der) catch |e| {
            self.last_error = @errorName(e);
            return error.BadCa;
        };
        if (added == 0) return error.BadCa;

        self.fd = fd;
        self.input = .{ .vtable = &reader_vtable, .buffer = &self.in_buf, .seek = 0, .end = 0 };
        self.output = .{ .vtable = &writer_vtable, .buffer = &self.out_buf, .end = 0 };
        setBlocking(fd, true);
        defer setBlocking(fd, false);

        var lock: std.Io.RwLock = .init;
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        sys.getrandom(&entropy) catch return error.Handshake;
        self.client = tls.Client.init(&self.input, &self.output, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } },
            .write_buffer = &self.clear_out,
            .read_buffer = &self.clear_in,
            .entropy = &entropy,
            .realtime_now = now,
        }) catch |e| {
            self.last_error = @errorName(e);
            if (self.timed_out) return error.Timeout;
            return if (std.mem.indexOf(u8, @errorName(e), "Certificate") != null or e == error.TlsAlert) error.Certificate else error.Handshake;
        };
        // The client flushes its own handshake records, so anything still buffered has been sent.
        self.output.end = 0;
        self.sent = 0;
        self.active = true;
    }

    pub fn reset(self: *Link) void {
        self.active = false;
        self.timed_out = false;
        self.last_error = "";
        self.fd = -1;
        self.sent = 0;
    }

    /// Reads plaintext from the broker into `dst`: whatever the client has already decrypted,
    /// otherwise the next whole record, otherwise whatever the socket has. Returns
    /// error.WouldBlock once there's nothing more.
    pub fn read(self: *Link, dst: []u8) ReadError!usize {
        std.debug.assert(self.active and dst.len > 0);
        while (true) {
            const clear = self.client.reader.buffered();
            if (clear.len > 0) {
                const n = @min(clear.len, dst.len);
                @memcpy(dst[0..n], clear[0..n]);
                self.client.reader.toss(n);
                return n;
            }
            if (self.client.eof()) return error.Closed;
            if (completeRecord(self.input.buffered()) != null) {
                // One record. Application data lands in the reader's buffer; a post-handshake
                // message (a session ticket or a key update) is consumed and leaves nothing.
                self.client.reader.fillMore() catch |e| switch (e) {
                    error.EndOfStream => return error.Closed,
                    error.ReadFailed => {
                        if (self.client.read_err) |re| self.last_error = @errorName(re);
                        return error.Tls;
                    },
                };
                continue;
            }
            // Move the partial record to the front of the buffer, then read more of it.
            if (self.input.seek > 0) {
                const partial = self.input.buffered();
                std.mem.copyForwards(u8, self.input.buffer[0..partial.len], partial);
                self.input.seek = 0;
                self.input.end = partial.len;
            }
            const n = sys.read(self.fd, self.input.buffer[self.input.end..]) catch |e| switch (e) {
                error.WouldBlock => return error.WouldBlock,
                error.Interrupted => continue,
                else => return error.Io,
            };
            if (n == 0) return error.Closed;
            self.input.end += n;
        }
    }

    /// True while ciphertext is waiting for the socket. `encrypt` mustn't be called until it's sent.
    pub fn pending(self: *const Link) bool {
        return self.sent < self.output.end;
    }

    /// Encrypts the start of `plain` into one record and returns how much of it was used.
    pub fn encrypt(self: *Link, plain: []const u8) WriteError!usize {
        std.debug.assert(self.active and !self.pending());
        self.output.end = 0;
        self.sent = 0;
        const n = @min(plain.len, tls.max_ciphertext_inner_record_len - 256);
        // Both buffers are empty and each holds a whole record, so neither write reaches a vtable.
        self.client.writer.writeAll(plain[0..n]) catch return error.Tls;
        self.client.writer.flush() catch return error.Tls;
        return n;
    }

    /// Sends as much of the pending ciphertext as the socket will take.
    pub fn send(self: *Link) WriteError!void {
        while (self.pending()) {
            const n = sys.write(self.fd, self.output.buffer[self.sent..self.output.end]) catch |e| switch (e) {
                error.WouldBlock => return error.WouldBlock,
                error.Interrupted => continue,
                else => return error.Io,
            };
            self.sent += n;
        }
        self.output.end = 0;
        self.sent = 0;
    }

    // The socket as the client sees it during the handshake: blocking, with a timeout. After the
    // handshake these are only a backstop (`read` hands the client whole records and `encrypt`
    // leaves room), and on a non-blocking socket they fail rather than wait.
    fn socketReadVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        const self: *Link = @alignCast(@fieldParentPtr("input", r));
        if (r.seek > 0) {
            const kept = r.buffer[r.seek..r.end];
            std.mem.copyForwards(u8, r.buffer[0..kept.len], kept);
            r.end = kept.len;
            r.seek = 0;
        }
        if (r.end == r.buffer.len) return error.ReadFailed;
        while (true) {
            const n = sys.read(self.fd, r.buffer[r.end..]) catch |e| switch (e) {
                error.Interrupted => continue,
                error.WouldBlock => {
                    self.timed_out = true;
                    return error.ReadFailed;
                },
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            r.end += n;
            return 0;
        }
    }

    fn socketStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        var none: [1][]u8 = .{""};
        return socketReadVec(r, &none);
    }

    fn socketDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Link = @alignCast(@fieldParentPtr("output", w));
        try self.writeAllBlocking(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.writeAllBlocking(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.writeAllBlocking(last);
            n += last.len;
        }
        return n;
    }

    fn writeAllBlocking(self: *Link, bytes: []const u8) std.Io.Writer.Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            off += sys.write(self.fd, bytes[off..]) catch |e| switch (e) {
                error.Interrupted => continue,
                error.WouldBlock => {
                    self.timed_out = true;
                    return error.WriteFailed;
                },
                else => return error.WriteFailed,
            };
        }
    }
};

fn setBlocking(fd: sys.Fd, on: bool) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = linux.fcntl(fd, linux.F.SETFL, if (on) flags & ~nonblock else flags | nonblock);
    const tv = linux.timeval{ .sec = if (on) handshake_timeout_s else 0, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
}

test "A record is only whole once the length in its header has arrived" {
    try std.testing.expectEqual(@as(?usize, null), completeRecord(""));
    try std.testing.expectEqual(@as(?usize, null), completeRecord(&.{ 0x17, 0x03, 0x03, 0x00 }));
    try std.testing.expectEqual(@as(?usize, null), completeRecord(&.{ 0x17, 0x03, 0x03, 0x00, 0x03, 0xaa, 0xbb }));
    try std.testing.expectEqual(@as(?usize, 8), completeRecord(&.{ 0x17, 0x03, 0x03, 0x00, 0x03, 0xaa, 0xbb, 0xcc }));
    // A second record behind the first doesn't change the first one's length.
    try std.testing.expectEqual(@as(?usize, 5), completeRecord(&.{ 0x14, 0x03, 0x03, 0x00, 0x00, 0x17, 0x03 }));
}

// A throwaway self-signed P-256 certificate made for this test, valid 2026-10-24 to 2036-10-21.
const test_ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBmDCCAT2gAwIBAgIUdyU0imFcpsHbHHQYxwuU68AVwqowCgYIKoZIzj0EAwIw
    \\ITEfMB0GA1UEAwwWdGMwMDIgdGxzX2xpbmsgdGVzdCBjYTAeFw0yNjEwMjQxMjIz
    \\NTVaFw0zNjEwMjExMjIzNTVaMCExHzAdBgNVBAMMFnRjMDAyIHRsc19saW5rIHRl
    \\c3QgY2EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATppLWQiSktMLjvOd+Xn4Xb
    \\DYh7vnsvPrXrX0V0jXd393aKRgJ4Um4P9HL2qXsPN8OYhYivnZhhlK6SqHocYoFP
    \\o1MwUTAdBgNVHQ4EFgQUqR5p2i0fR08RwAtSeUyax0QpVmAwHwYDVR0jBBgwFoAU
    \\qR5p2i0fR08RwAtSeUyax0QpVmAwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQD
    \\AgNJADBGAiEAq7UWj0gD3ay+5d5kMh2uR/4AsWrJMJS99GRBnQkJsO8CIQC9+mx5
    \\/An6VWs0NpJev4pjVE4xiJiqN3gQ1NPJpekaVA==
    \\-----END CERTIFICATE-----
;

test "A PEM CA ends up in the bundle, and text that isn't one is rejected" {
    var heap: [24 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const gpa = fba.allocator();
    var scratch: [4096]u8 = undefined;
    var bundle: Certificate.Bundle = .empty;
    const now_s: i64 = 1795000000; // 2026-11-18, within the test certificate's validity
    try std.testing.expectEqual(@as(usize, 1), try addPem(&bundle, gpa, "some text first\n" ++ test_ca_pem ++ "\n", now_s, &scratch));
    try std.testing.expectEqual(@as(usize, 0), try addPem(&bundle, gpa, "no certificate here", now_s, &scratch));
    try std.testing.expectError(error.BadPem, addPem(&bundle, gpa, "-----BEGIN CERTIFICATE-----\nAAAA", now_s, &scratch));
}
