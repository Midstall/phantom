//! Stroker: expands a centreline Path into the filled Outline that
//! text/raster.zig already knows how to draw. Nothing below this point can
//! stroke a path: Canvas strokes rounded rectangles only and the rasteriser
//! fills, so a centreline has to become an outline before it reaches a screen.
const std = @import("std");
const path_mod = @import("path.zig");
const outline = @import("../text/outline.zig");

const Point = outline.Point;
const Cap = path_mod.Cap;
const Join = path_mod.Join;

/// Flatness tolerance for Bezier subdivision, in grid units. The value matches
/// raster.zig's deliberately: a curve in an icon and a curve in a glyph go
/// through the same rasteriser, so they break into chords of the same fineness.
const flatten_tolerance: f32 = 0.25;

/// Chord tolerance for the arcs of caps, joins and dots, in grid units. Much
/// finer than flatten_tolerance because these arcs are sampled once, in grid
/// units, and then magnified: raster.zig's 0.25 is in device pixels at the
/// final size, while a cap on the 24 unit icon grid drawn at 96 px is scaled by
/// four, so 0.25 here would show as a full pixel of facets.
const arc_tolerance: f32 = 0.02;

/// Two points nearer than this in both axes are one point. Below it a direction
/// cannot be normalised: the squared length underflows f32 to zero and the unit
/// vector comes out NaN, which then spreads through the whole outline without
/// ever raising an error. The icon grid is 24 units wide, so no real geometry
/// comes near this distance.
const merge_epsilon: f32 = 1e-6;

/// Upper bound on the chords of one arc. Only a radius above roughly 270 grid
/// units reaches it, which is an order of magnitude outside the icon grid.
const arc_steps_max: u32 = 256;

/// A miter longer than this multiple of the stroke half-width becomes a bevel.
/// 4 is the SVG default; without it a hairpin grows an unbounded spike.
const miter_limit: f32 = 4;

/// One flattened subpath: the centreline as a polyline with no two consecutive
/// points nearer than merge_epsilon.
const Sub = struct {
    pts: std.ArrayList(Point) = .empty,
    closed: bool = false,
};

/// Walks a point list forwards or backwards. The right side of a stroke is the
/// left side of the reversed centreline, so one side routine serves both and
/// the two can never disagree.
const Walk = struct {
    pts: []const Point,
    reverse: bool,

    fn len(self: Walk) usize {
        return self.pts.len;
    }

    fn get(self: Walk, i: usize) Point {
        return if (self.reverse) self.pts[self.pts.len - 1 - i] else self.pts[i];
    }
};

/// Expand `p`'s centreline into a filled outline of `p.stroke.width` grid
/// units. Every segment of the result is a line, which is what the rasteriser
/// wants and what keeps the fill independent of the output size.
///
/// An open subpath becomes one contour: the left side forwards, a cap, the
/// right side backwards, a cap. A closed one becomes two contours wound
/// opposite ways so the non-zero rule leaves the middle hollow.
///
/// Verbs before the first move have no start point and are dropped. The caller
/// owns the result and frees it with `deinit`.
pub fn expand(gpa: std.mem.Allocator, p: path_mod.Path) std.mem.Allocator.Error!outline.Outline {
    var out: outline.Outline = .{};
    errdefer out.deinit(gpa);

    var subs: std.ArrayList(Sub) = .empty;
    defer {
        for (subs.items) |*s| s.pts.deinit(gpa);
        subs.deinit(gpa);
    }
    try flatten(gpa, p.verbs, &subs);

    const r = p.stroke.width / 2;

    // Scratch for the contour under construction, reused across subpaths so a
    // 40 icon theme does not churn the allocator once per corner.
    var pts: std.ArrayList(Point) = .empty;
    defer pts.deinit(gpa);

    for (subs.items) |*s| {
        const centre = s.pts.items;
        if (centre.len == 0) continue;
        if (centre.len == 1) {
            // No direction exists, so only a cap that is the same in every
            // direction has an answer here.
            switch (p.stroke.cap) {
                .round => {
                    pts.clearRetainingCapacity();
                    try appendCircle(gpa, &pts, centre[0], r);
                    try emitContour(gpa, &out, pts.items);
                },
                .butt => {},
            }
            continue;
        }

        // Two points enclose no area, so a closed subpath of two would give an
        // outer and an inner contour of the same shape wound opposite ways and
        // the non-zero rule would cancel them to nothing. Stroke it once
        // instead, which is what the author drew.
        if (s.closed and centre.len >= 3) {
            pts.clearRetainingCapacity();
            try appendSide(gpa, &pts, .{ .pts = centre, .reverse = false }, true, r, p.stroke.join);
            try emitContour(gpa, &out, pts.items);

            pts.clearRetainingCapacity();
            try appendSide(gpa, &pts, .{ .pts = centre, .reverse = true }, true, r, p.stroke.join);
            try emitContour(gpa, &out, pts.items);
            continue;
        }

        const fwd: Walk = .{ .pts = centre, .reverse = false };
        const back: Walk = .{ .pts = centre, .reverse = true };
        pts.clearRetainingCapacity();
        try appendSide(gpa, &pts, fwd, false, r, p.stroke.join);
        try appendCap(gpa, &pts, fwd, r, p.stroke.cap);
        try appendSide(gpa, &pts, back, false, r, p.stroke.join);
        try appendCap(gpa, &pts, back, r, p.stroke.cap);
        try emitContour(gpa, &out, pts.items);
    }

    return out;
}

