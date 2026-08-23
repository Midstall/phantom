const std = @import("std");
const render_object = @import("render_object.zig");
const layout = @import("layout.zig");
const geom = @import("geometry.zig");
const canvas_mod = @import("canvas.zig");
const BuildContext = @import("BuildContext.zig");
const BuildOwner = @import("BuildOwner.zig");
const FaultSink = @import("FaultSink.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const phantom = @import("../phantom.zig");

/// A stable, unique id per type: the address of a per-type static byte. The anonymous
/// struct closes over @typeName(T) so it is a distinct type per T, giving a distinct b.
pub fn typeId(comptime T: type) usize {
    return @intFromPtr(&struct {
        const marker: *const anyopaque = @typeName(T).ptr;
        var b: u8 = 0;
    }.b);
}

/// Find the nearest InheritedWidget of type T at or above `start` (walk the parent
/// chain, inclusive of start). Returns a borrowed `*const T`, or null if none.
pub fn inheritedOf(start: ?*Element, comptime T: type) ?*const T {
    const id = typeId(T);
    var e: ?*Element = start;
    while (e) |el| : (e = el.parent) {
        if (el.inherited_id == id) {
            if (el.inherited_data) |p| return @ptrCast(@alignCast(p));
        }
    }
    return null;
}

/// Depth of a would-be child of `parent`. Root is depth 0. Used to order dirty
/// rebuilds parent-first.
pub fn depthOf(parent: ?*Element) u32 {
    return if (parent) |p| p.depth + 1 else 0;
}

/// The framework-managed base every State struct must embed as a field named `base`.
/// Carries the back-pointer to the mounted Element so setState can schedule a rebuild,
/// and exposes the owner's resources so lifecycle methods (which take no BuildContext)
/// can allocate and touch IO.
pub const StateBase = struct {
    element: *Element = undefined,

    pub fn gpa(self: *const StateBase) std.mem.Allocator {
        return self.element.owner.gpa;
    }
    pub fn io(self: *const StateBase) std.Io {
        return self.element.owner.io;
    }
    pub fn sink(self: *const StateBase) *FaultSink {
        return self.element.owner.sink;
    }
    pub fn scheduler(self: *const StateBase) *Scheduler {
        return &self.element.owner.scheduler;
    }
};

/// Type-erased hooks the framework calls on a mounted State object.
pub const StateVTable = struct {
    build: *const fn (state: *anyopaque, bctx: *BuildContext) anyerror!Widget,
    deinit: *const fn (state: *anyopaque, gpa: std.mem.Allocator) void,
};

/// A persistent, mutable node in the element tree. Owned by `owner.gpa` and freed on
/// unmount. Render-object elements set `render_object`; component (stateful) elements
/// leave it null and expose their subtree root render object via `renderObject()`.
pub const Element = struct {
    owner: *BuildOwner,
    parent: ?*Element = null,
    /// The widget type identity (each widget type has exactly one static vtable), used
    /// by canUpdate to decide update-in-place vs replace.
    vtable: *const Widget.VTable,
    type_name: []const u8,
    render_object: ?*render_object.RenderObject = null,
    /// Single child this slice. Multi-child (Column/Row) is deferred with the same TODO
    /// as the renderer slice.
    child: ?*Element = null,
    /// Multi-child slot for multi-child widgets (Flex). Empty for single-child
    /// widgets, which keep using `child` above. Reconciled by updateChildren.
    children: std.ArrayList(*Element) = .empty,
    state: ?*anyopaque = null,
    state_vtable: ?*const StateVTable = null,
    dirty: bool = false,
    depth: u32 = 0,
    /// Number of times this element has rebuilt. Test harness reads it to prove
    /// reconciliation granularity (an untouched ancestor's count does not move).
    build_count: u32 = 0,
    /// InheritedWidget slot: an InheritedWidget's element sets these so descendants can
    /// find it by type. `inherited_id` is a per-type id (typeId(T)); `inherited_data`
    /// is a `*const T` borrowed for the frame.
    inherited_id: ?usize = null,
    inherited_data: ?*const anyopaque = null,

    /// The render object representing this element's subtree root: its own, else the
    /// child's (walk down to the nearest render object).
    pub fn renderObject(self: *Element) ?*render_object.RenderObject {
        if (self.render_object) |ro| return ro;
        if (self.child) |c| return c.renderObject();
        return null;
    }

    /// Recursively tear down: child first, then this state object, then this own render
    /// object, then the element itself. A render-object element's own render object is
    /// freed here. Its child's render object is owned by the child element and freed by
    /// that child's deinit, so no double free.
    pub fn deinit(self: *Element, gpa: std.mem.Allocator) void {
        self.owner.removeFromDirty(self);
        self.owner.forgetPointer(self);
        if (self.render_object) |ro| {
            if (ro.focus) |h| self.owner.forgetFocus(h);
            if (ro.key_listener) |h| self.owner.forgetFocus(h);
        }
        for (self.children.items) |c| c.deinit(gpa);
        self.children.deinit(gpa);
        if (self.child) |c| c.deinit(gpa);
        if (self.state_vtable) |sv| sv.deinit(self.state.?, gpa);
        if (self.render_object) |ro| ro.destroy(gpa);
        gpa.destroy(self);
    }

    /// Reconcile a single child slot against a new widget config. Mirrors Flutter's
    /// updateChild:
    ///   new == null      -> unmount old (if any), return null
    ///   old == null      -> mount new, return fresh element
    ///   same vtable      -> update old in place, return old
    ///   different vtable  -> unmount old, mount new, return fresh
    pub fn updateChild(self: *Element, old: ?*Element, new_widget: ?Widget, bctx: *BuildContext) anyerror!?*Element {
        const gpa = bctx.owner.gpa;
        if (new_widget == null) {
            if (old) |o| o.deinit(gpa);
            return null;
        }
        const nw = new_widget.?;
        if (old) |o| {
            if (nw.canUpdate(o)) {
                try nw.update(o, bctx);
                return o;
            }
            o.deinit(gpa);
        }
        return try nw.mount(bctx, self);
    }

    /// Positionally reconcile `self.children` against `new_widgets` (no keys):
    /// unmount surplus tail, reconcile the overlapping prefix in place via
    /// updateChild, mount and append the new tail. Each mounted child's parent is self.
    pub fn updateChildren(self: *Element, new_widgets: []const Widget, bctx: *BuildContext) anyerror!void {
        const gpa = bctx.owner.gpa;
        while (self.children.items.len > new_widgets.len) {
            const old = self.children.pop().?;
            old.deinit(gpa);
        }
        for (new_widgets, 0..) |w, i| {
            if (i < self.children.items.len) {
                const updated = try self.updateChild(self.children.items[i], w, bctx);
                self.children.items[i] = updated.?;
            } else {
                const mounted = try w.mount(bctx, self);
                try self.children.append(gpa, mounted);
            }
        }
    }

    /// Rebuild a component (stateful) element from its State. Infallible: a build error
    /// or a child reconcile error is recorded as a fault and an ErrorBox is substituted
    /// so the rest of the frame survives. No-op for render-object elements.
    pub fn rebuild(self: *Element, bctx: *BuildContext) void {
        const sv = self.state_vtable orelse return;
        self.build_count += 1;
        const prev_element = bctx.element;
        bctx.element = self;
        defer bctx.element = prev_element;
        const built = sv.build(self.state.?, bctx) catch |e| {
            bctx.owner.sink.report(.state_update, @errorName(e));
            const eb = phantom.ErrorBox{};
            self.child = self.updateChild(self.child, eb.widget(), bctx) catch null;
            self.reattachAfterChildChange();
            return;
        };
        self.child = self.updateChild(self.child, built, bctx) catch |e| {
            bctx.owner.sink.report(.build_failed, @errorName(e));
            return;
        };
        self.reattachAfterChildChange();
    }

    /// After a component element's child subtree may have changed render object identity,
    /// re-point the nearest ancestor render object at this subtree's render object so the
    /// render object tree stays wired. Idempotent when nothing changed (the counter case).
    pub fn reattachAfterChildChange(self: *Element) void {
        // Single-child assumption: `anc.child` is the one spine leading to `self`. When
        // multi-child (Column/Row) lands, this up-walk must be revisited.
        var a: ?*Element = self.parent;
        while (a) |anc| : (a = anc.parent) {
            if (anc.render_object) |ro| {
                if (anc.child) |ac| ro.adoptChild(ac.renderObject());
                return;
            }
        }
    }
};

/// Immutable widget configuration. `ptr` borrows the caller's widget value (usually a
/// stack local or a scratch-arena copy) and is only valid through mount/update, which
/// copy everything they keep into the gpa-owned element tree. Do not stash a Widget and
/// use it across build passes.
pub const Widget = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mount: *const fn (ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element,
        update: *const fn (ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void,
    };

    pub fn mount(self: Widget, bctx: *BuildContext, parent: ?*Element) !*Element {
        return self.vtable.mount(self.ptr, bctx, parent);
    }
    pub fn update(self: Widget, el: *Element, bctx: *BuildContext) !void {
        return self.vtable.update(self.ptr, el, bctx);
    }
    /// True when `el` was produced by this same widget type (vtable identity), so it can
    /// be updated in place rather than replaced.
    pub fn canUpdate(self: Widget, el: *const Element) bool {
        return el.vtable == self.vtable;
    }
};

const Dummy = struct {
    ro: render_object.RenderObject = .{ .layoutFn = lf, .paintFn = pf },
    fn lf(base: *render_object.RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        _ = base;
        return c.constrain(.{ .width = 1, .height = 1 });
    }
    fn pf(_: *render_object.RenderObject, _: *canvas_mod.Canvas, _: geom.PhysicalOffset) anyerror!void {}
    const vtable = Widget.VTable{ .mount = mount, .update = update };
    fn widget(self: *const Dummy) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Dummy = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(render_object.RenderObject);
        ro.* = self.ro;
        ro.destroyFn = destroyRo;
        const el = try gpa.create(Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Dummy), .render_object = ro, .depth = depthOf(parent) };
        return el;
    }
    fn update(_: *const anyopaque, _: *Element, _: *BuildContext) anyerror!void {}
    fn destroyRo(ro: *render_object.RenderObject, gpa: std.mem.Allocator) void {
        gpa.destroy(ro);
    }
};

