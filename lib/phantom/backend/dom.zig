const std = @import("std");
const dl = @import("../display_list.zig");
const geom = @import("../geometry.zig");
const text = @import("../text.zig");
const image_mod = @import("../image/Image.zig");
const icon_builtin = @import("../icon/builtin.zig");
const svg_path = @import("../icon/svg_path.zig");

pub fn ch(v: f32) u8 {
    const scaled = std.math.clamp(v, 0.0, 1.0) * 255.0;
    return @intFromFloat(@round(scaled));
}

/// Format a 0..1 alpha channel for CSS rgba(). Opaque prints "1" (keeps the common
/// case byte-stable), transparent prints "0", otherwise 2-decimal with trailing
/// zeros trimmed (0.3 rather than 0.30000001192092896 that a raw float print gives).
/// Writes into `buf` (>= 5 bytes) and returns the slice.
pub fn alpha(buf: []u8, v: f32) []const u8 {
    const hundredths: u32 = @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 100.0));
    if (hundredths >= 100) return "1";
    if (hundredths == 0) return "0";
    if (hundredths % 10 == 0) return std.fmt.bufPrint(buf, "0.{d}", .{hundredths / 10}) catch "0";
    return std.fmt.bufPrint(buf, "0.{d:0>2}", .{hundredths}) catch "0";
}

/// Collect distinct font pointers from the display list and return a slice of
/// them in insertion order. Caller owns the returned slice (gpa.free).
pub fn collectFonts(gpa: std.mem.Allocator, list: dl.DisplayList) ![]const *text.Font {
    var ptrs: std.ArrayList(*text.Font) = .empty;
    errdefer ptrs.deinit(gpa);
    for (list.primitives.items) |p| {
        switch (p) {
            .text => |run| {
                const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
                var found = false;
                for (ptrs.items) |existing| {
                    if (existing == font_ptr) {
                        found = true;
                        break;
                    }
                }
                if (!found) try ptrs.append(gpa, font_ptr);
            },
            else => {},
        }
    }
    return ptrs.toOwnedSlice(gpa);
}

/// Write HTML-escaped text (escaping &, <, >) into buf.
fn appendEscaped(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |byte| {
        switch (byte) {
            '&' => try buf.appendSlice(gpa, "&amp;"),
            '<' => try buf.appendSlice(gpa, "&lt;"),
            '>' => try buf.appendSlice(gpa, "&gt;"),
            else => try buf.append(gpa, byte),
        }
    }
}

