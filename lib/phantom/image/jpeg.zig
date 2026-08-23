const std = @import("std");

pub const DecodeError = error{
    InvalidSignature,
    BadMarker,
    Unsupported,
    Truncated,
    BadData,
    OutOfMemory,
};

pub const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    td: u8 = 0,
    ta: u8 = 0,
};

pub const Frame = struct {
    precision: u8,
    width: u16,
    height: u16,
    components: [4]Component,
    num_components: u8,
};

// Canonical Huffman decode table (T.81 Figure F.16 DECODE).
// Built from the BITS[16] + VALS arrays in a DHT segment.
pub const HuffTable = struct {
    // mincode[l], maxcode[l], valptr[l] for code lengths 1..16 (index 1-based; [0] unused).
    mincode: [17]i32,
    maxcode: [17]i32,
    valptr: [17]u16,
    vals: [256]u8,
    nvals: u16,
};

// Build a canonical HuffTable from the 16-byte BITS array and the VALUES slice.
// Returns BadData if the sum of BITS exceeds 256 or if the table is otherwise malformed.
pub fn buildHuff(bits: *const [16]u8, vals: []const u8) DecodeError!HuffTable {
    var total: usize = 0;
    for (bits) |b| total += b;
    if (total > 256) return error.BadData;
    if (vals.len < total) return error.Truncated;

    var ht: HuffTable = undefined;
    ht.nvals = @intCast(total);
    // Copy the relevant values.
    @memcpy(ht.vals[0..total], vals[0..total]);

    // Canonical code assignment (T.81 Annex C/F).
    // code starts at 0; for each length: assign MINCODE, advance by count, left-shift moving on.
    var code: i32 = 0;
    var val_idx: u16 = 0;
    for (1..17) |l| {
        const cnt: u8 = bits[l - 1];
        if (cnt == 0) {
            ht.mincode[l] = 0;
            ht.maxcode[l] = -1; // no codes of this length
            ht.valptr[l] = val_idx;
        } else {
            ht.mincode[l] = code;
            ht.maxcode[l] = code + @as(i32, cnt) - 1;
            ht.valptr[l] = val_idx;
            code += cnt;
            val_idx += cnt;
        }
        code = code * 2; // left shift for the next length
    }

    return ht;
}

// Decode one symbol from the bit reader using the canonical DECODE algorithm (Figure F.16).
pub fn huffDecode(ht: *const HuffTable, br: *BitReader) DecodeError!u8 {
    var code: i32 = 0;
    for (1..17) |l| {
        const bit = try br.getBit();
        code = (code << 1) | @as(i32, bit);
        if (code <= ht.maxcode[l]) {
            if (code < ht.mincode[l]) return error.BadData;
            const idx = ht.valptr[l] + @as(u16, @intCast(code - ht.mincode[l]));
            if (idx >= ht.nvals) return error.BadData;
            return ht.vals[idx];
        }
    }
    return error.BadData;
}

// MSB-first bit reader over an entropy-coded segment.
// Handles 0xFF00 byte stuffing and marker detection.
pub const BitReader = struct {
    data: []const u8,
    pos: usize,
    bits: u32,
    cnt: u5,
    marker: ?u8 = null,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data, .pos = 0, .bits = 0, .cnt = 0, .marker = null };
    }

    // Refill the bit buffer by reading the next byte (with 0xFF00 destuffing and marker handling).
    fn refill(self: *BitReader) void {
        // Already at/past a marker or end of data.
        if (self.marker != null) return;
        if (self.pos >= self.data.len) return;

        const byte = self.data[self.pos];
        self.pos += 1;

        if (byte == 0xFF) {
            if (self.pos >= self.data.len) {
                // Truncated: treat as marker/stop.
                self.marker = 0x00;
                return;
            }
            const next = self.data[self.pos];
            if (next == 0x00) {
                // Stuffed 0xFF byte: consume both, yield 0xFF.
                self.pos += 1;
                self.bits = (self.bits << 8) | 0xFF;
                self.cnt += 8;
            } else {
                // Any non-zero byte after 0xFF is a marker; stop producing bits.
                self.marker = next;
                self.pos += 1;
            }
        } else {
            self.bits = (self.bits << 8) | byte;
            self.cnt += 8;
        }
    }

    pub fn getBit(self: *BitReader) DecodeError!u1 {
        if (self.cnt == 0) {
            if (self.marker != null) return 0; // past marker: fill with 0 bits
            self.refill();
            if (self.cnt == 0) return 0; // end of data or marker
        }
        self.cnt -= 1;
        return @intCast((self.bits >> self.cnt) & 1);
    }

    // Read up to 16 bits MSB-first.
    pub fn getBits(self: *BitReader, n: u5) DecodeError!u32 {
        var result: u32 = 0;
        var remaining: u5 = n;
        while (remaining > 0) {
            if (self.cnt == 0) {
                if (self.marker != null) {
                    // Past marker: fill with 0 bits.
                    remaining = 0;
                    break;
                }
                self.refill();
                if (self.cnt == 0) break;
            }
            const take: u5 = if (self.cnt < remaining) self.cnt else remaining;
            self.cnt -= take;
            result = (result << take) | ((self.bits >> self.cnt) & ((@as(u32, 1) << take) - 1));
            remaining -= take;
        }
        return result;
    }

    // Handle an embedded RSTn marker after a restart interval.
    // Verifies self.marker is 0xD0..0xD7, clears the bit buffer, and clears
    // self.marker so the next refill call reads fresh entropy bytes.
    // In refill(), when 0xFF is seen followed by a non-zero byte, both bytes are
    // consumed (pos advances past both) before marker is set.  So pos is already
    // past the 2-byte RSTn marker; no additional skip is needed here.
    pub fn restart(self: *BitReader) DecodeError!void {
        const m = self.marker orelse return error.BadData;
        if (m < 0xD0 or m > 0xD7) return error.BadData;
        self.bits = 0;
        self.cnt = 0;
        self.marker = null;
    }
};

// T.81 F.2.2.1 receive_extend: read `size` bits and sign-extend.
pub fn receiveExtend(br: *BitReader, size: u5) DecodeError!i32 {
    if (size == 0) return 0;
    // Guard the i32 shifts below against overflow on a malformed size category.
    // Valid JPEG magnitude categories are <= 16 (baseline DC <= 11, AC <= 10);
    // anything larger is corrupt input and must not panic the shift.
    if (size > 16) return error.BadData;
    const v: i32 = @intCast(try br.getBits(size));
    // If the top bit is 0, the value is negative: v - (2^size - 1).
    if (v < (@as(i32, 1) << (size - 1))) {
        return v - ((@as(i32, 1) << size) - 1);
    }
    return v;
}

// A single per-component sample plane produced by decodeScan.
// data is row-major, w*h bytes.  Caller frees data with the same allocator.
pub const Plane = struct {
    data: []u8,
    w: usize,
    h: usize,
};

// Internal decode context populated by the marker walk.
// J2 adds Huffman tables; J4 adds scan_start (byte offset of entropy-coded data
// within the original JPEG bytes slice passed to parseHeaders).
pub const Ctx = struct {
    frame: Frame,
    quant: [4][64]u16,
    restart_interval: u16 = 0,
    dc: [4]?HuffTable = [_]?HuffTable{null} ** 4,
    ac: [4]?HuffTable = [_]?HuffTable{null} ** 4,
    // Offset into the original bytes[] at which entropy-coded data begins
    // (immediately after the SOS segment payload).  0 when no SOS was parsed yet.
    scan_start: usize = 0,
    // True when the frame header was SOF2 (progressive DCT).
    progressive: bool = false,
};

// Marker codes (the byte after 0xFF).
const M_SOI: u8 = 0xD8;
const M_EOI: u8 = 0xD9;
const M_SOF0: u8 = 0xC0; // Baseline sequential DCT
const M_SOF1: u8 = 0xC1; // Extended sequential DCT
const M_SOF2: u8 = 0xC2; // Progressive DCT
const M_SOF3: u8 = 0xC3; // Lossless sequential
const M_SOF5: u8 = 0xC5;
const M_SOF6: u8 = 0xC6;
const M_SOF7: u8 = 0xC7;
const M_SOF9: u8 = 0xC9; // Arithmetic
const M_SOF10: u8 = 0xCA;
const M_SOF11: u8 = 0xCB;
const M_SOF13: u8 = 0xCD;
const M_SOF14: u8 = 0xCE;
const M_SOF15: u8 = 0xCF;
const M_DHT: u8 = 0xC4;
const M_DQT: u8 = 0xDB;
const M_DRI: u8 = 0xDD;
const M_SOS: u8 = 0xDA;
const M_COM: u8 = 0xFE;
// APP0-APPF: 0xE0-0xEF

// Read a 2-byte big-endian u16 from bytes at pos. Returns Truncated if out of range.
fn readU16BE(bytes: []const u8, pos: usize) DecodeError!u16 {
    if (pos + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(u16, bytes[pos..][0..2], .big);
}

// Parse DQT segment payload into ctx.quant tables.
// A DQT payload may contain multiple tables packed back to back.
fn parseDQT(ctx: *Ctx, payload: []const u8) DecodeError!void {
    var off: usize = 0;
    while (off < payload.len) {
        if (off + 1 > payload.len) return error.Truncated;
        const pq_tq = payload[off];
        off += 1;
        const pq: u8 = pq_tq >> 4;
        const tq: u8 = pq_tq & 0x0F;
        if (tq > 3) return error.BadData;
        if (pq == 0) {
            // 8-bit: 64 byte values
            if (off + 64 > payload.len) return error.Truncated;
            for (0..64) |i| {
                ctx.quant[tq][i] = payload[off + i];
            }
            off += 64;
        } else if (pq == 1) {
            // 16-bit: 64 big-endian u16 values
            if (off + 128 > payload.len) return error.Truncated;
            for (0..64) |i| {
                ctx.quant[tq][i] = std.mem.readInt(u16, payload[off + i * 2 ..][0..2], .big);
            }
            off += 128;
        } else {
            return error.BadData;
        }
    }
}

// Parse DRI segment payload (2-byte restart interval).
fn parseDRI(ctx: *Ctx, payload: []const u8) DecodeError!void {
    if (payload.len < 2) return error.Truncated;
    ctx.restart_interval = std.mem.readInt(u16, payload[0..2], .big);
}

// Parse SOF0 or SOF2 segment payload into ctx.frame.
// progressive=true sets ctx.progressive; the binary frame layout is identical.
fn parseSOF0(ctx: *Ctx, payload: []const u8, progressive: bool) DecodeError!void {
    ctx.progressive = progressive;
    if (payload.len < 6) return error.Truncated;
    const precision = payload[0];
    if (precision != 8) return error.Unsupported;
    const height = std.mem.readInt(u16, payload[1..3], .big);
    const width = std.mem.readInt(u16, payload[3..5], .big);
    const nf = payload[5];
    if (nf == 0 or nf > 3) return error.Unsupported;
    if (payload.len < 6 + @as(usize, nf) * 3) return error.Truncated;
    var frame: Frame = .{
        .precision = precision,
        .width = width,
        .height = height,
        .components = undefined,
        .num_components = nf,
    };
    // Zero-initialise all component slots.
    for (&frame.components) |*c| {
        c.* = .{ .id = 0, .h = 0, .v = 0, .tq = 0 };
    }
    for (0..nf) |i| {
        const base = 6 + i * 3;
        const id = payload[base];
        const hv = payload[base + 1];
        const tq_c = payload[base + 2];
        const hh = hv >> 4;
        const vv = hv & 0x0F;
        // Validate the sampling factors (1..4) and the quant-table selector (0..3).
        // A malformed frame with tq > 3 would otherwise index ctx.quant ([4] tables)
        // out of bounds in decodeScan; h/v of 0 or > 4 is invalid per T.81.
        if (hh == 0 or hh > 4 or vv == 0 or vv > 4) return error.Unsupported;
        if (tq_c > 3) return error.BadData;
        frame.components[i] = .{
            .id = id,
            .h = hh,
            .v = vv,
            .tq = tq_c,
        };
    }
    ctx.frame = frame;
}

// Parse a DHT segment payload into ctx.dc/ac tables.
// A DHT payload may contain multiple tables packed back to back.
fn parseDHT(ctx: *Ctx, payload: []const u8) DecodeError!void {
    var off: usize = 0;
    while (off < payload.len) {
        if (off + 1 > payload.len) return error.Truncated;
        const tc_th = payload[off];
        off += 1;
        const tc: u8 = tc_th >> 4;
        const th: u8 = tc_th & 0x0F;
        if (tc > 1) return error.BadData;
        if (th > 3) return error.BadData;

        // Read the 16 BITS bytes.
        if (off + 16 > payload.len) return error.Truncated;
        const bits: *const [16]u8 = payload[off..][0..16];
        off += 16;

        // Count total values expected.
        var total: usize = 0;
        for (bits) |b| total += b;
        if (total > 256) return error.BadData;

        if (off + total > payload.len) return error.Truncated;
        const vals = payload[off .. off + total];
        off += total;

        const ht = try buildHuff(bits, vals);
        if (tc == 0) {
            ctx.dc[th] = ht;
        } else {
            ctx.ac[th] = ht;
        }
    }
}

// Parse an SOS segment payload: attach td/ta selectors to frame components.
// For baseline (progressive=false): validates Ss=0, Se=63, Ah=Al=0.
// For progressive: skips that validation (parseScanHeader handles it later).
fn parseSOS(ctx: *Ctx, payload: []const u8) DecodeError!void {
    if (payload.len < 1) return error.Truncated;
    const ns: u8 = payload[0];
    if (ns == 0 or ns > 4) return error.BadData;
    const expected_len: usize = 1 + @as(usize, ns) * 2 + 3;
    if (payload.len < expected_len) return error.Truncated;

    var off: usize = 1;
    for (0..ns) |_| {
        const cs = payload[off];
        off += 1;
        const td_ta = payload[off];
        off += 1;
        const td: u8 = td_ta >> 4;
        const ta: u8 = td_ta & 0x0F;
        // Find the matching frame component and attach td/ta.
        var found = false;
        for (0..ctx.frame.num_components) |ci| {
            if (ctx.frame.components[ci].id == cs) {
                ctx.frame.components[ci].td = td;
                ctx.frame.components[ci].ta = ta;
                found = true;
                break;
            }
        }
        if (!found) return error.BadData;
    }

    // Ss, Se, Ah|Al
    const ss = payload[off];
    const se = payload[off + 1];
    const ah_al = payload[off + 2];
    // Progressive scans use different Ss/Se/Ah/Al ranges; skip strict baseline check.
    if (!ctx.progressive) {
        if (ss != 0 or se != 63 or ah_al != 0) return error.Unsupported;
    }
}

// Progressive scan header parsed from each SOS in a progressive stream.
pub const ScanHeader = struct {
    num_comps: u8,
    // comp_idx[i] = index into ctx.frame.components for scan component i.
    comp_idx: [4]u8,
    ss: u8,
    se: u8,
    ah: u8,
    al: u8,
};

// Parse an SOS payload into a ScanHeader for the progressive driver.
// Sets the matched frame component td/ta selectors as a side effect (same as parseSOS).
fn parseScanHeader(ctx: *Ctx, payload: []const u8) DecodeError!ScanHeader {
    if (payload.len < 1) return error.Truncated;
    const ns: u8 = payload[0];
    if (ns == 0 or ns > 4) return error.BadData;
    const expected_len: usize = 1 + @as(usize, ns) * 2 + 3;
    if (payload.len < expected_len) return error.Truncated;

    var sh: ScanHeader = .{
        .num_comps = ns,
        .comp_idx = [_]u8{0} ** 4,
        .ss = 0,
        .se = 0,
        .ah = 0,
        .al = 0,
    };

    var off: usize = 1;
    for (0..ns) |i| {
        const cs = payload[off];
        off += 1;
        const td_ta = payload[off];
        off += 1;
        const td: u8 = td_ta >> 4;
        const ta: u8 = td_ta & 0x0F;
        var found = false;
        for (0..ctx.frame.num_components) |ci| {
            if (ctx.frame.components[ci].id == cs) {
                ctx.frame.components[ci].td = td;
                ctx.frame.components[ci].ta = ta;
                sh.comp_idx[i] = @intCast(ci);
                found = true;
                break;
            }
        }
        if (!found) return error.BadData;
    }

    const ss = payload[off];
    const se = payload[off + 1];
    const ah_al = payload[off + 2];
    const ah: u8 = ah_al >> 4;
    const al: u8 = ah_al & 0x0F;

    // Validate spectral band + successive approximation fields.
    if (ss > 63 or se > 63) return error.BadData;
    if (ss > se and !(ss == 0 and se == 0)) return error.BadData;
    if (ah > 13 or al > 13) return error.BadData;

    sh.ss = ss;
    sh.se = se;
    sh.ah = ah;
    sh.al = al;
    return sh;
}

// Per-component coefficient buffer for progressive decoding.
// data holds blocks_w * blocks_h * 64 i32 values, zero-initialised.
// Coefficients are stored in zig-zag order per 8x8 block.
pub const CoeffPlane = struct {
    data: []i32,
    blocks_w: usize,
    blocks_h: usize,
};

// Allocate per-component coefficient buffers.
// Returns a slice of CoeffPlane (one per frame component), zero-initialised.
// Caller must free with freeCoeffs.
fn allocCoeffs(gpa: std.mem.Allocator, ctx: *const Ctx) DecodeError![]CoeffPlane {
    const nc = ctx.frame.num_components;
    if (nc == 0) return error.BadData;

    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        if (c.h > hmax) hmax = c.h;
        if (c.v > vmax) vmax = c.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const w: u32 = ctx.frame.width;
    const h: u32 = ctx.frame.height;
    if (w == 0 or h == 0) return error.BadData;

    const mcu_w: u32 = @as(u32, hmax) * 8;
    const mcu_h: u32 = @as(u32, vmax) * 8;
    const mcus_x: u32 = (w + mcu_w - 1) / mcu_w;
    const mcus_y: u32 = (h + mcu_h - 1) / mcu_h;

    const coeffs = try gpa.alloc(CoeffPlane, nc);
    errdefer gpa.free(coeffs);

    var allocated: usize = 0;
    errdefer {
        for (0..allocated) |ci| {
            gpa.free(coeffs[ci].data);
        }
    }

    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        const bw: usize = @as(usize, mcus_x) * @as(usize, c.h);
        const bh: usize = @as(usize, mcus_y) * @as(usize, c.v);
        const buf = try gpa.alloc(i32, bw * bh * 64);
        @memset(buf, 0);
        coeffs[ci] = .{ .data = buf, .blocks_w = bw, .blocks_h = bh };
        allocated += 1;
    }

    return coeffs;
}

