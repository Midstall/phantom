const std = @import("std");
const builtin = @import("builtin");
const phantom = @import("../phantom.zig");

/// Linux is the only target with the lattice compositor path today. Everywhere else
/// the terminal is the only backend, so the detection cannot return `.gpu` there and
/// the lattice import is never analyzed.
const gpu_available = builtin.os.tag == .linux;

const lattice = if (gpu_available) @import("lattice") else void;
const prism = if (gpu_available) @import("prism") else void;

const Dispatch = struct {
    running: bool = true,
    root: *phantom.Element,
    scale: f32 = 1.0,
    last: phantom.PhysicalOffset = phantom.PhysicalOffset.zero,
    dispatcher: phantom.input.Dispatcher = .{},
};

fn handler(ctx_data: *anyopaque, ev: lattice.Event) void {
    const d: *Dispatch = @ptrCast(@alignCast(ctx_data));
    switch (ev) {
        .close_requested => d.running = false,
        .input => |ie| switch (ie) {
            .pointer_motion => |m| {
                d.last = .{ .x = @as(f32, @floatCast(m.x)) * d.scale, .y = @as(f32, @floatCast(m.y)) * d.scale };
                d.dispatcher.move(d.root, d.last);
            },
            .pointer_button => |btn| switch (btn.state) {
                .pressed => d.dispatcher.down(d.root, d.last),
                .released => d.dispatcher.up(d.root, d.last),
            },
            .pointer_axis => |a| d.dispatcher.scroll(d.root, d.last, @as(f32, @floatCast(a.horizontal)) * d.scale, @as(f32, @floatCast(a.vertical)) * d.scale),
            else => {},
        },
        else => {},
    }
}

pub const Backend = enum { gpu, tui, none };

/// Choose the backend. The environment override comes first so a user can always
/// force a choice. A compositor means a window is possible, and a terminal on stdout
/// means the terminal path works. Neither means the program cannot draw at all.
pub fn selectBackend(env: *const std.process.Environ.Map, stdout_is_tty: bool) Backend {
    if (!gpu_available) {
        return if (stdout_is_tty) .tui else .none;
    }
    if (env.get("PHANTOM_BACKEND")) |want| {
        if (std.mem.eql(u8, want, "tui")) return .tui;
        if (std.mem.eql(u8, want, "gpu")) return .gpu;
        // Any other value is user input and is a runtime fault, so the detection runs
        // instead of the program failing.
    }
    if (env.get("WAYLAND_DISPLAY") != null) return .gpu;
    if (env.get("DISPLAY") != null) return .gpu;
    if (stdout_is_tty) return .tui;
    return .none;
}

test "the environment override wins over everything else" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PHANTOM_BACKEND", "tui");
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, true));

    try env.put("PHANTOM_BACKEND", "gpu");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true));
}

test "a Wayland display selects the GPU backend" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true));
}

test "an X display with no Wayland socket selects the GPU backend" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("DISPLAY", ":0");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true));
}

test "a Wayland display beats an X display when both are set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try env.put("DISPLAY", ":0");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true));
}

test "no display and a terminal selects the terminal backend" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    // selectBackend only reads stdout_is_tty, not TERM, so the map stays empty.
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, true));
}

test "no display and no terminal selects nothing" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Backend.none, selectBackend(&env, false));
}

test "an unknown override value is ignored and the detection runs" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PHANTOM_BACKEND", "nonsense");
    try env.put("WAYLAND_DISPLAY", "wayland-0");
    try std.testing.expectEqual(Backend.gpu, selectBackend(&env, true));
}

test "an unknown override value with no display and a terminal falls through to the terminal backend" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PHANTOM_BACKEND", "nonsense");
    try std.testing.expectEqual(Backend.tui, selectBackend(&env, true));
}

