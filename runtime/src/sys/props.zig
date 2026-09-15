//! bounded invocations of the device's own /bin/setprop and /bin/getprop: fork, exec with an empty
//! environment, wait at most `timeout_ns`, kill on timeout. never reports success it did not
//! observe.
//!
//! properties go through the vendor's binaries rather than the property area directly: the runtime
//! links no libc, the area's layout is android's and undocumented here, and these two calls are
//! rare (one at startup, one per upgrade check) so the fork costs nothing worth saving.
const std = @import("std");
const sys = @import("linux.zig");

pub const Error = error{ SpawnFailed, SetpropFailed, GetpropFailed, Timeout };

pub const setprop_path: [:0]const u8 = "/bin/setprop";
pub const getprop_path: [:0]const u8 = "/bin/getprop";

pub fn set(name: [:0]const u8, value: [:0]const u8, timeout_ns: u64) Error!void {
    const pid = sys.fork() catch return error.SpawnFailed;
    if (pid == 0) {
        sys.unblockAllSignals();
        const argv = [_:null]?[*:0]const u8{ setprop_path.ptr, name.ptr, value.ptr };
        const envp = [_:null]?[*:0]const u8{};
        sys.execve(setprop_path.ptr, &argv, &envp) catch {};
        sys.exit(127);
    }
    const deadline = sys.monotonicNs() + timeout_ns;
    while (true) {
        const status = sys.waitNoHang(pid) catch return error.SetpropFailed;
        if (status) |st| {
            const exited_normally = (st & 0x7f) == 0;
            const code = (st >> 8) & 0xff;
            return if (exited_normally and code == 0) {} else error.SetpropFailed;
        }
        if (sys.monotonicNs() >= deadline) {
            sys.kill(pid, .KILL);
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                if ((sys.waitNoHang(pid) catch null) != null) break;
                sys.nanosleep(10_000_000);
            }
            return error.Timeout;
        }
        sys.nanosleep(10_000_000);
    }
}

/// the environment entry `getprop` needs to find the property area at all.
///
/// this is the android property workspace: `<fd>,<size>` naming an already-open descriptor onto
/// `/dev/__properties__`. `setprop` does not need it -- it talks to the property service over a
/// socket -- but a reader maps that area directly, so `getprop` under an empty environment prints
/// nothing and **exits 0**, which reads exactly like a property that is not set. that cost an hour.
pub const workspace_var = "ANDROID_PROPERTY_WORKSPACE";

/// read a property, into `out`. returns the value with surrounding whitespace removed; a property
/// that is not set reads as an empty slice, which is what `getprop` prints for one.
///
/// `workspace` is the caller's own `ANDROID_PROPERTY_WORKSPACE=...` entry, passed as the child's
/// entire environment: enough for getprop to find the area, and nothing else inherited.
pub fn get(name: [:0]const u8, out: []u8, timeout_ns: u64, workspace: ?[*:0]const u8) Error![]const u8 {
    const fds = sys.pipeNonblock() catch return error.SpawnFailed;
    const pid = sys.fork() catch {
        sys.close(fds[0]);
        sys.close(fds[1]);
        return error.SpawnFailed;
    };
    if (pid == 0) {
        sys.unblockAllSignals();
        sys.dup2(fds[1], 1) catch sys.exit(127);
        sys.close(fds[0]);
        sys.close(fds[1]);
        const argv = [_:null]?[*:0]const u8{ getprop_path.ptr, name.ptr };
        if (workspace) |w| {
            const envp = [_:null]?[*:0]const u8{w};
            sys.execve(getprop_path.ptr, &argv, &envp) catch {};
        } else {
            const envp = [_:null]?[*:0]const u8{};
            sys.execve(getprop_path.ptr, &argv, &envp) catch {};
        }
        sys.exit(127);
    }
    sys.close(fds[1]);
    defer sys.close(fds[0]);

    var n: usize = 0;
    var exited: ?u32 = null;
    const deadline = sys.monotonicNs() + timeout_ns;
    while (true) {
        var drained = false;
        while (n < out.len) {
            const got = sys.read(fds[0], out[n..]) catch |e| switch (e) {
                error.WouldBlock => break,
                error.Interrupted => continue,
                else => return error.GetpropFailed,
            };
            if (got == 0) {
                drained = true; // the child closed its end: everything it printed is here
                break;
            }
            n += got;
        }
        if (exited == null) exited = sys.waitNoHang(pid) catch return error.GetpropFailed;
        // only stop once the pipe is drained as well as the child reaped, or a fast reader would
        // return the value truncated at whatever had arrived first
        if (drained and exited != null) break;
        if (n == out.len and exited != null) break;
        if (sys.monotonicNs() >= deadline) {
            sys.kill(pid, .KILL);
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                if ((sys.waitNoHang(pid) catch null) != null) break;
                sys.nanosleep(10_000_000);
            }
            return error.Timeout;
        }
        if (!drained) sys.nanosleep(2_000_000);
    }
    const st = exited orelse return error.GetpropFailed;
    const exited_normally = (st & 0x7f) == 0;
    const code = (st >> 8) & 0xff;
    if (!exited_normally or code != 0) return error.GetpropFailed;
    return std.mem.trim(u8, out[0..n], " \t\r\n");
}

/// find the caller's own `ANDROID_PROPERTY_WORKSPACE=...` entry in an environment block, to hand to
/// a child that has to read a property.
///
/// the supervisor spawns every child with an empty environment on purpose, and for five of the six
/// that is right: they read properties through the supervisor or not at all. the bring-up script is
/// the exception -- it asks init whether `wpa_supplicant` is running -- and an empty environment
/// makes that question return **empty and exit 0**, which reads exactly like "not running".
/// a null entry ends the block rather than being skipped: this is a NULL-terminated environment
/// vector, and scanning past the terminator reads whatever the slice happens to cover.
pub fn findWorkspace(environ: anytype) ?[*:0]const u8 {
    for (environ) |maybe| {
        const entry = maybe orelse return null;
        const text = std.mem.span(entry);
        if (std.mem.startsWith(u8, text, workspace_var ++ "=")) return entry;
    }
    return null;
}

test "the property workspace is found by name, not by position" {
    const a: [:0]const u8 = "PATH=/bin";
    const b: [:0]const u8 = "ANDROID_PROPERTY_WORKSPACE=8,32768";
    const c: [:0]const u8 = "HOME=/";
    // a name that merely starts the same must not match: the entry is handed to a child verbatim
    const d: [:0]const u8 = "ANDROID_PROPERTY_WORKSPACE_EXTRA=no";

    const with = [_]?[*:0]const u8{ a.ptr, d.ptr, b.ptr, c.ptr };
    const found = findWorkspace(&with) orelse return error.TestExpectedWorkspace;
    try std.testing.expectEqualStrings(b, std.mem.span(found));

    const without = [_]?[*:0]const u8{ a.ptr, d.ptr, c.ptr };
    try std.testing.expect(findWorkspace(&without) == null);

    // the terminator ends the scan: anything past it is not part of the environment
    const past_end = [_]?[*:0]const u8{ a.ptr, null, b.ptr };
    try std.testing.expect(findWorkspace(&past_end) == null);

    const empty = [_]?[*:0]const u8{};
    try std.testing.expect(findWorkspace(&empty) == null);
}