/// Split the verbs into subpaths and reduce every curve to line segments.
fn flatten(
    gpa: std.mem.Allocator,
    verbs: []const path_mod.Verb,
    subs: *std.ArrayList(Sub),
) std.mem.Allocator.Error!void {
    // An index, not a pointer: appending a subpath reallocates the list and
    // would leave a pointer to the old buffer.
    var cur: ?usize = null;

    for (verbs) |verb| {
        switch (verb) {
            .move => |pt| {
                try subs.append(gpa, .{});
                cur = subs.items.len - 1;
                try push(gpa, &subs.items[subs.items.len - 1].pts, pt);
            },
            .line => |pt| {
                const i = cur orelse continue;
                try push(gpa, &subs.items[i].pts, pt);
            },
            .quad => |q| {
                const i = cur orelse continue;
                const list = &subs.items[i].pts;
                try flattenQuad(gpa, list, list.items[list.items.len - 1], q.ctrl, q.end, 0);
            },
            .cubic => |c| {
                const i = cur orelse continue;
                const list = &subs.items[i].pts;
                try flattenCubic(gpa, list, list.items[list.items.len - 1], c.c1, c.c2, c.end, 0);
            },
            .close => {
                const i = cur orelse continue;
                subs.items[i].closed = true;
                // A draw verb after a close has no start point again, the same
                // as one before the first move.
                cur = null;
            },
        }
    }

    // An author who ends a ring back on its start point means one corner, not
    // two in the same place.
    for (subs.items) |*s| {
        const n = s.pts.items.len;
        if (s.closed and n >= 2 and near(s.pts.items[n - 1], s.pts.items[0])) {
            _ = s.pts.pop();
        }
    }
}

/// Append `pt` unless it repeats the point already there.
fn push(gpa: std.mem.Allocator, list: *std.ArrayList(Point), pt: Point) std.mem.Allocator.Error!void {
    if (list.items.len > 0 and near(list.items[list.items.len - 1], pt)) return;
    try list.append(gpa, pt);
}

fn near(a: Point, b: Point) bool {
    // Compared per axis rather than by distance: squaring a subnormal delta
    // underflows to zero, which is the case this guard exists to catch.
    return @abs(a.x - b.x) <= merge_epsilon and @abs(a.y - b.y) <= merge_epsilon;
}

