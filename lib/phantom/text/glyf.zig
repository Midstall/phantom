//! TrueType simple-glyph decoder. Reads a glyph from the raw glyf table bytes
//! using loca offsets, and emits its contours into a shared Outline via Builder.
//! Composite glyphs (numberOfContours < 0) return error.CompositeGlyphUnsupported.
const std = @import("std");
const Sfnt = @import("sfnt.zig");
const outline_mod = @import("outline.zig");
const Outline = outline_mod.Outline;
const Builder = outline_mod.Builder;
const Point = outline_mod.Point;

/// Wraps the raw loca table + index_to_loc_format from head.
/// index_to_loc_format: 0 = short (u16 offsets, each doubled); 1 = long (u32).
pub const Loca = struct {
    data: []const u8,
    index_to_loc_format: i16,

    /// Returns the (start, end) byte range within the glyf table for glyph id.
    /// Returns error.InvalidLoca if the glyph id is out of range or the table
    /// is too short.
    pub fn range(self: Loca, id: u16) !struct { start: u32, end: u32 } {
        if (self.index_to_loc_format == 0) {
            // Short format: each entry is a u16 storing offset/2.
            const needed = (@as(usize, id) + 2) * 2;
            if (self.data.len < needed) return error.InvalidLoca;
            const s = @as(u32, Sfnt.u16be(self.data, @as(usize, id) * 2)) * 2;
            const e = @as(u32, Sfnt.u16be(self.data, (@as(usize, id) + 1) * 2)) * 2;
            return .{ .start = s, .end = e };
        } else {
            // Long format: each entry is a u32.
            const needed = (@as(usize, id) + 2) * 4;
            if (self.data.len < needed) return error.InvalidLoca;
            const s = Sfnt.u32be(self.data, @as(usize, id) * 4);
            const e = Sfnt.u32be(self.data, (@as(usize, id) + 1) * 4);
            return .{ .start = s, .end = e };
        }
    }
};

