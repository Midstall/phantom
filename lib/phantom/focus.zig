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

test "focusNode jumps to a chosen node rather than the next one in the order" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var h2 = FocusHandlers{ .ctx = undefined };
    var h3 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    try m.order.append(gpa, &h3);
    m.focusNext(); // current is h1

    try std.testing.expect(m.focusNode(&h3));
    try std.testing.expect(m.current == &h3);
    // The jump must leave the traversal consistent: Tab from h3 wraps to h1.
    m.focusNext();
    try std.testing.expect(m.current == &h1);
}

test "focusNode tells the caller a node outside the order was not focused" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined };
    var stranger = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    m.focusNext();

    try std.testing.expect(!m.focusNode(&stranger));
    // An unmounted or unavailable target must not take the focus away from h1.
    try std.testing.expect(m.current == &h1);
}

test "focusNode announces the arrival to the node it moved the focus to" {
    const gpa = std.testing.allocator;
    const Watch = struct {
        var gained: bool = false;
        fn onChange(_: *anyopaque, focused: bool) void {
            if (focused) gained = true;
        }
    };
    Watch.gained = false;
    var dummy: u8 = 0;
    var h1 = FocusHandlers{ .ctx = &dummy };
    var h2 = FocusHandlers{ .ctx = &dummy, .on_focus_change = Watch.onChange };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext(); // current is h1

    try std.testing.expect(m.focusNode(&h2));
    // A button that draws a focus ring only learns it is focused from this call.
    try std.testing.expect(Watch.gained);
}

test "focusById reaches a node by name and reports the name back" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined, .id = "prompt" };
    var h2 = FocusHandlers{ .ctx = undefined, .id = "results" };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    try std.testing.expect(m.focusById("results"));
    try std.testing.expect(m.current == &h2);
    try std.testing.expectEqualStrings("results", m.focusedId().?);
}

test "focusById matches on the id text and not on the slice address" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined, .id = "prompt" };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);

    // A caller builds the id at runtime, so it is a different slice with the same
    // bytes. Comparing addresses would silently never match.
    var built: [6]u8 = "prompt".*;
    try std.testing.expect(m.focusById(&built));
    try std.testing.expect(m.current == &h1);
}

test "focusById leaves the focus where it is when no node carries the id" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined, .id = "prompt" };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);
    m.focusNext(); // current is h1

    try std.testing.expect(!m.focusById("missing"));
    try std.testing.expect(m.current == &h1);
    // A node with no id must not answer to an empty name either.
    try std.testing.expect(!m.focusById(""));
    try std.testing.expect(m.current == &h1);
}

test "focusById takes the first of two nodes that share an id" {
    const gpa = std.testing.allocator;
    var h1 = FocusHandlers{ .ctx = undefined, .id = "row" };
    var h2 = FocusHandlers{ .ctx = undefined, .id = "row" };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    try std.testing.expect(m.focusById("row"));
    try std.testing.expect(m.current == &h1);
}

test "currentNode hands back the render object under the focused node" {
    const gpa = std.testing.allocator;
    var ro = RenderObject{ .layoutFn = noLayout, .paintFn = noPaint };
    var h1 = FocusHandlers{ .ctx = undefined, .node = &ro };
    var h2 = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);
    try m.order.append(gpa, &h1);
    try m.order.append(gpa, &h2);

    try std.testing.expect(m.currentNode() == null); // nothing focused yet
    m.focusNext();
    try std.testing.expect(m.currentNode() == &ro);
    m.focusNext(); // h2 supplied no render object
    try std.testing.expect(m.currentNode() == null);
}

test "collect names the nearest focusable ancestor of every node" {
    const gpa = std.testing.allocator;
    var outer = FocusHandlers{ .ctx = undefined };
    var inner = FocusHandlers{ .ctx = undefined };
    var m = FocusManager{};
    defer m.deinit(gpa);

    // testTree chains the elements, so outer encloses inner.
    var tree = try testTree(gpa, &.{ &outer, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);

    try std.testing.expect(outer.parent == null);
    try std.testing.expect(inner.parent == &outer);
}

test "collect skips an unavailable node when it names an ancestor" {
    const gpa = std.testing.allocator;
    const Gone = struct {
        fn no(_: *anyopaque) bool {
            return false;
        }
    };
    var dummy: u8 = 0;
    var outer = FocusHandlers{ .ctx = &dummy };
    var middle = FocusHandlers{ .ctx = &dummy, .available = Gone.no };
    var inner = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &outer, &middle, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);

    // A disabled node is not in the order, so a key must not bubble into it. The
    // link has to skip past it to the nearest node the manager still holds.
    try std.testing.expectEqual(@as(usize, 2), m.order.items.len);
    try std.testing.expect(inner.parent == &outer);
}

