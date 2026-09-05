const std = @import("std");
const popsquares = @import("popsquares.zig");

pub const usage_text = "usage: popsquares [options]\n" ++
    "  --fps N          frames per second, 1..240 (60)\n" ++
    "  --pop S          seconds for a full pop to fade (2)\n" ++
    "  --alive P        percent of leds that take part, 0..100 (100)\n" ++
    "  --dim P          percent chance a re-arm comes back dim, 0..100 (25)\n" ++
    "  --dim-min N      dim re-arm level range, 0..127 (0)\n" ++
    "  --dim-max N      (127)\n" ++
    "  --tint-pct P     percent of pops in the tint colour, 0..100 (15)\n" ++
    "  --tint RRGGBB    tint colour as hex (3a6ea5)\n" ++
    "  --brightness P   panel brightness, 0..100 (100)\n" ++
    "  --seconds S      stop after s seconds (run until sigint/sigterm)\n" ++
    "  --seed N         rng seed (from the clock)\n" ++
    "  --dry-run        never open spidev/gpio; just run the loop\n" ++
    "  --stats          print the achieved fps to stderr every 5 s\n" ++
    "  --help\n";

pub const Config = struct {
    fps: u16 = 60,
    brightness: u8 = 100,
    seconds: f64 = 0,
    seed: u32 = 0,
    dry_run: bool = false,
    stats: bool = false,
    animation: popsquares.Options = .{},
};

pub const RangeFailure = struct {
    name: []const u8,
    low: f64,
    high: f64,
};

/// failure and outcome slices borrow args; write diagnostics before freeing argv storage.
pub const Failure = union(enum) {
    needs_value: []const u8,
    range: RangeFailure,
    tint: []const u8,
    unknown: []const u8,

    pub fn write(self: Failure, writer: anytype) !void {
        switch (self) {
            .needs_value => |name| try writer.print("popsquares: {s} needs a value\n", .{name}),
            .range => |range| try writer.print("popsquares: {s} must be between {s} and {s}\n", .{ range.name, cG(range.low), cG(range.high) }),
            .tint => |value| try writer.print("popsquares: --tint wants RRGGBB hex, got {s}\n", .{value}),
            .unknown => |name| try writer.print("popsquares: unknown option {s}\n", .{name}),
        }
    }
};

pub const Outcome = union(enum) {
    run: Config,
    help,
    failure: Failure,

    pub fn write(self: Outcome, writer: anytype) !void {
        if (self == .failure) try self.failure.write(writer);
    }
};

pub fn usage(writer: anytype) !void {
    try writer.writeAll(usage_text);
}

pub fn parse(args: []const [:0]const u8) Outcome {
    var config = Config{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const name = asBytes(args[index]);
        if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) return .help;
        if (std.mem.eql(u8, name, "--dry-run")) {
            config.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--stats")) {
            config.stats = true;
            continue;
        }

        if (index + 1 >= args.len) return .{ .failure = .{ .needs_value = name } };
        index += 1;
        const value = asBytes(args[index]);
        const number = cAtof(value);

        if (std.mem.eql(u8, name, "--fps")) {
            if (!inRange(number, 1, 240, name)) return .{ .failure = .{ .range = .{ .name = name, .low = 1, .high = 240 } } };
            config.fps = safeInt(u16, number);
        } else if (std.mem.eql(u8, name, "--pop")) {
            if (!inRange(number, 0.1, 600, name)) return .{ .failure = .{ .range = .{ .name = name, .low = 0.1, .high = 600 } } };
            config.animation.pop_seconds = @floatCast(number);
        } else if (std.mem.eql(u8, name, "--alive")) {
            if (!inRange(number, 0, 100, name)) return rangeFailure(name, 0, 100);
            config.animation.alive = @floatCast(number / 100.0);
        } else if (std.mem.eql(u8, name, "--dim")) {
            if (!inRange(number, 0, 100, name)) return rangeFailure(name, 0, 100);
            config.animation.dim = @floatCast(number / 100.0);
        } else if (std.mem.eql(u8, name, "--dim-min")) {
            if (!inRange(number, 0, 127, name)) return rangeFailure(name, 0, 127);
            config.animation.dim_min = safeInt(i32, number);
        } else if (std.mem.eql(u8, name, "--dim-max")) {
            if (!inRange(number, 0, 127, name)) return rangeFailure(name, 0, 127);
            config.animation.dim_max = safeInt(i32, number);
        } else if (std.mem.eql(u8, name, "--tint-pct")) {
            if (!inRange(number, 0, 100, name)) return rangeFailure(name, 0, 100);
            config.animation.tint_fraction = @floatCast(number / 100.0);
        } else if (std.mem.eql(u8, name, "--brightness")) {
            if (!inRange(number, 0, 100, name)) return rangeFailure(name, 0, 100);
            config.brightness = safeInt(u8, number);
        } else if (std.mem.eql(u8, name, "--seconds")) {
            if (!inRange(number, 0, 1e7, name)) return rangeFailure(name, 0, 1e7);
            config.seconds = number;
        } else if (std.mem.eql(u8, name, "--seed")) {
            config.seed = cStrtoul(value);
        } else if (std.mem.eql(u8, name, "--tint")) {
            if (!parseColour(value, &config.animation.tint)) return .{ .failure = .{ .tint = value } };
        } else {
            return .{ .failure = .{ .unknown = name } };
        }
    }
    return .{ .run = config };
}

