//! tc002-supervisor: raises the anti-brick property before anything else, audits what it
//! inherited from the vendor loader, then supervises the renderer over a private seqpacket
//! channel: ready and heartbeat deadlines, graceful stop with escalation, bounded restarts with a
//! fallback binary, the physical maintenance gesture, and wlan0 address changes.
const std = @import("std");
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const props = @import("sys/props.zig");
const codec = @import("ipc/codec.zig");
const messages = @import("ipc/messages.zig");
const evdev = @import("input/evdev.zig");
const child = @import("supervisor/child.zig");
const maintenance = @import("supervisor/maintenance.zig");
const cli = @import("supervisor/cli.zig");
const config = @import("supervisor/config.zig");
const mcu = @import("supervisor/mcu.zig");
const logring = @import("supervisor/logring.zig");
const tz = @import("scene/tz.zig");
const clock = @import("scene/clockfont.zig");
const scene = @import("scene/scene.zig");
const ip = @import("scene/ip.zig");
const clockscene = @import("scene/clock.zig");
const param = @import("scene/param.zig");
const sntp = @import("supervisor/sntp.zig");
const metrics = @import("supervisor/metrics.zig");
const night = @import("supervisor/night.zig");
const canvas = @import("scene/canvas.zig");
const api = @import("net/api.zig");

const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const ns_per_s = std.time.ns_per_s;

/// the wall clock in whole seconds, which is what the sun is on
fn unixNow() i64 {
    return @intCast(sys.realtimeNs() / ns_per_s);
}

const Tag = enum(u64) { timer = 1, signals = 2, ipc = 3, keys = 4, netd = 5, mcu = 6, logs = 7, sntp = 8, ntfy = 9, berry = 10 };

const tick_ns: u64 = 100_000_000;
/// how often the night schedule is consulted: a ramp of tens of minutes over a hundred steps moves
/// no faster than this, and asking costs a few dozen floating point operations
const night_poll_ns: u64 = 10 * ns_per_s;
const property_timeout_ns: u64 = 2 * ns_per_s;
const ipc_packets_per_iteration = 32;
const relay_timeout_ns: u64 = 2 * ns_per_s;
const relay_max = 32;
const netd_restart_ns: u64 = 1 * ns_per_s;
const sample_period_ns: u64 = 5 * ns_per_s;
const netd_uid: u32 = 1001;
const netd_gid: u32 = 1001;
const http_port: u16 = 80;

var lifecycle = child.Lifecycle{};
var gesture = maintenance.Gesture{};
var packet_buf: [codec.max_message]u8 = undefined;
var send_buf: [codec.max_message]u8 = undefined;
var evbuf: [32 * evdev.event_size]u8 = undefined;
var netd_packet_buf: [codec.max_message]u8 = undefined;
var ntfy_packet_buf: [codec.max_message]u8 = undefined;
var ntfy_send_buf: [codec.max_message]u8 = undefined;
var berry_packet_buf: [codec.max_message]u8 = undefined;
var berry_send_buf: [codec.max_message]u8 = undefined;
const berry_backoff_min_ns: u64 = 2 * ns_per_s;
const berry_backoff_max_ns: u64 = 60 * ns_per_s;
/// berryd reports every second. two seconds of silence is the renderer's own threshold, and it is
/// the only way to notice a vm wedged inside a script: the process stays alive and stops answering.
const berry_silence_ns: u64 = 2 * ns_per_s;
const ntfy_backoff_min_ns: u64 = 2 * ns_per_s;
const ntfy_backoff_max_ns: u64 = 60 * ns_per_s;
var config_buf: [config.file_max]u8 = undefined;
var canvas_file_buf: [canvas.file_max]u8 = undefined;
/// the largest file the durable-state migration copies is the ntfy ca
var migrate_buf: [api.max_ca]u8 = undefined;
var config_arena: [4096]u8 = undefined;
var proc_buf: [4096]u8 = undefined;
var log_buf: [1024]u8 = undefined;
/// every process's recent log lines, served to netd in pages
var ring = logring.Ring{};
var assembler = logring.Assembler{};

fn ringSink(line: []const u8) void {
    ring.push(line);
}

const Relay = struct { used: bool = false, id: u64 = 0, deadline_ns: u64 = 0, from_ntfy: bool = false };

const mcu_reply_timeout_ns: u64 = 500_000_000;

/// the single nonblocking handler for the pixel mcu's serial link: one outstanding query at a
/// time, bounded reads, unsolicited frames (mic reports) counted and discarded, no state changes
/// sent to the mcu and never the firmware-upload protocol.
const McuLink = struct {
    fd: ?sys.Fd = null,
    sync: mcu.Sync = .{},
    awaiting: ?u8 = null,
    deadline_ns: u64 = 0,
    next_poll_ns: u64 = 0,
    poll_ns: u64 = 30 * ns_per_s,
    version_asked: bool = false,
    replies: u32 = 0,
    timeouts: u32 = 0,
    unsolicited: u32 = 0,
    last_ok_ns: u64 = 0,
    version: [24]u8 = undefined,
    version_len: usize = 0,

    fn send(self: *McuLink, cmd: u8, payload: []const u8, now: u64) void {
        const fd = self.fd orelse return;
        var frame: [mcu.max_frame]u8 = undefined;
        const bytes = mcu.encode(&frame, cmd, payload) catch return;
        sys.writeAll(fd, bytes) catch |e| {
            log.warn("mcu write failed: {s}", .{sys.errText(e)});
            return;
        };
        self.awaiting = cmd;
        self.deadline_ns = now + mcu_reply_timeout_ns;
    }

    fn readable(self: *McuLink, s: *Supervisor, now: u64) void {
        const fd = self.fd orelse return;
        var buf: [256]u8 = undefined;
        var rounds: u32 = 0;
        while (rounds < 8) : (rounds += 1) {
            const n = sys.read(fd, &buf) catch |e| switch (e) {
                error.WouldBlock, error.Interrupted => break,
                else => {
                    log.warn("mcu read failed: {s}", .{sys.errText(e)});
                    return;
                },
            };
            if (n == 0) break;
            self.sync.push(buf[0..n]);
        }
        while (self.sync.next()) |f| {
            const used = f.used;
            self.handle(s, f, now);
            self.sync.consume(used);
        }
    }

    fn handle(self: *McuLink, s: *Supervisor, f: mcu.Frame, now: u64) void {
        const want = self.awaiting orelse {
            self.unsolicited +|= 1;
            return;
        };
        if (f.cmd != want) {
            self.unsolicited +|= 1;
            return;
        }
        self.awaiting = null;
        self.replies +|= 1;
        self.last_ok_ns = now;
        switch (f.cmd) {
            @intFromEnum(mcu.Command.query_version) => {
                const n = @min(f.payload.len, self.version.len);
                @memcpy(self.version[0..n], f.payload[0..n]);
                self.version_len = n;
                log.info("mcu version reply: {s} ({d} bytes)", .{ self.version[0..n], f.payload.len });
                self.send(@intFromEnum(mcu.Command.query_battery), "", now);
            },
            @intFromEnum(mcu.Command.query_battery) => {
                if (mcu.parseBattery(f.payload)) |b| {
                    s.snapshot.battery_mv = b.millivolts;
                    s.snapshot.battery_pct = if (b.raw_first <= 100) b.raw_first else 255;
                    if (s.cfg_stats) log.info("mcu battery: first={d} raw={d} -> {d} mv", .{ b.raw_first, b.raw_value, b.millivolts });
                } else log.warn("mcu battery reply too short: {d} bytes", .{f.payload.len});
                self.send(@intFromEnum(mcu.Command.query_usb), "", now);
            },
            @intFromEnum(mcu.Command.query_usb) => {
                if (f.payload.len >= 1) {
                    s.snapshot.usb_present = if (f.payload[0] != 0) 1 else 0;
                    if (s.cfg_stats) log.info("mcu usb: {d}", .{f.payload[0]});
                }
            },
            else => {},
        }
    }

    fn poll(self: *McuLink, s: *Supervisor, now: u64) void {
        if (self.fd == null) return;
        if (self.awaiting != null) {
            if (now >= self.deadline_ns) {
                self.timeouts +|= 1;
                if (self.timeouts == 1 or self.timeouts % 20 == 0) log.warn("mcu: no reply to command {x:0>2} within 500 ms ({d} timeouts so far)", .{ self.awaiting.?, self.timeouts });
                self.awaiting = null;
                self.next_poll_ns = now + self.poll_ns;
                if (self.timeouts >= 3 and self.last_ok_ns == 0) {
                    s.snapshot.battery_mv = 0xffff;
                    s.snapshot.battery_pct = 255;
                    s.snapshot.usb_present = 255;
                }
            }
            return;
        }
        if (now < self.next_poll_ns) return;
        self.next_poll_ns = now + self.poll_ns;
        if (!self.version_asked) {
            self.version_asked = true;
            self.send(@intFromEnum(mcu.Command.query_version), "", now);
        } else self.send(@intFromEnum(mcu.Command.query_battery), "", now);
    }
};

// --- sntp (feat/sntp) ---------------------------------------------------------------------------

/// the sntp client's socket side: one udp socket connected to the configured server, the pure
/// client state machine, the clock corrections, and rate-limited logging.
const SntpLink = struct {
    fd: ?sys.Fd = null,
    client: sntp.Client = .{},
    nonce: u32 = 0x9e37_79b9,
    consecutive_failures: u32 = 0,

    fn nextNonce(self: *SntpLink) u32 {
        var x = self.nonce;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.nonce = x;
        return x;
    }

    /// (re)open the socket for the configured server; at startup and whenever the settings change.
    fn configure(self: *SntpLink, s: *Supervisor, now: u64) void {
        if (self.fd) |fd| {
            sys.epollDel(s.ep, fd);
            sys.close(fd);
            self.fd = null;
        }
        self.client.configure(s.cfg.ntp_server, s.cfg.ntp_interval_s, now);
        self.client.setNetwork(s.last_ip != null, now);
        self.consecutive_failures = 0; // a new server gets its own first warning
        const addr = s.cfg.ntp_server orelse {
            log.info("sntp disabled: no ntp_server configured", .{});
            return;
        };
        const fd = sys.udpConnect(addr, sntp.port) catch |e| {
            log.warn("sntp socket to {d}.{d}.{d}.{d} failed: {s}", .{ addr[0], addr[1], addr[2], addr[3], sys.errText(e) });
            self.client.configure(null, s.cfg.ntp_interval_s, now);
            return;
        };
        sys.epollAdd(s.ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.sntp)) catch |e| {
            log.warn("sntp socket epoll add failed: {s}", .{sys.errText(e)});
            sys.close(fd);
            self.client.configure(null, s.cfg.ntp_interval_s, now);
            return;
        };
        self.fd = fd;
        log.info("sntp server {d}.{d}.{d}.{d}, polling every {d} s once wlan0 has an address", .{ addr[0], addr[1], addr[2], addr[3], s.cfg.ntp_interval_s });
    }

    fn failure(self: *SntpLink, text: []const u8) void {
        self.consecutive_failures +|= 1;
        if (self.consecutive_failures == 1 or self.consecutive_failures % 10 == 0) log.warn("sntp: {s} ({d} consecutive failures)", .{ text, self.consecutive_failures });
    }

    fn poll(self: *SntpLink, now: u64) void {
        switch (self.client.poll(now)) {
            .none => {},
            .timeout => self.failure("no reply within 2 s"),
            .send => {
                const fd = self.fd orelse return;
                const t1 = sys.realtimeNs();
                const req = sntp.buildRequest(t1, self.nextNonce());
                sys.udpSend(fd, &req.bytes) catch |e| {
                    self.client.onSocketError(now);
                    self.failure(sys.errText(e));
                    return;
                };
                self.client.onSent(req.sent, t1, now);
            },
        }
    }

    fn readable(self: *SntpLink, s: *Supervisor, now: u64) void {
        const fd = self.fd orelse return;
        var buf: [128]u8 = undefined;
        var rounds: u32 = 0;
        while (rounds < 4) : (rounds += 1) {
            const pkt = sys.udpRecv(fd, &buf) catch |e| {
                self.client.onSocketError(now);
                self.failure(if (e == error.Closed) "server unreachable (icmp)" else sys.errText(e));
                return;
            } orelse return;
            const t4 = sys.realtimeNs();
            switch (self.client.onReply(pkt, t4, now)) {
                .ok => |r| self.apply(s, r, now),
                .rejected => |why| self.failure(sntp.rejectText(why)),
            }
        }
    }

    /// step large offsets (the renderer rearms its wall-clock deadline), slew small ones.
    fn apply(self: *SntpLink, s: *Supervisor, r: sntp.Reply, now: u64) void {
        const how = sntp.correctionFor(r.offset_ns);
        switch (how) {
            .step => {
                const target: i128 = @as(i128, sys.realtimeNs()) + r.offset_ns;
                sys.clockSetRealtime(@intCast(@max(target, 0))) catch |e| {
                    log.err("sntp: clock_settime failed: {s}", .{sys.errText(e)});
                    return;
                };
                s.send(.time_corrected);
            },
            .slew => sys.adjtimeOffset(@intCast(@divTrunc(r.offset_ns, 1000))) catch |e| {
                log.err("sntp: adjtimex failed: {s}", .{sys.errText(e)});
                return;
            },
        }
        log.info("sntp: offset {d} ms, delay {d} ms, stratum {d}, {s}", .{ @divTrunc(r.offset_ns, 1_000_000), @divTrunc(r.delay_ns, 1_000_000), r.stratum, if (how == .step) "stepped" else "slewing" });
        self.consecutive_failures = 0;
        self.publish(s, now);
        s.sendNetd(.{ .status = s.snapshot }, 0);
    }

    fn publish(self: *SntpLink, s: *Supervisor, now: u64) void {
        const ts = self.client.timeState(now);
        s.snapshot.time_state = ts.state;
        s.snapshot.time_age_s = ts.age_s;
    }
};

