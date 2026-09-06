//! host tool: asserts the built bootstrap is what the vendor loader can dlopen and nothing more —
//! an elf32 little-endian arm shared object with no DT_NEEDED entries and a non-empty init array.
const std = @import("std");

var file_buf: [256 * 1024]u8 = undefined;

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("elfcheck: " ++ fmt ++ "\n", args);
    return 1;
}

fn u16At(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const raw = init.args.vector;
    if (raw.len < 2) return fail("usage: elfcheck <libtc002-bootstrap.so>", .{});
    const path = raw[1];
    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(path), .{ .ACCMODE = .RDONLY }, 0) catch |e| return fail("cannot open {s}: {s}", .{ path, @errorName(e) });
    var len: usize = 0;
    while (len < file_buf.len) {
        const n = std.posix.read(fd, file_buf[len..]) catch |e| return fail("read failed: {s}", .{@errorName(e)});
        if (n == 0) break;
        len += n;
    }
    const b = file_buf[0..len];
    if (len < 52) return fail("too short for an elf32 header", .{});
    if (!std.mem.eql(u8, b[0..4], "\x7fELF")) return fail("not an elf file", .{});
    if (b[4] != 1) return fail("not elf32 (class {d})", .{b[4]});
    if (b[5] != 1) return fail("not little-endian", .{});
    const e_type = u16At(b, 16);
    const e_machine = u16At(b, 18);
    if (e_type != 3) return fail("not et_dyn (type {d})", .{e_type});
    if (e_machine != 40) return fail("not arm (machine {d})", .{e_machine});
    const phoff = u32At(b, 28);
    const phentsize = u16At(b, 42);
    const phnum = u16At(b, 44);
    var dyn_off: ?usize = null;
    var dyn_size: usize = 0;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsize;
        if (ph + 32 > len) return fail("program header {d} out of range", .{i});
        if (u32At(b, ph) == 2) { // PT_DYNAMIC
            dyn_off = u32At(b, ph + 4);
            dyn_size = u32At(b, ph + 16);
        }
    }
    const off = dyn_off orelse return fail("no pt_dynamic segment", .{});
    if (off + dyn_size > len) return fail("dynamic segment out of range", .{});
    var needed: u32 = 0;
    var init_array: ?u32 = null;
    var init_array_sz: u32 = 0;
    var has_init: bool = false;
    var d: usize = off;
    while (d + 8 <= off + dyn_size) : (d += 8) {
        const tag: i32 = @bitCast(u32At(b, d));
        const val = u32At(b, d + 4);
        switch (tag) {
            0 => break, // DT_NULL
            1 => needed += 1, // DT_NEEDED
            12 => has_init = true, // DT_INIT
            25 => init_array = val, // DT_INIT_ARRAY
            27 => init_array_sz = val, // DT_INIT_ARRAYSZ
            else => {},
        }
    }
    if (needed != 0) return fail("{d} dt_needed entries; the bootstrap must not depend on any library", .{needed});
    if (init_array == null or init_array_sz < 4) return fail("no init_array constructor (dt_init present: {})", .{has_init});
    std.debug.print("elfcheck: ok — elf32 arm et_dyn, no dt_needed, init_array of {d} bytes, {d} bytes total\n", .{ init_array_sz, len });
    return 0;
}
