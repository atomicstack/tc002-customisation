//! test aggregator: every pure module is listed here so `zig build test` covers it.
test {
    _ = @import("panel/geometry.zig");
}
