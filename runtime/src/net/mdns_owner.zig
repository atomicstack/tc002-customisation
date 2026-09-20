//! bounded ownership and startup scheduling for the mdns responder.
const std = @import("std");
const mdns = @import("mdns.zig");
pub const Owner = struct {
    mac: [6]u8 = .{0} ** 6,
    ip: ?[4]u8 = null,
    name: [mdns.name_capacity]u8 = undefined,
    name_len: usize = 0,
    attempt: u32 = 1,
    probes: u8 = 0,
    announcements: u8 = 0,
    next_ns: u64 = 0,
    /// the current name has been announced at least once, so caches on the lan hold it and it
    /// has to be withdrawn if we give it up
    claimed: bool = false,
    /// a goodbye for a name we have just given up, waiting for the socket; sent before anything
    /// else and outside the backoff, because the caches holding the old name are wrong now.
    /// twice, a second apart, like an announcement (rfc 6762 s8.3): multicast over wifi drops
    /// frames, and a lost goodbye leaves the old name cached for 75 minutes.
    farewell: [512]u8 = undefined,
    farewell_len: usize = 0,
    farewell_left: u8 = 0,
    farewell_next_ns: u64 = 0,
    /// switched off: the name has been withdrawn (or never announced) and nothing more goes out.
    /// turning mdns back on is a fresh owner, not a flag flip.
    retired: bool = false,

    pub fn configure(self: *Owner, address_mac: [6]u8, ip: ?[4]u8, now: u64) void {
        if (std.meta.eql(self.mac, address_mac) and std.meta.eql(self.ip, ip)) return;
        if (self.name_len == 0 or !std.meta.eql(self.mac, address_mac)) {
            self.mac = address_mac;
            self.attempt = 1;
            self.setName();
        }
        self.ip = ip;
        self.restart(now, 0);
    }

    /// queue the goodbye for the current name if anyone can hold it (it was announced).
    fn withdrawName(self: *Owner) void {
        if (!self.claimed) return;
        if (self.responder()) |old| self.farewell_len = old.goodbye(&self.farewell) orelse 0;
        self.farewell_left = if (self.farewell_len > 0) 2 else 0;
        self.farewell_next_ns = 0;
        self.claimed = false;
    }

    /// mdns switched off: withdraw the name and go quiet for good.
    pub fn retire(self: *Owner, now: u64) void {
        _ = now;
        self.withdrawName();
        self.retired = true;
    }

    fn setName(self: *Owner) void {
        self.withdrawName();
        const base = mdns.instanceFromMacBytes(self.mac, &self.name);
        self.name_len = base.len;
        if (self.attempt > 1) {
            const suffix = std.fmt.bufPrint(self.name[base.len..], "-{d}", .{self.attempt}) catch unreachable;
            self.name_len += suffix.len;
        }
    }

    fn restart(self: *Owner, now: u64, delay: u64) void {
        self.probes = 0;
        self.announcements = 0;
        const entropy = std.hash.Wyhash.hash(now, &self.mac) ^ @as(u32, @bitCast(self.ip orelse .{ 0, 0, 0, 0 }));
        self.next_ns = now + delay + entropy % (250 * std.time.ns_per_ms);
    }

    pub fn ready(self: *const Owner) bool {
        return !self.retired and self.ip != null and self.announcements > 0;
    }

    pub fn responder(self: *const Owner) ?mdns.Responder {
        return .{ .instance = self.name[0..self.name_len], .ip = self.ip orelse return null };
    }

    /// packet generation does not advance time or ownership: only a successful
    /// socket send commits a probe/announcement, so transient failures retry.
    pub fn packet(self: *const Owner, now: u64, out: []u8) ?usize {
        if (self.farewell_left > 0) {
            // nothing else goes out while a name is being withdrawn; the new name's probes start
            // after a five-second backoff anyway
            if (now < self.farewell_next_ns or out.len < self.farewell_len) return null;
            @memcpy(out[0..self.farewell_len], self.farewell[0..self.farewell_len]);
            return self.farewell_len;
        }
        if (self.retired) return null;
        if (now < self.next_ns or self.announcements >= 2) return null;
        const r = self.responder() orelse return null;
        return if (self.probes < 3) r.probe(out) else r.announce(out);
    }

    pub fn sent(self: *Owner, now: u64) void {
        if (self.farewell_left > 0) {
            self.farewell_left -= 1;
            self.farewell_next_ns = now + std.time.ns_per_s;
            return;
        }
        if (self.probes < 3) {
            self.probes += 1;
            self.next_ns = now + 250 * std.time.ns_per_ms;
        } else {
            self.announcements += 1;
            self.claimed = true;
            self.next_ns = now + std.time.ns_per_s;
        }
    }

    /// a goodbye for a name just given up is waiting to be sent
    pub fn withdrawing(self: *const Owner) bool {
        return self.farewell_left > 0;
    }

    /// the goodbye for a clean exit: only a name that was announced is held by anyone.
    pub fn goodbye(self: *const Owner, out: []u8) ?usize {
        if (!self.claimed) return null;
        const r = self.responder() orelse return null;
        return r.goodbye(out);
    }

    /// ownership accepts only packets whose ttl proves they did not cross a router.
    /// legacy queries are still answered independently of this stricter ownership rule.
    pub fn observeLocal(self: *Owner, packet_bytes: []const u8, port: u16, ttl: ?u8, now: u64) void {
        if (ttl == null or ttl.? != 255) return;
        self.observe(packet_bytes, port, now);
    }

    fn observe(self: *Owner, packet_bytes: []const u8, port: u16, now: u64) void {
        if (port != mdns.mcast_port or self.probes == 0) return;
        const r = self.responder() orelse return;
        switch (r.conflict(packet_bytes, !self.ready())) {
            .none => {},
            .probe_lost => self.restart(now, std.time.ns_per_s),
            .answer => {
                // back off on every conflict, which also bounds persistent hostile
                // or broken peers. no replies under either name until probing ends.
                if (!self.ready()) {
                    self.attempt +|= 1;
                    self.setName();
                }
                self.restart(now, 5 * std.time.ns_per_s);
            },
        }
    }
};

