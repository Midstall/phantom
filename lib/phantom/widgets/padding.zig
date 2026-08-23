const std = @import("std");
const phantom = @import("../../phantom.zig");
const colored_box = @import("colored_box.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout = phantom.layout;

const RenderPadding = struct {
    base: RenderObject,
    /// Logical insets from the widget config. Converted to physical in layoutFn
    /// using the constraint scale, so paintFn always reads physical_insets.
    insets: geom.LogicalEdgeInsets,
    physical_insets: geom.PhysicalEdgeInsets = .{},
    child: ?*RenderObject = null,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderPadding = @fieldParentPtr("base", base);
        const pi = self.insets.toPhysical(c.scale);
        self.physical_insets = pi;
        const inner = c.deflate(pi);
        const child_size = if (self.child) |ch| ch.layout(inner) else geom.PhysicalSize.zero;
        return c.constrain(.{
            .width = child_size.width + pi.horizontal(),
            .height = child_size.height + pi.vertical(),
        });
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderPadding = @fieldParentPtr("base", base);
        const child = self.child orelse return;
        const child_offset = geom.PhysicalOffset{ .x = offset.x + self.physical_insets.left, .y = offset.y + self.physical_insets.top };
        child.paint(cv, child_offset) catch |e| {
            if (cv.sink) |s| s.report(.render_failed, @errorName(e));
            // The fallback paint allocates (display-list append) and can itself OOM.
            // Swallow that: a boundary must never re-throw or a fallback-paint failure
            // would abort the whole frame and defeat the point of the boundary.
            phantom.widgets.error_box.paintFault(cv, geom.PhysicalRect.fromOriginSize(child_offset, child.size)) catch {
                if (cv.sink) |s| s.report(.render_failed, "fault fallback paint also failed");
            };
        };
    }
    fn adoptChildFn(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderPadding = @fieldParentPtr("base", base);
        self.child = child;
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderPadding = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const Padding = struct {
    insets: geom.LogicalEdgeInsets,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Padding) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Padding = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderPadding);
        ro.* = .{
            .base = .{ .layoutFn = RenderPadding.layoutFn, .paintFn = RenderPadding.paintFn, .adoptChildFn = RenderPadding.adoptChildFn, .destroyFn = RenderPadding.destroyFn },
            .insets = self.insets,
        };
        const el = try gpa.create(Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Padding), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        // Build boundary: a child that fails to mount is replaced by an ErrorBox so the
        // rest of the tree survives.
        el.child = el.updateChild(null, self.child, bctx) catch |e| blk: {
            bctx.owner.sink.report(.build_failed, @errorName(e));
            const eb = phantom.ErrorBox{};
            break :blk el.updateChild(null, eb.widget(), bctx) catch null;
        };
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const Padding = @ptrCast(@alignCast(ptr));
        const ro: *RenderPadding = @fieldParentPtr("base", el.render_object.?);
        ro.insets = self.insets;
        el.child = el.updateChild(el.child, self.child, bctx) catch |e| blk: {
            bctx.owner.sink.report(.build_failed, @errorName(e));
            const eb = phantom.ErrorBox{};
            break :blk el.updateChild(el.child, eb.widget(), bctx) catch null;
        };
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "Padding insets the child and offsets its paint" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = colored_box.ColoredBox{ .color = geom.Color.rgb(0, 0, 1), .radius = 16 };
    var pad = Padding{ .insets = geom.LogicalEdgeInsets.all(40), .child = box.widget() };
    const el = try pad.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    const size = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 800, .height = 600 }));
    try std.testing.expectEqual(@as(f32, 800), size.width);
    try std.testing.expectEqual(@as(f32, 720), el.child.?.render_object.?.size.width);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 0, .y = 0 });
    const rr = canvas.list.primitives.items[0].rrect;
    try std.testing.expectEqual(@as(f32, 40), rr.rect.x);
    try std.testing.expectEqual(@as(f32, 40), rr.rect.y);
}

test "Padding+ColoredBox at scale 2 doubles physical insets and child size" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = colored_box.ColoredBox{ .color = geom.Color.rgb(0, 0, 1), .radius = 0 };
    var pad = Padding{ .insets = geom.LogicalEdgeInsets.all(10), .child = box.widget() };
    const el = try pad.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    // Layout at scale 2: logical insets 10 -> physical 20 per side; 200 - 2*20 = 160
    _ = el.render_object.?.layout(layout.BoxConstraints.tightScaled(.{ .width = 200, .height = 200 }, 2.0));
    const child_size = el.child.?.render_object.?.size;
    try std.testing.expectEqual(@as(f32, 160), child_size.width);
    try std.testing.expectEqual(@as(f32, 160), child_size.height);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 0, .y = 0 });
    const rr = canvas.list.primitives.items[0].rrect;
    // child painted at physical offset (20, 20)
    try std.testing.expectEqual(@as(f32, 20), rr.rect.x);
    try std.testing.expectEqual(@as(f32, 20), rr.rect.y);
    try std.testing.expectEqual(@as(f32, 160), rr.rect.width);
    try std.testing.expectEqual(@as(f32, 160), rr.rect.height);
}

const FailWidget = struct {
    const vt = Widget.VTable{ .mount = mnt, .update = upd };
    fn widget(self: *const FailWidget) Widget {
        return .{ .ptr = self, .vtable = &vt };
    }
    fn mnt(_: *const anyopaque, _: *phantom.BuildContext, _: ?*Element) anyerror!*Element {
        return error.OutOfMemory;
    }
    fn upd(_: *const anyopaque, _: *Element, _: *phantom.BuildContext) anyerror!void {}
};

test "Padding substitutes an ErrorBox when its child fails to build" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var failing = FailWidget{};
    var pad = Padding{ .insets = geom.LogicalEdgeInsets.all(10), .child = failing.widget() };
    const el = try pad.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.build_failed, sink.first.?.code);
    try std.testing.expectEqualStrings(@typeName(phantom.ErrorBox), el.child.?.type_name);
}
