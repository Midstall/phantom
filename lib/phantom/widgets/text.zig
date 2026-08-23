const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout_mod = phantom.layout;
const text_layout = @import("../text/layout.zig");
const Font = @import("../text/Font.zig");
const mono = @import("../text/mono.zig");
const dl = phantom.display_list;
const theme_mod = @import("../theme.zig");

const RenderText = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    /// Logical font size from the widget config. Scaled to physical in layoutFn
    /// using the constraint scale; paintFn reads physical_size.
    size: f32,
    physical_size: f32 = 0,
    color: geom.Color,
    line: ?text_layout.Line = null,
    /// Points at `BuildOwner.text_metrics`, which outlives every element in the tree.
    /// A pointer and not a copy, so a resize that changes the cell size reaches the
    /// next layout with no remount.
    text_metrics: *const mono.TextMetrics,

    fn layoutFn(base: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        const self: *RenderText = @fieldParentPtr("base", base);
        if (self.line) |*l| {
            l.deinit(self.gpa);
            self.line = null;
        }
        self.physical_size = self.size * c.scale;
        const l = text_layout.layoutLine(self.gpa, self.font, self.text, self.physical_size, self.text_metrics.*) catch {
            return c.constrain(.{ .width = 0, .height = 0 });
        };
        self.line = l;
        return c.constrain(.{ .width = l.width, .height = l.height });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderText = @fieldParentPtr("base", base);
        const l = self.line orelse return;
        cv.drawText(.{
            .glyphs = l.glyphs,
            .text = self.text,
            .font = @ptrCast(self.font),
            .size = self.physical_size,
            .color = self.color,
            .origin = offset,
            .ascent = l.ascent,
        }) catch |e| {
            if (cv.sink) |s| s.report(.render_failed, @errorName(e));
        };
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderText = @fieldParentPtr("base", base);
        if (self.line) |*l| l.deinit(self.gpa);
        // RenderText owns a copy of the string (the widget config it came from lives
        // in the per-frame build arena, which is reset after each frame).
        gpa.free(self.text);
        gpa.destroy(self);
    }
};

pub const Text = struct {
    text: []const u8,
    font: ?*Font = null,
    size: ?f32 = null,
    color: ?geom.Color = null,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Text) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // Resolve font/size/color from an optional parent element chain or the owner default theme.
    // Explicit fields on Text always win; null fields fall back to the theme.
    fn resolve(self: *const Text, parent: ?*Element, bctx: *phantom.BuildContext) struct { font: *Font, size: f32, color: geom.Color } {
        const td = phantom.inheritedOf(parent, theme_mod.ThemeData) orelse theme_mod.defaultTheme(bctx.owner);
        return .{
            .font = self.font orelse td.body_font,
            .size = self.size orelse td.text_size,
            .color = self.color orelse td.text_color,
        };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const r = self.resolve(parent, bctx);
        // Own a copy of the string: the widget config lives in the per-frame build
        // arena, which is reset after each frame, so a borrowed pointer would dangle
        // for any text not rebuilt every frame (e.g. a static list item).
        const text_copy = try gpa.dupe(u8, self.text);
        errdefer gpa.free(text_copy);
        const ro = try gpa.create(RenderText);
        // Free the render object (and, via the errdefer above, the string copy) if the
        // element allocation below fails, so an OOM mid-mount does not leak.
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderText.layoutFn,
                .paintFn = RenderText.paintFn,
                .destroyFn = RenderText.destroyFn,
            },
            .gpa = gpa,
            .font = r.font,
            .text = text_copy,
            .size = r.size,
            .color = r.color,
            .text_metrics = &bctx.owner.text_metrics,
        };
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Text),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        const ro: *RenderText = @fieldParentPtr("base", el.render_object.?);
        const r = self.resolve(el.parent, bctx);
        // Replace the owned string copy (dupe first so a failed alloc leaves the old
        // string intact rather than freeing it and dangling).
        const new_text = try ro.gpa.dupe(u8, self.text);
        ro.gpa.free(ro.text);
        ro.text = new_text;
        ro.font = r.font;
        ro.size = r.size;
        ro.color = r.color;
        if (ro.line) |*l| {
            l.deinit(ro.gpa);
            ro.line = null;
        }
    }
};

