const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const pointer = phantom.pointer;
const testing = @import("../testing.zig");

/// The scroll offset that `content` inside `viewport` allows. Shared with
/// `GridView`, so the two scrolling widgets can never disagree about where the
/// ends of a scroll are.
pub fn clampOffset(
    offset: geom.PhysicalOffset,
    content: geom.PhysicalSize,
    viewport: geom.PhysicalSize,
) geom.PhysicalOffset {
    const max_x = @max(@as(f32, 0), content.width - viewport.width);
    const max_y = @max(@as(f32, 0), content.height - viewport.height);
    return .{
        .x = std.math.clamp(offset.x, 0, max_x),
        .y = std.math.clamp(offset.y, 0, max_y),
    };
}

/// How far one key scrolls, or null when the key does not scroll. One arrow press
/// moves one line, and one page key moves most of a viewport. The overlap of one
/// line keeps a reader's place across a page jump, which is what every document
/// viewer does. Home and End pass the whole content, which the clamp turns into
/// exactly the top or the bottom.
pub fn keyScrollDelta(
    keysym: phantom.input.Keysym,
    viewport_height: f32,
    content_height: f32,
) ?f32 {
    const line: f32 = 16;
    const page = @max(viewport_height - line, line);
    return switch (keysym) {
        .down => line,
        .up => -line,
        .page_down => page,
        .page_up => -page,
        .home => -content_height,
        .end => content_height,
        else => null,
    };
}

const RenderScrollView = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    offset: geom.PhysicalOffset = .zero,
    content: geom.PhysicalSize = geom.PhysicalSize.zero,
    viewport: geom.PhysicalSize = geom.PhysicalSize.zero,
    handlers: pointer.PointerHandlers,
    focus_handlers: phantom.FocusHandlers = undefined,
    axis: ScrollView.Axis = .vertical,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderScrollView = @fieldParentPtr("base", base);
        const vp = c.biggest();
        self.viewport = vp;
        if (self.child) |ch| {
            const child_constraints: layout.BoxConstraints = switch (self.axis) {
                .vertical => .{
                    .min_width = 0,
                    .max_width = vp.width,
                    .min_height = 0,
                    .max_height = std.math.inf(f32),
                    .scale = c.scale,
                },
                .horizontal => .{
                    .min_width = 0,
                    .max_width = std.math.inf(f32),
                    .min_height = 0,
                    .max_height = vp.height,
                    .scale = c.scale,
                },
                .both => .{
                    .min_width = 0,
                    .max_width = std.math.inf(f32),
                    .min_height = 0,
                    .max_height = std.math.inf(f32),
                    .scale = c.scale,
                },
            };
            const child_size = ch.layout(child_constraints);
            self.content = child_size;
        } else {
            self.content = geom.PhysicalSize.zero;
        }
        self.offset = clampOffset(self.offset, self.content, vp);
        return vp;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderScrollView = @fieldParentPtr("base", base);
        try cv.pushScroll(.{
            .viewport = geom.PhysicalRect.fromOriginSize(offset, base.size),
            .offset = self.offset,
            .content = self.content,
        });
        if (self.child) |ch| try ch.paint(cv, offset);
        try cv.popScroll();
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderScrollView = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }

    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderScrollView = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn scrollThunk(ctx: *anyopaque, dx: f32, dy: f32) void {
        const self: *RenderScrollView = @ptrCast(@alignCast(ctx));
        self.offset = clampOffset(
            .{ .x = self.offset.x + dx, .y = self.offset.y + dy },
            self.content,
            self.viewport,
        );
    }

    fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
        const self: *RenderScrollView = @ptrCast(@alignCast(ctx));
        if (ev.action == .release) return false;
        const dy = keyScrollDelta(ev.keysym, self.base.size.height, self.content.height) orelse return false;
        // The wheel handler already adds the delta and clamps against the content and
        // the viewport. Call it rather than repeating the clamp, so one path cannot
        // drift from the other.
        scrollThunk(self, 0, dy);
        return true;
    }

    fn installHandlers(self: *RenderScrollView) void {
        self.handlers = .{ .ctx = self, .on_scroll = scrollThunk };
        self.base.pointer = &self.handlers;
        self.focus_handlers = .{ .ctx = self, .on_key = onKey };
        self.base.focus = &self.focus_handlers;
    }
};

