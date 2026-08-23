const std = @import("std");
const phantom = @import("../phantom.zig");
const prism = @import("prism");
const prism_backend = @import("backend/prism.zig");
const cell_grid = @import("backend/cell_grid.zig");
const tui_cells = @import("backend/tui_cells.zig");

const Element = phantom.Element;

pub const Finder = struct { type_name: []const u8 };

pub const find = struct {
    pub fn byType(comptime T: type) Finder {
        return .{ .type_name = @typeName(T) };
    }
};

fn search(el: *Element, f: Finder) ?*Element {
    if (std.mem.eql(u8, el.type_name, f.type_name)) return el;
    if (el.child) |c| return search(c, f);
    return null;
}

pub const Raster = struct {
    gpa: std.mem.Allocator,
    device: prism.Device,
    target: *prism.hal.Resource,
    pixels: []const u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Raster) void {
        self.device.destroyResource(self.target);
        self.device.deinit();
    }

    pub fn expectPixel(self: *Raster, x: u32, y: u32, color: phantom.Color, tol: u8) !void {
        const off = (y * self.width + x) * 4;
        const want = [3]u8{ chan(color.r), chan(color.g), chan(color.b) };
        inline for (0..3) |i| {
            const got = self.pixels[off + i];
            const diff = if (got > want[i]) got - want[i] else want[i] - got;
            if (diff > tol) return error.PixelMismatch;
        }
    }

    fn chan(v: f32) u8 {
        return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
    }
};

pub const TuiRaster = struct {
    grid: cell_grid.CellGrid,

    pub fn deinit(self: *TuiRaster) void {
        self.grid.deinit();
    }

    pub fn expectCell(self: *TuiRaster, col: u16, row: u16, ch: u21) !void {
        const cell = self.grid.cellAt(col, row) orelse return error.CellOutOfRange;
        if (cell.ch != ch) {
            std.debug.print(
                "cell ({d},{d}) is U+{X:0>4} and not U+{X:0>4}\n{s}\n",
                .{ col, row, cell.ch, ch, "grid follows" },
            );
            self.dumpAscii();
            return error.CellMismatch;
        }
    }

    pub fn expectBg(self: *TuiRaster, col: u16, row: u16, want: phantom.Color) !void {
        const cell = self.grid.cellAt(col, row) orelse return error.CellOutOfRange;
        const w = cell_grid.Rgb.fromColor(want);
        if (!cell.bg.eql(w)) {
            std.debug.print(
                "cell ({d},{d}) background is {d},{d},{d} and not {d},{d},{d}\n",
                .{ col, row, cell.bg.r, cell.bg.g, cell.bg.b, w.r, w.g, w.b },
            );
            return error.CellMismatch;
        }
    }

    /// Print the grid as text. A failing cell test is much easier to read next to a
    /// picture of the whole grid than as one coordinate.
    pub fn dumpAscii(self: *TuiRaster) void {
        var row: u16 = 0;
        while (row < self.grid.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < self.grid.cols) : (col += 1) {
                const cell = self.grid.back[@as(usize, row) * self.grid.cols + col];
                const printable = cell.ch >= 0x20 and cell.ch < 0x7F;
                const shown: u8 = if (printable) @intCast(cell.ch) else if (cell.ch == ' ' or cell.ch == 0) '.' else '?';
                std.debug.print("{c}", .{shown});
            }
            std.debug.print("\n", .{});
        }
    }
};

