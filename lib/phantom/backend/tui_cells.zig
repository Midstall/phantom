//! Mode B: the display list becomes character cells. Rectangles become background
//! colours, borders become box drawing glyphs and text becomes the codepoints the
//! terminal draws.
const std = @import("std");
const dl = @import("../display_list.zig");
const geom = @import("../geometry.zig");
const grid_mod = @import("cell_grid.zig");
const CellGrid = grid_mod.CellGrid;
const Rgb = grid_mod.Rgb;
const DisplayList = dl.DisplayList;
const text = @import("../text.zig");
const mono = @import("../text/mono.zig");
const image_mod = @import("../image/Image.zig");
const icon_builtin = @import("../icon/builtin.zig");
const Attrs = grid_mod.Attrs;

pub const Ctx = struct {
    cell_w: f32,
    cell_h: f32,
};

/// The signed distance to a rounded box, ported from `shaders/rrect.frag.glsl`. The
/// GPU and the terminal must agree on the shape, so this is the same function and not
/// an approximation of it.
pub fn sdRoundedBox(px: f32, py: f32, hw: f32, hh: f32, r: f32) f32 {
    const qx = @abs(px) - hw + r;
    const qy = @abs(py) - hh + r;
    const outside = std.math.hypot(@max(qx, 0.0), @max(qy, 0.0));
    return @min(@max(qx, qy), 0.0) + outside - r;
}

/// How many sample points to take across one cell in each axis. A cell is roughly
/// 9 by 18 pixels, and 2 by 2 gives coverage in quarters, which is enough resolution
/// for a colour that a terminal shows as one flat block.
const samples = 2;

/// The fraction of one cell that a filled rounded rectangle covers, from 0 to 1.
pub fn fillCoverage(r: dl.RRect, cell_col: u16, cell_row: u16, ctx: Ctx) f32 {
    return sampleCell(r, cell_col, cell_row, ctx, false);
}

/// The fraction of one cell that the border ring of a rounded rectangle covers.
pub fn strokeCoverage(r: dl.RRect, cell_col: u16, cell_row: u16, ctx: Ctx) f32 {
    return sampleCell(r, cell_col, cell_row, ctx, true);
}

fn sampleCell(r: dl.RRect, cell_col: u16, cell_row: u16, ctx: Ctx, ring: bool) f32 {
    const hw = r.rect.width * 0.5;
    const hh = r.rect.height * 0.5;
    const cx = r.rect.x + hw;
    const cy = r.rect.y + hh;
    // The radius cannot exceed the half extent, and a font or a widget may ask for
    // more, so clamp it here rather than trusting the caller.
    const radius = @min(r.radius, @min(hw, hh));

    var hits: u32 = 0;
    var sy: u32 = 0;
    while (sy < samples) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < samples) : (sx += 1) {
            const fx = (@as(f32, @floatFromInt(sx)) + 0.5) / @as(f32, samples);
            const fy = (@as(f32, @floatFromInt(sy)) + 0.5) / @as(f32, samples);
            const px = (@as(f32, @floatFromInt(cell_col)) + fx) * ctx.cell_w - cx;
            const py = (@as(f32, @floatFromInt(cell_row)) + fy) * ctx.cell_h - cy;
            const d = sdRoundedBox(px, py, hw, hh, radius);
            const inside = if (ring) (d <= 0 and d >= -r.stroke_width) else (d <= 0);
            if (inside) hits += 1;
        }
    }
    return @as(f32, @floatFromInt(hits)) / @as(f32, samples * samples);
}

/// The cell range a rectangle can touch, as a half open interval: `c1` and `r1`
/// sit one past the last covered cell, in both axes.
pub const Bounds = struct { c0: u16, r0: u16, c1: u16, r1: u16 };

/// The cell range a rectangle can touch. Clamped to the grid, so a rectangle that
/// starts off screen still paints the part that is on screen.
fn cellBounds(rect: geom.PhysicalRect, ctx: Ctx, grid: *CellGrid) Bounds {
    const left = @max(@floor(rect.x / ctx.cell_w), 0);
    const top = @max(@floor(rect.y / ctx.cell_h), 0);
    const right = @ceil((rect.x + rect.width) / ctx.cell_w);
    const bottom = @ceil((rect.y + rect.height) / ctx.cell_h);
    return .{
        .c0 = @intFromFloat(@min(left, @as(f32, @floatFromInt(grid.cols)))),
        .r0 = @intFromFloat(@min(top, @as(f32, @floatFromInt(grid.rows)))),
        .c1 = @intFromFloat(@max(@min(right, @as(f32, @floatFromInt(grid.cols))), 0)),
        .r1 = @intFromFloat(@max(@min(bottom, @as(f32, @floatFromInt(grid.rows))), 0)),
    };
}