pub const ScrollView = struct {
    child: Widget,
    axis: Axis = .vertical,

    pub const Axis = enum { vertical, horizontal, both };

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const ScrollView) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const ScrollView = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderScrollView);
        ro.* = .{
            .base = .{
                .layoutFn = RenderScrollView.layoutFn,
                .paintFn = RenderScrollView.paintFn,
                .destroyFn = RenderScrollView.destroyFn,
                .adoptChildFn = RenderScrollView.adopt,
            },
            .gpa = gpa,
            .handlers = .{ .ctx = ro },
            .axis = self.axis,
        };
        ro.installHandlers();
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(ScrollView),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const ScrollView = @ptrCast(@alignCast(ptr));
        const ro: *RenderScrollView = @fieldParentPtr("base", el.render_object.?);
        ro.axis = self.axis;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "ScrollView layout: viewport == tight constraints, content == child natural size, size == viewport" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // Text with unbounded constraints reports its natural size (c.constrain clamps to
    // [0, inf] which is just the natural width/height). Font size 200 gives height > 100.
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var tall_text = phantom.Text{ .text = "Tall", .font = &font, .size = 200, .color = phantom.Color.rgb(1, 1, 1) };
    var sv = ScrollView{ .child = tall_text.widget() };
    const el = try sv.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const c = layout.BoxConstraints.tight(.{ .width = 100, .height = 100 });
    const size = el.render_object.?.layout(c);

    const ro: *RenderScrollView = @fieldParentPtr("base", el.render_object.?);

    // Reported size == viewport (100x100)
    try std.testing.expectEqual(@as(f32, 100), size.width);
    try std.testing.expectEqual(@as(f32, 100), size.height);

    // viewport field stored on the RO
    try std.testing.expectEqual(@as(f32, 100), ro.viewport.width);
    try std.testing.expectEqual(@as(f32, 100), ro.viewport.height);

    // content is the child's natural height (Text at size 200 > 100px)
    try std.testing.expect(ro.content.height > 100);
}

test "ScrollView paint: display list starts push_scroll (viewport==bounds, offset==zero) and ends pop_scroll" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // ColoredBox fills the unbounded constraint (returns 0,0 but that is fine for
    // the paint structure test; we only check push_scroll + pop_scroll positions).
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) };
    var sv = ScrollView{ .child = box.widget() };
    const el = try sv.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const paint_offset = geom.PhysicalOffset{ .x = 5, .y = 10 };
    try el.render_object.?.paint(&canvas, paint_offset);

    const prims = canvas.list.primitives.items;
    // Must have at least push_scroll + child (rrect from ColoredBox) + pop_scroll = 3
    try std.testing.expect(prims.len >= 3);

    // First primitive: push_scroll
    const sr = prims[0].push_scroll;
    // viewport rect == ScrollView bounds (offset arg + base.size)
    try std.testing.expectEqual(@as(f32, 5), sr.viewport.x);
    try std.testing.expectEqual(@as(f32, 10), sr.viewport.y);
    try std.testing.expectEqual(@as(f32, 100), sr.viewport.width);
    try std.testing.expectEqual(@as(f32, 100), sr.viewport.height);
    // offset starts at zero
    try std.testing.expectEqual(@as(f32, 0), sr.offset.x);
    try std.testing.expectEqual(@as(f32, 0), sr.offset.y);
    // content == the child's natural size (stored on the RO)
    const ro: *RenderScrollView = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(ro.content.width, sr.content.width);
    try std.testing.expectEqual(ro.content.height, sr.content.height);

    // Last primitive: pop_scroll
    _ = prims[prims.len - 1].pop_scroll;
}

test "ScrollView on_scroll: dy=50 clamps; huge dy clamps to max; negative clamps to 0" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Text at size 200 has natural height > 100 viewport
    var tall_text = phantom.Text{ .text = "Tall", .font = &font, .size = 200, .color = phantom.Color.rgb(1, 1, 1) };
    var sv = ScrollView{ .child = tall_text.widget() };
    const el = try sv.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));
    const ro: *RenderScrollView = @fieldParentPtr("base", el.render_object.?);

    // Content must be taller than viewport for these assertions to be meaningful
    try std.testing.expect(ro.content.height > 100);
    const max_y = ro.content.height - ro.viewport.height;

    // Fire on_scroll with dy=50 (within range) -> offset.y == 50
    const h = ro.base.pointer.?;
    h.on_scroll.?(h.ctx, 0, 50);
    try std.testing.expectEqual(@as(f32, 50), ro.offset.y);

    // Huge dy -> clamps to content.height - viewport.height
    h.on_scroll.?(h.ctx, 0, 999999);
    try std.testing.expectApproxEqAbs(max_y, ro.offset.y, 0.001);

    // Negative -> clamps to 0
    h.on_scroll.?(h.ctx, 0, -999999);
    try std.testing.expectEqual(@as(f32, 0), ro.offset.y);
}