fn rangeFailure(name: []const u8, low: f64, high: f64) Outcome {
    return .{ .failure = .{ .range = .{ .name = name, .low = low, .high = high } } };
}

fn asBytes(value: [:0]const u8) []const u8 {
    return value[0..value.len];
}

fn inRange(value: f64, low: f64, high: f64, _: []const u8) bool {
    return std.math.isFinite(value) and value >= low and value <= high;
}

fn safeInt(comptime T: type, value: f64) T {
    if (std.math.isNan(value) or std.math.isInf(value)) return 0;
    return @intFromFloat(@trunc(value));
}

fn cG(value: f64) []const u8 {
    if (value == 1e7) return "1e+07";
    if (value == 0.1) return "0.1";
    if (value == 1) return "1";
    if (value == 240) return "240";
    if (value == 600) return "600";
    if (value == 127) return "127";
    if (value == 100) return "100";
    return "0";
}

fn cAtof(value: []const u8) f64 {
    var start: usize = 0;
    while (start < value.len and std.ascii.isWhitespace(value[start])) : (start += 1) {}
    if (start == value.len) return 0;

    const rest = value[start..];
    var sign_len: usize = 0;
    if (rest[0] == '+' or rest[0] == '-') sign_len = 1;
    if (sign_len < rest.len and startsIgnoreCase(rest[sign_len..], "inf")) {
        return if (rest[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    }
    if (sign_len < rest.len and startsIgnoreCase(rest[sign_len..], "nan")) return std.math.nan(f64);

    var end = sign_len;
    var digits: usize = 0;
    const hexadecimal = end + 1 < rest.len and rest[end] == '0' and (rest[end + 1] == 'x' or rest[end + 1] == 'X');
    if (hexadecimal) {
        end += 2;
        while (end < rest.len and hexDigit(rest[end]) != null) : (end += 1) digits += 1;
        if (end < rest.len and rest[end] == '.') {
            end += 1;
            while (end < rest.len and hexDigit(rest[end]) != null) : (end += 1) digits += 1;
        }
    } else {
        while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) digits += 1;
        if (end < rest.len and rest[end] == '.') {
            end += 1;
            while (end < rest.len and std.ascii.isDigit(rest[end])) : (end += 1) digits += 1;
        }
    }
    if (digits == 0) return 0;
    const exponent_marker = if (end >= rest.len)
        false
    else if (hexadecimal)
        (rest[end] == 'p' or rest[end] == 'P')
    else
        (rest[end] == 'e' or rest[end] == 'E');
    if (end < rest.len and exponent_marker) {
        var exponent_end = end + 1;
        if (exponent_end < rest.len and (rest[exponent_end] == '+' or rest[exponent_end] == '-')) exponent_end += 1;
        const exponent_start = exponent_end;
        while (exponent_end < rest.len and std.ascii.isDigit(rest[exponent_end])) : (exponent_end += 1) {}
        if (exponent_end > exponent_start) end = exponent_end;
    }
    return std.fmt.parseFloat(f64, rest[0..end]) catch 0;
}

fn startsIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |expected, index| {
        if (std.ascii.toLower(value[index]) != std.ascii.toLower(expected)) return false;
    }
    return true;
}

