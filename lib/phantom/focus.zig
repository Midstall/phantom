const std = @import("std");

test "collect finds the focusable render objects in tree order" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &h1, &h2 });
    defer tree.deinit(gpa);

    try m.collect(gpa, tree.root);
    try std.testing.expectEqual(@as(usize, 2), m.order.items.len);
    try std.testing.expect(m.order.items[0] == &h1);
    try std.testing.expect(m.order.items[1] == &h2);
}

test "focusNext moves forward and wraps at the end" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    try std.testing.expect(m.current == null);
    m.focusNext();
    try std.testing.expect(m.current == &h1);
    m.focusNext();
    try std.testing.expect(m.current == &h2);
    m.focusNext();
    try std.testing.expect(m.current == &h1); // wrapped
}

test "focusPrev moves backward and wraps at the start" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    m.focusPrev();
    try std.testing.expect(m.current == &h2); // wrapped from nothing to the last
    m.focusPrev();
    try std.testing.expect(m.current == &h1);
}

test "a focus change calls the leaving node and then the arriving node" {
    const gpa = std.testing.allocator;
    const Log = struct {
        var events: [4]bool = .{ false, false, false, false };
        fn a(_: *anyopaque, focused: bool) void {
            events[if (focused) 0 else 1] = true;
        }
        fn b(_: *anyopaque, focused: bool) void {
            events[if (focused) 2 else 3] = true;
        }
    };
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy, .on_focus_change = Log.a };
    var h2 = FocusHandlers{ .ctx = &dummy, .on_focus_change = Log.b };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    m.focusNext(); // h1 gains focus
    try std.testing.expect(Log.events[0]);
    m.focusNext(); // h1 loses it and h2 gains it
    try std.testing.expect(Log.events[1]);
    try std.testing.expect(Log.events[2]);
}

test "the focused node sees every key, including Tab" {
    // The focused node gets first refusal, so a text field can insert a tab and a
    // dialog can take Escape. Only what it refuses reaches the traversal rules.
    const gpa = std.testing.allocator;
    const Greedy = struct {
        var saw: ?input.Keysym = null;
        fn onKey(_: *anyopaque, ev: input.KeyEvent) bool {
            saw = ev.keysym;
            return true; // consumes everything
        }
    };
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy, .on_key = Greedy.onKey };
    var h2 = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext(); // current is h1

    Greedy.saw = null;
    try std.testing.expect(m.dispatch(.{ .keysym = .tab }));
    try std.testing.expectEqual(@as(?input.Keysym, .tab), Greedy.saw);
    // It consumed Tab, so the focus did not move.
    try std.testing.expect(m.current == &h1);
}

test "a key the focused node refuses falls through to the traversal rules" {
    const gpa = std.testing.allocator;
    const Picky = struct {
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            return false; // consumes nothing
        }
    };
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy, .on_key = Picky.onKey };
    var h2 = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext(); // current is h1

    try std.testing.expect(m.dispatch(.{ .keysym = .tab }));
    try std.testing.expect(m.current == &h2);
}

test "a node with no key handler still lets Tab move the focus" {
    const gpa = std.testing.allocator;
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy };
    var h2 = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext();

    try std.testing.expect(m.dispatch(.{ .keysym = .tab }));
    try std.testing.expect(m.current == &h2);
}

test "an ordinary key with no focused node is not consumed" {
    const gpa = std.testing.allocator;
    var m = FocusManager{};
    defer m.deinit(gpa);
    try std.testing.expect(!m.dispatch(.{ .keysym = input.Keysym.fromCodepoint('x') }));
}

test "forget removes a node and clears it from the current slot" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext(); // current is h1

    m.forget(&h1);
    try std.testing.expect(m.current == null);
    try std.testing.expectEqual(@as(usize, 1), m.order.items.len);
    // A dispatch after the removal must not reach the freed handlers.
    try std.testing.expect(!m.dispatch(.{ .keysym = input.Keysym.fromCodepoint('x') }));
}

