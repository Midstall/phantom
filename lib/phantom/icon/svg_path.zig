//! Serialises an icon centreline as SVG path data.
//!
//! An icon `Path` is a centreline plus a stroke width, and SVG strokes a path
//! itself. So the two renderers split the same geometry two ways: Prism expands
//! the centreline with `icon/stroke.zig` and rasterises the outline into the
//! glyph atlas, while the DOM backend hands the centreline to the browser and
//! lets it do the expansion. The web side needs no atlas and stays sharp at
//! every zoom level, because the browser strokes at device resolution.
const std = @import("std");
const path = @import("path.zig");

/// Serialisation grows one buffer, so that buffer is the only thing that fails.
pub const Error = error{OutOfMemory};

/// Bytes `coord` can need. `{d:.3}` on the largest finite f32 writes 39 integer
/// digits, and a sign, a point and 3 decimals bring that to 44.
pub const coord_len = 48;

/// Format `v` for an SVG attribute, into `buf` (at least `coord_len` bytes).
///
/// Three decimals is a thousandth of a grid unit. The grid is 24 units on a
/// side and Phantom draws an icon at tens of pixels, so a thousandth of a unit
/// stays two orders of magnitude under one device pixel at any size a shell
/// asks for. More digits only make the document longer, and f32 coordinates
/// derived from ratios print 8 significant digits of rounding noise otherwise.
pub fn coord(buf: []u8, v: f32) []const u8 {
    const rounded = @round(v * 1000) / 1000;
    // Rounding can land on -0, which names the same point as 0 and costs a byte
    // more to print.
    const safe: f32 = if (rounded == 0) 0 else rounded;
    const printed = std.fmt.bufPrint(buf, "{d:.3}", .{safe}) catch return "0";
    return trimTrailingZeros(printed);
}

/// Drop the zeros a fixed-decimal format pads with, and the point they leave
/// behind. `nan` and `inf` carry no point and pass through unchanged.
fn trimTrailingZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// The `stroke-linecap` keyword for `cap`. Exhaustive with no `else`, so a new
/// cap fails the build here rather than drawing as a butt end.
pub fn lineCap(cap: path.Cap) []const u8 {
    return switch (cap) {
        .butt => "butt",
        .round => "round",
    };
}

/// The `stroke-linejoin` keyword for `join`, exhaustive for the same reason as
/// `lineCap`.
pub fn lineJoin(join: path.Join) []const u8 {
    return switch (join) {
        .miter => "miter",
        .round => "round",
    };
}

/// The `d` attribute for `p`, in the coordinate system of a viewBox `grid`
/// units on a side. Caller owns the returned slice.
///
/// Icon paths grow y upwards, because `text/raster.zig` flips y on its way to a
/// top-down bitmap and a path handed to it has to grow upwards. SVG grows y
/// downwards, so every y becomes `grid - y` here. Without the flip the torii
/// draws as a sagging beam over inverted pillars.
pub fn data(gpa: std.mem.Allocator, p: path.Path, grid: f32) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    // Exhaustive with no `else`: a new verb must fail the build rather than
    // drop a segment out of the mark.
    for (p.verbs) |verb| switch (verb) {
        .move => |pt| {
            try buf.append(gpa, 'M');
            try appendPoint(&buf, gpa, pt, grid);
        },
        .line => |pt| {
            try buf.append(gpa, 'L');
            try appendPoint(&buf, gpa, pt, grid);
        },
        .quad => |q| {
            try buf.append(gpa, 'Q');
            try appendPoint(&buf, gpa, q.ctrl, grid);
            try buf.append(gpa, ' ');
            try appendPoint(&buf, gpa, q.end, grid);
        },
        .cubic => |c| {
            try buf.append(gpa, 'C');
            try appendPoint(&buf, gpa, c.c1, grid);
            try buf.append(gpa, ' ');
            try appendPoint(&buf, gpa, c.c2, grid);
            try buf.append(gpa, ' ');
            try appendPoint(&buf, gpa, c.end, grid);
        },
        .close => try buf.append(gpa, 'Z'),
    };

    return buf.toOwnedSlice(gpa);
}