const testing = std.testing;
const ms = std.time.ns_per_ms;
const mac: [6]u8 = .{ 0xcc, 0xc4, 0xb2, 0x77, 0x9e, 0x85 };

test "ownership waits for three probes and sends two startup announcements" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    try testing.expect(!owner.ready());
    var out: [512]u8 = undefined;
    for (0..3) |i| {
        const now = owner.next_ns;
        const n = owner.packet(now, &out).?;
        try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[2..4], .big));
        try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[4..6], .big));
        try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[8..10], .big));
        try testing.expect(n > 12);
        try testing.expect(!owner.ready());
        owner.sent(now);
        try testing.expectEqual(@as(u8, @intCast(i + 1)), owner.probes);
    }
    const now = owner.next_ns;
    _ = owner.packet(now, &out).?;
    try testing.expectEqual(@as(u16, 0x8400), std.mem.readInt(u16, out[2..4], .big));
    owner.sent(now);
    try testing.expect(owner.ready());
    try testing.expect(owner.packet(now + 999 * ms, &out) == null);
    _ = owner.packet(now + 1000 * ms, &out).?;
    owner.sent(now + 1000 * ms);
    try testing.expect(owner.packet(now + 10000 * ms, &out) == null);
}

test "failed sends do not advance ownership and lost address disables replies" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    const now = owner.next_ns;
    const n = owner.packet(now, &out).?;
    try testing.expectEqual(n, owner.packet(now + ms, &out).?);
    try testing.expectEqual(@as(u8, 0), owner.probes);
    owner.configure(mac, null, now);
    try testing.expect(owner.packet(now + 1000 * ms, &out) == null);
    try testing.expect(!owner.ready());
    owner.configure(mac, .{ 192, 0, 2, 11 }, now + 2000 * ms);
    try testing.expectEqual(@as(u8, 0), owner.probes);
    try testing.expect(!owner.ready());
}

test "established conflicts re-probe before selecting a suffixed name" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    for (0..4) |_| {
        const now = owner.next_ns;
        _ = owner.packet(now, &out).?;
        owner.sent(now);
    }
    try testing.expect(owner.ready());
    var other = owner.responder().?;
    other.ip = .{ 192, 0, 2, 11 };
    const n = other.announce(&out).?;
    owner.observeLocal(out[0..n], 5353, 255, 2000 * ms);
    try testing.expect(!owner.ready());
    try testing.expectEqualStrings("tc002-ccc4b2779e85", owner.responder().?.instance);
    var scratch: [512]u8 = undefined;
    const retry = owner.next_ns;
    _ = owner.packet(retry, &scratch).?;
    owner.sent(retry);
    owner.observeLocal(out[0..n], 5353, 255, retry + ms);
    try testing.expectEqualStrings("tc002-ccc4b2779e85-2", owner.responder().?.instance);
    try testing.expect(owner.next_ns >= retry + 5001 * ms);
}

test "looped back announcements and legacy responses cannot rename us" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    const ours = owner.responder().?;
    const n = ours.announce(&out).?;
    owner.observeLocal(out[0..n], 5353, 255, 100 * ms);
    var other = ours;
    other.ip = .{ 192, 0, 2, 11 };
    const k = other.announce(&out).?;
    owner.observeLocal(out[0..k], 43210, 255, 100 * ms);
    try testing.expectEqualStrings("tc002-ccc4b2779e85", owner.responder().?.instance);
}