// --- end sntp -----------------------------------------------------------------------------------

const Supervisor = struct {
    cfg_cli: cli.Config,
    cfg_dir_text: []const u8,
    /// where settings and credentials are read and written: the durable partition when it is
    /// usable, otherwise cfg_dir_text, which is the volatile behaviour this replaced
    state_dir_text: []const u8,
    cfg_stats: bool,
    ep: sys.Fd,
    timer: sys.Fd,
    sigfd: sys.Fd,
    keys: ?sys.Fd,
    self_pid: sys.Pid,
    child_pid: ?sys.Pid = null,
    child_fd: ?sys.Fd = null,
    child_spawned_ns: u64 = 0,
    heartbeats: u64 = 0,
    restarts: u32 = 0,
    request_id: u64 = 1,
    last_ip: ?[4]u8 = null,
    next_ip_poll: u64 = 0,
    /// when the on-device menu's info page is due its next set of readings
    next_device_push: u64 = 0,
    shutting_down: bool = false,
    // network daemon
    cfg: config.Config = .{},
    creds: api.Credentials = undefined,
    listener: ?sys.Fd = null,
    netd_pid: ?sys.Pid = null,
    netd_fd: ?sys.Fd = null,
    netd_path: [:0]const u8 = "/tmp/tc002/tc002-netd",
    netd_restart_at: u64 = 0,
    netd_exits: child.NetdExits = .{},
    // the ntfy subscriber: a child like netd, restarted with backoff, replaced on a settings change
    ntfy_pid: ?sys.Pid = null,
    ntfy_fd: ?sys.Fd = null,
    ntfy_restart_at: u64 = 0,
    ntfy_backoff_ns: u64 = ntfy_backoff_min_ns,
    ntfy_spawned_ns: u64 = 0,
    ntfy_path: [:0]const u8 = "/tmp/tc002/tc002-ntfy",
    ntfy_ca: [api.max_ca]u8 = undefined,
    ntfy_ca_len: u16 = 0,
    ntfy_seq: u64 = 0,
    // the script interpreter: a child like the others, spawned only while it is enabled
    berry_pid: ?sys.Pid = null,
    berry_fd: ?sys.Fd = null,
    berry_restart_at: u64 = 0,
    berry_backoff_ns: u64 = berry_backoff_min_ns,
    berry_spawned_ns: u64 = 0,
    berry_heard_ns: u64 = 0,
    berry_path: [:0]const u8 = "/tmp/tc002/tc002-berryd",
    berry_replacing: bool = false,
    /// the running subscriber is being replaced after a settings change: its exit is expected
    ntfy_replacing: bool = false,
    relays: [relay_max]Relay = [_]Relay{.{}} ** relay_max,
    snapshot: messages.StatusSnapshot = .{},
    last_heartbeat: messages.Heartbeat = .{ .presented = 0, .revision = 0, .state = 0 },
    hb_presented_at_ns: u64 = 0,
    hb_presented: u64 = 0,
    next_sample_ns: u64 = 0,
    cpu_busy_prev: u64 = 0,
    cpu_total_prev: u64 = 0,
    boot_id: u32 = 0,
    proc_cpu_prev: [3]u64 = .{ 0, 0, 0 },
    proc_cpu_prev_ns: u64 = 0,
    net_prev: metrics.Net = .{},
    net_prev_ns: u64 = 0,
    mcu_link: McuLink = .{},
    /// the children's stdout and stderr: drained into the ring and echoed to our own stderr
    log_pipe: ?[2]sys.Fd = null,
    sntp_link: SntpLink = .{},
    /// the canvas document. the supervisor owns it because it is state a client reads back and
    /// will one day persist; the renderer gets a copy whenever it changes or restarts.
    canvas_doc: canvas.Document = .{},
    /// when this document's animations started. the supervisor keeps the same account the renderer
    /// does -- the same comparison over the same documents -- so `GET /canvas` can publish ages a
    /// second renderer can reproduce the phase from.
    canvas_clocks: canvas.Clocks = .{},
    /// the uploaded sprites, held for the same reason as the document and replayed with it
    sprites: canvas.Sprites = .{},
    /// the document revision last written to the state directory
    canvas_saved: u32 = 0,
    /// the night brightness schedule; the phase it is in lives in the snapshot
    night: night.Schedule = .{},
    next_night_poll: u64 = 0,

    fn send(self: *Supervisor, msg: messages.Message) void {
        self.request_id += 1;
        _ = self.sendRenderer(msg, self.request_id, lifecycle.epoch);
    }

    fn sendRenderer(self: *Supervisor, msg: messages.Message, request_id: u64, epoch: u32) bool {
        const fd = self.child_fd orelse return false;
        const packet = messages.encodePacket(msg, request_id, epoch, &send_buf) catch return false;
        sys.sendPacket(fd, packet) catch |e| {
            if (e != error.WouldBlock) log.warn("ipc send to renderer failed: {s}", .{sys.errText(e)});
            return false;
        };
        return true;
    }

    fn sendNetd(self: *Supervisor, msg: messages.Message, request_id: u64) void {
        const fd = self.netd_fd orelse return;
        const packet = messages.encodePacket(msg, request_id, lifecycle.epoch, &send_buf) catch return;
        sys.sendPacket(fd, packet) catch |e| {
            if (e != error.WouldBlock) log.warn("ipc send to netd failed: {s}", .{sys.errText(e)});
        };
    }

    // credentials and configuration

    fn pathIn(self: *Supervisor, buf: []u8, comptime rel: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/" ++ rel, .{self.cfg_dir()}) catch unreachable;
    }

    fn cfg_dir(self: *Supervisor) []const u8 {
        return self.cfg_dir_text;
    }

    /// settings and credentials; the relative layout matches pathIn so the two can be swapped
    fn statePathIn(self: *Supervisor, buf: []u8, comptime rel: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/" ++ rel, .{self.state_dir_text}) catch unreachable;
    }

    /// create every component of the state directory. /data is mounted by init before the app
    /// starts, but /data/tc002 and its child are ours to make.
    fn makeStateDir(self: *Supervisor) !void {
        var buf: [160]u8 = undefined;
        const path = self.state_dir_text;
        if (path.len == 0 or path.len + 1 > buf.len) return error.Invalid;
        var i: usize = 1;
        while (i <= path.len) : (i += 1) {
            if (i < path.len and path[i] != '/') continue;
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            const part: [:0]const u8 = buf[0..i :0];
            sys.mkdir(part, 0o700) catch |e| if (e != error.Exists) return e;
        }
    }

    /// carry settings and credentials over from the volatile directory the first time the durable
    /// one is used, so an upgrade keeps the settings and the tokens the console already holds. an
    /// existing durable file is never overwritten: this only ever fills a gap.
    fn migrateState(self: *Supervisor) void {
        if (std.mem.eql(u8, self.state_dir_text, self.cfg_dir_text)) return;
        var moved: u8 = 0;
        inline for (.{ "config", "credentials" }) |d| {
            var db: [160]u8 = undefined;
            sys.mkdir(self.statePathIn(&db, d), 0o700) catch {};
        }
        inline for (.{ "config/config.json", "credentials/tokens", "credentials/ntfy-ca.pem" }) |rel| {
            var from_buf: [160]u8 = undefined;
            var to_buf: [160]u8 = undefined;
            var dir_buf: [160]u8 = undefined;
            var tmp_buf: [160]u8 = undefined;
            var probe: [1]u8 = undefined;
            const to = self.statePathIn(&to_buf, rel);
            const absent = if (sys.readFile(to, &probe)) |_| false else |e| e == error.NotFound;
            if (absent) {
                if (sys.readFile(self.pathIn(&from_buf, rel), &migrate_buf)) |bytes| {
                    const dir = self.statePathIn(&dir_buf, comptime std.fs.path.dirname(rel).?);
                    const tmp = self.statePathIn(&tmp_buf, rel ++ ".tmp");
                    if (sys.saveFileAtomic(dir, tmp, to, bytes)) |_| {
                        moved += 1;
                    } else |e| log.warn("could not carry {s} over: {s}", .{ rel, sys.errText(e) });
                } else |_| {}
            }
        }
        if (moved > 0) log.info("carried {d} file(s) from {s} into {s}", .{ moved, self.cfg_dir_text, self.state_dir_text });
    }

    fn loadCredentials(self: *Supervisor) !void {
        var dir_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        const dir = self.statePathIn(&dir_buf, "credentials");
        sys.mkdir(dir, 0o700) catch {};
        const path = self.statePathIn(&path_buf, "credentials/tokens");
        var raw: [64]u8 = undefined;
        if (sys.readFile(path, &raw)) |bytes| {
            if (bytes.len == 64) {
                self.creds = .{ .control = raw[0..32].*, .admin = raw[32..64].* };
                log.info("credentials loaded", .{});
                return;
            }
        } else |_| {}
        try sys.getrandom(&raw);
        var tmp_buf: [160]u8 = undefined;
        const tmp = self.statePathIn(&tmp_buf, "credentials/tokens.tmp");
        try sys.saveFileAtomic(dir, tmp, path, &raw);
        self.creds = .{ .control = raw[0..32].*, .admin = raw[32..64].* };
        log.info("credentials generated (mode 0600 in the credentials directory; never logged)", .{});
    }

    fn loadConfig(self: *Supervisor) void {
        var dir_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        sys.mkdir(self.statePathIn(&dir_buf, "config"), 0o700) catch {};
        const path = self.statePathIn(&path_buf, "config/config.json");
        const bytes = sys.readFile(path, &config_buf) catch {
            log.info("no saved configuration; using defaults", .{});
            return;
        };
        self.cfg = config.fromJson(bytes, &config_arena) catch {
            log.warn("saved configuration is invalid; using defaults and keeping the file", .{});
            return;
        };
        log.info("configuration loaded, revision {d}", .{self.cfg.revision});
    }

    fn saveConfig(self: *Supervisor) messages.Status {
        var dir_buf: [160]u8 = undefined;
        var tmp_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        const dir = self.statePathIn(&dir_buf, "config");
        const tmp = self.statePathIn(&tmp_buf, "config/config.json.tmp");
        const path = self.statePathIn(&path_buf, "config/config.json");
        const text = config.toJson(&self.cfg, &config_buf) catch return .rejected;
        // counted here because here is where the runtime writes to flash. these are application
        // writes of the settings file and nothing more: jffs2 metadata, compression and garbage
        // collection are not in them, and this build exposes no mtd erase counters to add.
        const began = sys.monotonicNs();
        self.snapshot.saves +|= 1;
        sys.saveFileAtomic(dir, tmp, path, text) catch |e| {
            self.snapshot.save_failures +|= 1;
            log.err("configuration save failed: {s}", .{sys.errText(e)});
            return .unavailable;
        };
        self.snapshot.save_bytes +|= @intCast(@min(text.len, 0xffffffff));
        self.snapshot.save_last_ms = @intCast(@min((sys.monotonicNs() -| began) / std.time.ns_per_ms, 0xfffe));
        self.cfg.saved_revision = self.cfg.revision;
        log.info("configuration saved, revision {d}", .{self.cfg.revision});
        return .applied;
    }

    /// reboot, asked for on the panel and confirmed there. the display goes dark first so the
    /// device does not sit showing a frozen clock, then the vendor's own reboot runs.
    fn rebootNow(self: *Supervisor) void {
        self.send(.{ .power = .{ .on = 0 } });
        self.snapshot.power = 0;
        const pid = sys.fork() catch {
            log.err("reboot: fork failed", .{});
            return;
        };
        if (pid == 0) {
            sys.unblockAllSignals();
            const path: [:0]const u8 = "/bin/reboot";
            const argv = [_:null]?[*:0]const u8{path.ptr};
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(path.ptr, &argv, &envp) catch {};
            sys.exit(127);
        }
        log.info("reboot: /bin/reboot started as pid {d}", .{pid});
    }

    /// the saved parameters of every generator, so the renderer's scenes match the settings. the
    /// renderer applies each to the generator it belongs to, whichever one is showing.
    fn sendGeneratorParams(self: *Supervisor) void {
        for (self.cfg.generator_params, 0..) |slots, owner| {
            const declared = scene.paramsFor(@enumFromInt(@as(u8, @intCast(owner)))).len - scene.art_params.len;
            for (slots[0..@min(declared, slots.len)], 0..) |v, slot| {
                self.send(.{ .set_param = .{ .base = 0x80 | @as(u8, @intCast(owner)), .index = @intCast(slot), .value = v } });
            }
        }
    }

    /// a parameter of a base scene, changed from that scene's own menu on the panel. the renderer
    /// shows it already; here it becomes an ordinary settings patch, which persists itself.
    fn onSetParam(self: *Supervisor, sp: messages.SetParam) void {
        const before = self.cfg;
        const v = sp.value;
        const rgb = [3]u8{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) };
        const patched = switch (sp.base) {
            0 => switch (sp.index) { // art: its own parameter, then the showing generator's slots
                0 => self.cfg.patch(.{ .generator = messages.enumFromInt(scene.Generator, @as(u8, @truncate(v))) orelse return }),
                else => blk: {
                    const owner: usize = self.cfg.generator;
                    const slot = sp.index - 1;
                    if (owner >= param.owner_count or slot >= param.max_per_owner) return;
                    self.cfg.generator_params[owner][slot] = v;
                    self.cfg.revision += 1;
                    break :blk {};
                },
            },
            1 => switch (sp.index) { // the clock, in its table's order
                0 => self.cfg.patch(.{ .clock_font = messages.enumFromInt(clock.Font, @as(u8, @truncate(v))) orelse return }),
                1 => self.cfg.patch(.{ .clock_colour = rgb }),
                2 => self.cfg.patch(.{ .clock_colour_mode = messages.enumFromInt(clockscene.ColourMode, @as(u8, @truncate(v))) orelse return }),
                3 => self.cfg.patch(.{ .clock_colour2 = rgb }),
                4 => self.cfg.patch(.{ .clock_gradient = messages.enumFromInt(clockscene.Gradient, @as(u8, @truncate(v))) orelse return }),
                5 => self.cfg.patch(.{ .clock_spread = @as(u8, @truncate(v)) }),
                6 => self.cfg.patch(.{ .clock_digit = messages.enumFromInt(clockscene.DigitStyle, @as(u8, @truncate(v))) orelse return }),
                else => return,
            },
            2 => switch (sp.index) { // ip
                0 => self.cfg.patch(.{ .ip_mode = messages.enumFromInt(ip.Mode, @as(u8, @truncate(v))) orelse return }),
                else => return,
            },
            else => return,
        };
        patched catch |e| {
            log.warn("scene parameter {d}.{d} rejected: {s}", .{ sp.base, sp.index, @errorName(e) });
            self.cfg = before;
            return;
        };
        self.snapshot.config_revision = self.cfg.revision;
        self.sendNetd(.{ .config = self.cfg }, 0);
        self.persistSettings();
        log.info("scene parameter {d}.{d} set, revision {d}", .{ sp.base, sp.index, self.cfg.revision });
    }

    /// the on-device menu changed something. the renderer has already previewed it; here it is
    /// validated, applied and persisted like any other settings change, so it survives a reboot.
    fn onMenuRequest(self: *Supervisor, m: messages.MenuRequest, now: u64) void {
        const kind = messages.enumFromInt(messages.MenuRequest.Kind, m.kind) orelse {
            log.warn("unknown menu request {d}", .{m.kind});
            return;
        };
        switch (kind) {
            .power_off => {
                self.snapshot.power = 0;
                self.send(.{ .power = .{ .on = 0 } });
                log.info("menu: display off", .{});
                return;
            },
            .reboot => {
                log.info("menu: reboot confirmed on the device", .{});
                self.rebootNow();
                return;
            },
            .brightness, .clock_font, .generator, .ip_mode, .mqtt, .ntfy, .night, .night_level => {},
        }
        const before = self.cfg;
        const patched = switch (kind) {
            .brightness => self.cfg.patch(.{ .brightness = @truncate(m.value) }),
            .night => self.cfg.patch(.{ .night = m.value != 0 }),
            .night_level => self.cfg.patch(.{ .night_brightness = @truncate(m.value) }),
            .clock_font => self.cfg.patch(.{ .clock_font = messages.enumFromInt(clock.Font, @as(u8, @truncate(m.value))) orelse return }),
            .generator => self.cfg.patch(.{ .generator = messages.enumFromInt(scene.Generator, @as(u8, @truncate(m.value))) orelse return }),
            .ip_mode => self.cfg.patch(.{ .ip_mode = messages.enumFromInt(ip.Mode, @as(u8, @truncate(m.value))) orelse return }),
            .mqtt => blk: {
                var next = self.cfg.mqtt;
                next.enabled = m.value != 0;
                break :blk self.cfg.patchMqtt(.{ .enabled = next.enabled });
            },
            .ntfy => blk: {
                const next = self.cfg.patchNtfy(.{ .enabled = m.value != 0 }) catch |e| break :blk e;
                self.cfg.setNtfy(next);
                self.restartNtfy(now);
                break :blk {};
            },
            else => unreachable,
        };
        patched catch |e| {
            log.warn("menu {s} rejected: {s}", .{ @tagName(kind), @errorName(e) });
            self.cfg = before;
            return;
        };
        self.snapshot.config_revision = self.cfg.revision;
        // the renderer already shows it, but netd holds its own copy and acts on the mqtt and
        // ntfy settings itself, so it has to be told: nothing else pushes a change it did not ask
        // for. then it goes to disk like any other settings change.
        self.applyConfigLive(before);
        self.sendNetd(.{ .config = self.cfg }, 0);
        self.persistSettings();
        log.info("menu: {s} set, revision {d}", .{ @tagName(kind), self.cfg.revision });
    }

    /// every accepted settings change is written out at once: forgetting to save is what lost a
    /// configuration twice. the reply carries `saved_revision`, so a client confirms persistence by
    /// seeing it match `revision`; if the write failed they differ and the log says why.
    fn persistSettings(self: *Supervisor) void {
        _ = self.saveConfig();
        self.snapshot.config_revision = self.cfg.revision;
        self.snapshot.saved_revision = self.cfg.saved_revision;
    }

    /// live effects of a settings change: the renderer gets transient commands, netd the full config.
    fn applyConfigLive(self: *Supervisor, before: config.Config) void {
        const c = &self.cfg;
        if (before.brightness != c.brightness) {
            self.send(.{ .brightness = .{ .value = c.brightness } });
            self.night.hold(unixNow()); // set by hand, so the schedule stands aside until the next ramp
        }
        if (before.base != c.base or before.generator != c.generator) self.send(.{ .set_base = .{ .base = c.base, .generator = c.generator, .seed = 0 } });
        if (!std.mem.eql(u8, before.timezone.slice(), c.timezone.slice())) self.send(.{ .set_timezone = config.Text.init(c.tzRule()) });
        if (!std.meta.eql(before.clockStyle(), c.clockStyle())) self.send(.{ .clock_style = messages.ClockStyle.full(c.clockStyle()) });
        if (before.ip_mode != c.ip_mode) self.send(.{ .ip_mode = .{ .mode = c.ip_mode } });
        // a generator's parameters changed by an api patch have to reach the renderer too; the
        // panel menu applies its own preview, an http client has none
        if (!std.meta.eql(before.generator_params, c.generator_params)) self.sendGeneratorParams();
        if (!std.meta.eql(before.ntp_server, c.ntp_server) or before.ntp_interval_s != c.ntp_interval_s) self.sntp_link.configure(self, sys.monotonicNs()); // sntp
        const was_running = self.night.settings.enabled and self.night.point != null;
        self.syncNight();
        self.next_night_poll = 0; // a settings change takes effect now rather than at the next tick
        if (was_running and !(self.night.settings.enabled and self.night.point != null)) {
            // the schedule was driving the panel and has just stopped: give the settings' own
            // brightness back, because nothing else will
            self.night.override_until = null;
            self.snapshot.night_phase = 0;
            if (self.snapshot.brightness != c.brightness) self.send(.{ .brightness = .{ .value = c.brightness } });
        }
        // berryd takes its heap once at startup and cannot resize it under a live vm, so any berry
        // settings change replaces the process rather than trying to reconfigure it in place
        if (!std.meta.eql(before.berry, c.berry)) self.restartBerry(sys.monotonicNs());
        self.snapshot.config_revision = c.revision;
        self.snapshot.saved_revision = c.saved_revision;
    }

    // the network daemon

    fn spawnNetd(self: *Supervisor, now: u64) void {
        _ = now;
        const listener = self.listener orelse return;
        const fds = sys.socketpairSeqpacket() catch |e| {
            log.err("socketpair for netd failed: {s}", .{sys.errText(e)});
            return;
        };
        const pid = sys.fork() catch |e| {
            log.err("fork for netd failed: {s}", .{sys.errText(e)});
            sys.close(fds[0]);
            sys.close(fds[1]);
            return;
        };
        if (pid == 0) {
            sys.unblockAllSignals();
            sys.setSignalDisposition(.TERM, linux.SIG.DFL);
            sys.setSignalDisposition(.INT, linux.SIG.DFL);
            sys.setSignalDisposition(.PIPE, linux.SIG.DFL);
            if (self.log_pipe) |lp| {
                sys.dup2(lp[1], 1) catch sys.exit(126);
                sys.dup2(lp[1], 2) catch sys.exit(126);
            }
            // park both descriptors high first so neither dup2 can clobber the other's source
            sys.dup2(fds[1], 60) catch sys.exit(126);
            sys.dup2(listener, 61) catch sys.exit(126);
            sys.dup2(60, 3) catch sys.exit(126);
            sys.dup2(61, 5) catch sys.exit(126);
            var fd: i32 = 4;
            while (fd < 64) : (fd += 1) if (fd != 5) sys.close(fd);
            sys.prctlPdeathsig(.TERM) catch sys.exit(126);
            if (sys.getppid() != self.self_pid) sys.exit(125);
            sys.dropPrivileges(netd_uid, netd_gid) catch sys.exit(124);
            const argv = [_:null]?[*:0]const u8{ self.netd_path.ptr, if (self.cfg_stats) "--stats" else "--profile", if (self.cfg_stats) null else "isolated-lan" };
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(self.netd_path.ptr, &argv, &envp) catch {};
            sys.exit(127);
        }
        sys.close(fds[1]);
        self.netd_fd = fds[0];
        self.netd_pid = pid;
        sys.epollAdd(self.ep, fds[0], linux.EPOLL.IN, @intFromEnum(Tag.netd)) catch {};
        log.info("spawned netd pid {d} as uid {d}", .{ pid, netd_uid });
        self.sendNetd(.{ .credentials = self.creds }, 0);
        self.sendNetd(.{ .config = self.cfg }, 0);
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn reapNetd(self: *Supervisor, now: u64) void {
        const pid = self.netd_pid orelse return;
        const status = sys.waitNoHang(pid) catch |e| switch (e) {
            error.NoChild => @as(?u32, 0),
            else => return,
        } orelse return;
        if (self.shutting_down) {
            log.info("netd pid {d} stopped", .{pid});
        } else if ((status & 0x7f) == 0) {
            log.warn("netd pid {d} exited with code {d}", .{ pid, (status >> 8) & 0xff });
        } else {
            log.warn("netd pid {d} killed by signal {d}", .{ pid, status & 0x7f });
        }
        if (self.netd_fd) |fd| sys.close(fd);
        self.netd_fd = null;
        self.netd_pid = null;
        self.netd_exits.onExit(self.shutting_down);
        self.netd_restart_at = now + netd_restart_ns;
        for (&self.relays) |*r| r.used = false;
    }

    fn pollNetd(self: *Supervisor, now: u64) void {
        if (self.shutting_down or self.listener == null) return;
        if (self.netd_pid == null and now >= self.netd_restart_at) self.spawnNetd(now);
    }

    // the ntfy subscriber

    fn caSet(self: *const Supervisor) u8 {
        return @intFromBool(self.ntfy_ca_len > 0);
    }

    fn ntfyConfigMessage(self: *const Supervisor) messages.Message {
        var nc = messages.NtfyConfig{ .ntfy = self.cfg.ntfy, .ca_len = self.ntfy_ca_len };
        @memcpy(nc.ca[0..self.ntfy_ca_len], self.ntfy_ca[0..self.ntfy_ca_len]);
        return .{ .ntfy_config = nc };
    }

    fn sendNtfy(self: *Supervisor, msg: messages.Message) void {
        const fd = self.ntfy_fd orelse return;
        const packet = messages.encodePacket(msg, 0, lifecycle.epoch, &ntfy_send_buf) catch return;
        sys.sendPacket(fd, packet) catch |e| {
            if (e != error.WouldBlock) log.warn("ipc send to the ntfy subscriber failed: {s}", .{sys.errText(e)});
        };
    }

    fn spawnNtfy(self: *Supervisor, now: u64) void {
        const fds = sys.socketpairSeqpacket() catch |e| {
            log.err("socketpair for the ntfy subscriber failed: {s}", .{sys.errText(e)});
            self.ntfy_restart_at = now + ntfy_backoff_max_ns;
            return;
        };
        const pid = sys.fork() catch |e| {
            log.err("fork for the ntfy subscriber failed: {s}", .{sys.errText(e)});
            sys.close(fds[0]);
            sys.close(fds[1]);
            self.ntfy_restart_at = now + ntfy_backoff_max_ns;
            return;
        };
        if (pid == 0) {
            sys.unblockAllSignals();
            sys.setSignalDisposition(.TERM, linux.SIG.DFL);
            sys.setSignalDisposition(.INT, linux.SIG.DFL);
            sys.setSignalDisposition(.PIPE, linux.SIG.DFL);
            if (self.log_pipe) |lp| {
                sys.dup2(lp[1], 1) catch sys.exit(126);
                sys.dup2(lp[1], 2) catch sys.exit(126);
            }
            sys.dup2(fds[1], 60) catch sys.exit(126);
            sys.dup2(60, 3) catch sys.exit(126);
            var fd: i32 = 4;
            while (fd < 64) : (fd += 1) sys.close(fd);
            sys.prctlPdeathsig(.TERM) catch sys.exit(126);
            if (sys.getppid() != self.self_pid) sys.exit(125);
            sys.dropPrivileges(netd_uid, netd_gid) catch sys.exit(124);
            const argv = [_:null]?[*:0]const u8{self.ntfy_path.ptr};
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(self.ntfy_path.ptr, &argv, &envp) catch {};
            sys.exit(127);
        }
        sys.close(fds[1]);
        self.ntfy_fd = fds[0];
        self.ntfy_pid = pid;
        self.ntfy_spawned_ns = now;
        sys.epollAdd(self.ep, fds[0], linux.EPOLL.IN, @intFromEnum(Tag.ntfy)) catch {};
        log.info("spawned the ntfy subscriber pid {d} as uid {d}", .{ pid, netd_uid });
        self.sendNtfy(self.ntfyConfigMessage());
        self.snapshot.ntfy = .{ .state = 1, .messages = self.snapshot.ntfy.messages, .ca_set = self.caSet() };
    }

    fn reapNtfy(self: *Supervisor, now: u64) void {
        const pid = self.ntfy_pid orelse return;
        const status = sys.waitNoHang(pid) catch |e| switch (e) {
            error.NoChild => @as(?u32, 0),
            else => return,
        } orelse return;
        if (self.shutting_down or !self.cfg.ntfy.enabled or self.ntfy_replacing) {
            log.info("ntfy subscriber pid {d} stopped", .{pid});
        } else if ((status & 0x7f) == 0) {
            log.warn("ntfy subscriber pid {d} exited with code {d}", .{ pid, (status >> 8) & 0xff });
        } else {
            log.warn("ntfy subscriber pid {d} killed by signal {d}", .{ pid, status & 0x7f });
        }
        if (self.ntfy_fd) |fd| sys.close(fd);
        self.ntfy_fd = null;
        self.ntfy_pid = null;
        for (&self.relays) |*r| if (r.from_ntfy) {
            r.used = false;
        };
        if (self.ntfy_replacing) {
            // a replacement starts at once and shows as connecting until it reports
            self.ntfy_replacing = false;
            self.ntfy_backoff_ns = ntfy_backoff_min_ns;
            self.ntfy_restart_at = now;
            self.snapshot.ntfy = .{ .state = if (self.cfg.ntfy.enabled) 1 else 0, .messages = self.snapshot.ntfy.messages, .ca_set = self.caSet() };
        } else {
            // the backoff doubles up to a minute; a run that lasted longer than a minute starts over
            self.ntfy_backoff_ns = if (now - self.ntfy_spawned_ns > 60 * ns_per_s) ntfy_backoff_min_ns else @min(self.ntfy_backoff_ns * 2, ntfy_backoff_max_ns);
            self.ntfy_restart_at = now + self.ntfy_backoff_ns;
            if (self.cfg.ntfy.enabled and !self.shutting_down) {
                if (self.snapshot.ntfy.state != 3) self.snapshot.ntfy = .{ .state = 3, .messages = self.snapshot.ntfy.messages, .err = config.Text.init("subscriber exited"), .ca_set = self.caSet() };
            } else {
                self.snapshot.ntfy = .{ .messages = self.snapshot.ntfy.messages, .ca_set = self.caSet() };
            }
        }
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn pollNtfy(self: *Supervisor, now: u64) void {
        if (self.shutting_down) return;
        if (self.cfg.ntfy.enabled) {
            if (self.ntfy_pid == null and now >= self.ntfy_restart_at) self.spawnNtfy(now);
        } else if (self.ntfy_pid) |pid| sys.kill(pid, .TERM);
    }

    /// the settings changed: the subscriber takes them once, so a running one is replaced
    fn restartNtfy(self: *Supervisor, now: u64) void {
        self.ntfy_backoff_ns = ntfy_backoff_min_ns;
        self.ntfy_restart_at = now;
        if (self.ntfy_pid) |pid| {
            self.ntfy_replacing = true;
            sys.kill(pid, .TERM);
        }
        if (!self.cfg.ntfy.enabled) {
            self.snapshot.ntfy = .{ .messages = self.snapshot.ntfy.messages, .ca_set = self.caSet() };
            self.sendNetd(.{ .status = self.snapshot }, 0);
        }
    }

    /// the extra ca certificate lives beside the tokens (root only); the subscriber gets it over ipc
    fn storeNtfyCa(self: *Supervisor, pem: []const u8) void {
        self.ntfy_ca_len = @intCast(pem.len);
        @memcpy(self.ntfy_ca[0..pem.len], pem);
        var dir_buf: [160]u8 = undefined;
        var tmp_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        const dir = self.statePathIn(&dir_buf, "credentials");
        const tmp = self.statePathIn(&tmp_buf, "credentials/ntfy-ca.pem.tmp");
        const path = self.statePathIn(&path_buf, "credentials/ntfy-ca.pem");
        sys.saveFileAtomic(dir, tmp, path, pem) catch |e| log.warn("the ntfy ca could not be stored: {s}", .{sys.errText(e)});
        log.info("ntfy ca {s} ({d} bytes)", .{ if (pem.len > 0) "installed" else "removed", pem.len });
    }

    fn loadNtfyCa(self: *Supervisor) void {
        var path_buf: [160]u8 = undefined;
        const path = self.statePathIn(&path_buf, "credentials/ntfy-ca.pem");
        if (sys.readFile(path, &self.ntfy_ca)) |bytes| {
            self.ntfy_ca_len = @intCast(bytes.len);
            if (bytes.len > 0) log.info("ntfy ca loaded ({d} bytes)", .{bytes.len});
        } else |_| {}
        self.snapshot.ntfy.ca_set = self.caSet();
    }

    fn drainNtfy(self: *Supervisor, now: u64) void {
        const fd = self.ntfy_fd orelse return;
        var count: u32 = 0;
        while (count < ipc_packets_per_iteration) : (count += 1) {
            const packet = sys.recvPacket(fd, &ntfy_packet_buf) catch |e| {
                if (e != error.Closed) log.warn("ntfy subscriber receive failed: {s}", .{sys.errText(e)});
                return;
            } orelse return;
            const p = messages.decodePacket(packet) catch |e| {
                log.warn("bad packet from the ntfy subscriber: {s}", .{@errorName(e)});
                continue;
            };
            switch (p.message) {
                .notify => |n| {
                    if (self.child_fd == null or lifecycle.state != .running) continue;
                    var slot: ?*Relay = null;
                    for (&self.relays) |*r| if (!r.used) {
                        slot = r;
                        break;
                    };
                    const r = slot orelse continue;
                    self.ntfy_seq += 1;
                    const id: u64 = 0x8000_0000_0000_0000 | self.ntfy_seq;
                    if (!self.sendRenderer(.{ .notify = n }, id, lifecycle.epoch)) continue;
                    r.* = .{ .used = true, .id = id, .deadline_ns = now + relay_timeout_ns, .from_ntfy = true };
                },
                .ntfy_status => |st| {
                    self.snapshot.ntfy = st;
                    self.snapshot.ntfy.ca_set = self.caSet();
                    self.sendNetd(.{ .status = self.snapshot }, 0);
                },
                else => log.warn("unexpected {s} from the ntfy subscriber", .{@tagName(p.message)}),
            }
        }
    }

    // the script interpreter

    fn sendBerry(self: *Supervisor, msg: messages.Message) void {
        const fd = self.berry_fd orelse return;
        const packet = messages.encodePacket(msg, 0, lifecycle.epoch, &berry_send_buf) catch return;
        sys.sendPacket(fd, packet) catch |e| {
            if (e != error.WouldBlock) log.warn("ipc send to berryd failed: {s}", .{sys.errText(e)});
        };
    }

    fn berryConfigMessage(self: *const Supervisor) messages.Message {
        return .{ .berry_config = .{ .heap_kb = self.cfg.berry.heap_kb, .handler_ms = self.cfg.berry.handler_ms } };
    }

    fn spawnBerry(self: *Supervisor, now: u64) void {
        const fds = sys.socketpairSeqpacket() catch |e| {
            log.err("socketpair for berryd failed: {s}", .{sys.errText(e)});
            self.berry_restart_at = now + berry_backoff_max_ns;
            return;
        };
        const pid = sys.fork() catch |e| {
            log.err("fork for berryd failed: {s}", .{sys.errText(e)});
            sys.close(fds[0]);
            sys.close(fds[1]);
            self.berry_restart_at = now + berry_backoff_max_ns;
            return;
        };
        if (pid == 0) {
            sys.unblockAllSignals();
            sys.setSignalDisposition(.TERM, linux.SIG.DFL);
            sys.setSignalDisposition(.INT, linux.SIG.DFL);
            sys.setSignalDisposition(.PIPE, linux.SIG.DFL);
            if (self.log_pipe) |lp| {
                sys.dup2(lp[1], 1) catch sys.exit(126);
                sys.dup2(lp[1], 2) catch sys.exit(126);
            }
            sys.dup2(fds[1], 60) catch sys.exit(126);
            sys.dup2(60, 3) catch sys.exit(126);
            var fd: i32 = 4;
            while (fd < 64) : (fd += 1) sys.close(fd);
            sys.prctlPdeathsig(.TERM) catch sys.exit(126);
            if (sys.getppid() != self.self_pid) sys.exit(125);
            sys.dropPrivileges(netd_uid, netd_gid) catch sys.exit(124);
            const argv = [_:null]?[*:0]const u8{self.berry_path.ptr};
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(self.berry_path.ptr, &argv, &envp) catch {};
            sys.exit(127);
        }
        sys.close(fds[1]);
        self.berry_fd = fds[0];
        self.berry_pid = pid;
        self.berry_spawned_ns = now;
        self.berry_heard_ns = now;
        sys.epollAdd(self.ep, fds[0], linux.EPOLL.IN, @intFromEnum(Tag.berry)) catch {};
        log.info("spawned berryd pid {d} as uid {d}", .{ pid, netd_uid });
        self.sendBerry(self.berryConfigMessage());
        self.snapshot.berry_state = 1;
    }

    fn reapBerry(self: *Supervisor, now: u64) void {
        const pid = self.berry_pid orelse return;
        const status = sys.waitNoHang(pid) catch |e| switch (e) {
            error.NoChild => @as(?u32, 0),
            else => return,
        } orelse return;
        if (self.shutting_down or !self.cfg.berry.enabled or self.berry_replacing) {
            log.info("berryd pid {d} stopped", .{pid});
        } else if ((status & 0x7f) == 0) {
            log.warn("berryd pid {d} exited with code {d}", .{ pid, (status >> 8) & 0xff });
        } else {
            log.warn("berryd pid {d} killed by signal {d}", .{ pid, status & 0x7f });
        }
        if (self.berry_fd) |fd| sys.close(fd);
        self.berry_fd = null;
        self.berry_pid = null;
        self.snapshot.berry = .{};
        if (self.berry_replacing) {
            self.berry_replacing = false;
            self.berry_backoff_ns = berry_backoff_min_ns;
            self.berry_restart_at = now;
            self.snapshot.berry_state = if (self.cfg.berry.enabled) 1 else 0;
        } else {
            // a child that ran a while before dying starts the backoff over
            self.berry_backoff_ns = if (now - self.berry_spawned_ns > 60 * ns_per_s) berry_backoff_min_ns else @min(self.berry_backoff_ns * 2, berry_backoff_max_ns);
            self.berry_restart_at = now + self.berry_backoff_ns;
            self.snapshot.berry_state = if (self.cfg.berry.enabled and !self.shutting_down) 3 else 0;
        }
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn pollBerry(self: *Supervisor, now: u64) void {
        if (self.shutting_down) return;
        if (self.cfg.berry.enabled) {
            if (self.berry_pid == null and now >= self.berry_restart_at) {
                self.spawnBerry(now);
                return;
            }
            // the wedged case: alive, and no longer reporting. a script looping forever inside the
            // vm cannot answer, and the interpreter's own watchdog is the thing that failed if we
            // are here at all, so the process goes.
            if (self.berry_pid) |pid| {
                if (self.berry_heard_ns != 0 and now -| self.berry_heard_ns > berry_silence_ns) {
                    log.warn("berryd has not reported for {d} ms; killing pid {d}", .{ (now -| self.berry_heard_ns) / 1_000_000, pid });
                    self.berry_heard_ns = now; // do not kill it again before it is reaped
                    sys.kill(pid, .KILL);
                }
            }
        } else if (self.berry_pid) |pid| sys.kill(pid, .TERM);
    }

    /// the settings changed: berryd takes them once and cannot resize a live heap, so it is replaced
    fn restartBerry(self: *Supervisor, now: u64) void {
        self.berry_backoff_ns = berry_backoff_min_ns;
        self.berry_restart_at = now;
        if (self.berry_pid) |pid| {
            self.berry_replacing = true;
            sys.kill(pid, .TERM);
        }
        if (!self.cfg.berry.enabled) {
            self.snapshot.berry_state = 0;
            self.snapshot.berry = .{};
            self.sendNetd(.{ .status = self.snapshot }, 0);
        }
    }

    fn drainBerry(self: *Supervisor, now: u64) void {
        const fd = self.berry_fd orelse return;
        var count: u32 = 0;
        while (count < ipc_packets_per_iteration) : (count += 1) {
            const packet = sys.recvPacket(fd, &berry_packet_buf) catch |e| {
                if (e != error.Closed) log.warn("berryd receive failed: {s}", .{sys.errText(e)});
                return;
            } orelse return;
            const p = messages.decodePacket(packet) catch |e| {
                log.warn("bad packet from berryd: {s}", .{@errorName(e)});
                continue;
            };
            switch (p.message) {
                .berry_status => |st| {
                    self.berry_heard_ns = now;
                    self.snapshot.berry = st;
                    self.snapshot.berry_state = 2;
                    self.sendNetd(.{ .status = self.snapshot }, 0);
                },
                else => log.warn("unexpected {s} from berryd", .{@tagName(p.message)}),
            }
        }
    }

    fn relayResult(self: *Supervisor, request_id: u64, status: messages.Status, revision: u32) void {
        self.sendNetd(.{ .result = .{ .status = status, .revision = revision } }, request_id);
    }

    fn drainNetd(self: *Supervisor, now: u64) void {
        const fd = self.netd_fd orelse return;
        var count: u32 = 0;
        while (count < ipc_packets_per_iteration) : (count += 1) {
            const packet = sys.recvPacket(fd, &netd_packet_buf) catch |e| {
                if (e != error.Closed) log.warn("netd receive failed: {s}", .{sys.errText(e)});
                return;
            } orelse return;
            const p = messages.decodePacket(packet) catch |e| {
                log.warn("bad packet from netd: {s}", .{@errorName(e)});
                continue;
            };
            switch (p.message) {
                .log_get => |g| {
                    var page = messages.LogLines{ .next = g.after };
                    ring.page(g.after, &page);
                    self.sendNetd(.{ .log_lines = page }, p.request_id);
                },
                .set_base, .notify, .frame, .brightness, .reseed, .arm_stream, .screen_get, .inject_input, .power, .clock_style, .ip_mode => {
                    // a brightness from an api client or mqtt is as hand-set as the knob is
                    if (p.message == .brightness) self.night.hold(unixNow());
                    if (self.child_fd == null or lifecycle.state != .running) {
                        self.relayResult(p.request_id, .unavailable, self.snapshot.revision);
                        continue;
                    }
                    var slot: ?*Relay = null;
                    for (&self.relays) |*r| if (!r.used) {
                        slot = r;
                        break;
                    };
                    const r = slot orelse {
                        self.relayResult(p.request_id, .overload, self.snapshot.revision);
                        continue;
                    };
                    const epoch = if (p.epoch == 0) lifecycle.epoch else p.epoch;
                    if (!self.sendRenderer(p.message, p.request_id, epoch)) {
                        self.relayResult(p.request_id, .overload, self.snapshot.revision);
                        continue;
                    }
                    r.* = .{ .used = true, .id = p.request_id, .deadline_ns = now + relay_timeout_ns };
                },
                .status_get => self.sendNetd(.{ .status = self.snapshot }, p.request_id),
                .config_get => self.sendNetd(.{ .config = self.cfg }, p.request_id),
                .canvas_get => self.sendNetd(.{ .canvas = self.canvasView() }, p.request_id),
                .sprite => |sp| {
                    self.sprites.put(sp) catch {
                        self.sendNetd(.{ .canvas_error = .{ .reason = messages.CanvasError.full } }, p.request_id);
                        continue;
                    };
                    self.send(.{ .sprite = sp });
                    self.saveCanvas();
                    self.sendNetd(.{ .sprite_list = self.spriteList() }, p.request_id);
                    log.info("sprite {s} {d}x{d} stored", .{ sp.id.slice(), sp.w, sp.h });
                },
                .sprite_delete => |id| {
                    _ = self.sprites.remove(id.slice());
                    self.send(.{ .sprite_delete = id });
                    self.saveCanvas();
                    self.sendNetd(.{ .sprite_list = self.spriteList() }, p.request_id);
                },
                .sprite_list_get => self.sendNetd(.{ .sprite_list = self.spriteList() }, p.request_id),
                .canvas => |v| {
                    var next = v.doc;
                    next.revision = self.canvas_doc.revision +% 1;
                    self.installCanvas(next);
                    self.sendCanvas();
                    self.saveCanvas();
                    self.sendNetd(.{ .canvas = self.canvasView() }, p.request_id);
                    log.info("canvas: {d} elements, revision {d}", .{ self.canvas_doc.count, self.canvas_doc.revision });
                },
                .canvas_patch => |cp| {
                    // onto a copy, so the clocks can be told what actually changed
                    var next = self.canvas_doc;
                    canvas.applyPatch(&next, &cp) catch |e| {
                        log.warn("canvas patch rejected: {s}", .{@errorName(e)});
                        self.sendNetd(.{ .canvas_error = messages.CanvasError.of(e) }, p.request_id);
                        continue;
                    };
                    self.installCanvas(next);
                    self.sendCanvas();
                    self.sendNetd(.{ .canvas = self.canvasView() }, p.request_id);
                },
                .canvas_clear => {
                    var next = self.canvas_doc;
                    next.clear();
                    self.installCanvas(next);
                    self.sendCanvas();
                    self.saveCanvas();
                    self.sendNetd(.{ .canvas = self.canvasView() }, p.request_id);
                },
                .config_patch => |w| {
                    const before = self.cfg;
                    self.cfg.patch(w.toApi()) catch |e| {
                        self.sendNetd(.{ .save_result = .{ .status = if (e == error.RevisionConflict) .conflict else .rejected, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    };
                    self.applyConfigLive(before);
                    self.persistSettings();
                    self.sendNetd(.{ .config = self.cfg }, p.request_id);
                },
                .mqtt_put => |w| {
                    self.cfg.patchMqtt(w.toApi()) catch {
                        self.sendNetd(.{ .save_result = .{ .status = .rejected, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    };
                    self.snapshot.config_revision = self.cfg.revision;
                    self.persistSettings();
                    self.sendNetd(.{ .config = self.cfg }, p.request_id);
                },
                .ntfy_put => |w| {
                    const next = self.cfg.patchNtfy(w.toApi()) catch {
                        self.sendNetd(.{ .save_result = .{ .status = .rejected, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    };
                    if (w.has & messages.NtfyPut.F.ca != 0) self.storeNtfyCa(w.ca[0..w.ca_len]);
                    self.cfg.setNtfy(next);
                    self.snapshot.config_revision = self.cfg.revision;
                    self.restartNtfy(now);
                    self.persistSettings();
                    self.sendNetd(.{ .config = self.cfg }, p.request_id);
                },
                .config_save => |cs| {
                    if (cs.has_revision != 0 and cs.revision != self.cfg.revision) {
                        self.sendNetd(.{ .save_result = .{ .status = .conflict, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    }
                    const st = self.saveConfig();
                    self.snapshot.saved_revision = self.cfg.saved_revision;
                    self.sendNetd(.{ .save_result = .{ .status = st, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                },
                else => log.warn("unexpected {s} from netd", .{@tagName(p.message)}),
            }
        }
    }

    fn expireRelays(self: *Supervisor, now: u64) void {
        for (&self.relays) |*r| if (r.used and now >= r.deadline_ns) {
            r.used = false;
            self.relayResult(r.id, .timeout, self.snapshot.revision);
        };
    }

    // status snapshot and procfs sampling

    fn procValue(text: []const u8, key: []const u8) ?u64 {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, key)) continue;
            var it = std.mem.tokenizeAny(u8, line[key.len..], " \t:kB");
            const v = it.next() orelse return null;
            return std.fmt.parseInt(u64, v, 10) catch null;
        }
        return null;
    }

    /// utime+stime jiffies of a process from /proc/<pid>/stat (field 14 and 15, after the comm).
    fn cpuJiffiesOf(pid: ?sys.Pid) ?u64 {
        const p = pid orelse return null;
        var path: [48]u8 = undefined;
        const text = sys.readFile(std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{p}) catch return null, &proc_buf) catch return null;
        const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
        var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        var i: usize = 0;
        var total: u64 = 0;
        while (it.next()) |f| : (i += 1) {
            // fields after ')': state(3) ppid(4) ... utime(14) stime(15)
            if (i + 3 == 14 or i + 3 == 15) total += std.fmt.parseInt(u64, f, 10) catch 0;
            if (i + 3 > 15) break;
        }
        return total;
    }

    fn readMac(self: *Supervisor) void {
        var buf: [32]u8 = undefined;
        const text = sys.readFile("/sys/class/net/wlan0/address", &buf) catch return;
        const t = std.mem.trim(u8, text, " \n\r");
        if (t.len != 17) return;
        var mac: [6]u8 = undefined;
        var i: usize = 0;
        while (i < 6) : (i += 1) mac[i] = std.fmt.parseInt(u8, t[i * 3 .. i * 3 + 2], 16) catch return;
        self.snapshot.mac = mac;
        self.snapshot.mac_present = 1;
    }

    fn rssOf(pid: ?sys.Pid) u32 {
        const p = pid orelse return 0;
        var path: [48]u8 = undefined;
        const text = sys.readFile(std.fmt.bufPrintZ(&path, "/proc/{d}/status", .{p}) catch return 0, &proc_buf) catch return 0;
        return @intCast(@min(procValue(text, "VmRSS:") orelse 0, 0xffffffff));
    }

    /// the interface counters are the kernel's own unsigned long, which is 32 bits on this cpu;
    /// the parse keeps them wide, and this is where they meet the wire
    fn clamp32(v: u64) u32 {
        return @intCast(@min(v, 0xffffffff));
    }

    fn sample(self: *Supervisor, now: u64) void {
        if (sys.readFile("/proc/meminfo", &proc_buf)) |text| {
            self.snapshot.mem_available_kb = @intCast(@min(procValue(text, "MemAvailable:") orelse 0, 0xffffffff));
        } else |_| {}
        if (sys.readFile("/proc/stat", &proc_buf)) |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            if (lines.next()) |cpu| {
                var it = std.mem.tokenizeScalar(u8, cpu, ' ');
                _ = it.next();
                var fields: [8]u64 = .{0} ** 8;
                var i: usize = 0;
                while (it.next()) |f| : (i += 1) {
                    if (i >= fields.len) break;
                    fields[i] = std.fmt.parseInt(u64, f, 10) catch 0;
                }
                var total: u64 = 0;
                for (fields) |f| total += f;
                const busy = total - fields[3] - fields[4]; // idle + iowait
                if (self.cpu_total_prev != 0 and total > self.cpu_total_prev) {
                    self.snapshot.cpu_pct = @intCast(@min((busy - self.cpu_busy_prev) * 100 / (total - self.cpu_total_prev), 100));
                }
                self.cpu_busy_prev = busy;
                self.cpu_total_prev = total;
            }
        } else |_| {}
        if (sys.readFile("/proc/meminfo", &proc_buf)) |text| {
            self.snapshot.mem_free_kb = @intCast(@min(procValue(text, "MemFree:") orelse 0, 0xffffffff));
            self.snapshot.tmpfs_used_kb = @intCast(@min(procValue(text, "Shmem:") orelse 0xffffffff, 0xffffffff));
            // the total the used and available figures are a fraction of; without it nothing
            // downstream can draw a bar
            self.snapshot.mem_total_kb = @intCast(@min(procValue(text, "MemTotal:") orelse 0, 0xffffffff));
            const m = metrics.parseMeminfo(text);
            self.snapshot.mem_cached_kb = m.cached_kb;
            self.snapshot.mem_dirty_kb = m.dirty_kb;
            self.snapshot.mem_writeback_kb = m.writeback_kb;
            self.snapshot.mem_slab_kb = m.slab_kb;
        } else |_| {}
        // the flash partition, which is the only durable storage and appears nowhere in /proc,
        // and the size of the tmpfs the runtime lives in
        if (sys.fsUsage("/data")) |u| {
            self.snapshot.flash_total_kb = u.total_kb;
            self.snapshot.flash_used_kb = u.used_kb;
        } else |_| {}
        if (sys.fsUsage("/tmp")) |u| self.snapshot.tmpfs_total_kb = u.total_kb else |_| {}
        if (sys.readFile("/proc/loadavg", &proc_buf)) |text| {
            // "0.12 0.08 0.05 1/78 1234"
            if (std.mem.indexOfScalar(u8, text, ' ')) |sp| {
                const one = text[0..sp];
                if (std.mem.indexOfScalar(u8, one, '.')) |dot| {
                    const whole = std.fmt.parseInt(u16, one[0..dot], 10) catch 0;
                    const frac = std.fmt.parseInt(u16, one[dot + 1 ..][0..@min(2, one.len - dot - 1)], 10) catch 0;
                    self.snapshot.load_1m_x100 = @min(whole * 100 + frac, 0xfffe);
                }
            }
        } else |_| {}
        if (sys.readFile("/proc/net/dev", &proc_buf)) |text| {
            if (metrics.parseNetDev(text, "wlan0")) |n| {
                self.snapshot.net_rx_bytes = clamp32(n.rx_bytes);
                self.snapshot.net_tx_bytes = clamp32(n.tx_bytes);
                self.snapshot.net_rx_packets = clamp32(n.rx_packets);
                self.snapshot.net_tx_packets = clamp32(n.tx_packets);
                self.snapshot.net_rx_errors = clamp32(n.rx_errors);
                self.snapshot.net_rx_dropped = clamp32(n.rx_dropped);
                self.snapshot.net_tx_errors = clamp32(n.tx_errors);
                self.snapshot.net_tx_dropped = clamp32(n.tx_dropped);
                const interval = if (self.net_prev_ns != 0 and now > self.net_prev_ns) now - self.net_prev_ns else 0;
                self.snapshot.net_rx_bps = metrics.perSecond(n.rx_bytes, self.net_prev.rx_bytes, interval);
                self.snapshot.net_tx_bps = metrics.perSecond(n.tx_bytes, self.net_prev.tx_bytes, interval);
                self.net_prev = n;
                self.net_prev_ns = now;
            }
        } else |_| {}
        if (sys.readFile("/proc/net/wireless", &proc_buf)) |text| {
            // "wlan0: 0000   49.  -61.  -256        0 ..." : link quality, level dbm
            var lines = std.mem.splitScalar(u8, text, '\n');
            self.snapshot.wifi_level_dbm = -32768;
            self.snapshot.wifi_quality = 255;
            while (lines.next()) |line| {
                const t = std.mem.trim(u8, line, " ");
                if (!std.mem.startsWith(u8, t, "wlan0:")) continue;
                var it = std.mem.tokenizeAny(u8, t[6..], " .");
                _ = it.next(); // status
                const q = it.next() orelse break;
                const l = it.next() orelse break;
                self.snapshot.wifi_quality = @intCast(@min(std.fmt.parseInt(u16, q, 10) catch 255, 255));
                self.snapshot.wifi_level_dbm = std.fmt.parseInt(i16, l, 10) catch -32768;
            }
        } else |_| {}
        // per-process cpu over the sample interval, in tenths of a percent of one core
        const jiffies = [3]?u64{ cpuJiffiesOf(self.self_pid), cpuJiffiesOf(self.child_pid), cpuJiffiesOf(self.netd_pid) };
        if (self.proc_cpu_prev_ns != 0 and now > self.proc_cpu_prev_ns) {
            const interval_ns = now - self.proc_cpu_prev_ns;
            const fields = [3]*u16{ &self.snapshot.cpu_supervisor_pct_x10, &self.snapshot.cpu_renderer_pct_x10, &self.snapshot.cpu_netd_pct_x10 };
            for (jiffies, 0..) |j, i| {
                if (j) |v| {
                    if (v >= self.proc_cpu_prev[i]) {
                        // /proc/<pid>/stat counts USER_HZ (100) ticks: delta ticks / interval seconds = percent of one core
                        const pct_x10 = (v - self.proc_cpu_prev[i]) * 10 * ns_per_s / interval_ns;
                        fields[i].* = @intCast(@min(pct_x10, 0xfffe));
                    }
                } else fields[i].* = 0xffff;
            }
        }
        for (jiffies, 0..) |j, i| self.proc_cpu_prev[i] = j orelse 0;
        self.proc_cpu_prev_ns = now;
        self.snapshot.rss_supervisor_kb = rssOf(self.self_pid);
        self.snapshot.rss_renderer_kb = rssOf(self.child_pid);
        self.snapshot.rss_netd_kb = rssOf(self.netd_pid);
        self.snapshot.uptime_s = @intCast(now / ns_per_s);
        self.snapshot.sample_age_ms = 0;
        self.snapshot.restarts = self.restarts;
        self.sntp_link.publish(self, now); // sntp
        self.snapshot.ip_present = @intFromBool(self.last_ip != null);
        self.snapshot.ip = self.last_ip orelse .{ 0, 0, 0, 0 };
        self.snapshot.config_revision = self.cfg.revision;
        self.snapshot.saved_revision = self.cfg.saved_revision;
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn onHeartbeat(self: *Supervisor, h: messages.Heartbeat, now: u64) void {
        const changed = h.menu != self.snapshot.menu or h.menu_item != self.snapshot.menu_item or h.menu_state != self.snapshot.menu_state or h.revision != self.snapshot.revision or h.base != self.snapshot.base or h.brightness != self.snapshot.brightness or h.overlay != self.snapshot.overlay or h.generator != self.snapshot.generator or h.power != self.snapshot.power;
        self.snapshot.revision = h.revision;
        self.snapshot.power = h.power;
        self.snapshot.clock = h.clock;
        self.snapshot.ip_mode = h.ip_mode;
        self.snapshot.menu = h.menu;
        self.snapshot.menu_item = h.menu_item;
        self.snapshot.menu_state = h.menu_state;
        self.snapshot.presented = h.presented;
        self.snapshot.base = h.base;
        self.snapshot.generator = h.generator;
        self.snapshot.overlay = h.overlay;
        self.snapshot.brightness = h.brightness;
        // a reseed goes through arb.apply, which bumps the revision, so `changed` already covers it
        self.snapshot.seed = h.seed;
        self.snapshot.epoch = lifecycle.epoch;
        self.snapshot.renderer_state = 2;
        if (self.hb_presented_at_ns != 0 and now > self.hb_presented_at_ns and now - self.hb_presented_at_ns >= 2 * ns_per_s) {
            const delta = h.presented - self.hb_presented;
            self.snapshot.fps_x10 = @intCast(@min(delta * 10 * ns_per_s / (now - self.hb_presented_at_ns), 0xffff));
            self.hb_presented = h.presented;
            self.hb_presented_at_ns = now;
        } else if (self.hb_presented_at_ns == 0) {
            self.hb_presented = h.presented;
            self.hb_presented_at_ns = now;
        }
        if (changed) self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn panelLockFree(self: *Supervisor) bool {
        const fd = sys.open(self.cfg_cli.lock_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| {
            log.warn("cannot open panel lock: {s}", .{sys.errText(e)});
            return false;
        };
        defer sys.close(fd);
        const free = sys.flockTry(fd) catch return false;
        if (free) sys.funlock(fd);
        return free;
    }

    fn spawn(self: *Supervisor, now: u64) void {
        if (!self.panelLockFree()) {
            log.warn("panel lock still held; not starting a renderer", .{});
            return;
        }
        const path = if (lifecycle.slot == .candidate) self.cfg_cli.renderer else self.cfg_cli.fallbackPath();
        const epoch = lifecycle.epoch + 1;
        var epoch_buf: [16]u8 = undefined;
        const epoch_text = std.fmt.bufPrintZ(&epoch_buf, "{d}", .{epoch}) catch unreachable;
        var argv: cli.Argv = undefined;
        _ = cli.spawnArgv(self.cfg_cli, path, epoch_text, &argv);

        const fds = sys.socketpairSeqpacket() catch |e| {
            log.err("socketpair failed: {s}", .{sys.errText(e)});
            return;
        };
        const pid = sys.fork() catch |e| {
            log.err("fork failed: {s}", .{sys.errText(e)});
            sys.close(fds[0]);
            sys.close(fds[1]);
            return;
        };
        if (pid == 0) {
            // child: fixed descriptor layout, parent-death termination, clean signal state, no env
            sys.unblockAllSignals();
            sys.setSignalDisposition(.TERM, linux.SIG.DFL);
            sys.setSignalDisposition(.INT, linux.SIG.DFL);
            sys.setSignalDisposition(.PIPE, linux.SIG.DFL);
            if (self.log_pipe) |lp| {
                sys.dup2(lp[1], 1) catch sys.exit(126);
                sys.dup2(lp[1], 2) catch sys.exit(126);
            }
            sys.dup2(fds[1], 3) catch sys.exit(126);
            if (fds[0] != 3) sys.close(fds[0]);
            if (fds[1] != 3) sys.close(fds[1]);
            sys.prctlPdeathsig(.TERM) catch sys.exit(126);
            if (sys.getppid() != self.self_pid) sys.exit(125); // the parent died before pdeathsig was armed
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(path.ptr, &argv, &envp) catch {};
            const msg = "tc002-supervisor: exec of renderer failed\n";
            sys.writeAll(2, msg) catch {};
            sys.exit(127);
        }
        sys.close(fds[1]);
        self.child_fd = fds[0];
        self.child_pid = pid;
        self.child_spawned_ns = now;
        sys.epollAdd(self.ep, fds[0], linux.EPOLL.IN, @intFromEnum(Tag.ipc)) catch |e| log.err("epoll add failed: {s}", .{sys.errText(e)});
        lifecycle.onSpawned(now);
        log.info("spawned renderer pid {d} epoch {d} slot {s} path {s}", .{ pid, lifecycle.epoch, @tagName(lifecycle.slot), path });
    }

    fn reap(self: *Supervisor, now: u64) void {
        const pid = self.child_pid orelse return;
        const status = sys.waitNoHang(pid) catch |e| switch (e) {
            error.NoChild => @as(?u32, 0),
            else => return,
        } orelse return;
        if ((status & 0x7f) == 0) {
            log.info("renderer pid {d} exited with code {d} after {d} ms", .{ pid, (status >> 8) & 0xff, (now - self.child_spawned_ns) / 1_000_000 });
        } else {
            log.warn("renderer pid {d} killed by signal {d} after {d} ms", .{ pid, status & 0x7f, (now - self.child_spawned_ns) / 1_000_000 });
        }
        if (self.child_fd) |fd| sys.close(fd);
        self.child_fd = null;
        self.child_pid = null;
        lifecycle.onExit(now);
        if (lifecycle.state == .waiting_restart) self.restarts += 1;
        self.snapshot.renderer_state = 0;
        for (&self.relays) |*r| if (r.used) {
            r.used = false;
            self.relayResult(r.id, .unavailable, self.snapshot.revision);
        };
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn drainSignals(self: *Supervisor, now: u64) void {
        while (sys.readSignal(self.sigfd) catch null) |info| {
            switch (info.signo) {
                @intFromEnum(linux.SIG.CHLD) => {
                    self.reap(now);
                    self.reapNetd(now);
                    self.reapNtfy(now);
                    self.reapBerry(now);
                },
                else => {
                    if (!self.shutting_down) log.info("signal {d}: shutting down", .{info.signo});
                    self.shutting_down = true;
                    lifecycle.requestStop(now);
                    if (lifecycle.state == .stopping) self.send(.stop);
                },
            }
        }
    }

    fn drainIpc(self: *Supervisor, now: u64) void {
        const fd = self.child_fd orelse return;
        var count: u32 = 0;
        while (count < ipc_packets_per_iteration) : (count += 1) {
            const packet = sys.recvPacket(fd, &packet_buf) catch |e| {
                if (e != error.Closed) log.warn("ipc receive failed: {s}", .{sys.errText(e)});
                return;
            } orelse return;
            const p = messages.decodePacket(packet) catch |e| {
                log.warn("bad ipc packet from renderer: {s}", .{@errorName(e)});
                continue;
            };
            switch (p.message) {
                .heartbeat => |h| {
                    self.heartbeats += 1;
                    lifecycle.onHeartbeat(now);
                    self.onHeartbeat(h, now);
                },
                .ready => {
                    lifecycle.onReady(now);
                    log.info("renderer ready {d} ms after spawn", .{(now - self.child_spawned_ns) / 1_000_000});
                    if (self.last_ip) |a| self.send(.{ .ip_changed = .{ .present = 1, .addr = a } });
                    // saved defaults become the renderer's state; the renderer's revision counts from here
                    self.send(.{ .brightness = .{ .value = self.cfg.brightness } });
                    self.send(.{ .set_base = .{ .base = self.cfg.base, .generator = self.cfg.generator, .seed = 0 } });
                    self.send(.{ .set_timezone = config.Text.init(self.cfg.tzRule()) });
                    self.send(.{ .clock_style = messages.ClockStyle.full(self.cfg.clockStyle()) });
                    self.send(.{ .ip_mode = .{ .mode = self.cfg.ip_mode } });
                    self.sendGeneratorParams();
                    // a restart redraws what was pushed, pictures first so the document finds them
                    for (self.sprites.items[0..self.sprites.count]) |sp| self.send(.{ .sprite = sp });
                    if (!self.canvas_doc.empty()) {
                        // the renderer installs it fresh, restarting whatever has no id to be
                        // recognised by. running the same comparison here keeps the two in step.
                        self.canvas_clocks.install(&self.canvas_doc, &self.canvas_doc, sys.monotonicNs());
                        self.sendCanvas();
                    }
                    // the renderer started dark: reveal the saved state with the power ramp
                    self.send(.{ .power = .{ .on = 1 } });
                    self.snapshot.epoch = lifecycle.epoch;
                    self.snapshot.renderer_state = 2;
                    for (&self.relays) |*r| r.used = false;
                    self.hb_presented_at_ns = 0;
                },
                .result => |r| {
                    for (&self.relays) |*rel| if (rel.used and rel.id == p.request_id) {
                        rel.used = false;
                        if (!rel.from_ntfy) self.relayResult(p.request_id, r.status, r.revision);
                        break;
                    };
                },
                .screen => |sc| {
                    for (&self.relays) |*rel| if (rel.used and rel.id == p.request_id) {
                        rel.used = false;
                        self.sendNetd(.{ .screen = sc }, p.request_id);
                        break;
                    };
                },
                .input => |i| self.sendNetd(.{ .input = i }, 0),
                .menu_request => |m| self.onMenuRequest(m, now),
                .set_param => |sp| self.onSetParam(sp),
                else => log.warn("unexpected {s} from renderer", .{@tagName(p.message)}),
            }
        }
    }

    fn onChildLine(self: *Supervisor, line: []const u8) void {
        _ = self;
        ring.push(line);
        // the file stays complete: the children used to write to it directly
        var b: [logring.Assembler.carry_max + 1]u8 = undefined;
        @memcpy(b[0..line.len], line);
        b[line.len] = '\n';
        sys.writeAll(2, b[0 .. line.len + 1]) catch {};
    }

    fn drainLogs(self: *Supervisor) void {
        const lp = self.log_pipe orelse return;
        var rounds: u32 = 0;
        while (rounds < 16) : (rounds += 1) {
            const n = sys.read(lp[0], &log_buf) catch return;
            if (n == 0) return;
            assembler.feed(log_buf[0..n], self, Supervisor.onChildLine);
            if (n < log_buf.len) return;
        }
    }

    fn drainKeys(self: *Supervisor, now: u64) void {
        const fd = self.keys orelse return;
        while (true) {
            const n = sys.read(fd, &evbuf) catch return;
            if (n == 0) return;
            var off: usize = 0;
            while (off + evdev.event_size <= n) : (off += evdev.event_size) {
                const ev = evdev.decode(evbuf[off..][0..evdev.event_size]);
                if (ev.type == evdev.EV_KEY and ev.code == self.cfg_cli.keymap.knob and ev.value != 2) gesture.onKey(ev.value != 0, now);
            }
            if (n < evbuf.len) return;
        }
    }

    fn setDebugProperty(self: *Supervisor, value: [:0]const u8) void {
        _ = self;
        props.set("persist.sys.zkdebug", value, property_timeout_ns) catch |e| {
            log.err("setprop persist.sys.zkdebug={s} failed: {s}", .{ value, @errorName(e) });
            return;
        };
        log.info("persist.sys.zkdebug={s}", .{value});
    }

    fn pollGesture(self: *Supervisor, now: u64) void {
        switch (gesture.poll(now)) {
            .none => {},
            .grant => switch (self.cfg_cli.profile) {
                .dev => log.info("maintenance gesture recognised (dev profile: adbd left as it is)", .{}),
                .hardened => {
                    log.info("maintenance gesture recognised: adbd enabled for fifteen minutes", .{});
                    self.setDebugProperty("1");
                },
            },
            .revoke => switch (self.cfg_cli.profile) {
                .dev => log.info("maintenance window expired (dev profile: nothing to revoke)", .{}),
                .hardened => {
                    log.info("maintenance window expired: adbd disabled", .{});
                    self.setDebugProperty("0");
                },
            },
        }
    }

    fn pollLifecycle(self: *Supervisor, now: u64) void {
        switch (lifecycle.poll(now)) {
            .none => {},
            .spawn => if (!self.shutting_down) self.spawn(now),
            .request_stop => {
                log.warn("renderer unresponsive (state {s}); requesting stop", .{@tagName(lifecycle.state)});
                if (self.child_fd != null) self.send(.stop);
                if (self.child_pid) |pid| sys.kill(pid, .TERM);
            },
            .kill => if (self.child_pid) |pid| {
                log.warn("renderer pid {d} did not stop in time; killing", .{pid});
                sys.kill(pid, .KILL);
            },
            .confirm_slot => log.info("renderer healthy for sixty seconds: {s} slot confirmed", .{@tagName(lifecycle.slot)}),
        }
    }

    /// the readouts the menu's info page shows. the renderer cannot see any of this itself.
    fn pushDeviceStatus(self: *Supervisor, now: u64) void {
        if (now < self.next_device_push) return;
        self.next_device_push = now + 5 * ns_per_s;
        if (self.snapshot.renderer_state != 2) return;
        const st = self.snapshot;
        self.send(.{ .device_status = .{
            .battery_pct = st.battery_pct,
            .usb = st.usb_present,
            .wifi_quality = st.wifi_quality,
            .wifi_dbm = st.wifi_level_dbm,
            .time_synced = @intFromBool(st.time_state == 1), // 1 is synced; 2 is stale
            .mqtt_on = @intFromBool(self.cfg.mqtt.enabled),
            .ntfy_on = @intFromBool(self.cfg.ntfy.enabled),
            .uptime_s = st.uptime_s,
            .night_on = @intFromBool(self.cfg.night),
            .night_level = self.cfg.night_brightness,
            .night_placed = @intFromBool(self.night.point != null),
        } });
    }

    /// the night brightness schedule. it drives the panel transiently, exactly as an api client
    /// would: the settings keep the daylight brightness, and nothing is written to flash by a ramp
    /// that runs every evening.
    fn pollNight(self: *Supervisor, now: u64) void {
        if (now < self.next_night_poll) return;
        self.next_night_poll = now + night_poll_ns;
        if (self.snapshot.renderer_state != 2) return;
        const unix = unixNow();
        const want = self.night.target(unix); // null while a hand-set brightness still stands
        const plan = self.night.plan(unix);
        const phase: u8 = if (plan) |p| @as(u8, @intFromEnum(p.phase)) + 1 else 0;
        if (phase != self.snapshot.night_phase) {
            if (plan) |p| log.info("night: {s}, brightness {d}{s}", .{ p.phase.text(), p.brightness, if (want == null) " (held)" else "" });
        }
        self.snapshot.night_phase = phase;
        self.snapshot.night_override = @intFromBool(self.night.override_until != null);
        const value = want orelse return;
        if (value == self.snapshot.brightness) return;
        self.send(.{ .brightness = .{ .value = value } });
    }

    /// the renderer draws whatever document the supervisor is holding
    fn sendCanvas(self: *Supervisor) void {
        self.send(.{ .canvas = self.canvasView() });
    }

    /// the document as a client reads it back: with the ages of its animation clocks
    fn canvasView(self: *const Supervisor) messages.CanvasView {
        const now = sys.monotonicNs();
        var v = messages.CanvasView{ .doc = self.canvas_doc, .doc_age_ms = self.canvas_clocks.docAgeMs(now) };
        for (0..self.canvas_doc.count) |i| v.element_age_ms[i] = self.canvas_clocks.elementAgeMs(i, now);
        return v;
    }

    /// take a new document and start the clocks the elements that changed need
    fn installCanvas(self: *Supervisor, next: canvas.Document) void {
        self.canvas_clocks.install(&self.canvas_doc, &next, sys.monotonicNs());
        self.canvas_doc = next;
    }

    /// the document and its pictures go to the state directory on a layout change, and **never on
    /// a value patch**: home assistant pushing a reading every minute would otherwise be 1,440
    /// jffs2 writes a day. so a reboot restores the layout with the values its last full push
    /// carried, which is what any dashboard shows until its next update.
    fn saveCanvas(self: *Supervisor) void {
        var dir_buf: [160]u8 = undefined;
        var tmp_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        const dir = self.statePathIn(&dir_buf, "config");
        const tmp = self.statePathIn(&tmp_buf, "config/canvas.bin.tmp");
        const path = self.statePathIn(&path_buf, "config/canvas.bin");
        const n = canvas.saveBytes(&self.canvas_doc, &self.sprites, &canvas_file_buf) catch {
            log.err("canvas save failed: it does not fit its buffer", .{});
            return;
        };
        sys.saveFileAtomic(dir, tmp, path, canvas_file_buf[0..n]) catch |e| {
            log.err("canvas save failed: {s}", .{sys.errText(e)});
            return;
        };
        self.canvas_saved = self.canvas_doc.revision;
        self.canvas_doc.saved_revision = self.canvas_saved;
        log.info("canvas saved, revision {d}, {d} bytes", .{ self.canvas_doc.revision, n });
    }

    fn loadCanvas(self: *Supervisor) void {
        var path_buf: [160]u8 = undefined;
        const path = self.statePathIn(&path_buf, "config/canvas.bin");
        const bytes = sys.readFile(path, &canvas_file_buf) catch return;
        canvas.loadBytes(bytes, &self.canvas_doc, &self.sprites) catch {
            log.warn("saved canvas is invalid; starting empty and keeping the file", .{});
            self.canvas_doc = .{};
            self.sprites = .{};
            return;
        };
        self.canvas_saved = self.canvas_doc.revision;
        self.canvas_doc.saved_revision = self.canvas_saved;
        log.info("canvas loaded, revision {d}, {d} elements, {d} sprites", .{ self.canvas_doc.revision, self.canvas_doc.count, self.sprites.count });
    }

    fn spriteList(self: *const Supervisor) messages.SpriteList {
        var l = messages.SpriteList{ .count = self.sprites.count };
        for (self.sprites.items[0..self.sprites.count], 0..) |*sp, i| l.items[i] = .{ .id = sp.id, .w = sp.w, .h = sp.h };
        return l;
    }

    /// the schedule works from copies of the settings, refreshed whenever they change
    fn syncNight(self: *Supervisor) void {
        self.night.settings = self.cfg.nightSettings();
        self.night.point = self.cfg.point();
        if (self.cfg.night and self.night.point == null) {
            log.warn("night: enabled but nowhere: set latitude and longitude, or an iana timezone in place of \"{s}\"", .{self.cfg.timezone.slice()});
        }
    }

    fn pollIp(self: *Supervisor, now: u64) void {
        if (now < self.next_ip_poll) return;
        self.next_ip_poll = now + @as(u64, self.cfg_cli.ip_poll_s) * ns_per_s;
        const addr = sys.ifAddr("wlan0") catch |e| {
            log.warn("wlan0 address query failed: {s}", .{sys.errText(e)});
            return;
        };
        if (std.meta.eql(addr, self.last_ip)) return;
        self.last_ip = addr;
        self.sntp_link.client.setNetwork(addr != null, now); // sntp
        if (addr) |a| log.info("wlan0 address {d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) else log.info("wlan0 has no address", .{});
        self.send(.{ .ip_changed = .{ .present = if (addr != null) 1 else 0, .addr = addr orelse .{ 0, 0, 0, 0 } } });
    }
};

/// log what the loader handed us: descriptors, signal masks, working directory, environment names.
fn audit(environ: anytype, args: []const [:0]const u8, close_inherited: bool) void {
    var path_buf: [64]u8 = undefined;
    var target: [256]u8 = undefined;
    var fd: i32 = 0;
    var inherited: u32 = 0;
    while (fd < 256) : (fd += 1) {
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
        const t = sys.readlink(path, &target) catch continue;
        log.info("inherited fd {d} -> {s}", .{ fd, t });
        if (fd > 2) {
            inherited += 1;
            if (close_inherited) sys.close(fd);
        }
    }
    log.info("{d} inherited descriptors above stderr{s}", .{ inherited, if (close_inherited) " (closed)" else "" });
    if (sys.readlink("/proc/self/cwd", &target)) |cwd| log.info("cwd {s}", .{cwd}) else |_| {}
    if (sys.open("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) |sfd| {
        defer sys.close(sfd);
        var status: [2048]u8 = undefined;
        const n = sys.read(sfd, &status) catch 0;
        var lines = std.mem.splitScalar(u8, status[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "SigBlk") or std.mem.startsWith(u8, line, "SigIgn") or std.mem.startsWith(u8, line, "SigCgt") or std.mem.startsWith(u8, line, "PPid")) log.info("{s}", .{line});
        }
    } else |_| {}
    for (args, 0..) |a, i| log.info("arg {d}: {s}", .{ i, a });
    var env_count: u32 = 0;
    for (environ) |maybe| {
        const entry = maybe orelse break;
        const s = std.mem.span(entry);
        const name = if (std.mem.indexOfScalar(u8, s, '=')) |eq| s[0..eq] else s;
        log.info("inherited env {s}", .{name});
        env_count += 1;
    }
    log.info("{d} inherited environment variables (values not logged)", .{env_count});
}

/// when the loader exec'd us, stderr is whatever the loader had; keep the log in the runtime dir.
fn redirectLog(cfg: cli.Config) void {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/supervisor.log", .{cfg.dir}) catch return;
    sys.mkdir(cfg.dir, 0o700) catch {};
    const fd = sys.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) catch return;
    sys.dup2(fd, 1) catch {};
    sys.dup2(fd, 2) catch {};
    sys.close(fd);
}

fn run(cfg_in: cli.Config, environ: anytype, args: []const [:0]const u8) !u8 {
    const t0 = sys.monotonicNs();
    log.sink = ringSink;
    // --tz may be an iana zone name; the renderer only speaks posix rules
    var cfg = cfg_in;
    var tz_buf: [config.text_max + 1]u8 = undefined;
    if (tz.resolve(cfg.tz_rule)) |rule| {
        if (!std.mem.eql(u8, rule, cfg.tz_rule)) cfg.tz_rule = std.fmt.bufPrintZ(&tz_buf, "{s}", .{rule}) catch cfg.tz_rule;
    } else log.warn("--tz {s} is neither a posix rule nor a zone name; the renderer will refuse it", .{cfg.tz_rule});
    // 1. the anti-brick flag, before anything that could block or fail
    var property_ms: ?u64 = null;
    if (!cfg.no_property) {
        props.set("sys.zkapp.state", "running", property_timeout_ns) catch |e| {
            log.err("sys.zkapp.state=running failed: {s}; exiting without pretending", .{@errorName(e)});
            return 2;
        };
        property_ms = (sys.monotonicNs() - t0) / 1_000_000;
    }
    // where stderr pointed before any redirect, for the audit
    var stderr_target: [128]u8 = undefined;
    const original_stderr = sys.readlink("/proc/self/fd/2", &stderr_target) catch "(unknown)";
    if (cfg.from_bootstrap) redirectLog(cfg);
    if (property_ms) |ms| {
        log.info("sys.zkapp.state=running accepted {d} ms after entry (uptime {d} ms){s}", .{ ms, t0 / 1_000_000, if (cfg.from_bootstrap) ", exec'd by the bootstrap" else "" });
    } else {
        log.warn("sys.zkapp.state not set (--no-property)", .{});
    }
    log.info("original stderr -> {s}", .{original_stderr});
    // 2. audit and normalise inherited state
    audit(environ, args, cfg.close_inherited);
    sys.unblockAllSignals();
    sys.setSignalDisposition(.PIPE, linux.SIG.IGN);
    sys.setSignalDisposition(.TERM, linux.SIG.DFL);
    sys.setSignalDisposition(.INT, linux.SIG.DFL);
    sys.setSignalDisposition(.CHLD, linux.SIG.DFL);
    sys.setSignalDisposition(.HUP, linux.SIG.IGN);
    sys.chdir("/") catch {};
    // 3. hardened profile: no adb until the physical gesture
    if (cfg.profile == .hardened) {
        props.set("persist.sys.zkdebug", "0", property_timeout_ns) catch |e| log.err("persist.sys.zkdebug=0 failed: {s}", .{@errorName(e)});
    }
    // 4. runtime directory and the panel lock file, created once and never unlinked
    sys.mkdir(cfg.dir, 0o700) catch |e| {
        log.err("cannot create {s}: {s}", .{ cfg.dir, sys.errText(e) });
        return 1;
    };
    const lock = sys.open(cfg.lock_path, .{ .ACCMODE = .RDONLY, .CREAT = true, .CLOEXEC = true }, 0o600) catch |e| {
        log.err("cannot create panel lock: {s}", .{sys.errText(e)});
        return 1;
    };
    sys.close(lock);
    // 5. the maintenance gesture reader, independent of the renderer
    const keys = sys.open(cfg.keys_path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| blk: {
        log.warn("no button device for the maintenance gesture: {s}", .{sys.errText(e)});
        break :blk null;
    };
    const now0 = sys.monotonicNs();
    if (keys) |fd| {
        if (sys.evdevKeyDown(fd, cfg.keymap.knob) catch false) {
            log.info("knob already held at startup", .{});
            gesture.onKey(true, now0);
        }
    }
    // 6. event sources
    const ep = try sys.epollCreate();
    const timer = try sys.timerfdCreate();
    const sigfd = try sys.signalfdFor(&.{ .CHLD, .TERM, .INT });
    try sys.epollAdd(ep, timer, linux.EPOLL.IN, @intFromEnum(Tag.timer));
    try sys.epollAdd(ep, sigfd, linux.EPOLL.IN, @intFromEnum(Tag.signals));
    if (keys) |fd| try sys.epollAdd(ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.keys));

    var s = Supervisor{ .cfg_cli = cfg, .cfg_dir_text = cfg.dir, .state_dir_text = cfg.state, .cfg_stats = cfg.stats, .ep = ep, .timer = timer, .sigfd = sigfd, .keys = keys, .self_pid = sys.getpid() };
    // settings and credentials belong on the persistent partition; if it cannot be used the
    // runtime still comes up, on the volatile directory, and says so rather than failing to start
    if (s.makeStateDir()) |_| {
        s.migrateState();
        log.info("durable settings and credentials in {s}", .{s.state_dir_text});
    } else |e| {
        log.warn("{s} is unusable ({s}); settings and credentials stay in {s} and will not survive a reboot", .{ s.state_dir_text, sys.errText(e), s.cfg_dir_text });
        s.state_dir_text = s.cfg_dir_text;
    }
    // the children's log lines come through a pipe so the ring sees them; the file still gets them
    if (sys.pipeNonblock()) |lp| {
        s.log_pipe = lp;
        try sys.epollAdd(ep, lp[0], linux.EPOLL.IN, @intFromEnum(Tag.logs));
    } else |e| log.warn("no log pipe ({s}); the log ring holds only the supervisor's lines", .{sys.errText(e)});
    log.info("supervising {s} (fallback {s}) profile {s} pid {d}", .{ cfg.renderer, cfg.fallbackPath(), @tagName(cfg.profile), s.self_pid });
    var netd_path_buf: [160]u8 = undefined;
    s.netd_path = std.fmt.bufPrintZ(&netd_path_buf, "{s}/tc002-netd", .{cfg.dir}) catch unreachable;
    var ntfy_path_buf: [160]u8 = undefined;
    s.ntfy_path = std.fmt.bufPrintZ(&ntfy_path_buf, "{s}/tc002-ntfy", .{cfg.dir}) catch unreachable;
    s.loadNtfyCa();
    var boot: [4]u8 = undefined;
    sys.getrandom(&boot) catch {};
    s.boot_id = std.mem.readInt(u32, &boot, .little);
    s.snapshot.boot_id = s.boot_id;
    s.readMac();
    if (s.snapshot.mac_present != 0) {
        const m = s.snapshot.mac;
        log.info("device identity from wlan0: tc002-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ m[0], m[1], m[2], m[3], m[4], m[5] });
    } else log.warn("no wlan0 mac; discovery identity falls back to the boot id", .{});
    // 7. the network daemon's privileged resources: credentials, configuration, the listener
    s.loadCredentials() catch |e| log.err("credentials unavailable: {s}; netd will refuse every request", .{sys.errText(e)});
    s.loadConfig();
    s.loadCanvas();
    s.snapshot.config_revision = s.cfg.revision;
    s.snapshot.saved_revision = s.cfg.saved_revision;
    s.listener = sys.tcpListener(http_port, 8) catch |e| blk: {
        log.err("cannot bind port {d}: {s}; the http api will be unavailable", .{ http_port, sys.errText(e) });
        break :blk null;
    };
    if (s.listener != null) log.info("listening on port {d} (plaintext, isolated-lan profile)", .{http_port});
    // 8. the pixel mcu link: queries only, on the vendor's baud
    if (!cfg.no_mcu) {
        s.mcu_link.poll_ns = @as(u64, cfg.mcu_poll_s) * ns_per_s;
        if (sys.uartOpen(cfg.mcu_path, cfg.mcu_baud)) |fd| {
            s.mcu_link.fd = fd;
            try sys.epollAdd(ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.mcu));
            log.info("mcu link {s} at {d} baud, polling every {d} s", .{ cfg.mcu_path, cfg.mcu_baud, cfg.mcu_poll_s });
        } else |e| log.warn("mcu link unavailable ({s}: {s}); battery telemetry stays unknown", .{ cfg.mcu_path, sys.errText(e) });
    }
    // 9. the sntp client, on the configured server (none by default), and the night schedule
    s.sntp_link.configure(&s, sys.monotonicNs());
    s.syncNight();

    var events: [8]sys.Event = undefined;
    while (true) {
        const now = sys.monotonicNs();
        s.drainSignals(now);
        s.drainLogs();
        s.drainIpc(now);
        s.drainKeys(now);
        s.pollGesture(now);
        s.pollLifecycle(now);
        s.pollIp(now);
        s.pushDeviceStatus(now);
        s.pollNight(now);
        s.drainNetd(now);
        s.pollNetd(now);
        s.drainNtfy(now);
        s.pollNtfy(now);
        s.drainBerry(now);
        s.pollBerry(now);
        s.mcu_link.poll(&s, now);
        s.sntp_link.poll(now); // sntp
        s.expireRelays(now);
        if (now >= s.next_sample_ns) {
            s.sample(now);
            s.next_sample_ns = now + sample_period_ns;
        }
        if (s.shutting_down and s.netd_pid != null) {
            if (s.netd_pid) |pid| sys.kill(pid, .TERM);
        }
        if (s.shutting_down and s.ntfy_pid != null) {
            if (s.ntfy_pid) |pid| sys.kill(pid, .TERM);
        }
        if (s.shutting_down and s.berry_pid != null) {
            if (s.berry_pid) |pid| sys.kill(pid, .TERM);
        }
        if (s.shutting_down and s.child_pid == null and s.netd_pid == null and s.ntfy_pid == null and s.berry_pid == null) break;
        try sys.timerfdArmAt(timer, now + tick_ns);
        const n = try sys.epollWait(ep, &events, -1);
        for (events[0..n]) |ev| {
            if (ev.data.u64 == @intFromEnum(Tag.timer)) sys.timerfdDrain(timer);
            if (ev.data.u64 == @intFromEnum(Tag.mcu)) s.mcu_link.readable(&s, sys.monotonicNs());
            if (ev.data.u64 == @intFromEnum(Tag.sntp)) s.sntp_link.readable(&s, sys.monotonicNs()); // sntp
        }
    }
    log.info("exit: {d} heartbeats, {d} renderer restarts, {d} netd restarts, mcu replies {d} timeouts {d} unsolicited {d}, sntp ok {d} failed {d}, final state {s}", .{ s.heartbeats, s.restarts, s.netd_exits.restarts, s.mcu_link.replies, s.mcu_link.timeouts, s.mcu_link.unsolicited, s.sntp_link.client.successes, s.sntp_link.client.failures, @tagName(lifecycle.state) });
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    log.program = "tc002-supervisor";
    var args: [32][:0]const u8 = undefined;
    const raw = init.args.vector;
    const n = @min(raw.len, args.len);
    for (0..n) |i| args[i] = std.mem.span(raw[i]);
    const outcome = cli.parse(args[@min(n, 1)..n]) catch |e| {
        log.err("bad arguments: {s}", .{switch (e) {
            error.MissingValue => "an option is missing its value",
            error.BadValue => "an option has an invalid value",
            error.UnknownOption => "unknown option",
        }});
        sys.writeAll(2, cli.usage) catch {};
        return 2;
    };
    const cfg = switch (outcome) {
        .run => |c| c,
        .help => {
            sys.writeAll(1, cli.usage) catch {};
            return 0;
        },
    };
    return run(cfg, init.environ.block.slice, args[0..n]) catch |e| {
        log.err("fatal: {s}", .{sys.errText(e)});
        return 1;
    };
}
