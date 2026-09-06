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
const api = @import("net/api.zig");

const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const ns_per_s = std.time.ns_per_s;

const Tag = enum(u64) { timer = 1, signals = 2, ipc = 3, keys = 4, netd = 5 };

const tick_ns: u64 = 100_000_000;
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
var config_buf: [config.file_max]u8 = undefined;
var config_arena: [4096]u8 = undefined;
var proc_buf: [4096]u8 = undefined;

const Relay = struct { used: bool = false, id: u64 = 0, deadline_ns: u64 = 0 };

const Supervisor = struct {
    cfg_cli: cli.Config,
    cfg_dir_text: []const u8,
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
    shutting_down: bool = false,
    // network daemon
    cfg: config.Config = .{},
    creds: api.Credentials = undefined,
    listener: ?sys.Fd = null,
    netd_pid: ?sys.Pid = null,
    netd_fd: ?sys.Fd = null,
    netd_path: [:0]const u8 = "/tmp/tc002/tc002-netd",
    netd_restart_at: u64 = 0,
    netd_restarts: u32 = 0,
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

    fn loadCredentials(self: *Supervisor) !void {
        var dir_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        const dir = self.pathIn(&dir_buf, "credentials");
        sys.mkdir(dir, 0o700) catch {};
        const path = self.pathIn(&path_buf, "credentials/tokens");
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
        const tmp = self.pathIn(&tmp_buf, "credentials/tokens.tmp");
        try sys.saveFileAtomic(dir, tmp, path, &raw);
        self.creds = .{ .control = raw[0..32].*, .admin = raw[32..64].* };
        log.info("credentials generated (mode 0600 in the credentials directory; never logged)", .{});
    }

    fn loadConfig(self: *Supervisor) void {
        var dir_buf: [160]u8 = undefined;
        var path_buf: [160]u8 = undefined;
        sys.mkdir(self.pathIn(&dir_buf, "config"), 0o700) catch {};
        const path = self.pathIn(&path_buf, "config/config.json");
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
        const dir = self.pathIn(&dir_buf, "config");
        const tmp = self.pathIn(&tmp_buf, "config/config.json.tmp");
        const path = self.pathIn(&path_buf, "config/config.json");
        const text = config.toJson(&self.cfg, &config_buf) catch return .rejected;
        sys.saveFileAtomic(dir, tmp, path, text) catch |e| {
            log.err("configuration save failed: {s}", .{sys.errText(e)});
            return .unavailable;
        };
        self.cfg.saved_revision = self.cfg.revision;
        log.info("configuration saved, revision {d}", .{self.cfg.revision});
        return .applied;
    }

    /// live effects of a settings change: the renderer gets transient commands, netd the full config.
    fn applyConfigLive(self: *Supervisor, before: config.Config) void {
        const c = &self.cfg;
        if (before.brightness != c.brightness) self.send(.{ .brightness = .{ .value = c.brightness } });
        if (before.base != c.base or before.generator != c.generator) self.send(.{ .set_base = .{ .base = c.base, .generator = c.generator, .seed = 0 } });
        if (!std.mem.eql(u8, before.timezone.slice(), c.timezone.slice())) self.send(.{ .set_timezone = c.timezone });
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
        if ((status & 0x7f) == 0) log.warn("netd pid {d} exited with code {d}", .{ pid, (status >> 8) & 0xff }) else log.warn("netd pid {d} killed by signal {d}", .{ pid, status & 0x7f });
        if (self.netd_fd) |fd| sys.close(fd);
        self.netd_fd = null;
        self.netd_pid = null;
        self.netd_restarts += 1;
        self.netd_restart_at = now + netd_restart_ns;
        for (&self.relays) |*r| r.used = false;
    }

    fn pollNetd(self: *Supervisor, now: u64) void {
        if (self.shutting_down or self.listener == null) return;
        if (self.netd_pid == null and now >= self.netd_restart_at) self.spawnNetd(now);
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
                .set_base, .notify, .frame, .brightness, .reseed, .arm_stream => {
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
                .config_patch => |w| {
                    const before = self.cfg;
                    self.cfg.patch(w.toApi()) catch |e| {
                        self.sendNetd(.{ .save_result = .{ .status = if (e == error.RevisionConflict) .conflict else .rejected, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    };
                    self.applyConfigLive(before);
                    self.sendNetd(.{ .config = self.cfg }, p.request_id);
                },
                .mqtt_put => |w| {
                    self.cfg.patchMqtt(w.toApi()) catch {
                        self.sendNetd(.{ .save_result = .{ .status = .rejected, .saved_revision = self.cfg.saved_revision } }, p.request_id);
                        continue;
                    };
                    self.snapshot.config_revision = self.cfg.revision;
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
        } else |_| {}
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
                        // 100 jiffies per second on this kernel (CONFIG_HZ=100)
                        const pct_x10 = (v - self.proc_cpu_prev[i]) * 10 * ns_per_s / (interval_ns / 100 * 100) / 100 * 100 / 100;
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
        self.snapshot.ip_present = @intFromBool(self.last_ip != null);
        self.snapshot.ip = self.last_ip orelse .{ 0, 0, 0, 0 };
        self.snapshot.config_revision = self.cfg.revision;
        self.snapshot.saved_revision = self.cfg.saved_revision;
        self.sendNetd(.{ .status = self.snapshot }, 0);
    }

    fn onHeartbeat(self: *Supervisor, h: messages.Heartbeat, now: u64) void {
        const changed = h.revision != self.snapshot.revision or h.base != self.snapshot.base or h.brightness != self.snapshot.brightness or h.overlay != self.snapshot.overlay or h.generator != self.snapshot.generator;
        self.snapshot.revision = h.revision;
        self.snapshot.presented = h.presented;
        self.snapshot.base = h.base;
        self.snapshot.generator = h.generator;
        self.snapshot.overlay = h.overlay;
        self.snapshot.brightness = h.brightness;
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
                    self.send(.{ .set_timezone = self.cfg.timezone });
                    self.snapshot.epoch = lifecycle.epoch;
                    self.snapshot.renderer_state = 2;
                    for (&self.relays) |*r| r.used = false;
                    self.hb_presented_at_ns = 0;
                },
                .result => |r| {
                    for (&self.relays) |*rel| if (rel.used and rel.id == p.request_id) {
                        rel.used = false;
                        self.relayResult(p.request_id, r.status, r.revision);
                        break;
                    };
                },
                else => log.warn("unexpected {s} from renderer", .{@tagName(p.message)}),
            }
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

    fn pollIp(self: *Supervisor, now: u64) void {
        if (now < self.next_ip_poll) return;
        self.next_ip_poll = now + @as(u64, self.cfg_cli.ip_poll_s) * ns_per_s;
        const addr = sys.ifAddr("wlan0") catch |e| {
            log.warn("wlan0 address query failed: {s}", .{sys.errText(e)});
            return;
        };
        if (std.meta.eql(addr, self.last_ip)) return;
        self.last_ip = addr;
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

fn run(cfg: cli.Config, environ: anytype, args: []const [:0]const u8) !u8 {
    const t0 = sys.monotonicNs();
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

    var s = Supervisor{ .cfg_cli = cfg, .cfg_dir_text = cfg.dir, .cfg_stats = cfg.stats, .ep = ep, .timer = timer, .sigfd = sigfd, .keys = keys, .self_pid = sys.getpid() };
    log.info("supervising {s} (fallback {s}) profile {s} pid {d}", .{ cfg.renderer, cfg.fallbackPath(), @tagName(cfg.profile), s.self_pid });
    var netd_path_buf: [160]u8 = undefined;
    s.netd_path = std.fmt.bufPrintZ(&netd_path_buf, "{s}/tc002-netd", .{cfg.dir}) catch unreachable;
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
    s.snapshot.config_revision = s.cfg.revision;
    s.snapshot.saved_revision = s.cfg.saved_revision;
    s.listener = sys.tcpListener(http_port, 8) catch |e| blk: {
        log.err("cannot bind port {d}: {s}; the http api will be unavailable", .{ http_port, sys.errText(e) });
        break :blk null;
    };
    if (s.listener != null) log.info("listening on port {d} (plaintext, isolated-lan profile)", .{http_port});

    var events: [8]sys.Event = undefined;
    while (true) {
        const now = sys.monotonicNs();
        s.drainSignals(now);
        s.drainIpc(now);
        s.drainKeys(now);
        s.pollGesture(now);
        s.pollLifecycle(now);
        s.pollIp(now);
        s.drainNetd(now);
        s.pollNetd(now);
        s.expireRelays(now);
        if (now >= s.next_sample_ns) {
            s.sample(now);
            s.next_sample_ns = now + sample_period_ns;
        }
        if (s.shutting_down and s.netd_pid != null) {
            if (s.netd_pid) |pid| sys.kill(pid, .TERM);
        }
        if (s.shutting_down and s.child_pid == null and s.netd_pid == null) break;
        try sys.timerfdArmAt(timer, now + tick_ns);
        const n = try sys.epollWait(ep, &events, -1);
        for (events[0..n]) |ev| if (ev.data.u64 == @intFromEnum(Tag.timer)) sys.timerfdDrain(timer);
    }
    log.info("exit: {d} heartbeats, {d} renderer restarts, {d} netd restarts, final state {s}", .{ s.heartbeats, s.restarts, s.netd_restarts, @tagName(lifecycle.state) });
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
