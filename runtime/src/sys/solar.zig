//! sunrise, sunset and the civil twilight either side of them, for a point on the planet.
//!
//! the low-precision sunrise equation: solar mean anomaly, the equation of the centre, the
//! declination that follows, and the hour angle at which the sun crosses a given zenith. the
//! declination is evaluated at solar noon rather than at the crossing itself, which is where the
//! error comes from; against an independent formulation (the noaa solar calculator) this agrees
//! within 80 s at the worst case tried (anchorage in november) and within 10 s at mid-latitudes.
//! a brightness ramp lasts tens of minutes, so that is far below anything visible.
//!
//! pure, and deliberately free of libm: `@sin` and `@cos` lower to calls this binary cannot link,
//! so the sine is a truncated taylor series and the arccosine an abramowitz-and-stegun fit. the
//! rest (`@sqrt`, `@abs`, float conversions) is hardware or compiler_rt.
const std = @import("std");

/// a place, in hundredths of a degree: latitude positive north, longitude positive east.
pub const Point = struct { lat_c: i16, lon_c: i16 };

/// the sun's day at a point: the instants in unix seconds, or null where it never crosses that
/// altitude. `sun_up` tells the two polar cases apart when the crossings are missing.
pub const Day = struct {
    /// solar noon, which always exists and is what the day is built around
    noon: i64,
    sunrise: ?i64 = null,
    sunset: ?i64 = null,
    /// civil twilight: the sun 6 degrees below the horizon, when a lit panel stops competing
    dawn: ?i64 = null,
    dusk: ?i64 = null,
    /// the sun stays above the horizon all day (a polar summer) rather than below it all day
    sun_up: bool = false,
};

/// the standard zenith for sunrise and sunset: the sun's centre 0.833 degrees below the horizon,
/// which allows for its radius and for refraction.
pub const zenith_sun = 90.833;
/// civil twilight.
pub const zenith_civil = 96.0;

/// days from the unix epoch to 2000-01-01, the epoch the sunrise equation counts from.
const days_to_j2000 = 10957;

/// the sun's day containing `unix_s`, which is the day whose solar noon is nearest: at a longitude
/// far from greenwich the crossings themselves can land on the utc day either side, so callers
/// that need a window rather than a day ask for the days around it and sort.
pub fn day(unix_s: i64, p: Point) Day {
    const lat = @as(f64, @floatFromInt(p.lat_c)) / 100.0;
    const lon = @as(f64, @floatFromInt(p.lon_c)) / 100.0;
    const n: f64 = @floatFromInt(@divFloor(unix_s, 86400) - days_to_j2000);

    // mean solar time at this longitude, in days since 2000-01-01
    const mean = n - lon / 360.0;
    const anomaly = wrap360(357.5291 + 0.98560028 * mean);
    const centre = 1.9148 * sinDeg(anomaly) + 0.0200 * sinDeg(2 * anomaly) + 0.0003 * sinDeg(3 * anomaly);
    // ecliptic longitude: the mean anomaly plus the centre, plus the argument of perihelion (180 + 102.9372)
    const ecliptic = wrap360(anomaly + centre + 282.9372);
    const transit = mean + 0.0053 * sinDeg(anomaly) - 0.0069 * sinDeg(2 * ecliptic);
    const noon = (transit + @as(f64, days_to_j2000) + 0.5) * 86400.0;

    const sin_decl = sinDeg(ecliptic) * sinDeg(23.4397);
    const cos_decl = @sqrt(1.0 - sin_decl * sin_decl);
    const sin_lat = sinDeg(lat);
    const cos_lat = cosDeg(lat);

    var d = Day{ .noon = @intFromFloat(@round(noon)) };
    // the sun rises at all unless the hour angle has no solution; which polar case it is follows
    // from the sign, since an ever-higher sun drives the cosine below -1
    d.sun_up = (cosDeg(zenith_sun) - sin_lat * sin_decl) / (cos_lat * cos_decl) < -1.0;
    if (hourAngle(zenith_sun, sin_lat, cos_lat, sin_decl, cos_decl)) |h| {
        d.sunrise = @intFromFloat(@round(noon - h));
        d.sunset = @intFromFloat(@round(noon + h));
    }
    if (hourAngle(zenith_civil, sin_lat, cos_lat, sin_decl, cos_decl)) |h| {
        d.dawn = @intFromFloat(@round(noon - h));
        d.dusk = @intFromFloat(@round(noon + h));
    }
    return d;
}

