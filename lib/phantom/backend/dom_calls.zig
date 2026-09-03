const std = @import("std");
const display_list = @import("../display_list.zig");
const geometry = @import("../geometry.zig");
const dom = @import("dom.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const icon_builtin = @import("../icon/builtin.zig");
const svg_path = @import("../icon/svg_path.zig");
const platform = @import("../platform.zig");
const FaultSink = @import("../FaultSink.zig");

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
    /// Opens `url` in `mode`, and reports whether it WAS opened. A browser hands
    /// back nothing when it refuses a popup, and that has to reach the caller:
    /// see `platform.OpenMode`.
    open_url: ?*const fn (ctx: *anyopaque, url: []const u8, mode: platform.OpenMode) bool = null,
    /// Writes the current route into `buf` and returns the written part, or
    /// null when the real route is longer than `buf` can hold. A truncated
    /// route is a different, shorter one than the browser actually shows, so
    /// the caller must refuse it rather than take the shortened copy.
    read_location: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Writes the query string, with no leading "?", into `buf` and returns the
    /// written part. Null when it does not fit, on the same rule
    /// `read_location` follows. Null on a host with no address to read.
    read_query: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Writes the host the page is served from, with no port on it. Null when it
    /// does not fit. An application needs it to name its own server in a URL.
    read_host: ?*const fn (ctx: *anyopaque, buf: []u8) ?[]const u8 = null,
    /// Applies a whole `name:value;name:value` declaration to a node through
    /// the CSSOM, one property at a time.
    ///
    /// A `style` ATTRIBUTE is markup, and a Content Security Policy without
    /// `'unsafe-inline'` refuses every one of them: a page positioned this way
    /// draws nothing and fills the console. Assigning through the style object
    /// instead is not refused, because `script-src` already stopped an attacker
    /// running any script at all, so the CSSOM adds no way in. Same result, same
    /// declaration, and a policy nobody has to loosen.
    ///
    /// Null falls back to `set_attribute`, which keeps a host written before this
    /// existed working, at the cost of needing `'unsafe-inline'`.
    set_style: ?*const fn (ctx: *anyopaque, node: u32, decl: []const u8) void = null,
    /// Adds one rule to a `<style>` element's sheet through the CSSOM, for the
    /// same reason: the TEXT of a style element is markup too, so a policy
    /// refuses it however the element itself was made. The element must already
    /// be in the document, because a detached one has no sheet to add to.
    ///
    /// Null falls back to `set_text_content`.
    add_rule: ?*const fn (ctx: *anyopaque, style_node: u32, rule: []const u8) void = null,
    /// Fills `buf` with cryptographically secure random bytes and reports
    /// whether it managed to. This is `crypto.getRandomValues` on a browser.
    ///
    /// A host that leaves it null has no random source at all, which is not the
    /// same as a source that returns zeros: `std.Io.failing`'s `noRandom` zeroes
    /// the buffer AND reports success, so a caller drawing a key from it gets a
    /// key of zeros and no error. Everything downstream of this hook exists to
    /// stop that particular lie.
    fill_random: ?*const fn (ctx: *anyopaque, buf: []u8) bool = null,
    /// Puts `path` in the address bar without loading a new page, in `mode`.
    write_location: ?*const fn (ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void = null,
    /// Reads a scroll region's current offset (scrollLeft/scrollTop) from the
    /// host. Null on a host that cannot read it back; `render` then carries no
    /// offset across a rebuild, which is today's behaviour: a tap resets every
    /// open region to the top.
    read_scroll_offset: ?*const fn (ctx: *anyopaque, node: u32) geometry.PhysicalOffset = null,
    /// Sets a scroll region's offset on the host. Null on a host that cannot
    /// write it; `render` then leaves a rebuilt region wherever a fresh
    /// element starts, which is today's behaviour.
    write_scroll_offset: ?*const fn (ctx: *anyopaque, node: u32, offset: geometry.PhysicalOffset) void = null,

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
    /// Apply a style declaration. Prefers the CSSOM hook, which a strict Content
    /// Security Policy permits, and falls back to the `style` attribute, which it
    /// does not. See `set_style`.
    pub fn setStyle(self: DomOps, node: u32, decl: []const u8) void {
        const f = self.set_style orelse return self.setAttribute(node, "style", decl);
        f(self.ctx, node, decl);
    }
    /// Add one rule to a style element. Prefers the CSSOM hook for the same
    /// reason, and falls back to setting the element's text. See `add_rule`.
    pub fn addRule(self: DomOps, style_node: u32, rule: []const u8) void {
        const f = self.add_rule orelse return self.setTextContent(style_node, rule);
        f(self.ctx, style_node, rule);
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
    /// Null when the host has no read hook, so a caller cannot tell "no host
    /// support" from "the offset is zero" and must treat both the same way:
    /// nothing to carry across the rebuild.
    pub fn readScrollOffset(self: DomOps, node: u32) ?geometry.PhysicalOffset {
        const f = self.read_scroll_offset orelse return null;
        return f(self.ctx, node);
    }
    pub fn writeScrollOffset(self: DomOps, node: u32, offset: geometry.PhysicalOffset) void {
        const f = self.write_scroll_offset orelse return;
        f(self.ctx, node, offset);
    }
};

/// Build the @font-face CSS block for a list of fonts. Call once at init and
/// inject a single <style> into <head>. Caller owns the returned slice.
/// The CSS family name for a font.
///
/// Derived from the font's own address, NOT from its position in a collected
/// list, and that is a correctness fix rather than a style choice. The faces are
/// declared once from the fonts the FIRST render used, while every later frame
/// names a font by its index in ITS OWN collection. A frame whose text uses a
/// different set, or the same set in a different order, would then ask for a
/// family that was declared for another font, and the page would draw in the
/// wrong one with nothing to indicate it. An address is the same in both places
/// by construction, so the two cannot drift apart.
pub fn fontFamily(buf: []u8, font_ptr: *const text.Font) []const u8 {
    return std.fmt.bufPrint(buf, "pf{x}", .{@intFromPtr(font_ptr)}) catch "pf0";
}

/// The buffer `fontFamily` needs: "pf" and a pointer in hex.
pub const family_len = 2 + @sizeOf(usize) * 2;

/// Build the `@font-face` block for a list of fonts. Call once at init and add
/// the rules to a single sheet. Caller owns the returned slice.
///
/// A font that says where it is served from is referenced BY URL. One that does
/// not has its bytes embedded in the rule as a `data:` URL, which is the only
/// thing left to do with it, and which `font-src 'self'` refuses: see
/// `text.Font.url` for why that matters more than it looks.
pub fn fontFaceCss(gpa: std.mem.Allocator, fonts: []const *text.Font) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (fonts) |font_ptr| {
        var fam: [family_len]u8 = undefined;
        const family = fontFamily(&fam, font_ptr);
        if (font_ptr.url) |url| {
            const face = try std.fmt.allocPrint(gpa, "@font-face{{font-family:{s};src:url(\"{s}\") format(\"opentype\")}}", .{ family, url });
            defer gpa.free(face);
            try buf.appendSlice(gpa, face);
            continue;
        }
        const enc = std.base64.standard.Encoder;
        const b64 = try gpa.alloc(u8, enc.calcSize(font_ptr.bytes.len));
        defer gpa.free(b64);
        _ = enc.encode(b64, font_ptr.bytes);
        const face = try std.fmt.allocPrint(gpa, "@font-face{{font-family:{s};src:url(data:font/otf;base64,{s}) format(\"opentype\")}}", .{ family, b64 });
        defer gpa.free(face);
        try buf.appendSlice(gpa, face);
    }
    return buf.toOwnedSlice(gpa);
}

/// How many clip/scroll regions can nest before `render` refuses to open any
/// more and reports a fault instead of corrupting the frame. A real page nests
/// a handful of regions at most; this catches a runaway or malformed display
/// list rather than reading or writing past a fixed stack.
pub const max_region_depth = 32;

/// How many scroll regions `render` remembers offsets for across a rebuild.
/// Unlike `max_region_depth`, this counts every open region in one frame, not
/// only how deep they nest, because sibling regions do not nest at all. Same
/// bound style as `max_region_depth`: a page past the limit still renders,
/// the regions past it just fall back to today's behaviour (reset to the
/// top), and a fault is reported rather than writing past a fixed array.
pub const max_scroll_regions = 32;

/// Scroll offsets carried across a rebuild, keyed by creation order. A tap
/// rebuilds the whole DOM (see `render`), which would otherwise hand the
/// scroll position of every open region back to the browser's default of
/// zero. A caller (`WebApp`) owns one instance for the life of the page and
/// passes a pointer to every `render` call; passing null opts out of
/// carrying scroll state entirely.
pub const ScrollMemory = struct {
    /// The outer div handle of each scroll region `render` created last
    /// frame, in creation order.
    handles: [max_scroll_regions]u32 = undefined,
    count: usize = 0,
};

/// One open clip or scroll region: the append target and coordinate origin its
/// matching push saw before it changed them. A pop restores exactly this, so a
/// region nested inside another one cannot leak its coordinates into whatever
/// comes after it.
const RegionFrame = struct {
    parent: u32,
    origin: ?geometry.PhysicalOffset,
};

/// Rebuild the whole document body's child tree from the display list. `sink`
/// records a fault when the display list nests more clip/scroll regions than
/// `max_region_depth`; pass null where no sink is wired up.
///
/// `mem`, if given, carries scroll offsets across the rebuild: the region a
/// tap would otherwise reset to the top instead keeps the position the
/// browser already had it at. Pass null to opt out.
///
/// `reset_scroll` is true exactly once, on the render that follows a
/// navigation: the caller is expected to clear it after that one call. A
/// visitor arriving at a new route expects its top, not wherever the
/// previous route happened to be scrolled to, so this render drops `mem`'s
/// saved offsets instead of applying them.
pub fn render(gpa: std.mem.Allocator, ops: DomOps, list: display_list.DisplayList, viewport: geometry.PhysicalSize, bg: geometry.Color, sink: ?*FaultSink, mem: ?*ScrollMemory, reset_scroll: bool) !void {
    // Read every remembered region's live offset before its div is destroyed
    // below. Skipped on a navigation (the new page starts at the top) and
    // when the host cannot read scroll position at all.
    var saved: [max_scroll_regions]geometry.PhysicalOffset = undefined;
    var saved_count: usize = 0;
    if (mem) |m| {
        if (!reset_scroll and ops.read_scroll_offset != null) {
            for (m.handles[0..m.count]) |h| {
                saved[saved_count] = ops.readScrollOffset(h) orelse break;
                saved_count += 1;
            }
        }
        // This frame's regions are recorded fresh as they are created below,
        // in the loop over `list.primitives`.
        m.count = 0;
    }

    ops.clearChildren(ops.body);

    // Collect distinct fonts once; used for text primitive font-family index lookups.
    const fonts = try dom.collectFonts(gpa, list);
    defer gpa.free(fonts);

    // Layout container: position:relative, viewport-sized, branded bg.
    const container = ops.createElement("div");
    {
        const style = try std.fmt.allocPrint(gpa, "position:relative;width:{d}px;height:{d}px;background:rgb({d},{d},{d})", .{ viewport.width, viewport.height, dom.ch(bg.r), dom.ch(bg.g), dom.ch(bg.b) });
        defer gpa.free(style);
        ops.setStyle(container, style);
    }
    ops.appendChild(ops.body, container);

    // parent is where children append (the container, or a scroll/clip region's
    // inner div). region_origin subtracts the region's own origin from child
    // coords. Regions nest, so `region_stack` keeps every open one's parent and
    // origin, and each pop restores exactly the frame its push saved.
    var parent: u32 = container;
    var region_origin: ?geometry.PhysicalOffset = null;
    var region_stack: [max_region_depth]RegionFrame = undefined;
    var region_depth: usize = 0;
    // Opens refused past `max_region_depth`, so a later pop can tell it was
    // never recorded and must not touch `region_stack`.
    var region_skipped: usize = 0;

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
                    ops.setStyle(node, style);
                    ops.appendChild(parent, node);
                } else {
                    // Plain fill rrect (kept identical to Task 1).
                    const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;background:rgba({d},{d},{d},{s})", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, dom.ch(r.color.r), dom.ch(r.color.g), dom.ch(r.color.b), dom.alpha(&abuf, r.color.a) });
                    defer gpa.free(style);
                    const node = ops.createElement("div");
                    ops.setStyle(node, style);
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
                    ops.setStyle(node, style);
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
                    ops.setStyle(node, style);
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
            ops.setStyle(node, style);
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
            ops.setStyle(svg, style);

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
            // A zero length run has nothing to draw, and it is not safe to give
            // one to the host. An empty slice carries the allocator's dangling
            // pointer, and the JS side builds a memory view from that pointer
            // before it reads the length, so it throws on a view it never
            // needed. A blank line in a code block produces exactly this run.
            if (run.text.len == 0) continue;
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
            // Named by the font itself, not by where it landed in this frame's
            // collection. See `fontFamily`: the faces were declared once from
            // the first frame's fonts, so an index would name a different font
            // the moment a later frame used a different set.
            var fam: [family_len]u8 = undefined;
            const family = fontFamily(&fam, font_ptr);
            var tbuf: [8]u8 = undefined;
            // `white-space:pre` because this framework already decided where
            // every line breaks and how wide each run is. Without it a browser
            // applies its own rules to the run: it collapses each stretch of
            // spaces to one, drops the leading spaces of a line, and may break
            // the run again at a width of its own choosing. Indented source in
            // a code block loses its indentation to exactly that.
            const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;white-space:pre;font-family:{s};font-size:{d}px;color:rgba({d},{d},{d},{s})", .{ run.origin.x - ox, run.origin.y - oy, family, run.size, dom.ch(run.color.r), dom.ch(run.color.g), dom.ch(run.color.b), dom.alpha(&tbuf, run.color.a) });
            defer gpa.free(style);
            const node = ops.createElement("div");
            ops.setStyle(node, style);
            ops.setTextContent(node, run.text);
            ops.appendChild(parent, node);
        },
        .push_scroll => |sr| {
            if (region_depth >= max_region_depth) {
                region_skipped += 1;
                if (sink) |s| s.report(.region_overflow, "scroll region nesting exceeded max_region_depth, region skipped");
            } else {
                const ox: f32 = if (region_origin) |o| o.x else 0;
                const oy: f32 = if (region_origin) |o| o.y else 0;
                // Outer div: clipping/scrolling window at the viewport position and
                // size, relative to whatever region this one is nested inside.
                const outer_style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;overflow:scroll", .{ sr.viewport.x - ox, sr.viewport.y - oy, sr.viewport.width, sr.viewport.height });
                defer gpa.free(outer_style);
                const outer = ops.createElement("div");
                ops.setStyle(outer, outer_style);
                ops.appendChild(parent, outer);
                // Inner div: the full content area that scrolls inside the outer.
                const inner_style = try std.fmt.allocPrint(gpa, "position:relative;width:{d}px;height:{d}px", .{ sr.content.width, sr.content.height });
                defer gpa.free(inner_style);
                const inner = ops.createElement("div");
                ops.setStyle(inner, inner_style);
                ops.appendChild(outer, inner);
                // This is the Nth region `render` has built this frame: give
                // it the Nth saved offset (if there is one), then remember its
                // handle so the render after next can read the offset back.
                // Must come after `inner` is attached: `outer` has nothing to
                // scroll to before that, so a browser clamps any offset back
                // to zero rather than holding it for content not there yet.
                if (mem) |m| {
                    if (m.count < max_scroll_regions) {
                        if (m.count < saved_count) ops.writeScrollOffset(outer, saved[m.count]);
                        m.handles[m.count] = outer;
                        m.count += 1;
                    } else if (sink) |s| {
                        s.report(.region_overflow, "scroll region count exceeded max_scroll_regions, offset not tracked");
                    }
                }
                // Children now append to the inner div; coords subtract the
                // viewport origin. The frame this push saw goes on the stack, so
                // the matching pop restores exactly it and not the top level.
                region_stack[region_depth] = .{ .parent = parent, .origin = region_origin };
                region_depth += 1;
                parent = inner;
                region_origin = .{ .x = sr.viewport.x, .y = sr.viewport.y };
            }
        },
        .pop_scroll => {
            if (region_skipped > 0) {
                // This pop matches a push that was refused for depth, not one
                // that opened a region, so there is no frame to restore.
                region_skipped -= 1;
            } else if (region_depth > 0) {
                region_depth -= 1;
                const frame = region_stack[region_depth];
                parent = frame.parent;
                region_origin = frame.origin;
            } else {
                // A pop with no matching push is a malformed display list, a
                // runtime fault and not a programmer error, so it falls back to
                // the top level rather than reading before an empty stack.
                parent = container;
                region_origin = null;
            }
        },
        .push_clip => |cr| {
            if (region_depth >= max_region_depth) {
                region_skipped += 1;
                if (sink) |s| s.report(.region_overflow, "clip region nesting exceeded max_region_depth, region skipped");
            } else {
                const ox: f32 = if (region_origin) |o| o.x else 0;
                const oy: f32 = if (region_origin) |o| o.y else 0;
                // A browser clips to the full rounded shape, so this backend is
                // the one that honours the radius exactly. Positioned relative to
                // whatever region this clip is nested inside, like every other
                // primitive here.
                const style = try std.fmt.allocPrint(gpa, "position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;border-radius:{d}px;overflow:hidden", .{ cr.rect.x - ox, cr.rect.y - oy, cr.rect.width, cr.rect.height, cr.radius });
                defer gpa.free(style);
                const node = ops.createElement("div");
                ops.setStyle(node, style);
                ops.appendChild(parent, node);
                // Children now append inside the clip; coords subtract its origin.
                region_stack[region_depth] = .{ .parent = parent, .origin = region_origin };
                region_depth += 1;
                parent = node;
                region_origin = .{ .x = cr.rect.x, .y = cr.rect.y };
            }
        },
        .pop_clip => {
            if (region_skipped > 0) {
                region_skipped -= 1;
            } else if (region_depth > 0) {
                region_depth -= 1;
                const frame = region_stack[region_depth];
                parent = frame.parent;
                region_origin = frame.origin;
            } else {
                parent = container;
                region_origin = null;
            }
        },
    };

    // Inject a <style> with interactive rules if any were accumulated.
    //
    // Appended BEFORE the rules go in, and not after: a style element that is not
    // in the document has no sheet, and `addRule` has nothing to add to. The
    // fallback path does not care either way, so the order costs it nothing.
    if (rules.items.len > 0) {
        const style_node = ops.createElement("style");
        ops.appendChild(ops.body, style_node);
        ops.addRule(style_node, rules.items);
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
    /// The query string `read_query` reports, with no leading "?". Empty until
    /// a test sets one, which is a page opened on an address with no query.
    search_buf: [location_cap]u8 = undefined,
    search_len: usize = 0,
    /// The host `read_host` reports. Empty until a test sets one, which reads as
    /// a page with no host, a thing no real browser produces; a test that cares
    /// calls `setHost` first.
    host_buf: [location_cap]u8 = undefined,
    host_len: usize = 0,
    /// Scroll offsets a test has set, simulating the browser. Bounded, like
    /// the rest of this mock; a test needs at most a handful of regions.
    scroll_offsets: [scroll_offsets_cap]ScrollEntry = undefined,
    scroll_offsets_len: usize = 0,

    /// Comfortably past `router.max_path`, so a test can park a location here
    /// that is too long for the router's own buffer without touching this
    /// buffer's limit.
    pub const location_cap = 512;

    pub const scroll_offsets_cap = 8;

    const ScrollEntry = struct { node: u32, offset: geometry.PhysicalOffset };

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

    /// Sets the query string `readQuery` reports, with no leading "?", without
    /// recording a call. The browser keeps the query out of the path, so this is
    /// separate from `setLocation` rather than parsed back out of it.
    pub fn setSearch(self: *Recorder, query: []const u8) void {
        @memcpy(self.search_buf[0..query.len], query);
        self.search_len = query.len;
    }

    fn readQuery(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.search_len > buf.len) return null;
        @memcpy(buf[0..self.search_len], self.search_buf[0..self.search_len]);
        return buf[0..self.search_len];
    }

    /// Stands in for `crypto.getRandomValues`. Deterministic on purpose: a test
    /// needs to know what it got, and what is under test is that the bytes come
    /// from the host at all rather than from `noRandom`'s memset of zeros. The
    /// sequence starts at 1 so a filled buffer never looks like an empty one.
    fn fillRandom(ctx: *anyopaque, buf: []u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("fillRandom({d})", .{buf.len});
        for (buf, 0..) |*b, i| b.* = @truncate(i +% 1);
        return true;
    }

    /// Sets the host `readHost` reports, without recording a call.
    pub fn setHost(self: *Recorder, host: []const u8) void {
        @memcpy(self.host_buf[0..host.len], host);
        self.host_len = host.len;
    }

    fn readHost(ctx: *anyopaque, buf: []u8) ?[]const u8 {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.host_len > buf.len) return null;
        @memcpy(buf[0..self.host_len], self.host_buf[0..self.host_len]);
        return buf[0..self.host_len];
    }

    fn writeLocation(ctx: *anyopaque, path: []const u8, mode: platform.WriteMode) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("writeLocation({s},{s})", .{ path, @tagName(mode) });
        self.setLocation(path);
    }

    /// Sets the offset `readScrollOffset` reports for `node`, without
    /// recording a call. Lets a test simulate the browser having scrolled a
    /// region, the same way `setLocation` simulates the address bar.
    pub fn setScrollOffset(self: *Recorder, node: u32, offset: geometry.PhysicalOffset) void {
        for (self.scroll_offsets[0..self.scroll_offsets_len]) |*e| {
            if (e.node == node) {
                e.offset = offset;
                return;
            }
        }
        self.scroll_offsets[self.scroll_offsets_len] = .{ .node = node, .offset = offset };
        self.scroll_offsets_len += 1;
    }

    fn readScrollOffset(ctx: *anyopaque, node: u32) geometry.PhysicalOffset {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        var off = geometry.PhysicalOffset.zero;
        for (self.scroll_offsets[0..self.scroll_offsets_len]) |e| {
            if (e.node == node) {
                off = e.offset;
                break;
            }
        }
        self.rec("readScrollOffset({d})->{d},{d}", .{ node, off.x, off.y });
        return off;
    }

    fn writeScrollOffset(ctx: *anyopaque, node: u32, offset: geometry.PhysicalOffset) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("writeScrollOffset({d},{d},{d})", .{ node, offset.x, offset.y });
        self.setScrollOffset(node, offset);
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

    /// Recorded under its own name, not as `setAttribute(n,style,...)`, because
    /// the difference between the two IS the thing under test: one is markup a
    /// Content Security Policy refuses and the other is not.
    fn setStyle(ctx: *anyopaque, node: u32, decl: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("setStyle({d},{s})", .{ node, decl });
    }

    fn addRule(ctx: *anyopaque, style_node: u32, rule: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.rec("addRule({d},{s})", .{ style_node, rule });
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
            .read_query = readQuery,
            .read_host = readHost,
            .set_style = setStyle,
            .add_rule = addRule,
            .fill_random = fillRandom,
            .write_location = writeLocation,
            .read_scroll_offset = readScrollOffset,
            .write_scroll_offset = writeScrollOffset,
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // clears body, builds the container, then the rrect div with the right style + append.
    try std.testing.expect(contains(rec.log.items, "clearChildren(1)"));
    try std.testing.expect(contains(rec.log.items, "position:relative;width:200px"));
    try std.testing.expect(contains(rec.log.items, "left:10px;top:20px;width:30px;height:40px;border-radius:4px;background:rgba(255,0,0,1)"));
}