pub const Harness = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    owner: *phantom.BuildOwner,
    sink: *phantom.FaultSink,
    root: *Element,
    canvas: phantom.Canvas,
    dispatcher: phantom.input.Dispatcher = .{},
    viewport: phantom.LogicalSize = .{ .width = 800, .height = 600 },
    dpr: f32 = 1.0,
    strict: bool = false,

    pub fn deinit(self: *Harness) void {
        self.root.deinit(self.gpa);
        self.owner.deinit();
        self.canvas.deinit();
        self.arena.deinit();
        self.gpa.destroy(self.arena);
        self.gpa.destroy(self.owner);
        self.gpa.destroy(self.sink);
    }

    pub fn pump(self: *Harness) !void {
        self.sink.policy = if (self.strict) .strict else .soft;
        self.canvas.sink = self.sink;
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = self.owner };
        self.owner.flushDirty(&bctx);
        self.canvas.clear();
        const ro = self.root.renderObject() orelse return error.NoRootRenderObject;
        const physical = self.viewport.toPhysical(self.dpr);
        _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, self.dpr));
        try ro.paint(&self.canvas, phantom.PhysicalOffset.zero);
        if (self.strict and !self.sink.ok()) return error.PhantomFault;
    }

    pub fn expect(self: *Harness, f: Finder, expected: enum { found, not_found }) !void {
        const got = search(self.root, f);
        switch (expected) {
            .found => try std.testing.expect(got != null),
            .not_found => try std.testing.expect(got == null),
        }
    }

    pub fn expectSize(self: *Harness, f: Finder, w: f32, h: f32) !void {
        const el = search(self.root, f) orelse return error.FinderMatchedNothing;
        const ro = el.renderObject() orelse return error.NoRenderObject;
        try std.testing.expectApproxEqAbs(w, ro.size.width, 0.01);
        try std.testing.expectApproxEqAbs(h, ro.size.height, 0.01);
    }

    pub fn expectHtml(self: *Harness, needle: []const u8) !void {
        const physical = self.viewport.toPhysical(self.dpr);
        const html = try phantom.backend.dom.renderToString(self.gpa, self.canvas.list, physical, phantom.Color.rgb(0, 0, 0));
        defer self.gpa.free(html);
        try std.testing.expect(std.mem.indexOf(u8, html, needle) != null);
    }

    pub fn expectNoFaults(self: *Harness) !void {
        if (!self.sink.ok()) {
            std.debug.print("unexpected phantom fault: {s}: {s}\n", .{ @tagName(self.sink.first.?.code), self.sink.first.?.msg });
            return error.UnexpectedFault;
        }
    }

    pub fn expectFault(self: *Harness, code: phantom.FaultCode) !void {
        const f = self.sink.first orelse return error.NoFaultRecorded;
        try std.testing.expectEqual(code, f.code);
    }

    pub fn expectBuildCount(self: *Harness, f: Finder, n: u32) !void {
        const el = search(self.root, f) orelse return error.FinderMatchedNothing;
        try std.testing.expectEqual(n, el.build_count);
    }

    pub fn stateOf(self: *Harness, f: Finder, comptime T: type) !*T {
        const el = search(self.root, f) orelse return error.FinderMatchedNothing;
        const s = el.state orelse return error.ElementHasNoState;
        return @ptrCast(@alignCast(s));
    }

    pub fn tapAt(self: *Harness, point: phantom.PhysicalOffset) void {
        self.owner.dispatcher = &self.dispatcher;
        self.dispatcher.down(self.root, point);
        self.dispatcher.up(self.root, point);
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = self.owner };
        self.owner.flushDirty(&bctx);
    }

    pub fn moveAt(self: *Harness, point: phantom.PhysicalOffset) !void {
        self.owner.dispatcher = &self.dispatcher;
        self.dispatcher.move(self.root, point);
        try self.pump();
    }

    pub fn scrollAt(self: *Harness, point: phantom.PhysicalOffset, dx: f32, dy: f32) !void {
        self.owner.dispatcher = &self.dispatcher;
        self.dispatcher.scroll(self.root, point, dx, dy);
        try self.pump();
    }

    /// Lay out, paint and rasterize the tree, then hand back the pixels.
    ///
    /// Skips the calling test on a machine that cannot draw at all: see
    /// `backend/prism.zig`'s `canRasterize`. Every caller of this asserts on
    /// rendered pixels, so there is exactly one thing to say when there are
    /// none to inspect, and saying it here means no individual golden has to
    /// remember to ask.
    pub fn rasterize(self: *Harness) !Raster {
        try prism_backend.requireRaster(self.gpa);
        const sel = prism.drivers.createBestDevice(self.gpa) orelse return error.NoPrismDevice;
        const dev = sel.device;
        // Ownership transfers to the returned Raster on success; on any error below,
        // free the device (and target once created) here so tests do not leak.
        errdefer dev.deinit();
        const physical = self.viewport.toPhysical(self.dpr);
        const w: u32 = @intFromFloat(physical.width);
        const h: u32 = @intFromFloat(physical.height);
        const target = try dev.createResource(.{ .image = .{ .width = w, .height = h, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
        errdefer dev.destroyResource(target);
        const ctx = try dev.createContext();
        defer ctx.deinit();
        var backend = try prism_backend.PrismBackend.init(dev, self.gpa);
        defer backend.deinit();
        try backend.render(ctx, target, physical, self.canvas.list, phantom.ColorScheme.tokyoNight().bg);
        const px = try dev.mapResource(target);
        return .{ .gpa = self.gpa, .device = dev, .target = target, .pixels = px, .width = w, .height = h };
    }

    /// Lay out and paint the tree into a character grid. The viewport comes from the
    /// grid, so the widget tree sees the same size the terminal would report.
    pub fn tuiRender(self: *Harness, cols: u16, rows: u16, cell_w: f32, cell_h: f32) !TuiRaster {
        self.owner.text_metrics = .{ .mono = phantom.text.mono.Mono.fromCell(cell_w, cell_h) };
        self.viewport = .{
            .width = @as(f32, @floatFromInt(cols)) * cell_w,
            .height = @as(f32, @floatFromInt(rows)) * cell_h,
        };
        try self.pump();

        var grid = try cell_grid.CellGrid.init(self.gpa, cols, rows);
        errdefer grid.deinit();
        grid.clear(cell_grid.Rgb.fromColor(phantom.ColorScheme.tokyoNight().bg));
        try tui_cells.render(&grid, self.canvas.list, .{ .cell_w = cell_w, .cell_h = cell_h });
        return .{ .grid = grid };
    }
};

pub fn mount(gpa: std.mem.Allocator, root_widget: phantom.Widget) !Harness {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const sink = try gpa.create(phantom.FaultSink);
    sink.* = .{};
    const owner = try gpa.create(phantom.BuildOwner);
    owner.* = .{ .gpa = gpa, .sink = sink };
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = owner };
    const root = try root_widget.mount(&bctx, null);
    return .{ .gpa = gpa, .arena = arena, .owner = owner, .sink = sink, .root = root, .canvas = phantom.Canvas.init(gpa) };
}

test "mount + pump the padded blue box, assert tree/layout/html" {
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0.15, 0.35, 0.85), .radius = 16 };
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(40), .child = box.widget() };

    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    try t.pump();

    try t.expect(find.byType(phantom.ColoredBox), .found);
    try t.expectSize(find.byType(phantom.ColoredBox), 720, 520);
    try t.expectHtml("border-radius:16px");
    try t.expectHtml("left:40px");
}

test "Tier 2: padded blue box rasterizes with a blue center and background padding gap" {
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0.15, 0.35, 0.85), .radius = 16 };
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(40), .child = box.widget() };

    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();

    var r = try t.rasterize();
    defer r.deinit();
    // center is inside the box
    try r.expectPixel(100, 100, phantom.Color.rgb(0.15, 0.35, 0.85), 40);
    // (10,10) is inside the 40px padding gap -> background (Tokyo Night bg #1a1b26)
    try r.expectPixel(10, 10, phantom.ColorScheme.tokyoNight().bg, 40);
}

const FailPaintHelper = struct {
    ro: phantom.RenderObject = .{ .layoutFn = lf, .paintFn = pf },
    fn lf(_: *phantom.RenderObject, c: phantom.BoxConstraints) phantom.PhysicalSize {
        return c.biggest();
    }
    fn pf(_: *phantom.RenderObject, _: *phantom.Canvas, _: phantom.PhysicalOffset) anyerror!void {
        return error.OutOfMemory;
    }
    const vt = phantom.Widget.VTable{ .mount = mnt, .update = upd };
    fn widget(self: *@This()) phantom.Widget {
        return .{ .ptr = self, .vtable = &vt };
    }
    fn mnt(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
        const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
        const gpa = bctx.owner.gpa;
        const ro = try gpa.create(phantom.RenderObject);
        ro.* = self.ro;
        ro.destroyFn = destroyRo;
        const el = try gpa.create(phantom.Element);
        el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vt, .type_name = @typeName(@This()), .render_object = ro, .depth = phantom.widget.depthOf(parent) };
        return el;
    }
    fn upd(_: *const anyopaque, _: *phantom.Element, _: *phantom.BuildContext) anyerror!void {}
    fn destroyRo(ro: *phantom.RenderObject, gpa: std.mem.Allocator) void {
        gpa.destroy(ro);
    }
};

test "expectNoFaults passes on a clean pump" {
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1), .radius = 4 };
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(10), .child = box.widget() };
    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    try t.pump();
    try t.expectNoFaults();
}

test "soft pump records a fault that expectFault detects" {
    var fp = FailPaintHelper{};
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(10), .child = fp.widget() };
    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    try t.pump();
    try t.expectFault(phantom.FaultCode.render_failed);
}

