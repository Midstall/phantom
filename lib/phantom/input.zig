const geom = @import("geometry.zig");
const render_object = @import("render_object.zig");
const pointer = @import("pointer.zig");
const widget = @import("widget.zig");

const Element = widget.Element;

/// Walk the element tree (pre-order) and return the DEEPEST render object's
/// pointer handlers whose absolute bounds [origin, origin+size] contain the
/// point. Deepest means a child listener wins over a parent listener. Overlapping
/// siblings are not disambiguated (z-order deferred); the last match wins.
pub fn hitTest(root: *Element, point: geom.PhysicalOffset) ?*pointer.PointerHandlers {
    var found: ?*pointer.PointerHandlers = null;
    walk(root, point, &found);
    return found;
}

fn walk(el: *Element, point: geom.PhysicalOffset, found: *?*pointer.PointerHandlers) void {
    if (el.render_object) |ro| {
        if (ro.pointer) |h| {
            if (contains(ro.origin, ro.size, point)) found.* = h;
        }
    }
    if (el.child) |c| walk(c, point, found);
    for (el.children.items) |c| walk(c, point, found);
}

fn contains(origin: geom.PhysicalOffset, size: geom.PhysicalSize, p: geom.PhysicalOffset) bool {
    return p.x >= origin.x and p.x < origin.x + size.width and
        p.y >= origin.y and p.y < origin.y + size.height;
}

/// Walk the element tree (pre-order) and return the DEEPEST render object's pointer
/// handlers whose on_scroll is set AND whose absolute bounds contain the point.
/// This finds the innermost scrollable container (skips non-scrollable handlers).
pub fn hitTestScroll(root: *Element, point: geom.PhysicalOffset) ?*pointer.PointerHandlers {
    var found: ?*pointer.PointerHandlers = null;
    walkScroll(root, point, &found);
    return found;
}

fn walkScroll(el: *Element, point: geom.PhysicalOffset, found: *?*pointer.PointerHandlers) void {
    if (el.render_object) |ro| {
        if (ro.pointer) |h| {
            if (h.on_scroll != null and contains(ro.origin, ro.size, point)) found.* = h;
        }
    }
    if (el.child) |c| walkScroll(c, point, found);
    for (el.children.items) |c| walkScroll(c, point, found);
}

/// A key, identified by its X11 keysym. The values match the ones Midstall's
/// `xkbcommon.zig` produces, so the Wayland path can map a keycode to a keysym and
/// hand the number over with no translation table between them. The terminal path
/// fills the same type from escape sequences. One key type serves both, which is
/// what the approved compositor design requires.
///
/// The enum is not exhaustive, because a printable key carries a unicode keysym:
/// a codepoint from 0x20 to 0x7E or 0xA0 to 0xFF is its own value, and anything
/// above 0xFF is the codepoint plus 0x01000000. That is the X11 rule and it is what
/// `Keysym.fromCodepoint` applies.
pub const Keysym = enum(u32) {
    no_symbol = 0,

    backspace = 0xFF08,
    tab = 0xFF09,
    enter = 0xFF0D,
    escape = 0xFF1B,
    home = 0xFF50,
    left = 0xFF51,
    up = 0xFF52,
    right = 0xFF53,
    down = 0xFF54,
    page_up = 0xFF55,
    page_down = 0xFF56,
    end = 0xFF57,
    insert = 0xFF63,
    f1 = 0xFFBE,
    f2 = 0xFFBF,
    f3 = 0xFFC0,
    f4 = 0xFFC1,
    f5 = 0xFFC2,
    f6 = 0xFFC3,
    f7 = 0xFFC4,
    f8 = 0xFFC5,
    f9 = 0xFFC6,
    f10 = 0xFFC7,
    f11 = 0xFFC8,
    f12 = 0xFFC9,
    delete = 0xFFFF,
    /// A bare modifier key held on its own. The terminal path only reports these
    /// when the kitty keyboard protocol's "report events" flag is on, which sends a
    /// key event for holding shift, ctrl, alt or super, not only for shortcuts that
    /// use them. A compositor path reports the same keys, so they need a real X11
    /// keysym like everything else here and not a terminal-only stand-in.
    shift_l = 0xFFE1,
    shift_r = 0xFFE2,
    control_l = 0xFFE3,
    control_r = 0xFFE4,
    alt_l = 0xFFE9,
    alt_r = 0xFFEA,
    super_l = 0xFFEB,
    super_r = 0xFFEC,
    _,

    pub fn fromCodepoint(cp: u21) Keysym {
        if ((cp >= 0x20 and cp <= 0x7E) or (cp >= 0xA0 and cp <= 0xFF)) {
            return @enumFromInt(@as(u32, cp));
        }
        if (cp >= 0x100 and cp <= 0x10FFFF) return @enumFromInt(@as(u32, cp) + 0x01000000);
        return .no_symbol;
    }

    /// The codepoint a printable keysym produces, or null for a named key.
    pub fn toCodepoint(self: Keysym) ?u21 {
        const v = @intFromEnum(self);
        if ((v >= 0x20 and v <= 0x7E) or (v >= 0xA0 and v <= 0xFF)) return @intCast(v);
        if (v >= 0x01000100 and v <= 0x0110FFFF) return @intCast(v - 0x01000000);
        return null;
    }
};

pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn none(self: Mods) bool {
        return !self.shift and !self.ctrl and !self.alt and !self.super;
    }
};

pub const KeyAction = enum { press, repeat, release };

pub const KeyEvent = struct {
    keysym: Keysym,
    /// The text this key produces, or null when it produces none. A text field
    /// inserts this and never reads the keysym. The slice borrows decoder storage
    /// and is valid for the callback only, which is the rule `TextRun.text` follows.
    text: ?[]const u8 = null,
    mods: Mods = .{},
    action: KeyAction = .press,
};

/// Routes pointer events into the tree. down records the hit handler as the
/// pressed target and delivers on_down; up delivers on_up to the SAME pressed
/// target (passing the up position so a GestureDetector can decide tap-vs-cancel
/// by its own bounds), then clears pressed. move delivers to the hit handler.
pub const Dispatcher = struct {
    pressed: ?*pointer.PointerHandlers = null,
    hovered: ?*pointer.PointerHandlers = null,

    pub fn down(self: *Dispatcher, root: *Element, point: geom.PhysicalOffset) void {
        const h = hitTest(root, point);
        self.pressed = h;
        if (h) |hd| if (hd.on_down) |f| f(hd.ctx, .{ .position = point, .phase = .down });
    }
    pub fn up(self: *Dispatcher, root: *Element, point: geom.PhysicalOffset) void {
        if (self.pressed) |hd| {
            if (hd.on_up) |f| f(hd.ctx, .{ .position = point, .phase = .up });
        }
        self.pressed = null;
        _ = root;
    }
    pub fn move(self: *Dispatcher, root: *Element, point: geom.PhysicalOffset) void {
        const h = hitTest(root, point);
        if (h != self.hovered) {
            if (self.hovered) |old| if (old.on_leave) |f| f(old.ctx, .{ .position = point, .phase = .leave });
            if (h) |new| if (new.on_enter) |f| f(new.ctx, .{ .position = point, .phase = .enter });
            self.hovered = h;
        }
        if (h) |hd| if (hd.on_move) |f| f(hd.ctx, .{ .position = point, .phase = .move });
    }
    pub fn clearHover(self: *Dispatcher, point: geom.PhysicalOffset) void {
        if (self.hovered) |old| if (old.on_leave) |f| f(old.ctx, .{ .position = point, .phase = .leave });
        self.hovered = null;
    }

    /// Drop `h` from the hovered/pressed slots if present, WITHOUT firing any
    /// callback (the handlers may be mid-teardown). Called by Element.deinit (via
    /// BuildOwner.forgetPointer) when a render object carrying these handlers is
    /// freed, so a later move/up can never dereference the freed handlers.
    pub fn forget(self: *Dispatcher, h: *pointer.PointerHandlers) void {
        if (self.hovered == h) self.hovered = null;
        if (self.pressed == h) self.pressed = null;
    }

    /// Deliver a scroll delta to the innermost scrollable container whose bounds
    /// contain the given point. Does nothing if no scrollable is under the point.
    pub fn scroll(self: *Dispatcher, root: *Element, point: geom.PhysicalOffset, dx: f32, dy: f32) void {
        _ = self;
        if (hitTestScroll(root, point)) |h| if (h.on_scroll) |f| f(h.ctx, dx, dy);
    }
};