test "a release does not move the focus" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext();

    _ = m.dispatch(.{ .keysym = .tab, .action = .release });
    try std.testing.expect(m.current == &h1); // a release must not advance twice
}

test "a repeat does move the focus, so holding Tab keeps moving" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext();

    _ = m.dispatch(.{ .keysym = .tab, .action = .repeat });
    try std.testing.expect(m.current == &h2);
}

test "escape reaches a listener when no node is focused" {
    // A `KeyboardListener` closing a window on Escape must work even when nothing
    // holds the focus, which is the common case for a global shortcut.
    const gpa = std.testing.allocator;
    const Listener = struct {
        fn onKey(_: *anyopaque, ev: input.KeyEvent) bool {
            return ev.keysym == .escape;
        }
    };
    var dummy: u8 = 0;
    var l = FocusHandlers{ .ctx = &dummy, .on_key = Listener.onKey };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.listeners.append(gpa, &l);

    try std.testing.expect(m.dispatch(.{ .keysym = .escape }));
}

test "the shortcut listeners are consulted last, after the tab traversal rule" {
    const gpa = std.testing.allocator;
    const Listener = struct {
        var fired = false;
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            fired = true;
            return true;
        }
    };
    Listener.fired = false;
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy };
    var l = FocusHandlers{ .ctx = &dummy, .on_key = Listener.onKey };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.listeners.append(gpa, &l);
    m.focusNext(); // current is h1, which has no on_key of its own

    // Tab is a traversal rule and must claim the key before a listener ever sees it.
    try std.testing.expect(m.dispatch(.{ .keysym = .tab }));
    try std.testing.expect(!Listener.fired);
}

test "forget drops a listener so a later key does not reach freed memory" {
    const gpa = std.testing.allocator;
    var dummy: u8 = 0;
    var l = FocusHandlers{ .ctx = &dummy, .on_key = struct {
        fn f(_: *anyopaque, _: input.KeyEvent) bool {
            return true;
        }
    }.f };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.listeners.append(gpa, &l);
    try std.testing.expect(m.dispatch(.{ .keysym = input.Keysym.fromCodepoint('q') }));

    m.forget(&l);
    try std.testing.expectEqual(@as(usize, 0), m.listeners.items.len);
    try std.testing.expect(!m.dispatch(.{ .keysym = input.Keysym.fromCodepoint('q') }));
}

// Keyboard focus. The pointer path installs `PointerHandlers` on a render object and
// hit tests the tree to find them. Focus is the same shape with a list instead of a
// hit test: the order is the pre-order walk of the element tree, which is the order
// a reader sees the widgets in, and that is what a Tab key should follow.
const input = @import("input.zig");
const widget = @import("widget.zig");
const render_object = @import("render_object.zig");
const Element = widget.Element;
const Widget = widget.Widget;
const RenderObject = render_object.RenderObject;

/// Installed on a render object that accepts the keyboard. The context is explicit
/// because a Zig function pointer cannot close over state, which is the same reason
/// `PointerHandlers` carries one.
pub const FocusHandlers = struct {
    ctx: *anyopaque,
    /// Returns true when the key was used. An unused key travels no further, because
    /// there is no bubbling in this slice.
    on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
    on_focus_change: ?*const fn (ctx: *anyopaque, focused: bool) void = null,
    /// Returns false when this handler is temporarily unavailable, for example a
    /// disabled button, and must be skipped by `collect`. Null means always
    /// available. Checked fresh on every `collect`, which runs after every rebuild,
    /// so a widget that flips its own enabled state between rebuilds needs no extra
    /// bookkeeping: the next collect just sees the new answer. Shared by `order` and
    /// `listeners`, so a future disabled `TextField` uses the same field.
    available: ?*const fn (ctx: *anyopaque) bool = null,
};

