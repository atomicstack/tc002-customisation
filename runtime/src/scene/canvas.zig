//! the canvas scene: a document of drawing primitives an integration pushes, so that it sends data
//! rather than composing 2,496 bytes of rgb itself. everything the panel knows about drawing — the
//! four fonts, the scroll pacing, the transitions — lives in here already and was not reachable
//! from outside the runtime.
//!
//! a document is a flat, copyable value: a fixed array of elements over two byte pools, one for
//! text and one for sample data, so it encodes to the ipc wire almost by memcpy and holds no
//! pointers. elements draw in the order they were given, painter-style, and every primitive clips
//! at the panel edge rather than refusing to be placed, so an integration can animate something in
//! from off-screen.
//!
//! pure: no allocation, no clock of its own, nothing but the buffer it is handed.
const std = @import("std");
const param = @import("param.zig");
const geometry = @import("../panel/geometry.zig");
const font = @import("font.zig");
const clockfont = @import("clockfont.zig");
const icons = @import("icons.zig");
const scene = @import("scene.zig");

pub const max_elements = 24;
pub const text_pool = 256;
pub const data_pool = 1024;
pub const id_max = 8;
/// a sparkline holds at most one sample per panel column
pub const samples_max = geometry.width;

/// how an empty canvas says so: dim, so it never looks like content
const hint = "canvas";
const hint_colour: [3]u8 = .{ 64, 64, 64 };

pub const Kind = enum(u8) { text, rect, line, circle, pixel, bar, sparkline, icon, sprite, tile };

/// how many uploaded sprites the device keeps, and how big one may be
pub const sprite_max = 8;
pub const sprite_side_max = 16;
pub const sprite_bytes_max = sprite_side_max * sprite_side_max * 3;

/// a picture an integration uploaded, drawn as-is. the built-in icons are monochrome and take the
/// element's colour; a sprite carries its own, which is what makes it the answer for anything the
/// set does not have.
pub const Sprite = struct {
    id: Id = .{},
    w: u8 = 0,
    h: u8 = 0,
    rgb: [sprite_bytes_max]u8 = [_]u8{0} ** sprite_bytes_max,

    pub const wire_len = 9 + 2 + sprite_bytes_max;

    pub fn bytes(self: *const Sprite) usize {
        return @as(usize, self.w) * self.h * 3;
    }
};

/// the renderer's sprite cache: volatile, replayed by the supervisor when the renderer restarts
pub const Sprites = struct {
    items: [sprite_max]Sprite = [_]Sprite{.{}} ** sprite_max,
    count: u8 = 0,

    pub fn find(self: *const Sprites, id: []const u8) ?*const Sprite {
        for (self.items[0..self.count]) |*sp| if (sp.id.eql(id)) return sp;
        return null;
    }

    /// replace one of the same id, or take the next slot
    pub fn put(self: *Sprites, sp: Sprite) error{Full}!void {
        for (self.items[0..self.count]) |*have| if (have.id.eql(sp.id.slice())) {
            have.* = sp;
            return;
        };
        if (self.count >= sprite_max) return error.Full;
        self.items[self.count] = sp;
        self.count += 1;
    }

    pub fn remove(self: *Sprites, id: []const u8) bool {
        for (self.items[0..self.count], 0..) |*sp, i| {
            if (!sp.id.eql(id)) continue;
            for (i..self.count - 1) |j| self.items[j] = self.items[j + 1];
            self.count -= 1;
            return true;
        }
        return false;
    }
};

/// what an element does on its own, so an integration pushes once and walks away. five run
/// continuously; `scramble`, `typewriter` and `sweep` are arrivals, which run once and then hold,
/// and start again when the value they are showing changes.
pub const Motion = enum(u8) { none, hue, bounce, scramble, scroll, blink, pulse, typewriter, sweep };

pub fn arrival(m: Motion) bool {
    return m == .scramble or m == .typewriter or m == .sweep;
}

pub const Animation = struct {
    kind: Motion = .none,
    /// the period: one full turn of the hue, one bounce, one blink, one pixel of scroll, or the
    /// whole of an arrival
    ms: u16 = 1000,
    /// 0..100 of the period, so a row of tiles does not move in lockstep
    phase: u8 = 0,
    /// bounce: pixels of travel. blink: the lit percentage of the period. otherwise unused.
    amount: u8 = 0,
    /// bounce along x rather than y
    axis_x: bool = false,

    pub const wire_len = 6;
};

/// `small` is the 5x7 with every printable character. `mini` is the 3x5 of the menus: letters,
/// digits and a little punctuation. `block` and `big` are the clock's own faces and carry **digits
/// and a colon only** — they are for a number a room away, not for words.
pub const Font = enum(u8) { small, mini, block, big };
pub const Align = enum(u8) { left, centre, right };
pub const Style = enum(u8) { line, bars, area };

pub const Id = struct {
    bytes: [id_max]u8 = [_]u8{0} ** id_max,
    len: u8 = 0,

    pub fn init(text: []const u8) Id {
        var id = Id{};
        id.len = @intCast(@min(text.len, id_max));
        @memcpy(id.bytes[0..id.len], text[0..id.len]);
        return id;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Id, text: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.slice(), text);
    }
};

/// a run inside one of the document's pools
pub const Span = struct { off: u16 = 0, len: u16 = 0 };

/// where an element sits. a width or height of zero means "as big as it needs to be", which for
/// text is the width of the string and for everything else the rest of the panel.
pub const Box = struct {
    x: i16 = 0,
    y: i16 = 0,
    w: i16 = 0,
    h: i16 = 0,

    pub fn width(self: Box, natural: i32) i32 {
        return if (self.w > 0) self.w else natural;
    }

    pub fn height(self: Box, natural: i32) i32 {
        return if (self.h > 0) self.h else natural;
    }

    /// the column shorthand: tile n of m, full height
    pub fn tile(n: u8, of: u8) Box {
        const m: i32 = @max(1, of);
        const i: i32 = @min(n, of -| 1);
        const x0 = @divTrunc(i * geometry.width, m);
        const x1 = @divTrunc((i + 1) * geometry.width, m);
        return .{ .x = @intCast(x0), .y = 0, .w = @intCast(x1 - x0), .h = geometry.height };
    }

    /// and the row shorthand: row n of m, full width
    pub fn row(n: u8, of: u8) Box {
        const m: i32 = @max(1, of);
        const i: i32 = @min(n, of -| 1);
        const y0 = @divTrunc(i * geometry.height, m);
        const y1 = @divTrunc((i + 1) * geometry.height, m);
        return .{ .x = 0, .y = @intCast(y0), .w = geometry.width, .h = @intCast(y1 - y0) };
    }
};

pub const Body = union(Kind) {
    text: struct { span: Span = .{}, face: Font = .small, alignment: Align = .left },
    rect: struct { filled: bool = false },
    line: struct { x2: i16 = 0, y2: i16 = 0 },
    circle: struct { r: u8 = 1, filled: bool = false },
    pixel: void,
    bar: struct { value: u8 = 0, background: [3]u8 = .{ 0, 0, 0 }, vertical: bool = false },
    sparkline: struct {
        span: Span = .{},
        style: Style = .line,
        /// the sample range; when they are equal the line scales to what it holds
        min: u8 = 0,
        max: u8 = 0,
        /// samples at or above `threshold` draw in `over`; unset when threshold is 0
        threshold: u8 = 0,
        over: [3]u8 = .{ 255, 0, 0 },
    },
    icon: struct { index: u8 = 0 },
    sprite: struct { id: Id = .{} },
    /// the composite an integration reaches for first: a glyph, a label and a value, laid out by
    /// the device because the device is where the font metrics are. a patch's `text` replaces the
    /// **value**, which is the part that changes.
    tile: struct {
        icon: u8 = 0,
        /// a sprite instead, when it has an id
        sprite_id: Id = .{},
        label: Span = .{},
        value: Span = .{},
        accent: [3]u8 = .{ 128, 128, 128 },
    },
};

pub const Element = struct {
    id: Id = .{},
    box: Box = .{},
    colour: [3]u8 = .{ 255, 255, 255 },
    anim: Animation = .{},
    body: Body,

    pub fn kind(self: *const Element) Kind {
        return std.meta.activeTag(self.body);
    }
};

pub const Error = error{ Full, TooLong };

pub const Document = struct {
    elements: [max_elements]Element = [_]Element{.{ .body = .pixel }} ** max_elements,
    count: u8 = 0,
    text: [text_pool]u8 = [_]u8{0} ** text_pool,
    text_len: u16 = 0,
    data: [data_pool]u8 = [_]u8{0} ** data_pool,
    data_len: u16 = 0,
    /// bumped on every accepted change, so a client can tell which document it is looking at
    revision: u32 = 0,

    pub fn empty(self: *const Document) bool {
        return self.count == 0;
    }

    pub fn clear(self: *Document) void {
        const rev = self.revision;
        self.* = .{};
        self.revision = rev + 1;
    }

    /// append text and return where it landed; compacts first if it would not otherwise fit
    pub fn addText(self: *Document, bytes: []const u8) Error!Span {
        if (bytes.len > text_pool) return error.TooLong;
        if (self.text_len + bytes.len > text_pool) self.compactText();
        if (self.text_len + bytes.len > text_pool) return error.Full;
        const span = Span{ .off = self.text_len, .len = @intCast(bytes.len) };
        @memcpy(self.text[span.off .. span.off + span.len], bytes);
        self.text_len += span.len;
        return span;
    }

    pub fn addData(self: *Document, bytes: []const u8) Error!Span {
        if (bytes.len > samples_max) return error.TooLong;
        if (self.data_len + bytes.len > data_pool) self.compactData();
        if (self.data_len + bytes.len > data_pool) return error.Full;
        const span = Span{ .off = self.data_len, .len = @intCast(bytes.len) };
        @memcpy(self.data[span.off .. span.off + span.len], bytes);
        self.data_len += span.len;
        return span;
    }

    pub fn add(self: *Document, e: Element) Error!void {
        if (self.count >= max_elements) return error.Full;
        self.elements[self.count] = e;
        self.count += 1;
    }

    pub fn textOf(self: *const Document, span: Span) []const u8 {
        if (span.off + span.len > self.text_len) return "";
        return self.text[span.off .. span.off + span.len];
    }

    pub fn dataOf(self: *const Document, span: Span) []const u8 {
        if (span.off + span.len > self.data_len) return "";
        return self.data[span.off .. span.off + span.len];
    }

    pub fn find(self: *Document, id: []const u8) ?*Element {
        for (self.elements[0..self.count]) |*e| if (e.id.eql(id)) return e;
        return null;
    }

    /// the pools are append-only, so a patch that lengthens a string walks the pool forward; when
    /// it runs out, everything still referenced is copied down and the spans repointed. that is
    /// the whole memory management here.
    fn compactText(self: *Document) void {
        var fresh: [text_pool]u8 = undefined;
        var len: u16 = 0;
        for (self.elements[0..self.count]) |*e| {
            switch (e.body) {
                .text => |*t| {
                    const old = self.textOf(t.span);
                    @memcpy(fresh[len .. len + old.len], old);
                    t.span = .{ .off = len, .len = @intCast(old.len) };
                    len += @intCast(old.len);
                },
                .tile => |*t| {
                    inline for (.{ "label", "value" }) |field| {
                        const old = self.textOf(@field(t, field));
                        @memcpy(fresh[len .. len + old.len], old);
                        @field(t, field) = .{ .off = len, .len = @intCast(old.len) };
                        len += @intCast(old.len);
                    }
                },
                else => {},
            }
        }
        @memcpy(self.text[0..len], fresh[0..len]);
        self.text_len = len;
    }

    fn compactData(self: *Document) void {
        var fresh: [data_pool]u8 = undefined;
        var len: u16 = 0;
        for (self.elements[0..self.count]) |*e| {
            if (e.body != .sparkline) continue;
            const old = self.dataOf(e.body.sparkline.span);
            @memcpy(fresh[len .. len + old.len], old);
            e.body.sparkline.span = .{ .off = len, .len = @intCast(old.len) };
            len += @intCast(old.len);
        }
        @memcpy(self.data[0..len], fresh[0..len]);
        self.data_len = len;
    }
};