// Free coefficient buffers allocated by allocCoeffs.
fn freeCoeffs(gpa: std.mem.Allocator, coeffs: []CoeffPlane) void {
    for (coeffs) |cp| gpa.free(cp.data);
    gpa.free(coeffs);
}

// Convert accumulated coefficient buffers to sample planes via dequant + IDCT.
// Returns one Plane per component; caller must free with freePlanes.
fn coeffsToPlanes(gpa: std.mem.Allocator, ctx: *const Ctx, coeffs: []const CoeffPlane) DecodeError![]Plane {
    const nc = ctx.frame.num_components;
    if (nc == 0) return error.BadData;

    const planes = try gpa.alloc(Plane, nc);
    errdefer gpa.free(planes);

    var allocated: usize = 0;
    errdefer {
        for (0..allocated) |ci| {
            gpa.free(planes[ci].data);
        }
    }

    for (0..nc) |ci| {
        const cp = coeffs[ci];
        const bw = cp.blocks_w;
        const bh = cp.blocks_h;
        const pw = bw * 8;
        const ph = bh * 8;
        const plane_data = try gpa.alloc(u8, pw * ph);
        planes[ci] = .{ .data = plane_data, .w = pw, .h = ph };
        allocated += 1;

        const qt = &ctx.quant[ctx.frame.components[ci].tq];
        for (0..bh) |by| {
            for (0..bw) |bx| {
                const blk = by * bw + bx;
                const base = blk * 64;
                if (base + 64 > cp.data.len) return error.BadData;
                const coeff_block: *const [64]i32 = cp.data[base..][0..64];
                var block_out: [64]u8 = undefined;
                dequantIdct(coeff_block, qt, &block_out);

                const px: usize = bx * 8;
                const py: usize = by * 8;
                for (0..8) |row| {
                    const dst_base = (py + row) * pw + px;
                    const src_base = row * 8;
                    @memcpy(plane_data[dst_base .. dst_base + 8], block_out[src_base .. src_base + 8]);
                }
            }
        }
    }

    return planes;
}

// Free planes allocated by coeffsToPlanes or decodeScan.
fn freePlanes(gpa: std.mem.Allocator, planes: []Plane) void {
    for (planes) |p| gpa.free(p.data);
    gpa.free(planes);
}

// Convert decoded sample planes to an RGBA image.
// Shared by both baseline and progressive paths.
// Handles grayscale (nc=1) and YCbCr (nc=3); other counts return Unsupported.
fn planesToRgba(gpa: std.mem.Allocator, ctx: *const Ctx, planes: []const Plane) DecodeError![]u8 {
    const nc = ctx.frame.num_components;
    const width: u32 = ctx.frame.width;
    const height: u32 = ctx.frame.height;
    if (width == 0 or height == 0) return error.BadData;

    const rgba_len = @as(usize, width) * @as(usize, height) * 4;
    const rgba = try gpa.alloc(u8, rgba_len);
    errdefer gpa.free(rgba);

    if (nc == 1) {
        // Grayscale: Y,Y,Y,255.
        const plane = planes[0];
        for (0..height) |y| {
            for (0..width) |x| {
                const sample = plane.data[y * plane.w + x];
                const o = (y * width + x) * 4;
                rgba[o + 0] = sample;
                rgba[o + 1] = sample;
                rgba[o + 2] = sample;
                rgba[o + 3] = 255;
            }
        }
    } else if (nc == 3) {
        // YCbCr with chroma upsampling via replication.
        var hmax: u8 = 0;
        var vmax: u8 = 0;
        for (0..3) |ci| {
            const c = ctx.frame.components[ci];
            if (c.h > hmax) hmax = c.h;
            if (c.v > vmax) vmax = c.v;
        }
        const p0 = planes[0];
        const p1 = planes[1];
        const p2 = planes[2];
        const c0 = ctx.frame.components[0];
        const c1 = ctx.frame.components[1];
        const c2 = ctx.frame.components[2];
        for (0..height) |y| {
            for (0..width) |x| {
                const sy0 = y * c0.v / vmax;
                const sx0 = x * c0.h / hmax;
                const sy1 = y * c1.v / vmax;
                const sx1 = x * c1.h / hmax;
                const sy2 = y * c2.v / vmax;
                const sx2 = x * c2.h / hmax;
                const luma = p0.data[sy0 * p0.w + sx0];
                const cb = p1.data[sy1 * p1.w + sx1];
                const cr = p2.data[sy2 * p2.w + sx2];
                const rgb = ycbcrToRgb(luma, cb, cr);
                const o = (y * width + x) * 4;
                rgba[o + 0] = rgb.r;
                rgba[o + 1] = rgb.g;
                rgba[o + 2] = rgb.b;
                rgba[o + 3] = 255;
            }
        }
    } else {
        return error.Unsupported;
    }

    return rgba;
}

// Scan forward from `from` in `bytes` to find the offset of a real marker
// (0xFF followed by a non-stuffing, non-RSTn byte).
// Stuffed bytes (0xFF 0x00) and restart markers (0xFF 0xD0-0xD7) are skipped.
// Returns the offset of the 0xFF byte of the real marker, or bytes.len if none found.
fn findNextMarker(bytes: []const u8, from: usize) usize {
    var i = from;
    while (i + 1 < bytes.len) {
        if (bytes[i] == 0xFF) {
            const next = bytes[i + 1];
            if (next == 0x00) {
                // Stuffed 0xFF: skip both bytes.
                i += 2;
                continue;
            }
            if (next >= 0xD0 and next <= 0xD7) {
                // RSTn: part of entropy data, skip.
                i += 2;
                continue;
            }
            // Real marker found.
            return i;
        }
        i += 1;
    }
    return bytes.len;
}

// Decode one progressive scan's entropy into coefficient buffers.
// Dispatches to the four T.81 G.1.2 progressive Huffman algorithms:
//   DC first  (ss==0, ah==0): interleaved MCU order, shifts new DC coeff left by al.
//   DC refine (ss==0, ah>0):  interleaved MCU order, OR-in a refinement bit.
//   AC first  (ss>0,  ah==0): P3 (returns Unsupported).
//   AC refine (ss>0,  ah>0):  P4 (returns Unsupported).
fn decodeProgressiveScan(
    ctx: *Ctx,
    scan: *const ScanHeader,
    entropy: []const u8,
    coeffs: []CoeffPlane,
) DecodeError!void {
    if (scan.ss == 0) {
        // DC scan: Se must be 0 for a well-formed progressive stream.
        if (scan.se != 0) return error.BadData;
        if (scan.ah == 0) {
            try dcFirst(ctx, scan, entropy, coeffs);
        } else {
            try dcRefine(ctx, scan, entropy, coeffs);
        }
    } else {
        // AC scan: must be single-component (non-interleaved).
        if (scan.num_comps != 1) return error.BadData;
        if (scan.ah == 0) {
            try acFirst(ctx, scan, entropy, coeffs); // P3: AC first
        } else {
            try acRefine(ctx, scan, entropy, coeffs); // P4: AC refine
        }
    }
}

