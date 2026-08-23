//! Pure-Zig CFF (Compact Font Format) table parser and Type2 charstring
//! interpreter. Produces glyph outlines (cubic Beziers) for CFF / OpenType
//! fonts, which is what makes the built-in branding fonts renderable natively.
//!
//! File-as-struct. Construct with `Cff.parse(gpa, cff_table)`, release with
//! `deinit(gpa)`, and emit a glyph outline with `outline(gpa, glyph, out)`.
//!
//! Internals: an INDEX reader, a DICT reader, the Top DICT (CharStrings /
//! Private / charset), the Private DICT (Subrs / defaultWidthX / nominalWidthX),
//! global + local Subr INDEXes with the Type2 bias, and the Type2 charstring VM.
const std = @import("std");
const outline_mod = @import("outline.zig");
const Outline = outline_mod.Outline;
const Builder = outline_mod.Builder;

const Cff = @This();

// -- raw table plus resolved sub-slices --
data: []const u8,
char_strings: Index,
global_subrs: Index,
local_subrs: Index,
nominal_width_x: f32 = 0,
default_width_x: f32 = 0,

pub fn parse(gpa: std.mem.Allocator, cff_table: []const u8) !Cff {
    _ = gpa; // no owned allocations: all indexes are slices into cff_table.

    // Header: major(1) minor(1) hdrSize(1) offSize(1).
    if (cff_table.len < 4) return error.InvalidCff;
    const hdr_size = cff_table[2];
    if (hdr_size < 4 or hdr_size > cff_table.len) return error.InvalidCff;

    // The four top-level INDEXes follow the header, back to back:
    // Name INDEX, Top DICT INDEX, String INDEX, Global Subr INDEX.
    var pos: usize = hdr_size;

    const name_index = try Index.read(cff_table, pos);
    pos = name_index.end;

    const top_dict_index = try Index.read(cff_table, pos);
    pos = top_dict_index.end;

    const string_index = try Index.read(cff_table, pos);
    pos = string_index.end;

    const global_subrs = try Index.read(cff_table, pos);

    // A CFF used inside an OpenType font holds a single font, so the Top DICT
    // INDEX has exactly one entry. Read it.
    if (top_dict_index.count == 0) return error.InvalidCff;
    const top_dict_bytes = try top_dict_index.get(0);

    var top = Dict.parse(top_dict_bytes);

    // CharStrings (op 17): absolute offset to the CharStrings INDEX.
    const char_strings_off = top.get(17) orelse return error.MissingCharStrings;
    const char_strings = try Index.read(cff_table, try tableOffset(char_strings_off, cff_table.len));

    // Private DICT (op 18): two operands, size then offset.
    var local_subrs = Index.empty(cff_table);
    var nominal_width_x: f32 = 0;
    var default_width_x: f32 = 0;
    if (top.getPair(18)) |priv| {
        const psize = try tableOffset(priv[0], cff_table.len);
        const poff = try tableOffset(priv[1], cff_table.len);
        if (poff + psize > cff_table.len) return error.InvalidCff;
        const priv_bytes = cff_table[poff .. poff + psize];
        var pdict = Dict.parse(priv_bytes);
        if (pdict.get(20)) |v| default_width_x = v;
        if (pdict.get(21)) |v| nominal_width_x = v;
        // Subrs (op 19): offset is relative to the start of the Private DICT.
        if (pdict.get(19)) |subr_rel| {
            const rel = try tableOffset(subr_rel, cff_table.len);
            const abs = poff + rel;
            if (abs > cff_table.len) return error.InvalidCff;
            local_subrs = try Index.read(cff_table, abs);
        }
    }

    return .{
        .data = cff_table,
        .char_strings = char_strings,
        .global_subrs = global_subrs,
        .local_subrs = local_subrs,
        .nominal_width_x = nominal_width_x,
        .default_width_x = default_width_x,
    };
}

pub fn deinit(self: *Cff, gpa: std.mem.Allocator) void {
    _ = gpa;
    self.* = undefined;
}

/// Validate a DICT-supplied offset (a raw f32) and convert it to a usize index
/// into the CFF table. Rejects negatives, non-finite values (NaN/Inf), and
/// offsets past the table length, so a malformed font yields a clean error
/// rather than a safety panic or wrapped arithmetic on the cast.
fn tableOffset(off_f: f32, len: usize) !usize {
    if (!std.math.isFinite(off_f) or off_f < 0 or off_f > @as(f32, @floatFromInt(len))) {
        return error.InvalidCff;
    }
    return @intFromFloat(off_f);
}