// --- motion -------------------------------------------------------------------------------------

/// a quarter-turn of sine, scaled to 0..255 and built at compile time: `@sin` lowers to a libm call
/// this binary cannot link, and the cube learned the same lesson.
const sine = blk: {
    @setEvalBranchQuota(20000);
    var table: [256]i16 = undefined;
    for (&table, 0..) |*v, i| {
        const a = @as(f64, @floatFromInt(i)) * std.math.tau / 256.0;
        v.* = @intFromFloat(@round(@sin(a) * 1000.0));
    }
    break :blk table;
};

/// sin(turns) in thousandths, turns being 0..255 around the circle
fn sin1000(turn: u8) i32 {
    return sine[turn];
}

/// where this element is in its period, 0..255, including its phase offset
fn turnOf(a: Animation, elapsed_ms: u64) u8 {
    const period: u64 = @max(1, a.ms);
    const offset: u64 = @as(u64, a.phase) * period / 100;
    return @truncate(((elapsed_ms + offset) * 256 / period) % 256);
}

/// how far through a one-shot arrival, 0..256 and capped there
fn progress(a: Animation, elapsed_ms: u64) u32 {
    const period: u64 = @max(1, a.ms);
    return @intCast(@min((elapsed_ms * 256) / period, 256));
}

/// a value the scramble can draw before a character has landed on its own
fn scrambleGlyph(seed: u64) u8 {
    var h = seed *% 0x9E3779B97F4A7C15;
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    // the printable band a flipboard would carry: digits and letters
    const set = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    return set[@as(usize, @truncate(h)) % set.len];
}

/// the element's colour once its animation has had a say
fn animatedColour(e: *const Element, elapsed_ms: u64) [3]u8 {
    return switch (e.anim.kind) {
        .hue => param.hueRgb(param.hueOf(param.rgbValue(e.colour)) +% turnOf(e.anim, elapsed_ms)),
        .pulse => blk: {
            // never all the way off: a pulse that vanishes reads as a fault
            const s = sin1000(turnOf(e.anim, elapsed_ms));
            const scale: i32 = 650 + @divTrunc(s * 350, 1000);
            break :blk .{
                @intCast(@divTrunc(@as(i32, e.colour[0]) * scale, 1000)),
                @intCast(@divTrunc(@as(i32, e.colour[1]) * scale, 1000)),
                @intCast(@divTrunc(@as(i32, e.colour[2]) * scale, 1000)),
            };
        },
        else => e.colour,
    };
}

/// where the animation has moved it to
fn animatedOffset(e: *const Element, elapsed_ms: u64, natural_w: i32, box_w: i32) [2]i32 {
    switch (e.anim.kind) {
        .bounce => {
            const travel: i32 = e.anim.amount;
            const d = @divTrunc(sin1000(turnOf(e.anim, elapsed_ms)) * travel, 1000);
            return if (e.anim.axis_x) .{ d, 0 } else .{ 0, d };
        },
        .scroll => {
            // only what does not fit scrolls, and it wraps with a panel's width of gap
            if (natural_w <= box_w) return .{ 0, 0 };
            const span: u64 = @intCast(natural_w + geometry.width);
            const per_px: u64 = @max(1, e.anim.ms);
            const moved: u64 = (elapsed_ms / per_px) % span;
            return .{ -@as(i32, @intCast(moved)), 0 };
        },
        else => return .{ 0, 0 },
    }
}

/// whether a blink is in its lit half
fn visible(e: *const Element, elapsed_ms: u64) bool {
    if (e.anim.kind != .blink) return true;
    const duty: u32 = if (e.anim.amount == 0) 50 else @min(e.anim.amount, 100);
    return @as(u32, turnOf(e.anim, elapsed_ms)) * 100 < duty * 256;
}

// --- drawing ------------------------------------------------------------------------------------

fn setPx(rgb: *geometry.Rgb, x: i32, y: i32, colour: [3]u8) void {
    if (x < 0 or y < 0 or x >= geometry.width or y >= geometry.height) return;
    const o = geometry.pixelOffset(@intCast(x), @intCast(y));
    rgb[o] = colour[0];
    rgb[o + 1] = colour[1];
    rgb[o + 2] = colour[2];
}

/// a painter that clips to a box as well as to the panel, which is what keeps a long string inside
/// the space it was given
const Clip = struct {
    rgb: *geometry.Rgb,
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn box(rgb: *geometry.Rgb, b: Box, natural_w: i32, natural_h: i32) Clip {
        const x: i32 = b.x;
        const y: i32 = b.y;
        return .{ .rgb = rgb, .x0 = x, .y0 = y, .x1 = x + b.width(natural_w), .y1 = y + b.height(natural_h) };
    }

    fn set(self: Clip, x: i32, y: i32, colour: [3]u8) void {
        if (x < self.x0 or x >= self.x1 or y < self.y0 or y >= self.y1) return;
        setPx(self.rgb, x, y, colour);
    }
};

/// a font painter that writes through a Clip, so text stops at the edge of its box
const ClipPainter = struct {
    clip: Clip,
    colour: [3]u8,

    pub fn at(self: ClipPainter, x: i32, y: i32) [3]u8 {
        _ = x;
        _ = y;
        return self.colour;
    }
};

fn textWidthOf(face: Font, text: []const u8) i32 {
    return switch (face) {
        .small => @intCast(font.textWidth(text)),
        .mini => @intCast(clockfont.textWidth(.mini, text)),
        .block => @intCast(clockfont.textWidth(.block, text)),
        .big => @intCast(clockfont.textWidth(.big, text)),
    };
}

fn textHeightOf(face: Font) i32 {
    return switch (face) {
        .small => font.glyph_h,
        .mini => clockfont.glyphHeight(.mini),
        .block => clockfont.glyphHeight(.block),
        .big => clockfont.glyphHeight(.big),
    };
}

/// draw text into a scratch buffer and copy it through the clip, so every font goes through one
/// path and none of them needs to learn about boxes
fn drawText(rgb: *geometry.Rgb, e: *const Element, text: []const u8, colour: [3]u8, offset: [2]i32) void {
    const b = e.body.text;
    const tw = textWidthOf(b.face, text);
    const th = textHeightOf(b.face);
    const box_w = e.box.width(tw);
    const x = offset[0] + switch (b.alignment) {
        .left => @as(i32, e.box.x),
        .centre => @as(i32, e.box.x) + @divTrunc(box_w - tw, 2),
        .right => @as(i32, e.box.x) + box_w - tw,
    };
    const y: i32 = @as(i32, e.box.y) + offset[1];
    var scratch = geometry.black_rgb;
    switch (b.face) {
        .small => font.blit(&scratch, x, y, text, colour),
        .mini => clockfont.blit(&scratch, x, y, .mini, text, clockfont.Solid{ .colour = colour }),
        .block => clockfont.blit(&scratch, x, y, .block, text, clockfont.Solid{ .colour = colour }),
        .big => clockfont.blit(&scratch, x, y, .big, text, clockfont.Solid{ .colour = colour }),
    }
    const clip = Clip.box(rgb, e.box, box_w, th);
    for (0..geometry.height) |sy| {
        for (0..geometry.width) |sx| {
            const o = geometry.pixelOffset(sx, sy);
            if (scratch[o] == 0 and scratch[o + 1] == 0 and scratch[o + 2] == 0) continue;
            clip.set(@intCast(sx), @intCast(sy), .{ scratch[o], scratch[o + 1], scratch[o + 2] });
        }
    }
}

fn drawRect(rgb: *geometry.Rgb, e: *const Element, offset: [2]i32, colour: [3]u8) void {
    const w = e.box.width(geometry.width - e.box.x);
    const h = e.box.height(geometry.height - e.box.y);
    const x0: i32 = @as(i32, e.box.x) + offset[0];
    const y0: i32 = @as(i32, e.box.y) + offset[1];
    var y: i32 = y0;
    while (y < y0 + h) : (y += 1) {
        var x: i32 = x0;
        while (x < x0 + w) : (x += 1) {
            const edge = x == x0 or x == x0 + w - 1 or y == y0 or y == y0 + h - 1;
            if (e.body.rect.filled or edge) setPx(rgb, x, y, colour);
        }
    }
}

