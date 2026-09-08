//! the proleptic gregorian calendar against the unix epoch (howard hinnant's algorithms), shared
//! by the timezone rules and the log timestamps. pure.
const std = @import("std");

pub const Civil = struct { year: i32, month: u8, day: u8 };

/// days since 1970-01-01 for a calendar date.
pub fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) @as(i64, month) - 3 else @as(i64, month) + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// the calendar date of a day count since 1970-01-01.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = @intCast(if (m <= 2) y + 1 else y), .month = m, .day = d };
}

test "civil dates round-trip across leap years and the epoch" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20454), daysFromCivil(2026, 1, 1));
    try std.testing.expectEqual(Civil{ .year = 2026, .month = 9, .day = 8 }, civilFromDays(daysFromCivil(2026, 9, 8)));
    try std.testing.expectEqual(Civil{ .year = 2024, .month = 2, .day = 29 }, civilFromDays(daysFromCivil(2024, 2, 29)));
    try std.testing.expectEqual(Civil{ .year = 1969, .month = 12, .day = 31 }, civilFromDays(-1));
    var d: i64 = -800;
    while (d < 40000) : (d += 37) {
        const c = civilFromDays(d);
        try std.testing.expectEqual(d, daysFromCivil(c.year, c.month, c.day));
    }
}
