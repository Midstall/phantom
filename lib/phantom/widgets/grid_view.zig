//! A scrolling grid of equally sized children. This is the launcher grid: a fixed
//! number of columns, every tile the same size, and as many rows as the item count
//! needs.
//!
//! What it borrows rather than reinvents:
//!   * `flex.zig` for the multi-child handling: the children element slot, the
//!     `updateChildren` reconcile, the render object child list and the offsets
//!     list that paint walks.
//!   * `scroll_view.zig` for the scrolling: the same offset clamp and the same
//!     key distances, called rather than copied, so the two scrollers cannot
//!     drift apart.
//!
//! Like `ScrollView`, every child is laid out AND painted, and the scroll region
//! in the display list is what cuts the rows below the viewport. The backends
//! already clip that region, so a grid needs no separate rule.
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
const scroll_view = @import("scroll_view.zig");
const testing = @import("../testing.zig");

/// The size of one tile and the step from one tile to the next, in physical
/// units. The step includes the gap, so a caller adds nothing of its own.
const Metrics = struct {
    item_width: f32,
    item_height: f32,
    step_x: f32,
    step_y: f32,
    columns: u32,
};

/// The tile geometry for a grid `columns` wide inside `width`. `columns` and
/// `aspect_ratio` come from a caller and are not trusted: a zero column count or
/// a negative ratio is a runtime fault in the configuration, recovered here
/// rather than reaching a division.
fn metricsFor(width: f32, columns: u32, spacing: f32, aspect_ratio: f32) Metrics {
    const cols = @max(@as(u32, 1), columns);
    const gaps: f32 = @floatFromInt(cols - 1);
    const cols_f: f32 = @floatFromInt(cols);
    const item_width = @max(@as(f32, 0), (width - spacing * gaps) / cols_f);
    const ratio = if (aspect_ratio > 0) aspect_ratio else 1;
    const item_height = item_width / ratio;
    return .{
        .item_width = item_width,
        .item_height = item_height,
        .step_x = item_width + spacing,
        .step_y = item_height + spacing,
        .columns = cols,
    };
}

/// The number of rows `count` items need in `columns` columns.
fn rowsFor(count: usize, columns: u32) usize {
    if (count == 0) return 0;
    return (count + columns - 1) / columns;
}

