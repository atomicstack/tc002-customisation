//! typed payloads for the renderer <-> supervisor channel, as one tagged union with fixed-size
//! big-endian encodings, plus the dedup-relevant result status.
const std = @import("std");
const codec = @import("codec.zig");
const geometry = @import("../panel/geometry.zig");
const transition = @import("../panel/transition.zig");
const config = @import("../supervisor/config.zig");
const api = @import("../net/api.zig");
const clock = @import("../scene/clock.zig");
const clockfont = @import("../scene/clockfont.zig");
const ip = @import("../scene/ip.zig");
const canvas = @import("../scene/canvas.zig");
const store = @import("../berry/store.zig");

test "every message kind round-trips through a packet" {
    var frame = Frame{ .duration_s = 9, .rgb = geometry.black_rgb };
    frame.rgb[2495] = 0x5a;
    var doc = canvas.Document{};
    const span = doc.addText("living room") catch unreachable;
    doc.add(.{ .id = canvas.Id.init("hdr"), .box = .{ .x = 1, .y = 2, .w = 50, .h = 6 }, .colour = .{ 9, 8, 7 }, .body = .{ .text = .{ .span = span, .face = .mini, .alignment = .centre } } }) catch unreachable;
    var patch = canvas.Patch{};
    patch.add(.{ .id = canvas.Id.init("hdr"), .has = canvas.Field.colour, .colour = .{ 1, 2, 3 } }) catch unreachable;
    const all = [_]Message{
        .{ .canvas = CanvasView{ .doc = doc, .doc_age_ms = 1234, .element_age_ms = [_]u32{777} ++ [_]u32{0} ** (canvas.max_elements - 1) } },
        .canvas_get,
        .{ .canvas_patch = patch },
        .canvas_clear,
        .{ .canvas_error = .{ .reason = CanvasError.wrong_field } },
        .{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } },
        .ready,
        .{ .result = .{ .status = .applied, .revision = 41 } },
        .{ .set_base = .{ .base = 1, .generator = 1, .seed = 0xdeadbeef } },
        .{ .set_base = .{ .base = 1, .generator = 0, .seed = 0, .style = .{ .has = 0x3f, .font = 3, .mode = 1, .colour = .{ 1, 2, 3 }, .colour2 = .{ 4, 5, 6 }, .gradient = 2, .spread = 90 } } },
        .{ .clock_style = ClockStyle.fromPatch(.{ .font = .segment, .colour = .{ 9, 9, 9 } }) },
        .{ .heartbeat = .{ .presented = 1, .revision = 2, .state = 1, .clock = ClockStyle.full(.{ .font = .mini, .mode = .gradient }), .seed = 0xfeedface } },
        .{ .notify = Notify.init("hello, panel", .{ 1, 2, 3 }, 30, .{}) },
        .{ .notify = Notify.init("bye", .{ 1, 2, 3 }, 2, .{ .has = 1, .effect = 4, .direction = 1, .duration_ms = 250, .exit = 1 }) },
        .{ .frame = frame },
        .{ .frame = .{ .duration_s = 1, .transition = .{ .has = 1, .effect = 6, .direction = 3, .duration_ms = 5000 }, .rgb = geometry.black_rgb } },
        .{ .set_base = .{ .base = 0, .generator = 1, .seed = 1, .transition = .{ .has = 1, .effect = 2, .direction = 2, .duration_ms = 40 } } },
        .{ .brightness = .{ .value = 55 } },
        .{ .reseed = .{ .seed = 12 } },
        .arm_stream,
        .time_corrected,
        .{ .ip_changed = .{ .present = 1, .addr = .{ 10, 0, 0, 111 } } },
        .stop,
        .{ .set_timezone = config.Text.init("JST-9") },
        .screen_get,
        .{ .screen = .{ .revision = 9, .brightness = 60, .power = 1, .rgb = frame.rgb } },
        .{ .input = .{ .control = 4, .event = 5, .position = -3 } },
        .{ .inject_input = .{ .control = 3, .event = 2, .steps = 1 } },
        .{ .power = .{ .on = 0 } },
        .{ .log_get = .{ .after = 41 } },
        .{ .log_lines = blk: {
            var l = LogLines{ .next = 44 };
            try std.testing.expect(l.add(42, "tc002d 12 info first"));
            try std.testing.expect(l.add(43, ""));
            break :blk l;
        } },
        .{ .credentials = .{ .control = [_]u8{0x11} ** 32, .admin = [_]u8{0x22} ** 32 } },
        .{ .config = blk: {
            var c = config.Config{};
            try c.patch(.{ .brightness = 9, .timezone = "JST-9", .ntp_server = .{ 1, 2, 3, 4 } });
            break :blk c;
        } },
        .config_get,
        .{ .config_patch = try ConfigPatch.fromApi(.{ .brightness = 3, .timezone = "UTC0", .expected_revision = 5 }) },
        .{ .config_patch = try ConfigPatch.fromApi(.{ .night = true, .night_brightness = 5, .night_lead_min = 60, .location = .{ .lat_c = -3387, .lon_c = 15122 }, .clock_font = .big, .clock_colour_mode = .gradient, .clock_colour = .{ 1, 2, 3 }, .clock_colour2 = .{ 7, 8, 9 }, .clock_gradient = .vertical, .clock_spread = 128, .clock_digit = .shadow, .ip_mode = .big }) },
        .{ .ip_mode = .{ .mode = 2 } },
        .{ .set_base = .{ .base = 2, .generator = 0, .seed = 0 } },
        .{ .config_save = .{ .has_revision = 1, .revision = 6 } },
        .{ .save_result = .{ .status = .conflict, .saved_revision = 5 } },
        .{ .mqtt_put = try MqttPut.fromApi(.{ .host = "10.0.0.2", .password = "Pw", .enabled = true }) },
        .{ .ntfy_put = try NtfyPut.fromApi(.{ .url = "https://ntfy.sh", .topic = "t", .enabled = true, .ca = "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n" }) },
        .{ .ntfy_put = try NtfyPut.fromApi(.{ .duration_s = 30, .insecure = true, .ca = "" }) },
        .{ .ntfy_config = blk: {
            var nc = NtfyConfig{ .ntfy = .{ .enabled = true, .url = config.Text.init("http://10.0.0.5:8080"), .topic = config.Text.init("door"), .token = config.Text.init("tk"), .duration_s = 5 } };
            const pem = "-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n";
            nc.ca_len = pem.len;
            @memcpy(nc.ca[0..pem.len], pem);
            break :blk nc;
        } },
        .{ .ntfy_status = .{ .state = 2, .messages = 9, .err = config.Text.init("dns failed") } },
        .{ .berry_config = .{ .heap_kb = 64, .handler_ms = 250 } },
        .{ .berry_status = .{ .heap_bytes = 65536, .heap_used = 8488, .heap_high_water = 9000, .alloc_failures = 2, .stops = 1 } },
        .{ .berry_script = BerryScript.init(.put, "autoexec", "print('boot')") },
        .{ .berry_script = BerryScript.init(.delete, "rules", "") },
        .{ .berry_result = .{ .outcome = 1, .name = store.Name.init("broken"), .text = config.Text.init("unexpected token") } },
        .berry_list_get,
        .{ .berry_event = BerryEvent.init(.mqtt, "home/doorbell", "pressed") },
        .{ .berry_event = BerryEvent.init(.subscribe, "home/+/state", "") },
        .{ .stream_frame = .{ .seq = 12345, .timeout_ms = 250, .rgb = geometry.black_rgb } },
        .{ .menu_request = .{ .kind = @intFromEnum(MenuRequest.Kind.brightness), .value = 70 } },
        .{ .menu_request = .{ .kind = @intFromEnum(MenuRequest.Kind.reboot) } },
        .{ .set_param = .{ .base = 1, .index = 3, .value = 0xff8000 } },
        .{ .device_status = .{ .battery_pct = 80, .usb = 1, .wifi_quality = 49, .wifi_dbm = -61, .time_synced = 1, .mqtt_on = 1, .uptime_s = 90061 } },
        .status_get,
        .{ .status = .{ .renderer_state = 2, .epoch = 3, .revision = 4, .presented = 5, .base = 1, .brightness = 77, .uptime_s = 8, .mem_available_kb = 14000, .cpu_pct = 12, .fps_x10 = 599, .ip_present = 1, .ip = .{ 10, 0, 0, 111 }, .config_revision = 2, .saved_revision = 1, .boot_id = 0xabcd, .sample_age_ms = 40, .mac = .{ 1, 2, 3, 4, 5, 6 }, .mac_present = 1, .load_1m_x100 = 123, .mem_free_kb = 4000, .wifi_level_dbm = -61, .wifi_quality = 49, .cpu_renderer_pct_x10 = 87, .tmpfs_used_kb = 1300, .battery_mv = 3987, .battery_pct = 80, .usb_present = 1, .clock = ClockStyle.full(.{ .font = .segment }), .mem_total_kb = 36240, .tmpfs_total_kb = 16504, .flash_total_kb = 8192, .flash_used_kb = 368, .night_phase = 2, .night_override = 1, .seed = 0xc0ffee, .menu = 1, .menu_item = 6, .menu_state = 1, .net_rx_bytes = 525283638, .net_tx_bytes = 48021332, .net_rx_packets = 2277879, .net_tx_packets = 295533, .net_rx_errors = 0, .net_rx_dropped = 1339872, .net_tx_errors = 0, .net_tx_dropped = 0, .net_rx_bps = 2033, .net_tx_bps = 236, .mem_cached_kb = 11772, .mem_dirty_kb = 0, .mem_writeback_kb = 0, .mem_slab_kb = 8528, .saves = 91, .save_failures = 0, .save_bytes = 40131, .save_last_ms = 12, .berry_state = 2, .berry = .{ .heap_bytes = 65536, .heap_used = 8488, .heap_high_water = 9001, .alloc_failures = 0, .stops = 3 } } },
    };
    var buf: [codec.max_message]u8 = undefined;
    for (all) |m| {
        const packet = try encodePacket(m, 0x0102030405060708, 3, &buf);
        const p = try decodePacket(packet);
        try std.testing.expectEqual(@as(u64, 0x0102030405060708), p.request_id);
        try std.testing.expectEqual(@as(u32, 3), p.epoch);
        try std.testing.expectEqualDeep(m, p.message);
    }
}

test "fixed hex vectors" {
    var buf: [codec.max_message]u8 = undefined;
    // the tail is the v7 seed (four bytes) then the three v8 menu bytes; the length went
    // 0x1f -> 0x22 when the menu arrived and 0x22 -> 0x26 when the seed did
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 0x1122334455667788, .revision = 7, .state = 2 } }, 1, 2, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "01" ++ "0000" ++ "0000000000000001" ++ "00000002" ++ "0026" ++ "0000" ++ "1122334455667788" ++ "00000007" ++ "02" ++ "00000000" ++ "01" ++ "0000" ++ "00" ++ "ffffff" ++ "ffffff" ++ "00" ++ "ff" ++ "00" ++ "00" ++ "00000000" ++ "00" ++ "00" ++ "00"), hb);
    const hb_seeded = try encodePacket(.{ .heartbeat = .{ .presented = 0, .revision = 0, .state = 0, .seed = 0xdeadbeef } }, 0, 0, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("deadbeef" ++ "00" ++ "00" ++ "00"), hb_seeded[hb_seeded.len - 7 ..]);
    const st = try encodePacket(.stop, 0, 9, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "18" ++ "0000" ++ "0000000000000000" ++ "00000009" ++ "0000" ++ "0000"), st);
    const nt = try encodePacket(.{ .notify = Notify.init("hi", .{ 0xff, 0x80, 0x00 }, 300, .{ .has = 1, .effect = 7, .direction = 3, .duration_ms = 300 }) }, 0, 0, &buf);
    try std.testing.expectEqualSlices(u8, &unhex("54434931" ++ "01" ++ "11" ++ "0000" ++ "0000000000000000" ++ "00000000" ++ "000e" ++ "0000" ++ "ff8000" ++ "012c" ++ "01" ++ "07" ++ "03" ++ "012c" ++ "00" ++ "02" ++ "6869"), nt);
    const fr = try encodePacket(.{ .frame = .{ .duration_s = 1, .rgb = geometry.black_rgb } }, 0, 0, &buf);
    try std.testing.expectEqual(@as(usize, codec.header_len + 2 + Transition.wire_len + geometry.rgb_bytes), fr.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Kind.frame)), fr[5]);
}

test "berry settings survive the ipc patch, which has its own field list and drops what it does not know" {
    const w = try ConfigPatch.fromApi(.{ .berry_enabled = true, .berry_heap_kb = 64, .berry_handler_ms = 120 });
    const a = w.toApi();
    try std.testing.expectEqual(@as(?bool, true), a.berry_enabled);
    try std.testing.expectEqual(@as(?u16, 64), a.berry_heap_kb);
    try std.testing.expectEqual(@as(?u16, 120), a.berry_handler_ms);
    // and over the wire, which is the half that silently dropped them
    var buf: [codec.max_message]u8 = undefined;
    const packet = try encodePacket(.{ .config_patch = w }, 7, 0, &buf);
    const back = try decodePacket(packet);
    const b = back.message.config_patch.toApi();
    try std.testing.expectEqual(@as(?bool, true), b.berry_enabled);
    try std.testing.expectEqual(@as(?u16, 64), b.berry_heap_kb);
    try std.testing.expectEqual(@as(?u16, 120), b.berry_handler_ms);
    // a patch that says nothing about berry must not assert defaults over what is configured
    const quiet = (try ConfigPatch.fromApi(.{ .brightness = 5 })).toApi();
    try std.testing.expect(quiet.berry_enabled == null);
    try std.testing.expect(quiet.berry_heap_kb == null);
    try std.testing.expect(quiet.berry_handler_ms == null);
}

