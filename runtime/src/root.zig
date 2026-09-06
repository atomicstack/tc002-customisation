//! test aggregator: every pure module is listed here so `zig build test` covers it.
test {
    _ = @import("panel/geometry.zig");
    _ = @import("panel/pack.zig");
    _ = @import("panel/presenter.zig");
    _ = @import("scene/scene.zig");
    _ = @import("scene/popsquares.zig");
    _ = @import("scene/plasma.zig");
}
