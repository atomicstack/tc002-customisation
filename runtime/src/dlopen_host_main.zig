//! host tool for the bootstrap test: dlopen the given library. if its constructor execs the
//! configured supervisor, this process is replaced and the exit code is the supervisor's; if the
//! constructor returns, exit 7.
const std = @import("std");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
const rtld_now: c_int = 2;

pub fn main(init: std.process.Init.Minimal) u8 {
    const raw = init.args.vector;
    if (raw.len < 2) {
        std.debug.print("usage: dlopen-host <library>\n", .{});
        return 2;
    }
    if (dlopen(raw[1], rtld_now) == null) {
        std.debug.print("dlopen failed for {s}\n", .{raw[1]});
        return 5;
    }
    std.debug.print("the constructor returned instead of exec'ing\n", .{});
    return 7;
}