fn cStrtoul(value: []const u8) u32 {
    var index: usize = 0;
    while (index < value.len and std.ascii.isWhitespace(value[index])) : (index += 1) {}
    var negative = false;
    if (index < value.len and (value[index] == '+' or value[index] == '-')) {
        negative = value[index] == '-';
        index += 1;
    }

    var base: u32 = 10;
    if (index < value.len and value[index] == '0') {
        base = 8;
        if (index + 1 < value.len and (value[index + 1] == 'x' or value[index + 1] == 'X')) {
            base = 16;
            index += 2;
        }
    }
    var parsed: u32 = 0;
    var overflow = false;
    var digits: usize = 0;
    while (index < value.len) : (index += 1) {
        const digit = hexDigit(value[index]);
        if (digit == null or digit.? >= base) break;
        if (!overflow) {
            const max = std.math.maxInt(u32);
            const digit_value: u32 = digit.?;
            if (parsed > (max - digit_value) / base) {
                overflow = true;
            } else {
                parsed = parsed * base + digit_value;
            }
        }
        digits += 1;
    }
    if (digits == 0) return 0;
    if (overflow) return std.math.maxInt(u32);
    return if (negative) 0 -% parsed else parsed;
}

fn parseColour(value: []const u8, tint: *[3]u8) bool {
    var text = value;
    if (text.len > 0 and text[0] == '#') text = text[1..];
    if (text.len != 6) return false;
    const first = hexDigit(text[0]) orelse return false;
    const second = hexDigit(text[1]) orelse return false;
    const third = hexDigit(text[2]) orelse return false;
    const fourth = hexDigit(text[3]) orelse return false;
    const fifth = hexDigit(text[4]) orelse return false;
    const sixth = hexDigit(text[5]) orelse return false;
    tint.* = .{ first * 16 + second, third * 16 + fourth, fifth * 16 + sixth };
    return true;
}

fn hexDigit(value: u8) ?u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => null,
    };
}

test "usage text matches the c program independently" {
    const expected = "usage: popsquares [options]\n" ++
        "  --fps N          frames per second, 1..240 (60)\n" ++
        "  --pop S          seconds for a full pop to fade (2)\n" ++
        "  --alive P        percent of leds that take part, 0..100 (100)\n" ++
        "  --dim P          percent chance a re-arm comes back dim, 0..100 (25)\n" ++
        "  --dim-min N      dim re-arm level range, 0..127 (0)\n" ++
        "  --dim-max N      (127)\n" ++
        "  --tint-pct P     percent of pops in the tint colour, 0..100 (15)\n" ++
        "  --tint RRGGBB    tint colour as hex (3a6ea5)\n" ++
        "  --brightness P   panel brightness, 0..100 (100)\n" ++
        "  --seconds S      stop after s seconds (run until sigint/sigterm)\n" ++
        "  --seed N         rng seed (from the clock)\n" ++
        "  --dry-run        never open spidev/gpio; just run the loop\n" ++
        "  --stats          print the achieved fps to stderr every 5 s\n" ++
        "  --help\n";
    try std.testing.expectEqualStrings(expected, usage_text);
}

test "defaults match c config and popsquares defaults" {
    const result = parse(&.{});
    switch (result) {
        .run => |config| {
            try std.testing.expectEqual(@as(u16, 60), config.fps);
            try std.testing.expectEqual(@as(u8, 100), config.brightness);
            try std.testing.expectEqual(@as(f64, 0), config.seconds);
            try std.testing.expectEqual(@as(u32, 0), config.seed);
            try std.testing.expect(!config.dry_run);
            try std.testing.expect(!config.stats);
            try std.testing.expectEqualDeep(popsquares.Options{}, config.animation);
        },
        else => try std.testing.expect(false),
    }
}

test "all flags parse with fractional values truncated like c" {
    const result = parse(&.{ "--fps", "120.9", "--pop", "3.5", "--alive", "12.75", "--dim", "25.9", "--dim-min", "11.9", "--dim-max", "126.9", "--tint-pct", "66.6", "--tint", "#aBcD01", "--brightness", "99.9", "--seconds", "4.25", "--seed", "0x123456789", "--dry-run", "--stats" });
    switch (result) {
        .run => |config| {
            try std.testing.expectEqual(@as(u16, 120), config.fps);
            try std.testing.expectEqual(@as(f32, 3.5), config.animation.pop_seconds);
            try std.testing.expectEqual(@as(f32, 0.1275), config.animation.alive);
            try std.testing.expectEqual(@as(f32, 0.259), config.animation.dim);
            try std.testing.expectEqual(@as(i32, 11), config.animation.dim_min);
            try std.testing.expectEqual(@as(i32, 126), config.animation.dim_max);
            try std.testing.expectEqual(@as(f32, 0.666), config.animation.tint_fraction);
            try std.testing.expectEqual([3]u8{ 0xab, 0xcd, 0x01 }, config.animation.tint);
            try std.testing.expectEqual(@as(u8, 99), config.brightness);
            try std.testing.expectEqual(@as(f64, 4.25), config.seconds);
            try std.testing.expectEqual(std.math.maxInt(u32), config.seed);
            try std.testing.expect(config.dry_run);
            try std.testing.expect(config.stats);
        },
        else => try std.testing.expect(false),
    }
}

