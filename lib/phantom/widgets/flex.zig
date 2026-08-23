const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;

pub const Axis = enum { vertical, horizontal };
pub const MainAxisAlignment = enum { start, center, end };
pub const CrossAxisAlignment = enum { start, center, end };

fn mainExtent(axis: Axis, s: geom.PhysicalSize) f32 {
    return switch (axis) {
        .vertical => s.height,
        .horizontal => s.width,
    };
}
fn crossExtent(axis: Axis, s: geom.PhysicalSize) f32 {
    return switch (axis) {
        .vertical => s.width,
        .horizontal => s.height,
    };
}
fn offsetFor(axis: Axis, main_pos: f32, cross_pos: f32) geom.PhysicalOffset {
    return switch (axis) {
        .vertical => .{ .x = cross_pos, .y = main_pos },
        .horizontal => .{ .x = main_pos, .y = cross_pos },
    };
}

pub const RenderFlex = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    direction: Axis,
    main: MainAxisAlignment,
    cross: CrossAxisAlignment,
    /// Where an allocation failure during layout is reported. A dropped child is
    /// invisible on screen, so it must never fail silently. Null only for a
    /// stack-owned RenderFlex that no widget mounted.
    sink: ?*phantom.FaultSink = null,
    children: std.ArrayList(*RenderObject) = .empty,
    offsets: std.ArrayList(geom.PhysicalOffset) = .empty,

    /// Report an allocation failure that costs the flex a child this frame.
    fn reportOom(self: *RenderFlex, msg: []const u8) void {
        if (self.sink) |s| s.report(.oom, msg);
    }

    pub fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        const size = c.biggest();
        // When the main axis is unbounded, pass the full unbounded constraint to
        // children so each can report its natural size, then sum for the return value.
        const main_unbounded = switch (self.direction) {
            .vertical => std.math.isInf(c.max_height),
            .horizontal => std.math.isInf(c.max_width),
        };
        // Cross-axis extent: use bounded value from biggest() as usual.
        const cross_ext_for_children = crossExtent(self.direction, size);
        const child_c: layout.BoxConstraints = if (main_unbounded) switch (self.direction) {
            .vertical => .{
                .min_width = 0,
                .max_width = cross_ext_for_children,
                .min_height = 0,
                .max_height = std.math.inf(f32),
                .scale = c.scale,
            },
            .horizontal => .{
                .min_width = 0,
                .max_width = std.math.inf(f32),
                .min_height = 0,
                .max_height = cross_ext_for_children,
                .scale = c.scale,
            },
        } else layout.BoxConstraints{ .max_width = size.width, .max_height = size.height, .scale = c.scale };
        self.offsets.clearRetainingCapacity();
        self.offsets.ensureTotalCapacity(self.gpa, self.children.items.len) catch {
            self.reportOom("out of memory reserving Flex child offsets");
        };
        var total_main: f32 = 0;
        var total_cross: f32 = 0;
        for (self.children.items) |ch| {
            const cs = ch.layout(child_c);
            total_main += mainExtent(self.direction, cs);
            if (crossExtent(self.direction, cs) > total_cross) total_cross = crossExtent(self.direction, cs);
        }
        // When main axis is unbounded, the flex shrinks to fit its children; otherwise
        // it fills the available space as before.
        const main_ext = if (main_unbounded) total_main else mainExtent(self.direction, size);
        const cross_ext = if (main_unbounded) total_cross else crossExtent(self.direction, size);
        var main_pos: f32 = switch (self.main) {
            .start => 0,
            .center => (main_ext - total_main) / 2.0,
            .end => main_ext - total_main,
        };
        for (self.children.items) |ch| {
            const cm = mainExtent(self.direction, ch.size);
            const cc = crossExtent(self.direction, ch.size);
            const cross_pos: f32 = switch (self.cross) {
                .start => 0,
                .center => (cross_ext - cc) / 2.0,
                .end => cross_ext - cc,
            };
            // Capacity was reserved above; if that OOMed, append safely (a short
            // offsets list is tolerated by paintFn, which iterates by offsets len).
            self.offsets.append(self.gpa, offsetFor(self.direction, main_pos, cross_pos)) catch {
                self.reportOom("out of memory recording a Flex child offset, child not painted");
            };
            main_pos += cm;
        }
        return if (main_unbounded) switch (self.direction) {
            .vertical => .{ .width = size.width, .height = total_main },
            .horizontal => .{ .width = total_main, .height = size.height },
        } else size;
    }

    pub fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        // Iterate by offsets length so a short offsets list (OOM during layout)
        // never indexes out of bounds; children beyond it are skipped this frame.
        for (self.offsets.items, 0..) |off, i| {
            try self.children.items[i].paint(cv, offset.add(off));
        }
    }

    pub fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        // Frees only the lists (pointers), NOT the child render objects: those are
        // owned by the child Elements and freed by their deinit.
        self.children.deinit(gpa);
        self.offsets.deinit(gpa);
        gpa.destroy(self);
    }
};

