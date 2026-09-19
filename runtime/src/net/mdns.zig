//! bounded multicast-dns packets for one tc002 service.
//!
//! names use the full wlan mac: `tc002-ccc4b2779e85.local`. the owner module
//! probes unique host/service names, resolves conflicts, and schedules announcements.
//! this module handles pure packet parsing, formatting and proposal comparisons.
//!
//! answers: service enumeration ptr, `_tc002._tcp.local` ptr, instance srv/txt,
//! and host a. names are sent uncompressed; incoming compression is bounded.
//! legacy one-shot queries receive unicast replies with their id and questions.
//! queries from port 5353 receive multicast replies, including qu requests.
//! known-answer suppression and multicast response delays are not implemented.

const std = @import("std");

pub const mcast_addr: [4]u8 = .{ 224, 0, 0, 251 };
pub const mcast_port: u16 = 5353;
pub const name_capacity = 32;
pub const Reply = struct { len: usize, addr: [4]u8, port: u16 };
pub const Conflict = enum { none, answer, probe_lost };

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
    legacy: bool = false,
    flush: bool = true,

    fn uniqueClass(self: Writer) u16 {
        return if (self.legacy or !self.flush) CLASS_IN else CLASS_IN | CLASS_FLUSH;
    }
    fn ttl(self: *Writer, seconds: u32) void {
        self.u32v(if (self.legacy) @min(seconds, 10) else seconds);
    }

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
    /// the instance and host share one label, optionally suffixed after a conflict.
    instance: []const u8,
    ip: [4]u8,
    port: u16 = 80,

    /// claim both unique names with all proposed records in the authority section.
    pub fn probe(self: Responder, out: []u8) ?usize {
        var w = Writer{ .buf = out, .flush = false };
        w.u16v(0);
        w.u16v(0);
        w.u16v(2);
        w.u16v(0);
        w.u16v(3);
        w.u16v(0);
        const host = self.hostName();
        const inst = self.instanceName();
        for ([_][]const []const u8{ &host, &inst }) |parts| {
            w.name(parts);
            w.u16v(TYPE_ANY);
            w.u16v(CLASS_IN | 0x8000);
        }
        self.putA(&w);
        self.putTxt(&w);
        self.putSrv(&w);
        return if (w.overflow) null else w.at;
    }

    /// only complete, well-formed packets may alter ownership. query answers are
    /// known answers, not claims; simultaneous proposals live in the authority section.
    pub fn conflict(self: Responder, packet: []const u8, probing: bool) Conflict {
        if (packet.len < 12) return .none;
        const flags = std.mem.readInt(u16, packet[2..4], .big);
        if (flags & 0x7a0f != 0) return .none;
        const response = flags & 0x8000 != 0;
        if (!response and !probing) return .none;
        var remote: Claims = .{};
        if (!remote.read(self, packet, !response, response)) return .none;
        var own_buf: [512]u8 = undefined;
        const n = self.announce(&own_buf) orelse return .none;
        var own: Claims = .{};
        if (!own.read(self, own_buf[0..n], false, response)) return .none;
        for ([_]usize{ 0, 1 }) |group| {
            const theirs = remote.sets[group].items[0..remote.sets[group].len];
            const ours = own.sets[group].items[0..own.sets[group].len];
            if (theirs.len == 0) continue;
            if (response) {
                // a response can contain only a subset of an rrset. each received
                // record must agree with one of ours; missing records are harmless.
                for (theirs) |key| {
                    var same = false;
                    var owned_type = false;
                    for (ours) |our_key| {
                        if (std.mem.eql(u8, key.bytes()[0..4], our_key.bytes()[0..4])) owned_type = true;
                        if (std.mem.eql(u8, key.bytes(), our_key.bytes())) same = true;
                    }
                    if (!same and (probing or owned_type)) return .answer;
                }
            } else {
                // rfc 6762 section 8.2: compare the sorted complete proposals.
                var i: usize = 0;
                while (i < @min(theirs.len, ours.len)) : (i += 1) {
                    switch (std.mem.order(u8, ours[i].bytes(), theirs[i].bytes())) {
                        .lt => return .probe_lost,
                        .gt => break,
                        .eq => continue,
                    }
                }
                if (i == ours.len and theirs.len > ours.len) return .probe_lost;
            }
        }
        return .none;
    }

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
        w.ttl(ttl);
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
        w.u16v(w.uniqueClass());
        w.ttl(ttl_host);
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
        w.u16v(w.uniqueClass());
        w.ttl(ttl_host);
        // one zero-length string, which is the dns-sd way of saying "no keys" -- an empty rdata
        // is not legal for TXT and some resolvers drop the record instead of the service.
        w.u16v(1);
        w.u8v(0);
    }

    fn putA(self: Responder, w: *Writer) void {
        const host = self.hostName();
        w.name(&host);
        w.u16v(TYPE_A);
        w.u16v(w.uniqueClass());
        w.ttl(ttl_host);
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
        return self.respondMode(query, out, false);
    }

    /// source port distinguishes legacy one-shot resolvers from multicast queriers.
    pub fn reply(self: Responder, query: []const u8, from: [4]u8, from_port: u16, out: []u8) ?Reply {
        if (from_port == 0) return null;
        const legacy = from_port != mcast_port;
        const n = self.respondMode(query, out, legacy) orelse return null;
        return .{ .len = n, .addr = if (legacy) from else mcast_addr, .port = if (legacy) from_port else mcast_port };
    }

    fn respondMode(self: Responder, query: []const u8, out: []u8, legacy: bool) ?usize {
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

        // include the related records too, so one exchange resolves the service
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

        var w = Writer{ .buf = out, .legacy = legacy };
        w.u16v(if (legacy) std.mem.readInt(u16, query[0..2], .big) else 0);
        w.u16v(0x8400);
        w.u16v(if (legacy) qd else 0);
        w.u16v(count);
        w.u16v(0);
        w.u16v(0);
        // preserve offsets for compressed questions by keeping the original question section.
        if (legacy) w.bytes(query[12..off]);
        if (want_meta) self.putPtr(&w, &meta, &svc, ttl_ptr);
        if (want_ptr) self.putPtr(&w, &svc, &inst, ttl_ptr);
        if (want_srv) self.putSrv(&w);
        if (want_txt) self.putTxt(&w);
        if (want_a) self.putA(&w);
        if (w.overflow) return null;
        return w.at;
    }
};

