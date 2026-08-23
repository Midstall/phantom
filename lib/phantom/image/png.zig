const std = @import("std");

pub const DecodeError = error{
    InvalidSignature,
    BadChunk,
    CrcMismatch,
    Unsupported,
    Truncated,
    MissingIhdr,
    OutOfMemory,
};

pub const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,
    _,
};

pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    interlace: u8,
};

pub const signature = [8]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

const Chunk = struct {
    type: [4]u8,
    data: []const u8,
};

const ChunkIter = struct {
    bytes: []const u8,
    pos: usize,

    fn next(self: *ChunkIter) DecodeError!?Chunk {
        if (self.pos >= self.bytes.len) return null;
        if (self.pos + 4 > self.bytes.len) return error.Truncated;

        const len = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;

        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        var chunk_type: [4]u8 = undefined;
        @memcpy(&chunk_type, self.bytes[self.pos..][0..4]);
        self.pos += 4;

        if (self.pos + len > self.bytes.len) return error.Truncated;
        const data = self.bytes[self.pos .. self.pos + len];
        self.pos += len;

        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        const stored_crc = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;

        var crc = std.hash.Crc32.init();
        crc.update(&chunk_type);
        crc.update(data);
        if (crc.final() != stored_crc) return error.CrcMismatch;

        return Chunk{ .type = chunk_type, .data = data };
    }
};

pub fn readHeader(bytes: []const u8) DecodeError!Header {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) {
        return error.InvalidSignature;
    }

    var iter = ChunkIter{ .bytes = bytes, .pos = 8 };
    const chunk = (try iter.next()) orelse return error.MissingIhdr;

    if (!std.mem.eql(u8, &chunk.type, "IHDR")) return error.MissingIhdr;
    if (chunk.data.len < 13) return error.Truncated;

    const width = std.mem.readInt(u32, chunk.data[0..4], .big);
    const height = std.mem.readInt(u32, chunk.data[4..8], .big);
    const bit_depth = chunk.data[8];
    const color_type: ColorType = @enumFromInt(chunk.data[9]);
    const compression = chunk.data[10];
    const filter_method = chunk.data[11];
    const interlace = chunk.data[12];

    if (compression != 0 or filter_method != 0) return error.Unsupported;

    return Header{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .interlace = interlace,
    };
}

fn appendChunk(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), ctype: []const u8, data: []const u8) !void {
    var len_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_be, @intCast(data.len), .big);
    try buf.appendSlice(gpa, &len_be);
    try buf.appendSlice(gpa, ctype);
    try buf.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(ctype);
    crc.update(data);
    var crc_be: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_be, crc.final(), .big);
    try buf.appendSlice(gpa, &crc_be);
}

test "readHeader parses a 4x4 8-bit RGBA IHDR" {
    var hdr_data = [_]u8{ 0, 0, 0, 4, 0, 0, 0, 4, 8, 6, 0, 0, 0 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, &signature);
    try appendChunk(std.testing.allocator, &buf, "IHDR", &hdr_data);
    const h = try readHeader(buf.items);
    try std.testing.expectEqual(@as(u32, 4), h.width);
    try std.testing.expectEqual(@as(u32, 4), h.height);
    try std.testing.expectEqual(@as(u8, 8), h.bit_depth);
    try std.testing.expectEqual(ColorType.rgba, h.color_type);
    try std.testing.expectEqual(@as(u8, 0), h.interlace);
}

test "readHeader rejects a bad signature" {
    try std.testing.expectError(DecodeError.InvalidSignature, readHeader(&[_]u8{0} ** 16));
}

// Concatenates all IDAT chunk payloads in order, stopping at IEND.
// Returns a gpa-owned slice; caller frees.
pub fn concatIdat(gpa: std.mem.Allocator, bytes: []const u8) DecodeError![]u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &signature)) {
        return error.InvalidSignature;
    }
    var iter = ChunkIter{ .bytes = bytes, .pos = 8 };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (try iter.next()) |chunk| {
        if (std.mem.eql(u8, &chunk.type, "IEND")) break;
        if (std.mem.eql(u8, &chunk.type, "IDAT")) {
            try out.appendSlice(gpa, chunk.data);
        }
    }
    return out.toOwnedSlice(gpa);
}

// Decompresses a zlib-wrapped deflate stream.
// This is the ONLY place in the decoder that uses std.compress.flate.
// A future pure-Zig inflate can replace just this function.
pub fn inflateZlib(gpa: std.mem.Allocator, zlib_bytes: []const u8, size_hint: usize) DecodeError![]u8 {
    _ = size_hint; // .unlimited used; PNG raw size is trusted from the IHDR
    var in: std.Io.Reader = .fixed(zlib_bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&in, .zlib, &window);
    return d.reader.allocRemaining(gpa, .unlimited) catch return error.BadChunk;
}

