const std = @import("std");
const phantom = @import("../phantom.zig");

/// Heap-allocated, page-lifetime web app. JS holds the pointer returned by init
/// (as a usize) and passes it back to dispatchTap. No module-level globals.
pub const WebApp = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    sink: *phantom.FaultSink,
    owner: *phantom.BuildOwner,
    root: *phantom.Element,
    view: *phantom.View,
    ops: phantom.backend.dom_calls.DomOps,
    dispatcher: phantom.input.Dispatcher = .{},
    /// Nanoseconds since the Unix epoch, from the browser's `Date.now`. This is
    /// the settable clock: NTP and a timezone edit both move it, and it can move
    /// backwards. Only a time of day is read from it. Zero until the first tick.
    wall_ns: i96 = 0,
    /// Nanoseconds since the page time origin, from the browser's
    /// `performance.now`. Never moves backwards, so every deadline is armed
    /// against this one. Zero until the first tick.
    mono_ns: i96 = 0,

    /// Called by the browser once per animation frame. Advances both clocks,
    /// fires due callbacks, and repaints only if something asked for it.
    ///
    /// The scheduler runs on the monotonic clock alone. Armed against wall time,
    /// an NTP step backwards would push every periodic deadline into the future,
    /// and because the repaint below is conditional the page would stop drawing
    /// for the whole length of the step.
    pub fn tick(self: *WebApp, wall_ms: f64, mono_ms: f64) void {
        // Widen the wall clock before the multiply. Date.now is about 1.77e12,
        // and 1.77e12 times 1e6 is past f64's 2^53 exact-integer range, so
        // multiplying in f64 would quantise it to roughly 256 ns. Date.now has
        // no fractional part, so truncating to an integer costs nothing. The
        // monotonic value is small enough to stay exact in f64 and it does carry
        // a fraction, so that one is multiplied as a float.
        self.wall_ns = @as(i96, @intFromFloat(wall_ms)) * std.time.ns_per_ms;
        self.mono_ns = @intFromFloat(mono_ms * std.time.ns_per_ms);
        self.owner.scheduler.tick(self.mono_ns);
        // An unconditional render would rebuild the whole DOM 60 times a
        // second, so repaint only when a callback marked something dirty.
        if (self.owner.dirty.items.len > 0) self.render();
    }

    pub fn render(self: *WebApp) void {
        // One BuildContext per render for flushDirty + layout + paint.
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = self.owner };
        self.owner.flushDirty(&bctx);
        const physical = self.view.metrics.size.toPhysical(self.view.metrics.text_scale);
        var canvas = phantom.Canvas.init(self.gpa);
        canvas.sink = self.sink;
        defer canvas.deinit();
        const ro = self.root.renderObject() orelse return;
        _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, self.view.metrics.text_scale));
        // A dropped frame leaves the previous DOM on screen, which is
        // indistinguishable from "nothing changed" unless it is recorded.
        ro.paint(&canvas, phantom.PhysicalOffset.zero) catch |err| {
            self.sink.report(.render_failed, @errorName(err));
        };
        phantom.backend.dom_calls.render(self.gpa, self.ops, canvas.list, physical, phantom.ColorScheme.tokyoNight().bg, self.sink) catch |err| {
            self.sink.report(.render_failed, @errorName(err));
        };
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn dispatchTap(self: *WebApp, x: f32, y: f32) void {
        // Web layout scale = text_scale = 1.0, so clientX/Y are physical coords.
        const p = phantom.PhysicalOffset{ .x = x, .y = y };
        self.dispatcher.down(self.root, p);
        self.dispatcher.up(self.root, p);
        self.render();
    }

    /// Update the active View metrics (window resized or DPR changed) and
    /// re-render. Mutates the existing boxed View in place, so the installed
    /// MediaQuery.data pointer stays valid and reads the new size.
    pub fn resize(self: *WebApp, logical: phantom.LogicalSize, dpr: f32) void {
        self.owner.setActiveViewMetrics(.{ .size = logical, .dpr = dpr, .text_scale = 1.0 });
        self.render();
    }

    /// The browser moved back or forward. The address bar already holds the new
    /// path, so this only tells the tree. It does nothing when the tree has no
    /// router, which is every application that does not use one.
    pub fn navigate(self: *WebApp, path: []const u8) void {
        const h = self.owner.router orelse return;
        applyLocation(h, path);
        self.render();
    }

    /// The browser moved back or forward, or a host tells the tree the
    /// address changed some other way. Reads the new path through the same
    /// hook the tree already writes with, then tells the router.
    ///
    /// Does nothing when the address cannot be read: with no read hook, or
    /// when `platform.readLocation` refuses an over-long address. The refusal
    /// itself already reports the fault, at the point where the true length
    /// is still known, so this is not a second silent failure.
    pub fn locationChanged(self: *WebApp) void {
        var buf: [phantom.router.max_path]u8 = undefined;
        const path = self.owner.platform.readLocation(&buf) orelse return;
        self.navigate(path);
    }
};

