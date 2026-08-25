//! The Icon widget: draws one built-in mark in a box.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout_mod = phantom.layout;
const theme_mod = @import("../theme.zig");
const builtin_icons = @import("../icon/builtin.zig");

/// How a mark fills a box that is not square.
pub const Fit = enum {
    /// Keep the mark square, at the shorter side of the box, and centre it.
    /// A mark has shape in both axes, so stretching one distorts it. This is
    /// the default for that reason.
    square,
    /// Stretch the mark to the whole box.
    ///
    /// For a rule this is the only correct answer: `rule_vertical` in a box one
    /// column wide and one row tall must reach the full height of the row, or
    /// consecutive rows draw a dashed line instead of one continuous rail. A
    /// straight line stretched along its own length is the same line, so a rule
    /// loses nothing here, and its width comes from the other axis, which the
    /// box does not stretch.
    fill,
};

const RenderIcon = struct {
    base: RenderObject,
    id: builtin_icons.Id,
    /// Box side in logical units, from the widget config. Physical units come
    /// from the constraint scale at layout.
    size: f32,
    fit: Fit,
    color: geom.Color,
    /// Borrowed from the widget config, which the app owns for at least as long
    /// as the element. Nothing here copies it.
    label: ?[]const u8,

    fn layoutFn(base: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        const self: *RenderIcon = @fieldParentPtr("base", base);
        const side = self.size * c.scale;
        return c.constrain(.{ .width = side, .height = side });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderIcon = @fieldParentPtr("base", base);
        // The box layout settled on, not the side that was asked for: a parent
        // may squeeze an icon, and a mark drawn at the unconstrained size would
        // then spill outside its own box.
        const box: geom.PhysicalSize = switch (self.fit) {
            // The shorter side of a stretched box wins, which keeps the mark
            // square and inside the box in both axes.
            .square => sq: {
                const side = @min(base.size.width, base.size.height);
                break :sq .{ .width = side, .height = side };
            },
            .fill => base.size,
        };
        cv.drawIcon(.{
            .id = self.id,
            .size = box,
            .color = self.color,
            .origin = offset,
            .label = self.label,
        }) catch |e| {
            // A frame that cannot record one icon still draws the rest of the
            // tree, so this is reported and dropped rather than propagated.
            if (cv.sink) |s| s.report(.render_failed, @errorName(e));
        };
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderIcon = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

/// One built-in mark, drawn in a `size` by `size` logical box, or stretched to
/// whatever box a parent gives it when `fit` says so.
pub const Icon = struct {
    id: builtin_icons.Id,
    /// Side of the box in logical units. The grid the mark is authored on, so
    /// the default draws it at its intended weight.
    size: f32 = builtin_icons.grid,
    /// What the mark does with a box that is not square. Layout is unchanged by
    /// this: an icon still asks for `size` by `size` and takes whatever a parent
    /// gives it, so a caller reaches `.fill` by putting the icon in a box of the
    /// shape it wants, a `SizedBox` for one.
    fit: Fit = .square,
    /// Null takes the theme foreground.
    color: ?geom.Color = null,
    /// What a screen reader announces for this mark. Give one whenever the icon
    /// carries meaning of its own, because a mark alone has no text and is
    /// silent. Leave it null only when the icon repeats a label that sits beside
    /// it, where a name would be announced twice.
    label: ?[]const u8 = null,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Icon) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// An icon with no colour of its own is foreground, not body text: it sits
    /// beside a label as often as inside one, and the brand marks the two
    /// separately. `colors.fg` is the foreground; `text_color` is what a run of
    /// text takes, which a theme is free to dim on its own.
    fn resolveColor(self: *const Icon, parent: ?*Element, bctx: *phantom.BuildContext) geom.Color {
        if (self.color) |c| return c;
        const td = phantom.inheritedOf(parent, theme_mod.ThemeData) orelse theme_mod.defaultTheme(bctx.owner);
        return td.colors.fg;
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Icon = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;

        const ro = try gpa.create(RenderIcon);
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderIcon.layoutFn,
                .paintFn = RenderIcon.paintFn,
                .destroyFn = RenderIcon.destroyFn,
            },
            .id = self.id,
            .size = self.size,
            .fit = self.fit,
            .color = self.resolveColor(parent, bctx),
            .label = self.label,
        };

        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Icon),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const Icon = @ptrCast(@alignCast(ptr));
        const ro: *RenderIcon = @fieldParentPtr("base", el.render_object.?);
        ro.id = self.id;
        ro.size = self.size;
        ro.fit = self.fit;
        ro.color = self.resolveColor(el.parent, bctx);
        ro.label = self.label;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "an Icon lays out to the requested logical size" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var ic = Icon{ .id = .torii, .size = 32 };
    const el = try ic.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    // Loose, not tight: a tight constraint hands back its own size whatever the
    // widget asked for, so this would pass for an Icon that ignored `size`.
    const size = el.render_object.?.layout(layout_mod.BoxConstraints.loose(.{ .width = 200, .height = 200 }));
    try std.testing.expectEqual(@as(f32, 32), size.width);
    try std.testing.expectEqual(@as(f32, 32), size.height);
}

