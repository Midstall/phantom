const std = @import("std");
const display_list = @import("../display_list.zig");
const geometry = @import("../geometry.zig");
const dom = @import("dom.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const icon_builtin = @import("../icon/builtin.zig");
const svg_path = @import("../icon/svg_path.zig");
const platform = @import("../platform.zig");

/// The namespace an `<svg>` and its children must be created in. `createElement`
/// puts an element in the HTML namespace whatever its name is, and an `svg` in
/// the HTML namespace is an unknown element that a browser lays out but never
/// paints. Only `createElementNS` reaches the SVG namespace.
pub const svg_ns = "http://www.w3.org/2000/svg";

/// A vtable of DOM operations, implemented by the web entry (via the generated
/// webidl dom module) or by a recording mock in tests. Every fn takes ctx so
/// the implementation carries its state (handles / a recorder) without globals.
pub const DomOps = struct {
    ctx: *anyopaque,
    create_element: *const fn (ctx: *anyopaque, tag: []const u8) u32,
    /// Namespaced element creation, for the `<svg>` an icon draws into. Null
    /// falls back to `create_element`, which keeps every existing host
    /// compiling; a host that leaves it null renders no icons, because an
    /// `svg` in the HTML namespace paints nothing.
    create_element_ns: ?*const fn (ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 = null,
    create_text_node: *const fn (ctx: *anyopaque, data: []const u8) u32,
    set_attribute: *const fn (ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void,
    set_text_content: *const fn (ctx: *anyopaque, node: u32, textv: []const u8) void,
    append_child: *const fn (ctx: *anyopaque, parent: u32, child: u32) void,
    clear_children: *const fn (ctx: *anyopaque, node: u32) void,
    body: u32,
    head: u32,
    /// Opens a URL in a new tab. Null on a host that has no browser.
    open_url: ?*const fn (ctx: *anyopaque, url: []const u8) void = null,
    /// Writes the current route into `buf` and returns the written part, or
    /// null when the real route is longer than `buf` can hold. A truncated
    /// route is a different, shorter one than the browser actually shows, so
    /// the caller must refuse it rather than take the shortened copy.
    read_location: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Puts `path` in the address bar without loading a new page, in `mode`.
    write_location: ?*const fn (ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void = null,

    pub fn createElement(self: DomOps, tag: []const u8) u32 {
        return self.create_element(self.ctx, tag);
    }
    pub fn createElementNs(self: DomOps, ns: []const u8, tag: []const u8) u32 {
        const f = self.create_element_ns orelse return self.create_element(self.ctx, tag);
        return f(self.ctx, ns, tag);
    }
    pub fn createTextNode(self: DomOps, data: []const u8) u32 {
        return self.create_text_node(self.ctx, data);
    }
    pub fn setAttribute(self: DomOps, node: u32, name: []const u8, value: []const u8) void {
        self.set_attribute(self.ctx, node, name, value);
    }
    pub fn setTextContent(self: DomOps, node: u32, textv: []const u8) void {
        self.set_text_content(self.ctx, node, textv);
    }
    pub fn appendChild(self: DomOps, parent: u32, child: u32) void {
        self.append_child(self.ctx, parent, child);
    }
    pub fn clearChildren(self: DomOps, node: u32) void {
        self.clear_children(self.ctx, node);
    }
};

/// Build the @font-face CSS block for a list of fonts. Call once at init and
/// inject a single <style> into <head>. Caller owns the returned slice.
pub fn fontFaceCss(gpa: std.mem.Allocator, fonts: []const *text.Font) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (fonts, 0..) |font_ptr, i| {
        const enc = std.base64.standard.Encoder;
        const b64 = try gpa.alloc(u8, enc.calcSize(font_ptr.bytes.len));
        defer gpa.free(b64);
        _ = enc.encode(b64, font_ptr.bytes);
        const face = try std.fmt.allocPrint(gpa, "@font-face{{font-family:pf{d};src:url(data:font/otf;base64,{s}) format(\"opentype\")}}", .{ i, b64 });
        defer gpa.free(face);
        try buf.appendSlice(gpa, face);
    }
    return buf.toOwnedSlice(gpa);
}

/// Rebuild the whole document body's child tree from the display list.
pub fn render(gpa: std.mem.Allocator, ops: DomOps, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color) !void {
    ops.clearChildren(ops.body);

    // Collect distinct fonts once; used for text primitive font-family index lookups.
    const fonts = try dom.collectFonts(gpa, list);
    defer gpa.free(fonts);

    // Layout container: position:relative, viewport-sized, branded bg.
    const container = ops.createElement("div");
    {
        const style = try std.fmt.allocPrint(gpa, "position:relative;width:{d}px;height:{d}px;background:rgb({d},{d},{d})", .{ viewport.width, viewport.height, dom.ch(bg.r), dom.ch(bg.g), dom.ch(bg.b) });
        defer gpa.free(style);
        ops.setAttribute(container, "style", style);
    }
    ops.appendChild(ops.body, container);

    // parent is where children append (the container, or a scroll region inner div).
    // region_origin subtracts the scroll viewport origin from child coords (v1 single level).
    var parent: u32 = container;
    var region_origin: ?geometry.PhysicalOffset = null;

    // Accumulate :hover/:active rules for interactive rrects; injected as a <style> after the loop.
    var rules: std.ArrayList(u8) = .empty;
    defer rules.deinit(gpa);
    var cls: u32 = 0;

    for (list.primitives.items) |p| switch (p) {
        .rrect => |r| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            var abuf: [8]u8 = undefined;

            if (r.hover_color == null and r.active_color == null) {
                // Non-interactive: plain fill or stroke.
                if (r.stroke_width > 0) {
                    // Stroke rrect: border ring, no fill.
                    const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;box-sizing:border-box;border:{d}px solid rgba({d},{d},{d},{s});background:transparent", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, r.stroke_width, dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });
                    defer gpa.free(style);
                    const node = ops.createElement("div");
                    ops.setAttribute(node, "style", style);
                    ops.appendChild(parent, node);
                } else {
                    // Plain fill rrect (kept identical to Task 1).
                    const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;background:rgba({d},{d},{d},{s})", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });
                    defer gpa.free(style);
                    const node = ops.createElement("div");
                    ops.setAttribute(node, "style", style);
                    ops.appendChild(parent, node);
                }
            } else {
                // Interactive rrect: base div carries a pb{n} class; state colors go to rules buffer.
                const c = cls;
                cls += 1;
                const node = ops.createElement("div");
                const cls_val = try std.fmt.allocPrint(gpa, "pb{d}", .{c});
                defer gpa.free(cls_val);
                ops.setAttribute(node, "class", cls_val);
                if (r.stroke_width > 0) {
                    const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;box-sizing:border-box;border:{d}px solid rgba({d},{d},{d},{s});background:transparent", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, r.stroke_width, dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });
                    defer gpa.free(style);
                    ops.setAttribute(node, "style", style);
                    ops.appendChild(parent, node);
                    if (r.hover_color) |h| {
                        var hbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:hover{{border-color:rgba({d},{d},{d},{s})}}", .{ c, dom.ch(h.r), dom.ch(h.g), dom.ch(h.b), dom.alpha(&hbuf, h.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                    if (r.active_color) |ac| {
                        var pbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:active{{border-color:rgba({d},{d},{d},{s})}}", .{ c, dom.ch(ac.r), dom.ch(ac.g), dom.ch(ac.b), dom.alpha(&pbuf, ac.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                } else {
                    const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;background:rgba({d},{d},{d},{s})", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });
                    defer gpa.free(style);
                    ops.setAttribute(node, "style", style);
                    ops.appendChild(parent, node);
                    if (r.hover_color) |h| {
                        var hbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:hover{{background:rgba({d},{d},{d},{s})}}", .{ c, dom.ch(h.r), dom.ch(h.g), dom.ch(h.b), dom.alpha(&hbuf, h.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                    if (r.active_color) |ac| {
                        var pbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:active{{background:rgba({d},{d},{d},{s})}}", .{ c, dom.ch(ac.r), dom.ch(ac.g), dom.ch(ac.b), dom.alpha(&pbuf, ac.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                }
                // A pointer cursor is the browser's own affordance for "this
                // responds to a tap", so every interactive rectangle gets one.
                const cursor_rule = try std.fmt.allocPrint(gpa, ".pb{d}{{cursor:pointer}}", .{c});
                defer gpa.free(cursor_rule);
                try rules.appendSlice(gpa, cursor_rule);
            }
        },
        .image => |img| {
            const im: *image_mod.Image = @ptrCast(@alignCast(img.image));
            if (im.bytes.len == 0) continue; // no encoded bytes -> nothing to <img> (v1: fromRgba images skipped on web)
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px", .{ img.rect.x - ox, img.rect.y - oy, img.rect.width, img.rect.height });
            defer gpa.free(style);
            const enc = std.base64.standard.Encoder;
            const b64 = try gpa.alloc(u8, enc.calcSize(im.bytes.len));
            defer gpa.free(b64);
            _ = enc.encode(b64, im.bytes);
            const src = try std.fmt.allocPrint(gpa, "data:{s};base64,{s}", .{ image_mod.Image.mime(im.format), b64 });
            defer gpa.free(src);
            const node = ops.createElement("img");
            ops.setAttribute(node, "style", style);
            ops.setAttribute(node, "src", src);
            ops.appendChild(parent, node);
        },
        .icon => |ic| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const icon_path = icon_builtin.pathFor(ic.id);

            // The viewBox is the authoring grid and width/height are the size
            // the frontend asked for, so the browser does the scaling and one
            // centreline serves every size. That also fixes stroke-width in
            // GRID units: scaling it here as well would square the factor.
            var gbuf: [svg_path.coord_len]u8 = undefined;
            const grid_s = svg_path.coord(&gbuf, icon_builtin.grid);
            const view_box = try std.fmt.allocPrint(gpa, "0 0 {s} {s}", .{ grid_s, grid_s });
            defer gpa.free(view_box);
            const w_s = try std.fmt.allocPrint(gpa, "{d}", .{ic.size.width});
            defer gpa.free(w_s);
            const h_s = try std.fmt.allocPrint(gpa, "{d}", .{ic.size.height});
            defer gpa.free(h_s);
            const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px", .{ ic.origin.x - ox, ic.origin.y - oy });
            defer gpa.free(style);

            const svg = ops.createElementNs(svg_ns, "svg");
            ops.setAttribute(svg, "viewBox", view_box);
            // See `dom.zig`: without this the browser centres the square grid in
            // a box that is not square and the mark comes out short.
            ops.setAttribute(svg, "preserveAspectRatio", "none");
            ops.setAttribute(svg, "width", w_s);
            ops.setAttribute(svg, "height", h_s);
            ops.setAttribute(svg, "style", style);

            // `<title>` is the accessible name of an inline SVG, and the first
            // child is the one a screen reader reads, so it goes in before the
            // path. It is written only when there is a name: an empty title
            // takes the name slot and then announces nothing, which is worse
            // than a mark with no title at all.
            if (ic.label) |name| {
                const title = ops.createElementNs(svg_ns, "title");
                ops.setTextContent(title, name);
                ops.appendChild(svg, title);
            }

            const d = try svg_path.data(gpa, icon_path, icon_builtin.grid);
            defer gpa.free(d);
            var abuf: [8]u8 = undefined;
            const stroke = try std.fmt.allocPrint(gpa, "rgba({d},{d},{d},{s})", .{
                dom.ch(ic.color.r), dom.ch(ic.color.g), dom.ch(ic.color.b), dom.alpha(&abuf, ic.color.a),
            });
            defer gpa.free(stroke);
            var sbuf: [svg_path.coord_len]u8 = undefined;

            const node = ops.createElementNs(svg_ns, "path");
            ops.setAttribute(node, "d", d);
            // A centreline filled rather than stroked draws as a solid blob.
            ops.setAttribute(node, "fill", "none");
            ops.setAttribute(node, "stroke", stroke);
            ops.setAttribute(node, "stroke-width", svg_path.coord(&sbuf, icon_path.stroke.width));
            ops.setAttribute(node, "stroke-linecap", svg_path.lineCap(icon_path.stroke.cap));
            ops.setAttribute(node, "stroke-linejoin", svg_path.lineJoin(icon_path.stroke.join));
            ops.appendChild(svg, node);
            ops.appendChild(parent, svg);
        },
        .text => |run| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
            var font_idx: usize = 0;
            for (fonts, 0..) |fp, i| {
                if (fp == font_ptr) {
                    font_idx = i;
                    break;
                }
            } else unreachable;
            var tbuf: [8]u8 = undefined;
            const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;font-family:pf{d};font-size:{d}px;color:rgba({d},{d},{d},{s})", .{ run.origin.x - ox, run.origin.y - oy, font_idx, run.size, dom.ch(run.color.r), dom.ch(run.color.g), dom.ch(run.color.b), dom.alpha(&tbuf, run.color.a) });
            defer gpa.free(style);
            const node = ops.createElement("div");
            ops.setAttribute(node, "style", style);
            ops.setTextContent(node, run.text);
            ops.appendChild(parent, node);
        },
        .push_scroll => |sr| {
            // Outer div: clipping/scrolling window at the viewport position and size.
            const outer_style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;overflow:scroll", .{ sr.viewport.x, sr.viewport.y, sr.viewport.width, sr.viewport.height });
            defer gpa.free(outer_style);
            const outer = ops.createElement("div");
            ops.setAttribute(outer, "style", outer_style);
            ops.appendChild(parent, outer);
            // Inner div: the full content area that scrolls inside the outer.
            const inner_style = try std.fmt.allocPrint(gpa, "position:relative;width:{d}px;height:{d}px", .{ sr.content.width, sr.content.height });
            defer gpa.free(inner_style);
            const inner = ops.createElement("div");
            ops.setAttribute(inner, "style", inner_style);
            ops.appendChild(outer, inner);
            // Children now append to the inner div; coords subtract the viewport origin.
            parent = inner;
            region_origin = .{ .x = sr.viewport.x, .y = sr.viewport.y };
        },
        .pop_scroll => {
            // Restore the top-level container as the append target.
            parent = container;
            region_origin = null;
        },
        .push_clip => |cr| {
            // A browser clips to the full rounded shape, so this backend is the
            // one that honours the radius exactly.
            const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;overflow:hidden", .{ cr.rect.x, cr.rect.y, cr.rect.width, cr.rect.height, cr.radius });
            defer gpa.free(style);
            const node = ops.createElement("div");
            ops.setAttribute(node, "style", style);
            ops.appendChild(parent, node);
            // Children now append inside the clip; coords subtract its origin.
            parent = node;
            region_origin = .{ .x = cr.rect.x, .y = cr.rect.y };
        },
        .pop_clip => {
            parent = container;
            region_origin = null;
        },
    };

    // Inject a <style> with interactive rules if any were accumulated.
    if (rules.items.len > 0) {
        const style_node = ops.createElement("style");
        ops.setTextContent(style_node, rules.items);
        ops.appendChild(ops.body, style_node);
    }
}

// Recording mock for tests. No global mutable state: each fn casts ctx to *Recorder.
// Exported so a test outside this file (a WebApp test with no browser) can
// drive one through `phantom.backend.dom_calls.Recorder`.
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    log: std.ArrayList([]u8) = .empty,
    next_handle: u32 = 100,
    /// Mimics the address bar for `read_location` / `write_location`. Empty
    /// until a write happens, the same as a fresh page with nothing written
    /// to its history yet.
    location_buf: [location_cap]u8 = undefined,
    location_len: usize = 0,

    /// Comfortably past `router.max_path`, so a test can park a location here
    /// that is too long for the router's own buffer without touching this
    /// buffer's limit.
    pub const location_cap = 512;

    /// Sets the location `read_location` reports, without recording a call.
    /// Lets a test start a Recorder already parked at a given address, the
    /// same as a page freshly opened on a link somebody sent.
    pub fn setLocation(self: *Recorder, path: []const u8) void {
        @memcpy(self.location_buf[0..path.len], path);
        self.location_len = path.len;
    }

    fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.location_len > buf.len) return null;
        @memcpy(buf[0..self.location_len], self.location_buf[0..self.location_len]);
        return buf[0..self.location_len];
    }

    fn writeLocation(ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("writeLocation({s},{s})", .{ path, @tagName(mode) });
        self.setLocation(path);
    }

    fn rec(self: *Recorder, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.log.append(self.gpa, line) catch {};
    }

    pub fn deinit(self: *Recorder) void {
        for (self.log.items) |l| self.gpa.free(l);
        self.log.deinit(self.gpa);
    }

    fn createElement(ctx: *anyopaque, tag: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createElement({s})->{d}", .{ tag, self.next_handle });
        return self.next_handle;
    }

    fn createElementNS(ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createElementNS({s},{s})->{d}", .{ ns, tag, self.next_handle });
        return self.next_handle;
    }

    fn createTextNode(ctx: *anyopaque, data: []const u8) u32 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.next_handle += 1;
        self.rec("createTextNode({s})->{d}", .{ data, self.next_handle });
        return self.next_handle;
    }

    fn setAttribute(ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("setAttribute({d},{s},{s})", .{ node, name, value });
    }

    fn setTextContent(ctx: *anyopaque, node: u32, textv: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("setTextContent({d},{s})", .{ node, textv });
    }

    fn appendChild(ctx: *anyopaque, parent: u32, child: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("appendChild({d},{d})", .{ parent, child });
    }

    fn clearChildren(ctx: *anyopaque, node: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("clearChildren({d})", .{node});
    }

    pub fn ops(self: *Recorder) DomOps {
        return .{
            .ctx = self,
            .create_element = createElement,
            .create_element_ns = createElementNS,
            .create_text_node = createTextNode,
            .set_attribute = setAttribute,
            .set_text_content = setTextContent,
            .append_child = appendChild,
            .clear_children = clearChildren,
            .body = 1,
            .head = 2,
            .read_location = readLocation,
            .write_location = writeLocation,
        };
    }
};