test "Text owns its string: survives an arena reset that clobbers the source" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // A per-frame arena string, like the demo's `allocPrint(b.arena, "Item {d}", ...)`.
    const s = try std.fmt.allocPrint(arena.allocator(), "Item {d}", .{42});
    var t = Text{ .text = s, .font = &font, .size = 16, .color = geom.Color.rgb(1, 1, 1) };
    const el = try t.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    // Simulate the per-frame reset (app.zig / web.zig) then clobber the reused memory.
    _ = arena.reset(.retain_capacity);
    const filler = try arena.allocator().alloc(u8, s.len + 8);
    @memset(filler, 'X');

    _ = el.render_object.?.layout(layout_mod.BoxConstraints.tight(.{ .width = 400, .height = 100 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    const run = canvas.list.primitives.items[0].text;
    try std.testing.expectEqualStrings("Item 42", run.text);
}

test "Text lays out and paints a TextRun matching its string and color" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t = Text{ .text = "Hi", .font = &font, .size = 32, .color = geom.Color.rgb(1, 1, 1) };
    const el = try t.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const size = el.render_object.?.layout(layout_mod.BoxConstraints.tight(.{ .width = 400, .height = 100 }));
    try std.testing.expect(size.width == 400); // tight-constrained
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 10, .y = 20 });
    const run = canvas.list.primitives.items[0].text;
    try std.testing.expectEqualStrings("Hi", run.text);
    try std.testing.expectEqual(@as(usize, 2), run.glyphs.len);
    try std.testing.expectEqual(@as(f32, 1), run.color.r);
    try std.testing.expectEqual(@as(f32, 10), run.origin.x);
}

test "Text.update invalidates cached line" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t1 = Text{ .text = "Hi", .font = &font, .size = 32, .color = geom.Color.rgb(1, 0, 0) };
    const el = try t1.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.render_object.?.layout(layout_mod.BoxConstraints.tight(.{ .width = 400, .height = 100 }));
    const ro: *RenderText = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expect(ro.line != null);

    var t2 = Text{ .text = "Bye", .font = &font, .size = 16, .color = geom.Color.rgb(0, 1, 0) };
    try t2.widget().update(el, &bctx);
    try std.testing.expect(ro.line == null);
}

test "Text with null font/color resolves from the theme; explicit wins" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // Theme-resolved: Text with no font/color wrapped in a Theme
    const td = theme_mod.defaultTheme(&owner);
    var themed = Text{ .text = "A" };
    var th = phantom.Theme{ .data = td, .child = themed.widget() };
    const el = try th.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    // the Text is el.child; its RenderText took the theme font + fg color
    const text_el = el.child.?;
    _ = text_el.render_object.?.layout(phantom.BoxConstraints.tight(.{ .width = 100, .height = 50 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try text_el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    const run = canvas.list.primitives.items[0].text;
    try std.testing.expect(@as(*const Font, @ptrCast(@alignCast(run.font))) == td.body_font);
    try std.testing.expectEqual(td.text_color, run.color);
}

test "Text with no Theme ancestor uses the instance default theme" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // No Theme in the tree; null font/color should resolve via defaultTheme(owner)
    var t = Text{ .text = "B" };
    const el = try t.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const td = theme_mod.defaultTheme(&owner);
    const ro: *RenderText = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expect(ro.font == td.body_font);
    try std.testing.expectEqual(td.text_color, ro.color);
    try std.testing.expectEqual(td.text_size, ro.size);
}

test "Text at scale 2 rasterizes at double physical size" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t = Text{ .text = "Hi", .font = &font, .size = 24, .color = geom.Color.rgb(1, 1, 1) };
    const el = try t.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.render_object.?.layout(layout_mod.BoxConstraints.tightScaled(.{ .width = 400, .height = 200 }, 2.0));
    const ro: *RenderText = @fieldParentPtr("base", el.render_object.?);
    // logical size 24 at scale 2 -> physical_size 48
    try std.testing.expectEqual(@as(f32, 48), ro.physical_size);

    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset.zero);
    const run = canvas.list.primitives.items[0].text;
    // TextRun.size must be the physical size
    try std.testing.expectEqual(@as(f32, 48), run.size);
}

test "Text explicit font/color wins over theme" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    const explicit_color = geom.Color.rgb(1, 0, 0);
    const explicit_size: f32 = 99;

    // Wrap in a Theme so we can confirm the explicit values beat it
    const td = theme_mod.defaultTheme(&owner);
    var t = Text{ .text = "C", .font = &font, .size = explicit_size, .color = explicit_color };
    var th = phantom.Theme{ .data = td, .child = t.widget() };
    const el = try th.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    const text_el = el.child.?;
    const ro: *RenderText = @fieldParentPtr("base", text_el.render_object.?);
    try std.testing.expect(ro.font == &font);
    try std.testing.expectEqual(explicit_color, ro.color);
    try std.testing.expectEqual(explicit_size, ro.size);
}
