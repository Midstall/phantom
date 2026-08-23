//! Placement and forced sizing for a single child. Flex distributes children
//! along an axis and padding pushes them inwards, but neither can pin a child
//! to a corner of its parent or give it an exact size. A shell bar needs both:
//! a fixed height across the full width, with clusters at the left, centre and
//! right of that bar.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;

pub const Alignment = enum {
    top_left,
    top_center,
    top_right,
    center_left,
    center,
    center_right,
    bottom_left,
    bottom_center,
    bottom_right,

    /// The child's origin inside `parent`, given the child's size.
    pub fn offsetFor(
        self: Alignment,
        parent: geom.PhysicalSize,
        child: geom.PhysicalSize,
    ) geom.PhysicalOffset {
        const free_x = parent.width - child.width;
        const free_y = parent.height - child.height;
        // Both switches are exhaustive with no `else`, so a tenth alignment
        // fails the build instead of landing silently at zero.
        return .{
            .x = switch (self) {
                .top_left, .center_left, .bottom_left => 0,
                .top_center, .center, .bottom_center => free_x / 2,
                .top_right, .center_right, .bottom_right => free_x,
            },
            .y = switch (self) {
                .top_left, .top_center, .top_right => 0,
                .center_left, .center, .center_right => free_y / 2,
                .bottom_left, .bottom_center, .bottom_right => free_y,
            },
        };
    }
};

const RenderAlign = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    alignment: Alignment,
    /// Physical origin of the child inside this box, resolved by the last
    /// layout pass. paintFn adds it to the incoming offset.
    child_offset: geom.PhysicalOffset = geom.PhysicalOffset.zero,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderAlign = @fieldParentPtr("base", base);
        // The child gets loose constraints or it would fill the box and never
        // move.
        const child_c = layout.BoxConstraints{
            .min_width = 0,
            .max_width = c.max_width,
            .min_height = 0,
            .max_height = c.max_height,
            .scale = c.scale,
        };
        const child_size = if (self.child) |ch| ch.layout(child_c) else geom.PhysicalSize.zero;
        // Align fills what it is given, but an unbounded axis has no biggest to
        // fill, so it wraps the child there instead of collapsing to the minimum.
        const size = geom.PhysicalSize{
            .width = if (std.math.isInf(c.max_width)) @max(c.min_width, child_size.width) else c.max_width,
            .height = if (std.math.isInf(c.max_height)) @max(c.min_height, child_size.height) else c.max_height,
        };
        self.child_offset = self.alignment.offsetFor(size, child_size);
        return size;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderAlign = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset.add(self.child_offset));
    }

    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderAlign = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderAlign = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const Align = struct {
    alignment: Alignment = .center,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Align) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Align = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderAlign);
        ro.* = .{
            .base = .{
                .layoutFn = RenderAlign.layoutFn,
                .paintFn = RenderAlign.paintFn,
                .destroyFn = RenderAlign.destroyFn,
                .adoptChildFn = RenderAlign.adopt,
            },
            .alignment = self.alignment,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Align),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Align = @ptrCast(@alignCast(ptr));
        const ro: *RenderAlign = @fieldParentPtr("base", el.render_object.?);
        ro.alignment = self.alignment;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

/// Centre a child in the space its parent offers.
pub fn Center(opts: struct { child: Widget }) Align {
    return .{ .alignment = .center, .child = opts.child };
}