test "a key the focused node refuses reaches its focusable ancestor" {
    const gpa = std.testing.allocator;
    const Ancestor = struct {
        var saw: ?input.Keysym = null;
        fn onKey(_: *anyopaque, ev: input.KeyEvent) bool {
            saw = ev.keysym;
            return true;
        }
    };
    const Picky = struct {
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            return false;
        }
    };
    Ancestor.saw = null;
    var dummy: u8 = 0;
    var outer = FocusHandlers{ .ctx = &dummy, .on_key = Ancestor.onKey };
    var inner = FocusHandlers{ .ctx = &dummy, .on_key = Picky.onKey };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &outer, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);
    try std.testing.expect(m.focusNode(&inner));

    // This is a text field inside a scroll view: the field ignores Page Down and
    // the view around it scrolls.
    try std.testing.expect(m.dispatch(.{ .keysym = .page_down }));
    try std.testing.expectEqual(@as(?input.Keysym, .page_down), Ancestor.saw);
    // Bubbling must not move the focus.
    try std.testing.expect(m.current == &inner);
}

test "a key the focused node uses never reaches its ancestor" {
    const gpa = std.testing.allocator;
    const Ancestor = struct {
        var fired = false;
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            fired = true;
            return true;
        }
    };
    const Greedy = struct {
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            return true;
        }
    };
    Ancestor.fired = false;
    var dummy: u8 = 0;
    var outer = FocusHandlers{ .ctx = &dummy, .on_key = Ancestor.onKey };
    var inner = FocusHandlers{ .ctx = &dummy, .on_key = Greedy.onKey };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &outer, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);
    try std.testing.expect(m.focusNode(&inner));

    try std.testing.expect(m.dispatch(.{ .keysym = .page_down }));
    try std.testing.expect(!Ancestor.fired);
}

test "Tab traverses instead of bubbling, so an ancestor cannot trap the user" {
    const gpa = std.testing.allocator;
    const Ancestor = struct {
        var fired = false;
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            fired = true;
            return true; // would swallow every key it is offered
        }
    };
    Ancestor.fired = false;
    var dummy: u8 = 0;
    var outer = FocusHandlers{ .ctx = &dummy, .on_key = Ancestor.onKey };
    var inner = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &outer, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);
    try std.testing.expect(m.focusNode(&inner));

    try std.testing.expect(m.dispatch(.{ .keysym = .tab }));
    try std.testing.expect(!Ancestor.fired);
    // Tab wrapped from the last node back to the first.
    try std.testing.expect(m.current == &outer);
}

test "bubbling stops at the first ancestor that uses the key" {
    const gpa = std.testing.allocator;
    const Log = struct {
        var order: [3]u8 = .{ 0, 0, 0 };
        var next: usize = 0;
        fn record(tag: u8, use: bool) bool {
            order[next] = tag;
            next += 1;
            return use;
        }
        fn top(_: *anyopaque, _: input.KeyEvent) bool {
            return record('t', true);
        }
        fn middle(_: *anyopaque, _: input.KeyEvent) bool {
            return record('m', true);
        }
        fn leaf(_: *anyopaque, _: input.KeyEvent) bool {
            return record('l', false);
        }
    };
    Log.next = 0;
    Log.order = .{ 0, 0, 0 };
    var dummy: u8 = 0;
    var top = FocusHandlers{ .ctx = &dummy, .on_key = Log.top };
    var middle = FocusHandlers{ .ctx = &dummy, .on_key = Log.middle };
    var leaf = FocusHandlers{ .ctx = &dummy, .on_key = Log.leaf };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &top, &middle, &leaf });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);
    try std.testing.expect(m.focusNode(&leaf));

    try std.testing.expect(m.dispatch(.{ .keysym = .page_down }));
    // Innermost first, and the outermost ancestor never runs.
    try std.testing.expectEqual(@as(usize, 2), Log.next);
    try std.testing.expectEqual(@as(u8, 'l'), Log.order[0]);
    try std.testing.expectEqual(@as(u8, 'm'), Log.order[1]);
}

test "forget cuts the parent link so a key cannot bubble into a freed ancestor" {
    const gpa = std.testing.allocator;
    const Ancestor = struct {
        var fired = false;
        fn onKey(_: *anyopaque, _: input.KeyEvent) bool {
            fired = true;
            return true;
        }
    };
    Ancestor.fired = false;
    var dummy: u8 = 0;
    var outer = FocusHandlers{ .ctx = &dummy, .on_key = Ancestor.onKey };
    var inner = FocusHandlers{ .ctx = &dummy };
    var m = FocusManager{};
    defer m.deinit(gpa);

    var tree = try testTree(gpa, &.{ &outer, &inner });
    defer tree.deinit(gpa);
    try m.collect(gpa, tree.root);
    try std.testing.expect(m.focusNode(&inner));

    // Element.deinit calls this just before the ancestor's render object is freed.
    m.forget(&outer);
    try std.testing.expect(inner.parent == null);
    try std.testing.expect(!m.dispatch(.{ .keysym = .page_down }));
    try std.testing.expect(!Ancestor.fired);
}