const RenderGridView = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    /// Where an allocation failure during layout is reported. A dropped child is
    /// invisible on screen, so it must never fail silently.
    sink: ?*phantom.FaultSink = null,
    columns: u32,
    /// Logical gap between tiles on both axes. layoutFn scales it.
    spacing: f32,
    aspect_ratio: f32,
    children: std.ArrayList(*RenderObject) = .empty,
    offsets: std.ArrayList(geom.PhysicalOffset) = .empty,
    offset: geom.PhysicalOffset = .zero,
    content: geom.PhysicalSize = geom.PhysicalSize.zero,
    viewport: geom.PhysicalSize = geom.PhysicalSize.zero,
    handlers: pointer.PointerHandlers,
    focus_handlers: phantom.FocusHandlers = undefined,
    /// The copy of the config id that `focus_handlers.id` points at. Owned,
    /// because the config it comes from lives in the per-frame build arena.
    id: phantom.focus.OwnedId = .{},
    /// The controller this grid is attached to, kept so `destroyFn` can detach.
    controller: ?*scroll_view.ScrollController = null,

    fn reportOom(self: *RenderGridView, msg: []const u8) void {
        if (self.sink) |s| s.report(.oom, msg);
    }

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderGridView = @fieldParentPtr("base", base);
        const vp = c.biggest();
        self.viewport = vp;
        self.offsets.clearRetainingCapacity();

        const count = self.children.items.len;
        if (count == 0) {
            // An empty grid takes no content, so there is nothing to scroll and
            // nothing to paint. The box itself still fills what it was offered.
            self.content = geom.PhysicalSize.zero;
            self.offset = scroll_view.clampOffset(self.offset, self.content, vp);
            return vp;
        }

        const m = metricsFor(vp.width, self.columns, self.spacing * c.scale, self.aspect_ratio);
        self.offsets.ensureTotalCapacity(self.gpa, count) catch {
            self.reportOom("out of memory reserving GridView tile offsets");
        };
        // Every tile is the same size, so each child gets the same tight box.
        const child_c = layout.BoxConstraints{
            .min_width = m.item_width,
            .max_width = m.item_width,
            .min_height = m.item_height,
            .max_height = m.item_height,
            .scale = c.scale,
        };
        for (self.children.items, 0..) |ch, i| {
            _ = ch.layout(child_c);
            const col: f32 = @floatFromInt(i % m.columns);
            const row: f32 = @floatFromInt(i / m.columns);
            // Capacity was reserved above; if that OOMed, append safely (a short
            // offsets list is tolerated by paintFn, which iterates by offsets len).
            self.offsets.append(self.gpa, .{ .x = col * m.step_x, .y = row * m.step_y }) catch {
                self.reportOom("out of memory recording a GridView tile offset, tile not painted");
            };
        }

        const rows = rowsFor(count, m.columns);
        const rows_f: f32 = @floatFromInt(rows);
        // The gap sits BETWEEN rows, so the last row contributes no gap. Counting
        // one gap per row would leave a strip of empty scroll at the bottom.
        self.content = .{
            .width = vp.width,
            .height = rows_f * m.step_y - (m.step_y - m.item_height),
        };
        self.offset = scroll_view.clampOffset(self.offset, self.content, vp);
        return vp;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderGridView = @fieldParentPtr("base", base);
        try cv.pushScroll(.{
            .viewport = geom.PhysicalRect.fromOriginSize(offset, base.size),
            .offset = self.offset,
            .content = self.content,
        });
        // Iterate by offsets length so a short offsets list (OOM during layout)
        // never indexes out of bounds; tiles beyond it are skipped this frame.
        // Tiles paint at their unscrolled position and the backend applies the
        // scroll, which is what `RenderScrollView` does for its child too.
        for (self.offsets.items, 0..) |off, i| {
            try self.children.items[i].paint(cv, offset.add(off));
        }
        try cv.popScroll();
    }

    /// Point the controller at this grid. The same reasoning as `ScrollView`: a
    /// controller that already drives another view is taken over, because the
    /// widget that named it here is the live one.
    fn attach(self: *RenderGridView, controller: ?*scroll_view.ScrollController) void {
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
    /// moved the controller to another view must not have its new target erased
    /// by this grid being freed afterwards.
    fn detach(self: *RenderGridView) void {
        const c = self.controller orelse return;
        if (c.view) |v| {
            if (v.node == &self.base) c.view = null;
        }
        self.controller = null;
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderGridView = @fieldParentPtr("base", base);
        self.detach();
        self.id.deinit(gpa);
        // Frees only the lists (pointers), NOT the child render objects: those are
        // owned by the child Elements and freed by their deinit.
        self.children.deinit(gpa);
        self.offsets.deinit(gpa);
        gpa.destroy(self);
    }

    fn scrollThunk(ctx: *anyopaque, dx: f32, dy: f32) void {
        const self: *RenderGridView = @ptrCast(@alignCast(ctx));
        self.offset = scroll_view.clampOffset(
            .{ .x = self.offset.x + dx, .y = self.offset.y + dy },
            self.content,
            self.viewport,
        );
    }

    fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
        const self: *RenderGridView = @ptrCast(@alignCast(ctx));
        if (ev.action == .release) return false;
        const dy = scroll_view.keyScrollDelta(ev.keysym, self.base.size.height, self.content.height) orelse return false;
        scrollThunk(self, 0, dy);
        return true;
    }

    fn installHandlers(self: *RenderGridView) void {
        self.handlers = .{ .ctx = self, .on_scroll = scrollThunk };
        self.base.pointer = &self.handlers;
        self.focus_handlers = .{ .ctx = self, .on_key = onKey, .node = &self.base, .id = self.id.text };
        self.base.focus = &self.focus_handlers;
    }
};