// TEST-ONLY: compress raw bytes into a zlib stream using std.compress.flate.Compress.
// Not called from production code. Used solely for round-trip tests.
fn deflateZlibForTest(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Compress.init asserts output.buffer.len > 8, so allocate upfront.
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, raw.len + 128);
    errdefer aw.deinit();
    var cbuf: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&aw.writer, &cbuf, .zlib, .default);
    try c.writer.writeAll(raw);
    try c.finish(); // writes the zlib footer (adler32)
    return aw.toOwnedSlice();
}

test "inflateZlib round-trips a deflated buffer" {
    const gpa = std.testing.allocator;
    const raw = "hello png world, the quick brown fox" ** 4;
    const z = try deflateZlibForTest(gpa, raw);
    defer gpa.free(z);
    const out = try inflateZlib(gpa, z, raw.len);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(raw, out);
}

// The PNG Paeth predictor. Computes in i32 to avoid overflow.
fn paeth(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p: i32 = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// Removes the per-scanline filter bytes from a raw post-inflate buffer and
// reconstructs the original sample bytes.
// filtered: height*(1+stride) bytes; output: height*stride bytes (gpa-owned, caller frees).
// bpp = bytes per pixel (channels for 8-bit: gray=1, gray_alpha=2, rgb=3, rgba=4, palette=1).
pub fn unfilter(
    gpa: std.mem.Allocator,
    filtered: []const u8,
    width: u32,
    height: u32,
    bpp: usize,
) DecodeError![]u8 {
    const stride: usize = @as(usize, width) * bpp;
    const row_in: usize = 1 + stride;
    if (filtered.len != @as(usize, height) * row_in) return error.Truncated;

    const out_len: usize = @as(usize, height) * stride;
    const out = try gpa.alloc(u8, out_len);
    errdefer gpa.free(out);

    for (0..height) |row| {
        const in_off: usize = row * row_in;
        const filter_type: u8 = filtered[in_off];
        const raw_row: []const u8 = filtered[in_off + 1 .. in_off + 1 + stride];

        const out_row_off: usize = row * stride;
        const cur_row: []u8 = out[out_row_off .. out_row_off + stride];

        // Previous row (zero-filled sentinel for first row).
        const prev_row: ?[]const u8 = if (row > 0) out[(row - 1) * stride .. row * stride] else null;

        switch (filter_type) {
            0 => { // None
                @memcpy(cur_row, raw_row);
            },
            1 => { // Sub
                for (0..stride) |x| {
                    const raw_x: u16 = raw_row[x];
                    const a: u16 = if (x >= bpp) cur_row[x - bpp] else 0;
                    cur_row[x] = @truncate(raw_x +% a);
                }
            },
            2 => { // Up
                for (0..stride) |x| {
                    const raw_x: u16 = raw_row[x];
                    const b: u16 = if (prev_row) |pr| pr[x] else 0;
                    cur_row[x] = @truncate(raw_x +% b);
                }
            },
            3 => { // Average (floor, not rounded)
                for (0..stride) |x| {
                    const raw_x: u16 = raw_row[x];
                    const a: u16 = if (x >= bpp) cur_row[x - bpp] else 0;
                    const b: u16 = if (prev_row) |pr| pr[x] else 0;
                    cur_row[x] = @truncate(raw_x +% ((a + b) >> 1));
                }
            },
            4 => { // Paeth
                for (0..stride) |x| {
                    const raw_x: u8 = raw_row[x];
                    const a: u8 = if (x >= bpp) cur_row[x - bpp] else 0;
                    const b: u8 = if (prev_row) |pr| pr[x] else 0;
                    const c: u8 = if (prev_row) |pr| (if (x >= bpp) pr[x - bpp] else 0) else 0;
                    cur_row[x] = raw_x +% paeth(a, b, c);
                }
            },
            else => return error.BadChunk,
        }
    }

    return out;
}

test "paeth predictor picks the closest of a,b,c" {
    try std.testing.expectEqual(@as(u8, 10), paeth(10, 20, 30));
    try std.testing.expectEqual(@as(u8, 20), paeth(200, 20, 210));
}

test "unfilter reconstructs Sub and Up rows" {
    const gpa = std.testing.allocator;
    // 2x2, bpp=1 (gray). Row0 filter=Sub(1): raw [10, +5]; Row1 filter=Up(2): [+3,+4] over row0.
    const filtered = [_]u8{ 1, 10, 5, 2, 3, 4 };
    const out = try unfilter(gpa, &filtered, 2, 2, 1);
    defer gpa.free(out);
    // Row0: 10, 15. Row1: 10+3=13, 15+4=19.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 15, 13, 19 }, out);
}

test "unfilter reconstructs Average row bpp=2 (exercises left-neighbor at bpp offset)" {
    const gpa = std.testing.allocator;
    // 3x1, bpp=2 (gray_alpha). One row, filter=Average(3).
    // Raw row bytes: [10, 5, 20, 3, 30, 2].
    // x=0: a=0(x<bpp), b=0(first row). recon=10+floor(0/2)=10.
    // x=1: a=0(x<bpp), b=0. recon=5+0=5.
    // x=2: a=recon[0]=10, b=0. recon=20+floor(10/2)=25.
    // x=3: a=recon[1]=5, b=0. recon=3+floor(5/2)=5.
    // x=4: a=recon[2]=25, b=0. recon=30+floor(25/2)=42.
    // x=5: a=recon[3]=5, b=0. recon=2+floor(5/2)=4.
    const filtered = [_]u8{ 3, 10, 5, 20, 3, 30, 2 };
    const out = try unfilter(gpa, &filtered, 3, 1, 2);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 5, 25, 5, 42, 4 }, out);
}

