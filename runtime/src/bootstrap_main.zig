//! libtc002-bootstrap.so: the shared object the vendor loader dlopens as its "startup library".
//! it has no libc and does exactly one thing: a constructor execs the supervisor at the path fixed
//! at build time, passing `--from-bootstrap` and the loader's environment through. it never sets
//! the anti-brick property; if the exec fails it writes one line to stderr and exits, so an absent
//! supervisor is never mistaken for a running one.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const supervisor_path: [:0]const u8 = build_options.supervisor_path ++ "";
const failure_message = "tc002-bootstrap: exec of supervisor failed\n";

const Envp = [*:null]?[*:0]const u8;

// the host process's environment: glibc/uclibc/musl export `environ`; macos needs _NSGetEnviron.
const linux_environ = if (builtin.os.tag == .linux) @extern(?*Envp, .{ .name = "environ", .linkage = .weak }) else null;
extern "c" fn _NSGetEnviron() *Envp;

fn environment() Envp {
    const empty: [0:null]?[*:0]const u8 = .{};
    if (builtin.os.tag == .linux) {
        if (linux_environ) |p| return p.*;
        return &empty;
    }
    if (builtin.os.tag == .macos) return _NSGetEnviron().*;
    return &empty;
}

fn bootstrap() callconv(.c) void {
    const argv = [_:null]?[*:0]const u8{ supervisor_path.ptr, "--from-bootstrap" };
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.execve(supervisor_path.ptr, &argv, environment());
        _ = std.os.linux.write(2, failure_message.ptr, failure_message.len);
        std.os.linux.exit_group(1);
    } else {
        _ = std.c.execve(supervisor_path.ptr, @ptrCast(&argv), @ptrCast(environment()));
        _ = std.c.write(2, failure_message.ptr, failure_message.len);
        std.c._exit(1);
    }
}

export const init_array linksection(if (builtin.os.tag == .macos) "__DATA,__mod_init_func" else ".init_array") = [_]*const fn () callconv(.c) void{&bootstrap};