pub fn renderToString(gpa: std.mem.Allocator, list: dl.DisplayList, viewport: geom.PhysicalSize, bg: geom.Color) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Base style: fill the whole browser viewport with the theme background and drop
    // the default body margin, so the branded bg reaches the window edges even though
    // the layout container below is a fixed size (the real viewport size is threaded
    // in a later slice). bg is emitted numerically (ch), so there is no injection path.
    const base_style = try std.fmt.allocPrint(gpa, "<style>html,body{{margin:0;background:rgb({d},{d},{d})}}</style>", .{ ch(bg.r), ch(bg.g), ch(bg.b) });
    defer gpa.free(base_style);
    try buf.appendSlice(gpa, base_style);

    // Collect distinct fonts for @font-face emission.
    const fonts = try collectFonts(gpa, list);
    defer gpa.free(fonts);

    // Emit a <style> block with one @font-face per distinct font.
    if (fonts.len > 0) {
        try buf.appendSlice(gpa, "<style>");
        for (fonts, 0..) |font_ptr, i| {
            const enc = std.base64.standard.Encoder;
            const b64_len = enc.calcSize(font_ptr.bytes.len);
            const b64_buf = try gpa.alloc(u8, b64_len);
            defer gpa.free(b64_buf);
            _ = enc.encode(b64_buf, font_ptr.bytes);
            const face = try std.fmt.allocPrint(gpa, "@font-face{{font-family:pf{d};src:url(data:font/otf;base64,{s}) format(\"opentype\")}}", .{ i, b64_buf });
            defer gpa.free(face);
            try buf.appendSlice(gpa, face);
        }
        try buf.appendSlice(gpa, "</style>");
    }

    const open = try std.fmt.allocPrint(gpa, "<div style=\"position:relative;width:{d}px;height:{d}px;background:rgb({d},{d},{d})\">", .{ viewport.width, viewport.height, ch(bg.r), ch(bg.g), ch(bg.b) });
    defer gpa.free(open);
    try buf.appendSlice(gpa, open);

    var rules: std.ArrayList(u8) = .empty;
    defer rules.deinit(gpa);
    var cls: u32 = 0;
    var region_origin: ?geom.PhysicalOffset = null;

    for (list.primitives.items) |p| switch (p) {
        .rrect => |r| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            var abuf: [8]u8 = undefined;
            if (r.hover_color == null and r.active_color == null) {
                // Plain rrect: byte-identical output for opaque colors (regression path).
                const div = if (r.stroke_width > 0)
                    try std.fmt.allocPrint(gpa, "<div style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;" ++
                        "border-radius:{d}px;box-sizing:border-box;border:{d}px solid rgba({d},{d},{d},{s});background:transparent\"></div>", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, r.stroke_width, ch(r.color.r), ch(r.color.g), ch(r.color.b), alpha(&abuf, r.color.a) })
                else
                    try std.fmt.allocPrint(gpa, "<div style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;" ++
                        "border-radius:{d}px;background:rgba({d},{d},{d},{s})\"></div>", .{ r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, ch(r.color.r), ch(r.color.g), ch(r.color.b), alpha(&abuf, r.color.a) });
                defer gpa.free(div);
                try buf.appendSlice(gpa, div);
            } else {
                // Interactive rrect: base div carries a class; state colors go to <style> rules.
                const c = cls;
                cls += 1;
                if (r.stroke_width > 0) {
                    const div = try std.fmt.allocPrint(gpa, "<div class=\"pb{d}\" style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;" ++
                        "border-radius:{d}px;box-sizing:border-box;border:{d}px solid rgba({d},{d},{d},{s});background:transparent\"></div>", .{ c, r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, r.stroke_width, ch(r.color.r), ch(r.color.g), ch(r.color.b), alpha(&abuf, r.color.a) });
                    defer gpa.free(div);
                    try buf.appendSlice(gpa, div);
                    if (r.hover_color) |h| {
                        var hbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:hover{{border-color:rgba({d},{d},{d},{s})}}", .{ c, ch(h.r), ch(h.g), ch(h.b), alpha(&hbuf, h.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                    if (r.active_color) |a| {
                        var pbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:active{{border-color:rgba({d},{d},{d},{s})}}", .{ c, ch(a.r), ch(a.g), ch(a.b), alpha(&pbuf, a.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                } else {
                    const div = try std.fmt.allocPrint(gpa, "<div class=\"pb{d}\" style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;" ++
                        "border-radius:{d}px;background:rgba({d},{d},{d},{s})\"></div>", .{ c, r.rect.x - ox, r.rect.y - oy, r.rect.width, r.rect.height, r.radius, ch(r.color.r), ch(r.color.g), ch(r.color.b), alpha(&abuf, r.color.a) });
                    defer gpa.free(div);
                    try buf.appendSlice(gpa, div);
                    if (r.hover_color) |h| {
                        var hbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:hover{{background:rgba({d},{d},{d},{s})}}", .{ c, ch(h.r), ch(h.g), ch(h.b), alpha(&hbuf, h.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                    if (r.active_color) |a| {
                        var pbuf: [8]u8 = undefined;
                        const rule = try std.fmt.allocPrint(gpa, ".pb{d}:active{{background:rgba({d},{d},{d},{s})}}", .{ c, ch(a.r), ch(a.g), ch(a.b), alpha(&pbuf, a.a) });
                        defer gpa.free(rule);
                        try rules.appendSlice(gpa, rule);
                    }
                }
            }
        },
        .push_scroll => |sr| {
            const div = try std.fmt.allocPrint(gpa, "<div style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;overflow:scroll\">" ++
                "<div style=\"position:relative;width:{d}px;height:{d}px\">", .{ sr.viewport.x, sr.viewport.y, sr.viewport.width, sr.viewport.height, sr.content.width, sr.content.height });
            defer gpa.free(div);
            try buf.appendSlice(gpa, div);
            region_origin = .{ .x = sr.viewport.x, .y = sr.viewport.y };
        },
        .pop_scroll => {
            try buf.appendSlice(gpa, "</div></div>");
            region_origin = null;
        },
        .push_clip => |cr| {
            // A browser clips to the full rounded shape, so this backend is the
            // one that honours the radius exactly.
            const div = try std.fmt.allocPrint(gpa, "<div style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px;" ++
                "border-radius:{d}px;overflow:hidden\">", .{ cr.rect.x, cr.rect.y, cr.rect.width, cr.rect.height, cr.radius });
            defer gpa.free(div);
            try buf.appendSlice(gpa, div);
            region_origin = .{ .x = cr.rect.x, .y = cr.rect.y };
        },
        .pop_clip => {
            try buf.appendSlice(gpa, "</div>");
            region_origin = null;
        },
        .image => |img| {
            const im: *image_mod.Image = @ptrCast(@alignCast(img.image));
            if (im.bytes.len == 0) continue; // no encoded bytes -> nothing to <img> (v1: fromRgba images skipped on web)
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const enc = std.base64.standard.Encoder;
            const b64_buf = try gpa.alloc(u8, enc.calcSize(im.bytes.len));
            defer gpa.free(b64_buf);
            _ = enc.encode(b64_buf, im.bytes);
            const tag = try std.fmt.allocPrint(gpa, "<img style=\"position:absolute;left:{d}px;top:{d}px;width:{d}px;height:{d}px\" src=\"data:{s};base64,{s}\">", .{ img.rect.x - ox, img.rect.y - oy, img.rect.width, img.rect.height, image_mod.Image.mime(im.format), b64_buf });
            defer gpa.free(tag);
            try buf.appendSlice(gpa, tag);
        },
        .icon => |ic| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const icon_path = icon_builtin.pathFor(ic.id);
            const d = try svg_path.data(gpa, icon_path, icon_builtin.grid);
            defer gpa.free(d);
            // The viewBox is the authoring grid and width/height are the size
            // the frontend asked for, so the browser does the scaling and one
            // centreline serves every size. That also fixes stroke-width in
            // GRID units: scaling it here as well would square the factor.
            //
            // `preserveAspectRatio="none"` lets the two axes scale apart. The
            // default centres the square grid inside the box and leaves the rest
            // blank, which for a rule in a tall box draws exactly the short,
            // gapped mark the box was made non-square to avoid.
            var gbuf: [svg_path.coord_len]u8 = undefined;
            const grid_s = svg_path.coord(&gbuf, icon_builtin.grid);
            var sbuf: [svg_path.coord_len]u8 = undefined;
            var abuf: [8]u8 = undefined;
            const svg_open = try std.fmt.allocPrint(gpa, "<svg viewBox=\"0 0 {s} {s}\" preserveAspectRatio=\"none\" width=\"{d}\" height=\"{d}\" style=\"position:absolute;left:{d}px;top:{d}px\">", .{ grid_s, grid_s, ic.size.width, ic.size.height, ic.origin.x - ox, ic.origin.y - oy });
            defer gpa.free(svg_open);
            try buf.appendSlice(gpa, svg_open);
            // `<title>` is the accessible name of an inline SVG, and the first
            // child is the one a screen reader reads. It is written only when
            // there is a name: an empty title takes the name slot and then
            // announces nothing, which is worse than a mark with no title at
            // all, because a reader can still fall back on the surroundings.
            if (ic.label) |name| {
                try buf.appendSlice(gpa, "<title>");
                try appendEscaped(&buf, gpa, name);
                try buf.appendSlice(gpa, "</title>");
            }
            const tag = try std.fmt.allocPrint(gpa, "<path d=\"{s}\" fill=\"none\" stroke=\"rgba({d},{d},{d},{s})\" stroke-width=\"{s}\" stroke-linecap=\"{s}\" stroke-linejoin=\"{s}\"/></svg>", .{ d, ch(ic.color.r), ch(ic.color.g), ch(ic.color.b), alpha(&abuf, ic.color.a), svg_path.coord(&sbuf, icon_path.stroke.width), svg_path.lineCap(icon_path.stroke.cap), svg_path.lineJoin(icon_path.stroke.join) });
            defer gpa.free(tag);
            try buf.appendSlice(gpa, tag);
        },
        .text => |run| {
            const ox: f32 = if (region_origin) |o| o.x else 0;
            const oy: f32 = if (region_origin) |o| o.y else 0;
            const font_ptr: *text.Font = @ptrCast(@alignCast(run.font));
            // Find the index for this font pointer.
            // collectFonts scanned the same primitive list, so every text run's font
            // is guaranteed present; the else enforces that invariant.
            var font_idx: usize = 0;
            for (fonts, 0..) |fp, i| {
                if (fp == font_ptr) {
                    font_idx = i;
                    break;
                }
            } else unreachable;
            var tbuf: [8]u8 = undefined;
            const header = try std.fmt.allocPrint(gpa, "<div style=\"position:absolute;left:{d}px;top:{d}px;font-family:pf{d};font-size:{d}px;color:rgba({d},{d},{d},{s})\">", .{
                run.origin.x - ox, run.origin.y - oy,
                font_idx,          run.size,
                ch(run.color.r),   ch(run.color.g),
                ch(run.color.b),   alpha(&tbuf, run.color.a),
            });
            defer gpa.free(header);
            try buf.appendSlice(gpa, header);
            try appendEscaped(&buf, gpa, run.text);
            try buf.appendSlice(gpa, "</div>");
        },
    };

    try buf.appendSlice(gpa, "</div>");
    if (rules.items.len > 0) {
        try buf.appendSlice(gpa, "<style>");
        try buf.appendSlice(gpa, rules.items);
        try buf.appendSlice(gpa, "</style>");
    }
    return buf.toOwnedSlice(gpa);
}

