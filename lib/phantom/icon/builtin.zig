//! Built-in icons: the Midstall set, each a comptime `Path` on the 24 unit grid.
//!
//! A built-in icon is a centreline, not a filled shape. `icon/stroke.zig`
//! expands it at draw time with the grammar's stroke width, so one path serves
//! every size and the geometry cannot drift between two of them.
const path = @import("path.zig");

/// Side of the square every built-in path is authored on. `path.Stroke`'s
/// default width of 1.7 was chosen for this grid.
pub const grid: f32 = 24;

/// The same number as an integer count of units, which is the form
/// `text/raster.zig` takes for the denominator of its scale.
pub const grid_units: u16 = 24;

/// Identifies a built-in icon. The value doubles as the atlas cache id, so a
/// member keeps its number once shipped: renumbering makes a warm atlas draw
/// one mark under another one's name.
pub const Id = enum(u32) {
    torii = 0,

    // The interface set. Each is a centreline on the same 24 grid the torii
    // uses, drawn inside a 2 unit margin so a mark never touches its own box,
    // except the two rules, which are deliberately full bleed (see below).
    //
    // These exist because the bundled fonts do not have them. Mesmerize and
    // Neuropol are display faces: every non-ASCII codepoint probed, U+2713 and
    // U+2502 among them, resolves to glyph 0. In cell mode that costs nothing,
    // since the terminal draws text with its own font, but pixel mode
    // rasterises with the bundled faces and a tick came out as a replacement
    // box. A mark phantom draws itself works in both.
    check = 1,
    cross = 2,
    chevron_left = 3,
    chevron_right = 4,
    chevron_up = 5,
    chevron_down = 6,
    arrow_right = 7,
    plus = 8,
    minus = 9,
    rule_vertical = 10,
    rule_horizontal = 11,
};

/// The centreline of `id`.
pub fn pathFor(id: Id) path.Path {
    return switch (id) {
        .torii => torii,
        .check => check,
        .cross => cross,
        .chevron_left => chevron_left,
        .chevron_right => chevron_right,
        .chevron_up => chevron_up,
        .chevron_down => chevron_down,
        .arrow_right => arrow_right,
        .plus => plus,
        .minus => minus,
        .rule_vertical => rule_vertical,
        .rule_horizontal => rule_horizontal,
    };
}

// ---------------------------------------------------------------------------
// The Midstall logomark
//
// Transcribed from branding/pkgs/midstall-logo/midstall_logo/logomark.py, which
// builds a torii gate with an integrated letter M out of six stroked elements:
// the kasagi (top rail), the two M diagonals, the two pillars, and the nuki
// (crossbar).
//
// The generator works on a 220 by 170 canvas. Fitting that across the 24 grid
// is a uniform scale of 24/220 = 0.109091, under which the 170 tall canvas
// becomes 18.545 units, so centring it leaves 2.7273 clear above and below.
// Source y grows downwards, grid y grows upwards, hence
//
//     grid_x = 24 * src_x / 220
//     grid_y = 24 - 2.7273 - 24 * src_y / 220
//
// Working the named ratios through gives, in source units then grid units:
//
//   padding_top    = 4.5 + 170*0.09          = 19.8
//   padding_bottom = 4.5
//   usable_height  = 170 - 19.8 - 4.5        = 145.7
//
//   beam_left_x    = 220*(0.28-0.12)  =  35.2  ->  3.840
//   pillar_left_x  = 220*0.28         =  61.6  ->  6.720
//   centre_x       = 220/2            = 110.0  -> 12.000
//   pillar_right_x = 220*0.72         = 158.4  -> 17.280
//   beam_right_x   = 220*(0.72+0.12)  = 184.8  -> 20.160
//
//   kasagi_end_y   = 19.8 - 170*0.09  =   4.5  -> 20.782
//   beam_y         = padding_top      =  19.8  -> 19.113
//   crossbar_y     = 19.8 + 145.7*0.33 = 67.881 -> 13.868
//   diagonal_y     = 19.8 + 145.7*0.33 = 67.881 -> 13.868
//   pillar_bottom_y= 170 - 4.5        = 165.5  ->  3.218
//
// The kasagi's ends (20.782) sit ABOVE its centre control point (19.113), which
// is the upward sweep that makes the shape read as a torii. Each pillar starts
// where that curve passes over it, at t = (6.72-3.84)/(20.16-3.84) = 3/17,
// giving 20.297.
//
// The stroke is NOT scaled with the geometry. See src_stroke below.
// ---------------------------------------------------------------------------

