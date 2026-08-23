//! Shared glyph outline types: Point, Segment, Contour, Outline, Builder.
//! Backend-agnostic; used by glyf.zig (TrueType) and later cff.zig.
const std = @import("std");

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Segment = union(enum) {
    line: Point,
    quad: struct { ctrl: Point, end: Point },
    cubic: struct { c1: Point, c2: Point, end: Point },
};

pub const Contour = struct {
    start: Point,
    segs: std.ArrayList(Segment) = .empty,
};

pub const Outline = struct {
    contours: std.ArrayList(Contour) = .empty,

    pub fn deinit(self: *Outline, gpa: std.mem.Allocator) void {
        for (self.contours.items) |*c| {
            c.segs.deinit(gpa);
        }
        self.contours.deinit(gpa);
    }
};

/// Stateful builder that appends contours and segments to an Outline.
/// Call moveTo to start a contour, then lineTo/quadTo/cubicTo to add
/// segments. Call finish() when done; it is a no-op if no contour is open.
pub const Builder = struct {
    out: *Outline,
    /// Index into out.contours.items of the current open contour, or null.
    cur: ?usize = null,

    pub fn init(out: *Outline) Builder {
        return .{ .out = out };
    }

    /// Start a new contour at (x, y). Any previously open contour is left as-is.
    pub fn moveTo(self: *Builder, gpa: std.mem.Allocator, x: f32, y: f32) !void {
        const idx = self.out.contours.items.len;
        try self.out.contours.append(gpa, Contour{
            .start = .{ .x = x, .y = y },
            .segs = .empty,
        });
        self.cur = idx;
    }

    /// Append a line segment to the current end point (x, y).
    pub fn lineTo(self: *Builder, gpa: std.mem.Allocator, x: f32, y: f32) !void {
        const c = &self.out.contours.items[self.cur.?];
        try c.segs.append(gpa, .{ .line = .{ .x = x, .y = y } });
    }

    /// Append a quadratic Bezier segment.
    pub fn quadTo(self: *Builder, gpa: std.mem.Allocator, cx: f32, cy: f32, ex: f32, ey: f32) !void {
        const c = &self.out.contours.items[self.cur.?];
        try c.segs.append(gpa, .{ .quad = .{
            .ctrl = .{ .x = cx, .y = cy },
            .end = .{ .x = ex, .y = ey },
        } });
    }

    /// Append a cubic Bezier segment.
    pub fn cubicTo(self: *Builder, gpa: std.mem.Allocator, c1x: f32, c1y: f32, c2x: f32, c2y: f32, ex: f32, ey: f32) !void {
        const c = &self.out.contours.items[self.cur.?];
        try c.segs.append(gpa, .{ .cubic = .{
            .c1 = .{ .x = c1x, .y = c1y },
            .c2 = .{ .x = c2x, .y = c2y },
            .end = .{ .x = ex, .y = ey },
        } });
    }

    /// Close the current contour (noop if none open).
    pub fn finish(self: *Builder) void {
        self.cur = null;
    }
};

test "Outline builder: one contour three line segments" {
    const gpa = std.testing.allocator;
    var out = Outline{};
    defer out.deinit(gpa);

    var b = Builder.init(&out);
    try b.moveTo(gpa, 0, 0);
    try b.lineTo(gpa, 1, 0);
    try b.lineTo(gpa, 0.5, 1);
    try b.lineTo(gpa, 0, 0);
    b.finish();

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    try std.testing.expectEqual(@as(usize, 3), out.contours.items[0].segs.items.len);
}
