//! Calls back once per frame while it runs, with the time elapsed since it
//! started. Every animation needs this and nothing else in the tree provides it:
//! `Scheduler.everyFrame` fires a callback but says nothing about time, and a
//! frame counter is wrong because the terminal backend and the GPU backend do not
//! run at the same rate.
//!
//! A Ticker holds a registration on the owner's scheduler. The owner MUST call
//! `deinit` when it goes away, or the scheduler keeps a pointer to freed memory.
const std = @import("std");
const Scheduler = @import("scheduler.zig").Scheduler;

pub const Ticker = struct {
    pub const Nanos = Scheduler.Nanos;
    /// `elapsed` counts from the first frame this ticker saw, not from the epoch.
    pub const Callback = *const fn (ctx: *anyopaque, elapsed: Nanos) void;

    scheduler: *Scheduler,
    /// Passed back to `on_tick`. Borrowed, and must outlive the registration.
    ctx: *anyopaque,
    on_tick: Callback,
    /// The scheduler registration while running, else null. Doubles as the
    /// running flag, so the two can never disagree.
    handle: ?Scheduler.Handle = null,
    /// The clock reading of the first frame after `start`. Null until that frame
    /// arrives, because `start` has no clock of its own to read.
    started_at: ?Nanos = null,

    /// Begin calling back on every frame. Starting an already running ticker is
    /// ignored, so a build that runs twice does not register twice and does not
    /// leak the first registration.
    pub fn start(self: *Ticker, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.handle != null) return;
        self.started_at = null;
        self.handle = try self.scheduler.everyFrame(gpa, self, tickThunk);
    }

    /// Stop calling back. Stopping a stopped ticker is ignored, so a caller
    /// tearing down does not need to track whether it already stopped.
    pub fn stop(self: *Ticker) void {
        const h = self.handle orelse return;
        self.scheduler.cancel(h);
        self.handle = null;
        self.started_at = null;
    }

    pub fn isRunning(self: *const Ticker) bool {
        return self.handle != null;
    }

    /// Restart the elapsed clock without dropping the registration. An animation
    /// that plays again from the beginning calls this rather than stop and start,
    /// which would cancel and re-add an entry for no gain.
    pub fn reset(self: *Ticker) void {
        self.started_at = null;
    }

    /// Cancel the registration. Safe on a ticker that never started.
    pub fn deinit(self: *Ticker) void {
        self.stop();
    }

    fn tickThunk(ctx: *anyopaque) void {
        const self: *Ticker = @ptrCast(@alignCast(ctx));
        const now = self.scheduler.now;
        const started = self.started_at orelse blk: {
            // The first frame baselines the clock and reports zero elapsed, which
            // is the same rule a periodic scheduler entry follows.
            self.started_at = now;
            break :blk now;
        };
        self.on_tick(self.ctx, now - started);
    }
};

const Probe = struct {
    calls: u32 = 0,
    last: Ticker.Nanos = -1,

    fn onTick(ctx: *anyopaque, elapsed: Ticker.Nanos) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last = elapsed;
    }
};

fn liveEntries(s: *const Scheduler) usize {
    var n: usize = 0;
    for (s.entries.items) |e| {
        if (!e.cancelled) n += 1;
    }
    return n;
}

test "a ticker reports the time elapsed since its first frame, not the clock" {
    // A ticker started while the clock already reads 5_000 must report 0 on that
    // frame. Reporting the raw clock would jump an animation straight to its end.
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    s.tick(5_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 0), probe.last);
    s.tick(5_250);
    try std.testing.expectEqual(@as(Ticker.Nanos, 250), probe.last);
    s.tick(9_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 4_000), probe.last);
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
}

test "a ticker fires once per frame however far the clock jumped" {
    // The terminal backend ticks far more slowly than the GPU one. A ticker that
    // replayed the missed frames would run an animation at a different speed on
    // each backend.
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    s.tick(0);
    s.tick(16_000_000); // one frame at 60 per second
    s.tick(1_016_000_000); // one frame a whole second later
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
    try std.testing.expectEqual(@as(Ticker.Nanos, 1_016_000_000), probe.last);
}

test "a stopped ticker fires no more and leaves no scheduler entry" {
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    s.tick(1_000);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);

    t.stop();
    s.tick(2_000);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), liveEntries(&s));
    try std.testing.expect(!t.isRunning());

    t.stop(); // stopping twice changes nothing
    try std.testing.expectEqual(@as(usize, 0), liveEntries(&s));
}

test "deinit while running cancels the registration" {
    // A torn down widget whose registration survives leaves the scheduler holding
    // a pointer into freed memory, and the next frame dereferences it.
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };

    try t.start(gpa);
    try std.testing.expectEqual(@as(usize, 1), liveEntries(&s));
    t.deinit();
    try std.testing.expectEqual(@as(usize, 0), liveEntries(&s));

    s.tick(1_000);
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), s.entries.items.len);
}

test "starting twice registers one entry and fires once per frame" {
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    const first = t.handle.?;
    try t.start(gpa);
    try std.testing.expectEqual(first, t.handle.?); // the second start was ignored
    try std.testing.expectEqual(@as(usize, 1), liveEntries(&s));

    s.tick(1_000);
    try std.testing.expectEqual(@as(u32, 1), probe.calls);
}

test "a restarted ticker measures from its new first frame" {
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    s.tick(1_000);
    s.tick(3_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 2_000), probe.last);

    t.stop();
    try t.start(gpa);
    s.tick(10_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 0), probe.last);
    s.tick(10_500);
    try std.testing.expectEqual(@as(Ticker.Nanos, 500), probe.last);
}

test "reset restarts the elapsed clock without touching the registration" {
    const gpa = std.testing.allocator;
    var s = Scheduler{};
    defer s.deinit(gpa);
    var probe = Probe{};
    var t = Ticker{ .scheduler = &s, .ctx = &probe, .on_tick = Probe.onTick };
    defer t.deinit();

    try t.start(gpa);
    const handle = t.handle.?;
    s.tick(1_000);
    s.tick(3_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 2_000), probe.last);

    t.reset();
    try std.testing.expectEqual(handle, t.handle.?);
    s.tick(4_000);
    try std.testing.expectEqual(@as(Ticker.Nanos, 0), probe.last);
    try std.testing.expectEqual(@as(usize, 1), liveEntries(&s));
}
