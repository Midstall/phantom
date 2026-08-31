//! Children placed one after another along an axis. A child that carries a flex
//! factor (`Flexible`, `Expanded`) shares out the main-axis space the other
//! children did not take, and the main axis alignment decides where any space
//! that stays free goes. Without those two things a label and a right-pinned
//! value cannot be a Row, because both children sit at the start edge.
const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const testing = @import("../testing.zig");

pub const Axis = enum { vertical, horizontal };
pub const MainAxisAlignment = enum {
    start,
    center,
    end,
    /// No space before the first child or after the last one. All of it goes
    /// into the gaps between children.
    space_between,
    /// Every child gets an equal share of space, half of it on each side, so
    /// the outer edges are half as wide as the inner gaps.
    space_around,
    /// Every gap is the same width, the two outer ones included.
    space_evenly,
};
pub const CrossAxisAlignment = enum { start, center, end };

/// How much of its share a flexible child must take. `Expanded` uses `.tight`,
/// so the child fills the share exactly; `Flexible` uses `.loose`, so the child
/// may report a smaller size and give the rest back to the alignment.
pub const FlexFit = enum { loose, tight };

fn mainExtent(axis: Axis, s: geom.PhysicalSize) f32 {
    return switch (axis) {
        .vertical => s.height,
        .horizontal => s.width,
    };
}
fn crossExtent(axis: Axis, s: geom.PhysicalSize) f32 {
    return switch (axis) {
        .vertical => s.width,
        .horizontal => s.height,
    };
}
fn offsetFor(axis: Axis, main_pos: f32, cross_pos: f32) geom.PhysicalOffset {
    return switch (axis) {
        .vertical => .{ .x = cross_pos, .y = main_pos },
        .horizontal => .{ .x = main_pos, .y = cross_pos },
    };
}

/// Constraints for a flexible child that was given `share` of the main axis.
fn shareConstraints(axis: Axis, share: f32, fit: FlexFit, cross_max: f32, scale: f32) layout.BoxConstraints {
    const main_min: f32 = switch (fit) {
        .loose => 0,
        .tight => share,
    };
    return switch (axis) {
        .vertical => .{ .min_width = 0, .max_width = cross_max, .min_height = main_min, .max_height = share, .scale = scale },
        .horizontal => .{ .min_width = main_min, .max_width = share, .min_height = 0, .max_height = cross_max, .scale = scale },
    };
}

/// Where the free main-axis space goes: `leading` before the first child and
/// `between` in every gap.
pub const Spacing = struct {
    leading: f32,
    between: f32,
};

/// Split `free` main-axis space between the leading edge and the gaps, for
/// `count` children.
pub fn spacingFor(alignment: MainAxisAlignment, free: f32, count: usize) Spacing {
    if (count == 0) return .{ .leading = 0, .between = 0 };
    const n: f32 = @floatFromInt(count);
    // A negative `free` means the children overflowed. Sharing that out would
    // make them overlap, so the space-distributing modes pack from the start
    // instead. start, center and end keep the raw slack, which is the
    // long-standing behaviour and pushes an overflow off the leading edge.
    const gap = @max(0.0, free);
    return switch (alignment) {
        .start => .{ .leading = 0, .between = 0 },
        .center => .{ .leading = free / 2.0, .between = 0 },
        .end => .{ .leading = free, .between = 0 },
        // One child has no gap to sit between, so this degrades to start rather
        // than dividing by zero.
        .space_between => if (count == 1)
            .{ .leading = 0, .between = 0 }
        else
            .{ .leading = 0, .between = gap / (n - 1.0) },
        .space_around => .{ .leading = gap / n / 2.0, .between = gap / n },
        .space_evenly => .{ .leading = gap / (n + 1.0), .between = gap / (n + 1.0) },
    };
}

/// A pass-through box that tells its parent flex how much of the leftover main
/// axis it wants. Only a `RenderFlex` reads it; anywhere else it is a plain
/// wrapper that hands its constraints to its child unchanged.
pub const RenderFlexible = struct {
    base: RenderObject,
    child: ?*RenderObject = null,
    flex: u16,
    fit: FlexFit,

    pub fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderFlexible = @fieldParentPtr("base", base);
        const child_size = if (self.child) |ch| ch.layout(c) else geom.PhysicalSize.zero;
        // constrain, not the raw child size: under a tight fit the minimum is
        // the whole share, so a smaller child still reserves the space the flex
        // handed out and the children after it are not pulled backwards.
        return c.constrain(child_size);
    }

    pub fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderFlexible = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }

    pub fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderFlexible = @fieldParentPtr("base", base);
        self.child = child;
    }

    pub fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderFlexible = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
};

/// Recover a flexible child from a type-erased render object. The `type_id` tag
/// proves the concrete type, so @fieldParentPtr below is sound. A layoutFn
/// comparison would not be: release builds merge identical function bodies.
fn asFlexible(ro: *RenderObject) ?*RenderFlexible {
    if (!ro.isType(RenderFlexible)) return null;
    return @fieldParentPtr("base", ro);
}

