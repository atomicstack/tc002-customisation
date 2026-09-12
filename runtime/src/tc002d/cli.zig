//! tc002d command-line options. pure so the parser is host-tested; the process reads
//! `std.os.argv` and hands the slice in.
const std = @import("std");
const evdev = @import("../input/evdev.zig");
const arbiter = @import("../scene/arbiter.zig");
const scene = @import("../scene/scene.zig");

pub const usage =
    \\usage: tc002d [options]
    \\  --ipc-fd N          supervisor channel (SOCK_SEQPACKET); omit for standalone runs
    \\  --epoch N           renderer epoch given by the supervisor (1)
    \\  --lock PATH         panel lock file (/tmp/tc002/panel.lock); created if standalone
    \\  --spi PATH          spidev node (/dev/spidev0.0)
    \\  --gpio PATH         latch gpio value file (/sys/class/gpio/gpio35/value)
    \\  --keys PATH         button evdev node (/dev/input/event67)
    \\  --knob PATH         rotary evdev node (/dev/input/event68)
    \\  --keymap L,M,R,K    keycodes for left, middle, right, knob (108,105,106,103)
    \\  --tz RULE           posix tz rule for the clock (UTC0)
    \\  --base clock|art|canvas  initial base scene (clock)
    \\  --generator N       initial art generator index (0)
    \\  --seed N            art seed, 0 = from the clock (0)
    \\  --brightness N      1..100 (100)
    \\  --seconds S         stop after s seconds, 0 = run until stopped (0)
    \\  --crossfade-ms N    default transition, a cross-fade, 0..5000 ms, 0 = none (500)
    \\  --power-fade-ms N   fade to and from black on power changes, 0..5000 (600)
    \\  --dry-run           never open spidev/gpio; model the panel only
    \\  --stats             log achieved cadence every 5 s
    \\  --start-dark        keep the panel dark until a power-on command: the supervisor uses it so
    \\                      the saved scene fades in instead of the built-in default showing first
    \\  --help
    \\
;

pub const Config = struct {
    ipc_fd: ?i32 = null,
    epoch: u32 = 1,
    lock_path: [:0]const u8 = "/tmp/tc002/panel.lock",
    spi_path: [:0]const u8 = "/dev/spidev0.0",
    gpio_path: [:0]const u8 = "/sys/class/gpio/gpio35/value",
    keys_path: [:0]const u8 = "/dev/input/event67",
    knob_path: [:0]const u8 = "/dev/input/event68",
    keymap: evdev.KeyMap = .{},
    tz_rule: [:0]const u8 = "UTC0",
    // the clock, not art: the fallback slot is spawned without --start-dark, so this default
    // is what a cold start shows before the supervisor pushes the saved scene
    base: arbiter.Base = .clock,
    generator: scene.Generator = .popsquares,
    seed: u32 = 0,
    brightness: u8 = 100,
    seconds: u32 = 0,
    crossfade_ms: u32 = 500,
    power_fade_ms: u32 = 600,
    dry_run: bool = false,
    stats: bool = false,
    start_dark: bool = false,
};

pub const Outcome = union(enum) { run: Config, help, failure: [:0]const u8 };

pub const ParseError = error{ MissingValue, BadValue, UnknownOption };

fn parseU32(text: []const u8, lo: u32, hi: u32) ParseError!u32 {
    const v = std.fmt.parseInt(u32, text, 10) catch return error.BadValue;
    if (v < lo or v > hi) return error.BadValue;
    return v;
}

