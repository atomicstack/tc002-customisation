//! the canvas scene: a document of drawing primitives an integration pushes, so that it sends data
//! rather than composing 2,496 bytes of rgb itself. everything the panel knows about drawing — the
//! four fonts, the scroll pacing, the transitions — lives in here already and was not reachable
//! from outside the runtime.
//!
//! this is the scene shell. it holds no document yet and draws the hint that says so, because an
//! empty canvas is a state worth showing rather than a black panel that looks like a fault. the
//! document, the elements and their animations arrive in the following commits.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const scene = @import("scene.zig");

/// how an empty canvas says so: dim, so it never looks like content
const hint = "canvas";
const hint_colour: [3]u8 = .{ 64, 64, 64 };

/// what this scene can be told. the document's own controls (clear, and how many elements it
/// holds) arrive with the document.
pub const params = [_]param.Param{};

pub const State = struct {
    /// how many elements the document holds; nothing can push one yet
    count: u8 = 0,

    pub fn getParam(_: *const State, _: usize) u32 {
        return 0;
    }

    pub fn setParam(_: *State, _: usize, _: u32) void {}

    pub fn empty(self: *const State) bool {
        return self.count == 0;
    }

    pub fn render(self: *const State, now_ns: u64, rgb: *geometry.Rgb) void {
        _ = now_ns;
        @memset(rgb, 0);
        if (!self.empty()) return; // the document draws itself, once there is one
        const w = font.textWidth(hint);
        const x: i32 = @intCast((geometry.width - w) / 2);
        const y: i32 = @intCast((geometry.height - font.glyph_h) / 2);
        font.blit(rgb, x, y, hint, hint_colour);
    }

    /// an empty canvas has nothing to animate, and a static document will not either: only an
    /// element that declares an animation makes this continuous.
    pub fn cadence(self: *const State) scene.Cadence {
        _ = self;
        return .idle;
    }
};

test "an empty canvas draws its hint rather than nothing, and asks for no redraws" {
    const s = State{};
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expect(!std.mem.eql(u8, &geometry.black_rgb, &rgb));
    try std.testing.expectEqual(scene.Cadence.idle, s.cadence());

    // dim, and only in the middle band: an empty canvas must not read as content
    var lit: usize = 0;
    for (0..geometry.pixels) |i| {
        const v = rgb[i * 3];
        if (v == 0) continue;
        lit += 1;
        try std.testing.expectEqual(hint_colour[0], v);
        const y = i / geometry.width;
        try std.testing.expect(y >= 4 and y < 12);
    }
    try std.testing.expect(lit > 20);
}

test "a document, once there is one, draws in place of the hint" {
    var s = State{ .count = 1 };
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqualSlices(u8, &geometry.black_rgb, &rgb);
    s.count = 0;
    s.render(0, &rgb);
    try std.testing.expect(!std.mem.eql(u8, &geometry.black_rgb, &rgb));
}
