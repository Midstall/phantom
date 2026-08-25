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
    // Only the ascent is needed on its own now: the line box comes from
    // `Font.lineHeight`, so the two cannot disagree.

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
            // Through `Font.lineHeight` rather than repeating the subtraction,
            // so the line box a caller can ASK for and the one a run actually
            // gets are the same number by construction.
            .proportional => font.lineHeight(size),
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

/// A run of text broken into lines that each fit a width.
pub const Paragraph = struct {
    lines: []Line,
    /// The widest line, which is what the paragraph occupies.
    width: f32,
    /// The sum of the line heights, stacked with no extra leading.
    height: f32,

    pub fn deinit(self: *Paragraph, gpa: std.mem.Allocator) void {
        for (self.lines) |*l| l.deinit(gpa);
        gpa.free(self.lines);
        self.* = undefined;
    }
};

/// The advance one codepoint contributes under `metrics`, which is the same
/// question `layoutLine` asks per glyph. Breaking has to measure with the model
/// that will draw, or a line that was measured as fitting would not.
fn advanceOf(font: *Font, cp: u21, size: f32, metrics: mono.TextMetrics) f32 {
    return switch (metrics) {
        .proportional => font.advance(cp, size),
        .mono => |m| m.advance * @as(f32, @floatFromInt(mono.wcwidth(cp))),
    };
}

/// Where the line starting at `from` ends, and where the next one starts.
///
/// The two differ when the break falls on a space: the space ends the line and
/// is not carried onto the next one, so a wrapped paragraph does not begin
/// lines with a blank.
const Break = struct { end: usize, next: usize };

fn nextBreak(
    font: *Font,
    text: []const u8,
    from: usize,
    size: f32,
    metrics: mono.TextMetrics,
    max_width: f32,
) Break {
    var width: f32 = 0;
    var last_space: ?usize = null;
    var i = from;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..][0..@min(len, text.len - i)]) catch {
            // Malformed input is a runtime fault, not a reason to stop laying
            // out. Treat the byte as one character and keep going, which is
            // what `layoutLine` does with the same input.
            i += 1;
            continue;
        };
        if (cp == '\n') return .{ .end = i, .next = i + len };

        const w = advanceOf(font, cp, size, metrics);
        // `width > 0` keeps the line making progress: a single codepoint wider
        // than the whole line still gets a line of its own, rather than looping
        // for ever on a break that cannot be taken.
        if (max_width > 0 and width + w > max_width and width > 0) {
            if (last_space) |sp| {
                const sp_len = std.unicode.utf8ByteSequenceLength(text[sp]) catch 1;
                return .{ .end = sp, .next = sp + sp_len };
            }
            // No space to break at, so the word is longer than the line and is
            // broken between characters instead. Overflowing the box would hide
            // the text under whatever is drawn next to it.
            return .{ .end = i, .next = i };
        }
        width += w;
        if (cp == ' ') last_space = i;
        i += len;
    }
    return .{ .end = text.len, .next = text.len };
}

/// Lay out `text` as lines that each fit `max_width`, breaking at spaces where
/// there is one and between characters where there is not.
///
/// A `max_width` of zero or less does not wrap: only the line feeds in `text`
/// break it. That is the honest reading of "no width to fit into", and it is
/// what an unbounded constraint gives.
///
/// Line feeds always break, wrapped or not. Nothing else in the text is treated
/// as markup.
///
/// This lives here, beside `layoutLine`, because breaking has to agree with
/// measuring: it asks `advanceOf` the same question `layoutLine` asks per glyph,
/// including the wide-character rule under `.mono`. A caller that broke text
/// itself would own a second copy of that agreement.
pub fn layoutParagraph(
    gpa: std.mem.Allocator,
    font: *Font,
    text: []const u8,
    size: f32,
    metrics: mono.TextMetrics,
    max_width: f32,
) !Paragraph {
    var lines: std.ArrayList(Line) = .empty;
    errdefer {
        for (lines.items) |*l| l.deinit(gpa);
        lines.deinit(gpa);
    }

    var pos: usize = 0;
    while (true) {
        const b = nextBreak(font, text, pos, size, metrics, max_width);
        var line = try layoutLine(gpa, font, text[pos..b.end], size, metrics);
        errdefer line.deinit(gpa);
        try lines.append(gpa, line);
        if (b.next >= text.len) break;
        pos = b.next;
    }

    var width: f32 = 0;
    var height: f32 = 0;
    for (lines.items) |l| {
        width = @max(width, l.width);
        height += l.height;
    }
    return .{
        .lines = try lines.toOwnedSlice(gpa),
        .width = width,
        .height = height,
    };
}