test "an Icon at scale 2 lays out to twice the physical size" {
    // Every logical-unit widget in Phantom scales by c.scale. Without this an
    // icon is half size on a HiDPI display.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var ic = Icon{ .id = .torii, .size = 32 };
    const el = try ic.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const size = el.render_object.?.layout(.{ .max_width = 200, .max_height = 200, .scale = 2 });
    try std.testing.expectEqual(@as(f32, 64), size.width);
    try std.testing.expectEqual(@as(f32, 64), size.height);

    // The primitive carries the physical size too. The backend rasterises at
    // that number, so a layout that scales while the primitive does not draws a
    // 32 pixel mark into a 64 pixel box.
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(geom.PhysicalSize{ .width = 64, .height = 64 }, canvas.list.primitives.items[0].icon.size);
}

test "an Icon with no explicit colour takes the theme foreground" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // The default theme sets text_color to colors.fg, so a theme that leaves
    // the two equal cannot tell them apart. Pull them apart here: an Icon that
    // took text_color, or a hardcoded white, fails on this theme only.
    var custom = theme_mod.defaultTheme(&owner).*;
    custom.colors.fg = geom.Color.rgb(1, 0, 0);
    custom.text_color = geom.Color.rgb(0, 1, 0);

    var ic = Icon{ .id = .torii, .size = 24 };
    var th = phantom.Theme{ .data = &custom, .child = ic.widget() };
    const el = try th.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const icon_el = el.child.?;
    _ = icon_el.render_object.?.layout(layout_mod.BoxConstraints.loose(.{ .width = 100, .height = 100 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try icon_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(geom.Color.rgb(1, 0, 0), canvas.list.primitives.items[0].icon.color);
}

test "an Icon emits exactly one icon primitive" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var ic = Icon{ .id = .torii, .size = 24, .color = geom.Color.rgb(0, 0, 1) };
    const el = try ic.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    _ = el.render_object.?.layout(layout_mod.BoxConstraints.loose(.{ .width = 100, .height = 100 }));

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 7, .y = 11 });

    // One primitive, and it is the icon: an Icon that also painted a backing
    // box, or that emitted one primitive per contour, fails the count.
    try std.testing.expectEqual(@as(usize, 1), canvas.list.primitives.items.len);
    const prim = canvas.list.primitives.items[0].icon;
    try std.testing.expectEqual(builtin_icons.Id.torii, prim.id);
    try std.testing.expectEqual(geom.PhysicalSize{ .width = 24, .height = 24 }, prim.size);
    try std.testing.expectEqual(geom.Color.rgb(0, 0, 1), prim.color);
    try std.testing.expectEqual(@as(f32, 7), prim.origin.x);
    try std.testing.expectEqual(@as(f32, 11), prim.origin.y);
}

test "an Icon hands its label to the primitive, and null stays null" {
    // The backends read the name off the primitive, so a widget that accepted a
    // label and dropped it here would leave every icon unnamed.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var named = Icon{ .id = .torii, .size = 24, .label = "Genesis" };
    const named_el = try named.widget().mount(&bctx, null);
    defer named_el.deinit(gpa);
    _ = named_el.render_object.?.layout(layout_mod.BoxConstraints.loose(.{ .width = 100, .height = 100 }));

    var plain = Icon{ .id = .torii, .size = 24 };
    const plain_el = try plain.widget().mount(&bctx, null);
    defer plain_el.deinit(gpa);
    _ = plain_el.render_object.?.layout(layout_mod.BoxConstraints.loose(.{ .width = 100, .height = 100 }));

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try named_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try plain_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);

    try std.testing.expectEqualStrings("Genesis", canvas.list.primitives.items[0].icon.label.?);
    try std.testing.expect(canvas.list.primitives.items[1].icon.label == null);
}

