//! what a script can call.
//!
//! every function here is a berry native function -- a plain `int f(bvm*)`, which zig can define
//! because it is not variadic -- registered as a global under an underscored name. a small berry
//! prelude then gathers them into the `tc002` and `panel` modules, because assembling a module in
//! berry costs three lines and assembling one from c costs a compile-time table.
//!
//! nothing here touches the panel directly: berryd has no framebuffer and no network. a call turns
//! into an ipc message, the supervisor relays it, and the renderer does the work. that is what
//! keeps a script on the far side of a process boundary from anything it could break, and the
//! boundary costs 8.3 microseconds.
//!
//! the vocabulary is the api's, deliberately: bases are clock/art/canvas, elements are the same
//! ten kinds `/canvas` takes, colours are the same six hex digits. nothing gets a second name for
//! being said in berry.
const std = @import("std");
const vm_mod = @import("vm.zig");
const canvas = @import("../scene/canvas.zig");
const icons = @import("../scene/icons.zig");
const messages = @import("../ipc/messages.zig");
const arbiter = @import("../scene/arbiter.zig");
const geometry = @import("../panel/geometry.zig");

const Bvm = vm_mod.Bvm;

// -- the berry stack api. only what these bindings need.

extern fn be_top(vm: *Bvm) c_int;
extern fn be_isint(vm: *Bvm, index: c_int) bool;
extern fn be_isstring(vm: *Bvm, index: c_int) bool;
extern fn be_isnumber(vm: *Bvm, index: c_int) bool;
extern fn be_toint(vm: *Bvm, index: c_int) i64;
extern fn be_tostring(vm: *Bvm, index: c_int) [*:0]const u8;
extern fn be_pushint(vm: *Bvm, value: i64) void;
extern fn be_pushbool(vm: *Bvm, value: c_int) void;
extern fn be_pushnil(vm: *Bvm) void;
extern fn be_returnvalue(vm: *Bvm) c_int;
extern fn be_returnnilvalue(vm: *Bvm) c_int;
extern fn be_regfunc(vm: *Bvm, name: [*:0]const u8, f: *const fn (vm: ?*Bvm) callconv(.c) c_int) void;
extern fn be_raise(vm: *Bvm, except: [*:0]const u8, msg: ?[*:0]const u8) void;

// -- the host's side

/// how a call reaches the rest of the device. berryd points this at its supervisor channel; a test
/// can point it at a recorder.
pub var emit: ?*const fn (msg: messages.Message) void = null;

/// the document `panel.*` is building. one per vm: a script draws, then shows.
pub var doc: canvas.Document = .{};

/// counts for `/status`, so "my script is not drawing" has an answer that is not a guess
pub var calls: u32 = 0;
pub var refusals: u32 = 0;

fn send(msg: messages.Message) void {
    calls +|= 1;
    if (emit) |f| f(msg);
}

// -- argument helpers

fn argInt(vm: *Bvm, index: c_int, fallback: i64) i64 {
    if (index > be_top(vm)) return fallback;
    if (!be_isnumber(vm, index)) return fallback;
    return be_toint(vm, index);
}

fn argText(vm: *Bvm, index: c_int) []const u8 {
    if (index > be_top(vm) or !be_isstring(vm, index)) return "";
    return std.mem.span(be_tostring(vm, index));
}

/// a colour is either 0xrrggbb or "rrggbb". the integer is the fast path and the string is the
/// readable one; both are accepted because a script is read more often than it is run.
fn argColour(vm: *Bvm, index: c_int, fallback: [3]u8) [3]u8 {
    if (index > be_top(vm)) return fallback;
    if (be_isint(vm, index)) {
        const v: u32 = @truncate(@as(u64, @bitCast(be_toint(vm, index))));
        return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
    }
    if (be_isstring(vm, index)) {
        const text = std.mem.span(be_tostring(vm, index));
        if (text.len == 6) {
            var out: [3]u8 = undefined;
            for (0..3) |i| {
                out[i] = std.fmt.parseInt(u8, text[i * 2 .. i * 2 + 2], 16) catch return fallback;
            }
            return out;
        }
    }
    return fallback;
}

