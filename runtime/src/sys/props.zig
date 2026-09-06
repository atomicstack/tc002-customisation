//! a bounded invocation of the device's own /bin/setprop: fork, exec with an empty environment,
//! wait at most `timeout_ns`, kill on timeout. never reports success it did not observe.
const std = @import("std");
const sys = @import("linux.zig");

pub const Error = error{ SpawnFailed, SetpropFailed, Timeout };

pub const setprop_path: [:0]const u8 = "/bin/setprop";

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
