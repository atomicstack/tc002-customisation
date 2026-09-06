//! tc002-netd: the network daemon. an http/1.1 server for /api/v1 and an mqtt 3.1.1 client, both
//! in one epoll loop with fixed buffers, running as an unprivileged uid with exactly two inherited
//! descriptors: fd 3, the supervisor's seqpacket channel, and fd 5, the already-bound listener.
//! it holds no authoritative state: every scene command is relayed to the supervisor, which
//! forwards it to the live renderer and returns the renderer's own result.
const std = @import("std");
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const http = @import("net/http.zig");
const api = @import("net/api.zig");
const json = @import("net/json.zig");
const mqtt = @import("net/mqtt.zig");
const messages = @import("ipc/messages.zig");
const codec = @import("ipc/codec.zig");
const config = @import("supervisor/config.zig");
const geometry = @import("panel/geometry.zig");
const scene = @import("scene/scene.zig");

const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const ns_per_s = std.time.ns_per_s;

const supervisor_fd: sys.Fd = 3;
const listener_fd: sys.Fd = 5;
const max_conns = 4;
const in_buf_len = http.max_head + json.max_body;
const out_buf_len = 4096;
const request_timeout_ns: u64 = 5 * ns_per_s;
const idle_timeout_ns: u64 = 10 * ns_per_s;
const relay_timeout_ns: u64 = 2 * ns_per_s;
const state_coalesce_ns: u64 = 500_000_000;
const tick_ns: u64 = 250_000_000;
const mqtt_pending_max = 8;
const frames_per_second_max = 10;
const mqtt_frame_envelope = 8 + 4 + 2 + geometry.rgb_bytes;

const Tag = enum(u64) { timer = 1, supervisor = 2, listener = 3, mqtt = 4, conn_base = 16 };

const ConnState = enum { free, reading, relaying, writing };
const Awaiting = enum { none, renderer_result, status, config, save_result };

const Conn = struct {
    fd: sys.Fd = -1,
    state: ConnState = .free,
    in: [in_buf_len]u8 = undefined,
    in_len: usize = 0,
    head_len: usize = 0,
    body_len: usize = 0,
    have_head: bool = false,
    req: http.Request = undefined,
    started_ns: u64 = 0,
    last_ns: u64 = 0,
    awaiting: Awaiting = .none,
    pending_id: u64 = 0,
    client_id: u64 = 0,
    out: [out_buf_len]u8 = undefined,
    out_len: usize = 0,
    out_off: usize = 0,
};

const MqttPending = struct { used: bool = false, id: u64 = 0, since_ns: u64 = 0 };

