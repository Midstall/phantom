const geom = @import("geometry.zig");

pub const PointerPhase = enum { down, up, move, enter, leave };

pub const PointerEvent = struct {
    position: geom.PhysicalOffset,
    phase: PointerPhase,
};

/// Pointer callbacks installed on a RenderObject (via base.pointer) by a gesture
/// widget. Each callback carries an explicit ctx because Zig function pointers
/// cannot close over state; the installing render object passes itself as ctx.
pub const PointerHandlers = struct {
    ctx: *anyopaque,
    on_down: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_up: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_move: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_enter: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_leave: ?*const fn (ctx: *anyopaque, ev: PointerEvent) void = null,
    on_scroll: ?*const fn (ctx: *anyopaque, dx: f32, dy: f32) void = null,
};
