//! tc002-supervisor command-line options and the exact argv it hands the renderer. pure.
const std = @import("std");
const evdev = @import("../input/evdev.zig");

pub const usage =
    \\usage: tc002-supervisor [options]
    \\  --profile dev|hardened  dev leaves adbd alone; hardened resets persist.sys.zkdebug=0 at boot (dev)
    \\  --renderer PATH         candidate renderer (/tmp/tc002/tc002d)
    \\  --fallback PATH         fallback renderer after three failures in sixty seconds (same as --renderer)
    \\  --dir PATH              volatile runtime directory: binaries, log, lock (/tmp/tc002)
    \\  --state PATH            durable settings and credentials (/data/tc002/state); falls back to --dir
    \\  --lock PATH             panel lock file (/tmp/tc002/panel.lock)
    \\  --tz RULE               posix tz rule or iana zone name; the renderer gets the rule (UTC0)
    \\  --keymap L,M,R,K        keycodes for left, middle, right, knob (108,105,106,103)
    \\  --keys PATH             button evdev node (/dev/input/event67)
    \\  --knob PATH             rotary evdev node (/dev/input/event68)
    \\  --ip-poll S             seconds between wlan0 address checks (5)
    \\  --mcu PATH              pixel mcu serial port (/dev/ttyS1); --no-mcu disables the link
    \\  --mcu-baud N            serial speed (1500000, the vendor's value)
    \\  --mcu-poll S            seconds between battery/usb queries (30)
    \\  --no-property           do not set sys.zkapp.state (host-less experiments only)
    \\  --close-inherited       close every inherited descriptor above stderr after the audit
    \\  --stats                 ask the renderer for periodic statistics
    \\  --from-bootstrap        set by the bootstrap shared object; logged only
    \\  --help
    \\
;

pub const Profile = enum { dev, hardened };

pub const Config = struct {
    profile: Profile = .dev,
    renderer: [:0]const u8 = "/tmp/tc002/tc002d",
    fallback: ?[:0]const u8 = null,
    dir: [:0]const u8 = "/tmp/tc002",
    /// settings and credentials live here, on the persistent jffs2 partition, so they survive a
    /// power cycle. the layout under it matches the one under --dir, so falling back is a swap.
    state: [:0]const u8 = "/data/tc002/state",
    lock_path: [:0]const u8 = "/tmp/tc002/panel.lock",
    tz_rule: [:0]const u8 = "UTC0",
    keymap_text: [:0]const u8 = "108,105,106,103",
    keymap: evdev.KeyMap = .{},
    keys_path: [:0]const u8 = "/dev/input/event67",
    knob_path: [:0]const u8 = "/dev/input/event68",
    ip_poll_s: u32 = 5,
    mcu_path: [:0]const u8 = "/dev/ttyS1",
    mcu_baud: u32 = 1_500_000,
    mcu_poll_s: u32 = 30,
    no_mcu: bool = false,
    no_property: bool = false,
    close_inherited: bool = false,
    stats: bool = false,
    from_bootstrap: bool = false,

    pub fn fallbackPath(self: Config) [:0]const u8 {
        return self.fallback orelse self.renderer;
    }
};

pub const Outcome = union(enum) { run: Config, help };
pub const ParseError = error{ MissingValue, BadValue, UnknownOption };

pub fn parse(args: []const [:0]const u8) ParseError!Outcome {
    var c = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
        if (std.mem.eql(u8, a, "--no-property")) {
            c.no_property = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-mcu")) {
            c.no_mcu = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--close-inherited")) {
            c.close_inherited = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--stats")) {
            c.stats = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--from-bootstrap")) {
            c.from_bootstrap = true;
            continue;
        }
        const known = [_][]const u8{ "--profile", "--renderer", "--fallback", "--dir", "--state", "--lock", "--tz", "--keymap", "--keys", "--knob", "--ip-poll", "--mcu", "--mcu-baud", "--mcu-poll" };
        var is_known = false;
        for (known) |k| is_known = is_known or std.mem.eql(u8, a, k);
        if (!is_known) return error.UnknownOption;
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--profile")) {
            c.profile = if (std.mem.eql(u8, v, "dev")) .dev else if (std.mem.eql(u8, v, "hardened")) .hardened else return error.BadValue;
        } else if (std.mem.eql(u8, a, "--renderer")) {
            c.renderer = v;
        } else if (std.mem.eql(u8, a, "--fallback")) {
            c.fallback = v;
        } else if (std.mem.eql(u8, a, "--dir")) {
            c.dir = v;
        } else if (std.mem.eql(u8, a, "--state")) {
            c.state = v;
        } else if (std.mem.eql(u8, a, "--lock")) {
            c.lock_path = v;
        } else if (std.mem.eql(u8, a, "--tz")) {
            c.tz_rule = v;
        } else if (std.mem.eql(u8, a, "--keymap")) {
            c.keymap = evdev.parseKeyMap(v) catch return error.BadValue;
            c.keymap_text = v;
        } else if (std.mem.eql(u8, a, "--keys")) {
            c.keys_path = v;
        } else if (std.mem.eql(u8, a, "--knob")) {
            c.knob_path = v;
        } else if (std.mem.eql(u8, a, "--ip-poll")) {
            const n = std.fmt.parseInt(u32, v, 10) catch return error.BadValue;
            if (n < 1 or n > 3600) return error.BadValue;
            c.ip_poll_s = n;
        } else if (std.mem.eql(u8, a, "--mcu")) {
            c.mcu_path = v;
        } else if (std.mem.eql(u8, a, "--mcu-baud")) {
            const n = std.fmt.parseInt(u32, v, 10) catch return error.BadValue;
            if (n < 1200 or n > 4_000_000) return error.BadValue;
            c.mcu_baud = n;
        } else if (std.mem.eql(u8, a, "--mcu-poll")) {
            const n = std.fmt.parseInt(u32, v, 10) catch return error.BadValue;
            if (n < 5 or n > 3600) return error.BadValue;
            c.mcu_poll_s = n;
        }
    }
    return .{ .run = c };
}