test "help short circuits at the point it is encountered" {
    const result = parse(&.{ "--fps", "60", "--help", "--unknown" });
    try std.testing.expect(result == .help);
}

test "numeric boundaries are accepted" {
    const result = parse(&.{ "--fps", "1", "--pop", "0.1", "--alive", "0", "--dim", "100", "--dim-min", "0", "--dim-max", "127", "--tint-pct", "100", "--brightness", "0", "--seconds", "10000000" });
    try std.testing.expect(result == .run);
}

test "numeric values outside each supported range retain range context" {
    const cases = [_]struct { args: []const [:0]const u8, name: []const u8, low: f64, high: f64 }{
        .{ .args = &.{ "--fps", "0" }, .name = "--fps", .low = 1, .high = 240 },
        .{ .args = &.{ "--pop", "0" }, .name = "--pop", .low = 0.1, .high = 600 },
        .{ .args = &.{ "--alive", "101" }, .name = "--alive", .low = 0, .high = 100 },
        .{ .args = &.{ "--dim", "-1" }, .name = "--dim", .low = 0, .high = 100 },
        .{ .args = &.{ "--dim-min", "128" }, .name = "--dim-min", .low = 0, .high = 127 },
        .{ .args = &.{ "--dim-max", "-1" }, .name = "--dim-max", .low = 0, .high = 127 },
        .{ .args = &.{ "--tint-pct", "101" }, .name = "--tint-pct", .low = 0, .high = 100 },
        .{ .args = &.{ "--brightness", "101" }, .name = "--brightness", .low = 0, .high = 100 },
        .{ .args = &.{ "--seconds", "10000001" }, .name = "--seconds", .low = 0, .high = 1e7 },
    };
    for (cases) |case| {
        switch (parse(case.args)) {
            .failure => |failure| switch (failure) {
                .range => |range| {
                    try std.testing.expectEqualStrings(case.name, range.name);
                    try std.testing.expectEqual(case.low, range.low);
                    try std.testing.expectEqual(case.high, range.high);
                },
                else => try std.testing.expect(false),
            },
            else => try std.testing.expect(false),
        }
    }
}

