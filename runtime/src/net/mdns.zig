//! a multicast-dns responder, small enough to answer for one service and nothing else.
//!
//! **why this exists.** one clock on a lan needs no discovery. two make "the device" ambiguous,
//! and every tool here grew up assuming there was only one -- so they pick the first transport
//! that answers and talk to whichever clock that is. an mdns name is the fix that does not need
//! the tools to agree on anything: `tc002-9e85.local` resolves on macos with nothing installed,
//! and `_tc002._tcp` is browsable with `dns-sd -B`.
//!
//! **what it answers**, and nothing else:
//!
//!   PTR  `_services._dns-sd._udp.local` -> `_tc002._tcp.local`   (service-type enumeration)
//!   PTR  `_tc002._tcp.local`            -> `<instance>._tc002._tcp.local`
//!   SRV  `<instance>._tc002._tcp.local` -> 0 0 <port> `<instance>.local`
//!   TXT  `<instance>._tc002._tcp.local`
//!   A    `<instance>.local`             -> the device's address
//!
//! **deliberate simplifications**, each one a thing a full responder does that this does not:
//!
//!   - *no name compression.* rfc 1035 pointers are optional for a sender; every name here is
//!     written out in full. the largest packet this builds is still well under one mtu, and the
//!     parser does understand pointers, because queries arrive compressed.
//!   - *responses always go to the multicast group*, never unicast. the QU bit (rfc 6762 s5.4)
//!     is ignored, which costs a little lan traffic and removes a whole branch.
//!   - *no probing or conflict detection* (rfc 6762 s8). the instance name carries the last four
//!     hex digits of the device's own mac, so two clocks on one lan do not collide by
//!     construction. this is the simplification to revisit first if that assumption ever breaks.
//!   - *no known-answer suppression* and no response delay: a query that matches is answered.
//!
//! the module is pure -- bytes in, bytes out -- so all of it is exercised on the host. the socket
//! that carries it lives in netd.

const std = @import("std");

pub const mcast_addr: [4]u8 = .{ 224, 0, 0, 251 };
pub const mcast_port: u16 = 5353;

/// rfc 6762 s10: two minutes for the records that point at one host, so a clock that moves or
/// goes away stops being advertised quickly. the shared PTR gets the long ttl it conventionally has.
const ttl_host: u32 = 120;
const ttl_ptr: u32 = 4500;

const TYPE_A: u16 = 1;
const TYPE_PTR: u16 = 12;
const TYPE_TXT: u16 = 16;
const TYPE_SRV: u16 = 33;
const TYPE_ANY: u16 = 255;

const CLASS_IN: u16 = 1;
/// rfc 6762 s10.2: set on records this host is the unique owner of, telling peers to drop what
/// they had cached for that name. not set on the shared PTR, which several hosts may answer.
const CLASS_FLUSH: u16 = 0x8000;

const max_labels = 8;
const max_label_len = 63;

pub const Name = struct {
    parts: [max_labels][]const u8 = undefined,
    n: usize = 0,

    pub fn eql(self: Name, other: []const []const u8) bool {
        if (self.n != other.len) return false;
        for (self.parts[0..self.n], other) |a, b| {
            if (!std.ascii.eqlIgnoreCase(a, b)) return false;
        }
        return true;
    }
};

/// decode a name at `start`, following compression pointers. returns the offset just past the
/// name *as it appeared in the question* (a pointer is two bytes however far it reaches), or null
/// on anything malformed. the pointer budget is what stops a crafted packet looping forever.
pub fn parseName(buf: []const u8, start: usize, out: *Name) ?usize {
    var off = start;
    var after: ?usize = null;
    var hops: usize = 0;
    out.n = 0;
    while (true) {
        if (off >= buf.len) return null;
        const len = buf[off];
        if (len == 0) {
            off += 1;
            return after orelse off;
        }
        if (len & 0xc0 == 0xc0) {
            if (off + 1 >= buf.len) return null;
            hops += 1;
            if (hops > 8) return null;
            const target = (@as(usize, len & 0x3f) << 8) | buf[off + 1];
            if (after == null) after = off + 2;
            if (target >= buf.len or target >= off) return null; // pointers must go backwards
            off = target;
            continue;
        }
        if (len > max_label_len) return null;
        if (off + 1 + len > buf.len) return null;
        if (out.n >= max_labels) return null;
        out.parts[out.n] = buf[off + 1 ..][0..len];
        out.n += 1;
        off += 1 + len;
    }
}