const std = @import("std");
const RenderObject = render_object.RenderObject;
const BuildOwner = @import("BuildOwner.zig");
const FaultSink = @import("FaultSink.zig");
const layout = @import("layout.zig");
const Canvas = @import("canvas.zig").Canvas;

// A test render object with a fixed size that carries pointer handlers.
const HitBox = struct {
    base: RenderObject,
    handlers: pointer.PointerHandlers,
    w: f32,
    h: f32,
    fn lf(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *HitBox = @fieldParentPtr("base", base);
        return c.constrain(.{ .width = self.w, .height = self.h });
    }
    fn pf(_: *RenderObject, _: *Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn make(w: f32, h: f32) HitBox {
        return .{ .base = .{ .layoutFn = lf, .paintFn = pf }, .handlers = .{ .ctx = undefined }, .w = w, .h = h };
    }
};

test "hitTest returns the deepest handler whose bounds contain the point; Dispatcher tracks pressed" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    // Build two elements: a parent element whose render object is a HitBox at
    // (0,0) size 100x100, and a child element whose render object is a smaller
    // HitBox. Both carry handlers so we can prove "deepest wins".
    var outer_ro = HitBox.make(100, 100);
    outer_ro.base.pointer = &outer_ro.handlers;
    var inner_ro = HitBox.make(40, 40);
    inner_ro.base.pointer = &inner_ro.handlers;
    const vt = widget.Widget.VTable{ .mount = undefined, .update = undefined };
    var child = Element{ .owner = &owner, .vtable = &vt, .type_name = "child", .render_object = &inner_ro.base };
    var parent = Element{ .owner = &owner, .vtable = &vt, .type_name = "parent", .render_object = &outer_ro.base, .child = &child };
    // Lay out + set absolute origins (as paint would): outer at (0,0), inner at (30,30).
    _ = outer_ro.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));
    outer_ro.base.origin = .{ .x = 0, .y = 0 };
    _ = inner_ro.base.layout(layout.BoxConstraints.tight(.{ .width = 40, .height = 40 }));
    inner_ro.base.origin = .{ .x = 30, .y = 30 };

    // Point inside inner (deepest) -> inner handlers.
    try std.testing.expect(hitTest(&parent, .{ .x = 40, .y = 40 }) == &inner_ro.handlers);
    // Point inside outer but outside inner -> outer handlers.
    try std.testing.expect(hitTest(&parent, .{ .x = 5, .y = 5 }) == &outer_ro.handlers);
    // Point outside both -> null.
    try std.testing.expect(hitTest(&parent, .{ .x = 200, .y = 200 }) == null);

    // Dispatcher: down records pressed + delivers on_down; up delivers on_up to
    // the SAME pressed target even when the up point is elsewhere (pointer
    // capture). hits[0] counts downs, hits[1] counts ups.
    var hits = [2]u32{ 0, 0 };
    inner_ro.handlers = .{ .ctx = &hits, .on_down = struct {
        fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
            const h: *[2]u32 = @ptrCast(@alignCast(ctx));
            h[0] += 1;
        }
    }.f, .on_up = struct {
        fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
            const h: *[2]u32 = @ptrCast(@alignCast(ctx));
            h[1] += 1;
        }
    }.f };
    inner_ro.base.pointer = &inner_ro.handlers;
    var d = Dispatcher{};
    d.down(&parent, .{ .x = 40, .y = 40 });
    try std.testing.expect(d.pressed == &inner_ro.handlers);
    try std.testing.expectEqual(@as(u32, 1), hits[0]);
    // Up OUTSIDE inner's bounds: capture still delivers on_up to the pressed target.
    d.up(&parent, .{ .x = 200, .y = 200 });
    try std.testing.expect(d.pressed == null);
    try std.testing.expectEqual(@as(u32, 1), hits[1]);
}