/// One point as `x y`. A command letter separates itself from the number after
/// it, so no separator goes in front of the command.
fn appendPoint(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, pt: path.Point, grid: f32) Error!void {
    var num: [coord_len]u8 = undefined;
    try buf.appendSlice(gpa, coord(&num, pt.x));
    try buf.append(gpa, ' ');
    try buf.appendSlice(gpa, coord(&num, grid - pt.y));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const builtin_icons = @import("builtin.zig");

test "a move then a line serialises to M and L with y measured down from the grid" {
    const gpa = std.testing.allocator;
    const p = path.Path{ .verbs = &.{
        .{ .move = .{ .x = 2, .y = 4 } },
        .{ .line = .{ .x = 10, .y = 4 } },
    } };
    const d = try data(gpa, p, 24);
    defer gpa.free(d);
    // y = 4 on a y-up grid of 24 is 20 down from the top edge. An unflipped
    // serialiser writes "M2 4L10 4" and draws every built-in mark upside down.
    try std.testing.expectEqualStrings("M2 20L10 20", d);
}

test "a quadratic serialises to Q with the control point before the end point" {
    // The torii's kasagi is the only curve in the Midstall mark, so a Q with its
    // two points swapped bends the brand mark the wrong way.
    const gpa = std.testing.allocator;
    const p = path.Path{ .verbs = &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .quad = .{ .ctrl = .{ .x = 6, .y = 18 }, .end = .{ .x = 12, .y = 0 } } },
    } };
    const d = try data(gpa, p, 24);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("M0 24Q6 6 12 24", d);
}

test "a cubic serialises to C with both control points before the end point" {
    const gpa = std.testing.allocator;
    const p = path.Path{ .verbs = &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .cubic = .{
            .c1 = .{ .x = 1, .y = 2 },
            .c2 = .{ .x = 3, .y = 4 },
            .end = .{ .x = 5, .y = 6 },
        } },
    } };
    const d = try data(gpa, p, 24);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("M0 24C1 22 3 20 5 18", d);
}

test "a closed subpath ends in Z" {
    const gpa = std.testing.allocator;
    const p = path.Path{ .verbs = &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 4, .y = 0 } },
        .close,
    } };
    const d = try data(gpa, p, 24);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("M0 24L4 24Z", d);
}

test "an empty path serialises to an empty d" {
    // A `d` of "" is the one string a browser draws nothing for, which is the
    // right answer for no verbs. Anything else would be a stray dot.
    const gpa = std.testing.allocator;
    const d = try data(gpa, path.Path{ .verbs = &.{} }, 24);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("", d);
}

test "round and butt caps map to their own SVG keywords" {
    try std.testing.expectEqualStrings("round", lineCap(.round));
    try std.testing.expectEqualStrings("butt", lineCap(.butt));
}

test "round and miter joins map to their own SVG keywords" {
    try std.testing.expectEqualStrings("round", lineJoin(.round));
    try std.testing.expectEqualStrings("miter", lineJoin(.miter));
}

test "a coordinate keeps three decimals and drops the padding zeros" {
    var buf: [coord_len]u8 = undefined;
    try std.testing.expectEqualStrings("12", coord(&buf, 12));
    try std.testing.expectEqualStrings("1.7", coord(&buf, 1.7));
    try std.testing.expectEqualStrings("3.218", coord(&buf, 3.2181234));
    try std.testing.expectEqualStrings("-2.5", coord(&buf, -2.5));
    // A value that rounds to nothing is the origin, not "-0".
    try std.testing.expectEqualStrings("0", coord(&buf, -0.0001));
    // The rounding noise an f32 ratio carries must not reach the document.
    try std.testing.expectEqualStrings("3.84", coord(&buf, 24.0 * 35.2 / 220.0));
}

test "the torii serialises to one quadratic kasagi over five straight elements" {
    // The mark is six subpaths: the curved kasagi, two pillars, two diagonals
    // and the nuki. Six M commands, exactly one Q, and no Z, because the
    // generator strokes six open shapes rather than one closed outline.
    const gpa = std.testing.allocator;
    const d = try data(gpa, builtin_icons.torii, builtin_icons.grid);
    defer gpa.free(d);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, d, "M"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, d, "Q"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, d, "L"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, d, "Z"));

    // The kasagi opens the path. Its ends sit at y = 20.782 on the y-up grid,
    // which is 3.218 down from the top, and its control point at 19.113 is
    // LOWER on the grid, so in SVG space it is the larger number. A flipped
    // curve gives the gate a sagging beam.
    try std.testing.expectEqualStrings("M3.84 3.218Q12 4.887 20.16 3.218", d[0 .. std.mem.indexOfScalar(u8, d[1..], 'M').? + 1]);
}
