//! tc002-berry-check: the vendored interpreter, linked for the device and asked to run one line.
//!
//! phase 1 has no berryd yet, so this is what proves the arm build and what the interpreter's size
//! on this target is measured from. it is a build step, not an installed part of the runtime, and
//! it touches nothing outside the process: no device node, no file, no property.
const std = @import("std");
const sys = @import("sys/linux.zig");
const berry = @import("berry/vm.zig");

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

var out_len: usize = 0;

fn collect(text: []const u8) void {
    out_len += text.len;
    _ = sys.write(1, text) catch {};
}

pub fn main() u8 {
    berry.sink = collect;
    var vm = berry.Vm.init() orelse {
        _ = sys.write(2, "berry: the vm would not start\n") catch {};
        return 1;
    };
    defer vm.deinit();

    const status = vm.run("check", "import string print(string.format('berry %s on the device', '6e6e621'))");
    if (status != .ok) {
        _ = sys.write(2, "berry: the check script failed: ") catch {};
        _ = sys.write(2, vm.errorText()) catch {};
        _ = sys.write(2, "\n") catch {};
        return 1;
    }
    if (out_len == 0) {
        _ = sys.write(2, "berry: the script ran but nothing reached the write seam\n") catch {};
        return 1;
    }
    return 0;
}
