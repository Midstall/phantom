//! Prism coverage atlas. Persistent rgba8_unorm sampled texture into which
//! coverage bitmaps are shelf-packed and uploaded. Coverage is stored in the R
//! channel; G/B/A are zero. The text shader reads the alpha channel after the
//! bindTexture swizzle {one,one,one,r} broadcasts R into A. Maintains a map
//! from (kind, owner, size, id) to a UV rect and placement metadata.
//!
//! Glyphs are one kind of coverage; icons are another. The atlas itself does
//! not know how a bitmap was produced, so `ensureCoverage` is the general entry
//! point and `ensure` is the glyph-shaped wrapper over it.
//!
//! File-as-struct pattern: the public type is GlyphAtlas = @This().
const std = @import("std");
const prism = @import("prism");
const hal = prism.hal;
const text = @import("../text.zig");

/// An 8-bit alpha coverage bitmap with placement metadata.
const Coverage = text.Glyph;

const GlyphAtlas = @This();

// Atlas dimensions. rgba8_unorm: 4 bytes per pixel, stride = width * 4.
// Using rgba8_unorm (rather than r8_unorm) ensures the software reference
// driver can sample the atlas correctly; coverage is stored in the R channel.
const atlas_w: u32 = 512;
const atlas_h: u32 = 512;
const atlas_bpp: u32 = 4; // bytes per pixel (rgba8_unorm)

/// What produced a cached bitmap. The discriminator keeps an icon and a glyph
/// with the same numbers in `owner` and `id` in separate cache slots.
pub const Kind = enum { glyph, icon };

/// Cache lookup key: kind, owner identity, size by bit-cast f32, and an id
/// within that owner.
pub const Key = struct {
    kind: Kind,
    /// A glyph's font pointer, or an icon's identifier. Opaque to the atlas.
    owner: usize,
    size_bits: u32,
    id: u32,
};

/// Per-entry atlas record. UV coordinates are normalized [0,1] into the atlas
/// texture. w, h, left, top, advance carry the raster placement metadata.
pub const Entry = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
    w: u32,
    h: u32,
    left: i32,
    top: i32,
    advance: f32,
};

device: prism.Device,
/// The rgba8_unorm atlas texture. Coverage is stored in the R channel.
/// Read by the Prism backend for bindTexture with swizzle {one,one,one,r}.
image: *hal.Resource,
/// Shelf packer state: next insertion point.
pen_x: u32,
pen_y: u32,
row_h: u32,
/// Cache map from Key to Entry.
map: std.AutoHashMapUnmanaged(Key, Entry),

/// Create a 512x512 rgba8_unorm sampled atlas image (coverage in R, sampled into
/// alpha via a {one,one,one,r} swizzle) and zero-init its pixels. rgba8 is used
/// because the Prism software driver has no working r8_unorm sampler path.
pub fn init(device: prism.Device, gpa: std.mem.Allocator) !GlyphAtlas {
    _ = gpa;
    const img = try device.createResource(.{ .image = .{
        .width = atlas_w,
        .height = atlas_h,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    } });
    errdefer device.destroyResource(img);

    // Zero-init in case the driver does not guarantee zeroed memory.
    const px = try device.mapResource(img);
    @memset(px, 0);

    return .{
        .device = device,
        .image = img,
        .pen_x = 0,
        .pen_y = 0,
        .row_h = 0,
        .map = .{},
    };
}

/// Destroy the atlas texture and free the lookup map.
pub fn deinit(self: *GlyphAtlas, gpa: std.mem.Allocator) void {
    self.device.destroyResource(self.image);
    self.map.deinit(gpa);
}

/// Return the atlas Entry for (font, size, cp), rasterizing and uploading
/// the glyph if it is not already cached. Returns error.AtlasFull when the
/// atlas has no room for a new shelf row.
pub fn ensure(
    self: *GlyphAtlas,
    gpa: std.mem.Allocator,
    font: *text.Font,
    size: f32,
    cp: u21,
) !Entry {
    const key = Key{
        .kind = .glyph,
        .owner = @intFromPtr(font),
        .size_bits = @bitCast(size),
        .id = cp,
    };

    // Cache hit: return the existing entry before touching the font engine.
    if (self.map.get(key)) |cached| return cached;

    // Rasterize the glyph via the font engine. The font cache owns the result.
    const cov = try font.glyph(gpa, cp, size);
    return self.ensureCoverage(gpa, key, cov.*);
}