fn drawLine(rgb: *geometry.Rgb, e: *const Element, offset: [2]i32, colour: [3]u8) void {
    // bresenham, so a diagonal has no gaps
    var x: i32 = @as(i32, e.box.x) + offset[0];
    var y: i32 = @as(i32, e.box.y) + offset[1];
    const x2: i32 = @as(i32, e.body.line.x2) + offset[0];
    const y2: i32 = @as(i32, e.body.line.y2) + offset[1];
    const dx = @abs(x2 - x);
    const dy = @abs(y2 - y);
    const sx: i32 = if (x < x2) 1 else -1;
    const sy: i32 = if (y < y2) 1 else -1;
    var err: i32 = @as(i32, @intCast(dx)) - @as(i32, @intCast(dy));
    var guard: u32 = 0;
    while (guard < 4 * geometry.width * geometry.height) : (guard += 1) {
        setPx(rgb, x, y, colour);
        if (x == x2 and y == y2) break;
        const e2 = 2 * err;
        if (e2 > -@as(i32, @intCast(dy))) {
            err -= @intCast(dy);
            x += sx;
        }
        if (e2 < @as(i32, @intCast(dx))) {
            err += @intCast(dx);
            y += sy;
        }
    }
}

fn drawCircle(rgb: *geometry.Rgb, e: *const Element, offset: [2]i32, colour: [3]u8) void {
    // midpoint, with the filled case drawn as spans so there are no seams
    const cx: i32 = @as(i32, e.box.x) + offset[0];
    const cy: i32 = @as(i32, e.box.y) + offset[1];
    const r: i32 = e.body.circle.r;
    if (r <= 0) {
        setPx(rgb, cx, cy, colour);
        return;
    }
    var x: i32 = r;
    var y: i32 = 0;
    var err: i32 = 1 - r;
    while (x >= y) {
        if (e.body.circle.filled) {
            var i: i32 = -x;
            while (i <= x) : (i += 1) {
                setPx(rgb, cx + i, cy + y, colour);
                setPx(rgb, cx + i, cy - y, colour);
            }
            i = -y;
            while (i <= y) : (i += 1) {
                setPx(rgb, cx + i, cy + x, colour);
                setPx(rgb, cx + i, cy - x, colour);
            }
        } else {
            for ([_][2]i32{ .{ x, y }, .{ y, x }, .{ -x, y }, .{ -y, x }, .{ x, -y }, .{ y, -x }, .{ -x, -y }, .{ -y, -x } }) |p| {
                setPx(rgb, cx + p[0], cy + p[1], colour);
            }
        }
        y += 1;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x -= 1;
            err += 2 * (y - x) + 1;
        }
    }
}

fn drawBar(rgb: *geometry.Rgb, e: *const Element, offset: [2]i32, colour: [3]u8) void {
    const b = e.body.bar;
    const w = e.box.width(geometry.width - e.box.x);
    const h = e.box.height(1);
    const x0: i32 = @as(i32, e.box.x) + offset[0];
    const y0: i32 = @as(i32, e.box.y) + offset[1];
    const pct: i32 = @min(b.value, 100);
    // the filled extent, rounded so 1% of a wide bar still lights a pixel and 99% leaves one dark
    const span = if (b.vertical) @divTrunc(pct * h + 99, 100) else @divTrunc(pct * w + 99, 100);
    var y: i32 = y0;
    while (y < y0 + h) : (y += 1) {
        var x: i32 = x0;
        while (x < x0 + w) : (x += 1) {
            const on = if (b.vertical) (y >= y0 + h - span) else (x < x0 + span);
            const paint = if (on) colour else b.background;
            if (on or !std.meta.eql(b.background, [3]u8{ 0, 0, 0 })) setPx(rgb, x, y, paint);
        }
    }
}

fn drawIcon(rgb: *geometry.Rgb, index: u8, x0: i32, y0: i32, colour: [3]u8) void {
    if (index >= icons.count) return;
    const art = icons.bitmaps[index];
    for (art, 0..) |row, y| {
        for (0..icons.size) |x| {
            if (row & (@as(u8, 0x80) >> @intCast(x)) == 0) continue;
            setPx(rgb, x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), colour);
        }
    }
}

/// a sprite carries its own colours, so it is copied rather than tinted; a black pixel is
/// transparent, which is what lets one sit over something else
fn drawSprite(rgb: *geometry.Rgb, sp: *const Sprite, x0: i32, y0: i32) void {
    for (0..sp.h) |y| {
        for (0..sp.w) |x| {
            const o = (y * sp.w + x) * 3;
            const c = [3]u8{ sp.rgb[o], sp.rgb[o + 1], sp.rgb[o + 2] };
            if (c[0] == 0 and c[1] == 0 and c[2] == 0) continue;
            setPx(rgb, x0 + @as(i32, @intCast(x)), y0 + @as(i32, @intCast(y)), c);
        }
    }
}

/// the composite: a glyph, a label and a value. wide enough and they sit side by side with the
/// label over the value; narrower and the label goes, because two characters of it would say
/// nothing. the device decides, which is the point of having the composite at all.
fn drawTile(rgb: *geometry.Rgb, d: *const Document, e: *const Element, sprites: *const Sprites, offset: [2]i32, colour: [3]u8) void {
    const t = e.body.tile;
    const x0: i32 = @as(i32, e.box.x) + offset[0];
    const y0: i32 = @as(i32, e.box.y) + offset[1];
    const w = e.box.width(geometry.width - e.box.x);
    const h = e.box.height(geometry.height - e.box.y);
    const label = d.textOf(t.label);
    const value = d.textOf(t.value);
    const glyph_w: i32 = icons.size;

    const side_by_side = w >= glyph_w + 12 and label.len > 0;
    if (side_by_side) {
        drawIconOrSprite(rgb, e, sprites, x0, y0 + @divTrunc(h - glyph_w, 2), colour);
        const tx = x0 + glyph_w + 2;
        clockfont.blit(rgb, tx, y0 + @divTrunc(h, 2) - 6, .mini, label, clockfont.Solid{ .colour = t.accent });
        clockfont.blit(rgb, tx, y0 + @divTrunc(h, 2), .mini, value, clockfont.Solid{ .colour = colour });
        return;
    }
    // stacked: the glyph on top, the value under it, both centred in the box
    const vw: i32 = @intCast(clockfont.textWidth(.mini, value));
    drawIconOrSprite(rgb, e, sprites, x0 + @divTrunc(w - glyph_w, 2), y0, colour);
    clockfont.blit(rgb, x0 + @divTrunc(w - vw, 2), y0 + glyph_w + 1, .mini, value, clockfont.Solid{ .colour = colour });
}

fn drawIconOrSprite(rgb: *geometry.Rgb, e: *const Element, sprites: *const Sprites, x: i32, y: i32, colour: [3]u8) void {
    const t = e.body.tile;
    if (t.sprite_id.len > 0) {
        if (sprites.find(t.sprite_id.slice())) |sp| drawSprite(rgb, sp, x, y);
        return;
    }
    drawIcon(rgb, t.icon, x, y, colour);
}

fn drawSparkline(rgb: *geometry.Rgb, d: *const Document, e: *const Element, offset: [2]i32, colour: [3]u8, reveal: u32) void {
    const s = e.body.sparkline;
    const samples = d.dataOf(s.span);
    if (samples.len == 0) return;
    const w = e.box.width(geometry.width - e.box.x);
    const h = e.box.height(geometry.height - e.box.y);
    if (w <= 0 or h <= 0) return;
    const x0: i32 = @as(i32, e.box.x) + offset[0];
    const y0: i32 = @as(i32, e.box.y) + offset[1];

    // the range: what was asked for, or what the samples themselves span
    var lo: i32 = s.min;
    var hi: i32 = s.max;
    if (lo >= hi) {
        lo = samples[0];
        hi = samples[0];
        for (samples) |v| {
            lo = @min(lo, v);
            hi = @max(hi, v);
        }
        if (hi == lo) hi = lo + 1; // a flat line sits on the floor rather than dividing by zero
    }

    var prev: ?i32 = null;
    var col: i32 = 0;
    while (col < w) : (col += 1) {
        // which sample this column shows: the last one is pinned to the right edge
        const idx: usize = if (w <= 1 or samples.len == 1) samples.len - 1 else @intCast(@divTrunc(col * @as(i32, @intCast(samples.len - 1)), w - 1));
        const v = std.math.clamp(@as(i32, samples[idx]), lo, hi);
        const top = y0 + h - 1 - @divTrunc((v - lo) * (h - 1), hi - lo);
        // a sweep draws what has arrived so far and nothing to its right
        if (@as(u32, @intCast(col)) * 256 > reveal * @as(u32, @intCast(w))) break;
        const paint = if (s.threshold > 0 and samples[idx] >= s.threshold) s.over else colour;
        const x = x0 + col;
        switch (s.style) {
            .bars, .area => {
                var y = top;
                while (y < y0 + h) : (y += 1) setPx(rgb, x, y, paint);
            },
            .line => {
                setPx(rgb, x, top, paint);
                // join to the previous column so a steep change is a line rather than two dots
                if (prev) |p| {
                    var y = @min(p, top);
                    const end = @max(p, top);
                    while (y <= end) : (y += 1) setPx(rgb, x, y, paint);
                }
            },
        }
        prev = top;
    }
}

