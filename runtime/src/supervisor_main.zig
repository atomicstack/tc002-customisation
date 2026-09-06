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

const linux = std.os.linux;
const ns_per_s = std.time.ns_per_s;

const Tag = enum(u64) { timer = 1, signals = 2, ipc = 3, keys = 4 };

const tick_ns: u64 = 100_000_000;
const property_timeout_ns: u64 = 2 * ns_per_s;
const ipc_packets_per_iteration = 32;

var lifecycle = child.Lifecycle{};
var gesture = maintenance.Gesture{};
var packet_buf: [codec.max_message]u8 = undefined;
var send_buf: [codec.max_message]u8 = undefined;
var evbuf: [32 * evdev.event_size]u8 = undefined;

const Supervisor = struct {
    cfg: cli.Config,
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

    fn send(self: *Supervisor, msg: messages.Message) void {
        const fd = self.child_fd orelse return;
        self.request_id += 1;
        const packet = messages.encodePacket(msg, self.request_id, lifecycle.epoch, &send_buf) catch return;
        sys.sendPacket(fd, packet) catch |e| log.warn("ipc send to renderer failed: {s}", .{sys.errText(e)});
    }

    fn panelLockFree(self: *Supervisor) bool {
        const fd = sys.open(self.cfg.lock_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |e| {
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
        const path = if (lifecycle.slot == .candidate) self.cfg.renderer else self.cfg.fallbackPath();
        const epoch = lifecycle.epoch + 1;
        var epoch_buf: [16]u8 = undefined;
        const epoch_text = std.fmt.bufPrintZ(&epoch_buf, "{d}", .{epoch}) catch unreachable;
        var argv: cli.Argv = undefined;
        _ = cli.spawnArgv(self.cfg, path, epoch_text, &argv);

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
    }

    fn drainSignals(self: *Supervisor, now: u64) void {
        while (sys.readSignal(self.sigfd) catch null) |info| {
            switch (info.signo) {
                @intFromEnum(linux.SIG.CHLD) => self.reap(now),
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
                .heartbeat => {
                    self.heartbeats += 1;
                    lifecycle.onHeartbeat(now);
                },
                .ready => {
                    lifecycle.onReady(now);
                    log.info("renderer ready {d} ms after spawn", .{(now - self.child_spawned_ns) / 1_000_000});
                    if (self.last_ip) |a| self.send(.{ .ip_changed = .{ .present = 1, .addr = a } });
                },
                .result => {},
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
                if (ev.type == evdev.EV_KEY and ev.code == self.cfg.keymap.knob and ev.value != 2) gesture.onKey(ev.value != 0, now);
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
            .grant => switch (self.cfg.profile) {
                .dev => log.info("maintenance gesture recognised (dev profile: adbd left as it is)", .{}),
                .hardened => {
                    log.info("maintenance gesture recognised: adbd enabled for fifteen minutes", .{});
                    self.setDebugProperty("1");
                },
            },
            .revoke => switch (self.cfg.profile) {
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
        self.next_ip_poll = now + @as(u64, self.cfg.ip_poll_s) * ns_per_s;
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

fn run(cfg: cli.Config, environ: anytype, args: []const [:0]const u8) !u8 {
    const t0 = sys.monotonicNs();
    // 1. the anti-brick flag, before anything that could block or fail
    if (cfg.no_property) {
        log.warn("sys.zkapp.state not set (--no-property)", .{});
    } else {
        props.set("sys.zkapp.state", "running", property_timeout_ns) catch |e| {
            log.err("sys.zkapp.state=running failed: {s}; exiting without pretending", .{@errorName(e)});
            return 2;
        };
        log.info("sys.zkapp.state=running accepted {d} ms after entry (uptime {d} ms)", .{ (sys.monotonicNs() - t0) / 1_000_000, t0 / 1_000_000 });
    }
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

    var s = Supervisor{ .cfg = cfg, .ep = ep, .timer = timer, .sigfd = sigfd, .keys = keys, .self_pid = sys.getpid() };
    log.info("supervising {s} (fallback {s}) profile {s} pid {d}", .{ cfg.renderer, cfg.fallbackPath(), @tagName(cfg.profile), s.self_pid });

    var events: [8]sys.Event = undefined;
    while (true) {
        const now = sys.monotonicNs();
        s.drainSignals(now);
        s.drainIpc(now);
        s.drainKeys(now);
        s.pollGesture(now);
        s.pollLifecycle(now);
        s.pollIp(now);
        if (s.shutting_down and s.child_pid == null) break;
        try sys.timerfdArmAt(timer, now + tick_ns);
        const n = try sys.epollWait(ep, &events, -1);
        for (events[0..n]) |ev| if (ev.data.u64 == @intFromEnum(Tag.timer)) sys.timerfdDrain(timer);
    }
    log.info("exit: {d} heartbeats, {d} restarts, final state {s}", .{ s.heartbeats, s.restarts, @tagName(lifecycle.state) });
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
