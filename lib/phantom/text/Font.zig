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

/// Horizontal advance of `cp` at `px_size` pixels (device space). Metrics only,
/// no rasterization, no allocation.
pub fn advance(self: *const Font, cp: u21, px_size: f32) f32 {
    const gidx = self.metrics.glyphIndex(cp);
    const adv_units: f32 = @floatFromInt(self.metrics.advanceWidth(gidx));
    return adv_units * px_size / @as(f32, @floatFromInt(self.metrics.units_per_em));
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
