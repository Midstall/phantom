//! The character cell buffer for mode B. It holds a back buffer that a frame paints
//! into and a front buffer that records what the terminal already shows. The
//! difference between them is the only thing the writer sends.
const std = @import("std");
const geom = @import("../geometry.zig");
const ansi = @import("../tui/ansi.zig");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromColor(c: geom.Color) Rgb {
        return .{ .r = chan(c.r), .g = chan(c.g), .b = chan(c.b) };
    }

    fn chan(v: f32) u8 {
        return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
    }

    /// Source over destination with a scalar coverage. A terminal cell has no alpha
    /// channel, so the blend resolves here and the cell keeps one opaque colour.
    pub fn blend(dst: Rgb, src: Rgb, coverage: f32) Rgb {
        const a = std.math.clamp(coverage, 0.0, 1.0);
        return .{
            .r = mix(dst.r, src.r, a),
            .g = mix(dst.g, src.g, a),
            .b = mix(dst.b, src.b, a),
        };
    }

    fn mix(d: u8, s: u8, a: f32) u8 {
        const df: f32 = @floatFromInt(d);
        const sf: f32 = @floatFromInt(s);
        return @intFromFloat(@round(df + (sf - df) * a));
    }

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
    italic: bool = false,

    pub fn eql(a: Attrs, b: Attrs) bool {
        return a.bold == b.bold and a.dim == b.dim and
            a.underline == b.underline and a.italic == b.italic;
    }
};

pub const Cell = struct {
    /// The codepoint to draw. Zero marks the continuation cell of a wide glyph: the
    /// writer skips it, because the terminal already advanced two columns.
    ch: u21 = ' ',
    fg: Rgb = .{ .r = 255, .g = 255, .b = 255 },
    bg: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    attrs: Attrs = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.fg.eql(b.fg) and a.bg.eql(b.bg) and a.attrs.eql(b.attrs);
    }
};

pub const ClipRect = struct { col: u16, row: u16, cols: u16, rows: u16 };

/// The coverage at which a fill is treated as opaque. Below this the fill tints the
/// background and leaves any glyph readable. At or above it the fill covers the
/// glyph, which is what a painter's algorithm does on a pixel surface.
const opaque_coverage: f32 = 0.5;

/// A codepoint the Unicode standard permanently reserves as "not a character". No
/// font, no font shaper, and no frame can ever produce it, and it differs from the
/// continuation marker for a wide glyph, which is 0. The front buffer starts filled
/// with it, so the first diff reports every cell as changed.
const front_sentinel: u21 = 0xFFFF;