test "renderToString emits an @font-face and a positioned text div" {
    const gpa = std.testing.allocator;
    var font = try @import("../text.zig").Font.load(gpa, @import("../text.zig").builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = 'H', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{ .glyphs = &glyphs, .text = "Hello", .font = &font, .size = 24, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 12, .y = 34 } } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "@font-face") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "font-family:pf0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "base64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Hello<") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:12px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "font-size:24px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgb(0,0,0)") != null);
}

test "renderToString emits a positioned div with border-radius" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 40, .y = 40, .width = 720, .height = 520 },
        .radius = 16,
        .color = geom.Color.rgb(0.15, 0.35, 0.85),
    } });

    const html = try renderToString(std.testing.allocator, list, geom.PhysicalSize{ .width = 800, .height = 600 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "left:40px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "top:40px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "border-radius:16px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:720px") != null);
    // verify the float->0..255 channel conversion (0.15,0.35,0.85 -> 38,89,217)
    try std.testing.expect(std.mem.indexOf(u8, html, "rgba(38,89,217,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgb(0,0,0)") != null);
}

test "renderToString escapes special characters in text content" {
    const gpa = std.testing.allocator;
    var font = try @import("../text.zig").Font.load(gpa, @import("../text.zig").builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = '<', .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{ .glyphs = &glyphs, .text = "<b>&", .font = &font, .size = 16, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 0, .y = 0 } } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    // Escaped form must be present.
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;b&gt;&amp;") != null);
    // Raw injection vectors must be absent.
    try std.testing.expect(std.mem.indexOf(u8, html, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
}

test "renderToString: filled rrect uses background and no border; stroked rrect uses border and transparent" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    // Filled rrect: red at x=10,y=20,w=100,h=50,r=5
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .radius = 5,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    // Stroked rrect: green at x=60,y=70,w=80,h=40,r=8, stroke 3px
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 60, .y = 70, .width = 80, .height = 40 },
        .radius = 8,
        .color = geom.Color.rgb(0, 0.502, 0),
        .stroke_width = 3,
    } });
    const html = try renderToString(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    // (a) Filled div: background present, no border property.
    try std.testing.expect(std.mem.indexOf(u8, html, "background:rgba(255,0,0,1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:10px") != null);

    // (b) Stroked div: border + box-sizing + transparent background + stroke color.
    try std.testing.expect(std.mem.indexOf(u8, html, "border:3px solid rgba(") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "box-sizing:border-box") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "background:transparent") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:60px") != null);

    // (c) Filled rrect regression: byte-for-byte match of the pre-change format.
    // The filled div must be exactly this string with no border property.
    const expected_filled = "<div style=\"position:absolute;left:10px;top:20px;width:100px;height:50px;border-radius:5px;background:rgba(255,0,0,1)\"></div>";
    try std.testing.expect(std.mem.indexOf(u8, html, expected_filled) != null);
    // Filled rrect must NOT contain any border property.
    // We check the filled div substring does not contain "border:".
    const filled_start = std.mem.indexOf(u8, html, "left:10px").?;
    const filled_end = std.mem.indexOf(u8, html[filled_start..], "</div>").? + filled_start + 6;
    try std.testing.expect(std.mem.indexOf(u8, html[filled_start..filled_end], "border:") == null);
}

