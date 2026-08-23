const std = @import("std");
const layout_mod = @import("layout.zig");
const geom = @import("geometry.zig");
const canvas_mod = @import("canvas.zig");
const pointer_mod = @import("pointer.zig");
const widget_mod = @import("widget.zig");

/// Re-exported from the widget layer so a render object can tag itself without
/// depending on widget internals. One stable, distinct usize per type.
pub const typeId = widget_mod.typeId;

pub const RenderObject = struct {
    layoutFn: *const fn (self: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize,
    paintFn: *const fn (self: *RenderObject, cv: *canvas_mod.Canvas, offset: geom.PhysicalOffset) anyerror!void,
    /// Free the concrete render object that embeds this base. Null for stack-owned
    /// render objects (tests) and set for every gpa-owned one so Element.deinit can
    /// reclaim it. Implementations recover the concrete pointer via @fieldParentPtr.
    destroyFn: ?*const fn (self: *RenderObject, gpa: std.mem.Allocator) void = null,
    /// Set this render object's single child slot. Only single-child render objects
    /// (RenderPadding) implement it. Leaves leave it null.
    adoptChildFn: ?*const fn (self: *RenderObject, child: ?*RenderObject) void = null,
    size: geom.PhysicalSize = geom.PhysicalSize.zero,
    /// Absolute physical top-left recorded by the last paint (for hit-testing).
    origin: geom.PhysicalOffset = geom.PhysicalOffset.zero,
    /// Pointer handlers installed by a gesture widget. Null for non-interactive
    /// render objects. Hit-testing returns the deepest one whose bounds contain
    /// the point.
    pointer: ?*pointer_mod.PointerHandlers = null,
    /// Keyboard handlers installed by a focusable widget. Null for everything that
    /// does not take the keyboard. The focus manager collects these in tree order.
    focus: ?*@import("focus.zig").FocusHandlers = null,
    /// Keyboard handlers installed by a `KeyboardListener`. This widget does not join
    /// the Tab order, so it carries its own slot instead of sharing `focus`. The focus
    /// manager collects these in tree order too, and consults them last: after the
    /// focused node and after Tab and Escape.
    key_listener: ?*@import("focus.zig").FocusHandlers = null,
    /// Identity of the concrete struct that embeds this base, set at construction
    /// with `typeId(T)`. Null means untagged: no parent may downcast it, which
    /// keeps every render object that does not need a downcast unchanged.
    ///
    /// A parent must not use `layoutFn` as a per-type tag. ReleaseFast and
    /// ReleaseSmall merge two identical function bodies to one address, so two
    /// unrelated render objects compare equal there and `@fieldParentPtr` then
    /// aims at a foreign struct with no fault reported.
    type_id: ?usize = null,

    /// True when this render object was tagged as `T` at construction. Call this
    /// before `@fieldParentPtr`, which is only sound once the tag proves the type.
    pub fn isType(self: *const RenderObject, comptime T: type) bool {
        const id = self.type_id orelse return false;
        return id == typeId(T);
    }

    pub fn layout(self: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        self.size = self.layoutFn(self, c);
        return self.size;
    }
    pub fn paint(self: *RenderObject, cv: *canvas_mod.Canvas, offset: geom.PhysicalOffset) !void {
        self.origin = offset;
        return self.paintFn(self, cv, offset);
    }
    pub fn destroy(self: *RenderObject, gpa: std.mem.Allocator) void {
        if (self.destroyFn) |f| f(self, gpa);
    }
    pub fn adoptChild(self: *RenderObject, child: ?*RenderObject) void {
        if (self.adoptChildFn) |f| f(self, child);
    }
};

const FixedBox = struct {
    base: RenderObject,
    fn layoutFn(_: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        return c.constrain(.{ .width = 50, .height = 30 });
    }
    fn paintFn(_: *RenderObject, _: *canvas_mod.Canvas, _: geom.PhysicalOffset) anyerror!void {}
};

test "layout stores size" {
    var fb = FixedBox{ .base = .{ .layoutFn = FixedBox.layoutFn, .paintFn = FixedBox.paintFn } };
    const s = fb.base.layout(.{});
    try std.testing.expectEqual(@as(f32, 50), s.width);
    try std.testing.expectEqual(@as(f32, 30), fb.base.size.height);
}

const OneChild = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    freed: *bool,
    fn lf(_: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        return c.constrain(.{ .width = 1, .height = 1 });
    }
    fn pf(_: *RenderObject, _: *canvas_mod.Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *OneChild = @fieldParentPtr("base", base);
        self.child = child;
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *OneChild = @fieldParentPtr("base", base);
        self.freed.* = true;
        _ = gpa;
    }
};

