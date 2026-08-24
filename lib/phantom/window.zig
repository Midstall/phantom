//! The window event loop. This is the compositor equivalent of `tui.Session`.
const std = @import("std");
const phantom = @import("../phantom.zig");

/// Whether the window path can be COMPILED here at all. Not a claim about
/// hardware, and not a claim about whether a window can be opened.
///
/// lattice builds wherever prism does, aarch64-macos included, so the one
/// constraint is prism's and it is stated in one place: see
/// `backend.prism.builds_here`. Whether a window can actually be OPENED is a
/// separate, runtime question, and lattice answers it in `available`.
const compositor_builds = phantom.backend.prism.builds_here;

const lattice = if (compositor_builds) @import("lattice") else void;

/// Whether a window can actually be opened here, asked of lattice rather than
/// guessed from the environment.
///
/// lattice resolves its own backend from `WAYLAND_DISPLAY`, `DISPLAY`,
/// `XDG_SESSION_TYPE` and the DRM device, and its rules are not the obvious
/// ones: an X11 session resolves to the HEADLESS backend, not to a window. A
/// second implementation of that reasoning here would disagree with the first
/// one, and the way it would disagree is that phantom would choose the window
/// backend under X11 and lattice would then quietly render to nothing.
///
/// So this asks by opening a context and reading back what lattice gave it. A
/// backend with no outputs has no screen to put a window on, which is what the
/// headless backend reports, and it is the signal available today without
/// lattice having to expose the resolved backend kind.
///
/// The context is opened and closed again, which costs a compositor round trip
/// once at startup. That is worth more than a guess that can be wrong.
pub fn available(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    // An `if` on a comptime-known condition drops the untaken branch before
    // analysis, which is what keeps `lattice` (a `void` wherever the compositor
    // path does not build) from being reached for members it does not have. An
    // early `return false` above would NOT do that: the rest of the body sits at
    // function scope and is analyzed either way. An aarch64-macos build is what
    // caught this.
    if (compositor_builds) {
        var ctx = lattice.Context.init(gpa, io, environ, .{}) catch return false;
        defer ctx.deinit();
        // A render device is as necessary as a screen: without one there is
        // nothing to draw the window's contents with.
        if (ctx.renderDevice() == null) return false;
        return ctx.outputs().len > 0;
    }
    return false;
}

/// Fold a lattice key event into the shared phantom key event. lattice has
/// already run the keymap: the keysym arrives as the X11 number input.Keysym
/// carries, so the conversion is a bit cast and not a table. The enum is
/// non-exhaustive, so any u32 lattice can send is a valid cast.
///
/// Analyzed only where the compositor path builds: `lattice` is `void`
/// elsewhere, and every reference to this function sits behind that gate.
fn keyEventFromLattice(k: lattice.event.KeyEvent) phantom.input.KeyEvent {
    return .{
        .keysym = @enumFromInt(k.keysym),
        .text = k.text,
        .mods = .{
            .shift = k.mods.shift,
            .ctrl = k.mods.ctrl,
            .alt = k.mods.alt,
            .super = k.mods.super,
        },
        .action = switch (k.state) {
            .pressed => .press,
            .released => .release,
        },
    };
}

/// Route one lattice key event into the focus manager. The window path has no
/// hard quit key: closing a window is the compositor's `close_requested`, and
/// an application's own shortcuts are what `KeyboardListener` is for.
fn dispatchKey(focus_mgr: *phantom.FocusManager, k: lattice.event.KeyEvent) void {
    _ = focus_mgr.dispatch(keyEventFromLattice(k));
}