/// Upload an already-rasterised coverage bitmap under `key`, or return the
/// cached entry. The caller owns `cov` and may free it after this returns:
/// the pixels are copied into the atlas texture, never retained.
/// Returns error.AtlasFull when the atlas has no room for a new shelf row.
pub fn ensureCoverage(
    self: *GlyphAtlas,
    gpa: std.mem.Allocator,
    key: Key,
    cov: Coverage,
) !Entry {
    // Cache hit: return the existing entry.
    if (self.map.get(key)) |cached| return cached;

    // Handle zero-size bitmaps (whitespace, missing, etc.) by recording a
    // degenerate entry so subsequent ensure() calls are still cache hits.
    if (cov.w == 0 or cov.h == 0) {
        const entry = Entry{
            .u0 = 0,
            .v0 = 0,
            .u1 = 0,
            .v1 = 0,
            .w = 0,
            .h = 0,
            .left = cov.left,
            .top = cov.top,
            .advance = cov.advance,
        };
        try self.map.put(gpa, key, entry);
        return entry;
    }

    // Shelf packer: wrap to a new row if the glyph does not fit horizontally.
    if (self.pen_x + cov.w + 1 > atlas_w) {
        self.pen_x = 0;
        self.pen_y += self.row_h + 1;
        self.row_h = 0;
    }

    // Vertical overflow check: no eviction this slice.
    if (self.pen_y + cov.h > atlas_h) return error.AtlasFull;

    const gx = self.pen_x;
    const gy = self.pen_y;
    self.pen_x += cov.w + 1;
    if (cov.h > self.row_h) self.row_h = cov.h;

    // Upload coverage bitmap into the atlas sub-rect, row by row.
    // Atlas stride = atlas_w * atlas_bpp (rgba8_unorm: 4 bytes per pixel).
    // Coverage goes into the R channel; G/B/A are zero. The bindTexture
    // swizzle {one, one, one, r} broadcasts R into alpha for the text shader.
    const dst = try self.device.mapResource(self.image);
    var row: u32 = 0;
    while (row < cov.h) : (row += 1) {
        var col: u32 = 0;
        while (col < cov.w) : (col += 1) {
            const dst_off = ((gy + row) * atlas_w + gx + col) * atlas_bpp;
            const src_byte = cov.pixels[row * cov.w + col];
            dst[dst_off + 0] = src_byte; // R = coverage
            dst[dst_off + 1] = 0; // G = 0
            dst[dst_off + 2] = 0; // B = 0
            dst[dst_off + 3] = 0; // A = 0
        }
    }

    // Compute normalized UV coordinates.
    const aw: f32 = @floatFromInt(atlas_w);
    const ah: f32 = @floatFromInt(atlas_h);
    const cw: f32 = @floatFromInt(cov.w);
    const ch: f32 = @floatFromInt(cov.h);
    const fgx: f32 = @floatFromInt(gx);
    const fgy: f32 = @floatFromInt(gy);

    const entry = Entry{
        .u0 = fgx / aw,
        .v0 = fgy / ah,
        .u1 = (fgx + cw) / aw,
        .v1 = (fgy + ch) / ah,
        .w = cov.w,
        .h = cov.h,
        .left = cov.left,
        .top = cov.top,
        .advance = cov.advance,
    };
    try self.map.put(gpa, key, entry);
    return entry;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GlyphAtlas.ensure packs a glyph and uploads non-zero coverage" {
    const gpa = std.testing.allocator;
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var atlas = try GlyphAtlas.init(sel.device, gpa);
    defer atlas.deinit(gpa);
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const e1 = try atlas.ensure(gpa, &font, 48, 'A');
    try std.testing.expect(e1.w > 0 and e1.h > 0);
    try std.testing.expect(e1.u1 > e1.u0 and e1.v1 > e1.v0);
    // second ensure is a cache hit: identical entry
    const e2 = try atlas.ensure(gpa, &font, 48, 'A');
    try std.testing.expectEqual(e1.u0, e2.u0);
    // the atlas texture has some non-zero coverage where 'A' was packed
    const px = try sel.device.mapResource(atlas.image);
    var any: bool = false;
    for (px) |v| {
        if (v != 0) any = true;
    }
    try std.testing.expect(any);
}