fn paintFill(grid: *CellGrid, r: dl.RRect, ctx: Ctx) void {
    const b = cellBounds(r.rect, ctx, grid);
    const color = Rgb.fromColor(r.color);
    var row = b.r0;
    while (row < b.r1) : (row += 1) {
        var col = b.c0;
        while (col < b.c1) : (col += 1) {
            const cov = fillCoverage(r, col, row, ctx) * r.color.a;
            // blendBg clears the cell's glyph once coverage reaches its opaque
            // threshold, so a fill painted after a border erases the border glyph
            // it lands on, matching the painter's algorithm order the GPU backend
            // uses. This is a genuine limit of a character grid: a pixel backend
            // blends a half covering fill and leaves the border partly visible,
            // but a cell holds one glyph or none, so the terminal has to pick.
            grid.blendBg(col, row, color, cov);
        }
    }
}

const box_horizontal: u21 = '\u{2500}';
const box_vertical: u21 = '\u{2502}';
const box_top_left: u21 = '\u{250C}';
const box_top_right: u21 = '\u{2510}';
const box_bottom_left: u21 = '\u{2514}';
const box_bottom_right: u21 = '\u{2518}';
const box_round_top_left: u21 = '\u{256D}';
const box_round_top_right: u21 = '\u{256E}';
const box_round_bottom_right: u21 = '\u{256F}';
const box_round_bottom_left: u21 = '\u{2570}';

/// The glyph for one cell of a border, or null when the cell is not on the border.
/// `b` is the half open cell range of the rectangle, so `c1` and `r1` are one past
/// the last cell.
pub fn borderGlyph(col: u16, row: u16, b: Bounds, radius: f32) ?u21 {
    if (b.c1 <= b.c0 or b.r1 <= b.r0) return null;
    const last_col = b.c1 - 1;
    const last_row = b.r1 - 1;
    const on_left = col == b.c0;
    const on_right = col == last_col;
    const on_top = row == b.r0;
    const on_bottom = row == last_row;
    const rounded = radius > 0;

    // A one cell wide or one cell tall box puts a cell on two edges at once, for
    // example both the top and the bottom. The checks below run top before bottom
    // and left before right, so a degenerate box always reads as its top corner
    // and never has to pick between two corners that collapsed onto one cell.
    if (on_top and on_left) return if (rounded) box_round_top_left else box_top_left;
    if (on_top and on_right) return if (rounded) box_round_top_right else box_top_right;
    if (on_bottom and on_left) return if (rounded) box_round_bottom_left else box_bottom_left;
    if (on_bottom and on_right) return if (rounded) box_round_bottom_right else box_bottom_right;
    if (on_top or on_bottom) return box_horizontal;
    if (on_left or on_right) return box_vertical;
    return null;
}

fn paintStroke(grid: *CellGrid, r: dl.RRect, ctx: Ctx) void {
    const b = cellBounds(r.rect, ctx, grid);
    const color = Rgb.fromColor(r.color);

    // A ring thinner than one cell cannot be seen as a tint, so it becomes glyphs.
    // A thicker ring covers whole cells and the tint reads correctly.
    const thin = r.stroke_width < @min(ctx.cell_w, ctx.cell_h);
    if (!thin) {
        var row = b.r0;
        while (row < b.r1) : (row += 1) {
            var col = b.c0;
            while (col < b.c1) : (col += 1) {
                const cov = strokeCoverage(r, col, row, ctx) * r.color.a;
                grid.blendBg(col, row, color, cov);
            }
        }
        return;
    }

    var row = b.r0;
    while (row < b.r1) : (row += 1) {
        var col = b.c0;
        while (col < b.c1) : (col += 1) {
            const glyph = borderGlyph(col, row, b, r.radius) orelse continue;
            grid.putChar(col, row, glyph, color, .{});
        }
    }
}

/// The terminal draws the glyphs, so the font identity survives only as attributes.
/// 600 is where semibold starts, and it is the same threshold CSS uses for bold.
pub fn attrsForFont(font: *text.Font) Attrs {
    return .{ .bold = font.weight() >= 600, .italic = font.isItalic() };
}

