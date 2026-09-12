//! the procfs readings the supervisor samples beyond cpu and memory totals, parsed here so they
//! can be tested on the host: the interface counters, the memory gauges the sampler did not yet
//! read, and the rate arithmetic that turns a pair of counters into bytes per second.
//!
//! what this kernel cannot give us is worth writing down, because it was measured rather than
//! assumed (linux 4.9.84, probed 2026-09-12): `bpf` and `perf_event_open` both return enosys,
//! there are no kprobes, `/proc/self/io` is absent, and vmstat carries only gauges -- no
//! pgfault, pgalloc or pgscan event counters. nothing here may be presented as flash wear
//! either: mtd6 exposes geometry and ecc fields but no programmed-byte or erase totals.
const std = @import("std");

/// a rate we have no honest answer for: no previous sample, no elapsed time, or a counter that
/// went backwards. never reported as zero, which would read as "idle".
pub const unknown_rate: u32 = 0xffffffff;

/// the sixteen counters `/proc/net/dev` keeps per interface, of which we carry eight
pub const Net = struct {
    rx_bytes: u64 = 0,
    rx_packets: u64 = 0,
    rx_errors: u64 = 0,
    rx_dropped: u64 = 0,
    tx_bytes: u64 = 0,
    tx_packets: u64 = 0,
    tx_errors: u64 = 0,
    tx_dropped: u64 = 0,
};

/// the memory gauges beyond MemTotal/MemFree/MemAvailable, which the sampler already reads
pub const Mem = struct {
    cached_kb: u32 = 0,
    dirty_kb: u32 = 0,
    writeback_kb: u32 = 0,
    slab_kb: u32 = 0,
};

/// one interface's line out of `/proc/net/dev`, or null if it is not there. the name is matched
/// whole, so `wlan0` never matches `wlan0.1`, and the first count may be glued to the colon --
/// some kernels print `wlan0:525283638` once the byte total grows past the column width.
pub fn parseNetDev(text: []const u8, iface: []const u8) ?Net {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        if (!std.mem.eql(u8, t[0..colon], iface)) continue;
        var it = std.mem.tokenizeAny(u8, t[colon + 1 ..], " \t");
        var f: [16]u64 = .{0} ** 16;
        var i: usize = 0;
        while (it.next()) |tok| : (i += 1) {
            if (i >= f.len) break;
            f[i] = std.fmt.parseInt(u64, tok, 10) catch return null;
        }
        if (i < 16) return null; // a short line is a kernel we do not understand, not a zero
        return .{
            .rx_bytes = f[0],   .rx_packets = f[1], .rx_errors = f[2],  .rx_dropped = f[3],
            .tx_bytes = f[8],   .tx_packets = f[9], .tx_errors = f[10], .tx_dropped = f[11],
        };
    }
    return null;
}

/// the four gauges out of `/proc/meminfo`. a field this kernel does not print stays zero, which
/// for a gauge is the truth rather than a placeholder.
pub fn parseMeminfo(text: []const u8) Mem {
    return .{
        .cached_kb = kbOf(text, "Cached:"),
        .dirty_kb = kbOf(text, "Dirty:"),
        .writeback_kb = kbOf(text, "Writeback:"),
        .slab_kb = kbOf(text, "Slab:"),
    };
}

/// `Cached:` must not match `SwapCached:`, so the key is only accepted at the start of a line
fn kbOf(text: []const u8, key: []const u8) u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeAny(u8, line[key.len..], " \t");
        const v = it.next() orelse return 0;
        return @intCast(@min(std.fmt.parseInt(u64, v, 10) catch 0, 0xffffffff));
    }
    return 0;
}

/// units per second across the interval. `prev` of zero is treated as "no previous sample": the
/// counters here are lifetime totals that only read zero before anything has happened, and a
/// first sample reporting a full lifetime's traffic as one second of it is worse than unknown.
pub fn perSecond(now_total: u64, prev_total: u64, interval_ns: u64) u32 {
    if (prev_total == 0 or interval_ns == 0) return unknown_rate;
    if (now_total < prev_total) return unknown_rate; // the interface was reset under us
    const delta = now_total - prev_total;
    const per_s = delta * std.time.ns_per_s / interval_ns;
    return @intCast(@min(per_s, unknown_rate - 1));
}

