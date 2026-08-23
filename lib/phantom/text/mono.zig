//! Monospace text metrics for the cell renderer. A character grid gives every
//! column the same width, so the proportional advances of a real font do not apply.
//! This module supplies the replacement metrics and the column count of one
//! codepoint.
//!
//! Limitation: the column count is per codepoint and follows the East Asian Width
//! property. It is not grapheme cluster segmentation, so a sequence joined with a
//! zero width joiner, for example an emoji family, reports the sum of its parts and
//! not the one column pair the terminal draws.

const std = @import("std");

/// The wide and zero width codepoint tables. Kept in their own file, see
/// `mono/tables.zig`, because they are close to 500 lines of generated data,
/// and a person reading the logic in this file should not have to scroll
/// past them to find it.
const tables = @import("mono/tables.zig");

/// Confirms a range table is sorted by start and has no internal overlap, so
/// bisection over it never returns a wrong answer. A table that fails this
/// check must not compile: a silent wrong answer at runtime is worse than a
/// build break.
fn assertSorted(comptime ranges: []const [2]u21) void {
    comptime {
        for (ranges, 0..) |range, i| {
            if (range[0] > range[1]) {
                @compileError("range out of order (start after end)");
            }
            if (i > 0 and ranges[i - 1][1] >= range[0]) {
                @compileError("ranges not sorted or overlapping");
            }
        }
    }
}

comptime {
    assertSorted(&tables.wide_ranges);
    assertSorted(&tables.zero_ranges);
}

fn inRanges(cp: u21, ranges: []const [2]u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// The number of columns one codepoint occupies: 0, 1 or 2.
pub fn wcwidth(cp: u21) u2 {
    // A control character has no printed form. The writer never emits one, so it
    // must not reserve a column either.
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (inRanges(cp, &tables.zero_ranges)) return 0;
    if (inRanges(cp, &tables.wide_ranges)) return 2;
    return 1;
}

/// The metrics that replace a font's proportional metrics in the cell renderer.
pub const Mono = struct {
    advance: f32,
    line: f32,
    ascent: f32,

    pub fn fromCell(cell_w: f32, cell_h: f32) Mono {
        return .{
            .advance = cell_w,
            .line = cell_h,
            // The exact baseline does not change any cell, because the writer places
            // text by the top of the run. The value keeps the line box sane for the
            // layout code that reads it.
            .ascent = cell_h * 0.8,
        };
    }
};

/// How text measures. `proportional` is the font's own advances and is what the GPU
/// backend and the web backend use. `mono` is the cell grid.
pub const TextMetrics = union(enum) {
    proportional,
    mono: Mono,
};

test "the wide and zero range tables are sorted with no overlap" {
    // assertSorted runs at comptime on module load. A regression here fails the
    // build rather than this test, but the test documents the invariant and
    // gives a named place for a filtered run to find it.
    comptime assertSorted(&tables.wide_ranges);
    comptime assertSorted(&tables.zero_ranges);
}

test "wcwidth gives one column to plain ASCII" {
    try std.testing.expectEqual(@as(u2, 1), wcwidth('A'));
    try std.testing.expectEqual(@as(u2, 1), wcwidth(' '));
    try std.testing.expectEqual(@as(u2, 1), wcwidth('~'));
}

test "wcwidth gives two columns to CJK and to fullwidth forms" {
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{4E00}')); // CJK unified
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{3042}')); // hiragana A
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{FF21}')); // fullwidth A
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{AC00}')); // hangul syllable
}

test "wcwidth gives zero columns to combining marks and to control characters" {
    try std.testing.expectEqual(@as(u2, 0), wcwidth('\u{0301}')); // combining acute
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x00));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x1B));
}

test "wcwidth gives two columns to the common emoji blocks" {
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{1F600}'));
    try std.testing.expectEqual(@as(u2, 2), wcwidth('\u{1F680}'));
}

test "the kana voiced sound marks are combining and take no column" {
    // They sit inside the wide kana range, so they only measure correctly because
    // zero_ranges is consulted first. A reordering of wcwidth would break them.
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x3099));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x309A));
}

test "a codepoint in both tables is zero width, because combining wins over wide" {
    // 0x3099 is inside wide_ranges and inside zero_ranges. Zero must win.
    try std.testing.expect(inRanges(0x3099, &tables.wide_ranges));
    try std.testing.expect(inRanges(0x3099, &tables.zero_ranges));
    try std.testing.expectEqual(@as(u2, 0), wcwidth(0x3099));
}

test "wcwidth boundaries: the edges of an isolated wide pair are wide and the neighbors are not" {
    // The watch/hourglass pair sits alone between two Neutral codepoints in the real
    // data (2313..2319 is N, 231A..231B is W, 231C..231F is N), so it gives a clean
    // edge check that does not depend on a neighboring block also being wide.
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x231A)); // first of the pair
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x231B)); // last of the pair
    try std.testing.expectEqual(@as(u2, 1), wcwidth(0x2319)); // one before the pair
    try std.testing.expectEqual(@as(u2, 1), wcwidth(0x231C)); // one after the pair
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x4E00)); // interior: CJK unified, first
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x9FFF)); // interior: CJK unified, last
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0xA000)); // first of the yi syllables
}

test "wcwidth gives two columns to ordinary status glyphs used in command line output" {
    // These sit in narrow, easy to miss single-codepoint entries rather than a large
    // named block, so a table edit that drops one silently narrows real output.
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x2705)); // white heavy check mark
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x274C)); // cross mark
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x2B50)); // white medium star
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x231A)); // watch
    try std.testing.expectEqual(@as(u2, 2), wcwidth(0x23F0)); // alarm clock
}

test "Mono.fromCell derives the advance, the line and the ascent from the cell size" {
    const m = Mono.fromCell(9, 18);
    try std.testing.expectEqual(@as(f32, 9), m.advance);
    try std.testing.expectEqual(@as(f32, 18), m.line);
    // The ascent places the baseline inside the row. Nothing in mode B reads it, but
    // layout uses it for the line box. Pin the 0.8 constant so a change to it shows
    // up here rather than only in a downstream layout test. Approximate equality
    // absorbs the rounding difference between the f32 multiply and the f32 parse
    // of the literal. It does not absorb a change to the constant.
    try std.testing.expectApproxEqAbs(@as(f32, 14.4), m.ascent, 0.001);
}
