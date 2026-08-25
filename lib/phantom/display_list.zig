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
    /// The box the mark draws into, in device pixels. The icon grid maps onto
    /// this box, so it is a size and not a scale factor.
    ///
    /// A box that is not square scales the two axes by different amounts. That
    /// is what a rule needs: `rule_vertical` must reach the full height of its
    /// row while it stays one column wide, and stretching a straight line along
    /// its own length keeps it straight. A mark with shape in both axes, a tick
    /// for one, comes out distorted, so a caller asks for this only where it
    /// means it (see `widgets/icon.zig`'s `Fit`).
    size: geom.PhysicalSize,
    /// The mark is a single colour: coverage tints this, as a glyph does.
    color: geom.Color,
    /// Top-left of that box in device pixels.
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

/// True when two primitives would draw the same thing.
///
/// Exhaustive on the tag, so a new primitive kind fails to compile here rather
/// than being silently treated as unchanged, which would show up as a frame that
/// never repaints.
///
/// Every slice is compared by CONTENT, because the storage behind it is reused
/// from frame to frame: `TextRun.glyphs` and `TextRun.text` borrow RenderText's
/// buffers and `IconPrimitive.label` borrows the caller's, so comparing pointers
/// would call a changed label unchanged. The two type-erased pointers, `font`
/// and `image`, are compared by identity instead: both refer to objects that
/// outlive the frame and are not rewritten in place.
pub fn primitiveEql(a: Primitive, b: Primitive) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .rrect => |x| std.meta.eql(x, b.rrect),
        .text => |x| t: {
            const y = b.text;
            break :t x.font == y.font and
                x.size == y.size and
                std.meta.eql(x.color, y.color) and
                std.meta.eql(x.origin, y.origin) and
                x.ascent == y.ascent and
                std.mem.eql(u8, x.text, y.text) and
                glyphsEql(x.glyphs, y.glyphs);
        },
        .push_scroll => |x| std.meta.eql(x, b.push_scroll),
        .pop_scroll => true,
        .push_clip => |x| std.meta.eql(x, b.push_clip),
        .pop_clip => true,
        .image => |x| std.meta.eql(x, b.image),
        .icon => |x| i: {
            const y = b.icon;
            break :i x.id == y.id and
                std.meta.eql(x.size, y.size) and
                std.meta.eql(x.color, y.color) and
                std.meta.eql(x.origin, y.origin) and
                optionalBytesEql(x.label, y.label);
        },
    };
}

/// Compared field by field rather than as raw bytes: `cp` is a `u21`, so the
/// bytes behind a `PositionedGlyph` carry padding bits that mean nothing and
/// need not match. Comparing those would report a difference on every frame,
/// which is exactly the repaint this comparison exists to avoid.
fn glyphsEql(a: []const PositionedGlyph, b: []const PositionedGlyph) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.cp != y.cp or x.x != y.x or x.y != y.y) return false;
    }
    return true;
}

fn optionalBytesEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// A copy of one frame's display list, kept so the next frame can be compared
/// against it.
///
/// This exists for backends whose cost of DRAWING a frame is far above the cost
/// of deciding whether to. The terminal's pixel mode is the case that forced it:
/// reading one 3002x1665 frame back off the GPU measured 1.05 SECONDS, and the
/// loop was paying that ten times a second to redraw a screen that had not
/// changed. Comparing the display list first costs microseconds, because a
/// frame is a few hundred primitives and a few hundred glyphs.
///
/// The copy is what makes the comparison honest. Holding the previous frame's
/// primitives without copying their slice contents would compare this frame
/// against storage that this frame has already overwritten, which reads as "no
/// change" exactly when the text changed.
pub const Snapshot = struct {
    prims: std.ArrayList(Primitive) = .empty,
    /// Backing storage the captured primitives' slices are rebased onto. Two
    /// arrays and not one byte blob, so `PositionedGlyph` keeps its natural
    /// alignment instead of needing a cast out of a `[]u8`.
    glyphs: std.ArrayList(PositionedGlyph) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    captured: bool = false,

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        self.prims.deinit(gpa);
        self.glyphs.deinit(gpa);
        self.bytes.deinit(gpa);
        self.* = undefined;
    }

    /// Forget the captured frame, so the next comparison reports a difference.
    /// For when something other than this list changed what is on screen.
    pub fn reset(self: *Snapshot) void {
        self.captured = false;
    }

    /// Whether `list` differs from the captured frame, capturing it when it
    /// does. Nothing captured yet counts as a difference, so the first frame of
    /// a run always draws.
    ///
    /// A matching list is NOT re-captured: the stored copy already equals it, so
    /// the steady state does no copying at all.
    pub fn differs(self: *Snapshot, gpa: std.mem.Allocator, list: DisplayList) !bool {
        if (self.captured and self.matches(list)) return false;
        try self.capture(gpa, list);
        return true;
    }

    fn matches(self: *const Snapshot, list: DisplayList) bool {
        if (self.prims.items.len != list.primitives.items.len) return false;
        for (self.prims.items, list.primitives.items) |a, b| {
            if (!primitiveEql(a, b)) return false;
        }
        return true;
    }

    fn capture(self: *Snapshot, gpa: std.mem.Allocator, list: DisplayList) !void {
        // Reserved up front and filled after, so appending cannot reallocate
        // part way and leave the slices rebased onto it dangling.
        var total_glyphs: usize = 0;
        var total_bytes: usize = 0;
        for (list.primitives.items) |p| switch (p) {
            .text => |t| {
                total_glyphs += t.glyphs.len;
                total_bytes += t.text.len;
            },
            .icon => |i| total_bytes += if (i.label) |l| l.len else 0,
            else => {},
        };
        try self.prims.ensureTotalCapacity(gpa, list.primitives.items.len);
        try self.glyphs.ensureTotalCapacity(gpa, total_glyphs);
        try self.bytes.ensureTotalCapacity(gpa, total_bytes);
        self.prims.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();

        for (list.primitives.items) |p| {
            var copy = p;
            switch (copy) {
                .text => |*t| {
                    t.glyphs = self.appendGlyphs(t.glyphs);
                    t.text = self.appendBytes(t.text);
                },
                .icon => |*i| {
                    if (i.label) |l| i.label = self.appendBytes(l);
                },
                else => {},
            }
            self.prims.appendAssumeCapacity(copy);
        }
        self.captured = true;
    }

    fn appendGlyphs(self: *Snapshot, src: []const PositionedGlyph) []const PositionedGlyph {
        const start = self.glyphs.items.len;
        self.glyphs.appendSliceAssumeCapacity(src);
        return self.glyphs.items[start..][0..src.len];
    }

    fn appendBytes(self: *Snapshot, src: []const u8) []const u8 {
        const start = self.bytes.items.len;
        self.bytes.appendSliceAssumeCapacity(src);
        return self.bytes.items[start..][0..src.len];
    }
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

