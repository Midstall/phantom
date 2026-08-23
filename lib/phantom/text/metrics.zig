//! sfnt table metrics (head/hhea/maxp/hmtx/cmap). File-as-struct; use parse()
//! to construct. All integer fields are already host-endian after parsing.
const std = @import("std");
const Sfnt = @import("sfnt.zig");
const Metrics = @This();

// -- scalar fields parsed from head / hhea / maxp --
units_per_em: u16,
index_to_loc_format: i16,
ascent: i16,
descent: i16,
line_gap: i16,
num_glyphs: u16,
num_h_metrics: u16,

// OS/2, with a head.macStyle fallback. A font with neither reports the normal
// weight, because a missing table is not evidence of a bold font.
weight_class: u16,
italic: bool,

// -- raw table slices kept for lookup --
hmtx: []const u8,
cmap: []const u8,

// -- format-4 array offsets (byte offsets into `cmap`) --
seg_count: usize,
end_off: usize,
start_off: usize,
delta_off: usize,
range_off: usize,

pub fn parse(sfnt: Sfnt) !Metrics {
    // head
    const head = sfnt.table("head") orelse return error.MissingHead;
    if (head.len < 54) return error.InvalidHead;
    const units_per_em = Sfnt.u16be(head, 18);
    const index_to_loc_format = Sfnt.i16be(head, 50);

    // head.macStyle bit 0 is bold and bit 1 is italic. It is inside the 54 bytes
    // this function already requires, so it costs no new bounds check.
    const mac_style = Sfnt.u16be(head, 44);
    const mac_bold = (mac_style & 0x0001) != 0;
    const mac_italic = (mac_style & 0x0002) != 0;

    // OS/2 is the better source when it is present. usWeightClass is at offset 4 and
    // fsSelection is at offset 62. Bit 0 of fsSelection is italic and bit 5 is bold.
    var weight_class: u16 = if (mac_bold) 700 else 400;
    var italic: bool = mac_italic;
    if (sfnt.table("OS/2")) |os2| {
        if (os2.len >= 64) {
            const raw_weight = Sfnt.u16be(os2, 4);
            // A malformed font may report zero or an absurd value. This is untrusted
            // input from a file, so clamp instead of trusting it.
            if (raw_weight >= 1 and raw_weight <= 1000) weight_class = raw_weight;
            const fs_selection = Sfnt.u16be(os2, 62);
            italic = (fs_selection & 0x0001) != 0;
            if ((fs_selection & 0x0020) != 0 and weight_class < 600) weight_class = 700;
        }
    }

    // hhea
    const hhea = sfnt.table("hhea") orelse return error.MissingHhea;
    if (hhea.len < 36) return error.InvalidHhea;
    const ascent = Sfnt.i16be(hhea, 4);
    const descent = Sfnt.i16be(hhea, 6);
    const line_gap = Sfnt.i16be(hhea, 8);
    const num_h_metrics = Sfnt.u16be(hhea, 34);
    // The spec requires at least one hmetric. Reject 0 so advanceWidth's
    // (num_h_metrics - 1) tail index cannot underflow and panic on a bad font.
    if (num_h_metrics == 0) return error.InvalidHhea;

    // maxp
    const maxp = sfnt.table("maxp") orelse return error.MissingMaxp;
    if (maxp.len < 6) return error.InvalidMaxp;
    const num_glyphs = Sfnt.u16be(maxp, 4);

    // hmtx
    const hmtx = sfnt.table("hmtx") orelse return error.MissingHmtx;
    const needed_hmtx = @as(usize, num_h_metrics) * 4;
    if (hmtx.len < needed_hmtx) return error.InvalidHmtx;

    // cmap: scan encoding records for a Unicode subtable (platform 3 enc 1 or platform 0)
    const cmap_tbl = sfnt.table("cmap") orelse return error.MissingCmap;
    if (cmap_tbl.len < 4) return error.InvalidCmap;
    const num_enc = Sfnt.u16be(cmap_tbl, 2);

    var chosen_off: ?u32 = null;
    var i: usize = 0;
    while (i < num_enc) : (i += 1) {
        const rec = 4 + i * 8;
        if (rec + 8 > cmap_tbl.len) break;
        const platform = Sfnt.u16be(cmap_tbl, rec);
        const encoding = Sfnt.u16be(cmap_tbl, rec + 2);
        const sub_off = Sfnt.u32be(cmap_tbl, rec + 4);
        // Prefer platform 3 encoding 1 (Windows Unicode BMP); also accept platform 0 (Unicode).
        if (platform == 3 and encoding == 1) {
            chosen_off = sub_off;
            break;
        }
        if (platform == 0 and chosen_off == null) {
            chosen_off = sub_off;
        }
    }

    const coff = chosen_off orelse return error.NoUnicodeCmap;
    if (@as(usize, coff) + 2 > cmap_tbl.len) return error.InvalidCmap;
    const fmt = Sfnt.u16be(cmap_tbl, coff);
    if (fmt != 4) return error.NoUnicodeCmap;

    // format-4 layout (all offsets relative to start of cmap table)
    // +6: segCountX2, +14: endCode[segCount], then 2 reserved bytes, startCode[], idDelta[], idRangeOffset[]
    if (@as(usize, coff) + 8 > cmap_tbl.len) return error.InvalidCmap;
    const seg_count_x2 = Sfnt.u16be(cmap_tbl, coff + 6);
    const seg_count: usize = seg_count_x2 / 2;

    const end_off: usize = coff + 14;
    const start_off: usize = end_off + seg_count * 2 + 2; // +2 for reservedPad
    const delta_off: usize = start_off + seg_count * 2;
    const range_off: usize = delta_off + seg_count * 2;

    if (range_off + seg_count * 2 > cmap_tbl.len) return error.InvalidCmap;

    return .{
        .units_per_em = units_per_em,
        .index_to_loc_format = index_to_loc_format,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .num_glyphs = num_glyphs,
        .num_h_metrics = num_h_metrics,
        .weight_class = weight_class,
        .italic = italic,
        .hmtx = hmtx,
        .cmap = cmap_tbl,
        .seg_count = seg_count,
        .end_off = end_off,
        .start_off = start_off,
        .delta_off = delta_off,
        .range_off = range_off,
    };
}

