//! The lifetime-safe home for transient widget configs during one build pass. A `Widget`
//! borrows the memory its config lives in and is only valid through mount/update. A
//! `root()` builder that returned a Widget borrowing its own stack locals would dangle;
//! `new` copies into a scratch arena (reset each build pass) and hands out stable
//! pointers. The persistent element tree is allocated from `owner.gpa`, not the arena. On
//! OOM `new` does not panic: it records a fault and returns an inert sentinel.

const std = @import("std");
const FaultSink = @import("FaultSink.zig");
const BuildOwner = @import("BuildOwner.zig");
const panic_mod = @import("panic.zig");
const Element = @import("widget.zig").Element;
const BuildContext = @This();

/// Scratch allocator for transient widget configs, reset after each build pass.
arena: std.mem.Allocator,
/// Owns the persistent element tree (gpa), the fault sink, and the dirty queue.
owner: *BuildOwner,
/// The element whose State.build is currently running (set by Element.rebuild).
/// Anchors Theme.of / inheritedOf calls made inside a build. Null during the
/// initial top-down mount, where RenderObjectWidgets walk from their mount parent.
element: ?*Element = null,

pub fn sink(self: *const BuildContext) *FaultSink {
    return self.owner.sink;
}
pub fn gpa(self: *const BuildContext) std.mem.Allocator {
    return self.owner.gpa;
}

/// Copy a slice into the scratch arena and return a stable slice. On OOM:
/// record a fault and return an empty slice (the tree is discarded on fault).
pub fn newSlice(self: *BuildContext, comptime T: type, items: []const T) []T {
    if (self.arena.alloc(T, items.len)) |buf| {
        @memcpy(buf, items);
        return buf;
    } else |_| {
        self.owner.sink.report(.oom, "out of memory building widget child list");
        return &[_]T{};
    }
}

/// Copy `value` into the scratch arena and return a stable pointer. On OOM: record an
/// `oom` fault and return an inert zeroed sentinel (the fluent chain keeps going; the
/// tree is discarded by the framework on fault, so the sentinel is never dereferenced).
pub fn new(self: *BuildContext, value: anytype) *@TypeOf(value) {
    const T = @TypeOf(value);
    if (self.arena.create(T)) |p| {
        p.* = value;
        return p;
    } else |_| {
        self.owner.sink.report(.oom, "out of memory building widget tree");
        return sentinel(T);
    }
}

const SENTINEL_SIZE: usize = 256;
const SENTINEL_ALIGN: usize = 16;
var sentinel_buf: [SENTINEL_SIZE]u8 align(SENTINEL_ALIGN) = [_]u8{0} ** SENTINEL_SIZE;

fn sentinel(comptime T: type) *T {
    if (@sizeOf(T) > SENTINEL_SIZE or @alignOf(T) > SENTINEL_ALIGN) {
        panic_mod.panic("widget config {s} ({d} bytes) exceeds the fault sentinel", .{ @typeName(T), @sizeOf(T) });
    }
    return @ptrCast(@alignCast(&sentinel_buf));
}

fn testOwner(gpa_alloc: std.mem.Allocator, s: *FaultSink) BuildOwner {
    return .{ .gpa = gpa_alloc, .sink = s };
}

test "new copies into the arena and returns stable distinct pointers" {
    var fault_sink = FaultSink{};
    var owner = testOwner(std.testing.allocator, &fault_sink);
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var b = BuildContext{ .arena = arena.allocator(), .owner = &owner };
    const a = b.new(@as(u32, 7));
    const c = b.new(@as(u32, 9));
    try std.testing.expectEqual(@as(u32, 7), a.*);
    try std.testing.expectEqual(@as(u32, 9), c.*);
    try std.testing.expect(a != c);
    try std.testing.expect(fault_sink.ok());
}

test "new under OOM records a fault and returns an inert sentinel (no crash)" {
    var fault_sink = FaultSink{};
    var owner = testOwner(std.testing.allocator, &fault_sink);
    defer owner.deinit();
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var b = BuildContext{ .arena = fa.allocator(), .owner = &owner };
    const p = b.new(@as(u32, 42));
    try std.testing.expect(!fault_sink.ok());
    try std.testing.expectEqual(FaultSink.FaultCode.oom, fault_sink.first.?.code);
    try std.testing.expectEqual(@as(u32, 0), p.*);
}