const src_w: f32 = 220;
const src_h: f32 = 170;
const pillar_inset: f32 = 0.28;
const beam_overhang: f32 = 0.12;
const diagonal_depth: f32 = 0.33;
const crossbar_position: f32 = 0.33;
const kasagi_curve: f32 = 0.09;

/// The generator's own stroke width, used here ONLY for the padding it reserves
/// at the top and bottom of the canvas. It is deliberately not carried onto the
/// icon grid: 4.5 * 24/220 is 0.49 units, a hairline that disappears at icon
/// size. The 220 wide mark is for display use, where a fine stroke reads; an
/// icon takes the grammar's 1.7, which is `path.Stroke`'s default.
const src_stroke: f32 = 4.5;

const padding_top = src_stroke + src_h * kasagi_curve;
const padding_bottom = src_stroke;
const usable_height = src_h - padding_top - padding_bottom;

/// Width is the binding axis: fitting 220 across 24 leaves the 170 tall canvas
/// short of the grid, which is what `pad_y` then takes up.
const scale = grid / src_w;

/// Half the height the mark leaves over, which centres it vertically.
const pad_y = (grid - src_h * scale) / 2;

fn gx(x_src: f32) f32 {
    return x_src * scale;
}

/// The generator draws with y growing downwards, as SVG does. `text/raster.zig`
/// flips y on its way to a top-down bitmap, so a path handed to it has to grow
/// upwards or the mark rasterises upside down.
fn gy(y_src: f32) f32 {
    return grid - (pad_y + y_src * scale);
}

const beam_left_x = gx(src_w * (pillar_inset - beam_overhang));
const pillar_left_x = gx(src_w * pillar_inset);
const centre_x = gx(src_w / 2);
const pillar_right_x = gx(src_w * (1 - pillar_inset));
const beam_right_x = gx(src_w * (1 - pillar_inset + beam_overhang));

const beam_y = gy(padding_top);
const kasagi_end_y = gy(padding_top - src_h * kasagi_curve);
const pillar_bottom_y = gy(src_h - padding_bottom);
const diagonal_y = gy(padding_top + usable_height * diagonal_depth);
const crossbar_y = gy(padding_top + usable_height * crossbar_position);

/// The kasagi's y at Bezier parameter `t`. The two ends share a y and the
/// control point at the centre is the low one, so the rail sweeps upwards.
fn kasagiY(t: f32) f32 {
    const u = 1 - t;
    return u * u * kasagi_end_y + 2 * u * t * beam_y + t * t * kasagi_end_y;
}

/// Where the kasagi passes over a pillar. The curve is symmetric about
/// `centre_x`, so both pillars start at the same height and one value serves.
const pillar_top_y = kasagiY((pillar_left_x - beam_left_x) / (beam_right_x - beam_left_x));

/// The Midstall logomark. Six separate subpaths, one per element, matching the
/// generator: it strokes six shapes with round caps rather than one connected
/// outline, and joining them here would change where the round ends fall.
pub const torii = path.Path{ .verbs = &.{
    .{ .move = .{ .x = beam_left_x, .y = kasagi_end_y } },
    .{ .quad = .{
        .ctrl = .{ .x = centre_x, .y = beam_y },
        .end = .{ .x = beam_right_x, .y = kasagi_end_y },
    } },

    .{ .move = .{ .x = pillar_left_x, .y = pillar_top_y } },
    .{ .line = .{ .x = pillar_left_x, .y = pillar_bottom_y } },

    .{ .move = .{ .x = pillar_right_x, .y = pillar_top_y } },
    .{ .line = .{ .x = pillar_right_x, .y = pillar_bottom_y } },

    .{ .move = .{ .x = pillar_left_x, .y = pillar_top_y } },
    .{ .line = .{ .x = centre_x, .y = diagonal_y } },

    .{ .move = .{ .x = pillar_right_x, .y = pillar_top_y } },
    .{ .line = .{ .x = centre_x, .y = diagonal_y } },

    .{ .move = .{ .x = pillar_left_x, .y = crossbar_y } },
    .{ .line = .{ .x = pillar_right_x, .y = crossbar_y } },
} };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const stroke = @import("stroke.zig");
const raster = @import("../text/raster.zig");