const Writer = struct {
    buf: []u8,
    at: usize = 0,
    overflow: bool = false,

    fn u8v(self: *Writer, v: u8) void {
        if (self.at + 1 > self.buf.len) {
            self.overflow = true;
            return;
        }
        self.buf[self.at] = v;
        self.at += 1;
    }
    fn u16v(self: *Writer, v: u16) void {
        if (self.at + 2 > self.buf.len) {
            self.overflow = true;
            return;
        }
        std.mem.writeInt(u16, self.buf[self.at..][0..2], v, .big);
        self.at += 2;
    }
    fn u32v(self: *Writer, v: u32) void {
        if (self.at + 4 > self.buf.len) {
            self.overflow = true;
            return;
        }
        std.mem.writeInt(u32, self.buf[self.at..][0..4], v, .big);
        self.at += 4;
    }
    fn bytes(self: *Writer, b: []const u8) void {
        if (self.at + b.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.at..][0..b.len], b);
        self.at += b.len;
    }
    fn name(self: *Writer, parts: []const []const u8) void {
        for (parts) |p| {
            if (p.len == 0 or p.len > max_label_len) {
                self.overflow = true;
                return;
            }
            self.u8v(@intCast(p.len));
            self.bytes(p);
        }
        self.u8v(0);
    }
};

