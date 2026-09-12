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
const transition = @import("panel/transition.zig");
const ip = @import("scene/ip.zig");
const param = @import("scene/param.zig");
const scene = @import("scene/scene.zig");
const actions = @import("input/actions.zig");
const clock = @import("scene/clock.zig");
const solar = @import("sys/solar.zig");
const canvas = @import("scene/canvas.zig");
const night = @import("supervisor/night.zig");

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
const Awaiting = enum { none, renderer_result, status, config, save_result, screen, logs, canvas };

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
    /// a screen read wants octets rather than the json document
    screen_raw: bool = false,
    out: [out_buf_len]u8 = undefined,
    out_len: usize = 0,
    out_off: usize = 0,

    /// reset the bookkeeping only: assigning a whole `Conn` copies its 12 kib of buffers and makes
    /// every page of the table resident for nothing (measured: 48 kib for 16 useful bytes).
    fn reset(c: *Conn) void {
        c.fd = -1;
        c.state = .free;
        c.in_len = 0;
        c.head_len = 0;
        c.body_len = 0;
        c.have_head = false;
        c.started_ns = 0;
        c.last_ns = 0;
        c.awaiting = .none;
        c.pending_id = 0;
        c.client_id = 0;
        c.screen_raw = false;
        c.out_len = 0;
        c.out_off = 0;
    }
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
/// sized for the base64 screen document (3,328 characters plus its fields) and a log page
var json_buf: [3584]u8 = undefined;

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
        c.reset();
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
            c.reset();
            c.fd = fd;
            c.state = .reading;
            c.started_ns = now;
            c.last_ns = now;
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
                self.respondError(c, 413, "body_too_large", "bodies are limited to 8192 bytes");
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
            .set_scene => |s| self.relay(c, .{ .set_base = .{ .base = @intFromEnum(s.base), .generator = if (s.generator) |g| @intFromEnum(g) else 0xff, .seed = s.seed orelse 0, .style = if (s.style) |st| messages.ClockStyle.fromPatch(st) else .{}, .transition = messages.Transition.fromSpec(s.transition) } }, s.request_id, s.epoch orelse 0, now),
            .action => |a| switch (a.kind) {
                .brightness => self.relay(c, .{ .brightness = .{ .value = a.brightness.? } }, a.request_id, a.epoch, now),
                .reseed => self.relay(c, .{ .reseed = .{ .seed = a.seed orelse @truncate(now ^ a.request_id) } }, a.request_id, a.epoch, now),
                .arm_stream => self.relay(c, .arm_stream, a.request_id, a.epoch, now),
                .power => self.relay(c, .{ .power = .{ .on = @intFromBool(a.power.?) } }, a.request_id, a.epoch, now),
            },
            .screen => |s| {
                c.screen_raw = s.raw;
                self.ask(c, .screen_get, .screen, now);
            },
            .logs => |l| self.ask(c, .{ .log_get = .{ .after = l.after } }, .logs, now),
            .input => |i| self.relay(c, .{ .inject_input = .{ .control = @intFromEnum(i.control), .event = @intFromEnum(i.event), .steps = i.steps } }, i.request_id, i.epoch, now),
            .notify => |n| self.relay(c, .{ .notify = messages.Notify.init(n.text, n.colour, n.duration_s, messages.Transition.fromSpec(n.transition)) }, n.request_id, n.epoch, now),
            .frame => |f| {
                if (!self.frameAllowed(now)) {
                    c.client_id = f.request_id;
                    self.respondError(c, 429, "frame_rate", "occasional frames are limited to ten per second");
                    self.flushConn(c, now);
                    return;
                }
                self.relay(c, .{ .frame = .{ .duration_s = f.duration_s, .transition = messages.Transition.fromSpec(f.transition), .rgb = f.rgb.* } }, f.request_id, f.epoch, now);
            },
            .config_get => self.ask(c, .config_get, .config, now),
            // the supervisor keeps the document, so every canvas route is a round trip to it
            .canvas_get => self.ask(c, .canvas_get, .canvas, now),
            .canvas_put => |d| self.ask(c, .{ .canvas = d }, .canvas, now),
            .canvas_patch => |cp| self.ask(c, .{ .canvas_patch = cp }, .canvas, now),
            .canvas_clear => self.ask(c, .canvas_clear, .canvas, now),
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
            .ntfy_get => {
                if (!self.have_cfg) {
                    self.respondError(c, 503, "not_ready", "settings not received yet");
                    self.flushConn(c, now);
                    return;
                }
                var o = Out{ .buf = &json_buf };
                self.ntfySettingsJson(&o);
                self.respond(c, 200, "application/json", o.slice());
                self.flushConn(c, now);
            },
            .ntfy_put => |p| {
                const w = messages.NtfyPut.fromApi(p) catch {
                    self.respondError(c, 400, "invalid_value", "a text field is too long");
                    self.flushConn(c, now);
                    return;
                };
                self.ask(c, .{ .ntfy_put = w }, .config, now);
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
        if (self.findConn(true, request_id)) |c| if (c.awaiting == .renderer_result or c.awaiting == .screen) {
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
        };
        for (&self.m_pending) |*p| if (p.used and p.id == request_id) {
            p.used = false;
            self.publishResult(request_id, r.status, r.revision);
            return;
        };
    }

    fn onScreen(self: *Netd, request_id: u64, sc: *const messages.Screen, now: u64) void {
        if (self.findConn(true, request_id)) |c| {
            if (c.awaiting != .screen) return;
            if (c.screen_raw) {
                self.respond(c, 200, "application/octet-stream", &sc.rgb);
            } else {
                var o = Out{ .buf = &json_buf };
                self.screenJson(&o, sc);
                if (o.overflow) self.respondError(c, 500, "internal", "the screen document did not fit") else self.respond(c, 200, "application/json", o.slice());
            }
            self.flushConn(c, now);
            return;
        }
        for (&self.m_pending) |*p| if (p.used and p.id == request_id) {
            p.used = false;
            // binary: u32 revision, u8 brightness, u8 power, then the 2,496 rgb bytes
            var payload: [6 + geometry.rgb_bytes]u8 = undefined;
            std.mem.writeInt(u32, payload[0..4], sc.revision, .big);
            payload[4] = sc.brightness;
            payload[5] = sc.power;
            @memcpy(payload[6..], &sc.rgb);
            self.mqttPublish("screen", &payload, 0, false);
            return;
        };
    }

    fn onLogs(self: *Netd, request_id: u64, l: *const messages.LogLines, now: u64) void {
        const c = self.findConn(true, request_id) orelse return;
        if (c.awaiting != .logs) return;
        var o = Out{ .buf = &json_buf };
        o.fmt("{{\"next\":{d},\"lines\":[", .{l.next});
        var it = l.iterator();
        var first = true;
        while (it.next()) |r| {
            if (!first) o.add(",");
            first = false;
            o.fmt("{{\"seq\":{d},\"text\":", .{r.seq});
            o.str(r.text);
            o.add("}");
        }
        o.add("]}");
        if (o.overflow) self.respondError(c, 500, "internal", "the log page did not fit") else self.respond(c, 200, "application/json", o.slice());
        self.flushConn(c, now);
    }

    /// a control event from the renderer: published as a momentary mqtt event, never retained,
    /// so a consumer that reconnects later cannot act on a stale press.
    fn onInput(self: *Netd, i: messages.Input) void {
        const control = messages.enumFromInt(actions.Control, i.control) orelse return;
        const event = messages.enumFromInt(actions.EdgeEvent, i.event) orelse return;
        if (!self.m_connected) return;
        var tb: [32]u8 = undefined;
        const suffix = std.fmt.bufPrint(&tb, "input/{s}", .{@tagName(control)}) catch return;
        var o = Out{ .buf = json_buf[0..128] };
        o.fmt("{{\"event_type\":\"{s}\",\"position\":{d}}}", .{ @tagName(event), i.position });
        self.mqttPublish(suffix, o.slice(), 0, false);
    }

    fn onStatus(self: *Netd, request_id: u64, st: messages.StatusSnapshot, now: u64) void {
        const changed = st.revision != self.status.revision or st.epoch != self.status.epoch or st.renderer_state != self.status.renderer_state or st.base != self.status.base or st.brightness != self.status.brightness or st.overlay != self.status.overlay or st.power != self.status.power or !std.meta.eql(st.clock, self.status.clock);
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

    /// the generators' own parameters, as a view: one object per generator keyed by the names its
    /// table declares, values in the same shape a patch would send. a generator with no parameters
    /// still appears, so a client can see the whole set.
    fn generatorParamsJson(self: *Netd, o: *Out, c: *const config.Config) void {
        _ = self;
        o.add(",\"generators\":{");
        inline for (@typeInfo(scene.Generator).@"enum".fields, 0..) |f, gi| {
            if (gi > 0) o.add(",");
            o.fmt("\"{s}\":{{", .{f.name});
            const own = comptime scene.paramsFor(@enumFromInt(f.value))[scene.art_params.len..];
            inline for (own, 0..) |pm, i| {
                if (i > 0) o.add(",");
                const v = if (gi < param.owner_count and i < param.max_per_owner) c.generator_params[gi][i] else 0;
                o.fmt("\"{s}\":", .{pm.name});
                switch (pm.kind) {
                    .choice => o.str(if (v < pm.choices.len) pm.choices[v] else "?"),
                    .toggle => o.add(if (v != 0) "\"on\"" else "\"off\""),
                    .colour => o.fmt("\"{x:0>6}\"", .{v & 0xffffff}),
                    .number => o.fmt("{d}", .{@as(i32, @bitCast(v))}),
                }
            }
            o.add("}");
        }
        o.add("}");
    }

    fn onCanvas(self: *Netd, request_id: u64, d: *const canvas.Document, now: u64) void {
        const c = self.findConn(true, request_id) orelse return;
        var o = Out{ .buf = &json_buf };
        canvasJson(&o, d);
        self.respond(c, 200, "application/json", o.slice());
        self.flushConn(c, now);
    }

    fn onCanvasError(self: *Netd, request_id: u64, e: messages.CanvasError, now: u64) void {
        const c = self.findConn(true, request_id) orelse return;
        switch (e.reason) {
            messages.CanvasError.unknown_element => self.respondError(c, 400, "unknown_element", "the document has no element with that id"),
            messages.CanvasError.wrong_field => self.respondError(c, 400, "invalid_element_field", "that field does not belong to that element's type"),
            else => self.respondError(c, 400, "document_full", "the document's pools cannot hold that"),
        }
        self.flushConn(c, now);
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
                .canvas => |*d| self.onCanvas(p.request_id, d, now),
                .canvas_error => |e| self.onCanvasError(p.request_id, e, now),
                .screen => |*sc| self.onScreen(p.request_id, sc, now),
                .log_lines => |*l| self.onLogs(p.request_id, l, now),
                .input => |i| self.onInput(i),
                else => log.warn("unexpected {s} from supervisor", .{@tagName(p.message)}),
            }
        }
    }

    // json documents

    fn baseName(b: u8) []const u8 {
        return switch (b) {
            0 => "clock",
            1 => "art",
            2 => "canvas",
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

    /// the document as held, in the shape a `PUT` would send it back: what is on the panel, not a
    /// separate vocabulary for reading it.
    fn canvasJson(o: *Out, d: *const canvas.Document) void {
        o.fmt("{{\"revision\":{d},\"elements\":[", .{d.revision});
        for (d.elements[0..d.count], 0..) |*e, i| {
            if (i > 0) o.add(",");
            o.fmt("{{\"type\":\"{s}\"", .{@tagName(e.kind())});
            if (e.id.len > 0) {
                o.add(",\"id\":");
                o.str(e.id.slice());
            }
            o.fmt(",\"at\":[{d},{d}]", .{ e.box.x, e.box.y });
            if (e.box.w != 0 or e.box.h != 0) o.fmt(",\"size\":[{d},{d}]", .{ e.box.w, e.box.h });
            o.fmt(",\"colour\":\"{x:0>2}{x:0>2}{x:0>2}\"", .{ e.colour[0], e.colour[1], e.colour[2] });
            if (e.anim.kind != .none) {
                o.fmt(",\"animate\":{{\"kind\":\"{s}\",\"ms\":{d},\"phase\":{d},\"amount\":{d},\"axis\":\"{s}\"}}", .{ @tagName(e.anim.kind), e.anim.ms, e.anim.phase, e.anim.amount, if (e.anim.axis_x) "x" else "y" });
            }
            switch (e.body) {
                .text => |t| {
                    o.add(",\"text\":");
                    o.str(d.textOf(t.span));
                    o.fmt(",\"font\":\"{s}\",\"align\":\"{s}\"", .{ @tagName(t.face), @tagName(t.alignment) });
                },
                .rect => |r| o.fmt(",\"filled\":{}", .{r.filled}),
                .line => |l| o.fmt(",\"to\":[{d},{d}]", .{ l.x2, l.y2 }),
                .circle => |cc| o.fmt(",\"r\":{d},\"filled\":{}", .{ cc.r, cc.filled }),
                .pixel => {},
                .bar => |b| o.fmt(",\"value\":{d},\"background\":\"{x:0>2}{x:0>2}{x:0>2}\",\"vertical\":{}", .{ b.value, b.background[0], b.background[1], b.background[2], b.vertical }),
                .sparkline => |sp| {
                    o.add(",\"data\":[");
                    for (d.dataOf(sp.span), 0..) |v, j| {
                        if (j > 0) o.add(",");
                        o.fmt("{d}", .{v});
                    }
                    o.fmt("],\"style\":\"{s}\",\"min\":{d},\"max\":{d},\"threshold\":{d}", .{ @tagName(sp.style), sp.min, sp.max, sp.threshold });
                    o.fmt(",\"over\":\"{x:0>2}{x:0>2}{x:0>2}\"", .{ sp.over[0], sp.over[1], sp.over[2] });
                },
            }
            o.add("}");
        }
        o.fmt("],\"limits\":{{\"elements\":{d},\"text_bytes\":{d},\"data_bytes\":{d},\"samples\":{d}}}}}", .{ canvas.max_elements, canvas.text_pool, canvas.data_pool, canvas.samples_max });
    }

    fn nightPhaseName(p: u8) []const u8 {
        return switch (p) {
            1...4 => night.Phase.text(@enumFromInt(p - 1)),
            else => "unknown",
        };
    }

    /// hundredths of a degree as a decimal, without pulling in float formatting
    fn degreesJson(o: *Out, hundredths: i16) void {
        const sign = if (hundredths < 0) "-" else "";
        const v: u32 = @abs(hundredths);
        o.fmt("{s}{d}.{d:0>2}", .{ sign, v / 100, v % 100 });
    }

    fn timeStateName(s: u8) []const u8 {
        return switch (s) {
            0 => "unsynced",
            1 => "synced",
            2 => "stale",
            else => "unknown",
        };
    }

    fn enumName(comptime E: type, value: u8) []const u8 {
        return if (messages.enumFromInt(E, value)) |v| @tagName(v) else "unknown";
    }

    /// the clock style as `{"font","colour_mode","colour","colour2","gradient"}`.
    fn clockJson(o: *Out, s: messages.ClockStyle) void {
        o.fmt("{{\"font\":\"{s}\",\"colour_mode\":\"{s}\",\"colour\":\"{x:0>2}{x:0>2}{x:0>2}\",\"colour2\":\"{x:0>2}{x:0>2}{x:0>2}\",\"gradient\":\"{s}\",\"spread\":{d},\"digits\":\"{s}\"}}", .{ enumName(clock.Font, s.font), enumName(clock.ColourMode, s.mode), s.colour[0], s.colour[1], s.colour[2], s.colour2[0], s.colour2[1], s.colour2[2], enumName(clock.Gradient, s.gradient), s.spread, enumName(clock.DigitStyle, s.digit) });
    }

    /// fps is only meaningful against a continuous cadence: art with no overlay. otherwise null.
    fn fpsJson(self: *Netd, o: *Out) void {
        const st = self.status;
        if (st.base == 0 and st.overlay == 0 and st.renderer_state == 2) o.fmt("\"fps\":{d}.{d},", .{ st.fps_x10 / 10, st.fps_x10 % 10 }) else o.add("\"fps\":null,");
    }

    fn statusJson(self: *Netd, o: *Out, now: u64) void {
        const st = self.status;
        o.add("{");
        o.fmt("\"epoch\":{d},\"revision\":{d},\"renderer\":\"{s}\",\"base\":\"{s}\",\"generator\":\"{s}\",\"overlay\":\"{s}\",\"brightness\":{d},\"power\":{},\"presented\":{d},", .{ st.epoch, st.revision, rendererName(st.renderer_state), baseName(st.base), generatorName(st.generator), overlayName(st.overlay), st.brightness, st.power != 0, st.presented });
        self.fpsJson(o);
        o.fmt("\"uptime_s\":{d},\"memory_available_kb\":{d},\"memory_total_kb\":{d},", .{ st.uptime_s, st.mem_available_kb, st.mem_total_kb });
        if (st.cpu_pct == 255) o.add("\"cpu_pct\":null,") else o.fmt("\"cpu_pct\":{d},", .{st.cpu_pct});
        o.fmt("\"restarts\":{d},\"network\":{{\"ip\":", .{st.restarts});
        if (st.ip_present != 0) o.fmt("\"{d}.{d}.{d}.{d}\"", .{ st.ip[0], st.ip[1], st.ip[2], st.ip[3] }) else o.add("null");
        o.fmt("}},\"time\":{{\"state\":\"{s}\",\"age_s\":", .{timeStateName(st.time_state)});
        if (st.time_age_s == 0xffffffff) o.add("null") else o.fmt("{d}", .{st.time_age_s});
        o.add("},\"clock\":");
        clockJson(o, st.clock);
        o.fmt(",\"ip_mode\":\"{s}\"", .{enumName(ip.Mode, st.ip_mode)});
        o.add(",\"night\":");
        self.nightStatusJson(o, &st);
        o.add(",\"ntfy\":");
        self.ntfyStatusJson(o);
        o.fmt(",\"config_revision\":{d},\"saved_revision\":{d},\"transport\":\"plaintext\",\"mqtt\":", .{ st.config_revision, st.saved_revision });
        self.mqttStatusJson(o, now);
        o.fmt(",\"boot_id\":\"{x:0>8}\",\"sample_age_ms\":{d},", .{ st.boot_id, st.sample_age_ms + @as(u32, @intCast(@min((now -| self.status_at_ns) / 1_000_000, 0xffffffff))) });
        self.telemetryJson(o);
        o.add("}");
    }

    /// what the night schedule is doing, and the crossings it is working from. the phase comes
    /// from the supervisor, which owns the schedule; the sun is recomputed here from the same
    /// settings and the same clock, so it costs nothing to carry it over the wire.
    fn nightStatusJson(self: *Netd, o: *Out, st: *const messages.StatusSnapshot) void {
        const c = &self.cfg;
        o.fmt("{{\"enabled\":{},\"phase\":", .{c.night});
        if (st.night_phase == 0) o.add("null") else o.fmt("\"{s}\"", .{nightPhaseName(st.night_phase)});
        o.fmt(",\"held\":{}", .{st.night_override != 0});
        const point = c.point();
        if (point != null and st.time_state != 0) {
            const d = solar.day(@intCast(sys.realtimeNs() / std.time.ns_per_s), point.?);
            o.add(",\"today\":{");
            inline for (.{ "dawn", "sunrise", "sunset", "dusk" }, .{ d.dawn, d.sunrise, d.sunset, d.dusk }, 0..) |name, at, i| {
                if (i > 0) o.add(",");
                if (at) |t| o.fmt("\"{s}\":{d}", .{ name, t }) else o.fmt("\"{s}\":null", .{name});
            }
            o.fmt(",\"sun_up\":{}}}", .{d.sun_up});
        } else o.add(",\"today\":null");
        o.add("}");
    }

    /// the framebuffer document: base64 keeps it usable from curl and jq; `?format=raw` is octets.
    fn screenJson(self: *Netd, o: *Out, sc: *const messages.Screen) void {
        o.fmt("{{\"width\":{d},\"height\":{d},\"epoch\":{d},\"revision\":{d},\"brightness\":{d},\"power\":{},\"rgb_base64\":\"", .{ geometry.width, geometry.height, self.currentEpoch(), sc.revision, sc.brightness, sc.power != 0 });
        const enc = std.base64.standard.Encoder;
        const need = enc.calcSize(sc.rgb.len);
        if (o.len + need + 2 > o.buf.len) {
            o.overflow = true;
            return;
        }
        _ = enc.encode(o.buf[o.len .. o.len + need], &sc.rgb);
        o.len += need;
        o.add("\"}");
    }

    fn configJson(self: *Netd, o: *Out) void {
        const c = &self.cfg;
        o.fmt("{{\"revision\":{d},\"saved_revision\":{d},\"brightness\":{d},\"base\":\"{s}\",\"generator\":\"{s}\",\"timezone\":", .{ c.revision, c.saved_revision, c.brightness, baseName(c.base), generatorName(c.generator) });
        o.str(c.timezone.slice());
        o.add(",\"ntp\":{\"server\":");
        if (c.ntp_server) |s| o.fmt("\"{d}.{d}.{d}.{d}\"", .{ s[0], s[1], s[2], s[3] }) else o.add("null");
        o.fmt(",\"interval_s\":{d}}},\"frame_timeout_ms\":{d},\"metrics_interval_s\":{d},\"discovery\":{{\"enabled\":{},\"prefix\":", .{ c.ntp_interval_s, c.frame_timeout_ms, c.metrics_interval_s, c.discovery });
        o.str(c.discovery_prefix.slice());
        o.add("},\"clock\":");
        clockJson(o, messages.ClockStyle.full(c.clockStyle()));
        o.fmt(",\"ip_mode\":\"{s}\"", .{enumName(ip.Mode, c.ip_mode)});
        o.fmt(",\"night\":{{\"enabled\":{},\"brightness\":{d},\"lead_min\":{d}}},\"latitude\":", .{ c.night, c.night_brightness, c.night_lead_min });
        if (c.latitude) |v| degreesJson(o, v) else o.add("null");
        o.add(",\"longitude\":");
        if (c.longitude) |v| degreesJson(o, v) else o.add("null");
        // and where those two resolve to, which is the timezone's own reference point when they
        // are not set. read-only: a patch sets latitude and longitude, or location_auto.
        o.add(",\"location\":");
        if (c.point()) |pt| {
            o.add("{\"latitude\":");
            degreesJson(o, pt.lat_c);
            o.add(",\"longitude\":");
            degreesJson(o, pt.lon_c);
            o.fmt(",\"source\":\"{s}\"}}", .{if (c.locationAuto()) "timezone" else "set"});
        } else o.add("null");
        self.generatorParamsJson(o, c);
        o.add(",\"allowed_origins\":[");
        for (c.origins[0..c.origin_count], 0..) |*org, i| {
            if (i > 0) o.add(",");
            o.str(org.slice());
        }
        o.add("]}");
    }

    fn ntfyStateName(state: u8) []const u8 {
        return switch (state) {
            1 => "connecting",
            2 => "subscribed",
            3 => "error",
            else => "off",
        };
    }

    /// the subscriber's state as reported through the supervisor's snapshot
    fn ntfyStatusJson(self: *Netd, o: *Out) void {
        const n = &self.status.ntfy;
        o.fmt("{{\"state\":\"{s}\",\"messages\":{d},\"error\":", .{ ntfyStateName(n.state), n.messages });
        o.str(n.err.slice());
        o.add("}");
    }

    /// the settings without the secrets, plus whether they are set, plus the live status
    fn ntfySettingsJson(self: *Netd, o: *Out) void {
        const n = &self.cfg.ntfy;
        o.fmt("{{\"enabled\":{},\"url\":", .{n.enabled});
        o.str(n.url.slice());
        o.add(",\"topic\":");
        o.str(n.topic.slice());
        o.add(",\"username\":");
        o.str(n.username.slice());
        o.fmt(",\"token_set\":{},\"password_set\":{},\"duration_s\":{d},\"insecure\":{},\"ca_set\":{},\"status\":", .{ n.token.len > 0, n.password.len > 0, n.duration_s, n.insecure, self.status.ntfy.ca_set != 0 });
        self.ntfyStatusJson(o);
        o.add("}");
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
        o.fmt("\"rss_kb\":{{\"supervisor\":{d},\"renderer\":{d},\"netd\":{d}}},\"renderer_restarts\":{d},\"mqtt_reconnects\":{d},\"scene\":\"{s}\",\"brightness\":{d},\"power\":{},", .{ st.rss_supervisor_kb, st.rss_renderer_kb, st.rss_netd_kb, st.restarts, self.client.reconnects, baseName(st.base), st.brightness, st.power != 0 });
        self.fpsJson(o);
        o.fmt("\"presented\":{d},\"http_requests\":{d},\"http_rejected\":{d},\"mqtt_commands\":{d},\"mqtt_dropped\":{d},\"time\":{{\"state\":\"{s}\"}},\"night\":\"{s}\",", .{ st.presented, self.http_requests, self.http_rejected, self.mqtt_commands, self.mqtt_dropped, timeStateName(st.time_state), if (st.night_phase == 0) "off" else nightPhaseName(st.night_phase) });
        self.telemetryJson(o);
        o.add("}");
    }

    /// the added telemetry, with explicit nulls for anything not measured.
    fn telemetryJson(self: *Netd, o: *Out) void {
        const st = self.status;
        var id: [24]u8 = undefined;
        o.fmt("\"device_id\":\"{s}\",", .{self.deviceId(&id)});
        if (st.load_1m_x100 == 0xffff) o.add("\"load_1m\":null,") else o.fmt("\"load_1m\":{d}.{d:0>2},", .{ st.load_1m_x100 / 100, st.load_1m_x100 % 100 });
        o.fmt("\"memory_free_kb\":{d},\"memory_total_kb\":{d},", .{ st.mem_free_kb, st.mem_total_kb });
        if (st.tmpfs_used_kb == 0xffffffff) o.add("\"tmpfs_used_kb\":null,") else o.fmt("\"tmpfs_used_kb\":{d},", .{st.tmpfs_used_kb});
        o.fmt("\"tmpfs_total_kb\":{d},\"flash_used_kb\":{d},\"flash_total_kb\":{d},", .{ st.tmpfs_total_kb, st.flash_used_kb, st.flash_total_kb });
        o.add("\"wifi\":{\"rssi_dbm\":");
        if (st.wifi_level_dbm == -32768) o.add("null") else o.fmt("{d}", .{st.wifi_level_dbm});
        o.add(",\"quality\":");
        if (st.wifi_quality == 255) o.add("null") else o.fmt("{d}", .{st.wifi_quality});
        o.add("},\"cpu_pct_by_process\":{");
        const names = [_][]const u8{ "supervisor", "renderer", "netd" };
        const vals = [_]u16{ st.cpu_supervisor_pct_x10, st.cpu_renderer_pct_x10, st.cpu_netd_pct_x10 };
        for (names, vals, 0..) |n, v, i| {
            if (i > 0) o.add(",");
            if (v == 0xffff) o.fmt("\"{s}\":null", .{n}) else o.fmt("\"{s}\":{d}.{d}", .{ n, v / 10, v % 10 });
        }
        o.add("},\"battery\":{\"millivolts\":");
        if (st.battery_mv == 0xffff) o.add("null") else o.fmt("{d}", .{st.battery_mv});
        o.add(",\"percent\":");
        if (st.battery_pct == 255) o.add("null") else o.fmt("{d}", .{st.battery_pct});
        o.add(",\"usb_present\":");
        if (st.usb_present == 255) o.add("null") else o.add(if (st.usb_present != 0) "true" else "false");
        o.add("}");
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
                var tb: [7][96]u8 = undefined;
                var topics: [7][]const u8 = undefined;
                const names = [_][]const u8{ "cmd/scene", "cmd/action", "cmd/notify", "cmd/frame", "cmd/config", "cmd/screen", "cmd/input" };
                for (names, 0..) |n, i| topics[i] = self.topic(&tb[i], n);
                var birth_buf: [96]u8 = undefined;
                const birth = std.fmt.bufPrint(&birth_buf, "{s}/status", .{self.cfg.discovery_prefix.slice()}) catch "homeassistant/status";
                var all: [8][]const u8 = undefined;
                for (topics, 0..) |t, i| all[i] = t;
                all[7] = birth;
                const space = self.mqttSpace();
                const n = mqtt.encodeSubscribe(space, self.client.packetId(), if (self.cfg.discovery) all[0..8] else all[0..7], 1) catch return;
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
            // the 14-byte envelope, or 18 or 19 bytes with a transition (effect, direction, duration_ms,
            // optionally exit) before the rgb
            const extra = p.payload.len -| mqtt_frame_envelope;
            const extended = extra == 4 or extra == 5;
            if (p.payload.len != mqtt_frame_envelope and !extended) return;
            const rid = std.mem.readInt(u64, p.payload[0..8], .big);
            const epoch = std.mem.readInt(u32, p.payload[8..12], .big);
            const duration = std.mem.readInt(u16, p.payload[12..14], .big);
            const t: messages.Transition = if (extended) .{ .has = 1, .effect = p.payload[14], .direction = p.payload[15], .duration_ms = std.mem.readInt(u16, p.payload[16..18], .big), .exit = if (extra == 5) p.payload[18] else 0 } else .{};
            const bad_transition = extended and (t.toSpec() == null or t.duration_ms > transition.max_duration_ms);
            if (duration < 1 or duration > 300 or bad_transition) {
                self.publishResult(rid, .rejected, self.status.revision);
                return;
            }
            if (!self.frameAllowed(now)) {
                self.publishResult(rid, .overload, self.status.revision);
                return;
            }
            const rgb_at: usize = mqtt_frame_envelope - geometry.rgb_bytes + extra;
            self.mqttRelay(.{ .frame = .{ .duration_s = duration, .transition = t, .rgb = p.payload[rgb_at..][0..geometry.rgb_bytes].* } }, rid, epoch, now);
            return;
        }
        if (std.mem.eql(u8, suffix, "screen")) {
            // any payload: the reply goes to `<prefix>/screen`, not retained
            self.mqttRelay(.screen_get, self.newId(), 0, now);
            return;
        }
        const kind: api.BodyKind = if (std.mem.eql(u8, suffix, "scene")) .scene else if (std.mem.eql(u8, suffix, "action")) .action else if (std.mem.eql(u8, suffix, "notify")) .notify else if (std.mem.eql(u8, suffix, "config")) .config_patch else if (std.mem.eql(u8, suffix, "input")) .input else return;
        switch (api.parseBody(kind, p.payload, &arena)) {
            .reject => |j| {
                var o = Out{ .buf = &json_buf };
                o.fmt("{{\"status\":\"rejected\",\"error\":\"{s}\",\"message\":\"{s}\"}}", .{ j.code, j.message });
                self.mqttPublish("result", o.slice(), 0, false);
            },
            .op => |op| switch (op) {
                .set_scene => |s| self.mqttRelay(.{ .set_base = .{ .base = @intFromEnum(s.base), .generator = if (s.generator) |g| @intFromEnum(g) else 0xff, .seed = s.seed orelse 0, .style = if (s.style) |st| messages.ClockStyle.fromPatch(st) else .{}, .transition = messages.Transition.fromSpec(s.transition) } }, s.request_id, s.epoch orelse 0, now),
                .action => |a| switch (a.kind) {
                    .brightness => self.mqttRelay(.{ .brightness = .{ .value = a.brightness.? } }, a.request_id, a.epoch, now),
                    .reseed => self.mqttRelay(.{ .reseed = .{ .seed = a.seed orelse @truncate(now ^ a.request_id) } }, a.request_id, a.epoch, now),
                    .arm_stream => self.mqttRelay(.arm_stream, a.request_id, a.epoch, now),
                    .power => self.mqttRelay(.{ .power = .{ .on = @intFromBool(a.power.?) } }, a.request_id, a.epoch, now),
                },
                .input => |i| self.mqttRelay(.{ .inject_input = .{ .control = @intFromEnum(i.control), .event = @intFromEnum(i.event), .steps = i.steps } }, i.request_id, i.epoch, now),
                .notify => |n| self.mqttRelay(.{ .notify = messages.Notify.init(n.text, n.colour, n.duration_s, messages.Transition.fromSpec(n.transition)) }, n.request_id, n.epoch, now),
                .config_patch => |cp| {
                    // the control subset only: transient brightness and scene parameters
                    const admin_fields = cp.timezone != null or cp.ntp_server != null or cp.ntp_interval_s != null or cp.frame_timeout_ms != null or cp.metrics_interval_s != null or cp.discovery != null or cp.discovery_prefix != null or cp.clock_font != null or cp.clock_colour_mode != null or cp.clock_colour != null or cp.clock_colour2 != null or cp.clock_gradient != null or cp.clock_spread != null or cp.ip_mode != null;
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
            var o = Out{ .buf = json_buf[0..1536] };
            self.metricsJson(&o, now);
            if (!o.overflow) self.mqttPublish("metrics", o.slice(), 0, false) else self.mqtt_dropped += 1;
            self.next_metrics_ns = now + @as(u64, self.cfg.metrics_interval_s) * ns_per_s;
        }
    }

    // home-assistant mqtt discovery: read-only diagnostic sensors over the metrics topic, the
    // display power over the state topic, and the physical controls as momentary event entities

    const Component = enum { sensor, binary_sensor, event };
    const Entity = struct {
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
    };
    const entities = [_]Entity{
        .{ .key = "power", .name = "display power", .component = .binary_sensor, .topic = "state", .template = "{{ 'ON' if value_json.power else 'OFF' }}", .device_class = "power" },
        .{ .key = "button_left", .name = "left button", .component = .event, .topic = "input/left", .event_types = "\"press\",\"release\"", .device_class = "button", .diagnostic = false },
        .{ .key = "button_middle", .name = "middle button", .component = .event, .topic = "input/middle", .event_types = "\"press\",\"release\"", .device_class = "button", .diagnostic = false },
        .{ .key = "button_right", .name = "right button", .component = .event, .topic = "input/right", .event_types = "\"press\",\"release\"", .device_class = "button", .diagnostic = false },
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

    /// the stable device identity: the wlan0 mac, or the boot id when there is none. never the ip.
    fn deviceId(self: *Netd, buf: *[24]u8) []const u8 {
        const st = self.status;
        if (st.mac_present != 0) return std.fmt.bufPrint(buf, "tc002-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ st.mac[0], st.mac[1], st.mac[2], st.mac[3], st.mac[4], st.mac[5] }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "tc002-boot{x:0>8}", .{st.boot_id}) catch buf[0..0];
    }

    fn discoveryTopic(self: *Netd, buf: []u8, e: Entity) []const u8 {
        var id: [24]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}/{s}/{s}/{s}/config", .{ self.disc_prefix_used.slice(), @tagName(e.component), self.deviceId(&id), e.key }) catch buf[0..0];
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
        const t = self.discoveryTopic(&tb, e);
        if (self.disc_remove) {
            self.mqttPublishTopic(t, "", 1, true);
        } else {
            var o = Out{ .buf = json_buf[0..1024] };
            const interval: u64 = if (self.cfg.metrics_interval_s != 0) self.cfg.metrics_interval_s else 30;
            var id: [24]u8 = undefined;
            const dev = self.deviceId(&id);
            o.fmt("{{\"name\":\"{s}\",\"unique_id\":\"{s}_{s}\",\"state_topic\":\"{s}/{s}\",\"availability_topic\":\"{s}/availability\"", .{ e.name, dev, e.key, self.prefix(), e.topic, self.prefix() });
            switch (e.component) {
                .sensor => o.fmt(",\"value_template\":\"{s}\",\"expire_after\":{d}", .{ e.template, interval * 3 }),
                .binary_sensor => o.fmt(",\"value_template\":\"{s}\",\"payload_on\":\"ON\",\"payload_off\":\"OFF\"", .{e.template}),
                .event => o.fmt(",\"event_types\":[{s}]", .{e.event_types}),
            }
            if (e.diagnostic) o.add(",\"entity_category\":\"diagnostic\"");
            if (e.unit.len > 0) o.fmt(",\"unit_of_measurement\":\"{s}\"", .{e.unit});
            if (e.device_class.len > 0) o.fmt(",\"device_class\":\"{s}\"", .{e.device_class});
            if (e.state_class.len > 0) o.fmt(",\"state_class\":\"{s}\"", .{e.state_class});
            o.fmt(",\"device\":{{\"identifiers\":[\"{s}\"],\"name\":\"tc002\",\"model\":\"tc002 custom runtime\",\"manufacturer\":\"ulanzi (custom firmware)\",\"sw_version\":\"plan-b\"}},\"origin\":{{\"name\":\"tc002-netd\"}}}}", .{dev});
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
    for (&conns) |*c| c.reset();
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
