const std = @import("std");
const Sfnt = @This();

bytes: []const u8,
num_tables: u16,
table_dir_off: usize, // offset of the first 16-byte table record

pub fn u16be(b: []const u8, off: usize) u16 {
    return (@as(u16, b[off]) << 8) | b[off + 1];
}
pub fn i16be(b: []const u8, off: usize) i16 {
    return @bitCast(u16be(b, off));
}
pub fn u32be(b: []const u8, off: usize) u32 {
    return (@as(u32, b[off]) << 24) | (@as(u32, b[off + 1]) << 16) | (@as(u32, b[off + 2]) << 8) | b[off + 3];
}

pub fn parse(bytes: []const u8) !Sfnt {
    if (bytes.len < 12) return error.InvalidFont;
    const ver = u32be(bytes, 0);
    // 0x00010000 = TrueType, 'OTTO' = CFF, 'true'/'ttcf' handled minimally.
    if (ver != 0x00010000 and ver != 0x4F54544F and ver != 0x74727565) return error.UnsupportedSfnt;
    const num = u16be(bytes, 4);
    const dir_off: usize = 12;
    if (bytes.len < dir_off + @as(usize, num) * 16) return error.InvalidFont;
    return .{ .bytes = bytes, .num_tables = num, .table_dir_off = dir_off };
}

pub fn table(self: Sfnt, tag: *const [4]u8) ?[]const u8 {
    var i: usize = 0;
    while (i < self.num_tables) : (i += 1) {
        const rec = self.table_dir_off + i * 16;
        if (std.mem.eql(u8, self.bytes[rec .. rec + 4], tag)) {
            const off = u32be(self.bytes, rec + 8);
            const len = u32be(self.bytes, rec + 12);
            // Widen to usize before adding so a crafted font with a near-u32-max
            // offset cannot wrap the sum and slip past the bounds check.
            if (@as(usize, off) + @as(usize, len) > self.bytes.len) return null;
            return self.bytes[off .. off + len];
        }
    }
    return null;
}

pub const OutlineFormat = enum { glyf, cff };

pub fn outlineFormat(self: Sfnt) ?OutlineFormat {
    if (self.table("glyf") != null) return .glyf;
    if (self.table("CFF ") != null) return .cff;
    return null;
}

const builtin = @import("builtin.zig");

test "parse Neuropol sfnt: finds CFF/cmap/head and reports cff format" {
    const s = try Sfnt.parse(builtin.neuropol_bytes);
    try std.testing.expect(s.table("CFF ") != null);
    try std.testing.expect(s.table("cmap") != null);
    try std.testing.expect(s.table("head") != null);
    try std.testing.expect(s.table("glyf") == null);
    try std.testing.expectEqual(OutlineFormat.cff, s.outlineFormat().?);
}