/// Decode the simple glyph at index `glyph` from `glyf_table` (raw bytes of
/// the glyf table) using `loca` for the byte range. Segments are appended to
/// `out` via Builder. On error `out` may contain partial data; the caller
/// should deinit it.
pub fn readGlyph(gpa: std.mem.Allocator, glyf_table: []const u8, loca: Loca, glyph: u16, out: *Outline) !void {
    const r = try loca.range(glyph);
    // A zero-length glyph range is valid (empty glyph, e.g. space).
    if (r.start == r.end) return;
    if (r.end < r.start) return error.InvalidLoca;
    if (@as(usize, r.end) > glyf_table.len) return error.InvalidGlyf;

    const b = glyf_table[r.start..r.end];
    if (b.len < 10) return error.InvalidGlyf;

    const num_contours_raw = Sfnt.i16be(b, 0);
    if (num_contours_raw < 0) return error.CompositeGlyphUnsupported;
    const num_contours: usize = @intCast(num_contours_raw);

    if (num_contours == 0) return;

    // endPtsOfContours: num_contours u16be values at offset 10.
    var off: usize = 10;
    const end_pts_end = off + num_contours * 2;
    if (end_pts_end > b.len) return error.InvalidGlyf;

    var end_pts = try std.ArrayList(u16).initCapacity(gpa, num_contours);
    defer end_pts.deinit(gpa);
    {
        var i: usize = 0;
        while (i < num_contours) : (i += 1) {
            end_pts.appendAssumeCapacity(Sfnt.u16be(b, off + i * 2));
        }
    }
    off = end_pts_end;

    const point_count: usize = @as(usize, end_pts.items[num_contours - 1]) + 1;

    // Skip instructions.
    if (off + 2 > b.len) return error.InvalidGlyf;
    const instr_len: usize = Sfnt.u16be(b, off);
    off += 2 + instr_len;
    if (off > b.len) return error.InvalidGlyf;

    // Read flags with repeat support.
    var flags = try std.ArrayList(u8).initCapacity(gpa, point_count);
    defer flags.deinit(gpa);
    while (flags.items.len < point_count) {
        if (off >= b.len) return error.InvalidGlyf;
        const f = b[off];
        off += 1;
        try flags.append(gpa, f);
        if (f & 0x08 != 0) {
            // Repeat: next byte is the additional count.
            if (off >= b.len) return error.InvalidGlyf;
            const repeat: usize = b[off];
            off += 1;
            var ri: usize = 0;
            while (ri < repeat and flags.items.len < point_count) : (ri += 1) {
                try flags.append(gpa, f);
            }
        }
    }
    if (flags.items.len != point_count) return error.InvalidGlyf;

    // Read x-coordinates (delta-encoded).
    var xs = try std.ArrayList(f32).initCapacity(gpa, point_count);
    defer xs.deinit(gpa);
    {
        var acc: i32 = 0;
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            const f = flags.items[i];
            var dx: i32 = 0;
            if (f & 0x02 != 0) {
                // Short: magnitude is u8; sign bit is 0x10 (set = positive).
                if (off >= b.len) return error.InvalidGlyf;
                const mag: i32 = @intCast(b[off]);
                off += 1;
                dx = if (f & 0x10 != 0) mag else -mag;
            } else if (f & 0x10 != 0) {
                // Same as previous: delta 0.
                dx = 0;
            } else {
                // i16be delta.
                if (off + 2 > b.len) return error.InvalidGlyf;
                dx = @intCast(Sfnt.i16be(b, off));
                off += 2;
            }
            acc += dx;
            xs.appendAssumeCapacity(@floatFromInt(acc));
        }
    }

    // Read y-coordinates (delta-encoded; 0x04 short, 0x20 same).
    var ys = try std.ArrayList(f32).initCapacity(gpa, point_count);
    defer ys.deinit(gpa);
    {
        var acc: i32 = 0;
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            const f = flags.items[i];
            var dy: i32 = 0;
            if (f & 0x04 != 0) {
                // Short: magnitude is u8; sign bit is 0x20 (set = positive).
                if (off >= b.len) return error.InvalidGlyf;
                const mag: i32 = @intCast(b[off]);
                off += 1;
                dy = if (f & 0x20 != 0) mag else -mag;
            } else if (f & 0x20 != 0) {
                // Same as previous: delta 0.
                dy = 0;
            } else {
                // i16be delta.
                if (off + 2 > b.len) return error.InvalidGlyf;
                dy = @intCast(Sfnt.i16be(b, off));
                off += 2;
            }
            acc += dy;
            ys.appendAssumeCapacity(@floatFromInt(acc));
        }
    }

    // Build on-curve flag array.
    var on_curve = try std.ArrayList(bool).initCapacity(gpa, point_count);
    defer on_curve.deinit(gpa);
    for (flags.items) |f| {
        on_curve.appendAssumeCapacity(f & 0x01 != 0);
    }

    // Walk contours and emit segments via Builder.
    var bld = Builder.init(out);
    var contour_start: usize = 0;
    for (end_pts.items) |end_pt_raw| {
        const end_pt: usize = end_pt_raw;
        if (end_pt < contour_start) return error.InvalidGlyf;
        const count = end_pt - contour_start + 1;

        // Collect points for this contour.
        const pts_start = contour_start;
        const pts_end = end_pt + 1;
        const cx = xs.items[pts_start..pts_end];
        const cy = ys.items[pts_start..pts_end];
        const con = on_curve.items[pts_start..pts_end];

        // Find the start position: prefer the first on-curve point.
        var first_on: ?usize = null;
        {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (con[i]) {
                    first_on = i;
                    break;
                }
            }
        }

        if (first_on == null) {
            // All off-curve: implied midpoints everywhere; start at midpoint(last, 0).
            const lx = (cx[count - 1] + cx[0]) / 2.0;
            const ly = (cy[count - 1] + cy[0]) / 2.0;
            try bld.moveTo(gpa, lx, ly);
        } else {
            try bld.moveTo(gpa, cx[first_on.?], cy[first_on.?]);
        }

        const fo = first_on orelse (count - 1);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const cur = (fo + 1 + i) % count;
            const next = (fo + 2 + i) % count;

            if (con[cur]) {
                // on-curve: line from current position to this point
                try bld.lineTo(gpa, cx[cur], cy[cur]);
            } else {
                // off-curve control point; look ahead for the endpoint
                const end_x: f32 = if (con[next]) cx[next] else (cx[cur] + cx[next]) / 2.0;
                const end_y: f32 = if (con[next]) cy[next] else (cy[cur] + cy[next]) / 2.0;
                try bld.quadTo(gpa, cx[cur], cy[cur], end_x, end_y);
                // If we consumed an implied midpoint, the next loop iteration
                // will land on an on-curve point and emit a line; that is correct.
                // If we consumed a real on-curve endpoint, skip it.
                if (con[next]) {
                    i += 1;
                }
            }
        }

        bld.finish();
        contour_start = end_pt + 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readGlyph: triangle simple glyph" {
    // Hand-crafted minimal glyf table containing one simple glyph:
    // 3 on-curve points forming a right triangle at (0,0), (100,0), (0,200).
    //
    // glyf entry layout:
    //   [0..1]  numberOfContours = 1       (i16be)
    //   [2..3]  xMin = 0                   (i16be)
    //   [4..5]  yMin = 0                   (i16be)
    //   [6..7]  xMax = 100                 (i16be)
    //   [8..9]  yMax = 200                 (i16be)
    //   [10..11] endPtsOfContours[0] = 2   (u16be, 3 points indexed 0..2)
    //   [12..13] instructionLength = 0     (u16be)
    //   [14]    flags[0] = 0x37 (ON_CURVE | X_SHORT | Y_SHORT | X_SAME | Y_SAME | REPEAT=no)
    //             Actually: use 0x01 (ON_CURVE only) with i16be coords for clarity.
    //   We use i16be deltas (no SHORT bit) for simplicity:
    //     flags: 0x01 each (3 bytes)
    //     x-deltas: 0, 100, -100  as i16be (each 2 bytes = 6 bytes)
    //     y-deltas: 0, 0, 200     as i16be (each 2 bytes = 6 bytes)
    //
    // Total glyf bytes: 10 (header) + 2 (endPts) + 2 (instrLen) + 3 (flags) + 6 (x) + 6 (y) = 29.
    //
    // Points after decode:
    //   p0: x=0,   y=0
    //   p1: x=100, y=0
    //   p2: x=0,   y=200
    //
    // Contour walk starting at p0 (first on-curve):
    //   moveTo(0,0)
    //   p1 on-curve -> lineTo(100, 0)
    //   p2 on-curve -> lineTo(0, 200)
    //   close back to start: lineTo(0, 0)   [loop wraps around]
    // Expected: 1 contour, 3 segments (line to p1, line to p2, line back to p0).

    const glyf_bytes = [_]u8{
        // numberOfContours = 1
        0x00, 0x01,
        // xMin = 0
        0x00, 0x00,
        // yMin = 0
        0x00, 0x00,
        // xMax = 100
        0x00, 0x64,
        // yMax = 200
        0x00, 0xC8,
        // endPtsOfContours[0] = 2
        0x00, 0x02,
        // instructionLength = 0
        0x00, 0x00,
        // flags: 3 x ON_CURVE (0x01); no SHORT bits so coords are i16be
        0x01, 0x01,
        0x01,
        // x-deltas (i16be): 0, +100, -100
        0x00, 0x00, // p0 x-delta = 0  -> x=0
        0x00, 0x64, // p1 x-delta = 100 -> x=100
        0xFF, 0x9C, // p2 x-delta = -100 -> x=0
        // y-deltas (i16be): 0, 0, +200
        0x00, 0x00, // p0 y-delta = 0   -> y=0
        0x00, 0x00, // p1 y-delta = 0   -> y=0
        0x00, 0xC8, // p2 y-delta = 200 -> y=200
    };

    // loca (long format, index_to_loc_format=1): glyph 0 starts at 0, ends at glyf_bytes.len.
    var loca_bytes: [8]u8 = undefined;
    // entry 0: offset 0
    loca_bytes[0] = 0;
    loca_bytes[1] = 0;
    loca_bytes[2] = 0;
    loca_bytes[3] = 0;
    // entry 1: offset = glyf_bytes.len
    const glen: u32 = @intCast(glyf_bytes.len);
    loca_bytes[4] = @intCast((glen >> 24) & 0xFF);
    loca_bytes[5] = @intCast((glen >> 16) & 0xFF);
    loca_bytes[6] = @intCast((glen >> 8) & 0xFF);
    loca_bytes[7] = @intCast(glen & 0xFF);

    const loca = Loca{ .data = &loca_bytes, .index_to_loc_format = 1 };

    const gpa = std.testing.allocator;
    var out = Outline{};
    defer out.deinit(gpa);

    try readGlyph(gpa, &glyf_bytes, loca, 0, &out);

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);

    const ct = out.contours.items[0];
    // start point: p0 = (0, 0)
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.start.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.start.y, 0.001);

    // 3 segments: line to p1, line to p2, line back to p0
    try std.testing.expectEqual(@as(usize, 3), ct.segs.items.len);

    // seg 0: line to (100, 0)
    try std.testing.expect(ct.segs.items[0] == .line);
    try std.testing.expectApproxEqAbs(@as(f32, 100), ct.segs.items[0].line.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[0].line.y, 0.001);

    // seg 1: line to (0, 200)
    try std.testing.expect(ct.segs.items[1] == .line);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[1].line.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), ct.segs.items[1].line.y, 0.001);

    // seg 2: line back to (0, 0) - closing the contour
    try std.testing.expect(ct.segs.items[2] == .line);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[2].line.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[2].line.y, 0.001);
}

