//! tc002d: the renderer. one epoll loop with a monotonic timer, evdev, the supervisor's
//! seqpacket channel and a signalfd. owns the panel through an exclusive lock, the applied scene
//! state, the presentation model, and command deduplication. no steady-state allocation.
const std = @import("std");
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const geometry = @import("panel/geometry.zig");
const pack = @import("panel/pack.zig");
const presenter = @import("panel/presenter.zig");
const fade = @import("panel/fade.zig");
const spidev = @import("panel/spidev.zig");
const scene = @import("scene/scene.zig");
const tz = @import("scene/tz.zig");
const arbiter = @import("scene/arbiter.zig");
const menu = @import("scene/menu.zig");
const ip = @import("scene/ip.zig");
const evdev = @import("input/evdev.zig");
const actions = @import("input/actions.zig");
const messages = @import("ipc/messages.zig");
const codec = @import("ipc/codec.zig");
const dedup = @import("ipc/dedup.zig");
const cli = @import("tc002d/cli.zig");
const sched = @import("tc002d/sched.zig");

const linux = std.os.linux;

/// no symbolised stack traces on the device: a panic prints its message and exits. this keeps the
/// dwarf unwinder and its tables out of the binary (it more than halves .text).
pub const panic = std.debug.simple_panic;
/// and no segfault handler: it would drag the dwarf unwinder back in.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const ns_per_s = std.time.ns_per_s;

const Tag = enum(u64) { timer = 1, keys = 2, knob = 3, ipc = 4, signals = 5 };

const heartbeat_period_ns: u64 = 250_000_000;
const stats_period_ns: u64 = 5 * ns_per_s;
const stop_bound_ns: u64 = 300_000_000;
const ipc_packets_per_iteration = 8;
const evdev_events_per_read = 64;

// everything the loop touches is static: allocated once, never in the render path.
var arb: arbiter.Arbiter = undefined;
var rgb: geometry.Rgb = undefined;
/// what goes to the panel after fades: the scene output blended and levelled, before brightness.
var out_rgb: geometry.Rgb = geometry.black_rgb;
var fader = fade.Fader{};
/// the outgoing scene rendered live as a transition's old layer
var old_rgb: geometry.Rgb = undefined;
var frame: geometry.Frame = undefined;
var lut: pack.Lut = undefined;
var lut_brightness: u8 = 0;
var pres = presenter.Presenter{};
var frame_version: u32 = 0;
var cache = dedup.Cache{};
var packet_buf: [codec.max_message]u8 = undefined;
/// sized for the largest reply (a screen read: 6 + 2,496 bytes of payload)
var reply_buf: [codec.max_message]u8 = undefined;
var evbuf: [evdev_events_per_read * evdev.event_size]u8 = undefined;