test "renderToString: plain filled rrect is byte-identical (no class, no pb style)" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .radius = 5,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    const html = try renderToString(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    // (a) Byte-identical plain filled rrect: no class, no pb style.
    const expected_filled = "<div style=\"position:absolute;left:10px;top:20px;width:100px;height:50px;border-radius:5px;background:rgba(255,0,0,1)\"></div>";
    try std.testing.expect(std.mem.indexOf(u8, html, expected_filled) != null);
    // No class= attribute on this rrect.
    try std.testing.expect(std.mem.indexOf(u8, html, "class=") == null);
    // No pb rules <style> block emitted.
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb") == null);
}

test "renderToString: fillRRectStates emits class and hover/active style rules" {
    var cv = @import("../canvas.zig").Canvas.init(std.testing.allocator);
    defer cv.deinit();
    try cv.fillRRectStates(
        geom.PhysicalRect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        4,
        geom.Color.rgb(0, 0, 1), // base: blue
        geom.Color.rgb(0, 0, 0.9), // hover: slightly darker blue
        geom.Color.rgb(0, 0, 0.8), // active: darker blue
    );
    const html = try renderToString(std.testing.allocator, cv.list, geom.PhysicalSize{ .width = 200, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    // The div must carry class="pb0".
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pb0\"") != null);
    // A <style> block must be present after the wrapper close.
    try std.testing.expect(std.mem.indexOf(u8, html, "<style>") != null);
    // Hover rule uses background.
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb0:hover{background:rgba(") != null);
    // Active rule uses background.
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb0:active{background:rgba(") != null);
    // No border-color in style rules (this is a fill).
    try std.testing.expect(std.mem.indexOf(u8, html, "border-color") == null);
}

test "renderToString: strokeRRectStates emits border-color hover/active style rules" {
    var cv = @import("../canvas.zig").Canvas.init(std.testing.allocator);
    defer cv.deinit();
    try cv.strokeRRectStates(
        geom.PhysicalRect{ .x = 0, .y = 0, .width = 80, .height = 40 },
        4,
        2,
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.3 }, // base
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.5 }, // hover
        geom.Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.7 }, // active
    );
    const html = try renderToString(std.testing.allocator, cv.list, geom.PhysicalSize{ .width = 200, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    // The div must carry class="pb0".
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"pb0\"") != null);
    // Hover rule uses border-color.
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb0:hover{border-color:rgba(") != null);
    // Active rule uses border-color.
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb0:active{border-color:rgba(") != null);
    // No background in style rules (this is a stroke).
    try std.testing.expect(std.mem.indexOf(u8, html, ".pb0:hover{background") == null);
}

test "alpha() formats CSS alpha compactly: opaque 1, transparent 0, fractional trimmed" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("1", alpha(&buf, 1.0));
    try std.testing.expectEqualStrings("0", alpha(&buf, 0.0));
    try std.testing.expectEqualStrings("0.3", alpha(&buf, 0.3));
    try std.testing.expectEqualStrings("0.5", alpha(&buf, 0.5));
    try std.testing.expectEqualStrings("0.7", alpha(&buf, 0.7));
    try std.testing.expectEqualStrings("0.15", alpha(&buf, 0.15));
}

test "renderToString: fractional alpha is compact (no long float representation)" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.3 },
    } });
    const html = try renderToString(std.testing.allocator, list, geom.PhysicalSize{ .width = 50, .height = 50 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, ",0.3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "0.30000") == null);
}

test "renderToString: image with encoded bytes emits <img> tag with data URL" {
    const gpa = std.testing.allocator;
    const png_bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01 };
    var img = image_mod.Image.fromBytes(png_bytes, 20, 10);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 8, .y = 16, .width = 20, .height = 10 },
        .opacity = 1,
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    // Must contain an <img tag.
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") != null);
    // Must contain the data URL prefix for PNG.
    try std.testing.expect(std.mem.indexOf(u8, html, "data:image/png;base64,") != null);
    // Must contain the positioned style values.
    try std.testing.expect(std.mem.indexOf(u8, html, "left:8px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "top:16px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width:20px") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "height:10px") != null);
}

test "renderToString: image fromRgba (no encoded bytes) emits no img tag" {
    const gpa = std.testing.allocator;
    const rgba_pixels = [_]u8{255} ** (4 * 4 * 4);
    var img = image_mod.Image.fromRgba(&rgba_pixels, 4, 4);
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = &img,
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .opacity = 1,
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    // No img element should appear (fromRgba has no encoded bytes).
    try std.testing.expect(std.mem.indexOf(u8, html, "<img") == null);
}

test "renderToString: an icon emits an inline svg whose viewBox is the grid and whose size is the request" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 40, .height = 40 },
        .color = geom.Color.rgb(1, 0, 0),
        .origin = .{ .x = 6, .y = 9 },
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 200, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);

    // The two must differ: an svg sized at its viewBox would pass a test that
    // only looked at one of them, and would draw every icon at 24 pixels.
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 24 24\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width=\"40\" height=\"40\"") != null);
    // Positioned like every other primitive, from the primitive's own origin.
    try std.testing.expect(std.mem.indexOf(u8, html, "position:absolute;left:6px;top:9px") != null);
}

