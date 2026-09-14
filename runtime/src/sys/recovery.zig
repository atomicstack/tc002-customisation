//! the two mechanisms that stop a flashed runtime from taking the device away with it.
//!
//! a runtime that boots from `/res` replaces the vendor app, so a bad one has nobody to hand the
//! panel back to and no network to be reached over. the only recovery route this project has ever
//! verified is adb over the device's own wifi (see [`FIRMWARE.md`](../../FIRMWARE.md)), and a
//! runtime that fails to bring wifi up has taken that away too. so:
//!
//! - **the stock-config fallback.** the vendor loader reads `/tmp/EasyUI.cfg` *before* the
//!   read-only `/res/etc/EasyUI.cfg`, so writing one whose `startupLibPath` is the vendor library
//!   makes the next `zkswe` start the stock app instead of us. `/tmp` is tmpfs, so it lasts until
//!   the next power cycle -- long enough for the vendor app to bring the network up its own proven
//!   way and to run the upgrade check the reset button's reflash depends on.
//!
//! - **the boot-failure counter.** the bootstrap counts a boot before it execs the supervisor, and
//!   the supervisor clears it once it has stayed up long enough to be called working. three bad
//!   boots in a row and the bootstrap writes the stock config and stands aside, with nobody
//!   touching the device.
//!
//! the policy is separated from the syscalls deliberately. the bootstrap links no libc and runs as
//! a shared-object constructor, so none of the io here can run on a host; the decisions can, and
//! those are what would be wrong in a way nobody noticed until a device did not come back.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const easyui_cfg_path: [*:0]const u8 = "/tmp/EasyUI.cfg";
pub const fail_count_path: [*:0]const u8 = "/data/tc002/state/boot-fails";

/// how many boots may fail before the runtime stops trying.
///
/// three, not one: a single failure is as likely to be a power cut mid-boot or a wedged spi probe
/// as a broken build, and giving up on the first would make the runtime far too easy to lose. not
/// ten either -- every attempt is a reboot cycle the user watches fail.
pub const fail_threshold: u8 = 3;

/// how long the supervisor must stay up before the boot counts as good. long enough to be past the
/// panel, the network and the first frames; short enough that a user power-cycling an apparently
/// dead clock does not clear a genuine failure by accident.
pub const healthy_after_ns: u64 = 60 * std.time.ns_per_s;

pub const Decision = enum { go, hand_back };

/// what the bootstrap should do, given how many boots have already failed.
pub fn decide(fails: u8) Decision {
    return if (fails >= fail_threshold) .hand_back else .go;
}

/// saturating, because a counter that wrapped to zero would hand a boot loop back its own runway.
pub fn nextCount(fails: u8) u8 {
    return fails +| 1;
}

/// the counter file's contents, or 0 for anything unreadable. an unparseable counter is treated as
/// "no failures yet": the file lives on jffs2 and a truncated write after a power cut must not
/// strand the runtime, and the failure it would be hiding will simply happen again and re-count.
pub fn parseCount(text: []const u8) u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.fmt.parseInt(u8, trimmed, 10) catch 0;
}

/// the stock loader configuration: the same keys as this device's `/res/etc/EasyUI.cfg`, with
/// `startupLibPath` pointing back at the vendor library. the loader parses it with jsoncpp, so
/// whitespace and key order do not matter.
///
/// it is a copy, which is the weak part: a unit with a different language or touch device would be
/// handed this one's settings. it is only ever in place for one boot, and the alternative -- the
/// image preserving the original alongside the modified one -- is worth doing before this is ever
/// relied on for real.
pub const stock_easyui_cfg =
    "{\"baud\":\"115200\",\"rotateTouch\":0,\"rotateScreen\":0," ++
    "\"startupLibPath\":\"/res/lib/libzkgui.so\",\"languageCode\":\"zh_CN\"," ++
    "\"defBrightness\":-1,\"screensaverTimeOut\":-1,\"touchDev\":\"/dev/input/event0\"," ++
    "\"languagePath\":\"/res/tr/\",\"uart\":\"ttyS1\",\"startupTouchCalib\":false," ++
    "\"zkdebug\":false,\"resPath\":\"/res/ui/\"}\n";

// -- the io. raw syscalls, no allocator, so the no-libc bootstrap can use this as it is.

fn isErr(rc: usize) bool {
    const s: isize = @bitCast(rc);
    return s < 0 and s > -4096;
}

fn openZ(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, path, flags, mode);
    if (isErr(rc)) return null;
    return @intCast(rc);
}

fn writeAll(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (isErr(rc)) return false;
        const n: usize = @intCast(rc);
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// hand the next `zkswe` start back to the vendor app. best effort: if this cannot be written
/// there is nothing further to try, and saying so is the caller's business.
pub fn writeStockCfg() bool {
    const fd = openZ(easyui_cfg_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) orelse return false;
    defer _ = linux.close(fd);
    return writeAll(fd, stock_easyui_cfg);
}

pub fn readFailCount() u8 {
    const fd = openZ(fail_count_path, .{ .ACCMODE = .RDONLY }, 0) orelse return 0;
    defer _ = linux.close(fd);
    var buf: [16]u8 = undefined;
    const rc = linux.read(fd, &buf, buf.len);
    if (isErr(rc)) return 0;
    return parseCount(buf[0..@intCast(rc)]);
}

pub fn writeFailCount(v: u8) void {
    _ = linux.mkdir("/data/tc002", 0o700);
    _ = linux.mkdir("/data/tc002/state", 0o700);
    const fd = openZ(fail_count_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) orelse return;
    defer _ = linux.close(fd);
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}\n", .{v}) catch return;
    _ = writeAll(fd, text);
}

test "the counter runs out, and only then" {
    try std.testing.expectEqual(Decision.go, decide(0));
    try std.testing.expectEqual(Decision.go, decide(1));
    try std.testing.expectEqual(Decision.go, decide(2));
    // the third failed boot is the one that stops it trying
    try std.testing.expectEqual(Decision.hand_back, decide(3));
    try std.testing.expectEqual(Decision.hand_back, decide(255));
}

test "a boot loop cannot wrap the counter back into its own runway" {
    var n: u8 = 0;
    for (0..1000) |_| n = nextCount(n);
    try std.testing.expectEqual(@as(u8, 255), n);
    try std.testing.expectEqual(Decision.hand_back, decide(n));
}

test "an unreadable counter reads as no failures, not as failure" {
    try std.testing.expectEqual(@as(u8, 0), parseCount(""));
    try std.testing.expectEqual(@as(u8, 0), parseCount("garbage"));
    try std.testing.expectEqual(@as(u8, 0), parseCount("\x00\x00"));
    try std.testing.expectEqual(@as(u8, 2), parseCount("2\n"));
    try std.testing.expectEqual(@as(u8, 2), parseCount("  2 \r\n"));
    try std.testing.expectEqual(@as(u8, 3), parseCount("3"));
    // a truncated jffs2 write must not read as a number that hands the panel back early
    try std.testing.expectEqual(@as(u8, 0), parseCount("3\x00garbage"));
}

test "the fallback config starts the vendor app and nothing else" {
    try std.testing.expect(std.mem.indexOf(u8, stock_easyui_cfg, "/res/lib/libzkgui.so") != null);
    // the whole point is that it must NOT point at us
    try std.testing.expect(std.mem.indexOf(u8, stock_easyui_cfg, "tc002") == null);
    try std.testing.expect(std.mem.endsWith(u8, stock_easyui_cfg, "}\n"));
}
