//! the sigmastar mi_ao / mi_sys ioctl layer, recovered from the device's own libraries rather than
//! linked against them. see `vendor/mi_ao/README.md` for how the numbers were obtained and what is
//! still inferred rather than measured.
//!
//! pure enough to test: everything here builds a request number and packs an envelope, and only
//! `call` touches a descriptor. the packing is what the host tests pin, because a wrong envelope is
//! the difference between silence and a noise on a device somebody lives with.
const std = @import("std");
const sys = @import("../sys/linux.zig");

/// linux ioctl encoding, arm: dir(2) | size(14) | type(8) | nr(8)
pub const dir_write: u32 = 1;
pub const dir_read: u32 = 2;
pub const magic: u32 = 'i';

pub fn ioc(dir: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (magic << 8) | nr;
}

pub fn iow(nr: u32, size: u32) u32 {
    return ioc(dir_write, nr, size);
}

pub fn iowr(nr: u32, size: u32) u32 {
    return ioc(dir_write | dir_read, nr, size);
}

/// every call wraps its payload in this. the pointer is stored as 64 bits sign-extended from the
/// 32-bit address, which is what the library does and therefore what the driver expects.
pub const Envelope = extern struct {
    size: u32,
    reserved: u32 = 0,
    ptr_lo: u32,
    ptr_hi: u32,

    /// the packing itself, over an address rather than a pointer, so it is testable on a host
    /// whose pointers are not 32 bits.
    pub fn pack(addr: u32, size: u32) Envelope {
        return .{
            .size = size,
            .ptr_lo = addr,
            // sign-extended, not zero-extended: the library computes `asr #31` over the address
            .ptr_hi = if (addr & 0x8000_0000 != 0) 0xffff_ffff else 0,
        };
    }

    /// wrap a real payload. `@truncate` rather than `@intCast` because this is only ever called on
    /// the device, where a pointer is 32 bits; on a 64-bit host it would be meaningless, which is
    /// why `pack` exists and is what the tests use.
    pub fn wrap(payload: []const u8) Envelope {
        return pack(@truncate(@intFromPtr(payload.ptr)), @intCast(payload.len));
    }
};

/// the audio-out calls this runtime uses. the numbers are in `vendor/mi_ao/README.md`.
pub const ao = struct {
    pub const set_pub_attr = iow(0, 56);
    pub const get_pub_attr = iowr(1, 56);
    pub const enable = iow(2, 4);
    pub const disable = iow(3, 4);
    pub const enable_chn = iow(4, 8);
    pub const disable_chn = iow(5, 8);
    pub const send_frame = iow(6, 8);
    pub const pause_chn = iow(7, 4);
    pub const resume_chn = iow(8, 4);
    pub const clear_chn_buf = iow(9, 8);
    pub const query_chn_stat = iowr(10, 20);
    pub const set_volume = iow(11, 16);
    pub const get_volume = iowr(12, 12);
    pub const set_mute = iow(13, 12);
    pub const get_mute = iowr(14, 12);
    pub const clr_pub_attr = iow(15, 4);
};

/// the shared-buffer calls the samples travel through
pub const mi_sys = struct {
    pub const init = ioc(dir_read, 0, 4);
    pub const exit = ioc(dir_read, 1, 4);
    pub const mmap = iowr(10, 24);
    pub const munmap = iow(11, 8);
    pub const mma_alloc = iowr(27, 48);
    pub const mma_free = iow(28, 8);
    pub const flush_inv_cache = iow(29, 8);
};

pub const ao_path = "/dev/mi_ao";
pub const sys_path = "/dev/mi_sys";

/// issue one call. the payload is passed by pointer inside the envelope, exactly as the vendor
/// library does it.
pub fn call(fd: sys.Fd, request: u32, payload: []const u8) sys.Error!void {
    var env = Envelope.wrap(payload);
    _ = try sys.ioctl(fd, request, @intFromPtr(&env));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the request numbers are the ones read off the device" {
    // a regression test against `vendor/mi_ao/README.md`: if this file and that table ever
    // disagree, one of them has been edited without the other
    try testing.expectEqual(@as(u32, 0x40386900), ao.set_pub_attr);
    try testing.expectEqual(@as(u32, 0xc0386901), ao.get_pub_attr);
    try testing.expectEqual(@as(u32, 0x40046902), ao.enable);
    try testing.expectEqual(@as(u32, 0x40086904), ao.enable_chn);
    try testing.expectEqual(@as(u32, 0x40086906), ao.send_frame);
    try testing.expectEqual(@as(u32, 0x4010690b), ao.set_volume);
    try testing.expectEqual(@as(u32, 0x400c690d), ao.set_mute);
    try testing.expectEqual(@as(u32, 0x40086909), ao.clear_chn_buf);

    try testing.expectEqual(@as(u32, 0x80046900), mi_sys.init);
    try testing.expectEqual(@as(u32, 0xc018690a), mi_sys.mmap);
    try testing.expectEqual(@as(u32, 0x4008690b), mi_sys.munmap);
    try testing.expectEqual(@as(u32, 0xc030691b), mi_sys.mma_alloc);
    try testing.expectEqual(@as(u32, 0x4008691c), mi_sys.mma_free);
    try testing.expectEqual(@as(u32, 0x4008691d), mi_sys.flush_inv_cache);
}

test "the envelope is sixteen bytes in the order the driver reads them" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(Envelope));
    const e = Envelope.pack(0x0040_1234, 56);
    try testing.expectEqual(@as(u32, 56), e.size);
    try testing.expectEqual(@as(u32, 0), e.reserved);
    try testing.expectEqual(@as(u32, 0x0040_1234), e.ptr_lo);
    // field order matters as much as the values: the driver reads size, pad, then a 64-bit pointer
    try testing.expectEqual(@as(usize, 0), @offsetOf(Envelope, "size"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Envelope, "ptr_lo"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Envelope, "ptr_hi"));
}

test "the pointer is sign-extended, not zero-extended" {
    // the library computes `asr r3, r2, #31` over the address, so an address with the top bit set
    // carries 0xffffffff in the high word. kernel-side that is what makes the 64-bit read land.
    try testing.expectEqual(@as(u32, 0xffff_ffff), Envelope.pack(0x8000_0000, 4).ptr_hi);
    try testing.expectEqual(@as(u32, 0), Envelope.pack(0x0040_0000, 4).ptr_hi);
}

test "the encoding itself, so a new call can be added from the table alone" {
    try testing.expectEqual(@as(u32, 0x40386900), iow(0, 56));
    try testing.expectEqual(@as(u32, 0xc0146917), iowr(23, 20));
    // magic 'i' sits in bits 8..15 of every one of them
    try testing.expectEqual(@as(u32, 'i'), (ao.send_frame >> 8) & 0xff);
    try testing.expectEqual(@as(u32, 'i'), (mi_sys.mma_alloc >> 8) & 0xff);
}
