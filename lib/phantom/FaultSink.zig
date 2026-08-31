//! Records recoverable faults during a build/render pass so the framework can
//! soft-fail instead of aborting. The `soft` policy (default, production) writes to
//! the injected `diagnostics` writer and continues; `strict` (the test harness) keeps
//! the first fault so tests surface it and fail loudly. File-as-struct: the file IS
//! the FaultSink type.

const std = @import("std");
const FaultSink = @This();

pub const FaultCode = enum {
    oom,
    build_failed,
    layout_overflow,
    render_failed,
    state_init,
    state_update,
    /// A peer spoke the protocol wrongly. Terminal input that does not parse lands
    /// here. It is a recovered runtime fault and never a programmer error.
    protocol,
    /// No route in the table matches the current location.
    route_not_found,
    /// A navigation was refused. The path was too long, or the history is full.
    route_rejected,
    /// A link was tapped on a backend that cannot open a URL.
    link_unsupported,
    /// The browser's address was longer than the buffer that reads it. The
    /// read is refused rather than truncated, because a truncated address is
    /// a different, shorter route than the one the user is actually on.
    location_too_long,
};

pub const Fault = struct {
    code: FaultCode,
    msg: []const u8,
};

pub const Policy = enum { soft, strict };

policy: Policy = .soft,
first: ?Fault = null,
count: usize = 0,

/// Where a recovered fault is written for a human to read. Null discards the
/// text: the fault is still counted and still kept in `first`, which is what the
/// harness reads, so nothing is hidden by leaving this unset.
///
/// A writer rather than `std.log`, because `std.log` is ONE process-wide
/// destination behind ONE process-wide level. A library that logs through it
/// cannot be pointed somewhere else by the program embedding it, two instances
/// in one process cannot be told apart, and a test cannot read back what was
/// written without turning the level down for the whole process and hiding
/// every other test's output along with its own. An injected writer has none of
/// those problems and is the same rule the rest of this framework already
/// follows for input and output.
///
/// The terminal backend relies on the indirection: it points this at the same
/// descriptor it has redirected to a log file, so a fault reported while the
/// alternate screen is up cannot scroll the display out from under itself.
diagnostics: ?*std.Io.Writer = null,

/// Record a fault. Keeps the first one (for the harness) and counts them all.
/// In soft mode it also writes it to `diagnostics`; in strict mode the harness
/// inspects `first` after the pass and surfaces it.
pub fn report(self: *FaultSink, code: FaultCode, msg: []const u8) void {
    self.count += 1;
    if (self.first == null) self.first = .{ .code = code, .msg = msg };
    if (self.policy != .soft) return;
    const w = self.diagnostics orelse return;
    // Best effort, and flushed at once. A diagnostic that cannot be written is
    // not worth failing a frame over, and `count` and `first` have already
    // recorded the fault either way. Flushing per fault rather than per frame
    // because the next thing to happen may be the crash this line explains, and
    // faults are rare enough that the syscall costs nothing worth counting.
    w.print("phantom fault: {s}: {s}\n", .{ @tagName(code), msg }) catch {};
    w.flush() catch {};
}

/// True when no fault has been recorded since the last reset.
pub fn ok(self: *const FaultSink) bool {
    return self.count == 0;
}

/// Clear recorded faults (called at the start of each frame/pass).
pub fn reset(self: *FaultSink) void {
    self.first = null;
    self.count = 0;
}

test "records first fault, counts all, ok/reset behave" {
    var s = FaultSink{};
    try std.testing.expect(s.ok());
    s.report(.oom, "out of memory");
    try std.testing.expect(!s.ok());
    try std.testing.expectEqual(FaultCode.oom, s.first.?.code);
    s.report(.render_failed, "gpu");
    try std.testing.expectEqual(@as(usize, 2), s.count);
    // first is preserved, not overwritten
    try std.testing.expectEqual(FaultCode.oom, s.first.?.code);
    s.reset();
    try std.testing.expect(s.ok());
    try std.testing.expect(s.first == null);
}

test "a protocol fault records like any other code" {
    var s = FaultSink{};
    s.report(.protocol, "terminal input sequences dropped");
    try std.testing.expect(!s.ok());
    try std.testing.expectEqual(FaultCode.protocol, s.first.?.code);
}

test "a fault written to an injected writer names its code and its message" {
    var collected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer collected.deinit();
    var s = FaultSink{ .diagnostics = &collected.writer };
    s.report(.render_failed, "gpu");
    try std.testing.expectEqualStrings("phantom fault: render_failed: gpu\n", collected.written());
}

test "every fault reaches the writer, not only the first one the sink keeps" {
    var collected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer collected.deinit();
    var s = FaultSink{ .diagnostics = &collected.writer };
    s.report(.oom, "first");
    s.report(.protocol, "second");
    // `first` keeps one for the harness, but a human reading the log needs
    // every one: two faults in a frame is a different story from one.
    try std.testing.expectEqualStrings(
        "phantom fault: oom: first\nphantom fault: protocol: second\n",
        collected.written(),
    );
}

test "with no writer a fault is still counted and still kept, it is only the text that goes nowhere" {
    var s = FaultSink{};
    s.report(.oom, "out of memory");
    // This is what makes a silent test run honest rather than a cover up: the
    // harness reads `count` and `first`, and neither depends on there being
    // somewhere to write to.
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqual(FaultCode.oom, s.first.?.code);
    try std.testing.expect(!s.ok());
}

test "strict policy writes nothing, because the harness surfaces the fault itself" {
    var collected = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer collected.deinit();
    var s = FaultSink{ .policy = .strict, .diagnostics = &collected.writer };
    s.report(.oom, "out of memory");
    try std.testing.expectEqual(@as(usize, 0), collected.written().len);
    try std.testing.expectEqual(FaultCode.oom, s.first.?.code);
}

test "two sinks write to two places, which one process-wide logger could not do" {
    var a_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer a_out.deinit();
    var b_out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer b_out.deinit();
    var a = FaultSink{ .diagnostics = &a_out.writer };
    var b = FaultSink{ .diagnostics = &b_out.writer };

    a.report(.oom, "from a");
    b.report(.protocol, "from b");

    try std.testing.expect(std.mem.indexOf(u8, a_out.written(), "from a") != null);
    try std.testing.expect(std.mem.indexOf(u8, a_out.written(), "from b") == null);
    try std.testing.expect(std.mem.indexOf(u8, b_out.written(), "from b") != null);
    try std.testing.expect(std.mem.indexOf(u8, b_out.written(), "from a") == null);
}

test "strict policy still records the first fault" {
    var s = FaultSink{ .policy = .strict };
    s.report(.state_init, "init failed");
    try std.testing.expect(!s.ok());
    try std.testing.expectEqual(FaultCode.state_init, s.first.?.code);
}
