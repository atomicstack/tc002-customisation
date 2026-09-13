//! server-sent events: the framing for `GET /api/v1/events`, which publishes every statement this
//! device applies so a mirror can replicate them instead of polling and diffing.
//!
//! sse rather than websockets: it is a content type and a blank-line delimiter, browsers have
//! `EventSource` built in, and the traffic only ever flows one way. websockets would mean rfc 6455
//! framing, masking and a close handshake in a static-buffer epoll loop, for nothing.
//!
//! pure: the sockets live in netd. every writer here is bounded and returns an empty slice rather
//! than a truncated frame, because half an event is worse than no event -- a mirror that sees a
//! revision gap resyncs, but one that parses half a statement does not know it should.
const std = @import("std");
const messages = @import("../ipc/messages.zig");
const arbiter = @import("../scene/arbiter.zig");
const scene = @import("../scene/scene.zig");
const clock = @import("../scene/clock.zig");
const ip = @import("../scene/ip.zig");

/// what a quiet stream sends so the connection is exercised. a comment, ignored by every client.
///
/// it is a *write*, which is the point: a subscriber that dies without a fin (a closed lid, a
/// dropped wifi, a nat timeout) is invisible to a server that only reads. writing to it fails, and
/// the slot comes back. exempting the route from the idle timeout instead would leave dead
/// subscribers holding slots for ever.
pub const keepalive = ": ping\n\n";

/// the response head. no content-length, because the body does not end; no `connection: close`,
/// which every other response in this server carries.
pub fn head(out: []u8) []u8 {
    const h = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: no-store\r\nconnection: keep-alive\r\n\r\n";
    if (out.len < h.len) return out[0..0];
    @memcpy(out[0..h.len], h);
    return out[0..h.len];
}

fn enumName(comptime E: type, v: u8) []const u8 {
    const e = messages.enumFromInt(E, v) orelse return "unknown";
    return @tagName(e);
}

fn kindName(v: u8) []const u8 {
    return enumName(arbiter.Statement.Kind, v);
}

fn sourceName(v: u8) []const u8 {
    return enumName(messages.Applied.Source, v);
}

/// one event: `data: {...}` and the blank line that ends it.
///
/// `extra_age_ms` is the staleness this hop adds on top of the age the renderer stamped, the same
/// accumulation `/status` does for `sample_age_ms`. a mirror running deliberately behind real time
/// uses it to place the statement at the instant it actually happened.
pub fn event(out: []u8, a: messages.Applied, extra_age_ms: u32) []u8 {
    var n: usize = 0;
    const w = struct {
        fn add(buf: []u8, at: *usize, s: []const u8) bool {
            if (at.* + s.len > buf.len) return false;
            @memcpy(buf[at.*..][0..s.len], s);
            at.* += s.len;
            return true;
        }
        fn fmt(buf: []u8, at: *usize, comptime f: []const u8, args: anytype) bool {
            const r = std.fmt.bufPrint(buf[at.*..], f, args) catch return false;
            at.* += r.len;
            return true;
        }
        /// json string escaping, matching the rest of the api: quotes, backslash, control bytes
        fn str(buf: []u8, at: *usize, s: []const u8) bool {
            if (!add(buf, at, "\"")) return false;
            for (s) |c| {
                const ok = switch (c) {
                    '"' => add(buf, at, "\\\""),
                    '\\' => add(buf, at, "\\\\"),
                    0...0x1f => fmt(buf, at, "\\u{x:0>4}", .{c}),
                    else => add(buf, at, &[1]u8{c}),
                };
                if (!ok) return false;
            }
            return add(buf, at, "\"");
        }
    };

    const age = a.age_ms +| extra_age_ms;
    if (!w.fmt(out, &n, "data: {{\"revision\":{d},\"age_ms\":{d},\"cmd\":\"{s}\",\"source\":\"{s}\"", .{ a.revision, age, kindName(a.kind), sourceName(a.source) })) return out[0..0];

    const kind = messages.enumFromInt(arbiter.Statement.Kind, a.kind) orelse .overlay_expired;
    const ok = switch (kind) {
        .set_base => w.fmt(out, &n, ",\"base\":\"{s}\"", .{enumName(arbiter.Base, a.base)}),
        .select_generator => w.fmt(out, &n, ",\"generator\":\"{s}\"", .{enumName(scene.Generator, a.generator)}),
        .notify => blk: {
            if (!w.add(out, &n, ",\"text\":")) break :blk false;
            if (!w.str(out, &n, a.textSlice())) break :blk false;
            break :blk w.fmt(out, &n, ",\"colour\":\"{x:0>2}{x:0>2}{x:0>2}\",\"duration_s\":{d}", .{ a.colour[0], a.colour[1], a.colour[2], a.duration_s });
        },
        .raw => w.fmt(out, &n, ",\"duration_s\":{d}", .{a.duration_s}),
        .brightness => w.fmt(out, &n, ",\"brightness\":{d}", .{a.brightness}),
        .reseed => w.fmt(out, &n, ",\"seed\":{d}", .{a.seed}),
        .power => w.fmt(out, &n, ",\"power\":{}", .{a.power != 0}),
        .set_ip_mode => w.fmt(out, &n, ",\"ip_mode\":\"{s}\"", .{enumName(ip.Mode, a.ip_mode)}),
        .set_clock_style => w.fmt(out, &n, ",\"clock\":{{\"font\":\"{s}\",\"colour_mode\":\"{s}\",\"colour\":\"{x:0>2}{x:0>2}{x:0>2}\",\"colour2\":\"{x:0>2}{x:0>2}{x:0>2}\",\"gradient\":\"{s}\",\"spread\":{d},\"digits\":\"{s}\"}}", .{
            enumName(clock.Font, a.style.font),
            enumName(clock.ColourMode, a.style.mode),
            a.style.colour[0],
            a.style.colour[1],
            a.style.colour[2],
            a.style.colour2[0],
            a.style.colour2[1],
            a.style.colour2[2],
            enumName(clock.Gradient, a.style.gradient),
            a.style.spread,
            enumName(clock.DigitStyle, a.style.digit),
        }),
        // these carry nothing beyond the revision and the fact that they happened
        .arm_stream, .overlay_expired => true,
    };
    if (!ok) return out[0..0];
    if (!w.add(out, &n, "}\n\n")) return out[0..0];
    return out[0..n];
}