// AC first (Ss>0, Se>0, Ah==0): single-component, that component's block raster order.
// Decodes AC coefficients for a progressive AC-first scan per T.81 G.1.2.
// eobrun: end-of-band run counter, shared across blocks within the scan (reset at restart).
// shift = Al: point transform applied to each placed coefficient.
// Block iteration uses the REAL (non-padded) block dimensions for the component,
// but indexes into the MCU-padded coeff plane by row stride (blocks_w).
// Control flow follows stb_image stbi__jpeg_decode_block_prog_ac (no fast-AC path).
fn acFirst(
    ctx: *Ctx,
    scan: *const ScanHeader,
    entropy: []const u8,
    coeffs: []CoeffPlane,
) DecodeError!void {
    const ci = scan.comp_idx[0];
    const nc = ctx.frame.num_components;
    if (ci >= nc) return error.BadData;
    const c = ctx.frame.components[ci];
    if (c.ta > 3 or ctx.ac[c.ta] == null) return error.BadData;
    const ac_ht = &ctx.ac[c.ta].?;

    // Compute Hmax/Vmax over ALL frame components for the non-interleaved block grid.
    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |fi| {
        const fc = ctx.frame.components[fi];
        if (fc.h > hmax) hmax = fc.h;
        if (fc.v > vmax) vmax = fc.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const width: u32 = ctx.frame.width;
    const height: u32 = ctx.frame.height;

    // Non-interleaved AC: iterate over the REAL block grid for this component.
    // comp_pixel_w = ceil(width * c.h / Hmax); comp_pixel_h = ceil(height * c.v / Vmax).
    // w2 = ceil(comp_pixel_w / 8); h2 = ceil(comp_pixel_h / 8).
    const comp_pixel_w: u32 = (@as(u32, width) * @as(u32, c.h) + @as(u32, hmax) - 1) / @as(u32, hmax);
    const comp_pixel_h: u32 = (@as(u32, height) * @as(u32, c.v) + @as(u32, vmax) - 1) / @as(u32, vmax);
    const w2: u32 = (comp_pixel_w + 7) / 8;
    const h2: u32 = (comp_pixel_h + 7) / 8;

    // Guard: the real dims must not exceed the padded plane dims.
    if (w2 > coeffs[ci].blocks_w or h2 > coeffs[ci].blocks_h) return error.BadData;
    // Guard: scan spectral band must be within [1,63].
    if (scan.ss == 0 or scan.se > 63 or scan.ss > scan.se) return error.BadData;

    const shift: u5 = @intCast(scan.al);
    var br = BitReader.init(entropy);
    var eobrun: u32 = 0;
    var block_count: u32 = 0;
    const ri = ctx.restart_interval;

    for (0..h2) |by| {
        for (0..w2) |bx| {
            const blk = by * coeffs[ci].blocks_w + bx;
            // Guard: blk*64+63 must be within data bounds.
            if (blk * 64 + 63 >= coeffs[ci].data.len) return error.BadData;

            if (eobrun > 0) {
                eobrun -= 1;
            } else {
                var k: usize = scan.ss;
                while (k <= scan.se) {
                    const rs = try huffDecode(ac_ht, &br);
                    const r: u8 = rs >> 4;
                    const s: u5 = @intCast(rs & 0x0F);
                    if (s == 0) {
                        if (r < 15) {
                            // EOBn: end-of-band run of (1 << r) + extra bits.
                            eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                            if (r != 0) eobrun += try br.getBits(@intCast(r));
                            break;
                        }
                        // r == 15: ZRL, skip 16 zeros (k may exceed se, loop exits).
                        k += 16;
                    } else {
                        k += r;
                        if (k > scan.se) return error.BadData;
                        coeffs[ci].data[blk * 64 + k] = (try receiveExtend(&br, s)) << shift;
                        k += 1;
                    }
                }
            }

            block_count += 1;

            if (ri != 0 and block_count % ri == 0) {
                // Reset eobrun and resync bit reader past RSTn marker.
                eobrun = 0;
                br.bits = 0;
                br.cnt = 0;
                if (br.marker == null) br.refill();
                if (br.marker) |m| {
                    if (m >= 0xD0 and m <= 0xD7) {
                        try br.restart();
                    } else {
                        return;
                    }
                }
            }
        }
    }
}

// AC refine (Ss>0, Ah>0): single-component, that component's block raster order.
// Refines previously-placed AC coefficients: applies a correction bit to each nonzero
// coeff and optionally inserts a new +/-bit at a zero position after a run-length gap.
// eobrun spans blocks within the scan (reset at scan start and at each restart).
// Block iteration mirrors acFirst: non-interleaved w2 x h2 grid, blk = by*blocks_w + bx.
// Algorithm is stb_image stbi__jpeg_decode_block_prog_ac (refinement branch; fast-AC path removed).
// See: https://github.com/nothings/stb/blob/master/stb_image.h
fn acRefine(
    ctx: *Ctx,
    scan: *const ScanHeader,
    entropy: []const u8,
    coeffs: []CoeffPlane,
) DecodeError!void {
    const ci = scan.comp_idx[0];
    const nc = ctx.frame.num_components;
    if (ci >= nc) return error.BadData;
    const c = ctx.frame.components[ci];
    if (c.ta > 3 or ctx.ac[c.ta] == null) return error.BadData;
    const ac_ht = &ctx.ac[c.ta].?;

    // Compute Hmax/Vmax over ALL frame components for the non-interleaved block grid.
    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |fi| {
        const fc = ctx.frame.components[fi];
        if (fc.h > hmax) hmax = fc.h;
        if (fc.v > vmax) vmax = fc.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const width: u32 = ctx.frame.width;
    const height: u32 = ctx.frame.height;

    // Non-interleaved AC: iterate over the REAL block grid for this component.
    const comp_pixel_w: u32 = (@as(u32, width) * @as(u32, c.h) + @as(u32, hmax) - 1) / @as(u32, hmax);
    const comp_pixel_h: u32 = (@as(u32, height) * @as(u32, c.v) + @as(u32, vmax) - 1) / @as(u32, vmax);
    const w2: u32 = (comp_pixel_w + 7) / 8;
    const h2: u32 = (comp_pixel_h + 7) / 8;

    // Guard: the real dims must not exceed the padded plane dims.
    if (w2 > coeffs[ci].blocks_w or h2 > coeffs[ci].blocks_h) return error.BadData;
    // Guard: scan spectral band must be within [1,63].
    if (scan.ss == 0 or scan.se > 63 or scan.ss > scan.se) return error.BadData;

    // al <= 13 validated by parseScanHeader; 1 << al is safe in i32.
    const bit: i32 = @as(i32, 1) << @intCast(scan.al);

    var br = BitReader.init(entropy);
    var eobrun: u32 = 0;
    var block_count: u32 = 0;
    const ri = ctx.restart_interval;

    for (0..h2) |by| {
        for (0..w2) |bx| {
            const blk = by * coeffs[ci].blocks_w + bx;
            // Guard: blk*64+63 must be within data bounds.
            if (blk * 64 + 63 >= coeffs[ci].data.len) return error.BadData;
            const base = blk * 64;

            // The block-entry eobrun state decides the path (mutually exclusive, per
            // stb_image). If this block STARTS inside an eob run, only apply correction
            // bits + consume one run unit. Otherwise read Huffman symbols; a symbol that
            // decodes an EOB sets eobrun for FOLLOWING blocks and does THIS block's
            // corrections via the r=64 sweep, so it must NOT also run the trailing path.
            if (eobrun > 0) {
                // Block entirely within an eob run: correct remaining nonzeros, consume one.
                var k: usize = scan.ss;
                while (k <= scan.se) : (k += 1) {
                    const p = base + k;
                    if (coeffs[ci].data[p] != 0) {
                        if ((try br.getBit()) == 1 and (coeffs[ci].data[p] & bit) == 0) {
                            coeffs[ci].data[p] += if (coeffs[ci].data[p] > 0) bit else -bit;
                        }
                    }
                }
                eobrun -= 1;
            } else {
                var k: usize = scan.ss;
                while (k <= scan.se) {
                    const rs = try huffDecode(ac_ht, &br);
                    var r: i32 = @intCast(rs >> 4);
                    const s: u32 = rs & 0x0F;
                    var newval: i32 = 0;
                    if (s == 0) {
                        if (r < 15) {
                            // EOBn: set eobrun and force inner loop to sweep to end.
                            eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                            if (r != 0) eobrun += try br.getBits(@intCast(r));
                            r = 64; // force inner loop to run to end of band (corrections only, no placement)
                        }
                        // else r == 15: ZRL equivalent in refine context; s==0 newval stays 0,
                        // inner loop skips 16 zero-history coefficients before next symbol.
                    } else {
                        // Refinement bit: magnitude MUST be 1.
                        if (s != 1) return error.BadData;
                        newval = if ((try br.getBit()) == 1) bit else -bit;
                    }
                    // Inner loop: advance k over the spectral band.
                    // For each already-nonzero coeff: read a correction bit and, if set and
                    // the bit is not already present, bump the coeff by +/-bit.
                    // For zero coeffs: count down r; when r reaches 0 at a zero position,
                    // place newval (if nonzero) and break to read the next Huffman symbol.
                    while (k <= scan.se) {
                        const p = base + k;
                        k += 1;
                        if (coeffs[ci].data[p] != 0) {
                            if ((try br.getBit()) == 1 and (coeffs[ci].data[p] & bit) == 0) {
                                coeffs[ci].data[p] += if (coeffs[ci].data[p] > 0) bit else -bit;
                            }
                        } else {
                            if (r == 0) {
                                if (newval != 0) coeffs[ci].data[p] = newval;
                                break;
                            }
                            r -= 1;
                        }
                    }
                }
            }

            block_count += 1;

            if (ri != 0 and block_count % ri == 0) {
                // Reset eobrun and resync bit reader past RSTn marker.
                eobrun = 0;
                br.bits = 0;
                br.cnt = 0;
                if (br.marker == null) br.refill();
                if (br.marker) |m| {
                    if (m >= 0xD0 and m <= 0xD7) {
                        try br.restart();
                    } else {
                        return;
                    }
                }
            }
        }
    }
}

// DC first (Ss==0, Se==0, Ah==0): interleaved MCU order.
// Decodes a DC magnitude category, extends the diff, accumulates a per-component predictor,
// and stores the shifted coefficient into coeffs[ci].data[blk*64 + 0].
// Point transform: coeff = pred << al.
fn dcFirst(
    ctx: *Ctx,
    scan: *const ScanHeader,
    entropy: []const u8,
    coeffs: []CoeffPlane,
) DecodeError!void {
    // Compute Hmax/Vmax over ALL frame components for MCU geometry.
    const nc = ctx.frame.num_components;
    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        if (c.h > hmax) hmax = c.h;
        if (c.v > vmax) vmax = c.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const w: u32 = ctx.frame.width;
    const h: u32 = ctx.frame.height;
    const mcu_w: u32 = @as(u32, hmax) * 8;
    const mcu_h: u32 = @as(u32, vmax) * 8;
    const mcus_x: u32 = (w + mcu_w - 1) / mcu_w;
    const mcus_y: u32 = (h + mcu_h - 1) / mcu_h;

    // Validate all scan components have a DC table before beginning.
    for (0..scan.num_comps) |si| {
        const ci = scan.comp_idx[si];
        if (ci >= nc) return error.BadData;
        const c = ctx.frame.components[ci];
        if (c.td > 3 or ctx.dc[c.td] == null) return error.BadData;
    }

    var br = BitReader.init(entropy);
    // Per scan-component DC predictors indexed by scan slot [0..num_comps).
    var pred = [_]i32{0} ** 4;
    var mcu_count: u32 = 0;
    const ri = ctx.restart_interval;

    for (0..mcus_y) |my| {
        for (0..mcus_x) |mx| {
            for (0..scan.num_comps) |si| {
                const ci = scan.comp_idx[si];
                const c = ctx.frame.components[ci];
                const dc_ht = &ctx.dc[c.td].?;
                for (0..c.v) |by| {
                    for (0..c.h) |bx| {
                        const blk = (my * c.v + by) * coeffs[ci].blocks_w + (mx * c.h + bx);
                        if (blk * 64 + 63 >= coeffs[ci].data.len) return error.BadData;

                        const t_raw = try huffDecode(dc_ht, &br);
                        if (t_raw > 16) return error.BadData;
                        const t: u5 = @intCast(t_raw);
                        const diff = try receiveExtend(&br, t);
                        pred[si] += diff;
                        coeffs[ci].data[blk * 64 + 0] = pred[si] << @as(u5, @intCast(scan.al));
                    }
                }
            }

            mcu_count += 1;

            if (ri != 0 and mcu_count % ri == 0) {
                // Reset all DC predictors.
                @memset(&pred, 0);
                // Drain bits and resync past the RSTn marker.
                br.bits = 0;
                br.cnt = 0;
                if (br.marker == null) br.refill();
                if (br.marker) |m| {
                    if (m >= 0xD0 and m <= 0xD7) {
                        try br.restart();
                    } else {
                        return;
                    }
                }
            }
        }
    }
}

// DC refine (Ss==0, Se==0, Ah>0): interleaved MCU order.
// For each block in MCU order, reads one bit; if 1, ORs in (1 << al) into coeff[blk][0].
// No predictor used.
fn dcRefine(
    ctx: *Ctx,
    scan: *const ScanHeader,
    entropy: []const u8,
    coeffs: []CoeffPlane,
) DecodeError!void {
    const nc = ctx.frame.num_components;
    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        if (c.h > hmax) hmax = c.h;
        if (c.v > vmax) vmax = c.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const w: u32 = ctx.frame.width;
    const h: u32 = ctx.frame.height;
    const mcu_w: u32 = @as(u32, hmax) * 8;
    const mcu_h: u32 = @as(u32, vmax) * 8;
    const mcus_x: u32 = (w + mcu_w - 1) / mcu_w;
    const mcus_y: u32 = (h + mcu_h - 1) / mcu_h;

    for (0..scan.num_comps) |si| {
        const ci = scan.comp_idx[si];
        if (ci >= nc) return error.BadData;
    }

    var br = BitReader.init(entropy);
    var mcu_count: u32 = 0;
    const ri = ctx.restart_interval;
    const al_shift: u5 = @intCast(scan.al);

    for (0..mcus_y) |my| {
        for (0..mcus_x) |mx| {
            for (0..scan.num_comps) |si| {
                const ci = scan.comp_idx[si];
                const c = ctx.frame.components[ci];
                for (0..c.v) |by| {
                    for (0..c.h) |bx| {
                        const blk = (my * c.v + by) * coeffs[ci].blocks_w + (mx * c.h + bx);
                        if (blk * 64 + 63 >= coeffs[ci].data.len) return error.BadData;

                        if ((try br.getBit()) == 1) {
                            coeffs[ci].data[blk * 64 + 0] |= (@as(i32, 1) << al_shift);
                        }
                    }
                }
            }

            mcu_count += 1;

            if (ri != 0 and mcu_count % ri == 0) {
                // Realign bit reader past RSTn (no DC predictor state to reset for refine).
                br.bits = 0;
                br.cnt = 0;
                if (br.marker == null) br.refill();
                if (br.marker) |m| {
                    if (m >= 0xD0 and m <= 0xD7) {
                        try br.restart();
                    } else {
                        return;
                    }
                }
            }
        }
    }
}

// Progressive JPEG driver skeleton.
// Walks all SOS segments from ctx.scan_start, dispatches each via decodeProgressiveScan
// (stub in P1, filled in P2-P4), then converts accumulated coefficients to planes.
fn decodeProgressive(gpa: std.mem.Allocator, ctx: *Ctx, bytes: []const u8) DecodeError![]Plane {
    const coeffs = try allocCoeffs(gpa, ctx);
    errdefer freeCoeffs(gpa, coeffs);

    // Re-walk all markers from right after SOI. Each SOS decodes one progressive
    // scan; DHT/DQT/DRI segments (which can appear before the first scan and be
    // redefined between scans) update the tables in place.
    var pos: usize = 2; // skip SOI

    while (pos < bytes.len) {
        if (pos + 1 > bytes.len) return error.Truncated;
        if (bytes[pos] != 0xFF) return error.BadMarker;
        pos += 1;

        // Skip padding 0xFF bytes.
        while (pos < bytes.len and bytes[pos] == 0xFF) {
            pos += 1;
        }
        if (pos >= bytes.len) return error.Truncated;
        const code = bytes[pos];
        pos += 1;

        switch (code) {
            0x00 => return error.BadMarker,
            M_EOI => break,
            M_SOI => return error.BadMarker,
            0xD0...0xD7 => {},
            M_SOS => {
                const seg_len = try readU16BE(bytes, pos);
                if (seg_len < 2) return error.BadData;
                const payload_len: usize = seg_len - 2;
                pos += 2;
                if (pos + payload_len > bytes.len) return error.Truncated;
                const payload = bytes[pos .. pos + payload_len];
                pos += payload_len;

                const sh = try parseScanHeader(ctx, payload);

                // Locate the entropy segment: everything from pos up to the next real marker.
                const marker_off = findNextMarker(bytes, pos);
                const entropy = bytes[pos..marker_off];

                try decodeProgressiveScan(ctx, &sh, entropy, coeffs);

                // Advance pos to the next marker (findNextMarker returned offset of 0xFF).
                pos = marker_off;
            },
            else => {
                const seg_len = try readU16BE(bytes, pos);
                if (seg_len < 2) return error.BadData;
                const payload_len: usize = seg_len - 2;
                pos += 2;
                if (pos + payload_len > bytes.len) return error.Truncated;
                const payload = bytes[pos .. pos + payload_len];
                pos += payload_len;

                // Tables may be (re)defined before the first scan and between scans;
                // parse them wherever they appear so each scan sees the current tables.
                switch (code) {
                    M_DHT => try parseDHT(ctx, payload),
                    M_DQT => try parseDQT(ctx, payload),
                    M_DRI => try parseDRI(ctx, payload),
                    else => {},
                }
            },
        }
    }

    const planes = try coeffsToPlanes(gpa, ctx, coeffs);
    freeCoeffs(gpa, coeffs);
    return planes;
}

// Walk the JPEG marker sequence from the start of bytes.
// Fills ctx with SOF0, DQT, DRI, DHT data.
// On encountering SOS, parses the SOS payload (attaches td/ta to frame components,
// validates baseline parameters) and records ctx.scan_start as the byte offset
// of the entropy-coded data.  Stops at SOS or EOI.
pub fn parseHeaders(bytes: []const u8) DecodeError!Ctx {
    if (bytes.len < 2) return error.InvalidSignature;
    if (bytes[0] != 0xFF or bytes[1] != M_SOI) return error.InvalidSignature;

    var ctx: Ctx = .{
        .frame = .{
            .precision = 0,
            .width = 0,
            .height = 0,
            .components = [_]Component{.{ .id = 0, .h = 0, .v = 0, .tq = 0 }} ** 4,
            .num_components = 0,
        },
        .quant = [_][64]u16{[_]u16{0} ** 64} ** 4,
        .restart_interval = 0,
    };

    var pos: usize = 2; // skip SOI
    while (pos < bytes.len) {
        // Every marker starts with 0xFF.
        if (pos + 1 > bytes.len) return error.Truncated;
        if (bytes[pos] != 0xFF) return error.BadMarker;
        pos += 1;

        // Skip padding 0xFF bytes (the spec allows multiple 0xFF before the code).
        while (pos < bytes.len and bytes[pos] == 0xFF) {
            pos += 1;
        }
        if (pos >= bytes.len) return error.Truncated;
        const code = bytes[pos];
        pos += 1;

        switch (code) {
            0x00 => {
                // 0xFF00 is a stuffed byte in scan data; not valid in the header stream.
                return error.BadMarker;
            },
            M_EOI => break,
            M_SOI => {
                // Nested SOI is not expected; treat as bad.
                return error.BadMarker;
            },
            // RSTn markers (0xD0-0xD7): no payload, skip.
            0xD0...0xD7 => {},
            M_SOS => {
                // Read the SOS segment length so we can parse the payload and
                // locate the entropy-coded data that follows.
                const seg_len = try readU16BE(bytes, pos);
                if (seg_len < 2) return error.BadData;
                const payload_len: usize = seg_len - 2;
                pos += 2;
                if (pos + payload_len > bytes.len) return error.Truncated;
                const payload = bytes[pos .. pos + payload_len];
                pos += payload_len;
                // Parse the SOS payload: attach td/ta to frame components.
                try parseSOS(&ctx, payload);
                // Entropy-coded data begins immediately after the SOS payload.
                ctx.scan_start = pos;
                break;
            },
            // Unsupported SOF variants (lossless, differential, arithmetic).
            M_SOF1, M_SOF3, M_SOF5, M_SOF6, M_SOF7, M_SOF9, M_SOF10, M_SOF11, M_SOF13, M_SOF14, M_SOF15 => {
                return error.Unsupported;
            },
            else => {
                // All remaining markers have a 2-byte length field (length includes the 2 bytes).
                const seg_len = try readU16BE(bytes, pos);
                if (seg_len < 2) return error.BadData;
                const payload_len: usize = seg_len - 2;
                pos += 2;
                if (pos + payload_len > bytes.len) return error.Truncated;
                const payload = bytes[pos .. pos + payload_len];
                pos += payload_len;

                switch (code) {
                    M_SOF0 => try parseSOF0(&ctx, payload, false),
                    M_SOF2 => try parseSOF0(&ctx, payload, true),
                    M_DQT => try parseDQT(&ctx, payload),
                    M_DRI => try parseDRI(&ctx, payload),
                    M_DHT => try parseDHT(&ctx, payload),
                    M_COM => {}, // Comment: skip.
                    // APP0-APPF: skip.
                    0xE0...0xEF => {},
                    else => {
                        // Unknown marker with length field: skip the payload.
                    },
                }
            },
        }
    }

    return ctx;
}

// Decode one 8x8 block of DCT coefficients from the bit reader.
// dc_ht: DC Huffman table (required).
// ac_ht: AC Huffman table (required).
// pred: per-component DC predictor (updated in place).
// out_zz: output buffer of 64 coefficients in zig-zag order.
pub fn decodeBlock(
    br: *BitReader,
    dc_ht: *const HuffTable,
    ac_ht: *const HuffTable,
    pred: *i32,
    out_zz: *[64]i32,
) DecodeError!void {
    @memset(out_zz, 0);

    // DC coefficient: magnitude category t, then receive_extend for the diff.
    // Guard the category before the u5 cast: a malformed DC table can decode to a
    // symbol > 31, which would panic @intCast (and > 16 is not a valid category).
    const t_raw = try huffDecode(dc_ht, br);
    if (t_raw > 16) return error.BadData;
    const t: u5 = @intCast(t_raw);
    const diff = try receiveExtend(br, t);
    pred.* += diff;
    out_zz[0] = pred.*;

    // AC coefficients: k runs from 1 to 63.
    var k: usize = 1;
    while (k < 64) {
        const rs = try huffDecode(ac_ht, br);
        const r: u8 = rs >> 4;
        const s: u5 = @intCast(rs & 0x0F);
        if (s == 0) {
            if (r == 15) {
                // ZRL: skip 16 zero coefficients.
                k += 16;
            } else {
                // EOB: remaining coefficients are all zero.
                break;
            }
        } else {
            k += r;
            if (k > 63) return error.BadData;
            out_zz[k] = try receiveExtend(br, s);
            k += 1;
        }
    }
}

// Decode the entropy-coded scan data starting at entropy_bytes.
// Produces one Plane per frame component.  The caller must free each plane.data
// and the returned slice itself using gpa.
pub fn decodeScan(
    gpa: std.mem.Allocator,
    ctx: *const Ctx,
    entropy_bytes: []const u8,
) DecodeError![]Plane {
    const nc = ctx.frame.num_components;
    if (nc == 0) return error.BadData;

    // Compute Hmax and Vmax.
    var hmax: u8 = 0;
    var vmax: u8 = 0;
    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        if (c.h > hmax) hmax = c.h;
        if (c.v > vmax) vmax = c.v;
    }
    if (hmax == 0 or vmax == 0) return error.BadData;

    const w: u32 = ctx.frame.width;
    const h: u32 = ctx.frame.height;
    const mcu_w: u32 = @as(u32, hmax) * 8;
    const mcu_h: u32 = @as(u32, vmax) * 8;
    const mcus_x: u32 = (w + mcu_w - 1) / mcu_w;
    const mcus_y: u32 = (h + mcu_h - 1) / mcu_h;

    // Allocate output planes.
    const planes = try gpa.alloc(Plane, nc);
    errdefer gpa.free(planes);

    var planes_allocated: usize = 0;
    errdefer {
        for (0..planes_allocated) |ci| {
            gpa.free(planes[ci].data);
        }
    }

    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        const pw: usize = @as(usize, mcus_x) * @as(usize, c.h) * 8;
        const ph: usize = @as(usize, mcus_y) * @as(usize, c.v) * 8;
        planes[ci] = .{
            .data = try gpa.alloc(u8, pw * ph),
            .w = pw,
            .h = ph,
        };
        planes_allocated += 1;
    }

    // Guard: ensure each component has valid Huffman tables.
    for (0..nc) |ci| {
        const c = ctx.frame.components[ci];
        if (c.td > 3 or ctx.dc[c.td] == null) return error.BadData;
        if (c.ta > 3 or ctx.ac[c.ta] == null) return error.BadData;
    }

    // Per-component DC predictors.
    var dc_pred: [4]i32 = [_]i32{0} ** 4;

    var br = BitReader.init(entropy_bytes);
    var mcu_count: u32 = 0;
    const ri = ctx.restart_interval;

    scan: for (0..mcus_y) |my| {
        for (0..mcus_x) |mx| {
            // For each component, for each data unit within the MCU.
            for (0..nc) |ci| {
                const c = ctx.frame.components[ci];
                const dc_ht = &ctx.dc[c.td].?;
                const ac_ht = &ctx.ac[c.ta].?;

                for (0..c.v) |by| {
                    for (0..c.h) |bx| {
                        var coeffs: [64]i32 = undefined;
                        try decodeBlock(&br, dc_ht, ac_ht, &dc_pred[ci], &coeffs);

                        // Dequantize + IDCT -> 8x8 pixel block.
                        const qt = &ctx.quant[c.tq];
                        var block_out: [64]u8 = undefined;
                        dequantIdct(&coeffs, qt, &block_out);

                        // Blit the block into the component plane.
                        const px: usize = (mx * @as(usize, c.h) + bx) * 8;
                        const py: usize = (my * @as(usize, c.v) + by) * 8;
                        const pw = planes[ci].w;
                        for (0..8) |row| {
                            const dst_base = (py + row) * pw + px;
                            const src_base = row * 8;
                            @memcpy(planes[ci].data[dst_base .. dst_base + 8], block_out[src_base .. src_base + 8]);
                        }
                    }
                }
            }

            mcu_count += 1;

            // Restart interval handling: after every ri MCUs, consume the RSTn marker.
            if (ri != 0 and mcu_count % ri == 0) {
                // Drain any remaining bits from the byte buffer (byte realignment).
                br.bits = 0;
                br.cnt = 0;
                // Surface the marker if it has not been encountered yet.
                if (br.marker == null) {
                    br.refill();
                }
                if (br.marker) |m| {
                    if (m >= 0xD0 and m <= 0xD7) {
                        try br.restart();
                    } else {
                        // Non-restart marker (e.g. EOI): stop decoding cleanly.
                        break :scan;
                    }
                }
                // Reset all DC predictors after each restart interval.
                @memset(&dc_pred, 0);
            }
        }
    }

    return planes;
}