test "dom_calls: a text primitive names its font the same way the font-face does" {
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // The raw string is passed directly (browser handles escaping).
    try std.testing.expect(contains(rec.log.items, "setTextContent") and contains(rec.log.items, "<b>hi</b>"));
    // The family the run asks for must be the one the face was declared under.
    // Comparing the two rather than pinning a literal is the whole point: an
    // index satisfied a literal happily while naming a different font on any
    // frame whose text used a different set.
    var fam: [family_len]u8 = undefined;
    const family = fontFamily(&fam, &font);
    const decl = try fontFaceCss(gpa, &.{&font});
    defer gpa.free(decl);
    try std.testing.expect(std.mem.indexOf(u8, decl, family) != null);

    var want: [family_len + 12]u8 = undefined;
    const asked = try std.fmt.bufPrint(&want, "font-family:{s}", .{family});
    try std.testing.expect(contains(rec.log.items, asked));
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
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
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    try std.testing.expect(contains(rec.log.items, ".pb0{cursor:pointer}"));
    try std.testing.expect(!contains(rec.log.items, ".pb1"));
}

test "dom_calls: a wrapped paragraph's three text runs each set a different line, never the whole paragraph" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // Narrow enough that "one", "two" and "three" each land on their own line.
    const source = "one two three";
    const m = text.mono.TextMetrics{ .mono = text.mono.Mono.fromCell(10, 20) };
    var p = try text.layout.layoutParagraph(gpa, &font, source, 14, m, 55);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    var y: f32 = 0;
    for (p.lines) |l| {
        try list.append(gpa, .{ .text = .{
            .glyphs = l.glyphs,
            .text = source[l.start..l.end],
            .font = &font,
            .size = 14,
            .color = geometry.Color.rgb(1, 1, 1),
            .origin = .{ .x = 0, .y = y },
        } });
        y += l.height;
    }
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);

    // Three distinct setTextContent calls, one per line, exactly matching the
    // line each was drawn for.
    try std.testing.expect(contains(rec.log.items, "setTextContent(102,one)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent(103,two)"));
    try std.testing.expect(contains(rec.log.items, "setTextContent(104,three)"));
    // This is what a run holding `self.text` (the whole paragraph) would have
    // produced on every line, and is exactly what must never appear.
    try std.testing.expect(!contains(rec.log.items, source));
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
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // Outer div has overflow:scroll and the viewport position/size.
    try std.testing.expect(contains(rec.log.items, "overflow:scroll"));
    try std.testing.expect(contains(rec.log.items, "left:10px;top:20px;width:100px;height:50px;overflow:scroll"));
    // Inner div has position:relative and the content size.
    try std.testing.expect(contains(rec.log.items, "position:relative;width:100px;height:300px"));
    // The rrect is appended to the inner div with adjusted coords: left=0 (10-10), top=100 (120-20).
    try std.testing.expect(contains(rec.log.items, "left:0px;top:100px"));
}

