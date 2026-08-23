//! Per-font glyph cache. Keyed by (px_size as bit-pattern, codepoint).
//! All rasterized Coverage bitmaps are owned here; deinit frees them.
//! File-as-struct pattern.
const std = @import("std");
const raster = @import("raster.zig");
const Coverage = raster.Coverage;
const GlyphCache = @This();

pub const Key = struct {
    /// px_size as its f32 bit pattern so the key is hashable.
    size_bits: u32,
    cp: u21,
};

/// Coverage values are heap-boxed so their addresses remain stable across
/// map rehashes. The map stores *Coverage (a pointer to the heap box), not
/// Coverage by value. That way every pointer returned by get() stays valid
/// even after subsequent put() calls trigger a table grow/rehash.
map: std.AutoHashMapUnmanaged(Key, *Coverage) = .{},

/// Look up a cached Coverage. Returns a stable heap pointer (not into the
/// map's backing array), so it survives any later rehash.
pub fn get(self: *GlyphCache, key: Key) ?*const Coverage {
    const ptr = self.map.get(key) orelse return null;
    return ptr;
}

/// Store a Coverage in the cache. Boxes cov on the heap so the returned pointer
/// from get() is rehash-stable. Ownership of cov.pixels transfers into the cache
/// ONLY on success. On any error the caller keeps ownership of cov.pixels (the
/// caller's errdefer frees them); put frees only the box it allocated, so
/// cov.pixels is never double-freed.
pub fn put(self: *GlyphCache, gpa: std.mem.Allocator, key: Key, cov: Coverage) !void {
    const boxed = try gpa.create(Coverage);
    boxed.* = cov;
    // Insert failure: free only the box we allocated. cov.pixels stays owned by
    // the caller (freeing them here too would double-free with the caller).
    errdefer gpa.destroy(boxed);
    try self.map.put(gpa, key, boxed);
}

/// Free all owned pixel buffers, their heap boxes, then the map itself.
pub fn deinit(self: *GlyphCache, gpa: std.mem.Allocator) void {
    var it = self.map.valueIterator();
    while (it.next()) |box_ptr| {
        const box = box_ptr.*;
        // Only free non-empty pixel slices (zero-coverage entries have empty slices).
        if (box.pixels.len > 0) {
            gpa.free(box.pixels);
        }
        gpa.destroy(box);
    }
    self.map.deinit(gpa);
    self.* = .{};
}
