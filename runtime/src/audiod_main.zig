//! tc002-audiod: the speaker, in a process of its own.
//!
//! spawned by the supervisor with the ipc socket on fd 3, only while `sound.enabled`. it runs as
//! **root**, which is not a choice: `/dev/mi_ao` and `/dev/mi_sys` are `crw-------`, exactly as
//! `/dev/spidev0.0` is for the renderer. it parses nothing from the network -- every command
//! reaches it as a typed ipc message that the supervisor has already validated.
//!
//! being root is also what makes the design simple: a sound is far too big for an 8 kb ipc
//! datagram, so audiod reads `config/sounds.bin` itself rather than having the store streamed to
//! it. the supervisor writes that file atomically, so a reader sees either the old set or the new.
//!
//! it is a process of its own for the same reason berryd is. pushing pcm means waking on a timer
//! and blocking on a device; doing that inside the renderer's 60 fps loop would put audio jitter
//! and frame jitter in the same thread, and the measured cost of the boundary is 8.3 microseconds.
//!
//! **nothing here has been run against the hardware.** the ioctl numbers are recovered and pinned
//! by tests (`sound/mi.zig`), but the 52-byte attribute payload that sets sample rate and channel
//! count is a size, not a decoded layout -- see `attr_layout_verified` below.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const messages = @import("ipc/messages.zig");
const codec = @import("ipc/codec.zig");
const store = @import("sound/store.zig");
const wav = @import("sound/wav.zig");
const mi = @import("sound/mi.zig");

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const supervisor_fd: sys.Fd = 3;
/// the liveness ping, on berryd's cadence and for berryd's reason: a wedged process is a silent
/// one, so silence is what the supervisor watches for
const report_interval_ns: u64 = 1 * std.time.ns_per_s;
/// how often the playback loop tops the device up while a sound is playing
const feed_interval_ns: u64 = 20 * std.time.ns_per_ms;
const idle_interval_ns: u64 = 250 * std.time.ns_per_ms;

/// **the guard.** `MI_AO_SetPubAttr` takes 52 bytes that were measured as a size and never decoded
/// as fields. pushing a guessed layout at an amplifier attached to somebody's living room is how
/// you get a noise rather than a sound, so the device path refuses until this is set true by
/// somebody who has checked it -- see `vendor/mi_ao/README.md`. everything above it (the store,
/// the queue, the decode, the reporting) runs regardless, so the plumbing can be exercised on a
/// real device in silence.
const attr_layout_verified = false;

var packet_buf: [codec.max_message]u8 = undefined;
var send_buf: [codec.max_message]u8 = undefined;
/// the store as last read from disk
var sounds: store.Store = .{};
var file_buf: [store.budget + 64]u8 = undefined;

const State = enum(u8) { off = 0, starting = 1, ready = 2, playing = 3, failed = 4 };

/// what is playing and how far through it we are. the samples are not copied: `Playing` borrows
/// them out of the store, which does not move while a sound is playing.
const Playing = struct {
    name: store.Name = .{},
    sound: ?wav.Wav = null,
    /// the next sample to hand the device
    cursor: u32 = 0,
    loop: bool = false,
    volume: u8 = 0,

    fn active(self: *const Playing) bool {
        return self.sound != null;
    }

    fn msLeft(self: *const Playing) u32 {
        const w = self.sound orelse return 0;
        const total = w.sampleCount();
        if (self.cursor >= total or w.rate == 0) return 0;
        const frames_left = (total - self.cursor) / @max(w.channels, 1);
        return @intCast(@as(u64, frames_left) * 1000 / w.rate);
    }

    fn stop(self: *Playing) void {
        self.sound = null;
        self.cursor = 0;
        self.loop = false;
    }
};

var playing: Playing = .{};
var state: State = .starting;
var underruns: u32 = 0;
var volume: u8 = 60;

fn send(msg: messages.Message) void {
    const packet = messages.encodePacket(msg, 0, 0, &send_buf) catch return;
    sys.sendPacket(supervisor_fd, packet) catch |e| switch (e) {
        error.WouldBlock => {},
        else => log.warn("ipc send failed: {s}", .{sys.errText(e)}),
    };
}

fn report() void {
    send(.{ .sound_status = .{
        .state = @intFromEnum(state),
        .playing = playing.name,
        .ms_left = playing.msLeft(),
        .underruns = underruns,
    } });
}

/// re-read the store. called at startup and whenever the supervisor says it changed.
fn reload(state_dir: []const u8) void {
    var path_buf: [192]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/config/sounds.bin", .{state_dir}) catch return;
    const bytes = sys.readFile(path.ptr, &file_buf) catch |e| {
        log.info("no sounds to load: {s}", .{sys.errText(e)});
        return;
    };
    if (!sounds.load(bytes)) {
        log.warn("the stored sounds will not parse; none are available", .{});
        return;
    }
    log.info("sounds loaded: {d} of them, {d} bytes", .{ sounds.count(), sounds.used() });
}