pub fn advanceWidth(self: Metrics, glyph: u16) u16 {
    const g = @as(usize, glyph);
    if (g < self.num_h_metrics) {
        return Sfnt.u16be(self.hmtx, g * 4);
    }
    // monospaced tail: last record holds the advance for all remaining glyphs
    return Sfnt.u16be(self.hmtx, (@as(usize, self.num_h_metrics) - 1) * 4);
}

pub fn glyphIndex(self: Metrics, cp: u21) u16 {
    if (cp > 0xFFFF) return 0; // format 4 is BMP-only
    const c: u16 = @intCast(cp);
    const seg = self.seg_count;
    var idx: usize = 0;
    while (idx < seg) : (idx += 1) {
        const end = Sfnt.u16be(self.cmap, self.end_off + idx * 2);
        if (c <= end) {
            const start = Sfnt.u16be(self.cmap, self.start_off + idx * 2);
            if (c < start) return 0;
            const id_range = Sfnt.u16be(self.cmap, self.range_off + idx * 2);
            if (id_range == 0) {
                const delta = Sfnt.u16be(self.cmap, self.delta_off + idx * 2);
                return c +% delta;
            } else {
                // glyphIdArray index per the format-4 spec
                const gi_off = self.range_off + idx * 2 + id_range + (c - start) * 2;
                if (gi_off + 2 > self.cmap.len) return 0;
                const g = Sfnt.u16be(self.cmap, gi_off);
                if (g == 0) return 0;
                const delta = Sfnt.u16be(self.cmap, self.delta_off + idx * 2);
                return g +% delta;
            }
        }
    }
    return 0;
}

const builtin = @import("builtin.zig");

test "Neuropol metrics: unitsPerEm, cmap A, advance of digit 0" {
    const s = try Sfnt.parse(builtin.neuropol_bytes);
    const m = try Metrics.parse(s);
    try std.testing.expect(m.units_per_em >= 16 and m.units_per_em <= 16384);
    const a = m.glyphIndex('A');
    try std.testing.expect(a != 0);
    try std.testing.expect(m.advanceWidth(m.glyphIndex('0')) > 0);
    try std.testing.expect(m.ascent > 0 and m.descent < 0);
}

