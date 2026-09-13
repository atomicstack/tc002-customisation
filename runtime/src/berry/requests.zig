//! named execution policy: which stored script a run request may reach, and why it may not.
//!
//! designed by codex-panel, who wrote these tests before handing the runtime side over. the rules
//! worth keeping deliberate are the two that are easy to get wrong: a run carries **no source**,
//! because a run route that accepts a body is an eval route wearing a disguise and `SECURITY.md`
//! says there deliberately is not one; and a run while berry is off **reports** that rather than
//! enabling it as a side effect.
const std = @import("std");
const store = @import("store.zig");
const messages = @import("../ipc/messages.zig");

pub const RunError = error{ InvalidName, UnexpectedBody, NotFound, Disabled, Unavailable, Busy };

/// the message that runs a stored script: an `eval` of its own source, so the interpreter runs it
/// and nothing is written back. the store is only read.
pub fn prepareRun(
    scripts: *const store.Store,
    name: []const u8,
    source: []const u8,
    enabled: bool,
    running: bool,
    busy: bool,
) RunError!messages.BerryScript {
    if (!store.validName(name)) return error.InvalidName;
    if (source.len != 0) return error.UnexpectedBody;
    if (!enabled) return error.Disabled;
    if (!running) return error.Unavailable;
    var it = scripts.iterate();
    const found = while (it.next()) |e| {
        if (std.mem.eql(u8, e.name, name)) break e;
    } else return error.NotFound;
    if (busy) return error.Busy;
    return messages.BerryScript.init(.eval, found.name, found.source);
}

const testing = std.testing;

test "named run selects stored source without changing the store" {
    var scripts = store.Store{};
    try scripts.put("hello", "print('stored')");
    const before = scripts;
    const w = try prepareRun(&scripts, "hello", "", true, true, false);
    try testing.expectEqualStrings("hello", w.name.slice());
    try testing.expectEqualStrings("print('stored')", w.slice());
    // an eval, so the supervisor answers it and never writes it back
    try testing.expectEqual(@intFromEnum(messages.BerryScript.Op.eval), w.op);
    try testing.expectEqualDeep(before, scripts);
}

test "named run refuses disabled missing busy and supplied source" {
    var scripts = store.Store{};
    try scripts.put("hello", "print('stored')");
    try testing.expectError(error.Disabled, prepareRun(&scripts, "hello", "", false, false, false));
    try testing.expectError(error.Unavailable, prepareRun(&scripts, "hello", "", true, false, false));
    try testing.expectError(error.NotFound, prepareRun(&scripts, "missing", "", true, true, false));
    try testing.expectError(error.Busy, prepareRun(&scripts, "hello", "", true, true, true));
    try testing.expectError(error.UnexpectedBody, prepareRun(&scripts, "hello", "print('injected')", true, true, false));
    try testing.expectError(error.InvalidName, prepareRun(&scripts, "bad/name", "", true, true, false));
}

test "a body is refused before the store is consulted, so a run can never smuggle source" {
    var scripts = store.Store{};
    // even for a name that does not exist, and even while disabled: the body is the objection
    try testing.expectError(error.UnexpectedBody, prepareRun(&scripts, "absent", "print('x')", false, false, true));
}
