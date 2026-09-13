//! strict json for the api's request bodies: at most 4,096 bytes and eight levels deep, unknown
//! fields and duplicate keys rejected, invalid utf-8 rejected, parsed into typed structs from a
//! fixed per-request arena that is reset after use.
const std = @import("std");

pub const max_body = 8192;
pub const max_depth = 8;
/// the parsed form of a body: the struct tree plus a copy of every string in it, so it has to be
/// comfortably larger than the body itself
pub const arena_size = 16384;

pub const Error = error{ TooLarge, TooDeep, InvalidJson, UnknownField, DuplicateField, MissingField, OutOfRange, NotWhole };

/// where a parse gave up. `InvalidJson` covers a body that is not json at all and says nothing
/// useful about a body that is; a number the schema cannot hold is the common mistake, and the
/// client deserves to hear which field it was for.
pub const Where = struct {
    /// bytes into the body, as the scanner had it when it stopped
    offset: usize = 0,
    /// the field the parser was reading, a slice of the body. empty when there is none to name.
    field: []const u8 = "",
};

const Sample = struct { text: []const u8, colour: ?[]const u8 = null, duration: u16 = 5 };

test "a valid body parses with defaults" {
    var arena: [arena_size]u8 = undefined;
    const v = try parseT(Sample, "{\"text\":\"hi\",\"colour\":\"ff0000\"}", &arena);
    try std.testing.expectEqualStrings("hi", v.text);
    try std.testing.expectEqualStrings("ff0000", v.colour.?);
    try std.testing.expectEqual(@as(u16, 5), v.duration);
}

test "unknown, duplicate and missing fields are rejected" {
    var arena: [arena_size]u8 = undefined;
    try std.testing.expectError(error.UnknownField, parseT(Sample, "{\"text\":\"a\",\"bogus\":1}", &arena));
    try std.testing.expectError(error.DuplicateField, parseT(Sample, "{\"text\":\"a\",\"text\":\"b\"}", &arena));
    try std.testing.expectError(error.MissingField, parseT(Sample, "{\"duration\":3}", &arena));
}

test "size, depth, syntax, types and utf-8 are enforced" {
    var arena: [arena_size]u8 = undefined;
    var big: [max_body + 1]u8 = undefined;
    @memset(&big, ' ');
    try std.testing.expectError(error.TooLarge, parseT(Sample, &big, &arena));
    try std.testing.expectError(error.TooDeep, parseT(Sample, "{\"text\":[[[[[[[[1]]]]]]]]}", &arena));
    try std.testing.expect(depthOk("{\"text\":[[[[[[[1]]]]]]]}"));
    try std.testing.expectError(error.InvalidJson, parseT(Sample, "{\"text\":\"a\"", &arena));
    try std.testing.expectError(error.InvalidJson, parseT(Sample, "{\"text\":7}", &arena));
    try std.testing.expectError(error.InvalidJson, parseT(Sample, "{\"text\":\"a\",\"duration\":NaN}", &arena));
    // a number the field cannot hold is its own error, so the caller can name the field
    try std.testing.expectError(error.OutOfRange, parseT(Sample, "{\"text\":\"a\",\"duration\":-1}", &arena));
    try std.testing.expectError(error.OutOfRange, parseT(Sample, "{\"text\":\"a\",\"duration\":70000}", &arena));
    try std.testing.expectError(error.NotWhole, parseT(Sample, "{\"text\":\"a\",\"duration\":1.5}", &arena));
    try std.testing.expectError(error.InvalidJson, parseT(Sample, "{\"text\":\"\xff\"}", &arena));
    try std.testing.expectError(error.InvalidJson, parseT(Sample, "[1,2]", &arena));
}

test "the field a parse gave up in is the one the client mistyped" {
    var arena: [arena_size]u8 = undefined;
    var where = Where{};
    try std.testing.expectError(error.OutOfRange, parse(Sample, "{\"text\":\"a\",\"duration\":70000}", &arena, &where));
    try std.testing.expectEqualStrings("duration", where.field);
    // a syntax error has no field to name, and an ok parse leaves nothing behind
    try std.testing.expectError(error.InvalidJson, parse(Sample, "[1,2]", &arena, &where));
    try std.testing.expectEqualStrings("", where.field);
    _ = try parse(Sample, "{\"text\":\"hi\"}", &arena, &where);
    try std.testing.expectEqualStrings("", where.field);
}