fn contains(log: []const []u8, needle: []const u8) bool {
    for (log) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
    return false;
}

/// Index of the first recorded line holding `needle`, for tests that pin the
/// order of two calls and not only that both happened.
fn indexOfLine(log: []const []u8, needle: []const u8) ?usize {
    for (log, 0..) |l, i| if (std.mem.indexOf(u8, l, needle) != null) return i;
    return null;
}

test "dom_calls: fill rrect creates a styled div appended to the container" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // clears body, builds the container, then the rrect div with the right style + append.
    try std.testing.expect(contains(rec.log.items, "clearChildren(1)"));
    try std.testing.expect(contains(rec.log.items, "position:relative;width:200px"));
    try std.testing.expect(contains(rec.log.items, "left:10px;top:20px;width:30px;height:40px;border-radius:4px;background:rgba(255,0,0,1)"));
}

test "dom_calls: text primitive records setTextContent with raw string and font-family:pf0 style" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]display_list.PositionedGlyph{.{ .cp = 'h', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{
        .glyphs = &glyphs,
        .text = "<b>hi</b>",
        .font = &font,
        .size = 16,
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = geometry.PhysicalOffset{ .x = 5, .y = 8 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // The raw string is passed directly (browser handles escaping).
    try std.testing.expect(contains(rec.log.items, "setTextContent") and contains(rec.log.items, "<b>hi</b>"));
    // The style div must carry font-family:pf0.
    try std.testing.expect(contains(rec.log.items, "font-family:pf0"));
}

test "dom_calls: stroke rrect records a border:...solid rgba style" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 5, .y = 10, .width = 60, .height = 30 },
        .radius = 3,
        .color = geometry.Color.rgb(0, 1, 0),
        .stroke_width = 2,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // Must have border-radius, box-sizing, and the border solid rgba style.
    try std.testing.expect(contains(rec.log.items, "box-sizing:border-box"));
    try std.testing.expect(contains(rec.log.items, "border:2px solid rgba("));
    try std.testing.expect(contains(rec.log.items, "background:transparent"));
}

test "dom_calls: interactive fill rrect records class=pb0 and a style element with hover rule" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 },
        .radius = 4,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.9),
        .active_color = geometry.Color.rgb(0, 0, 0.8),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // The div must carry class="pb0" via setAttribute.
    try std.testing.expect(contains(rec.log.items, "setAttribute(") and contains(rec.log.items, "class,pb0"));
    // A style element must be created and its textContent must contain the hover rule.
    try std.testing.expect(contains(rec.log.items, "createElement(style)"));
    try std.testing.expect(contains(rec.log.items, ".pb0:hover{background:"));
}