const Renderer = struct {
    cfg: cli.Config,
    ep: sys.Fd,
    timer: sys.Fd,
    sigfd: sys.Fd,
    keys: ?sys.Fd,
    knob: ?sys.Fd,
    lock: sys.Fd,
    device: ?spidev.Device,
    mapper: actions.Mapper,
    started_ns: u64,
    render_deadline: ?u64 = null,
    /// the last redraw found nothing to schedule (an idle scene, or the panel dark): redraw only
    /// on a change instead of on every wake-up.
    idle: bool = false,
    /// started dark and not yet switched on: the saved state lands without effects, then fades in
    unrevealed: bool = false,
    next_heartbeat: u64 = 0,
    next_stats: u64 = 0,
    stopping: bool = false,
    stop_deadline: u64 = 0,
    ready_sent: bool = false,
    ipc_dead: bool = false,
    redraws: u64 = 0,
    write_errors: u64 = 0,
    short_writes: u64 = 0,
    stats_transfers: u64 = 0,
    stats_redraws: u64 = 0,
    dropped_actions: u32 = 0,

    fn send(self: *Renderer, msg: messages.Message, request_id: u64) void {
        if (self.ipc_dead) return;
        const fd = self.cfg.ipc_fd orelse return;
        const packet = messages.encodePacket(msg, request_id, self.cfg.epoch, &reply_buf) catch {
            log.warn("ipc message {s} does not fit a packet", .{@tagName(msg)});
            return;
        };
        sys.sendPacket(fd, packet) catch |e| switch (e) {
            error.WouldBlock => {}, // the supervisor is behind; heartbeats and results are bounded
            else => log.warn("ipc send failed: {s}", .{sys.errText(e)}),
        };
    }

    fn reply(self: *Renderer, request_id: u64, status: messages.Status, revision: u32) void {
        self.send(.{ .result = .{ .status = status, .revision = revision } }, request_id);
    }

    fn beginStop(self: *Renderer, now: u64) void {
        if (self.stopping) return;
        self.stopping = true;
        self.stop_deadline = now + stop_bound_ns;
        self.render_deadline = null;
        // the panel shows the previous transfer, so black goes out until it is visible
        @memset(&frame, 0);
        frame_version +%= 1;
        pres.submit(frame_version, .isolated);
    }

    /// rearm wall-clock presentation and redraw on the next iteration.
    fn forceRedraw(self: *Renderer) void {
        self.render_deadline = null;
        self.idle = false;
    }

    fn redraw(self: *Renderer, now: u64, base_deadline: u64) void {
        const wall = sys.realtimeNs();
        arb.tick(now, wall);
        if (self.unrevealed and arb.power) self.unrevealed = false;
        if (arb.takeTransition()) |spec| {
            if (self.unrevealed) {
                // nothing is visible yet: the saved state simply lands, the power ramp reveals it
                arb.transitionDone();
            } else {
                // an effect that starts while another runs, or a cut, has no live old layer: the
                // remembered composite (or nothing) stands in
                const chained = fader.cross.active();
                fader.begin(&out_rgb, spec, now);
                if (chained or !fader.cross.active()) arb.transitionDone();
            }
        }
        if (arb.takeMenuRequest()) |r| self.sendMenuRequest(r);
        fader.setPower(arb.power, now);
        arb.render(wall, &rgb);
        const live_old = fader.cross.active() and arb.renderOutgoing(wall, &old_rgb);
        const fading = if (live_old) fader.applyLive(&old_rgb, &rgb, &out_rgb, now) else fader.apply(&rgb, &out_rgb, now);
        if (!fader.cross.active()) arb.transitionDone();
        if (lut_brightness != arb.brightness) {
            lut = pack.buildLut(arb.brightness);
            lut_brightness = arb.brightness;
        }
        pack.packWithLut(&out_rgb, &lut, &frame);
        frame_version +%= 1;
        // a running fade owns the cadence; a dark panel has none; otherwise the scene decides
        const cadence: scene.Cadence = if (fading) .{ .continuous = scene.frame_period_ns } else if (fader.dark()) .idle else arb.cadence(wall);
        pres.submit(frame_version, if (cadence == .continuous) .continuous else .isolated);
        self.redraws += 1;
        self.render_deadline = sched.afterRedraw(fading, cadence, base_deadline, now, wall);
        self.idle = cadence == .idle;
    }

    /// the settings the on-device menu changed: the supervisor validates, applies and persists
    fn sendMenuRequest(self: *Renderer, r: menu.Request) void {
        if (r == .scene_param) {
            // the scene it belongs to is whatever is showing: the menu is that scene's own
            self.send(.{ .set_param = .{ .base = @intFromEnum(arb.base), .index = r.scene_param.index, .value = r.scene_param.value } }, 0);
            return;
        }
        const K = messages.MenuRequest.Kind;
        const m: messages.MenuRequest = switch (r) {
            .brightness => |v| .{ .kind = @intFromEnum(K.brightness), .value = v },
            .clock_font => |f| .{ .kind = @intFromEnum(K.clock_font), .value = @intFromEnum(f) },
            .generator => |g| .{ .kind = @intFromEnum(K.generator), .value = @intFromEnum(g) },
            .ip_mode => |v| .{ .kind = @intFromEnum(K.ip_mode), .value = @intFromEnum(v) },
            .mqtt => |on| .{ .kind = @intFromEnum(K.mqtt), .value = @intFromBool(on) },
            .ntfy => |on| .{ .kind = @intFromEnum(K.ntfy), .value = @intFromBool(on) },
            .night => |on| .{ .kind = @intFromEnum(K.night), .value = @intFromBool(on) },
            .night_level => |v| .{ .kind = @intFromEnum(K.night_level), .value = v },
            .power_off => .{ .kind = @intFromEnum(K.power_off) },
            .reboot => .{ .kind = @intFromEnum(K.reboot) },
            // a reseed is not a setting and a close is nobody else's business
            .none, .close, .reseed, .scene_param => return,
        };
        self.send(.{ .menu_request = m }, 0);
    }

    fn sendEdges(self: *Renderer, edges: *const actions.EdgeQueue) void {
        for (edges.slice()) |e| self.send(.{ .input = .{ .control = @intFromEnum(e.control), .event = @intFromEnum(e.event), .position = e.position } }, 0);
        if (edges.dropped > 0) log.warn("dropped {d} input edges under load", .{edges.dropped});
    }

    fn transfer(self: *Renderer, now: u64) void {
        if (self.device) |*d| {
            if (d.writeFrame(&frame)) |n| {
                if (n != geometry.frame_bytes) self.short_writes += 1;
            } else |_| {
                self.write_errors += 1;
            }
        }
        pres.transfer(now);
        if (!self.ready_sent) {
            self.ready_sent = true;
            self.send(.ready, 0);
            log.info("ready after {d} ms", .{(now - self.started_ns) / 1_000_000});
        }
    }

    fn heartbeat(self: *Renderer, now: u64) void {
        _ = now;
        const state: u8 = if (self.stopping) 2 else if (self.ready_sent) 1 else 0;
        const overlay: u8 = switch (arb.overlay) {
            .none => 0,
            .notify => 1,
            .raw => 2,
            .stream_arming => 3,
        };
        self.send(.{ .heartbeat = .{
            .presented = pres.transfers,
            .revision = arb.revision,
            .state = state,
            .base = @intFromEnum(arb.base),
            .generator = @intFromEnum(arb.art.generator),
            .overlay = overlay,
            .brightness = arb.brightness,
            .power = @intFromBool(arb.power),
            .clock = messages.ClockStyle.full(arb.clock.style),
            .ip_mode = @intFromEnum(arb.ip.mode),
        } }, 0);
    }

    fn handlePacket(self: *Renderer, bytes: []const u8, now: u64) void {
        const p = messages.decodePacket(bytes) catch |e| {
            log.warn("bad ipc packet: {s}", .{@errorName(e)});
            return;
        };
        switch (p.message) {
            .stop => {
                log.info("stop requested by the supervisor", .{});
                self.beginStop(now);
                self.reply(p.request_id, .applied, arb.revision);
                return;
            },
            .time_corrected => {
                _ = arb.apply(.time_corrected, now);
                self.forceRedraw();
                self.reply(p.request_id, .applied, arb.revision);
                return;
            },
            .ip_changed => |i| {
                _ = arb.apply(.{ .ip_changed = if (i.present != 0) i.addr else null }, now);
                self.reply(p.request_id, .applied, arb.revision);
                return;
            },
            .set_param => |sp| {
                // the top bit says the parameter belongs to a named generator rather than to
                // whatever scene happens to be showing
                if (sp.base & 0x80 != 0) {
                    arb.setGeneratorParam(sp.base & 0x7f, sp.index, sp.value);
                } else if (messages.enumFromInt(arbiter.Base, sp.base)) |b| {
                    if (b == arb.base) arb.setSceneParam(sp.index, sp.value);
                }
                return;
            },
            .device_status => |d| {
                arb.setDeviceStatus(.{
                    .address = arb.ip.addr,
                    .battery_pct = d.battery_pct,
                    .usb = d.usb,
                    .wifi_quality = d.wifi_quality,
                    .wifi_dbm = d.wifi_dbm,
                    .time_synced = d.time_synced != 0,
                    .uptime_s = d.uptime_s,
                    .mqtt_on = d.mqtt_on != 0,
                    .ntfy_on = d.ntfy_on != 0,
                    .night_on = d.night_on != 0,
                    .night_level = d.night_level,
                    .night_placed = d.night_placed != 0,
                });
                return;
            },
            .set_timezone => |t| {
                if (tz.parse(t.slice())) |rule| {
                    arb.clock.rule = rule;
                    _ = arb.apply(.time_corrected, now);
                    self.forceRedraw();
                    self.reply(p.request_id, .applied, arb.revision);
                } else |_| {
                    self.reply(p.request_id, .rejected, arb.revision);
                }
                return;
            },
            .screen_get => {
                // a read: what is on the panel now, outside the epoch and dedup rules
                self.send(.{ .screen = .{ .revision = arb.revision, .brightness = arb.brightness, .power = @intFromBool(arb.power), .rgb = out_rgb } }, p.request_id);
                return;
            },
            .heartbeat, .ready, .result, .screen, .input, .log_get, .log_lines, .credentials, .config, .config_get, .config_patch, .config_save, .save_result, .mqtt_put, .status_get, .status => return, // not for the renderer
            else => {},
        }
        // discrete, non-idempotent commands: epoch, then the deduplication window, then apply
        if (p.epoch != self.cfg.epoch) {
            self.reply(p.request_id, .stale_epoch, arb.revision);
            return;
        }
        if (cache.lookup(p.request_id, now)) |e| {
            self.reply(p.request_id, e.status, e.revision);
            return;
        }
        if (!cache.available(now)) {
            self.reply(p.request_id, .overload, arb.revision);
            return;
        }
        const res: arbiter.Result = switch (p.message) {
            .set_base => |s| blk: {
                const base = messages.enumFromInt(arbiter.Base, s.base) orelse break :blk arbiter.Result{ .rejected = .invalid_text };
                const spec = s.transition.toSpec();
                var r = arb.applyWith(.{ .set_base = base }, spec, now);
                if (base == .art) {
                    if (messages.enumFromInt(scene.Generator, s.generator)) |g| r = arb.applyWith(.{ .select_generator = g }, spec, now);
                    if (s.seed != 0) r = arb.apply(.{ .reseed = s.seed }, now);
                }
                if (s.style.has != 0) r = arb.applyWith(.{ .set_clock_style = s.style.toPatch() }, spec, now);
                break :blk r;
            },
            .canvas => |d| blk: {
                // install rather than assign: the renderer owns when an arrival animation started
                arb.canvas.install(d, now);
                arb.dirty = true;
                if (arb.base == .canvas) self.forceRedraw();
                break :blk arbiter.Result{ .applied = arb.revision };
            },
            .sprite => |sp| blk: {
                arb.canvas.sprites.put(sp) catch {};
                arb.dirty = true;
                break :blk arbiter.Result{ .applied = arb.revision };
            },
            .sprite_delete => |id| blk: {
                _ = arb.canvas.sprites.remove(id.slice());
                arb.dirty = true;
                break :blk arbiter.Result{ .applied = arb.revision };
            },
            .clock_style => |cs| arb.apply(.{ .set_clock_style = cs.toPatch() }, now),
            .ip_mode => |m| blk: {
                const mode = messages.enumFromInt(ip.Mode, m.mode) orelse break :blk arbiter.Result{ .rejected = .invalid_text };
                break :blk arb.apply(.{ .set_ip_mode = mode }, now);
            },
            .notify => |n| arb.applyWith(.{ .notify = .{ .text = n.slice(), .colour = n.colour, .duration_s = n.duration_s } }, n.transition.toSpec(), now),
            .frame => |f| arb.applyWith(.{ .raw = .{ .rgb = &f.rgb, .duration_s = f.duration_s } }, f.transition.toSpec(), now),
            .brightness => |b| arb.apply(.{ .brightness = b.value }, now),
            .reseed => |r| arb.apply(.{ .reseed = r.seed }, now),
            .arm_stream => arb.apply(.arm_stream, now),
            .power => |pw| arb.apply(.{ .power = pw.on != 0 }, now),
            .inject_input => |i| blk: {
                const control = messages.enumFromInt(actions.Control, i.control) orelse break :blk arbiter.Result{ .rejected = .invalid_text };
                const event = messages.enumFromInt(actions.EdgeEvent, i.event) orelse break :blk arbiter.Result{ .rejected = .invalid_text };
                var queue = actions.ActionQueue{};
                var edges = actions.EdgeQueue{};
                if (!self.mapper.inject(control, event, i.steps, now, &queue, &edges)) break :blk arbiter.Result{ .rejected = .invalid_text };
                for (queue.slice()) |a| arb.action(a, now);
                self.sendEdges(&edges);
                break :blk arbiter.Result{ .applied = arb.revision };
            },
            else => unreachable,
        };
        const status: messages.Status = switch (res) {
            .applied => .applied,
            .rejected => .rejected,
        };
        _ = cache.insert(p.request_id, status, arb.revision, now);
        self.reply(p.request_id, status, arb.revision);
    }

    fn drainIpc(self: *Renderer, now: u64) void {
        if (self.ipc_dead) return;
        const fd = self.cfg.ipc_fd orelse return;
        var count: u32 = 0;
        while (count < ipc_packets_per_iteration) : (count += 1) {
            const packet = sys.recvPacket(fd, &packet_buf) catch |e| {
                switch (e) {
                    error.Closed => {
                        // the supervisor is gone: stop once, and stop watching the dead socket
                        log.warn("supervisor channel closed, stopping", .{});
                        self.ipc_dead = true;
                        sys.epollDel(self.ep, fd);
                        self.beginStop(now);
                    },
                    error.Truncated => log.warn("oversized ipc packet dropped", .{}),
                    else => log.warn("ipc receive failed: {s}", .{sys.errText(e)}),
                }
                return;
            } orelse return;
            self.handlePacket(packet, now);
        }
    }

    fn drainDevice(self: *Renderer, fd: sys.Fd, now: u64, queue: *actions.ActionQueue, edges: *actions.EdgeQueue) void {
        while (true) {
            const n = sys.read(fd, &evbuf) catch |e| switch (e) {
                error.WouldBlock, error.Interrupted => return,
                else => {
                    log.warn("input read failed: {s}", .{sys.errText(e)});
                    return;
                },
            };
            if (n == 0) return;
            var off: usize = 0;
            while (off + evdev.event_size <= n) : (off += evdev.event_size) {
                self.mapper.feed(evdev.decode(evbuf[off..][0..evdev.event_size]), now, queue, edges);
            }
            if (n < evbuf.len) return;
        }
    }

    fn drainInput(self: *Renderer, now: u64) void {
        var queue = actions.ActionQueue{};
        var edges = actions.EdgeQueue{};
        if (self.keys) |fd| self.drainDevice(fd, now, &queue, &edges);
        if (self.knob) |fd| self.drainDevice(fd, now, &queue, &edges);
        self.mapper.poll(now, &queue, &edges);
        for (queue.slice()) |a| arb.action(a, now);
        if (queue.dropped > 0) {
            self.dropped_actions += queue.dropped;
            log.warn("dropped {d} physical actions under load", .{queue.dropped});
        }
        self.sendEdges(&edges);
        if (self.mapper.abs_unexpected) |v| {
            log.warn("rotary reported an unexpected value {d} (known: 8 then 1 ccw, 13 then 11 cw)", .{v});
            self.mapper.abs_unexpected = null;
        }
        if (self.mapper.last_press) |p| {
            log.info("key {d} pressed: {s}", .{ p.code, @tagName(p.control) });
            self.mapper.last_press = null;
        }
        if (self.mapper.unmapped_code != 0) {
            log.info("unmapped keycode {d} pressed (keymap {d},{d},{d},{d})", .{ self.mapper.unmapped_code, self.mapper.keymap.left, self.mapper.keymap.middle, self.mapper.keymap.right, self.mapper.keymap.knob });
            self.mapper.unmapped_code = 0;
        }
    }

    fn stats(self: *Renderer, now: u64) void {
        const interval = now - (self.next_stats - stats_period_ns);
        const t = pres.transfers - self.stats_transfers;
        const r = self.redraws - self.stats_redraws;
        log.info("transfers={d} redraws={d} fps={d}.{d} short={d} errors={d} visible={d} revision={d}", .{
            t,
            r,
            t * ns_per_s / interval,
            (t * ns_per_s * 10 / interval) % 10,
            self.short_writes,
            self.write_errors,
            pres.visible,
            arb.revision,
        });
        self.stats_transfers = pres.transfers;
        self.stats_redraws = self.redraws;
    }
};

