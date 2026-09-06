//! the renderer child's lifecycle as a pure state machine driven by monotonic time: ready and
//! heartbeat deadlines, graceful stop with escalation, restart delays of 1/2/5 s, a three-failures-
//! in-sixty-seconds window that switches to the embedded slot and then halts, and a sixty-second
//! healthy window that confirms the candidate slot once.
const std = @import("std");

const s_ns = std.time.ns_per_s;

test "first poll spawns; ready must arrive within ten seconds, then stop escalates to kill" {
    var l = Lifecycle{};
    try std.testing.expectEqual(Directive.spawn, l.poll(0));
    l.onSpawned(0);
    try std.testing.expectEqual(@as(u32, 1), l.epoch);
    try std.testing.expectEqual(Directive.none, l.poll(9 * s_ns));
    try std.testing.expectEqual(Directive.request_stop, l.poll(10 * s_ns));
    try std.testing.expectEqual(State.stopping, l.state);
    try std.testing.expectEqual(Directive.none, l.poll(11 * s_ns + 999_000_000));
    try std.testing.expectEqual(Directive.kill, l.poll(12 * s_ns));
    try std.testing.expectEqual(Directive.none, l.poll(12 * s_ns + 100_000_000));
    l.onExit(12 * s_ns + 200_000_000);
    try std.testing.expectEqual(State.waiting_restart, l.state);
    try std.testing.expectEqual(Directive.none, l.poll(13 * s_ns + 100_000_000));
    try std.testing.expectEqual(Directive.spawn, l.poll(13 * s_ns + 200_000_000));
}

test "heartbeats keep it running; a two-second gap requests a stop" {
    var l = Lifecycle{};
    _ = l.poll(0);
    l.onSpawned(0);
    l.onReady(3 * s_ns);
    try std.testing.expectEqual(State.running, l.state);
    var t: u64 = 3 * s_ns;
    while (t <= 5 * s_ns) : (t += 250_000_000) {
        l.onHeartbeat(t);
        try std.testing.expectEqual(Directive.none, l.poll(t));
    }
    try std.testing.expectEqual(Directive.none, l.poll(6 * s_ns + 900_000_000));
    try std.testing.expectEqual(Directive.request_stop, l.poll(7 * s_ns));
}

test "sixty healthy seconds confirms the slot exactly once and resets the attempt counter" {
    var l = Lifecycle{};
    _ = l.poll(0);
    l.onSpawned(0);
    l.onExit(100); // one early failure so the attempt counter is nonzero
    try std.testing.expectEqual(@as(u8, 1), l.attempt);
    _ = l.poll(2 * s_ns);
    l.onSpawned(2 * s_ns);
    l.onReady(3 * s_ns);
    var confirms: u32 = 0;
    var t: u64 = 3 * s_ns;
    while (t <= 70 * s_ns) : (t += 250_000_000) {
        l.onHeartbeat(t);
        if (l.poll(t) == .confirm_slot) {
            confirms += 1;
            try std.testing.expect(t >= 62 * s_ns);
        }
    }
    try std.testing.expectEqual(@as(u32, 1), confirms);
    try std.testing.expectEqual(@as(u8, 0), l.attempt);
    try std.testing.expect(l.confirmed);
}

test "restart delays are 1, 2, 5 seconds; three failures in sixty seconds fall back, then halt" {
    var l = Lifecycle{};
    _ = l.poll(0);
    l.onSpawned(0);
    l.onExit(1 * s_ns);
    try std.testing.expectEqual(@as(u64, 2 * s_ns), l.deadline_ns);
    _ = l.poll(2 * s_ns);
    l.onSpawned(2 * s_ns);
    l.onExit(3 * s_ns);
    try std.testing.expectEqual(@as(u64, 5 * s_ns), l.deadline_ns);
    try std.testing.expectEqual(Slot.candidate, l.slot);
    _ = l.poll(5 * s_ns);
    l.onSpawned(5 * s_ns);
    l.onExit(6 * s_ns);
    try std.testing.expectEqual(Slot.embedded, l.slot);
    try std.testing.expectEqual(@as(u64, 7 * s_ns), l.deadline_ns); // the fallback pair starts a fresh 1 s delay
    try std.testing.expectEqual(Directive.spawn, l.poll(7 * s_ns));
    l.onSpawned(7 * s_ns);
    l.onExit(8 * s_ns);
    _ = l.poll(9 * s_ns);
    l.onSpawned(9 * s_ns);
    l.onExit(10 * s_ns);
    try std.testing.expectEqual(@as(u64, 15 * s_ns), l.deadline_ns);
    _ = l.poll(15 * s_ns);
    l.onSpawned(15 * s_ns);
    l.onExit(16 * s_ns);
    try std.testing.expectEqual(State.halted, l.state);
    try std.testing.expectEqual(Directive.none, l.poll(100 * s_ns));
    try std.testing.expectEqual(@as(u32, 6), l.epoch);
}

test "failures spread over more than sixty seconds do not fall back" {
    var l = Lifecycle{};
    var t: u64 = 0;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        _ = l.poll(t);
        l.onSpawned(t);
        l.onExit(t + s_ns);
        t += 40 * s_ns;
    }
    try std.testing.expectEqual(Slot.candidate, l.slot);
    try std.testing.expectEqual(State.waiting_restart, l.state);
}

