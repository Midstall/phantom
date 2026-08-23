//! Overlapping children, painted in order. The first child sizes the stack and
//! the rest are drawn over it. A shell layers a bar and a dock over a
//! wallpaper, which no single-child or flex widget can express.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;

/// Scale one logical edge inset to physical. A null edge does not pin the
/// child, so it stays null instead of becoming a zero inset.
fn toPhysical(logical: ?f32, scale: f32) ?f32 {
    return if (logical) |v| v * scale else null;
}

/// The tight extent of an axis whose two edges are both pinned, else null when
/// the child keeps its own extent.
fn spanExtent(available: f32, start: ?f32, end: ?f32) ?f32 {
    if (start != null and end != null) return @max(0.0, available - start.? - end.?);
    return null;
}

/// Where a child of `extent` sits on one axis. The start edge wins when both
/// are pinned, because the span above already made the child fill the gap.
fn axisOffset(available: f32, start: ?f32, end: ?f32, extent: f32) f32 {
    if (start) |s| return s;
    if (end) |e| return available - e - extent;
    return 0;
}

pub const RenderPositioned = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    /// Logical edge insets from the widget config. layoutFn converts them with
    /// the constraint scale so the inset keeps its apparent size on a HiDPI
    /// display.
    top: ?f32,
    right: ?f32,
    bottom: ?f32,
    left: ?f32,
    /// Physical offset inside the parent stack, resolved by the last layout
    /// pass. The stack reads it to place this child at paint time.
    resolved: geom.PhysicalOffset = geom.PhysicalOffset.zero,

    pub fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderPositioned = @fieldParentPtr("base", base);
        const available = c.biggest();
        const top = toPhysical(self.top, c.scale);
        const right = toPhysical(self.right, c.scale);
        const bottom = toPhysical(self.bottom, c.scale);
        const left = toPhysical(self.left, c.scale);

        const width_span = spanExtent(available.width, left, right);
        const height_span = spanExtent(available.height, top, bottom);
        // enforce on the way down and constrain on the way up: a pinned span is a
        // wish, and the parent stack's limits always win over it.
        const child_c = (layout.BoxConstraints{
            .min_width = width_span orelse 0,
            .max_width = width_span orelse available.width,
            .min_height = height_span orelse 0,
            .max_height = height_span orelse available.height,
            .scale = c.scale,
        }).enforce(c);
        const size = if (self.child) |ch| c.constrain(ch.layout(child_c)) else child_c.constrain(geom.PhysicalSize.zero);
        self.resolved = .{
            .x = axisOffset(available.width, left, right, size.width),
            .y = axisOffset(available.height, top, bottom, size.height),
        };
        return size;
    }

    pub fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderPositioned = @fieldParentPtr("base", base);
        // The parent stack already added `resolved` to this offset.
        if (self.child) |ch| try ch.paint(cv, offset);
    }

    pub fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderPositioned = @fieldParentPtr("base", base);
        self.child = child;
    }

    pub fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderPositioned = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

/// Recover a positioned child from a type-erased render object. The `type_id`
/// tag proves the concrete type, so @fieldParentPtr below is sound. A layoutFn
/// comparison would not be: release builds merge identical function bodies.
fn asPositioned(ro: *RenderObject) ?*RenderPositioned {
    if (!ro.isType(RenderPositioned)) return null;
    return @fieldParentPtr("base", ro);
}