/// The flex factor of a child, or 0 when it is not flexible and therefore takes
/// its natural main-axis extent.
fn flexOf(ro: *RenderObject) u16 {
    return if (asFlexible(ro)) |f| f.flex else 0;
}

pub const RenderFlex = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    direction: Axis,
    main: MainAxisAlignment,
    cross: CrossAxisAlignment,
    /// Where an allocation failure during layout is reported. A dropped child is
    /// invisible on screen, so it must never fail silently. Null only for a
    /// stack-owned RenderFlex that no widget mounted.
    sink: ?*phantom.FaultSink = null,
    children: std.ArrayList(*RenderObject) = .empty,
    offsets: std.ArrayList(geom.PhysicalOffset) = .empty,

    /// Report an allocation failure that costs the flex a child this frame.
    fn reportOom(self: *RenderFlex, msg: []const u8) void {
        if (self.sink) |s| s.report(.oom, msg);
    }

    /// An unbounded main axis has no leftover to share out, so a flex factor
    /// there cannot be honoured. The child is laid out at its natural size and
    /// the mistake is named instead of quietly collapsing the child to nothing.
    fn reportUnboundedFlex(self: *RenderFlex) void {
        if (self.sink) |s| s.report(
            .layout_overflow,
            "a Flex child has a flex factor but the main axis is unbounded, it kept its natural size",
        );
    }

    pub fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        const size = c.biggest();
        // When the main axis is unbounded, pass the full unbounded constraint to
        // children so each can report its natural size, then sum for the return value.
        const main_unbounded = switch (self.direction) {
            .vertical => std.math.isInf(c.max_height),
            .horizontal => std.math.isInf(c.max_width),
        };
        // An unbounded cross axis gets the same treatment as an unbounded main axis:
        // a child sees infinity and reports its natural extent, instead of the zero
        // that biggest() would give an unbounded axis.
        const cross_unbounded = switch (self.direction) {
            .vertical => std.math.isInf(c.max_width),
            .horizontal => std.math.isInf(c.max_height),
        };
        const cross_ext_for_children = if (cross_unbounded) std.math.inf(f32) else crossExtent(self.direction, size);
        const main_ext_for_children = if (main_unbounded) std.math.inf(f32) else mainExtent(self.direction, size);
        const child_c: layout.BoxConstraints = switch (self.direction) {
            .vertical => .{
                .min_width = 0,
                .max_width = cross_ext_for_children,
                .min_height = 0,
                .max_height = main_ext_for_children,
                .scale = c.scale,
            },
            .horizontal => .{
                .min_width = 0,
                .max_width = main_ext_for_children,
                .min_height = 0,
                .max_height = cross_ext_for_children,
                .scale = c.scale,
            },
        };
        self.offsets.clearRetainingCapacity();
        self.offsets.ensureTotalCapacity(self.gpa, self.children.items.len) catch {
            self.reportOom("out of memory reserving Flex child offsets");
        };
        // First pass: only the children that size themselves. A flexible child is
        // held back because its share depends on what this pass leaves over.
        var inflexible_main: f32 = 0;
        var total_cross: f32 = 0;
        var total_flex: u32 = 0;
        for (self.children.items) |ch| {
            const f = flexOf(ch);
            if (f > 0 and !main_unbounded) {
                total_flex += f;
                continue;
            }
            if (f > 0) self.reportUnboundedFlex();
            const cs = ch.layout(child_c);
            inflexible_main += mainExtent(self.direction, cs);
            if (crossExtent(self.direction, cs) > total_cross) total_cross = crossExtent(self.direction, cs);
        }
        // When main axis is unbounded, the flex shrinks to fit its children; otherwise
        // it fills the available space as before.
        const main_ext = if (main_unbounded) inflexible_main else mainExtent(self.direction, size);

        // Second pass: share what is left in proportion to the flex factors.
        var total_main = inflexible_main;
        if (total_flex > 0) {
            // If the children that size themselves already overflowed the axis
            // there is nothing left to share. A negative share would become a
            // constraint no child can satisfy, so the flexible ones get zero.
            const spare = @max(0.0, main_ext - inflexible_main);
            const denominator: f32 = @floatFromInt(total_flex);
            for (self.children.items) |ch| {
                const fl = asFlexible(ch) orelse continue;
                if (fl.flex == 0) continue;
                const share = spare * @as(f32, @floatFromInt(fl.flex)) / denominator;
                const cs = ch.layout(shareConstraints(self.direction, share, fl.fit, cross_ext_for_children, c.scale));
                total_main += mainExtent(self.direction, cs);
                if (crossExtent(self.direction, cs) > total_cross) total_cross = crossExtent(self.direction, cs);
            }
        }

        // total_cross is the tallest (or widest) child seen above. Standard flex
        // behaviour sizes the cross axis to that child whenever the parent did not
        // hand this flex a bound to fill.
        const cross_ext = if (main_unbounded or cross_unbounded) total_cross else crossExtent(self.direction, size);
        const spacing = spacingFor(self.main, main_ext - total_main, self.children.items.len);
        var main_pos: f32 = spacing.leading;
        for (self.children.items) |ch| {
            const cm = mainExtent(self.direction, ch.size);
            const cc = crossExtent(self.direction, ch.size);
            const cross_pos: f32 = switch (self.cross) {
                .start => 0,
                .center => (cross_ext - cc) / 2.0,
                .end => cross_ext - cc,
            };
            // Capacity was reserved above; if that OOMed, append safely (a short
            // offsets list is tolerated by paintFn, which iterates by offsets len).
            self.offsets.append(self.gpa, offsetFor(self.direction, main_pos, cross_pos)) catch {
                self.reportOom("out of memory recording a Flex child offset, child not painted");
            };
            main_pos += cm + spacing.between;
        }
        return switch (self.direction) {
            .vertical => .{
                .width = cross_ext,
                .height = if (main_unbounded) total_main else size.height,
            },
            .horizontal => .{
                .width = if (main_unbounded) total_main else size.width,
                .height = cross_ext,
            },
        };
    }

    pub fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        // Iterate by offsets length so a short offsets list (OOM during layout)
        // never indexes out of bounds; children beyond it are skipped this frame.
        for (self.offsets.items, 0..) |off, i| {
            try self.children.items[i].paint(cv, offset.add(off));
        }
    }

    pub fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderFlex = @fieldParentPtr("base", base);
        // Frees only the lists (pointers), NOT the child render objects: those are
        // owned by the child Elements and freed by their deinit.
        self.children.deinit(gpa);
        self.offsets.deinit(gpa);
        gpa.destroy(self);
    }
};