pub const CellGrid = struct {
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    back: []Cell,
    front: []Cell,
    clips: std.ArrayList(ClipRect) = .empty,

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !CellGrid {
        const count = @as(usize, cols) * @as(usize, rows);
        const back = try gpa.alloc(Cell, count);
        errdefer gpa.free(back);
        const front = try gpa.alloc(Cell, count);
        @memset(back, .{});
        @memset(front, .{ .ch = front_sentinel });
        return .{ .gpa = gpa, .cols = cols, .rows = rows, .back = back, .front = front };
    }

    pub fn deinit(self: *CellGrid) void {
        self.gpa.free(self.back);
        self.gpa.free(self.front);
        self.clips.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn resize(self: *CellGrid, cols: u16, rows: u16) !void {
        const count = @as(usize, cols) * @as(usize, rows);
        const back = try self.gpa.alloc(Cell, count);
        errdefer self.gpa.free(back);
        const front = try self.gpa.alloc(Cell, count);
        self.gpa.free(self.back);
        self.gpa.free(self.front);
        self.back = back;
        self.front = front;
        self.cols = cols;
        self.rows = rows;
        @memset(self.back, .{});
        @memset(self.front, .{ .ch = front_sentinel });
        self.clips.clearRetainingCapacity();
    }

    /// Reset the back buffer to one background colour. The front buffer is untouched,
    /// so the writer still sends only what changed.
    pub fn clear(self: *CellGrid, bg: Rgb) void {
        @memset(self.back, .{ .bg = bg });
        self.clips.clearRetainingCapacity();
    }

    /// Force the next write to send every cell. Used after a resize and after the
    /// terminal may have been written to by something else.
    pub fn invalidate(self: *CellGrid) void {
        @memset(self.front, .{ .ch = front_sentinel });
    }

    pub fn pushClip(self: *CellGrid, rect: ClipRect) !void {
        const clipped = if (self.clips.items.len == 0) rect else intersect(self.clips.items[self.clips.items.len - 1], rect);
        try self.clips.append(self.gpa, clipped);
    }

    pub fn popClip(self: *CellGrid) void {
        if (self.clips.items.len == 0) return;
        _ = self.clips.pop();
    }

    /// The overlap of two rectangles. Uses u32 for the edge maths so a rectangle at
    /// the top of the u16 range cannot overflow, and reports zero size, never a
    /// wrapped one, when the two rectangles do not overlap.
    fn intersect(a: ClipRect, b: ClipRect) ClipRect {
        const left = @max(a.col, b.col);
        const top = @max(a.row, b.row);
        const right = @min(@as(u32, a.col) + a.cols, @as(u32, b.col) + b.cols);
        const bottom = @min(@as(u32, a.row) + a.rows, @as(u32, b.row) + b.rows);
        if (right <= left or bottom <= top) return .{ .col = left, .row = top, .cols = 0, .rows = 0 };
        return .{
            .col = left,
            .row = top,
            .cols = @intCast(right - left),
            .rows = @intCast(bottom - top),
        };
    }

    /// A pointer to one cell of the back buffer, or null when the position is off the
    /// grid or outside the current clip.
    pub fn cellAt(self: *CellGrid, col: u16, row: u16) ?*Cell {
        if (col >= self.cols or row >= self.rows) return null;
        if (self.clips.items.len > 0) {
            const c = self.clips.items[self.clips.items.len - 1];
            if (col < c.col or row < c.row) return null;
            // Widened to u32 so a clip rect near the top of the u16 range cannot
            // overflow the edge sum, the same hazard intersect() guards against.
            if (@as(u32, col) >= @as(u32, c.col) + c.cols or @as(u32, row) >= @as(u32, c.row) + c.rows) return null;
        }
        return &self.back[@as(usize, row) * self.cols + col];
    }

    pub fn blendBg(self: *CellGrid, col: u16, row: u16, color: Rgb, coverage: f32) void {
        if (coverage <= 0) return;
        const cell = self.cellAt(col, row) orelse return;
        cell.bg = cell.bg.blend(color, coverage);
        if (coverage >= opaque_coverage) cell.ch = ' ';
    }

    pub fn putChar(self: *CellGrid, col: u16, row: u16, ch: u21, fg: Rgb, attrs: Attrs) void {
        const cell = self.cellAt(col, row) orelse return;
        cell.ch = ch;
        cell.fg = fg;
        cell.attrs = attrs;
    }

    /// Compare the back buffer against the front buffer and append the smallest byte
    /// sequence that makes the terminal match. The front buffer then records what the
    /// terminal shows.
    ///
    /// The caller owns `out` and flushes it in one write. One write for each frame
    /// avoids a partly drawn frame reaching the screen.
    /// `opts.position` decides where the frame lands: at a fixed place on the
    /// screen, or wherever the cursor happens to be. See `Positioning`.
    pub fn writeFrame(self: *CellGrid, gpa: std.mem.Allocator, out: *std.ArrayList(u8), opts: WriteOpts) !void {
        const start_len = out.items.len;
        if (opts.sync) try out.appendSlice(gpa, ansi.sync_begin);

        // Which grid row the cursor is on, for `.relative`, where a move is
        // counted from the last one rather than stated outright. Starts at zero
        // because `.relative` DEFINES the cursor's position at the start of a
        // frame as the grid's top left corner. Unused under `.absolute`, where
        // every span states its own address and nothing has to be remembered.
        var cur_row: u16 = 0;

        // The last SGR state written, so a run of same coloured cells pays for one
        // sequence and not one for each cell. This state also survives a cursor jump
        // between spans: the terminal keeps its SGR state across a cursor move, so a
        // span that starts with the same colour the previous span ended with does not
        // resend it.
        var have_state = false;
        var last_fg: Rgb = undefined;
        var last_bg: Rgb = undefined;
        var last_attrs: Attrs = .{};

        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < self.cols) {
                const index = @as(usize, row) * self.cols + col;
                if (Cell.eql(self.back[index], self.front[index])) {
                    col += 1;
                    continue;
                }

                // A continuation cell carries no glyph of its own: the terminal only
                // moves two columns when the LEAD glyph before it is sent. A span
                // that opened here would move the cursor onto this column and then
                // write nothing for it, leaving the cursor one short of where the
                // rest of the span assumes it is. Backing the span up onto the lead
                // column and resending the whole glyph keeps the two in step.
                const span_start = if (self.back[index].ch == 0 and col > 0) col - 1 else col;

                // A span is a run of changed cells. One cursor move covers it all.
                var buf: [24]u8 = undefined;
                switch (opts.position) {
                    // Saturating, not wrapping: an origin that pushes a row past
                    // the top of the u16 range describes a screen no terminal
                    // has, and clamping puts the span at the last row rather
                    // than back at the first one, which is the less destructive
                    // of the two wrong answers. `cursorTo` takes u16, so the sum
                    // cannot be widened out of the problem.
                    .absolute => |o| try out.appendSlice(gpa, ansi.cursorTo(
                        buf[0..16],
                        row +| o.row,
                        span_start +| o.col,
                    )),
                    .relative => try moveRelative(gpa, out, &cur_row, row, span_start),
                }

                col = span_start;
                while (col < self.cols) : (col += 1) {
                    const i = @as(usize, row) * self.cols + col;
                    // The lead column the span backed up onto is written
                    // unconditionally: it did not change, but it still has to be
                    // resent so the cursor genuinely reaches the columns after it.
                    if (col != span_start and Cell.eql(self.back[i], self.front[i])) break;
                    const cell = self.back[i];
                    self.front[i] = cell;

                    // A continuation cell has no glyph of its own. The terminal moved
                    // two columns for the wide glyph before it, so writing anything
                    // here would push the row out of alignment. The front buffer is
                    // already updated above, so the next frame does not see this cell
                    // as changed again.
                    if (cell.ch == 0) continue;

                    // `.none` emits no SGR at all, so every cell keeps whatever
                    // colour the terminal already holds. The diff still runs on
                    // the full cell, colour included: a cell whose colour alone
                    // changed then costs a cursor move and a repeated glyph,
                    // which is wasteful but never wrong. Tracking a separate
                    // "visible difference" for this one mode would put the
                    // colour decision in two places, which is what routing it
                    // through `opts.color` exists to avoid.
                    const need_state = opts.color != .none and (!have_state or
                        !cell.fg.eql(last_fg) or
                        !cell.bg.eql(last_bg) or
                        !cell.attrs.eql(last_attrs));
                    if (need_state) {
                        if (have_state and !cell.attrs.eql(last_attrs)) {
                            // SGR has no per-attribute reset that is portable, so drop
                            // to a full reset before a different attribute set.
                            try out.appendSlice(gpa, ansi.sgr_reset);
                        }
                        // Re-sent here even on a colour-only change, where the attributes
                        // did not actually change: each SGR set code is idempotent, so
                        // applying it again costs a few bytes and changes nothing.
                        if (cell.attrs.bold) try out.appendSlice(gpa, ansi.csi ++ "1m");
                        if (cell.attrs.dim) try out.appendSlice(gpa, ansi.csi ++ "2m");
                        if (cell.attrs.italic) try out.appendSlice(gpa, ansi.csi ++ "3m");
                        if (cell.attrs.underline) try out.appendSlice(gpa, ansi.csi ++ "4m");
                        switch (opts.color) {
                            .truecolor => {
                                try out.appendSlice(gpa, ansi.setFg(&buf, cell.fg.r, cell.fg.g, cell.fg.b));
                                try out.appendSlice(gpa, ansi.setBg(&buf, cell.bg.r, cell.bg.g, cell.bg.b));
                            },
                            .indexed => {
                                try out.appendSlice(gpa, ansi.setFg256(buf[0..16], rgbTo256(cell.fg)));
                                try out.appendSlice(gpa, ansi.setBg256(buf[0..16], rgbTo256(cell.bg)));
                            },
                            // Unreachable rather than a no-op: `need_state` is
                            // false for `.none`, so this arm can only be entered
                            // if that guard is ever removed.
                            .none => unreachable,
                        }
                        have_state = true;
                        last_fg = cell.fg;
                        last_bg = cell.bg;
                        last_attrs = cell.attrs;
                    }

                    var utf8: [4]u8 = undefined;
                    // The codepoint comes from a font or from application text, and an
                    // unpaired surrogate cannot be encoded. That is a runtime fault in
                    // the input, so it degrades to a space and does not fail the frame.
                    const n = std.unicode.utf8Encode(cell.ch, &utf8) catch {
                        try out.append(gpa, ' ');
                        continue;
                    };
                    try out.appendSlice(gpa, utf8[0..n]);
                }
            }
        }

        // A frame that changed nothing must produce no bytes at all, so the sync
        // wrapper is removed rather than sent empty.
        if (out.items.len == start_len + (if (opts.sync) ansi.sync_begin.len else 0)) {
            out.shrinkRetainingCapacity(start_len);
            return;
        }

        if (have_state) try out.appendSlice(gpa, ansi.sgr_reset);
        // Put the cursor back where the frame found it, so the next frame's
        // moves count from the same place and whatever the caller prints next
        // lands where it expects rather than in the middle of the band.
        if (opts.position == .relative) {
            var home: [8]u8 = undefined;
            if (cur_row > 0) try out.appendSlice(gpa, ansi.cursorUp(&home, cur_row));
            try out.appendSlice(gpa, ansi.cr);
        }
        if (opts.sync) try out.appendSlice(gpa, ansi.sync_end);
    }

    /// Write the back buffer as plain text: one line for each row, no escape byte
    /// of any kind, no cursor move and no colour.
    ///
    /// This is not `writeFrame` with the colour turned off. `writeFrame` is a
    /// DIFFING screen writer: it sends only what changed and it positions each
    /// span absolutely, so it needs cursor moves whatever `WriteOpts.color` says.
    /// A pipe, a log or a golden file wants the whole grid as text instead, which
    /// is a different operation and gets its own function rather than a mode that
    /// quietly makes `writeFrame` stop diffing.
    ///
    /// The front buffer is untouched, so this can be called beside `writeFrame`
    /// without either confusing the other about what the terminal shows.
    /// Trailing blanks on each row are dropped: a text dump has no reason to
    /// carry them, and a golden file reads better without them.
    pub fn writePlain(self: *const CellGrid, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            const line = self.back[@as(usize, row) * self.cols ..][0..self.cols];
            var end: u16 = self.cols;
            while (end > 0 and isBlank(line[end - 1])) : (end -= 1) {}

            var col: u16 = 0;
            while (col < end) : (col += 1) {
                // A continuation cell carries no glyph of its own: the lead glyph
                // before it already stands for both columns. Writing anything
                // here would put a character in the row that is not in the grid.
                if (line[col].ch == 0) continue;
                var utf8: [4]u8 = undefined;
                // Same degradation `writeFrame` uses: an unpaired surrogate is a
                // runtime fault in the input, not a reason to fail the dump.
                const n = std.unicode.utf8Encode(line[col].ch, &utf8) catch {
                    try out.append(gpa, ' ');
                    continue;
                };
                try out.appendSlice(gpa, utf8[0..n]);
            }
            try out.append(gpa, '\n');
        }
    }
};

