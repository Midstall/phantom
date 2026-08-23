const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout = phantom.layout;

const RenderColoredBox = struct {
    base: RenderObject,
    color: geom.Color,
    /// Logical corner radius from the widget config. Scaled to physical in
    /// layoutFn using the constraint scale; paintFn reads physical_radius.
    radius: f32,
    physical_radius: f32 = 0,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderColoredBox = @fieldParentPtr("base", base);
        self.physical_radius = self.radius * c.scale;
        return c.biggest();
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderColoredBox = @fieldParentPtr("base", base);
        try cv.fillRRect(geom.PhysicalRect.fromOriginSize(offset, base.size), self.physical_radius, self.color);
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderColoredBox = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const ColoredBox = struct {
    color: geom.Color,
    radius: f32 = 0,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const ColoredBox) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const ColoredBox = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderColoredBox);
        ro.* = .{
            .base = .{ .layoutFn = RenderColoredBox.layoutFn, .paintFn = RenderColoredBox.paintFn, .destroyFn = RenderColoredBox.destroyFn },
            .color = self.color,
            .radius = self.radius,
        };
        const el = try gpa.create(Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(ColoredBox), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        _ = bctx;
        const self: *const ColoredBox = @ptrCast(@alignCast(ptr));
        const ro: *RenderColoredBox = @fieldParentPtr("base", el.render_object.?);
        ro.color = self.color;
        ro.radius = self.radius;
    }
};

test "ColoredBox fills constraints and records an rrect" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var cb = ColoredBox{ .color = geom.Color.rgb(0, 0, 1), .radius = 16 };
    const el = try cb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const size = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 200), size.width);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 5, .y = 7 });
    const rr = canvas.list.primitives.items[0].rrect;
    try std.testing.expectEqual(@as(f32, 5), rr.rect.x);
    try std.testing.expectEqual(@as(f32, 200), rr.rect.width);
    try std.testing.expectEqual(@as(f32, 16), rr.radius);
}

test "ColoredBox.update mutates the render object in place" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var cb1 = ColoredBox{ .color = geom.Color.rgb(0, 0, 1), .radius = 4 };
    const el = try cb1.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const ro_before = el.render_object.?;

    var cb2 = ColoredBox{ .color = geom.Color.rgb(1, 0, 0), .radius = 20 };
    try cb2.widget().update(el, &bctx);
    try std.testing.expect(el.render_object.? == ro_before); // same render object, updated in place
    _ = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 10, .height = 10 }));
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(@as(f32, 20), canvas.list.primitives.items[0].rrect.radius);
}