fn flattenQuad(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    p2: Point,
    depth: u8,
) std.mem.Allocator.Error!void {
    if (depth >= 16 or pointLineDist(p1, p0, p2) <= flatten_tolerance) {
        try push(gpa, list, p2);
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p012 = mid(p01, p12);
    try flattenQuad(gpa, list, p0, p01, p012, depth + 1);
    try flattenQuad(gpa, list, p012, p12, p2, depth + 1);
}

fn flattenCubic(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
    depth: u8,
) std.mem.Allocator.Error!void {
    const dev = @max(pointLineDist(p1, p0, p3), pointLineDist(p2, p0, p3));
    if (depth >= 18 or dev <= flatten_tolerance) {
        try push(gpa, list, p3);
        return;
    }
    const p01 = mid(p0, p1);
    const p12 = mid(p1, p2);
    const p23 = mid(p2, p3);
    const p012 = mid(p01, p12);
    const p123 = mid(p12, p23);
    const p0123 = mid(p012, p123);
    try flattenCubic(gpa, list, p0, p01, p012, p0123, depth + 1);
    try flattenCubic(gpa, list, p0123, p123, p23, p3, depth + 1);
}

/// Offset one side of `w` by `r`, adding a join at every interior vertex. The
/// side is the left of the direction of travel, so walking a reversed centre
/// line gives the right side.
fn appendSide(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    w: Walk,
    closed: bool,
    r: f32,
    join: Join,
) std.mem.Allocator.Error!void {
    const n = w.len();
    const seg_count = if (closed) n else n - 1;

    // An open side starts on the first segment's offset line. A ring has no
    // start, so its first point comes from the wrap-around vertex handled last
    // and the contour closes onto it.
    if (!closed) try list.append(gpa, add(w.get(0), normalAt(w, 0, r)));

    var i: usize = 0;
    while (i < seg_count) : (i += 1) {
        const v = w.get((i + 1) % n);
        const n0 = normalAt(w, i, r);
        if (!closed and i + 1 == seg_count) {
            // The far end of an open side: the cap continues from here.
            try list.append(gpa, add(v, n0));
            break;
        }
        const next = if (i + 1 == seg_count) 0 else i + 1;
        try appendJoin(gpa, list, v, n0, normalAt(w, next, r), r, join);
    }
}

/// Fill the wedge the two offset segments leave at a vertex.
fn appendJoin(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    v: Point,
    n0: Point,
    n1: Point,
    r: f32,
    join: Join,
) std.mem.Allocator.Error!void {
    const cross = n0.x * n1.y - n0.y * n1.x;
    const dot = n0.x * n1.x + n0.y * n1.y;
    const a = add(v, n0);
    const b = add(v, n1);

    if (cross == 0 and dot > 0) {
        // Straight through: both offsets lie on one line, so the vertex needs
        // no point of its own.
        try list.append(gpa, a);
        return;
    }

    if (cross > 0) {
        // Inside of the turn, where the two offsets overlap rather than leave a
        // gap. Both loose ends go in and the overlap is left to the non-zero
        // rule, which winds the doubled area the same way as the rest of the
        // stroke and so fills it. Trimming to the crossing point instead was
        // tried and rendered pixel for pixel the same.
        try list.append(gpa, a);
        try list.append(gpa, b);
        return;
    }

    // Outside of the turn, the only side where the two offsets leave a gap.
    switch (join) {
        .round => {
            try list.append(gpa, a);
            try appendArc(gpa, list, v, r, std.math.atan2(n0.y, n0.x), sweep(cross, dot));
            try list.append(gpa, b);
        },
        .miter => {
            try list.append(gpa, a);
            if (miterPoint(v, n0, n1, r)) |m| try list.append(gpa, m);
            try list.append(gpa, b);
        },
    }
}

/// Signed turn from `n0` to `n1`, negative when the left side is the outside.
fn sweep(cross: f32, dot: f32) f32 {
    // A 180 degree reversal has no sign: both directions are half a turn. Take
    // the negative one so the arc sweeps past the tip the way a cap does,
    // rather than folding back over the stroke and leaving a square end.
    if (cross == 0) return -std.math.pi;
    return std.math.atan2(cross, dot);
}

/// Where the two offset lines meet, or null when the turn is too sharp for the
/// miter limit and a bevel has to do instead.
fn miterPoint(v: Point, n0: Point, n1: Point, r: f32) ?Point {
    const bx = n0.x + n1.x;
    const by = n0.y + n1.y;
    const len2 = bx * bx + by * by;
    if (!(len2 > 0)) return null;
    // The bisector is 2r*cos(half the turn) long and the miter reaches
    // r/cos(half the turn) from the vertex, so the miter is 2r/|bisector|
    // half-widths long. A hairpin drives that to infinity.
    const bisector_len = @sqrt(len2);
    if (2 * r > miter_limit * bisector_len) return null;
    const k = 2 * r * r / len2;
    return .{ .x = v.x + bx * k, .y = v.y + by * k };
}

/// Close off the far end of `w`, from the left offset round to the right one.
fn appendCap(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    w: Walk,
    r: f32,
    cap: Cap,
) std.mem.Allocator.Error!void {
    switch (cap) {
        // The next side starts on the opposite offset, so a straight edge
        // between the two needs no point at all.
        .butt => {},
        .round => {
            const n = w.len();
            const end = w.get(n - 1);
            const nrm = normalAt(w, n - 2, r);
            // Half a turn, sweeping through the direction of travel so the
            // bulge lands past the end point rather than back over the stroke.
            try appendArc(gpa, list, end, r, std.math.atan2(nrm.y, nrm.x), -std.math.pi);
        },
    }
}

/// Points strictly between the ends of the arc; the caller owns both ends.
fn appendArc(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    centre: Point,
    r: f32,
    start: f32,
    total: f32,
) std.mem.Allocator.Error!void {
    const steps = arcSteps(r, total);
    var k: u32 = 1;
    while (k < steps) : (k += 1) {
        const a = start + total * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps)));
        try list.append(gpa, .{ .x = centre.x + r * @cos(a), .y = centre.y + r * @sin(a) });
    }
}

