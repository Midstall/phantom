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

/// The least offset that shows all of `rect`. Both are in content coordinates, so
/// the caller has already taken the viewport's own position out. A rect larger than
/// the viewport lines up with its start edge, because the start of an item is what a
/// reader needs first.
pub fn offsetToShow(
    offset: geom.PhysicalOffset,
    rect: geom.PhysicalRect,
    viewport: geom.PhysicalSize,
) geom.PhysicalOffset {
    return .{
        .x = axisOffsetToShow(offset.x, rect.x, rect.width, viewport.width),
        .y = axisOffsetToShow(offset.y, rect.y, rect.height, viewport.height),
    };
}

fn axisOffsetToShow(offset: f32, start: f32, extent: f32, viewport: f32) f32 {
    if (start < offset) return start;
    // Showing the end of a rect this long would push its start out of sight, and a
    // reader needs the start first.
    if (extent > viewport) return start;
    const end = start + extent;
    if (end > offset + viewport) return end - viewport;
    // Already in view, so the reader's place is kept.
    return offset;
}

/// The parts of a scrolling render object a `ScrollController` drives, without
/// naming which widget owns them.
///
/// `ScrollView` and `GridView` scroll identically: both clamp `offset + delta`
/// against the same content and viewport, through the same `clampOffset`.
/// Pointing the controller at the fields rather than at one render object type
/// is what lets one controller serve both, instead of `GridView` growing a
/// second copy of the same methods.
///
/// The pointers reach into the render object, so a handle is valid only while
/// that object is mounted. `detach` is what keeps that true.
pub const Scrollable = struct {
    node: *RenderObject,
    offset: *geom.PhysicalOffset,
    content: *const geom.PhysicalSize,
    viewport: *const geom.PhysicalSize,
};

/// The handle an application holds to reach a mounted scrolling widget. The scroll
/// offset lives on the render object, which the widget tree owns and rebuilds, so a
/// controller is the only stable thing a caller can keep across frames. It does not
/// own the view: the view attaches itself while it is mounted and detaches before it
/// is freed, which is why every method reports whether it reached anything.
///
/// One controller drives one view. Giving the same controller to two mounted
/// scrolling widgets leaves it pointing at whichever mounted last.
pub const ScrollController = struct {
    view: ?Scrollable = null,

    /// True while a mounted `ScrollView` uses this controller.
    pub fn attached(self: *const ScrollController) bool {
        return self.view != null;
    }

    /// Where the content is scrolled to, or null while detached.
    pub fn offset(self: *const ScrollController) ?geom.PhysicalOffset {
        const v = self.view orelse return null;
        return v.offset.*;
    }

    /// The furthest the content can scroll, or null while detached. Zero on both
    /// axes until the first layout, because nothing is known about the content yet.
    pub fn maxOffset(self: *const ScrollController) ?geom.PhysicalOffset {
        const v = self.view orelse return null;
        return .{
            .x = @max(@as(f32, 0), v.content.width - v.viewport.width),
            .y = @max(@as(f32, 0), v.content.height - v.viewport.height),
        };
    }

    /// Scroll to an absolute offset, clamped to what the content allows. Returns
    /// false while detached.
    pub fn jumpTo(self: *ScrollController, to: geom.PhysicalOffset) bool {
        const v = self.view orelse return false;
        v.offset.* = clampOffset(to, v.content.*, v.viewport.*);
        return true;
    }

    /// Add to the offset, clamped the same way a wheel event is. Returns false while
    /// detached.
    pub fn scrollBy(self: *ScrollController, dx: f32, dy: f32) bool {
        const v = self.view orelse return false;
        // The same clamp both scrolling render objects apply to a wheel event.
        v.offset.* = clampOffset(
            .{ .x = v.offset.x + dx, .y = v.offset.y + dy },
            v.content.*,
            v.viewport.*,
        );
        return true;
    }

    /// Scroll the least amount that puts `rect` in view. The rect is in content
    /// coordinates, where the top left of the content is the origin. Returns false
    /// while detached.
    pub fn scrollIntoView(self: *ScrollController, rect: geom.PhysicalRect) bool {
        const v = self.view orelse return false;
        v.offset.* = clampOffset(offsetToShow(v.offset.*, rect, v.viewport.*), v.content.*, v.viewport.*);
        return true;
    }

    /// Scroll the least amount that puts one render object of the content in view.
    /// Returns false while detached, or when the view and the child have not both
    /// been painted yet: a render object learns where it sits from the paint pass,
    /// so there is nothing to aim at before the first frame.
    ///
    /// `child` must be inside this view. A render object from elsewhere in the tree
    /// gives a meaningless rectangle rather than an error, because the render tree
    /// holds no upward link to check it against.
    pub fn showChild(self: *ScrollController, child: *RenderObject) bool {
        const v = self.view orelse return false;
        // The child is painted at the view's own paint origin plus its position in
        // the content. The scroll offset is applied by the backend from the pushed
        // scroll region, not by the paint offset, so the difference of the two
        // origins is the content coordinate with no offset to undo.
        return self.scrollIntoView(.{
            .x = child.origin.x - v.node.origin.x,
            .y = child.origin.y - v.node.origin.y,
            .width = child.size.width,
            .height = child.size.height,
        });
    }
};