pub const FocusManager = struct {
    order: std.ArrayList(*FocusHandlers) = .empty,
    current: ?*FocusHandlers = null,
    /// Widgets that see the keys nothing else used. Collected by the same tree walk
    /// that fills `order`, and consulted last.
    listeners: std.ArrayList(*FocusHandlers) = .empty,

    pub fn deinit(self: *FocusManager, gpa: std.mem.Allocator) void {
        self.order.deinit(gpa);
        self.listeners.deinit(gpa);
        self.* = undefined;
    }

    /// Rebuild the traversal order from the tree. Called after a build pass, because
    /// a rebuild can add or remove focusable nodes, and because a node can flip its
    /// own `available` answer (e.g. a button's `enabled` field) between rebuilds
    /// with no separate notification.
    pub fn collect(self: *FocusManager, gpa: std.mem.Allocator, root: *Element) !void {
        self.order.clearRetainingCapacity();
        self.listeners.clearRetainingCapacity();
        try walk(gpa, root, &self.order, &self.listeners);
        // The focused node may have been removed from the tree, or turned itself
        // unavailable, by the rebuild that preceded this. Either way it is gone from
        // `order` now. The render object is still alive here (an unmount instead goes
        // through `forget`, which is called before the render object is freed), so it
        // is safe to fire `on_focus_change(false)` through `setCurrent`, which lets a
        // widget like `RenderButton` clear its own `focused` flag instead of leaving
        // a stale ring waiting for it if it becomes available again.
        if (self.current) |c| {
            var still_there = false;
            for (self.order.items) |h| {
                if (h == c) still_there = true;
            }
            if (!still_there) self.setCurrent(null);
        }
    }

    fn walk(gpa: std.mem.Allocator, el: *Element, out: *std.ArrayList(*FocusHandlers), listeners: *std.ArrayList(*FocusHandlers)) !void {
        if (el.render_object) |ro| {
            if (ro.focus) |h| if (isAvailable(h)) try out.append(gpa, h);
            if (ro.key_listener) |h| if (isAvailable(h)) try listeners.append(gpa, h);
        }
        if (el.child) |c| try walk(gpa, c, out, listeners);
        for (el.children.items) |c| try walk(gpa, c, out, listeners);
    }

    fn isAvailable(h: *FocusHandlers) bool {
        return if (h.available) |f| f(h.ctx) else true;
    }

    pub fn focusNext(self: *FocusManager) void {
        self.move(1);
    }

    pub fn focusPrev(self: *FocusManager) void {
        self.move(-1);
    }

    fn move(self: *FocusManager, step: i32) void {
        if (self.order.items.len == 0) return;
        const count: i32 = @intCast(self.order.items.len);
        const from: i32 = if (self.current) |c| self.indexOf(c) orelse -1 else if (step > 0) -1 else 0;
        // The modulo of a negative value is negative in Zig, so the count is added
        // before the wrap.
        const next_index = @mod(from + step + count, count);
        self.setCurrent(self.order.items[@intCast(next_index)]);
    }

    fn indexOf(self: *FocusManager, h: *FocusHandlers) ?i32 {
        for (self.order.items, 0..) |item, i| {
            if (item == h) return @intCast(i);
        }
        return null;
    }

    fn setCurrent(self: *FocusManager, h: ?*FocusHandlers) void {
        if (self.current == h) return;
        if (self.current) |old| {
            if (old.on_focus_change) |f| f(old.ctx, false);
        }
        self.current = h;
        if (h) |new| {
            if (new.on_focus_change) |f| f(new.ctx, true);
        }
    }

    pub fn clear(self: *FocusManager) void {
        self.setCurrent(null);
    }

    /// Route one key. The focused node sees it first, because an application must be
    /// able to take a key the manager would otherwise spend: a text field needs Tab
    /// to insert a tab, and a dialog needs Escape to close itself. A key the focused
    /// node does not use reaches the traversal rules (Tab, Escape), and a key the
    /// traversal rules decline reaches the shortcut listeners last: a `KeyboardListener`
    /// never steals a key the focused node or a traversal rule wanted first.
    ///
    /// Returns true when the key was used.
    pub fn dispatch(self: *FocusManager, ev: input.KeyEvent) bool {
        // A repeat moves focus, because holding Tab should keep moving. A release
        // must not, or every Tab would move twice.
        if (ev.action == .release) return false;

        if (self.current) |c| {
            if (c.on_key) |f| {
                if (f(c.ctx, ev)) return true;
            }
        }

        switch (ev.keysym) {
            .tab => {
                if (ev.mods.shift) self.focusPrev() else self.focusNext();
                return true;
            },
            .escape => {
                // Nothing to clear: the traversal rule declines and the key falls
                // through, so a listener can still close a window on Escape when no
                // widget holds the focus.
                if (self.current != null) {
                    self.clear();
                    return true;
                }
            },
            else => {},
        }

        // Last: the shortcut listeners, in tree order. The first one that uses the
        // key ends the walk.
        for (self.listeners.items) |l| {
            if (l.on_key) |f| {
                if (f(l.ctx, ev)) return true;
            }
        }
        return false;
    }

    /// Drop `h` without calling any callback. `Element.deinit` calls this when a
    /// render object that carries these handlers is freed, so a later key can never
    /// reach freed memory. This mirrors `Dispatcher.forget`. `h` is only ever present
    /// in one of `order` and `listeners`, but both are checked so the caller does not
    /// need to know which kind of handler it is freeing.
    pub fn forget(self: *FocusManager, h: *FocusHandlers) void {
        if (self.current == h) self.current = null;
        removeAll(&self.order, h);
        removeAll(&self.listeners, h);
    }

    /// Remove every occurrence of `h` from `list`. In practice `h` lives in only one
    /// of `order` and `listeners`, so calling this on the other is a no-op scan; no
    /// early exit on the caller's side, so the two calls in `forget` stay identical
    /// regardless of which list actually holds `h`.
    fn removeAll(list: *std.ArrayList(*FocusHandlers), h: *FocusHandlers) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i] == h) {
                _ = list.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }
};