/// the time either side of solar noon, in seconds, at which the sun crosses `zenith`; null when it
/// never does.
fn hourAngle(zenith: f64, sin_lat: f64, cos_lat: f64, sin_decl: f64, cos_decl: f64) ?f64 {
    const c = (cosDeg(zenith) - sin_lat * sin_decl) / (cos_lat * cos_decl);
    if (c > 1.0 or c < -1.0) return null;
    return acosDeg(c) / 360.0 * 86400.0;
}

fn wrap360(x: f64) f64 {
    const whole: f64 = @floatFromInt(@as(i64, @intFromFloat(x / 360.0)));
    const r = x - whole * 360.0;
    return if (r < 0) r + 360.0 else r;
}

const rad_per_deg = std.math.pi / 180.0;

/// sine of an angle in degrees: folded into the first quadrant, then the taylor series to x^11,
/// whose error over that range is under 4e-6.
fn sinDeg(a: f64) f64 {
    var d = wrap360(a);
    var sign: f64 = 1.0;
    if (d > 180.0) {
        d -= 180.0;
        sign = -1.0;
    }
    if (d > 90.0) d = 180.0 - d;
    const x = d * rad_per_deg;
    const x2 = x * x;
    const series = 1.0 + x2 * (-1.0 / 6.0 + x2 * (1.0 / 120.0 + x2 * (-1.0 / 5040.0 + x2 * (1.0 / 362880.0 - x2 / 39916800.0))));
    return sign * x * series;
}

fn cosDeg(a: f64) f64 {
    return sinDeg(a + 90.0);
}

/// arccosine in degrees (abramowitz and stegun 4.4.45), within 0.004 degrees, which is a second of
/// hour angle. the input is clamped because a caller has already decided the crossing exists.
fn acosDeg(x: f64) f64 {
    const c = @min(@max(x, -1.0), 1.0);
    const a = @abs(c);
    const poly = 1.5707288 - 0.2121144 * a + 0.0742610 * a * a - 0.0187293 * a * a * a;
    const r = @sqrt(1.0 - a) * poly / rad_per_deg;
    return if (c >= 0.0) r else 180.0 - r;
}

// the vectors below come from the noaa solar calculator's formulation, which shares no terms with
// the one implemented here beyond the astronomy itself.
const tolerance_s = 120;

fn expectNear(want: i64, got: ?i64) !void {
    const g = got orelse return error.TestUnexpectedResult;
    if (@abs(g - want) > tolerance_s) {
        std.debug.print("expected {d}, got {d} ({d} s out)\n", .{ want, g, g - want });
        return error.TestUnexpectedResult;
    }
}

/// midday utc on a day counted from the unix epoch, which is what `day` is asked about
fn atNoonUtc(unix_day: i64) i64 {
    return unix_day * 86400 + 43200;
}