pub const GridView = struct {
    /// How many tiles fit across. Zero is read as one, because a grid with no
    /// columns has nowhere to put a tile.
    columns: u32 = 1,
    /// Logical gap between tiles, on both axes.
    spacing: f32 = 0,
    /// Tile width divided by tile height. The width comes from the columns and
    /// the space offered, so this is what fixes the height. Zero or less is read
    /// as one, which gives square tiles.
    aspect_ratio: f32 = 1,
    /// A name the application can move the focus to. See `FocusManager.focusById`.
    id: ?[]const u8 = null,
    /// The handle an application scrolls this grid through. `ScrollController`
    /// drives a `ScrollView` exactly the same way.
    controller: ?*scroll_view.ScrollController = null,
    children: []const Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const GridView) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn syncChildren(rg: *RenderGridView, el: *Element, gpa: std.mem.Allocator) void {
        rg.children.clearRetainingCapacity();
        rg.children.ensureTotalCapacity(gpa, el.children.items.len) catch {
            rg.reportOom("out of memory reserving the GridView tile list");
        };
        for (el.children.items) |ch| {
            if (ch.renderObject()) |ro| rg.children.append(gpa, ro) catch {
                rg.reportOom("out of memory adding a GridView tile, tile not painted");
            };
        }
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const GridView = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const rg = try gpa.create(RenderGridView);
        rg.* = .{
            .base = .{
                .layoutFn = RenderGridView.layoutFn,
                .paintFn = RenderGridView.paintFn,
                .destroyFn = RenderGridView.destroyFn,
            },
            .gpa = gpa,
            .sink = bctx.owner.sink,
            .columns = self.columns,
            .spacing = self.spacing,
            .aspect_ratio = self.aspect_ratio,
            .handlers = .{ .ctx = rg },
        };
        // Before `installHandlers`, which reads the id into the focus handlers.
        rg.id.set(gpa, self.id) catch |e| {
            gpa.destroy(rg);
            return e;
        };
        rg.installHandlers();
        rg.attach(self.controller);
        const el = gpa.create(Element) catch |e| {
            rg.detach();
            rg.id.deinit(gpa);
            gpa.destroy(rg);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(GridView),
            .render_object = &rg.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        try el.updateChildren(self.children, bctx);
        syncChildren(rg, el, gpa);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const GridView = @ptrCast(@alignCast(ptr));
        const rg: *RenderGridView = @fieldParentPtr("base", el.render_object.?);
        rg.columns = self.columns;
        rg.spacing = self.spacing;
        rg.aspect_ratio = self.aspect_ratio;
        // A rebuild can rename the grid or move the controller to another
        // widget, so both are re-read and the handlers re-installed.
        try rg.id.set(bctx.owner.gpa, self.id);
        rg.installHandlers();
        rg.attach(self.controller);
        try el.updateChildren(self.children, bctx);
        syncChildren(rg, el, bctx.owner.gpa);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// `count` coloured tiles, so a test can read each one's rect out of the display
/// list. The caller keeps the arrays alive for the whole test.
fn fillTiles(boxes: []phantom.ColoredBox, kids: []Widget) void {
    for (boxes, 0..) |*b, i| {
        b.* = .{ .color = phantom.Color.rgb(0, 0, 1) };
        kids[i] = b.widget();
    }
}

fn pushScrollOf(prims: []const phantom.Primitive) ?phantom.display_list.ScrollRegion {
    for (prims) |p| {
        switch (p) {
            .push_scroll => |sr| return sr,
            else => {},
        }
    }
    return null;
}

/// The rrect rects in paint order, skipping the scroll markers.
fn tileRects(prims: []const phantom.Primitive, out: []geom.PhysicalRect) usize {
    var n: usize = 0;
    for (prims) |p| {
        switch (p) {
            .rrect => |r| {
                if (n < out.len) {
                    out[n] = r.rect;
                    n += 1;
                }
            },
            else => {},
        }
    }
    return n;
}

test "a fixed column count wraps tiles onto the next row" {
    const gpa = std.testing.allocator;
    var boxes: [5]phantom.ColoredBox = undefined;
    var kids: [5]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    // 200 wide, two columns, no gap: each tile is 100 wide and, at an aspect
    // ratio of one, 100 tall.
    h.viewport = .{ .width = 200, .height = 400 };
    try h.pump();

    var rects: [8]geom.PhysicalRect = undefined;
    const n = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(usize, 5), n);
    for (rects[0..n]) |r| {
        try std.testing.expectEqual(@as(f32, 100), r.width);
        try std.testing.expectEqual(@as(f32, 100), r.height);
    }
    // Row 0.
    try std.testing.expectEqual(@as(f32, 0), rects[0].x);
    try std.testing.expectEqual(@as(f32, 0), rects[0].y);
    try std.testing.expectEqual(@as(f32, 100), rects[1].x);
    try std.testing.expectEqual(@as(f32, 0), rects[1].y);
    // The third tile wraps.
    try std.testing.expectEqual(@as(f32, 0), rects[2].x);
    try std.testing.expectEqual(@as(f32, 100), rects[2].y);
    try std.testing.expectEqual(@as(f32, 100), rects[3].x);
    try std.testing.expectEqual(@as(f32, 100), rects[3].y);
    // Row 2 holds the odd one out, alone in the first column.
    try std.testing.expectEqual(@as(f32, 0), rects[4].x);
    try std.testing.expectEqual(@as(f32, 200), rects[4].y);
    try h.expectNoFaults();
}

test "the spacing sits between tiles and not after the last one" {
    const gpa = std.testing.allocator;
    var boxes: [4]phantom.ColoredBox = undefined;
    var kids: [4]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .spacing = 10, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    // 210 wide with one 10 unit gap: each tile is (210 - 10) / 2 = 100.
    h.viewport = .{ .width = 210, .height = 400 };
    try h.pump();

    var rects: [8]geom.PhysicalRect = undefined;
    const n = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(f32, 100), rects[0].width);
    try std.testing.expectEqual(@as(f32, 110), rects[1].x); // one tile plus the gap
    try std.testing.expectEqual(@as(f32, 110), rects[2].y);

    // Two rows of 100 with one gap between them is 210, not 220.
    const sr = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    try std.testing.expectEqual(@as(f32, 210), sr.content.height);
}