test "StateBase accessors read gpa/io/sink through the element's owner" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    // Placeholder vtable: this test only reads through the element's owner, so mount
    // and update are never dispatched.
    const vt = Widget.VTable{ .mount = undefined, .update = undefined };
    var el = Element{ .owner = &owner, .vtable = &vt, .type_name = "test" };
    var base = StateBase{ .element = &el };
    try std.testing.expect(std.meta.eql(owner.gpa, base.gpa()));
    try std.testing.expect(base.sink() == &sink);
    // default io is std.Io.failing
    try std.testing.expect(base.io().vtable == std.Io.failing.vtable);
}

test "StateBase.scheduler reaches the owner's instance, not a copy" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    const vt = Widget.VTable{ .mount = undefined, .update = undefined };
    var el = Element{ .owner = &owner, .vtable = &vt, .type_name = "leaf" };
    const base = StateBase{ .element = &el };

    // Registering through the accessor must be visible on the owner, or a
    // widget's timer would be dropped on the floor.
    var counter: u32 = 0;
    _ = try base.scheduler().everyFrame(std.testing.allocator, &counter, struct {
        fn f(ctx: *anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.f);
    owner.scheduler.tick(1);
    try std.testing.expectEqual(@as(u32, 1), counter);
}

test "mount builds a gpa-owned Element tagged with its widget type name" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var d = Dummy{};
    const el = try d.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(@typeName(Dummy), el.type_name);
    try std.testing.expect(el.depth == 0);
}