pub const State = struct {
    doc: Document = .{},
    /// pictures an integration uploaded, kept here because this is where they are drawn
    sprites: Sprites = .{},
    /// when each element's arrival animation began. the renderer owns this, not the document: a
    /// document is a declaration and says nothing about when it was said.
    started_ns: [max_elements]u64 = [_]u64{0} ** max_elements,
    /// when the document itself was installed, which is where the continuous animations count from
    epoch_ns: u64 = 0,

    pub fn getParam(_: *const State, _: usize) u32 {
        return 0;
    }

    pub fn setParam(_: *State, _: usize, _: u32) void {}

    pub fn empty(self: *const State) bool {
        return self.doc.empty();
    }

    /// take a document and work out what changed. an element whose value is new restarts its
    /// arrival animation; one that merely kept its place does not, so a patch that moves a bar
    /// does not make the text beside it scramble all over again.
    pub fn install(self: *State, doc: Document, now_ns: u64) void {
        var restart: [max_elements]bool = [_]bool{true} ** max_elements;
        for (doc.elements[0..doc.count], 0..) |*e, i| {
            if (e.id.len == 0) continue;
            for (self.doc.elements[0..self.doc.count], 0..) |*old_e, j| {
                if (!old_e.id.eql(e.id.slice())) continue;
                const same = switch (e.body) {
                    .text => |t| old_e.body == .text and std.mem.eql(u8, doc.textOf(t.span), self.doc.textOf(old_e.body.text.span)),
                    .sparkline => |sp| old_e.body == .sparkline and std.mem.eql(u8, doc.dataOf(sp.span), self.doc.dataOf(old_e.body.sparkline.span)),
                    else => std.meta.eql(e.body, old_e.body),
                };
                // it keeps its clock only if it is showing the same thing it was
                if (same) {
                    restart[i] = false;
                    self.started_ns[i] = self.started_ns[j];
                }
                break;
            }
        }
        self.doc = doc;
        self.epoch_ns = now_ns;
        for (0..max_elements) |i| if (restart[i]) {
            self.started_ns[i] = now_ns;
        };
    }

    fn elapsedMs(self: *const State, i: usize, now_ns: u64) u64 {
        const from = if (arrival(self.doc.elements[i].anim.kind)) self.started_ns[i] else self.epoch_ns;
        return (now_ns -| from) / std.time.ns_per_ms;
    }

    pub fn render(self: *const State, now_ns: u64, rgb: *geometry.Rgb) void {
        @memset(rgb, 0);
        if (self.doc.empty()) {
            // a dim word rather than a black panel: an empty canvas is a state, not a fault
            const w: i32 = @intCast(font.textWidth(hint));
            font.blit(rgb, @divTrunc(geometry.width - w, 2), (geometry.height - font.glyph_h) / 2, hint, hint_colour);
            return;
        }
        for (self.doc.elements[0..self.doc.count], 0..) |*e, i| {
            const ms = self.elapsedMs(i, now_ns);
            if (!visible(e, ms)) continue;
            const colour = animatedColour(e, ms);
            var reveal: u32 = 256;
            if (e.anim.kind == .sweep) reveal = progress(e.anim, ms);
            switch (e.body) {
                .text => {
                    var buf: [text_pool]u8 = undefined;
                    const shown = self.animatedText(i, ms, &buf);
                    const natural = textWidthOf(e.body.text.face, shown);
                    const offset = animatedOffset(e, ms, natural, e.box.width(natural));
                    drawText(rgb, e, shown, colour, offset);
                },
                .rect => drawRect(rgb, e, animatedOffset(e, ms, 0, 0), colour),
                .line => drawLine(rgb, e, animatedOffset(e, ms, 0, 0), colour),
                .circle => drawCircle(rgb, e, animatedOffset(e, ms, 0, 0), colour),
                .pixel => {
                    const o = animatedOffset(e, ms, 0, 0);
                    setPx(rgb, @as(i32, e.box.x) + o[0], @as(i32, e.box.y) + o[1], colour);
                },
                .bar => drawBar(rgb, e, animatedOffset(e, ms, 0, 0), colour),
                .sparkline => drawSparkline(rgb, &self.doc, e, animatedOffset(e, ms, 0, 0), colour, reveal),
                .icon => {
                    const o = animatedOffset(e, ms, 0, 0);
                    drawIcon(rgb, e.body.icon.index, @as(i32, e.box.x) + o[0], @as(i32, e.box.y) + o[1], colour);
                },
                .sprite => {
                    const o = animatedOffset(e, ms, 0, 0);
                    if (self.sprites.find(e.body.sprite.id.slice())) |sp| drawSprite(rgb, sp, @as(i32, e.box.x) + o[0], @as(i32, e.box.y) + o[1]);
                },
                .tile => drawTile(rgb, &self.doc, e, &self.sprites, animatedOffset(e, ms, 0, 0), colour),
            }
        }
    }

    /// the string as the animation would have it: a flipboard settling left to right, or a line
    /// arriving a character at a time. anything else shows what it was given.
    fn animatedText(self: *const State, i: usize, elapsed_ms: u64, buf: []u8) []const u8 {
        const e = &self.doc.elements[i];
        const text = self.doc.textOf(e.body.text.span);
        if (text.len == 0 or text.len > buf.len) return text;
        switch (e.anim.kind) {
            .scramble => {
                const p = progress(e.anim, elapsed_ms);
                if (p >= 256) return text;
                @memcpy(buf[0..text.len], text);
                // each character lands in turn, and the ones still to land keep flipping
                for (buf[0..text.len], 0..) |*c, n| {
                    const lands_at: u32 = @intCast((n + 1) * 256 / text.len);
                    if (p >= lands_at) continue;
                    if (text[n] == ' ') continue; // a space is not a character to guess at
                    c.* = scrambleGlyph(@as(u64, elapsed_ms / 60) *% 31 +% n);
                }
                return buf[0..text.len];
            },
            .typewriter => {
                const p = progress(e.anim, elapsed_ms);
                const shown = @min(text.len, (text.len * p) / 256);
                @memcpy(buf[0..shown], text[0..shown]);
                return buf[0..shown];
            },
            else => return text,
        }
    }

    /// frames are wanted only while something is moving: a document with no animation is drawn
    /// when it changes and not again, and one that only scrambles on update goes quiet when the
    /// scramble has finished.
    pub fn cadence(self: *const State, now_ns: u64) scene.Cadence {
        for (self.doc.elements[0..self.doc.count], 0..) |*e, i| {
            switch (e.anim.kind) {
                .none => {},
                .scramble, .typewriter, .sweep => {
                    if (progress(e.anim, self.elapsedMs(i, now_ns)) < 256) return .{ .continuous = scene.frame_period_ns };
                },
                .scroll => {
                    // only text that does not fit its box actually moves
                    if (e.body == .text) {
                        const t = self.doc.textOf(e.body.text.span);
                        if (textWidthOf(e.body.text.face, t) > e.box.width(textWidthOf(e.body.text.face, t))) return .{ .continuous = scene.frame_period_ns };
                        if (e.box.w > 0 and textWidthOf(e.body.text.face, t) > e.box.w) return .{ .continuous = scene.frame_period_ns };
                    }
                },
                else => return .{ .continuous = scene.frame_period_ns },
            }
        }
        return .idle;
    }
};

/// what this scene can be told from a dial. a document is pushed, not tuned.
pub const params = [_]param.Param{};

// --- tests --------------------------------------------------------------------------------------

const white = [3]u8{ 255, 255, 255 };

fn lit(rgb: *const geometry.Rgb) usize {
    var n: usize = 0;
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] != 0 or rgb[i * 3 + 1] != 0 or rgb[i * 3 + 2] != 0) n += 1;
    }
    return n;
}

fn at(rgb: *const geometry.Rgb, x: usize, y: usize) [3]u8 {
    const o = geometry.pixelOffset(x, y);
    return .{ rgb[o], rgb[o + 1], rgb[o + 2] };
}

test "an empty canvas draws its hint rather than nothing, and asks for no redraws" {
    const s = State{};
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expect(lit(&rgb) > 20);
    try std.testing.expectEqual(scene.Cadence.idle, s.cadence(0));
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] == 0) continue;
        try std.testing.expectEqual(hint_colour[0], rgb[i * 3]); // dim, so it never reads as content
    }
}

test "a rectangle is an outline unless it is filled, and both clip at the edge" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 2, .y = 3, .w = 5, .h = 4 }, .colour = white, .body = .{ .rect = .{} } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 5 * 4 - 3 * 2), lit(&rgb)); // perimeter only
    try std.testing.expectEqual(white, at(&rgb, 2, 3));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(&rgb, 3, 4)); // hollow

    s.doc.elements[0].body.rect.filled = true;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 20), lit(&rgb));
    try std.testing.expectEqual(white, at(&rgb, 3, 4));

    // half off the panel: what fits is drawn and the rest is simply not
    s.doc.elements[0].box = .{ .x = 48, .y = 14, .w = 10, .h = 10 };
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 4 * 2), lit(&rgb));
}

test "a line joins its ends with no gaps, whichever way it runs" {
    for ([_][4]i16{ .{ 0, 0, 51, 15 }, .{ 51, 15, 0, 0 }, .{ 0, 15, 51, 0 }, .{ 10, 8, 10, 0 }, .{ 3, 3, 40, 3 } }) |c| {
        var s = State{};
        try s.doc.add(.{ .box = .{ .x = c[0], .y = c[1] }, .colour = white, .body = .{ .line = .{ .x2 = c[2], .y2 = c[3] } } });
        var rgb: geometry.Rgb = undefined;
        s.render(0, &rgb);
        try std.testing.expectEqual(white, at(&rgb, @intCast(c[0]), @intCast(c[1])));
        try std.testing.expectEqual(white, at(&rgb, @intCast(c[2]), @intCast(c[3])));
        // every column the line spans has at least one lit pixel, so there are no holes
        const lo = @min(c[0], c[2]);
        const hi = @max(c[0], c[2]);
        var x: usize = @intCast(lo);
        while (x <= hi) : (x += 1) {
            var any = false;
            for (0..geometry.height) |y| any = any or at(&rgb, x, y)[0] != 0;
            try std.testing.expect(any);
        }
    }
}

test "a circle is round, and filled means filled" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 26, .y = 8 }, .colour = white, .body = .{ .circle = .{ .r = 5 } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    const outline = lit(&rgb);
    try std.testing.expectEqual(white, at(&rgb, 31, 8)); // due east of the centre
    try std.testing.expectEqual(white, at(&rgb, 26, 3)); // and due north
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(&rgb, 26, 8)); // hollow in the middle

    s.doc.elements[0].body.circle.filled = true;
    s.render(0, &rgb);
    try std.testing.expect(lit(&rgb) > outline * 2);
    try std.testing.expectEqual(white, at(&rgb, 26, 8));
    // every lit pixel is inside the radius, allowing the half pixel a midpoint circle carries
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] == 0) continue;
        const dx: f32 = @floatFromInt(@as(i32, @intCast(i % geometry.width)) - 26);
        const dy: f32 = @floatFromInt(@as(i32, @intCast(i / geometry.width)) - 8);
        try std.testing.expect(@sqrt(dx * dx + dy * dy) <= 5.5);
    }
}

test "a bar fills its box in proportion, and rounds so the ends are honest" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 50, .h = 3 }, .colour = white, .body = .{ .bar = .{ .value = 50 } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 25 * 3), lit(&rgb));
    try std.testing.expectEqual(white, at(&rgb, 24, 1));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(&rgb, 25, 1));

    // 1% of a wide bar still shows, and 100% fills it
    s.doc.elements[0].body.bar.value = 1;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 3), lit(&rgb));
    s.doc.elements[0].body.bar.value = 100;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 150), lit(&rgb));

    // vertical fills from the bottom, which is where a level belongs
    s.doc.elements[0].box = .{ .x = 0, .y = 0, .w = 2, .h = 16 };
    s.doc.elements[0].body.bar = .{ .value = 25, .vertical = true };
    s.render(0, &rgb);
    try std.testing.expectEqual(white, at(&rgb, 0, 15));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(&rgb, 0, 0));

    // a background paints the empty part instead of leaving it dark
    s.doc.elements[0].body.bar.background = .{ 8, 8, 8 };
    s.render(0, &rgb);
    try std.testing.expectEqual([3]u8{ 8, 8, 8 }, at(&rgb, 0, 0));
}