test "strict pump returns an error when a fault occurs" {
    var fp = FailPaintHelper{};
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(10), .child = fp.widget() };
    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    t.strict = true;
    try std.testing.expectError(error.PhantomFault, t.pump());
}

// Inner stateful widget: a box whose radius encodes its own counter.
const Inner = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: u32 = 0,
        box: phantom.ColoredBox = undefined,
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            _ = b;
            s.box = .{ .color = phantom.Color.rgb(0, 0, 1), .radius = @floatFromInt(s.count) };
            return s.box.widget();
        }
    };
    pub fn widget(self: *const Inner) phantom.Widget {
        return phantom.StatefulWidget(Inner, self);
    }
};

// Outer stateful widget: builds an Inner. It should NOT rebuild when Inner rebuilds.
const Outer = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        inner: Inner = .{},
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            _ = b;
            return s.inner.widget();
        }
    };
    pub fn widget(self: *const Outer) phantom.Widget {
        return phantom.StatefulWidget(Outer, self);
    }
};

fn incInner(s: *Inner.State) void {
    s.count += 1;
}

test "setState rebuilds only the target element, not its ancestor" {
    var outer = Outer{};
    var t = try mount(std.testing.allocator, outer.widget());
    defer t.deinit();
    t.viewport = .{ .width = 40, .height = 40 };
    try t.pump();

    try t.expectBuildCount(find.byType(Outer), 1);
    try t.expectBuildCount(find.byType(Inner), 1);

    const inner_state = try t.stateOf(find.byType(Inner), Inner.State);
    phantom.setState(inner_state, incInner);
    try t.pump();

    // Inner rebuilt, Outer did not.
    try t.expectBuildCount(find.byType(Inner), 2);
    try t.expectBuildCount(find.byType(Outer), 1);
    // The reconciled render object reflects the new count.
    var found_radius_one = false;
    for (t.canvas.list.primitives.items) |p| {
        if (p.rrect.radius == 1) found_radius_one = true;
    }
    try std.testing.expect(found_radius_one);
}

test "Tier 2: Text widget rasterizes glyph pixels in expected region, background elsewhere" {
    // Golden: mount a white 'H' at 24px inside a top-padded container, rasterize
    // through Prism end-to-end, then assert:
    //   (a) at least one lit pixel INSIDE the expected glyph bounding box
    //   (b) the far-corner pixel is background (no glyph there)
    // Viewport 200x80. Padding.top=50 shifts the baseline down so the glyph lands
    // on-screen even after the negative top-bearing is applied.
    // The text color is white (1,1,1). Background is Tokyo Night bg (#1a1b26).
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var txt = phantom.Text{ .text = "H", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var pad = phantom.Padding{
        .insets = .{ .left = 0, .top = 50, .right = 0, .bottom = 0 },
        .child = txt.widget(),
    };

    var t = try mount(gpa, pad.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 80 };
    try t.pump();

    var r = try t.rasterize();
    defer r.deinit();

    // (a) Assert at least one lit pixel in the glyph region.
    // origin.y=50 is the run's TOP; the baseline is origin.y + ascent (the line
    // ascent), which places the glyph correctly on the live top-left surface. This
    // offscreen device is a GL (bottom-origin) path, so its readback is vertically
    // inverted relative to the surface, and the 'H' lands near the top of the raster
    // at roughly x[1..22] y[6..23]. We scan the box [x:0..30, y:0..40] for one bright
    // pixel (the white glyph on the dark Tokyo Night bg).
    const glyph_x0: u32 = 0;
    const glyph_x1: u32 = 30;
    const glyph_y0: u32 = 0;
    const glyph_y1: u32 = 40;
    var found_glyph_pixel = false;
    var gy_scan = glyph_y0;
    while (gy_scan < glyph_y1) : (gy_scan += 1) {
        var gx_scan = glyph_x0;
        while (gx_scan < glyph_x1) : (gx_scan += 1) {
            const off = (gy_scan * r.width + gx_scan) * 4;
            // White glyph: all three channels should be high when lit.
            if (r.pixels[off] > 40 and r.pixels[off + 1] > 40 and r.pixels[off + 2] > 40) {
                found_glyph_pixel = true;
            }
        }
    }
    try std.testing.expect(found_glyph_pixel);

    // (b) Assert far-corner pixel is background (Tokyo Night bg #1a1b26, no glyph).
    try r.expectPixel(195, 75, phantom.ColorScheme.tokyoNight().bg, 40);
}

test "Tier 2: themed Text rasterizes Tokyo Night fg glyph pixels on Tokyo Night bg" {
    // Golden: mount Text{ .text = "0", .size = 48 } with NO explicit font or color.
    // The default theme (Tokyo Night + Neuropol body) is resolved automatically.
    // Rasterize through Prism and assert:
    //   (a) at least one lit pixel in the theme fg color region (glyph area)
    //   (b) a background pixel matches the theme bg (#1a1b26)
    const gpa = std.testing.allocator;
    const cs = phantom.ColorScheme.tokyoNight();

    // No explicit Padding.top here; use top=60 so the baseline is on-screen for 48px text.
    var txt = phantom.Text{ .text = "0", .size = 48 };
    var pad = phantom.Padding{
        .insets = .{ .left = 0, .top = 60, .right = 0, .bottom = 0 },
        .child = txt.widget(),
    };

    var t = try mount(gpa, pad.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 160 };
    try t.pump();

    var r = try t.rasterize();
    defer r.deinit();

    // (a) At least one lit pixel in the expected glyph region for '0' at 48px.
    // Glyph starts near x=0..4 with a typical left bearing and is ~30px wide, ~50px tall.
    // Baseline at y=60, top bearing around -36..-32 puts the top near y=24.
    // Scan a generous region [x:1..60, y:20..120].
    var found_fg_pixel = false;
    var gy: u32 = 20;
    while (gy < 120) : (gy += 1) {
        var gx: u32 = 1;
        while (gx < 60) : (gx += 1) {
            const off = (gy * r.width + gx) * 4;
            // Theme fg is #c0caf5 (light lavender): r~192, g~202, b~245.
            // A lit glyph pixel should have notably elevated r, g, b vs the dark bg.
            if (r.pixels[off] > 80 and r.pixels[off + 1] > 80 and r.pixels[off + 2] > 80) {
                found_fg_pixel = true;
            }
        }
    }
    try std.testing.expect(found_fg_pixel);

    // (b) Far-corner pixel is the theme bg (#1a1b26 ~ r:26, g:27, b:38).
    try r.expectPixel(195, 155, cs.bg, 40);
}

test "Padding paints an ErrorBox (fault color) when its child paint fails" {
    const FailPaint = struct {
        ro: phantom.RenderObject = .{ .layoutFn = lf, .paintFn = pf },
        fn lf(_: *phantom.RenderObject, c: phantom.BoxConstraints) phantom.PhysicalSize {
            return c.biggest();
        }
        fn pf(_: *phantom.RenderObject, _: *phantom.Canvas, _: phantom.PhysicalOffset) anyerror!void {
            return error.OutOfMemory;
        }
        const vt = phantom.Widget.VTable{ .mount = mnt, .update = upd };
        fn widget(self: *@This()) phantom.Widget {
            return .{ .ptr = self, .vtable = &vt };
        }
        fn mnt(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*phantom.Element) anyerror!*phantom.Element {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ptr)));
            const gpa = bctx.owner.gpa;
            const ro = try gpa.create(phantom.RenderObject);
            ro.* = self.ro;
            ro.destroyFn = destroyRo;
            const el = try gpa.create(phantom.Element);
            el.* = .{ .owner = bctx.owner, .parent = parent, .vtable = &vt, .type_name = @typeName(@This()), .render_object = ro, .depth = phantom.widget.depthOf(parent) };
            return el;
        }
        fn upd(_: *const anyopaque, _: *phantom.Element, _: *phantom.BuildContext) anyerror!void {}
        fn destroyRo(ro: *phantom.RenderObject, gpa: std.mem.Allocator) void {
            gpa.destroy(ro);
        }
    };

    var fp = FailPaint{};
    var pad = phantom.Padding{ .insets = phantom.LogicalEdgeInsets.all(10), .child = fp.widget() };
    var t = try mount(std.testing.allocator, pad.widget());
    defer t.deinit();
    t.viewport = .{ .width = 100, .height = 100 };
    try t.pump();

    try std.testing.expect(!t.sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.render_failed, t.sink.first.?.code);
    var found_fault_fill = false;
    for (t.canvas.list.primitives.items) |p| {
        const c = p.rrect.color;
        if (c.r == 1 and c.g == 0 and c.b == 1) found_fault_fill = true;
    }
    try std.testing.expect(found_fault_fill);
}