/// Where a window session draws, and how much of the process it takes over.
///
/// Every default matches what `App.run` did when it was the only way in: a
/// program whose whole job is the window wants all of it. Each field is here so
/// a program that EMBEDS phantom, and already owns its own event loop or its own
/// logging, can keep the piece it owns. This mirrors `tui.Options` field for
/// field wherever the two backends have the same decision to make, so a caller
/// that has driven one already knows how to drive the other.
pub const Options = struct {
    title: []const u8 = "phantom",
    width: u32 = 800,
    height: u32 = 600,

    /// Which lattice backend to open the window on. Null lets lattice probe the
    /// environment, which is what an ordinary application wants.
    driver: ?[]const u8 = null,

    /// Where recovered faults and other diagnostics are written. Null opens a
    /// writer over the process's own stderr. A window session has no display to
    /// corrupt, unlike the terminal one, so stderr is simply where a human
    /// looks; an embedder with its own log passes it here.
    diagnostics: ?*std.Io.Writer = null,

    /// How long `step` waits for compositor events before returning, in
    /// milliseconds. Null blocks until one arrives.
    ///
    /// The default matches a 60Hz frame. A caller with its own loop to run
    /// usually wants zero, which polls what has already arrived and returns at
    /// once, so the loop's other work is not held up for a frame's worth of
    /// time on every turn.
    poll_ms: ?u32 = 16,
};

pub const App = struct {
    /// Run a window application until it closes. This owns the process for as
    /// long as it runs. A caller that cannot give up its own loop drives
    /// `Session` directly instead; this function is the short way to do exactly
    /// what `Session` does with nothing else going on.
    pub fn run(process: std.process.Init, root: phantom.Root, opts: Options) !void {
        // The comptime branch is what keeps `Session`, and through it every
        // lattice type it names, from being analyzed on a target where lattice
        // is a `void`. It is the one gate in this file, so a caller never needs
        // one of its own: `app.zig` calls this unconditionally.
        if (compositor_builds) {
            // A Session holds pointers into its own fields, so it must be built
            // at an address that does not move: see `tui.Tui.run`, which says
            // the same of its own session for the same reason.
            var session: Session = undefined;
            try session.init(process.gpa, process.io, process.environ_map, root, opts);
            defer session.deinit();
            while (try session.step()) {}
            return;
        }
        // Only reachable through `PHANTOM_BACKEND=gpu`, since `available` reports
        // false here and nothing else selects this backend.
        return error.NoWindowBackend;
    }
};