/// Bias applied to callsubr/callgsubr operands per the Type2 spec.
fn subrBias(count: usize) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// Interpret the Type2 charstring for `glyph` and emit its contours into `out`.
pub fn outline(self: *Cff, gpa: std.mem.Allocator, glyph: u16, out: *Outline) !void {
    if (glyph >= self.char_strings.count) return error.InvalidGlyphIndex;
    const cs = try self.char_strings.get(glyph);

    var b = Builder.init(out);
    var vm = Vm{
        .gpa = gpa,
        .builder = &b,
        .gsubrs = self.global_subrs,
        .lsubrs = self.local_subrs,
        .gbias = subrBias(self.global_subrs.count),
        .lbias = subrBias(self.local_subrs.count),
        .nominal_width_x = self.nominal_width_x,
        .width = self.default_width_x,
    };
    try vm.run(cs, 0);
    b.finish();
}

// ---------------------------------------------------------------------------
// INDEX reader
// ---------------------------------------------------------------------------

/// A CFF INDEX: a count, an offset-size, an offset array, then packed data.
/// All fields are slices / values referencing the parent buffer; no ownership.
const Index = struct {
    /// The whole CFF table this index lives in.
    base: []const u8,
    count: usize,
    /// Byte offset (into `base`) of the first data byte (object 0 start - 1).
    data_base: usize,
    /// Byte offset (into `base`) of the offset array.
    off_array: usize,
    off_size: u8,
    /// Byte offset one past the end of the whole INDEX structure.
    end: usize,

    fn empty(base: []const u8) Index {
        return .{ .base = base, .count = 0, .data_base = 0, .off_array = 0, .off_size = 1, .end = 0 };
    }

    /// Read an INDEX starting at `pos`. Layout: count(u16), and if count > 0:
    /// offSize(u8), (count+1) offsets of offSize bytes each, then data.
    fn read(base: []const u8, pos: usize) !Index {
        if (pos + 2 > base.len) return error.InvalidCff;
        const count = (@as(usize, base[pos]) << 8) | base[pos + 1];
        if (count == 0) {
            return .{ .base = base, .count = 0, .data_base = 0, .off_array = 0, .off_size = 1, .end = pos + 2 };
        }
        if (pos + 3 > base.len) return error.InvalidCff;
        const off_size = base[pos + 2];
        if (off_size < 1 or off_size > 4) return error.InvalidCff;
        const off_array = pos + 3;
        const off_bytes = (count + 1) * @as(usize, off_size);
        if (off_array + off_bytes > base.len) return error.InvalidCff;
        // Offsets are 1-based relative to the byte just before the data. So the
        // data base is (end of offset array) - 1.
        const data_base = off_array + off_bytes - 1;
        // The last offset gives the total data size; compute the structure end.
        const last = readOffset(base, off_array, off_size, count);
        const end = data_base + last;
        if (end > base.len) return error.InvalidCff;
        return .{
            .base = base,
            .count = count,
            .data_base = data_base,
            .off_array = off_array,
            .off_size = off_size,
            .end = end,
        };
    }

    fn readOffset(base: []const u8, off_array: usize, off_size: u8, i: usize) usize {
        var v: usize = 0;
        var k: usize = 0;
        const start = off_array + i * @as(usize, off_size);
        while (k < off_size) : (k += 1) {
            v = (v << 8) | base[start + k];
        }
        return v;
    }

    /// Return object `i` as a slice into the parent buffer.
    fn get(self: Index, i: usize) ![]const u8 {
        if (i >= self.count) return error.InvalidCff;
        const start = readOffset(self.base, self.off_array, self.off_size, i);
        const stop = readOffset(self.base, self.off_array, self.off_size, i + 1);
        if (start > stop) return error.InvalidCff;
        const s = self.data_base + start;
        const e = self.data_base + stop;
        if (e > self.base.len) return error.InvalidCff;
        return self.base[s..e];
    }
};

// ---------------------------------------------------------------------------
// DICT reader
// ---------------------------------------------------------------------------