// bounded canonical rrsets used only for ownership decisions, not a general dns cache.
const Key = struct {
    data: [512]u8 = undefined,
    len: usize = 0,

    fn bytes(self: *const Key) []const u8 {
        return self.data[0..self.len];
    }

    fn read(self: *Key, packet: []const u8, kind: u16, start: usize, end: usize, fold_names: bool) bool {
        var w = Writer{ .buf = &self.data };
        w.u16v(CLASS_IN);
        w.u16v(kind);
        var off = start;
        if (kind == TYPE_SRV) {
            if (end - start < 7) return false;
            w.bytes(packet[start..][0..6]);
            off += 6;
        }
        if (kind == TYPE_SRV or kind == TYPE_PTR or kind == 5 or kind == 2) {
            var target: Name = .{};
            const after = parseName(packet, off, &target) orelse return false;
            if (after != end) return false;
            for (target.parts[0..target.n]) |part| {
                w.u8v(@intCast(part.len));
                for (part) |c| w.u8v(if (fold_names) std.ascii.toLower(c) else c);
            }
            w.u8v(0);
        } else {
            if (kind == TYPE_A and end - start != 4) return false;
            w.bytes(packet[start..end]);
        }
        self.len = w.at;
        return !w.overflow;
    }
};

const ClaimSet = struct {
    items: [8]Key = undefined,
    len: usize = 0,

    fn add(self: *ClaimSet, key: Key) bool {
        var at: usize = 0;
        while (at < self.len) : (at += 1) {
            switch (std.mem.order(u8, key.bytes(), self.items[at].bytes())) {
                .eq => return true,
                .lt => break,
                .gt => {},
            }
        }
        if (self.len == self.items.len) return false;
        var i = self.len;
        while (i > at) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[at] = key;
        self.len += 1;
        return true;
    }
};