fn paintText(grid: *CellGrid, run: dl.TextRun, ctx: Ctx) void {
    // A negative origin means the run scrolled above or left of the viewport. The
    // cell index is unsigned, so the run starts at the grid edge and the clip
    // rectangle removes what should not show.
    const col_f = @floor(run.origin.x / ctx.cell_w + 0.5);
    const row_f = @floor(run.origin.y / ctx.cell_h + 0.5);
    const cols_f: f32 = @floatFromInt(grid.cols);
    const rows_f: f32 = @floatFromInt(grid.rows);
    // A non-finite offset, or a row past either edge of the grid, means no cell of
    // this run can ever land on screen. The whole run is dropped rather than fed
    // to a cast that cannot represent it.
    if (!std.math.isFinite(col_f) or !std.math.isFinite(row_f)) return;
    if (row_f < 0 or row_f >= rows_f or col_f >= cols_f) return;

    const font: *text.Font = @ptrCast(@alignCast(run.font));
    const attrs = attrsForFont(font);
    const color = Rgb.fromColor(run.color);
    const row: u16 = @intFromFloat(row_f);

    // Clamped so the cast to i32 below cannot overflow even when the run starts far
    // to the left of the viewport. col_f is already known to be less than cols_f,
    // which fits in i32 with room to spare, so only the lower bound needs guarding.
    const col_clamped = @max(col_f, -cols_f - 1);
    var col_i: i32 = @intFromFloat(col_clamped);
    // The run text comes from the application and may not be valid UTF-8. That is a
    // runtime fault in the input, so the run is dropped and the frame continues.
    var it = (std.unicode.Utf8View.init(run.text) catch return).iterator();
    while (it.nextCodepoint()) |cp| {
        const width = mono.wcwidth(cp);
        if (width == 0) {
            // A combining mark rides on the cell before it: no cell, no advance.
            continue;
        }
        if (col_i >= @as(i32, grid.cols)) break;
        if (col_i >= 0) {
            const col: u16 = @intCast(col_i);
            grid.putChar(col, row, cp, color, attrs);
            // The terminal advances two columns for a wide glyph, so the second cell
            // must carry the continuation mark and never a glyph of its own.
            if (width == 2 and col + 1 < grid.cols) {
                grid.putChar(col + 1, row, 0, color, attrs);
            }
        }
        col_i += @as(i32, width);
    }
}

/// Blend one flat colour into every cell of `b`. Shared by the image and icon
/// fallbacks, which both stand in for a shape mode B cannot draw with a single
/// solid block over the shape's cell range.
fn fillCellRect(grid: *CellGrid, b: Bounds, color: Rgb, alpha: f32) void {
    var row = b.r0;
    while (row < b.r1) : (row += 1) {
        var col = b.c0;
        while (col < b.c1) : (col += 1) {
            grid.blendBg(col, row, color, alpha);
        }
    }
}

fn paintImageFallback(grid: *CellGrid, p: dl.ImagePrimitive, ctx: Ctx) void {
    const img: *image_mod = @ptrCast(@alignCast(p.image));
    const avg = averageColor(img);
    const b = cellBounds(p.rect, ctx, grid);
    fillCellRect(grid, b, avg, p.opacity);
}

/// The mean of every pixel. A terminal with no graphics support shows one flat block
/// for the image, and the mean is the least wrong single colour for it.
///
/// `Image.rgba` is optional: it is null until a decoder runs, and an encoded image
/// that nothing decoded yet has no pixels to average. That is a runtime condition
/// and not a programmer error, so it returns black rather than failing the frame.
fn averageColor(img: *image_mod) Rgb {
    const pixels = img.rgba orelse return .{ .r = 0, .g = 0, .b = 0 };
    var sum_r: u64 = 0;
    var sum_g: u64 = 0;
    var sum_b: u64 = 0;
    var count: u64 = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        sum_r += pixels[i];
        sum_g += pixels[i + 1];
        sum_b += pixels[i + 2];
        count += 1;
    }
    if (count == 0) return .{ .r = 0, .g = 0, .b = 0 };
    return .{
        .r = @intCast(sum_r / count),
        .g = @intCast(sum_g / count),
        .b = @intCast(sum_b / count),
    };
}

fn paintIconFallback(grid: *CellGrid, p: dl.IconPrimitive, ctx: Ctx) void {
    const rect = geom.PhysicalRect{
        .x = p.origin.x,
        .y = p.origin.y,
        .width = p.size,
        .height = p.size,
    };
    const b = cellBounds(rect, ctx, grid);
    const color = Rgb.fromColor(p.color);

    // A mark that has no coverage draws nothing, which is what the block below
    // does at alpha zero. Any coverage above that draws the whole character: a
    // cell is either the character or it is not, so there is no partly drawn
    // one. `paintText` treats its own colour the same way.
    if (p.color.a <= 0) return;

    if (icon_builtin.cellMarkFor(p.id)) |mark| {
        paintCellMark(grid, b, mark, color);
        return;
    }
    // No character means this mark, so it degrades to one solid block. The icon
    // shape needs a graphics protocol, and mode B has none.
    fillCellRect(grid, b, color, p.color.a);
}