test "a sparkline scales to its samples, pins the newest to the right, and honours a threshold" {
    var s = State{};
    const span = try s.doc.addData(&[_]u8{ 0, 25, 50, 75, 100 });
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 5, .h = 5 }, .colour = white, .body = .{ .sparkline = .{ .span = span, .style = .line } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    // rising left to right: the first column sits at the bottom, the last at the top
    try std.testing.expectEqual(white, at(&rgb, 0, 4));
    try std.testing.expectEqual(white, at(&rgb, 4, 0));

    // bars fill downwards from the value, so the newest column is full height
    s.doc.elements[0].body.sparkline.style = .bars;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 3 + 4 + 5), lit(&rgb));

    // a flat line does not divide by zero; it sits on the floor
    var flat = State{};
    const fspan = try flat.doc.addData(&[_]u8{ 7, 7, 7, 7 });
    try flat.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .colour = white, .body = .{ .sparkline = .{ .span = fspan, .style = .line } } });
    flat.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 4), lit(&rgb));
    try std.testing.expectEqual(white, at(&rgb, 0, 3));

    // a threshold recolours only the samples that reach it
    var t = State{};
    const tspan = try t.doc.addData(&[_]u8{ 10, 90 });
    try t.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 2, .h = 4 }, .colour = white, .body = .{ .sparkline = .{ .span = tspan, .style = .bars, .min = 0, .max = 100, .threshold = 50, .over = .{ 255, 0, 0 } } } });
    t.render(0, &rgb);
    try std.testing.expectEqual(white, at(&rgb, 0, 3)); // under the threshold, the normal colour
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, at(&rgb, 1, 1)); // over it, the other one
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, at(&rgb, 1, 3)); // for the whole bar
}

test "text draws in every font, aligns inside its box and is clipped by it" {
    var s = State{};
    const span = try s.doc.addText("hello");
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0 }, .colour = white, .body = .{ .text = .{ .span = span } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    const left = lit(&rgb);
    try std.testing.expect(left > 10);

    // centred in a box that is the whole panel puts it in the middle
    s.doc.elements[0].box = .{ .x = 0, .y = 0, .w = geometry.width, .h = geometry.height };
    s.doc.elements[0].body.text.alignment = .centre;
    s.render(0, &rgb);
    var min_x: usize = geometry.width;
    var max_x: usize = 0;
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] == 0) continue;
        min_x = @min(min_x, i % geometry.width);
        max_x = @max(max_x, i % geometry.width);
    }
    const margin_left = min_x;
    const margin_right = geometry.width - 1 - max_x;
    try std.testing.expect(margin_left > 0 and @abs(@as(i32, @intCast(margin_left)) - @as(i32, @intCast(margin_right))) <= 1);

    // a box narrower than the string cuts it off rather than letting it run over its neighbour
    s.doc.elements[0].box = .{ .x = 0, .y = 0, .w = 8, .h = 16 };
    s.doc.elements[0].body.text.alignment = .left;
    s.render(0, &rgb);
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3] == 0) continue;
        try std.testing.expect(i % geometry.width < 8);
    }

    // the two digit faces carry numbers, which is what they are for
    for ([_]Font{ .block, .big }) |face| {
        var n = State{};
        const nspan = try n.doc.addText("42");
        try n.doc.add(.{ .colour = white, .body = .{ .text = .{ .span = nspan, .face = face } } });
        n.render(0, &rgb);
        try std.testing.expect(lit(&rgb) > 10);
    }
}

test "tiles and rows divide the panel without gaps or overlaps" {
    var covered = [_]bool{false} ** geometry.width;
    for (0..3) |i| {
        const b = Box.tile(@intCast(i), 3);
        var x = b.x;
        while (x < b.x + b.w) : (x += 1) {
            try std.testing.expect(!covered[@intCast(x)]); // no overlap
            covered[@intCast(x)] = true;
        }
    }
    for (covered) |c| try std.testing.expect(c); // and no gap
    try std.testing.expectEqual(@as(i16, geometry.height), Box.tile(0, 3).h);

    var rows = [_]bool{false} ** geometry.height;
    for (0..4) |i| {
        const b = Box.row(@intCast(i), 4);
        var y = b.y;
        while (y < b.y + b.h) : (y += 1) {
            try std.testing.expect(!rows[@intCast(y)]);
            rows[@intCast(y)] = true;
        }
    }
    for (rows) |r| try std.testing.expect(r);
    // an out-of-range index lands on the last tile rather than off the panel
    try std.testing.expectEqual(Box.tile(2, 3), Box.tile(9, 3));
}

test "elements draw in the order they were given" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .colour = .{ 255, 0, 0 }, .body = .{ .rect = .{ .filled = true } } });
    try s.doc.add(.{ .box = .{ .x = 2, .y = 2, .w = 4, .h = 4 }, .colour = .{ 0, 255, 0 }, .body = .{ .rect = .{ .filled = true } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, at(&rgb, 3, 3)); // the later one wins where they meet
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, at(&rgb, 0, 0));
}

test "the pools fill, compact and refuse what will never fit" {
    var d = Document{};
    // a patched string walks the pool forward; when it runs out, what is live is copied down
    const a = try d.addText("first");
    try d.add(.{ .id = Id.init("a"), .body = .{ .text = .{ .span = a } } });
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        d.elements[0].body.text.span = try d.addText("0123456789");
    }
    try std.testing.expectEqualStrings("0123456789", d.textOf(d.elements[0].body.text.span));
    try std.testing.expect(d.text_len <= text_pool);

    try std.testing.expectError(error.TooLong, d.addText(&[_]u8{'x'} ** (text_pool + 1)));
    try std.testing.expectError(error.TooLong, d.addData(&[_]u8{0} ** (samples_max + 1)));

    var full = Document{};
    var n: usize = 0;
    while (n < max_elements) : (n += 1) try full.add(.{ .body = .pixel });
    try std.testing.expectError(error.Full, full.add(.{ .body = .pixel }));
}

test "an element is found by id, and one without an id is drawn but not addressable" {
    var d = Document{};
    try d.add(.{ .id = Id.init("temp"), .body = .{ .bar = .{ .value = 10 } } });
    try d.add(.{ .body = .{ .rect = .{} } }); // decoration
    try std.testing.expect(d.find("temp") != null);
    try std.testing.expect(d.find("nope") == null);
    try std.testing.expect(d.find("") == null);
    d.find("temp").?.body.bar.value = 80;
    try std.testing.expectEqual(@as(u8, 80), d.elements[0].body.bar.value);
    // an id is capped rather than rejected, so a long one still addresses its element
    const long = Id.init("abcdefghijkl");
    try std.testing.expectEqualStrings("abcdefgh", long.slice());
}

test "a cleared document is empty again and says so on the panel" {
    var s = State{};
    const span = try s.doc.addText("x");
    try s.doc.add(.{ .body = .{ .text = .{ .span = span } } });
    try std.testing.expect(!s.doc.empty());
    const before = s.doc.revision;
    s.doc.clear();
    try std.testing.expect(s.doc.empty());
    try std.testing.expectEqual(before + 1, s.doc.revision);
    try std.testing.expectEqual(@as(u16, 0), s.doc.text_len);
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual(hint_colour, at(&rgb, 11, 6)); // back to the hint
}

// --- the wire, and patching by id ---------------------------------------------------------------
//
// the document travels whole: netd parses it, the supervisor keeps it and pushes it to the
// renderer. a patch travels as a list of updates naming elements by id, because an integration
// that has already sent the layout should send only what it knows: a number, not a screen.

/// id, box, colour, kind, then the widest variant (a sparkline's eleven bytes), padded so every
/// record is the same size and the codec stays a loop rather than a state machine
pub const element_wire = 9 + 8 + 3 + Animation.wire_len + 1 + 22;
pub const wire_max = 9 + max_elements * element_wire + text_pool + data_pool;

/// one element of a patch: which element, and which of its fields to replace
pub const patch_bytes_max = 64;
pub const Field = struct {
    pub const text: u8 = 1 << 0;
    pub const data: u8 = 1 << 1;
    pub const value: u8 = 1 << 2;
    pub const colour: u8 = 1 << 3;
};

