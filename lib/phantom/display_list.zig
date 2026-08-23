const std = @import("std");
const geom = @import("geometry.zig");
/// The icon subsystem imports nothing from here, so naming `Id` directly costs
/// no cycle and spares every backend an untyped integer to switch on. Fonts are
/// type-erased above only because text.zig does import this module.
const icon_builtin = @import("icon/builtin.zig");

pub const RRect = struct {
    rect: geom.PhysicalRect,
    radius: f32,
    color: geom.Color,
    stroke_width: f32 = 0, // physical px; 0 = filled, >0 = inside border ring
    hover_color: ?geom.Color = null, // DOM :hover only; Prism ignores
    active_color: ?geom.Color = null, // DOM :active only; Prism ignores
};

/// A single positioned glyph within a laid-out text run. `x`/`y` are baseline-
/// relative offsets from the run's `origin`, in device pixels.
pub const PositionedGlyph = struct { cp: u21, x: f32, y: f32 };

/// A laid-out run of text. Carries BOTH the positioned glyphs (the Prism backend
/// blits them) and the source string + font (the DOM backend renders real HTML
/// text). `font` is erased to *anyopaque so this module does not import the text
/// engine (which imports this module); backends cast it back to *text.Font. The
/// `glyphs` slice borrows RenderText-owned storage and is valid only for the frame.
pub const TextRun = struct {
    glyphs: []const PositionedGlyph,
    text: []const u8,
    /// Type-erased font pointer. Backends @ptrCast this to *text.Font. Kept as
    /// *anyopaque here to avoid an import cycle: text imports display_list, so
    /// display_list must not import text.
    font: *anyopaque,
    size: f32,
    color: geom.Color,
    /// Top-left of the run in device pixels. Glyph x/y are baseline-relative, so a
    /// backend that blits glyphs (Prism) places the baseline at origin.y + ascent.
    origin: geom.PhysicalOffset,
    /// Distance from origin (the run's top) down to the baseline, in device pixels
    /// (the line ascent). Prism adds this to reach the baseline; the DOM backend
    /// ignores it and lets CSS position the text within the div at origin.
    ascent: f32 = 0,
};

pub const ScrollRegion = struct {
    viewport: geom.PhysicalRect,
    offset: geom.PhysicalOffset,
    content: geom.PhysicalSize,
};

/// A rounded rectangle that bounds everything drawn until the matching
/// `pop_clip`. A zero radius is a plain rectangular clip.
///
/// How much of the shape a backend honours depends on what it can express. The
/// DOM backend clips to the full rounded shape. The character grid has no shape
/// inside a cell, so it clips to the cell rectangle and drops the radius. The
/// GPU backend clips with a scissor rectangle, which is also square: a rounded
/// scissor needs a clip term in every fragment shader, which is not built yet.
pub const ClipRegion = struct {
    rect: geom.PhysicalRect,
    radius: f32 = 0,
};

pub const ImagePrimitive = struct {
    image: *anyopaque, // type-erased *image.Image (backends @ptrCast); avoids an import cycle
    rect: geom.PhysicalRect,
    opacity: f32 = 1,
};

/// A built-in icon to draw. The frontend emits the identity, the size and the
/// tint; the backend expands the centreline, rasterises it at `size` and caches
/// the coverage. That is the same split text uses, where the frontend emits
/// glyph indices and the backend owns the atlas, and it keeps a frame's cost at
/// one primitive per icon however many contours the mark has.
pub const IconPrimitive = struct {
    id: icon_builtin.Id,
    /// Side of the square the mark draws into, in device pixels. The icon grid
    /// maps onto this square, so it is a size and not a scale factor.
    size: f32,
    /// The mark is a single colour: coverage tints this, as a glyph does.
    color: geom.Color,
    /// Top-left of that square in device pixels.
    origin: geom.PhysicalOffset,
    /// The accessible name of the mark, or null when a neighbouring label
    /// already names it and a second announcement would only repeat. The DOM
    /// backend writes it as an SVG `<title>`, which is what a screen reader
    /// reads. Prism drops it: a GPU surface has no accessibility tree to put it
    /// in. The slice borrows caller storage and is valid for the frame only,
    /// which is the same rule `TextRun.text` follows.
    label: ?[]const u8 = null,
};

pub const Primitive = union(enum) {
    rrect: RRect,
    text: TextRun,
    push_scroll: ScrollRegion,
    pop_scroll: void,
    push_clip: ClipRegion,
    pop_clip: void,
    image: ImagePrimitive,
    icon: IconPrimitive,
};

pub const DisplayList = struct {
    primitives: std.ArrayList(Primitive) = .empty,

    pub fn deinit(self: *DisplayList, gpa: std.mem.Allocator) void {
        self.primitives.deinit(gpa);
    }
    pub fn clear(self: *DisplayList) void {
        self.primitives.clearRetainingCapacity();
    }
    pub fn append(self: *DisplayList, gpa: std.mem.Allocator, p: Primitive) !void {
        try self.primitives.append(gpa, p);
    }
};