/// Put `mark` into the cells of `b`, one character for a symbol and the whole
/// box for a rule.
fn paintCellMark(grid: *CellGrid, b: Bounds, mark: icon_builtin.CellMark, color: Rgb) void {
    // An empty box means the mark sits off the grid, or rounded away to nothing.
    if (b.c1 <= b.c0 or b.r1 <= b.r0) return;
    if (mark.tile) {
        var row = b.r0;
        while (row < b.r1) : (row += 1) {
            var col = b.c0;
            while (col < b.c1) : (col += 1) grid.putChar(col, row, mark.cp, color, .{});
        }
        return;
    }
    // The middle of the box, biased left and up. A square mark is two cells wide
    // whenever a cell is taller than it is wide, which is every terminal, and
    // the box then has no true middle. Left is the better of the two: a mark
    // usually leads the text beside it, and the far cell would put a gap there.
    grid.putChar(b.c0 + (b.c1 - b.c0 - 1) / 2, b.r0 + (b.r1 - b.r0 - 1) / 2, mark.cp, color, .{});
}

/// Shift a rect by the current scroll offset. `RenderScrollView.paintFn` paints its
/// child at the plain, unscrolled offset and leaves the scroll to the backend (see
/// `prism.zig`'s `appendQuad` doing the same for the GPU path), so every primitive
/// inside a scroll region arrives in unscrolled coordinates. A positive offset is a
/// downward or rightward scroll, which moves content up or left on screen, hence
/// the subtraction.
fn translateRect(rect: geom.PhysicalRect, offset: geom.PhysicalOffset) geom.PhysicalRect {
    return .{ .x = rect.x - offset.x, .y = rect.y - offset.y, .width = rect.width, .height = rect.height };
}

fn translateOffset(o: geom.PhysicalOffset, offset: geom.PhysicalOffset) geom.PhysicalOffset {
    return .{ .x = o.x - offset.x, .y = o.y - offset.y };
}

/// Walk the display list and paint it into the grid. The caller clears the grid
/// first, so this function only adds.
pub fn render(grid: *CellGrid, list: DisplayList, ctx: Ctx) !void {
    // The accumulated scroll offset of every push_scroll currently open, applied to
    // each primitive's position before it is painted. Regions can nest, so this is a
    // stack: push_scroll adds its own offset on top of what its ancestors already
    // contributed, and pop_scroll removes exactly that contribution again.
    var offset_stack: std.ArrayList(geom.PhysicalOffset) = .empty;
    defer offset_stack.deinit(grid.gpa);
    var offset: geom.PhysicalOffset = .zero;

    for (list.primitives.items) |prim| {
        switch (prim) {
            .rrect => |r| {
                var translated = r;
                translated.rect = translateRect(r.rect, offset);
                if (r.stroke_width > 0) paintStroke(grid, translated, ctx) else paintFill(grid, translated, ctx);
            },
            .text => |run| {
                var translated = run;
                translated.origin = translateOffset(run.origin, offset);
                paintText(grid, translated, ctx);
            },
            .push_scroll => |s| {
                // The viewport is the region's own position in its parent's space, so
                // any offset already open (an ancestor's scroll) applies to it too. The
                // region's own offset takes effect only for what is painted inside it.
                const b = cellBounds(translateRect(s.viewport, offset), ctx, grid);
                try grid.pushClip(.{
                    .col = b.c0,
                    .row = b.r0,
                    .cols = b.c1 -| b.c0,
                    .rows = b.r1 -| b.r0,
                });
                try offset_stack.append(grid.gpa, offset);
                offset = .{ .x = offset.x + s.offset.x, .y = offset.y + s.offset.y };
            },
            .push_clip => |c| {
                // The radius is dropped: a cell is the smallest thing the grid
                // can address, so there is no shape inside one to round. The
                // rectangle still cuts a child at the boundary, and `pushClip`
                // intersects with any clip already open.
                const b = cellBounds(translateRect(c.rect, offset), ctx, grid);
                try grid.pushClip(.{
                    .col = b.c0,
                    .row = b.r0,
                    .cols = b.c1 -| b.c0,
                    .rows = b.r1 -| b.r0,
                });
            },
            .pop_clip => grid.popClip(),
            .pop_scroll => {
                grid.popClip();
                // A pop with no matching push is a malformed display list, a runtime
                // fault and not a programmer error, so it falls back to no offset
                // rather than crash on the empty stack.
                offset = offset_stack.pop() orelse geom.PhysicalOffset.zero;
            },
            .image => |p| {
                var translated = p;
                translated.rect = translateRect(p.rect, offset);
                paintImageFallback(grid, translated, ctx);
            },
            .icon => |p| {
                var translated = p;
                translated.origin = translateOffset(p.origin, offset);
                paintIconFallback(grid, translated, ctx);
            },
        }
    }
}

test "sdRoundedBox is negative inside, zero on the edge and positive outside" {
    // A box half width 10, half height 10, no radius, sampled from its centre.
    try std.testing.expect(sdRoundedBox(0, 0, 10, 10, 0) < 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sdRoundedBox(10, 0, 10, 10, 0), 0.001);
    try std.testing.expect(sdRoundedBox(20, 0, 10, 10, 0) > 0);
}

