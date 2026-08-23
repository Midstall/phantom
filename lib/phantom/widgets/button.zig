const std = @import("std");
const phantom = @import("../../phantom.zig");
const theme_mod = @import("../theme.zig");
const testing = @import("../testing.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const BuildContext = phantom.BuildContext;
const pointer = phantom.pointer;

const black = geom.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };

const RenderButton = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    handlers: pointer.PointerHandlers,
    variant: Button.Variant,
    enabled: bool,
    on_tap: ?*const fn (*anyopaque) void,
    user_ctx: *anyopaque,
    base_color: geom.Color,
    hover_color: geom.Color,
    pressed_color: geom.Color,
    disabled_color: geom.Color,
    radius: f32,
    border_width: f32,
    physical_radius: f32 = 0,
    physical_border: f32 = 0,
    hovered: bool = false,
    pressed: bool = false,
    focus_handlers: phantom.FocusHandlers = undefined,
    focused: bool = false,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderButton = @fieldParentPtr("base", base);
        self.physical_radius = self.radius * c.scale;
        self.physical_border = self.border_width * c.scale;
        if (self.child) |ch| return ch.layout(c);
        return c.constrain(geom.PhysicalSize.zero);
    }

    fn paintColor(self: *RenderButton) geom.Color {
        if (!self.enabled) return self.disabled_color;
        if (self.pressed) return self.pressed_color;
        // A keyboard focus ring must be as visible as a mouse hover, or a keyboard
        // user cannot tell where the focus is, so focused shares the hover colour.
        if (self.hovered or self.focused) return self.hover_color;
        return self.base_color;
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderButton = @fieldParentPtr("base", base);
        const rect = geom.PhysicalRect.fromOriginSize(offset, base.size);
        const col = self.paintColor();
        if (self.border_width > 0) {
            if (self.enabled) {
                try cv.strokeRRectStates(rect, self.physical_radius, self.physical_border, col, self.hover_color, self.pressed_color);
            } else {
                try cv.strokeRRect(rect, self.physical_radius, self.physical_border, col);
            }
        } else {
            if (self.enabled) {
                try cv.fillRRectStates(rect, self.physical_radius, col, self.hover_color, self.pressed_color);
            } else {
                try cv.fillRRect(rect, self.physical_radius, col);
            }
        }
        if (self.child) |ch| try ch.paint(cv, offset);
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderButton = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }

    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderButton = @fieldParentPtr("base", base);
        self.child = child;
    }

    fn enterThunk(ctx: *anyopaque, _: pointer.PointerEvent) void {
        const s: *RenderButton = @ptrCast(@alignCast(ctx));
        s.hovered = true;
    }

    fn leaveThunk(ctx: *anyopaque, _: pointer.PointerEvent) void {
        const s: *RenderButton = @ptrCast(@alignCast(ctx));
        s.hovered = false;
        s.pressed = false;
    }

    fn downThunk(ctx: *anyopaque, _: pointer.PointerEvent) void {
        const s: *RenderButton = @ptrCast(@alignCast(ctx));
        s.pressed = true;
    }

    fn upThunk(ctx: *anyopaque, ev: pointer.PointerEvent) void {
        const s: *RenderButton = @ptrCast(@alignCast(ctx));
        s.pressed = false;
        const o = s.base.origin;
        const sz = s.base.size;
        const inside = ev.position.x >= o.x and ev.position.x < o.x + sz.width and
            ev.position.y >= o.y and ev.position.y < o.y + sz.height;
        if (inside) if (s.on_tap) |f| f(s.user_ctx);
    }

    /// Enter and Space operate a button. This matches what a screen reader user and a
    /// keyboard user expect from a button on every other platform.
    fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
        const self: *RenderButton = @ptrCast(@alignCast(ctx));
        if (ev.action == .release) return false;
        // A modifier held means the user is reaching for a shortcut and not pressing
        // this button, so only the bare key activates.
        if (!ev.mods.none()) return false;
        const space = phantom.input.Keysym.fromCodepoint(' ');
        const is_activate = ev.keysym == .enter or ev.keysym == space;
        if (!is_activate) return false;
        // A disabled button ignores the keyboard for the same reason it ignores a
        // click, so the enabled check belongs here and not only on the pointer path.
        if (!self.enabled) return false;
        if (self.on_tap) |f| f(self.user_ctx);
        return true;
    }

    fn onFocusChange(ctx: *anyopaque, focused: bool) void {
        const self: *RenderButton = @ptrCast(@alignCast(ctx));
        self.focused = focused;
    }

    /// A disabled button must not join the Tab order, the same way it is skipped by
    /// a pointer hit test: nothing happens when it is reached, and a keyboard user
    /// deserves the same "this control is unavailable" signal a mouse user gets for
    /// free from the cursor never landing on it.
    fn isAvailable(ctx: *anyopaque) bool {
        const self: *RenderButton = @ptrCast(@alignCast(ctx));
        return self.enabled;
    }

    fn installHandlers(self: *RenderButton) void {
        if (self.enabled) {
            self.handlers = .{
                .ctx = self,
                .on_down = downThunk,
                .on_up = upThunk,
                .on_enter = enterThunk,
                .on_leave = leaveThunk,
            };
            self.base.pointer = &self.handlers;
        } else {
            self.base.pointer = null;
        }
        self.focus_handlers = .{
            .ctx = self,
            .on_key = onKey,
            .on_focus_change = onFocusChange,
            .available = isAvailable,
        };
        self.base.focus = &self.focus_handlers;
    }
};