pub const RenderStack = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    /// Where an allocation failure during layout is reported. A dropped child is
    /// invisible on screen, so it must never fail silently. Null only for a
    /// stack-owned RenderStack that no widget mounted.
    sink: ?*phantom.FaultSink = null,
    children: std.ArrayList(*RenderObject) = .empty,
    offsets: std.ArrayList(geom.PhysicalOffset) = .empty,

    /// Report an allocation failure that costs the stack a child this frame.
    fn reportOom(self: *RenderStack, msg: []const u8) void {
        if (self.sink) |s| s.report(.oom, msg);
    }

    pub fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderStack = @fieldParentPtr("base", base);
        self.offsets.clearRetainingCapacity();
        if (self.children.items.len == 0) return c.constrain(geom.PhysicalSize.zero);
        self.offsets.ensureTotalCapacity(self.gpa, self.children.items.len) catch {
            self.reportOom("out of memory reserving Stack child offsets");
        };
        // The first child sizes the stack. Every later child is laid out loosely
        // inside that size so an overlay can never grow the stack.
        const size = c.constrain(self.children.items[0].layout(c));
        const overlay_c = layout.BoxConstraints{
            .min_width = 0,
            .max_width = size.width,
            .min_height = 0,
            .max_height = size.height,
            .scale = c.scale,
        };
        for (self.children.items, 0..) |ch, i| {
            if (i > 0) _ = ch.layout(overlay_c);
            const off = if (asPositioned(ch)) |p| p.resolved else geom.PhysicalOffset.zero;
            // Capacity was reserved above; if that OOMed, append safely (a short
            // offsets list is tolerated by paintFn, which iterates by offsets len).
            self.offsets.append(self.gpa, off) catch {
                self.reportOom("out of memory recording a Stack child offset, child not painted");
            };
        }
        return size;
    }

    pub fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderStack = @fieldParentPtr("base", base);
        // Iterate by offsets length so a short offsets list (OOM during layout)
        // never indexes out of bounds; children beyond it are skipped this frame.
        for (self.offsets.items, 0..) |off, i| {
            try self.children.items[i].paint(cv, offset.add(off));
        }
    }

    pub fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderStack = @fieldParentPtr("base", base);
        // Frees only the lists (pointers), NOT the child render objects: those are
        // owned by the child Elements and freed by their deinit.
        self.children.deinit(gpa);
        self.offsets.deinit(gpa);
        gpa.destroy(self);
    }
};

pub const Stack = struct {
    children: []const Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Stack) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn syncChildren(rs: *RenderStack, el: *Element, gpa: std.mem.Allocator) void {
        rs.children.clearRetainingCapacity();
        rs.children.ensureTotalCapacity(gpa, el.children.items.len) catch {
            rs.reportOom("out of memory reserving the Stack child list");
        };
        for (el.children.items) |ch| {
            if (ch.renderObject()) |ro| rs.children.append(gpa, ro) catch {
                rs.reportOom("out of memory adding a Stack child, child not painted");
            };
        }
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Stack = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const rs = try gpa.create(RenderStack);
        rs.* = .{
            .base = .{ .layoutFn = RenderStack.layoutFn, .paintFn = RenderStack.paintFn, .destroyFn = RenderStack.destroyFn },
            .gpa = gpa,
            .sink = bctx.owner.sink,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(rs);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Stack),
            .render_object = &rs.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        try el.updateChildren(self.children, bctx);
        syncChildren(rs, el, gpa);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Stack = @ptrCast(@alignCast(ptr));
        const rs: *RenderStack = @fieldParentPtr("base", el.render_object.?);
        try el.updateChildren(self.children, bctx);
        syncChildren(rs, el, bctx.owner.gpa);
    }
};

pub const Positioned = struct {
    /// Logical distance from each edge of the stack. Null means the edge does
    /// not pin the child.
    top: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
    left: ?f32 = null,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Positioned) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Positioned = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderPositioned);
        ro.* = .{
            .base = .{
                .layoutFn = RenderPositioned.layoutFn,
                .paintFn = RenderPositioned.paintFn,
                .destroyFn = RenderPositioned.destroyFn,
                .adoptChildFn = RenderPositioned.adopt,
                .type_id = phantom.render_object.typeId(RenderPositioned),
            },
            .top = self.top,
            .right = self.right,
            .bottom = self.bottom,
            .left = self.left,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Positioned),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Positioned = @ptrCast(@alignCast(ptr));
        const ro: *RenderPositioned = @fieldParentPtr("base", el.render_object.?);
        ro.top = self.top;
        ro.right = self.right;
        ro.bottom = self.bottom;
        ro.left = self.left;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "Stack takes the size of its first child" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bg = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var fg = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    const kids = bctx.newSlice(Widget, &.{ bg.widget(), fg.widget() });
    var st = Stack{ .children = kids };

    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    const size = el.renderObject().?.layout(
        layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }),
    );
    try std.testing.expectEqual(@as(f32, 400), size.width);
    try std.testing.expectEqual(@as(f32, 300), size.height);
}

test "Stack paints children in order so the last one is on top" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bg = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var fg = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    const kids = bctx.newSlice(Widget, &.{ bg.widget(), fg.widget() });
    var st = Stack{ .children = kids };

    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 10, .height = 10 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    // Two rrects, blue recorded before red.
    try std.testing.expectEqual(@as(usize, 2), canvas.list.primitives.items.len);
    try std.testing.expectEqual(@as(f32, 1), canvas.list.primitives.items[0].rrect.color.b);
    try std.testing.expectEqual(@as(f32, 1), canvas.list.primitives.items[1].rrect.color.r);
}