/// a bounded text builder for json responses; overflow is remembered, never written past the end.
const Out = struct {
    buf: []u8,
    len: usize = 0,
    overflow: bool = false,

    fn add(self: *Out, s: []const u8) void {
        if (self.len + s.len > self.buf.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    fn fmt(self: *Out, comptime f: []const u8, args: anytype) void {
        const r = std.fmt.bufPrint(self.buf[self.len..], f, args) catch {
            self.overflow = true;
            return;
        };
        self.len += r.len;
    }

    fn str(self: *Out, s: []const u8) void {
        self.add("\"");
        for (s) |c| switch (c) {
            '"' => self.add("\\\""),
            '\\' => self.add("\\\\"),
            0...0x1f => self.fmt("\\u{x:0>4}", .{c}),
            else => self.add(&[1]u8{c}),
        };
        self.add("\"");
    }

    fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

var conns: [max_conns]Conn = undefined;
var packet_buf: [codec.max_message]u8 = undefined;
var send_buf: [codec.max_message]u8 = undefined;
var arena: api.Arena = undefined;
var json_buf: [2048]u8 = undefined;

const Netd = struct {
    ep: sys.Fd,
    timer: sys.Fd,
    stats: bool,
    creds: ?api.Credentials = null,
    cfg: config.Config = .{},
    have_cfg: bool = false,
    status: messages.StatusSnapshot = .{},
    status_at_ns: u64 = 0,
    next_id: u64 = 0x8000_0000_0000_0000,
    supervisor_dead: bool = false,
    // mqtt
    client: mqtt.Client = .{},
    mfd: ?sys.Fd = null,
    m_in: [4096]u8 = undefined,
    m_in_len: usize = 0,
    m_out: [4096]u8 = undefined,
    m_out_len: usize = 0,
    m_out_off: usize = 0,
    m_pending: [mqtt_pending_max]MqttPending = [_]MqttPending{.{}} ** mqtt_pending_max,
    m_connected: bool = false,
    m_last_error: [64]u8 = undefined,
    m_last_error_len: usize = 0,
    state_dirty: bool = true,
    last_state_pub_ns: u64 = 0,
    next_metrics_ns: u64 = 0,
    // home-assistant discovery: one entity per second, at most one pass in flight
    disc_index: u8 = 0,
    disc_active: bool = false,
    disc_remove: bool = false,
    disc_next_ns: u64 = 0,
    disc_published: bool = false,
    disc_prefix_used: config.Text = .{},
    // counters
    http_requests: u32 = 0,
    http_rejected: u32 = 0,
    mqtt_dropped: u32 = 0,
    mqtt_commands: u32 = 0,
    frames_in_second: u8 = 0,
    frame_second: u64 = 0,

    fn newId(self: *Netd) u64 {
        self.next_id += 1;
        return self.next_id;
    }

    fn sendSupervisor(self: *Netd, msg: messages.Message, request_id: u64, epoch: u32) bool {
        if (self.supervisor_dead) return false;
        const packet = messages.encodePacket(msg, request_id, epoch, &send_buf) catch return false;
        sys.sendPacket(supervisor_fd, packet) catch |e| {
            if (e != error.WouldBlock) log.warn("send to supervisor failed: {s}", .{sys.errText(e)});
            return false;
        };
        return true;
    }

    // http connections

    fn closeConn(self: *Netd, c: *Conn) void {
        _ = self;
        if (c.fd >= 0) sys.close(c.fd);
        c.* = .{};
    }

    fn respond(self: *Netd, c: *Conn, status: u16, content_type: []const u8, body: []const u8) void {
        _ = self;
        const r = http.writeResponse(&c.out, status, content_type, body);
        c.out_len = r.len;
        c.out_off = 0;
        c.state = .writing;
        c.awaiting = .none;
    }

    fn respondError(self: *Netd, c: *Conn, status: u16, code: []const u8, message: []const u8) void {
        var body: [256]u8 = undefined;
        const b = http.errorBody(&body, code, message, c.client_id);
        if (status >= 400) self.http_rejected += 1;
        self.respond(c, status, "application/json", b);
    }

    fn flushConn(self: *Netd, c: *Conn, now: u64) void {
        while (c.out_off < c.out_len) {
            const n = sys.write(c.fd, c.out[c.out_off..c.out_len]) catch |e| switch (e) {
                error.WouldBlock => {
                    sys.epollMod(self.ep, c.fd, linux.EPOLL.OUT, self.connTag(c));
                    c.last_ns = now;
                    return;
                },
                error.Interrupted => continue,
                else => {
                    self.closeConn(c);
                    return;
                },
            };
            c.out_off += n;
        }
        self.closeConn(c);
    }

    fn connTag(self: *Netd, c: *Conn) u64 {
        _ = self;
        const index = (@intFromPtr(c) - @intFromPtr(&conns)) / @sizeOf(Conn);
        return @intFromEnum(Tag.conn_base) + index;
    }

    fn acceptAll(self: *Netd, now: u64) void {
        while (true) {
            const fd = sys.accept(listener_fd) catch |e| {
                log.warn("accept failed: {s}", .{sys.errText(e)});
                return;
            } orelse return;
            var slot: ?*Conn = null;
            for (&conns) |*c| if (c.state == .free) {
                slot = c;
                break;
            };
            const c = slot orelse {
                // over the connection budget: a canned 429, best effort, then close
                const busy = "HTTP/1.1 429 Too Many Requests\r\ncontent-type: application/json\r\ncontent-length: 62\r\nconnection: close\r\n\r\n{\"error\":\"overload\",\"message\":\"too many connections\",\"request_id\":\"\"}";
                _ = sys.write(fd, busy) catch {};
                sys.close(fd);
                self.http_rejected += 1;
                continue;
            };
            c.* = .{ .fd = fd, .state = .reading, .started_ns = now, .last_ns = now };
            sys.setTcpNodelay(fd);
            sys.epollAdd(self.ep, fd, linux.EPOLL.IN, self.connTag(c)) catch {
                self.closeConn(c);
                continue;
            };
        }
    }

    fn readConn(self: *Netd, c: *Conn, now: u64) void {
        while (c.state == .reading) {
            if (c.in_len == c.in.len) {
                self.respondError(c, 413, "request_too_large", "the request exceeds the buffer");
                self.flushConn(c, now);
                return;
            }
            const n = sys.read(c.fd, c.in[c.in_len..]) catch |e| switch (e) {
                error.WouldBlock => return,
                error.Interrupted => continue,
                else => {
                    self.closeConn(c);
                    return;
                },
            };
            if (n == 0) {
                self.closeConn(c);
                return;
            }
            c.in_len += n;
            c.last_ns = now;
            self.tryDispatch(c, now);
        }
    }

    fn tryDispatch(self: *Netd, c: *Conn, now: u64) void {
        if (!c.have_head) {
            c.req = http.parseHead(c.in[0..c.in_len]) catch |e| switch (e) {
                error.Incomplete => return,
                error.TooLarge => {
                    self.respondError(c, 413, "head_too_large", "request headers are limited to 4096 bytes");
                    self.flushConn(c, now);
                    return;
                },
                error.Malformed => {
                    self.respondError(c, 400, "malformed_request", "the request could not be parsed");
                    self.flushConn(c, now);
                    return;
                },
                error.Unsupported => {
                    self.respondError(c, 400, "unsupported_request", "chunked, encoded or expect-continue requests are not supported");
                    self.flushConn(c, now);
                    return;
                },
            };
            c.have_head = true;
            c.head_len = c.req.head_len;
            c.body_len = c.req.content_length orelse 0;
            if (c.body_len > json.max_body) {
                self.respondError(c, 413, "body_too_large", "bodies are limited to 4096 bytes");
                self.flushConn(c, now);
                return;
            }
        }
        if (c.in_len < c.head_len + c.body_len) return;
        self.http_requests += 1;
        self.dispatch(c, now);
    }

    fn currentEpoch(self: *const Netd) u32 {
        return self.status.epoch;
    }

    fn relay(self: *Netd, c: *Conn, msg: messages.Message, request_id: u64, epoch: u32, now: u64) void {
        c.client_id = request_id;
        if (!self.sendSupervisor(msg, request_id, epoch)) {
            self.respondError(c, 503, "supervisor_unavailable", "the local channel is unavailable");
            self.flushConn(c, now);
            return;
        }
        c.awaiting = .renderer_result;
        c.pending_id = request_id;
        c.state = .relaying;
        c.last_ns = now;
    }

    fn ask(self: *Netd, c: *Conn, msg: messages.Message, awaiting: Awaiting, now: u64) void {
        const id = self.newId();
        if (!self.sendSupervisor(msg, id, 0)) {
            self.respondError(c, 503, "supervisor_unavailable", "the local channel is unavailable");
            self.flushConn(c, now);
            return;
        }
        c.awaiting = awaiting;
        c.pending_id = id;
        c.state = .relaying;
        c.last_ns = now;
    }

    fn frameAllowed(self: *Netd, now: u64) bool {
        const second = now / ns_per_s;
        if (second != self.frame_second) {
            self.frame_second = second;
            self.frames_in_second = 0;
        }
        if (self.frames_in_second >= frames_per_second_max) return false;
        self.frames_in_second += 1;
        return true;
    }

    /// turn an operation into a relay or an immediate response. shared by http and mqtt.
    fn execute(self: *Netd, c: *Conn, op: api.Op, now: u64) void {
        switch (op) {
            .status => self.ask(c, .status_get, .status, now),
            .scenes => {
                self.respond(c, 200, "application/json", api.scenes_body);
                self.flushConn(c, now);
            },
            .set_scene => |s| self.relay(c, .{ .set_base = .{ .base = @intFromEnum(s.base), .generator = if (s.generator) |g| @intFromEnum(g) else 0xff, .seed = s.seed orelse 0 } }, s.request_id, s.epoch orelse 0, now),
            .action => |a| switch (a.kind) {
                .brightness => self.relay(c, .{ .brightness = .{ .value = a.brightness.? } }, a.request_id, a.epoch, now),
                .reseed => self.relay(c, .{ .reseed = .{ .seed = a.seed orelse @truncate(now ^ a.request_id) } }, a.request_id, a.epoch, now),
                .arm_stream => self.relay(c, .arm_stream, a.request_id, a.epoch, now),
            },
            .notify => |n| self.relay(c, .{ .notify = messages.Notify.init(n.text, n.colour, n.duration_s) }, n.request_id, n.epoch, now),
            .frame => |f| {
                if (!self.frameAllowed(now)) {
                    c.client_id = f.request_id;
                    self.respondError(c, 429, "frame_rate", "occasional frames are limited to ten per second");
                    self.flushConn(c, now);
                    return;
                }
                self.relay(c, .{ .frame = .{ .duration_s = f.duration_s, .rgb = f.rgb.* } }, f.request_id, f.epoch, now);
            },
            .config_get => self.ask(c, .config_get, .config, now),
            .config_patch => |p| {
                const w = messages.ConfigPatch.fromApi(p) catch {
                    self.respondError(c, 400, "invalid_value", "a text field is too long");
                    self.flushConn(c, now);
                    return;
                };
                self.ask(c, .{ .config_patch = w }, .config, now);
            },
            .config_save => |s| self.ask(c, .{ .config_save = .{ .has_revision = @intFromBool(s.revision != null), .revision = s.revision orelse 0 } }, .save_result, now),
            .mqtt_get => {
                if (!self.have_cfg) {
                    self.respondError(c, 503, "not_ready", "settings not received yet");
                    self.flushConn(c, now);
                    return;
                }
                var o = Out{ .buf = &json_buf };
                self.mqttSettingsJson(&o);
                self.respond(c, 200, "application/json", o.slice());
                self.flushConn(c, now);
            },
            .mqtt_put => |p| {
                const w = messages.MqttPut.fromApi(p) catch {
                    self.respondError(c, 400, "invalid_value", "a text field is too long");
                    self.flushConn(c, now);
                    return;
                };
                self.ask(c, .{ .mqtt_put = w }, .config, now);
            },
            .mqtt_status => {
                var o = Out{ .buf = &json_buf };
                self.mqttStatusJson(&o, now);
                self.respond(c, 200, "application/json", o.slice());
                self.flushConn(c, now);
            },
            .streams_create, .streams_palette, .streams_delete => {
                self.respondError(c, 503, "not_implemented", "stream sessions are not available in this release");
                self.flushConn(c, now);
            },
        }
    }

    fn dispatch(self: *Netd, c: *Conn, now: u64) void {
        const body = c.in[c.head_len .. c.head_len + c.body_len];
        const creds = self.creds orelse {
            self.respondError(c, 503, "not_ready", "credentials not received yet");
            self.flushConn(c, now);
            return;
        };
        const origins = if (self.have_cfg) self.cfg.originPolicy() else api.OriginPolicy{};
        switch (api.route(c.req, body, &creds, &origins, &arena)) {
            .reject => |j| {
                self.respondError(c, j.status, j.code, j.message);
                self.flushConn(c, now);
            },
            .op => |op| self.execute(c, op, now),
        }
    }

    // replies from the supervisor

    fn findConn(self: *Netd, awaiting_any: bool, request_id: u64) ?*Conn {
        _ = self;
        for (&conns) |*c| if (c.state == .relaying and c.pending_id == request_id and (awaiting_any or c.awaiting == .renderer_result)) return c;
        return null;
    }

    fn appliedJson(self: *Netd, o: *Out, status: messages.Status, revision: u32, request_id: u64) void {
        o.fmt("{{\"status\":\"{s}\",\"revision\":{d},\"epoch\":{d},\"request_id\":\"{x:0>16}\"}}", .{ @tagName(status), revision, self.currentEpoch(), request_id });
    }

    fn onResult(self: *Netd, request_id: u64, r: messages.Result, now: u64) void {
        if (self.findConn(false, request_id)) |c| {
            switch (r.status) {
                .applied => {
                    var o = Out{ .buf = &json_buf };
                    self.appliedJson(&o, .applied, r.revision, request_id);
                    self.respond(c, 200, "application/json", o.slice());
                },
                .rejected => self.respondError(c, 400, "rejected", "the renderer rejected the command"),
                .overload => self.respondError(c, 429, "overload", "the renderer's command queue is full"),
                .stale_epoch => self.respondError(c, 409, "stale_epoch", "the renderer epoch changed; read status and retry"),
                .expired => self.respondError(c, 409, "expired", "the request id refers to an expired session"),
                .unavailable => self.respondError(c, 503, "renderer_unavailable", "no renderer is running"),
                .timeout => self.respondError(c, 504, "timeout", "the renderer did not answer within two seconds; retry with the same request id"),
                .conflict => self.respondError(c, 409, "conflict", "conflict"),
            }
            self.flushConn(c, now);
            return;
        }
        for (&self.m_pending) |*p| if (p.used and p.id == request_id) {
            p.used = false;
            self.publishResult(request_id, r.status, r.revision);
            return;
        };
    }

    fn onStatus(self: *Netd, request_id: u64, st: messages.StatusSnapshot, now: u64) void {
        const changed = st.revision != self.status.revision or st.epoch != self.status.epoch or st.renderer_state != self.status.renderer_state or st.base != self.status.base or st.brightness != self.status.brightness or st.overlay != self.status.overlay;
        self.status = st;
        self.status_at_ns = now;
        if (changed) self.state_dirty = true;
        if (request_id != 0) {
            if (self.findConn(true, request_id)) |c| {
                if (c.awaiting == .status) {
                    var o = Out{ .buf = &json_buf };
                    self.statusJson(&o, now);
                    self.respond(c, 200, "application/json", o.slice());
                    self.flushConn(c, now);
                }
            }
        }
    }

    fn onConfig(self: *Netd, request_id: u64, cfg: config.Config, now: u64) void {
        const mqtt_changed = !std.meta.eql(cfg.mqtt, self.cfg.mqtt);
        const discovery_was = self.cfg.discovery;
        const prefix_changed = !std.mem.eql(u8, cfg.discovery_prefix.slice(), self.cfg.discovery_prefix.slice());
        self.cfg = cfg;
        if (self.m_connected and self.have_cfg) {
            if ((discovery_was and !cfg.discovery) or (discovery_was and prefix_changed)) self.discoveryStart(true, now) else if (cfg.discovery and (!discovery_was or prefix_changed)) self.discoveryStart(false, now);
        }
        self.have_cfg = true;
        if (mqtt_changed or !self.client.enabled) self.applyMqttSettings(now);
        if (self.next_metrics_ns == 0 and cfg.metrics_interval_s != 0) self.next_metrics_ns = now + @as(u64, cfg.metrics_interval_s) * ns_per_s;
        if (self.findConn(true, request_id)) |c| {
            if (c.awaiting == .config) {
                var o = Out{ .buf = &json_buf };
                if (std.mem.eql(u8, c.req.path, "/api/v1/mqtt")) self.mqttSettingsJson(&o) else self.configJson(&o);
                self.respond(c, 200, "application/json", o.slice());
                self.flushConn(c, now);
            }
        }
    }

    fn onSaveResult(self: *Netd, request_id: u64, r: messages.SaveResult, now: u64) void {
        const c = self.findConn(true, request_id) orelse return;
        switch (r.status) {
            .applied => {
                var o = Out{ .buf = &json_buf };
                o.fmt("{{\"status\":\"saved\",\"saved_revision\":{d}}}", .{r.saved_revision});
                self.respond(c, 200, "application/json", o.slice());
            },
            .conflict => self.respondError(c, 409, "revision_conflict", "the expected revision does not match"),
            .rejected => self.respondError(c, 400, "rejected", "the settings were rejected"),
            .unavailable => self.respondError(c, 503, "save_failed", "the configuration could not be written"),
            else => self.respondError(c, 500, "internal", "unexpected save result"),
        }
        self.flushConn(c, now);
    }

    fn drainSupervisor(self: *Netd, now: u64) void {
        var count: u32 = 0;
        while (count < 32) : (count += 1) {
            const packet = sys.recvPacket(supervisor_fd, &packet_buf) catch |e| {
                if (e == error.Closed) {
                    log.warn("supervisor channel closed", .{});
                    self.supervisor_dead = true;
                    sys.epollDel(self.ep, supervisor_fd);
                }
                return;
            } orelse return;
            const p = messages.decodePacket(packet) catch |e| {
                log.warn("bad packet from supervisor: {s}", .{@errorName(e)});
                continue;
            };
            switch (p.message) {
                .credentials => |cr| {
                    self.creds = cr;
                    log.info("credentials received", .{});
                },
                .config => |cfg| self.onConfig(p.request_id, cfg, now),
                .status => |st| self.onStatus(p.request_id, st, now),
                .result => |r| self.onResult(p.request_id, r, now),
                .save_result => |r| self.onSaveResult(p.request_id, r, now),
                else => log.warn("unexpected {s} from supervisor", .{@tagName(p.message)}),
            }
        }
    }

    // json documents

    fn baseName(b: u8) []const u8 {
        return switch (b) {
            0 => "art",
            1 => "clock",
            2 => "ip",
            else => "unknown",
        };
    }

    fn generatorName(g: u8) []const u8 {
        return if (messages.enumFromInt(scene.Generator, g)) |v| @tagName(v) else "unknown";
    }

    fn overlayName(o: u8) []const u8 {
        return switch (o) {
            0 => "none",
            1 => "notify",
            2 => "frame",
            3 => "stream_arming",
            else => "unknown",
        };
    }

    fn rendererName(s: u8) []const u8 {
        return switch (s) {
            0 => "none",
            1 => "starting",
            2 => "running",
            3 => "stopping",
            else => "unknown",
        };
    }

    fn timeStateName(s: u8) []const u8 {
        return switch (s) {
            0 => "unsynced",
            1 => "synced",
            2 => "stale",
            else => "unknown",
        };
    }

    /// fps is only meaningful against a continuous cadence: art with no overlay. otherwise null.
    fn fpsJson(self: *Netd, o: *Out) void {
        const st = self.status;
        if (st.base == 0 and st.overlay == 0 and st.renderer_state == 2) o.fmt("\"fps\":{d}.{d},", .{ st.fps_x10 / 10, st.fps_x10 % 10 }) else o.add("\"fps\":null,");
    }

    fn statusJson(self: *Netd, o: *Out, now: u64) void {
        const st = self.status;
        o.add("{");
        o.fmt("\"epoch\":{d},\"revision\":{d},\"renderer\":\"{s}\",\"base\":\"{s}\",\"generator\":\"{s}\",\"overlay\":\"{s}\",\"brightness\":{d},\"presented\":{d},", .{ st.epoch, st.revision, rendererName(st.renderer_state), baseName(st.base), generatorName(st.generator), overlayName(st.overlay), st.brightness, st.presented });
        self.fpsJson(o);
        o.fmt("\"uptime_s\":{d},\"memory_available_kb\":{d},", .{ st.uptime_s, st.mem_available_kb });
        if (st.cpu_pct == 255) o.add("\"cpu_pct\":null,") else o.fmt("\"cpu_pct\":{d},", .{st.cpu_pct});
        o.fmt("\"restarts\":{d},\"network\":{{\"ip\":", .{st.restarts});
        if (st.ip_present != 0) o.fmt("\"{d}.{d}.{d}.{d}\"", .{ st.ip[0], st.ip[1], st.ip[2], st.ip[3] }) else o.add("null");
        o.fmt("}},\"time\":{{\"state\":\"{s}\",\"age_s\":", .{timeStateName(st.time_state)});
        if (st.time_age_s == 0xffffffff) o.add("null") else o.fmt("{d}", .{st.time_age_s});
        o.fmt("}},\"config_revision\":{d},\"saved_revision\":{d},\"transport\":\"plaintext\",\"mqtt\":", .{ st.config_revision, st.saved_revision });
        self.mqttStatusJson(o, now);
        o.fmt(",\"boot_id\":\"{x:0>8}\",\"sample_age_ms\":{d}}}", .{ st.boot_id, st.sample_age_ms + @as(u32, @intCast(@min((now -| self.status_at_ns) / 1_000_000, 0xffffffff))) });
    }

    fn configJson(self: *Netd, o: *Out) void {
        const c = &self.cfg;
        o.fmt("{{\"revision\":{d},\"saved_revision\":{d},\"brightness\":{d},\"base\":\"{s}\",\"generator\":\"{s}\",\"timezone\":", .{ c.revision, c.saved_revision, c.brightness, baseName(c.base), generatorName(c.generator) });
        o.str(c.timezone.slice());
        o.add(",\"ntp\":{\"server\":");
        if (c.ntp_server) |s| o.fmt("\"{d}.{d}.{d}.{d}\"", .{ s[0], s[1], s[2], s[3] }) else o.add("null");
        o.fmt(",\"interval_s\":{d}}},\"frame_timeout_ms\":{d},\"metrics_interval_s\":{d},\"discovery\":{{\"enabled\":{},\"prefix\":", .{ c.ntp_interval_s, c.frame_timeout_ms, c.metrics_interval_s, c.discovery });
        o.str(c.discovery_prefix.slice());
        o.add("},\"allowed_origins\":[");
        for (c.origins[0..c.origin_count], 0..) |*org, i| {
            if (i > 0) o.add(",");
            o.str(org.slice());
        }
        o.add("]}");
    }

    fn mqttSettingsJson(self: *Netd, o: *Out) void {
        const m = &self.cfg.mqtt;
        o.fmt("{{\"enabled\":{},\"host\":", .{m.enabled});
        o.str(m.host.slice());
        o.fmt(",\"port\":{d},\"username\":", .{m.port});
        o.str(m.username.slice());
        o.add(",\"client_id\":");
        o.str(m.client_id.slice());
        o.add(",\"prefix\":");
        o.str(self.prefix());
        o.fmt(",\"tls\":{},\"password_set\":{}}}", .{ m.tls, m.password.len > 0 });
    }

    fn mqttStatusJson(self: *Netd, o: *Out, now: u64) void {
        o.fmt("{{\"enabled\":{},\"connected\":{},\"state\":\"{s}\",\"reconnect_delay_s\":{d},\"reconnects\":{d},\"last_error\":", .{ self.client.enabled, self.m_connected, @tagName(self.client.state), self.client.reconnectDelayS(now), self.client.reconnects });
        o.str(self.m_last_error[0..self.m_last_error_len]);
        o.add("}");
    }

    fn metricsJson(self: *Netd, o: *Out, now: u64) void {
        const st = self.status;
        o.fmt("{{\"v\":1,\"boot_id\":\"{x:0>8}\",\"epoch\":{d},\"sample_age_ms\":{d},\"uptime_s\":{d},\"memory_available_kb\":{d},", .{ st.boot_id, st.epoch, st.sample_age_ms + @as(u32, @intCast(@min((now -| self.status_at_ns) / 1_000_000, 0xffffffff))), st.uptime_s, st.mem_available_kb });
        if (st.cpu_pct == 255) o.add("\"cpu_pct\":null,") else o.fmt("\"cpu_pct\":{d},", .{st.cpu_pct});
        o.fmt("\"rss_kb\":{{\"supervisor\":{d},\"renderer\":{d},\"netd\":{d}}},\"renderer_restarts\":{d},\"mqtt_reconnects\":{d},\"scene\":\"{s}\",\"brightness\":{d},", .{ st.rss_supervisor_kb, st.rss_renderer_kb, st.rss_netd_kb, st.restarts, self.client.reconnects, baseName(st.base), st.brightness });
        self.fpsJson(o);
        o.fmt("\"presented\":{d},\"http_requests\":{d},\"http_rejected\":{d},\"mqtt_commands\":{d},\"mqtt_dropped\":{d},\"time\":{{\"state\":\"{s}\"}}}}", .{ st.presented, self.http_requests, self.http_rejected, self.mqtt_commands, self.mqtt_dropped, timeStateName(st.time_state) });
    }

    // mqtt

    fn prefix(self: *const Netd) []const u8 {
        return if (self.cfg.mqtt.prefix.len > 0) self.cfg.mqtt.prefix.slice() else "tc002";
    }

    fn setError(self: *Netd, text: []const u8) void {
        const n = @min(text.len, self.m_last_error.len);
        @memcpy(self.m_last_error[0..n], text[0..n]);
        self.m_last_error_len = n;
    }

    fn applyMqttSettings(self: *Netd, now: u64) void {
        const m = &self.cfg.mqtt;
        if (m.enabled and m.host.len > 0 and !m.tls) {
            if (self.client.enabled) self.mqttClose(self.client.disable());
            self.client = .{ .rng = @truncate(now | 1) };
            self.client.enable(now);
            log.info("mqtt enabled: {s}:{d} prefix {s}", .{ m.host.slice(), m.port, self.prefix() });
        } else {
            if (m.enabled and m.tls) {
                self.setError("tls is not available in this build");
                log.warn("mqtt settings ask for tls, which this build cannot provide; staying disconnected rather than falling back", .{});
            }
            self.mqttClose(self.client.disable());
        }
    }

    fn mqttClose(self: *Netd, directive: mqtt.Directive) void {
        _ = directive;
        if (self.mfd) |fd| {
            sys.epollDel(self.ep, fd);
            sys.close(fd);
            self.mfd = null;
        }
        self.m_in_len = 0;
        self.m_out_len = 0;
        self.m_out_off = 0;
        if (self.m_connected) log.info("mqtt disconnected", .{});
        self.m_connected = false;
    }

    fn topic(self: *Netd, buf: []u8, suffix: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.prefix(), suffix }) catch buf[0..0];
    }

    /// queue a packet built by `builder` into the output buffer; drops (and counts) when full.
    fn mqttQueue(self: *Netd, n: usize) void {
        self.m_out_len += n;
    }

    fn mqttSpace(self: *Netd) []u8 {
        if (self.m_out_off > 0 and self.m_out_off == self.m_out_len) {
            self.m_out_len = 0;
            self.m_out_off = 0;
        }
        return self.m_out[self.m_out_len..];
    }

    fn mqttPublish(self: *Netd, suffix: []const u8, payload: []const u8, qos: u2, retain: bool) void {
        if (!self.m_connected) return;
        var tb: [96]u8 = undefined;
        const t = self.topic(&tb, suffix);
        const space = self.mqttSpace();
        const n = mqtt.encodePublish(space, .{ .topic = t, .payload = payload, .qos = qos, .retain = retain, .packet_id = if (qos > 0) self.client.packetId() else 0 }) catch {
            self.mqtt_dropped += 1;
            return;
        };
        self.mqttQueue(n);
        self.mqttFlush();
    }

    fn mqttFlush(self: *Netd) void {
        const fd = self.mfd orelse return;
        while (self.m_out_off < self.m_out_len) {
            const n = sys.write(fd, self.m_out[self.m_out_off..self.m_out_len]) catch |e| switch (e) {
                error.WouldBlock => {
                    sys.epollMod(self.ep, fd, linux.EPOLL.IN | linux.EPOLL.OUT, @intFromEnum(Tag.mqtt));
                    return;
                },
                error.Interrupted => continue,
                else => {
                    self.setError("write failed");
                    return;
                },
            };
            self.m_out_off += n;
        }
        self.m_out_len = 0;
        self.m_out_off = 0;
        sys.epollMod(self.ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.mqtt));
    }

    fn mqttDirective(self: *Netd, d: mqtt.Directive, now: u64) void {
        switch (d) {
            .none => {},
            .open_socket => {
                const addr = api.parseIpv4(self.cfg.mqtt.host.slice()) orelse {
                    self.setError("invalid broker address");
                    self.mqttDirective(self.client.onSocket(false, now), now);
                    return;
                };
                const fd = sys.tcpConnect(addr, self.cfg.mqtt.port) catch |e| {
                    self.setError(sys.errText(e));
                    self.mqttDirective(self.client.onSocket(false, now), now);
                    return;
                };
                self.mfd = fd;
                sys.epollAdd(self.ep, fd, linux.EPOLL.IN | linux.EPOLL.OUT, @intFromEnum(Tag.mqtt)) catch {};
            },
            .send_connect => {
                var will_topic: [96]u8 = undefined;
                const wt = self.topic(&will_topic, "availability");
                var cid_buf: [48]u8 = undefined;
                const cid = if (self.cfg.mqtt.client_id.len > 0) self.cfg.mqtt.client_id.slice() else std.fmt.bufPrint(&cid_buf, "tc002-{x:0>8}", .{self.status.boot_id}) catch "tc002";
                const m = &self.cfg.mqtt;
                const space = self.mqttSpace();
                const n = mqtt.encodeConnect(space, .{
                    .client_id = cid,
                    .keepalive_s = 30,
                    .username = if (m.username.len > 0) m.username.slice() else null,
                    .password = if (m.password.len > 0) m.password.slice() else null,
                    .will = .{ .topic = wt, .payload = "offline", .retain = true, .qos = 1 },
                }) catch {
                    self.setError("connect packet too large");
                    return;
                };
                self.mqttQueue(n);
                self.mqttFlush();
            },
            .send_subscribe => {
                var tb: [5][96]u8 = undefined;
                var topics: [5][]const u8 = undefined;
                const names = [_][]const u8{ "cmd/scene", "cmd/action", "cmd/notify", "cmd/frame", "cmd/config" };
                for (names, 0..) |n, i| topics[i] = self.topic(&tb[i], n);
                var birth_buf: [96]u8 = undefined;
                const birth = std.fmt.bufPrint(&birth_buf, "{s}/status", .{self.cfg.discovery_prefix.slice()}) catch "homeassistant/status";
                var all: [6][]const u8 = undefined;
                for (topics, 0..) |t, i| all[i] = t;
                all[5] = birth;
                const space = self.mqttSpace();
                const n = mqtt.encodeSubscribe(space, self.client.packetId(), if (self.cfg.discovery) all[0..6] else all[0..5], 1) catch return;
                self.mqttQueue(n);
                self.m_connected = true;
                log.info("mqtt connected", .{});
                self.setError("");
                self.mqttFlush();
                self.mqttPublish("availability", "online", 1, true);
                self.state_dirty = true;
                self.last_state_pub_ns = 0;
                if (self.cfg.discovery) self.discoveryStart(false, now);
            },
            .send_ping => {
                const space = self.mqttSpace();
                const n = mqtt.encodePingreq(space) catch return;
                self.mqttQueue(n);
                self.mqttFlush();
            },
            .close => self.mqttClose(.close),
            .notify_connected => {},
            .notify_disconnected => {
                self.setError("connection lost");
                self.mqttClose(.close);
            },
        }
    }

    fn mqttReadable(self: *Netd, now: u64) void {
        const fd = self.mfd orelse return;
        while (true) {
            if (self.m_in_len == self.m_in.len) {
                self.setError("packet too large");
                self.mqttDirective(self.client.onClosed(now), now);
                return;
            }
            const n = sys.read(fd, self.m_in[self.m_in_len..]) catch |e| switch (e) {
                error.WouldBlock => break,
                error.Interrupted => continue,
                else => {
                    self.setError("read failed");
                    self.mqttDirective(self.client.onClosed(now), now);
                    return;
                },
            };
            if (n == 0) {
                self.setError("broker closed the connection");
                self.mqttDirective(self.client.onClosed(now), now);
                return;
            }
            self.m_in_len += n;
        }
        var off: usize = 0;
        while (off < self.m_in_len) {
            const d = mqtt.decode(self.m_in[off..self.m_in_len]) catch |e| switch (e) {
                error.Incomplete => break,
                else => {
                    self.setError("malformed packet from broker");
                    self.mqttDirective(self.client.onClosed(now), now);
                    return;
                },
            };
            off += d.used;
            self.client.onTraffic(now);
            switch (d.packet) {
                .connack => |c| {
                    if (c.return_code != 0) self.setError("broker refused the connection");
                    self.mqttDirective(self.client.onConnack(c.return_code, now), now);
                },
                .publish => |p| self.onMqttPublish(p, now),
                .puback => {},
                .suback => {},
                .pingresp => self.client.onPingresp(),
                .other => {},
            }
        }
        if (off > 0) {
            std.mem.copyForwards(u8, self.m_in[0 .. self.m_in_len - off], self.m_in[off..self.m_in_len]);
            self.m_in_len -= off;
        }
    }

    fn publishResult(self: *Netd, request_id: u64, status: messages.Status, revision: u32) void {
        var o = Out{ .buf = &json_buf };
        o.fmt("{{\"request_id\":\"{x:0>16}\",\"status\":\"{s}\",\"revision\":{d},\"epoch\":{d}}}", .{ request_id, @tagName(status), revision, self.currentEpoch() });
        self.mqttPublish("result", o.slice(), 0, false);
    }

    fn mqttRelay(self: *Netd, msg: messages.Message, request_id: u64, epoch: u32, now: u64) void {
        var slot: ?*MqttPending = null;
        for (&self.m_pending) |*p| if (!p.used) {
            slot = p;
            break;
        };
        const p = slot orelse {
            self.publishResult(request_id, .overload, self.status.revision);
            return;
        };
        if (!self.sendSupervisor(msg, request_id, epoch)) {
            self.publishResult(request_id, .unavailable, self.status.revision);
            return;
        }
        p.* = .{ .used = true, .id = request_id, .since_ns = now };
        self.mqtt_commands += 1;
    }

    fn onMqttPublish(self: *Netd, p: anytype, now: u64) void {
        if (p.qos == 1) {
            const space = self.mqttSpace();
            if (mqtt.encodePuback(space, p.packet_id)) |n| self.mqttQueue(n) else |_| {}
            self.mqttFlush();
        }
        // home-assistant birth: republish discovery when it comes online
        if (self.cfg.discovery and std.mem.endsWith(u8, p.topic, "/status") and std.mem.startsWith(u8, p.topic, self.cfg.discovery_prefix.slice())) {
            if (std.mem.eql(u8, p.payload, "online")) self.discoveryStart(false, now);
            return;
        }
        if (p.retain) return; // retained deliveries are never commands
        var pb: [96]u8 = undefined;
        const cmd_prefix = self.topic(&pb, "cmd/");
        if (!std.mem.startsWith(u8, p.topic, cmd_prefix)) return;
        const suffix = p.topic[cmd_prefix.len..];
        if (std.mem.eql(u8, suffix, "frame")) {
            if (p.payload.len != mqtt_frame_envelope) return;
            const rid = std.mem.readInt(u64, p.payload[0..8], .big);
            const epoch = std.mem.readInt(u32, p.payload[8..12], .big);
            const duration = std.mem.readInt(u16, p.payload[12..14], .big);
            if (duration < 1 or duration > 300) {
                self.publishResult(rid, .rejected, self.status.revision);
                return;
            }
            if (!self.frameAllowed(now)) {
                self.publishResult(rid, .overload, self.status.revision);
                return;
            }
            self.mqttRelay(.{ .frame = .{ .duration_s = duration, .rgb = p.payload[14..][0..geometry.rgb_bytes].* } }, rid, epoch, now);
            return;
        }
        const kind: api.BodyKind = if (std.mem.eql(u8, suffix, "scene")) .scene else if (std.mem.eql(u8, suffix, "action")) .action else if (std.mem.eql(u8, suffix, "notify")) .notify else if (std.mem.eql(u8, suffix, "config")) .config_patch else return;
        switch (api.parseBody(kind, p.payload, &arena)) {
            .reject => |j| {
                var o = Out{ .buf = &json_buf };
                o.fmt("{{\"status\":\"rejected\",\"error\":\"{s}\",\"message\":\"{s}\"}}", .{ j.code, j.message });
                self.mqttPublish("result", o.slice(), 0, false);
            },
            .op => |op| switch (op) {
                .set_scene => |s| self.mqttRelay(.{ .set_base = .{ .base = @intFromEnum(s.base), .generator = if (s.generator) |g| @intFromEnum(g) else 0xff, .seed = s.seed orelse 0 } }, s.request_id, s.epoch orelse 0, now),
                .action => |a| switch (a.kind) {
                    .brightness => self.mqttRelay(.{ .brightness = .{ .value = a.brightness.? } }, a.request_id, a.epoch, now),
                    .reseed => self.mqttRelay(.{ .reseed = .{ .seed = a.seed orelse @truncate(now ^ a.request_id) } }, a.request_id, a.epoch, now),
                    .arm_stream => self.mqttRelay(.arm_stream, a.request_id, a.epoch, now),
                },
                .notify => |n| self.mqttRelay(.{ .notify = messages.Notify.init(n.text, n.colour, n.duration_s) }, n.request_id, n.epoch, now),
                .config_patch => |cp| {
                    // the control subset only: transient brightness and scene parameters
                    const admin_fields = cp.timezone != null or cp.ntp_server != null or cp.ntp_interval_s != null or cp.frame_timeout_ms != null or cp.metrics_interval_s != null or cp.discovery != null or cp.discovery_prefix != null;
                    if (admin_fields) {
                        var o = Out{ .buf = &json_buf };
                        o.add("{\"status\":\"rejected\",\"error\":\"admin_only\",\"message\":\"durable settings are administered over http\"}");
                        self.mqttPublish("result", o.slice(), 0, false);
                        return;
                    }
                    const rid = self.newId();
                    if (cp.brightness) |b| self.mqttRelay(.{ .brightness = .{ .value = b } }, rid, 0, now);
                    if (cp.base) |b| self.mqttRelay(.{ .set_base = .{ .base = @intFromEnum(b), .generator = if (cp.generator) |g| @intFromEnum(g) else 0xff, .seed = 0 } }, rid + 1, 0, now);
                },
                else => {},
            },
        }
    }

    fn mqttTick(self: *Netd, now: u64) void {
        var guard: u32 = 0;
        while (guard < 4) : (guard += 1) {
            const d = self.client.poll(now);
            if (d == .none) break;
            self.mqttDirective(d, now);
        }
        for (&self.m_pending) |*p| if (p.used and now - p.since_ns >= relay_timeout_ns) {
            p.used = false;
            self.publishResult(p.id, .timeout, self.status.revision);
        };
        self.discoveryStep(now);
        if (self.m_connected and self.state_dirty and now - self.last_state_pub_ns >= state_coalesce_ns) {
            var o = Out{ .buf = &json_buf };
            self.statusJson(&o, now);
            self.mqttPublish("state", o.slice(), 0, true);
            self.state_dirty = false;
            self.last_state_pub_ns = now;
        }
        if (self.m_connected and self.cfg.metrics_interval_s != 0 and self.next_metrics_ns != 0 and now >= self.next_metrics_ns) {
            var o = Out{ .buf = json_buf[0..1024] };
            self.metricsJson(&o, now);
            if (!o.overflow) self.mqttPublish("metrics", o.slice(), 0, false) else self.mqtt_dropped += 1;
            self.next_metrics_ns = now + @as(u64, self.cfg.metrics_interval_s) * ns_per_s;
        }
    }

    // home-assistant mqtt discovery (read-only diagnostic sensors over the metrics topic)

    const Entity = struct { key: []const u8, name: []const u8, template: []const u8, unit: []const u8, device_class: []const u8, state_class: []const u8 };
    const entities = [_]Entity{
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
        .{ .key = "fps", .name = "achieved fps", .template = "{{ value_json.fps if value_json.fps is not none else 'unknown' }}", .unit = "fps", .device_class = "", .state_class = "measurement" },
        .{ .key = "presented", .name = "frames presented", .template = "{{ value_json.presented }}", .unit = "", .device_class = "", .state_class = "total_increasing" },
        .{ .key = "time_state", .name = "time sync", .template = "{{ value_json.time.state }}", .unit = "", .device_class = "", .state_class = "" },
    };

    fn discoveryTopic(self: *Netd, buf: []u8, key: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/sensor/tc002-{x:0>8}/{s}/config", .{ self.disc_prefix_used.slice(), self.status.boot_id, key }) catch buf[0..0];
    }

    /// start a discovery pass: publish (or, when removing, clear) every entity, one per second.
    fn discoveryStart(self: *Netd, remove: bool, now: u64) void {
        if (!self.m_connected) return;
        if (!remove) self.disc_prefix_used = self.cfg.discovery_prefix;
        self.disc_index = 0;
        self.disc_active = true;
        self.disc_remove = remove;
        self.disc_next_ns = now;
    }

    fn discoveryStep(self: *Netd, now: u64) void {
        if (!self.disc_active or !self.m_connected or now < self.disc_next_ns) return;
        if (self.disc_index >= entities.len) {
            self.disc_active = false;
            if (!self.disc_remove) {
                self.disc_published = true;
                // a fresh sample right after the pass, then the periodic cadence continues
                self.next_metrics_ns = now;
            } else self.disc_published = false;
            return;
        }
        const e = entities[self.disc_index];
        var tb: [160]u8 = undefined;
        const t = self.discoveryTopic(&tb, e.key);
        if (self.disc_remove) {
            self.mqttPublishTopic(t, "", 1, true);
        } else {
            var o = Out{ .buf = json_buf[0..1024] };
            const interval: u64 = if (self.cfg.metrics_interval_s != 0) self.cfg.metrics_interval_s else 30;
            o.fmt("{{\"name\":\"{s}\",\"unique_id\":\"tc002_{x:0>8}_{s}\",\"state_topic\":\"{s}/metrics\",\"value_template\":\"{s}\",\"availability_topic\":\"{s}/availability\",\"expire_after\":{d},\"entity_category\":\"diagnostic\"", .{ e.name, self.status.boot_id, e.key, self.prefix(), e.template, self.prefix(), interval * 3 });
            if (e.unit.len > 0) o.fmt(",\"unit_of_measurement\":\"{s}\"", .{e.unit});
            if (e.device_class.len > 0) o.fmt(",\"device_class\":\"{s}\"", .{e.device_class});
            if (e.state_class.len > 0) o.fmt(",\"state_class\":\"{s}\"", .{e.state_class});
            o.fmt(",\"device\":{{\"identifiers\":[\"tc002-{x:0>8}\"],\"name\":\"tc002\",\"model\":\"tc002 custom runtime\",\"manufacturer\":\"ulanzi (custom firmware)\",\"sw_version\":\"plan-b\"}},\"origin\":{{\"name\":\"tc002-netd\"}}}}", .{self.status.boot_id});
            if (!o.overflow) self.mqttPublishTopic(t, o.slice(), 1, true) else self.mqtt_dropped += 1;
        }
        self.disc_index += 1;
        self.disc_next_ns = now + ns_per_s;
    }

    fn mqttPublishTopic(self: *Netd, t: []const u8, payload: []const u8, qos: u2, retain: bool) void {
        if (!self.m_connected) return;
        const space = self.mqttSpace();
        const n = mqtt.encodePublish(space, .{ .topic = t, .payload = payload, .qos = qos, .retain = retain, .packet_id = if (qos > 0) self.client.packetId() else 0 }) catch {
            self.mqtt_dropped += 1;
            return;
        };
        self.mqttQueue(n);
        self.mqttFlush();
    }

    fn tick(self: *Netd, now: u64) void {
        for (&conns) |*c| {
            switch (c.state) {
                .free => {},
                .reading => if (now - c.started_ns >= request_timeout_ns) {
                    self.respondError(c, 400, "request_timeout", "the request was not completed within five seconds");
                    self.flushConn(c, now);
                },
                .relaying => if (now - c.last_ns >= relay_timeout_ns) {
                    self.respondError(c, 504, "timeout", "no answer within two seconds; retry with the same request id");
                    self.flushConn(c, now);
                },
                .writing => if (now - c.last_ns >= idle_timeout_ns) self.closeConn(c),
            }
        }
        self.mqttTick(now);
    }
};