const Claims = struct {
    sets: [2]ClaimSet = .{ .{}, .{} },

    fn read(self: *Claims, r: Responder, packet: []const u8, authority_only: bool, fold_names: bool) bool {
        const questions = std.mem.readInt(u16, packet[4..6], .big);
        const answers: usize = std.mem.readInt(u16, packet[6..8], .big);
        const authority: usize = std.mem.readInt(u16, packet[8..10], .big);
        const additional: usize = std.mem.readInt(u16, packet[10..12], .big);
        var off: usize = 12;
        for (0..questions) |_| {
            var name: Name = .{};
            off = parseName(packet, off, &name) orelse return false;
            if (off + 4 > packet.len) return false;
            off += 4;
        }
        const host = r.hostName();
        const instance = r.instanceName();
        for (0..answers + authority + additional) |index| {
            var name: Name = .{};
            off = parseName(packet, off, &name) orelse return false;
            if (off + 10 > packet.len) return false;
            const kind = std.mem.readInt(u16, packet[off..][0..2], .big);
            const class = std.mem.readInt(u16, packet[off + 2 ..][0..2], .big) & 0x7fff;
            const ttl = std.mem.readInt(u32, packet[off + 4 ..][0..4], .big);
            const len = std.mem.readInt(u16, packet[off + 8 ..][0..2], .big);
            const start = off + 10;
            off = start + len;
            if (off > packet.len) return false;
            if (authority_only and (index < answers or index >= answers + authority)) continue;
            if (class != CLASS_IN or ttl == 0) continue;
            const group: usize = if (name.eql(&host)) 0 else if (name.eql(&instance)) 1 else continue;
            var key: Key = .{};
            if (!key.read(packet, kind, start, off, fold_names)) return false;
            if (!self.sets[group].add(key)) return false;
        }
        return true;
    }
};

/// use the whole hardware identity: a 16-bit tail is not unique across devices.
pub fn instanceFromMacBytes(mac: [6]u8, out: *[name_capacity]u8) []const u8 {
    const hex = "0123456789abcdef";
    const prefix = "tc002-";
    @memcpy(out[0..prefix.len], prefix);
    for (mac, 0..) |byte, i| {
        out[prefix.len + 2 * i] = hex[byte >> 4];
        out[prefix.len + 2 * i + 1] = hex[byte & 0xf];
    }
    return out[0 .. prefix.len + 12];
}