const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;

pub const Flex = struct {
    direction: Axis = .vertical,
    main: MainAxisAlignment = .start,
    cross: CrossAxisAlignment = .start,
    children: []const Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Flex) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn syncChildren(rf: *RenderFlex, el: *Element, gpa: std.mem.Allocator) void {
        rf.children.clearRetainingCapacity();
        rf.children.ensureTotalCapacity(gpa, el.children.items.len) catch {
            rf.reportOom("out of memory reserving the Flex child list");
        };
        for (el.children.items) |ch| {
            if (ch.renderObject()) |ro| rf.children.append(gpa, ro) catch {
                rf.reportOom("out of memory adding a Flex child, child not painted");
            };
        }
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const rf = try gpa.create(RenderFlex);
        rf.* = .{
            .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn },
            .gpa = gpa,
            .direction = self.direction,
            .main = self.main,
            .cross = self.cross,
            .sink = bctx.owner.sink,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(rf);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Flex),
            .render_object = &rf.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        try el.updateChildren(self.children, bctx);
        syncChildren(rf, el, gpa);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
        rf.direction = self.direction;
        rf.main = self.main;
        rf.cross = self.cross;
        try el.updateChildren(self.children, bctx);
        syncChildren(rf, el, bctx.owner.gpa);
    }
};

/// Claims a share of the leftover main-axis space of the enclosing Flex. The
/// share is `flex` divided by the sum of every sibling's flex factor. A
/// `Flexible` inside anything other than a Flex is a transparent wrapper.
///
/// This is a wrapper widget rather than a field on the Flex child list because
/// a child arrives as a type-erased `Widget`. A parallel array of factors would
/// have to stay in step with the children by hand, and `Stack`/`Positioned`
/// already set the precedent for a wrapper the parent downcasts.
pub const Flexible = struct {
    flex: u16 = 1,
    fit: FlexFit = .loose,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Flexible) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Flexible = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderFlexible);
        ro.* = .{
            .base = .{
                .layoutFn = RenderFlexible.layoutFn,
                .paintFn = RenderFlexible.paintFn,
                .destroyFn = RenderFlexible.destroyFn,
                .adoptChildFn = RenderFlexible.adopt,
                .type_id = phantom.render_object.typeId(RenderFlexible),
            },
            .flex = self.flex,
            .fit = self.fit,
        };
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Flexible),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |ch| ch.renderObject() else null);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Flexible = @ptrCast(@alignCast(ptr));
        const ro: *RenderFlexible = @fieldParentPtr("base", el.render_object.?);
        ro.flex = self.flex;
        ro.fit = self.fit;
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |ch| ch.renderObject() else null);
    }
};

/// A `Flexible` that must fill its whole share. Use it for the one region that
/// should soak up whatever the fixed-size regions did not take.
pub fn Expanded(opts: struct { flex: u16 = 1, child: Widget }) Flexible {
    return .{ .flex = opts.flex, .fit = .tight, .child = opts.child };
}

pub fn Column(opts: struct { main: MainAxisAlignment = .start, cross: CrossAxisAlignment = .start, children: []const Widget }) Flex {
    return .{ .direction = .vertical, .main = opts.main, .cross = opts.cross, .children = opts.children };
}
pub fn Row(opts: struct { main: MainAxisAlignment = .start, cross: CrossAxisAlignment = .start, children: []const Widget }) Flex {
    return .{ .direction = .horizontal, .main = opts.main, .cross = opts.cross, .children = opts.children };
}