const RenderScrollView = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    offset: geom.PhysicalOffset = .zero,
    content: geom.PhysicalSize = geom.PhysicalSize.zero,
    viewport: geom.PhysicalSize = geom.PhysicalSize.zero,
    handlers: pointer.PointerHandlers,
    focus_handlers: phantom.FocusHandlers = undefined,
    /// The copy of the config's id that `focus_handlers.id` points at.
    id: phantom.focus.OwnedId = .{},
    /// The controller this view is attached to, kept so `destroyFn` can detach.
    controller: ?*ScrollController = null,
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
        self.detach();
        self.id.deinit(gpa);
        gpa.destroy(self);
    }

    /// Point the controller at this view. A controller that already drives another
    /// view is taken over, because the widget that named it here is the live one.
    fn attach(self: *RenderScrollView, controller: ?*ScrollController) void {
        if (self.controller == controller) return;
        self.detach();
        self.controller = controller;
        if (controller) |c| c.view = .{
            .node = &self.base,
            .offset = &self.offset,
            .content = &self.content,
            .viewport = &self.viewport,
        };
    }

    /// Clear the controller, but only while it still points here. A rebuild that
    /// moved the controller to another view must not have its new target erased by
    /// this view being freed afterwards.
    fn detach(self: *RenderScrollView) void {
        const c = self.controller orelse return;
        if (c.view) |v| {
            if (v.node == &self.base) c.view = null;
        }
        self.controller = null;
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
        self.focus_handlers = .{
            .ctx = self,
            .on_key = onKey,
            .id = self.id.text,
            .node = &self.base,
        };
        self.base.focus = &self.focus_handlers;
    }
};