pub const Responder = struct {
    /// the dns-sd instance name and the host label both: `tc002-9e85` gives `tc002-9e85.local`
    /// and `tc002-9e85._tc002._tcp.local`.
    instance: []const u8,
    ip: [4]u8,
    port: u16 = 80,

    fn serviceName(_: Responder) [3][]const u8 {
        return .{ "_tc002", "_tcp", "local" };
    }
    fn instanceName(self: Responder) [4][]const u8 {
        return .{ self.instance, "_tc002", "_tcp", "local" };
    }
    fn hostName(self: Responder) [2][]const u8 {
        return .{ self.instance, "local" };
    }
    fn metaName(_: Responder) [4][]const u8 {
        return .{ "_services", "_dns-sd", "_udp", "local" };
    }

    fn putPtr(self: Responder, w: *Writer, from: []const []const u8, to: []const []const u8, ttl: u32) void {
        _ = self;
        w.name(from);
        w.u16v(TYPE_PTR);
        w.u16v(CLASS_IN); // shared record: no cache-flush
        w.u32v(ttl);
        const len_at = w.at;
        w.u16v(0);
        const start = w.at;
        w.name(to);
        if (!w.overflow) std.mem.writeInt(u16, w.buf[len_at..][0..2], @intCast(w.at - start), .big);
    }

    fn putSrv(self: Responder, w: *Writer) void {
        const inst = self.instanceName();
        w.name(&inst);
        w.u16v(TYPE_SRV);
        w.u16v(CLASS_IN | CLASS_FLUSH);
        w.u32v(ttl_host);
        const len_at = w.at;
        w.u16v(0);
        const start = w.at;
        w.u16v(0); // priority
        w.u16v(0); // weight
        w.u16v(self.port);
        const host = self.hostName();
        w.name(&host);
        if (!w.overflow) std.mem.writeInt(u16, w.buf[len_at..][0..2], @intCast(w.at - start), .big);
    }

    fn putTxt(self: Responder, w: *Writer) void {
        const inst = self.instanceName();
        w.name(&inst);
        w.u16v(TYPE_TXT);
        w.u16v(CLASS_IN | CLASS_FLUSH);
        w.u32v(ttl_host);
        // one zero-length string, which is the dns-sd way of saying "no keys" -- an empty rdata
        // is not legal for TXT and some resolvers drop the record instead of the service.
        w.u16v(1);
        w.u8v(0);
    }

    fn putA(self: Responder, w: *Writer) void {
        const host = self.hostName();
        w.name(&host);
        w.u16v(TYPE_A);
        w.u16v(CLASS_IN | CLASS_FLUSH);
        w.u32v(ttl_host);
        w.u16v(4);
        w.bytes(&self.ip);
    }

    /// the unsolicited announcement, sent on startup and whenever the address changes. it is the
    /// same packet a full PTR query would get back.
    pub fn announce(self: Responder, out: []u8) ?usize {
        var w = Writer{ .buf = out };
        w.u16v(0); // id: always 0 in mdns
        w.u16v(0x8400); // response, authoritative
        w.u16v(0); // qdcount
        w.u16v(4); // ancount: ptr, srv, txt, a
        w.u16v(0);
        w.u16v(0);
        const svc = self.serviceName();
        const inst = self.instanceName();
        self.putPtr(&w, &svc, &inst, ttl_ptr);
        self.putSrv(&w);
        self.putTxt(&w);
        self.putA(&w);
        if (w.overflow) return null;
        return w.at;
    }

    /// answer a query, or null when it asks for nothing we own. `out` must be big enough for the
    /// full answer set; 512 bytes is comfortable for the names this builds.
    pub fn respond(self: Responder, query: []const u8, out: []u8) ?usize {
        if (query.len < 12) return null;
        const flags = std.mem.readInt(u16, query[2..4], .big);
        if (flags & 0x8000 != 0) return null; // a response, not a query
        if (flags & 0x7800 != 0) return null; // not a standard query
        const qd = std.mem.readInt(u16, query[4..6], .big);
        if (qd == 0) return null;

        const svc = self.serviceName();
        const inst = self.instanceName();
        const host = self.hostName();
        const meta = self.metaName();

        var want_meta = false;
        var want_ptr = false;
        var want_srv = false;
        var want_txt = false;
        var want_a = false;

        var off: usize = 12;
        var i: usize = 0;
        while (i < qd) : (i += 1) {
            var name: Name = .{};
            const next = parseName(query, off, &name) orelse return null;
            if (next + 4 > query.len) return null;
            const qtype = std.mem.readInt(u16, query[next..][0..2], .big);
            const qclass = std.mem.readInt(u16, query[next + 2 ..][0..2], .big);
            off = next + 4;
            // the top class bit is the unicast-response request, not part of the class
            if (qclass & 0x7fff != CLASS_IN and qclass & 0x7fff != 255) continue;

            if (name.eql(&meta) and (qtype == TYPE_PTR or qtype == TYPE_ANY)) want_meta = true;
            if (name.eql(&svc) and (qtype == TYPE_PTR or qtype == TYPE_ANY)) want_ptr = true;
            if (name.eql(&inst)) {
                if (qtype == TYPE_SRV or qtype == TYPE_ANY) want_srv = true;
                if (qtype == TYPE_TXT or qtype == TYPE_ANY) want_txt = true;
            }
            if (name.eql(&host) and (qtype == TYPE_A or qtype == TYPE_ANY)) want_a = true;
        }

        if (!(want_meta or want_ptr or want_srv or want_txt or want_a)) return null;

        // a PTR answer carries the rest as additionals, so one exchange resolves the service
        if (want_ptr) {
            want_srv = true;
            want_txt = true;
            want_a = true;
        }
        if (want_srv) want_a = true;

        var count: u16 = 0;
        if (want_meta) count += 1;
        if (want_ptr) count += 1;
        if (want_srv) count += 1;
        if (want_txt) count += 1;
        if (want_a) count += 1;

        var w = Writer{ .buf = out };
        w.u16v(0);
        w.u16v(0x8400);
        w.u16v(0);
        w.u16v(count);
        w.u16v(0);
        w.u16v(0);
        if (want_meta) self.putPtr(&w, &meta, &svc, ttl_ptr);
        if (want_ptr) self.putPtr(&w, &svc, &inst, ttl_ptr);
        if (want_srv) self.putSrv(&w);
        if (want_txt) self.putTxt(&w);
        if (want_a) self.putA(&w);
        if (w.overflow) return null;
        return w.at;
    }
};

/// the same, from the six raw bytes the supervisor reports in its status snapshot.
pub fn instanceFromMacBytes(mac: [6]u8, out: *[16]u8) []const u8 {
    const hex = "0123456789abcdef";
    const prefix = "tc002-";
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len + 0] = hex[mac[4] >> 4];
    out[prefix.len + 1] = hex[mac[4] & 0xf];
    out[prefix.len + 2] = hex[mac[5] >> 4];
    out[prefix.len + 3] = hex[mac[5] & 0xf];
    return out[0 .. prefix.len + 4];
}