/// True for a cell that adds nothing to a text dump: a space, or the
/// continuation half of a wide glyph, which `writePlain` skips in any case.
fn isBlank(c: Cell) bool {
    return c.ch == ' ' or c.ch == 0;
}

/// Move the cursor to grid cell (`row`, `col`) without ever naming a screen
/// position, and record the row it now sits on.
///
/// The column is reached with a carriage return and then a move right, rather
/// than by counting from wherever the cursor was left. That costs a byte or two
/// and buys two things: it clears the pending wrap state a glyph in the last
/// column leaves behind (see `ansi.cr`), and it means the row is the only piece
/// of cursor state this has to keep, so there is one fewer thing to get wrong.
fn moveRelative(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cur_row: *u16,
    row: u16,
    col: u16,
) !void {
    var buf: [8]u8 = undefined;
    // Guarded because a terminal reads a zero parameter as one, so an
    // unguarded "move zero rows" would move one and the band would drift a row
    // for every span that happened to start on the row already under the cursor.
    if (row > cur_row.*) {
        try out.appendSlice(gpa, ansi.cursorDown(&buf, row - cur_row.*));
    } else if (row < cur_row.*) {
        try out.appendSlice(gpa, ansi.cursorUp(&buf, cur_row.* - row));
    }
    try out.appendSlice(gpa, ansi.cr);
    if (col > 0) try out.appendSlice(gpa, ansi.cursorRight(&buf, col));
    cur_row.* = row;
}