test "malformed atof-style numbers become zero and parse safely" {
    const result = parse(&.{ "--seconds", "not-a-number" });
    switch (result) {
        .run => |config| try std.testing.expectEqual(@as(f64, 0), config.seconds),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(parse(&.{ "--fps", "wat" }) == .failure);
}

test "nonfinite numeric values never trap" {
    try std.testing.expect(parse(&.{ "--seconds", "nan" }) == .failure);
    try std.testing.expect(parse(&.{ "--pop", "inf" }) == .failure);
    try std.testing.expect(parse(&.{ "--fps", "nan" }) == .failure);
}

test "c atof prefixes include hexadecimal floats and nan payloads safely" {
    switch (parse(&.{ "--seconds", "0x1p2" })) {
        .run => |config| try std.testing.expectEqual(@as(f64, 4), config.seconds),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(parse(&.{ "--seconds", "nan(foo)" }) == .failure);
    try std.testing.expect(parse(&.{ "--pop", "infinitytail" }) == .failure);
    try std.testing.expect(std.math.isInf(cAtof("infinitytail")));
    try std.testing.expect(std.math.isInf(cAtof("-infinitytail")));
    try std.testing.expect(std.math.isNan(cAtof("+nan(payload)")));
    try std.testing.expectEqual(@as(f64, -4), cAtof("-0x1p2tail"));
    try std.testing.expectEqual(@as(f64, 12), cAtof("12tail"));
}

test "seed follows base-auto parsing and truncates to u32" {
    const result = parse(&.{ "--seed", "123.9" });
    switch (result) {
        .run => |config| try std.testing.expectEqual(@as(u32, 123), config.seed),
        else => try std.testing.expect(false),
    }
    const hex = parse(&.{ "--seed", "0x123456789" });
    switch (hex) {
        .run => |config| try std.testing.expectEqual(std.math.maxInt(u32), config.seed),
        else => try std.testing.expect(false),
    }
    const octal = parse(&.{ "--seed", "077" });
    switch (octal) {
        .run => |config| try std.testing.expectEqual(@as(u32, 63), config.seed),
        else => try std.testing.expect(false),
    }
    const signed = parse(&.{ "--seed", "-1" });
    switch (signed) {
        .run => |config| try std.testing.expectEqual(std.math.maxInt(u32), config.seed),
        else => try std.testing.expect(false),
    }
    const invalid = parse(&.{ "--seed", "wat" });
    switch (invalid) {
        .run => |config| try std.testing.expectEqual(@as(u32, 0), config.seed),
        else => try std.testing.expect(false),
    }
}

test "seed saturates unsigned long overflow before applying a negative sign" {
    const cases = [_]struct { text: [:0]const u8, expected: u32 }{
        .{ .text = "0xffffffff", .expected = 0xffffffff },
        .{ .text = "0x100000000", .expected = 0xffffffff },
        .{ .text = "4294967296", .expected = 0xffffffff },
        .{ .text = "0x123456789", .expected = 0xffffffff },
        .{ .text = "-1", .expected = 0xffffffff },
        .{ .text = "-4294967295", .expected = 1 },
        .{ .text = "-4294967296", .expected = 0xffffffff },
    };
    for (cases) |case| {
        const args = [_][:0]const u8{ "--seed", case.text };
        switch (parse(&args)) {
            .run => |config| try std.testing.expectEqual(case.expected, config.seed),
            else => try std.testing.expect(false),
        }
    }
}

test "tint accepts optional hash and requires exactly six hex digits" {
    for ([_][]const [:0]const u8{ &.{ "--tint", "3a6ea5" }, &.{ "--tint", "#3a6ea5" } }) |args| {
        switch (parse(args)) {
            .run => |config| try std.testing.expectEqual([3]u8{ 0x3a, 0x6e, 0xa5 }, config.animation.tint),
            else => try std.testing.expect(false),
        }
    }
    for ([_][]const [:0]const u8{ &.{ "--tint", "#12345" }, &.{ "--tint", "1234567" }, &.{ "--tint", "12x456" }, &.{ "--tint", "" } }) |args| {
        try std.testing.expect(parse(args) == .failure);
    }
}

test "missing values and unknown options preserve c processing order and context" {
    switch (parse(&.{"--fps"})) {
        .failure => |failure| switch (failure) {
            .needs_value => |option| try std.testing.expectEqualStrings("--fps", option),
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
    switch (parse(&.{"--wat"})) {
        .failure => |failure| switch (failure) {
            .needs_value => |option| try std.testing.expectEqualStrings("--wat", option),
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
    switch (parse(&.{ "--wat", "value" })) {
        .failure => |failure| switch (failure) {
            .unknown => |option| try std.testing.expectEqualStrings("--wat", option),
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
}

test "failure diagnostics exactly match c" {
    const cases = [_]struct { result: Outcome, expected: []const u8 }{
        .{ .result = parse(&.{"--fps"}), .expected = "popsquares: --fps needs a value\n" },
        .{ .result = parse(&.{ "--wat", "value" }), .expected = "popsquares: unknown option --wat\n" },
        .{ .result = parse(&.{ "--fps", "0" }), .expected = "popsquares: --fps must be between 1 and 240\n" },
        .{ .result = parse(&.{ "--pop", "0" }), .expected = "popsquares: --pop must be between 0.1 and 600\n" },
        .{ .result = parse(&.{ "--seconds", "10000001" }), .expected = "popsquares: --seconds must be between 0 and 1e+07\n" },
        .{ .result = parse(&.{ "--tint", "xyz" }), .expected = "popsquares: --tint wants RRGGBB hex, got xyz\n" },
    };
    for (cases) |case| {
        var capture = Capture{ .buffer = undefined };
        try case.result.write(&capture);
        try std.testing.expectEqualStrings(case.expected, capture.buffer[0..capture.used]);
    }
}

const Capture = struct {
    buffer: [128]u8,
    used: usize = 0,

    pub fn writeAll(self: *Capture, bytes: []const u8) !void {
        @memcpy(self.buffer[self.used .. self.used + bytes.len], bytes);
        self.used += bytes.len;
    }

    pub fn print(self: *Capture, comptime format: []const u8, args: anytype) !void {
        var rendered: [128]u8 = undefined;
        try self.writeAll(std.fmt.bufPrint(&rendered, format, args) catch return error.NoSpaceLeft);
    }
};