test "unfilter reconstructs Paeth rows bpp=2 (exercises up-left corner at bpp offset)" {
    const gpa = std.testing.allocator;
    // 2x2, bpp=2. Both rows filter=Paeth(4).
    // Row0 raw: [10, 20, 5, 3].
    //   x=0: a=0,b=0,c=0. paeth(0,0,0)=0. recon=10.
    //   x=1: a=0(x<bpp),b=0,c=0. recon=20.
    //   x=2: a=recon[0]=10,b=0,c=0. paeth(10,0,0)=10. recon=5+10=15.
    //   x=3: a=recon[1]=20,b=0,c=0. paeth(20,0,0)=20. recon=3+20=23.
    // Row1 raw: [2, 1, 3, 4]. above=[10,20,15,23].
    //   x=0: a=0,b=above[0]=10,c=0. paeth(0,10,0)=10. recon=2+10=12.
    //   x=1: a=0(x<bpp),b=above[1]=20,c=0. paeth(0,20,0)=20. recon=1+20=21.
    //   x=2: a=recon[4]=12,b=above[2]=15,c=above[0]=10. paeth(12,15,10)=15. recon=3+15=18.
    //   x=3: a=recon[5]=21,b=above[3]=23,c=above[1]=20. paeth(21,23,20)=23. recon=4+23=27.
    const filtered = [_]u8{ 4, 10, 20, 5, 3, 4, 2, 1, 3, 4 };
    const out = try unfilter(gpa, &filtered, 2, 2, 2);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 15, 23, 12, 21, 18, 27 }, out);
}

test "unfilter returns Truncated on length mismatch" {
    const gpa = std.testing.allocator;
    // 2x2 bpp=1 expects 2*(1+2)=6 bytes; pass only 5.
    const short = [_]u8{ 0, 1, 2, 0, 3 };
    try std.testing.expectError(error.Truncated, unfilter(gpa, &short, 2, 2, 1));
}

test "concatIdat joins two IDAT chunks in order" {
    const gpa = std.testing.allocator;
    const idat1 = [_]u8{ 0xAA, 0xBB };
    const idat2 = [_]u8{ 0xCC, 0xDD, 0xEE };
    var hdr_data = [_]u8{ 0, 0, 0, 4, 0, 0, 0, 4, 8, 6, 0, 0, 0 };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, &signature);
    try appendChunk(gpa, &buf, "IHDR", &hdr_data);
    try appendChunk(gpa, &buf, "IDAT", &idat1);
    try appendChunk(gpa, &buf, "IDAT", &idat2);
    try appendChunk(gpa, &buf, "IEND", &.{});
    const result = try concatIdat(gpa, buf.items);
    defer gpa.free(result);
    const expected = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    try std.testing.expectEqualSlices(u8, &expected, result);
}

// Decoded RGBA output from decode(). rgba is gpa-owned; caller must free.
pub const Decoded = struct {
    rgba: []u8,
    width: u32,
    height: u32,
};

// Walk chunks starting at pos 8 and return the payload of the first chunk
// whose type matches the 4-byte tag, or null if not found.
fn findChunk(bytes: []const u8, tag: *const [4]u8) ?[]const u8 {
    var iter = ChunkIter{ .bytes = bytes, .pos = 8 };
    while (iter.next() catch null) |chunk| {
        if (std.mem.eql(u8, &chunk.type, tag)) return chunk.data;
        if (std.mem.eql(u8, &chunk.type, "IEND")) break;
    }
    return null;
}