fn openInput(path: [*:0]const u8, what: []const u8) ?sys.Fd {
    return sys.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |e| {
        log.warn("no {s} input device: {s}", .{ what, sys.errText(e) });
        return null;
    };
}

fn seedFromClock() u32 {
    var bytes: [4]u8 = undefined;
    sys.getrandom(&bytes) catch {
        const t = sys.realtimeNs();
        return @truncate(t ^ (t >> 32));
    };
    return std.mem.readInt(u32, &bytes, .little);
}

fn run(cfg: cli.Config) !u8 {
    const rule = tz.parse(cfg.tz_rule) catch {
        log.err("invalid tz rule", .{});
        return 2;
    };

    // the lock is created by the supervisor; standalone runs create it themselves
    const lock = sys.open(cfg.lock_path, .{ .ACCMODE = .RDONLY, .CREAT = cfg.ipc_fd == null, .CLOEXEC = true }, 0o600) catch |e| {
        log.err("cannot open panel lock: {s}", .{sys.errText(e)});
        return 3;
    };
    if (!try sys.flockTry(lock)) {
        log.err("panel lock held by another renderer; not touching the panel", .{});
        return 3;
    }

    const sigfd = try sys.signalfdFor(&.{ .TERM, .INT });
    sys.setSignalDisposition(.PIPE, linux.SIG.IGN);
    const keys = openInput(cfg.keys_path, "button");
    const knob = openInput(cfg.knob_path, "knob");

    var device: ?spidev.Device = null;
    if (!cfg.dry_run) {
        device = spidev.Device.open(cfg.spi_path, cfg.gpio_path) catch |e| {
            log.err("cannot open the panel ({s}): {s} (is zkswe stopped?)", .{ cfg.spi_path, sys.errText(e) });
            return 1;
        };
    }

    const ep = try sys.epollCreate();
    const timer = try sys.timerfdCreate();
    try sys.epollAdd(ep, timer, linux.EPOLL.IN, @intFromEnum(Tag.timer));
    try sys.epollAdd(ep, sigfd, linux.EPOLL.IN, @intFromEnum(Tag.signals));
    if (keys) |fd| try sys.epollAdd(ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.keys));
    if (knob) |fd| try sys.epollAdd(ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.knob));
    if (cfg.ipc_fd) |fd| try sys.epollAdd(ep, fd, linux.EPOLL.IN, @intFromEnum(Tag.ipc));

    const seed = if (cfg.seed != 0) cfg.seed else seedFromClock();
    arb = arbiter.Arbiter.init(cfg.base, cfg.generator, seed, rule);
    arb.brightness = cfg.brightness;
    fader.crossfade_ns = @as(u64, cfg.crossfade_ms) * 1_000_000;
    arb.default_transition = .{ .effect = .fade, .duration_ns = fader.crossfade_ns };
    fader.power_ns = @as(u64, cfg.power_fade_ms) * 1_000_000;
    if (cfg.start_dark) {
        // dark until the supervisor has pushed the saved state and sends power on
        arb.power = false;
        fader.power_on = false;
        fader.level = 0;
        fader.level_from = 0;
    }

    const started = sys.monotonicNs();
    var r = Renderer{
        .cfg = cfg,
        .ep = ep,
        .timer = timer,
        .sigfd = sigfd,
        .keys = keys,
        .knob = knob,
        .lock = lock,
        .device = device,
        .mapper = actions.Mapper.init(cfg.keymap),
        .started_ns = started,
        .next_heartbeat = started,
        .next_stats = started + stats_period_ns, .unrevealed = cfg.start_dark };
    log.info("epoch {d} seed {d} base {s} generator {d} {s}", .{ cfg.epoch, seed, @tagName(cfg.base), @intFromEnum(cfg.generator), if (cfg.dry_run) "dry run" else "panel open" });

    var events: [8]sys.Event = undefined;
    while (true) {
        const now = sys.monotonicNs();

        while (try sys.readSignal(r.sigfd)) |info| {
            log.info("signal {d}, stopping", .{info.signo});
            r.beginStop(now);
        }
        r.drainIpc(now);
        r.drainInput(now);

        if (!r.stopping) {
            if (r.render_deadline) |d| {
                if (now >= d) r.redraw(now, d);
            }
            // an idle overlay (a raw frame, a notification that fits) has no deadline: expire it here
            if (sched.expiryNeedsRedraw(arb.nextExpiryNs(), r.render_deadline, now)) r.forceRedraw();
            if (arb.takeDirty() or (r.render_deadline == null and !r.idle)) {
                // an isolated change: redraw immediately; keep a continuous phase if one is running
                const base = if (r.render_deadline) |d| (if (d <= now) d else d - scene.frame_period_ns) else now;
                r.redraw(now, base);
            }
        }
        if (pres.dueAt()) |due| {
            if (now >= due) r.transfer(now);
        }
        if (now >= r.next_heartbeat) {
            r.heartbeat(now);
            r.next_heartbeat = now + heartbeat_period_ns;
        }
        if (cfg.stats and now >= r.next_stats) {
            r.stats(now);
            r.next_stats = now + stats_period_ns;
        }
        if (cfg.seconds != 0 and !r.stopping and now - started >= @as(u64, cfg.seconds) * ns_per_s) r.beginStop(now);
        if (r.stopping and (!pres.needsTransfer() or now >= r.stop_deadline)) break;

        const wake = sched.earliest(r.render_deadline, pres.dueAt(), r.next_heartbeat, arb.nextExpiryNs());
        const wake_at = if (cfg.stats) sched.earliest(wake, r.next_stats, null, null) else wake;
        try sys.timerfdArmAt(r.timer, @max(wake_at orelse (now + ns_per_s), now + 1));
        const n = try sys.epollWait(r.ep, &events, -1);
        for (events[0..n]) |ev| if (ev.data.u64 == @intFromEnum(Tag.timer)) sys.timerfdDrain(r.timer);
    }

    const elapsed = sys.monotonicNs() - started;
    if (r.device) |*d| d.close();
    sys.funlock(lock);
    sys.close(lock);
    log.info("exit: transfers={d} redraws={d} seconds={d} short={d} errors={d} dropped_actions={d}", .{
        pres.transfers,
        r.redraws,
        elapsed / ns_per_s,
        r.short_writes,
        r.write_errors,
        r.dropped_actions,
    });
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    log.program = "tc002d";
    var args: [32][:0]const u8 = undefined;
    const raw = init.args.vector;
    const n = @min(raw.len -| 1, args.len);
    for (0..n) |i| args[i] = std.mem.span(raw[i + 1]);
    const outcome = cli.parse(args[0..n]) catch |e| {
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
        .failure => return 2,
    };
    return run(cfg) catch |e| {
        log.err("fatal: {s}", .{sys.errText(e)});
        return 1;
    };
}
