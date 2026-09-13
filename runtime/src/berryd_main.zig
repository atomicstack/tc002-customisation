//! tc002-berryd: the script interpreter, in a process of its own.
//!
//! the supervisor spawns it as uid 1001 with the ipc socket on fd 3 and sends its settings once.
//! it holds one berry vm on a fixed heap and reports what that heap is doing once a second. it
//! holds no authoritative state, opens no file and — deliberately — has no network descriptor at
//! all: everything a script eventually reaches goes back through the supervisor, so a script that
//! misbehaves can drive the panel but cannot open a socket.
//!
//! the second core is the point. a vm that spends 10 ms on a frame is spending it somewhere the
//! renderer's 60 fps loop never notices, and the measured cost of getting the result back is 8.3
//! microseconds (`zig build ipcbench`).
//!
//! the once-a-second report doubles as the liveness ping. a script stuck in a loop leaves this
//! process perfectly healthy and simply silent, so silence is the signal the supervisor watches.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const messages = @import("ipc/messages.zig");
const codec = @import("ipc/codec.zig");
const berry = @import("berry/vm.zig");
const store = @import("berry/store.zig");
const berry_api = @import("berry/api.zig");
const config = @import("supervisor/config.zig");

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const supervisor_fd: sys.Fd = 3;
/// often enough that two missed reports are still inside the supervisor's patience, and cheap:
/// the message is twenty bytes
const report_interval_ns: u64 = 1 * std.time.ns_per_s;
/// the settings should arrive immediately after the spawn; without them there is nothing to be
const config_wait_ns: u64 = 10 * std.time.ns_per_s;

var packet_buf: [codec.max_message]u8 = undefined;
var out_buf: [codec.max_message]u8 = undefined;
/// our copy of what the supervisor holds. the supervisor owns it; this is what a fresh vm is
/// handed so that a saved script survives a power cycle.
var scripts: store.Store = .{};

const Tag = enum(u64) { ipc, timer };

fn send(msg: messages.Message) void {
    const packet = messages.encodePacket(msg, 0, 0, &out_buf) catch return;
    sys.sendPacket(supervisor_fd, packet) catch {};
}

/// where a script's `print` goes: stdout, which the supervisor is already reading into the log
/// ring for every child it spawns. no new plumbing, and a script's output lands in `GET /logs`
/// beside everything else that happened.
fn toLog(text: []const u8) void {
    _ = sys.write(1, text) catch {};
}

fn report() void {
    send(.{ .berry_status = .{
        .heap_bytes = @intCast(berry.arena.buf.len),
        .heap_used = @intCast(berry.arena.used),
        .heap_high_water = @intCast(berry.arena.high_water),
        .alloc_failures = berry.arena.failures,
        .stops = berry.stops,
    } });
}

/// block until the supervisor sends the settings, or give up
fn waitConfig() ?messages.BerryConfig {
    const deadline = sys.monotonicNs() + config_wait_ns;
    while (sys.monotonicNs() < deadline) {
        if (sys.recvPacket(supervisor_fd, &packet_buf) catch null) |bytes| {
            const p = messages.decodePacket(bytes) catch continue;
            if (p.message == .berry_config) return p.message.berry_config;
            continue;
        }
        sys.nanosleep(5 * std.time.ns_per_ms);
    }
    return null;
}

/// what the supervisor asked for: compile a script, forget one, evaluate a snippet, or start over.
fn onScript(vm: *berry.Vm, w: messages.BerryScript, handler_ms: u16) void {
    const op: messages.BerryScript.Op = @enumFromInt(@min(w.op, 3));
    const name = w.name.slice();
    switch (op) {
        .put => {
            const st = vm.compile(name, w.slice());
            if (st != .ok) {
                const text = vm.errorText();
                log.warn("{s} will not compile: {s}", .{ name, text });
                send(.{ .berry_result = .{ .outcome = 1, .name = w.name, .text = config.Text.init(text[0..@min(text.len, config.text_max)]) } });
                vm.clearError();
                return;
            }
            scripts.put(name, w.slice()) catch |e| {
                send(.{ .berry_result = .{ .outcome = 3, .name = w.name, .text = config.Text.init(@errorName(e)) } });
                return;
            };
            send(.{ .berry_result = .{ .outcome = 0, .name = w.name } });
        },
        .delete => _ = scripts.remove(name),
        .eval => {
            const st = vm.runFor("eval", w.slice(), @as(u64, handler_ms) * std.time.ns_per_ms);
            const text = vm.errorText();
            send(.{ .berry_result = .{
                .outcome = if (st == .ok) 0 else 2,
                .name = w.name,
                .text = config.Text.init(text[0..@min(text.len, config.text_max)]),
            } });
            if (st != .ok) vm.clearError();
        },
        .reload => runAutoexec(vm, handler_ms),
    }
}