test "the tile count decides the content height and so the scroll extent" {
    const gpa = std.testing.allocator;
    var boxes: [9]phantom.ColoredBox = undefined;
    var kids: [9]Widget = undefined;
    fillTiles(&boxes, &kids);

    // Three columns of nine items is three rows, each 50 tall in a 150 wide box.
    var grid = GridView{ .columns = 3, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 150, .height = 100 };
    try h.pump();

    const nine = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    try std.testing.expectEqual(@as(f32, 150), nine.content.height); // three rows of 50
    try std.testing.expectEqual(@as(f32, 100), nine.viewport.height);

    // Six items are two rows, so the content and the scroll extent both shrink.
    var six_kids: [6]Widget = undefined;
    @memcpy(six_kids[0..], kids[0..6]);
    var smaller = GridView{ .columns = 3, .children = &six_kids };
    var bctx = BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    try smaller.widget().update(h.root, &bctx);
    try h.pump();

    const six = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    try std.testing.expectEqual(@as(f32, 100), six.content.height); // two rows of 50
    try std.testing.expect(six.content.height < nine.content.height);
}

test "an empty grid collapses to no content and records no fault" {
    const gpa = std.testing.allocator;
    var grid = GridView{ .columns = 4, .children = &.{} };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 120 };
    try h.pump();

    const sr = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    try std.testing.expectEqual(@as(f32, 0), sr.content.height);
    try std.testing.expectEqual(@as(f32, 0), sr.offset.y);
    // Only the push and the pop: there is no tile to paint between them.
    try std.testing.expectEqual(@as(usize, 2), h.canvas.list.primitives.items.len);
    // The grid still fills the box it was given.
    try h.expectSize(testing.find.byType(GridView), 200, 120);
    try h.expectNoFaults();
}