test "Tier 2: dpr=2 doubles glyph geometry and grows the physical framebuffer" {
    // Prove that DPI scaling works end-to-end through the offscreen rasterize path.
    // We rasterize the same Text at dpr=1 and dpr=2 with the same logical viewport
    // (100x60) and assert:
    //   (a) the dpr=2 raster dimensions are 200x120 (physical = logical * dpr)
    //   (b) the lit-glyph bounding-box height at dpr=2 is roughly 2x that at dpr=1
    //
    // The offscreen device may be GL bottom-origin; the glyph can appear near the
    // top of the readback. We scan the whole raster so position does not matter.
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Helper: compute lit-glyph bounding-box height over a raster.
    // A pixel is "lit" when all three channels exceed the threshold (40/255).
    const litBboxHeight = struct {
        fn run(r: *Raster) u32 {
            var min_y: u32 = std.math.maxInt(u32);
            var max_y: u32 = 0;
            var found: bool = false;
            var y: u32 = 0;
            while (y < r.height) : (y += 1) {
                var x: u32 = 0;
                while (x < r.width) : (x += 1) {
                    const off = (y * r.width + x) * 4;
                    if (r.pixels[off] > 40 and r.pixels[off + 1] > 40 and r.pixels[off + 2] > 40) {
                        if (y < min_y) min_y = y;
                        if (y > max_y) max_y = y;
                        found = true;
                    }
                }
            }
            if (!found) return 0;
            return max_y - min_y + 1;
        }
    }.run;

    // Raster at dpr=1: logical 100x60, physical 100x60.
    var txt1 = phantom.Text{ .text = "0", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var pad1 = phantom.Padding{
        .insets = .{ .left = 0, .top = 20, .right = 0, .bottom = 0 },
        .child = txt1.widget(),
    };
    var t1 = try mount(gpa, pad1.widget());
    defer t1.deinit();
    t1.viewport = .{ .width = 100, .height = 60 };
    t1.dpr = 1.0;
    try t1.pump();
    var r1 = try t1.rasterize();
    defer r1.deinit();

    // Raster at dpr=2: same logical viewport, physical 200x120.
    var txt2 = phantom.Text{ .text = "0", .font = &font, .size = 24, .color = phantom.Color.rgb(1, 1, 1) };
    var pad2 = phantom.Padding{
        .insets = .{ .left = 0, .top = 20, .right = 0, .bottom = 0 },
        .child = txt2.widget(),
    };
    var t2 = try mount(gpa, pad2.widget());
    defer t2.deinit();
    t2.viewport = .{ .width = 100, .height = 60 };
    t2.dpr = 2.0;
    try t2.pump();
    var r2 = try t2.rasterize();
    defer r2.deinit();

    // (a) Physical framebuffer is 200x120 at dpr=2.
    try std.testing.expectEqual(@as(u32, 200), r2.width);
    try std.testing.expectEqual(@as(u32, 120), r2.height);

    const h1 = litBboxHeight(&r1);
    const h2 = litBboxHeight(&r2);

    // Both rasters must have at least one lit pixel.
    try std.testing.expect(h1 > 0);
    try std.testing.expect(h2 > 0);

    // (b) The dpr=2 glyph bounding-box height is roughly 2x the dpr=1 height.
    // Allow 1.6..2.4 to accommodate rasterizer rounding.
    const h1f: f32 = @floatFromInt(h1);
    const h2f: f32 = @floatFromInt(h2);
    try std.testing.expect(h2f > h1f * 1.6);
    try std.testing.expect(h2f < h1f * 2.4);
}

fn findPointerRo(el: *phantom.Element) ?*phantom.RenderObject {
    if (el.render_object) |ro| {
        if (ro.pointer != null) return ro;
    }
    if (el.child) |c| {
        if (findPointerRo(c)) |ro| return ro;
    }
    for (el.children.items) |c| {
        if (findPointerRo(c)) |ro| return ro;
    }
    return null;
}

const TapCounter = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: u32 = 0,
        fn inc(s: *@This()) void {
            s.count += 1;
        }
        fn incTap(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            phantom.setState(s, TapCounter.State.inc);
        }
        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const label_text = try std.fmt.allocPrint(b.arena, "{d}", .{s.count});
            const label = b.new(phantom.Text{ .text = label_text, .size = 24 });
            const btn_label = b.new(phantom.Text{ .text = "+", .size = 24 });
            const btn = b.new(phantom.Button{ .on_tap = TapCounter.State.incTap, .ctx = s, .child = btn_label.widget() });
            const kids = b.newSlice(phantom.Widget, &.{ label.widget(), btn.widget() });
            return b.new(phantom.Column(.{ .main = .start, .cross = .start, .children = kids })).widget();
        }
    };
    pub fn widget(self: *const TapCounter) phantom.Widget {
        return phantom.StatefulWidget(TapCounter, self);
    }
};