pub const ColorMode = enum {
    /// 24 bit SGR. What every terminal that answered the truecolor probe takes.
    truecolor,
    /// The xterm 256 colour palette, for a terminal with no truecolor.
    indexed,
    /// No SGR at all. The frame is glyphs and cursor moves, and every cell keeps
    /// the colour the terminal already holds. For a caller that owns the colour
    /// decision itself, or writes somewhere colour would be noise.
    none,
};

/// The screen cell that grid cell (0,0) is drawn at. A grid that owns the whole
/// screen leaves this at the origin. A grid that owns one region of a screen
/// something else also writes to puts its own top left corner here, so the frame
/// never lands on a row the caller keeps for itself.
pub const Origin = struct { col: u16 = 0, row: u16 = 0 };

/// How a frame finds the cells it writes.
pub const Positioning = union(enum) {
    /// Absolute cursor addressing from the screen origin, shifted by `Origin`.
    /// Right for a frame that owns the display, or a fixed region of it, where
    /// row 4 means row 4 of the screen for as long as the program runs.
    absolute: Origin,

    /// Relative to wherever the cursor already is, which is taken to be the
    /// grid's own top left corner. The frame puts the cursor back there when it
    /// is done, so the next frame counts from the same place.
    ///
    /// This is what a band under scrolling text needs. Such a band has NO fixed
    /// screen row: every line the caller prints scrolls it up by one. An
    /// absolute address would pin the band to a row the text then scrolls
    /// through, so the band and the text would climb over each other.
    ///
    /// Two things are the caller's to get right, and neither can be done from
    /// here:
    ///
    /// 1. **Make room first.** None of the relative moves scroll, so moving
    ///    down at the last row of the screen leaves the cursor where it is and
    ///    every row of the band lands on one line. Print as many newlines as
    ///    the band has rows, then move back up, before the first frame.
    /// 2. **Call `invalidate` after printing.** The front buffer records what
    ///    each CELL holds, not where the band is. Printing a line scrolls the
    ///    band to a new place with its old contents still on screen, and a diff
    ///    against an unchanged front buffer would then write nothing at all and
    ///    leave the stale copy where the scroll put it.
    relative,
};