test "ScrollView pointer slot: base.pointer is non-null with on_scroll set" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var sv = ScrollView{ .child = box.widget() };
    const el = try sv.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const ro = el.render_object.?;
    _ = ro.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));

    try std.testing.expect(ro.pointer != null);
    try std.testing.expect(ro.pointer.?.on_scroll != null);
}

// `SizedBox.child` and `ScrollView.child` are both required, so the tall content
// is a SizedBox wrapping a ColoredBox leaf.
fn tallContent(leaf: *const phantom.ColoredBox) phantom.SizedBox {
    return .{ .width = 100, .height = 1000, .child = leaf.widget() };
}

fn scrollOffsetOf(ro: *RenderObject) f32 {
    const self: *RenderScrollView = @fieldParentPtr("base", ro);
    return self.offset.y;
}

test "the down arrow scrolls a focused scroll view" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var sv = ScrollView{ .child = child.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    const ro = h.root.renderObject().?;
    const handlers = ro.focus orelse return error.NoFocusHandlers;
    const before = scrollOffsetOf(ro);
    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .down }));
    try std.testing.expect(scrollOffsetOf(ro) > before);
}

test "page down scrolls further than the down arrow" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var sv = ScrollView{ .child = child.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    const ro = h.root.renderObject().?;
    const handlers = ro.focus orelse return error.NoFocusHandlers;
    _ = handlers.on_key.?(handlers.ctx, .{ .keysym = .down });
    const one_line = scrollOffsetOf(ro);
    _ = handlers.on_key.?(handlers.ctx, .{ .keysym = .page_down });
    const one_page = scrollOffsetOf(ro) - one_line;
    try std.testing.expect(one_page > one_line);
}

test "the scroll offset never goes above the top" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var sv = ScrollView{ .child = child.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    const ro = h.root.renderObject().?;
    const handlers = ro.focus orelse return error.NoFocusHandlers;
    _ = handlers.on_key.?(handlers.ctx, .{ .keysym = .up });
    // `scrollThunk` clamps to zero, so scrolling up at the top is a no-op and
    // never produces a negative offset.
    try std.testing.expectEqual(@as(f32, 0), scrollOffsetOf(ro));
}

test "End jumps to the bottom and clamps there, Home returns to the top" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var sv = ScrollView{ .child = child.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    const ro = h.root.renderObject().?;
    const handlers = ro.focus orelse return error.NoFocusHandlers;
    const self: *RenderScrollView = @fieldParentPtr("base", ro);

    // End passes a delta far larger than the content, so this proves scrollThunk's
    // clamp holds rather than assuming it: the offset lands exactly at the bottom,
    // never past it.
    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .end }));
    const max_y = self.content.height - self.viewport.height;
    try std.testing.expectApproxEqAbs(max_y, scrollOffsetOf(ro), 0.001);

    // Home passes an equally oversized delta upward; the same clamp must hold at
    // exactly zero in the other direction.
    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .home }));
    try std.testing.expectEqual(@as(f32, 0), scrollOffsetOf(ro));
}

test "ScrollView vertical axis: Column child lays out to natural stacked height, not 0" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t1 = phantom.Text{ .text = "Line 1", .font = &font, .size = 20, .color = phantom.Color.rgb(1, 1, 1) };
    var t2 = phantom.Text{ .text = "Line 2", .font = &font, .size = 20, .color = phantom.Color.rgb(1, 1, 1) };
    var t3 = phantom.Text{ .text = "Line 3", .font = &font, .size = 20, .color = phantom.Color.rgb(1, 1, 1) };
    var t4 = phantom.Text{ .text = "Line 4", .font = &font, .size = 20, .color = phantom.Color.rgb(1, 1, 1) };
    var t5 = phantom.Text{ .text = "Line 5", .font = &font, .size = 20, .color = phantom.Color.rgb(1, 1, 1) };
    const children = [_]phantom.Widget{
        t1.widget(), t2.widget(), t3.widget(), t4.widget(), t5.widget(),
    };
    var col = phantom.Column(.{ .children = &children });
    var sv = ScrollView{ .child = col.widget() };
    const el = try sv.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const viewport_height: f32 = 30;
    _ = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = viewport_height }));
    const ro: *RenderScrollView = @fieldParentPtr("base", el.render_object.?);

    // The Column stacks 5 text rows; total height must exceed the 30px viewport.
    try std.testing.expect(ro.content.height > viewport_height);
}