pub const Button = struct {
    pub const Variant = enum { primary, secondary };

    variant: Variant = .primary,
    enabled: bool = true,
    on_tap: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Button) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn colorsFor(self: *const Button, bctx: *BuildContext, anchor: ?*Element, ro: *RenderButton) void {
        const colors = (phantom.inheritedOf(anchor, theme_mod.ThemeData) orelse theme_mod.defaultTheme(bctx.owner)).colors;
        ro.variant = self.variant;
        ro.enabled = self.enabled;
        ro.on_tap = self.on_tap;
        ro.user_ctx = self.ctx;
        ro.radius = 4;
        switch (self.variant) {
            .primary => {
                const b = colors.blue;
                ro.border_width = 0;
                ro.base_color = b;
                ro.hover_color = geom.Color.mix(b, black, 0.1);
                ro.pressed_color = geom.Color.mix(b, black, 0.2);
                ro.disabled_color = geom.Color.mix(b, colors.bg, 0.6);
            },
            .secondary => {
                const d = geom.Color{ .r = colors.fg_dim.r, .g = colors.fg_dim.g, .b = colors.fg_dim.b, .a = 0.3 };
                ro.border_width = 1;
                ro.base_color = d;
                ro.hover_color = .{ .r = colors.fg_dim.r, .g = colors.fg_dim.g, .b = colors.fg_dim.b, .a = 0.5 };
                ro.pressed_color = .{ .r = colors.fg_dim.r, .g = colors.fg_dim.g, .b = colors.fg_dim.b, .a = 0.7 };
                ro.disabled_color = .{ .r = colors.fg_dim.r, .g = colors.fg_dim.g, .b = colors.fg_dim.b, .a = 0.15 };
            },
        }
        ro.installHandlers();
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Button = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderButton);
        ro.* = .{
            .base = .{
                .layoutFn = RenderButton.layoutFn,
                .paintFn = RenderButton.paintFn,
                .destroyFn = RenderButton.destroyFn,
                .adoptChildFn = RenderButton.adopt,
            },
            .gpa = gpa,
            .handlers = .{ .ctx = undefined },
            .variant = self.variant,
            .enabled = self.enabled,
            .on_tap = self.on_tap,
            .user_ctx = self.ctx,
            .base_color = geom.Color{},
            .hover_color = geom.Color{},
            .pressed_color = geom.Color{},
            .disabled_color = geom.Color{},
            .radius = 4,
            .border_width = 0,
        };
        self.colorsFor(bctx, parent, ro);
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Button),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        const pad = bctx.new(phantom.Padding{
            .insets = phantom.LogicalEdgeInsets.symmetric(24, 12),
            .child = self.child,
        });
        el.child = try el.updateChild(null, pad.widget(), bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Button = @ptrCast(@alignCast(ptr));
        const ro: *RenderButton = @fieldParentPtr("base", el.render_object.?);
        self.colorsFor(bctx, el.parent, ro);
        const pad = bctx.new(phantom.Padding{
            .insets = phantom.LogicalEdgeInsets.symmetric(24, 12),
            .child = self.child,
        });
        el.child = try el.updateChild(el.child, pad.widget(), bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "Button primary enabled: first display-list primitive is filled rrect with theme blue, hover/active colors, stroke_width 0" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var label = phantom.Text{ .text = "OK", .font = &font, .size = 14, .color = geom.Color.rgb(1, 1, 1) };
    var b = Button{ .variant = .primary, .child = label.widget() };
    const el = try b.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.renderObject().?.layout(phantom.BoxConstraints.tight(.{ .width = 200, .height = 80 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, phantom.PhysicalOffset.zero);

    const prims = canvas.list.primitives.items;
    try std.testing.expect(prims.len >= 1);
    const rr = prims[0].rrect;

    const blue = theme_mod.hex("#7aa2f7");
    try std.testing.expectApproxEqAbs(blue.r, rr.color.r, 0.01);
    try std.testing.expectApproxEqAbs(blue.g, rr.color.g, 0.01);
    try std.testing.expectApproxEqAbs(blue.b, rr.color.b, 0.01);
    try std.testing.expectEqual(@as(f32, 0), rr.stroke_width);

    const expected_hover = geom.Color.mix(blue, black, 0.1);
    const expected_active = geom.Color.mix(blue, black, 0.2);
    try std.testing.expect(rr.hover_color != null);
    try std.testing.expect(rr.active_color != null);
    try std.testing.expectApproxEqAbs(expected_hover.r, rr.hover_color.?.r, 0.01);
    try std.testing.expectApproxEqAbs(expected_hover.g, rr.hover_color.?.g, 0.01);
    try std.testing.expectApproxEqAbs(expected_active.r, rr.active_color.?.r, 0.01);
    try std.testing.expectApproxEqAbs(expected_active.g, rr.active_color.?.g, 0.01);
}

test "Button secondary enabled: first rrect has stroke_width > 0, base alpha 0.3, hover alpha 0.5" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var label = phantom.Text{ .text = "OK", .font = &font, .size = 14, .color = geom.Color.rgb(0, 0, 0) };
    var b = Button{ .variant = .secondary, .child = label.widget() };
    const el = try b.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    _ = el.renderObject().?.layout(phantom.BoxConstraints.tight(.{ .width = 200, .height = 80 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, phantom.PhysicalOffset.zero);

    const prims = canvas.list.primitives.items;
    try std.testing.expect(prims.len >= 1);
    const rr = prims[0].rrect;

    try std.testing.expect(rr.stroke_width > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), rr.color.a, 0.01);
    try std.testing.expect(rr.hover_color != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rr.hover_color.?.a, 0.01);
}

test "Button enabled installs handlers; disabled installs none and paints plain rrect" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    {
        var label = phantom.Text{ .text = "X", .font = &font, .size = 14, .color = geom.Color.rgb(1, 1, 1) };
        var b = Button{ .enabled = true, .child = label.widget() };
        const el = try b.widget().mount(&bctx, null);
        defer el.deinit(gpa);
        const ro = el.renderObject().?;
        _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 100, .height = 50 }));
        var canvas = phantom.Canvas.init(gpa);
        defer canvas.deinit();
        try ro.paint(&canvas, phantom.PhysicalOffset.zero);
        try std.testing.expect(ro.pointer != null);
        const h = ro.pointer.?;
        try std.testing.expect(h.on_enter != null);
        try std.testing.expect(h.on_leave != null);
        try std.testing.expect(h.on_down != null);
        try std.testing.expect(h.on_up != null);
    }

    arena.deinit();
    arena = std.heap.ArenaAllocator.init(gpa);
    bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    {
        var label = phantom.Text{ .text = "X", .font = &font, .size = 14, .color = geom.Color.rgb(1, 1, 1) };
        var b = Button{ .enabled = false, .child = label.widget() };
        const el = try b.widget().mount(&bctx, null);
        defer el.deinit(gpa);
        const ro = el.renderObject().?;
        _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 100, .height = 50 }));
        var canvas = phantom.Canvas.init(gpa);
        defer canvas.deinit();
        try ro.paint(&canvas, phantom.PhysicalOffset.zero);
        try std.testing.expect(ro.pointer == null);
        const prims = canvas.list.primitives.items;
        try std.testing.expect(prims.len >= 1);
        const rr = prims[0].rrect;
        try std.testing.expect(rr.hover_color == null);
        try std.testing.expect(rr.active_color == null);
    }
}