test "readGlyph: all-off-curve contour (diamond via implied midpoints)" {
    // Hand-crafted simple glyph: 1 contour, 4 off-curve points forming a diamond.
    // Points (all off-curve, flag 0x00):
    //   p0 = (0,   100)
    //   p1 = (100, 200)
    //   p2 = (200, 100)
    //   p3 = (100, 0)
    //
    // Implied on-curve starts (midpoints of adjacent off-curve pairs):
    //   start = mid(p3, p0) = (50, 50)
    //   m01   = mid(p0, p1) = (50, 150)
    //   m12   = mid(p1, p2) = (150, 150)
    //   m23   = mid(p2, p3) = (150, 50)
    //
    // Expected contour:
    //   moveTo(50, 50)                         <- mid(p3, p0)
    //   quadTo(p0=(0,100),   m01=(50,150))
    //   quadTo(p1=(100,200), m12=(150,150))
    //   quadTo(p2=(200,100), m23=(150,50))
    //   quadTo(p3=(100,0),   start=(50,50))    <- closing back to start
    //
    // glyf layout (long loca, index_to_loc_format=1):
    //   [0..1]  numberOfContours = 1  (i16be)
    //   [2..9]  bbox: xMin=0, yMin=0, xMax=200, yMax=200  (all i16be)
    //   [10..11] endPtsOfContours[0] = 3  (u16be)
    //   [12..13] instructionLength = 0  (u16be)
    //   [14..17] flags: 4 x 0x00 (off-curve, no short bits)
    //   x-deltas (i16be): 0, 0, 100, 100, 0  -- wait, we have 4 points.
    //   x-deltas: p0.x=0(delta 0), p1.x=100(delta+100), p2.x=200(delta+100), p3.x=100(delta-100)
    //   y-deltas: p0.y=100(delta+100), p1.y=200(delta+100), p2.y=100(delta-100), p3.y=0(delta-100)
    //
    // Total: 10 + 2 + 2 + 4 + 8 + 8 = 34 bytes.

    const glyf_bytes = [_]u8{
        // numberOfContours = 1
        0x00, 0x01,
        // xMin=0, yMin=0, xMax=200, yMax=200
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0xC8,
        0x00, 0xC8,
        // endPtsOfContours[0] = 3  (4 points, indices 0..3)
        0x00, 0x03,
        // instructionLength = 0
        0x00, 0x00,
        // flags: 4 x 0x00 (off-curve, i16be coords)
        0x00, 0x00,
        0x00, 0x00,
        // x-deltas (i16be): 0, +100, +100, -100
        0x00, 0x00, // p0 x-delta = 0   -> x=0
        0x00, 0x64, // p1 x-delta = 100 -> x=100
        0x00, 0x64, // p2 x-delta = 100 -> x=200
        0xFF, 0x9C, // p3 x-delta = -100-> x=100
        // y-deltas (i16be): +100, +100, -100, -100
        0x00, 0x64, // p0 y-delta = 100 -> y=100
        0x00, 0x64, // p1 y-delta = 100 -> y=200
        0xFF, 0x9C, // p2 y-delta = -100-> y=100
        0xFF, 0x9C, // p3 y-delta = -100-> y=0
    };

    var loca_bytes: [8]u8 = undefined;
    loca_bytes[0] = 0;
    loca_bytes[1] = 0;
    loca_bytes[2] = 0;
    loca_bytes[3] = 0;
    const glen: u32 = @intCast(glyf_bytes.len);
    loca_bytes[4] = @intCast((glen >> 24) & 0xFF);
    loca_bytes[5] = @intCast((glen >> 16) & 0xFF);
    loca_bytes[6] = @intCast((glen >> 8) & 0xFF);
    loca_bytes[7] = @intCast(glen & 0xFF);

    const loca = Loca{ .data = &loca_bytes, .index_to_loc_format = 1 };

    const gpa = std.testing.allocator;
    var out = Outline{};
    defer out.deinit(gpa);

    try readGlyph(gpa, &glyf_bytes, loca, 0, &out);

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);

    const ct = out.contours.items[0];

    // start = mid(p3, p0) = mid((100,0),(0,100)) = (50, 50)
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.start.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.start.y, 0.001);

    // 4 quad segments, one per off-curve point
    try std.testing.expectEqual(@as(usize, 4), ct.segs.items.len);

    // seg 0: quadTo(ctrl=p0=(0,100), end=mid(p0,p1)=(50,150))
    try std.testing.expect(ct.segs.items[0] == .quad);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[0].quad.ctrl.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), ct.segs.items[0].quad.ctrl.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.segs.items[0].quad.end.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), ct.segs.items[0].quad.end.y, 0.001);

    // seg 1: quadTo(ctrl=p1=(100,200), end=mid(p1,p2)=(150,150))
    try std.testing.expect(ct.segs.items[1] == .quad);
    try std.testing.expectApproxEqAbs(@as(f32, 100), ct.segs.items[1].quad.ctrl.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), ct.segs.items[1].quad.ctrl.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), ct.segs.items[1].quad.end.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), ct.segs.items[1].quad.end.y, 0.001);

    // seg 2: quadTo(ctrl=p2=(200,100), end=mid(p2,p3)=(150,50))
    try std.testing.expect(ct.segs.items[2] == .quad);
    try std.testing.expectApproxEqAbs(@as(f32, 200), ct.segs.items[2].quad.ctrl.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), ct.segs.items[2].quad.ctrl.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), ct.segs.items[2].quad.end.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.segs.items[2].quad.end.y, 0.001);

    // seg 3: quadTo(ctrl=p3=(100,0), end=start=(50,50))  -- closes back to start
    try std.testing.expect(ct.segs.items[3] == .quad);
    try std.testing.expectApproxEqAbs(@as(f32, 100), ct.segs.items[3].quad.ctrl.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ct.segs.items[3].quad.ctrl.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.segs.items[3].quad.end.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ct.segs.items[3].quad.end.y, 0.001);
}

test "readGlyph: composite glyph returns error" {
    // numberOfContours = -1 (0xFF 0xFF) -> CompositeGlyphUnsupported
    const glyf_bytes = [_]u8{
        0xFF, 0xFF, // numberOfContours = -1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0xC8, // bbox
    };
    var loca_bytes: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 10 };
    const loca = Loca{ .data = &loca_bytes, .index_to_loc_format = 1 };

    const gpa = std.testing.allocator;
    var out = Outline{};
    defer out.deinit(gpa);

    const err = readGlyph(gpa, &glyf_bytes, loca, 0, &out);
    try std.testing.expectError(error.CompositeGlyphUnsupported, err);
}
