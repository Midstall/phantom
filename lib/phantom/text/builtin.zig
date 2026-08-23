//! The vendored built-in branding fonts, embedded at build time.
//! Raw byte slices are exposed for direct use by lower-level text tasks.
//! Convenience loaders (neuropol, mesmerize_rg, mesmerize_sb) return a fully
//! parsed Font ready for glyph rasterization.
const std = @import("std");
const Font = @import("Font.zig");

pub const neuropol_bytes: []const u8 = @embedFile("fonts/Neuropol.otf");
pub const mesmerize_rg_bytes: []const u8 = @embedFile("fonts/Mesmerize Rg.otf");
pub const mesmerize_sb_bytes: []const u8 = @embedFile("fonts/Mesmerize Sb.otf");

/// Load Neuropol as a Font. Caller must call deinit(gpa) when done.
pub fn neuropol(gpa: std.mem.Allocator) !Font {
    return Font.load(gpa, neuropol_bytes);
}

/// Load Mesmerize Regular as a Font. Caller must call deinit(gpa) when done.
pub fn mesmerize_rg(gpa: std.mem.Allocator) !Font {
    return Font.load(gpa, mesmerize_rg_bytes);
}

/// Load Mesmerize SemiBold as a Font. Caller must call deinit(gpa) when done.
pub fn mesmerize_sb(gpa: std.mem.Allocator) !Font {
    return Font.load(gpa, mesmerize_sb_bytes);
}

test "built-in fonts embed non-empty and start with the OTTO sfnt tag" {
    for ([_][]const u8{ neuropol_bytes, mesmerize_rg_bytes, mesmerize_sb_bytes }) |b| {
        try std.testing.expect(b.len > 1000);
        // CFF OpenType sfnt version is 'OTTO' (0x4F54544F).
        try std.testing.expectEqualSlices(u8, "OTTO", b[0..4]);
    }
}