test "Dispatcher.move fires enter/leave on handler transitions and clearHover fires leave" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();

    // Box A: x=[0,50), y=[0,50)
    var box_a = HitBox.make(50, 50);
    // Box B: x=[100,150), y=[0,50) -- non-overlapping with A
    var box_b = HitBox.make(50, 50);

    // Counters: [enter, leave] per box
    var counters_a = [2]u32{ 0, 0 };
    var counters_b = [2]u32{ 0, 0 };

    box_a.handlers = .{
        .ctx = &counters_a,
        .on_enter = struct {
            fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
                const c: *[2]u32 = @ptrCast(@alignCast(ctx));
                c[0] += 1;
            }
        }.f,
        .on_leave = struct {
            fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
                const c: *[2]u32 = @ptrCast(@alignCast(ctx));
                c[1] += 1;
            }
        }.f,
    };
    box_a.base.pointer = &box_a.handlers;

    box_b.handlers = .{
        .ctx = &counters_b,
        .on_enter = struct {
            fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
                const c: *[2]u32 = @ptrCast(@alignCast(ctx));
                c[0] += 1;
            }
        }.f,
        .on_leave = struct {
            fn f(ctx: *anyopaque, _: pointer.PointerEvent) void {
                const c: *[2]u32 = @ptrCast(@alignCast(ctx));
                c[1] += 1;
            }
        }.f,
    };
    box_b.base.pointer = &box_b.handlers;

    const vt = widget.Widget.VTable{ .mount = undefined, .update = undefined };
    var el_a = Element{ .owner = &owner, .vtable = &vt, .type_name = "a", .render_object = &box_a.base };
    var el_b = Element{ .owner = &owner, .vtable = &vt, .type_name = "b", .render_object = &box_b.base };
    var root_el = Element{ .owner = &owner, .vtable = &vt, .type_name = "root" };

    _ = box_a.base.layout(layout.BoxConstraints.tight(.{ .width = 50, .height = 50 }));
    box_a.base.origin = .{ .x = 0, .y = 0 };
    _ = box_b.base.layout(layout.BoxConstraints.tight(.{ .width = 50, .height = 50 }));
    box_b.base.origin = .{ .x = 100, .y = 0 };

    // Wire el_a and el_b as children of root_el
    try root_el.children.append(gpa, &el_a);
    try root_el.children.append(gpa, &el_b);

    defer root_el.children.deinit(gpa);

    var d = Dispatcher{};

    // Move into box A: A.enter fires once, no leave
    d.move(&root_el, .{ .x = 25, .y = 25 });
    try std.testing.expectEqual(@as(u32, 1), counters_a[0]); // A enter
    try std.testing.expectEqual(@as(u32, 0), counters_a[1]); // A leave
    try std.testing.expect(d.hovered == &box_a.handlers);

    // Move within A: no new enter/leave
    d.move(&root_el, .{ .x = 10, .y = 10 });
    try std.testing.expectEqual(@as(u32, 1), counters_a[0]); // still 1
    try std.testing.expectEqual(@as(u32, 0), counters_a[1]); // still 0

    // Move into box B: A.leave + B.enter
    d.move(&root_el, .{ .x = 125, .y = 25 });
    try std.testing.expectEqual(@as(u32, 1), counters_a[1]); // A leave fired
    try std.testing.expectEqual(@as(u32, 1), counters_b[0]); // B enter fired
    try std.testing.expect(d.hovered == &box_b.handlers);

    // Move outside both: B.leave, hovered == null
    d.move(&root_el, .{ .x = 300, .y = 300 });
    try std.testing.expectEqual(@as(u32, 1), counters_b[1]); // B leave fired
    try std.testing.expect(d.hovered == null);

    // Move into A again then clearHover: A.leave fires, hovered becomes null
    d.move(&root_el, .{ .x = 25, .y = 25 });
    try std.testing.expectEqual(@as(u32, 2), counters_a[0]); // A enter again
    d.clearHover(.{ .x = 25, .y = 25 });
    try std.testing.expectEqual(@as(u32, 2), counters_a[1]); // A leave via clearHover
    try std.testing.expect(d.hovered == null);
}