test "an icon key and a glyph key with the same numbers do not collide" {
    // Without the kind discriminator, icon 65 at 16px and glyph 'A' at 16px in
    // the font at address 65 would share a cache slot and draw each other.
    const g = Key{ .kind = .glyph, .owner = 65, .size_bits = @bitCast(@as(f32, 16)), .id = 65 };
    const i = Key{ .kind = .icon, .owner = 65, .size_bits = @bitCast(@as(f32, 16)), .id = 65 };
    try std.testing.expect(!std.meta.eql(g, i));
}

test "ensureCoverage returns the cached entry on the second call" {
    const gpa = std.testing.allocator;
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var atlas = try GlyphAtlas.init(sel.device, gpa);
    defer atlas.deinit(gpa);

    const key = Key{ .kind = .icon, .owner = 1, .size_bits = @bitCast(@as(f32, 16)), .id = 7 };

    const first_pixels = try gpa.alloc(u8, 4 * 3);
    @memset(first_pixels, 0xff);
    var first = Coverage{
        .pixels = first_pixels,
        .w = 4,
        .h = 3,
        .left = 2,
        .top = -1,
        .advance = 5.0,
    };
    const e1 = try atlas.ensureCoverage(gpa, key, first);
    // The atlas must copy the pixels, so freeing here must not disturb the
    // cached entry that the second ensureCoverage call returns.
    first.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 4), e1.w);
    try std.testing.expectEqual(@as(u32, 3), e1.h);
    try std.testing.expectEqual(@as(u32, 1), atlas.map.count());
    const pen_x_after_first = atlas.pen_x;
    const pen_y_after_first = atlas.pen_y;

    // A second coverage with different dimensions and pixels under the same
    // key: a cache hit must ignore it entirely.
    const second_pixels = try gpa.alloc(u8, 9 * 9);
    @memset(second_pixels, 0x40);
    var second = Coverage{
        .pixels = second_pixels,
        .w = 9,
        .h = 9,
        .left = 100,
        .top = 100,
        .advance = 99.0,
    };
    defer second.deinit(gpa);
    const e2 = try atlas.ensureCoverage(gpa, key, second);

    try std.testing.expectEqual(e1, e2);
    // No second pack happened: the shelf pen and the map size did not move.
    try std.testing.expectEqual(pen_x_after_first, atlas.pen_x);
    try std.testing.expectEqual(pen_y_after_first, atlas.pen_y);
    try std.testing.expectEqual(@as(u32, 1), atlas.map.count());
}

test "ensureCoverage on a zero-size coverage records a degenerate entry" {
    const gpa = std.testing.allocator;
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var atlas = try GlyphAtlas.init(sel.device, gpa);
    defer atlas.deinit(gpa);

    const key = Key{ .kind = .icon, .owner = 3, .size_bits = @bitCast(@as(f32, 24)), .id = 11 };
    const cov = Coverage{
        .pixels = &.{},
        .w = 0,
        .h = 0,
        .left = 3,
        .top = -4,
        .advance = 7.5,
    };

    const e = try atlas.ensureCoverage(gpa, key, cov);

    // A degenerate entry has an empty UV rect but keeps the placement metadata,
    // because a caller still advances the pen by `advance`.
    try std.testing.expectEqual(@as(u32, 0), e.w);
    try std.testing.expectEqual(@as(u32, 0), e.h);
    try std.testing.expectEqual(@as(f32, 0), e.u0);
    try std.testing.expectEqual(@as(f32, 0), e.u1);
    try std.testing.expectEqual(@as(f32, 0), e.v0);
    try std.testing.expectEqual(@as(f32, 0), e.v1);
    try std.testing.expectEqual(@as(i32, 3), e.left);
    try std.testing.expectEqual(@as(i32, -4), e.top);
    try std.testing.expectEqual(@as(f32, 7.5), e.advance);

    // Nothing was packed, so the shelf pen is untouched.
    try std.testing.expectEqual(@as(u32, 0), atlas.pen_x);
    try std.testing.expectEqual(@as(u32, 0), atlas.pen_y);
    try std.testing.expectEqual(@as(u32, 0), atlas.row_h);

    // The degenerate entry is recorded, so the next call is a cache hit.
    try std.testing.expectEqual(@as(u32, 1), atlas.map.count());
    const e2 = try atlas.ensureCoverage(gpa, key, cov);
    try std.testing.expectEqual(e, e2);
    try std.testing.expectEqual(@as(u32, 1), atlas.map.count());
}
