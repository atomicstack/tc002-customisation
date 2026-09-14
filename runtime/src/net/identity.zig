//! how the device names itself on a broker: the home-assistant device id and the mqtt client id.
//! pure.
//!
//! both used to be worked out in two places in netd, and they disagreed. the client id was minted
//! from `boot_id`, which is fresh on every boot, so a rebooted clock arrived at the broker as a
//! *different* client. the previous session stayed alive until its keepalive expired, and when the
//! broker finally reaped it the dead session's retained will -- `offline` -- was published after
//! the new session had already said `online`. every home-assistant entity went unavailable a few
//! seconds after each reboot and stayed that way.
//!
//! a stable id makes the broker treat the reconnect as a takeover instead, which happens before the
//! new session publishes `online`, so the ordering can no longer inverted.

const std = @import("std");

/// the longest id either function produces, `tc002-` plus twelve hex digits of mac.
pub const max = 24;

/// the device's stable name. the mac is the only identifier that survives a reboot; `boot_id` is
/// the fallback for the window on a cold boot before wlan0 exists, and is explicitly marked so a
/// reader can tell a real identity from a temporary one.
pub fn deviceId(buf: *[max]u8, mac_present: bool, mac: [6]u8, boot_id: u32) []const u8 {
    if (mac_present) return std.fmt.bufPrint(buf, "tc002-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "tc002-boot{x:0>8}", .{boot_id}) catch buf[0..0];
}

/// the mqtt client id: whatever the settings say, else the device's own name. deliberately the
/// same string as `deviceId` rather than a second scheme -- one name for one device.
pub fn clientId(buf: *[max]u8, configured: []const u8, mac_present: bool, mac: [6]u8, boot_id: u32) []const u8 {
    if (configured.len > 0) return configured;
    return deviceId(buf, mac_present, mac, boot_id);
}

test "the client id is stable across reboots once the mac is known" {
    const mac = [6]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x01 };
    var a: [max]u8 = undefined;
    var b: [max]u8 = undefined;
    // the same device, two boots: boot_id differs, the identity must not. this is the bug.
    try std.testing.expectEqualStrings(
        clientId(&a, "", true, mac, 0x11111111),
        clientId(&b, "", true, mac, 0x22222222),
    );
    try std.testing.expectEqualStrings("tc002-deadbeef0001", clientId(&a, "", true, mac, 1));
    // and it is the same string the ha device is published under
    try std.testing.expectEqualStrings(deviceId(&b, true, mac, 1), clientId(&a, "", true, mac, 1));
}

test "without a mac it falls back to the boot id, and says so" {
    var a: [max]u8 = undefined;
    const id = clientId(&a, "", false, .{ 0, 0, 0, 0, 0, 0 }, 0xabcdef01);
    try std.testing.expectEqualStrings("tc002-bootabcdef01", id);
    // the fallback is visibly a fallback: nothing can mistake it for a mac-derived name
    try std.testing.expect(std.mem.indexOf(u8, id, "boot") != null);
}

test "a configured client id wins, and is not copied into the buffer" {
    var a: [max]u8 = undefined;
    try std.testing.expectEqualStrings("my-clock", clientId(&a, "my-clock", true, .{ 1, 2, 3, 4, 5, 6 }, 7));
}

test "every id fits the buffer" {
    var a: [max]u8 = undefined;
    try std.testing.expect(deviceId(&a, true, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, 0xffffffff).len <= max);
    try std.testing.expect(deviceId(&a, false, .{0} ** 6, 0xffffffff).len <= max);
}