// TEST-ONLY: append a JPEG segment (0xFF code + 2-byte BE length + payload) to buf.
// SOI/EOI (no-payload markers) must be appended manually.
fn appendSeg(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), code: u8, payload: []const u8) !void {
    const seg_len: u16 = @intCast(payload.len + 2);
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, code);
    var len_be: [2]u8 = undefined;
    std.mem.writeInt(u16, &len_be, seg_len, .big);
    try buf.appendSlice(gpa, &len_be);
    try buf.appendSlice(gpa, payload);
}

test "parseHeaders: SOF0 + DQT parsed correctly" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // DQT: table id 0, 8-bit (Pq=0, Tq=0 -> byte 0x00), 64 bytes all 0x01.
    {
        var dqt_payload: [65]u8 = undefined;
        dqt_payload[0] = 0x00; // Pq=0 | Tq=0
        @memset(dqt_payload[1..65], 0x01);
        try appendSeg(gpa, &buf, M_DQT, &dqt_payload);
    }

    // SOF0: precision=8, height=16, width=16, Nf=3
    // Y: id=1 h=2 v=2 tq=0; Cb: id=2 h=1 v=1 tq=0; Cr: id=3 h=1 v=1 tq=0
    {
        var sof_payload: [17]u8 = undefined;
        sof_payload[0] = 8; // precision
        std.mem.writeInt(u16, sof_payload[1..3], 16, .big); // height
        std.mem.writeInt(u16, sof_payload[3..5], 16, .big); // width
        sof_payload[5] = 3; // Nf
        // Component Y
        sof_payload[6] = 1; // id
        sof_payload[7] = (2 << 4) | 2; // h=2 v=2
        sof_payload[8] = 0; // tq=0
        // Component Cb
        sof_payload[9] = 2;
        sof_payload[10] = (1 << 4) | 1;
        sof_payload[11] = 0;
        // Component Cr
        sof_payload[12] = 3;
        sof_payload[13] = (1 << 4) | 1;
        sof_payload[14] = 0;
        try appendSeg(gpa, &buf, M_SOF0, sof_payload[0..15]);
    }

    // SOS stub to terminate the header walk (with minimal payload).
    {
        const sos_payload = [_]u8{ 3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0 };
        try appendSeg(gpa, &buf, M_SOS, &sos_payload);
    }

    const ctx = try parseHeaders(buf.items);

    try std.testing.expectEqual(@as(u16, 16), ctx.frame.width);
    try std.testing.expectEqual(@as(u16, 16), ctx.frame.height);
    try std.testing.expectEqual(@as(u8, 3), ctx.frame.num_components);
    try std.testing.expectEqual(@as(u8, 2), ctx.frame.components[0].h);
    try std.testing.expectEqual(@as(u8, 2), ctx.frame.components[0].v);
    try std.testing.expectEqual(@as(u8, 1), ctx.frame.components[1].h);
    try std.testing.expectEqual(@as(u16, 0), ctx.restart_interval);

    for (ctx.quant[0]) |v| {
        try std.testing.expectEqual(@as(u16, 1), v);
    }
}

// P1: SOF2 is now ACCEPTED (progressive flag set, correct dims).
// Previously this asserted error.Unsupported; that is now WRONG and updated.
test "parseHeaders: SOF2 accepted with progressive=true and correct frame" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // SOF2 (progressive) with a minimal payload.
    {
        var sof2_payload: [9]u8 = undefined;
        sof2_payload[0] = 8; // precision
        std.mem.writeInt(u16, sof2_payload[1..3], 16, .big); // height=16
        std.mem.writeInt(u16, sof2_payload[3..5], 32, .big); // width=32
        sof2_payload[5] = 1; // Nf=1
        sof2_payload[6] = 1; // component id=1
        sof2_payload[7] = (1 << 4) | 1; // h=1 v=1
        sof2_payload[8] = 0; // tq=0
        try appendSeg(gpa, &buf, M_SOF2, sof2_payload[0..9]);
    }

    // SOS stub: progressive SOS with Ss=0 Se=0 Ah=0 Al=0.
    {
        const sos_payload = [_]u8{ 1, 1, 0x00, 0, 0, 0 };
        try appendSeg(gpa, &buf, M_SOS, &sos_payload);
    }

    const ctx = try parseHeaders(buf.items);
    try std.testing.expect(ctx.progressive);
    try std.testing.expectEqual(@as(u16, 32), ctx.frame.width);
    try std.testing.expectEqual(@as(u16, 16), ctx.frame.height);
    try std.testing.expectEqual(@as(u8, 1), ctx.frame.num_components);
}

test "parseHeaders: SOF0 with out-of-range quant selector is rejected (no OOB)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // SOF0 with a single component whose tq = 5 (only quant tables 0..3 exist).
    // Without the guard this would index ctx.quant[5] out of bounds in decodeScan.
    var sof_payload: [9]u8 = undefined;
    sof_payload[0] = 8; // precision
    std.mem.writeInt(u16, sof_payload[1..3], 8, .big); // height
    std.mem.writeInt(u16, sof_payload[3..5], 8, .big); // width
    sof_payload[5] = 1; // Nf
    sof_payload[6] = 1; // id
    sof_payload[7] = (1 << 4) | 1; // h=1 v=1
    sof_payload[8] = 5; // tq = 5 (invalid)
    try appendSeg(gpa, &buf, M_SOF0, &sof_payload);

    try std.testing.expectError(error.BadData, parseHeaders(buf.items));
}

test "parseHeaders: SOF0 with zero sampling factor is rejected" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    var sof_payload: [9]u8 = undefined;
    sof_payload[0] = 8;
    std.mem.writeInt(u16, sof_payload[1..3], 8, .big);
    std.mem.writeInt(u16, sof_payload[3..5], 8, .big);
    sof_payload[5] = 1;
    sof_payload[6] = 1;
    sof_payload[7] = 0; // h=0 v=0 (invalid)
    sof_payload[8] = 0;
    try appendSeg(gpa, &buf, M_SOF0, &sof_payload);

    try std.testing.expectError(error.Unsupported, parseHeaders(buf.items));
}

test "parseHeaders: Truncated on segment length past buffer" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // APP0 with a claimed length of 100 bytes but only 4 bytes of payload follow.
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, 0xE0); // APP0
    try buf.append(gpa, 0x00);
    try buf.append(gpa, 102); // length = 102, payload = 100 bytes claimed
    // Only 4 bytes provided.
    try buf.append(gpa, 0xAA);
    try buf.append(gpa, 0xBB);
    try buf.append(gpa, 0xCC);
    try buf.append(gpa, 0xDD);

    try std.testing.expectError(error.Truncated, parseHeaders(buf.items));
}

// J2 tests: HuffTable build + decode, receiveExtend, BitReader, parseDHT via parseHeaders.

test "buildHuff + huffDecode: two length-2 codes" {
    // BITS = {0,2,0,...}: two codes of length 2, no other lengths.
    // VALS = {0x05, 0x06}.
    // Canonical assignment: code 00 -> 0x05, code 01 -> 0x06.
    var bits = [_]u8{0} ** 16;
    bits[1] = 2; // 2 codes of length 2
    const vals = [_]u8{ 0x05, 0x06 };

    const ht = try buildHuff(&bits, &vals);
    try std.testing.expectEqual(@as(u16, 2), ht.nvals);

    // Bitstream: 00 01 (packed into a single byte: 0b00_01_xxxx = 0x10 with junk in low bits).
    // We only consume 4 bits total so the junk does not matter.
    const stream = [_]u8{0b00010000};
    var br = BitReader.init(&stream);

    const sym0 = try huffDecode(&ht, &br);
    try std.testing.expectEqual(@as(u8, 0x05), sym0);

    const sym1 = try huffDecode(&ht, &br);
    try std.testing.expectEqual(@as(u8, 0x06), sym1);
}

test "receiveExtend: sign-extension cases from T.81 F.2.2.1" {
    // extend(3, 0b101) = 5 (positive: top bit set)
    {
        const stream = [_]u8{0b10100000};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, 5), try receiveExtend(&br, 3));
    }
    // extend(3, 0b001) = 1 - 7 = -6
    {
        const stream = [_]u8{0b00100000};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, -6), try receiveExtend(&br, 3));
    }
    // extend(3, 0b000) = 0 - 7 = -7
    {
        const stream = [_]u8{0b00000000};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, -7), try receiveExtend(&br, 3));
    }
    // extend(1, 0b1) = 1
    {
        const stream = [_]u8{0b10000000};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, 1), try receiveExtend(&br, 1));
    }
    // extend(1, 0b0) = -1
    {
        const stream = [_]u8{0b00000000};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, -1), try receiveExtend(&br, 1));
    }
    // size==0 -> 0
    {
        const stream = [_]u8{0b11111111};
        var br = BitReader.init(&stream);
        try std.testing.expectEqual(@as(i32, 0), try receiveExtend(&br, 0));
    }
}

test "BitReader: 0xFF00 destuffing produces 8 set bits per stuffed pair" {
    // 0xFF 0x00 0xFF 0x00 -> two stuffed 0xFF bytes -> 16 bits of 1s.
    const stream = [_]u8{ 0xFF, 0x00, 0xFF, 0x00 };
    var br = BitReader.init(&stream);

    var count_ones: u32 = 0;
    for (0..16) |_| {
        const bit = try br.getBit();
        count_ones += bit;
    }
    try std.testing.expectEqual(@as(u32, 16), count_ones);
    try std.testing.expect(br.marker == null);
}

test "BitReader: RST marker sets marker field and stops" {
    // 0xFF 0xD0 is RST0. The reader should stop and record marker = 0xD0.
    const stream = [_]u8{ 0xFF, 0xD0 };
    var br = BitReader.init(&stream);

    // The reader should not produce any real bits (or only produce 0-fill).
    // After the refill attempt the marker field is set.
    _ = try br.getBit(); // triggers refill which hits the marker
    try std.testing.expectEqual(@as(?u8, 0xD0), br.marker);
}

// Standard JPEG zig-zag scan order: natural[zigzag[k]] = coeff_in_file[k].
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// Precomputed cosine table: cos_tab[u][x] = cos((2x+1) * u * pi / 16)
// Indexed as [frequency u 0..7][sample x 0..7].
const cos_tab: [8][8]f32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [8][8]f32 = undefined;
    for (0..8) |u| {
        for (0..8) |x| {
            const arg = @as(f32, @floatFromInt(2 * x + 1)) * @as(f32, @floatFromInt(u)) * std.math.pi / 16.0;
            t[u][x] = @cos(arg);
        }
    }
    break :blk t;
};