test "patch wire forms map back to the api view" {
    const w = try ConfigPatch.fromApi(.{ .brightness = 3, .timezone = "JST-9", .ntp_server = .{ 9, 9, 9, 9 }, .clock_font = .mini, .clock_colour = .{ 5, 6, 7 }, .night = true, .night_brightness = 9, .night_lead_min = 45, .location = .{ .lat_c = -3387, .lon_c = 15122 } });
    const a = w.toApi();
    try std.testing.expectEqual(@as(?bool, true), a.night);
    try std.testing.expectEqual(@as(?u8, 9), a.night_brightness);
    try std.testing.expectEqual(@as(?u8, 45), a.night_lead_min);
    try std.testing.expectEqual(@as(i16, 15122), a.location.?.lon_c);
    try std.testing.expectEqual(@as(?bool, null), a.location_auto);
    // dropping a pinned location travels as its own flag, with no coordinates to carry
    const auto = (try ConfigPatch.fromApi(.{ .location_auto = true })).toApi();
    try std.testing.expectEqual(@as(?bool, true), auto.location_auto);
    try std.testing.expect(auto.location == null);
    try std.testing.expectEqual(@as(?clock.Font, .mini), a.clock_font);
    try std.testing.expectEqual([3]u8{ 5, 6, 7 }, a.clock_colour.?);
    try std.testing.expectEqual(@as(?clock.Gradient, null), a.clock_gradient);
    const sp = ClockStyle.fromPatch(.{ .mode = .gradient, .colour2 = .{ 1, 1, 1 } }).toPatch();
    try std.testing.expectEqual(@as(?clock.Font, null), sp.font);
    try std.testing.expectEqual(@as(?clock.ColourMode, .gradient), sp.mode);
    try std.testing.expectEqual([3]u8{ 1, 1, 1 }, sp.colour2.?);
    try std.testing.expectEqual(ClockStyle.F.all, ClockStyle.full(.{}).has); // every field, digits included
    try std.testing.expectEqual(@as(?u8, 40), ClockStyle.fromPatch(.{ .spread = 40 }).toPatch().spread);
    try std.testing.expectEqual(@as(?u8, 3), a.brightness);
    try std.testing.expectEqualStrings("JST-9", a.timezone.?);
    try std.testing.expectEqual([4]u8{ 9, 9, 9, 9 }, a.ntp_server.?);
    try std.testing.expectEqual(@as(?u32, null), a.expected_revision);
    try std.testing.expectEqual(@as(?bool, null), a.discovery);
    const m = try MqttPut.fromApi(.{ .host = "10.0.0.2", .tls = false });
    const ma = m.toApi();
    try std.testing.expectEqualStrings("10.0.0.2", ma.host.?);
    try std.testing.expectEqual(@as(?bool, false), ma.tls);
    try std.testing.expectEqual(@as(?[]const u8, null), ma.password);
}

test "transition blocks map to specs and back, unknown values to the default" {
    try std.testing.expect(Transition.fromSpec(null).toSpec() == null);
    const spec = transition.Spec{ .effect = .split_in, .direction = .up, .duration_ns = 1_250_000_000, .exit = .same };
    try std.testing.expectEqual(spec, Transition.fromSpec(spec).toSpec().?);
    try std.testing.expect((Transition{ .has = 1, .effect = 200 }).toSpec() == null);
    try std.testing.expect((Transition{ .has = 1, .exit = 9 }).toSpec() == null);
    try std.testing.expectEqual(transition.Effect.cut, Transition.fromSpec(transition.Spec.cut).toSpec().?.effect);
}

test "malformed payloads are rejected" {
    var buf: [codec.max_message]u8 = undefined;
    var src: [codec.max_message]u8 = undefined;
    const hb = try encodePacket(.{ .heartbeat = .{ .presented = 1, .revision = 1, .state = 1 } }, 0, 0, &src);
    const short = try codec.encode(.{ .kind = @intFromEnum(Kind.heartbeat), .request_id = 0, .epoch = 0, .payload_len = 12 }, hb[codec.header_len .. codec.header_len + 12], &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short));
    const unknown = try codec.encode(.{ .kind = 200, .request_id = 0, .epoch = 0, .payload_len = 0 }, "", &buf);
    try std.testing.expectError(error.UnknownKind, decodePacket(unknown));
    // a notify claiming 200 text bytes
    const long_notify = try codec.encode(.{ .kind = @intFromEnum(Kind.notify), .request_id = 0, .epoch = 0, .payload_len = 6 + 200 }, &([_]u8{ 0, 0, 0, 0, 5, 200 } ++ [_]u8{'a'} ** 200), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(long_notify));
    // a frame one byte short
    const short_frame = try codec.encode(.{ .kind = @intFromEnum(Kind.frame), .request_id = 0, .epoch = 0, .payload_len = 2497 }, &([_]u8{0} ** 2497), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(short_frame));
    // trailing bytes on a fixed-size message
    const trailing = try codec.encode(.{ .kind = @intFromEnum(Kind.stop), .request_id = 0, .epoch = 0, .payload_len = 1 }, "x", &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(trailing));
    // a log page whose record runs past its data, and one whose count lies
    const overrun = try codec.encode(.{ .kind = @intFromEnum(Kind.log_lines), .request_id = 0, .epoch = 0, .payload_len = 7 + 6 }, &([_]u8{ 0, 0, 0, 2, 1, 0, 6 } ++ [_]u8{ 0, 0, 0, 1, 9, 'a' }), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(overrun));
    const miscount = try codec.encode(.{ .kind = @intFromEnum(Kind.log_lines), .request_id = 0, .epoch = 0, .payload_len = 7 + 6 }, &([_]u8{ 0, 0, 0, 2, 2, 0, 6 } ++ [_]u8{ 0, 0, 0, 1, 1, 'a' }), &buf);
    try std.testing.expectError(error.BadPayload, decodePacket(miscount));
}

test "log pages iterate their records and refuse to overfill" {
    var l = LogLines{ .next = 0 };
    var i: u32 = 0;
    while (l.add(i, "x" ** log_line_max)) : (i += 1) {}
    try std.testing.expectEqual(@as(u32, log_lines_per_reply), i);
    try std.testing.expectEqual(@as(u16, log_data_max), l.len);
    var it = l.iterator();
    var n: u32 = 0;
    while (it.next()) |r| : (n += 1) {
        try std.testing.expectEqual(n, r.seq);
        try std.testing.expectEqual(@as(usize, log_line_max), r.text.len);
    }
    try std.testing.expectEqual(@as(u32, log_lines_per_reply), n);
    var short = LogLines{ .next = 0 };
    try std.testing.expect(short.add(7, "x" ** 200)); // truncated to the line maximum
    var sit = short.iterator();
    try std.testing.expectEqual(@as(usize, log_line_max), sit.next().?.text.len);
}

fn unhex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

pub const Kind = enum(u8) {
    heartbeat = 1,
    ready = 2,
    result = 3,
    set_base = 16,
    notify = 17,
    frame = 18,
    brightness = 19,
    reseed = 20,
    arm_stream = 21,
    time_corrected = 22,
    ip_changed = 23,
    stop = 24,
    set_timezone = 25,
    screen_get = 26,
    screen = 27,
    input = 28,
    inject_input = 29,
    power = 30,
    log_get = 41,
    log_lines = 42,
    clock_style = 43,
    ip_mode = 44,
    // supervisor <-> netd
    credentials = 32,
    config = 33,
    config_get = 34,
    config_patch = 35,
    config_save = 36,
    save_result = 37,
    mqtt_put = 38,
    status_get = 39,
    status = 40,
    // supervisor <-> netd (ntfy settings) and supervisor <-> the ntfy subscriber
    ntfy_put = 45,
    ntfy_config = 46,
    ntfy_status = 47,
    // the on-device settings menu: the renderer asks, the supervisor answers with a push
    menu_request = 48,
    device_status = 49,
    set_param = 50,
    // the canvas: netd puts, patches and clears; the supervisor keeps the document and pushes it
    // to the renderer, and answers a get from its own copy
    canvas = 51,
    canvas_get = 52,
    canvas_patch = 53,
    canvas_clear = 54,
    canvas_error = 55,
    sprite = 56,
    sprite_delete = 57,
    sprite_list_get = 58,
    sprite_list = 59,
    // the script interpreter: the supervisor hands it its settings, it reports what its heap is
    // doing and whether it has had to stop anything
    berry_config = 60,
    berry_status = 61,
    // scripts: netd puts and deletes, the supervisor keeps the store and hands each one to berryd,
    // which compiles it and says whether it took
    berry_script = 62,
    berry_result = 63,
    berry_list_get = 64,
    berry_scripts = 65,
    /// anything that happens *to* a script, and the two things a script asks of the broker. one
    /// kind rather than six: they all carry a topic-shaped string and a payload-shaped one.
    berry_event = 66,
    /// a frame in a stream. deliberately not `frame`: that one is a discrete command and passes
    /// through the renderer's deduplication window, which holds 128 ids for sixty seconds and so
    /// caps discrete commands at about two a second. a stream frame is idempotent -- the last one
    /// wins and a lost one is simply a lost frame -- so there is nothing for dedup to protect, and
    /// it is carried outside it.
    stream_frame = 67,
};

/// what the supervisor tells a fresh berryd about itself. the settings are the supervisor's, so
/// berryd never reads a file and never has to agree with anyone about defaults.
pub const BerryConfig = struct {
    heap_kb: u16 = 256,
    handler_ms: u16 = 100,

    pub const wire_len = 2 + 2;

    fn put(self: *const BerryConfig, out: []u8) void {
        std.mem.writeInt(u16, out[0..2], self.heap_kb, .little);
        std.mem.writeInt(u16, out[2..4], self.handler_ms, .little);
    }

    fn get(b: []const u8) BerryConfig {
        return .{
            .heap_kb = std.mem.readInt(u16, b[0..2], .little),
            .handler_ms = std.mem.readInt(u16, b[2..4], .little),
        };
    }
};

/// what berryd reports, which is also what `/status` carries. it doubles as the liveness ping:
/// a script spinning forever leaves the process alive and silent, so silence is the signal.
pub const BerryStatus = struct {
    heap_bytes: u32 = 0,
    heap_used: u32 = 0,
    heap_high_water: u32 = 0,
    alloc_failures: u32 = 0,
    /// scripts stopped for outstaying the handler deadline
    stops: u32 = 0,

    pub const wire_len = 5 * 4;

    fn put(self: *const BerryStatus, out: []u8) void {
        std.mem.writeInt(u32, out[0..4], self.heap_bytes, .little);
        std.mem.writeInt(u32, out[4..8], self.heap_used, .little);
        std.mem.writeInt(u32, out[8..12], self.heap_high_water, .little);
        std.mem.writeInt(u32, out[12..16], self.alloc_failures, .little);
        std.mem.writeInt(u32, out[16..20], self.stops, .little);
    }

    fn get(b: []const u8) BerryStatus {
        return .{
            .heap_bytes = std.mem.readInt(u32, b[0..4], .little),
            .heap_used = std.mem.readInt(u32, b[4..8], .little),
            .heap_high_water = std.mem.readInt(u32, b[8..12], .little),
            .alloc_failures = std.mem.readInt(u32, b[12..16], .little),
            .stops = std.mem.readInt(u32, b[16..20], .little),
        };
    }
};

/// one frame of a stream. the sequence number is what lets the renderer say how many it dropped or
/// coalesced rather than leaving everyone to guess.
pub const StreamFrame = struct {
    seq: u32 = 0,
    /// how long this frame stands if no other arrives. the supervisor fills it from
    /// `frame_timeout_ms`, so the deadman travels with the frame and needs no arming handshake to
    /// be correct: a script that dies mid-animation leaves a panel that clears itself.
    timeout_ms: u16 = 500,
    rgb: geometry.Rgb = geometry.black_rgb,

    pub const wire_len = 4 + 2 + geometry.rgb_bytes;
};

