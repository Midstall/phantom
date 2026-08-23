//! Cuts a child to a rounded rectangle. `Canvas` could already draw a rounded
//! rectangle, but nothing could bound a child to one, so a rounded surface with
//! content on it showed its content spilling over the corners.
//!
//! What each backend gives back differs, because what each one can express
//! differs. The DOM backend clips to the full rounded shape. The character grid
//! clips to whole cells, because a cell is the smallest thing it can address, so
//! the radius is dropped and the result is a rectangular clip. The GPU backend
//! clips with a scissor rectangle, which is also square. In every case a child
//! larger than the clip is cut at the boundary, which is the part a caller
//! depends on.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const testing = @import("../testing.zig");

const RenderClipRRect = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    /// Logical corner radius from the widget config. layoutFn multiplies it by
    /// the constraint scale, or the corner is half size on a HiDPI display.
    radius: f32,
    physical_radius: f32 = 0,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderClipRRect = @fieldParentPtr("base", base);
        self.physical_radius = self.radius * c.scale;
        // A proxy: the clip takes the size of what it clips, so wrapping a
        // widget in one never moves it.
        if (self.child) |ch| return c.constrain(ch.layout(c));
        return c.constrain(geom.PhysicalSize.zero);
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderClipRRect = @fieldParentPtr("base", base);
        const ch = self.child orelse return;
        // The clip is this box, so a child that overflows is cut at the edge the
        // parent gave this widget and not at the child's own edge.
        try cv.pushClip(.{
            .rect = geom.PhysicalRect.fromOriginSize(offset, base.size),
            .radius = self.physical_radius,
        });
        // Pop even when the child's paint fails, or the rest of the frame draws
        // inside a clip that was never meant for it.
        defer cv.popClip() catch |e| {
            if (cv.sink) |s| s.report(.render_failed, @errorName(e));
        };
        try ch.paint(cv, offset);
    }

    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderClipRRect = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderClipRRect = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

pub const ClipRRect = struct {
    /// Logical corner radius. Zero is a plain rectangular clip.
    radius: f32 = 0,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const ClipRRect) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const ClipRRect = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderClipRRect);
        ro.* = .{
            .base = .{
                .layoutFn = RenderClipRRect.layoutFn,
                .paintFn = RenderClipRRect.paintFn,
                .destroyFn = RenderClipRRect.destroyFn,
                .adoptChildFn = RenderClipRRect.adopt,
            },
            .radius = self.radius,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(ClipRRect),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const ClipRRect = @ptrCast(@alignCast(ptr));
        const ro: *RenderClipRRect = @fieldParentPtr("base", el.render_object.?);
        ro.radius = self.radius;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn clipRegionOf(prims: []const phantom.Primitive) ?phantom.display_list.ClipRegion {
    for (prims) |p| {
        switch (p) {
            .push_clip => |c| return c,
            else => {},
        }
    }
    return null;
}

test "a ClipRRect brackets its child's paint with a clip region" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var clip = ClipRRect{ .radius = 8, .child = box.widget() };
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 60 };
    try h.pump();

    const prims = h.canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 3), prims.len);
    _ = prims[0].push_clip;
    _ = prims[1].rrect; // the child paints between the push and the pop
    _ = prims[2].pop_clip;
    try h.expectNoFaults();
}

test "the clip rectangle is the box the parent gave the widget" {
    // A child larger than the clip must be cut at the clip's boundary, which is
    // only true if the region is the clip's own box and not the child's.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Text far wider than the 100 unit clip. A parent's constraints win over the
    // size a child reports, so an overflowing child is one whose painted content
    // runs past its box, which is what a long line does.
    var t = phantom.Text{ .text = "a very long prompt line", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var clip = ClipRRect{ .radius = 0, .child = t.widget() };
    const el = try clip.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 60 }));
    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, .{ .x = 5, .y = 7 });

    const region = clipRegionOf(canvas.list.primitives.items) orelse return error.NoClipRegion;
    try std.testing.expectEqual(@as(f32, 5), region.rect.x);
    try std.testing.expectEqual(@as(f32, 7), region.rect.y);
    try std.testing.expectEqual(@as(f32, 100), region.rect.width);
    try std.testing.expectEqual(@as(f32, 60), region.rect.height);

    // The last glyph is placed past the clip's right edge, so there really is
    // something for the boundary to cut.
    const run = canvas.list.primitives.items[1].text;
    try std.testing.expect(run.glyphs.len > 0);
    try std.testing.expect(run.origin.x + run.glyphs[run.glyphs.len - 1].x > region.rect.x + region.rect.width);
}

test "the clip radius scales with the layout scale" {
    // Without the scale multiply the corner is half as round on a HiDPI display
    // as it is on a standard one.
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var clip = ClipRRect{ .radius = 12, .child = box.widget() };
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 60 };

    try h.pump();
    try std.testing.expectEqual(@as(f32, 12), (clipRegionOf(h.canvas.list.primitives.items) orelse return error.NoClipRegion).radius);

    h.dpr = 2.0;
    try h.pump();
    try std.testing.expectEqual(@as(f32, 24), (clipRegionOf(h.canvas.list.primitives.items) orelse return error.NoClipRegion).radius);
}