test "Positioned offsets its child from the named edges" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bg = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var bar = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var pos = Positioned{ .top = 0, .left = 0, .right = 0, .child = bar.widget() };
    const kids = bctx.newSlice(Widget, &.{ bg.widget(), pos.widget() });
    var st = Stack{ .children = kids };

    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const bar_rect = canvas.list.primitives.items[1].rrect.rect;
    try std.testing.expectEqual(@as(f32, 0), bar_rect.x);
    try std.testing.expectEqual(@as(f32, 0), bar_rect.y);
    try std.testing.expectEqual(@as(f32, 400), bar_rect.width); // left+right stretch
}

test "a 40px dock pinned 10 from the bottom spans y 250 to 290" {
    // The dock in plan C pins to the bottom. A fixed height is what makes this
    // discriminating: a full-height child shifted 10 above the stack also puts
    // its lower edge at 290, so only a real top edge tells the two apart.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bg = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var dock = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var sized = phantom.SizedBox{ .height = 40, .child = dock.widget() };
    var pos = Positioned{ .bottom = 10, .left = 0, .right = 0, .child = sized.widget() };
    const kids = bctx.newSlice(Widget, &.{ bg.widget(), pos.widget() });
    var st = Stack{ .children = kids };

    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 300 }));

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[1].rrect.rect;
    try std.testing.expectEqual(@as(f32, 250), rect.y);
    try std.testing.expectEqual(@as(f32, 40), rect.height);
    try std.testing.expectEqual(@as(f32, 290), rect.y + rect.height);
    try std.testing.expectEqual(@as(f32, 400), rect.width);
}

test "at scale 2 a Positioned inset of 10 places the child 20 physical units in" {
    // Every other test uses scale 1, where `inset * scale` and `inset` agree.
    // Only this one fails if the scale multiply is dropped.
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bg = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var bar = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var sized = phantom.SizedBox{ .width = 30, .height = 20, .child = bar.widget() };
    var pos = Positioned{ .top = 10, .left = 10, .child = sized.widget() };
    const kids = bctx.newSlice(Widget, &.{ bg.widget(), pos.widget() });
    var st = Stack{ .children = kids };

    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    _ = el.renderObject().?.layout(
        layout.BoxConstraints.tightScaled(.{ .width = 400, .height = 300 }, 2.0),
    );

    var canvas = Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rect = canvas.list.primitives.items[1].rrect.rect;
    try std.testing.expectEqual(@as(f32, 20), rect.x);
    try std.testing.expectEqual(@as(f32, 20), rect.y);
    // The SizedBox scales too, so the child is 60x40 physical.
    try std.testing.expectEqual(@as(f32, 60), rect.width);
    try std.testing.expectEqual(@as(f32, 40), rect.height);
}

test "an empty Stack returns the smallest size its constraints allow" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var st = Stack{ .children = &.{} };
    const el = try st.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    // A loose constraint has a zero minimum, so an empty stack takes no room.
    const loose = el.renderObject().?.layout(
        layout.BoxConstraints.loose(.{ .width = 100, .height = 80 }),
    );
    try std.testing.expectEqual(@as(f32, 0), loose.width);
    try std.testing.expectEqual(@as(f32, 0), loose.height);
    // A tight constraint has no smaller option, so the minimum is the only size.
    const tight = el.renderObject().?.layout(
        layout.BoxConstraints.tight(.{ .width = 10, .height = 10 }),
    );
    try std.testing.expectEqual(@as(f32, 10), tight.width);
    try std.testing.expectEqual(@as(f32, 10), tight.height);
    try std.testing.expect(sink.ok());
}

test "a Positioned render object is tagged so the stack can recover it" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var bar = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0) };
    var plain = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var pos = Positioned{ .top = 5, .child = bar.widget() };

    const pos_el = try pos.widget().mount(&bctx, null);
    defer pos_el.deinit(std.testing.allocator);
    const plain_el = try plain.widget().mount(&bctx, null);
    defer plain_el.deinit(std.testing.allocator);

    try std.testing.expect(asPositioned(pos_el.renderObject().?) != null);
    // An untagged render object must never be downcast to RenderPositioned.
    try std.testing.expect(asPositioned(plain_el.renderObject().?) == null);
    try std.testing.expect(plain_el.renderObject().?.type_id == null);
}
