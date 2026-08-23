//! Fires registered callbacks when they come due. Holds no timer and performs
//! no IO: whichever loop is running supplies the timestamp. That keeps one
//! implementation correct under the native poll loop, a browser animation
//! frame, and a test with a hand written clock.
const std = @import("std");

pub const Scheduler = struct {
    pub const Handle = u32;
    pub const Callback = *const fn (ctx: *anyopaque) void;

    /// Nanoseconds, matching std.Io.Timestamp so no conversion is needed.
    pub const Nanos = i96;

    const Entry = struct {
        id: Handle,
        ctx: *anyopaque,
        callback: Callback,
        /// Zero means fire on every tick. Otherwise the period in nanoseconds.
        period: Nanos,
        /// Null until the first tick baselines it. Nanos is signed, so a
        /// computed due time can legitimately be zero; only null may mean
        /// "not yet baselined".
        due: ?Nanos,
        cancelled: bool = false,
    };

    entries: std.ArrayList(Entry) = .empty,
    next_id: Handle = 1,
    /// The timestamp of the tick that is running, or of the last one that ran. A
    /// callback takes no timestamp argument, so a callback that needs the clock
    /// reads it here instead of holding a clock of its own.
    now: Nanos = 0,
    /// Depth of `tick`, so a callback that cancels during a sweep defers the
    /// compaction rather than mutating the list being walked.
    ticking: u32 = 0,

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    /// Fire `callback` on every tick. `ctx` is borrowed and must outlive the
    /// registration or be cancelled first.
    pub fn everyFrame(
        self: *Scheduler,
        gpa: std.mem.Allocator,
        ctx: *anyopaque,
        callback: Callback,
    ) std.mem.Allocator.Error!Handle {
        return self.add(gpa, ctx, callback, 0);
    }

    /// Fire `callback` no more than once per `period` nanoseconds. Missed
    /// periods are dropped, not replayed.
    pub fn every(
        self: *Scheduler,
        gpa: std.mem.Allocator,
        period: Nanos,
        ctx: *anyopaque,
        callback: Callback,
    ) std.mem.Allocator.Error!Handle {
        std.debug.assert(period > 0); // use everyFrame for zero
        return self.add(gpa, ctx, callback, period);
    }

    fn add(
        self: *Scheduler,
        gpa: std.mem.Allocator,
        ctx: *anyopaque,
        callback: Callback,
        period: Nanos,
    ) std.mem.Allocator.Error!Handle {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(gpa, .{
            .id = id,
            .ctx = ctx,
            .callback = callback,
            .period = period,
            // A periodic entry becomes due one period after the first tick it
            // sees, so `due` is set on that tick rather than here.
            .due = null,
        });
        return id;
    }

    /// Stop a callback. Unknown and repeated handles are ignored, so a caller
    /// tearing down does not need to track whether it already cancelled.
    pub fn cancel(self: *Scheduler, handle: Handle) void {
        for (self.entries.items) |*e| {
            if (e.id == handle) {
                e.cancelled = true;
                return;
            }
        }
    }

    /// Fire everything due at `now`. Safe to call from any loop.
    pub fn tick(self: *Scheduler, now: Nanos) void {
        self.now = now;
        self.ticking += 1;
        // Index rather than pointer iteration: a callback may append, which
        // reallocates the backing store and dangles any held pointer.
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 1) {
            const e = self.entries.items[i];
            if (e.cancelled) continue;
            if (e.period == 0) {
                e.callback(e.ctx);
                continue;
            }
            if (e.due) |d| {
                if (now >= d) {
                    // Restart from now, so a long gap costs one firing.
                    self.entries.items[i].due = now + e.period;
                    e.callback(e.ctx);
                }
            } else {
                self.entries.items[i].due = now + e.period;
            }
        }
        self.ticking -= 1;
        if (self.ticking == 0) self.compact();
    }

    fn compact(self: *Scheduler) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].cancelled) {
                _ = self.entries.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

test "everyFrame fires on every tick" {
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    _ = try s.everyFrame(std.testing.allocator, &counter, bump);
    s.tick(1000);
    s.tick(2000);
    s.tick(3000);
    try std.testing.expectEqual(@as(u32, 3), counter);
}

test "every fires once its period has elapsed and not before" {
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    _ = try s.every(std.testing.allocator, 1000, &counter, bump);
    s.tick(0);
    try std.testing.expectEqual(@as(u32, 0), counter); // registered, not due
    s.tick(999);
    try std.testing.expectEqual(@as(u32, 0), counter); // one nanosecond short
    s.tick(1000);
    try std.testing.expectEqual(@as(u32, 1), counter); // exactly due
    s.tick(1500);
    try std.testing.expectEqual(@as(u32, 1), counter); // period restarted
    s.tick(2000);
    try std.testing.expectEqual(@as(u32, 2), counter);
}

test "a long gap fires a periodic callback once, not once per missed period" {
    // A backgrounded browser tab stops delivering animation frames. A clock
    // that catches up would fire hundreds of times and flood the dirty queue.
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    _ = try s.every(std.testing.allocator, 1000, &counter, bump);
    s.tick(0);
    s.tick(100_000);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "cancel stops a callback and is safe to call twice" {
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    const h = try s.everyFrame(std.testing.allocator, &counter, bump);
    s.tick(1);
    s.cancel(h);
    s.cancel(h); // idempotent
    s.tick(2);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "a callback that cancels itself during tick does not corrupt the sweep" {
    // The entry list is mutated from inside the loop that walks it. A naive
    // swapRemove during iteration skips the next entry.
    var ctx = SelfCancel{};
    var other: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    ctx.sched = &s;
    ctx.handle = try s.everyFrame(std.testing.allocator, &ctx, SelfCancel.run);
    _ = try s.everyFrame(std.testing.allocator, &other, bump);

    s.tick(1);
    s.tick(2);
    try std.testing.expectEqual(@as(u32, 1), ctx.calls); // cancelled itself
    try std.testing.expectEqual(@as(u32, 2), other); // still fired both ticks
}

test "tick with no entries is a no-op and does not allocate" {
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);
    s.tick(1);
    s.tick(2);
    try std.testing.expectEqual(@as(usize, 0), s.entries.items.len);
}

test "a periodic entry whose computed due lands on zero still fires" {
    // Nanos is signed, so a negative clock can compute due == 0. An
    // implementation using 0 as the "not yet baselined" sentinel silently
    // swallows this firing.
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);
    _ = try s.every(std.testing.allocator, 1000, &counter, bump);
    s.tick(-1000); // baseline, due becomes 0
    try std.testing.expectEqual(@as(u32, 0), counter);
    s.tick(0); // now >= due, must fire
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "registering entries from inside a callback survives a mid sweep reallocation" {
    // Appending during tick can move the backing store. tick reads entries
    // by index rather than holding a pointer across the callback, so a
    // callback that registers new work must not corrupt the sweep or lose
    // the entries it added.
    var counter: u32 = 0;
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    var registrar = Registrar{ .sched = &s, .gpa = std.testing.allocator, .to_add = 32 };
    _ = try s.everyFrame(std.testing.allocator, &counter, bump);
    _ = try s.everyFrame(std.testing.allocator, &registrar, Registrar.run);

    s.tick(1);

    try std.testing.expectEqual(@as(u32, 1), counter); // original callback still fired
    try std.testing.expectEqual(@as(u32, 32), registrar.added); // all new entries registered
    try std.testing.expectEqual(@as(usize, 34), s.entries.items.len); // 2 original + 32 new
}

test "a callback reads the timestamp of the tick that fired it" {
    // The callback signature carries no timestamp, so an animation reads the clock
    // from the scheduler. A stale value would make every frame report the same
    // elapsed time and the animation would never move.
    var seen = SeenTime{};
    var s = Scheduler{};
    defer s.deinit(std.testing.allocator);

    seen.sched = &s;
    _ = try s.everyFrame(std.testing.allocator, &seen, SeenTime.run);
    s.tick(1_000);
    try std.testing.expectEqual(@as(Scheduler.Nanos, 1_000), seen.at);
    s.tick(4_500);
    try std.testing.expectEqual(@as(Scheduler.Nanos, 4_500), seen.at);
}

const SeenTime = struct {
    sched: *Scheduler = undefined,
    at: Scheduler.Nanos = -1,

    fn run(ctx: *anyopaque) void {
        const self: *SeenTime = @ptrCast(@alignCast(ctx));
        self.at = self.sched.now;
    }
};

fn bump(ctx: *anyopaque) void {
    const c: *u32 = @ptrCast(@alignCast(ctx));
    c.* += 1;
}

const SelfCancel = struct {
    sched: *Scheduler = undefined,
    handle: Scheduler.Handle = 0,
    calls: u32 = 0,

    fn run(ctx: *anyopaque) void {
        const self: *SelfCancel = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.sched.cancel(self.handle);
    }
};

const Registrar = struct {
    sched: *Scheduler,
    gpa: std.mem.Allocator,
    to_add: u32,
    added: u32 = 0,

    fn run(ctx: *anyopaque) void {
        const self: *Registrar = @ptrCast(@alignCast(ctx));
        var n: u32 = 0;
        while (n < self.to_add) : (n += 1) {
            // Callback returns void, so an OOM cannot be propagated. Stopping
            // leaves `added` short of `to_add`, and the test asserts that
            // equality, so the failure is reported with a readable message
            // rather than aborting the whole run.
            _ = self.sched.everyFrame(self.gpa, self, Registrar.noop) catch return;
            self.added += 1;
        }
    }

    fn noop(ctx: *anyopaque) void {
        _ = ctx;
    }
};
