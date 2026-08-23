const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;

const RenderDecoratedBox = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    color: ?geom.Color,
    radius: f32, // logical
    border_color: ?geom.Color,
    border_width: f32, // logical
    physical_radius: f32 = 0,
    physical_border: f32 = 0,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderDecoratedBox = @fieldParentPtr("base", base);
        self.physical_radius = self.radius * c.scale;
        self.physical_border = self.border_width * c.scale;
        if (self.child) |ch| return ch.layout(c); // proxy: pass constraints, size to child
        return c.constrain(geom.PhysicalSize.zero);
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderDecoratedBox = @fieldParentPtr("base", base);
        const rect = geom.PhysicalRect.fromOriginSize(offset, base.size);
        if (self.color) |col| try cv.fillRRect(rect, self.physical_radius, col);
        if (self.border_color) |bc| if (self.physical_border > 0)
            try cv.strokeRRect(rect, self.physical_radius, self.physical_border, bc);
        if (self.child) |ch| try ch.paint(cv, offset); // child on top of decoration
    }
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderDecoratedBox = @fieldParentPtr("base", base);
        self.child = child;
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderDecoratedBox = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const DecoratedBox = struct {
    color: ?geom.Color = null,
    radius: f32 = 0,
    border_color: ?geom.Color = null,
    border_width: f32 = 0,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const DecoratedBox) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const DecoratedBox = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderDecoratedBox);
        ro.* = .{
            .base = .{
                .layoutFn = RenderDecoratedBox.layoutFn,
                .paintFn = RenderDecoratedBox.paintFn,
                .destroyFn = RenderDecoratedBox.destroyFn,
                .adoptChildFn = RenderDecoratedBox.adopt,
            },
            .gpa = gpa,
            .color = self.color,
            .radius = self.radius,
            .border_color = self.border_color,
            .border_width = self.border_width,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(DecoratedBox),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const DecoratedBox = @ptrCast(@alignCast(ptr));
        const ro: *RenderDecoratedBox = @fieldParentPtr("base", el.render_object.?);
        ro.color = self.color;
        ro.radius = self.radius;
        ro.border_color = self.border_color;
        ro.border_width = self.border_width;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "DecoratedBox with fill color: proxy sizes to child, first primitive is filled rrect, child primitive follows" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const scale = 2.0;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0), .radius = 0 };
    var db = DecoratedBox{
        .color = phantom.Color.rgb(0, 0, 1),
        .radius = 4,
        .child = box.widget(),
    };
    const el = try db.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const constraints = layout.BoxConstraints.tightScaled(.{ .width = 80, .height = 40 }, scale);
    const size = el.render_object.?.layout(constraints);

    // proxy: DecoratedBox size == child size (ColoredBox fills)
    try std.testing.expectEqual(@as(f32, 80), size.width);
    try std.testing.expectEqual(@as(f32, 40), size.height);
    try std.testing.expectEqual(@as(f32, 80), el.child.?.render_object.?.size.width);

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const offset = phantom.PhysicalOffset{ .x = 0, .y = 0 };
    try el.render_object.?.paint(&canvas, offset);

    // first primitive is the decoration rrect (filled: stroke_width == 0)
    const prims = canvas.list.primitives.items;
    try std.testing.expect(prims.len >= 2);
    const deco_rr = prims[0].rrect;
    try std.testing.expectEqual(@as(f32, 0), deco_rr.color.r);
    try std.testing.expectEqual(@as(f32, 0), deco_rr.color.g);
    try std.testing.expectEqual(@as(f32, 1), deco_rr.color.b);
    try std.testing.expectEqual(@as(f32, 0), deco_rr.stroke_width); // filled
    try std.testing.expectEqual(@as(f32, 4 * scale), deco_rr.radius);
    try std.testing.expectEqual(@as(f32, 0), deco_rr.rect.x);
    try std.testing.expectEqual(@as(f32, 0), deco_rr.rect.y);

    // second primitive is the child's own rrect
    const child_rr = prims[1].rrect;
    try std.testing.expectEqual(@as(f32, 1), child_rr.color.r);
    try std.testing.expectEqual(@as(f32, 0), child_rr.color.g);
}

test "DecoratedBox with border only: single stroked rrect, no filled rrect" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const scale = 1.0;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0), .radius = 0 };
    const border_col = phantom.Color.rgb(0.5, 0, 0.5);
    var db = DecoratedBox{
        .border_color = border_col,
        .border_width = 1,
        .child = box.widget(),
    };
    const el = try db.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.render_object.?.layout(layout.BoxConstraints.tightScaled(.{ .width = 60, .height = 30 }, scale));

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, phantom.PhysicalOffset.zero);

    const prims = canvas.list.primitives.items;
    // exactly 2: the stroked border rrect + the child's filled rrect
    try std.testing.expect(prims.len == 2);
    const border_rr = prims[0].rrect;
    // stroke_width == 1 * scale (physical)
    try std.testing.expectEqual(@as(f32, 1 * scale), border_rr.stroke_width);
    // no fill (color is the border_color, not a fill)
    try std.testing.expectEqual(border_col.r, border_rr.color.r);
    // the second primitive is the child (green fill)
    const child_rr = prims[1].rrect;
    try std.testing.expectEqual(@as(f32, 1), child_rr.color.g);
    // no additional filled rrect (color was null so only one pre-child primitive)
    try std.testing.expectEqual(@as(usize, 2), prims.len);
}