pub const Update = struct {
    id: Id = .{},
    has: u8 = 0,
    /// the replacement string or samples, whichever the element takes
    len: u8 = 0,
    bytes: [patch_bytes_max]u8 = [_]u8{0} ** patch_bytes_max,
    value: u8 = 0,
    colour: [3]u8 = .{ 0, 0, 0 },

    pub const wire_len = 9 + 1 + 1 + patch_bytes_max + 1 + 3;

    pub fn slice(self: *const Update) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Patch = struct {
    count: u8 = 0,
    items: [max_elements]Update = [_]Update{.{}} ** max_elements,

    pub const wire_max = 1 + max_elements * Update.wire_len;

    pub fn add(self: *Patch, u: Update) error{Full}!void {
        if (self.count >= max_elements) return error.Full;
        self.items[self.count] = u;
        self.count += 1;
    }
};

pub const ApplyError = error{ UnknownElement, WrongField, Full, TooLong };

/// apply one update. a field the element's kind has no use for is an error rather than a silent
/// no-op: an integration that thinks it is updating a reading should hear that it is not.
pub fn applyUpdate(d: *Document, u: *const Update) ApplyError!void {
    const e = d.find(u.id.slice()) orelse return error.UnknownElement;
    if (u.has & Field.text != 0) {
        switch (e.body) {
            .text => e.body.text.span = try d.addText(u.slice()),
            // a tile's value is what changes; its label is layout and waits for a put
            .tile => e.body.tile.value = try d.addText(u.slice()),
            else => return error.WrongField,
        }
    }
    if (u.has & Field.data != 0) {
        if (e.body != .sparkline) return error.WrongField;
        // find it again: addText/addData may have compacted the pools and moved the spans
        const target = d.find(u.id.slice()).?;
        target.body.sparkline.span = try d.addData(u.slice());
    }
    if (u.has & Field.value != 0) {
        const target = d.find(u.id.slice()).?;
        switch (target.body) {
            .bar => target.body.bar.value = u.value,
            .circle => target.body.circle.r = u.value,
            else => return error.WrongField,
        }
    }
    if (u.has & Field.colour != 0) d.find(u.id.slice()).?.colour = u.colour;
}

/// apply a whole patch, or none of it: a half-applied dashboard is worse than a rejected one, so
/// it is checked against a copy first and only committed once every update has landed.
pub fn applyPatch(d: *Document, p: *const Patch) ApplyError!void {
    var trial = d.*;
    for (p.items[0..p.count]) |*u| try applyUpdate(&trial, u);
    trial.revision = d.revision + 1;
    d.* = trial;
}

/// `std.meta.intToEnum` went away in zig 0.16; this is the same thing the ipc codec uses, kept
/// local because a scene has no business importing the ipc layer.
fn enumFromInt(comptime E: type, value: u8) ?E {
    inline for (@typeInfo(E).@"enum".fields) |f| if (f.value == value) return @enumFromInt(f.value);
    return null;
}

fn putSpan(out: []u8, s: Span) void {
    std.mem.writeInt(u16, out[0..2], s.off, .little);
    std.mem.writeInt(u16, out[2..4], s.len, .little);
}

fn getSpan(in: []const u8) Span {
    return .{ .off = std.mem.readInt(u16, in[0..2], .little), .len = std.mem.readInt(u16, in[2..4], .little) };
}

fn putElement(e: *const Element, out: []u8) void {
    @memset(out[0..element_wire], 0);
    out[0] = e.id.len;
    @memcpy(out[1..9], &e.id.bytes);
    inline for (.{ e.box.x, e.box.y, e.box.w, e.box.h }, 0..) |v, i| std.mem.writeInt(i16, out[9 + i * 2 ..][0..2], v, .little);
    @memcpy(out[17..20], &e.colour);
    out[20] = @intFromEnum(e.anim.kind);
    std.mem.writeInt(u16, out[21..23], e.anim.ms, .little);
    out[23] = e.anim.phase;
    out[24] = e.anim.amount;
    out[25] = @intFromBool(e.anim.axis_x);
    out[26] = @intFromEnum(e.kind());
    const v = out[27..];
    switch (e.body) {
        .text => |t| {
            putSpan(v, t.span);
            v[4] = @intFromEnum(t.face);
            v[5] = @intFromEnum(t.alignment);
        },
        .rect => |r| v[0] = @intFromBool(r.filled),
        .line => |l| {
            std.mem.writeInt(i16, v[0..2], l.x2, .little);
            std.mem.writeInt(i16, v[2..4], l.y2, .little);
        },
        .circle => |c| {
            v[0] = c.r;
            v[1] = @intFromBool(c.filled);
        },
        .pixel => {},
        .bar => |b| {
            v[0] = b.value;
            @memcpy(v[1..4], &b.background);
            v[4] = @intFromBool(b.vertical);
        },
        .sparkline => |s| {
            putSpan(v, s.span);
            v[4] = @intFromEnum(s.style);
            v[5] = s.min;
            v[6] = s.max;
            v[7] = s.threshold;
            @memcpy(v[8..11], &s.over);
        },
        .icon => |ic| v[0] = ic.index,
        .sprite => |sp| {
            v[0] = sp.id.len;
            @memcpy(v[1..9], &sp.id.bytes);
        },
        .tile => |t| {
            v[0] = t.icon;
            v[1] = t.sprite_id.len;
            @memcpy(v[2..10], &t.sprite_id.bytes);
            putSpan(v[10..], t.label);
            putSpan(v[14..], t.value);
            @memcpy(v[18..21], &t.accent);
        },
    }
}

fn getElement(in: []const u8) error{BadPayload}!Element {
    var e = Element{ .body = .pixel };
    e.id.len = @min(in[0], id_max);
    @memcpy(&e.id.bytes, in[1..9]);
    e.box.x = std.mem.readInt(i16, in[9..11], .little);
    e.box.y = std.mem.readInt(i16, in[11..13], .little);
    e.box.w = std.mem.readInt(i16, in[13..15], .little);
    e.box.h = std.mem.readInt(i16, in[15..17], .little);
    @memcpy(&e.colour, in[17..20]);
    e.anim = .{
        .kind = enumFromInt(Motion, in[20]) orelse return error.BadPayload,
        .ms = std.mem.readInt(u16, in[21..23], .little),
        .phase = in[23],
        .amount = in[24],
        .axis_x = in[25] != 0,
    };
    const v = in[27..];
    const kind = enumFromInt(Kind, in[26]) orelse return error.BadPayload;
    e.body = switch (kind) {
        .text => .{ .text = .{
            .span = getSpan(v),
            .face = enumFromInt(Font, v[4]) orelse return error.BadPayload,
            .alignment = enumFromInt(Align, v[5]) orelse return error.BadPayload,
        } },
        .rect => .{ .rect = .{ .filled = v[0] != 0 } },
        .line => .{ .line = .{ .x2 = std.mem.readInt(i16, v[0..2], .little), .y2 = std.mem.readInt(i16, v[2..4], .little) } },
        .circle => .{ .circle = .{ .r = v[0], .filled = v[1] != 0 } },
        .pixel => .pixel,
        .bar => .{ .bar = .{ .value = v[0], .background = v[1..4].*, .vertical = v[4] != 0 } },
        .sparkline => .{ .sparkline = .{
            .span = getSpan(v),
            .style = enumFromInt(Style, v[4]) orelse return error.BadPayload,
            .min = v[5],
            .max = v[6],
            .threshold = v[7],
            .over = v[8..11].*,
        } },
        .icon => .{ .icon = .{ .index = v[0] } },
        .sprite => blk: {
            var id = Id{ .len = @min(v[0], id_max) };
            @memcpy(&id.bytes, v[1..9]);
            break :blk .{ .sprite = .{ .id = id } };
        },
        .tile => blk: {
            var id = Id{ .len = @min(v[1], id_max) };
            @memcpy(&id.bytes, v[2..10]);
            break :blk .{ .tile = .{
                .icon = v[0],
                .sprite_id = id,
                .label = getSpan(v[10..]),
                .value = getSpan(v[14..]),
                .accent = v[18..21].*,
            } };
        },
    };
    return e;
}

/// the whole document as bytes; returns how many were written
pub fn encode(d: *const Document, out: []u8) error{Overflow}!usize {
    const total = 9 + @as(usize, d.count) * element_wire + d.text_len + d.data_len;
    if (out.len < total) return error.Overflow;
    std.mem.writeInt(u32, out[0..4], d.revision, .little);
    out[4] = d.count;
    std.mem.writeInt(u16, out[5..7], d.text_len, .little);
    std.mem.writeInt(u16, out[7..9], d.data_len, .little);
    var o: usize = 9;
    for (d.elements[0..d.count]) |*e| {
        putElement(e, out[o..]);
        o += element_wire;
    }
    @memcpy(out[o .. o + d.text_len], d.text[0..d.text_len]);
    o += d.text_len;
    @memcpy(out[o .. o + d.data_len], d.data[0..d.data_len]);
    return o + d.data_len;
}

pub fn decode(in: []const u8) error{BadPayload}!Document {
    if (in.len < 9) return error.BadPayload;
    var d = Document{};
    d.revision = std.mem.readInt(u32, in[0..4], .little);
    d.count = in[4];
    d.text_len = std.mem.readInt(u16, in[5..7], .little);
    d.data_len = std.mem.readInt(u16, in[7..9], .little);
    if (d.count > max_elements or d.text_len > text_pool or d.data_len > data_pool) return error.BadPayload;
    const total = 9 + @as(usize, d.count) * element_wire + d.text_len + d.data_len;
    if (in.len != total) return error.BadPayload;
    var o: usize = 9;
    for (0..d.count) |i| {
        d.elements[i] = try getElement(in[o..]);
        o += element_wire;
    }
    @memcpy(d.text[0..d.text_len], in[o .. o + d.text_len]);
    o += d.text_len;
    @memcpy(d.data[0..d.data_len], in[o .. o + d.data_len]);
    // a span that points outside its pool would read another element's bytes, so refuse it here
    for (d.elements[0..d.count]) |*e| switch (e.body) {
        .text => |t| if (t.span.off + t.span.len > d.text_len) return error.BadPayload,
        .sparkline => |s| if (s.span.off + s.span.len > d.data_len) return error.BadPayload,
        .tile => |t| if (t.label.off + t.label.len > d.text_len or t.value.off + t.value.len > d.text_len) return error.BadPayload,
        else => {},
    };
    return d;
}

pub fn putPatch(p: *const Patch, out: []u8) error{Overflow}!usize {
    const total = 1 + @as(usize, p.count) * Update.wire_len;
    if (out.len < total) return error.Overflow;
    out[0] = p.count;
    var o: usize = 1;
    for (p.items[0..p.count]) |*u| {
        out[o] = u.id.len;
        @memcpy(out[o + 1 .. o + 9], &u.id.bytes);
        out[o + 9] = u.has;
        out[o + 10] = u.len;
        @memcpy(out[o + 11 .. o + 11 + patch_bytes_max], &u.bytes);
        out[o + 11 + patch_bytes_max] = u.value;
        @memcpy(out[o + 12 + patch_bytes_max .. o + 15 + patch_bytes_max], &u.colour);
        o += Update.wire_len;
    }
    return o;
}

pub fn getPatch(in: []const u8) error{BadPayload}!Patch {
    if (in.len < 1) return error.BadPayload;
    var p = Patch{};
    p.count = in[0];
    if (p.count > max_elements or in.len != 1 + @as(usize, p.count) * Update.wire_len) return error.BadPayload;
    var o: usize = 1;
    for (0..p.count) |i| {
        var u = Update{};
        u.id.len = @min(in[o], id_max);
        @memcpy(&u.id.bytes, in[o + 1 .. o + 9]);
        u.has = in[o + 9];
        u.len = @min(in[o + 10], patch_bytes_max);
        @memcpy(&u.bytes, in[o + 11 .. o + 11 + patch_bytes_max]);
        u.value = in[o + 11 + patch_bytes_max];
        @memcpy(&u.colour, in[o + 12 + patch_bytes_max .. o + 15 + patch_bytes_max]);
        p.items[i] = u;
        o += Update.wire_len;
    }
    return p;
}

test "a document round-trips through the wire, whole" {
    var d = Document{};
    const hello = try d.addText("living room");
    const samples = try d.addData(&[_]u8{ 1, 2, 3, 250 });
    try d.add(.{ .id = Id.init("hdr"), .box = .{ .x = -3, .y = 0, .w = 52, .h = 6 }, .colour = .{ 1, 2, 3 }, .body = .{ .text = .{ .span = hello, .face = .mini, .alignment = .centre } } });
    try d.add(.{ .id = Id.init("g"), .box = Box.row(1, 2), .colour = .{ 4, 5, 6 }, .body = .{ .sparkline = .{ .span = samples, .style = .area, .min = 0, .max = 100, .threshold = 90, .over = .{ 7, 8, 9 } } } });
    try d.add(.{ .box = .{ .x = 1, .y = 2 }, .body = .{ .line = .{ .x2 = -9, .y2 = 15 } } });
    try d.add(.{ .body = .{ .bar = .{ .value = 66, .background = .{ 9, 9, 9 }, .vertical = true } } });
    try d.add(.{ .body = .{ .circle = .{ .r = 7, .filled = true } } });
    try d.add(.{ .body = .pixel });
    try d.add(.{ .body = .{ .rect = .{ .filled = true } } });
    d.revision = 4321;

    var buf: [wire_max]u8 = undefined;
    const n = try encode(&d, &buf);
    try std.testing.expect(n <= wire_max);
    const back = try decode(buf[0..n]);
    try std.testing.expectEqualDeep(d.elements[0..d.count], back.elements[0..back.count]);
    try std.testing.expectEqual(d.revision, back.revision);
    try std.testing.expectEqualStrings("living room", back.textOf(back.elements[0].body.text.span));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 250 }, back.dataOf(back.elements[1].body.sparkline.span));

    // and the panel cannot tell the two apart, which is the only thing that really matters
    var a: geometry.Rgb = undefined;
    var b: geometry.Rgb = undefined;
    (State{ .doc = d }).render(0, &a);
    (State{ .doc = back }).render(0, &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "a malformed document is refused rather than read" {
    var d = Document{};
    const span = try d.addText("hi");
    try d.add(.{ .body = .{ .text = .{ .span = span } } });
    var buf: [wire_max]u8 = undefined;
    const n = try encode(&d, &buf);

    try std.testing.expectError(error.BadPayload, decode(buf[0 .. n - 1])); // short
    try std.testing.expectError(error.BadPayload, decode(buf[0..3]));
    var bad_count = buf;
    bad_count[4] = max_elements + 1;
    try std.testing.expectError(error.BadPayload, decode(bad_count[0..n]));
    var bad_kind = buf;
    bad_kind[9 + 26] = 99;
    try std.testing.expectError(error.BadPayload, decode(bad_kind[0..n]));
    // a span reaching past its pool would read whatever follows it
    var bad_span = buf;
    std.mem.writeInt(u16, bad_span[9 + 27 ..][2..4], 9000, .little);
    try std.testing.expectError(error.BadPayload, decode(bad_span[0..n]));
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.Overflow, encode(&d, &small));
}