/// Coverage of the bitmap cell holding the grid point (x, y), or 0 when that
/// cell lies outside the bitmap, which is the same thing as no coverage.
/// raster.zig flips y on its way to a top-down bitmap, so a path-space y lands
/// in the row holding device y = -y.
fn coverageAt(cov: raster.Coverage, x: f32, y: f32) u8 {
    const col = @as(i64, @intFromFloat(@floor(x))) - cov.left;
    const row = @as(i64, @intFromFloat(@floor(-y))) - cov.top;
    if (col < 0 or row < 0) return 0;
    if (col >= cov.w or row >= cov.h) return 0;
    return cov.pixels[@as(usize, @intCast(row)) * cov.w + @as(usize, @intCast(col))];
}

test "the torii rasterises with solid pillars and a clear gap between them" {
    // One pixel per grid unit, so a bitmap cell is the unit square of the same
    // name and every coordinate below is read straight off the derivation in
    // this file. A golden that only counted lit pixels would pass for a blob.
    const gpa = std.testing.allocator;
    var out = try stroke.expand(gpa, torii);
    defer out.deinit(gpa);
    var cov = try raster.rasterize(gpa, out, grid_units, grid, grid_units);
    defer cov.deinit(gpa);

    // Inside the left pillar, below the nuki. The centreline is at x = 6.72 and
    // the stroke is 1.7 wide, so the band covers 5.87 to 7.57 and the cell
    // x in [6,7] sits wholly inside it.
    try std.testing.expectEqual(@as(u8, 255), coverageAt(cov, 6.72, 8.5));

    // The gap between the two pillars at the same height. The left pillar ends
    // at 7.57, the right starts at 16.43, the nuki's lower edge is at 13.02 and
    // every diagonal is above that, so nothing may reach here. A stroker that
    // filled its subpaths rather than stroking them lights this cell up.
    try std.testing.expectEqual(@as(u8, 0), coverageAt(cov, 12, 8.5));

    // The nuki itself. Sampled at x = 9, NOT at the centre: crossbar_position
    // and diagonal_depth are both 0.33, so the two M diagonals meet the nuki at
    // exactly one point and a centre sample stays lit with no crossbar at all.
    // At x in [9,10] the nearer diagonal is down to 14.96 at its lowest, so
    // this cell belongs to the nuki alone. Not a full 255: the band runs from
    // 13.02 to 14.72, so the cell y in [13,14] is short by the 0.02 sliver
    // under the band. Zero without a nuki, and far under this with a hairline.
    try std.testing.expect(coverageAt(cov, 9, 13.87) > 240);

    // The kasagi sweeps UP at its ends: they reach past y = 21 while the
    // middle, pulled down by the control point at 19.11, stops at 20.80. An
    // inverted curve swaps the two and gives the mark a sagging beam.
    try std.testing.expect(coverageAt(cov, 3.84, 21.5) > 0);
    try std.testing.expectEqual(@as(u8, 0), coverageAt(cov, 12, 21.5));

    // The mark is centred on the grid on both axes. Dropping the offset that
    // centres a 170 tall canvas inside a 24 square puts the vertical centre
    // near 9 instead of 12.
    const right = cov.left + @as(i64, cov.w);
    const top = -cov.top; // path-space y of the bitmap's top edge
    const bottom = -(cov.top + @as(i64, cov.h));
    try std.testing.expectEqual(@as(i64, 12), @divExact(cov.left + right, 2));
    try std.testing.expectEqual(@as(i64, 12), @divExact(top + bottom, 2));

    // And it stays inside the grid, so a caller may size the icon box at the
    // grid and never clip the mark.
    try std.testing.expect(cov.left >= 0 and right <= 24);
    try std.testing.expect(bottom >= 0 and top <= 24);
}

