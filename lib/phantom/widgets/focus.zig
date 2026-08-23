// A widget that can hold the keyboard focus. This is the keyboard equivalent of
// `Listener`, which does the same job for the pointer.
//
// Named by the approved compositor design, which also names `KeyboardListener` and
// `TextField`. One key path serves the terminal, the compositor and a future text
// field, so nothing here may be terminal specific.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const testing = @import("../testing.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;
const FocusHandlers = phantom.FocusHandlers;
const input = phantom.input;

const RenderFocus = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    handlers: FocusHandlers,
    // User callbacks + ctx captured from the widget config.
    on_key: ?*const fn (*anyopaque, input.KeyEvent) bool,
    on_focus_change: ?*const fn (*anyopaque, bool) void,
    user_ctx: *anyopaque,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderFocus = @fieldParentPtr("base", base);
        if (self.child) |ch| return ch.layout(c);
        return c.constrain(geom.PhysicalSize.zero);
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderFocus = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderFocus = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderFocus = @fieldParentPtr("base", base);
        self.child = child;
    }
    // Thunks routing the installed handlers to the user callbacks.
    fn keyThunk(ctx: *anyopaque, ev: input.KeyEvent) bool {
        const self: *RenderFocus = @ptrCast(@alignCast(ctx));
        if (self.on_key) |f| return f(self.user_ctx, ev);
        return false;
    }
    fn focusChangeThunk(ctx: *anyopaque, focused: bool) void {
        const self: *RenderFocus = @ptrCast(@alignCast(ctx));
        if (self.on_focus_change) |f| f(self.user_ctx, focused);
    }
};

pub const Focus = struct {
    child: Widget,
    /// Return true when the key was used. An unused key falls through to the focus
    /// traversal rules, which is how Tab keeps working inside a focusable widget.
    on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
    on_focus_change: ?*const fn (ctx: *anyopaque, focused: bool) void = null,
    ctx: *anyopaque = undefined,

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const Focus) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn install(ro: *RenderFocus, self: *const Focus) void {
        ro.on_key = self.on_key;
        ro.on_focus_change = self.on_focus_change;
        ro.user_ctx = self.ctx;
        ro.handlers = .{
            .ctx = ro,
            .on_key = if (self.on_key != null) RenderFocus.keyThunk else null,
            .on_focus_change = if (self.on_focus_change != null) RenderFocus.focusChangeThunk else null,
        };
        ro.base.focus = &ro.handlers;
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Focus = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderFocus);
        ro.* = .{ .base = .{ .layoutFn = RenderFocus.layoutFn, .paintFn = RenderFocus.paintFn, .destroyFn = RenderFocus.destroyFn, .adoptChildFn = RenderFocus.adopt }, .gpa = gpa, .handlers = .{ .ctx = undefined }, .on_key = null, .on_focus_change = null, .user_ctx = undefined };
        install(ro, self);
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Focus), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }
    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Focus = @ptrCast(@alignCast(ptr));
        const ro: *RenderFocus = @fieldParentPtr("base", el.render_object.?);
        install(ro, self);
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "a Focus widget registers one focus node in the tree order" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var f = Focus{ .child = leaf.widget() };
    var h = try testing.mount(gpa, f.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 1), mgr.order.items.len);
}

test "a Focus widget delivers keys to its callback only while it holds the focus" {
    const gpa = std.testing.allocator;
    const Seen = struct {
        var count: u32 = 0;
        fn onKey(_: *anyopaque, _: phantom.input.KeyEvent) bool {
            count += 1;
            return true;
        }
    };
    Seen.count = 0;

    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var f = Focus{ .child = leaf.widget(), .on_key = Seen.onKey };
    var h = try testing.mount(gpa, f.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);

    // Nothing is focused yet, so the callback must not fire.
    _ = mgr.dispatch(.{ .keysym = phantom.input.Keysym.fromCodepoint('x') });
    try std.testing.expectEqual(@as(u32, 0), Seen.count);

    mgr.focusNext();
    _ = mgr.dispatch(.{ .keysym = phantom.input.Keysym.fromCodepoint('x') });
    try std.testing.expectEqual(@as(u32, 1), Seen.count);
}

test "two Focus widgets collect in the order they appear in the tree" {
    const gpa = std.testing.allocator;
    var leaf_a = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var leaf_b = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) };
    var first = Focus{ .child = leaf_a.widget() };
    var second = Focus{ .child = leaf_b.widget() };
    var children = [_]phantom.Widget{ first.widget(), second.widget() };
    var column = phantom.Column(.{ .children = &children });
    var h = try testing.mount(gpa, column.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 2), mgr.order.items.len);

    // Tab order follows the tree, which is the order a reader sees the widgets in.
    mgr.focusNext();
    const one = mgr.current.?;
    mgr.focusNext();
    try std.testing.expect(mgr.current != one);
}

test "unmounting a focused Focus widget removes it from the manager" {
    // Element.deinit must call forgetFocus, or the manager keeps a pointer into
    // freed memory and the next key dereferences it.
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var f = Focus{ .child = leaf.widget() };
    var h = try testing.mount(gpa, f.widget());

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    h.owner.focus = &mgr;
    try mgr.collect(gpa, h.root);
    mgr.focusNext();
    try std.testing.expect(mgr.current != null);

    h.deinit();
    try std.testing.expect(mgr.current == null);
    try std.testing.expectEqual(@as(usize, 0), mgr.order.items.len);
}
