//! High-level Font API. Parses an sfnt/OTF byte slice, dispatches glyph
//! outlines via either the TrueType glyf reader or the CFF interpreter,
//! rasterizes to Coverage bitmaps, and caches results by (size, codepoint).
//! File-as-struct pattern.
const std = @import("std");
const Sfnt = @import("sfnt.zig");
const Metrics = @import("metrics.zig");
const glyf_mod = @import("glyf.zig");
const Loca = glyf_mod.Loca;
const outline_mod = @import("outline.zig");
const Outline = outline_mod.Outline;
const Cff = @import("cff.zig");
const raster = @import("raster.zig");
const Coverage = raster.Coverage;
const GlyphCache = @import("GlyphCache.zig");

const Font = @This();

bytes: []const u8,
sfnt: Sfnt,
metrics: Metrics,
format: Sfnt.OutlineFormat,
cff: ?Cff,
cache: GlyphCache,

/// Parse the font bytes and return an initialized Font.
/// Caller owns the bytes slice (Font does not copy it).
pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Font {
    const sfnt = try Sfnt.parse(bytes);
    const metrics = try Metrics.parse(sfnt);
    const fmt = sfnt.outlineFormat() orelse return error.NoOutlineTable;

    var cff_val: ?Cff = null;
    if (fmt == .cff) {
        const cff_table = sfnt.table("CFF ") orelse return error.MissingCff;
        cff_val = try Cff.parse(gpa, cff_table);
    }

    return .{
        .bytes = bytes,
        .sfnt = sfnt,
        .metrics = metrics,
        .format = fmt,
        .cff = cff_val,
        .cache = .{},
    };
}

pub fn deinit(self: *Font, gpa: std.mem.Allocator) void {
    self.cache.deinit(gpa);
    if (self.cff) |*c| {
        c.deinit(gpa);
    }
    self.* = undefined;
}

/// Return the units-per-em value from the head table.
pub fn unitsPerEm(self: *const Font) u16 {
    return self.metrics.units_per_em;
}

/// The OS/2 weight class, 1 to 1000. 400 is normal and 700 is bold. The cell
/// renderer treats 600 and above as bold, because that is where semibold starts.
pub fn weight(self: *const Font) u16 {
    return self.metrics.weight_class;
}

pub fn isItalic(self: *const Font) bool {
    return self.metrics.italic;
}

/// Return the typographic ascent in font units.
pub fn ascent(self: *const Font) i16 {
    return self.metrics.ascent;
}

/// Return the typographic descent in font units (negative).
pub fn descent(self: *const Font) i16 {
    return self.metrics.descent;
}

/// Whether this face can draw `cp` at all.
///
/// Glyph 0 is the `.notdef` box every face reserves for a codepoint it does not
/// cover, so a face that "draws" it draws a replacement box. The bundled faces
/// are display faces and cover little outside ASCII, which is what makes this
/// worth asking: see `backend/prism.zig`, which substitutes a built-in mark
/// rather than blit the box.
pub fn hasGlyph(self: *const Font, cp: u21) bool {
    return self.metrics.glyphIndex(cp) != 0;
}

/// Horizontal advance of `cp` at `px_size` pixels (device space). Metrics only,
/// no rasterization, no allocation.
pub fn advance(self: *const Font, cp: u21, px_size: f32) f32 {
    const gidx = self.metrics.glyphIndex(cp);
    const adv_units: f32 = @floatFromInt(self.metrics.advanceWidth(gidx));
    return adv_units * px_size / @as(f32, @floatFromInt(self.metrics.units_per_em));
}

/// The height of one line of this font at `px_size`, in those same pixels.
///
/// Ascent above the baseline plus descent below it. This is the LINE BOX, the
/// thing a caller needs to know how many rows fit in a height, and it is not the
/// point size: a 24px font does not occupy 24px of vertical space.
///
/// `line_gap` is deliberately left out. The gap is leading BETWEEN lines rather
/// than part of a line's own box, and `layout.layoutLine` has always measured a
/// run as ascent minus descent, so including it here would make this disagree
/// with the only other place phantom computes the same quantity. There is one
/// definition, and `layoutLine` calls this one.
///
/// Public because a caller that fits text to a row of a FIXED height, a terminal
/// cell being the case that forced this, otherwise has to recompute
/// `(ascent - descent) * size / units_per_em` from the raw fields, which is
/// phantom's own internal sum written out a second time in somebody else's code.
pub fn lineHeight(self: *const Font, px_size: f32) f32 {
    const units: f32 = @floatFromInt(@as(i32, self.metrics.ascent) - @as(i32, self.metrics.descent));
    return units * px_size / @as(f32, @floatFromInt(self.metrics.units_per_em));
}

