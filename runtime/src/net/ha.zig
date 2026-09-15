const std = @import("std");
const api = @import("api.zig");
pub const PatchPolicy = enum { transient, durable, rejected };
pub fn patchPolicy(p: api.ConfigPatch, controls: bool) PatchPolicy {
    @setEvalBranchQuota(10000);
    var durable = false;
    // default-deny every field not named here, including fields added to the API later.
    inline for (@typeInfo(api.ConfigPatch).@"struct".fields) |field| {
        const name = field.name;
        const value = @field(p, name);
        if (comptime std.mem.eql(u8, name, "generator_params")) {
            if (value.len != 0) return .rejected;
        } else if (value != null) {
            if (comptime oneOf(name, &.{ "brightness", "base", "generator" })) {
                // existing transient commands keep working without HA discovery.
            } else if (comptime oneOf(name, &.{ "clock_font", "clock_colour_mode", "clock_colour", "clock_colour2", "clock_gradient", "clock_spread", "clock_digit", "ip_mode", "timezone", "ntp_server", "ntp_interval_s", "night", "night_brightness", "night_lead_min", "expected_revision" })) {
                durable = true;
            } else return .rejected;
        }
    }
    return if (durable) (if (controls) .durable else .rejected) else .transient;
}
fn oneOf(comptime name: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

test "mqtt durable settings require opt in and privileged fields never qualify" {
    try std.testing.expectEqual(PatchPolicy.rejected, patchPolicy(.{ .night = true }, false));
    try std.testing.expectEqual(PatchPolicy.durable, patchPolicy(.{ .clock_font = .mini }, true));
    try std.testing.expectEqual(PatchPolicy.rejected, patchPolicy(.{ .discovery = true }, true));
    try std.testing.expectEqual(PatchPolicy.rejected, patchPolicy(.{ .berry_enabled = true }, true));
    try std.testing.expectEqual(PatchPolicy.rejected, patchPolicy(.{ .battery_shutdown = false, .brightness = 40 }, true));
    try std.testing.expectEqual(PatchPolicy.transient, patchPolicy(.{ .brightness = 40, .base = .art }, false));
}

pub fn removeEntity(remove_all: bool, discovery: bool, controls: bool, writable: bool) bool {
    return remove_all or !discovery or (writable and !controls);
}
test "disabled controls clear retained entities even during a normal reconnect pass" {
    try std.testing.expect(removeEntity(false, true, false, true));
    try std.testing.expect(removeEntity(false, false, true, true));
    try std.testing.expect(!removeEntity(false, true, true, true));
    try std.testing.expect(!removeEntity(false, true, false, false));
    try std.testing.expect(removeEntity(true, true, true, false));
}

pub const Component = enum { sensor, binary_sensor, event, @"switch", select, number, text };
pub const Entity = struct {
    key: []const u8,
    name: []const u8,
    template: []const u8 = "",
    unit: []const u8 = "",
    device_class: []const u8 = "",
    state_class: []const u8 = "",
    component: Component = .sensor,
    /// topic under the prefix that carries the state or the events
    topic: []const u8 = "metrics",
    /// json array body for an event entity's `event_types`
    event_types: []const u8 = "",
    diagnostic: bool = true,
    // writable entities (switch/select/number/text): the cmd/ subtopic to publish to, and how
    // to shape the payload. durable commands are limited by patchPolicy and require discovery_controls.
    command: []const u8 = "", // e.g. "cmd/action"; when set, a command_topic is emitted
    command_template: []const u8 = "", // ha command_template producing the device json payload
    options: []const u8 = "", // select: json array of option strings
    min: i32 = 0, // number: range; emitted when max > min
    max: i32 = 0,
    payload_on: []const u8 = "", // switch: the exact cmd payloads
    payload_off: []const u8 = "",
};
pub const entities = [_]Entity{
    .{ .key = "power_control", .name = "display power", .component = .@"switch", .topic = "state", .template = "{{ 'ON' if value_json.power else 'OFF' }}", .device_class = "outlet", .diagnostic = false, .command = "cmd/action", .payload_on = "{\\\"action\\\":\\\"power\\\",\\\"power\\\":true}", .payload_off = "{\\\"action\\\":\\\"power\\\",\\\"power\\\":false}" },
    .{ .key = "scene_control", .name = "scene", .component = .select, .topic = "state", .template = "{{ value_json.base }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"base\\\": value} | to_json }}", .options = "\"clock\",\"art\",\"canvas\"" },
    .{ .key = "brightness_control", .name = "brightness", .component = .number, .topic = "state", .template = "{{ value_json.brightness }}", .unit = "%", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"brightness\\\": value | int} | to_json }}", .min = 1, .max = 100 },
    .{ .key = "notify_control", .name = "notification", .component = .text, .diagnostic = false, .command = "cmd/notify", .command_template = "{{ {\\\"text\\\": value} | to_json }}" },
    .{ .key = "clock_font_control", .name = "clock font", .component = .select, .topic = "config", .template = "{{ value_json.clock.font }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_font\\\": value} | to_json }}", .options = "\"classic\",\"mini\",\"segment\",\"big\",\"block\",\"hires\"" },
    .{ .key = "clock_colour_mode_control", .name = "clock colour mode", .component = .select, .topic = "config", .template = "{{ value_json.clock.colour_mode }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_colour_mode\\\": value} | to_json }}", .options = "\"solid\",\"gradient\"" },
    .{ .key = "clock_colour_control", .name = "clock colour", .component = .text, .topic = "config", .template = "{{ value_json.clock.colour }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_colour\\\": value} | to_json }}" },
    .{ .key = "clock_colour2_control", .name = "clock second colour", .component = .text, .topic = "config", .template = "{{ value_json.clock.colour2 }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_colour2\\\": value} | to_json }}" },
    .{ .key = "clock_gradient_control", .name = "clock gradient", .component = .select, .topic = "config", .template = "{{ value_json.clock.gradient }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_gradient\\\": value} | to_json }}", .options = "\"horizontal\",\"vertical\",\"diagonal\"" },
    .{ .key = "clock_digit_control", .name = "clock digit style", .component = .select, .topic = "config", .template = "{{ value_json.clock.digits }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_digit\\\": value} | to_json }}", .options = "\"solid\",\"outline\",\"shadow\"" },
    .{ .key = "clock_spread_control", .name = "clock gradient spread", .component = .number, .topic = "config", .template = "{{ value_json.clock.spread }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"clock_spread\\\": value | int} | to_json }}", .min = 0, .max = 255 },
    .{ .key = "ip_mode_control", .name = "ip layout", .component = .select, .topic = "config", .template = "{{ value_json.ip_mode }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"ip_mode\\\": value} | to_json }}", .options = "\"lines\",\"mini\",\"scroll\",\"big\"" },
    .{ .key = "generator_control", .name = "art generator", .component = .select, .topic = "state", .template = "{{ value_json.generator }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"base\\\": \\\"art\\\", \\\"generator\\\": value} | to_json }}", .options = "\"popsquares\",\"plasma\",\"cube\",\"terrain\"" },
    .{ .key = "timezone_control", .name = "timezone", .component = .text, .topic = "config", .template = "{{ value_json.timezone }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"timezone\\\": value} | to_json }}" },
    .{ .key = "ntp_server_control", .name = "ntp server", .component = .text, .topic = "config", .template = "{{ value_json.ntp.server if value_json.ntp.server else '' }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"ntp_server\\\": value} | to_json }}" },
    .{ .key = "ntp_interval_control", .name = "ntp interval", .component = .select, .topic = "config", .template = "{{ value_json.ntp.interval_s }}", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"ntp_interval_s\\\": value | int} | to_json }}", .options = "\"300\",\"600\"" },
    .{ .key = "night_control", .name = "night dimming", .component = .@"switch", .topic = "config", .template = "{{ 'ON' if value_json.night.enabled else 'OFF' }}", .diagnostic = false, .command = "cmd/config", .payload_on = "{\\\"night\\\":true}", .payload_off = "{\\\"night\\\":false}" },
    .{ .key = "night_brightness_control", .name = "night brightness", .component = .number, .topic = "config", .template = "{{ value_json.night.brightness }}", .unit = "%", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"night_brightness\\\": value | int} | to_json }}", .min = 1, .max = 100 },
    .{ .key = "night_lead_control", .name = "night lead", .component = .number, .topic = "config", .template = "{{ value_json.night.lead_min }}", .unit = "min", .diagnostic = false, .command = "cmd/config", .command_template = "{{ {\\\"night_lead_min\\\": value | int} | to_json }}", .min = 0, .max = 120 },

    .{ .key = "power", .name = "display power", .component = .binary_sensor, .topic = "state", .template = "{{ 'ON' if value_json.power else 'OFF' }}", .device_class = "power" },
    .{ .key = "button_left", .name = "left button", .component = .event, .topic = "input/left", .event_types = "\"press\",\"release\",\"long\"", .device_class = "button", .diagnostic = false },
    .{ .key = "button_middle", .name = "middle button", .component = .event, .topic = "input/middle", .event_types = "\"press\",\"release\",\"long\"", .device_class = "button", .diagnostic = false },
    .{ .key = "button_right", .name = "right button", .component = .event, .topic = "input/right", .event_types = "\"press\",\"release\",\"long\"", .device_class = "button", .diagnostic = false },
    .{ .key = "knob", .name = "knob", .component = .event, .topic = "input/knob", .event_types = "\"press\",\"release\",\"long\"", .device_class = "button", .diagnostic = false },
    .{ .key = "rotary", .name = "rotary", .component = .event, .topic = "input/rotary", .event_types = "\"cw\",\"ccw\"", .diagnostic = false },
    .{ .key = "uptime", .name = "uptime", .template = "{{ value_json.uptime_s }}", .unit = "s", .device_class = "duration", .state_class = "" },
    .{ .key = "memory_available", .name = "memory available", .template = "{{ value_json.memory_available_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "cpu", .name = "cpu utilization", .template = "{{ value_json.cpu_pct }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "rss_supervisor", .name = "supervisor rss", .template = "{{ value_json.rss_kb.supervisor }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "rss_renderer", .name = "renderer rss", .template = "{{ value_json.rss_kb.renderer }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "rss_netd", .name = "netd rss", .template = "{{ value_json.rss_kb.netd }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "renderer_restarts", .name = "renderer restarts", .template = "{{ value_json.renderer_restarts }}", .unit = "", .device_class = "", .state_class = "total" },
    .{ .key = "mqtt_reconnects", .name = "mqtt reconnects", .template = "{{ value_json.mqtt_reconnects }}", .unit = "", .device_class = "", .state_class = "total" },
    .{ .key = "scene", .name = "scene", .template = "{{ value_json.scene }}", .unit = "", .device_class = "", .state_class = "" },
    .{ .key = "brightness", .name = "brightness", .template = "{{ value_json.brightness }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "night", .name = "night schedule", .template = "{{ value_json.night }}", .unit = "", .device_class = "", .state_class = "" },
    .{ .key = "fps", .name = "achieved fps", .template = "{{ value_json.fps if value_json.fps is not none else 'unknown' }}", .unit = "fps", .device_class = "", .state_class = "measurement" },
    .{ .key = "presented", .name = "frames presented", .template = "{{ value_json.presented }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "time_state", .name = "time sync", .template = "{{ value_json.time.state }}", .unit = "", .device_class = "", .state_class = "" },
    .{ .key = "load_1m", .name = "load average 1m", .template = "{{ value_json.load_1m }}", .unit = "", .device_class = "", .state_class = "measurement" },
    // the device's own counters. the rate pair reads null until a second sample exists, and
    // "frames the driver dropped" is deliberately not called packet loss -- see runtime.md
    .{ .key = "net_rx_rate", .name = "wifi receive rate", .template = "{{ value_json.net.rx_bytes_per_s }}", .unit = "B/s", .device_class = "data_rate", .state_class = "measurement" },
    .{ .key = "net_tx_rate", .name = "wifi transmit rate", .template = "{{ value_json.net.tx_bytes_per_s }}", .unit = "B/s", .device_class = "data_rate", .state_class = "measurement" },
    .{ .key = "net_rx_bytes", .name = "wifi received", .template = "{{ value_json.net.rx_bytes }}", .unit = "B", .device_class = "data_size", .state_class = "total_increasing" },
    .{ .key = "net_tx_bytes", .name = "wifi transmitted", .template = "{{ value_json.net.tx_bytes }}", .unit = "B", .device_class = "data_size", .state_class = "total_increasing" },
    .{ .key = "net_rx_dropped", .name = "wifi frames the driver dropped", .template = "{{ value_json.net.rx_dropped }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "net_rx_errors", .name = "wifi receive errors", .template = "{{ value_json.net.rx_errors }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "net_tx_errors", .name = "wifi transmit errors", .template = "{{ value_json.net.tx_errors }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "memory_cached", .name = "memory cached", .template = "{{ value_json.memory_cached_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "memory_dirty", .name = "memory dirty", .template = "{{ value_json.memory_dirty_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "memory_slab", .name = "memory slab", .template = "{{ value_json.memory_slab_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "config_saves", .name = "settings saves", .template = "{{ value_json.config_saves.count }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "config_save_failures", .name = "settings save failures", .template = "{{ value_json.config_saves.failures }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
    .{ .key = "config_save_bytes", .name = "settings bytes written", .template = "{{ value_json.config_saves.bytes }}", .unit = "B", .device_class = "data_size", .state_class = "total_increasing" },
    .{ .key = "memory_free", .name = "memory free", .template = "{{ value_json.memory_free_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "tmpfs_used", .name = "tmpfs and shmem used", .template = "{{ value_json.tmpfs_used_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "memory_total", .name = "memory total", .template = "{{ value_json.memory_total_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "memory_used_pct", .name = "memory used", .template = "{{ (100 * (value_json.memory_total_kb - value_json.memory_available_kb) / value_json.memory_total_kb) | round(0) if value_json.memory_total_kb else 'unknown' }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "flash_used", .name = "flash used", .template = "{{ value_json.flash_used_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "flash_total", .name = "flash total", .template = "{{ value_json.flash_total_kb }}", .unit = "kB", .device_class = "data_size", .state_class = "measurement" },
    .{ .key = "flash_used_pct", .name = "flash used", .template = "{{ (100 * value_json.flash_used_kb / value_json.flash_total_kb) | round(0) if value_json.flash_total_kb else 'unknown' }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "wifi_rssi", .name = "wifi signal", .template = "{{ value_json.wifi.rssi_dbm }}", .unit = "dBm", .device_class = "signal_strength", .state_class = "measurement" },
    .{ .key = "wifi_quality", .name = "wifi link quality", .template = "{{ value_json.wifi.quality }}", .unit = "", .device_class = "", .state_class = "measurement" },
    .{ .key = "cpu_supervisor", .name = "supervisor cpu", .template = "{{ value_json.cpu_pct_by_process.supervisor }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "cpu_renderer", .name = "renderer cpu", .template = "{{ value_json.cpu_pct_by_process.renderer }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "cpu_netd", .name = "netd cpu", .template = "{{ value_json.cpu_pct_by_process.netd }}", .unit = "%", .device_class = "", .state_class = "measurement" },
    .{ .key = "battery_voltage", .name = "battery voltage", .template = "{{ value_json.battery.millivolts }}", .unit = "mV", .device_class = "voltage", .state_class = "measurement" },
    .{ .key = "battery", .name = "battery", .template = "{{ value_json.battery.percent }}", .unit = "%", .device_class = "battery", .state_class = "measurement" },
    .{ .key = "usb_power", .name = "usb power", .template = "{{ 'on' if value_json.battery.usb_present else ('off' if value_json.battery.usb_present is not none else 'unknown') }}", .unit = "", .device_class = "", .state_class = "" },
};

test "discovery cleans the old prefix before publishing the new one" {
    try std.testing.expect(@hasDecl(@This(), "Discovery"));
    if (comptime @hasDecl(@This(), "Discovery")) {
        var d = @field(@This(), "Discovery"){};
        d.start("old", "device", true);
        try std.testing.expect(!d.remove);
        d.start("new", "device", true);
        try std.testing.expect(d.remove);
        try std.testing.expectEqualStrings("old", d.prefix.slice());
        d.start("newest", "device", true); // a reconnect or another edit preserves cleanup
        try std.testing.expectEqualStrings("old", d.prefix.slice());
        d.finish("newest", "device", true);
        try std.testing.expect(d.active and !d.remove);
        try std.testing.expectEqualStrings("newest", d.prefix.slice());
        d.start("newest", "device", false);
        d.finish("newest", "device", false);
        try std.testing.expect(!d.active);
        d.start("newest", "device", false); // disabled on startup still clears retained records
        try std.testing.expect(d.active and d.remove);
    }
}

/// one frozen identity per pass. changes first clear the old retained records, then use the
/// latest settings; reconnecting midway through removal must never lose that old identity.
pub const Discovery = struct {
    prefix: @import("../supervisor/config.zig").Text = .{},
    id: [24]u8 = undefined,
    id_len: usize = 0,
    active: bool = false,
    remove: bool = false,
    index: usize = 0,
    pending: u16 = 0,

    pub fn start(self: *Discovery, prefix: []const u8, id: []const u8, enabled: bool) void {
        if (self.active and self.remove) return;
        const changed = self.id_len > 0 and (!std.mem.eql(u8, self.prefix.slice(), prefix) or !std.mem.eql(u8, self.id[0..self.id_len], id));
        self.remove = changed or !enabled;
        if (!changed) {
            self.prefix.set(prefix) catch unreachable;
            @memcpy(self.id[0..id.len], id);
            self.id_len = id.len;
        }
        self.index = 0;
        self.pending = 0;
        self.active = true;
    }

    pub fn reconnect(self: *Discovery, prefix: []const u8, id: []const u8, enabled: bool) void {
        self.start(prefix, id, enabled);
        self.index = 0;
        self.pending = 0;
    }

    pub fn acknowledge(self: *Discovery, id: u16) void {
        if (self.pending == 0 or self.pending != id) return;
        self.pending = 0;
        self.index += 1;
    }

    pub fn finish(self: *Discovery, prefix: []const u8, id: []const u8, enabled: bool) void {
        const was_removing = self.remove;
        self.active = false;
        self.remove = false;
        if (was_removing) {
            self.id_len = 0;
            if (enabled) self.start(prefix, id, enabled);
        }
    }
};

test "writable discovery includes valid id-free commands and preserves readonly identities" {
    var controls: usize = 0;
    var readonly: usize = 0;
    for (entities) |e| {
        if (e.command.len == 0) {
            if (oneOfRuntime(e.key, &.{ "power", "scene", "brightness", "night" })) readonly += 1;
            continue;
        }
        controls += 1;
        try std.testing.expect(std.mem.endsWith(u8, e.key, "_control"));
        try std.testing.expect(std.mem.indexOf(u8, e.command_template, "request_id") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.payload_on, "request_id") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.command_template, "epoch") == null);
        try std.testing.expect(std.mem.indexOf(u8, e.payload_on, "epoch") == null);
        if (std.mem.eql(u8, e.key, "brightness_control")) try std.testing.expectEqual(@as(i32, 1), e.min);
        if (std.mem.eql(u8, e.key, "generator_control")) try std.testing.expect(std.mem.indexOf(u8, e.options, "\"terrain\"") != null);
        if (std.mem.eql(u8, e.key, "scene_control")) try std.testing.expectEqualStrings("\"clock\",\"art\",\"canvas\"", e.options);
    }
    try std.testing.expectEqual(@as(usize, 19), controls);
    try std.testing.expectEqual(@as(usize, 4), readonly);
}
fn oneOfRuntime(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

test "every discovery document is valid json and static power payloads mint fresh ids" {
    try std.testing.expect(@hasDecl(@This(), "render"));
    if (comptime @hasDecl(@This(), "render")) {
        var out: [1024]u8 = undefined;
        for (entities) |e| {
            const body = try @field(@This(), "render")(&out, e, "tc002_001122334455", "p" ** 64, 30);
            const doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
            defer doc.deinit();
            if (e.command.len > 0) try std.testing.expect(doc.value.object.contains("command_topic"));
            if (std.mem.eql(u8, e.key, "notify_control")) try std.testing.expect(!doc.value.object.contains("state_topic"));
            if (std.mem.eql(u8, e.key, "power_control")) {
                const payload = doc.value.object.get("payload_on").?.string;
                var arena: api.Arena = undefined;
                const first = api.parseBody(.action, payload, &arena, 100);
                try std.testing.expect(first == .op);
                try std.testing.expectEqual(@as(u64, 100), first.op.action.request_id);
                try std.testing.expect(first.op.action.epoch == null);
                const second = api.parseBody(.action, payload, &arena, 101);
                try std.testing.expectEqual(@as(u64, 101), second.op.action.request_id);
            }
        }
    }
}

pub fn render(buf: []u8, e: Entity, dev: []const u8, prefix: []const u8, interval: u64) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.print("{{\"name\":\"{s}\",\"unique_id\":\"{s}_{s}\",\"availability_topic\":\"{s}/availability\"", .{ e.name, dev, e.key, prefix });
    // everything with a template has a state to read; a text entity without one (the
    // notification box) is command-only and must not advertise a state topic.
    if (e.component != .text or e.template.len > 0) try w.print(",\"state_topic\":\"{s}/{s}\"", .{ prefix, e.topic });
    if (e.command.len > 0) try w.print(",\"command_topic\":\"{s}/{s}\"", .{ prefix, e.command });
    switch (e.component) {
        .sensor => try w.print(",\"value_template\":\"{s}\",\"expire_after\":{d}", .{ e.template, interval * 3 }),
        .binary_sensor => try w.print(",\"value_template\":\"{s}\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"", .{e.template}),
        .event => try w.print(",\"event_types\":[{s}]", .{e.event_types}),
        .@"switch" => try w.print(",\"value_template\":\"{s}\",\"state_on\":\"ON\",\"state_off\":\"OFF\",\"payload_on\":\"{s}\",\"payload_off\":\"{s}\"", .{ e.template, e.payload_on, e.payload_off }),
        .select => try w.print(",\"value_template\":\"{s}\",\"command_template\":\"{s}\",\"options\":[{s}]", .{ e.template, e.command_template, e.options }),
        .number => try w.print(",\"value_template\":\"{s}\",\"command_template\":\"{s}\",\"min\":{d},\"max\":{d},\"mode\":\"slider\"", .{ e.template, e.command_template, e.min, e.max }),
        .text => {
            if (e.template.len > 0) try w.print(",\"value_template\":\"{s}\"", .{e.template});
            try w.print(",\"command_template\":\"{s}\"", .{e.command_template});
        },
    }
    if (e.diagnostic) try w.writeAll(",\"entity_category\":\"diagnostic\"");
    if (e.unit.len > 0) try w.print(",\"unit_of_measurement\":\"{s}\"", .{e.unit});
    if (e.device_class.len > 0) try w.print(",\"device_class\":\"{s}\"", .{e.device_class});
    if (e.state_class.len > 0) try w.print(",\"state_class\":\"{s}\"", .{e.state_class});
    try w.print(",\"device\":{{\"identifiers\":[\"{s}\"],\"name\":\"tc002\",\"model\":\"tc002 custom runtime\",\"manufacturer\":\"ulanzi (custom firmware)\",\"sw_version\":\"plan-b\"}},\"origin\":{{\"name\":\"tc002-netd\"}}}}", .{dev});
    return w.buffered();
}

test "reconnect retries all old discovery tombstones that may have been lost with the socket" {
    var d = Discovery{};
    d.start("old", "device", true);
    d.start("new", "device", true);
    d.index = 7;
    d.reconnect("new", "device", true);
    try std.testing.expectEqual(@as(usize, 0), d.index);
    try std.testing.expectEqualStrings("old", d.prefix.slice());
    try std.testing.expect(d.remove);
}

test "discovery advances only after its own publish acknowledgement" {
    var d = Discovery{};
    d.start("old", "device", true);
    d.pending = 42;
    d.acknowledge(41);
    try std.testing.expectEqual(@as(usize, 0), d.index);
    d.acknowledge(42);
    try std.testing.expectEqual(@as(usize, 1), d.index);
    try std.testing.expectEqual(@as(u16, 0), d.pending);
    d.acknowledge(42);
    try std.testing.expectEqual(@as(usize, 1), d.index);
}

/// reserve ids for both commands that a transient config patch may emit.
pub fn transientIds(last_id: *u64) struct { brightness: u64, scene: u64 } {
    last_id.* += 2;
    return .{ .brightness = last_id.* - 1, .scene = last_id.* };
}

test "a scene config command cannot consume the next power command's dedup id" {
    var last_id: u64 = 100;
    const ids = transientIds(&last_id);
    last_id += 1; // the next id-free action uses netd's same counter
    var arena: api.Arena = undefined;
    const power = api.parseBody(.action, "{\"action\":\"power\",\"power\":false}", &arena, last_id);
    try std.testing.expect(power == .op);
    try std.testing.expect(ids.brightness != ids.scene);
    try std.testing.expect(ids.scene != power.op.action.request_id);
}