// Decode a PNG byte slice into a tightly-packed RGBA8 buffer.
// Supports 8-bit gray / gray_alpha / rgb / rgba / palette color types.
// Returns Unsupported for bit depths != 8 or Adam7 interlaced images.
// All intermediate allocations are freed; caller owns the returned rgba slice.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    const hdr = try readHeader(bytes);

    if (hdr.bit_depth != 8) return error.Unsupported;
    if (hdr.interlace != 0) return error.Unsupported;

    const bpp: usize = switch (hdr.color_type) {
        .gray => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        .palette => 1,
        _ => return error.Unsupported,
    };

    const w = hdr.width;
    const h = hdr.height;
    const size_hint: usize = @as(usize, h) * (1 + @as(usize, w) * bpp);

    // Concatenate all IDAT payloads, inflate, then unfilter.
    const idat = try concatIdat(gpa, bytes);
    defer gpa.free(idat);

    const inflated = try inflateZlib(gpa, idat, size_hint);
    defer gpa.free(inflated);

    const raw = try unfilter(gpa, inflated, w, h, bpp);
    defer gpa.free(raw);

    // Allocate the output RGBA buffer.
    const rgba_len: usize = @as(usize, w) * @as(usize, h) * 4;
    const rgba = try gpa.alloc(u8, rgba_len);
    errdefer gpa.free(rgba);

    const npx: usize = @as(usize, w) * @as(usize, h);

    switch (hdr.color_type) {
        .gray => {
            // Optional tRNS gray key (2 bytes, big-endian u16; we only care about 8-bit so low byte).
            var trns_key: ?u8 = null;
            if (findChunk(bytes, "tRNS")) |trns| {
                if (trns.len >= 2) trns_key = trns[1];
            }
            for (0..npx) |i| {
                const g = raw[i];
                rgba[i * 4 + 0] = g;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = g;
                rgba[i * 4 + 3] = if (trns_key) |k| (if (g == k) @as(u8, 0) else @as(u8, 255)) else 255;
            }
        },
        .gray_alpha => {
            for (0..npx) |i| {
                const g = raw[i * 2 + 0];
                const a = raw[i * 2 + 1];
                rgba[i * 4 + 0] = g;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = g;
                rgba[i * 4 + 3] = a;
            }
        },
        .rgb => {
            // Optional tRNS rgb key (6 bytes: r_hi r_lo g_hi g_lo b_hi b_lo).
            var trns_r: ?u8 = null;
            var trns_g: ?u8 = null;
            var trns_b: ?u8 = null;
            if (findChunk(bytes, "tRNS")) |trns| {
                if (trns.len >= 6) {
                    trns_r = trns[1];
                    trns_g = trns[3];
                    trns_b = trns[5];
                }
            }
            for (0..npx) |i| {
                const r = raw[i * 3 + 0];
                const g = raw[i * 3 + 1];
                const b = raw[i * 3 + 2];
                const a: u8 = if (trns_r) |kr| blk: {
                    break :blk if (r == kr and g == trns_g.? and b == trns_b.?) @as(u8, 0) else @as(u8, 255);
                } else 255;
                rgba[i * 4 + 0] = r;
                rgba[i * 4 + 1] = g;
                rgba[i * 4 + 2] = b;
                rgba[i * 4 + 3] = a;
            }
        },
        .rgba => {
            @memcpy(rgba, raw);
        },
        .palette => {
            const plte_data = findChunk(bytes, "PLTE") orelse return error.BadChunk;
            if (plte_data.len == 0 or plte_data.len % 3 != 0) return error.BadChunk;
            const num_entries: usize = plte_data.len / 3;

            // tRNS for palette: one alpha byte per palette entry (may be shorter, rest defaults to 255).
            const trns_data: ?[]const u8 = findChunk(bytes, "tRNS");

            for (0..npx) |i| {
                const idx: usize = raw[i];
                if (idx >= num_entries) return error.BadChunk;
                rgba[i * 4 + 0] = plte_data[idx * 3 + 0];
                rgba[i * 4 + 1] = plte_data[idx * 3 + 1];
                rgba[i * 4 + 2] = plte_data[idx * 3 + 2];
                rgba[i * 4 + 3] = if (trns_data) |td|
                    (if (idx < td.len) td[idx] else @as(u8, 255))
                else
                    255;
            }
        },
        _ => return error.Unsupported,
    }

    return Decoded{ .rgba = rgba, .width = w, .height = h };
}