fn onPlay(c: *const messages.SoundCmd) void {
    const name = c.name.slice();
    const bytes = sounds.get(name) orelse {
        log.warn("no sound called {s}", .{name});
        return;
    };
    const w = wav.parse(bytes) catch |e| {
        // the store keeps whatever it was given; refusing here rather than at upload means a file
        // that is not a wave is a log line, not a noise
        log.warn("{s} is not a wave this device can play: {s}", .{ name, @errorName(e) });
        return;
    };
    playing = .{
        .name = c.name,
        .sound = w,
        .cursor = 0,
        .loop = c.loop != 0,
        .volume = if (c.volume != 0) c.volume else volume,
    };
    state = .playing;
    log.info("playing {s}: {d} ms, {d} hz, {d} channel(s)", .{ name, w.durationMs(), w.rate, w.channels });
}

/// hand the device the next slice of samples. the only place that touches the hardware.
fn feed() void {
    const w = playing.sound orelse return;
    const total = w.sampleCount();
    if (playing.cursor >= total) {
        if (playing.loop) {
            playing.cursor = 0;
        } else {
            log.info("finished {s}", .{playing.name.slice()});
            playing.stop();
            state = .ready;
            return;
        }
    }
    if (!attr_layout_verified) {
        // silence, deliberately. the queue advances so the rest of the path can be exercised on a
        // device without the amplifier ever being handed a guessed configuration.
        playing.cursor = total;
        return;
    }
    // the device path lands here once the attribute layout is confirmed: mma_alloc, mmap, convert
    // into the shared buffer, flush the cache, send_frame.
    unreachable;
}

fn handle(msg: messages.Message, state_dir: []const u8) void {
    switch (msg) {
        .sound_config => |c| {
            volume = c.volume;
            log.info("settings: volume {d}", .{c.volume});
            if (state == .starting) state = .ready;
        },
        .sound_cmd => |c| {
            const op = messages.enumFromInt(messages.SoundCmd.Op, c.kind) orelse return;
            switch (op) {
                .play => onPlay(&c),
                .stop => {
                    if (playing.active()) log.info("stopped {s}", .{playing.name.slice()});
                    playing.stop();
                    playing.name = .{};
                    state = .ready;
                },
            }
        },
        .sound_list_get => reload(state_dir),
        .stop => {
            log.info("stopping", .{});
            state = .off;
        },
        else => {},
    }
}

fn run(state_dir: []const u8) !u8 {
    const ep = try sys.epollCreate();
    const timer = try sys.timerfdCreate();
    try sys.epollAdd(ep, supervisor_fd, linux.EPOLL.IN, 1);
    try sys.epollAdd(ep, timer, linux.EPOLL.IN, 2);

    reload(state_dir);
    state = .ready;
    if (!attr_layout_verified) {
        log.warn("the audio attribute layout is unverified, so nothing will reach the speaker; see vendor/mi_ao/README.md", .{});
    }

    var next_report: u64 = 0;
    var events: [4]linux.epoll_event = undefined;
    while (state != .off) {
        const now = sys.monotonicNs();
        if (now >= next_report) {
            report();
            next_report = now + report_interval_ns;
        }
        if (playing.active()) feed();

        const wake = if (playing.active()) feed_interval_ns else idle_interval_ns;
        try sys.timerfdArmAt(timer, now + wake);
        const n = sys.epollWait(ep, &events, -1) catch continue;
        for (events[0..n]) |ev| {
            if (ev.data.u64 == 1) {
                while (true) {
                    const packet = sys.recvPacket(supervisor_fd, &packet_buf) catch |e| switch (e) {
                        error.Closed => {
                            log.warn("supervisor channel closed, stopping", .{});
                            return 0;
                        },
                        else => break,
                    } orelse break;
                    const p = messages.decodePacket(packet) catch continue;
                    handle(p.message, state_dir);
                }
            } else if (ev.data.u64 == 2) {
                var buf: [8]u8 = undefined;
                _ = sys.read(timer, &buf) catch {};
            }
        }
    }
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    log.program = "tc002-audiod";
    var state_dir: []const u8 = "/data/tc002/state";
    var i: usize = 1;
    while (i < init.args.vector.len) : (i += 1) {
        const a = std.mem.span(init.args.vector[i]);
        if (std.mem.eql(u8, a, "--state") and i + 1 < init.args.vector.len) {
            i += 1;
            state_dir = std.mem.span(init.args.vector[i]);
        }
    }
    return run(state_dir) catch |e| {
        log.err("fatal: {s}", .{sys.errText(e)});
        return 1;
    };
}