test "a simultaneous probe loser backs off without renaming until the winner answers" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    const initial = owner.next_ns;
    _ = owner.packet(initial, &out).?;
    owner.sent(initial);
    var peer = owner.responder().?;
    peer.ip = .{ 192, 0, 2, 11 };
    const n = peer.probe(&out).?;
    owner.observeLocal(out[0..n], 5353, 255, initial + ms);
    try testing.expectEqualStrings("tc002-ccc4b2779e85", owner.responder().?.instance);
    try testing.expect(!owner.ready());
    try testing.expect(owner.next_ns >= initial + 1001 * ms);
    try testing.expectEqual(@as(u8, 0), owner.probes);
}

test "a new address must re-probe even after claiming the previous address" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    for (0..4) |_| {
        const now = owner.next_ns;
        _ = owner.packet(now, &out).?;
        owner.sent(now);
    }
    owner.configure(mac, .{ 192, 0, 2, 11 }, 2000 * ms);
    try testing.expect(!owner.ready());
    try testing.expectEqual(@as(u8, 0), owner.probes);
    try testing.expectEqualSlices(u8, &.{ 192, 0, 2, 11 }, &owner.responder().?.ip);
}

test "off-link or missing hop limit cannot change ownership" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var buf: [512]u8 = undefined;
    const now = owner.next_ns;
    _ = owner.packet(now, &buf).?;
    owner.sent(now);
    var peer = owner.responder().?;
    peer.ip = .{ 192, 0, 2, 11 };
    const n = peer.announce(&buf).?;
    for ([_]?u8{ null, 64, 254 }) |ttl| {
        owner.observeLocal(buf[0..n], 5353, ttl, now + ms);
        try testing.expectEqualStrings("tc002-ccc4b2779e85", owner.responder().?.instance);
    }
    owner.observeLocal(buf[0..n], 5353, 255, now + ms);
    try testing.expectEqualStrings("tc002-ccc4b2779e85-2", owner.responder().?.instance);
}

fn isResponse(pkt: []const u8) bool {
    return std.mem.readInt(u16, pkt[2..4], .big) & 0x8000 != 0;
}

/// the ptr target of the first answer: which instance a packet is talking about.
fn firstPtrTarget(pkt: []const u8, out: *mdns.Name) bool {
    var owner_name: mdns.Name = .{};
    const off = mdns.parseName(pkt, 12, &owner_name) orelse return false;
    if (std.mem.readInt(u32, pkt[off + 4 ..][0..4], .big) != 0) return false; // must be a goodbye
    return mdns.parseName(pkt, off + 10, out) != null;
}

fn establish(owner: *Owner, out: []u8) void {
    for (0..4) |_| {
        const now = owner.next_ns;
        _ = owner.packet(now, out).?;
        owner.sent(now);
    }
}

test "losing an announced name says goodbye to it before probing the new one" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    establish(&owner, &out);
    try testing.expect(owner.ready());
    var other = owner.responder().?;
    other.ip = .{ 192, 0, 2, 11 };
    var pkt: [512]u8 = undefined;
    const n = other.announce(&pkt).?;
    owner.observeLocal(pkt[0..n], 5353, 255, 2000 * ms); // an established conflict: re-probe first
    const retry = owner.next_ns;
    _ = owner.packet(retry, &out).?;
    owner.sent(retry);
    owner.observeLocal(pkt[0..n], 5353, 255, retry + ms); // still contested: rename
    try testing.expectEqualStrings("tc002-ccc4b2779e85-2", owner.responder().?.instance);
    // the goodbye goes out at once, inside the backoff, and withdraws the old instance
    const g = owner.packet(retry + 2 * ms, &out).?;
    try testing.expect(isResponse(out[0..g]));
    var target: mdns.Name = .{};
    try testing.expect(firstPtrTarget(out[0..g], &target));
    try testing.expect(target.eql(&.{ "tc002-ccc4b2779e85", "_tc002", "_tcp", "local" }));
    owner.sent(retry + 2 * ms);
    // the goodbye repeats a second later, then the backoff holds and a probe for the new name follows
    try testing.expect(owner.packet(retry + 3 * ms, &out) == null);
    const g2 = owner.packet(retry + 1002 * ms, &out).?;
    try testing.expect(isResponse(out[0..g2]));
    owner.sent(retry + 1002 * ms);
    try testing.expect(owner.packet(retry + 1003 * ms, &out) == null);
    const next = owner.next_ns;
    try testing.expect(next >= retry + 5000 * ms);
    const p = owner.packet(next, &out).?;
    try testing.expect(!isResponse(out[0..p]));
}