/// Reconciles the router's stack with a browser-driven address change.
///
/// The rule: pop when `path` is the entry already sitting below the stack's
/// top, replace otherwise.
///
/// Back and forward both arrive here as a bare path; the History API gives no
/// direction. A press of Back always lands on the entry the router's stack
/// already holds one below its top, because that is what "back" means, so
/// that case pops and the stack shrinks. Forward, and any other address
/// change, do not match a below-top entry: a popped entry is gone from the
/// router's stack the instant it pops, so the router has nothing to push
/// back. Rather than guess a forward stack it does not have, it replaces the
/// top so the built route tracks the address bar. Replacing here is what
/// keeps the stack from growing on a busy back-and-forth: only a real push
/// (a tapped `RouteLink`) grows it, and only a matched pop shrinks it.
fn applyLocation(h: phantom.RouterHandle, path: []const u8) void {
    if (h.isBelowTop(path)) {
        _ = h.pop();
    } else {
        h.replace(path);
    }
}

fn openUrlThunk(ctx: *anyopaque, url: []const u8) void {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.open_url` is set, so the
    // hook is never null here.
    app.ops.open_url.?(app.ops.ctx, url);
}

fn readLocationThunk(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.read_location` is set, so the
    // hook is never null here.
    return app.ops.read_location.?(app.ops.ctx, buf) orelse {
        // The real address does not fit `buf`. Taking the first max_path
        // bytes would land the tree on a different, shorter route than the
        // one the user is actually on, so the read is refused instead.
        app.sink.report(.location_too_long, "the browser address is longer than the buffer that reads it");
        return null;
    };
}