const TestTree = struct {
    root: *Element,
    objects: []RenderObject,

    fn deinit(self: *TestTree, gpa: std.mem.Allocator) void {
        // The elements are gpa owned by testTree, so free them the same way.
        gpa.free(self.objects);
        freeElement(gpa, self.root);
    }
};

fn freeElement(gpa: std.mem.Allocator, el: *Element) void {
    if (el.child) |c| freeElement(gpa, c);
    for (el.children.items) |c| freeElement(gpa, c);
    var e = el;
    e.children.deinit(gpa);
    gpa.destroy(e);
}

// A placeholder vtable for hand-built test elements. Never dispatched: these trees
// are walked directly, not mounted or updated.
const test_vtable = Widget.VTable{ .mount = undefined, .update = undefined };

/// Build a chain of elements, each holding one render object, and give the render
/// object at index i the handlers at index i.
fn testTree(gpa: std.mem.Allocator, handlers: []const *FocusHandlers) !TestTree {
    const objects = try gpa.alloc(RenderObject, handlers.len);
    errdefer gpa.free(objects);
    var root: ?*Element = null;
    var prev: ?*Element = null;
    var i: usize = 0;
    while (i < handlers.len) : (i += 1) {
        objects[i] = .{ .layoutFn = noLayout, .paintFn = noPaint, .focus = handlers[i] };
        const el = try gpa.create(Element);
        el.* = .{ .type_name = "test", .owner = undefined, .vtable = &test_vtable, .render_object = &objects[i] };
        if (root == null) root = el else prev.?.child = el;
        prev = el;
    }
    return .{ .root = root.?, .objects = objects };
}

fn noLayout(_: *RenderObject, c: @import("layout.zig").BoxConstraints) @import("geometry.zig").PhysicalSize {
    return c.constrain(.{ .width = 1, .height = 1 });
}

fn noPaint(_: *RenderObject, _: *@import("canvas.zig").Canvas, _: @import("geometry.zig").PhysicalOffset) anyerror!void {}