test "inheritedOf walks the parent chain and finds the nearest typed slot" {
    const Data = struct { v: u32 };
    var d_outer = Data{ .v = 1 };
    var d_inner = Data{ .v = 2 };
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    const vt = Widget.VTable{ .mount = undefined, .update = undefined };
    // chain: outer(Data=1) -> mid(Data=2) -> leaf
    var outer = Element{ .owner = &owner, .vtable = &vt, .type_name = "outer", .inherited_id = typeId(Data), .inherited_data = &d_outer };
    var mid = Element{ .owner = &owner, .vtable = &vt, .type_name = "mid", .parent = &outer, .inherited_id = typeId(Data), .inherited_data = &d_inner };
    var leaf = Element{ .owner = &owner, .vtable = &vt, .type_name = "leaf", .parent = &mid };
    // from leaf: nearest Data is mid (v=2)
    try std.testing.expectEqual(@as(u32, 2), inheritedOf(&leaf, Data).?.v);
    // from outer: outer itself (inclusive), v=1
    try std.testing.expectEqual(@as(u32, 1), inheritedOf(&outer, Data).?.v);
    // a different type is not found
    const Other = struct { x: u8 };
    try std.testing.expect(inheritedOf(&leaf, Other) == null);
    // null start
    try std.testing.expect(inheritedOf(null, Data) == null);
    // typeId distinctness: two different types must not share an id
    try std.testing.expect(typeId(Data) != typeId(Other));
}