test "a snapshot reports the first frame as a difference, then an identical one as none" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = .{ .r = 1, .g = 0, .b = 0 },
    } });

    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));
}

test "a changed primitive is a difference, and the frame after it is not" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .radius = 0,
        .color = .{ .r = 1, .g = 0, .b = 0 },
    } });
    try std.testing.expect(try snap.differs(gpa, list));

    // The colour a Button changes on hover, which is a repaint with no rebuild.
    list.primitives.items[0].rrect.color = .{ .r = 0, .g = 1, .b = 0 };
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));
}

test "text is compared by content, so reusing the buffer behind it cannot hide a change" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    // ONE buffer, rewritten in place between frames. This is what RenderText
    // does: the slice in the display list borrows storage the next layout
    // overwrites. A snapshot that kept the slice instead of copying what it
    // pointed at would be comparing this frame against itself and would report
    // "no change" for every edit a text field ever makes.
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..5], "Taps0");
    var font: u8 = 0;

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &.{},
        .text = buf[0..5],
        .font = @ptrCast(&font),
        .size = 16,
        .color = .{ .r = 1, .g = 1, .b = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));

    @memcpy(buf[0..5], "Taps1");
    try std.testing.expect(try snap.differs(gpa, list));
}

test "glyph positions are compared, so text that moved without changing is a difference" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    var glyphs = [_]PositionedGlyph{ .{ .cp = 'a', .x = 0, .y = 0 }, .{ .cp = 'b', .x = 8, .y = 0 } };
    var font: u8 = 0;
    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .text = .{
        .glyphs = &glyphs,
        .text = "ab",
        .font = @ptrCast(&font),
        .size = 16,
        .color = .{ .r = 1, .g = 1, .b = 1 },
        .origin = .{ .x = 0, .y = 0 },
    } });
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));

    // Same characters, laid out one pixel further along.
    glyphs[1].x = 9;
    try std.testing.expect(try snap.differs(gpa, list));
}

test "a primitive appended or removed is a difference even when every shared one matches" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    const box = Primitive{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
        .radius = 0,
        .color = .{ .r = 1, .g = 1, .b = 1 },
    } };
    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, box);
    try std.testing.expect(try snap.differs(gpa, list));

    try list.append(gpa, box);
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));

    _ = list.primitives.pop();
    try std.testing.expect(try snap.differs(gpa, list));
}

test "reset forces the next frame to draw, for when something else wrote to the screen" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .pop_clip = {} });
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));

    snap.reset();
    try std.testing.expect(try snap.differs(gpa, list));
}

test "an empty frame after a drawn one is a difference, and stays quiet after that" {
    const gpa = std.testing.allocator;
    var snap: Snapshot = .{};
    defer snap.deinit(gpa);

    var list: DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .pop_scroll = {} });
    try std.testing.expect(try snap.differs(gpa, list));

    list.clear();
    try std.testing.expect(try snap.differs(gpa, list));
    try std.testing.expect(!try snap.differs(gpa, list));
}