test "a patch replaces values by id, all of it or none" {
    var d = Document{};
    const t = try d.addText("20.4C");
    const s = try d.addData(&[_]u8{ 1, 2 });
    try d.add(.{ .id = Id.init("temp"), .body = .{ .text = .{ .span = t } } });
    try d.add(.{ .id = Id.init("hist"), .body = .{ .sparkline = .{ .span = s } } });
    try d.add(.{ .id = Id.init("lvl"), .colour = .{ 1, 1, 1 }, .body = .{ .bar = .{ .value = 10 } } });

    var p = Patch{};
    var u = Update{ .id = Id.init("temp"), .has = Field.text };
    u.len = 5;
    @memcpy(u.bytes[0..5], "21.1C");
    try p.add(u);
    var v = Update{ .id = Id.init("lvl"), .has = Field.value | Field.colour, .value = 80, .colour = .{ 9, 9, 9 } };
    v.len = 0;
    try p.add(v);
    try applyPatch(&d, &p);
    try std.testing.expectEqualStrings("21.1C", d.textOf(d.elements[0].body.text.span));
    try std.testing.expectEqual(@as(u8, 80), d.elements[2].body.bar.value);
    try std.testing.expectEqual([3]u8{ 9, 9, 9 }, d.elements[2].colour);
    try std.testing.expectEqual(@as(u32, 1), d.revision);

    // an unknown id, or a field the element has no use for, rejects the whole patch
    var bad = Patch{};
    try bad.add(.{ .id = Id.init("temp"), .has = Field.value, .value = 3 });
    try std.testing.expectError(error.WrongField, applyPatch(&d, &bad));
    var missing = Patch{};
    try missing.add(.{ .id = Id.init("nope"), .has = Field.colour });
    try std.testing.expectError(error.UnknownElement, applyPatch(&d, &missing));
    // and nothing moved: the first update of a rejected patch must not stand
    var partial = Patch{};
    var good = Update{ .id = Id.init("temp"), .has = Field.text };
    good.len = 4;
    @memcpy(good.bytes[0..4], "9.9C");
    try partial.add(good);
    try partial.add(.{ .id = Id.init("nope"), .has = Field.colour });
    try std.testing.expectError(error.UnknownElement, applyPatch(&d, &partial));
    try std.testing.expectEqualStrings("21.1C", d.textOf(d.elements[0].body.text.span));
    try std.testing.expectEqual(@as(u32, 1), d.revision);
}

test "a patch round-trips through its own wire form" {
    var p = Patch{};
    var u = Update{ .id = Id.init("hist"), .has = Field.data };
    u.len = 3;
    @memcpy(u.bytes[0..3], &[_]u8{ 5, 6, 7 });
    try p.add(u);
    try p.add(.{ .id = Id.init("lvl"), .has = Field.value, .value = 42 });
    var buf: [Patch.wire_max]u8 = undefined;
    const n = try putPatch(&p, &buf);
    const back = try getPatch(buf[0..n]);
    try std.testing.expectEqual(p.count, back.count);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7 }, back.items[0].slice());
    try std.testing.expectEqualStrings("lvl", back.items[1].id.slice());
    try std.testing.expectEqual(@as(u8, 42), back.items[1].value);
    try std.testing.expectError(error.BadPayload, getPatch(buf[0 .. n - 1]));
}

test "a hue animation walks the wheel and comes back, and a pulse never goes dark" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0 }, .colour = .{ 255, 0, 0 }, .anim = .{ .kind = .hue, .ms = 1000 }, .body = .pixel });
    var rgb: geometry.Rgb = undefined;
    var seen: usize = 0;
    var previous = [3]u8{ 255, 0, 0 };
    var ms: u64 = 0;
    while (ms < 1000) : (ms += 50) {
        s.render(ms * std.time.ns_per_ms, &rgb);
        const c = at(&rgb, 0, 0);
        if (!std.meta.eql(c, previous)) seen += 1;
        previous = c;
        // the wheel is fully saturated, so one channel is always at full and one at nothing
        try std.testing.expectEqual(@as(u8, 255), @max(c[0], @max(c[1], c[2])));
    }
    try std.testing.expect(seen > 10); // it really moves
    s.render(0, &rgb);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, at(&rgb, 0, 0)); // and starts where it was told

    var p = State{};
    try p.doc.add(.{ .colour = .{ 200, 200, 200 }, .anim = .{ .kind = .pulse, .ms = 400 }, .body = .pixel });
    var dimmest: u8 = 255;
    var brightest: u8 = 0;
    ms = 0;
    while (ms < 400) : (ms += 10) {
        p.render(ms * std.time.ns_per_ms, &rgb);
        const v = at(&rgb, 0, 0)[0];
        dimmest = @min(dimmest, v);
        brightest = @max(brightest, v);
    }
    try std.testing.expect(dimmest > 40); // a pulse that vanishes reads as a fault
    try std.testing.expect(brightest > dimmest + 40); // but it is clearly a pulse
}

test "a bounce travels and returns, along whichever axis it was given" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 10, .y = 8 }, .colour = white, .anim = .{ .kind = .bounce, .ms = 800, .amount = 3 }, .body = .pixel });
    var rgb: geometry.Rgb = undefined;
    var lowest: usize = 0;
    var highest: usize = 15;
    var ms: u64 = 0;
    while (ms < 800) : (ms += 20) {
        s.render(ms * std.time.ns_per_ms, &rgb);
        for (0..geometry.height) |y| {
            if (at(&rgb, 10, y)[0] == 0) continue;
            lowest = @max(lowest, y);
            highest = @min(highest, y);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), highest); // 8 - 3
    try std.testing.expectEqual(@as(usize, 11), lowest); // 8 + 3

    s.doc.elements[0].anim.axis_x = true;
    var left: usize = 52;
    var right: usize = 0;
    ms = 0;
    while (ms < 800) : (ms += 20) {
        s.render(ms * std.time.ns_per_ms, &rgb);
        for (0..geometry.width) |x| {
            if (at(&rgb, x, 8)[0] == 0) continue;
            left = @min(left, x);
            right = @max(right, x);
        }
    }
    try std.testing.expectEqual(@as(usize, 7), left);
    try std.testing.expectEqual(@as(usize, 13), right);
}

test "a blink is lit for its duty and dark for the rest" {
    var s = State{};
    try s.doc.add(.{ .colour = white, .anim = .{ .kind = .blink, .ms = 1000, .amount = 25 }, .body = .pixel });
    var rgb: geometry.Rgb = undefined;
    var on: usize = 0;
    var ms: u64 = 0;
    while (ms < 1000) : (ms += 10) {
        s.render(ms * std.time.ns_per_ms, &rgb);
        if (at(&rgb, 0, 0)[0] != 0) on += 1;
    }
    try std.testing.expect(on >= 23 and on <= 27); // a quarter of the period, give or take a frame
}