/// The `px_size` whose line box is exactly `line_px` tall: the inverse of
/// `lineHeight`.
///
/// For fitting text to a row whose height is already decided. The terminal's
/// pixel mode sizes its default text with this so one line of text occupies one
/// terminal cell, which is what makes an 80x24 terminal show 24 rows of text
/// rather than the 13 a fixed point size gave.
///
/// Returns 0 for a font whose ascent and descent are equal, which is a font with
/// no vertical extent at all: there is no size that makes a zero-height line box
/// reach `line_px`, and 0 is the answer that draws nothing rather than one that
/// divides by zero.
pub fn sizeForLineHeight(self: *const Font, line_px: f32) f32 {
    const units: f32 = @floatFromInt(@as(i32, self.metrics.ascent) - @as(i32, self.metrics.descent));
    if (units <= 0) return 0;
    return line_px * @as(f32, @floatFromInt(self.metrics.units_per_em)) / units;
}

/// Return a rasterized glyph Coverage for codepoint `cp` at `px_size` pixels.
/// Results are cached; subsequent calls with the same (cp, px_size) return the
/// same pointer without re-rasterizing.
pub fn glyph(self: *Font, gpa: std.mem.Allocator, cp: u21, px_size: f32) !*const Coverage {
    const key = GlyphCache.Key{
        .size_bits = @bitCast(px_size),
        .cp = cp,
    };

    if (self.cache.get(key)) |cached| {
        return cached;
    }

    // Resolve codepoint to glyph index.
    const gidx = self.metrics.glyphIndex(cp);

    // Build the outline in font units.
    var outline = Outline{};
    defer outline.deinit(gpa);

    switch (self.format) {
        .cff => {
            try self.cff.?.outline(gpa, gidx, &outline);
        },
        .glyf => {
            const loca_data = self.sfnt.table("loca") orelse return error.MissingLoca;
            const loca = Loca{
                .data = loca_data,
                .index_to_loc_format = self.metrics.index_to_loc_format,
            };
            const glyf_data = self.sfnt.table("glyf") orelse return error.MissingGlyf;
            try glyf_mod.readGlyph(gpa, glyf_data, loca, gidx, &outline);
        },
    }

    // Rasterize outline into a Coverage bitmap.
    const advance_units = self.metrics.advanceWidth(gidx);
    var cov = try raster.rasterize(
        gpa,
        outline,
        self.metrics.units_per_em,
        px_size,
        advance_units,
    );
    // If cache.put fails (OOM boxing or map grow), free the pixels here so
    // they do not leak. cache.put's own errdefer handles the box it allocated,
    // so this covers only the window before ownership transfers.
    errdefer cov.deinit(gpa);

    // Store in cache (takes ownership of cov.pixels via boxing) and return a
    // stable heap pointer. The errdefer above is superseded once put succeeds.
    try self.cache.put(gpa, key, cov);
    return self.cache.get(key).?;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const builtin_fonts = @import("builtin.zig");

test "Font.load(Neuropol).glyph('A',48) rasterizes and caches" {
    const gpa = std.testing.allocator;
    var f = try Font.load(gpa, builtin_fonts.neuropol_bytes);
    defer f.deinit(gpa);
    const g1 = try f.glyph(gpa, 'A', 48);
    try std.testing.expect(g1.w > 0 and g1.h > 0);
    try std.testing.expect(g1.pixels.len == g1.w * g1.h);
    const g2 = try f.glyph(gpa, 'A', 48);
    try std.testing.expect(g1 == g2); // cache hit returns the same pointer
    try std.testing.expect(g1.advance > 0);
}

test "Font.glyph pointer stable across cache rehash" {
    // This test proves Fix 1 (boxing). It:
    //   1. Rasterizes 'A' and saves the pointer + w/h.
    //   2. Inserts many distinct (codepoint, size) pairs so the underlying
    //      AutoHashMapUnmanaged grows and rehashes at least once (the default
    //      load-factor threshold is 0.75; inserting 35+ entries from a cold
    //      map guarantees multiple doubling steps).
    //   3. Re-reads the saved pointer's w/h and asserts they still match.
    //
    // Under the old by-value map, cache.put could move every stored Coverage
    // during a rehash, dangling the pointer returned by the earlier get().
    // Reading it would return garbage (or trip the testing allocator's
    // freed-memory detection). With boxing the Coverage lives on the heap and
    // only the map's internal pointer slot moves, so the pointer stays valid.
    const gpa = std.testing.allocator;
    var f = try Font.load(gpa, builtin_fonts.neuropol_bytes);
    defer f.deinit(gpa);

    const a_ptr = try f.glyph(gpa, 'A', 48);
    const saved_w = a_ptr.w;
    const saved_h = a_ptr.h;
    try std.testing.expect(saved_w > 0 and saved_h > 0);

    // Force multiple rehash rounds by inserting many distinct codepoints at
    // a slightly different size so none of them collide with the 'A' entry.
    var cp: u21 = 'B';
    while (cp <= 'Z') : (cp += 1) {
        _ = try f.glyph(gpa, cp, 48);
    }
    cp = '0';
    while (cp <= '9') : (cp += 1) {
        _ = try f.glyph(gpa, cp, 48);
    }

    // The 'A' pointer must still point to the same valid Coverage.
    try std.testing.expectEqual(saved_w, a_ptr.w);
    try std.testing.expectEqual(saved_h, a_ptr.h);
}

test "the regular body font reports a normal weight and no slant" {
    const gpa = std.testing.allocator;
    var font = try load(gpa, @import("builtin.zig").mesmerize_rg_bytes);
    defer font.deinit(gpa);
    try std.testing.expect(font.weight() < 600);
    try std.testing.expect(!font.isItalic());
}

test "the semibold font reports a heavier weight than the regular font" {
    const gpa = std.testing.allocator;
    const bi = @import("builtin.zig");
    var regular = try load(gpa, bi.mesmerize_rg_bytes);
    defer regular.deinit(gpa);
    var semibold = try load(gpa, bi.mesmerize_sb_bytes);
    defer semibold.deinit(gpa);
    try std.testing.expect(semibold.weight() > regular.weight());
}

test "a bundled font's weight always falls in the valid OS/2 usWeightClass range" {
    // All three bundled fonts carry an OS/2 table (Neuropol included), so this
    // does not exercise the no-OS/2 fallback path; `metrics.zig`'s
    // `buildFontWithoutOs2` covers that with a synthetic sfnt, in the tests
    // grouped around it. This only checks that a real font's reported weight
    // never leaves the range the cell renderer trusts it to be in: the renderer
    // compares the value against 600, and a zero would silently mean "not bold".
    const gpa = std.testing.allocator;
    var font = try load(gpa, @import("builtin.zig").neuropol_bytes);
    defer font.deinit(gpa);
    try std.testing.expect(font.weight() >= 100 and font.weight() <= 1000);
}

test "lineHeight is the ascent-to-descent box, and scales with the size" {
    const gpa = std.testing.allocator;
    var f = try @import("builtin.zig").mesmerize_rg(gpa);
    defer f.deinit(gpa);

    const at16 = f.lineHeight(16);
    const at32 = f.lineHeight(32);
    try std.testing.expect(at16 > 0);
    // Linear in the size, so twice the size is twice the box.
    try std.testing.expectApproxEqRel(at16 * 2, at32, 0.0001);
    // And it is NOT the point size: a line box is taller than the em it names,
    // which is the whole reason a caller cannot use the size as a row height.
    try std.testing.expect(at16 > 16);
}

test "sizeForLineHeight inverts lineHeight, so text can be fitted to a fixed row" {
    const gpa = std.testing.allocator;
    var f = try @import("builtin.zig").mesmerize_rg(gpa);
    defer f.deinit(gpa);

    for ([_]f32{ 8, 16, 18, 37, 100 }) |row| {
        const size = f.sizeForLineHeight(row);
        try std.testing.expectApproxEqRel(row, f.lineHeight(size), 0.0001);
    }
}

test "a run's measured height is the same number lineHeight reports" {
    const gpa = std.testing.allocator;
    var f = try @import("builtin.zig").mesmerize_rg(gpa);
    defer f.deinit(gpa);

    // The two must agree or fitting text to a row would be arithmetic about a
    // box that layout then ignores.
    var line = try @import("layout.zig").layoutLine(gpa, &f, "Taps: 0", 24, .proportional);
    defer line.deinit(gpa);
    try std.testing.expectApproxEqRel(f.lineHeight(24), line.height, 0.0001);
}