test "sunrise and sunset match an independent solar calculator" {
    const sydney = Point{ .lat_c = -3387, .lon_c = 15122 };
    const d = day(atNoonUtc(20707), sydney);
    try expectNear(1789070422, d.sunrise); // 2026-09-11, 06:00 local
    try expectNear(1789112610, d.sunset);
    try expectNear(1789068926, d.dawn);
    try expectNear(1789114106, d.dusk);

    const london = Point{ .lat_c = 5151, .lon_c = -13 };
    const midwinter = day(atNoonUtc(20808), london);
    try expectNear(1797840215, midwinter.sunrise); // 08:03 gmt, the shortest day
    try expectNear(1797868386, midwinter.sunset);
    try expectNear(1797837795, midwinter.dawn);
    try expectNear(1797870806, midwinter.dusk);
    const midsummer = day(atNoonUtc(20625), london);
    try expectNear(1782013382, midsummer.sunrise);
    try expectNear(1782073285, midsummer.sunset);

    const new_york = Point{ .lat_c = 4071, .lon_c = -7401 };
    const equinox = day(atNoonUtc(20532), new_york);
    try expectNear(1774004403, equinox.sunrise);
    try expectNear(1774048031, equinox.sunset);

    const quito = Point{ .lat_c = -22, .lon_c = -7851 };
    const on_the_line = day(atNoonUtc(20707), quito);
    try expectNear(1789124855, on_the_line.sunrise);
    try expectNear(1789168448, on_the_line.sunset);

    const ushuaia = Point{ .lat_c = -5480, .lon_c = -6830 };
    const far_south = day(atNoonUtc(20468), ushuaia);
    try expectNear(1768465309, far_south.sunrise);
    try expectNear(1768525382, far_south.sunset);
}

test "inside the arctic circle the crossings go missing, and say which way" {
    const tromso = Point{ .lat_c = 6965, .lon_c = 1896 };
    const midsummer = day(atNoonUtc(20625), tromso);
    try std.testing.expect(midsummer.sunrise == null and midsummer.sunset == null);
    try std.testing.expect(midsummer.dawn == null and midsummer.dusk == null);
    try std.testing.expect(midsummer.sun_up); // the midnight sun

    const midwinter = day(atNoonUtc(20808), tromso);
    try std.testing.expect(midwinter.sunrise == null and midwinter.sunset == null);
    try std.testing.expect(!midwinter.sun_up); // the polar night
    // but the twilight still arrives, and is all the daylight there is
    try expectNear(1797841859, midwinter.dawn);
    try expectNear(1797857578, midwinter.dusk);
}

test "the day holds together: noon between the crossings, twilight outside them" {
    const sydney = Point{ .lat_c = -3387, .lon_c = 15122 };
    var unix_day: i64 = 20454; // walk a whole year
    while (unix_day < 20454 + 365) : (unix_day += 1) {
        const d = day(atNoonUtc(unix_day), sydney);
        try std.testing.expect(d.dawn.? < d.sunrise.?);
        try std.testing.expect(d.sunrise.? < d.noon);
        try std.testing.expect(d.noon < d.sunset.?);
        try std.testing.expect(d.sunset.? < d.dusk.?);
        // solar noon is within a quarter hour of the same clock time every day, and 1.9 h from utc
        const offset = @mod(d.noon, 86400);
        try std.testing.expect(offset > 5600 and offset < 7900);
    }
}

test "the equinox puts sunrise six hours before local solar noon everywhere" {
    // the sun crosses the equator on 2026-03-20, so the day is half lit at every latitude; the sun
    // sets by its own radius and the air bends the last of it into view, so every half day runs a
    // few minutes long, and the further from the equator the shallower the crossing and the longer
    for ([_]i16{ -5480, -3387, -22, 4071, 5151 }) |lat_c| {
        const d = day(atNoonUtc(20532), .{ .lat_c = lat_c, .lon_c = 0 });
        const half_day = d.noon - d.sunrise.?;
        try std.testing.expect(half_day > 6 * 3600 and half_day < 6 * 3600 + 600);
        try std.testing.expect(@abs((d.sunset.? - d.noon) - half_day) <= 1); // each end rounds on its own
    }
}

test "the approximations hold: sine against the exact one, arccos against its own cosine" {
    var deg: f64 = -720.0;
    while (deg <= 720.0) : (deg += 0.37) {
        try std.testing.expectApproxEqAbs(@sin(deg * rad_per_deg), sinDeg(deg), 1e-5);
        try std.testing.expectApproxEqAbs(@cos(deg * rad_per_deg), cosDeg(deg), 1e-5);
    }
    var x: f64 = -1.0;
    while (x <= 1.0) : (x += 0.001) {
        const back = cosDeg(acosDeg(x));
        try std.testing.expectApproxEqAbs(x, back, 1e-4);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), acosDeg(1.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 180.0), acosDeg(-1.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90.0), acosDeg(0.0), 0.01);
}