test "OwnedId keeps its own copy, so the caller's buffer can be reused" {
    const gpa = std.testing.allocator;
    var id = OwnedId{};
    defer id.deinit(gpa);

    var scratch: [6]u8 = "prompt".*;
    try id.set(gpa, &scratch);
    // A frame loop resets the arena a widget config was built in. Overwriting the
    // source stands in for that.
    @memset(&scratch, 'z');
    try std.testing.expectEqualStrings("prompt", id.text.?);
}

test "OwnedId reuses the copy when the id text has not changed" {
    const gpa = std.testing.allocator;
    var id = OwnedId{};
    defer id.deinit(gpa);

    try id.set(gpa, "prompt");
    const first = id.text.?.ptr;
    var same: [6]u8 = "prompt".*;
    try id.set(gpa, &same);
    // A settled tree rebuilds every frame, so an allocation per frame per node is
    // the difference between quiet and churning.
    try std.testing.expect(id.text.?.ptr == first);

    try id.set(gpa, "results");
    try std.testing.expect(id.text.?.ptr != first);
    try std.testing.expectEqualStrings("results", id.text.?);
}

test "OwnedId releases the copy when the id is taken away" {
    const gpa = std.testing.allocator;
    var id = OwnedId{};
    defer id.deinit(gpa);

    try id.set(gpa, "prompt");
    try id.set(gpa, null);
    // The allocator in this test reports a leak if the copy survived.
    try std.testing.expect(id.text == null);
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
    /// Returns true when the key was used. A key this handler refuses continues
    /// through the rest of `dispatch`, which ends at the focusable ancestors and the
    /// shortcut listeners.
    on_key: ?*const fn (ctx: *anyopaque, ev: input.KeyEvent) bool = null,
    on_focus_change: ?*const fn (ctx: *anyopaque, focused: bool) void = null,
    /// Returns false when this handler is temporarily unavailable, for example a
    /// disabled button, and must be skipped by `collect`. Null means always
    /// available. Checked fresh on every `collect`, which runs after every rebuild,
    /// so a widget that flips its own enabled state between rebuilds needs no extra
    /// bookkeeping: the next collect just sees the new answer. Shared by `order` and
    /// `listeners`, so a future disabled `TextField` uses the same field.
    available: ?*const fn (ctx: *anyopaque) bool = null,
    /// The name an application moves the focus to this node by. Null leaves the node
    /// reachable through Tab only. The slice must stay valid for as long as the
    /// handlers do, so a widget that takes an id from its config keeps a copy of it
    /// in `OwnedId`: a config is rebuilt from a scratch arena that the frame loop
    /// resets before the next key arrives.
    id: ?[]const u8 = null,
    /// The render object these handlers sit on. It turns the focused node into a
    /// rectangle, which is what `ScrollController.showChild` needs to bring the node
    /// into view. Null when the installing widget did not supply it.
    node: ?*RenderObject = null,
    /// The nearest focusable ancestor. Filled in by `collect` from the element tree,
    /// so a widget must never set it: an install that did would be overwritten by
    /// the next collect anyway. `dispatch` walks this chain to offer a refused key
    /// to what encloses the focused node.
    parent: ?*FocusHandlers = null,
};