/// One running window application, with the loop left to the caller.
///
/// `init`, then `step` until it returns false, then `deinit`. `App.run` is that
/// sequence and nothing more. Splitting it apart is what lets a program that
/// already has an event loop of its own embed phantom rather than hand its
/// process over to it.
///
/// Build it in place at a stable address: see `App.run` for why.
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,

    ctx: lattice.Context,
    surface: lattice.Surface,
    backend: phantom.backend.PrismBackend,

    /// Backs `diag_writer`. Unused when the caller supplied a writer.
    diag_buf: [256]u8,
    diag_writer: std.Io.File.Writer,

    arena: std.heap.ArenaAllocator,
    sink: phantom.FaultSink,
    owner: phantom.BuildOwner,
    el: *phantom.Element,
    canvas: phantom.Canvas,

    dispatcher: phantom.input.Dispatcher,
    /// The focus manager owns keyboard traversal for the tree. It must outlive
    /// the element tree: tearing the tree down walks every render object and
    /// calls back into this to forget its focus handler, which is why `deinit`
    /// takes the tree down first. Mirrors `tui.Session`.
    focus_mgr: phantom.FocusManager,
    /// The last pointer position, in physical pixels. A button and a scroll
    /// report no position of their own, so both land wherever the last motion
    /// left the pointer.
    last_point: phantom.PhysicalOffset,
    /// Physical pixels for each logical pixel, applied to incoming pointer
    /// coordinates as well as to layout. See `step` for why it is 1.0 today.
    scale: f32,
    running: bool,

    /// Open the window and mount the tree. On any failure this unwinds
    /// everything it already did, so a caller that gets an error must NOT call
    /// `deinit`.
    ///
    /// Takes the allocator, the I/O and the environment one at a time rather
    /// than a whole `std.process.Init`, for the same reason `tui.Session.init`
    /// does: those three are all a session reads, and a caller that built its
    /// own environment map has no `std.process.Init` to hand over.
    pub fn init(
        self: *Session,
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        root: phantom.Root,
        opts: Options,
    ) !void {
        self.gpa = gpa;
        self.io = io;
        self.opts = opts;

        self.ctx = try lattice.Context.init(gpa, io, environ, .{
            .initial_width = opts.width,
            .initial_height = opts.height,
            .driver = opts.driver,
        });
        errdefer self.ctx.deinit();

        const dev = self.ctx.renderDevice() orelse return error.NoRenderDevice;
        self.backend = try phantom.backend.PrismBackend.init(dev.*, gpa);
        errdefer self.backend.deinit();
        // On-screen GL surface (default framebuffer, bottom-left origin): flip Y
        // so the top-left frontend coordinate space presents upright. Offscreen
        // goldens leave this false.
        self.backend.flip_y = true;

        self.surface = try self.ctx.createSurface(.{
            .title = opts.title,
            .width = opts.width,
            .height = opts.height,
            .color = lattice.ColorConfig.sdr(.xrgb8888),
        });
        errdefer self.ctx.destroySurface(self.surface.id);

        self.diag_writer = std.Io.File.stderr().writerStreaming(io, &self.diag_buf);
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.sink = .{ .diagnostics = opts.diagnostics orelse &self.diag_writer.interface };
        self.owner = .{ .gpa = gpa, .sink = &self.sink, .io = io };
        errdefer self.owner.deinit();

        // Build a View from the surface's logical size. lattice does not
        // negotiate buffer scaling today so rt.width == desc.width and the
        // framebuffer ratio evaluates to 1.0. The machinery is wired; native
        // auto-upgrades when lattice adds buffer scaling (set_buffer_scale or
        // the fractional-scale protocol). Native HiDPI is blocked on lattice
        // until that protocol lands.
        _ = try phantom.View.open(&self.owner, .{
            .title = opts.title,
            .size = .{
                .width = @floatFromInt(self.surface.desc.width),
                .height = @floatFromInt(self.surface.desc.height),
            },
            .dpr = 1.0,
            .text_scale = 1.0,
        });
        const view = self.owner.activeView().?;

        // The focus manager must exist before the tree does: a failed mount
        // tears the partial tree down through `errdefer`, and that walk calls
        // back into the manager to forget each focus handler. Mirrors
        // `tui.Session.init`.
        self.focus_mgr = .{};
        errdefer self.focus_mgr.deinit(gpa);
        self.owner.focus = &self.focus_mgr;

        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const root_widget = root.call(&bctx);
        var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
        self.el = if (self.sink.ok())
            try mq.widget().mount(&bctx, null)
        else eb: {
            const errbox = phantom.ErrorBox{};
            break :eb try errbox.widget().mount(&bctx, null);
        };
        errdefer self.el.deinit(gpa);

        self.canvas = phantom.Canvas.init(gpa);
        self.canvas.sink = &self.sink;
        errdefer self.canvas.deinit();

        self.dispatcher = .{};
        // Wired so `Element.deinit` forgets the handlers of any unmounted
        // hovered or pressed render object.
        self.owner.dispatcher = &self.dispatcher;
        self.last_point = phantom.PhysicalOffset.zero;
        self.scale = 1.0;
        self.running = true;
    }

    /// Put back everything `init` set up, tree first and window last, so nothing
    /// that draws outlives the surface it draws to.
    pub fn deinit(self: *Session) void {
        self.canvas.deinit();
        self.el.deinit(self.gpa);
        self.focus_mgr.deinit(self.gpa);
        self.owner.deinit();
        self.arena.deinit();
        self.ctx.destroySurface(self.surface.id);
        self.backend.deinit();
        self.ctx.deinit();
        self.* = undefined;
    }

    /// Draw a frame if the compositor is ready for one, then take in whatever
    /// events have arrived. Returns false once the window has closed, at which
    /// point the caller stops calling it and calls `deinit`.
    pub fn step(self: *Session) !bool {
        if (!self.running) return false;
        if (self.ctx.renderAvailable(self.surface.id)) try self.renderFrame();
        try self.ctx.poll(self.opts.poll_ms, handleEvent, self);
        return self.running;
    }

    /// Stop at the end of the current turn. Safe to call from a widget callback
    /// during `step`: the loop reads it on the way out.
    pub fn requestStop(self: *Session) void {
        self.running = false;
    }

    fn renderFrame(self: *Session) !void {
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const ts = std.Io.Clock.now(.awake, self.io);
        self.owner.scheduler.tick(ts.nanoseconds);
        self.owner.flushDirty(&bctx);
        // A rebuild can add or remove focusable nodes, so the traversal order is
        // rebuilt from the tree rather than kept incrementally.
        try self.focus_mgr.collect(self.gpa, self.el);

        const rt = try self.ctx.renderTarget(self.surface.id);
        const vp = phantom.PhysicalSize{
            .width = @floatFromInt(rt.width),
            .height = @floatFromInt(rt.height),
        };
        self.canvas.clear();
        const ro = self.el.renderObject() orelse return error.NoRootRenderObject;

        // Native has no buffer scaling (lattice sets neither set_buffer_scale
        // nor fractional-scale), so the surface, the framebuffer AND the
        // wl_pointer surface-local coordinates are all the SAME physical pixels
        // 1:1 at the current surface size. The scale is therefore 1.0. Do NOT
        // derive it from rt.width/surface.desc.width: a tiling or resizing
        // compositor makes rt.width differ from the requested desc.width, and
        // that ratio is a window RESIZE, not a DPI scale. Using it would zoom
        // the content AND multiply pointer coordinates, so hit testing would
        // miss. When lattice gains HiDPI, derive this from the wl_output scale
        // or the fractional-scale protocol, not from rt against desc.
        self.scale = 1.0;
        // Logical size equals physical size at scale 1.0. This is the CURRENT
        // surface size, so `MediaQuery.of` reports the live size on a resize;
        // the layout below IS the relayout.
        self.owner.setActiveViewMetrics(.{
            .size = .{ .width = vp.width, .height = vp.height },
            .dpr = self.scale,
            .text_scale = 1.0,
        });
        _ = ro.layout(phantom.BoxConstraints.tightScaled(vp, self.scale));
        try ro.paint(&self.canvas, phantom.PhysicalOffset.zero);
        try self.backend.render(
            rt.context.*,
            rt.target,
            vp,
            self.canvas.list,
            phantom.ColorScheme.tokyoNight().bg,
        );
        try self.ctx.commit(self.surface.id);
        // Transient configs produced during this build pass are dead now that
        // mount/update copied everything they keep into the gpa tree.
        _ = self.arena.reset(.retain_capacity);
    }

    /// Turn one compositor event into a dispatch into the tree.
    ///
    /// Separate from `dispatchEvent` only because lattice hands a callback an
    /// opaque pointer. Everything this decides lives in `dispatchEvent`, which
    /// takes a real `*Session` and can therefore be tested without a compositor.
    fn handleEvent(ctx_data: *anyopaque, ev: lattice.Event) void {
        const self: *Session = @ptrCast(@alignCast(ctx_data));
        self.dispatchEvent(ev);
    }

    /// What each compositor event does to the tree.
    ///
    /// A pointer button and a scroll carry no position of their own, so both use
    /// wherever the last motion left the pointer.
    pub fn dispatchEvent(self: *Session, ev: lattice.Event) void {
        switch (ev) {
            .close_requested => self.running = false,
            .input => |ie| switch (ie) {
                .pointer_motion => |m| {
                    self.last_point = .{
                        .x = @as(f32, @floatCast(m.x)) * self.scale,
                        .y = @as(f32, @floatCast(m.y)) * self.scale,
                    };
                    self.dispatcher.move(self.el, self.last_point);
                },
                .pointer_button => |btn| switch (btn.state) {
                    .pressed => self.dispatcher.down(self.el, self.last_point),
                    .released => self.dispatcher.up(self.el, self.last_point),
                },
                .pointer_axis => |a| self.dispatcher.scroll(
                    self.el,
                    self.last_point,
                    @as(f32, @floatCast(a.horizontal)) * self.scale,
                    @as(f32, @floatCast(a.vertical)) * self.scale,
                ),
                .key => |k| dispatchKey(&self.focus_mgr, k),
                else => {},
            },
            else => {},
        }
    }
};