/// A whole circle, for a subpath that collapsed to one point.
fn appendCircle(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(Point),
    centre: Point,
    r: f32,
) std.mem.Allocator.Error!void {
    const steps = arcSteps(r, 2 * std.math.pi);
    var k: u32 = 0;
    while (k < steps) : (k += 1) {
        const a = 2 * std.math.pi * (@as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps)));
        try list.append(gpa, .{ .x = centre.x + r * @cos(a), .y = centre.y + r * @sin(a) });
    }
}

/// Chords needed to hold an arc of `total` radians within arc_tolerance.
fn arcSteps(r: f32, total: f32) u32 {
    // A radius at or under the tolerance is already within it, and the acos
    // below would be out of domain there.
    if (!(r > arc_tolerance)) return 1;
    const max_step = 2 * std.math.acos(1 - arc_tolerance / r);
    const need = @ceil(@abs(total) / max_step);
    if (!(need >= 1)) return 1;
    if (need >= @as(f32, @floatFromInt(arc_steps_max))) return arc_steps_max;
    return @intFromFloat(need);
}

/// Left-hand normal of segment `i` of `w`, scaled to `r`.
fn normalAt(w: Walk, i: usize, r: f32) Point {
    const a = w.get(i);
    const b = w.get((i + 1) % w.len());
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    // Consecutive points are at least merge_epsilon apart, so the length is
    // well clear of the underflow that would make this NaN.
    const inv = r / @sqrt(dx * dx + dy * dy);
    return .{ .x = -dy * inv, .y = dx * inv };
}

fn emitContour(
    gpa: std.mem.Allocator,
    out: *outline.Outline,
    pts: []const Point,
) std.mem.Allocator.Error!void {
    var b = outline.Builder.init(out);
    try b.moveTo(gpa, pts[0].x, pts[0].y);
    for (pts[1..]) |p| try b.lineTo(gpa, p.x, p.y);
    // No line back to the start: the rasteriser closes every contour itself.
    b.finish();
}

fn add(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn mid(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

/// Perpendicular distance from `p` to the line through `a` and `b`.
fn pointLineDist(p: Point, a: Point, b: Point) f32 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) {
        const ex = p.x - a.x;
        const ey = p.y - a.y;
        return @sqrt(ex * ex + ey * ey);
    }
    return @abs((p.x - a.x) * dy - (p.y - a.y) * dx) / @sqrt(len2);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const raster = @import("../text/raster.zig");

const Bounds = struct { min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

/// Axis-aligned extent of every point an Outline passes through. The stroker
/// emits lines only, so the start point and each line endpoint is the whole
/// geometry.
fn bounds(o: outline.Outline) Bounds {
    var b: Bounds = .{
        .min_x = std.math.floatMax(f32),
        .min_y = std.math.floatMax(f32),
        .max_x = -std.math.floatMax(f32),
        .max_y = -std.math.floatMax(f32),
    };
    for (o.contours.items) |c| {
        track(&b, c.start);
        for (c.segs.items) |s| {
            switch (s) {
                .line => |p| track(&b, p),
                // expand() emits lines only; a curve here means it is broken.
                .quad, .cubic => unreachable,
            }
        }
    }
    return b;
}

fn track(b: *Bounds, p: outline.Point) void {
    if (p.x < b.min_x) b.min_x = p.x;
    if (p.y < b.min_y) b.min_y = p.y;
    if (p.x > b.max_x) b.max_x = p.x;
    if (p.y > b.max_y) b.max_y = p.y;
}

test "a single horizontal segment expands to a rectangle of the stroke width" {
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 10, .y = 0 } } },
        .stroke = .{ .width = 2, .cap = .butt },
    });
    defer out.deinit(gpa);

    // One closed contour. With butt caps the extent is exactly the segment
    // length by the stroke width.
    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const b = bounds(out);
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), b.max_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), b.max_y, 0.001);
}

