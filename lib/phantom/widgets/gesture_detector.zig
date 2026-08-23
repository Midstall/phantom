const std = @import("std");
const phantom = @import("../../phantom.zig");
const geom = phantom.geometry;
const layout = phantom.layout;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;
const PointerEvent = phantom.PointerEvent;
const PointerHandlers = phantom.PointerHandlers;

const RenderGestureDetector = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    handlers: PointerHandlers,
    on_tap: ?*const fn (*anyopaque) void,
    user_ctx: *anyopaque,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderGestureDetector = @fieldParentPtr("base", base);
        if (self.child) |ch| return ch.layout(c);
        return c.constrain(geom.PhysicalSize.zero);
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderGestureDetector = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderGestureDetector = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderGestureDetector = @fieldParentPtr("base", base);
        self.child = child;
    }
    // Fire on_tap only when the up point is within this detector's absolute bounds.
    // A drag-off before release is a cancel, no tap. The Dispatcher only delivers
    // on_up to the down target, so this bounds check makes the tap-vs-cancel decision.
    fn upThunk(ctx: *anyopaque, ev: PointerEvent) void {
        const self: *RenderGestureDetector = @ptrCast(@alignCast(ctx));
        const o = self.base.origin;
        const s = self.base.size;
        const inside = ev.position.x >= o.x and ev.position.x < o.x + s.width and
            ev.position.y >= o.y and ev.position.y < o.y + s.height;
        if (inside) if (self.on_tap) |f| f(self.user_ctx);
    }
};

pub const GestureDetector = struct {
    on_tap: ?*const fn (*anyopaque) void = null,
    ctx: *anyopaque = undefined,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const GestureDetector) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn install(ro: *RenderGestureDetector, self: *const GestureDetector) void {
        ro.on_tap = self.on_tap;
        ro.user_ctx = self.ctx;
        ro.handlers = .{ .ctx = ro, .on_down = null, .on_up = RenderGestureDetector.upThunk, .on_move = null };
        ro.base.pointer = &ro.handlers;
    }
    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const GestureDetector = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderGestureDetector);
        ro.* = .{ .base = .{ .layoutFn = RenderGestureDetector.layoutFn, .paintFn = RenderGestureDetector.paintFn, .destroyFn = RenderGestureDetector.destroyFn, .adoptChildFn = RenderGestureDetector.adopt }, .gpa = gpa, .handlers = .{ .ctx = undefined }, .on_tap = null, .user_ctx = undefined };
        install(ro, self);
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(GestureDetector), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }
    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const GestureDetector = @ptrCast(@alignCast(ptr));
        const ro: *RenderGestureDetector = @fieldParentPtr("base", el.render_object.?);
        install(ro, self);
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "GestureDetector fires on_tap on down+up within bounds; not on up outside" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var taps: u32 = 0;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    var g = GestureDetector{ .ctx = &taps, .on_tap = struct {
        fn f(ctx: *anyopaque) void {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.f, .child = box.widget() };
    const el = try g.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 100, .height = 100 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try ro.paint(&canvas, phantom.PhysicalOffset.zero); // sets origin (0,0)

    var d = phantom.input.Dispatcher{};
    d.down(el, .{ .x = 50, .y = 50 });
    d.up(el, .{ .x = 50, .y = 50 });
    try std.testing.expectEqual(@as(u32, 1), taps);
    // down inside, up outside the bounds -> no tap
    d.down(el, .{ .x = 50, .y = 50 });
    d.up(el, .{ .x = 500, .y = 500 });
    try std.testing.expectEqual(@as(u32, 1), taps);
}