// Scaling factor for frequency 0: C(0) = 1/sqrt(2), C(u>0) = 1.
const c0_scale: f32 = 1.0 / std.math.sqrt2;

// 1D IDCT in place on an 8-element slice.
// s(x) = 0.5 * sum_{u=0..7} C(u) * S(u) * cos((2x+1) * u * pi / 16)
fn idct1d(s: *[8]f32) void {
    var out: [8]f32 = undefined;
    for (0..8) |x| {
        var sum: f32 = 0.0;
        for (0..8) |u| {
            const cu: f32 = if (u == 0) c0_scale else 1.0;
            sum += cu * s[u] * cos_tab[u][x];
        }
        out[x] = 0.5 * sum;
    }
    s.* = out;
}

// In-place separable 8x8 IDCT: row pass then column pass.
// Combined 0.5 * 0.5 = 1/4 factor gives the standard 2D IDCT scaling.
pub fn idct8x8(block: *[64]f32) void {
    // Row pass: transform each of the 8 rows.
    for (0..8) |row| {
        var r: [8]f32 = undefined;
        for (0..8) |col| r[col] = block[row * 8 + col];
        idct1d(&r);
        for (0..8) |col| block[row * 8 + col] = r[col];
    }
    // Column pass: transform each of the 8 columns.
    for (0..8) |col| {
        var c: [8]f32 = undefined;
        for (0..8) |row| c[row] = block[row * 8 + col];
        idct1d(&c);
        for (0..8) |row| block[row * 8 + col] = c[row];
    }
}

// Dequantize, IDCT, and level-shift/clamp a single 8x8 block.
// coeffs_zz: 64 DCT coefficients in zig-zag order (from the scan decoder).
// qt_zz: 64 quantization table values in zig-zag order (from DQT).
// out: natural raster order output (row-major: out[y*8 + x]), values [0,255].
pub fn dequantIdct(coeffs_zz: *const [64]i32, qt_zz: *const [64]u16, out: *[64]u8) void {
    // Build natural-order f32 block: multiply coeff * quant at each zig-zag position,
    // then scatter to natural position via the zigzag table.
    var block: [64]f32 = undefined;
    for (0..64) |k| {
        const nat = zigzag[k];
        block[nat] = @as(f32, @floatFromInt(coeffs_zz[k])) * @as(f32, @floatFromInt(qt_zz[k]));
    }
    idct8x8(&block);
    // Level shift (+128), round, clamp to [0,255].
    for (0..64) |i| {
        const v = block[i] + 128.0;
        const clamped = std.math.clamp(v, 0.0, 255.0);
        out[i] = @intFromFloat(@round(clamped));
    }
}

test "zigzag first row matches the spec" {
    try std.testing.expectEqual([_]u8{ 0, 1, 8, 16, 9, 2, 3, 10 }, zigzag[0..8].*);
}

test "dequantIdct DC-only block is uniform D/8 + 128" {
    var q: [64]u16 = undefined;
    @memset(&q, 1);
    // DC coeff (zig-zag position 0) = 64, all AC = 0. IDCT -> uniform 8, +128 -> 136.
    var c: [64]i32 = undefined;
    @memset(&c, 0);
    c[0] = 64;
    var out: [64]u8 = undefined;
    dequantIdct(&c, &q, &out);
    for (out) |px| try std.testing.expectEqual(@as(u8, 136), px);
    // D=8 -> 129; D=0 -> 128; D=-128 -> 112.
    c[0] = 8;
    dequantIdct(&c, &q, &out);
    for (out) |px| try std.testing.expectEqual(@as(u8, 129), px);
    c[0] = 0;
    dequantIdct(&c, &q, &out);
    for (out) |px| try std.testing.expectEqual(@as(u8, 128), px);
    c[0] = -128;
    dequantIdct(&c, &q, &out);
    for (out) |px| try std.testing.expectEqual(@as(u8, 112), px);
}

test "dequantIdct single AC coeff F(1,0)=D varies in x, uniform in y" {
    // F(1,0)=D only, rest 0.
    // f(x,y) = (1/4) * C(1) * C(0) * D * cos((2x+1)*pi/16) * cos(0)
    //        = (1/4) * (1/sqrt2) * D * cos((2x+1)*pi/16)
    // After +128 level shift: out(x,y) = round(clamp((D/(4*sqrt2)) * cos((2x+1)*pi/16) + 128))
    // Independent of y. Use D=64 for a clear signal.
    const D: f32 = 64.0;
    var q: [64]u16 = undefined;
    @memset(&q, 1);
    var c: [64]i32 = undefined;
    @memset(&c, 0);
    // zig-zag position 1 corresponds to natural position 1, which is F(1,0) (row=0, col=1).
    c[1] = @intFromFloat(D);
    var out: [64]u8 = undefined;
    dequantIdct(&c, &q, &out);

    // Compute expected values for x=0 and x=1 from the formula.
    const scale = D / (4.0 * std.math.sqrt2);
    for (0..8) |y| {
        for (0..2) |x| {
            const arg = @as(f32, @floatFromInt(2 * x + 1)) * std.math.pi / 16.0;
            const expected_f = scale * @cos(arg) + 128.0;
            const expected_clamped = std.math.clamp(expected_f, 0.0, 255.0);
            const expected: u8 = @intFromFloat(@round(expected_clamped));
            const actual = out[y * 8 + x];
            // Allow tolerance of 1 due to f32 rounding.
            const diff = if (actual > expected) actual - expected else expected - actual;
            try std.testing.expect(diff <= 1);
        }
    }
    // Also verify the output is independent of y: all rows should match row 0.
    for (1..8) |y| {
        for (0..8) |x| {
            try std.testing.expectEqual(out[x], out[y * 8 + x]);
        }
    }
}

// J4 tests: decodeBlock, DC prediction, ZRL run, single-MCU decodeScan.

// Build a minimal HuffTable for testing: one or two length-2 codes.
// DC table: codes `00`->val0, `01`->val1.
fn testDcTable(val0: u8, val1: u8) !HuffTable {
    var bits = [_]u8{0} ** 16;
    bits[1] = 2; // two codes of length 2
    const vals = [_]u8{ val0, val1 };
    return buildHuff(&bits, &vals);
}

// AC table: `00`->0x00 (EOB).
fn testAcTableEobOnly() !HuffTable {
    var bits = [_]u8{0} ** 16;
    bits[1] = 1;
    const vals = [_]u8{0x00};
    return buildHuff(&bits, &vals);
}

// AC table: `00`->0x00 (EOB), `010`->0xF0 (ZRL), `011`->0x11 (r=1 s=1).
fn testAcTableWithRun() !HuffTable {
    var bits = [_]u8{0} ** 16;
    bits[1] = 1; // one length-2 code: 0x00 (EOB)
    bits[2] = 2; // two length-3 codes: 0xF0 (ZRL), 0x11 (r=1,s=1)
    const vals = [_]u8{ 0x00, 0xF0, 0x11 };
    return buildHuff(&bits, &vals);
}