test "a round cap extends the outline by half the stroke width" {
    // The distinguishing fact against butt: a round cap adds a half-width
    // bulge past each endpoint. An implementation ignoring caps passes the
    // butt test above and fails here.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{ .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 10, .y = 0 } } },
        .stroke = .{ .width = 2, .cap = .round },
    });
    defer out.deinit(gpa);
    const b = bounds(out);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min_x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 11), b.max_x, 0.05);
}

test "a zero length segment produces a round dot rather than a crash" {
    // Two identical consecutive points make the segment direction undefined.
    // A naive normalise divides by zero and emits NaN, which poisons the
    // rasteriser silently rather than failing loudly.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{ .{ .move = .{ .x = 5, .y = 5 } }, .{ .line = .{ .x = 5, .y = 5 } } },
        .stroke = .{ .width = 2, .cap = .round },
    });
    defer out.deinit(gpa);
    const b = bounds(out);
    try std.testing.expect(!std.math.isNan(b.min_x));
    try std.testing.expectApproxEqAbs(@as(f32, 2), b.max_x - b.min_x, 0.1);
}

test "an empty path yields an empty outline without erroring" {
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{ .verbs = &.{} });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.contours.items.len);
}

test "a closed square produces an outer and an inner contour" {
    // A closed subpath is a ring: filling one contour would produce a solid
    // square instead of a stroked outline.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 10 } },
            .{ .line = .{ .x = 0, .y = 10 } },
            .close,
        },
        .stroke = .{ .width = 2 },
    });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), out.contours.items.len);
    // The outer ring stands half a width outside the centreline on every side.
    const b = bounds(out);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 11), b.max_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min_y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 11), b.max_y, 0.001);
}

test "the middle of a closed square rasterises hollow while the band is solid" {
    // What the two contours are for. Wound the same way they would add up and
    // the non-zero rule would fill the square solid, which the contour count
    // above cannot tell apart from a stroked ring.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 10 } },
            .{ .line = .{ .x = 0, .y = 10 } },
            .close,
        },
        .stroke = .{ .width = 2 },
    });
    defer out.deinit(gpa);

    // One grid unit per pixel, so a cell maps to the unit square of the same
    // name. The outline spans -1 to 11 on both axes, giving a 12 by 12 bitmap
    // whose row 0 is the top, at y = 11.
    var cov = try raster.rasterize(gpa, out, 24, 24, 24);
    defer cov.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 12), cov.w);
    try std.testing.expectEqual(@as(u32, 12), cov.h);

    // Cell x 5 to 6, y 5 to 6: inside the ring, well clear of the band, which
    // reaches in only as far as 1.
    try std.testing.expectEqual(@as(u8, 0), cov.pixels[6 * 12 + 6]);
    // Cell x 5 to 6, y -1 to 0: the lower half of the bottom band.
    try std.testing.expectEqual(@as(u8, 255), cov.pixels[11 * 12 + 6]);
    // Cell x -1 to 0, y 5 to 6: the outer half of the left band.
    try std.testing.expectEqual(@as(u8, 255), cov.pixels[6 * 12 + 0]);
    // Cell x 0 to 1, y 0 to 1: the corner of the band, solid up to the inner
    // ring's turn at 1,1. A join that connects the two offsets end to end
    // instead of where they cross bites this cell in half.
    try std.testing.expectEqual(@as(u8, 255), cov.pixels[10 * 12 + 1]);
}

test "a curve is flattened into line segments" {
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .cubic = .{ .c1 = .{ .x = 5, .y = 10 }, .c2 = .{ .x = 15, .y = 10 }, .end = .{ .x = 20, .y = 0 } } },
        },
        .stroke = .{ .width = 2 },
    });
    defer out.deinit(gpa);
    // The kasagi of the torii is a curve, so this path must not collapse to a
    // straight line between the endpoints.
    const b = bounds(out);
    try std.testing.expect(b.max_y - b.min_y > 5);
    for (out.contours.items) |c| {
        for (c.segs.items) |s| try std.testing.expect(s == .line);
    }
}