pub fn instanceFromMac(mac: []const u8, out: *[name_capacity]u8) []const u8 {
    const prefix = "tc002-";
    @memcpy(out[0..prefix.len], prefix);
    var n: usize = prefix.len;
    for (mac) |c| {
        if (std.ascii.isHex(c) and n < prefix.len + 12) {
            out[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return out[0..n];
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

test "an instance name contains the whole mac" {
    var buf: [name_capacity]u8 = undefined;
    try testing.expectEqualStrings("tc002-ccc4b2779e85", instanceFromMac("cc:c4:b2:77:9e:85", &buf));
    try testing.expectEqualStrings("tc002-ccc4b277a282", instanceFromMac("CC:C4:B2:77:A2:82", &buf));
    try testing.expectEqualStrings("tc002-ccc4b2779e85", instanceFromMac("ccc4b2779e85", &buf));
}

test "an instance name from the raw mac bytes agrees with the text form" {
    var a: [name_capacity]u8 = undefined;
    var b: [name_capacity]u8 = undefined;
    try testing.expectEqualStrings(
        instanceFromMac("cc:c4:b2:77:9e:85", &a),
        instanceFromMacBytes(.{ 0xcc, 0xc4, 0xb2, 0x77, 0x9e, 0x85 }, &b),
    );
    try testing.expectEqualStrings("tc002-000000000001", instanceFromMacBytes(.{ 0, 0, 0, 0, 0x00, 0x01 }, &b));
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

test "different macs sharing a tail have different hostnames" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const first = instanceFromMacBytes(.{ 0xcc, 0xc4, 0xb2, 0x77, 0x9e, 0x85 }, &a);
    const second = instanceFromMacBytes(.{ 0xcc, 0xc4, 0xb2, 0x78, 0x9e, 0x85 }, &b);
    try testing.expect(!std.mem.eql(u8, first, second));
}

test "legacy queries receive a unicast answer with their id and question" {
    const r = Responder{ .instance = "tc002-9e85", .ip = .{ 192, 0, 2, 10 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "tc002-9e85", "local" }, TYPE_A, CLASS_IN);
    std.mem.writeInt(u16, qbuf[0..2], 0x1234, .big);
    var out: [512]u8 = undefined;
    const peer: [4]u8 = .{ 192, 0, 2, 20 };
    const reply = r.reply(q, peer, 43210, &out).?;
    try testing.expectEqualSlices(u8, &peer, &reply.addr);
    try testing.expectEqual(@as(u16, 43210), reply.port);
    try testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, out[0..2], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, out[4..6], .big));
    try testing.expectEqualSlices(u8, q[12..], out[12..q.len]);
    var name: Name = .{};
    const rr = parseName(out[0..reply.len], q.len, &name).?;
    try testing.expectEqual(CLASS_IN, std.mem.readInt(u16, out[rr + 2 ..][0..2], .big));
    try testing.expect(std.mem.readInt(u32, out[rr + 4 ..][0..4], .big) <= 10);
}

test "conflicting records and simultaneous probes are distinguished" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var peer = ours;
    peer.ip = .{ 192, 0, 2, 11 };
    var out: [512]u8 = undefined;
    const ann = peer.announce(&out).?;
    try testing.expectEqual(Conflict.answer, ours.conflict(out[0..ann], true));
    const probe = peer.probe(&out).?;
    try testing.expectEqual(Conflict.probe_lost, ours.conflict(out[0..probe], true));
    try testing.expectEqual(Conflict.none, ours.conflict(out[0..probe], false));
    const our_probe = ours.probe(&out).?;
    try testing.expectEqual(Conflict.none, peer.conflict(out[0..our_probe], true));
    try testing.expectEqual(Conflict.none, ours.conflict(out[0..our_probe], true));
    try testing.expectEqual(Conflict.none, ours.conflict(out[0 .. our_probe - 1], true));
}

test "multicast replies retain zero id no questions flush flags and normal ttl" {
    const r = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var qbuf: [128]u8 = undefined;
    const q = mkQuery(&qbuf, &.{ "tc002-ccc4b2779e85", "local" }, TYPE_A, CLASS_IN | 0x8000);
    std.mem.writeInt(u16, qbuf[0..2], 0x1234, .big);
    var out: [512]u8 = undefined;
    const reply = r.reply(q, .{ 192, 0, 2, 20 }, mcast_port, &out).?;
    try testing.expectEqualSlices(u8, &mcast_addr, &reply.addr);
    try testing.expectEqual(mcast_port, reply.port);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[0..2], .big));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[4..6], .big));
    var name: Name = .{};
    const off = parseName(out[0..reply.len], 12, &name).?;
    try testing.expectEqual(CLASS_IN | CLASS_FLUSH, std.mem.readInt(u16, out[off + 2 ..][0..2], .big));
    try testing.expectEqual(ttl_host, std.mem.readInt(u32, out[off + 4 ..][0..4], .big));
}

test "compressed legacy questions retain their offsets and small buffers are rejected" {
    const r = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var qbuf: [256]u8 = undefined;
    const first = mkQuery(&qbuf, &.{ "tc002-ccc4b2779e85", "local" }, TYPE_A, CLASS_IN);
    var w = Writer{ .buf = &qbuf, .at = first.len };
    w.u16v(0xc00c); // repeat the first question's name
    w.u16v(TYPE_ANY);
    w.u16v(CLASS_IN);
    std.mem.writeInt(u16, qbuf[4..6], 2, .big);
    const q = qbuf[0..w.at];
    var out: [512]u8 = undefined;
    const reply = r.reply(q, .{ 192, 0, 2, 20 }, 43210, &out).?;
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[4..6], .big));
    try testing.expectEqualSlices(u8, q[12..], out[12..q.len]);
    var name: Name = .{};
    _ = parseName(out[0..reply.len], first.len, &name).?;
    try testing.expect(name.eql(&.{ "tc002-ccc4b2779e85", "local" }));
    var tiny: [32]u8 = undefined;
    try testing.expect(r.reply(q, .{ 192, 0, 2, 20 }, 43210, &tiny) == null);
}

