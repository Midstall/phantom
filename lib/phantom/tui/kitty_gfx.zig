//! The kitty graphics protocol. An image goes out as an APC sequence carrying base64
//! pixel data. The protocol limits one chunk, so a large image splits and every chunk
//! but the last carries `m=1`.
const std = @import("std");
const ansi = @import("ansi.zig");

/// The protocol allows 4096 bytes of payload in one chunk.
pub const max_chunk = 4096;

pub const ImageDesc = struct {
    /// The identity the terminal keeps. `Session` gives every transmitted frame a
    /// fresh id and frees the previous one explicitly with `deleteImage`, rather
    /// than reusing one id, so a placement never briefly points at a half
    /// transmitted image.
    id: u32,
    width: u32,
    height: u32,
    /// Straight RGBA, eight bits for each channel.
    rgba: []const u8,
    /// Deflate the pixels before base64 and tell the terminal with `o=z`.
    ///
    /// A user interface frame is mostly flat colour, so this is not a marginal
    /// saving. One measured 3002x1665 frame is 19 MB of RGBA, which base64
    /// expands to 25 MB on the wire; compressed first it is 20 KB, and 26 KB
    /// encoded. That is the difference between a startup that writes 25 MB
    /// through a pty for the terminal to parse and one that writes 26 KB.
    compress: bool = true,
};

/// Deflate `src` into a zlib stream, which is the container `o=z` names. The
/// caller frees the result.
///
/// Level 1, the fastest. The ratio above is already about a thousand to one on
/// real frame data, so the slower levels would spend time to save bytes that are
/// no longer the bottleneck.
fn deflate(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    // `Compress.init` asserts the output has more than 8 bytes of buffer, so the
    // capacity is not merely an optimisation here.
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, @max(1024, src.len / 64));
    errdefer out.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var c = try std.compress.flate.Compress.init(&out.writer, window, .zlib, .level_1);
    try c.writer.writeAll(src);
    try c.finish();
    return out.toOwnedSlice();
}

pub const Placement = struct {
    col: u16,
    row: u16,
    /// Vertical stacking order. A higher `z` composites above a lower one where
    /// two placements overlap.
    ///
    /// Stated rather than left to default, because the session places small
    /// damage images on top of a full-screen base and the result is only correct
    /// if the newer one wins. Two placements sharing a z-index have no order the
    /// protocol promises, so the base takes 0 and each overlay takes the next
    /// value up. Kept at or above zero: a negative z has its own meaning in the
    /// protocol, placing the image beneath the text rather than over it.
    z: i32 = 0,
};

/// Send one image and place it at one cell. The cursor moves to the cell first,
/// because a placement lands at the cursor, and `C=1` stops the placement moving it.
pub fn transmit(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    img: ImageDesc,
    place: Placement,
) !void {
    if (img.rgba.len == 0 or img.width == 0 or img.height == 0) return;

    var cur_buf: [16]u8 = undefined;
    try out.appendSlice(gpa, ansi.cursorTo(&cur_buf, place.row, place.col));

    const packed_pixels: ?[]u8 = if (img.compress) try deflate(gpa, img.rgba) else null;
    defer if (packed_pixels) |p| gpa.free(p);
    const payload = packed_pixels orelse img.rgba;

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(payload.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = encoder.encode(encoded, payload);

    var offset: usize = 0;
    var first = true;
    while (offset < encoded.len) {
        const take = @min(max_chunk, encoded.len - offset);
        const is_last = offset + take >= encoded.len;

        try out.appendSlice(gpa, ansi.apc ++ "G");
        if (first) {
            // f=32 is RGBA. a=T transmits and displays in one step. q=2 suppresses the
            // response, because the loop does not read one and an unread response would
            // arrive in the middle of the next input decode.
            // o=z says the payload is a zlib stream of the RGBA, which the
            // terminal inflates before reading it as pixels. `s` and `v` still
            // describe the IMAGE, not the payload: the size on the wire is not
            // something the protocol is told.
            var head: [96]u8 = undefined;
            const s = try std.fmt.bufPrint(
                &head,
                "a=T,f=32,s={d},v={d},i={d},C=1,q=2,z={d}{s},m={d}",
                .{
                    img.width,
                    img.height,
                    img.id,
                    place.z,
                    if (img.compress) ",o=z" else "",
                    @intFromBool(!is_last),
                },
            );
            try out.appendSlice(gpa, s);
            first = false;
        } else {
            // A continuation chunk carries only m, which is what the protocol allows.
            try out.appendSlice(gpa, if (is_last) "m=0" else "m=1");
        }
        try out.append(gpa, ';');
        try out.appendSlice(gpa, encoded[offset..][0..take]);
        try out.appendSlice(gpa, ansi.st);

        offset += take;
    }
}

/// Free one image's data and placement by id. `I` (uppercase) frees the data as
/// well as the placement; the lowercase `i` form would keep the data and leak it
/// forever, one more image every frame, since a frame that changes always
/// transmits under a fresh id. Scoped to `id`, so it never touches any other
/// image's placement.
///
/// An earlier version of this loop deleted with `a=d,d=a`, "delete all
/// placements visible on screen": simpler, since it needs no id, but it deletes
/// every image on screen and not just the stale one, which erased whatever else
/// was on screen that a partial-damage frame never redrew. Confirmed against the
/// kitty graphics protocol documentation's delete table, the same way Task 22
/// verified its control keys against `graphics.c`.
pub fn deleteImage(gpa: std.mem.Allocator, out: *std.ArrayList(u8), id: u32) !void {
    var buf: [32]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "a=d,d=I,i={d}", .{id});
    try out.appendSlice(gpa, ansi.apc ++ "G");
    try out.appendSlice(gpa, body);
    try out.appendSlice(gpa, ansi.st);
}

