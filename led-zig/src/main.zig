const std = @import("std");
const cli = @import("cli.zig");
const device = @import("device.zig");
const frame = @import("frame.zig");
const popsquares = @import("popsquares.zig");

var stop_requested = false;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    @atomicStore(bool, &stop_requested, true, .release);
}

fn shouldStop() bool {
    return @atomicLoad(bool, &stop_requested, .acquire);
}

fn installSignals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn secondsBetween(start: std.Io.Timestamp, finish: std.Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(finish.nanoseconds - start.nanoseconds)) /
        @as(f64, std.time.ns_per_s);
}

fn sleepUntil(io: std.Io, deadline: i96) void {
    while (!shouldStop()) {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        const remaining = deadline - now;
        if (remaining <= 0) return;
        const slice = @min(remaining, 10 * std.time.ns_per_ms);
        std.Io.sleep(io, .fromNanoseconds(slice), .awake) catch return;
    }
}

fn deviceErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.DeviceBusy => "device or resource busy",
        error.SpiConfigureFailed => "spi configuration failed",
        else => "device i/o error",
    };
}

fn clockSeed(io: std.Io) u32 {
    const seconds: u32 = @truncate(@as(u96, @bitCast(
        @divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s),
    )));
    const process_id: u32 = @intCast(std.posix.system.getpid());
    return seconds *% 2_654_435_761 ^ process_id;
}

fn execute(
    io: std.Io,
    config: cli.Config,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    @atomicStore(bool, &stop_requested, false, .release);

    var maybe_device: ?device.Device = null;
    if (!config.dry_run) {
        maybe_device = device.Device.init(io, device.spi_path, device.gpio_path) catch |err| {
            try stderr.print(
                "popsquares: cannot open {s} / {s}: {s} (is zkswe stopped?)\n",
                .{ device.spi_path, device.gpio_path, deviceErrorText(err) },
            );
            return 1;
        };
    }
    defer if (maybe_device) |*panel| panel.deinit();

    installSignals();

    const seed = if (config.seed != 0) config.seed else clockSeed(io);
    var state = popsquares.State.init(config.animation, seed);
    var rgb: frame.Rgb = undefined;
    var wire_frame: frame.Frame = undefined;

    const period: i96 = @intFromFloat(
        @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(config.fps)),
    );
    const started = std.Io.Clock.awake.now(io);
    var last = started;
    var last_stats = started;
    var deadline = started.nanoseconds;
    var frames: u64 = 0;
    var frames_at_stats: u64 = 0;
    var short_writes: u64 = 0;
    var write_errors: u64 = 0;

    while (!shouldStop()) {
        const now = std.Io.Clock.awake.now(io);
        if (config.seconds > 0 and secondsBetween(started, now) >= config.seconds) break;

        state.step(config.animation, @floatCast(secondsBetween(last, now)));
        last = now;
        state.render(config.animation, &rgb);
        frame.pack(&rgb, config.brightness, &wire_frame);

        if (maybe_device) |*panel| {
            if (panel.writeFrame(&wire_frame)) |written| {
                if (written != frame.frame_bytes) short_writes += 1;
            } else |_| {
                write_errors += 1;
            }
        }
        frames += 1;

        if (config.stats and secondsBetween(last_stats, now) >= 5) {
            const interval = secondsBetween(last_stats, now);
            try stderr.print(
                "fps={d:.1} frames={d}\n",
                .{ @as(f64, @floatFromInt(frames - frames_at_stats)) / interval, frames },
            );
            try stderr.flush();
            last_stats = now;
            frames_at_stats = frames;
        }

        deadline += period;
        const after = std.Io.Clock.awake.now(io).nanoseconds;
        if (deadline < after) deadline = after;
        sleepUntil(io, deadline);
    }

    const elapsed = secondsBetween(started, std.Io.Clock.awake.now(io));
    if (maybe_device) |*panel| {
        @memset(&wire_frame, 0);
        _ = panel.writeFrame(&wire_frame) catch 0;
        _ = panel.writeFrame(&wire_frame) catch 0;
    }

    try stdout.print(
        "frames={d} seconds={d:.2} fps={d:.1} short_writes={d} write_errors={d}\n",
        .{
            frames,
            elapsed,
            if (elapsed > 0) @as(f64, @floatFromInt(frames)) / elapsed else 0,
            short_writes,
            write_errors,
        },
    );
    return 0;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const exit_code: u8 = switch (cli.parse(args[1..])) {
        .help => code: {
            try stdout.writeAll(cli.usage_text);
            break :code 0;
        },
        .failure => |failure| code: {
            try failure.write(stderr);
            try stderr.writeAll(cli.usage_text);
            break :code 2;
        },
        .run => |config| try execute(init.io, config, stdout, stderr),
    };

    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}