test "a lattice key event becomes a phantom key event" {
    if (!compositor_builds) return;
    const lk = lattice.event.KeyEvent{
        .keycode = 30,
        .state = .pressed,
        .keysym = 'a',
        .mods = .{ .shift = true },
        .text = "A",
    };
    const ev = keyEventFromLattice(lk);
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint('a'), ev.keysym);
    try std.testing.expectEqualStrings("A", ev.text.?);
    try std.testing.expect(ev.mods.shift);
    try std.testing.expect(!ev.mods.ctrl);
    try std.testing.expectEqual(phantom.input.KeyAction.press, ev.action);
}

test "a released lattice key reports the release action and keeps its keysym" {
    if (!compositor_builds) return;
    const lk = lattice.event.KeyEvent{ .keycode = 30, .state = .released, .keysym = 'a' };
    const ev = keyEventFromLattice(lk);
    try std.testing.expectEqual(phantom.input.KeyAction.release, ev.action);
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint('a'), ev.keysym);
    try std.testing.expect(ev.text == null);
    try std.testing.expect(ev.mods.none());
}

test "a key event reaches the focused node's handler" {
    if (!compositor_builds) return;
    const Seen = struct {
        var last: ?phantom.input.Keysym = null;
        fn onKey(_: *anyopaque, ev: phantom.input.KeyEvent) bool {
            last = ev.keysym;
            return true;
        }
    };
    Seen.last = null;

    var dummy: u8 = 0;
    var handlers = phantom.FocusHandlers{ .ctx = &dummy, .on_key = Seen.onKey };
    var mgr = phantom.FocusManager{};
    defer mgr.deinit(std.testing.allocator);
    try mgr.order.append(std.testing.allocator, &handlers);
    mgr.focusNext();

    dispatchKey(&mgr, .{ .keycode = 30, .state = .pressed, .keysym = 'a' });
    try std.testing.expectEqual(@as(?phantom.input.Keysym, phantom.input.Keysym.fromCodepoint('a')), Seen.last);
}