// -- synthetic sfnt bytes for the OS/2-fallback tests --
//
// All three bundled fonts (Neuropol, Mesmerize Rg, Mesmerize Sb) carry an OS/2
// table, so no bundled font exercises the head.macStyle-only fallback path.
// This builder makes a minimal sfnt with head, hhea, maxp, hmtx and cmap, and
// no OS/2 table, so the fallback path itself gets real coverage.
fn buildFontWithoutOs2(mac_style: u16) [228]u8 {
    var buf = [_]u8{0} ** 228;

    std.mem.writeInt(u32, buf[0..4], 0x00010000, .big); // sfntVersion
    std.mem.writeInt(u16, buf[4..6], 5, .big); // numTables

    const Rec = struct { tag: *const [4]u8, off: u32, len: u32 };
    const recs = [_]Rec{
        .{ .tag = "head", .off = 92, .len = 54 },
        .{ .tag = "hhea", .off = 146, .len = 36 },
        .{ .tag = "maxp", .off = 182, .len = 6 },
        .{ .tag = "hmtx", .off = 188, .len = 4 },
        .{ .tag = "cmap", .off = 192, .len = 36 },
    };
    for (recs, 0..) |r, i| {
        const rec_off = 12 + i * 16;
        @memcpy(buf[rec_off .. rec_off + 4], r.tag);
        std.mem.writeInt(u32, buf[rec_off + 8 ..][0..4], r.off, .big);
        std.mem.writeInt(u32, buf[rec_off + 12 ..][0..4], r.len, .big);
    }

    // head, at byte 92: unitsPerEm at +18, macStyle at +44.
    std.mem.writeInt(u16, buf[92 + 18 ..][0..2], 1000, .big);
    std.mem.writeInt(u16, buf[92 + 44 ..][0..2], mac_style, .big);

    // hhea, at byte 146: ascent +4, descent +6, numHMetrics +34.
    std.mem.writeInt(i16, buf[146 + 4 ..][0..2], 800, .big);
    std.mem.writeInt(i16, buf[146 + 6 ..][0..2], -200, .big);
    std.mem.writeInt(u16, buf[146 + 34 ..][0..2], 1, .big);

    // maxp, at byte 182: numGlyphs +4.
    std.mem.writeInt(u16, buf[182 + 4 ..][0..2], 1, .big);

    // hmtx, at byte 188: one hMetric record, advanceWidth 500.
    std.mem.writeInt(u16, buf[188..][0..2], 500, .big);

    // cmap, at byte 192: one encoding record (platform 3, encoding 1) pointing
    // at a format-4 subtable with a single terminal segment (0xFFFF..0xFFFF),
    // the minimum a format-4 cmap can be.
    const c = 192;
    std.mem.writeInt(u16, buf[c + 2 ..][0..2], 1, .big); // numTables
    std.mem.writeInt(u16, buf[c + 4 ..][0..2], 3, .big); // platformID
    std.mem.writeInt(u16, buf[c + 6 ..][0..2], 1, .big); // encodingID
    std.mem.writeInt(u32, buf[c + 8 ..][0..4], 12, .big); // subtable offset
    std.mem.writeInt(u16, buf[c + 12 ..][0..2], 4, .big); // format
    std.mem.writeInt(u16, buf[c + 18 ..][0..2], 2, .big); // segCountX2
    std.mem.writeInt(u16, buf[c + 26 ..][0..2], 0xFFFF, .big); // endCode[0]
    std.mem.writeInt(u16, buf[c + 30 ..][0..2], 0xFFFF, .big); // startCode[0]
    std.mem.writeInt(u16, buf[c + 32 ..][0..2], 1, .big); // idDelta[0]
    // idRangeOffset[0] stays 0.

    return buf;
}

test "a font with no OS/2 table and a plain macStyle reports normal weight" {
    // The fallback must not lie: a missing OS/2 table plus a macStyle with no
    // bold bit must report 400 (normal), never 0.
    const bytes = buildFontWithoutOs2(0x0000);
    const s = try Sfnt.parse(&bytes);
    try std.testing.expect(s.table("OS/2") == null);
    const m = try Metrics.parse(s);
    try std.testing.expectEqual(@as(u16, 400), m.weight_class);
    try std.testing.expect(!m.italic);
}

test "a font with no OS/2 table and a bold macStyle falls back to bold weight" {
    const bytes = buildFontWithoutOs2(0x0001); // bit 0 of macStyle is bold
    const s = try Sfnt.parse(&bytes);
    const m = try Metrics.parse(s);
    try std.testing.expectEqual(@as(u16, 700), m.weight_class);
    try std.testing.expect(!m.italic);
}

test "a font with no OS/2 table and an italic macStyle reports slant" {
    const bytes = buildFontWithoutOs2(0x0002); // bit 1 of macStyle is italic
    const s = try Sfnt.parse(&bytes);
    const m = try Metrics.parse(s);
    try std.testing.expectEqual(@as(u16, 400), m.weight_class);
    try std.testing.expect(m.italic);
}
