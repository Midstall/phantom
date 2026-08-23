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
};

/// The centreline of `id`.
pub fn pathFor(id: Id) path.Path {
    return switch (id) {
        .torii => torii,
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
