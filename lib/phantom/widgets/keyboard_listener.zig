// A widget that sees the keys nothing else used. This is the application shortcut
// path: a window that closes on Escape, or a shell that opens a launcher on a key,
// without stealing the focus from whatever the user is typing into.
//
// Unlike `Focus`, `KeyboardListener` never joins the Tab order, so it installs on
// `RenderObject.key_listener` instead of `RenderObject.focus`. `FocusManager`
// collects both in the same tree walk and consults a listener last: after the
// focused node and after the Tab/Escape traversal rules.
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

const RenderKeyboardListener = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    handlers: FocusHandlers,
    // User callback + ctx captured from the widget config.
    on_key: ?*const fn (*anyopaque, input.KeyEvent) bool,
    user_ctx: *anyopaque,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderKeyboardListener = @fieldParentPtr("base", base);
        if (self.child) |ch| return ch.layout(c);
        return c.constrain(geom.PhysicalSize.zero);
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderKeyboardListener = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderKeyboardListener = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderKeyboardListener = @fieldParentPtr("base", base);
        self.child = child;
    }
    // Thunk routing the installed handler to the user callback.
    fn keyThunk(ctx: *anyopaque, ev: input.KeyEvent) bool {
        const self: *RenderKeyboardListener = @ptrCast(@alignCast(ctx));
        if (self.on_key) |f| return f(self.user_ctx, ev);
        return false;
    }
};

pub const KeyboardListener = struct {
    child: Widget,
    /// Return true when the key was used. Called only for a key nothing higher in
    /// the dispatch order already used.
    on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
    ctx: *anyopaque = undefined,

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const KeyboardListener) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn install(ro: *RenderKeyboardListener, self: *const KeyboardListener) void {
        ro.on_key = self.on_key;
        ro.user_ctx = self.ctx;
        ro.handlers = .{
            .ctx = ro,
            .on_key = if (self.on_key != null) RenderKeyboardListener.keyThunk else null,
            .node = &ro.base,
        };
        ro.base.key_listener = &ro.handlers;
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const KeyboardListener = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderKeyboardListener);
        ro.* = .{
            .base = .{
                .layoutFn = RenderKeyboardListener.layoutFn,
                .paintFn = RenderKeyboardListener.paintFn,
                .destroyFn = RenderKeyboardListener.destroyFn,
                .adoptChildFn = RenderKeyboardListener.adopt,
            },
            .gpa = gpa,
            .handlers = .{ .ctx = undefined },
            .on_key = null,
            .user_ctx = undefined,
        };
        install(ro, self);
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(KeyboardListener), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }
    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const KeyboardListener = @ptrCast(@alignCast(ptr));
        const ro: *RenderKeyboardListener = @fieldParentPtr("base", el.render_object.?);
        install(ro, self);
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "a KeyboardListener sees a key that no focused node used" {
    const gpa = std.testing.allocator;
    const Seen = struct {
        var last: ?phantom.input.Keysym = null;
        fn onKey(_: *anyopaque, ev: phantom.input.KeyEvent) bool {
            last = ev.keysym;
            return true;
        }
    };
    Seen.last = null;

    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var kl = KeyboardListener{ .child = leaf.widget(), .on_key = Seen.onKey };
    var h = try testing.mount(gpa, kl.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);

    const q = phantom.input.Keysym.fromCodepoint('q');
    try std.testing.expect(mgr.dispatch(.{ .keysym = q }));
    try std.testing.expectEqual(@as(?phantom.input.Keysym, q), Seen.last);
}

test "a KeyboardListener does not join the tab order" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var kl = KeyboardListener{ .child = leaf.widget() };
    var h = try testing.mount(gpa, kl.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    // It listens, so it must not be focusable, or Tab would land on a widget that
    // has no visible focus of its own.
    try std.testing.expectEqual(@as(usize, 0), mgr.order.items.len);
}

test "a focused node wins a key that a KeyboardListener also wants" {
    const gpa = std.testing.allocator;
    const Focused = struct {
        fn onKey(_: *anyopaque, _: phantom.input.KeyEvent) bool {
            return true; // consumes it
        }
    };
    const Listener = struct {
        var fired = false;
        fn onKey(_: *anyopaque, _: phantom.input.KeyEvent) bool {
            fired = true;
            return true;
        }
    };
    Listener.fired = false;

    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var focusable = phantom.Focus{ .child = leaf.widget(), .on_key = Focused.onKey };
    var kl = KeyboardListener{ .child = focusable.widget(), .on_key = Listener.onKey };
    var h = try testing.mount(gpa, kl.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);
    mgr.focusNext();

    _ = mgr.dispatch(.{ .keysym = phantom.input.Keysym.fromCodepoint('x') });
    try std.testing.expect(!Listener.fired);
}

test "a real KeyboardListener never receives Tab" {
    // The manager claims Tab for itself as a traversal rule before any listener is
    // ever consulted, which is what keeps a shortcut from stealing focus movement.
    const gpa = std.testing.allocator;
    const Listener = struct {
        var saw_tab = false;
        fn onKey(_: *anyopaque, ev: phantom.input.KeyEvent) bool {
            if (ev.keysym == .tab) saw_tab = true;
            return false;
        }
    };
    Listener.saw_tab = false;

    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var kl = KeyboardListener{ .child = leaf.widget(), .on_key = Listener.onKey };
    var h = try testing.mount(gpa, kl.widget());
    defer h.deinit();

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    try mgr.collect(gpa, h.root);

    _ = mgr.dispatch(.{ .keysym = .tab });
    try std.testing.expect(!Listener.saw_tab);
}

test "unmounting a KeyboardListener removes it from the manager" {
    const gpa = std.testing.allocator;
    var leaf = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var kl = KeyboardListener{ .child = leaf.widget() };
    var h = try testing.mount(gpa, kl.widget());

    var mgr = phantom.FocusManager{};
    defer mgr.deinit(gpa);
    h.owner.focus = &mgr;
    try mgr.collect(gpa, h.root);
    try std.testing.expectEqual(@as(usize, 1), mgr.listeners.items.len);

    h.deinit();
    try std.testing.expectEqual(@as(usize, 0), mgr.listeners.items.len);
}