test "decodeBlock: DC diff=2 EOB produces coeffs[0]=2 rest zero" {
    // DC table: `00`->0x02 (cat 2), `01`->0x01 (cat 1).
    // AC table: `00`->0x00 (EOB).
    const dc_ht = try testDcTable(0x02, 0x01);
    const ac_ht = try testAcTableEobOnly();

    // Bitstream: DC code=`00`(cat2), magnitude bits=`10`(=2, positive), AC EOB=`00`.
    // Bits: 0 0 1 0 0 0 -> packed MSB first into byte 0: 0b00100000 = 0x20.
    const stream = [_]u8{ 0x20, 0x00 };
    var br = BitReader.init(&stream);
    var pred: i32 = 0;
    var zz: [64]i32 = undefined;
    try decodeBlock(&br, &dc_ht, &ac_ht, &pred, &zz);

    try std.testing.expectEqual(@as(i32, 2), pred);
    try std.testing.expectEqual(@as(i32, 2), zz[0]);
    for (zz[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "decodeBlock: DC prediction carries across two blocks" {
    // DC table: `00`->0x02 (cat 2), `01`->0x01 (cat 1).
    // AC table: `00`->0x00 (EOB).
    const dc_ht = try testDcTable(0x02, 0x01);
    const ac_ht = try testAcTableEobOnly();

    // Block1: DC code=`00`(cat2), bits=`10`(diff=2), AC EOB=`00`.
    // Block2: DC code=`01`(cat1), bits=`1`(diff=1), AC EOB=`00`.
    // Bits: 00 10 00 | 01 1 00 = 00100001 10 0xxxxx
    // Byte0: 0b00100001 = 0x21
    // Byte1: 0b10000000 = 0x80 (remaining bits don't matter)
    const stream = [_]u8{ 0x21, 0x80 };
    var br = BitReader.init(&stream);
    var pred: i32 = 0;
    var zz: [64]i32 = undefined;

    try decodeBlock(&br, &dc_ht, &ac_ht, &pred, &zz);
    try std.testing.expectEqual(@as(i32, 2), pred);
    try std.testing.expectEqual(@as(i32, 2), zz[0]);

    try decodeBlock(&br, &dc_ht, &ac_ht, &pred, &zz);
    try std.testing.expectEqual(@as(i32, 3), pred); // 2 + 1
    try std.testing.expectEqual(@as(i32, 3), zz[0]);
    for (zz[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "decodeBlock: AC run places coeff at k=2, zeros at k=1" {
    // DC table: `00`->0x00 (cat 0 = diff 0).
    // AC table: `00`->EOB, `010`->ZRL, `011`->0x11 (r=1,s=1).
    var dc_bits = [_]u8{0} ** 16;
    dc_bits[1] = 1;
    const dc_vals = [_]u8{0x00};
    const dc_ht = try buildHuff(&dc_bits, &dc_vals);
    const ac_ht = try testAcTableWithRun();

    // DC: code=`00`(cat0, diff=0).
    // AC: code=`011`(r=1,s=1), magnitude bit=`1`(value=1). block_zz[1+1=2]=1, k=3.
    //     code=`00`(EOB).
    // Bits: 00 | 011 1 | 00 -> 00 011 1 00 = 0b00011100 = 0x1C
    const stream = [_]u8{ 0x1C, 0x00 };
    var br = BitReader.init(&stream);
    var pred: i32 = 0;
    var zz: [64]i32 = undefined;
    try decodeBlock(&br, &dc_ht, &ac_ht, &pred, &zz);

    try std.testing.expectEqual(@as(i32, 0), zz[0]);
    try std.testing.expectEqual(@as(i32, 0), zz[1]); // zero run
    try std.testing.expectEqual(@as(i32, 1), zz[2]); // placed coeff
    for (zz[3..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

test "decodeScan: single 8x8 grayscale MCU produces correct plane" {
    const gpa = std.testing.allocator;

    // DC table: one length-2 code `00`->0x03 (cat 3).
    var dc_bits = [_]u8{0} ** 16;
    dc_bits[1] = 1;
    const dc_vals = [_]u8{0x03};
    const dc_ht = try buildHuff(&dc_bits, &dc_vals);

    // AC table: one length-2 code `00`->0x00 (EOB).
    const ac_ht = try testAcTableEobOnly();

    // Frame: 8x8, 1 component (id=1 h=1 v=1 tq=0 td=0 ta=0).
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 8,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{ dc_ht, null, null, null },
        .ac = [_]?HuffTable{ ac_ht, null, null, null },
        .scan_start = 0,
    };

    // Entropy stream: DC code=`00`(cat3), magnitude bits=`100`(=4, positive, diff=4),
    // AC EOB=`00`.
    // Bits: 00 100 00 -> 0b00100000 = 0x20 (pad with zeros).
    // dequantIdct with DC=4, all-quant=1:
    // Expected output = round(4/8 + 128) = round(128.5) = 129 (round half up in f32).
    // Actually verify: the IDCT DC formula from existing tests shows D=8->129, D=0->128.
    // So D=4: 4/8 = 0.5, +128 = 128.5 -> @round(128.5) in f32 is 129 (ties-to-even = 128).
    // Use D=8 (diff=8) to avoid rounding tie: expected = 129.
    // DC cat=4, diff=8=0b1000 (positive: top bit set for 4-bit value 8 >= 2^3=8... wait 8==8 so it's borderline).
    // Actually for cat=4, receiveExtend(4): v=8=0b1000, 2^(4-1)=8, v >= 8 so positive, v=8.
    // Let me use diff=10 (cat=4, bits=0b1010=10): 10 >= 8 so v=10.
    // dequantIdct DC=10: 10/8 + 128 = 1.25 + 128 = 129.25 -> round -> 129.
    // Cat3, diff=5: 5>=4 so positive, 5. 5/8+128=128.625 -> 129.
    // Use DC cat=3 (existing table!), diff=5 (bits `101`).
    // Bits: 00(DC code) 101(magnitude) 00(EOB) = 00 101 00 = 0b00101000 = 0x28.
    // Expected: dequantIdct DC=5: 5/8+128=128.625 -> round -> 129.
    const entropy = [_]u8{ 0x28, 0x00 };
    const planes = try decodeScan(gpa, &ctx, &entropy);
    defer {
        for (planes) |p| gpa.free(p.data);
        gpa.free(planes);
    }

    try std.testing.expectEqual(@as(usize, 1), planes.len);
    try std.testing.expectEqual(@as(usize, 8), planes[0].w);
    try std.testing.expectEqual(@as(usize, 8), planes[0].h);

    // All 64 pixels should be uniform 129 (DC=5, quant=1, IDCT=5/8, +128=128.625->129).
    for (planes[0].data) |px| {
        try std.testing.expectEqual(@as(u8, 129), px);
    }
}

// ---- J5: public decode() + YCbCr->RGB + chroma upsample ----

pub const Decoded = struct {
    rgba: []u8,
    width: u32,
    height: u32,
};

// Convert a single YCbCr triplet to RGB using BT.601 full-range coefficients.
// Output values are clamped to [0,255].
fn ycbcrToRgb(Y: u8, Cb: u8, Cr: u8) struct { r: u8, g: u8, b: u8 } {
    const y_f: f32 = @floatFromInt(Y);
    const cb_f: f32 = @as(f32, @floatFromInt(Cb)) - 128.0;
    const cr_f: f32 = @as(f32, @floatFromInt(Cr)) - 128.0;
    const r_f = y_f + 1.402 * cr_f;
    const g_f = y_f - 0.344136 * cb_f - 0.714136 * cr_f;
    const b_f = y_f + 1.772 * cb_f;
    return .{
        .r = @intFromFloat(std.math.clamp(@round(r_f), 0.0, 255.0)),
        .g = @intFromFloat(std.math.clamp(@round(g_f), 0.0, 255.0)),
        .b = @intFromFloat(std.math.clamp(@round(b_f), 0.0, 255.0)),
    };
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) DecodeError!Decoded {
    var ctx = try parseHeaders(bytes);
    const width: u32 = ctx.frame.width;
    const height: u32 = ctx.frame.height;
    if (width == 0 or height == 0) return error.BadData;

    if (ctx.progressive) {
        const planes = try decodeProgressive(gpa, &ctx, bytes);
        defer freePlanes(gpa, planes);
        const rgba = try planesToRgba(gpa, &ctx, planes);
        return .{ .rgba = rgba, .width = width, .height = height };
    }

    if (ctx.scan_start > bytes.len) return error.Truncated;
    const entropy = bytes[ctx.scan_start..];
    const planes = try decodeScan(gpa, &ctx, entropy);
    defer freePlanes(gpa, planes);
    const rgba = try planesToRgba(gpa, &ctx, planes);
    return .{ .rgba = rgba, .width = width, .height = height };
}

// ---- J5: TEST-ONLY minimal grayscale JPEG encoder ----

// Standard Annex K luma DC Huffman table (T.81 Table K.3).
const BITS_DC_LUMA = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const VALS_DC_LUMA = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

// Standard Annex K luma AC Huffman table (T.81 Table K.5).
const BITS_AC_LUMA = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const VALS_AC_LUMA = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

// Encode table entry: canonical Huffman code + bit length for one symbol.
const EncEntry = struct { code: u16, len: u5 };

// Build a canonical encode table from BITS + VALS.
// Returns an array indexed by symbol value (0..255) -> EncEntry.
// Symbols not in the table have len=0 (should not be emitted).
fn buildEncodeTable(
    comptime N: usize,
    bits: *const [16]u8,
    vals: *const [N]u8,
) [256]EncEntry {
    var table = [_]EncEntry{.{ .code = 0, .len = 0 }} ** 256;
    // Use u32 for intermediate code to avoid overflow at long code lengths.
    var code: u32 = 0;
    var vi: usize = 0;
    for (1..17) |l| {
        const cnt = bits[l - 1];
        for (0..cnt) |_| {
            if (vi < N) {
                const sym = vals[vi];
                table[sym] = .{ .code = @intCast(code), .len = @intCast(l) };
                vi += 1;
            }
            code += 1;
        }
        code = code * 2;
    }
    return table;
}

// Bit writer with 0xFF00 byte stuffing for JPEG entropy data.
const BitWriter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    bits: u32 = 0,
    cnt: u5 = 0,

    fn init(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) BitWriter {
        return .{ .buf = buf, .gpa = gpa };
    }

    fn writeBits(self: *BitWriter, code: u32, len: u5) !void {
        // Append bits MSB first into the accumulator.
        var remaining: u5 = len;
        while (remaining > 0) {
            // How many bits we can add to fill the current byte.
            const space: u5 = 8 - self.cnt;
            const take: u5 = if (remaining < space) remaining else space;
            // Shift the top `take` bits of code (from its msb end, offset by what we skip).
            // bit offset within code: remaining - take bits from the top.
            const shift = remaining - take;
            const chunk: u8 = @intCast((code >> shift) & ((@as(u32, 1) << take) - 1));
            self.bits = (self.bits << take) | chunk;
            self.cnt += take;
            remaining -= take;
            if (self.cnt == 8) {
                try self.flushByte();
            }
        }
    }

    fn flushByte(self: *BitWriter) !void {
        const byte: u8 = @intCast(self.bits & 0xFF);
        try self.buf.append(self.gpa, byte);
        if (byte == 0xFF) {
            // Byte stuffing: emit 0x00 after 0xFF.
            try self.buf.append(self.gpa, 0x00);
        }
        self.bits = 0;
        self.cnt = 0;
    }

    // Flush any remaining bits (pad to byte boundary with 1-bits per JPEG spec).
    fn flush(self: *BitWriter) !void {
        if (self.cnt > 0) {
            const pad: u5 = 8 - self.cnt;
            // Pad with 1s (JPEG spec: pad partial byte with 1s).
            const mask: u8 = @intCast((@as(u32, 1) << pad) - 1);
            const byte: u8 = @intCast(((self.bits << pad) | mask) & 0xFF);
            try self.buf.append(self.gpa, byte);
            if (byte == 0xFF) {
                try self.buf.append(self.gpa, 0x00);
            }
            self.bits = 0;
            self.cnt = 0;
        }
    }
};

// Forward 8x8 DCT (in place, row-major, f32).
// F(u,v) = (1/4) C(u) C(v) sum_{x,y} f(x,y) cos((2x+1)u pi/16) cos((2y+1)v pi/16)
// C(0)=1/sqrt2, C(k>0)=1.
// Implemented as separable 1D forward DCT: column pass then row pass.
fn fwdDct1d(s: *[8]f32) void {
    var out: [8]f32 = undefined;
    for (0..8) |u| {
        var sum: f32 = 0.0;
        for (0..8) |x| {
            sum += s[x] * cos_tab[u][x];
        }
        const cu: f32 = if (u == 0) c0_scale else 1.0;
        out[u] = 0.5 * cu * sum;
    }
    s.* = out;
}

fn fwdDct8x8(block: *[64]f32) void {
    // Column pass first, then row pass, mirrors the IDCT separable structure.
    // Column pass: transform each column.
    for (0..8) |col| {
        var c: [8]f32 = undefined;
        for (0..8) |row| c[row] = block[row * 8 + col];
        fwdDct1d(&c);
        for (0..8) |row| block[row * 8 + col] = c[row];
    }
    // Row pass: transform each row.
    for (0..8) |row| {
        var r: [8]f32 = undefined;
        for (0..8) |col| r[col] = block[row * 8 + col];
        fwdDct1d(&r);
        for (0..8) |col| block[row * 8 + col] = r[col];
    }
}

// Compute the magnitude category (number of bits needed to represent |v|).
fn magnitudeCategory(v: i32) u5 {
    if (v == 0) return 0;
    var n: i32 = if (v < 0) -v else v;
    var cat: u5 = 0;
    while (n > 0) : (n >>= 1) cat += 1;
    return cat;
}

// Encode a value V of known category S into the bit stream (the receive_extend inverse).
// Category 0 encodes nothing (used only for DC diff=0).
fn encodeValue(bw: *BitWriter, v: i32, cat: u5) !void {
    if (cat == 0) return;
    // If positive: emit lower `cat` bits of v.
    // If negative: emit v + 2^cat - 1 (the receive_extend inverse).
    const code: u32 = if (v > 0)
        @intCast(v & ((@as(i32, 1) << cat) - 1))
    else
        @intCast((v + ((@as(i32, 1) << cat) - 1)) & ((@as(i32, 1) << cat) - 1));
    try bw.writeBits(code, cat);
}

// Build a minimal grayscale JPEG from raw luma bytes.
// w and h must be multiples of 8.
pub fn encodeGrayJpeg(
    gpa: std.mem.Allocator,
    luma: []const u8,
    w: usize,
    h: usize,
) ![]u8 {
    std.debug.assert(w % 8 == 0 and h % 8 == 0);
    std.debug.assert(luma.len >= w * h);

    const dc_tab = buildEncodeTable(VALS_DC_LUMA.len, &BITS_DC_LUMA, &VALS_DC_LUMA);
    const ac_tab = buildEncodeTable(VALS_AC_LUMA.len, &BITS_AC_LUMA, &VALS_AC_LUMA);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI.
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, 0xD8);

    // DQT: table 0, 8-bit, all 1s.
    {
        var payload: [65]u8 = undefined;
        payload[0] = 0x00; // Pq=0 Tq=0
        @memset(payload[1..65], 0x01);
        try appendSeg(gpa, &buf, M_DQT, &payload);
    }

    // DHT: DC luma (Tc=0 Th=0).
    {
        const total_dc: usize = VALS_DC_LUMA.len;
        var payload: [1 + 16 + total_dc]u8 = undefined;
        payload[0] = 0x00; // Tc=0 Th=0
        @memcpy(payload[1..17], &BITS_DC_LUMA);
        @memcpy(payload[17 .. 17 + total_dc], &VALS_DC_LUMA);
        try appendSeg(gpa, &buf, M_DHT, &payload);
    }

    // DHT: AC luma (Tc=1 Th=0).
    {
        const total_ac: usize = VALS_AC_LUMA.len;
        var payload: [1 + 16 + total_ac]u8 = undefined;
        payload[0] = 0x10; // Tc=1 Th=0
        @memcpy(payload[1..17], &BITS_AC_LUMA);
        @memcpy(payload[17 .. 17 + total_ac], &VALS_AC_LUMA);
        try appendSeg(gpa, &buf, M_DHT, &payload);
    }

    // SOF0: precision=8, 1 component (Y, h=1 v=1, tq=0).
    {
        var payload: [9]u8 = undefined;
        payload[0] = 8; // precision
        std.mem.writeInt(u16, payload[1..3], @intCast(h), .big);
        std.mem.writeInt(u16, payload[3..5], @intCast(w), .big);
        payload[5] = 1; // Nf=1
        payload[6] = 1; // component id=1
        payload[7] = (1 << 4) | 1; // h=1 v=1
        payload[8] = 0; // tq=0
        try appendSeg(gpa, &buf, M_SOF0, &payload);
    }

    // SOS: Ns=1, Cs=1, Td=0 Ta=0, Ss=0 Se=63 Ah=0 Al=0.
    {
        const payload = [_]u8{ 1, 1, 0x00, 0, 63, 0 };
        try appendSeg(gpa, &buf, M_SOS, &payload);
    }

    // Entropy-coded data.
    {
        var bw = BitWriter.init(gpa, &buf);
        const blocks_x = w / 8;
        const blocks_y = h / 8;
        var dc_pred: i32 = 0;

        for (0..blocks_y) |by| {
            for (0..blocks_x) |bx| {
                // Extract 8x8 block and level shift.
                var block: [64]f32 = undefined;
                for (0..8) |row| {
                    for (0..8) |col| {
                        const px = luma[(by * 8 + row) * w + (bx * 8 + col)];
                        block[row * 8 + col] = @as(f32, @floatFromInt(px)) - 128.0;
                    }
                }

                // Forward DCT.
                fwdDct8x8(&block);

                // Quantize (all-1s quant table) and round to i32, then zig-zag order.
                var coeffs_zz: [64]i32 = undefined;
                for (0..64) |k| {
                    const nat = zigzag[k];
                    coeffs_zz[k] = @intFromFloat(@round(block[nat]));
                }

                // Encode DC: diff from predictor.
                const dc_diff = coeffs_zz[0] - dc_pred;
                dc_pred = coeffs_zz[0];
                const dc_cat = magnitudeCategory(dc_diff);
                const dc_entry = dc_tab[dc_cat];
                try bw.writeBits(dc_entry.code, dc_entry.len);
                try encodeValue(&bw, dc_diff, dc_cat);

                // Encode AC coefficients with run-length coding.
                var k: usize = 1;
                while (k < 64) {
                    // Count run of zeros.
                    var run: usize = 0;
                    while (k + run < 64 and coeffs_zz[k + run] == 0) run += 1;

                    if (k + run == 64) {
                        // EOB: all remaining are zero.
                        const eob_entry = ac_tab[0x00];
                        try bw.writeBits(eob_entry.code, eob_entry.len);
                        break;
                    }

                    // Emit ZRL tokens for runs >= 16.
                    while (run >= 16) {
                        const zrl_entry = ac_tab[0xF0];
                        try bw.writeBits(zrl_entry.code, zrl_entry.len);
                        run -= 16;
                        k += 16;
                    }

                    // Emit the nonzero coefficient.
                    k += run;
                    const val = coeffs_zz[k];
                    const size = magnitudeCategory(val);
                    const rs: u8 = @intCast((@as(usize, run) << 4) | size);
                    const ac_entry = ac_tab[rs];
                    try bw.writeBits(ac_entry.code, ac_entry.len);
                    try encodeValue(&bw, val, size);
                    k += 1;
                }

                // If k never reached 64 and the while loop broke (EOB case), that is fine.
                // If k == 64, the last AC was encoded without EOB (standard allows this).
            }
        }

        try bw.flush();
    }

    // EOI.
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, 0xD9);

    return buf.toOwnedSlice(gpa);
}

test "YCbCr->RGB matches BT.601 on known triples" {
    // (0,128,128) -> (0,0,0) black
    {
        const rgb = ycbcrToRgb(0, 128, 128);
        try std.testing.expectEqual(@as(u8, 0), rgb.r);
        try std.testing.expectEqual(@as(u8, 0), rgb.g);
        try std.testing.expectEqual(@as(u8, 0), rgb.b);
    }
    // (255,128,128) -> (255,255,255) white
    {
        const rgb = ycbcrToRgb(255, 128, 128);
        try std.testing.expectEqual(@as(u8, 255), rgb.r);
        try std.testing.expectEqual(@as(u8, 255), rgb.g);
        try std.testing.expectEqual(@as(u8, 255), rgb.b);
    }
    // (150,128,128) -> gray (150,150,150)
    {
        const rgb = ycbcrToRgb(150, 128, 128);
        try std.testing.expectEqual(@as(u8, 150), rgb.r);
        try std.testing.expectEqual(@as(u8, 150), rgb.g);
        try std.testing.expectEqual(@as(u8, 150), rgb.b);
    }
    // Chroma-nonzero cases that PIN the cross-term coefficients (neutral-chroma
    // cases above cannot). (76,84,255): Cr-128=127, Cb-128=-44 ->
    // R=76+1.402*127=254, G=76+0.344136*44-0.714136*127~=0, B=76-1.772*44~=0.
    {
        const rgb = ycbcrToRgb(76, 84, 255);
        try std.testing.expectApproxEqAbs(@as(f32, 254), @as(f32, @floatFromInt(rgb.r)), 2);
        try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(rgb.g)), 2);
        try std.testing.expectApproxEqAbs(@as(f32, 0), @as(f32, @floatFromInt(rgb.b)), 2);
    }
    // (128,170,128): Cb-128=42, Cr-128=0 -> R=128, G=128-0.344136*42~=114,
    // B=128+1.772*42~=202. Pins 1.772 (B) and 0.344136 (G) without clamping.
    {
        const rgb = ycbcrToRgb(128, 170, 128);
        try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(rgb.r)), 2);
        try std.testing.expectApproxEqAbs(@as(f32, 114), @as(f32, @floatFromInt(rgb.g)), 2);
        try std.testing.expectApproxEqAbs(@as(f32, 202), @as(f32, @floatFromInt(rgb.b)), 2);
    }
}

test "grayscale JPEG round-trips through encode+decode within tolerance" {
    const gpa = std.testing.allocator;
    // 16x16 smooth gradient luma.
    var luma: [256]u8 = undefined;
    for (0..16) |y| {
        for (0..16) |x| {
            luma[y * 16 + x] = @intCast((x * 8 + y * 8));
        }
    }
    const jpg = try encodeGrayJpeg(gpa, &luma, 16, 16);
    defer gpa.free(jpg);
    const d = try decode(gpa, jpg);
    defer gpa.free(d.rgba);
    try std.testing.expectEqual(@as(u32, 16), d.width);
    try std.testing.expectEqual(@as(u32, 16), d.height);
    for (0..16) |y| {
        for (0..16) |x| {
            const o = (y * 16 + x) * 4;
            // Grayscale: R==G==B.
            try std.testing.expect(d.rgba[o] == d.rgba[o + 1] and d.rgba[o + 1] == d.rgba[o + 2]);
            // Alpha must be 255.
            try std.testing.expectEqual(@as(u8, 255), d.rgba[o + 3]);
            const want = luma[y * 16 + x];
            const got = d.rgba[o];
            const diff: u8 = if (got > want) got - want else want - got;
            try std.testing.expect(diff <= 6);
        }
    }
}

test "parseDHT via parseHeaders: DC table 0 built and decodes correctly" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // DHT: Tc=0 Th=0 -> DC table 0; two length-2 codes for values {0x05, 0x06}.
    {
        // 1 byte tc_th + 16 bytes BITS + 2 bytes VALS = 19 bytes payload.
        var dht_payload: [19]u8 = undefined;
        dht_payload[0] = 0x00; // Tc=0 Th=0
        @memset(dht_payload[1..17], 0);
        dht_payload[2] = 2; // bits[1] = 2 (two codes of length 2)
        dht_payload[17] = 0x05;
        dht_payload[18] = 0x06;
        try appendSeg(gpa, &buf, M_DHT, &dht_payload);
    }

    // Minimal SOF0 and SOS to terminate the header walk.
    {
        var sof_payload: [11]u8 = undefined;
        sof_payload[0] = 8;
        std.mem.writeInt(u16, sof_payload[1..3], 8, .big);
        std.mem.writeInt(u16, sof_payload[3..5], 8, .big);
        sof_payload[5] = 1;
        sof_payload[6] = 1;
        sof_payload[7] = (1 << 4) | 1;
        sof_payload[8] = 0;
        try appendSeg(gpa, &buf, M_SOF0, sof_payload[0..9]);
    }
    {
        const sos_payload = [_]u8{ 1, 1, 0x00, 0, 0x3F, 0 };
        try appendSeg(gpa, &buf, M_SOS, &sos_payload);
    }

    const ctx = try parseHeaders(buf.items);
    try std.testing.expect(ctx.dc[0] != null);

    const ht = ctx.dc[0].?;
    // Decode the same two-symbol bitstream: 00 -> 0x05, 01 -> 0x06.
    const stream = [_]u8{0b00010000};
    var br = BitReader.init(&stream);

    const sym0 = try huffDecode(&ht, &br);
    try std.testing.expectEqual(@as(u8, 0x05), sym0);
    const sym1 = try huffDecode(&ht, &br);
    try std.testing.expectEqual(@as(u8, 0x06), sym1);
}