test "text that fits stays on one line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abc", 14, m, 100);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqual(@as(f32, 30), p.width);
    try std.testing.expectEqual(@as(f32, 20), p.height);
}

test "a wrap breaks at a space, and the space does not begin the next line" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    // Ten pixel columns and a fifty pixel line: five columns fit.
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "ab cd", 14, m, 50);
    defer p.deinit(gpa);
    // "ab cd" is exactly five columns, so it fits on one line.
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);

    var q = try layoutParagraph(gpa, &font, "abc def", 14, m, 50);
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.lines.len);
    // Three glyphs on each line: the space between them belongs to neither, or
    // the second line would start with a blank column.
    try std.testing.expectEqual(@as(usize, 3), q.lines[0].glyphs.len);
    try std.testing.expectEqual(@as(usize, 3), q.lines[1].glyphs.len);
    try std.testing.expectEqual(@as(u21, 'd'), q.lines[1].glyphs[0].cp);
}

test "a word wider than the line breaks between characters instead of overflowing" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abcdefgh", 14, m, 30);
    defer p.deinit(gpa);
    // Three columns to a line, so eight characters need three lines. Letting it
    // overflow instead would hide the text under whatever is drawn beside it.
    try std.testing.expectEqual(@as(usize, 3), p.lines.len);
    for (p.lines) |l| try std.testing.expect(l.width <= 30);
}

test "no line is ever wider than the width it was given" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(9, 18) };
    const prose = "the quick brown fox jumps over the lazy dog and keeps going";
    for ([_]f32{ 27, 45, 90, 180 }) |w| {
        var p = try layoutParagraph(gpa, &font, prose, 14, m, w);
        defer p.deinit(gpa);
        for (p.lines) |l| try std.testing.expect(l.width <= w);
        try std.testing.expect(p.width <= w);
    }
}

test "a line feed breaks even where the text would have fitted" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "a\nb", 14, m, 1000);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqual(@as(u21, 'a'), p.lines[0].glyphs[0].cp);
    try std.testing.expectEqual(@as(u21, 'b'), p.lines[1].glyphs[0].cp);
}

test "a width of zero does not wrap, and only the line feeds break the text" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "a long line of words", 14, m, 0);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);

    var q = try layoutParagraph(gpa, &font, "one\ntwo", 14, m, 0);
    defer q.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), q.lines.len);
}

test "breaking counts a wide character as the two columns it will be drawn in" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    // Three wide glyphs are six columns. A sixty pixel line holds all three; a
    // fifty pixel line holds two. Counting them as one column each would put
    // all three on the short line and draw past its edge.
    var wide = try layoutParagraph(gpa, &font, "\u{4E00}\u{4E00}\u{4E00}", 14, m, 60);
    defer wide.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), wide.lines.len);

    var narrow = try layoutParagraph(gpa, &font, "\u{4E00}\u{4E00}\u{4E00}", 14, m, 50);
    defer narrow.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), narrow.lines.len);
    try std.testing.expectEqual(@as(usize, 2), narrow.lines[0].glyphs.len);
}

test "a paragraph is as tall as its lines together and as wide as its widest" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "abc de", 14, m, 30);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), p.lines.len);
    try std.testing.expectEqual(@as(f32, 40), p.height);
    // The widest line, not the sum and not the last one.
    var widest: f32 = 0;
    for (p.lines) |l| widest = @max(widest, l.width);
    try std.testing.expectEqual(widest, p.width);
}

test "empty text is one empty line, so it occupies a row like any other" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const m = mono.TextMetrics{ .mono = mono.Mono.fromCell(10, 20) };
    var p = try layoutParagraph(gpa, &font, "", 14, m, 100);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), p.lines.len);
    try std.testing.expectEqual(@as(usize, 0), p.lines[0].glyphs.len);
    try std.testing.expectEqual(@as(f32, 20), p.height);
}

test "proportional wrapping measures with the font, not with a fixed column" {
    const gpa = std.testing.allocator;
    var font = try Font.load(gpa, builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const prose = "wrapping measured against the real advances of the face";
    const width: f32 = 200;
    var p = try layoutParagraph(gpa, &font, prose, 16, .proportional, width);
    defer p.deinit(gpa);
    try std.testing.expect(p.lines.len > 1);
    for (p.lines) |l| try std.testing.expect(l.width <= width);
}