const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;

pub const Flex = struct {
    direction: Axis = .vertical,
    main: MainAxisAlignment = .start,
    cross: CrossAxisAlignment = .start,
    children: []const Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Flex) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn syncChildren(rf: *RenderFlex, el: *Element, gpa: std.mem.Allocator) void {
        rf.children.clearRetainingCapacity();
        rf.children.ensureTotalCapacity(gpa, el.children.items.len) catch {
            rf.reportOom("out of memory reserving the Flex child list");
        };
        for (el.children.items) |ch| {
            if (ch.renderObject()) |ro| rf.children.append(gpa, ro) catch {
                rf.reportOom("out of memory adding a Flex child, child not painted");
            };
        }
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const rf = try gpa.create(RenderFlex);
        rf.* = .{
            .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn },
            .gpa = gpa,
            .direction = self.direction,
            .main = self.main,
            .cross = self.cross,
            .sink = bctx.owner.sink,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(rf);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Flex),
            .render_object = &rf.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        try el.updateChildren(self.children, bctx);
        syncChildren(rf, el, gpa);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
        rf.direction = self.direction;
        rf.main = self.main;
        rf.cross = self.cross;
        try el.updateChildren(self.children, bctx);
        syncChildren(rf, el, bctx.owner.gpa);
    }
};

pub fn Column(opts: struct { main: MainAxisAlignment = .start, cross: CrossAxisAlignment = .start, children: []const Widget }) Flex {
    return .{ .direction = .vertical, .main = opts.main, .cross = opts.cross, .children = opts.children };
}
pub fn Row(opts: struct { main: MainAxisAlignment = .start, cross: CrossAxisAlignment = .start, children: []const Widget }) Flex {
    return .{ .direction = .horizontal, .main = opts.main, .cross = opts.cross, .children = opts.children };
}

// Test-only render object: reports a fixed physical size (ignores constraints)
// and records the scale it was laid out with.
const FixedBox = struct {
    base: RenderObject,
    w: f32,
    h: f32,
    seen_scale: f32 = 0,
    fn lf(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *FixedBox = @fieldParentPtr("base", base);
        self.seen_scale = c.scale;
        return .{ .width = self.w, .height = self.h };
    }
    fn pf(_: *RenderObject, _: *Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn make(w: f32, h: f32) FixedBox {
        return .{ .base = .{ .layoutFn = lf, .paintFn = pf }, .w = w, .h = h };
    }
};

test "RenderFlex vertical start stacks children; center leads by half slack; scale flows" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(20, 50);
    var rf = RenderFlex{ .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn }, .gpa = gpa, .direction = .vertical, .main = .start, .cross = .start };
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    // vertical start at scale 2: children stack from y=0, scale flows to children
    _ = rf.base.layout(layout.BoxConstraints.tightScaled(.{ .width = 200, .height = 200 }, 2.0));
    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].y);
    try std.testing.expectEqual(@as(f32, 30), rf.offsets.items[1].y); // after child a's height
    try std.testing.expectEqual(@as(f32, 2.0), a.seen_scale); // scale preserved into child constraints
    // switch to center on both axes
    rf.main = .center;
    rf.cross = .center;
    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 200 }));
    // total main = 30+50 = 80; leading = (200-80)/2 = 60
    try std.testing.expectEqual(@as(f32, 60), rf.offsets.items[0].y);
    try std.testing.expectEqual(@as(f32, 90), rf.offsets.items[1].y);
    // cross center: (200-20)/2 = 90
    try std.testing.expectEqual(@as(f32, 90), rf.offsets.items[0].x);
}

