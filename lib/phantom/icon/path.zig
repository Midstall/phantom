//! Centreline path: the geometry a stroker expands into a filled outline.
//! Distinct from text/outline.zig's Outline, which is already a filled region.
const std = @import("std");
const outline = @import("../text/outline.zig");

/// Reused from text/outline.zig rather than redefined: same x/y grid point,
/// no reason for icon geometry to diverge from glyph geometry.
pub const Point = outline.Point;

pub const Cap = enum { butt, round };
pub const Join = enum { miter, round };

pub const Stroke = struct {
    /// Grid units, not pixels. The icon grammar fixes this at 1.7 on a 24 grid.
    width: f32 = 1.7,
    cap: Cap = .round,
    join: Join = .round,
};

/// Mirrors outline.Segment in shape, plus `move` and `close` for starting and
/// ending a subpath, since a centreline (unlike a filled Outline's Contour) has
/// no separate start-point field.
pub const Verb = union(enum) {
    move: Point,
    line: Point,
    quad: struct { ctrl: Point, end: Point },
    cubic: struct { c1: Point, c2: Point, end: Point },
    close,
};

pub const Path = struct {
    verbs: []const Verb,
    stroke: Stroke = .{},
};

/// Appends verbs to a caller-owned list, for the runtime SVG-path case where
/// verb count is not known at comptime. Built-in icons skip this and write
/// the `verbs` slice as a comptime constant directly.
pub const Builder = struct {
    verbs: std.ArrayList(Verb) = .empty,

    pub fn deinit(self: *Builder, gpa: std.mem.Allocator) void {
        self.verbs.deinit(gpa);
    }

    pub fn moveTo(self: *Builder, gpa: std.mem.Allocator, x: f32, y: f32) !void {
        try self.verbs.append(gpa, .{ .move = .{ .x = x, .y = y } });
    }

    pub fn lineTo(self: *Builder, gpa: std.mem.Allocator, x: f32, y: f32) !void {
        try self.verbs.append(gpa, .{ .line = .{ .x = x, .y = y } });
    }

    pub fn quadTo(self: *Builder, gpa: std.mem.Allocator, cx: f32, cy: f32, ex: f32, ey: f32) !void {
        try self.verbs.append(gpa, .{ .quad = .{
            .ctrl = .{ .x = cx, .y = cy },
            .end = .{ .x = ex, .y = ey },
        } });
    }

    pub fn cubicTo(self: *Builder, gpa: std.mem.Allocator, c1x: f32, c1y: f32, c2x: f32, c2y: f32, ex: f32, ey: f32) !void {
        try self.verbs.append(gpa, .{ .cubic = .{
            .c1 = .{ .x = c1x, .y = c1y },
            .c2 = .{ .x = c2x, .y = c2y },
            .end = .{ .x = ex, .y = ey },
        } });
    }

    pub fn close(self: *Builder, gpa: std.mem.Allocator) !void {
        try self.verbs.append(gpa, .close);
    }
};

test "a path of two verbs reports both in order" {
    const p = Path{ .verbs = &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 10, .y = 0 } },
    } };
    try std.testing.expectEqual(@as(usize, 2), p.verbs.len);
    try std.testing.expectEqual(@as(f32, 10), p.verbs[1].line.x);
}

test "the default stroke is the icon grammar" {
    // 1.7 on a 24 grid with round caps and joins, derived from the brand mark
    // at icon size. If this drifts, the whole set stops looking like Midstall.
    const s = Stroke{};
    try std.testing.expectEqual(@as(f32, 1.7), s.width);
    try std.testing.expectEqual(Cap.round, s.cap);
    try std.testing.expectEqual(Join.round, s.join);
}

test "a comptime path needs no allocator" {
    // Built-in icons are constants. If Path ever needs an allocator this stops
    // compiling, which is the point.
    const p = comptime Path{ .verbs = &.{.{ .move = .{ .x = 1, .y = 2 } }} };
    try std.testing.expectEqual(@as(f32, 1), p.verbs[0].move.x);
}