test "a supervisor-initiated stop follows the same escalation" {
    var l = Lifecycle{};
    _ = l.poll(0);
    l.onSpawned(0);
    l.onReady(1 * s_ns);
    l.requestStop(5 * s_ns);
    try std.testing.expectEqual(State.stopping, l.state);
    try std.testing.expectEqual(Directive.kill, l.poll(7 * s_ns));
    l.onExit(7 * s_ns + 1);
    try std.testing.expectEqual(State.stopped, l.state); // a requested stop is not a failure
    try std.testing.expectEqual(Directive.none, l.poll(8 * s_ns));
}

test "a netd exit during shutdown is a requested stop, not a restart" {
    var n = NetdExits{};
    n.onExit(false);
    try std.testing.expectEqual(@as(u32, 1), n.restarts);
    n.onExit(true);
    try std.testing.expectEqual(@as(u32, 1), n.restarts);
}

/// netd's exits: an exit while the supervisor is shutting down was asked for and is not counted.
pub const NetdExits = struct {
    restarts: u32 = 0,

    pub fn onExit(self: *NetdExits, shutting_down: bool) void {
        if (!shutting_down) self.restarts += 1;
    }
};

pub const ready_timeout_ns: u64 = 10 * s_ns;
pub const heartbeat_timeout_ns: u64 = 2 * s_ns;
pub const stop_timeout_ns: u64 = 2 * s_ns;
pub const healthy_ns: u64 = 60 * s_ns;
pub const failure_window_ns: u64 = 60 * s_ns;

pub const State = enum { idle, starting, running, stopping, waiting_restart, halted, stopped };
pub const Slot = enum { candidate, embedded };
pub const Directive = enum { none, spawn, request_stop, kill, confirm_slot };

pub const Lifecycle = struct {
    state: State = .idle,
    epoch: u32 = 0,
    slot: Slot = .candidate,
    /// meaning depends on state: ready deadline (starting), heartbeat deadline (running),
    /// kill deadline (stopping), spawn time (waiting_restart).
    deadline_ns: u64 = 0,
    started_ns: u64 = 0,
    confirmed: bool = false,
    attempt: u8 = 0,
    kill_sent: bool = false,
    requested: bool = false,
    failures: [3]u64 = .{ 0, 0, 0 },
    failure_count: u8 = 0,

    pub fn onSpawned(self: *Lifecycle, now_ns: u64) void {
        self.state = .starting;
        self.epoch += 1;
        self.started_ns = now_ns;
        self.deadline_ns = now_ns + ready_timeout_ns;
        self.kill_sent = false;
        self.requested = false;
    }

    pub fn onReady(self: *Lifecycle, now_ns: u64) void {
        if (self.state != .starting) return;
        self.state = .running;
        self.deadline_ns = now_ns + heartbeat_timeout_ns;
    }

    pub fn onHeartbeat(self: *Lifecycle, now_ns: u64) void {
        if (self.state == .running) self.deadline_ns = now_ns + heartbeat_timeout_ns;
    }

    /// the supervisor wants the child gone (shutdown, release switch); not counted as a failure.
    pub fn requestStop(self: *Lifecycle, now_ns: u64) void {
        if (self.state == .idle or self.state == .halted or self.state == .waiting_restart or self.state == .stopped) {
            self.state = .stopped;
            return;
        }
        self.state = .stopping;
        self.requested = true;
        self.deadline_ns = now_ns + stop_timeout_ns;
    }

    fn restartDelay(attempt: u8) u64 {
        return switch (attempt) {
            0, 1 => 1 * s_ns,
            2 => 2 * s_ns,
            else => 5 * s_ns,
        };
    }

    /// returns true when three failures fell inside the window.
    fn recordFailure(self: *Lifecycle, now_ns: u64) bool {
        if (self.failure_count < 3) {
            self.failures[self.failure_count] = now_ns;
            self.failure_count += 1;
        } else {
            self.failures[0] = self.failures[1];
            self.failures[1] = self.failures[2];
            self.failures[2] = now_ns;
        }
        return self.failure_count == 3 and now_ns - self.failures[0] < failure_window_ns;
    }

    pub fn onExit(self: *Lifecycle, now_ns: u64) void {
        switch (self.state) {
            .starting, .running, .stopping => {},
            else => return,
        }
        if (self.requested) {
            self.state = .stopped;
            self.requested = false;
            return;
        }
        if (self.recordFailure(now_ns)) {
            self.failure_count = 0;
            self.attempt = 0;
            switch (self.slot) {
                .candidate => self.slot = .embedded,
                .embedded => {
                    self.state = .halted;
                    return;
                },
            }
        }
        self.attempt +|= 1;
        self.state = .waiting_restart;
        self.deadline_ns = now_ns + restartDelay(self.attempt);
    }

    pub fn poll(self: *Lifecycle, now_ns: u64) Directive {
        switch (self.state) {
            .idle => return .spawn,
            .starting => if (now_ns >= self.deadline_ns) {
                self.state = .stopping;
                self.deadline_ns = now_ns + stop_timeout_ns;
                return .request_stop;
            },
            .running => {
                if (now_ns >= self.deadline_ns) {
                    self.state = .stopping;
                    self.deadline_ns = now_ns + stop_timeout_ns;
                    return .request_stop;
                }
                if (!self.confirmed and now_ns - self.started_ns >= healthy_ns) {
                    self.confirmed = true;
                    self.attempt = 0;
                    self.failure_count = 0;
                    return .confirm_slot;
                }
            },
            .stopping => if (!self.kill_sent and now_ns >= self.deadline_ns) {
                self.kill_sent = true;
                return .kill;
            },
            .waiting_restart => if (now_ns >= self.deadline_ns) return .spawn,
            .halted, .stopped => {},
        }
        return .none;
    }
};