fn writeLocationThunk(ctx: *anyopaque, path: []const u8, mode: phantom.WriteMode) void {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.write_location` is set, so
    // the hook is never null here.
    // Skip the browser call when the address bar already shows this path. A
    // browser-driven back or forward already moved it before this runs
    // (through `locationChanged`), and writing again would add a duplicate
    // history entry, turning one back-button press into two.
    if (app.ops.read_location) |read| {
        var buf: [phantom.router.max_path]u8 = undefined;
        if (read(app.ops.ctx, &buf)) |cur| {
            if (std.mem.eql(u8, cur, path)) return;
        }
    }
    app.ops.write_location.?(app.ops.ctx, path, mode);
}

fn webNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    // The browser publishes two clocks and they are not interchangeable, so the
    // tag decides which one answers. Exhaustive with no `else`: a new tag must
    // fail to compile rather than land on whichever arm is listed first.
    return switch (clock) {
        // Date.now, the settable one, in Unix epoch nanoseconds.
        .real => .{ .nanoseconds = app.wall_ns },
        // performance.now, monotonic from the page time origin. It usually keeps
        // counting while the machine is suspended, which is exactly `boot`;
        // `awake` accepts that, because its own contract says an implementation
        // may include suspended time when it cannot exclude it.
        .awake, .boot => .{ .nanoseconds = app.mono_ns },
        // No browser exposes per-process or per-thread CPU time: the high
        // resolution timers that would measure it were cut back for Spectre. The
        // zero timestamp is the same answer `std.Io.noNow` gives, and it agrees
        // with `clockResolution`, which still reports these unavailable. Handing
        // back wall time instead would pass elapsed time off as CPU time.
        .cpu_process, .cpu_thread => std.Io.Timestamp.zero,
    };
}

const web_vtable: std.Io.VTable = blk: {
    // 109 entries, of which one is implementable in a browser. The other 108 are
    // taken from `std.Io.failing` verbatim, so this file adds no behaviour it did
    // not implement. Note that `failing` is not uniformly failing: 15 of its
    // entries are `no*` stubs that succeed with a fixed answer (`noRandom` zeroes
    // the buffer, `noDirRead` reports an empty directory, `noAsync` runs the
    // closure inline). Being identical to `failing` is the property this vtable
    // holds, and the test at the bottom of the file is what pins it.
    var vt = std.Io.failing.vtable.*;
    vt.now = webNow;
    break :blk vt;
};

/// A std.Io backed by the browser clocks. `now` is real; every other operation
/// is whatever `std.Io.failing` does with it.
pub fn webIo(app: *WebApp) std.Io {
    return .{ .userdata = app, .vtable = &web_vtable };
}

/// Build the widget tree and keep owner/arena/view alive for the page lifetime.
/// Returns a heap-allocated *WebApp; the caller (JS via wasm) must store the
/// returned pointer and pass it to dispatchTap. Never deinit: the page owns it.
///
/// logical_viewport: window inner size in CSS px (logical; browser handles DPR).
/// device_pixel_ratio: stored in MediaQueryData for widgets to read; NOT applied
/// to layout because the browser maps CSS px to physical pixels via DPR itself.
pub fn init(
    gpa: std.mem.Allocator,
    ops: phantom.backend.dom_calls.DomOps,
    root: phantom.Root,
    logical_viewport: phantom.LogicalSize,
    device_pixel_ratio: f32,
    strategy: phantom.UrlStrategy,
) !*WebApp {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const sink = try gpa.create(phantom.FaultSink);
    sink.* = .{};
    const owner = try gpa.create(phantom.BuildOwner);
    owner.* = .{ .gpa = gpa, .sink = sink };
    const view_id = try phantom.View.open(owner, .{
        .title = "web",
        .size = logical_viewport,
        .dpr = device_pixel_ratio,
        .text_scale = 1.0,
    });
    _ = view_id;
    const view = owner.activeView().?;

    // The WebApp is allocated before the tree is mounted, because the Io borrows
    // its pointer and `owner.io` must already be the browser clock when `mount`
    // runs. `mount` runs every `initState` in the tree, and a State that copies
    // `owner.io` there would keep `std.Io.failing` for the life of the page: its
    // clock would read the zero timestamp on every frame. `root` is the one field
    // mount produces, so it is the one field filled in afterwards.
    const app = try gpa.create(WebApp);
    app.* = .{
        .gpa = gpa,
        .arena = arena,
        .sink = sink,
        .owner = owner,
        .root = undefined,
        .view = view,
        .ops = ops,
    };
    // Wire the instance Dispatcher (heap-stable) so Element.deinit forgets the
    // handlers of any unmounted hovered/pressed render object.
    owner.dispatcher = &app.dispatcher;
    owner.io = webIo(app);
    // Wired before the tree mounts, so a Router's first `sync` (from its
    // initial location) already reaches the address bar, and its first
    // `readLocation` (the deep-link read in `initState`) already reads it.
    //
    // Each hook is installed only when the matching `DomOps` member exists.
    // A host that leaves one null gets a null here too, not a thunk that
    // silently does nothing: `Platform.openUrl` must return false so
    // `Link.tap` reports `link_unsupported`, and `Platform.readLocation` must
    // return null so a missing hook cannot be mistaken for an empty address.
    owner.platform = .{
        .ctx = app,
        .open_url = if (ops.open_url != null) openUrlThunk else null,
        .read_location = if (ops.read_location != null) readLocationThunk else null,
        .write_location = if (ops.write_location != null) writeLocationThunk else null,
        .strategy = strategy,
    };

    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = owner };
    const root_widget = root.call(&bctx);
    var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
    const root_element = if (sink.ok()) try mq.widget().mount(&bctx, null) else eb: {
        const errbox = phantom.ErrorBox{};
        break :eb try errbox.widget().mount(&bctx, null);
    };
    app.root = root_element;

    // Inject @font-face for all fonts used by the initial render ONCE into <head>.
    // Do one layout+paint into a throwaway canvas to discover which fonts the tree uses,
    // build the CSS block, and append a <style> element before the real first render.
    {
        const physical = view.metrics.size.toPhysical(view.metrics.text_scale);
        var font_canvas = phantom.Canvas.init(gpa);
        font_canvas.sink = sink;
        defer font_canvas.deinit();
        if (root_element.renderObject()) |ro| {
            _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, view.metrics.text_scale));
            // A failure here loses the font list, so the first frame draws in a
            // fallback face. Recording it is the only way that is visible.
            ro.paint(&font_canvas, phantom.PhysicalOffset.zero) catch |err| {
                sink.report(.render_failed, @errorName(err));
            };
        }
        const fonts = try phantom.backend.dom.collectFonts(gpa, font_canvas.list);
        defer gpa.free(fonts);
        if (fonts.len > 0) {
            const css = try phantom.backend.dom_calls.fontFaceCss(gpa, fonts);
            defer gpa.free(css);
            const style_node = ops.createElement("style");
            ops.setTextContent(style_node, css);
            ops.appendChild(ops.head, style_node);
        }
    }

    // Reset the default body margin and paint the branded background to the window
    // edges, ONCE, into <head> (mirrors the string backend's base style). Injected at
    // <head> so it survives the per-render clearChildren(body) sweep.
    {
        const bg = phantom.ColorScheme.tokyoNight().bg;
        const css = try std.fmt.allocPrint(gpa, "html,body{{margin:0;background:rgb({d},{d},{d})}}", .{ phantom.backend.dom.ch(bg.r), phantom.backend.dom.ch(bg.g), phantom.backend.dom.ch(bg.b) });
        defer gpa.free(css);
        const style_node = ops.createElement("style");
        ops.setTextContent(style_node, css);
        ops.appendChild(ops.head, style_node);
    }

    app.render();
    return app;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A WebApp with nothing but its clocks set. Every other field is unreachable
/// from `webIo`, which is the whole surface these tests exercise.
fn clockOnlyApp(wall_ns: i96, mono_ns: i96) WebApp {
    return .{
        .gpa = undefined,
        .arena = undefined,
        .sink = undefined,
        .owner = undefined,
        .root = undefined,
        .view = undefined,
        .ops = undefined,
        .wall_ns = wall_ns,
        .mono_ns = mono_ns,
    };
}

test "the web std.Io reports the wall clock the browser last pushed" {
    var app = clockOnlyApp(1_500_000_000, 7);
    const ts = std.Io.Clock.now(.real, webIo(&app));
    try std.testing.expectEqual(@as(i96, 1_500_000_000), ts.nanoseconds);
}

test "the web std.Io answers the monotonic clocks with performance.now, not Date.now" {
    // The two differ by decades in the browser, so reading the wrong one is not
    // a rounding difference. Arming a deadline against the wall clock is what
    // stops the page repainting when NTP steps the clock backwards.
    var app = clockOnlyApp(1_767_225_840_000_000_000, 4_200_000_000);
    const io = webIo(&app);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), std.Io.Clock.now(.awake, io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), std.Io.Clock.now(.boot, io).nanoseconds);
}

test "the web std.Io reports no cpu time rather than passing off elapsed time as cpu time" {
    // A browser exposes no CPU accounting at all. Zero is what an unimplemented
    // clock answers, and `clockResolution` still reports these unavailable.
    var app = clockOnlyApp(1_767_225_840_000_000_000, 4_200_000_000);
    const io = webIo(&app);
    try std.testing.expectEqual(@as(i96, 0), std.Io.Clock.now(.cpu_process, io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), std.Io.Clock.now(.cpu_thread, io).nanoseconds);
}

test "the web std.Io is identical to std.Io.failing in every entry except now" {
    // "Identical to failing", not "fails": 15 of failing's entries are `no*`
    // stubs that succeed with a fixed answer. What must hold is that this file
    // implements exactly one operation and inherits the other 108 unchanged, so
    // the assertion walks the whole vtable rather than sampling one field.
    var app = clockOnlyApp(0, 0);
    const io = webIo(&app);

    var checked: usize = 0;
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |f| {
        if (comptime !std.mem.eql(u8, f.name, "now")) {
            try std.testing.expect(@field(io.vtable, f.name) == @field(std.Io.failing.vtable, f.name));
            checked += 1;
        }
    }
    try std.testing.expect(io.vtable.now != std.Io.failing.vtable.now);
    // A vtable that shrank to nothing would satisfy the loop above vacuously.
    try std.testing.expectEqual(@typeInfo(std.Io.VTable).@"struct".fields.len - 1, checked);
}

// ---------------------------------------------------------------------------
// write_location guard and read_location refusal (no browser: DomOps comes
// from dom_calls.Recorder)
// ---------------------------------------------------------------------------

fn countOccurrences(log: []const []u8, needle: []const u8) usize {
    var n: usize = 0;
    for (log) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

test "writing the same location twice reaches the browser once, and a different one reaches it again" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var app = clockOnlyApp(0, 0);
    app.ops = rec.ops();
    app.sink = &sink;
    app.owner = &owner;
    owner.platform = .{ .ctx = &app, .read_location = readLocationThunk, .write_location = writeLocationThunk };

    owner.platform.writeLocation("/gallery", .push);
    owner.platform.writeLocation("/gallery", .push);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(rec.log.items, "writeLocation("));

    owner.platform.writeLocation("/about", .push);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(rec.log.items, "writeLocation("));
}

fn locFaultHome(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "home" }).widget();
}

const loc_fault_routes = [_]phantom.Route{
    .{ .path = "/", .build = locFaultHome },
};

test "an over long browser address is refused: it reports the fault and the router's location does not change" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    // Longer than the router's own buffer, parked as if the page had been
    // opened on an address nobody typed by hand.
    const long = "/" ++ ("a" ** phantom.router.max_path);
    rec.setLocation(long);

    const r = phantom.Router{ .routes = &loc_fault_routes, .initial = "/", .not_found = locFaultHome };
    var h = try phantom.testing.mount(gpa, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(phantom.Router), phantom.Router.State);
    try std.testing.expectEqualStrings("/", state.location());

    var app = clockOnlyApp(0, 0);
    app.ops = rec.ops();
    app.sink = h.sink;
    app.owner = h.owner;
    h.owner.platform = .{ .ctx = &app, .read_location = readLocationThunk, .write_location = writeLocationThunk };

    app.locationChanged();

    try std.testing.expectEqualStrings("/", state.location());
    try h.expectFault(.location_too_long);
}

test "a browser tick advances the wall clock and the monotonic clock separately" {
    // The two arguments are easy to swap at the call site, and a swap is silent:
    // both are f64 milliseconds. Pinning them apart is what catches it.
    var app = clockOnlyApp(0, 0);
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    app.owner = &owner;

    app.tick(1_767_225_840_000.0, 4200.0);

    try std.testing.expectEqual(@as(i96, 1_767_225_840_000_000_000), app.wall_ns);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), app.mono_ns);
}

// ---------------------------------------------------------------------------
// Bug 2: browser back/forward must never grow the router's stack past
// max_stack, however many times it happens.
// ---------------------------------------------------------------------------

fn ratchetHome(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "home" }).widget();
}
fn ratchetA(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "a" }).widget();
}
const ratchet_routes = [_]phantom.Route{
    .{ .path = "/", .build = ratchetHome },
    .{ .path = "/a", .build = ratchetA },
};

test "clicking a link then pressing back, repeated far more times than max_stack, never exhausts the router's stack" {
    const gpa = std.testing.allocator;
    const r = phantom.Router{ .routes = &ratchet_routes, .initial = "/", .not_found = ratchetHome };
    var h = try phantom.testing.mount(gpa, r.widget());
    defer h.deinit();
    const handle = h.owner.router orelse return error.NoRouterClaimed;

    // A RouteLink push always grows the stack by one; a matched browser
    // back must always shrink it back by one, or a nav bar that alternates
    // the two (the ordinary way to use one) fills the stack for good in
    // well under a minute (this is the bug report). max_stack * 4 clears
    // that bar by a wide margin.
    var i: usize = 0;
    while (i < phantom.router.max_stack * 4) : (i += 1) {
        handle.push("/a");
        applyLocation(handle, "/");
    }

    try std.testing.expect(handle.depth() <= 2);
    try h.expectNoFaults();
}

// ---------------------------------------------------------------------------
// Bug 3: web.init must not install a hook the host never gave it. A missing
// hook and an over-long address are different faults and must stay
// distinguishable.
// ---------------------------------------------------------------------------

fn linkRoot(b: *phantom.BuildContext) phantom.Widget {
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    return b.new(phantom.Link{ .url = "https://example.com", .child = b.new(box).widget() }).widget();
}

fn plainRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) }).widget();
}

fn locFaultRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Router{ .routes = &loc_fault_routes, .initial = "/", .not_found = locFaultHome }).widget();
}

/// Frees everything `init` allocates. `init`'s own doc comment says "never
/// deinit: the page owns it", which is right for the real page, whose
/// process exits from under the app; a test has no such exit, so it tears
/// down by hand instead of leaking under the testing allocator.
fn destroyWebApp(gpa: std.mem.Allocator, app: *WebApp) void {
    app.root.deinit(gpa);
    app.owner.deinit();
    gpa.destroy(app.owner);
    gpa.destroy(app.sink);
    app.arena.deinit();
    gpa.destroy(app.arena);
    gpa.destroy(app);
}

test "web.init leaves the platform's open_url unset when the host has no open_url hook, so a tapped Link reports it is unsupported" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(linkRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    try std.testing.expect(!app.owner.platform.openUrl("https://example.com"));

    const ro = app.root.renderObject().?;
    app.dispatchTap(ro.origin.x + ro.size.width * 0.5, ro.origin.y + ro.size.height * 0.5);

    const f = app.sink.first orelse return error.NoFaultRecorded;
    try std.testing.expectEqual(phantom.FaultCode.link_unsupported, f.code);
}

test "web.init leaves the platform's read_location unset when the host has no read_location hook, so a missing hook is not mistaken for an empty address" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_location = null;
    const app = try init(gpa, ops, phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [phantom.router.max_path]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readLocation(&buf));
}

test "locationChanged does nothing when the host has no read_location hook, rather than routing to an empty path" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_location = null;
    const app = try init(gpa, ops, phantom.Root.plain(locFaultRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    app.locationChanged();

    try std.testing.expect(app.sink.ok());
}