test "an interactive rectangle gets a pointer cursor and a plain one does not" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // One rectangle with a hover colour, and one without.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 0, 1),
        .hover_color = geometry.Color.rgb(0, 0, 0.5),
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 20, .width = 10, .height = 10 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    try std.testing.expect(contains(rec.log.items, ".pb0{cursor:pointer}"));
    try std.testing.expect(!contains(rec.log.items, ".pb1"));
}

test "dom_calls: push_scroll creates outer+inner divs and adjusts child coords" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // push_scroll: viewport x=10,y=20,w=100,h=50; content w=100,h=300
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // fillRRect at absolute x=10,y=120,w=80,h=20 -> after subtract origin (10,20): left=0,top=100
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 10, .y = 120, .width = 80, .height = 20 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0));
    // Outer div has overflow:scroll and the viewport position/size.
    try std.testing.expect(contains(rec.log.items, "overflow:scroll"));
    try std.testing.expect(contains(rec.log.items, "left:10px;top:20px;width:100px;height:50px;overflow:scroll"));
    // Inner div has position:relative and the content size.
    try std.testing.expect(contains(rec.log.items, "position:relative;width:100px;height:300px"));
    // The rrect is appended to the inner div with adjusted coords: left=0 (10-10), top=100 (120-20).
    try std.testing.expect(contains(rec.log.items, "left:0px;top:100px"));
}