const sample_dev =
    \\Inter-|   Receive                                                |  Transmit
    \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    \\ wlan0: 525283638 2277879    0 1339872    0     0          0         0 48021332  295533    0    0    0     0       0          0
    \\  p2p0:       0       0    0    0    0     0          0         0        0       0    0    0    0     0       0          0
    \\    lo:    1104       7    0    0    0     0          0         0     1104       7    0    0    0     0       0          0
;

test "the interface counters come off the line whole" {
    const n = parseNetDev(sample_dev, "wlan0").?;
    try std.testing.expectEqual(@as(u64, 525283638), n.rx_bytes);
    try std.testing.expectEqual(@as(u64, 2277879), n.rx_packets);
    try std.testing.expectEqual(@as(u64, 0), n.rx_errors);
    // this device really does report a third of its received frames dropped; it is a driver
    // counter, not application packet loss, and nothing downstream may call it that
    try std.testing.expectEqual(@as(u64, 1339872), n.rx_dropped);
    try std.testing.expectEqual(@as(u64, 48021332), n.tx_bytes);
    try std.testing.expectEqual(@as(u64, 295533), n.tx_packets);
    try std.testing.expectEqual(@as(u64, 0), n.tx_errors);
    try std.testing.expectEqual(@as(u64, 0), n.tx_dropped);

    const lo = parseNetDev(sample_dev, "lo").?;
    try std.testing.expectEqual(@as(u64, 1104), lo.rx_bytes);
    try std.testing.expect(parseNetDev(sample_dev, "eth0") == null);
    try std.testing.expect(parseNetDev(sample_dev, "wlan") == null); // whole names only
    try std.testing.expect(parseNetDev("", "wlan0") == null);
}

test "a count glued to the colon, and a line too short to trust" {
    const glued = " wlan0:525283638 2277879 0 1339872 0 0 0 0 48021332 295533 0 0 0 0 0 0";
    const n = parseNetDev(glued, "wlan0").?;
    try std.testing.expectEqual(@as(u64, 525283638), n.rx_bytes);
    try std.testing.expectEqual(@as(u64, 48021332), n.tx_bytes);
    try std.testing.expect(parseNetDev(" wlan0: 1 2 3", "wlan0") == null);
    try std.testing.expect(parseNetDev(" wlan0: 1 2 x 4 5 6 7 8 9 10 11 12 13 14 15 16", "wlan0") == null);
}

test "the memory gauges, and a key that must not match a longer one" {
    const text =
        \\MemTotal:          36240 kB
        \\MemFree:            4408 kB
        \\Buffers:            2264 kB
        \\Cached:            11772 kB
        \\SwapCached:          999 kB
        \\Dirty:                 0 kB
        \\Writeback:             0 kB
        \\Slab:               8528 kB
    ;
    const m = parseMeminfo(text);
    try std.testing.expectEqual(@as(u32, 11772), m.cached_kb); // not SwapCached's 999
    try std.testing.expectEqual(@as(u32, 0), m.dirty_kb);
    try std.testing.expectEqual(@as(u32, 0), m.writeback_kb);
    try std.testing.expectEqual(@as(u32, 8528), m.slab_kb);
    try std.testing.expectEqual(Mem{}, parseMeminfo("")); // a kernel that prints none of it
}

test "a rate needs a pair of samples, and says so when it has not got one" {
    try std.testing.expectEqual(unknown_rate, perSecond(1000, 0, std.time.ns_per_s)); // first sample
    try std.testing.expectEqual(unknown_rate, perSecond(1000, 500, 0)); // no time passed
    try std.testing.expectEqual(unknown_rate, perSecond(400, 500, std.time.ns_per_s)); // reset
    try std.testing.expectEqual(@as(u32, 500), perSecond(1000, 500, std.time.ns_per_s));
    try std.testing.expectEqual(@as(u32, 100), perSecond(1000, 500, 5 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u32, 1000), perSecond(1000, 500, std.time.ns_per_s / 2));
    try std.testing.expectEqual(@as(u32, 0), perSecond(500, 500, std.time.ns_per_s)); // idle, known
}
