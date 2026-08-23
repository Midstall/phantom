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

const RenderPointerListener = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    child: ?*RenderObject = null,
    handlers: PointerHandlers,
    // User callbacks + ctx captured from the widget config.
    on_down: ?*const fn (*anyopaque, PointerEvent) void,
    on_up: ?*const fn (*anyopaque, PointerEvent) void,
    on_move: ?*const fn (*anyopaque, PointerEvent) void,
    user_ctx: *anyopaque,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderPointerListener = @fieldParentPtr("base", base);
        if (self.child) |ch| return ch.layout(c);
        return c.constrain(geom.PhysicalSize.zero);
    }
    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderPointerListener = @fieldParentPtr("base", base);
        if (self.child) |ch| try ch.paint(cv, offset);
    }
    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderPointerListener = @fieldParentPtr("base", base);
        gpa.destroy(self);
    }
    fn adopt(base: *RenderObject, child: ?*RenderObject) void {
        const self: *RenderPointerListener = @fieldParentPtr("base", base);
        self.child = child;
    }
    // Thunks routing the installed handlers to the user callbacks.
    fn downThunk(ctx: *anyopaque, ev: PointerEvent) void {
        const self: *RenderPointerListener = @ptrCast(@alignCast(ctx));
        if (self.on_down) |f| f(self.user_ctx, ev);
    }
    fn upThunk(ctx: *anyopaque, ev: PointerEvent) void {
        const self: *RenderPointerListener = @ptrCast(@alignCast(ctx));
        if (self.on_up) |f| f(self.user_ctx, ev);
    }
    fn moveThunk(ctx: *anyopaque, ev: PointerEvent) void {
        const self: *RenderPointerListener = @ptrCast(@alignCast(ctx));
        if (self.on_move) |f| f(self.user_ctx, ev);
    }
};

pub const Listener = struct {
    on_pointer_down: ?*const fn (*anyopaque, PointerEvent) void = null,
    on_pointer_up: ?*const fn (*anyopaque, PointerEvent) void = null,
    on_pointer_move: ?*const fn (*anyopaque, PointerEvent) void = null,
    ctx: *anyopaque = undefined,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };
    pub fn widget(self: *const Listener) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn install(ro: *RenderPointerListener, self: *const Listener) void {
        ro.on_down = self.on_pointer_down;
        ro.on_up = self.on_pointer_up;
        ro.on_move = self.on_pointer_move;
        ro.user_ctx = self.ctx;
        ro.handlers = .{
            .ctx = ro,
            .on_down = if (self.on_pointer_down != null) RenderPointerListener.downThunk else null,
            .on_up = if (self.on_pointer_up != null) RenderPointerListener.upThunk else null,
            .on_move = if (self.on_pointer_move != null) RenderPointerListener.moveThunk else null,
        };
        ro.base.pointer = &ro.handlers;
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Listener = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(RenderPointerListener);
        ro.* = .{ .base = .{ .layoutFn = RenderPointerListener.layoutFn, .paintFn = RenderPointerListener.paintFn, .destroyFn = RenderPointerListener.destroyFn, .adoptChildFn = RenderPointerListener.adopt }, .gpa = gpa, .handlers = .{ .ctx = undefined }, .on_down = null, .on_up = null, .on_move = null, .user_ctx = undefined };
        install(ro, self);
        const el = gpa.create(Element) catch |e| {
            gpa.destroy(ro);
            return e;
        };
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vtable, .type_name = @typeName(Listener), .render_object = &ro.base, .depth = phantom.widget.depthOf(parent) };
        errdefer el.deinit(gpa);
        el.child = try el.updateChild(null, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
        return el;
    }
    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Listener = @ptrCast(@alignCast(ptr));
        const ro: *RenderPointerListener = @fieldParentPtr("base", el.render_object.?);
        install(ro, self);
        el.child = try el.updateChild(el.child, self.child, bctx);
        ro.base.adoptChild(if (el.child) |c| c.renderObject() else null);
    }
};

test "Listener sizes to child, installs pointer handlers, and forwards a down event" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var downs: u32 = 0;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 0 };
    var l = Listener{ .ctx = &downs, .on_pointer_down = struct {
        fn f(ctx: *anyopaque, _: phantom.PointerEvent) void {
            const c: *u32 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.f, .child = box.widget() };
    const el = try l.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 80, .height = 40 }));
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    try ro.paint(&canvas, phantom.PhysicalOffset.zero);
    // sizes to child (ColoredBox fills -> 80x40) and installed handlers
    try std.testing.expectEqual(@as(f32, 80), ro.size.width);
    try std.testing.expect(ro.pointer != null);
    const h = phantom.input.hitTest(el, .{ .x = 10, .y = 10 }).?;
    if (h.on_down) |f| f(h.ctx, .{ .position = .{ .x = 10, .y = 10 }, .phase = .down });
    try std.testing.expectEqual(@as(u32, 1), downs);
}