// Test-only render object: reports a fixed physical size (ignores constraints)
// and records the scale it was laid out with.
const FixedBox = struct {
    base: RenderObject,
    w: f32,
    h: f32,
    seen_scale: f32 = 0,
    fn lf(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *FixedBox = @fieldParentPtr("base", base);
        self.seen_scale = c.scale;
        return .{ .width = self.w, .height = self.h };
    }
    fn pf(_: *RenderObject, _: *Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn make(w: f32, h: f32) FixedBox {
        return .{ .base = .{ .layoutFn = lf, .paintFn = pf }, .w = w, .h = h };
    }
};

// Test-only render object: takes the biggest size its constraints allow, the
// way ColoredBox does. Only a child that reads its constraints can show what
// share of the main axis a flex factor actually handed it.
const GreedyBox = struct {
    base: RenderObject,
    fn lf(_: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        return c.biggest();
    }
    fn pf(_: *RenderObject, _: *Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn make() GreedyBox {
        return .{ .base = .{ .layoutFn = lf, .paintFn = pf } };
    }
};

// Test-only render object: wants a fixed size but obeys its constraints, so a
// tight fit can force it larger and a loose fit cannot.
const NaturalBox = struct {
    base: RenderObject,
    w: f32,
    h: f32,
    fn lf(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *NaturalBox = @fieldParentPtr("base", base);
        return c.constrain(.{ .width = self.w, .height = self.h });
    }
    fn pf(_: *RenderObject, _: *Canvas, _: geom.PhysicalOffset) anyerror!void {}
    fn make(w: f32, h: f32) NaturalBox {
        return .{ .base = .{ .layoutFn = lf, .paintFn = pf }, .w = w, .h = h };
    }
};

fn makeFlexible(child: *RenderObject, flex: u16, fit: FlexFit) RenderFlexible {
    return .{
        .base = .{
            .layoutFn = RenderFlexible.layoutFn,
            .paintFn = RenderFlexible.paintFn,
            .adoptChildFn = RenderFlexible.adopt,
            .type_id = phantom.render_object.typeId(RenderFlexible),
        },
        .child = child,
        .flex = flex,
        .fit = fit,
    };
}

fn makeFlex(gpa: std.mem.Allocator, direction: Axis, main: MainAxisAlignment) RenderFlex {
    return .{
        .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn },
        .gpa = gpa,
        .direction = direction,
        .main = main,
        .cross = .start,
    };
}

test "RenderFlex vertical start stacks children; center leads by half slack; scale flows" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(20, 50);
    var rf = RenderFlex{ .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn }, .gpa = gpa, .direction = .vertical, .main = .start, .cross = .start };
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    // vertical start at scale 2: children stack from y=0, scale flows to children
    _ = rf.base.layout(layout.BoxConstraints.tightScaled(.{ .width = 200, .height = 200 }, 2.0));
    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].y);
    try std.testing.expectEqual(@as(f32, 30), rf.offsets.items[1].y); // after child a's height
    try std.testing.expectEqual(@as(f32, 2.0), a.seen_scale); // scale preserved into child constraints
    // switch to center on both axes
    rf.main = .center;
    rf.cross = .center;
    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 200 }));
    // total main = 30+50 = 80; leading = (200-80)/2 = 60
    try std.testing.expectEqual(@as(f32, 60), rf.offsets.items[0].y);
    try std.testing.expectEqual(@as(f32, 90), rf.offsets.items[1].y);
    // cross center: (200-20)/2 = 90
    try std.testing.expectEqual(@as(f32, 90), rf.offsets.items[0].x);
}

test "RenderFlex horizontal (Row) stacks on x" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(40, 30);
    var rf = RenderFlex{ .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn }, .gpa = gpa, .direction = .horizontal, .main = .start, .cross = .start };
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 100 }));
    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].x);
    try std.testing.expectEqual(@as(f32, 20), rf.offsets.items[1].x); // after child a's width
}

test "Flex widget mounts children, syncs render objects, stacks two Texts vertically" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t0 = phantom.Text{ .text = "A", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var t1 = phantom.Text{ .text = "B", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    const kids = [_]phantom.Widget{ t0.widget(), t1.widget() };
    var col = Flex{ .direction = .vertical, .main = .start, .cross = .start, .children = &kids };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), el.children.items.len);
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(usize, 2), rf.children.items.len);

    _ = el.render_object.?.layout(phantom.BoxConstraints.tight(.{ .width = 200, .height = 200 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, phantom.PhysicalOffset.zero);
    // two text runs, second below the first (start-aligned vertical stack)
    const items = canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].text.origin.y < items[1].text.origin.y);
}

test "a Flex layout that cannot allocate its offsets reports oom and paints no child" {
    // A dropped child leaves nothing on screen. The old code swallowed the
    // allocation failure with an empty catch, so the frame lost a child and no
    // fault named the reason.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(20, 50);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var rf = RenderFlex{
        .base = .{ .layoutFn = RenderFlex.layoutFn, .paintFn = RenderFlex.paintFn, .destroyFn = RenderFlex.destroyFn },
        .gpa = failing.allocator(),
        .direction = .vertical,
        .main = .start,
        .cross = .start,
        .sink = &sink,
    };
    // The child list is filled through the working allocator, so only the offset
    // allocations inside layoutFn meet the failing one.
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 200 }));

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.oom, sink.first.?.code);
    // No offset was recorded, so paintFn walks nothing rather than indexing past
    // the short list.
    try std.testing.expectEqual(@as(usize, 0), rf.offsets.items.len);
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try rf.base.paint(&canvas, geom.PhysicalOffset.zero);
    try std.testing.expectEqual(@as(usize, 0), canvas.list.primitives.items.len);
}