const RenderSizedBox = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    /// Logical extents from the widget config. layoutFn multiplies them by the
    /// constraint scale so the box keeps its apparent size on a HiDPI display.
    /// A null axis is not zero: it means the incoming constraint stands.
    width: ?f32,
    height: ?f32,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderSizedBox = @fieldParentPtr("base", base);
        const physical_width = if (self.width) |v| v * c.scale else null;
        const physical_height = if (self.height) |v| v * c.scale else null;
        const child_c = (layout.BoxConstraints{
            .min_width = physical_width orelse c.min_width,
            .max_width = physical_width orelse c.max_width,
            .min_height = physical_height orelse c.min_height,
            .max_height = physical_height orelse c.max_height,
            .scale = c.scale,
        }).enforce(c);
        if (self.child) |ch| return c.constrain(ch.layout(child_c));
        return child_c.constrain(geom.PhysicalSize.zero);
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderSizedBox = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }

    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderSizedBox = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderSizedBox = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const SizedBox = struct {
    /// Logical width. Null leaves the axis to the incoming constraint.
    width: ?f32 = null,
    /// Logical height. Null leaves the axis to the incoming constraint.
    height: ?f32 = null,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const SizedBox) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const SizedBox = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderSizedBox);
        ro.* = .{
            .base = .{
                .layoutFn = RenderSizedBox.layoutFn,
                .paintFn = RenderSizedBox.paintFn,
                .destroyFn = RenderSizedBox.destroyFn,
                .adoptChildFn = RenderSizedBox.adopt,
            },
            .width = self.width,
            .height = self.height,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(SizedBox),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const SizedBox = @ptrCast(@alignCast(ptr));
        const ro: *RenderSizedBox = @fieldParentPtr("base", el.render_object.?);
        ro.width = self.width;
        ro.height = self.height;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "SizedBox takes the given logical size out of loose constraints" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };

    const el = try sb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.loose(.{ .width = 400, .height = 300 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 100), rect.width);
    try std.testing.expectEqual(@as(f32, 40), rect.height);
}

test "a tight parent overrides the size SizedBox asks for" {
    // Parent constraints win. To get an unconstrained size, wrap the SizedBox
    // in a Center, which hands its child loose constraints.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };

    const el = try sb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const size = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }));
    try std.testing.expectEqual(@as(f32, 400), size.width);
    try std.testing.expectEqual(@as(f32, 300), size.height);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 400), rect.width);
    try std.testing.expectEqual(@as(f32, 300), rect.height);
}

test "SizedBox with only a height leaves the width to the constraints" {
    // The top bar sets a height and spans the full width. An implementation
    // that treats a null field as zero fails exactly here.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var sb = SizedBox{ .height = 40, .child = box.widget() };

    const el = try sb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.loose(.{ .width = 400, .height = 300 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 400), rect.width);
    try std.testing.expectEqual(@as(f32, 40), rect.height);
}

test "Center places a fixed-size child in the middle of its parent" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };
    var ce = Center(.{ .child = sb.widget() });

    const el = try ce.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const size = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }));
    try std.testing.expectEqual(@as(f32, 400), size.width);
    try std.testing.expectEqual(@as(f32, 300), size.height);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    // (400 - 100) / 2 = 150 and (300 - 40) / 2 = 130.
    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 150), rect.x);
    try std.testing.expectEqual(@as(f32, 130), rect.y);
}

test "Align .top_right puts the child against the top right corner" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };
    var al = Align{ .alignment = .top_right, .child = sb.widget() };

    const el = try al.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    // The right edge lands on 400 and the top edge stays on 0.
    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 300), rect.x);
    try std.testing.expectEqual(@as(f32, 0), rect.y);
}

test "SizedBox scales its logical size by the layout scale" {
    // Without the scale factor the shell renders at half size on a HiDPI
    // display, because the logical numbers reach the display list unchanged.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 1) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };

    const el = try sb.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    // Loose, because a tight parent would win over the scaled size and hide the
    // fact this test pins.
    _ = el.renderObject().?.layout(.{
        .max_width = 400,
        .max_height = 300,
        .scale = 2.0,
    });

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 200), rect.width);
    try std.testing.expectEqual(@as(f32, 80), rect.height);
}

test "Align wraps its child on an unbounded axis and fills the bounded one" {
    // An infinite max_width has no biggest to fill. Taking the minimum there
    // collapses the box to zero and the child vanishes from the scene.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var box = phantom.ColoredBox{ .color = geom.Color.rgb(1, 1, 0) };
    var sb = SizedBox{ .width = 100, .height = 40, .child = box.widget() };
    var al = Align{ .alignment = .bottom_left, .child = sb.widget() };

    const el = try al.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const size = el.renderObject().?.layout(.{
        .min_width = 0,
        .max_width = std.math.inf(f32),
        .min_height = 0,
        .max_height = 300,
    });
    try std.testing.expectEqual(@as(f32, 100), size.width);
    try std.testing.expectEqual(@as(f32, 300), size.height);

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    // Bottom left of a 100x300 box: x stays at 0 and y is 300 - 40.
    const rect = canvas.list.primitives.items[0].rrect.rect;
    try std.testing.expectEqual(@as(f32, 0), rect.x);
    try std.testing.expectEqual(@as(f32, 260), rect.y);
}