test "a one pixel image transmits as one chunk with the expected control keys" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const rgba = [_]u8{ 255, 0, 0, 255 };
    try transmit(gpa, &out, .{ .id = 1, .width = 1, .height = 1, .rgba = &rgba }, .{ .col = 0, .row = 0 });

    // The cursor moves first, because a placement lands where the cursor is.
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[1;1H"));
    // Then one APC sequence carrying the image.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_G") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=T") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "f=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "s=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "v=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "i=1") != null);
    // C=1 keeps the cursor where it was, or every image would scroll the screen.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "C=1") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.items, "\x1b\\"));
}

test "a payload larger than the chunk limit splits and marks every chunk but the last" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // 2048 pixels is 8192 raw bytes, which is more than one chunk of base64.
    const pixels = try gpa.alloc(u8, 2048 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 0x40);

    // Uncompressed on purpose: 8192 bytes of one repeated value deflate to
    // almost nothing, and then there would be no second chunk to test.
    try transmit(gpa, &out, .{ .id = 2, .width = 2048, .height = 1, .rgba = pixels, .compress = false }, .{ .col = 0, .row = 0 });

    // Every chunk except the last carries m=1, and the last carries m=0.
    try std.testing.expect(std.mem.count(u8, out.items, "m=1") >= 2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "m=0"));
    // The control keys appear one time, on the first chunk only.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "a=T"));
}

test "no chunk body is longer than the protocol limit" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const pixels = try gpa.alloc(u8, 5000 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 0x11);
    try transmit(gpa, &out, .{ .id = 3, .width = 5000, .height = 1, .rgba = pixels, .compress = false }, .{ .col = 0, .row = 0 });

    var it = std.mem.splitSequence(u8, out.items, "\x1b_G");
    _ = it.next(); // the text before the first sequence
    while (it.next()) |chunk| {
        const body_start = std.mem.indexOfScalar(u8, chunk, ';') orelse continue;
        const body_end = std.mem.indexOf(u8, chunk, "\x1b\\") orelse chunk.len;
        try std.testing.expect(body_end - body_start - 1 <= max_chunk);
    }
}

test "deleteImage frees one image's data and placement by id, scoped to that id alone" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deleteImage(gpa, &out, 42);
    // Uppercase I frees the data as well as the placement. i=42 scopes
    // the delete to that one id, so no other image on screen is touched.
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=I,i=42\x1b\\", out.items);
}

test "deleteImage carries the exact id requested, not a fixed one" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try deleteImage(gpa, &out, 1_000_000);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "i=1000000") != null);
}

test "the placement targets the requested cell" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const rgba = [_]u8{ 0, 0, 0, 255 };
    try transmit(gpa, &out, .{ .id = 1, .width = 1, .height = 1, .rgba = &rgba }, .{ .col = 9, .row = 4 });
    // The cell is zero based and CUP is one based.
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[5;10H"));
}