test "adoptChild sets the child slot and destroy routes through destroyFn" {
    var freed = false;
    var oc = OneChild{
        .base = .{ .layoutFn = OneChild.lf, .paintFn = OneChild.pf, .adoptChildFn = OneChild.adopt, .destroyFn = OneChild.destroyFn },
        .freed = &freed,
    };
    var leaf = FixedBox{ .base = .{ .layoutFn = FixedBox.layoutFn, .paintFn = FixedBox.paintFn } };
    oc.base.adoptChild(&leaf.base);
    try std.testing.expect(oc.child == &leaf.base);
    oc.base.adoptChild(null);
    try std.testing.expect(oc.child == null);
    oc.base.destroy(std.testing.allocator);
    try std.testing.expect(freed);
}

test "destroy and adoptChild are no-ops when the slots are null" {
    var fb = FixedBox{ .base = .{ .layoutFn = FixedBox.layoutFn, .paintFn = FixedBox.paintFn } };
    fb.base.adoptChild(null); // no crash
    fb.base.destroy(std.testing.allocator); // no crash, nothing freed
}

/// A near-clone of FixedBox: same field layout, byte-identical layoutFn body. The
/// optimizer is free to give both types the same layoutFn address, which is why
/// the type tag exists.
const CloneBox = struct {
    base: RenderObject,
    fn layoutFn(_: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        return c.constrain(.{ .width = 50, .height = 30 });
    }
    fn paintFn(_: *RenderObject, _: *canvas_mod.Canvas, _: geom.PhysicalOffset) anyerror!void {}
};

test "isType matches a tagged render object and rejects an untagged one" {
    var tagged = CloneBox{ .base = .{
        .layoutFn = CloneBox.layoutFn,
        .paintFn = CloneBox.paintFn,
        .type_id = typeId(CloneBox),
    } };
    var untagged = FixedBox{ .base = .{ .layoutFn = FixedBox.layoutFn, .paintFn = FixedBox.paintFn } };
    try std.testing.expect(tagged.base.isType(CloneBox));
    try std.testing.expect(untagged.base.type_id == null);
    try std.testing.expect(!untagged.base.isType(CloneBox));
    try std.testing.expect(!untagged.base.isType(FixedBox));
}

test "isType separates two types whose layout bodies may share one address" {
    var a = FixedBox{ .base = .{
        .layoutFn = FixedBox.layoutFn,
        .paintFn = FixedBox.paintFn,
        .type_id = typeId(FixedBox),
    } };
    var b = CloneBox{ .base = .{
        .layoutFn = CloneBox.layoutFn,
        .paintFn = CloneBox.paintFn,
        .type_id = typeId(CloneBox),
    } };
    try std.testing.expect(a.base.isType(FixedBox));
    try std.testing.expect(b.base.isType(CloneBox));
    // The tags stay distinct even in a build where the two layoutFn pointers merge.
    try std.testing.expect(!a.base.isType(CloneBox));
    try std.testing.expect(!b.base.isType(FixedBox));
    try std.testing.expect(a.base.type_id.? != b.base.type_id.?);
}