pub const WriteOpts = struct {
    color: ColorMode,
    sync: bool,
    position: Positioning = .{ .absolute = .{} },
};

/// Map a colour to the xterm 256 colour palette. Indices 16 to 231 are a 6x6x6 cube
/// and 232 to 255 are a 24 step grey ramp. A near grey uses the ramp, which has finer
/// steps than the cube does on the grey diagonal.
pub fn rgbTo256(c: Rgb) u8 {
    const max = @max(c.r, @max(c.g, c.b));
    const min = @min(c.r, @min(c.g, c.b));
    if (max - min < 8 and c.r > 8 and c.r < 248) {
        const level = (@as(u16, c.r) - 8) / 10;
        const capped: u16 = @min(level, 23);
        return @intCast(232 + capped);
    }
    const r6 = cubeIndex(c.r);
    const g6 = cubeIndex(c.g);
    const b6 = cubeIndex(c.b);
    return @intCast(16 + 36 * @as(u16, r6) + 6 * @as(u16, g6) + b6);
}

/// Map one colour channel to its 6 level cube index. The cube's real levels are 0,
/// 95, 135, 175, 215 and 255, so the gap from level 0 to level 1 is wider than the
/// rest and a plain divide would bias the dark end.
fn cubeIndex(v: u8) u8 {
    if (v < 48) return 0;
    if (v < 115) return 1;
    return @intCast(@min((@as(u16, v) - 35) / 40, 5));
}

test "a new grid holds cols by rows cells and every cell starts blank" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 80, 24);
    defer g.deinit();
    try std.testing.expectEqual(@as(u16, 80), g.cols);
    try std.testing.expectEqual(@as(u16, 24), g.rows);
    try std.testing.expectEqual(@as(usize, 80 * 24), g.back.len);
    try std.testing.expectEqual(@as(u21, ' '), g.back[0].ch);
}

test "cellAt returns null outside the grid and a pointer inside it" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    try std.testing.expect(g.cellAt(0, 0) != null);
    try std.testing.expect(g.cellAt(3, 1) != null);
    try std.testing.expect(g.cellAt(4, 0) == null);
    try std.testing.expect(g.cellAt(0, 2) == null);
}

test "blendBg at full coverage replaces the background" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.blendBg(0, 0, .{ .r = 255, .g = 0, .b = 0 }, 1.0);
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 0).?.bg.g);
}

test "blendBg at half coverage mixes with what was there" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.blendBg(0, 0, .{ .r = 200, .g = 100, .b = 0 }, 0.5);
    const c = g.cellAt(0, 0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 100), @as(f32, @floatFromInt(c.bg.r)), 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 50), @as(f32, @floatFromInt(c.bg.g)), 1.5);
}

test "blendBg at zero coverage changes nothing" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 10, .g = 20, .b = 30 });
    g.blendBg(0, 0, .{ .r = 255, .g = 255, .b = 255 }, 0.0);
    try std.testing.expectEqual(@as(u8, 10), g.cellAt(0, 0).?.bg.r);
}

test "a fill over a cell that holds a glyph clears the glyph" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.putChar(0, 0, 'X', .{ .r = 255, .g = 255, .b = 255 }, .{});
    try std.testing.expectEqual(@as(u21, 'X'), g.cellAt(0, 0).?.ch);
    // Painter order: a later opaque fill covers the glyph the same way it covers
    // the background.
    g.blendBg(0, 0, .{ .r = 0, .g = 0, .b = 255 }, 1.0);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
}

test "a partial fill does not clear a glyph, because the text is still readable" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.putChar(0, 0, 'X', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.blendBg(0, 0, .{ .r = 0, .g = 0, .b = 255 }, 0.3);
    try std.testing.expectEqual(@as(u21, 'X'), g.cellAt(0, 0).?.ch);
}

test "a fill at exactly the opaque threshold clears the glyph" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.putChar(0, 0, 'X', .{ .r = 255, .g = 255, .b = 255 }, .{});
    // Exactly at the threshold. The comparison is >=, so this must clear.
    g.blendBg(0, 0, .{ .r = 0, .g = 0, .b = 255 }, opaque_coverage);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
}

