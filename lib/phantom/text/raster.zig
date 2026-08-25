//! Coverage rasterizer: turns a glyph Outline (contours of line/quad/cubic
//! segments in font units) into an 8-bit alpha coverage bitmap with placement
//! metadata. Curves are flattened to line segments at the target pixel size and
//! filled with anti-aliased, nonzero-winding coverage via signed-area
//! accumulation (the stb_truetype v2 / font-rs approach).
const std = @import("std");
const outline_mod = @import("outline.zig");
const Outline = outline_mod.Outline;
const Point = outline_mod.Point;
const Segment = outline_mod.Segment;

/// An anti-aliased alpha coverage bitmap plus the placement metadata needed to
/// blit the glyph into a target surface. `pixels` is `w * h` bytes, row-major,
/// top-down; `left`/`top` are the integer device-space bitmap origin; `advance`
/// is the horizontal advance in pixels.
pub const Coverage = struct {
    pixels: []u8,
    w: u32,
    h: u32,
    left: i32,
    top: i32,
    advance: f32,

    pub fn deinit(self: *Coverage, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// Flatness tolerance for curve subdivision, in device pixels. A curve is
/// considered flat once the maximum deviation of its control point(s) from the
/// chord is below this value.
const flatten_tolerance: f32 = 0.25;

/// A single flattened line edge in device space, origin already at (0,0).
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

/// Rasterize `outline` (contours in font units) to an anti-aliased alpha
/// coverage bitmap at `px_size` pixels. `units_per_em` sets the font scale;
/// `advance_units` is the glyph's horizontal advance in font units.
pub fn rasterize(
    gpa: std.mem.Allocator,
    outline: Outline,
    units_per_em: u16,
    px_size: f32,
    advance_units: u16,
) !Coverage {
    return rasterizeScaled(gpa, outline, units_per_em, px_size, px_size, advance_units);
}

/// Rasterize `outline` into a box `px_w` by `px_h` pixels, which need not be
/// square.
///
/// A glyph never wants this: a face draws its two axes at one scale, and text
/// stretched in one axis is a different typeface. An icon does, because a rule
/// is a straight line and a straight line stretched along itself is the same
/// line. `rasterize` is this function with the two equal.
pub fn rasterizeScaled(
    gpa: std.mem.Allocator,
    outline: Outline,
    units_per_em: u16,
    px_w: f32,
    px_h: f32,
    advance_units: u16,
) !Coverage {
    const scale: f32 = px_w / @as(f32, @floatFromInt(units_per_em));
    const scale_y: f32 = px_h / @as(f32, @floatFromInt(units_per_em));
    // The advance is a horizontal measure, so it follows the horizontal scale.
    const advance: f32 = @as(f32, @floatFromInt(advance_units)) * scale;

    // 1. Flatten every segment into device-space line edges. Device space
    //    applies `scale` and flips Y (font +y is up, bitmap is top-down).
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(gpa);

    var min_x: f32 = std.math.floatMax(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_x: f32 = -std.math.floatMax(f32);
    var max_y: f32 = -std.math.floatMax(f32);
    var any_point = false;

    for (outline.contours.items) |contour| {
        var cur = devPoint(contour.start, scale, scale_y);
        const first = cur;
        trackBounds(cur, &min_x, &min_y, &max_x, &max_y, &any_point);
        for (contour.segs.items) |seg| {
            switch (seg) {
                .line => |p| {
                    const to = devPoint(p, scale, scale_y);
                    try edges.append(gpa, .{ .x0 = cur.x, .y0 = cur.y, .x1 = to.x, .y1 = to.y });
                    trackBounds(to, &min_x, &min_y, &max_x, &max_y, &any_point);
                    cur = to;
                },
                .quad => |q| {
                    const ctrl = devPoint(q.ctrl, scale, scale_y);
                    const end = devPoint(q.end, scale, scale_y);
                    try flattenQuad(gpa, &edges, cur, ctrl, end, &min_x, &min_y, &max_x, &max_y, &any_point, 0);
                    cur = end;
                },
                .cubic => |c| {
                    const c1 = devPoint(c.c1, scale, scale_y);
                    const c2 = devPoint(c.c2, scale, scale_y);
                    const end = devPoint(c.end, scale, scale_y);
                    try flattenCubic(gpa, &edges, cur, c1, c2, end, &min_x, &min_y, &max_x, &max_y, &any_point, 0);
                    cur = end;
                },
            }
        }
        // Close the contour implicitly so the fill winds correctly.
        if (cur.x != first.x or cur.y != first.y) {
            try edges.append(gpa, .{ .x0 = cur.x, .y0 = cur.y, .x1 = first.x, .y1 = first.y });
        }
    }

    if (!any_point) {
        return zeroCoverage(advance);
    }

    // 2. Integer pixel bounds.
    const left: i32 = @intFromFloat(@floor(min_x));
    const top: i32 = @intFromFloat(@floor(min_y));
    const right: i32 = @intFromFloat(@ceil(max_x));
    const bottom: i32 = @intFromFloat(@ceil(max_y));
    const wi = right - left;
    const hi = bottom - top;
    if (wi <= 0 or hi <= 0) {
        return zeroCoverage(advance);
    }
    const w: u32 = @intCast(wi);
    const h: u32 = @intCast(hi);

    // Translate every edge so the bitmap origin is (0,0).
    const off_x: f32 = @floatFromInt(left);
    const off_y: f32 = @floatFromInt(top);

    // 3. Signed-area accumulation. `acc` has an extra column so the final column
    //    of cover carries off the edge without a bounds check.
    const acc = try gpa.alloc(f32, (@as(usize, w) + 1) * @as(usize, h));
    defer gpa.free(acc);
    @memset(acc, 0);

    for (edges.items) |e| {
        addEdge(acc, w, h, e.x0 - off_x, e.y0 - off_y, e.x1 - off_x, e.y1 - off_y);
    }

    // 4. Integrate each row and clamp to 0..255.
    const pixels = try gpa.alloc(u8, @as(usize, w) * @as(usize, h));
    errdefer gpa.free(pixels);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var running: f32 = 0;
        const row_base = @as(usize, y) * (@as(usize, w) + 1);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            running += acc[row_base + x];
            var cov = @abs(running);
            if (cov > 1.0) cov = 1.0;
            pixels[@as(usize, y) * @as(usize, w) + x] = @intFromFloat(cov * 255.0 + 0.5);
        }
    }

    return .{
        .pixels = pixels,
        .w = w,
        .h = h,
        .left = left,
        .top = top,
        .advance = advance,
    };
}

fn zeroCoverage(advance: f32) Coverage {
    return .{
        .pixels = &.{},
        .w = 0,
        .h = 0,
        .left = 0,
        .top = 0,
        .advance = advance,
    };
}

/// Convert a font-unit point to device space: scale each axis, then flip Y.
fn devPoint(p: Point, scale: f32, scale_y: f32) Point {
    return .{ .x = p.x * scale, .y = -(p.y * scale_y) };
}

fn trackBounds(p: Point, min_x: *f32, min_y: *f32, max_x: *f32, max_y: *f32, any: *bool) void {
    if (p.x < min_x.*) min_x.* = p.x;
    if (p.y < min_y.*) min_y.* = p.y;
    if (p.x > max_x.*) max_x.* = p.x;
    if (p.y > max_y.*) max_y.* = p.y;
    any.* = true;
}

/// Recursively subdivide a quadratic Bezier until each piece is flat within the
/// tolerance, emitting line edges. Points are already in device space.
fn flattenQuad(
    gpa: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    p0: Point,
    p1: Point,
    p2: Point,
    min_x: *f32,
    min_y: *f32,
    max_x: *f32,
    max_y: *f32,
    any: *bool,
    depth: u8,
) !void {
    // Deviation of the control point from the chord p0->p2.
    const dev = pointLineDist(p1, p0, p2);
    if (depth >= 16 or dev <= flatten_tolerance) {
        try edges.append(gpa, .{ .x0 = p0.x, .y0 = p0.y, .x1 = p2.x, .y1 = p2.y });
        trackBounds(p2, min_x, min_y, max_x, max_y, any);
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p012 = mid(p01, p12);
    try flattenQuad(gpa, edges, p0, p01, p012, min_x, min_y, max_x, max_y, any, depth + 1);
    try flattenQuad(gpa, edges, p012, p12, p2, min_x, min_y, max_x, max_y, any, depth + 1);
}

/// Recursively subdivide a cubic Bezier until flat within the tolerance.
fn flattenCubic(
    gpa: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    min_x: *f32,
    min_y: *f32,
    max_x: *f32,
    max_y: *f32,
    any: *bool,
    depth: u8,
) !void {
    const d1 = pointLineDist(p1, p0, p3);
    const d2 = pointLineDist(p2, p0, p3);
    const dev = @max(d1, d2);
    if (depth >= 18 or dev <= flatten_tolerance) {
        try edges.append(gpa, .{ .x0 = p0.x, .y0 = p0.y, .x1 = p3.x, .y1 = p3.y });
        trackBounds(p3, min_x, min_y, max_x, max_y, any);
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p23 = mid(p2, p3);
    const p012 = mid(p01, p12);
    const p123 = mid(p12, p23);
    const p0123 = mid(p012, p123);
    try flattenCubic(gpa, edges, p0, p01, p012, p0123, min_x, min_y, max_x, max_y, any, depth + 1);
    try flattenCubic(gpa, edges, p0123, p123, p23, p3, min_x, min_y, max_x, max_y, any, depth + 1);
}

fn mid(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

/// Perpendicular distance from point `p` to the line through `a` and `b`.
fn pointLineDist(p: Point, a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) {
        const ex = p.x - a.x;
        const ey = p.y - a.y;
        return @sqrt(ex * ex + ey * ey);
    }
    const cross = (p.x - a.x) * dy - (p.y - a.y) * dx;
    return @abs(cross) / @sqrt(len2);
}

/// Add one line edge to the signed-area / cover accumulator. This is the core
/// of the stb_truetype v2 style rasterizer: for each scanline the edge crosses,
/// deposit the trapezoid area into the partially-covered cell and carry the full
/// coverage to the cells to its right. Winding sign comes from the edge's y
/// direction.
fn addEdge(acc: []f32, w: u32, h: u32, ex0: f32, ey0: f32, ex1: f32, ey1: f32) void {
    if (ey0 == ey1) return;

    const stride = @as(usize, w) + 1;
    const height: f32 = @floatFromInt(h);

    // Orient the edge so it goes top-to-bottom (increasing y); track winding.
    var x0 = ex0;
    var y0 = ey0;
    var x1 = ex1;
    var y1 = ey1;
    var dir: f32 = 1.0;
    if (y0 > y1) {
        std.mem.swap(f32, &x0, &x1);
        std.mem.swap(f32, &y0, &y1);
        dir = -1.0;
    }

    const dxdy = (x1 - x0) / (y1 - y0);

    // Clip to the vertical extent of the bitmap.
    if (y0 < 0) {
        x0 += dxdy * (0 - y0);
        y0 = 0;
    }
    if (y1 > height) {
        x1 += dxdy * (height - y1);
        y1 = height;
    }
    if (y0 >= y1) return;

    // Walk the edge one scanline row at a time. Within each row we cover a
    // vertical extent `dy` (in [0,1]) and a horizontal run from `x` to `x_next`.
    var y = y0;
    var x = x0;
    while (y < y1) {
        const row: u32 = @intFromFloat(@floor(y));
        if (row >= h) break;
        const row_bottom: f32 = @as(f32, @floatFromInt(row)) + 1.0;
        const seg_bottom = @min(row_bottom, y1);
        const dy = (seg_bottom - y) * dir; // signed vertical coverage for this row
        const x_next = x + dxdy * (seg_bottom - y);

        addSpan(acc[@as(usize, row) * stride ..][0..stride], w, x, x_next, dy);

        // Advance; nudge off the exact boundary so the next floor lands in the
        // following row and the loop terminates.
        y = if (seg_bottom == y) y + 1.0 else seg_bottom;
        x = x_next;
    }
}

/// Deposit one sub-scanline span into a single row of the accumulator using the
/// font-rs / stb_truetype signed-area scheme. `dy` is the signed vertical
/// coverage of this span (in [-1, 1]); the row is later prefix-summed so the
/// cover carries to every cell right of the edge, which is what fills interiors.
/// `row` is the (w+1)-wide accumulator slice for this scanline.
fn addSpan(row: []f32, w: u32, xa: f32, xb: f32, dy: f32) void {
    if (dy == 0) return;
    const wf: f32 = @floatFromInt(w);

    // Clamp endpoints to [0, w]. A point left of 0 contributes full cover from
    // column 0; a point right of w contributes nothing more than the carry.
    var xl = @max(0.0, @min(xa, xb));
    var xr = @min(wf, @max(xa, xb));
    if (xr <= 0) {
        // Whole span left of the bitmap: full cover across the entire row.
        row[0] += dy;
        return;
    }
    if (xl >= wf) return; // whole span right of the bitmap: nothing visible
    if (xl < 0) xl = 0;
    if (xr > wf) xr = wf;
    if (xr >= wf) xr = wf - 1e-4; // keep ir <= w-1 so row[ir+1] stays within the w+1 stride

    const il: u32 = @intFromFloat(@floor(xl));
    const ir: u32 = @intFromFloat(@floor(xr));

    if (il == ir) {
        // Span sits inside one cell. Area in the cell is dy * (1 - avg frac);
        // the remaining dy carries to the next cell (prefix sum handles right).
        const cover_x = (xl + xr) * 0.5 - @as(f32, @floatFromInt(il));
        row[il] += dy * (1.0 - cover_x);
        row[il + 1] += dy * cover_x;
        return;
    }

    // Span spans multiple cells. Slope of x with respect to covered-height.
    const inv_dx = 1.0 / (xr - xl);
    // First partial cell (from xl to its right boundary).
    const first_right: f32 = @floatFromInt(il + 1);
    const d_first = (first_right - xl) * inv_dx; // fraction of dy in first cell
    const first_cover_x = (xl + first_right) * 0.5 - @as(f32, @floatFromInt(il));
    row[il] += dy * d_first * (1.0 - first_cover_x);
    var carry = dy * d_first * first_cover_x;

    // Full middle cells: the edge crosses the whole cell, so all of that cell's
    // dy carries fully to the right (cover_x == 1 at the cell's right edge).
    var xi: u32 = il + 1;
    while (xi < ir) : (xi += 1) {
        const d_mid = inv_dx; // one cell of width contributes inv_dx of dy
        row[xi] += carry + dy * d_mid * 0.5;
        carry = dy * d_mid * 0.5;
    }

    // Last partial cell (from its left boundary to xr).
    const last_left: f32 = @floatFromInt(ir);
    const d_last = (xr - last_left) * inv_dx;
    const last_cover_x = (last_left + xr) * 0.5 - last_left;
    row[ir] += carry + dy * d_last * (1.0 - last_cover_x);
    row[ir + 1] += dy * d_last * last_cover_x;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const builtin = @import("builtin.zig");
const Sfnt = @import("sfnt.zig");
const Metrics = @import("metrics.zig");
const Cff = @import("cff.zig");
const Builder = outline_mod.Builder;

fn px(cov: Coverage, x: u32, y: u32) u8 {
    return cov.pixels[@as(usize, y) * cov.w + x];
}

test "rasterize crafted 500x500 square: interior full, exterior empty, AA edges" {
    const gpa = std.testing.allocator;

    // One contour, 4 line segments, a 500x500 box in a 1000 em. Box spans font
    // units x:[100,600], y:[100,600]. At 32px the scale is 0.032, so the box is
    // 16x16 device pixels.
    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);
    try b.moveTo(gpa, 100, 100);
    try b.lineTo(gpa, 600, 100);
    try b.lineTo(gpa, 600, 600);
    try b.lineTo(gpa, 100, 600);
    try b.lineTo(gpa, 100, 100);
    b.finish();

    var cov = try rasterize(gpa, out, 1000, 32, 700);
    defer cov.deinit(gpa);

    try std.testing.expect(cov.w > 0 and cov.h > 0);

    // Center pixel should be essentially fully covered.
    const cx = cov.w / 2;
    const cy = cov.h / 2;
    try std.testing.expect(px(cov, cx, cy) >= 250);

    // The bitmap is tight to the box, so scan for an interior-vs-edge contrast:
    // at least one edge pixel strictly between 0 and 255 (anti-aliasing). The
    // box edges at 100/600 font units land on 3.2 / 19.2 device px, i.e. not on
    // integer pixel boundaries, so the border row/column is partially covered.
    var found_aa = false;
    var x: u32 = 0;
    while (x < cov.w) : (x += 1) {
        const top_a = px(cov, x, 0);
        if (top_a > 0 and top_a < 255) found_aa = true;
    }
    try std.testing.expect(found_aa);

    // advance = 700 * 0.032 = 22.4
    try std.testing.expect(@abs(cov.advance - 22.4) < 0.01);
}

test "rasterize crafted triangle has partial coverage" {
    const gpa = std.testing.allocator;

    // A triangle: (100,100) -> (900,100) -> (500,700) -> back.
    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);
    try b.moveTo(gpa, 100, 100);
    try b.lineTo(gpa, 900, 100);
    try b.lineTo(gpa, 500, 700);
    try b.lineTo(gpa, 100, 100);
    b.finish();

    var cov = try rasterize(gpa, out, 1000, 48, 1000);
    defer cov.deinit(gpa);

    try std.testing.expect(cov.w > 0 and cov.h > 0);

    var has_full = false;
    var has_empty = false;
    var has_partial = false;
    for (cov.pixels) |a| {
        if (a >= 250) has_full = true;
        if (a == 0) has_empty = true;
        if (a > 0 and a < 255) has_partial = true;
    }
    // The slanted hypotenuse guarantees partially-covered pixels; the corners
    // outside the triangle guarantee empty pixels; the body guarantees full.
    try std.testing.expect(has_full);
    try std.testing.expect(has_empty);
    try std.testing.expect(has_partial);
}

test "rasterize right-edge exact integer device x does not panic (boundary OOB regression)" {
    // Regression: when a glyph's right edge translates to an exact integer
    // device x, xr == wf causes ir == w and row[ir+1] == row[w+1] which is
    // one past the end of the (w+1)-wide accumulator row.
    //
    // Geometry: a triangle whose rightmost vertex is at font x = 625 in a
    // 1000 unitsPerEm font rasterized at 32 px.
    //   scale = 32 / 1000 = 0.032
    //   device x = 625 * 0.032 = 20.0  (exactly integer)
    //
    // Before the fix this panics with index-out-of-bounds in ReleaseSafe/test
    // builds. After the fix it must complete and produce sane coverage.
    const gpa = std.testing.allocator;

    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);
    // Triangle: left base at (5,100), right base at (625,100), apex at (300,700)
    // The right base x = 625 maps to device x = 20.0 exactly at 32 px / 1000 em.
    try b.moveTo(gpa, 5, 100);
    try b.lineTo(gpa, 625, 100);
    try b.lineTo(gpa, 300, 700);
    try b.lineTo(gpa, 5, 100);
    b.finish();

    var cov = try rasterize(gpa, out, 1000, 32, 700);
    defer cov.deinit(gpa);

    try std.testing.expect(cov.w > 0 and cov.h > 0);

    var has_interior: bool = false;
    for (cov.pixels) |a| {
        if (a > 0) has_interior = true;
    }
    try std.testing.expect(has_interior);
}

test "rasterize Neuropol 'A' end-to-end: non-empty, interior near full, AA edges" {
    const gpa = std.testing.allocator;

    const s = try Sfnt.parse(builtin.neuropol_bytes);
    const m = try Metrics.parse(s);
    var cff = try Cff.parse(gpa, s.table("CFF ").?);
    defer cff.deinit(gpa);

    const gid = m.glyphIndex('A');
    try std.testing.expect(gid != 0);

    var o = Outline{};
    defer o.deinit(gpa);
    try cff.outline(gpa, gid, &o);

    var cov = try rasterize(gpa, o, m.units_per_em, 48, m.advanceWidth(gid));
    defer cov.deinit(gpa);

    // Non-empty coverage.
    try std.testing.expect(cov.w > 0 and cov.h > 0);
    try std.testing.expect(cov.pixels.len == @as(usize, cov.w) * @as(usize, cov.h));

    var max_a: u8 = 0;
    var has_partial = false;
    for (cov.pixels) |a| {
        if (a > max_a) max_a = a;
        if (a > 0 and a < 255) has_partial = true;
    }
    // Some interior pixel near full coverage (a solid stroke of the 'A').
    try std.testing.expect(max_a >= 240);
    // Anti-aliased edges present.
    try std.testing.expect(has_partial);
}

test "a non-square box stretches one axis and leaves the other alone" {
    // A vertical rule: the centreline of `icon/builtin.zig`'s rule_vertical, on
    // the same 24 unit grid. Stretching it down must make it longer and must
    // NOT make it wider, because its width comes from the axis the box does
    // not stretch.
    const gpa = std.testing.allocator;
    var square = Outline{};
    defer square.deinit(gpa);
    var sb = outline_mod.Builder.init(&square);
    try sb.moveTo(gpa, 11.15, 0);
    try sb.lineTo(gpa, 12.85, 0);
    try sb.lineTo(gpa, 12.85, 24);
    try sb.lineTo(gpa, 11.15, 24);
    sb.finish();

    var flat = try rasterizeScaled(gpa, square, 24, 24, 24, 24);
    defer flat.deinit(gpa);
    var tall = try rasterizeScaled(gpa, square, 24, 24, 72, 24);
    defer tall.deinit(gpa);

    try std.testing.expectEqual(flat.w, tall.w);
    try std.testing.expectEqual(flat.h * 3, tall.h);
}

test "rasterize is the square case of rasterizeScaled" {
    // The wrapper must not drift from what it wraps: text goes through it and
    // a face draws its two axes at one scale.
    const gpa = std.testing.allocator;
    var tri = Outline{};
    defer tri.deinit(gpa);
    var tb = outline_mod.Builder.init(&tri);
    try tb.moveTo(gpa, 2, 2);
    try tb.lineTo(gpa, 20, 4);
    try tb.lineTo(gpa, 8, 22);
    tb.finish();

    var a = try rasterize(gpa, tri, 24, 32, 24);
    defer a.deinit(gpa);
    var b = try rasterizeScaled(gpa, tri, 24, 32, 32, 24);
    defer b.deinit(gpa);

    try std.testing.expectEqual(a.w, b.w);
    try std.testing.expectEqual(a.h, b.h);
    try std.testing.expectEqual(a.left, b.left);
    try std.testing.expectEqual(a.top, b.top);
    try std.testing.expectEqual(a.advance, b.advance);
    try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
}
