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
    /// Break the text to the width the constraints allow. False keeps the old
    /// single-line behaviour, where a long string simply runs past its box.
    ///
    /// Off by default on purpose: turning it on for everyone would silently
    /// change the height of every existing `Text` that happens to sit in a
    /// narrow box, and a layout that was correct would quietly grow a row.
    wrap: bool = false,
    para: ?text_layout.Paragraph = null,
    /// Points at `BuildOwner.text_metrics`, which outlives every element in the tree.
    /// A pointer and not a copy, so a resize that changes the cell size reaches the
    /// next layout with no remount.
    text_metrics: *const mono.TextMetrics,

    fn layoutFn(base: *RenderObject, c: layout_mod.BoxConstraints) geom.PhysicalSize {
        const self: *RenderText = @fieldParentPtr("base", base);
        if (self.para) |*p| {
            p.deinit(self.gpa);
            self.para = null;
        }
        self.physical_size = self.size * c.scale;
        // A zero width tells `layoutParagraph` not to wrap, which is exactly
        // what an unwrapped Text wants and what an unbounded constraint means.
        const wrap_width: f32 = if (self.wrap) c.max_width else 0;
        const p = text_layout.layoutParagraph(
            self.gpa,
            self.font,
            self.text,
            self.physical_size,
            self.text_metrics.*,
            wrap_width,
        ) catch {
            return c.constrain(.{ .width = 0, .height = 0 });
        };
        self.para = p;
        return c.constrain(.{ .width = p.width, .height = p.height });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderText = @fieldParentPtr("base", base);
        const p = self.para orelse return;
        // One run per line, stacked by the height of the lines above it. Each
        // run carries its own ascent, so a backend that places a baseline does
        // not have to know the paragraph exists. The run's text is that one
        // line's slice, not the whole paragraph: a backend that draws from
        // `text` rather than `glyphs` (the DOM backend) would otherwise paint
        // the full paragraph on every line and overflow the box it is in.
        var y = offset.y;
        for (p.lines) |l| {
            // A blank line still holds its height, which the layout above
            // already counted, but it draws nothing. Emitting a run for it
            // gives every backend an empty slice to carry for no reason.
            if (l.start == l.end) {
                y += l.height;
                continue;
            }
            cv.drawText(.{
                .glyphs = l.glyphs,
                .text = self.text[l.start..l.end],
                .font = @ptrCast(self.font),
                .size = self.physical_size,
                .color = self.color,
                .origin = .{ .x = offset.x, .y = y },
                .ascent = l.ascent,
            }) catch |e| {
                if (cv.sink) |s| s.report(.render_failed, @errorName(e));
            };
            y += l.height;
        }
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderText = @fieldParentPtr("base", base);
        if (self.para) |*p| p.deinit(self.gpa);
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
    /// Break the text to the width the box allows instead of running past it.
    ///
    /// Off by default, so an existing layout keeps the height it had. A caller
    /// that wants a paragraph asks for one.
    wrap: bool = false,

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
            .wrap = self.wrap,
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
        ro.wrap = self.wrap;
        // Dropped rather than re-laid out here: the next layout rebuilds it,
        // and it cannot be rebuilt now because the constraints are not known.
        if (ro.para) |*p| {
            p.deinit(ro.gpa);
            ro.para = null;
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
    try std.testing.expect(ro.para != null);

    var t2 = Text{ .text = "Bye", .font = &font, .size = 16, .color = geom.Color.rgb(0, 1, 0) };
    try t2.widget().update(el, &bctx);
    try std.testing.expect(ro.para == null);
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

test "a Text that does not ask to wrap keeps running past its box, as it always has" {
    const gpa = std.testing.allocator;
    var h = try phantom.testing.mount(gpa, blk: {
        const t = Text{ .text = "a string far longer than the box it is given", .size = 16 };
        break :blk t.widget();
    });
    defer h.deinit();
    h.viewport = .{ .width = 60, .height = 200 };
    try h.pump();

    const el = h.root;
    const ro: *RenderText = @fieldParentPtr("base", el.render_object.?);
    // One line, however narrow the box: turning wrapping on for everyone would
    // change the height of every existing layout that sits in a narrow box.
    try std.testing.expectEqual(@as(usize, 1), ro.para.?.lines.len);
}

test "a wrapping Text breaks to the width it was given and grows taller instead of wider" {
    const gpa = std.testing.allocator;
    var h = try phantom.testing.mount(gpa, blk: {
        const t = Text{ .text = "a string far longer than the box it is given", .size = 16, .wrap = true };
        break :blk t.widget();
    });
    defer h.deinit();
    h.viewport = .{ .width = 120, .height = 400 };
    try h.pump();

    const ro: *RenderText = @fieldParentPtr("base", h.root.render_object.?);
    const p = ro.para.?;
    try std.testing.expect(p.lines.len > 1);
    for (p.lines) |l| try std.testing.expect(l.width <= 120);
    // Taller than one line, which is the whole point of wrapping.
    try std.testing.expect(p.height > p.lines[0].height);
}

test "a wrapping Text's three runs hold three different lines, not the whole paragraph three times" {
    const gpa = std.testing.allocator;
    var h = try phantom.testing.mount(gpa, blk: {
        const t = Text{ .text = "one two three", .size = 16, .wrap = true };
        break :blk t.widget();
    });
    defer h.deinit();
    // Narrow enough that each word lands on its own line under this font.
    h.viewport = .{ .width = 55, .height = 400 };
    try h.pump();

    var texts: std.ArrayList([]const u8) = .empty;
    defer texts.deinit(gpa);
    for (h.canvas.list.primitives.items) |prim| {
        if (prim == .text) try texts.append(gpa, prim.text.text);
    }
    try std.testing.expectEqual(@as(usize, 3), texts.items.len);
    // Each run is its own line, none of them the full paragraph: the DOM
    // backend sets an element's text content straight from this field, so a
    // run holding the whole string would spill that whole string into every
    // line's box.
    for (texts.items) |t| try std.testing.expect(t.len < "one two three".len);
    try std.testing.expect(!std.mem.eql(u8, texts.items[0], texts.items[1]));
    try std.testing.expect(!std.mem.eql(u8, texts.items[1], texts.items[2]));
}

test "a wrapping Text stacks its lines down the box rather than drawing them on top of each other" {
    const gpa = std.testing.allocator;
    var h = try phantom.testing.mount(gpa, blk: {
        const t = Text{ .text = "one two three four five six seven", .size = 16, .wrap = true };
        break :blk t.widget();
    });
    defer h.deinit();
    h.viewport = .{ .width = 100, .height = 400 };
    try h.pump();

    // Every line reaches the display list, each at its own origin. Painting them
    // all at the same y would look like one unreadable line.
    var ys: std.ArrayList(f32) = .empty;
    defer ys.deinit(gpa);
    for (h.canvas.list.primitives.items) |prim| {
        if (prim == .text) try ys.append(gpa, prim.text.origin.y);
    }
    const ro: *RenderText = @fieldParentPtr("base", h.root.render_object.?);
    try std.testing.expectEqual(ro.para.?.lines.len, ys.items.len);
    for (ys.items[1..], 0..) |y, i| try std.testing.expect(y > ys.items[i]);
}

test "an empty Text emits no run at all, so no backend receives a zero length slice" {
    const gpa = std.testing.allocator;
    var h = try phantom.testing.mount(gpa, blk: {
        const t = Text{ .text = "", .size = 16 };
        break :blk t.widget();
    });
    defer h.deinit();
    try h.pump();

    // An empty slice carries the allocator's dangling pointer. The web host
    // builds a memory view from that pointer before it reads the length, so a
    // run holding one crashes the whole render. A blank line in a code block
    // reaches here, which is how this was found.
    for (h.canvas.list.primitives.items) |prim| {
        try std.testing.expect(prim != .text);
    }
}