test "a Flex whose child list cannot grow reports oom and keeps the children it has" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    const two = [_]phantom.Widget{ box.widget(), box.widget() };
    var col = Flex{ .children = &two };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expect(sink.ok()); // a normal mount records nothing

    // Re-sync the render object's child list through an allocator that refuses,
    // which is the path a low memory frame takes.
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    // Release the capacity the mount reserved, or the refusing allocator is never
    // asked for anything and the test proves nothing.
    rf.children.clearAndFree(gpa);
    Flex.syncChildren(rf, el, failing.allocator());

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.oom, sink.first.?.code);
    try std.testing.expectEqual(@as(usize, 0), rf.children.items.len);
}

test "Flex widget update reconciles child count (grow then shrink), leak-clean" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    const two = [_]phantom.Widget{ box.widget(), box.widget() };
    var col = Flex{ .children = &two };
    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), el.children.items.len);
    const three = [_]phantom.Widget{ box.widget(), box.widget(), box.widget() };
    var col3 = Flex{ .children = &three };
    try col3.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 3), el.children.items.len);
    const rf: *RenderFlex = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(usize, 3), rf.children.items.len);
    const one = [_]phantom.Widget{box.widget()};
    var col1 = Flex{ .children = &one };
    try col1.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(usize, 1), el.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), rf.children.items.len);
}

test "a child that fills its constraints takes the whole main extent, so two of them do not share the Row" {
    // This is the gap flex factors close. The main-axis constraint a Flex hands
    // a child is loose, so a child that sizes itself keeps its natural extent,
    // but a child that fills (ColoredBox and everything built on it) swallows
    // the whole axis and pushes the next child clean off the end.
    const gpa = std.testing.allocator;
    var a = GreedyBox.make();
    var b = GreedyBox.make();
    var rf = makeFlex(gpa, .horizontal, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 100 }));

    try std.testing.expectEqual(@as(f32, 400), a.base.size.width);
    try std.testing.expectEqual(@as(f32, 400), rf.offsets.items[1].x);
}

test "spacingFor puts every gap between the children for space_between and none at the edges" {
    const s = spacingFor(.space_between, 300, 4);
    try std.testing.expectEqual(@as(f32, 0), s.leading);
    try std.testing.expectEqual(@as(f32, 100), s.between);
}

test "spacingFor gives space_around a leading edge that is half of an inner gap" {
    const s = spacingFor(.space_around, 240, 3);
    try std.testing.expectEqual(@as(f32, 80), s.between);
    try std.testing.expectEqual(@as(f32, 40), s.leading);
}

test "spacingFor makes every space_evenly gap equal, outer ones included" {
    const s = spacingFor(.space_evenly, 240, 3);
    try std.testing.expectEqual(@as(f32, 60), s.between);
    try std.testing.expectEqual(@as(f32, 60), s.leading);
}

test "spacingFor degrades space_between to start for a single child instead of dividing by zero" {
    const s = spacingFor(.space_between, 300, 1);
    try std.testing.expectEqual(@as(f32, 0), s.leading);
    try std.testing.expectEqual(@as(f32, 0), s.between);
    // A finite gap is the point: n - 1 is zero here, so a plain division would
    // have produced inf and thrown the child out of the box.
    try std.testing.expect(std.math.isFinite(s.between));
}

test "spacingFor refuses to hand out negative space when the children overflowed" {
    // Overflow makes `free` negative. Dividing that between the children would
    // stack them on top of each other, which reads as a rendering bug rather
    // than as an overflow.
    const s = spacingFor(.space_between, -120, 3);
    try std.testing.expectEqual(@as(f32, 0), s.between);
    const around = spacingFor(.space_around, -120, 3);
    try std.testing.expectEqual(@as(f32, 0), around.leading);
    // start, center and end keep the raw slack, which is the old behaviour.
    try std.testing.expectEqual(@as(f32, -120), spacingFor(.end, -120, 3).leading);
}

test "space_between pins the last child of a Row to the trailing edge" {
    // Use case: a label on the left and its value hard against the right edge.
    const gpa = std.testing.allocator;
    var label = FixedBox.make(60, 20);
    var value = FixedBox.make(50, 20);
    var rf = makeFlex(gpa, .horizontal, .space_between);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &label.base);
    try rf.children.append(gpa, &value.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 20 }));

    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].x);
    try std.testing.expectEqual(@as(f32, 350), rf.offsets.items[1].x);
    // The right edge of the value meets the right edge of the row.
    try std.testing.expectEqual(@as(f32, 400), rf.offsets.items[1].x + value.w);
}