test "dom_calls: image with encoded bytes emits createElement(img), style, and data URL src" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    // PNG magic bytes (8-byte signature) to trigger .png detection.
    const png_bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(png_bytes, 10, 10);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 5, .y = 15, .width = 64, .height = 32 },
        .opacity = 1,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // A createElement("img") call must be recorded.
    try std.testing.expect(contains(rec.log.items, "createElement(img)"));
    // The style attribute must include left/top/width/height.
    try std.testing.expect(contains(rec.log.items, "left:5px;top:15px;width:64px;height:32px"));
    // The src attribute value must begin with the data URL prefix for PNG.
    var found_src = false;
    for (rec.log.items) |l| {
        if (std.mem.indexOf(u8, l, "setAttribute(") != null and
            std.mem.indexOf(u8, l, ",src,") != null and
            std.mem.indexOf(u8, l, "data:image/png;base64,") != null)
        {
            // Verify the base64 tail decodes back to the original bytes.
            // The Recorder format ends with ")" so strip the trailing paren.
            const prefix = "data:image/png;base64,";
            const src_start = std.mem.indexOf(u8, l, prefix).? + prefix.len;
            var b64_data = l[src_start..];
            if (b64_data.len > 0 and b64_data[b64_data.len - 1] == ')') {
                b64_data = b64_data[0 .. b64_data.len - 1];
            }
            const dec = std.base64.standard.Decoder;
            const decoded_len = try dec.calcSizeForSlice(b64_data);
            const decoded = try gpa.alloc(u8, decoded_len);
            defer gpa.free(decoded);
            try dec.decode(decoded, b64_data);
            try std.testing.expectEqualSlices(u8, png_bytes, decoded);
            found_src = true;
        }
    }
    try std.testing.expect(found_src);
}