test "Tier 2: tapping a Button increments a stateful counter" {
    const gpa = std.testing.allocator;
    var t = try mount(gpa, (TapCounter{}).widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();

    // Find the GestureDetector render object (the one with pointer != null) and tap
    // its center. This is layout-independent and will not miss the button.
    const btn_ro = findPointerRo(t.root) orelse return error.NoPointerRenderObject;
    const tap_x = btn_ro.origin.x + btn_ro.size.width * 0.5;
    const tap_y = btn_ro.origin.y + btn_ro.size.height * 0.5;
    t.tapAt(.{ .x = tap_x, .y = tap_y });
    try t.pump();

    const state: *TapCounter.State = @ptrCast(@alignCast(t.root.state.?));
    try std.testing.expectEqual(@as(u32, 1), state.count);
}

test "primary Button display list: filled blue rounded rect painted behind label" {
    // Assert that a primary Button produces a filled (stroke_width == 0) rrect with
    // the theme accent-blue color (#7aa2f7 ~ r=0.478 g=0.635 b=0.969) as its first
    // display-list primitive. This is the T5 golden: brand color baked into the paint.
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var label = phantom.Text{ .text = "+", .font = &font, .size = 14, .color = phantom.Color.rgb(1, 1, 1) };
    var btn = phantom.Button{ .child = label.widget() };

    var t = try mount(gpa, btn.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 100 };
    try t.pump();

    // First primitive in the display list must be a filled blue rrect (the DecoratedBox bg).
    const prims = t.canvas.list.primitives.items;
    try std.testing.expect(prims.len >= 1);
    const rr = prims[0].rrect;
    // stroke_width == 0: filled, not a border ring
    try std.testing.expectEqual(@as(f32, 0), rr.stroke_width);
    // blue #7aa2f7 ~ r=122/255 g=162/255 b=247/255
    try std.testing.expectApproxEqAbs(@as(f32, 122.0 / 255.0), rr.color.r, 0.015);
    try std.testing.expectApproxEqAbs(@as(f32, 162.0 / 255.0), rr.color.g, 0.015);
    try std.testing.expectApproxEqAbs(@as(f32, 247.0 / 255.0), rr.color.b, 0.015);
}

// Helpers for hover/press color assertions.
// blue = #7aa2f7, black = {0,0,0,1}
// hover = mix(blue, black, 0.1) means each channel = blue_ch * 0.9
// pressed = mix(blue, black, 0.2) means each channel = blue_ch * 0.8
const theme_blue = phantom.theme.hex("#7aa2f7");
const theme_bg = phantom.theme.hex("#1a1b26");
const black_color = phantom.Color{ .r = 0, .g = 0, .b = 0, .a = 1 };

fn approxEq(a: f32, b: f32) bool {
    const diff = if (a > b) a - b else b - a;
    return diff < 0.015;
}

test "Harness.moveAt: primary Button hover and press change the display-list rrect color" {
    // Mount a primary Button with a Text child. After pump the base color is theme blue.
    // moveAt into the button center -> rrect color flips to hover color.
    // Dispatcher.down -> pressed color. Dispatcher.up -> back to hover (still inside).
    // moveAt outside -> leave -> base color.
    const gpa = std.testing.allocator;

    var label = phantom.Text{ .text = "X", .size = 14 };
    var btn = phantom.Button{ .child = label.widget() };

    var t = try mount(gpa, btn.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 100 };
    try t.pump();

    // Base color == theme blue
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        try std.testing.expect(approxEq(rr.color.r, theme_blue.r));
        try std.testing.expect(approxEq(rr.color.g, theme_blue.g));
        try std.testing.expect(approxEq(rr.color.b, theme_blue.b));
    }

    // Find the button render object center (it fills the viewport after Padding).
    const btn_ro = findPointerRo(t.root) orelse return error.NoPointerRenderObject;
    const cx = btn_ro.origin.x + btn_ro.size.width * 0.5;
    const cy = btn_ro.origin.y + btn_ro.size.height * 0.5;
    const center = phantom.PhysicalOffset{ .x = cx, .y = cy };

    // moveAt center -> hover color = mix(blue, black, 0.1)
    try t.moveAt(center);
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        const expected_hover = phantom.geometry.Color.mix(theme_blue, black_color, 0.1);
        try std.testing.expect(approxEq(rr.color.r, expected_hover.r));
        try std.testing.expect(approxEq(rr.color.g, expected_hover.g));
        try std.testing.expect(approxEq(rr.color.b, expected_hover.b));
        // hover color must differ from base
        try std.testing.expect(!approxEq(rr.color.r, theme_blue.r) or !approxEq(rr.color.g, theme_blue.g));
    }

    // Press (down) -> pressed color = mix(blue, black, 0.2)
    t.dispatcher.down(t.root, center);
    try t.pump();
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        const expected_pressed = phantom.geometry.Color.mix(theme_blue, black_color, 0.2);
        try std.testing.expect(approxEq(rr.color.r, expected_pressed.r));
        try std.testing.expect(approxEq(rr.color.g, expected_pressed.g));
        try std.testing.expect(approxEq(rr.color.b, expected_pressed.b));
    }

    // Up (still inside) -> back to hover color
    t.dispatcher.up(t.root, center);
    try t.pump();
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        const expected_hover = phantom.geometry.Color.mix(theme_blue, black_color, 0.1);
        try std.testing.expect(approxEq(rr.color.r, expected_hover.r));
        try std.testing.expect(approxEq(rr.color.g, expected_hover.g));
        try std.testing.expect(approxEq(rr.color.b, expected_hover.b));
    }

    // moveAt outside the button -> leave -> base color
    try t.moveAt(.{ .x = -10, .y = -10 });
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        try std.testing.expect(approxEq(rr.color.r, theme_blue.r));
        try std.testing.expect(approxEq(rr.color.g, theme_blue.g));
        try std.testing.expect(approxEq(rr.color.b, theme_blue.b));
    }
}