test "a zero radius emits a plain rectangular clip" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 1, 0) };
    var clip = ClipRRect{ .child = box.widget() }; // radius defaults to zero
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();
    h.viewport = .{ .width = 80, .height = 40 };
    try h.pump();

    const region = clipRegionOf(h.canvas.list.primitives.items) orelse return error.NoClipRegion;
    try std.testing.expectEqual(@as(f32, 0), region.radius);
    try std.testing.expectEqual(@as(f32, 80), region.rect.width);
}

test "a ClipRRect takes the size of the child it clips" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 1) };
    var sized = phantom.SizedBox{ .width = 40, .height = 20, .child = box.widget() };
    var clip = ClipRRect{ .radius = 4, .child = sized.widget() };
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();
    // Loose, so the SizedBox is free to be smaller than the viewport and the
    // proxy behaviour is what decides the answer.
    h.viewport = .{ .width = 200, .height = 100 };
    var bctx = BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    h.owner.flushDirty(&bctx);
    const size = h.root.renderObject().?.layout(layout.BoxConstraints.loose(.{ .width = 200, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 40), size.width);
    try std.testing.expectEqual(@as(f32, 20), size.height);
}

test "an empty ClipRRect collapses without a fault" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};

    // A ClipRRect whose child slot is empty has nothing to clip.
    const ro = try gpa.create(RenderClipRRect);
    defer gpa.destroy(ro);
    ro.* = .{
        .base = .{
            .layoutFn = RenderClipRRect.layoutFn,
            .paintFn = RenderClipRRect.paintFn,
            .adoptChildFn = RenderClipRRect.adopt,
        },
        .radius = 6,
    };

    const size = ro.base.layout(layout.BoxConstraints.loose(.{ .width = 100, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 0), size.width);
    try std.testing.expectEqual(@as(f32, 0), size.height);

    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try ro.base.paint(&canvas, geom.PhysicalOffset.zero);
    // Nothing to clip means no region either, so a backend never sees a push
    // with no content and no pop.
    try std.testing.expectEqual(@as(usize, 0), canvas.list.primitives.items.len);
    try std.testing.expect(sink.ok());
}

test "the terminal path cuts a child at the clip boundary and does not fault" {
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Ten characters inside a clip four cells wide.
    var t = phantom.Text{ .text = "abcdefghij", .font = &font, .size = 14, .color = phantom.Color.rgb(1, 1, 1) };
    var clip = ClipRRect{ .radius = 8, .child = t.widget() };
    var sized = phantom.SizedBox{ .width = 32, .height = 16, .child = clip.widget() };
    var al = phantom.Align{ .alignment = .top_left, .child = sized.widget() };
    var h = try testing.mount(gpa, al.widget());
    defer h.deinit();

    var r = try h.tuiRender(10, 1, 8, 16);
    defer r.deinit();

    // Cells 0 to 3 are inside the clip and hold the first four characters.
    try r.expectCell(0, 0, 'a');
    try r.expectCell(3, 0, 'd');
    // Cell 4 is past the clip, so the fifth character never reached the grid.
    // A cleared cell holds a space, which is what the clip left behind.
    try r.expectCell(4, 0, ' ');
    try r.expectCell(9, 0, ' ');
    try h.expectNoFaults();
}

test "a terminal clip with a radius does not fault, it drops the radius" {
    // A character grid has no shape inside a cell. The radius must be ignored
    // rather than reaching a cell index calculation that cannot represent it.
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var clip = ClipRRect{ .radius = 999, .child = box.widget() };
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();

    var r = try h.tuiRender(6, 2, 8, 16);
    defer r.deinit();

    // The box fills the whole clip, so every cell inside it is red.
    try r.expectBg(0, 0, phantom.Color.rgb(1, 0, 0));
    try r.expectBg(5, 1, phantom.Color.rgb(1, 0, 0));
    try h.expectNoFaults();
}

test "a clip nested in another clip narrows it and never widens it" {
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // An inner clip that asks for eight cells inside an outer clip of three.
    var t = phantom.Text{ .text = "abcdefghij", .font = &font, .size = 14, .color = phantom.Color.rgb(1, 1, 1) };
    var inner_size = phantom.SizedBox{ .width = 64, .height = 16, .child = t.widget() };
    var inner = ClipRRect{ .child = inner_size.widget() };
    var outer_size = phantom.SizedBox{ .width = 24, .height = 16, .child = inner.widget() };
    var outer = ClipRRect{ .child = outer_size.widget() };
    var al = phantom.Align{ .alignment = .top_left, .child = outer.widget() };
    var h = try testing.mount(gpa, al.widget());
    defer h.deinit();

    var r = try h.tuiRender(10, 1, 8, 16);
    defer r.deinit();

    try r.expectCell(2, 0, 'c');
    // The inner clip wanted eight cells, and the outer's three still win.
    try r.expectCell(3, 0, ' ');
    try h.expectNoFaults();
}

test "the web backend clips to the rounded shape the widget asked for" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var clip = ClipRRect{ .radius = 16, .child = box.widget() };
    var h = try testing.mount(gpa, clip.widget());
    defer h.deinit();
    h.viewport = .{ .width = 120, .height = 60 };
    try h.pump();

    // A browser can express the whole shape, so it gets the whole shape.
    try h.expectHtml("overflow:hidden");
    try h.expectHtml("border-radius:16px");
}
