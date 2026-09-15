//! tc002-supervisor command-line options and the exact argv it hands the renderer. pure.
const std = @import("std");
const evdev = @import("../input/evdev.zig");

pub const usage =
    \\usage: tc002-supervisor [options]
    \\  --profile dev|hardened  dev leaves adbd alone; hardened resets persist.sys.zkdebug=0 at boot (dev)
    \\  --bin-dir PATH          where this runtime's own binaries are (the build's -Dbin_dir)
    \\  --renderer PATH         candidate renderer (<bin-dir>/tc002d)
    \\  --fallback PATH         fallback renderer after three failures in sixty seconds (same as --renderer)
    \\  --dir PATH              writable runtime directory: log, lock, pidfiles (/tmp/tc002)
    \\  --state PATH            durable settings and credentials (/data/tc002/state); falls back to --dir
    \\  --lock PATH             panel lock file (<dir>/panel.lock)
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
    \\  --rt-priority N         run the renderer at SCHED_FIFO N (1..99); 0 leaves it normal
    \\  --netup-dir DIR         bring wifi up ourselves, using busybox and the scripts in DIR
    \\                          (the build's -Dnetup picks the default; empty means do not)
    \\  --from-bootstrap        set by the bootstrap shared object; logged only
    \\  --help
    \\
;

pub const Profile = enum { dev, hardened };

pub const Config = struct {
    profile: Profile = .dev,
    /// where this runtime's own binaries are. null means "whatever the build compiled in": a
    /// flashed supervisor is exec'd by the bootstrap with only `--from-bootstrap`, so it never
    /// sees an argument and the compiled-in value is the only one it will ever have.
    bin_dir: ?[:0]const u8 = null,
    /// null: `<bin_dir>/tc002d`. naming one binary must not move the other four.
    renderer: ?[:0]const u8 = null,
    fallback: ?[:0]const u8 = null,
    /// the **writable** runtime directory: the log, the panel lock, udhcpc's pidfile. deliberately
    /// not `bin_dir` -- on a flashed install the binaries sit on a read-only squashfs, and while
    /// these were one option a runtime on /res would have tried to write its log into flash.
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
    /// SCHED_FIFO priority for the renderer, 0 to leave it on the normal scheduler.
    rt_priority: u8 = 0,
    /// where busybox and the boot scripts live, for a runtime that has to bring wifi up itself.
    /// empty means the loader already did it, which is true of every /tmp install. null defers to
    /// the build (-Dnetup), which is how a flashed image turns it on without an argument.
    netup_dir: ?[:0]const u8 = null,
    from_bootstrap: bool = false,

};

/// the longest path the supervisor will build for one of its own binaries. bounded because these
/// are static buffers, and generous for the two installs that exist (/tmp/tc002 and /res/bin).
pub const path_max = 192;

/// one buffer per binary. it has to outlive the `Paths` that points into it.
pub const Buffers = struct {
    renderer: [path_max]u8 = undefined,
    netd: [path_max]u8 = undefined,
    ntfy: [path_max]u8 = undefined,
    audiod: [path_max]u8 = undefined,
    berryd: [path_max]u8 = undefined,
};

/// what the build compiled in. not a convenience: a flashed runtime is handed no arguments at all,
/// so these are the only values it will ever see.
pub const Defaults = struct {
    bin_dir: [:0]const u8,
    netup_dir: [:0]const u8,
};

/// every path that hangs off the binary directory, resolved in one place.
pub const Paths = struct {
    bin_dir: [:0]const u8,
    renderer: [:0]const u8,
    fallback: [:0]const u8,
    netd: [:0]const u8,
    ntfy: [:0]const u8,
    audiod: [:0]const u8,
    berryd: [:0]const u8,
    netup_dir: [:0]const u8,
};

pub const ResolveError = error{NameTooLong};

/// refused rather than truncated: a truncated exec path is a binary that silently is not there,
/// and the supervisor would report it as a child that would not start.
fn joinZ(buf: []u8, dir: []const u8, name: []const u8) ResolveError![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch error.NameTooLong;
}

pub fn resolve(cfg: Config, defaults: Defaults, buf: *Buffers) ResolveError!Paths {
    const dir = cfg.bin_dir orelse defaults.bin_dir;
    const renderer = cfg.renderer orelse try joinZ(&buf.renderer, dir, "tc002d");
    return .{
        .bin_dir = dir,
        .renderer = renderer,
        .fallback = cfg.fallback orelse renderer,
        .netd = try joinZ(&buf.netd, dir, "tc002-netd"),
        .ntfy = try joinZ(&buf.ntfy, dir, "tc002-ntfy"),
        .audiod = try joinZ(&buf.audiod, dir, "tc002-audiod"),
        .berryd = try joinZ(&buf.berryd, dir, "tc002-berryd"),
        .netup_dir = cfg.netup_dir orelse defaults.netup_dir,
    };
}

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
        if (std.mem.eql(u8, a, "--rt-priority")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            c.rt_priority = std.fmt.parseInt(u8, args[i], 10) catch return error.BadValue;
            if (c.rt_priority > 99) return error.BadValue;
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
        const known = [_][]const u8{ "--profile", "--bin-dir", "--renderer", "--fallback", "--dir", "--state", "--lock", "--tz", "--keymap", "--keys", "--knob", "--ip-poll", "--mcu", "--mcu-baud", "--mcu-poll", "--netup-dir" };
        var is_known = false;
        for (known) |k| is_known = is_known or std.mem.eql(u8, a, k);
        if (!is_known) return error.UnknownOption;
        if (i + 1 >= args.len) return error.MissingValue;
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--profile")) {
            c.profile = if (std.mem.eql(u8, v, "dev")) .dev else if (std.mem.eql(u8, v, "hardened")) .hardened else return error.BadValue;
        } else if (std.mem.eql(u8, a, "--bin-dir")) {
            c.bin_dir = v;
        } else if (std.mem.eql(u8, a, "--renderer")) {
            c.renderer = v;
        } else if (std.mem.eql(u8, a, "--fallback")) {
            c.fallback = v;
        } else if (std.mem.eql(u8, a, "--dir")) {
            c.dir = v;
        } else if (std.mem.eql(u8, a, "--netup-dir")) {
            c.netup_dir = v;
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
pub fn spawnArgv(cfg: Config, path: [:0]const u8, renderer: [:0]const u8, epoch_text: [:0]const u8, out: *Argv) usize {
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
    if (std.mem.eql(u8, path, renderer)) {
        out[n] = "--start-dark";
        n += 1;
    }
    out[n] = null;
    return n;
}

test "defaults and fallback path" {
    var buf: Buffers = .{};
    const tmp = Defaults{ .bin_dir = "/tmp/tc002", .netup_dir = "" };
    const o = try parse(&.{});
    try std.testing.expectEqual(Profile.dev, o.run.profile);
    try std.testing.expectEqualStrings("/tmp/tc002/tc002d", (try resolve(o.run, tmp, &buf)).fallback);
    // settings and credentials default to the persistent partition, not the tmpfs one
    try std.testing.expectEqualStrings("/data/tc002/state", o.run.state);
    try std.testing.expectEqualStrings("/tmp/tc002", o.run.dir);
    const st = try parse(&.{ "--state", "/data/elsewhere", "--dir", "/tmp/x" });
    try std.testing.expectEqualStrings("/data/elsewhere", st.run.state);
    try std.testing.expectEqualStrings("/tmp/x", st.run.dir);
    const f = try parse(&.{ "--fallback", "/res/bin/tc002d", "--profile", "hardened", "--ip-poll", "30", "--from-bootstrap", "--close-inherited" });
    try std.testing.expectEqualStrings("/res/bin/tc002d", (try resolve(f.run, tmp, &buf)).fallback);
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
    const n = spawnArgv(o.run, "/tmp/tc002/tc002d", "/tmp/tc002/tc002d", "7", &argv);
    const expected = [_][]const u8{ "/tmp/tc002/tc002d", "--ipc-fd", "3", "--epoch", "7", "--lock", "/tmp/tc002/panel.lock", "--tz", "JST-9", "--keymap", "1,2,3,4", "--keys", "/dev/input/event67", "--knob", "/dev/input/event68", "--stats", "--start-dark" };
    try std.testing.expectEqual(expected.len, n);
    for (expected, 0..) |e, i| try std.testing.expectEqualStrings(e, std.mem.span(argv[i].?));
    try std.testing.expect(argv[n] == null);
}

test "every binary follows the binary directory" {
    // the defect this replaces: netd and ntfy were built from `--dir` at startup while audiod and
    // berryd kept their compiled-in `/tmp/tc002` defaults, so `--dir` moved two of the four and
    // silently left the others behind. all five come from one place now, and this is that place.
    var buf: Buffers = .{};
    const res = Defaults{ .bin_dir = "/res/bin", .netup_dir = "/res/bin" };
    const o = try parse(&.{});
    const p = try resolve(o.run, res, &buf);
    try std.testing.expectEqualStrings("/res/bin", p.bin_dir);
    try std.testing.expectEqualStrings("/res/bin/tc002d", p.renderer);
    try std.testing.expectEqualStrings("/res/bin/tc002d", p.fallback);
    try std.testing.expectEqualStrings("/res/bin/tc002-netd", p.netd);
    try std.testing.expectEqualStrings("/res/bin/tc002-ntfy", p.ntfy);
    try std.testing.expectEqualStrings("/res/bin/tc002-audiod", p.audiod);
    try std.testing.expectEqualStrings("/res/bin/tc002-berryd", p.berryd);

    // --bin-dir beats the build's compiled-in default
    const c = try parse(&.{ "--bin-dir", "/tmp/x" });
    const q = try resolve(c.run, res, &buf);
    try std.testing.expectEqualStrings("/tmp/x/tc002-audiod", q.audiod);
    try std.testing.expectEqualStrings("/tmp/x/tc002d", q.renderer);

    // --renderer names one binary without moving the other four
    const r = try parse(&.{ "--bin-dir", "/tmp/x", "--renderer", "/tmp/new/tc002d" });
    const s = try resolve(r.run, res, &buf);
    try std.testing.expectEqualStrings("/tmp/new/tc002d", s.renderer);
    try std.testing.expectEqualStrings("/tmp/x/tc002-netd", s.netd);
    // and the fallback still follows the renderer unless it is named too
    try std.testing.expectEqualStrings("/tmp/new/tc002d", s.fallback);
    const tmp = Defaults{ .bin_dir = "/tmp/tc002", .netup_dir = "" };
    const t = try resolve((try parse(&.{ "--fallback", "/res/bin/tc002d" })).run, tmp, &buf);
    try std.testing.expectEqualStrings("/res/bin/tc002d", t.fallback);
    try std.testing.expectEqualStrings("/tmp/tc002/tc002d", t.renderer);

    // a directory that cannot hold the longest name is refused rather than truncated: a truncated
    // exec path is a binary that silently is not there
    var long: [path_max - 8:0]u8 = undefined;
    @memset(&long, 'a');
    long[0] = '/';
    long[long.len] = 0;
    var over = Config{ .bin_dir = &long };
    try std.testing.expectError(error.NameTooLong, resolve(over, res, &buf));
    over.renderer = "/tmp/tc002/tc002d"; // naming the renderer does not rescue the other four
    try std.testing.expectError(error.NameTooLong, resolve(over, res, &buf));

    // -Dnetup is what turns bring-up on for a flashed image; a /tmp build leaves it off, and
    // `--netup-dir` still beats both
    try std.testing.expectEqualStrings("/res/bin", p.netup_dir);
    try std.testing.expectEqualStrings("", t.netup_dir);
    const nu = try resolve((try parse(&.{ "--netup-dir", "/tmp/boot" })).run, res, &buf);
    try std.testing.expectEqualStrings("/tmp/boot", nu.netup_dir);
}