test "a fill just below the opaque threshold leaves the glyph readable" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.putChar(0, 0, 'X', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.blendBg(0, 0, .{ .r = 0, .g = 0, .b = 255 }, opaque_coverage - 0.01);
    try std.testing.expectEqual(@as(u21, 'X'), g.cellAt(0, 0).?.ch);
}

test "a clip rectangle rejects writes outside it" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    try g.pushClip(.{ .col = 2, .row = 2, .cols = 3, .rows = 3 });
    try std.testing.expect(g.cellAt(1, 2) == null);
    try std.testing.expect(g.cellAt(2, 2) != null);
    try std.testing.expect(g.cellAt(4, 4) != null);
    try std.testing.expect(g.cellAt(5, 4) == null);
    g.popClip();
    try std.testing.expect(g.cellAt(1, 2) != null);
}

test "nested clips intersect and never widen the parent" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    try g.pushClip(.{ .col = 2, .row = 2, .cols = 4, .rows = 4 });
    try g.pushClip(.{ .col = 0, .row = 0, .cols = 10, .rows = 10 });
    // The inner clip asks for the whole grid, and the intersection keeps the outer.
    try std.testing.expect(g.cellAt(1, 1) == null);
    try std.testing.expect(g.cellAt(3, 3) != null);
    g.popClip();
    g.popClip();
}

test "resize reallocates and reports the new dimensions" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    try g.resize(80, 24);
    try std.testing.expectEqual(@as(u16, 80), g.cols);
    try std.testing.expectEqual(@as(usize, 80 * 24), g.back.len);
    try std.testing.expectEqual(@as(usize, 80 * 24), g.front.len);
}

test "resize down to zero leaves the grid valid and every write is rejected" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    try g.resize(0, 0);
    try std.testing.expectEqual(@as(usize, 0), g.back.len);
    try std.testing.expectEqual(@as(usize, 0), g.front.len);
    try std.testing.expect(g.cellAt(0, 0) == null);
    g.putChar(0, 0, 'X', .{ .r = 1, .g = 1, .b = 1 }, .{}); // must not crash
}

test "a zero size grid is valid and every write is rejected" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 0, 0);
    defer g.deinit();
    try std.testing.expect(g.cellAt(0, 0) == null);
    g.putChar(0, 0, 'X', .{ .r = 1, .g = 1, .b = 1 }, .{}); // must not crash
}

test "the first frame writes every changed cell and nothing else" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'h', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.putChar(1, 0, 'i', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    // One cursor move for the span, one colour pair, then the two characters.
    try std.testing.expectEqualStrings(
        "\x1b[1;1H\x1b[38;2;255;255;255m\x1b[48;2;0;0;0mhi\x1b[0m",
        out.items,
    );
}

test "a frame that changes nothing writes nothing" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    try std.testing.expect(out.items.len > 0); // the first frame always writes

    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a frame that changes nothing writes nothing even with sync on" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = true });
    try std.testing.expect(out.items.len > 0); // the first frame always writes

    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = true });
    // The sync wrapper must not survive when nothing else was written.
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "only the changed cell is written on the second frame" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(2, 0, 'Z', .{ .r = 255, .g = 0, .b = 0 }, .{});
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    // The cursor jumps to column three (one based) and only Z is sent.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;3H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, " ") == null);
}

test "the colour sequence is emitted one time for a run of same coloured cells" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, 'a', white, .{});
    g.putChar(1, 0, 'b', white, .{});
    g.putChar(2, 0, 'c', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "38;2;255;255;255"));
}

test "the colour state survives a cursor jump between two spans of the same colour" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 5, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A settled first frame, so columns 1 through 3 already match the front
    // buffer and do not appear in the span the second frame writes.
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    out.clearRetainingCapacity();

    // Columns 1 through 3 are left unchanged, so the two spans below are
    // separated by a gap the writer must jump over with a fresh cursor move.
    g.putChar(0, 0, 'a', white, .{});
    g.putChar(4, 0, 'b', white, .{});
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    // Two cursor moves for the two spans, but the colour is set only once: the
    // terminal still holds it across the jump.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "H"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "38;2;255;255;255"));
}

test "sync wraps the frame when the terminal supports it" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 1, 1);
    defer g.deinit();
    g.putChar(0, 0, 'x', .{ .r = 1, .g = 1, .b = 1 }, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = true });
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[?2026h"));
    try std.testing.expect(std.mem.endsWith(u8, out.items, "\x1b[?2026l"));
}

test "without truecolor the writer emits indexed colour" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 1, 1);
    defer g.deinit();
    g.putChar(0, 0, 'x', .{ .r = 255, .g = 255, .b = 255 }, .{});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .indexed, .sync = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "38;5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "38;2;") == null);
}