test "a radius pulls the corner inside the square bounds" {
    // The corner of the square is inside the box, and the same corner of a rounded
    // box is outside it.
    try std.testing.expect(sdRoundedBox(9.9, 9.9, 10, 10, 0) < 0);
    try std.testing.expect(sdRoundedBox(9.9, 9.9, 10, 10, 8) > 0);
}

test "a fill that covers a whole cell reports full coverage" {
    const ctx = Ctx{ .cell_w = 9, .cell_h = 18 };
    const r = testRRect(0, 0, 90, 180, 0);
    try std.testing.expectEqual(@as(f32, 1), fillCoverage(r, 5, 5, ctx));
}

test "a fill that misses a cell reports no coverage" {
    const ctx = Ctx{ .cell_w = 9, .cell_h = 18 };
    const r = testRRect(0, 0, 9, 18, 0);
    try std.testing.expectEqual(@as(f32, 0), fillCoverage(r, 5, 5, ctx));
}

test "a fill that covers the left half of a cell reports half coverage" {
    const ctx = Ctx{ .cell_w = 8, .cell_h = 16 };
    // The rect ends at x=4, which is the middle of the first cell.
    const r = testRRect(0, 0, 4, 16, 0);
    try std.testing.expectEqual(@as(f32, 0.5), fillCoverage(r, 0, 0, ctx));
}

test "a large radius removes the corner cell of a box" {
    const ctx = Ctx{ .cell_w = 8, .cell_h = 16 };
    // A 64x64 box with a 32 radius is a circle, so its top left cell is empty.
    const square = testRRect(0, 0, 64, 64, 0);
    const circle = testRRect(0, 0, 64, 64, 32);
    try std.testing.expectEqual(@as(f32, 1), fillCoverage(square, 0, 0, ctx));
    try std.testing.expectEqual(@as(f32, 0), fillCoverage(circle, 0, 0, ctx));
}

test "render fills the covered cells and leaves the rest alone" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 16, .height = 32 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });

    // Two columns by two rows are red, and the cell beyond is untouched.
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(1, 1).?.bg.r);
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(2, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 2).?.bg.r);
}

test "a half transparent fill mixes with the cell it lands on" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 4);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 8, .height = 16 },
        .radius = 0,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // Full geometric coverage, half alpha, so the result is half red.
    try std.testing.expectApproxEqAbs(
        @as(f32, 128),
        @as(f32, @floatFromInt(g.cellAt(0, 0).?.bg.r)),
        2,
    );
}

fn testRRect(x: f32, y: f32, w: f32, h: f32, radius: f32) dl.RRect {
    return .{
        .rect = .{ .x = x, .y = y, .width = w, .height = h },
        .radius = radius,
        .color = geom.Color.rgb(1, 1, 1),
    };
}

test "a square border picks the four corners and the four edges" {
    const b = Bounds{ .c0 = 0, .r0 = 0, .c1 = 4, .r1 = 3 };
    try std.testing.expectEqual(@as(?u21, '\u{250C}'), borderGlyph(0, 0, b, 0)); // top left
    try std.testing.expectEqual(@as(?u21, '\u{2510}'), borderGlyph(3, 0, b, 0)); // top right
    try std.testing.expectEqual(@as(?u21, '\u{2514}'), borderGlyph(0, 2, b, 0)); // bottom left
    try std.testing.expectEqual(@as(?u21, '\u{2518}'), borderGlyph(3, 2, b, 0)); // bottom right
    try std.testing.expectEqual(@as(?u21, '\u{2500}'), borderGlyph(1, 0, b, 0)); // top edge
    try std.testing.expectEqual(@as(?u21, '\u{2502}'), borderGlyph(0, 1, b, 0)); // left edge
}

test "a radius picks the rounded corners and keeps the same edges" {
    const b = Bounds{ .c0 = 0, .r0 = 0, .c1 = 4, .r1 = 3 };
    try std.testing.expectEqual(@as(?u21, '\u{256D}'), borderGlyph(0, 0, b, 6));
    try std.testing.expectEqual(@as(?u21, '\u{256E}'), borderGlyph(3, 0, b, 6));
    try std.testing.expectEqual(@as(?u21, '\u{2570}'), borderGlyph(0, 2, b, 6));
    try std.testing.expectEqual(@as(?u21, '\u{256F}'), borderGlyph(3, 2, b, 6));
    try std.testing.expectEqual(@as(?u21, '\u{2500}'), borderGlyph(1, 0, b, 6));
}

test "an interior cell is not part of the border" {
    const b = Bounds{ .c0 = 0, .r0 = 0, .c1 = 4, .r1 = 3 };
    try std.testing.expectEqual(@as(?u21, null), borderGlyph(1, 1, b, 0));
    try std.testing.expectEqual(@as(?u21, null), borderGlyph(2, 1, b, 0));
}