test "Dispatcher.forget drops only the matching hovered/pressed slots, fires nothing" {
    var h1 = pointer.PointerHandlers{ .ctx = undefined };
    var h2 = pointer.PointerHandlers{ .ctx = undefined };
    var d = Dispatcher{ .hovered = &h1, .pressed = &h2 };
    d.forget(&h1);
    try std.testing.expect(d.hovered == null);
    try std.testing.expect(d.pressed == &h2); // unrelated slot untouched
    d.forget(&h2);
    try std.testing.expect(d.pressed == null);
    // Forgetting an unknown handler is a no-op.
    var h3 = pointer.PointerHandlers{ .ctx = undefined };
    d.hovered = &h1;
    d.forget(&h3);
    try std.testing.expect(d.hovered == &h1);
}

test "hitTestScroll returns the deepest on_scroll handler; Dispatcher.scroll fires it with correct deltas" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();

    // Parent HitBox: 100x100 at (0,0), HAS on_scroll.
    var parent_ro = HitBox.make(100, 100);
    // Child HitBox: 40x40 at (30,30), has on_down but NO on_scroll.
    var child_ro = HitBox.make(40, 40);

    var delta = [2]f32{ 0, 0 };
    parent_ro.handlers = .{
        .ctx = &delta,
        .on_scroll = struct {
            fn f(ctx: *anyopaque, dx: f32, dy: f32) void {
                const d: *[2]f32 = @ptrCast(@alignCast(ctx));
                d[0] = dx;
                d[1] = dy;
            }
        }.f,
    };
    parent_ro.base.pointer = &parent_ro.handlers;

    child_ro.handlers = .{
        .ctx = undefined,
        .on_down = struct {
            fn f(_: *anyopaque, _: pointer.PointerEvent) void {}
        }.f,
    };
    child_ro.base.pointer = &child_ro.handlers;

    const vt = widget.Widget.VTable{ .mount = undefined, .update = undefined };
    var child_el = Element{ .owner = &owner, .vtable = &vt, .type_name = "child", .render_object = &child_ro.base };
    var parent_el = Element{ .owner = &owner, .vtable = &vt, .type_name = "parent", .render_object = &parent_ro.base, .child = &child_el };

    _ = parent_ro.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 100 }));
    parent_ro.base.origin = .{ .x = 0, .y = 0 };
    _ = child_ro.base.layout(layout.BoxConstraints.tight(.{ .width = 40, .height = 40 }));
    child_ro.base.origin = .{ .x = 30, .y = 30 };

    // Point inside both parent and child: hitTestScroll returns PARENT (child has no on_scroll).
    const found = hitTestScroll(&parent_el, .{ .x = 40, .y = 40 });
    try std.testing.expect(found == &parent_ro.handlers);

    // Point inside only parent (outside child): also returns parent.
    try std.testing.expect(hitTestScroll(&parent_el, .{ .x = 5, .y = 5 }) == &parent_ro.handlers);

    // Point outside both: returns null.
    try std.testing.expect(hitTestScroll(&parent_el, .{ .x = 200, .y = 200 }) == null);

    // Dispatcher.scroll: fires parent on_scroll with the given dx/dy.
    var disp = Dispatcher{};
    disp.scroll(&parent_el, .{ .x = 40, .y = 40 }, 3.0, 7.5);
    try std.testing.expectEqual(@as(f32, 3.0), delta[0]);
    try std.testing.expectEqual(@as(f32, 7.5), delta[1]);

    // Scroll at a point outside: delta unchanged.
    disp.scroll(&parent_el, .{ .x = 200, .y = 200 }, 1.0, 2.0);
    try std.testing.expectEqual(@as(f32, 3.0), delta[0]);
    try std.testing.expectEqual(@as(f32, 7.5), delta[1]);
}