// ---------------------------------------------------------------------------
// The interface set
//
// Authored directly on the 24 grid rather than transcribed from a generator, so
// the numbers below ARE the geometry. Two rules hold across all of them:
//
//   * y grows UPWARDS here, as it does for the torii above, because
//     `text/raster.zig` flips on its way to a top-down bitmap.
//   * a mark keeps a 2 unit margin, so the default 1.7 stroke has room for its
//     round cap without touching the edge of the box.
//
// The exception is the two rules, which run the full height or width. A rail is
// drawn once per row and has to JOIN the one above it: a 2 unit margin would
// leave a visible gap at every row boundary, so they run 0 to 24 and take butt
// caps, which stop exactly at the boundary instead of rounding past it.

/// A tick. Down from the left, then up to the right, with the vertex low and
/// off centre, which is what makes it read as a tick rather than a V.
const check = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 13 } },
    .{ .line = .{ .x = 10, .y = 8 } },
    .{ .line = .{ .x = 19, .y = 18 } },
} };

/// Two diagonals through the centre.
const cross = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 6.5, .y = 6.5 } },
    .{ .line = .{ .x = 17.5, .y = 17.5 } },
    .{ .move = .{ .x = 17.5, .y = 6.5 } },
    .{ .line = .{ .x = 6.5, .y = 17.5 } },
} };

const chevron_left = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 14.5, .y = 19 } },
    .{ .line = .{ .x = 8, .y = 12 } },
    .{ .line = .{ .x = 14.5, .y = 5 } },
} };

const chevron_right = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 9.5, .y = 19 } },
    .{ .line = .{ .x = 16, .y = 12 } },
    .{ .line = .{ .x = 9.5, .y = 5 } },
} };

const chevron_up = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 9.5 } },
    .{ .line = .{ .x = 12, .y = 16 } },
    .{ .line = .{ .x = 19, .y = 9.5 } },
} };

const chevron_down = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 14.5 } },
    .{ .line = .{ .x = 12, .y = 8 } },
    .{ .line = .{ .x = 19, .y = 14.5 } },
} };

/// Shaft and head. The head meets the shaft at its tip rather than crossing it,
/// so the join stays clean at a small size.
const arrow_right = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 4, .y = 12 } },
    .{ .line = .{ .x = 19.5, .y = 12 } },
    .{ .move = .{ .x = 13.5, .y = 18 } },
    .{ .line = .{ .x = 19.5, .y = 12 } },
    .{ .line = .{ .x = 13.5, .y = 6 } },
} };

const plus = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 12, .y = 5 } },
    .{ .line = .{ .x = 12, .y = 19 } },
    .{ .move = .{ .x = 5, .y = 12 } },
    .{ .line = .{ .x = 19, .y = 12 } },
} };

const minus = path.Path{ .verbs = &.{
    .{ .move = .{ .x = 5, .y = 12 } },
    .{ .line = .{ .x = 19, .y = 12 } },
} };

/// Full bleed and butt capped, so stacking one per row draws a continuous rail
/// with no seam at the row boundaries. This is U+2502's job in a terminal, and
/// the reason it is here is that no bundled font has that glyph.
const rule_vertical = path.Path{
    .verbs = &.{
        .{ .move = .{ .x = 12, .y = 0 } },
        .{ .line = .{ .x = 12, .y = 24 } },
    },
    .stroke = .{ .cap = .butt },
};