test "renderToString: an icon is a stroked centreline, not a filled shape" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(0, 0.502, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);

    // fill="none" is the whole difference between a torii and a blue blob.
    try std.testing.expect(std.mem.indexOf(u8, html, "fill=\"none\"") != null);
    // The grammar's width, in grid units. The viewBox already scales it, so a
    // backend that multiplied by size/grid would print 1.7 here only by chance.
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-width=\"1.7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-linecap=\"round\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke-linejoin=\"round\"") != null);
    // Tinted through the same channel conversion as every other primitive.
    try std.testing.expect(std.mem.indexOf(u8, html, "stroke=\"rgba(0,128,255,1)\"") != null);
    // The kasagi opens the mark, so the d attribute starts with the curve.
    try std.testing.expect(std.mem.indexOf(u8, html, "d=\"M3.84 3.218Q12 4.887 20.16 3.218") != null);
}

test "renderToString: an icon at twice the size reuses one path at a larger width" {
    // The point of handing the centreline to the browser: the geometry does not
    // change with size, only the box it is scaled into. A backend that baked the
    // size into the coordinates gives two different d strings here.
    const gpa = std.testing.allocator;
    var small = dl.DisplayList{};
    defer small.deinit(gpa);
    try small.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 16, .height = 16 }, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });
    var large = dl.DisplayList{};
    defer large.deinit(gpa);
    try large.append(gpa, .{ .icon = .{ .id = .torii, .size = .{ .width = 32, .height = 32 }, .color = geom.Color.rgb(1, 1, 1), .origin = .{ .x = 0, .y = 0 } } });

    const a = try renderToString(gpa, small, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(a);
    const b = try renderToString(gpa, large, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(b);

    const d_start = std.mem.indexOf(u8, a, "d=\"").? + 3;
    const d_end = std.mem.indexOfScalarPos(u8, a, d_start, '"').?;
    try std.testing.expect(std.mem.indexOf(u8, b, a[d_start..d_end]) != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "width=\"16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "width=\"32\"") != null);
}