test "probe known answers and goodbye records do not cause ownership loss" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var peer = ours;
    peer.ip = .{ 192, 0, 2, 11 };
    var out: [512]u8 = undefined;
    const n = peer.probe(&out).?;
    // turn the authority section into a query's known-answer section.
    std.mem.writeInt(u16, out[6..8], 3, .big);
    std.mem.writeInt(u16, out[8..10], 0, .big);
    try testing.expectEqual(Conflict.none, ours.conflict(out[0..n], true));
    const k = peer.announce(&out).?;
    var off: usize = 12;
    for (0..4) |_| {
        var name: Name = .{};
        off = parseName(out[0..k], off, &name).?;
        std.mem.writeInt(u32, out[off + 4 ..][0..4], 0, .big);
        off += 10 + std.mem.readInt(u16, out[off + 8 ..][0..2], .big);
    }
    try testing.expectEqual(Conflict.none, ours.conflict(out[0..k], true));
}

test "a conflict only in the service instance also requires a new name" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var peer = ours;
    peer.port = 8080;
    var out: [512]u8 = undefined;
    const n = peer.announce(&out).?;
    try testing.expectEqual(Conflict.answer, ours.conflict(out[0..n], true));
    const p = peer.probe(&out).?;
    try testing.expectEqual(Conflict.probe_lost, ours.conflict(out[0..p], true));
}

test "established ownership ignores rr types it does not own" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var buf: [512]u8 = undefined;
    var w = Writer{ .buf = &buf };
    w.u16v(0);
    w.u16v(0x8400);
    w.u16v(0);
    w.u16v(1);
    w.u16v(0);
    w.u16v(0);
    const host = ours.hostName();
    w.name(&host);
    w.u16v(28); // a peer's aaaa is a different rrset from our a
    w.u16v(CLASS_IN);
    w.u32v(120);
    w.u16v(16);
    w.bytes(&(.{0} ** 16));
    try testing.expectEqual(Conflict.none, ours.conflict(buf[0..w.at], false));
    try testing.expectEqual(Conflict.answer, ours.conflict(buf[0..w.at], true));
}

test "simultaneous srv proposals compare raw uncompressed target bytes" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var buf: [512]u8 = undefined;
    var w = Writer{ .buf = &buf, .flush = false };
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    w.u16v(0);
    w.u16v(2);
    w.u16v(0);
    ours.putTxt(&w);
    const inst = ours.instanceName();
    w.name(&inst);
    w.u16v(TYPE_SRV);
    w.u16v(CLASS_IN);
    w.u32v(120);
    w.u16v(6 + 1 + 18 + 1 + 5 + 1);
    w.u16v(0);
    w.u16v(0);
    w.u16v(80);
    // equal-length first label: uppercase Z sorts before lowercase t on the wire.
    w.name(&.{ "ZZZZZZZZZZZZZZZZZZ", "local" });
    try testing.expectEqual(Conflict.none, ours.conflict(buf[0..w.at], true));
}

test "truncated conflict packets never alter ownership" {
    const ours = Responder{ .instance = "tc002-ccc4b2779e85", .ip = .{ 192, 0, 2, 10 } };
    var peer = ours;
    peer.ip = .{ 192, 0, 2, 11 };
    var buf: [512]u8 = undefined;
    const n = peer.announce(&buf).?;
    for (0..n) |len| try testing.expectEqual(Conflict.none, ours.conflict(buf[0..len], true));
    const k = peer.probe(&buf).?;
    for (0..k) |len| try testing.expectEqual(Conflict.none, ours.conflict(buf[0..len], true));
}