/// The same, along the other axis, for a separator that meets its neighbours.
const rule_horizontal = path.Path{
    .verbs = &.{
        .{ .move = .{ .x = 0, .y = 12 } },
        .{ .line = .{ .x = 24, .y = 12 } },
    },
    .stroke = .{ .cap = .butt },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The margin every mark keeps, except the two rules. See the section comment.
const margin: f32 = 2;

const Bounds = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

fn boundsOf(p: path.Path) Bounds {
    var b = Bounds{ .min_x = grid, .min_y = grid, .max_x = 0, .max_y = 0 };
    for (p.verbs) |v| {
        const pts: []const path.Point = switch (v) {
            .move => |pt| &.{pt},
            .line => |pt| &.{pt},
            .quad => |q| &.{ q.ctrl, q.end },
            .cubic => |c| &.{ c.c1, c.c2, c.end },
            .close => &.{},
        };
        for (pts) |pt| {
            b.min_x = @min(b.min_x, pt.x);
            b.min_y = @min(b.min_y, pt.y);
            b.max_x = @max(b.max_x, pt.x);
            b.max_y = @max(b.max_y, pt.y);
        }
    }
    return b;
}

test "every built-in id has a path, and none of them is empty" {
    // Exhaustive over the enum, so adding a member without a centreline fails
    // here rather than drawing nothing at a call site.
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        try std.testing.expect(pathFor(id).verbs.len > 0);
    }
}

test "every built-in mark stays inside its own grid" {
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const b = boundsOf(pathFor(@enumFromInt(f.value)));
        try std.testing.expect(b.min_x >= 0 and b.min_y >= 0);
        try std.testing.expect(b.max_x <= grid and b.max_y <= grid);
    }
}

test "the interface marks keep their margin, so a round cap never touches the edge" {
    // The rules are excluded on purpose: they are full bleed so that stacking
    // them draws a continuous rail, which is the whole reason they exist.
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        if (id == .rule_vertical or id == .rule_horizontal or id == .torii) continue;
        const b = boundsOf(pathFor(id));
        try std.testing.expect(b.min_x >= margin and b.min_y >= margin);
        try std.testing.expect(b.max_x <= grid - margin and b.max_y <= grid - margin);
    }
}

test "a rule runs the full length and stops square, so stacked rules meet with no seam" {
    const v = pathFor(.rule_vertical);
    const vb = boundsOf(v);
    try std.testing.expectEqual(@as(f32, 0), vb.min_y);
    try std.testing.expectEqual(grid, vb.max_y);
    // A round cap would bulge past the boundary and a gap would still show
    // between rows wherever the bulge did not reach.
    try std.testing.expectEqual(path.Cap.butt, v.stroke.cap);

    const h = pathFor(.rule_horizontal);
    const hb = boundsOf(h);
    try std.testing.expectEqual(@as(f32, 0), hb.min_x);
    try std.testing.expectEqual(grid, hb.max_x);
    try std.testing.expectEqual(path.Cap.butt, h.stroke.cap);
}

test "every built-in mark rasterises to real ink, which is what a missing glyph did not" {
    const gpa = std.testing.allocator;
    inline for (@typeInfo(Id).@"enum".fields) |f| {
        const id: Id = @enumFromInt(f.value);
        var out = try stroke.expand(gpa, pathFor(id));
        defer out.deinit(gpa);
        // The same call the GPU backend makes in `ensureIcon`.
        var cov = try raster.rasterize(gpa, out, grid_units, 24, grid_units);
        defer cov.deinit(gpa);

        var lit: usize = 0;
        for (cov.pixels) |px| {
            if (px > 0) lit += 1;
        }
        // The point of the whole set: a tick drawn by phantom puts ink on the
        // surface, where U+2713 in a bundled font resolved to glyph 0.
        try std.testing.expect(lit > 0);
    }
}

test "the check mark is a tick and not a V: its vertex sits left of centre" {
    const b = boundsOf(pathFor(.check));
    const verbs = pathFor(.check).verbs;
    try std.testing.expectEqual(@as(usize, 3), verbs.len);
    const vertex = verbs[1].line;
    // Lowest point of the three, and left of the middle, which is what
    // distinguishes a tick from a symmetric V.
    try std.testing.expectEqual(b.min_y, vertex.y);
    try std.testing.expect(vertex.x < grid / 2);
}