pub const max_argv = 24;
pub const Argv = [max_argv:null]?[*:0]const u8;

/// the exact argv for a renderer spawn; fixed options, typed values, no shell.
pub fn spawnArgv(cfg: Config, path: [:0]const u8, epoch_text: [:0]const u8, out: *Argv) usize {
    var n: usize = 0;
    const fixed = [_][:0]const u8{ path, "--ipc-fd", "3", "--epoch", epoch_text, "--lock", cfg.lock_path, "--tz", cfg.tz_rule, "--keymap", cfg.keymap_text, "--keys", cfg.keys_path, "--knob", cfg.knob_path };
    for (fixed) |a| {
        out[n] = a.ptr;
        n += 1;
    }
    if (cfg.stats) {
        out[n] = "--stats";
        n += 1;
    }
    // our own renderer starts dark and is switched on once the saved state is in place; an
    // older fallback binary may not know the option
    if (std.mem.eql(u8, path, cfg.renderer)) {
        out[n] = "--start-dark";
        n += 1;
    }
    out[n] = null;
    return n;
}

test "defaults and fallback path" {
    const o = try parse(&.{});
    try std.testing.expectEqual(Profile.dev, o.run.profile);
    try std.testing.expectEqualStrings("/tmp/tc002/tc002d", o.run.fallbackPath());
    // settings and credentials default to the persistent partition, not the tmpfs one
    try std.testing.expectEqualStrings("/data/tc002/state", o.run.state);
    try std.testing.expectEqualStrings("/tmp/tc002", o.run.dir);
    const st = try parse(&.{ "--state", "/data/elsewhere", "--dir", "/tmp/x" });
    try std.testing.expectEqualStrings("/data/elsewhere", st.run.state);
    try std.testing.expectEqualStrings("/tmp/x", st.run.dir);
    const f = try parse(&.{ "--fallback", "/res/bin/tc002d", "--profile", "hardened", "--ip-poll", "30", "--from-bootstrap", "--close-inherited" });
    try std.testing.expectEqualStrings("/res/bin/tc002d", f.run.fallbackPath());
    try std.testing.expectEqual(Profile.hardened, f.run.profile);
    try std.testing.expectEqual(@as(u32, 30), f.run.ip_poll_s);
    try std.testing.expect(f.run.from_bootstrap and f.run.close_inherited);
    try std.testing.expectError(error.BadValue, parse(&.{ "--profile", "prod" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "--ip-poll", "0" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{"--renderer-path"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--tz"}));
    const m = try parse(&.{ "--mcu-baud", "115200", "--mcu-poll", "10", "--no-mcu" });
    try std.testing.expectEqual(@as(u32, 115200), m.run.mcu_baud);
    try std.testing.expectEqual(@as(u32, 10), m.run.mcu_poll_s);
    try std.testing.expect(m.run.no_mcu);
    try std.testing.expectError(error.BadValue, parse(&.{ "--mcu-poll", "1" }));
}

test "the renderer argv is exact" {
    const o = try parse(&.{ "--tz", "JST-9", "--keymap", "1,2,3,4", "--stats" });
    var argv: Argv = undefined;
    const n = spawnArgv(o.run, "/tmp/tc002/tc002d", "7", &argv);
    const expected = [_][]const u8{ "/tmp/tc002/tc002d", "--ipc-fd", "3", "--epoch", "7", "--lock", "/tmp/tc002/panel.lock", "--tz", "JST-9", "--keymap", "1,2,3,4", "--keys", "/dev/input/event67", "--knob", "/dev/input/event68", "--stats", "--start-dark" };
    try std.testing.expectEqual(expected.len, n);
    for (expected, 0..) |e, i| try std.testing.expectEqualStrings(e, std.mem.span(argv[i].?));
    try std.testing.expect(argv[n] == null);
}