/// A focus id that a render object owns. A widget config is rebuilt every frame,
/// usually into a scratch arena that the frame loop resets, so handlers that
/// borrowed the config's slice would read freed memory on the next key. The copy is
/// replaced only when the id text changes, which leaves a settled tree allocating
/// nothing per frame.
pub const OwnedId = struct {
    text: ?[]const u8 = null,

    pub fn set(self: *OwnedId, gpa: std.mem.Allocator, id: ?[]const u8) !void {
        const want = id orelse {
            self.deinit(gpa);
            return;
        };
        if (self.text) |have| {
            if (std.mem.eql(u8, have, want)) return;
        }
        // Copy before releasing the old text, so a failed allocation leaves the
        // node with the id it already answered to instead of no id at all.
        const copy = try gpa.dupe(u8, want);
        self.deinit(gpa);
        self.text = copy;
    }

    pub fn deinit(self: *OwnedId, gpa: std.mem.Allocator) void {
        if (self.text) |t| gpa.free(t);
        self.text = null;
    }
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
        try walk(gpa, root, &self.order, &self.listeners, null);
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

    /// `enclosing` is the nearest focusable ancestor found so far. Only a node that
    /// reaches `out` becomes an ancestor for the subtree below it, so every parent
    /// link points at a node the manager still holds, and `forget` has one list to
    /// clear a freed node out of.
    fn walk(
        gpa: std.mem.Allocator,
        el: *Element,
        out: *std.ArrayList(*FocusHandlers),
        listeners: *std.ArrayList(*FocusHandlers),
        enclosing: ?*FocusHandlers,
    ) !void {
        var inner = enclosing;
        if (el.render_object) |ro| {
            if (ro.focus) |h| {
                if (isAvailable(h)) {
                    h.parent = enclosing;
                    try out.append(gpa, h);
                    inner = h;
                }
            }
            if (ro.key_listener) |h| if (isAvailable(h)) try listeners.append(gpa, h);
        }
        if (el.child) |c| try walk(gpa, c, out, listeners, inner);
        for (el.children.items) |c| try walk(gpa, c, out, listeners, inner);
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

    /// Move the focus to one chosen node. Returns false when the node is not in the
    /// traversal order, which is how an unmounted or unavailable node looks from
    /// here, and leaves the focus where it was. Tab order position is the wrong way
    /// to name a target, so this is what a click on a text field and a "focus the
    /// search box" command both go through.
    pub fn focusNode(self: *FocusManager, h: *FocusHandlers) bool {
        if (self.indexOf(h) == null) return false;
        self.setCurrent(h);
        return true;
    }

    /// Move the focus to the node that carries `id`. Returns false when no available
    /// node carries it. An id an application repeats is a programmer error the
    /// manager cannot see, so the first match in tree order wins rather than the
    /// call failing: focusing the first of two search boxes is still better than
    /// focusing neither.
    pub fn focusById(self: *FocusManager, id: []const u8) bool {
        for (self.order.items) |h| {
            const have = h.id orelse continue;
            if (std.mem.eql(u8, have, id)) {
                self.setCurrent(h);
                return true;
            }
        }
        return false;
    }

    /// The id of the focused node. Null when nothing holds the focus or the node
    /// that does was given no id.
    pub fn focusedId(self: *const FocusManager) ?[]const u8 {
        const c = self.current orelse return null;
        return c.id;
    }

    /// The render object under the focused node, for a caller that needs its
    /// rectangle. Null when nothing holds the focus or the installing widget
    /// supplied no render object.
    pub fn currentNode(self: *const FocusManager) ?*RenderObject {
        const c = self.current orelse return null;
        return c.node;
    }

    /// Offer `ev` to each focusable ancestor of the focused node, innermost first.
    /// Returns true when one of them used it.
    ///
    /// The chain is bounded by the length of the traversal order, because `collect`
    /// only ever names an ancestor that is in that order and no node is its own
    /// ancestor. The bound costs one comparison and removes any chance that a
    /// corrupted link spins the key loop forever.
    fn bubble(self: *FocusManager, ev: input.KeyEvent) bool {
        const c = self.current orelse return false;
        var next = c.parent;
        var hops: usize = 0;
        while (next) |anc| : (next = anc.parent) {
            if (hops >= self.order.items.len) return false;
            hops += 1;
            if (anc.on_key) |f| {
                if (f(anc.ctx, ev)) return true;
            }
        }
        return false;
    }

    /// Route one key, in four stages, and return true when a stage used it.
    ///
    ///   1. The focused node, because an application must be able to take a key the
    ///      manager would otherwise spend: a text field needs Tab to insert a tab,
    ///      and a dialog needs Escape to close itself.
    ///   2. The traversal rules, Tab and Escape.
    ///   3. The focusable ancestors of the focused node, innermost first. A key the
    ///      focused node refused usually belongs to what encloses it: the page keys
    ///      inside a text field belong to the scroll view around it, which is
    ///      otherwise unreachable while the field holds the focus.
    ///   4. The shortcut listeners, in tree order.
    ///
    /// The ancestors come after the traversal rules and not before, so that no
    /// ancestor can take Tab away from a user who is trying to leave. The cost is
    /// that an ancestor cannot define its own meaning for Tab or Escape. Escape is
    /// still swallowed by rule 2 whenever a node holds the focus, so an ancestor and
    /// a listener only see Escape when nothing is focused.
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

        if (self.bubble(ev)) return true;

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
        // A child of `h` outlives it whenever a subtree is rebuilt from the middle,
        // so the parent links have to be cut here as well. Without this the next key
        // would bubble from the surviving child into the freed ancestor.
        for (self.order.items) |item| {
            if (item.parent == h) item.parent = null;
        }
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