test "a subpath of a single move draws a dot of the stroke width" {
    // A move with nothing after it has no direction at all, so every offset
    // normal is undefined. The round cap has a defined answer regardless: the
    // dot the cap would draw at either end of a zero length stroke.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{.{ .move = .{ .x = 3, .y = 7 } }},
        .stroke = .{ .width = 2, .cap = .round },
    });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const b = bounds(out);
    try std.testing.expectApproxEqAbs(@as(f32, 2), b.max_x - b.min_x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 2), b.max_y - b.min_y, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 3), (b.min_x + b.max_x) / 2, 0.001);
}

test "a 180 degree reversal rounds the tip instead of emitting NaN" {
    // Doubling back leaves the join with two opposite normals: the turn has no
    // sign, so the side the join belongs on is undefined. Sweeping the arc past
    // the tip is the answer a cap would give, and it is the only one that keeps
    // the tip at x = 11 rather than folding back over the stroke.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
            .{ .line = .{ .x = 0, .y = 0 } },
        },
        .stroke = .{ .width = 2, .cap = .butt, .join = .round },
    });
    defer out.deinit(gpa);
    const b = bounds(out);
    try std.testing.expect(!std.math.isNan(b.min_x) and !std.math.isNan(b.max_y));
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.min_x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 11), b.max_x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min_y, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 1), b.max_y, 0.05);
}

test "a closed subpath of two points draws one stroked contour, not a cancelling pair" {
    // A ring needs three corners to enclose an area. With two, the outer and
    // the inner contour are the same shape wound opposite ways, so the non-zero
    // rule cancels them and the icon disappears. Such a subpath is a there and
    // back stroke and is drawn as one contour.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
            .close,
        },
        .stroke = .{ .width = 2, .cap = .butt },
    });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const b = bounds(out);
    try std.testing.expectApproxEqAbs(@as(f32, 10), b.max_x - b.min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2), b.max_y - b.min_y, 0.001);
}

test "two points a subnormal distance apart merge instead of producing NaN" {
    // The distance is not zero, so an exact equality test lets it through, but
    // the squared length underflows f32 to zero and the unit vector comes out
    // NaN. Points nearer than the merge epsilon are one point.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 1e-30, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
        },
        .stroke = .{ .width = 2, .cap = .butt },
    });
    defer out.deinit(gpa);
    const b = bounds(out);
    try std.testing.expect(!std.math.isNan(b.min_x) and !std.math.isNan(b.min_y));
    try std.testing.expectApproxEqAbs(@as(f32, 0), b.min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), b.max_x, 0.001);
}

test "a miter join carries the outer corner out to the apex" {
    // A right angle in a 2 unit stroke puts the apex a half-width diagonal out
    // from the vertex, at -1,-1. A round join reaches only 0.707 of that and a
    // bevel does not reach it at all, yet all three share the same extent, so
    // the apex has to be looked for by name.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 10 } },
            .{ .line = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
        },
        .stroke = .{ .width = 2, .cap = .butt, .join = .miter },
    });
    defer out.deinit(gpa);

    var found = false;
    for (out.contours.items) |c| {
        for (c.segs.items) |s| {
            const p = s.line;
            if (@abs(p.x + 1) < 0.001 and @abs(p.y + 1) < 0.001) found = true;
        }
    }
    try std.testing.expect(found);
}

test "a miter longer than the limit becomes a bevel instead of a spike" {
    // The two sides of a hairpin are almost parallel, so the apex runs off
    // towards infinity: here it would sit about 200 units out on a 24 unit
    // grid. The limit is what keeps the icon inside its own box.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{
            .{ .move = .{ .x = 0, .y = 0 } },
            .{ .line = .{ .x = 10, .y = 0 } },
            .{ .line = .{ .x = 0, .y = 0.1 } },
        },
        .stroke = .{ .width = 2, .cap = .butt, .join = .miter },
    });
    defer out.deinit(gpa);
    const b = bounds(out);
    try std.testing.expect(b.max_x < 12);
}

test "verbs before the first move are dropped rather than panicking" {
    // A line has no start point until a move gives it one. Builder can emit
    // this at runtime from a malformed SVG path, so it is a fault to recover
    // from, not an invariant to assert.
    const gpa = std.testing.allocator;
    var out = try expand(gpa, .{
        .verbs = &.{ .{ .line = .{ .x = 10, .y = 0 } }, .close },
        .stroke = .{ .width = 2 },
    });
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.contours.items.len);
}