/// an event for a script, or a request from one. it travels in both directions because the shapes
/// are the same in both: something happened on a topic, or a script wants something to.
pub const BerryEvent = struct {
    /// named Op rather than Kind because this file's top-level Kind is the message kind, and two
    /// of those in scope is one too many
    pub const Op = enum(u8) {
        /// netd -> supervisor -> berryd: a message arrived on a subscribed topic
        mqtt = 0,
        /// supervisor -> berryd: an ntfy notification arrived
        ntfy = 1,
        /// berryd -> supervisor -> netd: subscribe to this topic from now on
        subscribe = 2,
        /// berryd -> supervisor -> netd: publish this
        publish = 3,
    };

    /// as many topics as a device may subscribe to on a script's behalf. eight is not a physical
    /// bound; it is the point past which a clock is doing something a clock should not.
    pub const topic_max = 96;
    pub const payload_max = 256;

    kind: u8 = 0,
    topic_len: u8 = 0,
    topic: [topic_max]u8 = [_]u8{0} ** topic_max,
    payload_len: u16 = 0,
    payload: [payload_max]u8 = [_]u8{0} ** payload_max,

    pub const wire_len = 1 + 1 + topic_max + 2 + payload_max;

    pub fn init(op: Op, topic: []const u8, payload: []const u8) BerryEvent {
        var e = BerryEvent{ .kind = @intFromEnum(op) };
        e.topic_len = @intCast(@min(topic.len, topic_max));
        @memcpy(e.topic[0..e.topic_len], topic[0..e.topic_len]);
        e.payload_len = @intCast(@min(payload.len, payload_max));
        @memcpy(e.payload[0..e.payload_len], payload[0..e.payload_len]);
        return e;
    }

    pub fn topicSlice(self: *const BerryEvent) []const u8 {
        return self.topic[0..self.topic_len];
    }

    pub fn payloadSlice(self: *const BerryEvent) []const u8 {
        return self.payload[0..self.payload_len];
    }

    fn put(self: *const BerryEvent, out: []u8) void {
        out[0] = self.kind;
        out[1] = self.topic_len;
        @memcpy(out[2..][0..topic_max], &self.topic);
        std.mem.writeInt(u16, out[2 + topic_max ..][0..2], self.payload_len, .little);
        @memcpy(out[4 + topic_max ..][0..payload_max], &self.payload);
    }

    fn get(b: []const u8) BerryEvent {
        var e = BerryEvent{ .kind = b[0], .topic_len = @min(b[1], topic_max) };
        @memcpy(&e.topic, b[2..][0..topic_max]);
        e.payload_len = @min(std.mem.readInt(u16, b[2 + topic_max ..][0..2], .little), payload_max);
        @memcpy(&e.payload, b[4 + topic_max ..][0..payload_max]);
        return e;
    }
};

/// one script travelling: to the supervisor from netd, and on to berryd. the source is inline
/// because it has to arrive whole -- there is no chunking here, for the same reason canvas
/// documents have none: half a script is worse than a refused one.
pub const BerryScript = struct {
    pub const Op = enum(u8) { put = 0, delete = 1, eval = 2, reload = 3 };

    op: u8 = 0,
    name: store.Name = .{},
    len: u16 = 0,
    source: [store.script_max]u8 = undefined,

    pub const fixed_len = 1 + 1 + store.name_max + 2;
    pub const wire_len = fixed_len + store.script_max;

    pub fn init(op: Op, name: []const u8, source: []const u8) BerryScript {
        var b = BerryScript{ .op = @intFromEnum(op), .name = store.Name.init(name) };
        b.len = @intCast(@min(source.len, store.script_max));
        @memcpy(b.source[0..b.len], source[0..b.len]);
        return b;
    }

    pub fn slice(self: *const BerryScript) []const u8 {
        return self.source[0..self.len];
    }
};

/// whether a script took, and what berry said when it did not
pub const BerryResult = struct {
    /// 0 ok, 1 would not compile, 2 raised while running, 3 refused (no space, bad name)
    outcome: u8 = 0,
    name: store.Name = .{},
    text: config.Text = .{},

    pub const wire_len = 1 + 1 + store.name_max + 1 + config.text_max;
};

/// the listing `GET /berry/scripts` answers from, plus what the store has room for
pub const BerryScripts = struct {
    pub const Entry = struct { name: store.Name = .{}, bytes: u16 = 0, compiled: u8 = 0 };
    pub const max = 32;

    used: u32 = 0,
    budget: u32 = 0,
    count: u8 = 0,
    items: [max]Entry = [_]Entry{.{}} ** max,

    pub const wire_len = 4 + 4 + 1 + max * (1 + store.name_max + 2 + 1);
};

/// what the device is holding, for `GET /sprites`: ids and sizes, not the pixels
pub const SpriteList = struct {
    pub const Entry = struct { id: canvas.Id = .{}, w: u8 = 0, h: u8 = 0 };

    count: u8 = 0,
    items: [canvas.sprite_max]Entry = [_]Entry{.{}} ** canvas.sprite_max,

    pub const wire_len = 1 + canvas.sprite_max * 11;
};

/// why a canvas update was refused, so the client hears which mistake it made rather than a list
/// of the ones it might have
pub const CanvasError = struct {
    reason: u8,

    pub const unknown_element: u8 = 0;
    pub const wrong_field: u8 = 1;
    pub const full: u8 = 2;

    pub fn of(e: canvas.ApplyError) CanvasError {
        return .{ .reason = switch (e) {
            error.UnknownElement => unknown_element,
            error.WrongField => wrong_field,
            error.Full, error.TooLong => full,
        } };
    }
};

comptime {
    // both canvas payloads have to cross the ipc socket whole: chunking a document would cost the
    // atomicity that makes a half-drawn dashboard impossible
    if (canvas.wire_max > codec.max_payload) @compileError("a canvas document does not fit one ipc packet");
    if (canvas.Patch.wire_max > codec.max_payload) @compileError("a canvas patch does not fit one ipc packet");
}

pub const Status = enum(u8) { applied = 0, rejected = 1, overload = 2, stale_epoch = 3, expired = 4, unavailable = 5, timeout = 6, conflict = 7 };

/// `seed` is the art scene's current seed: the console runs the same generators in its preview
/// and cannot reproduce the panel's animation without it.
/// `menu` is 0 when none is open, otherwise its kind plus one; `menu_item` is the device menu's
/// item or the scene menu's entry, and `menu_state` whether it is browsing, adjusting or asking.
/// the renderer is the only thing that knows any of it, and a client driving the panel over
/// `/input` needs to be able to assert what is showing rather than count detents.
pub const Heartbeat = struct { presented: u64, revision: u32, state: u8, base: u8 = 0, generator: u8 = 0, overlay: u8 = 0, brightness: u8 = 0, power: u8 = 1, clock: ClockStyle = .{}, ip_mode: u8 = 0, seed: u32 = 0, menu: u8 = 0, menu_item: u8 = 0, menu_state: u8 = 0 };

/// the clock's style on the wire: a presence mask (for partial updates) and the five fields.
pub const ClockStyle = struct {
    has: u8 = 0,
    font: u8 = 0,
    mode: u8 = 0,
    colour: [3]u8 = .{ 255, 255, 255 },
    colour2: [3]u8 = .{ 255, 255, 255 },
    gradient: u8 = 0,
    spread: u8 = 255,
    digit: u8 = 0,

    pub const F = struct {
        pub const font: u8 = 1 << 0;
        pub const mode: u8 = 1 << 1;
        pub const colour: u8 = 1 << 2;
        pub const colour2: u8 = 1 << 3;
        pub const gradient: u8 = 1 << 4;
        pub const spread: u8 = 1 << 5;
        pub const digit: u8 = 1 << 6;
        pub const all: u8 = 0x7f;
    };

    pub const wire_len = 12;

    pub fn fromPatch(p: clock.StylePatch) ClockStyle {
        var w = ClockStyle{};
        if (p.font) |v| {
            w.has |= F.font;
            w.font = @intFromEnum(v);
        }
        if (p.mode) |v| {
            w.has |= F.mode;
            w.mode = @intFromEnum(v);
        }
        if (p.colour) |v| {
            w.has |= F.colour;
            w.colour = v;
        }
        if (p.colour2) |v| {
            w.has |= F.colour2;
            w.colour2 = v;
        }
        if (p.digit) |v| {
            w.has |= F.digit;
            w.digit = @intFromEnum(v);
        }
        if (p.gradient) |v| {
            w.has |= F.gradient;
            w.gradient = @intFromEnum(v);
        }
        if (p.spread) |v| {
            w.has |= F.spread;
            w.spread = v;
        }
        return w;
    }

    pub fn full(s: clock.Style) ClockStyle {
        return .{ .has = F.all, .font = @intFromEnum(s.font), .mode = @intFromEnum(s.mode), .colour = s.colour, .colour2 = s.colour2, .gradient = @intFromEnum(s.gradient), .spread = s.spread, .digit = @intFromEnum(s.digit) };
    }

    /// the patch view; fields with an unknown enum value are dropped.
    pub fn toPatch(self: ClockStyle) clock.StylePatch {
        const h = self.has;
        return .{
            .font = if (h & F.font != 0) enumFromInt(clock.Font, self.font) else null,
            .mode = if (h & F.mode != 0) enumFromInt(clock.ColourMode, self.mode) else null,
            .colour = if (h & F.colour != 0) self.colour else null,
            .colour2 = if (h & F.colour2 != 0) self.colour2 else null,
            .gradient = if (h & F.gradient != 0) enumFromInt(clock.Gradient, self.gradient) else null,
            .spread = if (h & F.spread != 0) self.spread else null,
            .digit = if (h & F.digit != 0) enumFromInt(clockfont.DigitStyle, self.digit) else null,
        };
    }

    fn put(self: ClockStyle, out: []u8) void {
        out[0] = self.has;
        out[1] = self.font;
        out[2] = self.mode;
        out[3..6].* = self.colour;
        out[6..9].* = self.colour2;
        out[9] = self.gradient;
        out[10] = self.spread;
        out[11] = self.digit;
    }

    fn get(b: []const u8) ClockStyle {
        return .{ .has = b[0], .font = b[1], .mode = b[2], .colour = b[3..6].*, .colour2 = b[6..9].*, .gradient = b[9], .spread = b[10], .digit = b[11] };
    }
};
pub const Result = struct { status: Status, revision: u32 };

/// the renderer's output as shown (after fades, before brightness and the level curve).
pub const Screen = struct { revision: u32, brightness: u8, power: u8, rgb: geometry.Rgb };
/// a physical or injected control event (`input`), or a request to inject one (`inject_input`).
/// control and event are `input/actions.zig` enums on the wire; `steps` only matters for cw/ccw.
pub const Input = struct { control: u8, event: u8, position: i32 = 0, steps: u8 = 1 };
pub const Power = struct { on: u8 };
pub const LogGet = struct { after: u32 };

pub const log_line_max = 160;
pub const log_lines_per_reply = 16;
pub const log_data_max = log_lines_per_reply * (5 + log_line_max);

/// a page of the supervisor's log ring: `count` records of `u32 seq, u8 len, bytes` in `data`.
pub const LogLines = struct {
    next: u32,
    count: u8 = 0,
    len: u16 = 0,
    data: [log_data_max]u8 = undefined,

    pub fn add(self: *LogLines, seq: u32, text: []const u8) bool {
        const n: usize = @min(text.len, log_line_max);
        if (self.count == log_lines_per_reply or @as(usize, self.len) + 5 + n > log_data_max) return false;
        const o: usize = self.len;
        std.mem.writeInt(u32, self.data[o..][0..4], seq, .big);
        self.data[o + 4] = @intCast(n);
        @memcpy(self.data[o + 5 .. o + 5 + n], text[0..n]);
        self.len += @intCast(5 + n);
        self.count += 1;
        return true;
    }

    pub const Record = struct { seq: u32, text: []const u8 };

    /// iterate the records; the layout was validated on decode.
    pub const Iterator = struct {
        lines: *const LogLines,
        off: usize = 0,
        pub fn next(self: *Iterator) ?Record {
            if (self.off + 5 > self.lines.len) return null;
            const d = self.lines.data[self.off..];
            const n = d[4];
            const r = Record{ .seq = std.mem.readInt(u32, d[0..4], .big), .text = d[5 .. 5 + @as(usize, n)] };
            self.off += 5 + @as(usize, n);
            return r;
        }
    };

    pub fn iterator(self: *const LogLines) Iterator {
        return .{ .lines = self };
    }
};
/// a base selection; a present `style` (mask non-zero) also restyles the clock in the same command.
/// an optional transition on a scene change, notification or frame; `has` = 0 means the
/// renderer's default. 6 bytes on the wire: has, effect, direction, duration_ms (big-endian), exit.
pub const Transition = struct {
    has: u8 = 0,
    effect: u8 = 0,
    direction: u8 = 0,
    duration_ms: u16 = 0,
    exit: u8 = 0,

    pub const wire_len = 6;

    pub fn fromSpec(spec: ?transition.Spec) Transition {
        const t = spec orelse return .{};
        return .{ .has = 1, .effect = @intFromEnum(t.effect), .direction = @intFromEnum(t.direction), .duration_ms = @intCast(t.duration_ns / 1_000_000), .exit = @intFromEnum(t.exit) };
    }

    /// null for the default and for values this build does not know
    pub fn toSpec(self: Transition) ?transition.Spec {
        if (self.has == 0) return null;
        const effect = enumFromInt(transition.Effect, self.effect) orelse return null;
        const direction = enumFromInt(transition.Direction, self.direction) orelse return null;
        const exit = enumFromInt(transition.Exit, self.exit) orelse return null;
        return .{ .effect = effect, .direction = direction, .duration_ns = @as(u64, self.duration_ms) * 1_000_000, .exit = exit };
    }

    fn put(self: Transition, out: []u8) void {
        out[0] = self.has;
        out[1] = self.effect;
        out[2] = self.direction;
        std.mem.writeInt(u16, out[3..5], self.duration_ms, .big);
        out[5] = self.exit;
    }

    fn get(b: []const u8) Transition {
        return .{ .has = b[0], .effect = b[1], .direction = b[2], .duration_ms = std.mem.readInt(u16, b[3..5], .big), .exit = b[5] };
    }
};

/// 0xff on set_base = not given
pub const SetBase = struct { base: u8, generator: u8, seed: u32, style: ClockStyle = .{}, transition: Transition = .{} };
/// the ip layout as a durable setting pushed to the renderer, for the device menu's own page
pub const IpMode = struct { mode: u8 };