test "space_evenly leaves the same gap before, between and after three children" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(40, 20);
    var b = FixedBox.make(40, 20);
    var c = FixedBox.make(40, 20);
    var rf = makeFlex(gpa, .horizontal, .space_evenly);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    try rf.children.append(gpa, &c.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 20 }));

    // 400 - 3*40 = 280 of free space over four equal gaps of 70.
    try std.testing.expectEqual(@as(f32, 70), rf.offsets.items[0].x);
    try std.testing.expectEqual(@as(f32, 180), rf.offsets.items[1].x);
    try std.testing.expectEqual(@as(f32, 290), rf.offsets.items[2].x);
    try std.testing.expectEqual(@as(f32, 70), 400 - (rf.offsets.items[2].x + c.w));
}

test "space_around gives the outer edges half a gap and the inner ones a whole gap" {
    const gpa = std.testing.allocator;
    var a = FixedBox.make(40, 20);
    var b = FixedBox.make(40, 20);
    var rf = makeFlex(gpa, .horizontal, .space_around);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 20 }));

    // 400 - 80 = 320 free over two children: 160 each, half of it per side.
    try std.testing.expectEqual(@as(f32, 80), rf.offsets.items[0].x);
    try std.testing.expectEqual(@as(f32, 280), rf.offsets.items[1].x);
    // Symmetric: the trailing margin equals the leading one, and the inner gap
    // is twice either of them. This is what separates space_around from
    // space_evenly, which would put 133.33 at every gap.
    try std.testing.expectEqual(@as(f32, 80), 400 - (rf.offsets.items[1].x + b.w));
    try std.testing.expectEqual(@as(f32, 160), rf.offsets.items[1].x - (rf.offsets.items[0].x + a.w));
}

test "an Expanded child takes exactly the height the fixed children left over" {
    // Use case: four regions in a Column where the transcript grows and the
    // other three keep their natural height.
    const gpa = std.testing.allocator;
    var header = FixedBox.make(20, 30);
    var transcript = GreedyBox.make();
    var flexible = makeFlexible(&transcript.base, 1, .tight);
    var footer = FixedBox.make(20, 50);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &header.base);
    try rf.children.append(gpa, &flexible.base);
    try rf.children.append(gpa, &footer.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 200, .height = 200 }));

    try std.testing.expectEqual(@as(f32, 120), flexible.base.size.height); // 200 - 30 - 50
    try std.testing.expectEqual(@as(f32, 0), rf.offsets.items[0].y);
    try std.testing.expectEqual(@as(f32, 30), rf.offsets.items[1].y);
    try std.testing.expectEqual(@as(f32, 150), rf.offsets.items[2].y);
    // The three regions cover the column with nothing left over.
    try std.testing.expectEqual(@as(f32, 200), rf.offsets.items[2].y + footer.h);
}

test "two Expanded children split the leftover in proportion to their flex factors" {
    const gpa = std.testing.allocator;
    var big_child = GreedyBox.make();
    var small_child = GreedyBox.make();
    var big = makeFlexible(&big_child.base, 2, .tight);
    var small = makeFlexible(&small_child.base, 1, .tight);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &big.base);
    try rf.children.append(gpa, &small.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 300 }));

    try std.testing.expectEqual(@as(f32, 200), big.base.size.height);
    try std.testing.expectEqual(@as(f32, 100), small.base.size.height);
    try std.testing.expectEqual(@as(f32, 200), rf.offsets.items[1].y);
}

test "three equal Expanded children each take a third of an axis that does not divide evenly" {
    // A third of 100 has no exact binary form, so this is where a distribution
    // that rounds the wrong way, or that divides by the child count instead of
    // the flex total, shows up.
    const gpa = std.testing.allocator;
    var c0 = GreedyBox.make();
    var c1 = GreedyBox.make();
    var c2 = GreedyBox.make();
    var f0 = makeFlexible(&c0.base, 1, .tight);
    var f1 = makeFlexible(&c1.base, 1, .tight);
    var f2 = makeFlexible(&c2.base, 1, .tight);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &f0.base);
    try rf.children.append(gpa, &f1.base);
    try rf.children.append(gpa, &f2.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 10, .height = 100 }));

    const third = 100.0 / 3.0;
    try std.testing.expectApproxEqAbs(third, f0.base.size.height, 1e-3);
    try std.testing.expectApproxEqAbs(third, f1.base.size.height, 1e-3);
    try std.testing.expectApproxEqAbs(third, f2.base.size.height, 1e-3);
    // The three of them together still reach the far edge, so no visible sliver
    // of the column is left unclaimed.
    try std.testing.expectApproxEqAbs(@as(f32, 100), rf.offsets.items[2].y + f2.base.size.height, 1e-3);
}

test "a tight fit forces a child up to its share while a loose fit leaves it at its natural size" {
    const gpa = std.testing.allocator;
    var tight_child = NaturalBox.make(20, 30);
    var loose_child = NaturalBox.make(20, 30);
    var tight = makeFlexible(&tight_child.base, 1, .tight);
    var loose = makeFlexible(&loose_child.base, 1, .loose);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &tight.base);
    try rf.children.append(gpa, &loose.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 200 }));

    // Both were offered 100, but only the tight one has to take it.
    try std.testing.expectEqual(@as(f32, 100), tight.base.size.height);
    try std.testing.expectEqual(@as(f32, 30), loose.base.size.height);
    try std.testing.expectEqual(@as(f32, 100), rf.offsets.items[1].y);
}