test "an empty pixel buffer produces no sequence at all" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try transmit(gpa, &out, .{ .id = 1, .width = 0, .height = 0, .rgba = &.{} }, .{ .col = 0, .row = 0 });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

/// Pull the base64 bodies out of every chunk and join them, which is what a
/// terminal does before decoding.
fn joinPayload(gpa: std.mem.Allocator, sequence: []const u8) ![]u8 {
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(gpa);
    var it = std.mem.splitSequence(u8, sequence, ansi.apc ++ "G");
    _ = it.next();
    while (it.next()) |chunk| {
        const semi = std.mem.indexOfScalar(u8, chunk, ';') orelse continue;
        const end = std.mem.indexOf(u8, chunk, ansi.st) orelse chunk.len;
        try joined.appendSlice(gpa, chunk[semi + 1 .. end]);
    }
    return joined.toOwnedSlice(gpa);
}

test "a compressed image round trips: the payload inflates back to the exact pixels" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    // Flat runs with a block of a second colour, which is what a real frame
    // looks like and what makes deflate worth doing at all.
    const w = 64;
    const h = 32;
    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    @memset(rgba, 0x20);
    for (10..20) |y| {
        for (5..40) |x| {
            const off = (y * w + x) * 4;
            rgba[off] = 0xC0;
            rgba[off + 1] = 0x40;
        }
    }

    try transmit(gpa, &out, .{ .id = 5, .width = w, .height = h, .rgba = rgba }, .{ .col = 0, .row = 0 });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "o=z") != null);

    const encoded = try joinPayload(gpa, out.items);
    defer gpa.free(encoded);

    const decoder = std.base64.standard.Decoder;
    const raw_len = try decoder.calcSizeForSlice(encoded);
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    try decoder.decode(raw, encoded);

    // The terminal's side: inflate the zlib stream and compare to what went in.
    var reader = std.Io.Reader.fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    const inflated = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(inflated);

    try std.testing.expectEqualSlices(u8, rgba, inflated);
}

test "compression is what shrinks the payload, and turning it off restores the raw base64" {
    const gpa = std.testing.allocator;
    const w = 64;
    const h = 32;
    const rgba = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(rgba);
    @memset(rgba, 0x20);

    var small: std.ArrayList(u8) = .empty;
    defer small.deinit(gpa);
    try transmit(gpa, &small, .{ .id = 1, .width = w, .height = h, .rgba = rgba }, .{ .col = 0, .row = 0 });

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try transmit(gpa, &big, .{
        .id = 1,
        .width = w,
        .height = h,
        .rgba = rgba,
        .compress = false,
    }, .{ .col = 0, .row = 0 });

    // The uncompressed form says nothing about compression, and is far larger.
    try std.testing.expect(std.mem.indexOf(u8, big.items, "o=z") == null);
    try std.testing.expect(small.items.len * 4 < big.items.len);
}

test "an uncompressed image still carries the raw base64 of its pixels" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const rgba = [_]u8{ 255, 0, 0, 255 };
    try transmit(gpa, &out, .{
        .id = 7,
        .width = 1,
        .height = 1,
        .rgba = &rgba,
        .compress = false,
    }, .{ .col = 0, .row = 0 });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "/wAA/w==") != null);
}

test "a placement states its stacking order, so an overlay composites above the base" {
    const gpa = std.testing.allocator;
    const rgba = [_]u8{ 0, 0, 0, 255 };

    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(gpa);
    try transmit(gpa, &base, .{ .id = 1, .width = 1, .height = 1, .rgba = &rgba }, .{ .col = 0, .row = 0, .z = 0 });
    try std.testing.expect(std.mem.indexOf(u8, base.items, "z=0") != null);

    var overlay: std.ArrayList(u8) = .empty;
    defer overlay.deinit(gpa);
    try transmit(gpa, &overlay, .{ .id = 2, .width = 1, .height = 1, .rgba = &rgba }, .{ .col = 3, .row = 4, .z = 7 });
    // Stated outright rather than left to the default: two placements sharing a
    // z-index have no order the protocol promises, so a damage image drawn over
    // the base would be free to end up underneath it.
    try std.testing.expect(std.mem.indexOf(u8, overlay.items, "z=7") != null);
}