// TEST-ONLY: build a minimal valid PNG from raw RGBA pixels.
// Prepends a None(0) filter byte to each row, deflates via deflateZlibForTest,
// and assembles: signature + IHDR + IDAT + IEND.
fn encodeRgbaPngForTest(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    const row_bytes: usize = @as(usize, w) * 4;

    // Build filtered image data: prepend 0x00 (None) filter to each row.
    var filtered: std.ArrayList(u8) = .empty;
    errdefer filtered.deinit(gpa);
    for (0..h) |row| {
        try filtered.append(gpa, 0); // None filter
        try filtered.appendSlice(gpa, rgba[row * row_bytes .. row * row_bytes + row_bytes]);
    }
    const filtered_bytes = try filtered.toOwnedSlice(gpa);
    defer gpa.free(filtered_bytes);

    // Deflate the filtered data.
    const zlib = try deflateZlibForTest(gpa, filtered_bytes);
    defer gpa.free(zlib);

    // Assemble the PNG byte stream.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, &signature);

    // IHDR: width(4) height(4) bit_depth(1) color_type(1) compression(1) filter(1) interlace(1).
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &buf, "IHDR", &ihdr);
    try appendChunk(gpa, &buf, "IDAT", zlib);
    try appendChunk(gpa, &buf, "IEND", &.{});

    return buf.toOwnedSlice(gpa);
}

test "decode round-trips a synthetic 2x2 RGBA PNG" {
    const gpa = std.testing.allocator;
    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128 };
    const png_bytes = try encodeRgbaPngForTest(gpa, &px, 2, 2);
    defer gpa.free(png_bytes);
    const d = try decode(gpa, png_bytes);
    defer gpa.free(d.rgba);
    try std.testing.expectEqual(@as(u32, 2), d.width);
    try std.testing.expectEqual(@as(u32, 2), d.height);
    try std.testing.expectEqualSlices(u8, &px, d.rgba);
}

test "decode handles a real-encoder 4x4 PNG fixture" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("testdata/logo.png");
    const d = try decode(gpa, bytes);
    defer gpa.free(d.rgba);
    try std.testing.expectEqual(@as(u32, 4), d.width);
    try std.testing.expectEqual(@as(u32, 4), d.height);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), d.rgba.len);
}

// TEST-ONLY helper: build a minimal 2x1 palette PNG and assert RGBA expansion.
// Layout: PLTE = 2 entries [red(255,0,0), blue(0,0,255)], tRNS = [255, 128].
// IDAT pixel data: index row = [0, 1] (one row, two pixels).
// Expected RGBA: (255,0,0,255), (0,0,255,128).
fn encodePalettePngForTest(gpa: std.mem.Allocator) ![]u8 {
    // PLTE: 2 x 3 bytes.
    const plte = [_]u8{ 255, 0, 0, 0, 0, 255 };
    // tRNS: 2 bytes, one alpha per entry.
    const trns = [_]u8{ 255, 128 };
    // Pixel indices: row of 2 pixels (width=2, height=1, bpp=1).
    // Filtered: 1 filter byte (0=None) + 2 index bytes.
    const filtered = [_]u8{ 0, 0, 1 };
    const zlib = try deflateZlibForTest(gpa, &filtered);
    defer gpa.free(zlib);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 2, .big); // width=2
    std.mem.writeInt(u32, ihdr[4..8], 1, .big); // height=1
    ihdr[8] = 8; // bit depth
    ihdr[9] = 3; // color type: palette
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &buf, "IHDR", &ihdr);
    try appendChunk(gpa, &buf, "PLTE", &plte);
    try appendChunk(gpa, &buf, "tRNS", &trns);
    try appendChunk(gpa, &buf, "IDAT", zlib);
    try appendChunk(gpa, &buf, "IEND", &.{});

    return buf.toOwnedSlice(gpa);
}

test "decode expands a synthetic palette PNG to RGBA with tRNS alpha" {
    const gpa = std.testing.allocator;
    const png_bytes = try encodePalettePngForTest(gpa);
    defer gpa.free(png_bytes);
    const d = try decode(gpa, png_bytes);
    defer gpa.free(d.rgba);
    try std.testing.expectEqual(@as(u32, 2), d.width);
    try std.testing.expectEqual(@as(u32, 1), d.height);
    // Pixel 0: index 0 -> PLTE[0]=(255,0,0) + tRNS[0]=255.
    // Pixel 1: index 1 -> PLTE[1]=(0,0,255) + tRNS[1]=128.
    const expected = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 128 };
    try std.testing.expectEqualSlices(u8, &expected, d.rgba);
}