test "a label on an Icon changes nothing Prism draws" {
    // The name is for an accessibility tree, and a GPU surface has none. Prism
    // must therefore rasterise a labelled icon to the same pixels as a plain
    // one: a backend that tried to draw the name, or that shifted the mark to
    // make room for it, fails here.
    const gpa = std.testing.allocator;
    const t = phantom.testing;

    var named = Icon{ .id = .torii, .size = 48, .color = geom.Color.rgb(1, 0, 0), .label = "Genesis" };
    var named_h = try t.mount(gpa, named.widget());
    defer named_h.deinit();
    named_h.viewport = .{ .width = 64, .height = 64 };
    try named_h.pump();
    var named_raster = try named_h.rasterize();
    defer named_raster.deinit();
    const named_pixels = try gpa.dupe(u8, named_raster.pixels);
    defer gpa.free(named_pixels);

    var plain = Icon{ .id = .torii, .size = 48, .color = geom.Color.rgb(1, 0, 0) };
    var plain_h = try t.mount(gpa, plain.widget());
    defer plain_h.deinit();
    plain_h.viewport = .{ .width = 64, .height = 64 };
    try plain_h.pump();
    var plain_raster = try plain_h.rasterize();
    defer plain_raster.deinit();

    try std.testing.expectEqualSlices(u8, named_pixels, plain_raster.pixels);
}

test "an Icon squeezed by a tight constraint draws at the box it was given" {
    // A parent is free to hand down less room than the icon asked for. Painting
    // at the requested size would put the mark outside its own box.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var ic = Icon{ .id = .torii, .size = 48 };
    const el = try ic.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    _ = el.render_object.?.layout(layout_mod.BoxConstraints.tight(.{ .width = 16, .height = 16 }));

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(geom.PhysicalSize{ .width = 16, .height = 16 }, canvas.list.primitives.items[0].icon.size);
}

test "a filled Icon takes the whole box, and a square one still does not" {
    // The rail case: a box one column wide and a whole row tall. `.square`
    // shrinks the mark to the column width and leaves the rest of the row
    // blank, which draws a dashed line down a stack of rows.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = layout_mod.BoxConstraints.tight(.{ .width = 16, .height = 48 });

    var filled = Icon{ .id = .rule_vertical, .size = 24, .fit = .fill };
    const filled_el = try filled.widget().mount(&bctx, null);
    defer filled_el.deinit(gpa);
    _ = filled_el.render_object.?.layout(box);

    var squared = Icon{ .id = .rule_vertical, .size = 24 };
    const squared_el = try squared.widget().mount(&bctx, null);
    defer squared_el.deinit(gpa);
    _ = squared_el.render_object.?.layout(box);

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try filled_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    try squared_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);

    const f = canvas.list.primitives.items[0].icon.size;
    try std.testing.expectEqual(@as(f32, 16), f.width);
    try std.testing.expectEqual(@as(f32, 48), f.height);

    // The default is unchanged: a mark with shape in both axes must not start
    // stretching because a parent handed down a tall box.
    const s = canvas.list.primitives.items[1].icon.size;
    try std.testing.expectEqual(@as(f32, 16), s.width);
    try std.testing.expectEqual(@as(f32, 16), s.height);
}

test "fill and square agree when the box is already square" {
    // The two differ only in what they do with a box that is not square, so a
    // square box must give the same primitive either way.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = layout_mod.BoxConstraints.tight(.{ .width = 32, .height = 32 });
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();

    for ([_]Fit{ .fill, .square }) |fit| {
        var ic = Icon{ .id = .check, .size = 24, .fit = fit };
        const el = try ic.widget().mount(&bctx, null);
        defer el.deinit(gpa);
        _ = el.render_object.?.layout(box);
        try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    }
    try std.testing.expectEqual(
        canvas.list.primitives.items[0].icon.size,
        canvas.list.primitives.items[1].icon.size,
    );
}