// ---- P1: progressive scaffolding tests ----

test "allocCoeffs: 16x16 3-component 2x2/1x1/1x1 frame has correct sizes" {
    const gpa = std.testing.allocator;

    // Build a ctx with a 16x16 3-component YCbCr frame: Y h=2 v=2, Cb h=1 v=1, Cr h=1 v=1.
    // Hmax=2, Vmax=2. mcu_w=16, mcu_h=16. mcus_x=1, mcus_y=1.
    // Y: blocks_w=1*2=2, blocks_h=1*2=2, data len=2*2*64=256.
    // Cb: blocks_w=1*1=1, blocks_h=1*1=1, data len=1*1*64=64.
    // Cr: same as Cb.
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 16,
            .height = 16,
            .components = [_]Component{
                .{ .id = 1, .h = 2, .v = 2, .tq = 0 },
                .{ .id = 2, .h = 1, .v = 1, .tq = 0 },
                .{ .id = 3, .h = 1, .v = 1, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 3,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    try std.testing.expectEqual(@as(usize, 3), coeffs.len);
    // Y: 2x2 blocks, 64 i32 each.
    try std.testing.expectEqual(@as(usize, 2), coeffs[0].blocks_w);
    try std.testing.expectEqual(@as(usize, 2), coeffs[0].blocks_h);
    try std.testing.expectEqual(@as(usize, 256), coeffs[0].data.len);
    // Cb: 1x1 block.
    try std.testing.expectEqual(@as(usize, 1), coeffs[1].blocks_w);
    try std.testing.expectEqual(@as(usize, 1), coeffs[1].blocks_h);
    try std.testing.expectEqual(@as(usize, 64), coeffs[1].data.len);
    // Cr: 1x1 block.
    try std.testing.expectEqual(@as(usize, 1), coeffs[2].blocks_w);
    try std.testing.expectEqual(@as(usize, 1), coeffs[2].blocks_h);
    try std.testing.expectEqual(@as(usize, 64), coeffs[2].data.len);
    // All values zero-initialised.
    for (coeffs[0].data) |v| try std.testing.expectEqual(@as(i32, 0), v);
    for (coeffs[1].data) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

// ---- P2: DC-first and DC-refine tests ----

// Build a minimal single-symbol DC HuffTable: one length-2 code `00` -> val.
fn testProgDcTable(val: u8) !HuffTable {
    var bits = [_]u8{0} ** 16;
    bits[1] = 1; // one code of length 2
    const vals = [_]u8{val};
    return buildHuff(&bits, &vals);
}

// P2-T1: DC first scan on a 1-component 8x8 frame (1 MCU, 1 block), al=1.
// DC Huffman table: single length-2 code `00` -> category 2.
// Entropy bits: `00` (DC sym cat=2) `10` (magnitude = 2, diff=+2) => coeff = 2 << 1 = 6.
test "decodeProgressiveScan: DC first al=1 1-block produces coeff = diff << al" {
    const gpa = std.testing.allocator;

    // Build the DC HuffTable: `00` -> 0x02 (category 2).
    const dc_ht = try testProgDcTable(0x02);

    // Frame: 8x8, 1 component (id=1, h=1, v=1, tq=0, td=0).
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 8,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{ dc_ht, null, null, null },
        .ac = [_]?HuffTable{null} ** 4,
        .progressive = true,
    };

    // Allocate coefficients (1x1 block for the single component).
    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // ScanHeader: DC first (ss=0, se=0, ah=0, al=1), single component (comp_idx[0]=0).
    const scan = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 0,
        .se = 0,
        .ah = 0,
        .al = 1,
    };

    // Entropy: DC code `00` (cat=2) + magnitude bits `11` (=3, positive -> diff=3).
    // receiveExtend(2, bits=11=3): 3 >= 2^(2-1)=2, positive, diff=3. pred=3.
    // coeff = pred << al = 3 << 1 = 6.
    // Packed MSB-first: 0 0 1 1 | padded = 0b00110000 = 0x30.
    const entropy = [_]u8{0x30};
    try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);

    // Expected: pred=3, coeff[0] = 3 << 1 = 6.
    try std.testing.expectEqual(@as(i32, 6), coeffs[0].data[0]);
    // All other coefficients should remain zero.
    for (coeffs[0].data[1..]) |v| try std.testing.expectEqual(@as(i32, 0), v);
}

// P2-T2: DC refine on a 1-component 8x8 frame (al=0) after a DC-first scan (al=1).
// After DC first: coeff[0]=6 (=0b110). DC refine with al=0 ORs in bit 0 if the refine bit is 1.
// Entropy: single `1` bit => coeff becomes 6 | 1 = 7.
test "decodeProgressiveScan: DC refine ORs in low bit on 1-block frame" {
    const gpa = std.testing.allocator;

    const dc_ht = try testProgDcTable(0x02);

    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 8,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{ dc_ht, null, null, null },
        .ac = [_]?HuffTable{null} ** 4,
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // Step 1: DC first (al=1) to set coeff[0]=6.
    {
        const scan = ScanHeader{
            .num_comps = 1,
            .comp_idx = [_]u8{ 0, 0, 0, 0 },
            .ss = 0,
            .se = 0,
            .ah = 0,
            .al = 1,
        };
        // DC cat=2 code `00` + magnitude bits `11` (diff=3) => coeff = 3<<1 = 6.
        const entropy = [_]u8{0x30};
        try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);
    }
    try std.testing.expectEqual(@as(i32, 6), coeffs[0].data[0]);

    // Step 2: DC refine (ah=1, al=0): one refine bit = 1 => OR in (1<<0) = 1.
    {
        const scan = ScanHeader{
            .num_comps = 1,
            .comp_idx = [_]u8{ 0, 0, 0, 0 },
            .ss = 0,
            .se = 0,
            .ah = 1,
            .al = 0,
        };
        // Single `1` bit, MSB first: 0b10000000 = 0x80.
        const entropy = [_]u8{0x80};
        try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);
    }

    // coeff[0] = 6 | 1 = 7.
    try std.testing.expectEqual(@as(i32, 7), coeffs[0].data[0]);
}

// P2-T3: DC first across two MCUs (16x8 frame, 2 blocks wide).
// Verifies that the DC predictor carries from block 0 to block 1.
// DC diff for block0 = +2, block1 = +1 => pred after block0=2, after block1=3.
// al=0 so coeff values equal the predictor directly.
test "decodeProgressiveScan: DC first pred carries across 2-MCU-wide frame" {
    const gpa = std.testing.allocator;

    // DC HuffTable: `00`->cat2 (2 bits magnitude), `01`->cat1 (1 bit magnitude).
    var bits = [_]u8{0} ** 16;
    bits[1] = 2; // two codes of length 2
    const vals = [_]u8{ 0x02, 0x01 };
    const dc_ht = try buildHuff(&bits, &vals);

    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 16,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{ dc_ht, null, null, null },
        .ac = [_]?HuffTable{null} ** 4,
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // ScanHeader: DC first, al=0, single component (comp_idx[0]=0).
    const scan = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 0,
        .se = 0,
        .ah = 0,
        .al = 0,
    };

    // Block0: code `00`(cat2) + bits `10`(diff=+2).
    // Block1: code `01`(cat1) + bit  `1` (diff=+1).
    // Bits: 00 10 | 01 1 = 0b00100_11_? padded: 0b00100110 = 0x26.
    // Let me be precise: 00 10 01 1 = 8 bits => 0b00100110? No:
    // 0 0 = code for cat2
    // 1 0 = magnitude bits for diff=+2 (cat2 range 2..3; 10b=2 >= 2^(2-1)=2, positive, val=2)
    // 0 1 = code for cat1
    // 1   = magnitude bit for diff=+1 (cat1 range 1; 1b=1 >= 2^0=1, positive, val=1)
    // => 0 0 1 0 0 1 1 x = 0b00100110 pad with 0 = 0x26 (just 7 real bits, pad 1 zero).
    const entropy = [_]u8{0x26};
    try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);

    // Block 0 (blk=0): pred=2, coeff[0]=2.
    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[0 * 64 + 0]);
    // Block 1 (blk=1): pred=3, coeff[0]=3.
    try std.testing.expectEqual(@as(i32, 3), coeffs[0].data[1 * 64 + 0]);
}

// Progressive skeleton end-to-end: a minimal progressive JPEG with a DC-first scan
// whose only block encodes DC diff=0 (category 0, no magnitude bits). All coeffs stay
// 0, dequantIdct produces uniform 128. Verifies the full decode() path for progressive.
test "decodeProgressive: DC-first all-zero DC produces uniform gray 8x8" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // SOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_SOI);

    // DQT: table 0, 8-bit, all 1s.
    {
        var dqt: [65]u8 = undefined;
        dqt[0] = 0x00;
        @memset(dqt[1..65], 1);
        try appendSeg(gpa, &buf, M_DQT, &dqt);
    }

    // DHT: DC table 0 with a single length-1 code `0` -> symbol 0x00 (category 0, diff=0).
    // bits[0]=1 (one code of length 1), VALS={0x00}.
    {
        var dht: [18]u8 = undefined;
        dht[0] = 0x00; // Tc=0 Th=0 (DC table 0)
        @memset(dht[1..17], 0);
        dht[1] = 1; // bits[0]=1: one code of length 1
        dht[17] = 0x00; // val: category 0
        try appendSeg(gpa, &buf, M_DHT, &dht);
    }

    // SOF2: 8x8, 1 component (Y h=1 v=1 tq=0).
    {
        var sof: [9]u8 = undefined;
        sof[0] = 8;
        std.mem.writeInt(u16, sof[1..3], 8, .big);
        std.mem.writeInt(u16, sof[3..5], 8, .big);
        sof[5] = 1;
        sof[6] = 1;
        sof[7] = (1 << 4) | 1;
        sof[8] = 0;
        try appendSeg(gpa, &buf, M_SOF2, sof[0..9]);
    }

    // SOS: Ns=1, Cs=1, Td=0 Ta=0, Ss=0 Se=0 Ah=0 Al=0 (DC-first scan, al=0).
    {
        const sos_payload = [_]u8{ 1, 1, 0x00, 0, 0, 0 };
        try appendSeg(gpa, &buf, M_SOS, &sos_payload);
    }
    // Entropy: one block, DC code = `0` (length 1, symbol 0x00 = category 0, no magnitude bits).
    // Single bit `0` padded to byte: 0b00000000 = 0x00. Category 0 means diff=0, pred stays 0.
    try buf.append(gpa, 0x00);

    // EOI
    try buf.append(gpa, 0xFF);
    try buf.append(gpa, M_EOI);

    const d = try decode(gpa, buf.items);
    defer gpa.free(d.rgba);

    try std.testing.expectEqual(@as(u32, 8), d.width);
    try std.testing.expectEqual(@as(u32, 8), d.height);
    // All-zero coeffs + dequantIdct -> DC=0 -> level-shift 128 -> gray 128.
    // Grayscale: R==G==B==128, A==255.
    const rgba_len = d.width * d.height * 4;
    var i: usize = 0;
    while (i < rgba_len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 128), d.rgba[i + 0]);
        try std.testing.expectEqual(@as(u8, 128), d.rgba[i + 1]);
        try std.testing.expectEqual(@as(u8, 128), d.rgba[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), d.rgba[i + 3]);
    }
}

// ---- P3: AC-first tests ----

// P3-T1: Single-block AC-first scan (1-component 8x8 frame, ss=1 se=5 al=0).
// AC HuffTable: one length-2 code `00` -> 0x11 (r=1, s=1), one length-3 code `010` -> 0x00 (EOB).
// Entropy: symbol `00` (r=1, s=1), magnitude bit `1` (value=1), then EOB `010`.
// Expected: coeff at k = ss + r = 1 + 1 = 2 has value receiveExtend(1, bit=`1`) = 1 << 0 = 1.
// All other AC positions in [1..5] are 0.
test "acFirst: single-block places coeff at k=2 with exact value" {
    const gpa = std.testing.allocator;

    // AC HuffTable: `00` -> 0x11 (r=1, s=1); `010` -> 0x00 (EOB).
    // BITS: bits[1]=1 (one 2-bit code), bits[2]=1 (one 3-bit code).
    // VALS: {0x11, 0x00}.
    // Canonical assignment: 2-bit codes start at `00`: 0x11 gets code `00`.
    // 3-bit codes start at `010`: 0x00 gets code `010`.
    var ac_bits = [_]u8{0} ** 16;
    ac_bits[1] = 1; // one 2-bit code
    ac_bits[2] = 1; // one 3-bit code
    const ac_vals = [_]u8{ 0x11, 0x00 };
    const ac_ht = try buildHuff(&ac_bits, &ac_vals);

    // Frame: 8x8, 1 component (h=1, v=1, ta=0).
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 8,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{null} ** 4,
        .ac = [_]?HuffTable{ ac_ht, null, null, null },
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // ScanHeader: AC first (ss=1 se=5 ah=0 al=0), single component comp_idx[0]=0.
    const scan = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 5,
        .ah = 0,
        .al = 0,
    };

    // Entropy bitstream construction:
    // Symbol 0x11 encoded as `00` (2 bits).
    // r=1, s=1 -> k = ss(1) + r(1) = 2. receiveExtend(s=1): read 1 bit `1` -> value=1 (positive).
    // coeff[blk*64 + 2] = 1 << al(0) = 1.
    // EOB symbol 0x00 encoded as `010` (3 bits).
    // Total bits: 00 1 010 = 6 bits -> pad to byte: 001 010 xx = 0b00101000 = 0x28, then 0xFF pad.
    // Bit layout (MSB first): 0 0 | 1 | 0 1 0 | x x = 0b00101000 = 0x28.
    const entropy = [_]u8{ 0x28, 0xFF };
    try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);

    // k=0 (DC) was not touched by this AC scan.
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[0]);
    // k=1: run of 1 zero before the nonzero at k=2.
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[1]);
    // k=2: placed coeff = receiveExtend(1, bit=1) << 0 = 1.
    try std.testing.expectEqual(@as(i32, 1), coeffs[0].data[2]);
    // k=3..5: zero (EOB broke the loop).
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[3]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[4]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[5]);
}

// P3-T2: EOB-run test on a 2-block component (16x8 frame).
// First block's AC scan emits EOB1 (r=1): eobrun = (1<<1)-1 + getBits(1).
// We encode r=1, extra bit=0 so eobrun = 1 + 0 = 1. After block0 finishes without placing any
// coeff (eobrun set and break), block1 is consumed by the eobrun (eobrun -= 1, continue).
// Assert all AC coeffs in block1 remain 0.
test "acFirst: EOB-run skips second block leaving its AC coeffs zero" {
    const gpa = std.testing.allocator;

    // AC HuffTable for this test:
    // Symbol 0x10 (r=1, s=0) = EOB1: encoded as `00` (2-bit code).
    // We need only one code.
    var ac_bits = [_]u8{0} ** 16;
    ac_bits[1] = 1; // one 2-bit code
    const ac_vals = [_]u8{0x10}; // 0x10 = r=1, s=0
    const ac_ht = try buildHuff(&ac_bits, &ac_vals);

    // Frame: 16x8, 1 component (h=1, v=1) -> Hmax=1, Vmax=1.
    // comp_pixel_w = ceil(16 * 1 / 1) = 16 -> w2 = ceil(16/8) = 2 blocks wide.
    // comp_pixel_h = ceil(8 * 1 / 1) = 8  -> h2 = ceil(8/8) = 1 block tall.
    // Total 2 blocks: block0 at blk=0, block1 at blk=1.
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 16,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{null} ** 4,
        .ac = [_]?HuffTable{ ac_ht, null, null, null },
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // ScanHeader: AC first (ss=1 se=63 ah=0 al=0), single component.
    const scan = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 63,
        .ah = 0,
        .al = 0,
    };

    // Block0: decode symbol 0x10 (r=1, s=0): r < 15 so EOBn path.
    // eobrun = (1 << 1) - 1 = 1. r != 0 so eobrun += getBits(1).
    // We encode extra bit = 0 -> eobrun = 1 + 0 = 1. Break out of block0's k-loop.
    // Block1: eobrun(1) > 0 -> eobrun -= 1 -> eobrun = 0. Skip, all AC stay 0.
    //
    // Entropy bitstream:
    // Symbol 0x10 -> code `00` (2 bits).
    // Extra bit for EOB1 = `0` (1 bit).
    // Total: 00 0 = 3 bits. Pad to byte: 000 x xxxx = 0b00000000 = 0x00.
    const entropy = [_]u8{0x00};
    try decodeProgressiveScan(&ctx, &scan, &entropy, coeffs);

    // Block0: no AC coefficients placed (EOBn with no preceding nonzero).
    for (coeffs[0].data[0 * 64 + 1 .. 0 * 64 + 64]) |v| {
        try std.testing.expectEqual(@as(i32, 0), v);
    }
    // Block1: consumed by eobrun, all AC coefficients remain zero.
    for (coeffs[0].data[1 * 64 + 1 .. 1 * 64 + 64]) |v| {
        try std.testing.expectEqual(@as(i32, 0), v);
    }
}