test "dom_calls: a clip nested in a scroll positions itself relative to the scroll's origin, not the canvas" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // Clip at absolute x=30,y=50: nested inside the scroll, so its own div must
    // sit at (30-10, 50-20) relative to the scroll's inner div, not at (30,50).
    try list.append(gpa, .{ .push_clip = .{
        .rect = geometry.PhysicalRect{ .x = 30, .y = 50, .width = 40, .height = 40 },
        .radius = 0,
    } });
    try list.append(gpa, .{ .pop_clip = {} });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    try std.testing.expect(contains(rec.log.items, "left:20px;top:30px;width:40px;height:40px"));
    // The un-adjusted absolute position must not appear: that would place the
    // clip twice as far from the scroll's own corner as it should be.
    try std.testing.expect(!contains(rec.log.items, "left:30px;top:50px;width:40px;height:40px"));
}

test "dom_calls: after a clip inside a scroll pops, later primitives return to the scroll's own div and origin" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 100 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .push_clip = .{
        .rect = geometry.PhysicalRect{ .x = 5, .y = 5, .width = 50, .height = 50 },
        .radius = 0,
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 10, .y = 10, .width = 8, .height = 8 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_clip = {} });
    // After the clip pops, this rrect is still inside the scroll: it must
    // append to the scroll's inner div (handle 103, not the container) and use
    // the scroll's origin (10,20), not the clip's or the canvas's absolute one.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 15, .y = 25, .width = 9, .height = 9 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 1, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // container=101, scroll outer=102, scroll inner=103, clip div=104, first
    // rrect div=105, second rrect div=106.
    try std.testing.expect(contains(rec.log.items, "appendChild(103,106)"));
    try std.testing.expect(!contains(rec.log.items, "appendChild(101,106)"));
    try std.testing.expect(contains(rec.log.items, "left:5px;top:5px;width:9px;height:9px"));
}