/// parse argv[1..]; every value is validated here so main only deals with a typed config.
pub fn parse(args: []const [:0]const u8) ParseError!Outcome {
    var c = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
        if (std.mem.eql(u8, a, "--dry-run")) {
            c.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--start-dark")) {
            c.start_dark = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--stats")) {
            c.stats = true;
            continue;
        }
        const known = [_][]const u8{ "--ipc-fd", "--epoch", "--lock", "--spi", "--gpio", "--keys", "--knob", "--keymap", "--tz", "--base", "--generator", "--seed", "--brightness", "--seconds", "--crossfade-ms", "--power-fade-ms" };
        var is_known = false;
        for (known) |k| is_known = is_known or std.mem.eql(u8, a, k);
        if (!is_known) return error.UnknownOption;
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--ipc-fd")) {
            c.ipc_fd = @intCast(try parseU32(v, 3, 1023));
        } else if (std.mem.eql(u8, a, "--epoch")) {
            c.epoch = try parseU32(v, 1, std.math.maxInt(u32));
        } else if (std.mem.eql(u8, a, "--lock")) {
            c.lock_path = v;
        } else if (std.mem.eql(u8, a, "--spi")) {
            c.spi_path = v;
        } else if (std.mem.eql(u8, a, "--gpio")) {
            c.gpio_path = v;
        } else if (std.mem.eql(u8, a, "--keys")) {
            c.keys_path = v;
        } else if (std.mem.eql(u8, a, "--knob")) {
            c.knob_path = v;
        } else if (std.mem.eql(u8, a, "--keymap")) {
            c.keymap = evdev.parseKeyMap(v) catch return error.BadValue;
        } else if (std.mem.eql(u8, a, "--tz")) {
            c.tz_rule = v;
        } else if (std.mem.eql(u8, a, "--base")) {
            c.base = if (std.mem.eql(u8, v, "clock")) .clock else if (std.mem.eql(u8, v, "art")) .art else if (std.mem.eql(u8, v, "canvas")) .canvas else return error.BadValue;
        } else if (std.mem.eql(u8, a, "--generator")) {
            c.generator = @enumFromInt(try parseU32(v, 0, scene.generator_count - 1));
        } else if (std.mem.eql(u8, a, "--seed")) {
            c.seed = try parseU32(v, 0, std.math.maxInt(u32));
        } else if (std.mem.eql(u8, a, "--brightness")) {
            c.brightness = @intCast(try parseU32(v, 1, 100));
        } else if (std.mem.eql(u8, a, "--seconds")) {
            c.seconds = try parseU32(v, 0, 10_000_000);
        } else if (std.mem.eql(u8, a, "--crossfade-ms")) {
            c.crossfade_ms = try parseU32(v, 0, 5000);
        } else if (std.mem.eql(u8, a, "--power-fade-ms")) {
            c.power_fade_ms = try parseU32(v, 0, 5000);
        } else {
            return error.UnknownOption;
        }
    }
    return .{ .run = c };
}

test "defaults" {
    const o = try parse(&.{});
    try std.testing.expectEqual(@as(?i32, null), o.run.ipc_fd);
    try std.testing.expectEqual(@as(u8, 100), o.run.brightness);
    try std.testing.expectEqual(arbiter.Base.clock, o.run.base);
    try std.testing.expectEqualStrings("UTC0", o.run.tz_rule);
}

test "options are typed and validated" {
    const o = try parse(&.{ "--ipc-fd", "3", "--epoch", "7", "--base", "clock", "--generator", "1", "--keymap", "1,2,3,4", "--brightness", "40", "--dry-run", "--seconds", "20", "--tz", "JST-9" });
    try std.testing.expectEqual(@as(?i32, 3), o.run.ipc_fd);
    try std.testing.expectEqual(@as(u32, 7), o.run.epoch);
    try std.testing.expectEqual(arbiter.Base.clock, o.run.base);
    try std.testing.expectEqual(scene.Generator.plasma, o.run.generator);
    try std.testing.expectEqual(@as(u16, 4), o.run.keymap.knob);
    try std.testing.expectEqual(@as(u8, 40), o.run.brightness);
    try std.testing.expect(o.run.dry_run);
    try std.testing.expectEqual(@as(u32, 20), o.run.seconds);
    try std.testing.expectEqualStrings("JST-9", o.run.tz_rule);
    try std.testing.expect((try parse(&.{"--help"})) == .help);
    try std.testing.expectError(error.MissingValue, parse(&.{"--seed"}));
    try std.testing.expectError(error.BadValue, parse(&.{ "--brightness", "0" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "--base", "moon" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "--generator", "9" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{"--bogus"}));
    const d = try parse(&.{"--start-dark"});
    try std.testing.expect(d.run.start_dark);
    const f = try parse(&.{ "--crossfade-ms", "0", "--power-fade-ms", "1000" });
    try std.testing.expectEqual(@as(u32, 0), f.run.crossfade_ms);
    try std.testing.expectEqual(@as(u32, 1000), f.run.power_fade_ms);
    try std.testing.expectError(error.BadValue, parse(&.{ "--crossfade-ms", "5001" }));
}