test "Harness.moveAt: disabled Button ignores hover and tap does not fire on_tap" {
    // A disabled Button: moveAt its center leaves the color at the disabled color.
    // tapAt does NOT call on_tap (counter stays 0).
    const gpa = std.testing.allocator;

    var tap_count: u32 = 0;
    var label = phantom.Text{ .text = "X", .size = 14 };
    var btn = phantom.Button{
        .enabled = false,
        .ctx = &tap_count,
        .on_tap = struct {
            fn f(ctx: *anyopaque) void {
                const c: *u32 = @ptrCast(@alignCast(ctx));
                c.* += 1;
            }
        }.f,
        .child = label.widget(),
    };

    var t = try mount(gpa, btn.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 100 };
    try t.pump();

    // Compute disabled color: mix(blue, bg, 0.6)
    const expected_disabled = phantom.geometry.Color.mix(theme_blue, theme_bg, 0.6);

    // Disabled color on base pump
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        try std.testing.expect(approxEq(rr.color.r, expected_disabled.r));
        try std.testing.expect(approxEq(rr.color.g, expected_disabled.g));
        try std.testing.expect(approxEq(rr.color.b, expected_disabled.b));
    }

    // moveAt center: color must not change (no handlers installed)
    // Use raw bounds: the button fills the 200x100 viewport via its Padding child.
    try t.moveAt(.{ .x = 100, .y = 50 });
    {
        const rr = t.canvas.list.primitives.items[0].rrect;
        try std.testing.expect(approxEq(rr.color.r, expected_disabled.r));
        try std.testing.expect(approxEq(rr.color.g, expected_disabled.g));
        try std.testing.expect(approxEq(rr.color.b, expected_disabled.b));
    }

    // tapAt center: on_tap must NOT fire
    t.tapAt(.{ .x = 100, .y = 50 });
    try std.testing.expectEqual(@as(u32, 0), tap_count);
}

fn findScrollRo(el: *phantom.Element) ?*phantom.RenderObject {
    if (el.render_object) |ro| {
        if (ro.pointer) |h| {
            if (h.on_scroll != null) return ro;
        }
    }
    if (el.child) |c| {
        if (findScrollRo(c)) |ro| return ro;
    }
    for (el.children.items) |c| {
        if (findScrollRo(c)) |ro| return ro;
    }
    return null;
}

test "Harness.scrollAt: vertical ScrollView offset advances and clamps" {
    const gpa = std.testing.allocator;

    // Build a Column of 20 Text items inside a ScrollView. The viewport is 100x100
    // but the Column of 20 rows at size 14 will be much taller than 100px, so the
    // content overflows and scrolling is possible.
    var items: [20]phantom.Text = undefined;
    var item_widgets: [20]phantom.Widget = undefined;
    for (0..20) |i| {
        items[i] = phantom.Text{ .text = "item", .size = 14 };
        item_widgets[i] = items[i].widget();
    }
    var col = phantom.Column(.{ .main = .start, .cross = .start, .children = &item_widgets });
    var sv = phantom.ScrollView{ .child = col.widget() };

    var t = try mount(gpa, sv.widget());
    defer t.deinit();
    t.viewport = .{ .width = 100, .height = 100 };
    try t.pump();

    // The viewport center for a 100x100 harness.
    const center = phantom.PhysicalOffset{ .x = 50, .y = 50 };

    // Confirm a ScrollView render object with on_scroll is in the tree.
    const scroll_ro = findScrollRo(t.root) orelse return error.NoScrollRenderObject;
    _ = scroll_ro;

    // Helper: extract the push_scroll region from the display list after a pump.
    const getPushScroll = struct {
        fn run(prims: []const phantom.Primitive) ?phantom.display_list.ScrollRegion {
            for (prims) |p| {
                switch (p) {
                    .push_scroll => |sr| return sr,
                    else => {},
                }
            }
            return null;
        }
    }.run;

    // After the initial pump the display list has a push_scroll; content must be taller than 100px.
    {
        const sr = getPushScroll(t.canvas.list.primitives.items) orelse return error.NoPushScroll;
        try std.testing.expect(sr.content.height > 100);
    }

    // scrollAt with dy=40: pump re-renders and the push_scroll offset.y must be 40.
    try t.scrollAt(center, 0, 40);
    {
        const sr = getPushScroll(t.canvas.list.primitives.items) orelse return error.NoPushScroll;
        try std.testing.expectApproxEqAbs(@as(f32, 40), sr.offset.y, 0.001);
    }

    // Compute max_y from the push_scroll content/viewport fields (viewport == 100).
    const max_y = blk: {
        const sr = getPushScroll(t.canvas.list.primitives.items) orelse break :blk @as(f32, 0);
        break :blk sr.content.height - sr.viewport.height;
    };
    try std.testing.expect(max_y > 0);

    // scrollAt with huge dy -> clamps to max_y.
    try t.scrollAt(center, 0, 999999);
    {
        const sr = getPushScroll(t.canvas.list.primitives.items) orelse return error.NoPushScroll;
        try std.testing.expectApproxEqAbs(max_y, sr.offset.y, 0.001);
    }
}

test "Element.deinit forgets an unmounted hovered/pressed target from the Dispatcher" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // A standalone Dispatcher wired onto the owner (as App.run / the web mount do).
    var d = phantom.input.Dispatcher{};
    owner.dispatcher = &d;

    var label = phantom.Text{ .text = "X", .size = 14 };
    var btn = phantom.Button{ .child = label.widget() };
    const el = try btn.widget().mount(&bctx, null);

    // Layout + paint so hitTest origins are set.
    var canvas = phantom.Canvas.init(gpa);
    defer canvas.deinit();
    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 100, .height = 60 }));
    try ro.paint(&canvas, phantom.PhysicalOffset.zero);

    // Hover + press the button so the Dispatcher points at its handlers.
    const center = phantom.PhysicalOffset{ .x = 50, .y = 30 };
    d.move(el, center);
    d.down(el, center);
    try std.testing.expect(d.hovered != null);
    try std.testing.expect(d.pressed != null);

    // Unmount the tree while hovered/pressed: Element.deinit must forget the freed
    // handlers so a later move/up cannot dereference freed memory.
    el.deinit(gpa);
    try std.testing.expect(d.hovered == null);
    try std.testing.expect(d.pressed == null);
}

test "REPRO: ScrollView rasterizes through the Prism scissor/segment path" {
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var txt = phantom.Text{ .text = "Hi", .font = &font, .size = 18, .color = phantom.Color.rgb(1, 1, 1) };
    var sv = phantom.ScrollView{ .child = txt.widget() };
    var t = try mount(gpa, sv.widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 80 };
    try t.pump();
    var r = try t.rasterize();
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 200), r.width);
}