test "a zero column count is read as one instead of dividing by zero" {
    // The column count comes from a caller and is not trusted.
    const gpa = std.testing.allocator;
    var boxes: [2]phantom.ColoredBox = undefined;
    var kids: [2]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 0, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 400 };
    try h.pump();

    var rects: [4]geom.PhysicalRect = undefined;
    const n = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(f32, 100), rects[0].width); // one full width column
    try std.testing.expectEqual(@as(f32, 100), rects[1].y); // the second tile wrapped
    try h.expectNoFaults();
}

test "an aspect ratio of two makes a tile half as tall as it is wide" {
    const gpa = std.testing.allocator;
    var boxes: [2]phantom.ColoredBox = undefined;
    var kids: [2]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .aspect_ratio = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 200 };
    try h.pump();

    var rects: [4]geom.PhysicalRect = undefined;
    _ = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(f32, 100), rects[0].width);
    try std.testing.expectEqual(@as(f32, 50), rects[0].height);
}

test "the spacing scales with the layout scale" {
    // Without the scale multiply the gaps close up on a HiDPI display.
    const gpa = std.testing.allocator;
    var boxes: [2]phantom.ColoredBox = undefined;
    var kids: [2]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .spacing = 10, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 210, .height = 200 };

    try h.pump();
    var rects: [4]geom.PhysicalRect = undefined;
    _ = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(f32, 110), rects[1].x); // 100 tile plus a 10 gap

    // At scale two the box is 420 physical wide and the gap is 20 physical, so
    // each tile is 200 and the second starts at 220.
    h.dpr = 2.0;
    try h.pump();
    _ = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(f32, 200), rects[0].width);
    try std.testing.expectEqual(@as(f32, 220), rects[1].x);
}

test "tiles below the viewport are painted and the scroll region cuts them" {
    // This follows ScrollView, which also paints its whole child and leaves the
    // cutting to the region a backend clips.
    const gpa = std.testing.allocator;
    var boxes: [6]phantom.ColoredBox = undefined;
    var kids: [6]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    // Three rows of 50 in a viewport 60 tall: row 2 is entirely below it.
    h.viewport = .{ .width = 100, .height = 60 };
    try h.pump();

    var rects: [8]geom.PhysicalRect = undefined;
    const n = tileRects(h.canvas.list.primitives.items, &rects);
    try std.testing.expectEqual(@as(usize, 6), n); // every tile reached the list
    try std.testing.expectEqual(@as(f32, 100), rects[5].y); // the last row is off screen

    // The region names the viewport the backend clips to.
    const sr = pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll;
    try std.testing.expectEqual(@as(f32, 60), sr.viewport.height);
    try std.testing.expectEqual(@as(f32, 150), sr.content.height);
    try std.testing.expect(sr.content.height > sr.viewport.height);
}

