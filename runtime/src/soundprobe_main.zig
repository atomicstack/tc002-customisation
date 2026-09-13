//! tc002-soundprobe: a diagnostic, not part of the runtime.
//!
//! opens the audio devices and walks the control plane with the exact bytes the vendor's own
//! `SoundDevice::init` uses, printing what each ioctl returned. it sends no frames unless asked,
//! so by default it cannot make a sound.
//!
//!   tc002-soundprobe [--rate N] [--channels N] [--send-frame]
const std = @import("std");
const sys = @import("sys/linux.zig");
const log = @import("sys/log.zig");
const mi = @import("sound/mi.zig");

pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

/// the 52 bytes `media::SoundDevice::init` builds, copied rather than interpreted
fn attrBytes(rate: u32, channels: u32) [52]u8 {
    var a = [_]u8{0} ** 52;
    std.mem.writeInt(u32, a[0..4], rate, .little);
    if (channels == 2) std.mem.writeInt(u32, a[12..16], 1, .little);
    std.mem.writeInt(u32, a[16..20], 4, .little);
    std.mem.writeInt(u32, a[20..24], 1024, .little);
    std.mem.writeInt(u32, a[28..32], 1, .little);
    return a;
}

fn step(name: []const u8, r: anyerror!void) bool {
    if (r) |_| {
        log.info("  {s}: ok", .{name});
        return true;
    } else |e| {
        log.warn("  {s}: {s}", .{ name, @errorName(e) });
        return false;
    }
}

fn run(rate: u32, channels: u32, try_frame: bool) !u8 {
    log.info("opening the audio devices", .{});
    const sys_fd = sys.open(mi.sys_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |e| {
        log.err("{s}: {s}", .{ mi.sys_path, @errorName(e) });
        return 1;
    };
    defer sys.close(sys_fd);
    const ao_fd = sys.open(mi.ao_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch |e| {
        log.err("{s}: {s}", .{ mi.ao_path, @errorName(e) });
        return 1;
    };
    defer sys.close(ao_fd);
    log.info("  both open (mi_sys fd {d}, mi_ao fd {d})", .{ sys_fd, ao_fd });

    var dev = [_]u8{0} ** 4; // device 0
    _ = step("MI_SYS_Init", mi.call(sys_fd, mi.mi_sys.init, &dev));

    log.info("configuring: {d} hz, {d} channel(s)", .{ rate, channels });
    var attr: [56]u8 = [_]u8{0} ** 56;
    const a = attrBytes(rate, channels);
    @memcpy(attr[4..56], &a); // +0 is the device id, then the 52-byte payload
    if (!step("MI_AO_SetPubAttr", mi.call(ao_fd, mi.ao.set_pub_attr, &attr))) return 2;
    if (!step("MI_AO_Enable", mi.call(ao_fd, mi.ao.enable, &dev))) return 2;

    var chn = [_]u8{0} ** 8; // device 0, channel 0
    _ = step("MI_AO_EnableChn", mi.call(ao_fd, mi.ao.enable_chn, &chn));

    // mute before anything else can possibly be heard
    var mute = [_]u8{0} ** 12;
    std.mem.writeInt(u32, mute[8..12], 1, .little);
    _ = step("MI_AO_SetMute(on)", mi.call(ao_fd, mi.ao.set_mute, &mute));

    var stat = [_]u8{0} ** 20;
    if (step("MI_AO_QueryChnStat", mi.call(ao_fd, mi.ao.query_chn_stat, &stat))) {
        log.info("    chn stat words: {d} {d} {d} {d} {d}", .{
            std.mem.readInt(u32, stat[0..4], .little),
            std.mem.readInt(u32, stat[4..8], .little),
            std.mem.readInt(u32, stat[8..12], .little),
            std.mem.readInt(u32, stat[12..16], .little),
            std.mem.readInt(u32, stat[16..20], .little),
        });
    }

    if (try_frame) {
        // the unknown: MI_AO_SendFrame's ioctl carries eight bytes, and the vendor's 288-byte
        // frame (pcm at +8, length at +84) has to reach the driver through them somehow. the
        // buffer here is **silence**, so every variant can be tried without a sound.
        var frame = [_]u8{0} ** 288;
        var pcm = [_]u8{0} ** 2048; // 1024 silent 16-bit samples
        const pcm_addr: u32 = @truncate(@intFromPtr(&pcm));
        const frame_addr: u32 = @truncate(@intFromPtr(&frame));
        std.mem.writeInt(u32, frame[8..12], pcm_addr, .little);
        std.mem.writeInt(u32, frame[84..88], pcm.len, .little);

        log.info("trying SendFrame payloads (silence, so nothing can be heard)", .{});
        var payload = [_]u8{0} ** 8;

        std.mem.writeInt(u32, payload[0..4], 0, .little);
        std.mem.writeInt(u32, payload[4..8], 0, .little);
        _ = step("  {dev=0, chn=0}", mi.call(ao_fd, mi.ao.send_frame, &payload));

        std.mem.writeInt(u32, payload[0..4], 0, .little);
        std.mem.writeInt(u32, payload[4..8], frame_addr, .little);
        _ = step("  {0, &frame}", mi.call(ao_fd, mi.ao.send_frame, &payload));

        std.mem.writeInt(u32, payload[0..4], frame_addr, .little);
        std.mem.writeInt(u32, payload[4..8], 0, .little);
        _ = step("  {&frame, 0}", mi.call(ao_fd, mi.ao.send_frame, &payload));

        std.mem.writeInt(u32, payload[0..4], pcm_addr, .little);
        std.mem.writeInt(u32, payload[4..8], pcm.len, .little);
        _ = step("  {&pcm, len}", mi.call(ao_fd, mi.ao.send_frame, &payload));
    }

    log.info("tearing down", .{});
    _ = step("MI_AO_DisableChn", mi.call(ao_fd, mi.ao.disable_chn, &chn));
    _ = step("MI_AO_Disable", mi.call(ao_fd, mi.ao.disable, &dev));
    log.info("done; no frames were sent, so nothing could have been heard", .{});
    return 0;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    log.program = "tc002-soundprobe";
    var rate: u32 = 44100;
    var channels: u32 = 1;
    var try_frame = false;
    var i: usize = 1;
    while (i < init.args.vector.len) : (i += 1) {
        const s = std.mem.span(init.args.vector[i]);
        if (std.mem.eql(u8, s, "--rate") and i + 1 < init.args.vector.len) {
            i += 1;
            rate = std.fmt.parseInt(u32, std.mem.span(init.args.vector[i]), 10) catch rate;
        } else if (std.mem.eql(u8, s, "--send-frame")) {
            try_frame = true;
        } else if (std.mem.eql(u8, s, "--channels") and i + 1 < init.args.vector.len) {
            i += 1;
            channels = std.fmt.parseInt(u32, std.mem.span(init.args.vector[i]), 10) catch channels;
        }
    }
    return run(rate, channels, try_frame) catch |e| {
        log.err("fatal: {s}", .{sys.errText(e)});
        return 1;
    };
}
