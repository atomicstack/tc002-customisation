//! hardware-free presentation model.
//!
//! the panel's mcu double-buffers: a pulsed transfer stores the new frame and makes the *previous*
//! transfer visible. so a logical frame becomes visible only after it has been sent twice, or after
//! it has been sent once and something else has been sent after it. this module tracks three frame
//! versions — intended (what the renderer wants shown), buffered (in the mcu's back buffer) and
//! visible — and decides when a transfer is due:
//!
//! - continuous mode (art, streaming): one transfer per deadline, accepting one frame of lag.
//! - isolated mode (clock tick, ip change, brightness, notification, raw frame, final black): keep
//!   transferring the latest intended frame, paced at least `min_gap_ns` apart, until it is visible.
//!   a newer update that arrives while an older one awaits its latch simply becomes the frame that
//!   gets sent next; the older one is never re-sent.
//!
//! versions are opaque counters owned by the caller, which also owns the frame bytes. tests model
//! what is visible, not how many bytes were written.
const std = @import("std");

pub const Mode = enum { continuous, isolated };

pub const Presenter = struct {
    min_gap_ns: u64 = 16_666_667,
    intended: u32 = 0,
    buffered: u32 = 0,
    visible: u32 = 0,
    last_transfer_ns: ?u64 = null,
    transfers: u64 = 0,
    mode: Mode = .isolated,

    /// a new logical frame is ready; `version` is the caller's counter for it.
    pub fn submit(self: *Presenter, version: u32, mode: Mode) void {
        self.intended = version;
        self.mode = mode;
    }

    /// continuous mode always wants the next deadline's transfer; isolated mode keeps sending
    /// the intended frame until it is both buffered and visible.
    pub fn needsTransfer(self: *const Presenter) bool {
        return switch (self.mode) {
            .continuous => true,
            .isolated => self.buffered != self.intended or self.visible != self.intended,
        };
    }

    /// monotonic time at which the next transfer may start, or null when none is needed.
    pub fn dueAt(self: *const Presenter) ?u64 {
        if (!self.needsTransfer()) return null;
        return if (self.last_transfer_ns) |t| t + self.min_gap_ns else 0;
    }

    /// model one pulsed spi write of the intended frame: the buffered frame becomes visible and
    /// the intended frame becomes buffered. the caller performs the actual write.
    pub fn transfer(self: *Presenter, now_ns: u64) void {
        self.visible = self.buffered;
        self.buffered = self.intended;
        self.last_transfer_ns = now_ns;
        self.transfers += 1;
    }

    pub fn isVisible(self: *const Presenter, version: u32) bool {
        return self.visible == version;
    }
};

test "an isolated update becomes visible after two paced transfers" {
    var p = Presenter{};
    p.submit(1, .isolated);
    try std.testing.expect(p.needsTransfer());
    try std.testing.expectEqual(@as(?u64, 0), p.dueAt());
    p.transfer(0);
    try std.testing.expect(!p.isVisible(1));
    try std.testing.expectEqual(@as(?u64, 16_666_667), p.dueAt());
    p.transfer(16_666_667);
    try std.testing.expect(p.isVisible(1));
    try std.testing.expect(!p.needsTransfer());
    try std.testing.expectEqual(@as(?u64, null), p.dueAt());
}

test "a newer isolated update supersedes one awaiting its latch and still latches" {
    var p = Presenter{};
    p.submit(1, .isolated);
    p.transfer(0);
    p.submit(2, .isolated); // before the second transfer of 1
    p.transfer(16_666_667); // sends 2; 1 becomes visible
    try std.testing.expect(p.isVisible(1));
    try std.testing.expect(p.needsTransfer());
    p.transfer(33_333_334); // sends 2 again; 2 visible
    try std.testing.expect(p.isVisible(2));
    try std.testing.expect(!p.needsTransfer());
    try std.testing.expectEqual(@as(u64, 3), p.transfers);
}

test "continuous mode wants one transfer per deadline and accepts one frame of lag" {
    var p = Presenter{};
    p.submit(1, .continuous);
    p.transfer(0);
    try std.testing.expect(p.needsTransfer());
    p.submit(2, .continuous);
    p.transfer(16_666_667);
    try std.testing.expect(p.isVisible(1));
    try std.testing.expect(!p.isVisible(2));
}

test "switching from continuous to an isolated frame latches the last desired frame" {
    var p = Presenter{};
    p.submit(7, .continuous);
    p.transfer(0);
    p.submit(8, .isolated);
    try std.testing.expect(p.needsTransfer());
    p.transfer(16_666_667);
    p.transfer(33_333_334);
    try std.testing.expect(p.isVisible(8));
    try std.testing.expect(!p.needsTransfer());
}

test "transfers are never due earlier than the minimum gap" {
    var p = Presenter{};
    p.submit(1, .isolated);
    p.transfer(5_000_000);
    try std.testing.expectEqual(@as(?u64, 21_666_667), p.dueAt());
}

test "resubmitting the visible version in isolated mode needs no transfer" {
    var p = Presenter{};
    p.submit(1, .isolated);
    p.transfer(0);
    p.transfer(16_666_667);
    p.submit(1, .isolated);
    try std.testing.expect(!p.needsTransfer());
}