test "an Expanded holds its whole share open even when the child inside ignores the constraint" {
    // A child is free to report any size it likes. If the Expanded passed that
    // size on, the share would shrink to fit the child and every later sibling
    // would slide up the axis, which is the opposite of what Expanded promises.
    const gpa = std.testing.allocator;
    var stubborn = FixedBox.make(20, 30);
    var flexible = makeFlexible(&stubborn.base, 1, .tight);
    var after = FixedBox.make(20, 50);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &flexible.base);
    try rf.children.append(gpa, &after.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 200 }));

    try std.testing.expectEqual(@as(f32, 150), flexible.base.size.height);
    try std.testing.expectEqual(@as(f32, 150), rf.offsets.items[1].y);
}

test "a Flexible with a flex factor of zero keeps its natural size and claims none of the leftover" {
    const gpa = std.testing.allocator;
    var inner = NaturalBox.make(20, 30);
    var fixed = makeFlexible(&inner.base, 0, .tight);
    var after = FixedBox.make(20, 50);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &fixed.base);
    try rf.children.append(gpa, &after.base);

    _ = rf.base.layout(layout.BoxConstraints.tight(.{ .width = 100, .height = 200 }));

    try std.testing.expectEqual(@as(f32, 30), fixed.base.size.height);
    try std.testing.expectEqual(@as(f32, 30), rf.offsets.items[1].y);
}

test "a flex factor on an unbounded main axis reports a fault and keeps the child's natural size" {
    // An unbounded axis has no leftover to divide. Silently collapsing the child
    // to nothing would lose it from the frame with no reason recorded.
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var inner = NaturalBox.make(20, 30);
    var flexible = makeFlexible(&inner.base, 1, .tight);
    var rf = makeFlex(gpa, .vertical, .start);
    rf.sink = &sink;
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &flexible.base);

    const size = rf.base.layout(.{ .min_width = 0, .max_width = 100, .min_height = 0, .max_height = std.math.inf(f32) });

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.layout_overflow, sink.first.?.code);
    try std.testing.expectEqual(@as(f32, 30), flexible.base.size.height);
    try std.testing.expectEqual(@as(f32, 30), size.height);
}

test "a Row of a label and an Expanded value paints the value against the right edge" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var label_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var label = phantom.SizedBox{ .width = 60, .child = label_fill.widget() };
    var value_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) };
    var value = phantom.SizedBox{ .width = 50, .child = value_fill.widget() };
    var pinned = phantom.Align{ .alignment = .center_right, .child = value.widget() };
    var grown = Expanded(.{ .child = pinned.widget() });
    const kids = [_]Widget{ label.widget(), grown.widget() };
    var row = Row(.{ .children = &kids });

    const el = try row.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 20 }));

    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const label_rect = canvas.list.primitives.items[0].rrect.rect;
    const value_rect = canvas.list.primitives.items[1].rrect.rect;
    try std.testing.expectEqual(@as(f32, 0), label_rect.x);
    try std.testing.expectEqual(@as(f32, 60), label_rect.width);
    // The value is 50 wide and its right edge meets the right edge of the row.
    try std.testing.expectEqual(@as(f32, 50), value_rect.width);
    try std.testing.expectEqual(@as(f32, 350), value_rect.x);
    try std.testing.expectEqual(@as(f32, 400), value_rect.x + value_rect.width);
}

test "a Column of four regions gives the Expanded transcript every row the other three left" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var header_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var header = phantom.SizedBox{ .height = 20, .child = header_fill.widget() };
    var transcript_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 1, 0) };
    var transcript = Expanded(.{ .child = transcript_fill.widget() });
    var status_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var status = phantom.SizedBox{ .height = 10, .child = status_fill.widget() };
    var input_fill = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 1, 0) };
    var input = phantom.SizedBox{ .height = 30, .child = input_fill.widget() };
    const kids = [_]Widget{ header.widget(), transcript.widget(), status.widget(), input.widget() };
    var col = Column(.{ .children = &kids });

    const el = try col.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    _ = el.renderObject().?.layout(layout.BoxConstraints.tight(.{ .width = 400, .height = 200 }));

    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try el.renderObject().?.paint(&canvas, geom.PhysicalOffset.zero);

    const rects = canvas.list.primitives.items;
    try std.testing.expectEqual(@as(usize, 4), rects.len);
    try std.testing.expectEqual(@as(f32, 0), rects[0].rrect.rect.y);
    try std.testing.expectEqual(@as(f32, 20), rects[0].rrect.rect.height);
    // 200 - 20 - 10 - 30 = 140 for the transcript, and the three fixed regions
    // keep the heights they asked for.
    try std.testing.expectEqual(@as(f32, 20), rects[1].rrect.rect.y);
    try std.testing.expectEqual(@as(f32, 140), rects[1].rrect.rect.height);
    try std.testing.expectEqual(@as(f32, 160), rects[2].rrect.rect.y);
    try std.testing.expectEqual(@as(f32, 10), rects[2].rrect.rect.height);
    try std.testing.expectEqual(@as(f32, 170), rects[3].rrect.rect.y);
    try std.testing.expectEqual(@as(f32, 30), rects[3].rrect.rect.height);
    try std.testing.expectEqual(@as(f32, 200), rects[3].rrect.rect.y + rects[3].rrect.rect.height);
}

