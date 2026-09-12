//! writes the api's static `/scenes` document to the path given as argv[1].
//!
//! the mock device used to carry its own hand-typed copy of every catalogue — bases, generators
//! and their parameter tables, clock fonts, digit styles, gradients, ip layouts, transitions — and
//! it drifted from the runtime exactly the way the console's javascript renderer did (popsquares
//! and plasma were still reported as declaring no parameters long after they grew some). this
//! emits the same bytes `GET /api/v1/scenes` serves, so there is one table and no second copy.
const std = @import("std");
const api = @import("net/api.zig");

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    const out = it.next() orelse return error.MissingOutputPath;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out, .data = api.scenes_body });
}
