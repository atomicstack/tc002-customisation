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

    fn setName(self: *Owner) void {
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
        return self.ip != null and self.announcements > 0;
    }

    pub fn responder(self: *const Owner) ?mdns.Responder {
        return .{ .instance = self.name[0..self.name_len], .ip = self.ip orelse return null };
    }

    /// packet generation does not advance time or ownership: only a successful
    /// socket send commits a probe/announcement, so transient failures retry.
    pub fn packet(self: *const Owner, now: u64, out: []u8) ?usize {
        if (now < self.next_ns or self.announcements >= 2) return null;
        const r = self.responder() orelse return null;
        return if (self.probes < 3) r.probe(out) else r.announce(out);
    }

    pub fn sent(self: *Owner, now: u64) void {
        if (self.probes < 3) {
            self.probes += 1;
            self.next_ns = now + 250 * std.time.ns_per_ms;
        } else {
            self.announcements += 1;
            self.next_ns = now + std.time.ns_per_s;
        }
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