pub const App = struct {
    /// Pick the backend and dispatch to it. A compositor gives the window path, a
    /// terminal on stdout gives the terminal path, and neither is a runtime fault:
    /// it fails loudly instead of drawing nothing and leaving the person to guess why.
    pub fn run(init: std.process.Init, root: phantom.Root) !void {
        // The terminal backend draws every frame to stdout (see Term.out in
        // lib/phantom/tui/term.zig), so stdout is the fd that decides whether the
        // terminal path can work. A terminal on stderr with stdout piped elsewhere
        // (`phantom-hello-tui | less`, for example) cannot receive the alt-screen and
        // cursor control codes without corrupting the pipe's data, so this checks
        // stdout alone and never falls back to stderr.
        const is_tty = std.Io.File.stdout().isTty(init.io) catch false;
        switch (selectBackend(init.environ_map, is_tty)) {
            .gpu => {
                if (!gpu_available) unreachable; // selectBackend cannot return this
                return runGpu(init, root);
            },
            .tui => return phantom.Tui.run(init, root, .{}),
            .none => {
                // A clear message, because "it did nothing" is the worst outcome here.
                var buf: [256]u8 = undefined;
                var w = std.Io.File.stderr().writerStreaming(init.io, &buf);
                try w.interface.writeAll(
                    "phantom: no display and no terminal.\n" ++
                        "Set WAYLAND_DISPLAY or DISPLAY for a window, run in a terminal, " ++
                        "or set PHANTOM_BACKEND=tui or gpu.\n",
                );
                try w.interface.flush();
                return error.NoBackend;
            },
        }
    }

    fn runGpu(init: std.process.Init, root: phantom.Root) !void {
        const gpa = init.gpa;

        var ctx = try lattice.Context.init(gpa, init.io, init.environ_map, .{
            .initial_width = 800,
            .initial_height = 600,
            .driver = null,
        });
        defer ctx.deinit();

        const dev = ctx.renderDevice() orelse return error.NoRenderDevice;
        var backend = try phantom.backend.PrismBackend.init(dev.*, gpa);
        defer backend.deinit();
        // On-screen GL surface (default framebuffer, bottom-left origin): flip Y so the
        // top-left frontend coordinate space presents upright. Offscreen goldens leave
        // this false.
        backend.flip_y = true;

        const surface = try ctx.createSurface(.{
            .title = "phantom",
            .width = 800,
            .height = 600,
            .color = lattice.ColorConfig.sdr(.xrgb8888),
        });
        defer ctx.destroySurface(surface.id);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        // A recovered fault has to reach a human, and this is the program that
        // owns the process, so its own stderr is where that is. Both of these
        // outlive the loop below, which is what the sink's borrowed pointer
        // needs.
        var diag_buf: [256]u8 = undefined;
        var diag = std.Io.File.stderr().writerStreaming(init.io, &diag_buf);
        var sink = phantom.FaultSink{ .diagnostics = &diag.interface };
        var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink, .io = init.io };
        defer owner.deinit();

        // Build a View from the surface's logical size. lattice does not negotiate
        // buffer scaling today so rt.width == desc.width and the framebuffer ratio
        // evaluates to 1.0. The machinery is wired; native auto-upgrades when lattice
        // adds buffer scaling (wl_surface.set_buffer_scale or fractional-scale protocol).
        // NOTE: native HiDPI is blocked on lattice until that protocol lands.
        const logical = phantom.LogicalSize{
            .width = @floatFromInt(surface.desc.width),
            .height = @floatFromInt(surface.desc.height),
        };
        const view_id = try phantom.View.open(&owner, .{
            .title = "phantom",
            .size = logical,
            .dpr = 1.0,
            .text_scale = 1.0,
        });
        _ = view_id;
        const view = owner.activeView().?;

        var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };
        const root_widget = root.call(&bctx);

        var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
        const el = if (sink.ok())
            try mq.widget().mount(&bctx, null)
        else eb: {
            const errbox = phantom.ErrorBox{};
            break :eb try errbox.widget().mount(&bctx, null);
        };
        defer el.deinit(gpa);

        var canvas = phantom.Canvas.init(gpa);
        canvas.sink = &sink;
        defer canvas.deinit();

        var st = Dispatch{ .root = el };
        // Wire the instance Dispatcher so Element.deinit forgets the handlers of any
        // unmounted hovered/pressed render object. st outlives the loop (stable stack).
        owner.dispatcher = &st.dispatcher;
        while (st.running) {
            if (ctx.renderAvailable(surface.id)) {
                const ts = std.Io.Clock.now(.awake, init.io);
                owner.scheduler.tick(ts.nanoseconds);
                owner.flushDirty(&bctx);
                const rt = try ctx.renderTarget(surface.id);
                const vp = phantom.PhysicalSize{ .width = @floatFromInt(rt.width), .height = @floatFromInt(rt.height) };
                canvas.clear();
                const ro = el.renderObject() orelse return error.NoRootRenderObject;
                // Native has no buffer scaling (lattice does not set wl_surface.set_buffer_scale
                // nor implement fractional-scale), so the surface, the framebuffer, AND the
                // wl_pointer surface-local coordinates are all the SAME physical pixels 1:1 at
                // the current surface size. The DPI scale is therefore 1.0. Do NOT derive it
                // from rt.width/surface.desc.width: a tiling/resizing compositor makes rt.width
                // differ from the requested desc.width, and that ratio is a window RESIZE, not
                // a DPI scale. Using it would zoom the content AND multiply pointer coords, so
                // hit-testing would miss. When lattice gains HiDPI, derive dpr from the
                // wl_output scale / fractional-scale protocol (not from rt/desc).
                const scale: f32 = 1.0;
                st.scale = scale;
                // Logical size == physical size at scale 1.0. This is the CURRENT surface size
                // (rt), so MediaQuery.of reports the live size on resize; the per-frame ro.layout
                // below IS the relayout.
                const logical_now = phantom.LogicalSize{
                    .width = @as(f32, @floatFromInt(rt.width)),
                    .height = @as(f32, @floatFromInt(rt.height)),
                };
                owner.setActiveViewMetrics(.{ .size = logical_now, .dpr = scale, .text_scale = 1.0 });
                _ = ro.layout(phantom.BoxConstraints.tightScaled(vp, scale));
                try ro.paint(&canvas, phantom.PhysicalOffset.zero);
                try backend.render(rt.context.*, rt.target, vp, canvas.list, phantom.ColorScheme.tokyoNight().bg);
                try ctx.commit(surface.id);
                // Transient configs produced during this build pass are dead now that
                // mount/update copied everything they keep into the gpa tree.
                _ = arena.reset(.retain_capacity);
            }
            try ctx.poll(16, handler, &st);
        }
    }
};
