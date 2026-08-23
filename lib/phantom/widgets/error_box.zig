const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout = phantom.layout;

/// The fallback fill for a faulted subtree: magenta, so a soft-failed region is
/// obvious on screen. Later (once text exists) it can also show the fault message.
pub const fault_color = geom.Color{ .r = 1, .g = 0, .b = 1, .a = 1 };

/// Paint the fault surface directly at `rect`. Used by the paint error boundary,
/// which catches a child's paint failure mid-frame and cannot allocate a new
/// element, so it draws the fallback straight into the canvas.
pub fn paintFault(cv: *Canvas, rect: geom.PhysicalRect) !void {
    try cv.fillRRect(rect, 0, fault_color);
}

const RenderErrorBox = struct {
    base: RenderObject,
    fn layoutFn(_: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        return c.biggest();
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        try paintFault(cv, geom.PhysicalRect.fromOriginSize(offset, base.size));
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderErrorBox = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const ErrorBox = struct {
    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const ErrorBox) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        _ = ptr;
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderErrorBox);
        ro.* = .{ .base = .{ .layoutFn = RenderErrorBox.layoutFn, .paintFn = RenderErrorBox.paintFn, .destroyFn = RenderErrorBox.destroyFn } };
        const el = try gpa.create(Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(ErrorBox), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        return el;
    }

    fn update(_: *const anyopaque, _: *Element, _: *phantom.BuildContext) anyerror!void {}
};

test "ErrorBox fills its slot and paints the fault color" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var eb = ErrorBox{};
    const el = try eb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 50, .height = 50 }));
    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 0, .y = 0 });
    const rr = canvas.list.primitives.items[0].rrect;
    try std.testing.expectEqual(@as(f32, 1), rr.color.r);
    try std.testing.expectEqual(@as(f32, 0), rr.color.g);
    try std.testing.expectEqual(@as(f32, 1), rr.color.b);
}