test "renderToString: a labelled icon carries an svg title, so it has an accessible name" {
    // A mark holds no text, so without a title a screen reader reads nothing
    // where an icon replaced a word. The title is the accessible name of inline
    // SVG, and it must come first, before the path.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "Genesis",
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>Genesis</title>") != null);
    const title_at = std.mem.indexOf(u8, html, "<title>").?;
    const path_at = std.mem.indexOf(u8, html, "<path ").?;
    try std.testing.expect(title_at < path_at);
}

test "renderToString: a label with markup in it is escaped, not written through" {
    // The label comes from the app, so it is arbitrary text. Written raw, a
    // name holding a bracket closes the title early and injects an element.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
        .label = "<b>&</b>",
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<title>&lt;b&gt;&amp;&lt;/b&gt;</title>") != null);
}

test "renderToString: an icon with no label emits no title element at all" {
    // An always-present title claims the accessible name and then announces an
    // empty string, which is worse than no title: with none, a reader falls back
    // on the surrounding text.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<title") == null);
    // The mark itself is still drawn: a backend that dropped the whole svg with
    // the title would also pass the line above.
    try std.testing.expect(std.mem.indexOf(u8, html, "<path ") != null);
}

test "renderToString: an icon inside a scroll region is placed relative to the region" {
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geom.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geom.PhysicalSize{ .width = 100, .height = 300 },
    } });
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 24, .height = 24 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 30, .y = 60 },
    } });
    try list.append(gpa, .{ .pop_scroll = {} });
    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 300, .height = 200 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    // 30-10 and 60-20, the same subtraction every other primitive makes.
    try std.testing.expect(std.mem.indexOf(u8, html, "left:20px;top:40px") != null);
}