test "fieldAt reads the key a byte offset sits under" {
    const body = "{\"elements\":[{\"type\":\"sparkline\",\"data\":[1,2,300]}]}";
    // a number inside a list answers with the field that holds the list, not with nothing
    try std.testing.expectEqualStrings("data", fieldAt(body, std.mem.indexOf(u8, body, "300").? + 4));
    try std.testing.expectEqualStrings("type", fieldAt(body, std.mem.indexOf(u8, body, "sparkline").?));
    // a string value is not a key: `"data"` here is the value of `text`, not a field name
    try std.testing.expectEqualStrings("text", fieldAt("{\"text\":\"data\",\"n\":9}", 14));
    // nothing to name rather than a guess
    try std.testing.expectEqualStrings("", fieldAt("[1,2,3]", 4));
    try std.testing.expectEqualStrings("", fieldAt("", 0));
    // a key that would need escaping in an error body is not one to quote back
    try std.testing.expectEqualStrings("", fieldAt("{\"a\\\"b\":300}", 10));
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

/// the tests do not care where a parse gave up
fn parseT(comptime T: type, body: []const u8, arena: []u8) Error!T {
    var where = Where{};
    return parse(T, body, arena, &where);
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

/// parse `body` into `T`; strings inside the result point into `arena`. on failure `where` is
/// filled in with the field the parser was reading, which is a slice of `body` and so outlives
/// the arena.
pub fn parse(comptime T: type, body: []const u8, arena: []u8, where: *Where) Error!T {
    where.* = .{};
    if (body.len > max_body) return error.TooLarge;
    if (!depthOk(body)) return error.TooDeep;
    var fba = std.heap.FixedBufferAllocator.init(arena);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), body);
    defer scanner.deinit();
    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(T, fba.allocator(), &scanner, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    }) catch |e| {
        const at: usize = @min(@as(usize, @intCast(diagnostics.getByteOffset())), body.len);
        where.* = .{ .offset = at, .field = fieldAt(body, at) };
        return switch (e) {
            error.UnknownField => error.UnknownField,
            error.DuplicateField => error.DuplicateField,
            error.MissingField => error.MissingField,
            error.OutOfMemory => error.TooLarge,
            // a number outside the range its field's type holds, or one with a fractional part.
            // both reach here as a whole-body "not valid json", which is true and useless.
            error.Overflow => error.OutOfRange,
            error.InvalidNumber => error.NotWhole,
            else => error.InvalidJson,
        };
    };
}

/// the field the parser was inside at `offset`: a forward walk remembering the most recent key at
/// each container depth, so a number deep in a list still answers with the field holding the list.
/// only a plain name is returned -- an error body is assembled with `bufPrint` and escapes nothing
/// it quotes, so a key with a quote or a backslash in it is not one to echo back.
pub fn fieldAt(body: []const u8, offset: usize) []const u8 {
    var keys: [max_depth + 2][]const u8 = @splat("");
    var depth: usize = 0;
    var i: usize = 0;
    const end = @min(offset, body.len);
    while (i < end) {
        switch (body[i]) {
            '"' => {
                const start = i + 1;
                i += 1;
                while (i < body.len) : (i += 1) {
                    if (body[i] == '\\') {
                        i += 1;
                        continue;
                    }
                    if (body[i] == '"') break;
                }
                const text = body[start..@min(i, body.len)];
                i += 1;
                // a key is a string with a colon after it; a value is a string without one
                var j = i;
                while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) j += 1;
                if (j < body.len and body[j] == ':') keys[depth] = text;
            },
            '{', '[' => {
                depth += 1;
                if (depth >= keys.len) return "";
                keys[depth] = "";
                i += 1;
            },
            '}', ']' => {
                depth -|= 1;
                i += 1;
            },
            else => i += 1,
        }
    }
    // inside a list there is no key at this depth; the field is the one that holds the list
    while (true) : (depth -= 1) {
        if (plainName(keys[depth])) return keys[depth];
        if (depth == 0) return "";
    }
}

fn plainName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}