/// `tc002-9e85` from `cc:c4:b2:77:9e:85`. the last four hex digits are what the vendor's own mqtt
/// prefix uses, so the name matches what the device is already called elsewhere.
pub fn instanceFromMac(mac: []const u8, out: *[16]u8) []const u8 {
    var hex: [12]u8 = undefined;
    var n: usize = 0;
    for (mac) |c| {
        const v: ?u8 = switch (c) {
            '0'...'9' => c,
            'a'...'f' => c,
            'A'...'F' => c + 32,
            else => null,
        };
        if (v) |d| {
            if (n < hex.len) {
                hex[n] = d;
                n += 1;
            }
        }
    }
    const tail = if (n >= 4) hex[n - 4 .. n] else hex[0..n];
    const prefix = "tc002-";
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..tail.len], tail);
    return out[0 .. prefix.len + tail.len];
}

// ---------------------------------------------------------------------------- tests

const testing = std.testing;

fn mkQuery(buf: []u8, parts: []const []const u8, qtype: u16, qclass: u16) []const u8 {
    var w = Writer{ .buf = buf };
    w.u16v(0);
    w.u16v(0); // standard query
    w.u16v(1); // one question
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    w.name(parts);
    w.u16v(qtype);
    w.u16v(qclass);
    std.debug.assert(!w.overflow);
    return buf[0..w.at];
}

fn answerCount(pkt: []const u8) u16 {
    return std.mem.readInt(u16, pkt[6..8], .big);
}

/// walk every answer, returning the types seen. proves the records are actually parseable
/// rather than merely present, which is the failure a length field gets wrong.
fn answerTypes(pkt: []const u8, out: *[8]u16) usize {
    var off: usize = 12;
    var seen: usize = 0;
    var i: usize = 0;
    const n = answerCount(pkt);
    while (i < n) : (i += 1) {
        var name: Name = .{};
        off = parseName(pkt, off, &name) orelse return seen;
        const t = std.mem.readInt(u16, pkt[off..][0..2], .big);
        const rdlen = std.mem.readInt(u16, pkt[off + 8 ..][0..2], .big);
        off += 10 + rdlen;
        if (seen < out.len) {
            out[seen] = t;
            seen += 1;
        }
    }
    std.debug.assert(off == pkt.len); // every byte accounted for
    return seen;
}

test "an instance name is the last four hex digits of the mac" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("tc002-9e85", instanceFromMac("cc:c4:b2:77:9e:85", &buf));
    try testing.expectEqualStrings("tc002-a282", instanceFromMac("CC:C4:B2:77:A2:82", &buf));
    try testing.expectEqualStrings("tc002-9e85", instanceFromMac("ccc4b2779e85", &buf));
}

test "an instance name from the raw mac bytes agrees with the text form" {
    var a: [16]u8 = undefined;
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings(
        instanceFromMac("cc:c4:b2:77:9e:85", &a),
        instanceFromMacBytes(.{ 0xcc, 0xc4, 0xb2, 0x77, 0x9e, 0x85 }, &b),
    );
    try testing.expectEqualStrings("tc002-0001", instanceFromMacBytes(.{ 0, 0, 0, 0, 0x00, 0x01 }, &b));
}

test "the announcement carries ptr, srv, txt and a, and every record parses" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var out: [512]u8 = undefined;
    const n = r.announce(&out).?;
    const pkt = out[0..n];
    try testing.expectEqual(@as(u16, 0x8400), std.mem.readInt(u16, pkt[2..4], .big));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, pkt[4..6], .big));
    try testing.expectEqual(@as(u16, 4), answerCount(pkt));
    var types: [8]u16 = undefined;
    const seen = answerTypes(pkt, &types);
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expectEqualSlices(u16, &.{ TYPE_PTR, TYPE_SRV, TYPE_TXT, TYPE_A }, types[0..4]);
}

test "a browse for the service is answered with everything needed to resolve it" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "_tc002", "_tcp", "local" }, TYPE_PTR, CLASS_IN);
    var out: [512]u8 = undefined;
    const n = r.respond(q, &out).?;
    var types: [8]u16 = undefined;
    const seen = answerTypes(out[0..n], &types);
    // one exchange has to be enough: ptr alone would force three more round trips
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expectEqualSlices(u16, &.{ TYPE_PTR, TYPE_SRV, TYPE_TXT, TYPE_A }, types[0..4]);
}