test "a thin stroke draws box glyphs and keeps the background" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 10, .g = 10, .b = 10 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
        .radius = 0,
        .color = geom.Color.rgb(0, 1, 0),
        .stroke_width = 1,
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });

    try std.testing.expectEqual(@as(u21, '\u{250C}'), g.cellAt(0, 0).?.ch);
    try std.testing.expectEqual(@as(u21, '\u{2500}'), g.cellAt(1, 0).?.ch);
    try std.testing.expectEqual(@as(u21, '\u{2518}'), g.cellAt(3, 2).?.ch);
    // The border colour is the foreground, and the background stays what it was.
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.fg.g);
    try std.testing.expectEqual(@as(u8, 10), g.cellAt(0, 0).?.bg.r);
}

test "a stroke wider than one cell tints instead of drawing glyphs" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .rrect = .{
            .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
            .radius = 0,
            .color = geom.Color.rgb(0, 1, 0),
            .stroke_width = 20, // wider than the 8 by 16 cell
        },
    });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // No glyph, a tinted background instead.
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
    try std.testing.expect(g.cellAt(0, 0).?.bg.g > 0);
}

test "an empty bounds reports no border and does not underflow" {
    const empty_cols = Bounds{ .c0 = 5, .r0 = 0, .c1 = 5, .r1 = 4 };
    try std.testing.expectEqual(@as(?u21, null), borderGlyph(5, 0, empty_cols, 0));
    const empty_rows = Bounds{ .c0 = 0, .r0 = 5, .c1 = 4, .r1 = 5 };
    try std.testing.expectEqual(@as(?u21, null), borderGlyph(0, 5, empty_rows, 0));
}

test "a one cell wide box picks a corner at each end and a vertical bar between" {
    // c0 and c1 - 1 are the same column, so that column is both the left and
    // the right edge. The border still resolves to a sensible glyph, not a crash.
    const b = Bounds{ .c0 = 2, .r0 = 0, .c1 = 3, .r1 = 4 };
    try std.testing.expectEqual(@as(?u21, '\u{250C}'), borderGlyph(2, 0, b, 0));
    try std.testing.expectEqual(@as(?u21, '\u{2514}'), borderGlyph(2, 3, b, 0));
    try std.testing.expectEqual(@as(?u21, '\u{2502}'), borderGlyph(2, 1, b, 0));
}

test "a one cell tall box picks a corner at each end and a horizontal bar between" {
    // r0 and r1 - 1 are the same row, so that row is both the top and the
    // bottom edge. The border still resolves to a sensible glyph, not a crash.
    const b = Bounds{ .c0 = 0, .r0 = 5, .c1 = 4, .r1 = 6 };
    try std.testing.expectEqual(@as(?u21, '\u{250C}'), borderGlyph(0, 5, b, 0));
    try std.testing.expectEqual(@as(?u21, '\u{2510}'), borderGlyph(3, 5, b, 0));
    try std.testing.expectEqual(@as(?u21, '\u{2500}'), borderGlyph(1, 5, b, 0));
}

test "a stroke exactly one cell wide falls on the tint side of the threshold" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .rrect = .{
            .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
            .radius = 0,
            .color = geom.Color.rgb(0, 1, 0),
            // Equal to the smaller cell dimension: the comparison is strict less
            // than, so this lands on the tint side, not the glyph side.
            .stroke_width = 8,
        },
    });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
    try std.testing.expect(g.cellAt(0, 0).?.bg.g > 0);
}

test "an opaque fill painted after a border erases the border glyph, as the painter's algorithm order requires" {
    // The primitive list is emitted in paint order, and the GPU backend also
    // draws later primitives over earlier ones (see the render loop comment in
    // prism.zig), so an opaque fill on top of a border must erase the glyph here
    // too. Anything else would make the terminal disagree with the GPU about
    // what a DecoratedBox with an opaque child looks like.
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
        .radius = 0,
        .color = geom.Color.rgb(0, 1, 0),
        .stroke_width = 1,
    } });
    try list.append(gpa, .{
        .rrect = .{
            .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
            .radius = 0,
            .color = geom.Color.rgb(1, 0, 0), // fully opaque, covers the whole ring
        },
    });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.bg.r);
}

test "a border painted after an opaque fill keeps its glyph" {
    // putChar runs after the fill's blendBg in paint order, so the glyph it
    // writes is the last thing to touch the cell and survives.
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
        .radius = 0,
        .color = geom.Color.rgb(0, 1, 0),
        .stroke_width = 1,
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, '\u{250C}'), g.cellAt(0, 0).?.ch);
}