test "dom_calls: after a scroll nested inside another scroll pops, later primitives return to the outer scroll's div and origin" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 10, .y = 20, .width = 200, .height = 200 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 200, .height = 400 },
    } });
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 30, .y = 40, .width = 50, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 50, .height = 150 },
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 35, .y = 45, .width = 6, .height = 6 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    // After the inner scroll pops, this rrect is still inside the outer one: it
    // must append to the outer's inner div (handle 103) with the outer's origin
    // (10,20), not the container with the inner scroll's or no origin at all.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 15, .y = 25, .width = 7, .height = 7 },
        .radius = 0,
        .color = geometry.Color.rgb(0, 1, 0),
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 500 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // container=101, outer scroll outer/inner=102/103, inner scroll outer/inner=104/105,
    // first rrect div=106, second rrect div=107.
    try std.testing.expect(contains(rec.log.items, "appendChild(103,107)"));
    try std.testing.expect(!contains(rec.log.items, "appendChild(101,107)"));
    try std.testing.expect(contains(rec.log.items, "left:5px;top:5px;width:7px;height:7px"));
}

test "dom_calls: a region nested past max_region_depth is skipped and reports a fault, without breaking the pops that follow" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var sink = FaultSink{};
    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    // One more push than the cap allows.
    var i: usize = 0;
    while (i < max_region_depth + 1) : (i += 1) {
        try list.append(gpa, .{ .push_clip = .{
            .rect = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 10, .height = 10 },
            .radius = 0,
        } });
    }
    i = 0;
    while (i < max_region_depth + 1) : (i += 1) {
        try list.append(gpa, .{ .pop_clip = {} });
    }
    // One more primitive after every push/pop balances out, to prove the stack
    // ended up back at the container rather than corrupted by the overflow.
    try list.append(gpa, .{ .rrect = .{
        .rect = geometry.PhysicalRect{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 300, .height = 200 }, geometry.Color.rgb(0, 0, 0), &sink, null, false);
    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(FaultSink.FaultCode.region_overflow, sink.first.?.code);
    // container=101, then one div per honoured push (max_region_depth of them,
    // handles 102..133); the refused push creates nothing. The trailing rrect's
    // div is handle 134 and must append to the container: every honoured push
    // was correctly unwound and the one refused push left nothing dangling for
    // its matching pop to (mis)restore.
    try std.testing.expect(contains(rec.log.items, "appendChild(101,134)"));
    try std.testing.expect(contains(rec.log.items, "left:1px;top:2px;width:3px;height:4px"));
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
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
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);

    // createElement("svg") builds an HTML unknown element that never paints, so
    // the namespaced call is the fact this pins.
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,svg)"));
    try std.testing.expect(contains(rec.log.items, "createElementNS(http://www.w3.org/2000/svg,path)"));
    // The viewBox is the grid and the size is the request: two different values.
    try std.testing.expect(contains(rec.log.items, "viewBox,0 0 24 24"));
    try std.testing.expect(contains(rec.log.items, "width,40"));
    try std.testing.expect(contains(rec.log.items, "height,40"));
    // Through the CSSOM, not as a `style` attribute: the attribute form is what
    // a strict Content Security Policy refuses.
    try std.testing.expect(contains(rec.log.items, "setStyle(") and contains(rec.log.items, "position:absolute;left:6px;top:9px"));
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
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);

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
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
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
    try render(gpa, ops, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
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
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);
    // No img element should be created (fromRgba has no encoded bytes).
    try std.testing.expect(!contains(rec.log.items, "createElement(img)"));
}

