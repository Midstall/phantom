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

/// A window that has been opened, before a session has been built on it.
///
/// This exists so the question and the answer are the same act. `open` cannot
/// tell a caller a window is possible without opening one, and a caller that
/// then threw that away and opened a second would pay for the whole connection
/// twice: a round trip, the globals, the driver, the seat bind.
///
/// The lattice `Context` is a backend pointer and a flag, with every piece of
/// real state behind that pointer, so handing one over is a copy of two words
/// and not a move of anything live.
///
/// Whoever holds this owns it. `Session.initOn` takes it; anyone else calls
/// `close`.
pub const Opening = if (compositor_builds) struct {
    ctx: lattice.Context,
    surface: lattice.Surface,

    /// Give back the window and the connection, for a caller that asked whether
    /// a window was possible and is not going to draw in one.
    pub fn close(self: *Opening) void {
        self.ctx.destroySurface(self.surface.id);
        self.ctx.deinit();
        self.* = undefined;
    }
} else struct {
    /// Never built: `open` reports null wherever the compositor path does not
    /// compile. The empty shape is what keeps `open`'s signature analyzable on
    /// a target where `lattice` is a `void`.
    pub fn close(self: *Opening) void {
        _ = self;
    }
};

/// Open a window, or report that this machine cannot.
///
/// lattice resolves its own backend from `WAYLAND_DISPLAY`, `DISPLAY`,
/// `XDG_SESSION_TYPE` and the DRM device, and its rules are not the obvious
/// ones: an X11 session resolves to the HEADLESS backend, not to a window. A
/// second implementation of that reasoning here would disagree with the first
/// one, and the way it would disagree is that phantom would choose the window
/// backend under X11 and lattice would then quietly render to nothing.
///
/// So this does not predict. It opens the context, checks that lattice gave it
/// a render device and a screen, and then CREATES THE SURFACE, because that is
/// the step that fails on a backend which answers every earlier question and
/// still cannot put a window up. A probe that stopped before it would report
/// yes and leave the real start to fail with `NotImplemented`.
///
/// Null means no window here, with everything this opened already closed.
pub fn open(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: Options,
) ?Opening {
    // An `if` on a comptime-known condition drops the untaken branch before
    // analysis, which is what keeps `lattice` (a `void` wherever the compositor
    // path does not build) from being reached for members it does not have. An
    // early `return null` above would NOT do that: the rest of the body sits at
    // function scope and is analyzed either way. An aarch64-macos build is what
    // caught this.
    if (compositor_builds) {
        var ctx = lattice.Context.init(gpa, io, environ, .{
            .initial_width = opts.width,
            .initial_height = opts.height,
            .driver = opts.driver,
        }) catch return null;
        // A render device is as necessary as a screen: without one there is
        // nothing to draw the window's contents with.
        if (ctx.renderDevice() == null) {
            ctx.deinit();
            return null;
        }
        // No outputs is what the headless backend reports, and a backend with no
        // screen has nowhere to put a window.
        if (ctx.outputs().len == 0) {
            ctx.deinit();
            return null;
        }
        const surface = ctx.createSurface(.{
            .title = opts.title,
            .width = opts.width,
            .height = opts.height,
            .color = lattice.ColorConfig.sdr(.xrgb8888),
        }) catch {
            ctx.deinit();
            return null;
        };
        return .{ .ctx = ctx, .surface = surface };
    }
    return null;
}