test "the terminal backend draws only the rows inside the viewport" {
    const gpa = std.testing.allocator;
    var boxes: [4]phantom.ColoredBox = undefined;
    var kids: [4]Widget = undefined;
    for (&boxes, 0..) |*b, i| {
        // Two colours, so a row that leaked past the clip is visible as a colour
        // and not only as a missing cell.
        b.* = .{ .color = if (i < 2) phantom.Color.rgb(1, 0, 0) else phantom.Color.rgb(0, 1, 0) };
        kids[i] = b.widget();
    }

    var grid = GridView{ .columns = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();

    // 16 cells across at 8 wide is 128 physical, so each tile is 64 by 64. The
    // grid is two rows of 64, and a viewport 64 tall shows only the first.
    var r = try h.tuiRender(16, 4, 8, 16);
    defer r.deinit();

    try r.expectBg(0, 0, phantom.Color.rgb(1, 0, 0));
    try r.expectBg(15, 3, phantom.Color.rgb(1, 0, 0));
    // The green row starts at y 64, which is past the grid, so no cell holds it.
    var row: u16 = 0;
    while (row < 4) : (row += 1) {
        try r.expectBg(0, row, phantom.Color.rgb(1, 0, 0));
    }
    try h.expectNoFaults();
}

test "the wheel scrolls a grid and clamps at both ends" {
    const gpa = std.testing.allocator;
    var boxes: [6]phantom.ColoredBox = undefined;
    var kids: [6]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 60 };
    try h.pump();

    const ro = h.root.renderObject().?;
    const handlers = ro.pointer orelse return error.NoPointerHandlers;
    handlers.on_scroll.?(handlers.ctx, 0, 40);
    try h.pump();
    try std.testing.expectApproxEqAbs(@as(f32, 40), (pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll).offset.y, 0.001);

    // Content 150 in a viewport 60 leaves 90 of travel, and no more.
    handlers.on_scroll.?(handlers.ctx, 0, 999_999);
    try h.pump();
    try std.testing.expectApproxEqAbs(@as(f32, 90), (pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll).offset.y, 0.001);

    handlers.on_scroll.?(handlers.ctx, 0, -999_999);
    try h.pump();
    try std.testing.expectEqual(@as(f32, 0), (pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll).offset.y);
}

test "End jumps a grid to the bottom and Home returns it to the top" {
    const gpa = std.testing.allocator;
    var boxes: [6]phantom.ColoredBox = undefined;
    var kids: [6]Widget = undefined;
    fillTiles(&boxes, &kids);

    var grid = GridView{ .columns = 2, .children = &kids };
    var h = try testing.mount(gpa, grid.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 60 };
    try h.pump();

    const handlers = h.root.renderObject().?.focus orelse return error.NoFocusHandlers;
    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .end }));
    try h.pump();
    try std.testing.expectApproxEqAbs(@as(f32, 90), (pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll).offset.y, 0.001);

    try std.testing.expect(handlers.on_key.?(handlers.ctx, .{ .keysym = .home }));
    try h.pump();
    try std.testing.expectEqual(@as(f32, 0), (pushScrollOf(h.canvas.list.primitives.items) orelse return error.NoPushScroll).offset.y);
}

test "a grid reconciles its tile count on update, growing then shrinking" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const two = [_]Widget{ box.widget(), box.widget() };
    var grid = GridView{ .columns = 2, .children = &two };
    const el = try grid.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    const rg: *RenderGridView = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(usize, 2), rg.children.items.len);

    const five = [_]Widget{ box.widget(), box.widget(), box.widget(), box.widget(), box.widget() };
    var grown = GridView{ .columns = 2, .children = &five };
    try grown.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 5), el.children.items.len);
    try std.testing.expectEqual(@as(usize, 5), rg.children.items.len);

    const one = [_]Widget{box.widget()};
    var shrunk = GridView{ .columns = 2, .children = &one };
    try shrunk.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 1), el.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), rg.children.items.len);
    try std.testing.expect(sink.ok());
}

test "a grid layout that cannot allocate its offsets reports oom and paints no tile" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var box_a = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var box_b = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) };
    var sink_owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer sink_owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &sink_owner };
    const a_el = try box_a.widget().mount(&bctx, null);
    defer a_el.deinit(gpa);
    const b_el = try box_b.widget().mount(&bctx, null);
    defer b_el.deinit(gpa);

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var rg = RenderGridView{
        .base = .{ .layoutFn = RenderGridView.layoutFn, .paintFn = RenderGridView.paintFn },
        .gpa = failing.allocator(),
        .sink = &sink,
        .columns = 2,
        .spacing = 0,
        .aspect_ratio = 1,
        .handlers = .{ .ctx = undefined },
    };
    // The tile list is filled through the working allocator, so only the offset
    // allocations inside layoutFn meet the refusing one.
    defer {
        rg.children.deinit(gpa);
        rg.offsets.deinit(gpa);
    }
    try rg.children.append(gpa, a_el.renderObject().?);
    try rg.children.append(gpa, b_el.renderObject().?);

    _ = rg.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));
    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.oom, sink.first.?.code);
    try std.testing.expectEqual(@as(usize, 0), rg.offsets.items.len);

    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try rg.base.paint(&canvas, geom.PhysicalOffset.zero);
    // The push and the pop, with no tile between them.
    try std.testing.expectEqual(@as(usize, 2), canvas.list.primitives.items.len);
}

