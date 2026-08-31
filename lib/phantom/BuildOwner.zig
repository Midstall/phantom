//! Owns the persistent element tree's allocator and the dirty-rebuild queue. The frame
//! loop (App.run) and the test harness call flushDirty before layout and paint. File as
//! struct: the file IS the BuildOwner type.

const std = @import("std");
const widget_mod = @import("widget.zig");
const Element = widget_mod.Element;
const FaultSink = @import("FaultSink.zig");
const BuildContext = @import("BuildContext.zig");
const theme_mod = @import("theme.zig");
const Font = @import("text/Font.zig");
const view_mod = @import("view.zig");
const View = view_mod.View;
const layout_mod = @import("layout.zig");
const geom_mod = @import("geometry.zig");
const input_mod = @import("input.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const mono = @import("text/mono.zig");
const BuildOwner = @This();

gpa: std.mem.Allocator,
sink: *FaultSink,
/// The resource hub's IO handle. Defaults to std.Io.failing (a portable comptime
/// std.Io that compiles on wasm and refuses any actual operation). App.run
/// overrides it with the process init.io; web.init overrides it with the browser
/// clocks, before the tree is mounted so every initState reads the real one.
io: std.Io = std.Io.failing,
dirty: std.ArrayList(*Element) = .empty,
/// Lazily loaded default theme. Null until the first defaultTheme call on this owner.
default_theme: ?theme_mod.ThemeData = null,
/// Lazily loaded built-in heading font (Neuropol). Freed on deinit.
default_heading_font: ?Font = null,
/// Lazily loaded built-in body font (Mesmerize Rg). Freed on deinit.
default_body_font: ?Font = null,
/// Lazily loaded built-in body bold font (Mesmerize Sb). Freed on deinit.
default_body_bold_font: ?Font = null,
/// All open views for this owner, keyed by view id. Each value is a boxed
/// *View allocated via gpa so &view.metrics is stable across map resizes.
views: std.AutoHashMapUnmanaged(u32, *View) = .empty,
/// The currently active (foreground) view id, or null if no view has been opened.
active_view: ?u32 = null,
/// Monotonically increasing counter used to assign unique ids to new views.
next_view_id: u32 = 0,
/// The active pointer Dispatcher for this instance (set by App.run / the web
/// mount / the test harness). Element.deinit uses it to forget the freed render
/// object's pointer handlers so hovered/pressed can never dangle. Null when no
/// input source is wired (e.g. a pure layout/paint test).
dispatcher: ?*input_mod.Dispatcher = null,
/// Set by the entry point that owns a focus manager. Null when nothing routes keys,
/// which is every backend except the terminal today.
focus: ?*@import("focus.zig").FocusManager = null,
/// Filled in by the backend that has a browser. Every other backend leaves it
/// empty, and the router then keeps its history in memory only.
platform: @import("platform.zig").Platform = .{},
/// The router that owns the address of the page, or null when the tree has
/// none. `Router.State.initState` claims this slot only when it is empty, so
/// the outermost router wins: mounting runs from the top down, so the
/// outermost one arrives first. A nested router keeps its own history and
/// leaves the address bar alone.
router: ?@import("router.zig").RouterHandle = null,
/// Timers and per-frame callbacks for this owner's tree. Ticked by whichever
/// loop is running: App.run natively, the browser animation frame on web.
scheduler: Scheduler = .{},
/// How text measures for this owner. `App.run` and `web.init` leave the default.
/// `tui.Session` sets `.mono` from the terminal cell size before the first build, and it
/// sets it again on each resize. The field is read through a stable pointer that
/// `RenderText` holds, so a change reaches every mounted text node with no rebuild.
text_metrics: mono.TextMetrics = .proportional,

pub fn deinit(self: *BuildOwner) void {
    self.scheduler.deinit(self.gpa);
    if (self.default_heading_font) |*f| f.deinit(self.gpa);
    if (self.default_body_font) |*f| f.deinit(self.gpa);
    if (self.default_body_bold_font) |*f| f.deinit(self.gpa);
    var it = self.views.valueIterator();
    while (it.next()) |v| self.gpa.destroy(v.*);
    self.views.deinit(self.gpa);
    self.dirty.deinit(self.gpa);
}

/// Return the active view, or null if no view has been opened on this owner.
pub fn activeView(self: *BuildOwner) ?*View {
    const id = self.active_view orelse return null;
    return self.views.get(id);
}

/// Mark an element dirty and enqueue it for the next flush. Deduplicated via the dirty
/// flag. If the queue append itself OOMs, clear the flag and report so a later schedule
/// (or an ancestor rebuild) can still pick it up.
pub fn scheduleBuildFor(self: *BuildOwner, el: *Element) void {
    if (el.dirty) return;
    el.dirty = true;
    self.dirty.append(self.gpa, el) catch {
        el.dirty = false;
        self.sink.report(.oom, "scheduleBuildFor: dirty queue append failed");
    };
}

/// Rebuild every dirty element, shallowest first (a parent is rebuilt before a child it
/// might remount). Each element is removed from the queue BEFORE its rebuild, so a rebuild
/// that frees a still-queued descendant (via Element.deinit -> removeFromDirty) can never
/// leave a dangling pointer for a later iteration to dereference. Each rebuild is
/// infallible (soft-fails internally), so one failure never aborts the rest.
pub fn flushDirty(self: *BuildOwner, bctx: *BuildContext) void {
    // TODO: if a future setState-during-build path lands, elements scheduled mid-flush are
    // still drained here (the loop runs until the queue is empty), which is correct; revisit
    // only if ordering guarantees across such nested scheduling become necessary.
    while (self.dirty.items.len > 0) {
        var min_idx: usize = 0;
        for (self.dirty.items, 0..) |el, idx| {
            if (el.depth < self.dirty.items[min_idx].depth) min_idx = idx;
        }
        const el = self.dirty.items[min_idx];
        _ = self.dirty.swapRemove(min_idx);
        el.dirty = false;
        el.rebuild(bctx);
    }
}

/// Drop the element's render-object pointer handlers from the active Dispatcher if
/// wired. Called by Element.deinit BEFORE the render object is freed, so a hovered or
/// pressed target that is being unmounted cannot leave the Dispatcher pointing at
/// freed memory. No-op when no dispatcher is wired or the element has no handlers.
pub fn forgetPointer(self: *BuildOwner, el: *Element) void {
    const d = self.dispatcher orelse return;
    const ro = el.render_object orelse return;
    const p = ro.pointer orelse return;
    d.forget(p);
}

/// Drop the focus handlers of a render object that is being freed. Mirrors
/// `forgetPointer`, and exists for the same reason: a stale pointer in the focus
/// order would be dereferenced by the next key.
pub fn forgetFocus(self: *BuildOwner, h: *@import("focus.zig").FocusHandlers) void {
    if (self.focus) |f| f.forget(h);
}

/// Remove an element from the dirty queue if present and clear its flag. Called by
/// Element.deinit so a freed element never lingers in the queue as a dangling pointer.
pub fn removeFromDirty(self: *BuildOwner, el: *Element) void {
    if (!el.dirty) return;
    el.dirty = false;
    for (self.dirty.items, 0..) |e, idx| {
        if (e == el) {
            _ = self.dirty.swapRemove(idx);
            return;
        }
    }
}

/// Overwrite the active View's metrics in place. Because the View is boxed (gpa-owned
/// pointer), &view.metrics is stable; the installed MediaQuery widget already holds that
/// pointer, so callers see the updated data on the next layout/build pass.
/// No-op when no view is active.
pub fn setActiveViewMetrics(self: *BuildOwner, m: view_mod.MediaQueryData) void {
    const v = self.activeView() orelse return;
    v.metrics = m;
}

/// Re-run layout on the entire render tree from `root`, using the given physical
/// viewport and scale. This is a DEDICATED pass for metrics changes (e.g. window
/// resize, DPR change) and is SEPARATE from flushDirty: it does not touch the dirty
/// queue and does not rebuild any StatefulWidget. Call setActiveViewMetrics first so
/// that MediaQuery.of returns the new values during any subsequent build triggered by
/// the caller.
pub fn forceRelayoutWholeTree(self: *BuildOwner, root: *Element, viewport: geom_mod.PhysicalSize, scale: f32) void {
    _ = self;
    const ro = root.renderObject() orelse return;
    _ = ro.layout(layout_mod.BoxConstraints.tightScaled(viewport, scale));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const phantom_mod = @import("../phantom.zig");

test "forceRelayoutWholeTree re-lays-out at a new scale, setActiveViewMetrics updates dpr" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // Open a view at dpr 1 so MediaQuery has a stable pointer.
    const vid = try view_mod.View.open(&owner, .{
        .title = "test",
        .size = geom_mod.LogicalSize{ .width = 200, .height = 200 },
        .dpr = 1.0,
        .text_scale = 1.0,
    });
    _ = vid;
    const view = owner.activeView().?;

    // Build: MediaQuery wrapping Padding(10) wrapping ColoredBox.
    var box = phantom_mod.ColoredBox{ .color = geom_mod.Color.rgb(0, 0, 1), .radius = 0 };
    var pad = phantom_mod.Padding{
        .insets = geom_mod.LogicalEdgeInsets.all(10),
        .child = box.widget(),
    };
    var mq = phantom_mod.MediaQuery{ .data = &view.metrics, .child = pad.widget() };
    const root = try mq.widget().mount(&bctx, null);
    defer root.deinit(gpa);

    // Initial layout at scale 1: physical 200x200, logical insets 10 -> physical 10 per side.
    // ColoredBox gets 200 - 2*10 = 180.
    _ = root.renderObject().?.layout(layout_mod.BoxConstraints.tightScaled(
        geom_mod.PhysicalSize{ .width = 200, .height = 200 },
        1.0,
    ));
    const box_el = root.child.?.child.?;
    try std.testing.expectEqual(@as(f32, 180), box_el.render_object.?.size.width);
    try std.testing.expectEqual(@as(f32, 180), box_el.render_object.?.size.height);

    // Change metrics to dpr 2 and relayout at 400x400 physical (same logical window).
    // Logical insets 10 -> physical 20 per side; ColoredBox gets 400 - 2*20 = 360.
    owner.setActiveViewMetrics(.{
        .size = geom_mod.LogicalSize{ .width = 200, .height = 200 },
        .dpr = 2.0,
        .text_scale = 1.0,
    });
    owner.forceRelayoutWholeTree(root, geom_mod.PhysicalSize{ .width = 400, .height = 400 }, 2.0);

    try std.testing.expectEqual(@as(f32, 360), box_el.render_object.?.size.width);
    try std.testing.expectEqual(@as(f32, 360), box_el.render_object.?.size.height);
    // Verify the metrics were actually updated on the view.
    try std.testing.expectEqual(@as(f32, 2.0), owner.activeView().?.metrics.dpr);
    try std.testing.expect(sink.ok());
}