test "a text run keeps its own spacing instead of letting the browser collapse it" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();

    var h = try @import("../testing.zig").mount(gpa, blk: {
        const t = @import("../widgets/text.zig").Text{ .text = "    indented", .size = 16 };
        break :blk t.widget();
    });
    defer h.deinit();
    try h.pump();

    try render(gpa, rec.ops(), h.canvas.list, .{ .width = 200, .height = 100 }, .{ .r = 0, .g = 0, .b = 0, .a = 1 }, null, null, false);

    // Without this rule a browser drops the leading spaces of a run and
    // collapses every other stretch of them, so indented source loses its
    // shape. This framework already placed the run, so the browser must not
    // re-space it.
    try std.testing.expect(contains(rec.log.items, "white-space:pre"));
    try std.testing.expect(contains(rec.log.items, "    indented"));
}

test "dom_calls: a scroll region's offset survives a second render at the same offset" {
    // A tap rebuilds the whole DOM (see `render`'s doc comment), destroying
    // the div the browser was scrolling and building a fresh one in its
    // place. `mem` is what carries the old offset onto the new div, so a tap
    // must never reset a region the visitor had scrolled.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    // First render: container=101, scroll outer=102, inner=103.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, false);
    try std.testing.expectEqual(@as(usize, 1), mem.count);
    try std.testing.expectEqual(@as(u32, 102), mem.handles[0]);

    // The visitor scrolls. The browser owns this value, not the framework, so
    // the test moves it the same way the browser would: on the live node.
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });

    // A tap: the whole tree rebuilds again. New container=104, new outer=105.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, false);

    // The new region was handed back the offset the old one held.
    try std.testing.expect(contains(rec.log.items, "writeScrollOffset(105,0,77)"));
    try std.testing.expectEqual(@as(u32, 105), mem.handles[0]);
}