/// what the on-device menu asks the supervisor to do. the renderer has already previewed it.
pub const MenuRequest = struct {
    kind: u8,
    value: u32 = 0,

    pub const Kind = enum(u8) { brightness = 0, clock_font = 1, generator = 2, ip_mode = 3, mqtt = 4, ntfy = 5, power_off = 6, reboot = 7, night = 8, night_level = 9 };
};

/// a parameter of one of the base scenes, by the scene and its index in that scene's table. the
/// renderer has already previewed it; the supervisor decides what it means for the settings.
pub const SetParam = struct { base: u8, index: u8, value: u32 };

/// what the menu's info page reads. the supervisor has all of it and pushes it every few seconds.
pub const DeviceStatus = struct {
    battery_pct: u8 = 255,
    usb: u8 = 255,
    wifi_quality: u8 = 255,
    wifi_dbm: i16 = -32768,
    time_synced: u8 = 0,
    mqtt_on: u8 = 0,
    ntfy_on: u8 = 0,
    uptime_s: u32 = 0,
    night_on: u8 = 0,
    night_level: u8 = 10,
    /// whether the schedule has a location to work from at all
    night_placed: u8 = 0,

    pub const wire_len = 1 + 1 + 1 + 2 + 1 + 1 + 1 + 4 + 3;
};
pub const Frame = struct { duration_s: u16, transition: Transition = .{}, rgb: geometry.Rgb };
pub const Brightness = struct { value: u8 };
pub const Reseed = struct { seed: u32 };
pub const IpChanged = struct { present: u8, addr: [4]u8 };

pub const Notify = struct {
    colour: [3]u8,
    duration_s: u16,
    len: u8,
    text: [128]u8,
    transition: Transition = .{},

    pub fn init(text: []const u8, colour: [3]u8, duration_s: u16, t: Transition) Notify {
        var n = Notify{ .colour = colour, .duration_s = duration_s, .len = @intCast(text.len), .text = [_]u8{0} ** 128, .transition = t };
        @memcpy(n.text[0..text.len], text);
        return n;
    }

    pub fn slice(self: *const Notify) []const u8 {
        return self.text[0..self.len];
    }
};

pub const Credentials = api.Credentials;

/// a config patch on the wire: presence flags plus fixed fields.
pub const ConfigPatch = struct {
    has: u32 = 0,
    brightness: u8 = 0,
    base: u8 = 0,
    generator: u8 = 0,
    timezone: config.Text = .{},
    ntp_server: [4]u8 = .{ 0, 0, 0, 0 },
    ntp_interval_s: u32 = 0,
    frame_timeout_ms: u16 = 0,
    metrics_interval_s: u32 = 0,
    discovery: u8 = 0,
    discovery_prefix: config.Text = .{},
    expected_revision: u32 = 0,
    clock_font: u8 = 0,
    clock_colour_mode: u8 = 0,
    clock_colour: [3]u8 = .{ 0, 0, 0 },
    clock_colour2: [3]u8 = .{ 0, 0, 0 },
    clock_gradient: u8 = 0,
    clock_spread: u8 = 0,
    clock_digit: u8 = 0,
    /// generator parameters carried with the rest of a settings change, so one request is one
    /// round trip and one revision
    param_count: u8 = 0,
    params: [api.max_params_per_patch]api.ResolvedParam = [_]api.ResolvedParam{.{ .owner = 0, .slot = 0, .value = 0 }} ** api.max_params_per_patch,
    ip_mode: u8 = 0,
    night: u8 = 0,
    night_brightness: u8 = 0,
    night_lead_min: u8 = 0,
    latitude: i16 = 0,
    longitude: i16 = 0,
    berry_enabled: u8 = 0,
    berry_heap_kb: u16 = 0,
    berry_handler_ms: u16 = 0,

    pub const F = struct {
        pub const brightness: u32 = 1 << 0;
        pub const base: u32 = 1 << 1;
        pub const generator: u32 = 1 << 2;
        pub const timezone: u32 = 1 << 3;
        pub const ntp_server: u32 = 1 << 4;
        pub const ntp_interval_s: u32 = 1 << 5;
        pub const frame_timeout_ms: u32 = 1 << 6;
        pub const metrics_interval_s: u32 = 1 << 7;
        pub const discovery: u32 = 1 << 8;
        pub const discovery_prefix: u32 = 1 << 9;
        pub const expected_revision: u32 = 1 << 10;
        pub const clock_font: u32 = 1 << 11;
        pub const clock_colour_mode: u32 = 1 << 12;
        pub const clock_colour: u32 = 1 << 13;
        pub const clock_colour2: u32 = 1 << 14;
        pub const clock_gradient: u32 = 1 << 15;
        pub const clock_spread: u32 = 1 << 16;
        pub const ip_mode: u32 = 1 << 17;
        pub const clock_digit: u32 = 1 << 18;
        pub const night: u32 = 1 << 19;
        pub const night_brightness: u32 = 1 << 20;
        pub const night_lead_min: u32 = 1 << 21;
        pub const location: u32 = 1 << 22;
        pub const location_auto: u32 = 1 << 23;
        pub const berry_enabled: u32 = 1 << 24;
        pub const berry_heap_kb: u32 = 1 << 25;
        pub const berry_handler_ms: u32 = 1 << 26;
    };

    pub const fixed_len = 4 + 3 + 65 + 4 + 4 + 2 + 4 + 1 + 65 + 4 + 12 + 7 + (1 + 2 + 2) + 1;
    pub const wire_len = fixed_len + api.max_params_per_patch * 6;

    pub fn fromApi(p: api.ConfigPatch) error{TooLong}!ConfigPatch {
        var w = ConfigPatch{};
        if (p.brightness) |v| {
            w.has |= F.brightness;
            w.brightness = v;
        }
        if (p.base) |v| {
            w.has |= F.base;
            w.base = @intFromEnum(v);
        }
        if (p.generator) |v| {
            w.has |= F.generator;
            w.generator = @intFromEnum(v);
        }
        if (p.timezone) |v| {
            w.has |= F.timezone;
            try w.timezone.set(v);
        }
        if (p.ntp_server) |v| {
            w.has |= F.ntp_server;
            w.ntp_server = v;
        }
        if (p.ntp_interval_s) |v| {
            w.has |= F.ntp_interval_s;
            w.ntp_interval_s = v;
        }
        if (p.frame_timeout_ms) |v| {
            w.has |= F.frame_timeout_ms;
            w.frame_timeout_ms = v;
        }
        if (p.metrics_interval_s) |v| {
            w.has |= F.metrics_interval_s;
            w.metrics_interval_s = v;
        }
        if (p.discovery) |v| {
            w.has |= F.discovery;
            w.discovery = @intFromBool(v);
        }
        if (p.discovery_prefix) |v| {
            w.has |= F.discovery_prefix;
            try w.discovery_prefix.set(v);
        }
        if (p.expected_revision) |v| {
            w.has |= F.expected_revision;
            w.expected_revision = v;
        }
        if (p.clock_font) |v| {
            w.has |= F.clock_font;
            w.clock_font = @intFromEnum(v);
        }
        if (p.clock_colour_mode) |v| {
            w.has |= F.clock_colour_mode;
            w.clock_colour_mode = @intFromEnum(v);
        }
        if (p.clock_colour) |v| {
            w.has |= F.clock_colour;
            w.clock_colour = v;
        }
        if (p.clock_colour2) |v| {
            w.has |= F.clock_colour2;
            w.clock_colour2 = v;
        }
        if (p.clock_gradient) |v| {
            w.has |= F.clock_gradient;
            w.clock_gradient = @intFromEnum(v);
        }
        if (p.clock_digit) |v| {
            w.has |= F.clock_digit;
            w.clock_digit = @intFromEnum(v);
        }
        w.param_count = @intCast(@min(p.generator_params.len, w.params.len));
        for (p.generator_params[0..w.param_count], 0..) |rp, i| w.params[i] = rp;
        if (p.clock_spread) |v| {
            w.has |= F.clock_spread;
            w.clock_spread = v;
        }
        if (p.ip_mode) |v| {
            w.has |= F.ip_mode;
            w.ip_mode = @intFromEnum(v);
        }
        if (p.night) |v| {
            w.has |= F.night;
            w.night = @intFromBool(v);
        }
        if (p.night_brightness) |v| {
            w.has |= F.night_brightness;
            w.night_brightness = v;
        }
        if (p.berry_enabled) |v| {
            w.has |= F.berry_enabled;
            w.berry_enabled = @intFromBool(v);
        }
        if (p.berry_heap_kb) |v| {
            w.has |= F.berry_heap_kb;
            w.berry_heap_kb = v;
        }
        if (p.berry_handler_ms) |v| {
            w.has |= F.berry_handler_ms;
            w.berry_handler_ms = v;
        }
        if (p.night_lead_min) |v| {
            w.has |= F.night_lead_min;
            w.night_lead_min = v;
        }
        if (p.location) |v| {
            w.has |= F.location;
            w.latitude = v.lat_c;
            w.longitude = v.lon_c;
        }
        if (p.location_auto) |v| if (v) {
            w.has |= F.location_auto;
        };
        return w;
    }

    /// the api view again; slices point into `self`.
    pub fn toApi(self: *const ConfigPatch) api.ConfigPatch {
        const h = self.has;
        return .{
            .brightness = if (h & F.brightness != 0) self.brightness else null,
            .base = if (h & F.base != 0) (enumFromInt(api.Base, self.base) orelse null) else null,
            .generator = if (h & F.generator != 0) (enumFromInt(@import("../scene/scene.zig").Generator, self.generator) orelse null) else null,
            .timezone = if (h & F.timezone != 0) self.timezone.slice() else null,
            .ntp_server = if (h & F.ntp_server != 0) self.ntp_server else null,
            .ntp_interval_s = if (h & F.ntp_interval_s != 0) self.ntp_interval_s else null,
            .frame_timeout_ms = if (h & F.frame_timeout_ms != 0) self.frame_timeout_ms else null,
            .metrics_interval_s = if (h & F.metrics_interval_s != 0) self.metrics_interval_s else null,
            .discovery = if (h & F.discovery != 0) self.discovery != 0 else null,
            .discovery_prefix = if (h & F.discovery_prefix != 0) self.discovery_prefix.slice() else null,
            .expected_revision = if (h & F.expected_revision != 0) self.expected_revision else null,
            .clock_font = if (h & F.clock_font != 0) (enumFromInt(clock.Font, self.clock_font) orelse null) else null,
            .clock_colour_mode = if (h & F.clock_colour_mode != 0) (enumFromInt(clock.ColourMode, self.clock_colour_mode) orelse null) else null,
            .clock_colour = if (h & F.clock_colour != 0) self.clock_colour else null,
            .clock_colour2 = if (h & F.clock_colour2 != 0) self.clock_colour2 else null,
            .clock_gradient = if (h & F.clock_gradient != 0) (enumFromInt(clock.Gradient, self.clock_gradient) orelse null) else null,
            .clock_spread = if (h & F.clock_spread != 0) self.clock_spread else null,
            .clock_digit = if (h & F.clock_digit != 0) enumFromInt(clockfont.DigitStyle, self.clock_digit) else null,
            .generator_params = self.params[0..self.param_count],
            .ip_mode = if (h & F.ip_mode != 0) enumFromInt(ip.Mode, self.ip_mode) else null,
            .night = if (h & F.night != 0) self.night != 0 else null,
            .night_brightness = if (h & F.night_brightness != 0) self.night_brightness else null,
            .night_lead_min = if (h & F.night_lead_min != 0) self.night_lead_min else null,
            .location = if (h & F.location != 0) .{ .lat_c = self.latitude, .lon_c = self.longitude } else null,
            .location_auto = if (h & F.location_auto != 0) true else null,
            .berry_enabled = if (h & F.berry_enabled != 0) self.berry_enabled != 0 else null,
            .berry_heap_kb = if (h & F.berry_heap_kb != 0) self.berry_heap_kb else null,
            .berry_handler_ms = if (h & F.berry_handler_ms != 0) self.berry_handler_ms else null,
        };
    }
};

