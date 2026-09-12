//! strict json for the api's request bodies: at most 4,096 bytes and eight levels deep, unknown
//! fields and duplicate keys rejected, invalid utf-8 rejected, parsed into typed structs from a
//! fixed per-request arena that is reset after use.
const std = @import("std");

pub const max_body = 8192;
pub const max_depth = 8;
/// the parsed form of a body: the struct tree plus a copy of every string in it, so it has to be
/// comfortably larger than the body itself
pub const arena_size = 16384;

pub const Error = error{ TooLarge, TooDeep, InvalidJson, UnknownField, DuplicateField, MissingField };

const Sample = struct { text: []const u8, colour: ?[]const u8 = null, duration: u16 = 5 };

test "a valid body parses with defaults" {
    var arena: [arena_size]u8 = undefined;
    const v = try parse(Sample, "{\"text\":\"hi\",\"colour\":\"ff0000\"}", &arena);
    try std.testing.expectEqualStrings("hi", v.text);
    try std.testing.expectEqualStrings("ff0000", v.colour.?);
    try std.testing.expectEqual(@as(u16, 5), v.duration);
}

test "unknown, duplicate and missing fields are rejected" {
    var arena: [arena_size]u8 = undefined;
    try std.testing.expectError(error.UnknownField, parse(Sample, "{\"text\":\"a\",\"bogus\":1}", &arena));
    try std.testing.expectError(error.DuplicateField, parse(Sample, "{\"text\":\"a\",\"text\":\"b\"}", &arena));
    try std.testing.expectError(error.MissingField, parse(Sample, "{\"duration\":3}", &arena));
}

test "size, depth, syntax, types and utf-8 are enforced" {
    var arena: [arena_size]u8 = undefined;
    var big: [max_body + 1]u8 = undefined;
    @memset(&big, ' ');
    try std.testing.expectError(error.TooLarge, parse(Sample, &big, &arena));
    try std.testing.expectError(error.TooDeep, parse(Sample, "{\"text\":[[[[[[[[1]]]]]]]]}", &arena));
    try std.testing.expect(depthOk("{\"text\":[[[[[[[1]]]]]]]}"));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "{\"text\":\"a\"", &arena));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "{\"text\":7}", &arena));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "{\"text\":\"a\",\"duration\":NaN}", &arena));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "{\"text\":\"a\",\"duration\":-1}", &arena));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "{\"text\":\"\xff\"}", &arena));
    try std.testing.expectError(error.InvalidJson, parse(Sample, "[1,2]", &arena));
}

test "brackets inside strings do not count towards depth" {
    try std.testing.expect(depthOk("{\"text\":\"[[[[[[[[[[[[\"}"));
    try std.testing.expect(depthOk("{\"text\":\"\\\"[[[[[[[[[[\"}"));
}

test "the parse arena stays ahead of the body it has to hold" {
    // every string in a body is copied into the arena alongside the struct tree it hangs off, so
    // an arena that is not comfortably larger than the body turns a large document into
    // error.TooLarge at the allocator rather than a clean 413. raising one without the other is
    // the mistake this catches.
    try std.testing.expect(arena_size >= 2 * max_body);
}

/// bracket depth outside strings; false when deeper than `max_depth`.
pub fn depthOk(body: []const u8) bool {
    var depth: u32 = 0;
    var in_string = false;
    var escaped = false;
    for (body) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_depth) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// parse `body` into `T`; strings inside the result point into `arena`.
pub fn parse(comptime T: type, body: []const u8, arena: []u8) Error!T {
    if (body.len > max_body) return error.TooLarge;
    if (!depthOk(body)) return error.TooDeep;
    var fba = std.heap.FixedBufferAllocator.init(arena);
    return std.json.parseFromSliceLeaky(T, fba.allocator(), body, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |e| switch (e) {
        error.UnknownField => error.UnknownField,
        error.DuplicateField => error.DuplicateField,
        error.MissingField => error.MissingField,
        error.OutOfMemory => error.TooLarge,
        else => error.InvalidJson,
    };
}
