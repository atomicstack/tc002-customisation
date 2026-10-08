//! comptime repetition, for the one case zig 0.17 left without a spelling.
//!
//! 0.17 removed `**`. where it repeated a single element, `@splat` says the same thing and says
//! it better, and that is what the tree uses now. the case `@splat` cannot express is a unit
//! longer than one element -- `"ab" ** 7`, which is how the api and credential tests write the
//! 64-character hex tokens they are made of, and how several tests write "one character past the
//! limit". that is what this is for, and it is the only thing it is for.
//!
//! comptime only, and the result is a pointer to a constant with a sentinel, so it coerces
//! exactly where a string literal would.

/// `n` copies of `unit`, end to end.
pub fn bytes(comptime unit: []const u8, comptime n: usize) *const [unit.len * n:0]u8 {
    // the value is a declaration rather than a local so that it has a static address: a `const`
    // inside the function body belongs to the call, and the pointer would not outlive it
    return comptime &struct {
        const value: [unit.len * n:0]u8 = blk: {
            var buf: [unit.len * n:0]u8 = undefined;
            for (0..n) |i| @memcpy(buf[i * unit.len ..][0..unit.len], unit);
            buf[unit.len * n] = 0;
            break :blk buf;
        };
    }.value;
}

test "a repeated unit is the unit, n times" {
    const std = @import("std");
    try std.testing.expectEqualStrings("ababab", bytes("ab", 3));
    try std.testing.expectEqualStrings("", bytes("ab", 0));
    try std.testing.expectEqual(@as(usize, 64), bytes("ab", 32).len);
    // the sentinel is there, so it stands in for a string literal wherever one was expected
    try std.testing.expectEqual(@as(u8, 0), bytes("x", 4)[4]);
}