test "RenderFlex horizontal (Row) stacks on x" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(40, 30);
    var rf = RenderFlex{ .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn }, .gpa = gpa, .direction = .horizontal, .main = .start, .cross = .start };
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].x);
    try std.testing.expectEqual(@as(f32, 20), rf.offsets.items[1].x); // after child a's width
}

test "Flex widget mounts children, syncs render objects, stacks two Texts vertically" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t0 = phantom.Text{ .text = "A", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var t1 = phantom.Text{ .text = "B", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    const kids = [_]phantom.Widget{ t0.widget(), t1.widget() };
    var col = Flex{ .direction = .vertical, .main = .start, .cross = .start, .children = &kids };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), el.children.items.len);
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(usize, 2), rf.children.items.len);

    _ = el.render_object.?.layout(phantom.BoxConstraints.tight(.{ .width = 200, .height = 200 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, phantom.PhysicalOffset.zero);
    // two text runs, second below the first (start-aligned vertical stack)
    const items = canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].text.origin.y < items[1].text.origin.y);
}

test "a Flex layout that cannot allocate its offsets reports oom and paints no child" {
    // A dropped child leaves nothing on screen. The old code swallowed the
    // allocation failure with an empty catch, so the frame lost a child and no
    // fault named the reason.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(20, 50);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var rf = RenderFlex{
        .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn },
        .gpa = failing.allocator(),
        .direction = .vertical,
        .main = .start,
        .cross = .start,
        .sink = &sink,
    };
    // The child list is filled through the working allocator, so only the offset
    // allocations inside layoutFn meet the failing one.
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 200 }));

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.oom, sink.first.?.code);
    // No offset was recorded, so paintFn walks nothing rather than indexing past
    // the short list.
    try std.testing.expectEqual(@as(usize, 0), rf.offsets.items.len);
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try rf.base.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(@as(usize, 0), canvas.list.primitives.items.len);
}

test "a Flex whose child list cannot grow reports oom and keeps the children it has" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    const two = [_]phantom.Widget{ box.widget(), box.widget() };
    var col = Flex{ .children = &two };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expect(sink.ok()); // a normal mount records nothing

    // Re-sync the render object's child list through an allocator that refuses,
    // which is the path a low memory frame takes.
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    // Release the capacity the mount reserved, or the refusing allocator is never
    // asked for anything and the test proves nothing.
    rf.children.clearAndFree(gpa);
    Flex.syncChildren(rf, el, failing.allocator());

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.oom, sink.first.?.code);
    try std.testing.expectEqual(@as(usize, 0), rf.children.items.len);
}

test "Flex widget update reconciles child count (grow then shrink), leak-clean" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    const two = [_]phantom.Widget{ box.widget(), box.widget() };
    var col = Flex{ .children = &two };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), el.children.items.len);
    const three = [_]phantom.Widget{ box.widget(), box.widget(), box.widget() };
    var col3 = Flex{ .children = &three };
    try col3.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 3), el.children.items.len);
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(usize, 3), rf.children.items.len);
    const one = [_]phantom.Widget{box.widget()};
    var col1 = Flex{ .children = &one };
    try col1.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 1), el.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), rf.children.items.len);
}