test "a fill below the opaque threshold tints the background but leaves the border glyph readable" {
    // A cell backend cannot show a half covering fill the way a pixel backend
    // does, since there is no such thing as half a glyph. Below the opaque
    // threshold the fill still tints, but the glyph it lands on is untouched.
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
        .radius = 0,
        .color = geom.Color.rgb(0, 1, 0),
        .stroke_width = 1,
    } });
    try list.append(gpa, .{
        .rrect = .{
            .rect = .{ .x = 0, .y = 0, .width = 32, .height = 48 },
            .radius = 0,
            .color = .{ .r = 1, .g = 0, .b = 0, .a = 0.3 }, // below the 0.5 opaque threshold
        },
    });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, '\u{250C}'), g.cellAt(0, 0).?.ch);
    try std.testing.expect(g.cellAt(0, 0).?.bg.r > 0);
}

test "a text run writes its codepoints starting at the cell of its origin" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 20, 4);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "hi",
        .font = @ptrCast(&font),
        .size = 14,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 16, .y = 16 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, 'h'), g.cellAt(2, 1).?.ch);
    try std.testing.expectEqual(@as(u21, 'i'), g.cellAt(3, 1).?.ch);
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(2, 1).?.fg.r);
}

test "a wide codepoint takes two cells and marks the second as a continuation" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 20, 4);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "\u{4E00}A",
        .font = @ptrCast(&font),
        .size = 14,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, '\u{4E00}'), g.cellAt(0, 0).?.ch);
    try std.testing.expectEqual(@as(u21, 0), g.cellAt(1, 0).?.ch);
    try std.testing.expectEqual(@as(u21, 'A'), g.cellAt(2, 0).?.ch);
}

test "text that runs past the right edge is clipped and does not wrap" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "abcdefgh",
        .font = @ptrCast(&font),
        .size = 14,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, 'd'), g.cellAt(3, 0).?.ch);
    // Row 1 must stay blank. A wrap here would be a silent layout error.
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 1).?.ch);
}

test "a bold font sets the bold attribute on every cell of its run" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 2);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.mesmerize_sb_bytes);
    defer font.deinit(gpa);
    // The attribute follows the font weight, so this test only means something when
    // the bundled semibold really reports 600 or more.
    if (font.weight() < 600) return error.SkipZigTest;

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "B",
        .font = @ptrCast(&font),
        .size = 14,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expect(g.cellAt(0, 0).?.attrs.bold);
}

test "a scroll region clips its contents and offsets them" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = .{ .x = 16, .y = 16, .width = 32, .height = 32 },
        .offset = .{ .x = 0, .y = 0 },
        .content = .{ .width = 32, .height = 100 },
    } });
    // A rectangle that starts above the viewport must be cut at the viewport edge.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 80 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .pop_scroll);

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // Inside the viewport is painted.
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(2, 1).?.bg.r);
    // Outside it is not, even though the rectangle covers that cell.
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 0).?.bg.r);
}

test "an image with no graphics support becomes a block of its average colour" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    // A 2x2 image, all pure red. `fromRgba` borrows the pixels and sets
    // `rgba_owned` false, so this path allocates nothing and frees nothing.
    const pixels = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255,
        255, 0, 0, 255, 255, 0, 0, 255,
    };
    var img = image_mod.fromRgba(&pixels, 2, 2);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .image = .{
        .image = @ptrCast(&img),
        .rect = .{ .x = 0, .y = 0, .width = 16, .height = 32 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.bg.r);
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 0).?.bg.g);
}

test "a scroll offset moves content up by the same number of cells it scrolled" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .push_scroll = .{
            .viewport = .{ .x = 0, .y = 0, .width = 80, .height = 160 },
            .offset = .{ .x = 0, .y = 32 }, // scrolled down two cells
            .content = .{ .width = 80, .height = 200 },
        },
    });
    // Sits at row 3 in unscrolled coordinates.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 48, .width = 8, .height = 16 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .pop_scroll);

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // The scroll moved it up by two cells, to row 1, not row 3.
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 1).?.bg.r);
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 3).?.bg.r);
}

test "content scrolled past the viewport is clipped away entirely" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .push_scroll = .{
            .viewport = .{ .x = 0, .y = 0, .width = 80, .height = 32 }, // 10 cols x 2 rows
            .offset = .{ .x = 0, .y = 500 }, // scrolled far past the content
            .content = .{ .width = 80, .height = 600 },
        },
    });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 80, .height = 32 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .pop_scroll);

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // The rect moved 500px above the viewport: nothing in the whole grid paints.
    var row: u16 = 0;
    while (row < 10) : (row += 1) {
        var col: u16 = 0;
        while (col < 10) : (col += 1) {
            try std.testing.expectEqual(@as(u8, 0), g.cellAt(col, row).?.bg.r);
        }
    }
}