// `Button.child` is required and has no default, so every test needs a leaf.
// `ColoredBox` is the leaf widget in this codebase: one colour, no child.
test "Enter on a focused button fires the tap callback" {
    const gpa = std.testing.allocator;
    const Counter = struct {
        var count: u32 = 0;
        fn onTap(_: *anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var dummy: u8 = 0;
    var b = Button{ .on_tap = Counter.onTap, .ctx = &dummy, .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const ro = h.root.renderObject().?;
    const handlers = findFocus(ro) orelse return error.NoFocusHandlers;
    _ = handlers.on_key.?(handlers.ctx, .{ .keysym = .enter });
    try std.testing.expectEqual(@as(u32, 1), Counter.count);
}

test "Space on a focused button fires the tap callback" {
    const gpa = std.testing.allocator;
    const Counter = struct {
        var count: u32 = 0;
        fn onTap(_: *anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var dummy: u8 = 0;
    var b = Button{ .on_tap = Counter.onTap, .ctx = &dummy, .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const handlers = findFocus(h.root.renderObject().?) orelse return error.NoFocusHandlers;
    _ = handlers.on_key.?(handlers.ctx, .{ .keysym = phantom.input.Keysym.fromCodepoint(' ') });
    try std.testing.expectEqual(@as(u32, 1), Counter.count);
}

test "a key the button does not use is not consumed" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var b = Button{ .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const handlers = findFocus(h.root.renderObject().?) orelse return error.NoFocusHandlers;
    try std.testing.expect(!handlers.on_key.?(handlers.ctx, .{ .keysym = phantom.input.Keysym.fromCodepoint('q') }));
}

test "Enter with a modifier held does not fire the tap callback" {
    // A modifier held means the user is reaching for a shortcut, not pressing this
    // button, so only the bare key may activate it.
    const gpa = std.testing.allocator;
    const Counter = struct {
        var count: u32 = 0;
        fn onTap(_: *anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var dummy: u8 = 0;
    var b = Button{ .on_tap = Counter.onTap, .ctx = &dummy, .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const handlers = findFocus(h.root.renderObject().?) orelse return error.NoFocusHandlers;
    try std.testing.expect(!handlers.on_key.?(handlers.ctx, .{ .keysym = .enter, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(u32, 0), Counter.count);
}

test "Enter on a disabled focused button does not fire the tap callback" {
    // A disabled button ignores the keyboard for the same reason it ignores a
    // click, so the enabled check belongs on the key path too.
    const gpa = std.testing.allocator;
    const Counter = struct {
        var count: u32 = 0;
        fn onTap(_: *anyopaque) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var dummy: u8 = 0;
    var b = Button{ .enabled = false, .on_tap = Counter.onTap, .ctx = &dummy, .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const handlers = findFocus(h.root.renderObject().?) orelse return error.NoFocusHandlers;
    try std.testing.expect(!handlers.on_key.?(handlers.ctx, .{ .keysym = .enter }));
    try std.testing.expectEqual(@as(u32, 0), Counter.count);
}

test "a disabled button leaves the traversal order, and rejoins when re-enabled" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var b = Button{ .enabled = true, .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 1), mgr.order.items.len);

    // Flip to disabled through an update (the button stays mounted; this is the
    // `enabled` field changing between rebuilds, not a remount) and recollect.
    var leaf2 = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var disabled = Button{ .enabled = false, .child = leaf2.widget() };
    var bctx = phantom.BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    try disabled.widget().update(h.root, &bctx);
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 0), mgr.order.items.len);

    // Flip back to enabled and recollect: it must rejoin the order.
    var leaf3 = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var enabled_again = Button{ .enabled = true, .child = leaf3.widget() };
    try enabled_again.widget().update(h.root, &bctx);
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 1), mgr.order.items.len);
}

test "disabling a focused button clears its focused state so a stale ring cannot return" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var b = Button{ .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    mgr.focusNext();

    const ro: *RenderButton = @fieldParentPtr("base", h.root.renderObject().?);
    try std.testing.expect(ro.focused);

    var leaf2 = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var disabled = Button{ .enabled = false, .child = leaf2.widget() };
    var bctx = phantom.BuildContext{ .arena = h.arena.allocator(), .owner = h.owner };
    try disabled.widget().update(h.root, &bctx);
    // Recollect drops the now-unavailable button from `order`, which must also fire
    // on_focus_change(false), or `focused` stays stale true and a re-enabled button
    // would show a ring before Tab ever reaches it again.
    try mgr.collect(gpa, h.root);

    try std.testing.expect(mgr.current == null);
    try std.testing.expect(!ro.focused);
}

test "gaining focus paints the button in its focused colour" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = geom.Color.rgb(0, 0, 1) };
    var b = Button{ .child = leaf.widget() };
    var h = try testing.mount(gpa, b.widget());
    defer h.deinit();

    const handlers = findFocus(h.root.renderObject().?) orelse return error.NoFocusHandlers;
    handlers.on_focus_change.?(handlers.ctx, true);
    try h.pump();
    // The focused state must reach the display list as a different colour than the
    // resting state, or the user cannot see where the focus is.
    const focused_color = firstRRectColor(h.canvas.list) orelse return error.NoRRect;
    handlers.on_focus_change.?(handlers.ctx, false);
    try h.pump();
    const resting_color = firstRRectColor(h.canvas.list) orelse return error.NoRRect;
    try std.testing.expect(focused_color.r != resting_color.r or
        focused_color.g != resting_color.g or
        focused_color.b != resting_color.b);
}

fn findFocus(ro: *RenderObject) ?*phantom.FocusHandlers {
    if (ro.focus) |h| return h;
    return null;
}

fn firstRRectColor(list: phantom.display_list.DisplayList) ?geom.Color {
    for (list.primitives.items) |p| {
        switch (p) {
            .rrect => |r| return r.color,
            else => {},
        }
    }
    return null;
}

test "Button tap fires on_tap via down+up in bounds" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var taps: u32 = 0;
    var label = phantom.Text{ .text = "+", .font = &font, .size = 24, .color = geom.Color.rgb(1, 1, 1) };
    var b = Button{ .ctx = &taps, .on_tap = struct {
        fn f(ctx: *anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.f, .child = label.widget() };
    const el = try b.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 200, .height = 80 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try ro.paint(&canvas, phantom.PhysicalOffset.zero);
    try std.testing.expect(ro.pointer != null);
    var d = phantom.input.Dispatcher{};
    d.down(el, .{ .x = 20, .y = 20 });
    d.up(el, .{ .x = 20, .y = 20 });
    try std.testing.expectEqual(@as(u32, 1), taps);
}
