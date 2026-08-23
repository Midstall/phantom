//! PhantomUI View: one window or canvas with its display metrics.
//! MediaQueryData carries logical size, device pixel ratio, and text scale.
//! View.open allocates a boxed View on the BuildOwner so the metrics pointer
//! is stable even when more views are added later.
//! Direct imports are used (not ../phantom.zig) to avoid import cycles.
const std = @import("std");
const BuildOwner = @import("BuildOwner.zig");
const geom = @import("geometry.zig");

/// Display metrics for one logical view. Logical size is widget-facing;
/// dpr converts to physical pixels; text_scale is an accessibility multiplier.
pub const MediaQueryData = struct {
    size: geom.LogicalSize,
    dpr: f32,
    text_scale: f32 = 1.0,

    /// Convenience: the product that a native backend would apply to layout.
    /// Web entry points (Task 5) may supply only text_scale to layout and let
    /// the browser handle DPR; do not embed that split here.
    pub fn effectiveScale(self: MediaQueryData) f32 {
        return self.dpr * self.text_scale;
    }
};

/// A single window or canvas managed by this BuildOwner instance.
/// title is a BORROWED slice (caller-owned, must outlive the View). No copy, no free.
pub const View = struct {
    id: u32,
    title: []const u8,
    metrics: MediaQueryData,

    /// Allocate a boxed View on owner.gpa, register it in owner.views, set
    /// owner.active_view if none yet, and return the new id.
    /// The box ensures &view.metrics is a stable pointer even when the map resizes.
    pub fn open(owner: *BuildOwner, opts: struct {
        title: []const u8,
        size: geom.LogicalSize,
        dpr: f32 = 1.0,
        text_scale: f32 = 1.0,
    }) !u32 {
        const id = owner.next_view_id;
        owner.next_view_id += 1;
        const boxed = try owner.gpa.create(View);
        // Free the box if the map insert below OOMs, so the error path does not leak.
        errdefer owner.gpa.destroy(boxed);
        boxed.* = .{
            .id = id,
            .title = opts.title,
            .metrics = .{
                .size = opts.size,
                .dpr = opts.dpr,
                .text_scale = opts.text_scale,
            },
        };
        try owner.views.put(owner.gpa, id, boxed);
        if (owner.active_view == null) owner.active_view = id;
        return id;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const FaultSink = @import("FaultSink.zig");

test "View.open stores boxed View on owner, active_view set, metrics stable" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();

    const id = try View.open(&owner, .{
        .title = "w",
        .size = geom.LogicalSize{ .width = 800, .height = 600 },
        .dpr = 2,
        .text_scale = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), id);
    try std.testing.expect(owner.views.get(id) != null);
    try std.testing.expectEqual(@as(?u32, 0), owner.active_view);
    const v = owner.views.get(id).?;
    try std.testing.expectEqual(@as(f32, 2), v.metrics.dpr);
    try std.testing.expectEqual(@as(f32, 2), v.metrics.effectiveScale());
}

test "two BuildOwners are fully independent (no shared state)" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var ownerA = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer ownerA.deinit();
    var ownerB = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer ownerB.deinit();

    const idA = try View.open(&ownerA, .{
        .title = "a",
        .size = geom.LogicalSize{ .width = 1024, .height = 768 },
        .dpr = 1,
    });
    const idB = try View.open(&ownerB, .{
        .title = "b",
        .size = geom.LogicalSize{ .width = 320, .height = 480 },
        .dpr = 3,
    });
    // Both ids start at 0 independently.
    try std.testing.expectEqual(@as(u32, 0), idA);
    try std.testing.expectEqual(@as(u32, 0), idB);
    // Each owner has exactly one view; they do not share the map.
    try std.testing.expectEqual(@as(usize, 1), ownerA.views.count());
    try std.testing.expectEqual(@as(usize, 1), ownerB.views.count());
    // DPR is per-owner, not shared.
    try std.testing.expectEqual(@as(f32, 1), ownerA.views.get(0).?.metrics.dpr);
    try std.testing.expectEqual(@as(f32, 3), ownerB.views.get(0).?.metrics.dpr);
}
