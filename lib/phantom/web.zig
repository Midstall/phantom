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
        phantom.backend.dom_calls.render(self.gpa, self.ops, canvas.list, physical, phantom.ColorScheme.tokyoNight().bg) catch |err| {
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
};

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