/// A DICT is a sequence of operand bytes followed by an operator. Operators are
/// one byte, or 12 followed by a second byte (escape). We decode lazily: `get`
/// scans the whole DICT and returns the last operand of the matching operator.
const Dict = struct {
    bytes: []const u8,

    fn parse(bytes: []const u8) Dict {
        return .{ .bytes = bytes };
    }

    /// Return the single (last) operand for a one-byte operator, or null.
    fn get(self: Dict, op: u16) ?f32 {
        var res: ?f32 = null;
        self.each(op, &res);
        return res;
    }

    /// Return the first two operands of an operator as a pair, or null.
    fn getPair(self: Dict, op: u16) ?[2]f32 {
        var ops: [48]f32 = undefined;
        var n: usize = 0;
        var found = false;
        self.eachPair(op, &ops, &n, &found);
        if (!found or n < 2) return null;
        return .{ ops[0], ops[1] };
    }

    /// Walk the DICT; when the target operator is hit, record its last operand
    /// into `last` (and optionally the full operand list is ignored here).
    fn each(self: Dict, target: u16, last: *?f32) void {
        var ops: [48]f32 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.bytes.len) {
            const b0 = self.bytes[i];
            if (b0 <= 21) {
                // operator
                var op: u16 = b0;
                i += 1;
                if (b0 == 12) {
                    if (i >= self.bytes.len) break;
                    op = 0x0c00 | @as(u16, self.bytes[i]);
                    i += 1;
                }
                if (op == target and n > 0) last.* = ops[n - 1];
                n = 0;
            } else {
                const adv = decodeDictOperand(self.bytes, i, &ops, &n) catch break;
                i = adv;
            }
        }
    }

    /// Same walk but records the full operand list for the target operator.
    fn eachPair(self: Dict, target: u16, out_ops: *[48]f32, out_n: *usize, found: *bool) void {
        var ops: [48]f32 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.bytes.len) {
            const b0 = self.bytes[i];
            if (b0 <= 21) {
                var op: u16 = b0;
                i += 1;
                if (b0 == 12) {
                    if (i >= self.bytes.len) break;
                    op = 0x0c00 | @as(u16, self.bytes[i]);
                    i += 1;
                }
                if (op == target) {
                    var k: usize = 0;
                    while (k < n and k < out_ops.len) : (k += 1) out_ops[k] = ops[k];
                    out_n.* = n;
                    found.* = true;
                }
                n = 0;
            } else {
                const adv = decodeDictOperand(self.bytes, i, &ops, &n) catch break;
                i = adv;
            }
        }
    }
};

/// Decode one DICT operand at `i`, push it, and return the new position.
/// DICT operand encoding differs from charstrings: 28 = int16, 29 = int32,
/// 30 = real (BCD), 32..246 = b0-139, 247..254 = two-byte forms.
fn decodeDictOperand(b: []const u8, i: usize, ops: *[48]f32, n: *usize) !usize {
    const b0 = b[i];
    var value: f32 = 0;
    var next = i;
    if (b0 == 28) {
        if (i + 3 > b.len) return error.InvalidCff;
        const v: i16 = @bitCast((@as(u16, b[i + 1]) << 8) | b[i + 2]);
        value = @floatFromInt(v);
        next = i + 3;
    } else if (b0 == 29) {
        if (i + 5 > b.len) return error.InvalidCff;
        const v: i32 = @bitCast((@as(u32, b[i + 1]) << 24) | (@as(u32, b[i + 2]) << 16) | (@as(u32, b[i + 3]) << 8) | b[i + 4]);
        value = @floatFromInt(v);
        next = i + 5;
    } else if (b0 == 30) {
        // Real number, packed BCD nibbles, terminated by the 0xf nibble.
        var acc: [64]u8 = undefined;
        var len: usize = 0;
        var j = i + 1;
        outer: while (j < b.len) : (j += 1) {
            const byte = b[j];
            const nibbles = [2]u4{ @truncate(byte >> 4), @truncate(byte & 0xf) };
            for (nibbles) |nib| {
                const c: ?u8 = switch (nib) {
                    0x0...0x9 => '0' + @as(u8, nib),
                    0xa => '.',
                    0xb => 'E',
                    0xc => null, // "E-" handled below
                    0xd => null, // reserved
                    0xe => '-',
                    0xf => {
                        j += 1;
                        break :outer;
                    },
                };
                if (nib == 0xc) {
                    if (len + 2 <= acc.len) {
                        acc[len] = 'E';
                        acc[len + 1] = '-';
                        len += 2;
                    }
                    continue;
                }
                if (c) |ch| {
                    if (len < acc.len) {
                        acc[len] = ch;
                        len += 1;
                    }
                }
            }
        }
        value = std.fmt.parseFloat(f32, acc[0..len]) catch 0;
        next = j;
    } else if (b0 >= 32 and b0 <= 246) {
        value = @floatFromInt(@as(i32, b0) - 139);
        next = i + 1;
    } else if (b0 >= 247 and b0 <= 250) {
        if (i + 2 > b.len) return error.InvalidCff;
        value = @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, b[i + 1]) + 108);
        next = i + 2;
    } else if (b0 >= 251 and b0 <= 254) {
        if (i + 2 > b.len) return error.InvalidCff;
        value = @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, b[i + 1]) - 108);
        next = i + 2;
    } else {
        return error.InvalidCff;
    }
    if (n.* < ops.len) {
        ops[n.*] = value;
        n.* += 1;
    }
    return next;
}

// ---------------------------------------------------------------------------
// Type2 charstring VM
// ---------------------------------------------------------------------------