test "a text run inside a scrolled region moves by the same amount as a rectangle does" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .push_scroll = .{
            .viewport = .{ .x = 0, .y = 0, .width = 80, .height = 160 },
            .offset = .{ .x = 0, .y = 32 }, // scrolled down two cells, same as the rect test
            .content = .{ .width = 80, .height = 200 },
        },
    });
    try list.append(gpa, .{
        .text = .{
            .glyphs = &.{},
            .text = "z",
            .font = @ptrCast(&font),
            .size = 14,
            .color = geom.Color.rgb(1, 1, 1),
            .origin = .{ .x = 0, .y = 48 }, // row 3 in unscrolled coordinates
        },
    });
    try list.append(gpa, .pop_scroll);

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    // A translation reaching only rects and not text would leave this at row 3.
    try std.testing.expectEqual(@as(u21, 'z'), g.cellAt(0, 1).?.ch);
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 3).?.ch);
}

test "nested scroll regions accumulate their offsets and unwind on pop" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 10, 10);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{
        .push_scroll = .{
            .viewport = .{ .x = 0, .y = 0, .width = 80, .height = 160 },
            .offset = .{ .x = 0, .y = 16 }, // outer: one cell
            .content = .{ .width = 80, .height = 300 },
        },
    });
    try list.append(gpa, .{
        .push_scroll = .{
            .viewport = .{ .x = 0, .y = 0, .width = 80, .height = 160 },
            .offset = .{ .x = 0, .y = 16 }, // inner: another cell, on top of the outer one
            .content = .{ .width = 80, .height = 300 },
        },
    });
    // Sits at row 4 in unscrolled coordinates; both offsets apply, landing on row 2.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 64, .width = 8, .height = 16 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .pop_scroll);
    try list.append(gpa, .pop_scroll);
    // Outside both regions again: an unscrolled primitive at the same position must
    // land on its own row. A leftover offset from either popped region would shift
    // this one too.
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 64, .width = 8, .height = 16 },
        .radius = 0,
        .color = geom.Color.rgb(0, 0, 1),
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 2).?.bg.r);
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 4).?.bg.b);
}

test "an extreme scroll offset does not crash the text or rect paths" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 4, 4);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .push_scroll = .{
        .viewport = .{ .x = 0, .y = 0, .width = 32, .height = 64 },
        .offset = .{ .x = 1.0e30, .y = 1.0e30 },
        .content = .{ .width = 32, .height = 64 },
    } });
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = "x",
        .font = @ptrCast(&font),
        .size = 14,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = .{ .x = 0, .y = 0 },
    } });
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 8, .height = 16 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try list.append(gpa, .pop_scroll);

    // Must not panic. The extreme offset pushes both primitives' translated
    // coordinates far past what any cell index can represent.
    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u8, 0), g.cellAt(0, 0).?.bg.r);
}

test "a mark with a character becomes that character, not a block" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    // One cell, at the origin.
    try list.append(gpa, .{ .icon = .{
        .id = .check,
        .size = 16,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    const cell = g.cellAt(0, 0).?;
    try std.testing.expectEqual(@as(u21, '\u{2713}'), cell.ch);
    try std.testing.expectEqual(@as(u8, 255), cell.fg.r);
    // A block would have painted the background instead, which is the bug this
    // test is about: the tick has to be readable, so the cell keeps its own.
    try std.testing.expectEqual(@as(u8, 0), cell.bg.r);
}

test "a rule fills every cell it covers, so a stacked rail has no gap" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    // Three cells tall, which is the shape a provenance rail asks for.
    try list.append(gpa, .{ .icon = .{
        .id = .rule_vertical,
        .size = 48,
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    for (0..3) |row| {
        try std.testing.expectEqual(@as(u21, '\u{2502}'), g.cellAt(0, @intCast(row)).?.ch);
    }
}

test "a symbol taller than one cell draws once, not once for every cell" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .check,
        .size = 48,
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    var ticks: usize = 0;
    for (0..8) |row| {
        for (0..8) |col| {
            if (g.cellAt(@intCast(col), @intCast(row)).?.ch == '\u{2713}') ticks += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), ticks);
}

test "a mark with no character keeps the block it always had" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = 16,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u8, 255), g.cellAt(0, 0).?.bg.r);
}

test "a mark with no coverage draws nothing" {
    const gpa = std.testing.allocator;
    var g = try CellGrid.init(gpa, 8, 8);
    defer g.deinit();
    g.clear(.{ .r = 0, .g = 0, .b = 0 });

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .icon = .{
        .id = .check,
        .size = 16,
        .color = .{ .r = 1, .g = 0, .b = 0, .a = 0 },
        .origin = .{ .x = 0, .y = 0 },
    } });

    try render(&g, list, .{ .cell_w = 8, .cell_h = 16 });
    try std.testing.expectEqual(@as(u21, ' '), g.cellAt(0, 0).?.ch);
}