test "Tab moves the focus through the window path" {
    if (!compositor_builds) return;
    var dummy: u8 = 0;
    var first = phantom.FocusHandlers{ .ctx = &dummy };
    var second = phantom.FocusHandlers{ .ctx = &dummy };
    var mgr = phantom.FocusManager{};
    defer mgr.deinit(std.testing.allocator);
    try mgr.order.append(std.testing.allocator, &first);
    try mgr.order.append(std.testing.allocator, &second);
    mgr.focusNext();

    // 0xFF09 is the X11 Tab keysym, which is what lattice reports after its
    // keymap resolves the key.
    dispatchKey(&mgr, .{ .keycode = 15, .state = .pressed, .keysym = 0xFF09 });
    try std.testing.expect(mgr.current == &second);
}

test "the default options open the window phantom has always opened" {
    const o = Options{};
    try std.testing.expectEqualStrings("phantom", o.title);
    try std.testing.expectEqual(@as(u32, 800), o.width);
    try std.testing.expectEqual(@as(u32, 600), o.height);
    // Null lets lattice probe the environment rather than pinning a backend.
    try std.testing.expect(o.driver == null);
    // A frame at 60Hz, which is what `App.run` waited before the split.
    try std.testing.expectEqual(@as(?u32, 16), o.poll_ms);
}