test "bold and italic attributes reach the SGR sequence" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 1, 1);
    defer g.deinit();
    g.putChar(0, 0, 'x', .{ .r = 255, .g = 255, .b = 255 }, .{ .bold = true, .italic = true });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[3m") != null);
}

test "a wide glyph continuation cell is not written" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, '\u{4E00}', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.cellAt(1, 0).?.ch = 0; // the continuation cell
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    // The wide glyph appears one time and no stray cursor move sits between it and
    // the next cell.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "\u{4E00}"));
}

test "a wide glyph continuation cell still updates the front buffer" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, '\u{4E00}', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.cellAt(1, 0).?.ch = 0; // the continuation cell
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    // A second frame with the same content, unchanged, must write nothing. If the
    // continuation cell's skip also skipped the front buffer update, the front and
    // back buffers would disagree forever and this would keep re-sending the row.
    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, '\u{4E00}', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.cellAt(1, 0).?.ch = 0;
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "a damage span that starts on a wide glyph continuation cell resends the lead glyph instead of losing a column" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, '\u{4E00}', white, .{});
    g.putChar(1, 0, 0, white, .{}); // the continuation cell
    g.putChar(2, 0, 'Z', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false }); // settle the front buffer
    out.clearRetainingCapacity();

    // Only the continuation cell's background changes, the way a fill edge that
    // lands between the two columns would leave it: Cell.eql compares bg, so this
    // alone marks the continuation cell changed while the lead glyph still
    // matches the front buffer. Column two changes too, so the writer's span runs
    // across both in one pass, which is what exposes the bug: a span that opens
    // on a continuation cell writes no byte for it, so the cursor never actually
    // reaches the column the code goes on to assume it is at.
    g.cellAt(1, 0).?.bg = .{ .r = 0, .g = 0, .b = 255 };
    g.putChar(2, 0, 'Y', white, .{});
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });

    // The span must back up onto the lead column and resend the whole glyph, so
    // the cursor is truly there by the time the writer reaches column two. The
    // bug moves the cursor straight to column two (one based column three) with
    // no glyph resent first, so "Y" lands one column short of where the front
    // buffer now claims it is.
    try std.testing.expectEqualStrings(
        "\x1b[1;1H\x1b[38;2;255;255;255m\x1b[48;2;0;0;0m\u{4E00}Y\x1b[0m",
        out.items,
    );
}

test "a continuation cell in the first column of the row cannot back up further and must not underflow" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    // A continuation cell can never legitimately open a row: `paintTextRun` only
    // ever writes one at `col + 1` for a `col` it already wrote a lead glyph at.
    // This only exists to prove the span's back-up in `writeFrame` cannot
    // underflow column zero if that invariant is ever violated.
    g.putChar(0, 0, 0, .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
}

test "an origin offsets every cursor move, so a grid can own one region of a larger screen" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'h', .{ .r = 255, .g = 255, .b = 255 }, .{});
    g.putChar(1, 0, 'i', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{
        .color = .none,
        .sync = false,
        .position = .{ .absolute = .{ .col = 4, .row = 20 } },
    });

    // Grid cell (0,0) lands at screen cell (4,20), which CUP counts from one as
    // row 21, column 5. Without the origin this would be the bare "\x1b[1;1H".
    try std.testing.expectEqualStrings("\x1b[21;5Hhi", out.items);
}

test "an origin that would push a span past the u16 range clamps instead of wrapping back to the first row" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 1, 1);
    defer g.deinit();
    g.putChar(0, 0, 'x', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{
        .color = .none,
        .sync = false,
        .position = .{ .absolute = .{ .col = 65535, .row = 65535 } },
    });

    // Saturated to 65535, printed one based as 65536. A wrapping add would give
    // "\x1b[1;1H" here and paint over the top left corner of somebody else's
    // screen, which is the outcome the saturating add exists to rule out.
    try std.testing.expectEqualStrings("\x1b[65536;65536Hx", out.items);
}

test "relative positioning names no screen row, moving down from where the cursor already was" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 3);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, 'a', white, .{});
    g.putChar(0, 1, 'b', white, .{});
    g.putChar(0, 2, 'c', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });

    // Row 0 needs no vertical move at all, because relative positioning DEFINES
    // the cursor as already being there. Rows 1 and 2 each move down one. Then
    // the cursor comes back up two to where the frame found it.
    try std.testing.expectEqualStrings(
        "\ra  " ++ // row 0: no move down, the frame starts here
            "\x1b[1B\rb  " ++ // row 1
            "\x1b[1B\rc  " ++ // row 2
            "\x1b[2A\r", // home again
        out.items,
    );
}