fn refuse(vm: *Bvm, message: [*:0]const u8) c_int {
    refusals +|= 1;
    be_raise(vm, "tc002_error", message);
    return 0;
}

// -- the device verbs

fn sceneFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const name = argText(v, 1);
    const base: arbiter.Base = if (std.mem.eql(u8, name, "clock"))
        .clock
    else if (std.mem.eql(u8, name, "art"))
        .art
    else if (std.mem.eql(u8, name, "canvas"))
        .canvas
    else
        return refuse(v, "a scene is clock, art or canvas");
    send(.{ .set_base = .{ .base = @intFromEnum(base), .generator = 0xff, .seed = 0 } });
    return be_returnnilvalue(v);
}

fn brightnessFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const value = argInt(v, 1, -1);
    if (value < 1 or value > 100) return refuse(v, "brightness is 1 to 100");
    send(.{ .brightness = .{ .value = @intCast(value) } });
    return be_returnnilvalue(v);
}

fn notifyFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const text = argText(v, 1);
    if (text.len == 0) return refuse(v, "a notification needs text");
    const colour = argColour(v, 2, .{ 255, 255, 255 });
    const seconds = argInt(v, 3, 5);
    if (seconds < arbiter.min_duration_s or seconds > arbiter.max_duration_s) return refuse(v, "a notification lasts 1 to 300 seconds");
    send(.{ .notify = messages.Notify.init(text, colour, @intCast(seconds), .{}) });
    return be_returnnilvalue(v);
}

// -- drawing

fn clearFn(vm: ?*Bvm) callconv(.c) c_int {
    doc = .{};
    return be_returnnilvalue(vm.?);
}

fn addElement(v: *Bvm, e: canvas.Element) c_int {
    doc.add(e) catch return refuse(v, "the document is full");
    be_pushint(v, doc.count);
    return be_returnvalue(v);
}

fn pixelFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const x: i16 = @intCast(argInt(v, 1, 0));
    const y: i16 = @intCast(argInt(v, 2, 0));
    const colour = argColour(v, 3, .{ 255, 255, 255 });
    return addElement(v, .{ .box = .{ .x = x, .y = y, .w = 1, .h = 1 }, .colour = colour, .body = .pixel });
}

fn rectFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const x: i16 = @intCast(argInt(v, 1, 0));
    const y: i16 = @intCast(argInt(v, 2, 0));
    const w: i16 = @intCast(argInt(v, 3, 1));
    const h: i16 = @intCast(argInt(v, 4, 1));
    const colour = argColour(v, 5, .{ 255, 255, 255 });
    const filled = argInt(v, 6, 0) != 0;
    return addElement(v, .{ .box = .{ .x = x, .y = y, .w = w, .h = h }, .colour = colour, .body = .{ .rect = .{ .filled = filled } } });
}

fn textFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const x: i16 = @intCast(argInt(v, 1, 0));
    const y: i16 = @intCast(argInt(v, 2, 0));
    const text = argText(v, 3);
    if (text.len == 0) return refuse(v, "text needs something to say");
    const colour = argColour(v, 4, .{ 255, 255, 255 });
    const span = doc.addText(text) catch return refuse(v, "the document's text pool is full");
    return addElement(v, .{
        .box = .{ .x = x, .y = y, .w = 0, .h = 0 },
        .colour = colour,
        .body = .{ .text = .{ .span = span, .face = .small, .alignment = .left } },
    });
}

fn iconFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const x: i16 = @intCast(argInt(v, 1, 0));
    const y: i16 = @intCast(argInt(v, 2, 0));
    const name = argText(v, 3);
    const index = icons.indexOf(name) orelse return refuse(v, "no icon by that name");
    const colour = argColour(v, 4, .{ 255, 255, 255 });
    return addElement(v, .{
        .box = .{ .x = x, .y = y, .w = icons.size, .h = icons.size },
        .colour = colour,
        .body = .{ .icon = .{ .index = index } },
    });
}

fn subscribeFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const topic = argText(v, 1);
    if (topic.len == 0 or topic.len > messages.BerryEvent.topic_max) return refuse(v, "a topic is 1 to 96 characters");
    send(.{ .berry_event = messages.BerryEvent.init(.subscribe, topic, "") });
    return be_returnnilvalue(v);
}

