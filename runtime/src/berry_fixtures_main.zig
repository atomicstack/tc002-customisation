//! runs every .be fixture in a directory through the vendored interpreter, on the host.
//!
//! a fixture passes when it loads and runs without raising — berry's own `assert` is what the
//! fixtures use. two conventions:
//!
//!   name.fail.be    must FAIL. this is the harness testing itself: a harness that cannot detect a
//!                   failing script is worse than none, because it reports success forever.
//!   name.expected   when present beside name.be, the text the fixture must print, exactly.
//!
//! this is the only place the vendored c is exercised by `zig build`. `src/root.zig` deliberately
//! cannot reach it, so `zig build test` stays pure zig and needs no c toolchain.
const std = @import("std");
const berry = @import("berry/vm.zig");

/// what the fixture under test printed. a fixed buffer rather than a list: the sink is a bare
/// function pointer with nowhere to carry an allocator, and a fixture that prints more than this
/// is a fixture with a bug.
var capture_buf: [16 * 1024]u8 = undefined;
var capture_len: usize = 0;

fn collect(text: []const u8) void {
    const room = capture_buf.len - capture_len;
    const n = @min(text.len, room);
    @memcpy(capture_buf[capture_len..][0..n], text[0..n]);
    capture_len += n;
}

fn captured() []const u8 {
    return capture_buf[0..capture_len];
}

/// a deterministic clock: every reading is one millisecond after the last.
///
/// the watchdog is only ever asked the time from inside berry's observability hook, which fires
/// every 65,536 instructions, so "a millisecond per reading" makes the budget below mean "stop
/// after about fifty hook visits". that is worth more than a wall clock here: the test cannot
/// flake on a loaded machine, and it cannot pass by accident on a fast one. a fixture that never
/// reaches the hook never advances this clock at all, so it can never be stopped by it.
/// berryd uses the real monotonic clock; what is under test is the deadline, not the clock.
var fake_now_ns: u64 = 0;

fn steppingClock() u64 {
    fake_now_ns += std.time.ns_per_ms;
    return fake_now_ns;
}

const fixture_budget_ns: u64 = 50 * std.time.ns_per_ms;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = init.minimal.args.iterate();
    _ = args.next(); // argv[0]
    const dir_path = args.next() orelse {
        std.debug.print("usage: berry-fixtures <directory of .be files>\n", .{});
        std.process.exit(2);
    };

    berry.sink = collect;
    berry.clock = steppingClock;
    berry.heapInit(256);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".be")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var failed: usize = 0;
    for (names.items) |name| {
        const must_fail = std.mem.endsWith(u8, name, ".fail.be");
        const source = try dir.readFileAlloc(io, name, arena, .limited(64 * 1024));

        capture_len = 0;
        const before = berry.alloc_calls;

        var vm = berry.Vm.init() orelse {
            std.debug.print("  {s}: the vm would not start\n", .{name});
            failed += 1;
            continue;
        };
        const status = vm.runFor(name, source, fixture_budget_ns);
        const message = if (status != .ok) vm.errorText() else "";

        if (must_fail) {
            if (status == .ok) {
                std.debug.print("  {s}: PASSED, but the name says it must fail\n", .{name});
                failed += 1;
            } else {
                std.debug.print("  {s}: failed as it should ({s})\n", .{ name, message });
            }
        } else if (status != .ok) {
            std.debug.print("  {s}: {s}\n", .{ name, message });
            if (capture_len > 0) std.debug.print("    output: {s}\n", .{captured()});
            failed += 1;
        } else if (try expectationFor(io, arena, dir, name)) |expected| {
            if (!std.mem.eql(u8, expected, captured())) {
                std.debug.print("  {s}: printed \"{s}\", expected \"{s}\"\n", .{ name, captured(), expected });
                failed += 1;
            } else {
                std.debug.print("  {s}: ok, output matched\n", .{name});
            }
        } else {
            std.debug.print("  {s}: ok\n", .{name});
        }

        // a run that allocated nothing did not reach the interpreter at all
        if (berry.alloc_calls == before) {
            std.debug.print("  {s}: ran without allocating through the seam, which cannot happen\n", .{name});
            failed += 1;
        }
        vm.deinit();
    }

    std.debug.print("{d} fixture(s), {d} failure(s); arena high water {d} of {d} bytes, {d} script(s) stopped for running too long\n", .{
        names.items.len,
        failed,
        berry.arena.high_water,
        berry.arena.buf.len,
        berry.stops,
    });
    if (failed != 0) std.process.exit(1);
}

/// the `.expected` file beside a fixture, when there is one
fn expectationFor(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !?[]const u8 {
    const stem = name[0 .. name.len - 3];
    const path = try std.fmt.allocPrint(arena, "{s}.expected", .{stem});
    return dir.readFileAlloc(io, path, arena, .limited(8 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}