/// the ntfy settings patch from netd: presence flags, fixed fields and a pem certificate of
/// variable length at the end (0 = not given; presence with length 0 = remove).
pub const NtfyPut = struct {
    has: u16 = 0,
    enabled: u8 = 0,
    url: config.Text = .{},
    topic: config.Text = .{},
    token: config.Text = .{},
    username: config.Text = .{},
    password: config.Text = .{},
    duration_s: u16 = 0,
    insecure: u8 = 0,
    ca_len: u16 = 0,
    ca: [api.max_ca]u8 = undefined,

    pub const F = struct {
        pub const enabled: u16 = 1 << 0;
        pub const url: u16 = 1 << 1;
        pub const topic: u16 = 1 << 2;
        pub const token: u16 = 1 << 3;
        pub const username: u16 = 1 << 4;
        pub const password: u16 = 1 << 5;
        pub const duration_s: u16 = 1 << 6;
        pub const insecure: u16 = 1 << 7;
        pub const ca: u16 = 1 << 8;
    };

    pub const fixed_len = 2 + 1 + 5 * (config.text_max + 1) + 2 + 1 + 2;

    pub fn fromApi(p: api.NtfyPut) error{TooLong}!NtfyPut {
        var w = NtfyPut{};
        if (p.enabled) |v| {
            w.has |= F.enabled;
            w.enabled = @intFromBool(v);
        }
        if (p.url) |v| {
            w.has |= F.url;
            try w.url.set(v);
        }
        if (p.topic) |v| {
            w.has |= F.topic;
            try w.topic.set(v);
        }
        if (p.token) |v| {
            w.has |= F.token;
            try w.token.set(v);
        }
        if (p.username) |v| {
            w.has |= F.username;
            try w.username.set(v);
        }
        if (p.password) |v| {
            w.has |= F.password;
            try w.password.set(v);
        }
        if (p.duration_s) |v| {
            w.has |= F.duration_s;
            w.duration_s = v;
        }
        if (p.insecure) |v| {
            w.has |= F.insecure;
            w.insecure = @intFromBool(v);
        }
        if (p.ca) |v| {
            if (v.len > api.max_ca) return error.TooLong;
            w.has |= F.ca;
            w.ca_len = @intCast(v.len);
            @memcpy(w.ca[0..v.len], v);
        }
        return w;
    }

    pub fn toApi(self: *const NtfyPut) api.NtfyPut {
        const h = self.has;
        return .{
            .enabled = if (h & F.enabled != 0) self.enabled != 0 else null,
            .url = if (h & F.url != 0) self.url.slice() else null,
            .topic = if (h & F.topic != 0) self.topic.slice() else null,
            .token = if (h & F.token != 0) self.token.slice() else null,
            .username = if (h & F.username != 0) self.username.slice() else null,
            .password = if (h & F.password != 0) self.password.slice() else null,
            .duration_s = if (h & F.duration_s != 0) self.duration_s else null,
            .insecure = if (h & F.insecure != 0) self.insecure != 0 else null,
            .ca = if (h & F.ca != 0) self.ca[0..self.ca_len] else null,
        };
    }

    fn put(self: *const NtfyPut, out: []u8) usize {
        var o: usize = 0;
        std.mem.writeInt(u16, out[o..][0..2], self.has, .little);
        out[o + 2] = self.enabled;
        o += 3;
        putText(out, &o, self.url);
        putText(out, &o, self.topic);
        putText(out, &o, self.token);
        putText(out, &o, self.username);
        putText(out, &o, self.password);
        std.mem.writeInt(u16, out[o..][0..2], self.duration_s, .little);
        out[o + 2] = self.insecure;
        std.mem.writeInt(u16, out[o + 3 ..][0..2], self.ca_len, .little);
        o += 5;
        @memcpy(out[o .. o + self.ca_len], self.ca[0..self.ca_len]);
        return o + self.ca_len;
    }

    fn get(b: []const u8) error{BadPayload}!NtfyPut {
        if (b.len < fixed_len) return error.BadPayload;
        var w = NtfyPut{};
        var o: usize = 0;
        w.has = std.mem.readInt(u16, b[o..][0..2], .little);
        w.enabled = b[o + 2];
        o += 3;
        w.url = try getText(b, &o);
        w.topic = try getText(b, &o);
        w.token = try getText(b, &o);
        w.username = try getText(b, &o);
        w.password = try getText(b, &o);
        w.duration_s = std.mem.readInt(u16, b[o..][0..2], .little);
        w.insecure = b[o + 2];
        w.ca_len = std.mem.readInt(u16, b[o + 3 ..][0..2], .little);
        o += 5;
        if (w.ca_len > api.max_ca or b.len != o + w.ca_len) return error.BadPayload;
        @memcpy(w.ca[0..w.ca_len], b[o .. o + w.ca_len]);
        return w;
    }
};

/// what the ntfy subscriber needs, sent by the supervisor once after spawn: the settings and
/// the extra ca certificate (pem, may be empty).
pub const NtfyConfig = struct {
    ntfy: config.Ntfy = .{},
    ca_len: u16 = 0,
    ca: [api.max_ca]u8 = undefined,

    pub const fixed_len = 1 + 5 * (config.text_max + 1) + 2 + 1 + 2;

    pub fn caSlice(self: *const NtfyConfig) []const u8 {
        return self.ca[0..self.ca_len];
    }

    fn put(self: *const NtfyConfig, out: []u8) usize {
        var o: usize = 0;
        out[o] = @intFromBool(self.ntfy.enabled);
        o += 1;
        putText(out, &o, self.ntfy.url);
        putText(out, &o, self.ntfy.topic);
        putText(out, &o, self.ntfy.token);
        putText(out, &o, self.ntfy.username);
        putText(out, &o, self.ntfy.password);
        std.mem.writeInt(u16, out[o..][0..2], self.ntfy.duration_s, .little);
        out[o + 2] = @intFromBool(self.ntfy.insecure);
        std.mem.writeInt(u16, out[o + 3 ..][0..2], self.ca_len, .little);
        o += 5;
        @memcpy(out[o .. o + self.ca_len], self.ca[0..self.ca_len]);
        return o + self.ca_len;
    }

    fn get(b: []const u8) error{BadPayload}!NtfyConfig {
        if (b.len < fixed_len) return error.BadPayload;
        var c = NtfyConfig{};
        var o: usize = 0;
        c.ntfy.enabled = b[o] != 0;
        o += 1;
        c.ntfy.url = try getText(b, &o);
        c.ntfy.topic = try getText(b, &o);
        c.ntfy.token = try getText(b, &o);
        c.ntfy.username = try getText(b, &o);
        c.ntfy.password = try getText(b, &o);
        c.ntfy.duration_s = std.mem.readInt(u16, b[o..][0..2], .little);
        c.ntfy.insecure = b[o + 2] != 0;
        c.ca_len = std.mem.readInt(u16, b[o + 3 ..][0..2], .little);
        o += 5;
        if (c.ca_len > api.max_ca or b.len != o + c.ca_len) return error.BadPayload;
        @memcpy(c.ca[0..c.ca_len], b[o .. o + c.ca_len]);
        return c;
    }
};

/// the subscriber's state for /status: 0 off, 1 connecting, 2 subscribed, 3 error (with text)
pub const NtfyStatus = struct {
    state: u8 = 0,
    messages: u32 = 0,
    err: config.Text = .{},
    /// set by the supervisor: an extra ca certificate is installed
    ca_set: u8 = 0,

    pub const wire_len = 1 + 4 + config.text_max + 1 + 1;

    fn put(self: *const NtfyStatus, out: []u8) void {
        out[0] = self.state;
        std.mem.writeInt(u32, out[1..5], self.messages, .little);
        var o: usize = 5;
        putText(out, &o, self.err);
        out[o] = self.ca_set;
    }

    fn get(b: []const u8) error{BadPayload}!NtfyStatus {
        var o: usize = 5;
        const err = try getText(b, &o);
        return .{ .state = b[0], .messages = std.mem.readInt(u32, b[1..5], .little), .err = err, .ca_set = b[o] };
    }
};

pub const MqttPut = struct {
    has: u8 = 0,
    enabled: u8 = 0,
    host: config.Text = .{},
    port: u16 = 0,
    username: config.Text = .{},
    password: config.Text = .{},
    client_id: config.Text = .{},
    prefix: config.Text = .{},
    tls: u8 = 0,

    pub const F = struct {
        pub const enabled: u8 = 1 << 0;
        pub const host: u8 = 1 << 1;
        pub const port: u8 = 1 << 2;
        pub const username: u8 = 1 << 3;
        pub const password: u8 = 1 << 4;
        pub const client_id: u8 = 1 << 5;
        pub const prefix: u8 = 1 << 6;
        pub const tls: u8 = 1 << 7;
    };

    pub const wire_len = 1 + 1 + 65 + 2 + 4 * 65 + 1;

    pub fn fromApi(p: api.MqttPut) error{TooLong}!MqttPut {
        var w = MqttPut{};
        if (p.enabled) |v| {
            w.has |= F.enabled;
            w.enabled = @intFromBool(v);
        }
        if (p.host) |v| {
            w.has |= F.host;
            try w.host.set(v);
        }
        if (p.port) |v| {
            w.has |= F.port;
            w.port = v;
        }
        if (p.username) |v| {
            w.has |= F.username;
            try w.username.set(v);
        }
        if (p.password) |v| {
            w.has |= F.password;
            try w.password.set(v);
        }
        if (p.client_id) |v| {
            w.has |= F.client_id;
            try w.client_id.set(v);
        }
        if (p.prefix) |v| {
            w.has |= F.prefix;
            try w.prefix.set(v);
        }
        if (p.tls) |v| {
            w.has |= F.tls;
            w.tls = @intFromBool(v);
        }
        return w;
    }

    pub fn toApi(self: *const MqttPut) api.MqttPut {
        const h = self.has;
        return .{
            .enabled = if (h & F.enabled != 0) self.enabled != 0 else null,
            .host = if (h & F.host != 0) self.host.slice() else null,
            .port = if (h & F.port != 0) self.port else null,
            .username = if (h & F.username != 0) self.username.slice() else null,
            .password = if (h & F.password != 0) self.password.slice() else null,
            .client_id = if (h & F.client_id != 0) self.client_id.slice() else null,
            .prefix = if (h & F.prefix != 0) self.prefix.slice() else null,
            .tls = if (h & F.tls != 0) self.tls != 0 else null,
        };
    }
};

pub const ConfigSave = struct { has_revision: u8, revision: u32 };
pub const SaveResult = struct { status: Status, saved_revision: u32 };

/// the supervisor's snapshot of everything netd reports over http and mqtt.
/// a canvas document together with the ages of its animation clocks. the document alone cannot
/// describe the phase: a second renderer of it (the console's preview) installs at its own instant,
/// and every animated element is then permanently out of step with the panel. the per-element ages
/// are not redundant with the document's -- `canvas.Clocks.install` restarts only the elements
/// whose value changed, so after a patch they differ.
pub const CanvasView = struct {
    doc: canvas.Document = .{},
    doc_age_ms: u32 = 0,
    element_age_ms: [canvas.max_elements]u32 = [_]u32{0} ** canvas.max_elements,
};

pub const StatusSnapshot = struct {
    renderer_state: u8 = 0, // 0 none, 1 starting, 2 running, 3 stopping
    epoch: u32 = 0,
    revision: u32 = 0,
    presented: u64 = 0,
    base: u8 = 0,
    generator: u8 = 0,
    overlay: u8 = 0,
    brightness: u8 = 0,
    uptime_s: u32 = 0,
    mem_available_kb: u32 = 0,
    cpu_pct: u8 = 255, // 255 = unknown
    rss_supervisor_kb: u32 = 0,
    rss_renderer_kb: u32 = 0,
    rss_netd_kb: u32 = 0,
    restarts: u32 = 0,
    fps_x10: u16 = 0,
    ip_present: u8 = 0,
    ip: [4]u8 = .{ 0, 0, 0, 0 },
    time_state: u8 = 0, // 0 unsynced, 1 synced, 2 stale
    time_age_s: u32 = 0xffffffff,
    config_revision: u32 = 0,
    saved_revision: u32 = 0,
    boot_id: u32 = 0,
    sample_age_ms: u32 = 0,
    // v2 fields: stable identity and more telemetry (unknown values are explicit, never zero)
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    mac_present: u8 = 0,
    load_1m_x100: u16 = 0xffff,
    mem_free_kb: u32 = 0,
    wifi_level_dbm: i16 = -32768, // -32768 unknown
    wifi_quality: u8 = 255,
    cpu_supervisor_pct_x10: u16 = 0xffff,
    cpu_renderer_pct_x10: u16 = 0xffff,
    cpu_netd_pct_x10: u16 = 0xffff,
    tmpfs_used_kb: u32 = 0xffffffff,
    battery_mv: u16 = 0xffff,
    battery_pct: u8 = 255,
    usb_present: u8 = 255,
    // v3: display power as the renderer reports it
    power: u8 = 1,
    ip_mode: u8 = 0,
    ntfy: NtfyStatus = .{},
    // v4: the clock style as the renderer reports it (mask ignored)
    clock: ClockStyle = .{},
    // v5: the totals the used figures are a fraction of, and the flash partition
    mem_total_kb: u32 = 0,
    tmpfs_total_kb: u32 = 0,
    flash_total_kb: u32 = 0,
    flash_used_kb: u32 = 0,
    // v6: the night brightness schedule, as the supervisor is running it
    night_phase: u8 = 0, // 0 not running, then day, to_night, night, to_day
    night_override: u8 = 0, // a brightness set by hand is standing in the schedule's way
    // v7: the art scene's seed, so a client running the same generators can reproduce the panel
    seed: u32 = 0,
    // v8: what the on-device menu is showing, so a client driving /input can assert rather than
    // count detents
    menu: u8 = 0,
    menu_item: u8 = 0,
    menu_state: u8 = 0,
    // v9: the device's own counters. the interface totals are the kernel's own 32-bit ones, so
    // they wrap where it wraps; the two rates are derived here and are `unknown_rate` until a
    // second sample exists. `net_rx_dropped` is the driver's counter under the driver's name and
    // is not application packet loss -- this device reports over a third of received frames there.
    net_rx_bytes: u32 = 0,
    net_tx_bytes: u32 = 0,
    net_rx_packets: u32 = 0,
    net_tx_packets: u32 = 0,
    net_rx_errors: u32 = 0,
    net_rx_dropped: u32 = 0,
    net_tx_errors: u32 = 0,
    net_tx_dropped: u32 = 0,
    net_rx_bps: u32 = 0xffffffff,
    net_tx_bps: u32 = 0xffffffff,
    mem_cached_kb: u32 = 0,
    mem_dirty_kb: u32 = 0,
    mem_writeback_kb: u32 = 0,
    mem_slab_kb: u32 = 0,
    // configuration saves: application writes to the settings file, counted where they happen.
    // not flash wear -- this build exposes no programmed-byte or erase totals to derive that from.
    saves: u32 = 0,
    save_failures: u32 = 0,
    save_bytes: u32 = 0,
    save_last_ms: u16 = 0xffff,
    // v10: the script interpreter. `berry_state` is 0 off, 1 starting, 2 running, 3 failed, so a
    // client can tell "not enabled" from "enabled and not answering" without inferring it from a
    // heap figure that would be zero either way.
    berry_state: u8 = 0,
    berry: BerryStatus = .{},

    pub const wire_len = 4 + 3 + 2 + 1 + 4 + 4 + 8 + 4 + 4 + 4 + 1 + 4 + 4 + 4 + 4 + 2 + 1 + 4 + 1 + 4 + 4 + 4 + 4 + 4 + (6 + 1 + 2 + 4 + 2 + 1 + 2 + 2 + 2 + 4 + 2 + 1 + 1) + 1 + ClockStyle.wire_len + 1 + NtfyStatus.wire_len + 4 * 4 + (10 * 4) + (4 * 4) + (4 + 4 + 4 + 2) + (1 + BerryStatus.wire_len);
};