fn run(stats: bool) !u8 {
    for (&conns) |*c| c.* = .{};
    const ep = try sys.epollCreate();
    const timer = try sys.timerfdCreate();
    try sys.epollAdd(ep, timer, linux.EPOLL.IN, @intFromEnum(Tag.timer));
    try sys.epollAdd(ep, supervisor_fd, linux.EPOLL.IN, @intFromEnum(Tag.supervisor));
    try sys.epollAdd(ep, listener_fd, linux.EPOLL.IN, @intFromEnum(Tag.listener));
    const sigfd = try sys.signalfdFor(&.{ .TERM, .INT });
    sys.setSignalDisposition(.PIPE, linux.SIG.IGN);
    var n = Netd{ .ep = ep, .timer = timer, .stats = stats };
    log.info("netd up: uid {d}, plaintext http on the inherited listener, mqtt on demand", .{linux.getuid()});
    var events: [16]sys.Event = undefined;
    var next_tick = sys.monotonicNs();
    var next_stats = next_tick + 30 * ns_per_s;
    while (true) {
        const now = sys.monotonicNs();
        if (sys.readSignal(sigfd) catch null) |_| {
            log.info("signal, exiting", .{});
            break;
        }
        if (now >= next_tick) {
            n.tick(now);
            next_tick = now + tick_ns;
        }
        if (stats and now >= next_stats) {
            log.info("http requests {d} rejected {d}; mqtt {s} commands {d} dropped {d} reconnects {d}", .{ n.http_requests, n.http_rejected, if (n.m_connected) "connected" else "disconnected", n.mqtt_commands, n.mqtt_dropped, n.client.reconnects });
            next_stats = now + 30 * ns_per_s;
        }
        try sys.timerfdArmAt(timer, next_tick);
        const count = try sys.epollWait(ep, &events, -1);
        const t = sys.monotonicNs();
        for (events[0..count]) |ev| {
            const tag = ev.data.u64;
            if (tag == @intFromEnum(Tag.timer)) {
                sys.timerfdDrain(timer);
            } else if (tag == @intFromEnum(Tag.supervisor)) {
                n.drainSupervisor(t);
            } else if (tag == @intFromEnum(Tag.listener)) {
                n.acceptAll(t);
            } else if (tag == @intFromEnum(Tag.mqtt)) {
                if (n.client.state == .connecting and ev.events & linux.EPOLL.OUT != 0) {
                    const ok = if (n.mfd) |fd| sys.socketConnected(fd) else false;
                    if (!ok) n.setError("connect failed");
                    n.mqttDirective(n.client.onSocket(ok, t), t);
                } else {
                    if (ev.events & (linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) n.mqttReadable(t);
                    if (ev.events & linux.EPOLL.OUT != 0) n.mqttFlush();
                }
            } else if (tag >= @intFromEnum(Tag.conn_base) and tag < @intFromEnum(Tag.conn_base) + max_conns) {
                const c = &conns[@as(usize, @intCast(tag - @intFromEnum(Tag.conn_base)))];
                if (c.state == .free) continue;
                if (c.state == .writing) {
                    n.flushConn(c, t);
                } else if (c.state == .reading) {
                    n.readConn(c, t);
                } else if (ev.events & (linux.EPOLL.HUP | linux.EPOLL.ERR) != 0) {
                    n.closeConn(c);
                }
            }
        }
        if (n.supervisor_dead) {
            log.warn("exiting: no supervisor", .{});
            return 1;
        }
    }
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    log.program = "tc002-netd";
    var stats = false;
    for (init.args.vector[1..]) |a| {
        const s = std.mem.span(a);
        if (std.mem.eql(u8, s, "--stats")) stats = true;
    }
    return run(stats) catch |e| {
        log.err("fatal: {s}", .{sys.errText(e)});
        return 1;
    };
}