// ---- P4: AC-refine tests ----

// Shared helper: build ctx and coeffs for a single 8x8 grayscale block, run an AC-first
// scan (ss=1 se=3 al=1) to place coeff[1]=2 (receiveExtend(1,`1`) << 1), then return the
// ctx+coeffs ready for an AC-refine scan.
// AC-first HuffTable: `00` -> 0x01 (r=0 s=1), `010` -> 0x00 (EOB).
// AC-first bits: 00(0x01) 1(mag) 010(EOB) = 0b00101000 = 0x28.
// In acFirst: k starts at ss=1, r=0 -> k+=0=1 -> coeff[blk*64+1] = receiveExtend(1,`1`)<<1 = 2. k=2.
fn setupAcRefineCtx(gpa: std.mem.Allocator) !struct { ctx: Ctx, coeffs: []CoeffPlane, ac_first_ht: HuffTable } {
    // AC-first HuffTable: `00` -> 0x01 (r=0, s=1); `010` -> 0x00 (EOB).
    var ac_bits = [_]u8{0} ** 16;
    ac_bits[1] = 1; // one 2-bit code
    ac_bits[2] = 1; // one 3-bit code
    const ac_vals_first = [_]u8{ 0x01, 0x00 };
    const ac_first_ht = try buildHuff(&ac_bits, &ac_vals_first);

    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 8,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{null} ** 4,
        .ac = [_]?HuffTable{ ac_first_ht, null, null, null },
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);

    // Run AC-first scan: ss=1 se=3 ah=0 al=1.
    // Symbol 0x11 (r=0, s=1): receiveExtend(1, `1`) = 1. coeff[1] = 1 << 1 = 2.
    // Then EOB `010`.
    // Bits: 00 1 010 xx = 0b00101000 = 0x28.
    const scan_first = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 3,
        .ah = 0,
        .al = 1,
    };
    const entropy_first = [_]u8{ 0x28, 0xFF };
    try decodeProgressiveScan(&ctx, &scan_first, &entropy_first, coeffs);

    return .{ .ctx = ctx, .coeffs = coeffs, .ac_first_ht = ac_first_ht };
}

// P4-T1: AC refine correction-bit applied when bit=1.
// After AC-first: coeff[1]=2. Refine scan (ss=1 se=3 ah=1 al=0):
// EOB symbol forces r=64, inner loop reads correction bit for coeff[1].
// Correction bit = 1: (2 & 1)==0, so coeff[1] += 1 -> 3.
// Assert coeff[1] == 3.
test "acRefine: correction bit 1 bumps nonzero coeff from 2 to 3" {
    const gpa = std.testing.allocator;

    const setup = try setupAcRefineCtx(gpa);
    var ctx = setup.ctx;
    const coeffs = setup.coeffs;
    defer freeCoeffs(gpa, coeffs);

    // Verify the AC-first placed the expected value.
    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[1]);

    // AC-refine HuffTable: `00` -> 0x00 (EOB, r=0 s=0).
    var ref_bits = [_]u8{0} ** 16;
    ref_bits[1] = 1; // one 2-bit code
    const ref_vals = [_]u8{0x00};
    const ac_ref_ht = try buildHuff(&ref_bits, &ref_vals);
    ctx.ac[0] = ac_ref_ht;

    const scan_refine = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 3,
        .ah = 1,
        .al = 0,
    };

    // Entropy: EOB symbol `00` (2 bits) + correction bit for coeff[1] = `1` (1 bit).
    // Total: 0 0 1 = 3 bits -> padded: 0b00100000 = 0x20.
    // EOB0: r=0, eobrun = (1<<0)-1 = 0, no getBits. r set to 64.
    // Inner loop k=1..3:
    //   k=1: coeff[1]=2 != 0. correction bit `1`. (2 & 1)==0 -> coeff[1] += 1 -> 3. k=2.
    //   k=2: coeff[2]=0. r=64 != 0 -> r=63. k=3.
    //   k=3: coeff[3]=0. r=63 != 0 -> r=62. k=4. exit inner.
    // Outer: k=4 > se=3. exit outer.
    // eobrun=0 -> trailing block skipped.
    const entropy_refine = [_]u8{0x20};
    try decodeProgressiveScan(&ctx, &scan_refine, &entropy_refine, coeffs);

    try std.testing.expectEqual(@as(i32, 3), coeffs[0].data[1]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[2]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[3]);
}

// P4-T2: AC refine correction-bit NOT applied when bit=0.
// After AC-first: coeff[1]=2. Refine with correction bit=0: coeff[1] stays 2.
test "acRefine: correction bit 0 leaves nonzero coeff unchanged" {
    const gpa = std.testing.allocator;

    const setup = try setupAcRefineCtx(gpa);
    var ctx = setup.ctx;
    const coeffs = setup.coeffs;
    defer freeCoeffs(gpa, coeffs);

    // AC-refine HuffTable: `00` -> 0x00 (EOB).
    var ref_bits = [_]u8{0} ** 16;
    ref_bits[1] = 1;
    const ref_vals = [_]u8{0x00};
    const ac_ref_ht = try buildHuff(&ref_bits, &ref_vals);
    ctx.ac[0] = ac_ref_ht;

    const scan_refine = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 3,
        .ah = 1,
        .al = 0,
    };

    // EOB symbol `00` + correction bit = `0`.
    // Bits: 0 0 0 -> padded 0b00000000 = 0x00.
    // coeff[1] stays 2 because correction bit was 0.
    const entropy_refine = [_]u8{0x00};
    try decodeProgressiveScan(&ctx, &scan_refine, &entropy_refine, coeffs);

    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[1]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[2]);
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[3]);
}

// P4-T3: AC refine new-coefficient insertion (s=1, r=1: one zero gap then place +bit at k=3).
// After AC-first: coeff[1]=2, coeff[2]=0, coeff[3]=0.
// Refine symbol 0x11 (r=1, s=1): magnitude bit `1` -> newval=+1.
// Inner loop from k=1:
//   k=1: coeff[1]=2 != 0. correction bit `0`. (2&1)==0 but bit=0 -> no change. k=2.
//   k=2: coeff[2]=0. r=1 != 0 -> r=0. k=3.
//   k=3: coeff[3]=0. r=0 -> place newval=1. coeff[3]=1. break.
// Assert coeff[3]==1, coeff[1] unchanged=2, coeff[2] still 0.
test "acRefine: new coefficient inserted at k=3 after one zero gap" {
    const gpa = std.testing.allocator;

    const setup = try setupAcRefineCtx(gpa);
    var ctx = setup.ctx;
    const coeffs = setup.coeffs;
    defer freeCoeffs(gpa, coeffs);

    // AC-refine HuffTable: `00` -> 0x11 (r=1, s=1).
    var ref_bits = [_]u8{0} ** 16;
    ref_bits[1] = 1;
    const ref_vals = [_]u8{0x11};
    const ac_ref_ht = try buildHuff(&ref_bits, &ref_vals);
    ctx.ac[0] = ac_ref_ht;

    const scan_refine = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 3,
        .ah = 1,
        .al = 0,
    };

    // Entropy: symbol `00` (0x11) + magnitude bit `1` (newval=+bit=1) + correction bit `0` (for coeff[1]).
    // Bits: 0 0 1 0 = 4 bits -> padded 0b00100000 = 0x20.
    // After placement at k=3: outer loop sees k=4 > se=3, exits.
    // eobrun=0 -> trailing block skipped.
    const entropy_refine = [_]u8{0x20};
    try decodeProgressiveScan(&ctx, &scan_refine, &entropy_refine, coeffs);

    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[1]); // unchanged (correction bit was 0)
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[2]); // zero run, not placed
    try std.testing.expectEqual(@as(i32, 1), coeffs[0].data[3]); // newly inserted
}

// P4-T4: AC refine cross-block EOB-run correction path (regression for double-correction bug).
//
// Scenario: a 2-block component (16x8 image, single component h=1 v=1, w2=2 h2=1).
// A prior AC-first scan places coeff[1]=2 in BOTH block 0 and block 1 (band ss=1 se=2 al=1).
// The AC-refine scan (ss=1 se=2 ah=1 al=0) encodes an EOB1 symbol in block 0:
//   - block 0: eobrun=0, enters the Huffman-decode branch. Decodes EOB1 (symbol 0x10, r=1, s=0).
//     eobrun = (1<<1)-1 + getBits(1) = 1 + 0 = 1. r is forced to 64. The inner sweep reads a
//     correction bit for block 0's nonzero coeff[1]=2 (correction bit=1 -> coeff[1]=3). eobrun NOT
//     applied to this block (we are in the else branch; the trailing if(eobrun>0) is skipped).
//   - block 1: eobrun=1 > 0 at block entry, enters the TRAILING if-branch. Reads a correction bit
//     for coeff[64+1]=2 (correction bit=1 -> coeff[64+1]=3). eobrun -= 1 = 0.
//
// The OLD bug: the if(eobrun>0) was a SECOND independent if, not an else. So block 0 would also
// run the trailing path after setting eobrun=1, double-correcting coeff[1] from 2 to 3 and then
// attempting to read a SECOND correction bit, causing bitstream desync. The fix is the if/else
// structure at block entry (lines 891+903). This test pins that exact path.
//
// Bit layout (MSB first):
//   AC-first entropy (2 blocks, ss=1 se=2 al=1):
//     blk0: sym 0x01=`00`, mag=`1`, EOB 0x00=`010`
//     blk1: sym 0x01=`00`, mag=`1`, EOB 0x00=`010`
//     -> `00 1 010 00 1 010 xxx` = 0x28 0xA0.
//   AC-refine entropy (2 blocks, ss=1 se=2 ah=1 al=0):
//     blk0: EOB1 sym 0x10=`00`, getBits(1)=`0`, correction k=1=`1`
//     blk1: (trailing path) correction k=1=`1`
//     -> `00 0 1 1 xxx` = 0x18.
test "acRefine: cross-block EOB-run trailing path corrects block1 exactly once" {
    const gpa = std.testing.allocator;

    // AC-first HuffTable for 2-block setup: `00` -> 0x01 (r=0, s=1), `010` -> 0x00 (EOB).
    var ac_first_bits = [_]u8{0} ** 16;
    ac_first_bits[1] = 1; // one 2-bit code
    ac_first_bits[2] = 1; // one 3-bit code
    const ac_first_vals = [_]u8{ 0x01, 0x00 };
    const ac_first_ht = try buildHuff(&ac_first_bits, &ac_first_vals);

    // Frame: 16x8, 1 component (h=1, v=1, ta=0).
    // Hmax=1, Vmax=1. comp_pixel_w=16, comp_pixel_h=8. w2=2, h2=1. blocks_w=2, blocks_h=1.
    var ctx: Ctx = .{
        .frame = .{
            .precision = 8,
            .width = 16,
            .height = 8,
            .components = [_]Component{
                .{ .id = 1, .h = 1, .v = 1, .tq = 0, .td = 0, .ta = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
                .{ .id = 0, .h = 0, .v = 0, .tq = 0 },
            },
            .num_components = 1,
        },
        .quant = [_][64]u16{[_]u16{1} ** 64} ** 4,
        .restart_interval = 0,
        .dc = [_]?HuffTable{null} ** 4,
        .ac = [_]?HuffTable{ ac_first_ht, null, null, null },
        .progressive = true,
    };

    const coeffs = try allocCoeffs(gpa, &ctx);
    defer freeCoeffs(gpa, coeffs);

    // AC-first scan (ss=1 se=2 ah=0 al=1): places coeff[1]=2 in both blocks.
    // blk0: `00`=0x01 -> k=1, mag `1` -> coeff[0*64+1]=1<<1=2. `010`=EOB -> break.
    // blk1: `00`=0x01 -> k=1, mag `1` -> coeff[1*64+1]=1<<1=2. `010`=EOB -> break.
    // Bits: 00 1 010 00 1 010 xxx = 0x28 0xA0.
    const scan_first = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 2,
        .ah = 0,
        .al = 1,
    };
    const entropy_first = [_]u8{ 0x28, 0xA0, 0xFF };
    try decodeProgressiveScan(&ctx, &scan_first, &entropy_first, coeffs);

    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[0 * 64 + 1]);
    try std.testing.expectEqual(@as(i32, 2), coeffs[0].data[1 * 64 + 1]);

    // AC-refine HuffTable: `00` -> 0x10 (EOB1, r=1, s=0).
    var ref_bits = [_]u8{0} ** 16;
    ref_bits[1] = 1; // one 2-bit code
    const ref_vals = [_]u8{0x10};
    const ac_ref_ht = try buildHuff(&ref_bits, &ref_vals);
    ctx.ac[0] = ac_ref_ht;

    const scan_refine = ScanHeader{
        .num_comps = 1,
        .comp_idx = [_]u8{ 0, 0, 0, 0 },
        .ss = 1,
        .se = 2,
        .ah = 1,
        .al = 0,
    };

    // AC-refine entropy: bit=1<<0=1.
    // blk0 (eobrun=0, enters else): EOB1=`00`, getBits(1)=`0` -> eobrun=1. r=64.
    //   Inner k=1: coeff[1]=2!=0, correction=`1`, (2&1)==0 -> coeff[1]+=1=3. k=2.
    //   Inner k=2: coeff[2]=0, r=64->63. k=3 > se=2, exit inner. Outer exits.
    //   (Trailing if skipped: we are in the else branch.)
    // blk1 (eobrun=1>0, enters if/trailing): correction k=1: coeff[64+1]=2!=0, `1`, coeff[64+1]=3.
    //   k=2: coeff[64+2]=0, skip. eobrun=0.
    // Bits: 00 0 1 1 xxx = 0b00011xxx = 0x18.
    const entropy_refine = [_]u8{0x18};
    try decodeProgressiveScan(&ctx, &scan_refine, &entropy_refine, coeffs);

    // Block 0, k=1: correction bit was 1, 2 + 1 = 3.
    try std.testing.expectEqual(@as(i32, 3), coeffs[0].data[0 * 64 + 1]);
    // Block 0, k=2: zero, untouched.
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[0 * 64 + 2]);
    // Block 1, k=1: correction bit was 1 via trailing path, 2 + 1 = 3.
    // With the double-correction bug the old code would desync (reads an extra bit) and
    // coeff[64+1] would not be 3, or the test would error on bit underread.
    try std.testing.expectEqual(@as(i32, 3), coeffs[0].data[1 * 64 + 1]);
    // Block 1, k=2: zero, untouched.
    try std.testing.expectEqual(@as(i32, 0), coeffs[0].data[1 * 64 + 2]);
}
