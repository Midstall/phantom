//! PhantomUI MediaQuery component widget. Mirrors the Theme widget pattern:
//! sets the element's inherited_id/inherited_data slot so descendants can
//! walk up the element tree and find the nearest MediaQueryData via inheritedOf.
//! Direct imports are used (not ../phantom.zig) to avoid import cycles.
const std = @import("std");
const widget_mod = @import("../widget.zig");
const Widget = widget_mod.Widget;
const Element = widget_mod.Element;
const typeId = widget_mod.typeId;
const inheritedOf = widget_mod.inheritedOf;
const depthOf = widget_mod.depthOf;
const BuildContext = @import("../BuildContext.zig");
const view_mod = @import("../view.zig");
const MediaQueryData = view_mod.MediaQueryData;

/// A comptime-CONST default, not a mutable global. Apps install a real MediaQuery
/// at the root so MediaQuery.of normally finds an ancestor value.
const default_media_query = MediaQueryData{
    .size = @import("../geometry.zig").LogicalSize.zero,
    .dpr = 1,
    .text_scale = 1,
};

/// Component widget (render_object = null) that installs MediaQueryData into the
/// element tree so any descendant can retrieve it via MediaQuery.of.
pub const MediaQuery = struct {
    data: *const MediaQueryData,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const MediaQuery) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Return the nearest ancestor MediaQueryData, or the immutable default if none.
    pub fn of(bctx: *BuildContext) *const MediaQueryData {
        return inheritedOf(bctx.element, MediaQueryData) orelse &default_media_query;
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const MediaQuery = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(MediaQuery),
            .render_object = null,
            .inherited_id = typeId(MediaQueryData),
            .inherited_data = self.data,
            .depth = depthOf(parent),
        };
        el.child = try el.updateChild(null, self.child, bctx);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const MediaQuery = @ptrCast(@alignCast(ptr));
        el.inherited_data = self.data;
        el.child = try el.updateChild(el.child, self.child, bctx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const FaultSink = @import("../FaultSink.zig");
const ColoredBox = @import("colored_box.zig").ColoredBox;
const geom = @import("../geometry.zig");
const BuildOwner = @import("../BuildOwner.zig");

test "MediaQuery wrapping a child: inheritedOf finds the installed data" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var data = MediaQueryData{
        .size = geom.LogicalSize{ .width = 800, .height = 600 },
        .dpr = 2,
        .text_scale = 1.5,
    };
    var box = ColoredBox{ .color = geom.Color.rgb(0, 0, 1), .radius = 0 };
    var mq = MediaQuery{ .data = &data, .child = box.widget() };
    const el = try mq.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    // The child element can see the inherited slot via inheritedOf.
    const found = inheritedOf(el.child, MediaQueryData);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(f32, 2), found.?.dpr);
    try std.testing.expectEqual(@as(f32, 1.5), found.?.text_scale);
}

test "MediaQuery.of returns ancestor data when wrapped, default when not" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // Not wrapped: returns the module-level default (size.zero, dpr=1).
    const def = MediaQuery.of(&bctx);
    try std.testing.expectEqual(@as(f32, 0), def.size.width);
    try std.testing.expectEqual(@as(f32, 1), def.dpr);

    // Wrapped: mount a MediaQuery, set bctx.element to the child, then call of.
    var data = MediaQueryData{
        .size = geom.LogicalSize{ .width = 1920, .height = 1080 },
        .dpr = 3,
        .text_scale = 1,
    };
    var box = ColoredBox{ .color = geom.Color.rgb(1, 0, 0), .radius = 0 };
    var mq = MediaQuery{ .data = &data, .child = box.widget() };
    const el = try mq.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    // Simulate being inside the child's build: bctx.element = child element.
    bctx.element = el.child;
    const found = MediaQuery.of(&bctx);
    try std.testing.expectEqual(@as(f32, 3), found.dpr);
    try std.testing.expectEqual(@as(f32, 1920), found.size.width);
    // Reset.
    bctx.element = null;
}

test "MediaQuery owner.deinit is leak-clean" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    // deinit must free any views registered on the owner without leak.
    const view_mod2 = @import("../view.zig");
    const _id = try view_mod2.View.open(&owner, .{
        .title = "leak-test",
        .size = geom.LogicalSize{ .width = 100, .height = 100 },
        .dpr = 1,
    });
    _ = _id;
    // owner.deinit() called by defer above frees the boxed View.
}