/// the script named `autoexec`, run once the supervisor has handed over the whole set. this is
/// what makes a device that was power-cycled come back doing what it was told to do.
fn runAutoexec(vm: *berry.Vm, handler_ms: u16) void {
    const source = scripts.get("autoexec") orelse return;
    const st = vm.runFor("autoexec", source, @as(u64, handler_ms) * std.time.ns_per_ms);
    if (st == .ok) {
        log.info("autoexec ran, {d} bytes", .{source.len});
    } else {
        log.warn("autoexec failed: {s}", .{vm.errorText()});
        vm.clearError();
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = init;
    log.program = "tc002-berryd";

    const cfg = waitConfig() orelse {
        log.err("no settings arrived; nothing to run", .{});
        return 1;
    };

    berry.sink = toLog;
    berry.clock = sys.monotonicNs;
    berry.heapInit(cfg.heap_kb);

    var vm = berry.Vm.init() orelse {
        log.err("the interpreter would not start in {d} kb", .{cfg.heap_kb});
        return 1;
    };
    defer vm.deinit();

    // the natives, then the prelude that gathers them into the tc002 and panel modules
    berry_api.emit = send;
    berry_api.register(&vm);
    if (vm.run("prelude", berry_api.prelude) != .ok) {
        log.err("the prelude would not run: {s}", .{vm.errorText()});
        return 1;
    }
    log.info("berry up: {d} kb of heap, {d} ms per handler", .{ cfg.heap_kb, cfg.handler_ms });
    report();

    const ep = sys.epollCreate() catch |e| {
        log.err("epoll: {s}", .{sys.errText(e)});
        return 1;
    };
    const timer = sys.timerfdCreate() catch |e| {
        log.err("timerfd: {s}", .{sys.errText(e)});
        return 1;
    };
    sys.epollAdd(ep, supervisor_fd, linux.EPOLL.IN, @intFromEnum(Tag.ipc)) catch return 1;
    sys.epollAdd(ep, timer, linux.EPOLL.IN, @intFromEnum(Tag.timer)) catch return 1;

    var next_report = sys.monotonicNs() + report_interval_ns;
    sys.timerfdArmAt(timer, next_report) catch {};

    var events: [4]sys.Event = undefined;
    while (true) {
        const n = sys.epollWait(ep, &events, 1000) catch |e| {
            log.err("epoll wait: {s}", .{sys.errText(e)});
            return 1;
        };
        for (events[0..n]) |ev| {
            switch (@as(Tag, @enumFromInt(ev.data.u64))) {
                .ipc => while (sys.recvPacket(supervisor_fd, &packet_buf) catch |e| {
                    // the supervisor is gone: so are we, and pdeathsig would have done it anyway
                    log.info("the supervisor closed the channel: {s}", .{sys.errText(e)});
                    return 0;
                }) |bytes| {
                    const p = messages.decodePacket(bytes) catch continue;
                    switch (p.message) {
                        // settings can change while we run; the heap cannot be resized under a
                        // live vm, so a heap change is the supervisor's cue to replace us
                        .berry_config => |c| log.info("settings updated: {d} ms per handler", .{c.handler_ms}),
                        .berry_script => |w| onScript(&vm, w, cfg.handler_ms),
                        .stop => {
                            log.info("stopping", .{});
                            return 0;
                        },
                        else => {},
                    }
                },
                .timer => {
                    sys.timerfdDrain(timer);
                    report();
                    next_report = sys.monotonicNs() + report_interval_ns;
                    sys.timerfdArmAt(timer, next_report) catch {};
                },
            }
        }
    }
}