pub const Message = union(Kind) {
    heartbeat: Heartbeat,
    ready,
    result: Result,
    set_base: SetBase,
    notify: Notify,
    frame: Frame,
    brightness: Brightness,
    reseed: Reseed,
    arm_stream,
    time_corrected,
    ip_changed: IpChanged,
    stop,
    set_timezone: config.Text,
    screen_get,
    screen: Screen,
    input: Input,
    inject_input: Input,
    power: Power,
    log_get: LogGet,
    log_lines: LogLines,
    clock_style: ClockStyle,
    ip_mode: IpMode,
    credentials: Credentials,
    config: config.Config,
    config_get,
    config_patch: ConfigPatch,
    config_save: ConfigSave,
    save_result: SaveResult,
    mqtt_put: MqttPut,
    status_get,
    status: StatusSnapshot,
    ntfy_put: NtfyPut,
    ntfy_config: NtfyConfig,
    ntfy_status: NtfyStatus,
    menu_request: MenuRequest,
    device_status: DeviceStatus,
    set_param: SetParam,
    canvas: CanvasView,
    canvas_get,
    canvas_patch: canvas.Patch,
    canvas_clear,
    canvas_error: CanvasError,
    sprite: canvas.Sprite,
    sprite_delete: canvas.Id,
    sprite_list_get,
    sprite_list: SpriteList,
    berry_config: BerryConfig,
    berry_status: BerryStatus,
    berry_script: BerryScript,
    berry_result: BerryResult,
    berry_list_get,
    berry_scripts: BerryScripts,
    berry_event: BerryEvent,
    stream_frame: StreamFrame,
};

pub const Packet = struct { request_id: u64, epoch: u32, message: Message };
pub const Error = codec.DecodeError || error{ UnknownKind, BadPayload };

fn encodePayload(msg: Message, out: []u8) usize {
    switch (msg) {
        .heartbeat => |h| {
            std.mem.writeInt(u64, out[0..8], h.presented, .big);
            std.mem.writeInt(u32, out[8..12], h.revision, .big);
            out[12] = h.state;
            out[13] = h.base;
            out[14] = h.generator;
            out[15] = h.overlay;
            out[16] = h.brightness;
            out[17] = h.power;
            h.clock.put(out[18 .. 18 + ClockStyle.wire_len]);
            out[18 + ClockStyle.wire_len] = h.ip_mode;
            std.mem.writeInt(u32, out[19 + ClockStyle.wire_len ..][0..4], h.seed, .big);
            out[23 + ClockStyle.wire_len] = h.menu;
            out[24 + ClockStyle.wire_len] = h.menu_item;
            out[25 + ClockStyle.wire_len] = h.menu_state;
            return 26 + ClockStyle.wire_len;
        },
        .clock_style => |s| {
            s.put(out[0..ClockStyle.wire_len]);
            return ClockStyle.wire_len;
        },
        .ip_mode => |m| {
            out[0] = m.mode;
            return 1;
        },
        .menu_request => |m| {
            out[0] = m.kind;
            std.mem.writeInt(u32, out[1..5], m.value, .big);
            return 5;
        },
        .set_param => |sp| {
            out[0] = sp.base;
            out[1] = sp.index;
            std.mem.writeInt(u32, out[2..6], sp.value, .big);
            return 6;
        },
        .canvas => |v| {
            var o = canvas.encode(&v.doc, out) catch return 0;
            // the ages follow the document, which knows its own length from its header
            if (o + 4 + @as(usize, v.doc.count) * 4 > out.len) return 0;
            std.mem.writeInt(u32, out[o..][0..4], v.doc_age_ms, .big);
            o += 4;
            for (0..v.doc.count) |i| {
                std.mem.writeInt(u32, out[o..][0..4], v.element_age_ms[i], .big);
                o += 4;
            }
            return o;
        },
        .canvas_patch => |p| return canvas.putPatch(&p, out) catch 0,
        .canvas_error => |e| {
            out[0] = e.reason;
            return 1;
        },
        .sprite => |sp| {
            out[0] = sp.id.len;
            @memcpy(out[1..9], &sp.id.bytes);
            out[9] = sp.w;
            out[10] = sp.h;
            @memcpy(out[11 .. 11 + sp.bytes()], sp.rgb[0..sp.bytes()]);
            return 11 + sp.bytes();
        },
        .sprite_delete => |id| {
            out[0] = id.len;
            @memcpy(out[1..9], &id.bytes);
            return 9;
        },
        .sprite_list => |l| {
            out[0] = l.count;
            for (l.items[0..l.count], 0..) |it, i| {
                const o = 1 + i * 11;
                out[o] = it.id.len;
                @memcpy(out[o + 1 .. o + 9], &it.id.bytes);
                out[o + 9] = it.w;
                out[o + 10] = it.h;
            }
            return 1 + @as(usize, l.count) * 11;
        },
        .berry_config => |c| {
            c.put(out);
            return BerryConfig.wire_len;
        },
        .berry_status => |b| {
            b.put(out);
            return BerryStatus.wire_len;
        },
        .berry_script => |b| {
            out[0] = b.op;
            out[1] = b.name.len;
            @memcpy(out[2..][0..store.name_max], &b.name.bytes);
            std.mem.writeInt(u16, out[2 + store.name_max ..][0..2], b.len, .little);
            @memcpy(out[BerryScript.fixed_len..][0..b.len], b.source[0..b.len]);
            return BerryScript.fixed_len + b.len;
        },
        .berry_result => |r| {
            out[0] = r.outcome;
            out[1] = r.name.len;
            @memcpy(out[2..][0..store.name_max], &r.name.bytes);
            var o: usize = 2 + store.name_max;
            putText(out, &o, r.text);
            return o;
        },
        .berry_event => |e| {
            e.put(out);
            return BerryEvent.wire_len;
        },
        .stream_frame => |f| {
            std.mem.writeInt(u32, out[0..4], f.seq, .big);
            std.mem.writeInt(u16, out[4..6], f.timeout_ms, .big);
            @memcpy(out[6..][0..geometry.rgb_bytes], &f.rgb);
            return StreamFrame.wire_len;
        },
        .berry_scripts => |l| {
            std.mem.writeInt(u32, out[0..4], l.used, .little);
            std.mem.writeInt(u32, out[4..8], l.budget, .little);
            out[8] = l.count;
            var o: usize = 9;
            for (l.items[0..l.count]) |it| {
                out[o] = it.name.len;
                @memcpy(out[o + 1 ..][0..store.name_max], &it.name.bytes);
                std.mem.writeInt(u16, out[o + 1 + store.name_max ..][0..2], it.bytes, .little);
                out[o + 3 + store.name_max] = it.compiled;
                o += 4 + store.name_max;
            }
            return o;
        },
        .device_status => |d| {
            out[0] = d.battery_pct;
            out[1] = d.usb;
            out[2] = d.wifi_quality;
            std.mem.writeInt(i16, out[3..5], d.wifi_dbm, .big);
            out[5] = d.time_synced;
            out[6] = d.mqtt_on;
            out[7] = d.ntfy_on;
            std.mem.writeInt(u32, out[8..12], d.uptime_s, .big);
            out[12] = d.night_on;
            out[13] = d.night_level;
            out[14] = d.night_placed;
            return DeviceStatus.wire_len;
        },
        .ready, .arm_stream, .time_corrected, .stop, .config_get, .status_get, .screen_get, .canvas_get, .canvas_clear, .sprite_list_get, .berry_list_get => return 0,
        .screen => |s| {
            std.mem.writeInt(u32, out[0..4], s.revision, .big);
            out[4] = s.brightness;
            out[5] = s.power;
            @memcpy(out[6 .. 6 + geometry.rgb_bytes], &s.rgb);
            return 6 + geometry.rgb_bytes;
        },
        .input, .inject_input => |i| {
            out[0] = i.control;
            out[1] = i.event;
            std.mem.writeInt(i32, out[2..6], i.position, .big);
            out[6] = i.steps;
            return 7;
        },
        .power => |p| {
            out[0] = p.on;
            return 1;
        },
        .log_get => |g| {
            std.mem.writeInt(u32, out[0..4], g.after, .big);
            return 4;
        },
        .log_lines => |l| {
            std.mem.writeInt(u32, out[0..4], l.next, .big);
            out[4] = l.count;
            std.mem.writeInt(u16, out[5..7], l.len, .big);
            @memcpy(out[7 .. 7 + @as(usize, l.len)], l.data[0..l.len]);
            return 7 + @as(usize, l.len);
        },
        .set_timezone => |t| {
            var o: usize = 0;
            putText(out, &o, t);
            return o;
        },
        .credentials => |c| {
            out[0..32].* = c.control;
            out[32..64].* = c.admin;
            return 64;
        },
        .config => |c| {
            config.encode(&c, out[0..config.encoded_len]);
            return config.encoded_len;
        },
        .config_patch => |p| {
            var o: usize = 0;
            std.mem.writeInt(u32, out[o..][0..4], p.has, .little);
            o += 4;
            out[o] = p.brightness;
            out[o + 1] = p.base;
            out[o + 2] = p.generator;
            o += 3;
            putText(out, &o, p.timezone);
            out[o..][0..4].* = p.ntp_server;
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], p.ntp_interval_s, .little);
            o += 4;
            std.mem.writeInt(u16, out[o..][0..2], p.frame_timeout_ms, .little);
            o += 2;
            std.mem.writeInt(u32, out[o..][0..4], p.metrics_interval_s, .little);
            o += 4;
            out[o] = p.discovery;
            o += 1;
            putText(out, &o, p.discovery_prefix);
            std.mem.writeInt(u32, out[o..][0..4], p.expected_revision, .little);
            o += 4;
            out[o] = p.clock_font;
            out[o + 1] = p.clock_colour_mode;
            out[o + 2 ..][0..3].* = p.clock_colour;
            out[o + 5 ..][0..3].* = p.clock_colour2;
            out[o + 8] = p.clock_gradient;
            out[o + 9] = p.clock_spread;
            out[o + 10] = p.ip_mode;
            out[o + 11] = p.clock_digit;
            o += 12;
            out[o] = p.night;
            out[o + 1] = p.night_brightness;
            out[o + 2] = p.night_lead_min;
            std.mem.writeInt(i16, out[o + 3 ..][0..2], p.latitude, .little);
            std.mem.writeInt(i16, out[o + 5 ..][0..2], p.longitude, .little);
            o += 7;
            out[o] = p.berry_enabled;
            std.mem.writeInt(u16, out[o + 1 ..][0..2], p.berry_heap_kb, .little);
            std.mem.writeInt(u16, out[o + 3 ..][0..2], p.berry_handler_ms, .little);
            o += 5;
            out[o] = p.param_count;
            o += 1;
            for (p.params[0..p.param_count]) |rp| {
                out[o] = rp.owner;
                out[o + 1] = rp.slot;
                std.mem.writeInt(u32, out[o + 2 ..][0..4], rp.value, .big);
                o += 6;
            }
            return o;
        },
        .config_save => |c| {
            out[0] = c.has_revision;
            std.mem.writeInt(u32, out[1..5], c.revision, .big);
            return 5;
        },
        .save_result => |r| {
            out[0] = @intFromEnum(r.status);
            std.mem.writeInt(u32, out[1..5], r.saved_revision, .big);
            return 5;
        },
        .mqtt_put => |m| {
            var o: usize = 0;
            out[o] = m.has;
            out[o + 1] = m.enabled;
            o += 2;
            putText(out, &o, m.host);
            std.mem.writeInt(u16, out[o..][0..2], m.port, .little);
            o += 2;
            putText(out, &o, m.username);
            putText(out, &o, m.password);
            putText(out, &o, m.client_id);
            putText(out, &o, m.prefix);
            out[o] = m.tls;
            o += 1;
            return o;
        },
        .ntfy_put => |n| return n.put(out),
        .ntfy_config => |n| return n.put(out),
        .ntfy_status => |n| {
            n.put(out[0..NtfyStatus.wire_len]);
            return NtfyStatus.wire_len;
        },
        .status => |st| {
            var o: usize = 0;
            out[o] = st.renderer_state;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.epoch, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.revision, .big);
            o += 4;
            std.mem.writeInt(u64, out[o..][0..8], st.presented, .big);
            o += 8;
            out[o] = st.base;
            out[o + 1] = st.generator;
            out[o + 2] = st.overlay;
            out[o + 3] = st.brightness;
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.uptime_s, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.mem_available_kb, .big);
            o += 4;
            out[o] = st.cpu_pct;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_supervisor_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_renderer_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.rss_netd_kb, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.restarts, .big);
            o += 4;
            std.mem.writeInt(u16, out[o..][0..2], st.fps_x10, .big);
            o += 2;
            out[o] = st.ip_present;
            o += 1;
            out[o..][0..4].* = st.ip;
            o += 4;
            out[o] = st.time_state;
            o += 1;
            std.mem.writeInt(u32, out[o..][0..4], st.time_age_s, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.config_revision, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.saved_revision, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.boot_id, .big);
            o += 4;
            std.mem.writeInt(u32, out[o..][0..4], st.sample_age_ms, .big);
            o += 4;
            out[o..][0..6].* = st.mac;
            o += 6;
            out[o] = st.mac_present;
            o += 1;
            std.mem.writeInt(u16, out[o..][0..2], st.load_1m_x100, .big);
            o += 2;
            std.mem.writeInt(u32, out[o..][0..4], st.mem_free_kb, .big);
            o += 4;
            std.mem.writeInt(i16, out[o..][0..2], st.wifi_level_dbm, .big);
            o += 2;
            out[o] = st.wifi_quality;
            o += 1;
            std.mem.writeInt(u16, out[o..][0..2], st.cpu_supervisor_pct_x10, .big);
            o += 2;
            std.mem.writeInt(u16, out[o..][0..2], st.cpu_renderer_pct_x10, .big);
            o += 2;
            std.mem.writeInt(u16, out[o..][0..2], st.cpu_netd_pct_x10, .big);
            o += 2;
            std.mem.writeInt(u32, out[o..][0..4], st.tmpfs_used_kb, .big);
            o += 4;
            std.mem.writeInt(u16, out[o..][0..2], st.battery_mv, .big);
            o += 2;
            out[o] = st.battery_pct;
            out[o + 1] = st.usb_present;
            o += 2;
            out[o] = st.power;
            o += 1;
            st.clock.put(out[o .. o + ClockStyle.wire_len]);
            o += ClockStyle.wire_len;
            out[o] = st.ip_mode;
            o += 1;
            st.ntfy.put(out[o .. o + NtfyStatus.wire_len]);
            o += NtfyStatus.wire_len;
            inline for (.{ st.mem_total_kb, st.tmpfs_total_kb, st.flash_total_kb, st.flash_used_kb }) |v| {
                std.mem.writeInt(u32, out[o..][0..4], v, .big);
                o += 4;
            }
            out[o] = st.night_phase;
            out[o + 1] = st.night_override;
            o += 2;
            std.mem.writeInt(u32, out[o..][0..4], st.seed, .big);
            o += 4;
            out[o] = st.menu;
            out[o + 1] = st.menu_item;
            out[o + 2] = st.menu_state;
            o += 3;
            inline for (.{
                st.net_rx_bytes,   st.net_tx_bytes,   st.net_rx_packets, st.net_tx_packets,
                st.net_rx_errors,  st.net_rx_dropped, st.net_tx_errors,  st.net_tx_dropped,
                st.net_rx_bps,     st.net_tx_bps,     st.mem_cached_kb,  st.mem_dirty_kb,
                st.mem_writeback_kb, st.mem_slab_kb,  st.saves,          st.save_failures,
                st.save_bytes,
            }) |v| {
                std.mem.writeInt(u32, out[o..][0..4], v, .big);
                o += 4;
            }
            std.mem.writeInt(u16, out[o..][0..2], st.save_last_ms, .big);
            o += 2;
            out[o] = st.berry_state;
            o += 1;
            st.berry.put(out[o..]);
            o += BerryStatus.wire_len;
            return o;
        },
        .result => |r| {
            out[0] = @intFromEnum(r.status);
            std.mem.writeInt(u32, out[1..5], r.revision, .big);
            return 5;
        },
        .set_base => |s| {
            out[0] = s.base;
            out[1] = s.generator;
            std.mem.writeInt(u32, out[2..6], s.seed, .big);
            s.style.put(out[6 .. 6 + ClockStyle.wire_len]);
            s.transition.put(out[6 + ClockStyle.wire_len .. 6 + ClockStyle.wire_len + Transition.wire_len]);
            return 6 + ClockStyle.wire_len + Transition.wire_len;
        },
        .notify => |n| {
            out[0..3].* = n.colour;
            std.mem.writeInt(u16, out[3..5], n.duration_s, .big);
            n.transition.put(out[5..11]);
            out[11] = n.len;
            @memcpy(out[12 .. 12 + @as(usize, n.len)], n.text[0..n.len]);
            return 12 + @as(usize, n.len);
        },
        .frame => |f| {
            std.mem.writeInt(u16, out[0..2], f.duration_s, .big);
            f.transition.put(out[2..8]);
            @memcpy(out[8 .. 8 + geometry.rgb_bytes], &f.rgb);
            return 8 + geometry.rgb_bytes;
        },
        .brightness => |b| {
            out[0] = b.value;
            return 1;
        },
        .reseed => |r| {
            std.mem.writeInt(u32, out[0..4], r.seed, .big);
            return 4;
        },
        .ip_changed => |i| {
            out[0] = i.present;
            out[1..5].* = i.addr;
            return 5;
        },
    }
}