test "dom_calls: a navigation clears a scroll region's offset instead of carrying it to the new page" {
    // A visitor who follows a link expects the top of the new page, exactly
    // like a browser gives them on any ordinary navigation. `reset_scroll`
    // is how a caller tells `render` this rebuild is that kind, not a tap.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    // First render: outer=102. The visitor scrolls it.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, false);
    rec.setScrollOffset(102, .{ .x = 0, .y = 77 });

    // A navigation to a new route: new outer=105, reset_scroll=true.
    try render(gpa, rec.ops(), list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, true);

    // The old offset is never read back and never written onto the new
    // region: it is left at the browser's own default of zero for a freshly
    // created element, exactly like following a link to any other page.
    try std.testing.expect(!contains(rec.log.items, "readScrollOffset(102)"));
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset(105"));
}

test "dom_calls: a host with no scroll offset hooks still renders a scroll region" {
    // Every existing DomOps leaves these two hooks null, the same as
    // create_element_ns before this fix. Rendering must degrade to today's
    // behaviour (no carried offset) rather than fail.
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var mem = ScrollMemory{};
    var ops = rec.ops();
    ops.read_scroll_offset = null;
    ops.write_scroll_offset = null;

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geometry.PhysicalRect{ .x = 0, .y = 0, .width = 100, .height = 50 },
        .offset = geometry.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geometry.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });

    try render(gpa, ops, list, .{ .width = 200, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, &mem, false);

    // The region still builds normally.
    try std.testing.expect(contains(rec.log.items, "overflow:scroll"));
    // Neither hook exists, so neither is ever called.
    try std.testing.expect(!contains(rec.log.items, "readScrollOffset("));
    try std.testing.expect(!contains(rec.log.items, "writeScrollOffset("));
    // The region is still remembered, so a host that gains the hooks later
    // starts carrying its offset from the very next render.
    try std.testing.expectEqual(@as(usize, 1), mem.count);
}

