//! the audio-out, through the device's own `libmi_ao.so`.
//!
//! `sound/mi.zig` drives the control plane as raw ioctls and works, but `MI_AO_SendFrame` marshals
//! samples through a buffer the library allocates itself, so the samples go through the vendor's
//! code rather than a reimplementation of it.
const std = @import("std");
const log = @import("../sys/log.zig");

extern fn dlopen(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern fn dlerror() ?[*:0]const u8;

const RTLD_NOW: c_int = 2;
const RTLD_GLOBAL: c_int = 0x100;

/// `libmi_ao.so` does not declare all of its own dependencies: it needs `CamOsGetTimeOfDay` from
/// the cam-os wrapper, so that has to be global in the process first. found the hard way.
const preload = [_][:0]const u8{
    "/lib/libcam_os_wrapper.so",
    "/lib/libcam_fs_wrapper.so",
    "/lib/libmi_common.so",
    "/lib/libmi_sys.so",
};

const SetPubAttrFn = *const fn (u32, *const anyopaque) callconv(.c) i32;
const DevFn = *const fn (u32) callconv(.c) i32;
const ChnFn = *const fn (u32, u32) callconv(.c) i32;
const SendFrameFn = *const fn (u32, u32, *const anyopaque, i32) callconv(.c) i32;
const VolumeFn = *const fn (u32, u32, i32, u32) callconv(.c) i32;
const MuteFn = *const fn (u32, u32, u32) callconv(.c) i32;

pub const Api = struct {
    set_pub_attr: SetPubAttrFn,
    enable: DevFn,
    disable: DevFn,
    enable_chn: ChnFn,
    disable_chn: ChnFn,
    clear_chn_buf: ChnFn,
    send_frame: SendFrameFn,
    set_volume: VolumeFn,
    set_mute: MuteFn,
};

/// the device's buffer is full. the vendor spins on this rather than treating it as an error.
pub const err_buffer_full: i32 = @bitCast(@as(u32, 0xA005200D));

var api: ?Api = null;

fn sym(h: ?*anyopaque, comptime T: type, name: [:0]const u8) ?T {
    const p = dlsym(h, name.ptr) orelse {
        log.err("libmi_ao.so has no {s}", .{name});
        return null;
    };
    return @ptrCast(@alignCast(p));
}

/// load the library once. returns null if anything is missing, and says which.
pub fn load() ?Api {
    if (api) |a| return a;
    for (preload) |p| {
        if (dlopen(p.ptr, RTLD_NOW | RTLD_GLOBAL) == null) {
            const e = dlerror();
            log.warn("preload {s}: {s}", .{ p, if (e) |t| std.mem.span(t) else "?" });
        }
    }
    const h = dlopen("/lib/libmi_ao.so", RTLD_NOW | RTLD_GLOBAL) orelse {
        const e = dlerror();
        log.err("libmi_ao.so: {s}", .{if (e) |t| std.mem.span(t) else "?"});
        return null;
    };
    const a = Api{
        .set_pub_attr = sym(h, SetPubAttrFn, "MI_AO_SetPubAttr") orelse return null,
        .enable = sym(h, DevFn, "MI_AO_Enable") orelse return null,
        .disable = sym(h, DevFn, "MI_AO_Disable") orelse return null,
        .enable_chn = sym(h, ChnFn, "MI_AO_EnableChn") orelse return null,
        .disable_chn = sym(h, ChnFn, "MI_AO_DisableChn") orelse return null,
        .clear_chn_buf = sym(h, ChnFn, "MI_AO_ClearChnBuf") orelse return null,
        .send_frame = sym(h, SendFrameFn, "MI_AO_SendFrame") orelse return null,
        .set_volume = sym(h, VolumeFn, "MI_AO_SetVolume") orelse return null,
        .set_mute = sym(h, MuteFn, "MI_AO_SetMute") orelse return null,
    };
    api = a;
    return a;
}

/// the 52-byte attribute payload, exactly as `media::SoundDevice::init` builds it. copied rather
/// than interpreted: the field names are still unknown and do not need to be.
pub fn attrBytes(rate: u32, channels: u32) [52]u8 {
    var a = [_]u8{0} ** 52;
    std.mem.writeInt(u32, a[0..4], rate, .little);
    if (channels == 2) std.mem.writeInt(u32, a[12..16], 1, .little);
    std.mem.writeInt(u32, a[16..20], 4, .little);
    std.mem.writeInt(u32, a[20..24], 1024, .little);
    std.mem.writeInt(u32, a[28..32], 1, .little);
    return a;
}

/// `MI_AUDIO_Frame_t`: 288 bytes with the pcm at +8 and the byte count at +84, as
/// `media::SoundDevice::output` builds it.
pub const Frame = struct {
    bytes: [288]u8 = [_]u8{0} ** 288,

    pub fn init(pcm: []const u8) Frame {
        var f = Frame{};
        const addr: u32 = @truncate(@intFromPtr(pcm.ptr));
        std.mem.writeInt(u32, f.bytes[8..12], addr, .little);
        std.mem.writeInt(u32, f.bytes[84..88], @intCast(pcm.len), .little);
        return f;
    }
};

/// 1..100 onto the decibel figure the device takes. the vendor computes a dB value from a 0..1
/// float; this is the same shape with the ends pinned so 100 is unattenuated and 1 is nearly off.
pub fn volumeDb(volume: u8) i32 {
    const v: i32 = @intCast(@min(@max(volume, 1), 100));
    return @divTrunc(v * 60, 100) - 60;
}

test "the volume mapping covers the range without going positive" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 0), volumeDb(100));
    try testing.expectEqual(@as(i32, -30), volumeDb(50));
    try testing.expect(volumeDb(1) < -55);
    // out of range is clamped rather than wrapped: a u8 of 0 must not become +60 dB
    try testing.expect(volumeDb(0) <= 0);
    try testing.expect(volumeDb(255) <= 0);
}

test "the attribute payload is the vendor's bytes" {
    const testing = std.testing;
    const a = attrBytes(44100, 1);
    try testing.expectEqual(@as(u32, 44100), std.mem.readInt(u32, a[0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, a[12..16], .little)); // mono
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, a[16..20], .little));
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, a[20..24], .little));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, a[28..32], .little));
    const st = attrBytes(48000, 2);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, st[12..16], .little)); // stereo
}

test "a frame carries the buffer and its length where the driver looks" {
    const testing = std.testing;
    var pcm = [_]u8{0} ** 64;
    const f = Frame.init(&pcm);
    try testing.expectEqual(@as(u32, 64), std.mem.readInt(u32, f.bytes[84..88], .little));
    try testing.expectEqual(@as(usize, 288), f.bytes.len);
}