const Vm = struct {
    gpa: std.mem.Allocator,
    builder: *Builder,
    gsubrs: Index,
    lsubrs: Index,
    gbias: i32,
    lbias: i32,

    // operand stack
    stack: [48]f32 = undefined,
    sp: usize = 0,

    // current point
    x: f32 = 0,
    y: f32 = 0,

    // hint / width bookkeeping
    num_stems: usize = 0,
    width_parsed: bool = false,
    width: f32,
    nominal_width_x: f32,
    open: bool = false,

    fn push(self: *Vm, v: f32) !void {
        if (self.sp >= self.stack.len) return error.StackOverflow;
        self.stack[self.sp] = v;
        self.sp += 1;
    }

    fn clear(self: *Vm) void {
        self.sp = 0;
    }

    /// Consume the optional leading width operand on the first stack-clearing
    /// operator. `even` = true when the operator takes an even number of args
    /// (moveto with 2, curve/line pairs) so an odd count means a leading width;
    /// for a fixed expected arg count, pass the expected count via `expected`.
    fn maybeWidth(self: *Vm, expected_parity: usize) void {
        if (self.width_parsed) return;
        self.width_parsed = true;
        // If the number of operands exceeds the expected parity, the first is
        // the width override (relative to nominalWidthX).
        if (self.sp > expected_parity) {
            self.width = self.nominal_width_x + self.stack[0];
            // shift stack left by one
            var i: usize = 1;
            while (i < self.sp) : (i += 1) self.stack[i - 1] = self.stack[i];
            self.sp -= 1;
        }
    }

    fn startContour(self: *Vm) !void {
        if (self.open) self.builder.finish();
        try self.builder.moveTo(self.gpa, self.x, self.y);
        self.open = true;
    }

    fn run(self: *Vm, cs: []const u8, depth: u8) !void {
        if (depth > 10) return error.RecursionTooDeep;
        var i: usize = 0;
        while (i < cs.len) {
            const b0 = cs[i];
            if (b0 >= 32 or b0 == 28) {
                // number
                i = try self.decodeOperand(cs, i);
                continue;
            }
            i += 1;
            switch (b0) {
                1, 3, 18, 23 => {
                    // hstem / vstem / hstemhm / vstemhm: count stems (pairs).
                    self.maybeWidth(self.evenParity());
                    self.num_stems += self.sp / 2;
                    self.clear();
                },
                19, 20 => {
                    // hintmask / cntrmask: pending operands are implicit vstems.
                    self.maybeWidth(self.evenParity());
                    self.num_stems += self.sp / 2;
                    self.clear();
                    const mask_bytes = (self.num_stems + 7) / 8;
                    if (i + mask_bytes > cs.len) return error.InvalidCharstring;
                    i += mask_bytes;
                },
                21 => { // rmoveto (dx dy)
                    self.maybeWidth(2);
                    if (self.sp >= 2) {
                        self.x += self.stack[0];
                        self.y += self.stack[1];
                    }
                    try self.startContour();
                    self.clear();
                },
                22 => { // hmoveto (dx)
                    self.maybeWidth(1);
                    if (self.sp >= 1) self.x += self.stack[0];
                    try self.startContour();
                    self.clear();
                },
                4 => { // vmoveto (dy)
                    self.maybeWidth(1);
                    if (self.sp >= 1) self.y += self.stack[0];
                    try self.startContour();
                    self.clear();
                },
                5 => { // rlineto: pairs
                    var k: usize = 0;
                    while (k + 2 <= self.sp) : (k += 2) {
                        self.x += self.stack[k];
                        self.y += self.stack[k + 1];
                        try self.builder.lineTo(self.gpa, self.x, self.y);
                    }
                    self.clear();
                },
                6 => { // hlineto: alternating h,v starting horizontal
                    try self.altLine(true);
                    self.clear();
                },
                7 => { // vlineto: alternating v,h starting vertical
                    try self.altLine(false);
                    self.clear();
                },
                8 => { // rrcurveto: sextuples
                    var k: usize = 0;
                    while (k + 6 <= self.sp) : (k += 6) {
                        try self.curve(
                            self.stack[k],
                            self.stack[k + 1],
                            self.stack[k + 2],
                            self.stack[k + 3],
                            self.stack[k + 4],
                            self.stack[k + 5],
                        );
                    }
                    self.clear();
                },
                24 => { // rcurveline: curves then one line
                    var k: usize = 0;
                    while (k + 6 <= self.sp -| 2) : (k += 6) {
                        try self.curve(
                            self.stack[k],
                            self.stack[k + 1],
                            self.stack[k + 2],
                            self.stack[k + 3],
                            self.stack[k + 4],
                            self.stack[k + 5],
                        );
                    }
                    if (k + 2 <= self.sp) {
                        self.x += self.stack[k];
                        self.y += self.stack[k + 1];
                        try self.builder.lineTo(self.gpa, self.x, self.y);
                    }
                    self.clear();
                },
                25 => { // rlinecurve: lines then one curve
                    var k: usize = 0;
                    while (k + 2 <= self.sp -| 6) : (k += 2) {
                        self.x += self.stack[k];
                        self.y += self.stack[k + 1];
                        try self.builder.lineTo(self.gpa, self.x, self.y);
                    }
                    if (k + 6 <= self.sp) {
                        try self.curve(
                            self.stack[k],
                            self.stack[k + 1],
                            self.stack[k + 2],
                            self.stack[k + 3],
                            self.stack[k + 4],
                            self.stack[k + 5],
                        );
                    }
                    self.clear();
                },
                26 => { // vvcurveto
                    try self.vvcurveto();
                    self.clear();
                },
                27 => { // hhcurveto
                    try self.hhcurveto();
                    self.clear();
                },
                30 => { // vhcurveto
                    try self.vhcurveto(false);
                    self.clear();
                },
                31 => { // hvcurveto
                    try self.vhcurveto(true);
                    self.clear();
                },
                10 => { // callsubr
                    const idx = try self.subrIndex(self.lbias);
                    const sub = self.lsubrs.get(idx) catch return error.InvalidSubr;
                    try self.run(sub, depth + 1);
                },
                29 => { // callgsubr
                    const idx = try self.subrIndex(self.gbias);
                    const sub = self.gsubrs.get(idx) catch return error.InvalidSubr;
                    try self.run(sub, depth + 1);
                },
                11 => { // return
                    return;
                },
                14 => { // endchar
                    self.maybeWidth(0);
                    if (self.sp == 4) return error.SeacUnsupported;
                    if (self.open) self.builder.finish();
                    self.open = false;
                    self.clear();
                    return;
                },
                12 => {
                    // escape operator: the second byte selects a two-byte op.
                    if (i >= cs.len) return error.InvalidCharstring;
                    const b1 = cs[i];
                    i += 1;
                    switch (b1) {
                        // The flex operators each encode two cubic Bezier
                        // segments; they must be emitted (not dropped) so that
                        // the pen ends at the right place for later relative ops.
                        34 => try self.hflex(),
                        35 => try self.flex(),
                        36 => try self.hflex1(),
                        37 => try self.flex1(),
                        // Arithmetic / storage escapes do not appear in outline
                        // charstrings; treat as stack-clearing no-ops.
                        else => {},
                    }
                    self.clear();
                },
                else => {
                    // Unknown / unsupported operator: clear and continue.
                    self.clear();
                },
            }
        }
    }

    /// Parity helper for stem/hint width detection: stems come in pairs so the
    /// expected operand count is even; an odd extra means a leading width.
    fn evenParity(self: *Vm) usize {
        // Largest even number <= sp; a leading width makes sp odd.
        return self.sp - (self.sp % 2);
    }

    fn subrIndex(self: *Vm, bias: i32) !usize {
        if (self.sp == 0) return error.InvalidSubr;
        self.sp -= 1;
        const arg = self.stack[self.sp];
        const idx = @as(i64, @intFromFloat(arg)) + bias;
        if (idx < 0) return error.InvalidSubr;
        return @intCast(idx);
    }

    /// Emit a cubic from the current point using relative control deltas.
    fn curve(self: *Vm, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) !void {
        const c1x = self.x + dx1;
        const c1y = self.y + dy1;
        const c2x = c1x + dx2;
        const c2y = c1y + dy2;
        const ex = c2x + dx3;
        const ey = c2y + dy3;
        try self.builder.cubicTo(self.gpa, c1x, c1y, c2x, c2y, ex, ey);
        self.x = ex;
        self.y = ey;
    }

    fn altLine(self: *Vm, start_horizontal: bool) !void {
        var horizontal = start_horizontal;
        var k: usize = 0;
        while (k < self.sp) : (k += 1) {
            if (horizontal) {
                self.x += self.stack[k];
            } else {
                self.y += self.stack[k];
            }
            try self.builder.lineTo(self.gpa, self.x, self.y);
            horizontal = !horizontal;
        }
    }

    fn hhcurveto(self: *Vm) !void {
        // hhcurveto: dy1? {dxa dxb dyb dxc}+
        var k: usize = 0;
        var dy1: f32 = 0;
        if (self.sp % 4 == 1) {
            dy1 = self.stack[0];
            k = 1;
        }
        while (k + 4 <= self.sp) : (k += 4) {
            const dxa = self.stack[k];
            const dxb = self.stack[k + 1];
            const dyb = self.stack[k + 2];
            const dxc = self.stack[k + 3];
            try self.curve(dxa, dy1, dxb, dyb, dxc, 0);
            dy1 = 0;
        }
    }

    fn vvcurveto(self: *Vm) !void {
        // vvcurveto: dx1? {dya dxb dyb dyc}+
        var k: usize = 0;
        var dx1: f32 = 0;
        if (self.sp % 4 == 1) {
            dx1 = self.stack[0];
            k = 1;
        }
        while (k + 4 <= self.sp) : (k += 4) {
            const dya = self.stack[k];
            const dxb = self.stack[k + 1];
            const dyb = self.stack[k + 2];
            const dyc = self.stack[k + 3];
            try self.curve(dx1, dya, dxb, dyb, 0, dyc);
            dx1 = 0;
        }
    }

    /// vhcurveto / hvcurveto: alternating tangents with an optional trailing
    /// 5th value on the final curve. `start_horizontal` = true for hvcurveto.
    fn vhcurveto(self: *Vm, start_horizontal: bool) !void {
        var horizontal = start_horizontal;
        var k: usize = 0;
        const n = self.sp;
        while (k + 4 <= n) {
            const remaining = n - k;
            // A trailing 5th operand applies only to the last group of 4.
            const last = remaining < 8;
            const df: f32 = if (last and remaining == 5) self.stack[k + 4] else 0;
            if (horizontal) {
                // start horizontal tangent, end vertical
                const dx1 = self.stack[k];
                const dx2 = self.stack[k + 1];
                const dy2 = self.stack[k + 2];
                const dy3 = self.stack[k + 3];
                try self.curve(dx1, 0, dx2, dy2, df, dy3);
            } else {
                // start vertical tangent, end horizontal
                const dy1 = self.stack[k];
                const dx2 = self.stack[k + 1];
                const dy2 = self.stack[k + 2];
                const dx3 = self.stack[k + 3];
                try self.curve(0, dy1, dx2, dy2, dx3, df);
            }
            horizontal = !horizontal;
            k += 4;
        }
    }

    /// flex (12 35): dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 dx6 dy6 fd.
    /// Two cubics; fd (flex depth) is ignored. 13 operands.
    fn flex(self: *Vm) !void {
        if (self.sp < 12) return;
        const s = self.stack;
        try self.curve(s[0], s[1], s[2], s[3], s[4], s[5]);
        try self.curve(s[6], s[7], s[8], s[9], s[10], s[11]);
    }

    /// hflex (12 34): dx1 dx2 dy2 dx3 dx4 dx5 dx6. 7 operands.
    /// Curve A = (dx1,0)(dx2,dy2)(dx3,0); Curve B = (dx4,0)(dx5,-dy2)(dx6,0).
    fn hflex(self: *Vm) !void {
        if (self.sp < 7) return;
        const s = self.stack;
        const dx1 = s[0];
        const dx2 = s[1];
        const dy2 = s[2];
        const dx3 = s[3];
        const dx4 = s[4];
        const dx5 = s[5];
        const dx6 = s[6];
        try self.curve(dx1, 0, dx2, dy2, dx3, 0);
        try self.curve(dx4, 0, dx5, -dy2, dx6, 0);
    }

    /// hflex1 (12 36): dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6. 9 operands.
    /// Curve A = (dx1,dy1)(dx2,dy2)(dx3,0);
    /// Curve B = (dx4,0)(dx5,dy5)(dx6, -(dy1+dy2+dy5)).
    fn hflex1(self: *Vm) !void {
        if (self.sp < 9) return;
        const s = self.stack;
        const dx1 = s[0];
        const dy1 = s[1];
        const dx2 = s[2];
        const dy2 = s[3];
        const dx3 = s[4];
        const dx4 = s[5];
        const dx5 = s[6];
        const dy5 = s[7];
        const dx6 = s[8];
        try self.curve(dx1, dy1, dx2, dy2, dx3, 0);
        try self.curve(dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5));
    }

    /// flex1 (12 37): dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6. 11 operands.
    /// The last point uses d6 for the larger-magnitude axis and returns the
    /// other axis to the starting position.
    fn flex1(self: *Vm) !void {
        if (self.sp < 11) return;
        const s = self.stack;
        const dx1 = s[0];
        const dy1 = s[1];
        const dx2 = s[2];
        const dy2 = s[3];
        const dx3 = s[4];
        const dy3 = s[5];
        const dx4 = s[6];
        const dy4 = s[7];
        const dx5 = s[8];
        const dy5 = s[9];
        const d6 = s[10];
        const dx = dx1 + dx2 + dx3 + dx4 + dx5;
        const dy = dy1 + dy2 + dy3 + dy4 + dy5;
        try self.curve(dx1, dy1, dx2, dy2, dx3, dy3);
        if (@abs(dx) > @abs(dy)) {
            try self.curve(dx4, dy4, dx5, dy5, d6, -dy);
        } else {
            try self.curve(dx4, dy4, dx5, dy5, -dx, d6);
        }
    }

    /// Decode a Type2 charstring number at `i`, push it, return new position.
    fn decodeOperand(self: *Vm, cs: []const u8, i: usize) !usize {
        const b0 = cs[i];
        if (b0 == 28) {
            if (i + 3 > cs.len) return error.InvalidCharstring;
            const v: i16 = @bitCast((@as(u16, cs[i + 1]) << 8) | cs[i + 2]);
            try self.push(@floatFromInt(v));
            return i + 3;
        } else if (b0 >= 32 and b0 <= 246) {
            try self.push(@floatFromInt(@as(i32, b0) - 139));
            return i + 1;
        } else if (b0 >= 247 and b0 <= 250) {
            if (i + 2 > cs.len) return error.InvalidCharstring;
            try self.push(@floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, cs[i + 1]) + 108));
            return i + 2;
        } else if (b0 >= 251 and b0 <= 254) {
            if (i + 2 > cs.len) return error.InvalidCharstring;
            try self.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, cs[i + 1]) - 108));
            return i + 2;
        } else if (b0 == 255) {
            if (i + 5 > cs.len) return error.InvalidCharstring;
            const v: i32 = @bitCast((@as(u32, cs[i + 1]) << 24) | (@as(u32, cs[i + 2]) << 16) | (@as(u32, cs[i + 3]) << 8) | cs[i + 4]);
            try self.push(@as(f32, @floatFromInt(v)) / 65536.0);
            return i + 5;
        }
        return error.InvalidCharstring;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const builtin = @import("builtin.zig");