/// the largest event this module can produce, so a caller can size a buffer that never truncates.
/// the notification statement is the big one: 128 bytes of text, every byte of which can escape to
/// six (`\u001f`), plus the envelope.
pub const event_max = 256 + 6 * arbiter.Statement.text_max;

const testing = std.testing;

test "the head is an event stream, and says none of the things a normal response says" {
    var buf: [256]u8 = undefined;
    const h = head(&buf);
    try testing.expect(std.mem.indexOf(u8, h, "content-type: text/event-stream") != null);
    // the two that would end the stream: a length it cannot know, and a close it must not do
    try testing.expect(std.mem.indexOf(u8, h, "content-length") == null);
    try testing.expect(std.mem.indexOf(u8, h, "connection: close") == null);
    try testing.expect(std.mem.endsWith(u8, h, "\r\n\r\n"));
}

test "a base selection names the base it landed on" {
    var buf: [event_max]u8 = undefined;
    const a = messages.Applied.init(.{ .kind = .set_base, .revision = 24, .base = .clock }, .input, 12);
    try testing.expectEqualStrings(
        "data: {\"revision\":24,\"age_ms\":12,\"cmd\":\"set_base\",\"source\":\"input\",\"base\":\"clock\"}\n\n",
        event(&buf, a, 0),
    );
}

test "each hop adds its own staleness, so the age is the age at the client" {
    var buf: [event_max]u8 = undefined;
    const a = messages.Applied.init(.{ .kind = .arm_stream, .revision = 3 }, .api, 40);
    try testing.expectEqualStrings(
        "data: {\"revision\":3,\"age_ms\":57,\"cmd\":\"arm_stream\",\"source\":\"api\"}\n\n",
        event(&buf, a, 17),
    );
}

test "a reseed publishes the seed the arbiter took, which is the whole point" {
    var buf: [event_max]u8 = undefined;
    const a = messages.Applied.init(.{ .kind = .reseed, .revision = 8, .seed = 2847113904 }, .input, 0);
    try testing.expect(std.mem.indexOf(u8, event(&buf, a, 0), "\"seed\":2847113904") != null);
}

test "a notification carries its text, escaped like the rest of the api" {
    var buf: [event_max]u8 = undefined;
    var st = arbiter.Statement{ .kind = .notify, .revision = 5, .colour = .{ 0x11, 0x22, 0x33 }, .duration_s = 9 };
    const text = "say \"hi\"\x01";
    st.text_len = text.len;
    @memcpy(st.text[0..text.len], text);
    const out = event(&buf, messages.Applied.init(st, .ntfy, 0), 0);
    try testing.expect(std.mem.indexOf(u8, out, "\"text\":\"say \\\"hi\\\"\\u0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"colour\":\"112233\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"duration_s\":9") != null);
}

test "an overlay expiring is an event with nothing but its revision" {
    var buf: [event_max]u8 = undefined;
    const a = messages.Applied.init(.{ .kind = .overlay_expired, .revision = 77 }, .local, 0);
    try testing.expectEqualStrings(
        "data: {\"revision\":77,\"age_ms\":0,\"cmd\":\"overlay_expired\",\"source\":\"local\"}\n\n",
        event(&buf, a, 0),
    );
}

test "a buffer too small yields nothing at all, never half a statement" {
    // a mirror that sees a gap resyncs; one that parses half an event does not know it should
    var small: [40]u8 = undefined;
    const a = messages.Applied.init(.{ .kind = .set_base, .revision = 1, .base = .art }, .api, 0);
    try testing.expectEqual(@as(usize, 0), event(&small, a, 0).len);

    // and the declared bound really does hold the worst case: 128 text bytes that all escape
    var st = arbiter.Statement{ .kind = .notify, .revision = 4294967295, .duration_s = 65535 };
    st.text_len = arbiter.Statement.text_max;
    @memset(st.text[0..st.text_len], 0x01);
    var big: [event_max]u8 = undefined;
    try testing.expect(event(&big, messages.Applied.init(st, .api, 4294967295), 4294967295).len > 0);
}

test "the clock style publishes the resolved style, not the patch that asked for it" {
    var buf: [event_max]u8 = undefined;
    var st = arbiter.Statement{ .kind = .set_clock_style, .revision = 2 };
    st.style = .{ .font = .mini };
    const out = event(&buf, messages.Applied.init(st, .api, 0), 0);
    try testing.expect(std.mem.indexOf(u8, out, "\"font\":\"mini\"") != null);
    // every field is present even though the request named one: a mirror sets the whole style
    try testing.expect(std.mem.indexOf(u8, out, "\"gradient\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"digits\":") != null);
}