pub const ScrollView = struct {
    child: Widget,
    axis: Axis = .vertical,
    /// The handle an application scrolls this view through. The view attaches itself
    /// to it on mount and detaches on unmount, so the caller only has to keep the
    /// controller alive for as long as the widget is mounted.
    controller: ?*ScrollController = null,
    /// The name `FocusManager.focusById` moves the keyboard focus here by. A view
    /// with no focusable children needs this to be reached by the arrow keys. The
    /// text is copied on mount, so a caller may build it in the frame arena.
    id: ?[]const u8 = null,

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
        ro.id.set(gpa, self.id) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        ro.installHandlers();
        ro.attach(self.controller);
        const el = gpa.create(Element) catch |e| {
            ro.detach();
            ro.id.deinit(gpa);
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
        try ro.id.set(ro.gpa, self.id);
        ro.installHandlers();
        ro.attach(self.controller);
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

test "offsetToShow leaves the offset alone when the rect is already in view" {
    const vp = geom.PhysicalSize{ .width = 100, .height = 100 };
    const got = offsetToShow(.{ .x = 0, .y = 500 }, .{ .x = 0, .y = 520, .width = 100, .height = 40 }, vp);
    try std.testing.expectEqual(@as(f32, 500), got.y);
}

test "offsetToShow moves down by the least amount that shows the end of the rect" {
    const vp = geom.PhysicalSize{ .width = 100, .height = 100 };
    // The rect runs 500..600 and the view shows 0..100, so the bottom edge decides.
    const got = offsetToShow(.zero, .{ .x = 0, .y = 500, .width = 100, .height = 100 }, vp);
    try std.testing.expectEqual(@as(f32, 500), got.y);
}

test "offsetToShow moves up to the start of a rect above the view" {
    const vp = geom.PhysicalSize{ .width = 100, .height = 100 };
    const got = offsetToShow(.{ .x = 0, .y = 500 }, .{ .x = 0, .y = 220, .width = 100, .height = 40 }, vp);
    try std.testing.expectEqual(@as(f32, 220), got.y);
}

test "offsetToShow lines a rect taller than the viewport up with its start" {
    const vp = geom.PhysicalSize{ .width = 100, .height = 100 };
    // Neither edge fits, so showing the end would hide the start. The start wins.
    const got = offsetToShow(.zero, .{ .x = 0, .y = 200, .width = 100, .height = 400 }, vp);
    try std.testing.expectEqual(@as(f32, 200), got.y);
}

test "offsetToShow scrolls each axis on its own" {
    const vp = geom.PhysicalSize{ .width = 100, .height = 100 };
    // The rect is right of the view and already inside it vertically.
    const got = offsetToShow(.{ .x = 0, .y = 50 }, .{ .x = 300, .y = 60, .width = 20, .height = 20 }, vp);
    try std.testing.expectEqual(@as(f32, 220), got.x);
    try std.testing.expectEqual(@as(f32, 50), got.y);
}

// ---------------------------------------------------------------------------
// Reaching a mounted view through a ScrollController
// ---------------------------------------------------------------------------

/// Ten stacked rows of 100 physical units each, so the content is 1000 tall inside
/// a 100 tall viewport and every row has a known content coordinate.
const RowList = struct {
    leaf: phantom.ColoredBox = .{ .color = geom.Color.rgb(0, 1, 0) },
    rows: [10]phantom.SizedBox = undefined,
    widgets: [10]phantom.Widget = undefined,

    fn column(self: *RowList) phantom.Flex {
        for (&self.rows, 0..) |*row, i| {
            row.* = .{ .width = 100, .height = 100, .child = self.leaf.widget() };
            self.widgets[i] = row.widget();
        }
        return phantom.Column(.{ .main = .start, .cross = .start, .children = &self.widgets });
    }
};

fn pushScrollOffset(prims: []const phantom.Primitive) ?geom.PhysicalOffset {
    for (prims) |p| {
        switch (p) {
            .push_scroll => |sr| return sr.offset,
            else => {},
        }
    }
    return null;
}

test "a ScrollController moves the offset of the view it is attached to, and the paint follows" {
    const gpa = std.testing.allocator;
    var list = RowList{};
    var col = list.column();
    var ctl = ScrollController{};
    var sv = ScrollView{ .controller = &ctl, .child = col.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 100 };
    try h.pump();

    try std.testing.expect(ctl.attached());
    try std.testing.expectEqual(@as(f32, 0), ctl.offset().?.y);

    try std.testing.expect(ctl.scrollBy(0, 250));
    try std.testing.expectEqual(@as(f32, 250), ctl.offset().?.y);
    try std.testing.expect(ctl.jumpTo(.{ .x = 0, .y = 40 }));
    try std.testing.expectEqual(@as(f32, 40), ctl.offset().?.y);

    // The offset is only worth anything if the next frame draws at it.
    try h.pump();
    try std.testing.expectEqual(@as(f32, 40), pushScrollOffset(h.canvas.list.primitives.items).?.y);
}

test "a ScrollController reports the last offset the content allows and clamps to it" {
    const gpa = std.testing.allocator;
    var list = RowList{};
    var col = list.column();
    var ctl = ScrollController{};
    var sv = ScrollView{ .controller = &ctl, .child = col.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 100 };
    try h.pump();

    // Ten rows of 100 in a viewport of 100 leaves 900 to scroll through.
    try std.testing.expectEqual(@as(f32, 900), ctl.maxOffset().?.y);
    try std.testing.expect(ctl.jumpTo(.{ .x = 0, .y = 99999 }));
    try std.testing.expectEqual(@as(f32, 900), ctl.offset().?.y);
    try std.testing.expect(ctl.scrollBy(0, -99999));
    try std.testing.expectEqual(@as(f32, 0), ctl.offset().?.y);
}

test "a ScrollController that no view uses reports nothing and refuses every move" {
    var ctl = ScrollController{};
    try std.testing.expect(!ctl.attached());
    try std.testing.expect(ctl.offset() == null);
    try std.testing.expect(ctl.maxOffset() == null);
    // An application that built its controller before the first build must be told
    // the call did nothing, rather than believing it scrolled.
    try std.testing.expect(!ctl.jumpTo(.{ .x = 0, .y = 10 }));
    try std.testing.expect(!ctl.scrollBy(0, 10));
    try std.testing.expect(!ctl.scrollIntoView(.{ .x = 0, .y = 0, .width = 10, .height = 10 }));
}

test "unmounting a ScrollView detaches its controller" {
    const gpa = std.testing.allocator;
    var list = RowList{};
    var col = list.column();
    var ctl = ScrollController{};
    var sv = ScrollView{ .controller = &ctl, .child = col.widget() };
    var h = try testing.mount(gpa, sv.widget());
    h.viewport = .{ .width = 100, .height = 100 };
    try h.pump();
    try std.testing.expect(ctl.scrollBy(0, 100));

    h.deinit();
    // The render object is freed now, so a controller that still pointed at it
    // would write through a dangling pointer on the next scroll.
    try std.testing.expect(!ctl.attached());
    try std.testing.expect(!ctl.scrollBy(0, 100));
}

test "scrollIntoView brings a row below the viewport just inside the bottom edge" {
    const gpa = std.testing.allocator;
    var list = RowList{};
    var col = list.column();
    var ctl = ScrollController{};
    var sv = ScrollView{ .controller = &ctl, .child = col.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 100 };
    try h.pump();

    // Row 5 covers content y 500..600.
    try std.testing.expect(ctl.scrollIntoView(.{ .x = 0, .y = 500, .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 500), ctl.offset().?.y);
    // Asking again for a row that is now in view must not move anything.
    try std.testing.expect(ctl.scrollIntoView(.{ .x = 0, .y = 500, .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 500), ctl.offset().?.y);
    // Row 0 is above the view, so it comes back to the top.
    try std.testing.expect(ctl.scrollIntoView(.{ .x = 0, .y = 0, .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 0), ctl.offset().?.y);
}

test "showChild scrolls a child render object into view and lands on the same offset twice" {
    const gpa = std.testing.allocator;
    var list = RowList{};
    var col = list.column();
    var ctl = ScrollController{};
    var sv = ScrollView{ .controller = &ctl, .child = col.widget() };
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 100 };
    try h.pump();

    const column_el = h.root.child orelse return error.NoColumnElement;
    const row7 = column_el.children.items[7].renderObject() orelse return error.NoRowRenderObject;

    try std.testing.expect(ctl.showChild(row7));
    // Row 7 covers content y 700..800, so its bottom edge decides the offset.
    try std.testing.expectEqual(@as(f32, 700), ctl.offset().?.y);

    // A second frame repaints at the new offset. The child's recorded origin must
    // still be a content coordinate, or the view would creep further on each call.
    try h.pump();
    try std.testing.expect(ctl.showChild(row7));
    try std.testing.expectEqual(@as(f32, 700), ctl.offset().?.y);
}

// ---------------------------------------------------------------------------
// Reaching a mounted view through the keyboard
// ---------------------------------------------------------------------------

test "a ScrollView with an id takes the focus by name and then scrolls on the arrow keys" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var sv = ScrollView{ .id = "log", .child = child.widget() };
    // The manager is torn down after the tree, because unmounting the tree calls
    // back into it to forget each freed focus node.
    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    h.owner.focus = &mgr;
    try mgr.collect(gpa, h.root);

    try std.testing.expect(mgr.focusById("log"));
    try std.testing.expect(mgr.dispatch(.{ .keysym = .down }));
    try std.testing.expect(scrollOffsetOf(h.root.renderObject().?) > 0);
}

test "a rebuilt ScrollView answers to its new id and no longer to the old one" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    var before = ScrollView{ .id = "old", .child = child.widget() };
    var h = try testing.mount(gpa, before.widget());
    defer h.deinit();
    try h.pump();
    h.owner.focus = &mgr;
    try mgr.collect(gpa, h.root);
    try std.testing.expect(mgr.focusById("old"));

    var bctx = phantom.BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    var after = ScrollView{ .id = "new", .child = child.widget() };
    try after.widget().update(h.root, &bctx);
    try mgr.collect(gpa, h.root);

    try std.testing.expect(mgr.focusById("new"));
    try std.testing.expect(!mgr.focusById("old"));
}

test "a rebuilt ScrollView moves its controller to the widget that names it" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    var ctl = ScrollController{};
    var before = ScrollView{ .child = child.widget() };
    var h = try testing.mount(gpa, before.widget());
    defer h.deinit();
    try h.pump();
    // A view built with no controller must not be reachable through one.
    try std.testing.expect(!ctl.attached());

    var bctx = phantom.BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    var after = ScrollView{ .controller = &ctl, .child = child.widget() };
    try after.widget().update(h.root, &bctx);
    try h.pump();

    // A rebuild that adds a controller has to attach it, or an application that
    // wires one up after the first frame never reaches the view.
    try std.testing.expect(ctl.attached());
    try std.testing.expect(ctl.scrollBy(0, 40));
    try std.testing.expectEqual(@as(f32, 40), ctl.offset().?.y);
}

test "a key the focused child refuses scrolls the ScrollView that encloses it" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0) };
    var child = tallContent(&leaf);
    // The row takes the focus and handles no keys of its own, which is the shape of
    // a selectable list item.
    var row = phantom.Focus{ .id = "row", .child = child.widget() };
    var sv = ScrollView{ .child = row.widget() };
    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    try h.pump();

    h.owner.focus = &mgr;
    try mgr.collect(gpa, h.root);

    try std.testing.expect(mgr.focusById("row"));
    try std.testing.expect(mgr.dispatch(.{ .keysym = .page_down }));
    try std.testing.expect(scrollOffsetOf(h.root.renderObject().?) > 0);
    // The key scrolled the view, and the row kept the focus.
    try std.testing.expectEqualStrings("row", mgr.focusedId().?);
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