test "a scramble settles left to right and ends on the word it was given" {
    var s = State{};
    const span = try s.doc.addText("HELLO");
    try s.doc.add(.{ .id = Id.init("w"), .colour = white, .anim = .{ .kind = .scramble, .ms = 1000 }, .body = .{ .text = .{ .span = span } } });
    var buf: [text_pool]u8 = undefined;

    try std.testing.expectEqualStrings("HELLO", s.animatedText(0, 1000, &buf)); // finished
    try std.testing.expectEqualStrings("HELLO", s.animatedText(0, 5000, &buf)); // and it stays
    // a fifth of the way through, the first character has landed and the last has not
    const early = s.animatedText(0, 250, &buf);
    try std.testing.expectEqual(@as(u8, 'H'), early[0]);
    try std.testing.expect(early[4] != 'O');
    const late = s.animatedText(0, 850, &buf);
    try std.testing.expectEqualStrings("HELL", late[0..4]);
    // and the unsettled characters keep changing rather than sitting on one wrong letter
    var changed = false;
    var a: [text_pool]u8 = undefined;
    const first = s.animatedText(0, 300, &a);
    var b2: [text_pool]u8 = undefined;
    const second = s.animatedText(0, 420, &b2);
    for (first, second) |c1, c2| changed = changed or c1 != c2;
    try std.testing.expect(changed);
}

test "a typewriter reveals a character at a time" {
    var s = State{};
    const span = try s.doc.addText("12345678");
    try s.doc.add(.{ .colour = white, .anim = .{ .kind = .typewriter, .ms = 800 }, .body = .{ .text = .{ .span = span } } });
    var buf: [text_pool]u8 = undefined;
    try std.testing.expectEqualStrings("", s.animatedText(0, 0, &buf));
    try std.testing.expectEqualStrings("1234", s.animatedText(0, 400, &buf));
    try std.testing.expectEqualStrings("12345678", s.animatedText(0, 800, &buf));
    try std.testing.expectEqualStrings("12345678", s.animatedText(0, 9000, &buf));
}

test "a sweep draws a sparkline left to right and then holds it" {
    var s = State{};
    const span = try s.doc.addData(&[_]u8{ 5, 5, 5, 5, 5, 5, 5, 5 });
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 8, .h = 4 }, .colour = white, .anim = .{ .kind = .sweep, .ms = 800 }, .body = .{ .sparkline = .{ .span = span, .style = .bars } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    const none = lit(&rgb);
    s.render(400 * std.time.ns_per_ms, &rgb);
    const half = lit(&rgb);
    s.render(900 * std.time.ns_per_ms, &rgb);
    const all = lit(&rgb);
    try std.testing.expect(none < half and half < all);
    try std.testing.expectEqual(@as(usize, 8), all); // a flat line sits on the floor: one row, every column
}

test "scrolling moves only text that does not fit, and the cadence follows what is moving" {
    var s = State{};
    const long = try s.doc.addText("a string far wider than eight pixels");
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .colour = white, .anim = .{ .kind = .scroll, .ms = 33 }, .body = .{ .text = .{ .span = long } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    var a: geometry.Rgb = undefined;
    @memcpy(&a, &rgb);
    s.render(200 * std.time.ns_per_ms, &rgb);
    try std.testing.expect(!std.mem.eql(u8, &a, &rgb)); // it moved
    try std.testing.expect(s.cadence(0) == .continuous);

    // a static document asks for nothing
    var still = State{};
    try still.doc.add(.{ .colour = white, .body = .pixel });
    try std.testing.expectEqual(scene.Cadence.idle, still.cadence(0));

    // an arrival goes quiet once it has arrived, which is the whole point of asking per element
    var once = State{};
    const word = try once.doc.addText("hi");
    try once.doc.add(.{ .colour = white, .anim = .{ .kind = .typewriter, .ms = 500 }, .body = .{ .text = .{ .span = word } } });
    try std.testing.expect(once.cadence(0) == .continuous);
    try std.testing.expectEqual(scene.Cadence.idle, once.cadence(600 * std.time.ns_per_ms));
}

test "installing a document restarts only what changed" {
    var built = Document{};
    const a = try built.addText("20.4C");
    const g = try built.addData(&[_]u8{ 1, 2 });
    try built.add(.{ .id = Id.init("t"), .anim = .{ .kind = .scramble, .ms = 600 }, .body = .{ .text = .{ .span = a } } });
    try built.add(.{ .id = Id.init("g"), .anim = .{ .kind = .sweep, .ms = 600 }, .body = .{ .sparkline = .{ .span = g } } });
    const first = built;
    var s = State{};
    s.install(first, 1000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1000 * std.time.ns_per_ms), s.started_ns[0]);

    // the same document again: nothing has changed, so nothing starts over
    s.install(first, 5000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 1000 * std.time.ns_per_ms), s.started_ns[0]);
    try std.testing.expectEqual(@as(u64, 1000 * std.time.ns_per_ms), s.started_ns[1]);

    // one value moves: that element scrambles again and the other is left alone
    var moved = first;
    moved.elements[0].body.text.span = try moved.addText("21.1C");
    s.install(moved, 9000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 9000 * std.time.ns_per_ms), s.started_ns[0]);
    try std.testing.expectEqual(@as(u64, 1000 * std.time.ns_per_ms), s.started_ns[1]);
}

test "an icon draws its art in the element's colour, and an unknown index draws nothing" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 0, .y = 0 }, .colour = .{ 0, 255, 0 }, .body = .{ .icon = .{ .index = icons.indexOf("sun").? } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, at(&rgb, 3, 0)); // the sun's top pixel
    const drawn = lit(&rgb);
    try std.testing.expect(drawn > 10);
    // every lit pixel is inside the eight by eight the glyph occupies
    for (0..geometry.pixels) |i| {
        if (rgb[i * 3 + 1] == 0) continue;
        try std.testing.expect(i % geometry.width < 8 and i / geometry.width < 8);
    }
    s.doc.elements[0].body.icon.index = 200;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 0), lit(&rgb));
}

test "a sprite draws its own colours, is transparent where it is black, and needs to have been uploaded" {
    var s = State{};
    try s.doc.add(.{ .box = .{ .x = 2, .y = 2 }, .body = .{ .sprite = .{ .id = Id.init("logo") } } });
    var rgb: geometry.Rgb = undefined;
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 0), lit(&rgb)); // nothing uploaded yet, so nothing drawn

    var sp = Sprite{ .id = Id.init("logo"), .w = 8, .h = 8 };
    for (0..64) |i| {
        sp.rgb[i * 3] = if (i % 2 == 0) 200 else 0; // a checkerboard of red and transparent
        sp.rgb[i * 3 + 1] = 0;
        sp.rgb[i * 3 + 2] = 0;
    }
    try s.sprites.put(sp);
    s.render(0, &rgb);
    try std.testing.expectEqual(@as(usize, 32), lit(&rgb));
    try std.testing.expectEqual([3]u8{ 200, 0, 0 }, at(&rgb, 2, 2));
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, at(&rgb, 3, 2)); // black is transparent

    // the cache replaces by id, fills up and gives a slot back on delete
    try std.testing.expectEqual(@as(u8, 1), s.sprites.count);
    try s.sprites.put(.{ .id = Id.init("logo"), .w = 8, .h = 8 });
    try std.testing.expectEqual(@as(u8, 1), s.sprites.count);
    for (0..sprite_max - 1) |i| {
        var other = Sprite{ .w = 8, .h = 8 };
        other.id = Id.init(&[_]u8{ 'a', @intCast('0' + i) });
        try s.sprites.put(other);
    }
    try std.testing.expectError(error.Full, s.sprites.put(.{ .id = Id.init("more"), .w = 8, .h = 8 }));
    try std.testing.expect(s.sprites.remove("logo"));
    try std.testing.expect(!s.sprites.remove("logo"));
    try s.sprites.put(.{ .id = Id.init("more"), .w = 8, .h = 8 });
}

test "a tile lays itself out: side by side when there is room, stacked when there is not" {
    var wide = State{};
    const l = try wide.doc.addText("temp");
    const v = try wide.doc.addText("21");
    try wide.doc.add(.{ .box = .{ .x = 0, .y = 0, .w = 52, .h = 16 }, .colour = white, .body = .{ .tile = .{
        .icon = icons.indexOf("thermometer").?,
        .label = l,
        .value = v,
        .accent = .{ 80, 80, 80 },
    } } });
    var rgb: geometry.Rgb = undefined;
    wide.render(0, &rgb);
    // the glyph on the left, and two colours of text to its right
    var accent: usize = 0;
    var bright: usize = 0;
    var glyph_px: usize = 0;
    for (0..geometry.pixels) |i| {
        const c = [3]u8{ rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] };
        if (std.meta.eql(c, [3]u8{ 80, 80, 80 })) accent += 1;
        if (std.meta.eql(c, white)) {
            if (i % geometry.width < 8) glyph_px += 1 else bright += 1;
        }
    }
    try std.testing.expect(glyph_px > 10); // the thermometer
    try std.testing.expect(accent > 5); // the label, in the accent colour
    try std.testing.expect(bright > 5); // the value, in the element's

    // a third of the panel has no room for a label, so the value goes under the glyph instead
    var narrow = State{};
    const l2 = try narrow.doc.addText("temp");
    const v2 = try narrow.doc.addText("21");
    try narrow.doc.add(.{ .box = Box.tile(0, 3), .colour = white, .body = .{ .tile = .{
        .icon = icons.indexOf("thermometer").?,
        .label = l2,
        .value = v2,
        .accent = .{ 80, 80, 80 },
    } } });
    narrow.render(0, &rgb);
    var narrow_accent: usize = 0;
    for (0..geometry.pixels) |i| {
        if (std.meta.eql([3]u8{ rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] }, [3]u8{ 80, 80, 80 })) narrow_accent += 1;
        if (rgb[i * 3] != 0) try std.testing.expect(i % geometry.width < 18); // stays in its tile
    }
    try std.testing.expectEqual(@as(usize, 0), narrow_accent); // the label is dropped, not squeezed
}

test "a patch moves a tile's value and leaves its label alone" {
    var d = Document{};
    const l = try d.addText("temp");
    const v = try d.addText("21");
    try d.add(.{ .id = Id.init("t"), .body = .{ .tile = .{ .label = l, .value = v } } });
    var p = Patch{};
    var u = Update{ .id = Id.init("t"), .has = Field.text };
    u.len = 4;
    @memcpy(u.bytes[0..4], "21.6");
    try p.add(u);
    try applyPatch(&d, &p);
    try std.testing.expectEqualStrings("21.6", d.textOf(d.elements[0].body.tile.value));
    try std.testing.expectEqualStrings("temp", d.textOf(d.elements[0].body.tile.label));
}