test "changing a Flexible's flex factor redistributes the axis on the next layout" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var fill = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var even = Flexible{ .flex = 1, .fit = .tight, .child = fill.widget() };
    const el = try even.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    const ro: *RenderFlexible = @fieldParentPtr("base", el.render_object.?);
    try std.testing.expectEqual(@as(u16, 1), ro.flex);

    var heavier = Flexible{ .flex = 3, .fit = .loose, .child = fill.widget() };
    try heavier.widget().update(el, &bctx);
    try std.testing.expectEqual(@as(u16, 3), ro.flex);
    try std.testing.expectEqual(FlexFit.loose, ro.fit);
    // Same render object, so the flex never rebuilds the subtree for a factor change.
    try std.testing.expect(el.render_object.? == &ro.base);
}

test "a Flexible render object is tagged so only a real one is read as flexible" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var fill = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var flexible = Expanded(.{ .flex = 4, .child = fill.widget() });
    const flex_el = try flexible.widget().mount(&bctx, null);
    defer flex_el.deinit(gpa);
    var plain = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const plain_el = try plain.widget().mount(&bctx, null);
    defer plain_el.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 4), flexOf(flex_el.renderObject().?));
    try std.testing.expectEqual(FlexFit.tight, asFlexible(flex_el.renderObject().?).?.fit);
    // An untagged render object must never be downcast to RenderFlexible.
    try std.testing.expect(asFlexible(plain_el.renderObject().?) == null);
    try std.testing.expectEqual(@as(u16, 0), flexOf(plain_el.renderObject().?));
}

test "a Row given a bounded width and an infinite max height reports its tallest child's height" {
    // The main axis (width) is bounded as usual; the cross axis (height) is the
    // one an unbounded parent, such as a vertical ScrollView, hands a Row. The
    // old code read the cross extent off biggest(), which is zero on an
    // unbounded axis, so the row reported zero height no matter what it held.
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(20, 50);
    var rf = makeFlex(gpa, .horizontal, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    const size = rf.base.layout(.{ .min_width = 0, .max_width = 200, .min_height = 0, .max_height = std.math.inf(f32) });
    try std.testing.expectEqual(@as(f32, 50), size.height);
}

test "a Column given a bounded height and an infinite max width reports its widest child's width" {
    // Same fault, the other axis: a Column's cross axis is width, and an
    // unbounded parent (a horizontal ScrollView) hands it infinity there.
    const gpa = std.testing.allocator;
    var a = FixedBox.make(20, 30);
    var b = FixedBox.make(50, 30);
    var rf = makeFlex(gpa, .vertical, .start);
    defer {
        rf.children.deinit(gpa);
        rf.offsets.deinit(gpa);
    }
    try rf.children.append(gpa, &a.base);
    try rf.children.append(gpa, &b.base);
    const size = rf.base.layout(.{ .min_width = 0, .max_width = std.math.inf(f32), .min_height = 0, .max_height = 200 });
    try std.testing.expectEqual(@as(f32, 50), size.width);
}

// Depth-first search for the first render object with an on_up handler, the
// way a real hit test would find a tap target. A plain pointer != null match
// would also catch the ScrollView itself, which installs a scroll handler
// but no tap handler.
fn findTappable(el: *Element) ?*RenderObject {
    if (el.renderObject()) |ro| {
        if (ro.pointer) |p| if (p.on_up != null) return ro;
    }
    if (el.child) |c| {
        if (findTappable(c)) |ro| return ro;
    }
    for (el.children.items) |c| {
        if (findTappable(c)) |ro| return ro;
    }
    return null;
}

test "a Row inside a ScrollView gives its child nonzero height, and a tap there reaches it" {
    // Pins the user-visible symptom: the showcase's home page held link cards
    // in a Row inside a vertical ScrollView. A zero-height row cannot be
    // tapped, so the cards were invisible and dead to the pointer.
    const gpa = std.testing.allocator;
    var taps: u32 = 0;
    var fill = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    var sized = phantom.SizedBox{ .width = 50, .height = 40, .child = fill.widget() };
    var tappable = phantom.GestureDetector{ .ctx = &taps, .on_tap = struct {
        fn f(ctx: *anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.f, .child = sized.widget() };
    const kids = [_]Widget{tappable.widget()};
    var row = Row(.{ .children = &kids });
    var sv = phantom.ScrollView{ .child = row.widget() };

    var h = try testing.mount(gpa, sv.widget());
    defer h.deinit();
    h.viewport = .{ .width = 200, .height = 300 };
    try h.pump();

    const target = findTappable(h.root) orelse return error.NoPointerRenderObject;
    try std.testing.expectEqual(@as(f32, 40), target.size.height);

    h.tapAt(.{
        .x = target.origin.x + target.size.width / 2.0,
        .y = target.origin.y + target.size.height / 2.0,
    });
    try std.testing.expectEqual(@as(u32, 1), taps);
}