test "a name that was never announced is not withdrawn" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    const initial = owner.next_ns;
    _ = owner.packet(initial, &out).?;
    owner.sent(initial); // one probe, nothing announced
    var peer = owner.responder().?;
    peer.ip = .{ 192, 0, 2, 11 };
    var pkt: [512]u8 = undefined;
    const n = peer.announce(&pkt).?;
    owner.observeLocal(pkt[0..n], 5353, 255, initial + ms);
    try testing.expectEqualStrings("tc002-ccc4b2779e85-2", owner.responder().?.instance);
    // no cache holds the old name, so there is nothing to say: the backoff holds and a probe follows
    try testing.expect(owner.packet(initial + 2 * ms, &out) == null);
    const p = owner.packet(owner.next_ns, &out).?;
    try testing.expect(!isResponse(out[0..p]));
}

test "shutdown withdraws the name only once it has been announced" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    try testing.expect(owner.goodbye(&out) == null);
    for (0..3) |_| {
        const now = owner.next_ns;
        _ = owner.packet(now, &out).?;
        owner.sent(now);
    }
    try testing.expect(owner.goodbye(&out) == null); // still probing
    const now = owner.next_ns;
    _ = owner.packet(now, &out).?;
    owner.sent(now); // the first announcement
    const g = owner.goodbye(&out).?;
    try testing.expect(isResponse(out[0..g]));
    var target: mdns.Name = .{};
    try testing.expect(firstPtrTarget(out[0..g], &target));
    try testing.expect(target.eql(&.{ "tc002-ccc4b2779e85", "_tc002", "_tcp", "local" }));
    // with the address gone the socket is gone too; nothing to send
    owner.configure(mac, null, now + ms);
    try testing.expect(owner.goodbye(&out) == null);
}

test "a goodbye is repeated a second later, because multicast on wifi drops frames" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    establish(&owner, &out);
    var other = owner.responder().?;
    other.ip = .{ 192, 0, 2, 11 };
    var pkt: [512]u8 = undefined;
    const n = other.announce(&pkt).?;
    owner.observeLocal(pkt[0..n], 5353, 255, 2000 * ms);
    const retry = owner.next_ns;
    _ = owner.packet(retry, &out).?;
    owner.sent(retry);
    owner.observeLocal(pkt[0..n], 5353, 255, retry + ms);
    const t = retry + 2 * ms;
    const g1 = owner.packet(t, &out).?;
    try testing.expect(isResponse(out[0..g1]));
    owner.sent(t);
    // not again straight away, and not lost in the backoff either: once more, one second on
    try testing.expect(owner.packet(t + 500 * ms, &out) == null);
    const g2 = owner.packet(t + 1000 * ms, &out).?;
    try testing.expect(isResponse(out[0..g2]));
    var target: mdns.Name = .{};
    try testing.expect(firstPtrTarget(out[0..g2], &target));
    try testing.expect(target.eql(&.{ "tc002-ccc4b2779e85", "_tc002", "_tcp", "local" }));
    owner.sent(t + 1000 * ms);
    // and that is all: the new name's probes follow on their own schedule
    try testing.expect(owner.packet(t + 1100 * ms, &out) == null);
    const p = owner.packet(owner.next_ns, &out).?;
    try testing.expect(!isResponse(out[0..p]));
}

test "switching mdns off withdraws an announced name, then nothing more is sent" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    establish(&owner, &out);
    const t = owner.next_ns + 10 * ms;
    owner.retire(t);
    try testing.expect(!owner.ready()); // no replies while the name is being withdrawn, or after
    const g1 = owner.packet(t, &out).?;
    try testing.expect(isResponse(out[0..g1]));
    var target: mdns.Name = .{};
    try testing.expect(firstPtrTarget(out[0..g1], &target));
    try testing.expect(target.eql(&.{ "tc002-ccc4b2779e85", "_tc002", "_tcp", "local" }));
    owner.sent(t);
    const g2 = owner.packet(t + 1000 * ms, &out).?;
    try testing.expect(isResponse(out[0..g2]));
    owner.sent(t + 1000 * ms);
    try testing.expect(!owner.withdrawing());
    // and then silence: no probes, no announcements, however long it waits
    try testing.expect(owner.packet(t + 2000 * ms, &out) == null);
    try testing.expect(owner.packet(t + 600_000 * ms, &out) == null);
    try testing.expect(owner.goodbye(&out) == null);
}

test "switching mdns off before the name was announced sends nothing" {
    var owner: Owner = .{};
    owner.configure(mac, .{ 192, 0, 2, 10 }, 0);
    var out: [512]u8 = undefined;
    const t = owner.next_ns;
    _ = owner.packet(t, &out).?;
    owner.sent(t); // one probe out, nothing announced
    owner.retire(t + ms);
    try testing.expect(!owner.withdrawing());
    try testing.expect(owner.packet(t + 500 * ms, &out) == null);
    try testing.expect(owner.packet(t + 600_000 * ms, &out) == null);
}