fn publishFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    const topic = argText(v, 1);
    if (topic.len == 0 or topic.len > messages.BerryEvent.topic_max) return refuse(v, "a topic is 1 to 96 characters");
    const payload = argText(v, 2);
    if (payload.len > messages.BerryEvent.payload_max) return refuse(v, "a payload is at most 256 bytes");
    send(.{ .berry_event = messages.BerryEvent.init(.publish, topic, payload) });
    return be_returnnilvalue(v);
}

fn showFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    send(.{ .canvas = .{ .doc = doc } });
    be_pushint(v, doc.count);
    return be_returnvalue(v);
}

/// the document rendered to pixels and pushed as one frame of a stream.
///
/// the script draws with the same panel calls it would use for a canvas document; what differs is
/// where the result goes. a document installed on the canvas is animated by the renderer and is
/// bounded by the command path's two-a-second deduplication window. a pushed frame is pixels, and
/// the script owns every one of them at up to sixty a second.
///
/// the rendering happens here, in zig, against the renderer's own canvas code -- which is what
/// makes this affordable: twenty native draw calls measured 0.20 ms on the device, against 10.8 ms
/// for a script that touches all 832 pixels itself.
fn pushFn(vm: ?*Bvm) callconv(.c) c_int {
    const v = vm.?;
    stream_state.doc = doc;
    stream_seq +%= 1;
    if (vm_mod.clock) |f| last_push_ns = f();
    var frame: geometry.Rgb = geometry.black_rgb;
    stream_state.render(if (vm_mod.clock) |f| f() else 0, &frame);
    send(.{ .stream_frame = .{ .seq = stream_seq, .rgb = frame } });
    be_pushint(v, stream_seq);
    return be_returnvalue(v);
}

fn streamFn(vm: ?*Bvm) callconv(.c) c_int {
    send(.arm_stream);
    return be_returnnilvalue(vm.?);
}

/// the canvas state pushed frames are rendered through: the same code the renderer runs, so a
/// pushed frame and an installed document draw identically
var stream_state: canvas.State = .{};
var stream_seq: u32 = 0;

/// when the last frame was pushed. berryd looks at this to decide how often to run script timers:
/// a device driving an animation needs a tick fine enough to hit sixty frames a second, and an
/// idle one should not be woken sixty times a second to find there is nothing to do.
pub var last_push_ns: u64 = 0;

// -- registration

const Binding = struct { name: [*:0]const u8, f: *const fn (vm: ?*Bvm) callconv(.c) c_int };

const bindings = [_]Binding{
    .{ .name = "_tc002_scene", .f = sceneFn },
    .{ .name = "_tc002_brightness", .f = brightnessFn },
    .{ .name = "_tc002_notify", .f = notifyFn },
    .{ .name = "_tc002_subscribe", .f = subscribeFn },
    .{ .name = "_tc002_publish", .f = publishFn },
    .{ .name = "_panel_clear", .f = clearFn },
    .{ .name = "_panel_pixel", .f = pixelFn },
    .{ .name = "_panel_rect", .f = rectFn },
    .{ .name = "_panel_text", .f = textFn },
    .{ .name = "_panel_icon", .f = iconFn },
    .{ .name = "_panel_show", .f = showFn },
    .{ .name = "_panel_stream", .f = streamFn },
    .{ .name = "_panel_push", .f = pushFn },
};

