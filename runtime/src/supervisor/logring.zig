//! the supervisor's log ring: the most recent lines from every runtime process, numbered from 1,
//! served in pages over the local channel. children write their lines into a pipe the supervisor
//! drains; the supervisor's own lines arrive through `log.sink`. fixed storage, no allocation.
const std = @import("std");
const messages = @import("../ipc/messages.zig");

pub const slots = 64;
pub const line_max = messages.log_line_max;

pub const Ring = struct {
    lines: [slots][line_max]u8 = undefined,
    lens: [slots]u8 = [_]u8{0} ** slots,
    /// the sequence number the next pushed line will get; lines are numbered from 1.
    next_seq: u32 = 1,

    pub fn push(self: *Ring, text: []const u8) void {
        const t = std.mem.trimEnd(u8, text, "\r\n");
        const n: usize = @min(t.len, line_max);
        const slot = self.next_seq % slots;
        @memcpy(self.lines[slot][0..n], t[0..n]);
        self.lens[slot] = @intCast(n);
        self.next_seq +%= 1;
    }

    /// the oldest sequence number still held.
    pub fn oldest(self: *const Ring) u32 {
        return if (self.next_seq > slots) self.next_seq - slots else 1;
    }

    fn get(self: *const Ring, seq: u32) []const u8 {
        const slot = seq % slots;
        return self.lines[slot][0..self.lens[slot]];
    }

    /// fill a page with the lines after `after`, oldest first. `out.next` is the sequence number
    /// of the last line included (pass it back as `after`); a jump in sequence numbers means
    /// lines were evicted in between.
    pub fn page(self: *const Ring, after: u32, out: *messages.LogLines) void {
        out.* = .{ .next = after };
        var seq = @max(after +| 1, self.oldest());
        while (seq < self.next_seq) : (seq += 1) {
            if (!out.add(seq, self.get(seq))) break;
            out.next = seq;
        }
    }
};

/// splits a byte stream from the pipe into lines; a line cut by a read boundary is carried over.
pub const Assembler = struct {
    pub const carry_max = 320;
    carry: [carry_max]u8 = undefined,
    carry_len: usize = 0,

    pub fn feed(self: *Assembler, bytes: []const u8, ctx: anytype, comptime onLine: fn (@TypeOf(ctx), []const u8) void) void {
        var rest = bytes;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const chunk = if (nl) |i| rest[0..i] else rest;
            const take: usize = @min(chunk.len, carry_max - self.carry_len);
            @memcpy(self.carry[self.carry_len .. self.carry_len + take], chunk[0..take]);
            self.carry_len += take;
            if (nl) |i| {
                onLine(ctx, self.carry[0..self.carry_len]);
                self.carry_len = 0;
                rest = rest[i + 1 ..];
            } else {
                rest = rest[rest.len..];
            }
        }
    }
};

const TestSink = struct {
    ring: *Ring,
    fn line(self: *TestSink, text: []const u8) void {
        self.ring.push(text);
    }
};

test "the ring numbers lines from one, evicts the oldest, and pages after a sequence number" {
    var r = Ring{};
    var page = messages.LogLines{ .next = 0 };
    r.page(0, &page);
    try std.testing.expectEqual(@as(u8, 0), page.count);
    try std.testing.expectEqual(@as(u32, 0), page.next);
    r.push("one\n");
    r.push("two");
    r.page(0, &page);
    try std.testing.expectEqual(@as(u8, 2), page.count);
    try std.testing.expectEqual(@as(u32, 2), page.next);
    var it = page.iterator();
    const first = it.next().?;
    try std.testing.expectEqual(@as(u32, 1), first.seq);
    try std.testing.expectEqualStrings("one", first.text);
    r.page(2, &page);
    try std.testing.expectEqual(@as(u8, 0), page.count);
    try std.testing.expectEqual(@as(u32, 2), page.next);
    var i: u32 = 0;
    while (i < 100) : (i += 1) r.push("x");
    try std.testing.expectEqual(@as(u32, 103), r.next_seq);
    try std.testing.expectEqual(@as(u32, 39), r.oldest());
    r.page(0, &page); // everything older than 39 is gone; a page holds sixteen
    try std.testing.expectEqual(@as(u8, 16), page.count);
    var first_it = page.iterator();
    try std.testing.expectEqual(@as(u32, 39), first_it.next().?.seq);
    try std.testing.expectEqual(@as(u32, 54), page.next);
    r.page(54, &page);
    try std.testing.expectEqual(@as(u32, 70), page.next);
    r.page(1000, &page); // beyond the end: nothing, and next stays as given
    try std.testing.expectEqual(@as(u8, 0), page.count);
}

test "long lines are cut at the line maximum" {
    var r = Ring{};
    r.push("y" ** 300);
    var page = messages.LogLines{ .next = 0 };
    r.page(0, &page);
    var it = page.iterator();
    try std.testing.expectEqual(@as(usize, line_max), it.next().?.text.len);
}

test "the assembler joins a line split across reads and drops nothing on exact boundaries" {
    var r = Ring{};
    var sink = TestSink{ .ring = &r };
    var a = Assembler{};
    a.feed("tc002d 1 info hel", &sink, TestSink.line);
    try std.testing.expectEqual(@as(u32, 1), r.next_seq);
    a.feed("lo\ntc002d 2 warn x\n", &sink, TestSink.line);
    try std.testing.expectEqual(@as(u32, 3), r.next_seq);
    var page = messages.LogLines{ .next = 0 };
    r.page(0, &page);
    var it = page.iterator();
    try std.testing.expectEqualStrings("tc002d 1 info hello", it.next().?.text);
    try std.testing.expectEqualStrings("tc002d 2 warn x", it.next().?.text);
    a.feed("\n\n", &sink, TestSink.line); // empty lines are lines too
    try std.testing.expectEqual(@as(u32, 5), r.next_seq);
    a.feed("z" ** 400, &sink, TestSink.line); // an overlong partial line is cut, not spilled
    a.feed("\n", &sink, TestSink.line);
    try std.testing.expectEqual(@as(u32, 6), r.next_seq);
}
