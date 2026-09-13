//! the zig side of the vendored berry interpreter.
//!
//! berry asks its host for two things: somewhere to put output, and an allocator. both are extern
//! symbols exported here, so the vendored c never learns whether it is running under the fixture
//! harness or under berryd. phase 2 replaces the bodies -- output goes to the log ring, allocation
//! to a fixed arena -- without touching vendor/.
//!
//! this module is deliberately not reachable from src/root.zig: the aggregator's tests are pure
//! zig and must not start requiring a c toolchain. `zig build test-berry` is where this is
//! exercised.
const std = @import("std");

/// berry's `berrorcode`, which every entry point returns
pub const Status = enum(c_int) {
    ok = 0,
    exit = 1,
    malloc_fail = 2,
    exception = 3,
    syntax_error = 4,
    exec_error = 5,
    io_error = 6,
    _,
};

const Bvm = opaque {};

extern fn be_vm_new() ?*Bvm;
extern fn be_vm_delete(vm: *Bvm) void;
extern fn be_loadbuffer(vm: *Bvm, name: [*:0]const u8, buffer: [*]const u8, length: usize) c_int;
extern fn be_pcall(vm: *Bvm, argc: c_int) c_int;
extern fn be_pop(vm: *Bvm, n: c_int) void;
extern fn be_tostring(vm: *Bvm, index: c_int) [*:0]const u8;

// -- the seam

/// where berry's output goes. null discards it, which is what a vm with nothing attached should do
/// rather than crash.
pub var sink: ?*const fn (text: []const u8) void = null;

/// how many times berry has allocated through us. phase 1 only proves the seam is wired; phase 2's
/// arena owns the byte accounting, because free() here is not told the size and an arena knows its
/// own high-water mark anyway.
pub var alloc_calls: usize = 0;

export fn tc002_berry_write(buffer: [*]const u8, length: usize) void {
    if (sink) |f| f(buffer[0..length]);
}

export fn tc002_berry_malloc(size: usize) ?*anyopaque {
    alloc_calls += 1;
    return std.c.malloc(size);
}

export fn tc002_berry_free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

export fn tc002_berry_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    alloc_calls += 1;
    return std.c.realloc(ptr, size);
}

// -- the wrapper

pub const Vm = struct {
    handle: *Bvm,

    /// null when the interpreter could not start, which on this device means the allocator refused
    pub fn init() ?Vm {
        return .{ .handle = be_vm_new() orelse return null };
    }

    pub fn deinit(self: *Vm) void {
        be_vm_delete(self.handle);
    }

    /// compile and run one source buffer. `name` is what appears in a traceback; it is truncated
    /// rather than rejected, because a fixture's filename is not worth failing a run over.
    pub fn run(self: *Vm, name: []const u8, source: []const u8) Status {
        var name_buf: [64]u8 = undefined;
        const n = @min(name.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], name[0..n]);
        name_buf[n] = 0;
        const loaded: Status = @enumFromInt(be_loadbuffer(self.handle, @ptrCast(&name_buf), source.ptr, source.len));
        if (loaded != .ok) return loaded;
        return @enumFromInt(be_pcall(self.handle, 0));
    }

    /// the message berry left on the stack after a failed `run`. only meaningful straight after one.
    pub fn errorText(self: *Vm) []const u8 {
        return std.mem.span(be_tostring(self.handle, -1));
    }

    /// drop what a failed call left behind, so the vm can be used again
    pub fn clearError(self: *Vm) void {
        be_pop(self.handle, 2);
    }
};