test "a printable codepoint becomes its own keysym" {
    try std.testing.expectEqual(@as(u32, 'a'), @intFromEnum(Keysym.fromCodepoint('a')));
    try std.testing.expectEqual(@as(u32, ' '), @intFromEnum(Keysym.fromCodepoint(' ')));
}

test "a codepoint above Latin-1 gets the unicode keysym offset" {
    // The X11 rule: a codepoint of 0x100 or more is the codepoint plus 0x01000000.
    try std.testing.expectEqual(@as(u32, 0x01004E00), @intFromEnum(Keysym.fromCodepoint(0x4E00)));
}

test "toCodepoint is the inverse of fromCodepoint for printable keys" {
    for ([_]u21{ 'a', 'Z', ' ', '~', 0xE9, 0x4E00, 0x1F600 }) |cp| {
        try std.testing.expectEqual(@as(?u21, cp), Keysym.fromCodepoint(cp).toCodepoint());
    }
}

test "a named key has no codepoint" {
    try std.testing.expectEqual(@as(?u21, null), Keysym.enter.toCodepoint());
    try std.testing.expectEqual(@as(?u21, null), Keysym.f1.toCodepoint());
    try std.testing.expectEqual(@as(?u21, null), Keysym.page_up.toCodepoint());
}

test "the named keysym values match the X11 numbers the Wayland path will send" {
    // These are keysymdef.h values. If one is wrong, the terminal and the
    // compositor disagree about what key was pressed and nothing catches it.
    try std.testing.expectEqual(@as(u32, 0xFF0D), @intFromEnum(Keysym.enter));
    try std.testing.expectEqual(@as(u32, 0xFF1B), @intFromEnum(Keysym.escape));
    try std.testing.expectEqual(@as(u32, 0xFF09), @intFromEnum(Keysym.tab));
    try std.testing.expectEqual(@as(u32, 0xFF52), @intFromEnum(Keysym.up));
    try std.testing.expectEqual(@as(u32, 0xFFC9), @intFromEnum(Keysym.f12));
}

test "the bare modifier keysyms match keysymdef.h" {
    // Verified against a real keysymdef.h on this machine
    // (Midstall's vendored X11 headers), the same way the block above was checked.
    try std.testing.expectEqual(@as(u32, 0xFFE1), @intFromEnum(Keysym.shift_l));
    try std.testing.expectEqual(@as(u32, 0xFFE2), @intFromEnum(Keysym.shift_r));
    try std.testing.expectEqual(@as(u32, 0xFFE3), @intFromEnum(Keysym.control_l));
    try std.testing.expectEqual(@as(u32, 0xFFE4), @intFromEnum(Keysym.control_r));
    try std.testing.expectEqual(@as(u32, 0xFFE9), @intFromEnum(Keysym.alt_l));
    try std.testing.expectEqual(@as(u32, 0xFFEA), @intFromEnum(Keysym.alt_r));
    try std.testing.expectEqual(@as(u32, 0xFFEB), @intFromEnum(Keysym.super_l));
    try std.testing.expectEqual(@as(u32, 0xFFEC), @intFromEnum(Keysym.super_r));
}