test "dom_calls: an icon creates an svg in the SVG namespace holding one stroked path" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 40, .height = 40 },
        .color = geometry.Color.rgb(1, 0, 0),
        .origin = .{ .x = 6, .y = 9 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0));

    // createElement("svg") builds an HTML unknown element that never paints, so
    // the namespaced call is the fact this pins.
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,svg)"));
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)"));
    // The viewBox is the grid and the size is the request: two different values.
    try std.testing.expect(contains(rec.log.items, "viewBox,0 0 24 24"));
    try std.testing.expect(contains(rec.log.items, "width,40"));
    try std.testing.expect(contains(rec.log.items, "height,40"));
    try std.testing.expect(contains(rec.log.items, "style,position:absolute;left:6px;top:9px"));
    // A stroked centreline, not a filled outline.
    try std.testing.expect(contains(rec.log.items, "fill,none"));
    try std.testing.expect(contains(rec.log.items, "stroke-width,1.7"));
    try std.testing.expect(contains(rec.log.items, "stroke-linecap,round"));
    try std.testing.expect(contains(rec.log.items, "stroke-linejoin,round"));
    try std.testing.expect(contains(rec.log.items, "stroke,rgba(255,0,0,1)"));
    try std.testing.expect(contains(rec.log.items, "d,M3.84 3.218Q12 4.887 20.16 3.218"));
}