pub fn encodePacket(msg: Message, request_id: u64, epoch: u32, out: []u8) error{Overflow}![]u8 {
    var payload: [codec.max_payload]u8 = undefined;
    const n = encodePayload(msg, &payload);
    return codec.encode(.{ .kind = @intFromEnum(msg), .request_id = request_id, .epoch = epoch, .payload_len = @intCast(n) }, payload[0..n], out);
}

/// a non-exhaustive-safe integer -> enum conversion: null for values without a tag.
pub fn enumFromInt(comptime E: type, value: @typeInfo(E).@"enum".tag_type) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (f.value == value) return @enumFromInt(f.value);
    return null;
}

fn putText(out: []u8, off: *usize, t: config.Text) void {
    out[off.*] = t.len;
    @memcpy(out[off.* + 1 .. off.* + 1 + config.text_max], &t.bytes);
    off.* += 1 + config.text_max;
}

fn getText(in: []const u8, off: *usize) error{BadPayload}!config.Text {
    var t = config.Text{};
    t.len = in[off.*];
    if (t.len > config.text_max) return error.BadPayload;
    @memcpy(&t.bytes, in[off.* + 1 .. off.* + 1 + config.text_max]);
    off.* += 1 + config.text_max;
    return t;
}

fn fixed(p: []const u8, n: usize) error{BadPayload}![]const u8 {
    if (p.len != n) return error.BadPayload;
    return p;
}

