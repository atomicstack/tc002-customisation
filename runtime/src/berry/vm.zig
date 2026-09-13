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
const Arena = @import("arena.zig").Arena;

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

pub const Bvm = opaque {};

extern fn be_vm_new() ?*Bvm;
extern fn be_vm_delete(vm: *Bvm) void;
extern fn be_loadbuffer(vm: *Bvm, name: [*:0]const u8, buffer: [*]const u8, length: usize) c_int;
extern fn be_pcall(vm: *Bvm, argc: c_int) c_int;
extern fn be_pop(vm: *Bvm, n: c_int) void;
extern fn be_tostring(vm: *Bvm, index: c_int) [*:0]const u8;
/// installs the watchdog hook. it lives in vendor/berry/port/be_port.c because the hook is
/// variadic, which zig cannot define, and because its raise longjmps -- which must not cross a
/// zig frame.
extern fn tc002_berry_install_hook(vm: *Bvm) void;

// -- the seam

/// where berry's output goes. null discards it, which is what a vm with nothing attached should do
/// rather than crash.
pub var sink: ?*const fn (text: []const u8) void = null;

/// how many times berry has allocated through us
pub var alloc_calls: usize = 0;

/// the vm's whole heap. static, because this runtime has no allocator of its own and the point of
/// the exercise is that a script cannot reach past a bound we chose. `heapInit` decides how much
/// of it a given vm may actually use, so the `berry.heap_kb` setting can shrink the arena without
/// anything here needing to allocate.
pub const heap_max_bytes = 256 * 1024;
var heap_buf: [heap_max_bytes]u8 align(8) = undefined;
pub var arena: Arena = undefined;
var arena_ready = false;

/// give the vm a heap of `kb` kilobytes, clamped to what is reserved. call before `Vm.init`.
pub fn heapInit(kb: usize) void {
    const want = @min(kb * 1024, heap_max_bytes);
    arena = Arena.init(heap_buf[0..@max(want, 4096)]);
    arena_ready = true;
}

export fn tc002_berry_write(buffer: [*]const u8, length: usize) void {
    if (sink) |f| f(buffer[0..length]);
}

export fn tc002_berry_malloc(size: usize) ?*anyopaque {
    if (!arena_ready) heapInit(heap_max_bytes / 1024);
    alloc_calls += 1;
    return @ptrCast(arena.alloc(size));
}

export fn tc002_berry_free(ptr: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(ptr orelse return);
    arena.free(p);
}

export fn tc002_berry_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (!arena_ready) heapInit(heap_max_bytes / 1024);
    alloc_calls += 1;
    const p: ?[*]u8 = @ptrCast(ptr);
    // c's realloc is not told the old size; the arena's own header knows it, and copying the whole
    // old block is always safe because it is by definition what the caller was given
    const old = if (p) |q| arena.sizeOf(q) else 0;
    return @ptrCast(arena.realloc(p, old, size));
}

// -- the watchdog
//
// a script that loops forever is not a crash: the process stays healthy and simply stops coming
// back. berry's observability hook fires every 2^16 instructions (see berry_conf.h), which is about
// 7.8 ms at the 8.4M instructions/s measured on this device, so a deadline is enforced to within
// one sample of where it was set.

/// the host's clock. a function pointer rather than a direct call because this module is built for
/// the device and for the host test harness, and they do not share a clock.
pub var clock: ?*const fn () u64 = null;

/// when the running script must be stopped. zero disarms it.
pub var deadline_ns: u64 = 0;

/// how many scripts have been stopped for running too long
pub var stops: u32 = 0;

export fn tc002_berry_should_stop() c_int {
    if (deadline_ns == 0) return 0;
    const now = (clock orelse return 0)();
    if (now < deadline_ns) return 0;
    stops +|= 1;
    deadline_ns = 0; // disarm, so the raise this triggers is not itself interrupted
    return 1;
}

// -- the wrapper

pub const Vm = struct {
    handle: *Bvm,

    /// null when the interpreter could not start, which on this device means the arena refused
    pub fn init() ?Vm {
        const handle = be_vm_new() orelse return null;
        tc002_berry_install_hook(handle);
        return .{ .handle = handle };
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

    /// compile without running. this is what `PUT /berry/scripts/{name}` is checked with: a script
    /// that will not compile never reaches flash, and the client hears the parser's own words.
    pub fn compile(self: *Vm, name: []const u8, source: []const u8) Status {
        var name_buf: [64]u8 = undefined;
        const n = @min(name.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], name[0..n]);
        name_buf[n] = 0;
        const st: Status = @enumFromInt(be_loadbuffer(self.handle, @ptrCast(&name_buf), source.ptr, source.len));
        // a successful compile leaves the closure on the stack; nothing here wants it
        if (st == .ok) be_pop(self.handle, 1);
        return st;
    }

    /// run with a deadline: the watchdog raises inside the script once `budget_ns` has passed.
    /// needs `clock` installed, and silently behaves like `run` without one.
    pub fn runFor(self: *Vm, name: []const u8, source: []const u8, budget_ns: u64) Status {
        if (clock) |f| deadline_ns = f() + budget_ns;
        defer deadline_ns = 0;
        return self.run(name, source);
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
