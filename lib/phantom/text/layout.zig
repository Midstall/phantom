const std = @import("std");
const dl = @import("../display_list.zig");
const Font = @import("Font.zig");
const builtin = @import("builtin.zig");
const mono = @import("mono.zig");

pub const Line = struct {
    glyphs: []dl.PositionedGlyph,
    width: f32,
    height: f32,
    ascent: f32,
    pub fn deinit(self: *Line, gpa: std.mem.Allocator) void {
        gpa.free(self.glyphs);
        self.* = undefined;
    }
};

/// Lay out one line of UTF-8 `text` in `font` at `size` px. Positions each glyph
/// on the baseline by cumulative advance (left to right, no kerning/shaping this
/// slice). Metrics only; the only allocation is the returned glyphs slice.
///
/// `metrics` selects the advance model. `.proportional` reads the font, which is
/// what the GPU backend and the web backend need. `.mono` gives every codepoint the
/// cell advance multiplied by its column count, which is what a character grid
/// needs, and it ignores `size`.
pub fn layoutLine(
    gpa: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    size: f32,
    metrics: mono.TextMetrics,
) !Line {
    const scale = size / @as(f32, @floatFromInt(font.metrics.units_per_em));
    const font_ascent = @as(f32, @floatFromInt(font.ascent())) * scale;
    const font_descent = @as(f32, @floatFromInt(font.descent())) * scale; // negative

    var glyphs: std.ArrayList(dl.PositionedGlyph) = .empty;
    errdefer glyphs.deinit(gpa);
    var pen_x: f32 = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        try glyphs.append(gpa, .{ .cp = cp, .x = pen_x, .y = 0 });
        pen_x += switch (metrics) {
            .proportional => font.advance(cp, size),
            .mono => |m| m.advance * @as(f32, @floatFromInt(mono.wcwidth(cp))),
        };
    }

    return .{
        .glyphs = try glyphs.toOwnedSlice(gpa),
        .width = pen_x,
        .height = switch (metrics) {
            .proportional => font_ascent - font_descent,
            .mono => |m| m.line,
        },
        .ascent = switch (metrics) {
            .proportional => font_ascent,
            .mono => |m| m.ascent,
        },
    };
}

test "layoutLine positions glyphs by cumulative advance and measures the line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var line = try layoutLine(gpa, &font, "AB", 48, .proportional);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), line.glyphs.len);
    try std.testing.expectEqual(@as(f32, 0), line.glyphs[0].x);
    // second glyph starts at the first glyph's advance
    try std.testing.expectApproxEqAbs(font.advance('A', 48), line.glyphs[1].x, 0.01);
    // width is the sum of both advances
    try std.testing.expectApproxEqAbs(font.advance('A', 48) + font.advance('B', 48), line.width, 0.01);
    // height is (ascent - descent) scaled; ascent > 0
    try std.testing.expect(line.height > 0 and line.ascent > 0);
}

test "mono metrics give every ASCII glyph the cell advance and the cell line height" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    var line = try layoutLine(gpa, &font, "Hello", 14, m);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 5), line.glyphs.len);
    // Five columns of nine pixels, and not the proportional advance of the font.
    try std.testing.expectEqual(@as(f32, 45), line.width);
    try std.testing.expectEqual(@as(f32, 18), line.height);
    try std.testing.expectEqual(@as(f32, 0), line.glyphs[0].x);
    try std.testing.expectEqual(@as(f32, 9), line.glyphs[1].x);
    try std.testing.expectEqual(@as(f32, 36), line.glyphs[4].x);
}

test "mono metrics ignore the font size, so two sizes measure the same" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    var small = try layoutLine(gpa, &font, "Hi", 8, m);
    defer small.deinit(gpa);
    var large = try layoutLine(gpa, &font, "Hi", 48, m);
    defer large.deinit(gpa);
    try std.testing.expectEqual(small.width, large.width);
    try std.testing.expectEqual(small.height, large.height);
}

test "mono metrics reserve two columns for a wide glyph" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var line = try layoutLine(gpa, &font, "\u{4E00}A", 14, m);
    defer line.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), line.glyphs.len);
    // The wide glyph takes two columns, so the ASCII glyph starts at column two.
    try std.testing.expectEqual(@as(f32, 20), line.glyphs[1].x);
    try std.testing.expectEqual(@as(f32, 30), line.width);
}

test "proportional metrics keep the font advances unchanged" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    var line = try layoutLine(gpa, &font, "AB", 48, .proportional);
    defer line.deinit(gpa);
    try std.testing.expectApproxEqAbs(font.advance('A', 48), line.glyphs[1].x, 0.01);
}