test "rowsFor rounds a partly filled last row up" {
    try std.testing.expectEqual(@as(usize, 0), rowsFor(0, 3));
    try std.testing.expectEqual(@as(usize, 1), rowsFor(1, 3));
    try std.testing.expectEqual(@as(usize, 1), rowsFor(3, 3));
    try std.testing.expectEqual(@as(usize, 2), rowsFor(4, 3));
    try std.testing.expectEqual(@as(usize, 3), rowsFor(9, 3));
}

test "metricsFor divides the width between the columns and the gaps" {
    const m = metricsFor(210, 2, 10, 1);
    try std.testing.expectEqual(@as(f32, 100), m.item_width);
    try std.testing.expectEqual(@as(f32, 100), m.item_height);
    try std.testing.expectEqual(@as(f32, 110), m.step_x);

    // A width too small for the gaps gives a zero tile rather than a negative one.
    const squeezed = metricsFor(10, 4, 20, 1);
    try std.testing.expectEqual(@as(f32, 0), squeezed.item_width);

    // A ratio of zero or less is read as one instead of dividing by zero.
    const guarded = metricsFor(100, 1, 0, 0);
    try std.testing.expectEqual(@as(f32, 100), guarded.item_height);
    try std.testing.expect(std.math.isFinite(metricsFor(100, 1, 0, -3).item_height));
}

test "a GridView scrolls through the same controller a ScrollView uses" {
    const gpa = std.testing.allocator;
    var ctl = scroll_view.ScrollController{};
    var kids: [12]Widget = undefined;
    var boxes: [12]phantom.ColoredBox = undefined;
    for (&boxes, 0..) |*b, i| {
        b.* = .{ .color = phantom.Color.rgb(@floatFromInt(i % 2), 0, 1) };
        kids[i] = b.widget();
    }
    var g = GridView{ .columns = 2, .controller = &ctl, .children = &kids };

    var h = try testing.mount(gpa, g.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 100 };
    try h.pump();

    // Attached by mounting, so the application never reaches into the tree.
    try std.testing.expect(ctl.attached());
    const max = ctl.maxOffset().?;
    try std.testing.expect(max.y > 0);

    try std.testing.expect(ctl.scrollBy(0, 30));
    try std.testing.expectEqual(@as(f32, 30), ctl.offset().?.y);
    // Clamped to what the content allows, exactly as a wheel event is.
    try std.testing.expect(ctl.jumpTo(.{ .x = 0, .y = max.y + 1000 }));
    try std.testing.expectEqual(max.y, ctl.offset().?.y);
}

test "unmounting a GridView detaches its controller, so the app cannot scroll freed storage" {
    const gpa = std.testing.allocator;
    var ctl = scroll_view.ScrollController{};
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 1, 1) };
    const kids = [_]Widget{box.widget()};
    var g = GridView{ .columns = 1, .controller = &ctl, .children = &kids };

    var h = try testing.mount(gpa, g.widget());
    try h.pump();
    try std.testing.expect(ctl.attached());

    h.deinit();
    try std.testing.expect(!ctl.attached());
    // Every method reports the miss rather than writing through a dead pointer.
    try std.testing.expect(!ctl.scrollBy(0, 10));
    try std.testing.expect(ctl.offset() == null);
}

test "a named GridView takes the focus by that name" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 1, 1) };
    const kids = [_]Widget{box.widget()};
    var g = GridView{ .columns = 1, .id = "launcher", .children = &kids };

    var h = try testing.mount(gpa, g.widget());
    defer h.deinit();
    try h.pump();
    try h.collectFocus();

    try std.testing.expect(h.focus.focusById("launcher"));
    try std.testing.expectEqualStrings("launcher", h.focus.focusedId().?);
}