test "renderToString: push_scroll emits overflow:scroll containers and adjusts child coords" {
    var list = dl.DisplayList{};
    defer list.deinit(std.testing.allocator);

    // push_scroll: viewport x=10,y=20,w=100,h=50; content w=100,h=300
    try list.append(std.testing.allocator, .{ .push_scroll = .{
        .viewport = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 },
        .offset = geom.PhysicalOffset{ .x = 0, .y = 0 },
        .content = geom.PhysicalSize{ .width = 100, .height = 300 },
    } });
    // fillRRect at absolute coords x=10,y=120,w=80,h=20
    // after coord adjustment: left = 10-10 = 0, top = 120-20 = 100
    try list.append(std.testing.allocator, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 10, .y = 120, .width = 80, .height = 20 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(std.testing.allocator, .{ .pop_scroll = {} });

    const html = try renderToString(std.testing.allocator, list, geom.PhysicalSize{ .width = 300, .height = 200 }, geom.Color.rgb(0, 0, 0));
    defer std.testing.allocator.free(html);

    // Outer scroll container at viewport position
    try std.testing.expect(std.mem.indexOf(u8, html, "overflow:scroll") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "left:10px;top:20px;width:100px;height:50px;overflow:scroll") != null);
    // Inner content div with content size
    try std.testing.expect(std.mem.indexOf(u8, html, "position:relative;width:100px;height:300px") != null);
    // Child rrect with adjusted coords: left=0 (10-10), top=100 (120-20)
    try std.testing.expect(std.mem.indexOf(u8, html, "left:0px;top:100px") != null);
    // Closing tags for both divs
    try std.testing.expect(std.mem.indexOf(u8, html, "</div></div>") != null);
}

test "renderToString: a mark in a box that is not square stretches instead of letterboxing" {
    // An svg keeps its viewBox aspect by default and centres it in the box,
    // which for a rule in a tall box redraws the short, gapped mark the box was
    // made tall to avoid. Only preserveAspectRatio="none" lets the two axes
    // scale apart.
    const gpa = std.testing.allocator;
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .rule_vertical,
        .size = .{ .width = 16, .height = 48 },
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });

    const html = try renderToString(gpa, list, geom.PhysicalSize{ .width = 100, .height = 100 }, geom.Color.rgb(0, 0, 0));
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "preserveAspectRatio=\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width=\"16\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "height=\"48\"") != null);
    // The viewBox stays the authoring grid, so one centreline still serves
    // every size and the stroke width keeps its grid units.
    try std.testing.expect(std.mem.indexOf(u8, html, "viewBox=\"0 0 24 24\"") != null);
}