test "an address query for the host name is answered with just the address" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "tc002-9e85", "local" }, TYPE_A, CLASS_IN);
    var out: [512]u8 = undefined;
    const n = r.respond(q, &out).?;
    var types: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), answerTypes(out[0..n], &types));
    try testing.expectEqual(TYPE_A, types[0]);
    // the address is the last four bytes of the packet
    try testing.expectEqualSlices(u8, &.{ 10, 0, 0, 68 }, out[n - 4 .. n]);
}

test "names match without regard to case, because dns does not care" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "TC002-9E85", "LOCAL" }, TYPE_A, CLASS_IN);
    var out: [512]u8 = undefined;
    try testing.expect(r.respond(q, &out) != null);
}

test "the service-type enumeration browsers use is answered" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "_services", "_dns-sd", "_udp", "local" }, TYPE_PTR, CLASS_IN);
    var out: [512]u8 = undefined;
    const n = r.respond(q, &out).?;
    var types: [8]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), answerTypes(out[0..n], &types));
    try testing.expectEqual(TYPE_PTR, types[0]);
}

test "questions for other names and other hosts are ignored" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var qbuf: [128]u8 = undefined;
    var out: [512]u8 = undefined;
    // another clock's name: the whole point of the scheme
    try testing.expect(r.respond(mkQuery(&qbuf, &.{ "tc002-a282", "local" }, TYPE_A, CLASS_IN), &out) == null);
    try testing.expect(r.respond(mkQuery(&qbuf, &.{ "_printer", "_tcp", "local" }, TYPE_PTR, CLASS_IN), &out) == null);
    // right name, wrong record type
    try testing.expect(r.respond(mkQuery(&qbuf, &.{ "tc002-9e85", "local" }, TYPE_SRV, CLASS_IN), &out) == null);
}

test "a response is never answered, or two responders would talk forever" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var out: [512]u8 = undefined;
    var ann: [512]u8 = undefined;
    const n = r.announce(&ann).?;
    try testing.expect(r.respond(ann[0..n], &out) == null);
}

test "a truncated or malformed query is rejected rather than trusted" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var out: [512]u8 = undefined;
    try testing.expect(r.respond(&.{}, &out) == null);
    try testing.expect(r.respond(&.{ 0, 0, 0, 0 }, &out) == null);
    // claims one question and supplies none
    const hdr = [_]u8{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
    try testing.expect(r.respond(&hdr, &out) == null);
    // a label that runs off the end of the packet
    const bad = [_]u8{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 40, 'a', 'b' };
    try testing.expect(r.respond(&bad, &out) == null);
}

test "compression pointers are followed, and only backwards" {
    // "local" at offset 12, then a name that points back at it
    var buf: [64]u8 = undefined;
    var w = Writer{ .buf = &buf };
    w.u16v(0);
    w.u16v(0);
    w.u16v(1);
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    const local_at = w.at;
    w.name(&.{"local"});
    const name_at = w.at;
    w.u8v(10);
    w.bytes("tc002-9e85");
    w.u8v(0xc0);
    w.u8v(@intCast(local_at));
    w.u16v(TYPE_A);
    w.u16v(CLASS_IN);

    var name: Name = .{};
    const next = parseName(buf[0..w.at], name_at, &name).?;
    try testing.expect(name.eql(&.{ "tc002-9e85", "local" }));
    try testing.expectEqual(name_at + 13, next);

    // a pointer that goes forward is a loop waiting to happen
    var fwd = [_]u8{ 0xc0, 0x04, 0, 0, 0 };
    var n2: Name = .{};
    try testing.expect(parseName(&fwd, 0, &n2) == null);
    // and one that points at itself
    var self_ptr = [_]u8{ 0xc0, 0x00 };
    try testing.expect(parseName(&self_ptr, 0, &n2) == null);
}

test "an output buffer too small returns null instead of a truncated packet" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 10, 0, 0, 68 } };
    var tiny: [24]u8 = undefined;
    try testing.expect(r.announce(&tiny) == null);
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "_tc002", "_tcp", "local" }, TYPE_PTR, CLASS_IN);
    try testing.expect(r.respond(q, &tiny) == null);
}