/// Whether a window can be opened here.
///
/// The yes or no on its own, for a caller with nothing to do with the window it
/// proves. It opens one and closes it again, so a caller that WILL go on to
/// draw should call `open` and keep what it gets: that is the same answer
/// without paying for the connection twice.
pub fn available(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) bool {
    var opened = open(gpa, io, environ, .{}) orelse return false;
    opened.close();
    return true;
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
            const opened = open(process.gpa, process.io, process.environ_map, opts) orelse
                return error.NoWindowBackend;
            return runOn(process, opened, root, opts);
        }
        // Only reachable through `PHANTOM_BACKEND=gpu`, since `open` reports null
        // here and nothing else selects this backend.
        return error.NoWindowBackend;
    }

    /// The same, on a window that is already open.
    ///
    /// `app.zig` takes this path: it has to open a window to know whether it can
    /// have one, and this is what keeps that window instead of dropping it and
    /// connecting a second time. Takes ownership of `opened`, whether it returns
    /// an error or not.
    pub fn runOn(process: std.process.Init, opened: Opening, root: phantom.Root, opts: Options) !void {
        if (compositor_builds) {
            // A Session holds pointers into its own fields, so it must be built
            // at an address that does not move: see `tui.Tui.run`, which says
            // the same of its own session for the same reason.
            var session: Session = undefined;
            try session.initOn(process.gpa, process.io, opened, root, opts);
            defer session.deinit();
            while (try session.step()) {}
            return;
        }
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
    /// Whether the last `step` drew. Read through `drewFrame`.
    drew_frame: bool,
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
        const opened = open(gpa, io, environ, opts) orelse return error.NoWindowBackend;
        return self.initOn(gpa, io, opened, root, opts);
    }

    /// Build a session on a window that is already open, taking it over.
    ///
    /// For a caller that asked whether a window was possible and got one back
    /// from `open`: that connection is the connection to draw on, and opening a
    /// second would pay the whole cost again for an answer it already has.
    ///
    /// This takes ownership either way. On success `deinit` gives the window
    /// back; on failure this closes it before returning, so a caller that gets
    /// an error must NOT call `deinit` and must NOT call `Opening.close`.
    pub fn initOn(
        self: *Session,
        gpa: std.mem.Allocator,
        io: std.Io,
        opened: Opening,
        root: phantom.Root,
        opts: Options,
    ) !void {
        self.gpa = gpa;
        self.io = io;
        self.opts = opts;

        self.ctx = opened.ctx;
        self.surface = opened.surface;
        errdefer {
            self.ctx.destroySurface(self.surface.id);
            self.ctx.deinit();
        }

        // `open` already found a device, so this cannot fail through that path.
        // It is still asked rather than assumed, because the answer is the one
        // the backend is built on.
        const dev = self.ctx.renderDevice() orelse return error.NoRenderDevice;
        self.backend = try phantom.backend.PrismBackend.init(dev.*, gpa);
        errdefer self.backend.deinit();
        // On-screen GL surface (default framebuffer, bottom-left origin): flip Y
        // so the top-left frontend coordinate space presents upright. Offscreen
        // goldens leave this false.
        self.backend.flip_y = true;

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
        self.drew_frame = false;
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
    ///
    /// The return value is whether the session is still running and NOT whether
    /// it drew: a compositor that is not ready for a frame yet is the normal
    /// case, not the end of the session. Ask `drewFrame` for that, which is a
    /// question only this backend raises. `tui.Session.step` draws every time,
    /// because a terminal has nothing to hold a frame back.
    pub fn step(self: *Session) !bool {
        if (!self.running) return false;
        self.drew_frame = self.ctx.renderAvailable(self.surface.id);
        if (self.drew_frame) try self.renderFrame();
        try self.ctx.poll(self.opts.poll_ms, handleEvent, self);
        return self.running;
    }

    /// Whether the last `step` drew a frame.
    ///
    /// False when the compositor was not ready for one, which is what `step`
    /// alone cannot tell a caller that tracks repaints. A `step` that returned
    /// false, or one that has not run yet, reports false: nothing was drawn.
    pub fn drewFrame(self: *const Session) bool {
        return self.drew_frame;
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

        // The size comes FIRST, before anything builds. A widget reads it through
        // `MediaQuery.of` during its build, so metrics published after
        // `flushDirty` are the metrics of the frame before: a window resize then
        // takes two frames to show, and the first of them lays out the new size
        // with the old numbers. Asking the surface for its target is what makes
        // the current size known, so that has to move up here too.
        const rt = try self.ctx.renderTarget(self.surface.id);
        const vp = phantom.PhysicalSize{
            .width = @floatFromInt(rt.width),
            .height = @floatFromInt(rt.height),
        };
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

        self.owner.flushDirty(&bctx);
        // A rebuild can add or remove focusable nodes, so the traversal order is
        // rebuilt from the tree rather than kept incrementally.
        try self.focus_mgr.collect(self.gpa, self.el);

        self.canvas.clear();
        const ro = self.el.renderObject() orelse return error.NoRootRenderObject;
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

// ---------------------------------------------------------------------------
// Session tests
//
// lattice's headless backend carries a real prism device, a surface and a
// render target, so a whole `Session` runs on it with no compositor. That is
// what makes the two behaviours below testable at all: everything else about
// the window path needs a display.
// ---------------------------------------------------------------------------

/// A window session standing on lattice's headless backend, with the pieces a
/// test needs to reach: `h` to move the surface size or hold a frame back.
const Fixture = struct {
    threaded: std.Io.Threaded,
    h: *lattice.backends.Headless,
    session: Session,

    fn open(f: *Fixture, gpa: std.mem.Allocator, root: phantom.Root) !void {
        try phantom.backend.prism.requireRaster(gpa);
        f.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer f.threaded.deinit();
        const io = f.threaded.io();

        f.h = try lattice.backends.Headless.init(gpa);
        var ctx = lattice.Context.initWithBackend(f.h.backend());
        errdefer ctx.deinit();
        const surface = try ctx.createSurface(.{
            .title = "test",
            .width = 800,
            .height = 600,
            .color = lattice.ColorConfig.sdr(.xrgb8888),
        });
        // `initOn` takes the window over, which is the seam this exercises.
        try f.session.initOn(gpa, io, .{ .ctx = ctx, .surface = surface }, root, .{ .poll_ms = 0 });
    }

    fn close(f: *Fixture) void {
        f.session.deinit();
        f.threaded.deinit();
    }
};

test "a step that drew and a step that did not are told apart" {
    // `step` returns whether the session is still running, so a compositor that
    // is not ready for a frame and a session that is still going look the same
    // from the outside. A caller tracking repaints needs the other answer.
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    f.open(gpa, phantom.Root.plain(testRoot)) catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer f.close();

    // Nothing has run yet, so nothing has been drawn.
    try std.testing.expect(!f.session.drewFrame());

    f.h.setRenderAvailable(true);
    try std.testing.expect(try f.session.step());
    try std.testing.expect(f.session.drewFrame());

    // The compositor holds the next frame back. The session is still running,
    // and that is exactly the case the return value cannot express.
    f.h.setRenderAvailable(false);
    try std.testing.expect(try f.session.step());
    try std.testing.expect(!f.session.drewFrame());

    // And it recovers, rather than latching off.
    f.h.setRenderAvailable(true);
    try std.testing.expect(try f.session.step());
    try std.testing.expect(f.session.drewFrame());
}

/// Records the viewport width every time it builds. A resize has to reach a
/// build, and this is what reports which frame's numbers it saw.
var seen_width: f32 = 0;

var reader_state: ?*SizeReader.State = null;

const SizeReader = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        pub fn build(s: *State, bctx: *phantom.BuildContext) anyerror!phantom.Widget {
            // The framework owns the state, so the test reaches it through here.
            reader_state = s;
            seen_width = phantom.MediaQuery.of(bctx).size.width;
            return (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget();
        }
    };
    pub fn widget(self: *const SizeReader) phantom.Widget {
        return phantom.StatefulWidget(SizeReader, self);
    }
};

var size_reader = SizeReader{};

fn sizeReaderRoot(_: *phantom.BuildContext) phantom.Widget {
    return size_reader.widget();
}

fn testRoot(_: *phantom.BuildContext) phantom.Widget {
    return (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget();
}

test "a build sees the size of the frame it is building, not the one before" {
    // `renderFrame` used to publish the viewport AFTER `flushDirty`, so a widget
    // reading `MediaQuery.of` during its build got the previous frame's numbers.
    // A window resize then took two frames to show, and the first of them laid
    // out the new size with the old width.
    const gpa = std.testing.allocator;
    var f: Fixture = undefined;
    f.open(gpa, phantom.Root.plain(sizeReaderRoot)) catch |e| switch (e) {
        error.SkipZigTest => return error.SkipZigTest,
        else => return e,
    };
    defer f.close();

    f.h.setRenderAvailable(true);
    _ = try f.session.step();
    try std.testing.expectEqual(@as(f32, 800), seen_width);

    // The surface is now wider, which is what a compositor resize looks like
    // from the render target's side.
    f.h.tw = 1024;
    // Dirty the tree so the next frame rebuilds. Without this `flushDirty` has
    // nothing to do and the test would pass whatever the order was.
    phantom.markNeedsBuild(reader_state.?);
    seen_width = 0;
    _ = try f.session.step();
    try std.testing.expectEqual(@as(f32, 1024), seen_width);
}
