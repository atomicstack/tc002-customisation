//! test aggregator: every pure module is listed here so `zig build test` covers it.
test {
    _ = @import("panel/geometry.zig");
    _ = @import("panel/pack.zig");
    _ = @import("panel/presenter.zig");
    _ = @import("scene/scene.zig");
    _ = @import("scene/popsquares.zig");
    _ = @import("scene/plasma.zig");
    _ = @import("scene/font.zig");
    _ = @import("scene/tz.zig");
    _ = @import("scene/clock.zig");
    _ = @import("scene/ip.zig");
    _ = @import("input/evdev.zig");
    _ = @import("input/actions.zig");
    _ = @import("scene/arbiter.zig");
    _ = @import("ipc/codec.zig");
    _ = @import("ipc/messages.zig");
    _ = @import("ipc/dedup.zig");
    _ = @import("supervisor/child.zig");
    _ = @import("supervisor/maintenance.zig");
    _ = @import("tc002d/cli.zig");
    _ = @import("tc002d/sched.zig");
}