test "updateChildren positionally reconciles: grow, shrink, type-change in place" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };
    const vt = Widget.VTable{ .mount = undefined, .update = undefined };
    var parent = Element{ .owner = &owner, .vtable = &vt, .type_name = "parent" };
    defer {
        for (parent.children.items) |c| c.deinit(gpa);
        parent.children.deinit(gpa);
    }

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    // grow to 2
    try parent.updateChildren(&.{ box.widget(), box.widget() }, &bctx);
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expect(parent.children.items[0].parent == &parent);
    const kept0 = parent.children.items[0];
    // same types -> update in place (identity preserved)
    try parent.updateChildren(&.{ box.widget(), box.widget() }, &bctx);
    try std.testing.expectEqual(@as(usize, 2), parent.children.items.len);
    try std.testing.expect(parent.children.items[0] == kept0);
    // grow to 3
    try parent.updateChildren(&.{ box.widget(), box.widget(), box.widget() }, &bctx);
    try std.testing.expectEqual(@as(usize, 3), parent.children.items.len);
    // shrink to 1 (tail unmounts, leak-clean)
    try parent.updateChildren(&.{box.widget()}, &bctx);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    // type-change at index 0 -> remount (identity changes)
    const eb = phantom.ErrorBox{};
    try parent.updateChildren(&.{eb.widget()}, &bctx);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    // identity changed (the ColoredBox element was unmounted and an ErrorBox mounted)
    try std.testing.expect(parent.children.items[0] != kept0);
}

test "updateChild updates same-type in place and replaces on type change" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // Build a tiny host element to hang a child slot on.
    var d = Dummy{};
    const host = try d.widget().mount(&bctx, null);
    defer host.deinit(std.testing.allocator);

    var box_a = phantom.ColoredBox{ .color = geom.Color.rgb(1, 0, 0), .radius = 2 };
    const c1 = try host.updateChild(null, box_a.widget(), &bctx);
    try std.testing.expect(c1 != null);

    // same type -> update in place, same element pointer.
    var box_b = phantom.ColoredBox{ .color = geom.Color.rgb(0, 1, 0), .radius = 9 };
    const c2 = try host.updateChild(c1, box_b.widget(), &bctx);
    try std.testing.expect(c2 == c1);

    // different type -> replaced, different element pointer.
    var eb = phantom.ErrorBox{};
    const c3 = try host.updateChild(c2, eb.widget(), &bctx);
    try std.testing.expect(c3 != c2);
    try std.testing.expectEqualStrings(@typeName(phantom.ErrorBox), c3.?.type_name);
    c3.?.deinit(std.testing.allocator);
}