/// gathers the underscored natives into two modules, and keeps the event bookkeeping here rather
/// than in zig.
///
/// handlers and timers are berry values; holding them from zig would mean a registry and a set of
/// reference rules, while holding them in a berry list costs nothing and cannot leak past the vm.
/// the zig side only ever calls `_tc002_dispatch` and `_tc002_tick`, which are plain globals.
///
/// a handler that raises is caught here, named in the log, and left registered -- one bad event is
/// not a reason to stop listening. ten failures in a row and it is dropped, because a handler
/// failing on every event will otherwise fill a 64-line log ring at event rate and destroy the
/// evidence of everything else that happened.
pub const prelude =
    \\tc002 = module('tc002')
    \\tc002.scene = _tc002_scene
    \\tc002.brightness = _tc002_brightness
    \\tc002.notify = _tc002_notify
    \\tc002.subscribe = _tc002_subscribe
    \\tc002.publish = _tc002_publish
    \\panel = module('panel')
    \\panel.clear = _panel_clear
    \\panel.pixel = _panel_pixel
    \\panel.rect = _panel_rect
    \\panel.text = _panel_text
    \\panel.icon = _panel_icon
    \\panel.show = _panel_show
    \\panel.stream = _panel_stream
    \\panel.push = _panel_push
    \\tc002._handlers = {}
    \\tc002._timers = []
    \\tc002.on = def (event, f)
    \\  if !tc002._handlers.contains(event) tc002._handlers[event] = [] end
    \\  tc002._handlers[event].push([f, 0])
    \\  return size(tc002._handlers[event])
    \\end
    \\tc002.every = def (ms, f) tc002._timers.push([ms, f, ms]) end
    \\tc002.after = def (ms, f) tc002._timers.push([0, f, ms]) end
    \\tc002._dispatch = def (event, a, b, c)
    \\  if !tc002._handlers.contains(event) return 0 end
    \\  var list = tc002._handlers[event]
    \\  var i = 0
    \\  var ran = 0
    \\  while i < size(list)
    \\    var entry = list[i]
    \\    try
    \\      entry[0](a, b, c)
    \\      entry[1] = 0
    \\      ran += 1
    \\    except .. as ex, msg
    \\      entry[1] += 1
    \\      print('handler for ' + event + ' failed: ' + str(ex) + ' ' + str(msg))
    \\      if entry[1] >= 10
    \\        print('handler for ' + event + ' failed ten times in a row and has been dropped')
    \\        list.remove(i)
    \\        continue
    \\      end
    \\    end
    \\    i += 1
    \\  end
    \\  return ran
    \\end
    \\tc002._tick = def (elapsed_ms)
    \\  var i = 0
    \\  var ran = 0
    \\  while i < size(tc002._timers)
    \\    var t = tc002._timers[i]
    \\    t[2] -= elapsed_ms
    \\    if t[2] <= 0
    \\      try
    \\        t[1]()
    \\        ran += 1
    \\      except .. as ex, msg
    \\        print('timer failed: ' + str(ex) + ' ' + str(msg))
    \\      end
    \\      if t[0] > 0
    \\        t[2] += t[0]
    \\      else
    \\        tc002._timers.remove(i)
    \\        continue
    \\      end
    \\    end
    \\    i += 1
    \\  end
    \\  return ran
    \\end
    \\_tc002_dispatch = tc002._dispatch
    \\_tc002_tick = tc002._tick
    \\_tc002_timers = def () return size(tc002._timers) end
;

/// register every native. the caller then runs `prelude` to make the modules.
pub fn register(vm: *vm_mod.Vm) void {
    for (bindings) |b| be_regfunc(vm.handle, b.name, b.f);
}

extern fn be_getglobal(vm: *Bvm, name: [*:0]const u8) bool;
extern fn be_pushstring(vm: *Bvm, str: [*:0]const u8) void;
extern fn be_pcall(vm: *Bvm, argc: c_int) c_int;
extern fn be_pop(vm: *Bvm, n: c_int) void;

/// one argument to a handler: berry is dynamically typed, and these are the only shapes anything
/// here needs to pass it
pub const Arg = union(enum) { none, int: i64, text: [*:0]const u8 };

/// call a global berry function with up to three arguments, under the watchdog's deadline.
/// returns false when the call raised, having left the message where `errorText` can find it.
pub fn callGlobal(vm: *vm_mod.Vm, name: [*:0]const u8, args: []const Arg, budget_ns: u64) bool {
    if (!be_getglobal(vm.handle, name)) return false;
    for (args) |a| switch (a) {
        .none => be_pushnil(vm.handle),
        .int => |v| be_pushint(vm.handle, v),
        .text => |t| be_pushstring(vm.handle, t),
    };
    if (vm_mod.clock) |f| vm_mod.deadline_ns = f() + budget_ns;
    defer vm_mod.deadline_ns = 0;
    const st: vm_mod.Status = @enumFromInt(be_pcall(vm.handle, @intCast(args.len)));
    if (st != .ok) return false;
    be_pop(vm.handle, 1); // the return value; nothing here wants it
    return true;
}