test "dom_calls: a rendered frame sets no style ATTRIBUTE anywhere, because a strict policy refuses every one" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    try render(gpa, rec.ops(), list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);

    // The whole point of the change, stated as the thing that must not happen.
    // A single one of these blanks the page under `style-src` without
    // `'unsafe-inline'`, so the assertion is on the absence, not on a sample.
    for (rec.log.items) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "setAttribute(") == null or
            std.mem.indexOf(u8, line, ",style,") == null);
    }
    // And the positioning really did happen, so the loop above is not passing
    // because nothing was drawn.
    try std.testing.expect(contains(rec.log.items, "setStyle("));
    try std.testing.expect(contains(rec.log.items, "position:absolute"));
    // The interactive rule went through the sheet rather than the element text.
    try std.testing.expect(contains(rec.log.items, "addRule("));
    try std.testing.expect(!contains(rec.log.items, "setTextContent"));
}

test "dom_calls: a host with no CSSOM hooks still renders, through the attribute it can use" {
    const gpa = std.testing.allocator;
    var rec = Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops_no_cssom = rec.ops();
    // A host written before these hooks existed. It needs `'unsafe-inline'`, and
    // that is its choice to make, but it must not stop drawing.
    ops_no_cssom.set_style = null;
    ops_no_cssom.add_rule = null;

    var list = display_list.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = geometry.Color.rgb(1, 0, 0),
        .hover_color = geometry.Color.rgb(0, 1, 0),
    } });
    try render(gpa, ops_no_cssom, list, .{ .width = 100, .height = 100 }, geometry.Color.rgb(0, 0, 0), null, null, false);

    try std.testing.expect(contains(rec.log.items, ",style,position:absolute"));
    try std.testing.expect(contains(rec.log.items, "setTextContent"));
    try std.testing.expect(!contains(rec.log.items, "setStyle("));
}