const Sfnt = @import("sfnt.zig");
const Metrics = @import("metrics.zig");

/// Encode a small integer as a single-byte Type2 operand (valid for -107..107).
fn enc(v: i32) u8 {
    return @intCast(v + 139);
}

test "Type2 VM: crafted rmoveto/rlineto/rrcurveto/endchar" {
    const gpa = std.testing.allocator;

    // Craft a charstring:
    //   100 100 rmoveto   -> moveTo(100,100)   ... but 100 > 107 so single byte
    //                        encoding needs v <= 107. Use 100 (enc 239) which is
    //                        within 32..246, so it is fine.
    //   50 0   rlineto    -> lineTo(150,100)
    //   10 20 30 40 50 60 rrcurveto
    //   endchar
    const cs = [_]u8{
        enc(100), enc(100), 21, // rmoveto
        enc(50), enc(0), 5, // rlineto
        enc(10), enc(20), enc(30), enc(40), enc(50), enc(60), 8, // rrcurveto
        14, // endchar
    };

    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);

    const empty_base = [_]u8{};
    var vm = Vm{
        .gpa = gpa,
        .builder = &b,
        .gsubrs = Index.empty(&empty_base),
        .lsubrs = Index.empty(&empty_base),
        .gbias = 107,
        .lbias = 107,
        .nominal_width_x = 0,
        .width = 0,
    };
    try vm.run(&cs, 0);
    b.finish();

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const c = out.contours.items[0];
    // start point of the contour
    try std.testing.expectEqual(@as(f32, 100), c.start.x);
    try std.testing.expectEqual(@as(f32, 100), c.start.y);
    // one line + one cubic
    try std.testing.expectEqual(@as(usize, 2), c.segs.items.len);

    // line segment to (150, 100)
    switch (c.segs.items[0]) {
        .line => |p| {
            try std.testing.expectEqual(@as(f32, 150), p.x);
            try std.testing.expectEqual(@as(f32, 100), p.y);
        },
        else => return error.TestUnexpectedResult,
    }

    // cubic: from (150,100), deltas 10,20 / 30,40 / 50,60
    // c1 = (160,120); c2 = (190,160); end = (240,220)
    switch (c.segs.items[1]) {
        .cubic => |cc| {
            try std.testing.expectEqual(@as(f32, 160), cc.c1.x);
            try std.testing.expectEqual(@as(f32, 120), cc.c1.y);
            try std.testing.expectEqual(@as(f32, 190), cc.c2.x);
            try std.testing.expectEqual(@as(f32, 160), cc.c2.y);
            try std.testing.expectEqual(@as(f32, 240), cc.end.x);
            try std.testing.expectEqual(@as(f32, 220), cc.end.y);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Type2 VM: flex (12 35) emits two cubics and advances the pen" {
    const gpa = std.testing.allocator;

    // Craft:
    //   0 0 rmoveto -> moveTo(0,0)
    //   flex: dx1..dy6 fd = 10 10 20 -10 10 -10   10 10 20 10 10 -10   50
    //     Curve A deltas: (10,10)(20,-10)(10,-10)
    //     Curve B deltas: (10,10)(20,10)(10,-10)
    //     fd = 50 (ignored)
    //   endchar
    const full = [_]u8{
        enc(0), enc(0), 21, // rmoveto -> (0,0)
        enc(10), enc(10), enc(20), enc(-10), enc(10), enc(-10), // curve A deltas
        enc(10), enc(10), enc(20), enc(10), enc(10), enc(-10), // curve B deltas
        enc(50), // fd
        12, 35, // flex
        14, // endchar
    };

    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);

    const empty_base = [_]u8{};
    var vm = Vm{
        .gpa = gpa,
        .builder = &b,
        .gsubrs = Index.empty(&empty_base),
        .lsubrs = Index.empty(&empty_base),
        .gbias = 107,
        .lbias = 107,
        .nominal_width_x = 0,
        .width = 0,
    };
    try vm.run(&full, 0);
    b.finish();

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const c = out.contours.items[0];
    try std.testing.expectEqual(@as(f32, 0), c.start.x);
    try std.testing.expectEqual(@as(f32, 0), c.start.y);
    // exactly two cubic segments
    try std.testing.expectEqual(@as(usize, 2), c.segs.items.len);

    // Curve A from (0,0): c1=(10,10) c2=(30,0) end=(40,-10)
    switch (c.segs.items[0]) {
        .cubic => |cc| {
            try std.testing.expectEqual(@as(f32, 10), cc.c1.x);
            try std.testing.expectEqual(@as(f32, 10), cc.c1.y);
            try std.testing.expectEqual(@as(f32, 30), cc.c2.x);
            try std.testing.expectEqual(@as(f32, 0), cc.c2.y);
            try std.testing.expectEqual(@as(f32, 40), cc.end.x);
            try std.testing.expectEqual(@as(f32, -10), cc.end.y);
        },
        else => return error.TestUnexpectedResult,
    }
    // Curve B from (40,-10): c1=(50,0) c2=(70,10) end=(80,0)
    switch (c.segs.items[1]) {
        .cubic => |cc| {
            try std.testing.expectEqual(@as(f32, 50), cc.c1.x);
            try std.testing.expectEqual(@as(f32, 0), cc.c1.y);
            try std.testing.expectEqual(@as(f32, 70), cc.c2.x);
            try std.testing.expectEqual(@as(f32, 10), cc.c2.y);
            try std.testing.expectEqual(@as(f32, 80), cc.end.x);
            try std.testing.expectEqual(@as(f32, 0), cc.end.y);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Type2 VM: hflex (12 34) emits two cubics returning to start y" {
    const gpa = std.testing.allocator;

    // 0 0 rmoveto; hflex dx1 dx2 dy2 dx3 dx4 dx5 dx6 = 10 20 15 10 10 20 10
    //   Curve A = (10,0)(20,15)(10,0); Curve B = (10,0)(20,-15)(10,0)
    const full = [_]u8{
        enc(0),  enc(0),  21, // rmoveto -> (0,0)
        enc(10), enc(20), enc(15),
        enc(10), enc(10), enc(20),
        enc(10),
        12, 34, // hflex
        14, // endchar
    };

    var out = Outline{};
    defer out.deinit(gpa);
    var b = Builder.init(&out);

    const empty_base = [_]u8{};
    var vm = Vm{
        .gpa = gpa,
        .builder = &b,
        .gsubrs = Index.empty(&empty_base),
        .lsubrs = Index.empty(&empty_base),
        .gbias = 107,
        .lbias = 107,
        .nominal_width_x = 0,
        .width = 0,
    };
    try vm.run(&full, 0);
    b.finish();

    try std.testing.expectEqual(@as(usize, 1), out.contours.items.len);
    const c = out.contours.items[0];
    try std.testing.expectEqual(@as(usize, 2), c.segs.items.len);

    // Curve A from (0,0): c1=(10,0) c2=(30,15) end=(40,15)
    switch (c.segs.items[0]) {
        .cubic => |cc| {
            try std.testing.expectEqual(@as(f32, 10), cc.c1.x);
            try std.testing.expectEqual(@as(f32, 0), cc.c1.y);
            try std.testing.expectEqual(@as(f32, 30), cc.c2.x);
            try std.testing.expectEqual(@as(f32, 15), cc.c2.y);
            try std.testing.expectEqual(@as(f32, 40), cc.end.x);
            try std.testing.expectEqual(@as(f32, 15), cc.end.y);
        },
        else => return error.TestUnexpectedResult,
    }
    // Curve B from (40,15): c1=(50,15) c2=(70,0) end=(80,0) -> y back to start (0)
    switch (c.segs.items[1]) {
        .cubic => |cc| {
            try std.testing.expectEqual(@as(f32, 50), cc.c1.x);
            try std.testing.expectEqual(@as(f32, 15), cc.c1.y);
            try std.testing.expectEqual(@as(f32, 70), cc.c2.x);
            try std.testing.expectEqual(@as(f32, 0), cc.c2.y);
            try std.testing.expectEqual(@as(f32, 80), cc.end.x);
            try std.testing.expectEqual(@as(f32, 0), cc.end.y);
        },
        else => return error.TestUnexpectedResult,
    }
    // Pen y returned to the starting y (0).
    try std.testing.expectEqual(@as(f32, 0), vm.y);
}

test "CFF interprets Neuropol 'A' into a non-empty cubic outline" {
    const gpa = std.testing.allocator;
    const s = try Sfnt.parse(builtin.neuropol_bytes);
    const m = try Metrics.parse(s);
    var cff = try Cff.parse(gpa, s.table("CFF ").?);
    defer cff.deinit(gpa);
    var o = Outline{};
    defer o.deinit(gpa);
    try cff.outline(gpa, m.glyphIndex('A'), &o);
    try std.testing.expect(o.contours.items.len >= 1);
    var seg_count: usize = 0;
    for (o.contours.items) |c| seg_count += c.segs.items.len;
    try std.testing.expect(seg_count > 0);
}