test "dom_calls: a labelled icon appends a namespaced title node holding the name" {
    // The title is the accessible name of inline SVG. It is namespaced like the
    // svg and the path, because a title in the HTML namespace is a foreign child
    // that no reader picks up.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "Genesis",
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0));

    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,title)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent") and contains(rec.log.items, "Genesis"));
    // First child of the svg, before the path: a reader takes the first title it
    // meets, so a title appended last names nothing.
    const title_at = indexOfLine(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,title)").?;
    const path_at = indexOfLine(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)").?;
    try std.testing.expect(title_at < path_at);
}

test "dom_calls: an icon with no label creates no title node" {
    // An empty title takes the accessible name and announces nothing with it,
    // which silences the icon more thoroughly than leaving the name unset.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    try std.testing.expect(!contains(rec.log.items, ",title)"));
    // The svg is still built, so this is not passing because nothing was drawn.
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)"));
}

test "dom_calls: a host with no namespaced creator still builds the icon through createElement" {
    // Every existing DomOps leaves create_element_ns null. The fallback keeps
    // those hosts compiling and emitting the tree, at the cost of an svg the
    // browser will not paint until the host supplies createElementNS.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geometry.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    var ops = rec.ops();
    ops.create_element_ns = null;
    try render(gpa, ops, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    try std.testing.expect(contains(rec.log.items, "createElement(svg)"));
    try std.testing.expect(contains(rec.log.items, "createElement(path)"));
    try std.testing.expect(!contains(rec.log.items, "createElementNS("));
}

test "dom_calls: image fromRgba (no encoded bytes) emits no img element" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    const rgba_pixels = [_]u8{255} ** (4 * 4 * 4); // 4x4 RGBA
    var img = image_mod.Image.fromRgba(&rgba_pixels, 4, 4);
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .opacity = 1,
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0));
    // No img element should be created (fromRgba has no encoded bytes).
    try std.testing.expect(!contains(rec.log.items, "createElement(img)"));
}