test "Tier 2: fromRgba image golden - sampled red quad appears at expected screen location" {
    // Build a 4x4 all-opaque red image via fromRgba, draw it at a known rect,
    // rasterize through Prism, and assert the center pixel of that rect is ~red.
    // This proves rgba8 texture upload + bindTexture + sampled quad end-to-end on
    // the software driver (which already samples a texture for text/atlas goldens).
    const gpa = std.testing.allocator;

    // 4x4 opaque red: R=255 G=0 B=0 A=255.
    const W: u32 = 4;
    const H: u32 = 4;
    var pixels: [W * H * 4]u8 = undefined;
    var pi: usize = 0;
    while (pi < pixels.len) : (pi += 4) {
        pixels[pi + 0] = 0xFF; // R
        pixels[pi + 1] = 0x00; // G
        pixels[pi + 2] = 0x00; // B
        pixels[pi + 3] = 0xFF; // A
    }

    var img = phantom.image.fromRgba(&pixels, W, H);

    // Draw the image at a rect that sits well inside the 200x200 viewport.
    // Rect: x=60, y=60, width=80, height=80 -> center at (100, 100).
    const rect = phantom.PhysicalRect{ .x = 60, .y = 60, .width = 80, .height = 80 };

    // Use the harness canvas directly (no widget needed for this GPU golden).
    var t = try mount(gpa, (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();

    // Append the image primitive directly after the pump's display list is populated.
    try t.canvas.list.append(gpa, .{ .image = .{ .image = &img, .rect = rect, .opacity = 1 } });

    var r = try t.rasterize();
    defer r.deinit();

    // The center pixel of the image rect (100, 100) should be ~red.
    // Red: r high (>180), g low (<60), b low (<60). Tolerance 40.
    const cx: u32 = 100;
    const cy: u32 = 100;
    const off = (cy * r.width + cx) * 4;
    // r channel high
    try std.testing.expect(r.pixels[off + 0] > 180);
    // g channel low
    try std.testing.expect(r.pixels[off + 1] < 60);
    // b channel low
    try std.testing.expect(r.pixels[off + 2] < 60);
}

test "Tier 2: fromBytes PNG golden - decoded logo.png appears at expected screen location" {
    // Build a 4x4 PNG image via fromBytes (encoded), draw it at a known rect,
    // rasterize through Prism (which calls ensureDecoded on the handle), and assert
    // the center pixel of that rect is NOT the clear/background color. This proves
    // decode -> GPU upload -> sampled quad end-to-end for the native PNG path.
    // The fromRgba golden above must still pass (borrowed rgba, not freed).
    const gpa = std.testing.allocator;

    // The fixture is a 4x4 RGBA PNG (all pixels are non-transparent, non-background).
    // Path is relative to lib/phantom/testing.zig which is at lib/phantom/.
    var img = phantom.image.fromBytes(@embedFile("image/testdata/logo.png"), 4, 4);
    // Prism calls ensureDecoded on img which allocates rgba; free it after rasterize.
    defer img.deinit(gpa);

    // Draw the image at a rect inside the 200x200 viewport. The rect is 80x80 for a
    // 4x4 texture, so each texel spans 20px and texel-i centers land at local
    // 10 + 20*i, that is at frontend x/y of 70, 90, 110 and 130.
    //
    // The offscreen target reads back vertically inverted relative to the frontend's
    // top-left space (this path leaves PrismBackend.flip_y false), so readback row
    // y maps to frontend row 199 - y. Texel row 1 sits at frontend y=90, therefore at
    // readback y=109. Texel column 1 sits at readback x=90 (X is not inverted).
    // Reading (90, 109) samples texel (1, 1) at its center with no neighbor blend.
    const rect = phantom.PhysicalRect{ .x = 60, .y = 60, .width = 80, .height = 80 };

    var t = try mount(gpa, (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();

    // Append the image primitive directly after the pump display list is populated.
    try t.canvas.list.append(gpa, .{ .image = .{ .image = &img, .rect = rect, .opacity = 1 } });

    var r = try t.rasterize();
    defer r.deinit();

    // rasterize() ran ensureDecoded on the handle, so img.rgba now holds the decoded
    // 4x4 RGBA. Read the EXPECTED texel (1,1) straight from it, then assert the pixel
    // sampled onto the screen at (90,90) matches it. This proves the decoded bytes
    // actually reach the framebuffer (not just that "something" drew).
    const decoded = img.rgba orelse return error.TestUnexpectedResult;
    const texel_off = (1 * img.width + 1) * 4; // row 1, col 1
    const exp_r = decoded[texel_off + 0];
    const exp_g = decoded[texel_off + 1];
    const exp_b = decoded[texel_off + 2];

    const so = (109 * r.width + 90) * 4;
    // Tolerance absorbs the linear-filter blend near the texel center (the pixel
    // center lands a fraction of a texel off dead center). The four row-1 texels
    // differ from each other by 128-255 per channel, so 24 still uniquely pins the
    // correct texel while tolerating the sub-texel blend.
    const tol: u8 = 24;
    const dr = if (r.pixels[so + 0] > exp_r) r.pixels[so + 0] - exp_r else exp_r - r.pixels[so + 0];
    const dg = if (r.pixels[so + 1] > exp_g) r.pixels[so + 1] - exp_g else exp_g - r.pixels[so + 1];
    const db = if (r.pixels[so + 2] > exp_b) r.pixels[so + 2] - exp_b else exp_b - r.pixels[so + 2];
    try std.testing.expect(dr <= tol);
    try std.testing.expect(dg <= tol);
    try std.testing.expect(db <= tol);
}

test "Tier 2: image orientation golden - rgba row 0 lands at the top of the quad" {
    // REGRESSION: the Prism image pass used to invert V (top of quad -> v=1), which
    // drew every image upside down on the window surface. Text and rounded rects were
    // unaffected, so only images were wrong. This golden pins the vertical order of
    // the sampled texels, not just that "some" image data reached the framebuffer.
    //
    // The fixture is a 4x4 RGBA PNG whose four rows are all different:
    //   row 0: red,      green,      blue,      white       (opaque)
    //   row 1: black,    cyan,       magenta,   yellow      (opaque)
    //   row 2: dk red,   dk green,   dk blue,   gray        (opaque)
    //   row 3: red 50%,  green 50%,  blue 50%,  transparent
    // A vertical flip swaps rows 0 and 3, so comparing the opaque rows against the
    // decoded bytes catches the inversion.
    const gpa = std.testing.allocator;

    var img = phantom.image.fromBytes(@embedFile("image/testdata/logo.png"), 4, 4);
    defer img.deinit(gpa);

    // 80x80 rect for a 4x4 texture: each texel spans 20px, so texel i centers on
    // frontend coordinate 60 + 10 + 20*i, that is 70, 90, 110 and 130.
    const rect = phantom.PhysicalRect{ .x = 60, .y = 60, .width = 80, .height = 80 };

    var t = try mount(gpa, (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();
    try t.canvas.list.append(gpa, .{ .image = .{ .image = &img, .rect = rect, .opacity = 1 } });

    var r = try t.rasterize();
    defer r.deinit();

    const decoded = img.rgba orelse return error.TestUnexpectedResult;

    // The offscreen target reads back vertically inverted relative to the frontend's
    // top-left space (flip_y stays false on this path), so readback row = 199 - py.
    // Frontend y 70/90/110/130 therefore read back at 129/109/89/69.
    const readback_y = [4]u32{ 129, 109, 89, 69 };
    const readback_x = [4]u32{ 70, 90, 110, 130 };

    // Tolerance absorbs the half-pixel offset between the pixel center and the texel
    // center. Neighbouring texels differ by 128-255 per channel, so 24 still pins the
    // correct texel uniquely.
    const tol: u8 = 24;

    // Rows 0..2 are opaque, so the framebuffer pixel must equal the decoded texel.
    // Row 3 is semi-transparent and blends with the background, so it is checked below.
    for (0..3) |row| {
        for (0..4) |col| {
            const texel = (row * img.width + col) * 4;
            const off = (readback_y[row] * r.width + readback_x[col]) * 4;
            inline for (0..3) |chan| {
                const got = r.pixels[off + chan];
                const want = decoded[texel + chan];
                const diff = if (got > want) got - want else want - got;
                if (diff > tol) {
                    std.debug.print(
                        "texel ({d},{d}) want rgb({d},{d},{d}) got rgb({d},{d},{d})\n",
                        .{ row, col, decoded[texel], decoded[texel + 1], decoded[texel + 2], r.pixels[off], r.pixels[off + 1], r.pixels[off + 2] },
                    );
                    return error.ImageOrientationMismatch;
                }
            }
        }
    }

    // Texel (3, 3) is fully transparent, so the black ColoredBox behind the image
    // shows through. Under a vertical flip this point would hold texel (0, 3),
    // which is opaque white.
    try r.expectPixel(readback_x[3], readback_y[3], phantom.Color.rgb(0, 0, 0), 24);
}

test "Tier 2: fromBytes JPEG golden - decoded grayscale renders" {
    // Encode a 16x16 solid mid-gray JPEG in-test, wrap it in an Image via
    // fromBytes, rasterize through Prism (which calls ensureDecoded), and
    // assert the center pixel of the drawn rect matches the source luma (~150).
    // A solid block is DC-only in the DCT domain, so it round-trips near-exactly
    // with the all-1s quant table used by encodeGrayJpeg.
    // This proves jpeg.decode -> GPU upload -> sampled quad end-to-end.
    const gpa = std.testing.allocator;

    const W: usize = 16;
    const H: usize = 16;
    var luma: [W * H]u8 = undefined;
    @memset(&luma, 150); // solid mid-gray

    const jpg = try phantom.jpeg.encodeGrayJpeg(gpa, &luma, W, H);
    defer gpa.free(jpg);

    // fromBytes hands the slice to Image; ensureDecoded will decode it later.
    var img = phantom.image.fromBytes(jpg, @intCast(W), @intCast(H));
    defer img.deinit(gpa);

    // Draw the image at a rect inside the 200x200 viewport.
    // Rect: x=60, y=60, width=80, height=80 -> center at (100, 100).
    const rect = phantom.PhysicalRect{ .x = 60, .y = 60, .width = 80, .height = 80 };

    var t = try mount(gpa, (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 0) }).widget());
    defer t.deinit();
    t.viewport = .{ .width = 200, .height = 200 };
    try t.pump();

    // Append the image primitive after the pump display list is populated.
    try t.canvas.list.append(gpa, .{ .image = .{ .image = &img, .rect = rect, .opacity = 1 } });

    var r = try t.rasterize();
    defer r.deinit();

    // rasterize() triggered ensureDecoded; img.rgba holds the decoded 16x16 RGBA.
    // For a solid-150 grayscale JPEG, each decoded pixel should have R==G==B~=150.
    // Assert the center pixel of the rendered rect (100, 100) is approximately gray-150.
    // Tolerance of 8 covers JPEG DC rounding (solid block decodes very close to exact).
    const cx: u32 = 100;
    const cy: u32 = 100;
    const off = (cy * r.width + cx) * 4;
    const pix_r = r.pixels[off + 0];
    const pix_g = r.pixels[off + 1];
    const pix_b = r.pixels[off + 2];

    // R, G, B should all be approximately equal (grayscale) and close to 150.
    const diff_rg: u8 = if (pix_r > pix_g) pix_r - pix_g else pix_g - pix_r;
    const diff_rb: u8 = if (pix_r > pix_b) pix_r - pix_b else pix_b - pix_r;
    try std.testing.expect(diff_rg <= 8);
    try std.testing.expect(diff_rb <= 8);

    const expected: u8 = 150;
    const tol_jpeg: u8 = 16; // JPEG + GPU sampling tolerance combined
    const dr_j: u8 = if (pix_r > expected) pix_r - expected else expected - pix_r;
    const dg_j: u8 = if (pix_g > expected) pix_g - expected else expected - pix_g;
    const db_j: u8 = if (pix_b > expected) pix_b - expected else expected - pix_b;
    try std.testing.expect(dr_j <= tol_jpeg);
    try std.testing.expect(dg_j <= tol_jpeg);
    try std.testing.expect(db_j <= tol_jpeg);
}

test "Tier 2 terminal: a Text widget lands on the expected cells" {
    const gpa = std.testing.allocator;
    var font = try phantom.text.Font.load(gpa, phantom.text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var t = phantom.Text{
        .text = "hi",
        .font = &font,
        .size = 14,
        .color = phantom.Color.rgb(1, 1, 1),
    };
    var h = try mount(gpa, t.widget());
    defer h.deinit();

    var r = try h.tuiRender(20, 5, 8, 16);
    defer r.deinit();

    try r.expectCell(0, 0, 'h');
    try r.expectCell(1, 0, 'i');
}

test "Tier 2 terminal: a ColoredBox fills the cells it covers" {
    const gpa = std.testing.allocator;
    var box = phantom.ColoredBox{ .color = phantom.Color.rgb(1, 0, 0) };
    var h = try mount(gpa, box.widget());
    defer h.deinit();
    h.viewport = .{ .width = 80, .height = 48 };

    var r = try h.tuiRender(10, 3, 8, 16);
    defer r.deinit();

    try r.expectBg(0, 0, phantom.Color.rgb(1, 0, 0));
    try r.expectBg(9, 2, phantom.Color.rgb(1, 0, 0));
}