test "dom_calls: a font that is served as a file is referenced by url, never embedded" {
    const gpa = std.testing.allocator;
    var font = try text.builtin.neuropol(gpa);
    defer font.deinit(gpa);

    const css = try fontFaceCss(gpa, &.{&font});
    defer gpa.free(css);

    // `font-src 'self'` refuses a `data:` URL however the rule reached the
    // document, and a refused font is not a cosmetic problem: layout was
    // measured against this font, so the glyphs a person sees and the rectangles
    // taps are tested against stop agreeing.
    try std.testing.expect(std.mem.indexOf(u8, css, "data:") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"fonts/Neuropol.otf\")") != null);
}

test "dom_calls: a font with nowhere to be fetched from still works, embedded" {
    const gpa = std.testing.allocator;
    // What an application's own font looks like: loaded from bytes, served from
    // nowhere. It needs `font-src data:`, and that is the application's call.
    var font = try text.Font.load(gpa, text.builtin.mesmerize_rg_bytes);
    defer font.deinit(gpa);
    try std.testing.expectEqual(@as(?[]const u8, null), font.url);

    const css = try fontFaceCss(gpa, &.{&font});
    defer gpa.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "data:font/otf;base64,") != null);
}

test "dom_calls: two fonts get two different families, so neither can answer for the other" {
    const gpa = std.testing.allocator;
    var a = try text.builtin.neuropol(gpa);
    defer a.deinit(gpa);
    var b = try text.builtin.mesmerize_rg(gpa);
    defer b.deinit(gpa);

    var fam_a: [family_len]u8 = undefined;
    var fam_b: [family_len]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, fontFamily(&fam_a, &a), fontFamily(&fam_b, &b)));

    // And the order they are declared in does not change what either is called,
    // which is exactly what an index could not promise.
    const one = try fontFaceCss(gpa, &.{ &a, &b });
    defer gpa.free(one);
    const other = try fontFaceCss(gpa, &.{ &b, &a });
    defer gpa.free(other);
    try std.testing.expect(std.mem.indexOf(u8, one, fontFamily(&fam_a, &a)) != null);
    try std.testing.expect(std.mem.indexOf(u8, other, fontFamily(&fam_a, &a)) != null);
}