pub fn decodePacket(bytes: []const u8) Error!Packet {
    const d = try codec.decode(bytes);
    const kind = enumFromInt(Kind, d.header.kind) orelse return error.UnknownKind;
    const p = d.payload;
    const message: Message = switch (kind) {
        .heartbeat => blk: {
            const b = try fixed(p, 26 + ClockStyle.wire_len);
            break :blk .{ .heartbeat = .{ .presented = std.mem.readInt(u64, b[0..8], .big), .revision = std.mem.readInt(u32, b[8..12], .big), .state = b[12], .base = b[13], .generator = b[14], .overlay = b[15], .brightness = b[16], .power = b[17], .clock = ClockStyle.get(b[18..]), .ip_mode = b[18 + ClockStyle.wire_len], .seed = std.mem.readInt(u32, b[19 + ClockStyle.wire_len ..][0..4], .big), .menu = b[23 + ClockStyle.wire_len], .menu_item = b[24 + ClockStyle.wire_len], .menu_state = b[25 + ClockStyle.wire_len] } };
        },
        .clock_style => blk: {
            const b = try fixed(p, ClockStyle.wire_len);
            break :blk .{ .clock_style = ClockStyle.get(b) };
        },
        .ip_mode => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .ip_mode = .{ .mode = b[0] } };
        },
        .menu_request => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .menu_request = .{ .kind = b[0], .value = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .set_param => blk: {
            const b = try fixed(p, 6);
            break :blk .{ .set_param = .{ .base = b[0], .index = b[1], .value = std.mem.readInt(u32, b[2..6], .big) } };
        },
        .canvas => blk: {
            const dlen = canvas.encodedLen(p) orelse return error.BadPayload;
            if (p.len < dlen) return error.BadPayload;
            var v = CanvasView{ .doc = canvas.decode(p[0..dlen]) catch return error.BadPayload };
            // a sender with no ages to give (netd putting a document up) simply omits the tail
            var o = dlen;
            if (p.len >= o + 4) {
                v.doc_age_ms = std.mem.readInt(u32, p[o..][0..4], .big);
                o += 4;
                for (0..v.doc.count) |i| {
                    if (p.len < o + 4) break;
                    v.element_age_ms[i] = std.mem.readInt(u32, p[o..][0..4], .big);
                    o += 4;
                }
            }
            break :blk .{ .canvas = v };
        },
        .canvas_patch => blk: {
            break :blk .{ .canvas_patch = canvas.getPatch(p) catch return error.BadPayload };
        },
        .canvas_get => blk: {
            _ = try fixed(p, 0);
            break :blk .canvas_get;
        },
        .canvas_clear => blk: {
            _ = try fixed(p, 0);
            break :blk .canvas_clear;
        },
        .canvas_error => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .canvas_error = .{ .reason = b[0] } };
        },
        .sprite => blk: {
            if (p.len < 11) return error.BadPayload;
            var sp = canvas.Sprite{};
            sp.id.len = @min(p[0], canvas.id_max);
            @memcpy(&sp.id.bytes, p[1..9]);
            sp.w = p[9];
            sp.h = p[10];
            if (sp.w == 0 or sp.h == 0 or sp.w > canvas.sprite_side_max or sp.h > canvas.sprite_side_max) return error.BadPayload;
            if (p.len != 11 + sp.bytes()) return error.BadPayload;
            @memcpy(sp.rgb[0..sp.bytes()], p[11..]);
            break :blk .{ .sprite = sp };
        },
        .sprite_delete => blk: {
            const b = try fixed(p, 9);
            var id = canvas.Id{ .len = @min(b[0], canvas.id_max) };
            @memcpy(&id.bytes, b[1..9]);
            break :blk .{ .sprite_delete = id };
        },
        .sprite_list_get => blk: {
            _ = try fixed(p, 0);
            break :blk .sprite_list_get;
        },
        .sprite_list => blk: {
            if (p.len < 1 or p[0] > canvas.sprite_max or p.len != 1 + @as(usize, p[0]) * 11) return error.BadPayload;
            var l = SpriteList{ .count = p[0] };
            for (0..l.count) |i| {
                const o = 1 + i * 11;
                l.items[i].id.len = @min(p[o], canvas.id_max);
                @memcpy(&l.items[i].id.bytes, p[o + 1 .. o + 9]);
                l.items[i].w = p[o + 9];
                l.items[i].h = p[o + 10];
            }
            break :blk .{ .sprite_list = l };
        },
        .berry_config => blk: {
            break :blk .{ .berry_config = BerryConfig.get(try fixed(p, BerryConfig.wire_len)) };
        },
        .berry_status => blk: {
            break :blk .{ .berry_status = BerryStatus.get(try fixed(p, BerryStatus.wire_len)) };
        },
        .berry_script => blk: {
            if (p.len < BerryScript.fixed_len or p.len > BerryScript.wire_len) return error.BadPayload;
            var b = BerryScript{ .op = p[0] };
            b.name.len = @min(p[1], store.name_max);
            @memcpy(&b.name.bytes, p[2..][0..store.name_max]);
            b.len = std.mem.readInt(u16, p[2 + store.name_max ..][0..2], .little);
            if (b.len > store.script_max or BerryScript.fixed_len + b.len != p.len) return error.BadPayload;
            @memcpy(b.source[0..b.len], p[BerryScript.fixed_len..][0..b.len]);
            break :blk .{ .berry_script = b };
        },
        .berry_result => blk: {
            const b = try fixed(p, BerryResult.wire_len);
            var r = BerryResult{ .outcome = b[0] };
            r.name.len = @min(b[1], store.name_max);
            @memcpy(&r.name.bytes, b[2..][0..store.name_max]);
            var o: usize = 2 + store.name_max;
            r.text = try getText(b, &o);
            break :blk .{ .berry_result = r };
        },
        .berry_list_get => blk: {
            _ = try fixed(p, 0);
            break :blk .berry_list_get;
        },
        .berry_event => blk: {
            break :blk .{ .berry_event = BerryEvent.get(try fixed(p, BerryEvent.wire_len)) };
        },
        .stream_frame => blk: {
            const b = try fixed(p, StreamFrame.wire_len);
            break :blk .{ .stream_frame = .{
                .seq = std.mem.readInt(u32, b[0..4], .big),
                .timeout_ms = std.mem.readInt(u16, b[4..6], .big),
                .rgb = b[6..][0..geometry.rgb_bytes].*,
            } };
        },
        .berry_scripts => blk: {
            if (p.len < 9) return error.BadPayload;
            var l = BerryScripts{
                .used = std.mem.readInt(u32, p[0..4], .little),
                .budget = std.mem.readInt(u32, p[4..8], .little),
                .count = @min(p[8], BerryScripts.max),
            };
            const entry_len = 4 + store.name_max;
            if (p.len != 9 + @as(usize, l.count) * entry_len) return error.BadPayload;
            for (0..l.count) |i| {
                const o = 9 + i * entry_len;
                l.items[i].name.len = @min(p[o], store.name_max);
                @memcpy(&l.items[i].name.bytes, p[o + 1 ..][0..store.name_max]);
                l.items[i].bytes = std.mem.readInt(u16, p[o + 1 + store.name_max ..][0..2], .little);
                l.items[i].compiled = p[o + 3 + store.name_max];
            }
            break :blk .{ .berry_scripts = l };
        },
        .device_status => blk: {
            const b = try fixed(p, DeviceStatus.wire_len);
            break :blk .{ .device_status = .{
                .battery_pct = b[0],
                .usb = b[1],
                .wifi_quality = b[2],
                .wifi_dbm = std.mem.readInt(i16, b[3..5], .big),
                .time_synced = b[5],
                .mqtt_on = b[6],
                .ntfy_on = b[7],
                .uptime_s = std.mem.readInt(u32, b[8..12], .big),
                .night_on = b[12],
                .night_level = b[13],
                .night_placed = b[14],
            } };
        },
        .screen_get => blk: {
            _ = try fixed(p, 0);
            break :blk .screen_get;
        },
        .screen => blk: {
            const b = try fixed(p, 6 + geometry.rgb_bytes);
            break :blk .{ .screen = .{ .revision = std.mem.readInt(u32, b[0..4], .big), .brightness = b[4], .power = b[5], .rgb = b[6..][0..geometry.rgb_bytes].* } };
        },
        .input, .inject_input => blk: {
            const b = try fixed(p, 7);
            const i = Input{ .control = b[0], .event = b[1], .position = std.mem.readInt(i32, b[2..6], .big), .steps = b[6] };
            break :blk if (kind == .input) .{ .input = i } else .{ .inject_input = i };
        },
        .power => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .power = .{ .on = b[0] } };
        },
        .log_get => blk: {
            const b = try fixed(p, 4);
            break :blk .{ .log_get = .{ .after = std.mem.readInt(u32, b[0..4], .big) } };
        },
        .log_lines => blk: {
            if (p.len < 7) return error.BadPayload;
            var l = LogLines{ .next = std.mem.readInt(u32, p[0..4], .big), .count = p[4], .len = std.mem.readInt(u16, p[5..7], .big) };
            if (l.len > log_data_max or p.len != 7 + @as(usize, l.len)) return error.BadPayload;
            // every record must lie inside the data and the count must match
            var off: usize = 0;
            var n: u8 = 0;
            while (off < l.len) : (n +%= 1) {
                if (off + 5 > l.len) return error.BadPayload;
                const len = p[7 + off + 4];
                if (len > log_line_max or off + 5 + len > l.len) return error.BadPayload;
                off += 5 + @as(usize, len);
            }
            if (n != l.count) return error.BadPayload;
            @memcpy(l.data[0..l.len], p[7 .. 7 + @as(usize, l.len)]);
            break :blk .{ .log_lines = l };
        },
        .config_get => blk: {
            _ = try fixed(p, 0);
            break :blk .config_get;
        },
        .status_get => blk: {
            _ = try fixed(p, 0);
            break :blk .status_get;
        },
        .set_timezone => blk: {
            const b = try fixed(p, 1 + config.text_max);
            var o: usize = 0;
            break :blk .{ .set_timezone = try getText(b, &o) };
        },
        .credentials => blk: {
            const b = try fixed(p, 64);
            break :blk .{ .credentials = .{ .control = b[0..32].*, .admin = b[32..64].* } };
        },
        .config => blk: {
            const b = try fixed(p, config.encoded_len);
            break :blk .{ .config = config.decode(b) catch return error.BadPayload };
        },
        .config_patch => blk: {
            // the parameter list is variable, so the payload runs from the fixed part up to the
            // whole struct rather than being one exact length
            if (p.len < ConfigPatch.fixed_len or p.len > ConfigPatch.wire_len) return error.BadPayload;
            const b = p;
            var w = ConfigPatch{};
            var o: usize = 0;
            w.has = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.brightness = b[o];
            w.base = b[o + 1];
            w.generator = b[o + 2];
            o += 3;
            w.timezone = try getText(b, &o);
            w.ntp_server = b[o..][0..4].*;
            o += 4;
            w.ntp_interval_s = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.frame_timeout_ms = std.mem.readInt(u16, b[o..][0..2], .little);
            o += 2;
            w.metrics_interval_s = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.discovery = b[o];
            o += 1;
            w.discovery_prefix = try getText(b, &o);
            w.expected_revision = std.mem.readInt(u32, b[o..][0..4], .little);
            o += 4;
            w.clock_font = b[o];
            w.clock_colour_mode = b[o + 1];
            w.clock_colour = b[o + 2 ..][0..3].*;
            w.clock_colour2 = b[o + 5 ..][0..3].*;
            w.clock_gradient = b[o + 8];
            w.clock_spread = b[o + 9];
            w.ip_mode = b[o + 10];
            w.clock_digit = b[o + 11];
            o += 12;
            w.night = b[o];
            w.night_brightness = b[o + 1];
            w.night_lead_min = b[o + 2];
            w.latitude = std.mem.readInt(i16, b[o + 3 ..][0..2], .little);
            w.longitude = std.mem.readInt(i16, b[o + 5 ..][0..2], .little);
            o += 7;
            w.berry_enabled = b[o];
            w.berry_heap_kb = std.mem.readInt(u16, b[o + 1 ..][0..2], .little);
            w.berry_handler_ms = std.mem.readInt(u16, b[o + 3 ..][0..2], .little);
            o += 5;
            if (b.len < o + 1) return error.BadPayload;
            w.param_count = @min(b[o], w.params.len);
            o += 1;
            if (b.len < o + @as(usize, w.param_count) * 6) return error.BadPayload;
            for (0..w.param_count) |i| {
                w.params[i] = .{ .owner = b[o], .slot = b[o + 1], .value = std.mem.readInt(u32, b[o + 2 ..][0..4], .big) };
                o += 6;
            }
            break :blk .{ .config_patch = w };
        },
        .config_save => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .config_save = .{ .has_revision = b[0], .revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .save_result => blk: {
            const b = try fixed(p, 5);
            const status = enumFromInt(Status, b[0]) orelse return error.BadPayload;
            break :blk .{ .save_result = .{ .status = status, .saved_revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .mqtt_put => blk: {
            const b = try fixed(p, MqttPut.wire_len);
            var m = MqttPut{};
            var o: usize = 0;
            m.has = b[o];
            m.enabled = b[o + 1];
            o += 2;
            m.host = try getText(b, &o);
            m.port = std.mem.readInt(u16, b[o..][0..2], .little);
            o += 2;
            m.username = try getText(b, &o);
            m.password = try getText(b, &o);
            m.client_id = try getText(b, &o);
            m.prefix = try getText(b, &o);
            m.tls = b[o];
            break :blk .{ .mqtt_put = m };
        },
        .ntfy_put => blk: {
            break :blk .{ .ntfy_put = try NtfyPut.get(p) };
        },
        .ntfy_config => blk: {
            break :blk .{ .ntfy_config = try NtfyConfig.get(p) };
        },
        .ntfy_status => blk: {
            const b = try fixed(p, NtfyStatus.wire_len);
            break :blk .{ .ntfy_status = try NtfyStatus.get(b) };
        },
        .status => blk: {
            const b = try fixed(p, StatusSnapshot.wire_len);
            var st = StatusSnapshot{};
            var o: usize = 0;
            st.renderer_state = b[o];
            o += 1;
            st.epoch = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.presented = std.mem.readInt(u64, b[o..][0..8], .big);
            o += 8;
            st.base = b[o];
            st.generator = b[o + 1];
            st.overlay = b[o + 2];
            st.brightness = b[o + 3];
            o += 4;
            st.uptime_s = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.mem_available_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.cpu_pct = b[o];
            o += 1;
            st.rss_supervisor_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.rss_renderer_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.rss_netd_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.restarts = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.fps_x10 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.ip_present = b[o];
            o += 1;
            st.ip = b[o..][0..4].*;
            o += 4;
            st.time_state = b[o];
            o += 1;
            st.time_age_s = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.config_revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.saved_revision = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.boot_id = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.sample_age_ms = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.mac = b[o..][0..6].*;
            o += 6;
            st.mac_present = b[o];
            o += 1;
            st.load_1m_x100 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.mem_free_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.wifi_level_dbm = std.mem.readInt(i16, b[o..][0..2], .big);
            o += 2;
            st.wifi_quality = b[o];
            o += 1;
            st.cpu_supervisor_pct_x10 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.cpu_renderer_pct_x10 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.cpu_netd_pct_x10 = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.tmpfs_used_kb = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.battery_mv = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.battery_pct = b[o];
            st.usb_present = b[o + 1];
            o += 2;
            st.power = b[o];
            o += 1;
            st.clock = ClockStyle.get(b[o .. o + ClockStyle.wire_len]);
            o += ClockStyle.wire_len;
            st.ip_mode = b[o];
            o += 1;
            st.ntfy = try NtfyStatus.get(b[o .. o + NtfyStatus.wire_len]);
            o += NtfyStatus.wire_len;
            inline for (.{ &st.mem_total_kb, &st.tmpfs_total_kb, &st.flash_total_kb, &st.flash_used_kb }) |f| {
                f.* = std.mem.readInt(u32, b[o..][0..4], .big);
                o += 4;
            }
            st.night_phase = b[o];
            st.night_override = b[o + 1];
            o += 2;
            st.seed = std.mem.readInt(u32, b[o..][0..4], .big);
            o += 4;
            st.menu = b[o];
            st.menu_item = b[o + 1];
            st.menu_state = b[o + 2];
            o += 3;
            inline for (.{
                &st.net_rx_bytes,   &st.net_tx_bytes,   &st.net_rx_packets, &st.net_tx_packets,
                &st.net_rx_errors,  &st.net_rx_dropped, &st.net_tx_errors,  &st.net_tx_dropped,
                &st.net_rx_bps,     &st.net_tx_bps,     &st.mem_cached_kb,  &st.mem_dirty_kb,
                &st.mem_writeback_kb, &st.mem_slab_kb,  &st.saves,          &st.save_failures,
                &st.save_bytes,
            }) |f| {
                f.* = std.mem.readInt(u32, b[o..][0..4], .big);
                o += 4;
            }
            st.save_last_ms = std.mem.readInt(u16, b[o..][0..2], .big);
            o += 2;
            st.berry_state = b[o];
            o += 1;
            st.berry = BerryStatus.get(b[o..][0..BerryStatus.wire_len]);
            o += BerryStatus.wire_len;
            break :blk .{ .status = st };
        },
        .ready => blk: {
            _ = try fixed(p, 0);
            break :blk .ready;
        },
        .result => blk: {
            const b = try fixed(p, 5);
            const status = enumFromInt(Status, b[0]) orelse return error.BadPayload;
            break :blk .{ .result = .{ .status = status, .revision = std.mem.readInt(u32, b[1..5], .big) } };
        },
        .set_base => blk: {
            const b = try fixed(p, 6 + ClockStyle.wire_len + Transition.wire_len);
            break :blk .{ .set_base = .{ .base = b[0], .generator = b[1], .seed = std.mem.readInt(u32, b[2..6], .big), .style = ClockStyle.get(b[6..]), .transition = Transition.get(b[6 + ClockStyle.wire_len ..]) } };
        },
        .notify => blk: {
            if (p.len < 12) return error.BadPayload;
            const len = p[11];
            if (len == 0 or len > 128 or p.len != 12 + @as(usize, len)) return error.BadPayload;
            break :blk .{ .notify = Notify.init(p[12..], p[0..3].*, std.mem.readInt(u16, p[3..5], .big), Transition.get(p[5..11])) };
        },
        .frame => blk: {
            const b = try fixed(p, 8 + geometry.rgb_bytes);
            break :blk .{ .frame = .{ .duration_s = std.mem.readInt(u16, b[0..2], .big), .transition = Transition.get(b[2..8]), .rgb = b[8..][0..geometry.rgb_bytes].* } };
        },
        .brightness => blk: {
            const b = try fixed(p, 1);
            break :blk .{ .brightness = .{ .value = b[0] } };
        },
        .reseed => blk: {
            const b = try fixed(p, 4);
            break :blk .{ .reseed = .{ .seed = std.mem.readInt(u32, b[0..4], .big) } };
        },
        .arm_stream => blk: {
            _ = try fixed(p, 0);
            break :blk .arm_stream;
        },
        .time_corrected => blk: {
            _ = try fixed(p, 0);
            break :blk .time_corrected;
        },
        .ip_changed => blk: {
            const b = try fixed(p, 5);
            break :blk .{ .ip_changed = .{ .present = b[0], .addr = b[1..5].* } };
        },
        .stop => blk: {
            _ = try fixed(p, 0);
            break :blk .stop;
        },
    };
    return .{ .request_id = d.header.request_id, .epoch = d.header.epoch, .message = message };
}