test "relative positioning never emits a zero move, which a terminal would read as one" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'x', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });

    // One row, starting at column zero, so there is no row to move and no
    // column to move. A terminal reads "CSI 0 A" as "CSI 1 A", so emitting an
    // unguarded zero move would walk the band a row up the screen every frame.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[0") == null);
    try std.testing.expectEqualStrings("\rx \r", out.items);
}

test "relative positioning reaches a column with a carriage return and a move right, never an absolute address" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 6, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // A settled first frame, so only the one cell changed below is in the span.
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });
    out.clearRetainingCapacity();

    g.putChar(4, 0, 'Z', .{ .r = 255, .g = 255, .b = 255 }, .{});
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });

    try std.testing.expectEqualStrings("\r\x1b[4CZ\r", out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "H") == null);
}

test "a relative frame that changed nothing writes nothing, not even a move back home" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });
    try std.testing.expect(out.items.len > 0);

    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });
    // A still band on an idle loop must cost nothing. A bare carriage return
    // each turn would be harmless on screen but would keep the stream busy
    // forever, which is what the empty-frame check exists to prevent.
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "invalidate makes a relative band redraw in full, which is what a scroll needs" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'a', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });

    // The caller prints a line: the terminal scrolls, so the band is now one row
    // higher on screen with its old contents still showing, while the back
    // buffer is unchanged. Without `invalidate` the diff sees no change and
    // writes nothing, and the stale copy stays where the scroll left it.
    out.clearRetainingCapacity();
    g.invalidate();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'a', .{ .r = 255, .g = 255, .b = 255 }, .{});
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false, .position = .relative });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a") != null);
}

test "colour mode none emits no SGR at all, not even the trailing reset" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 10, .g = 20, .b = 30 });
    g.putChar(0, 0, 'a', .{ .r = 255, .g = 0, .b = 0 }, .{ .bold = true });
    g.putChar(1, 0, 'b', .{ .r = 0, .g = 255, .b = 0 }, .{});
    g.putChar(2, 0, 'c', .{ .r = 0, .g = 0, .b = 255 }, .{ .underline = true });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false });

    // Three cells with three different colours and three different attribute
    // sets: every SGR path the writer has is exercised and none of them fires.
    try std.testing.expectEqualStrings("\x1b[1;1Habc", out.items);
}

test "colour mode none still diffs, so a second unchanged frame writes nothing" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 3, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'a', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false });
    try std.testing.expect(out.items.len > 0);

    out.clearRetainingCapacity();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'a', .{ .r = 255, .g = 255, .b = 255 }, .{});
    try g.writeFrame(gpa, &out, .{ .color = .none, .sync = false });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "writePlain writes the grid as text with no escape byte anywhere in it" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 6, 2);
    defer g.deinit();
    g.clear(.{ .r = 40, .g = 50, .b = 60 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, 'h', white, .{ .bold = true });
    g.putChar(1, 0, 'i', white, .{});
    g.putChar(0, 1, 'y', white, .{});
    g.putChar(1, 1, 'o', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writePlain(gpa, &out);

    try std.testing.expectEqualStrings("hi\nyo\n", out.items);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, out.items, 0x1b));
}

test "writePlain keeps an interior space and drops only the trailing run" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, 'a', white, .{});
    // Column one keeps the space `clear` left there.
    g.putChar(2, 0, 'b', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writePlain(gpa, &out);
    try std.testing.expectEqualStrings("a b\n", out.items);
}

test "writePlain writes a wide glyph one time and does not count its continuation cell" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    g.putChar(0, 0, '\u{4E00}', white, .{});
    g.putChar(1, 0, 0, white, .{}); // the continuation cell
    g.putChar(2, 0, 'Z', white, .{});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writePlain(gpa, &out);
    try std.testing.expectEqualStrings("\u{4E00}Z\n", out.items);
}

test "writePlain leaves the front buffer alone, so a writeFrame after it still sends the frame" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 2, 1);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });
    g.putChar(0, 0, 'h', .{ .r = 255, .g = 255, .b = 255 }, .{});

    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(gpa);
    try g.writePlain(gpa, &plain);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writeFrame(gpa, &out, .{ .color = .truecolor, .sync = false });
    // The dump must not have convinced the writer the terminal already shows
    // this frame: a caller that logs a grid and then draws it needs both.
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, 'h') != null);
}

test "an empty grid writes one newline for each row and nothing else" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 3);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try g.writePlain(gpa, &out);
    try std.testing.expectEqualStrings("\n\n\n", out.items);
}

test "rgbTo256 maps pure white and pure black to the ends of the cube" {
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(.{ .r = 0, .g = 0, .b = 0 }));
}

test "rgbTo256 maps a grey to the grayscale ramp and not to the colour cube" {
    const idx = rgbTo256(.{ .r = 128, .g = 128, .b = 128 });
    try std.testing.expect(idx >= 232 and idx <= 255);
}
