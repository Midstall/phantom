const std = @import("std");
const geom = @import("geometry.zig");
const dl = @import("display_list.zig");
const FaultSink = @import("FaultSink.zig");

pub const Canvas = struct {
    gpa: std.mem.Allocator,
    list: dl.DisplayList = .{},
    sink: ?*FaultSink = null,

    pub fn init(gpa: std.mem.Allocator) Canvas {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Canvas) void {
        self.list.deinit(self.gpa);
    }
    pub fn clear(self: *Canvas) void {
        self.list.clear();
    }
    pub fn fillRRect(self: *Canvas, rect: geom.PhysicalRect, radius: f32, color: geom.Color) !void {
        try self.list.append(self.gpa, .{ .rrect = .{ .rect = rect, .radius = radius, .color = color } });
    }

    pub fn strokeRRect(self: *Canvas, rect: geom.PhysicalRect, radius: f32, width: f32, color: geom.Color) !void {
        try self.list.append(self.gpa, .{ .rrect = .{ .rect = rect, .radius = radius, .color = color, .stroke_width = width } });
    }

    pub fn fillRRectStates(self: *Canvas, rect: geom.PhysicalRect, radius: f32, base: geom.Color, hover: geom.Color, active: geom.Color) !void {
        try self.list.append(self.gpa, .{ .rrect = .{ .rect = rect, .radius = radius, .color = base, .hover_color = hover, .active_color = active } });
    }

    pub fn strokeRRectStates(self: *Canvas, rect: geom.PhysicalRect, radius: f32, width: f32, base: geom.Color, hover: geom.Color, active: geom.Color) !void {
        try self.list.append(self.gpa, .{ .rrect = .{ .rect = rect, .radius = radius, .color = base, .stroke_width = width, .hover_color = hover, .active_color = active } });
    }

    pub fn drawText(self: *Canvas, run: dl.TextRun) !void {
        try self.list.append(self.gpa, .{ .text = run });
    }

    pub fn pushScroll(self: *Canvas, region: dl.ScrollRegion) !void {
        try self.list.append(self.gpa, .{ .push_scroll = region });
    }

    pub fn popScroll(self: *Canvas) !void {
        try self.list.append(self.gpa, .{ .pop_scroll = {} });
    }

    /// Bound everything drawn until the matching `popClip` to `region`. Every
    /// push needs its pop, or the rest of the frame stays clipped.
    pub fn pushClip(self: *Canvas, region: dl.ClipRegion) !void {
        try self.list.append(self.gpa, .{ .push_clip = region });
    }

    pub fn popClip(self: *Canvas) !void {
        try self.list.append(self.gpa, .{ .pop_clip = {} });
    }

    pub fn drawImage(self: *Canvas, prim: dl.ImagePrimitive) !void {
        try self.list.append(self.gpa, .{ .image = prim });
    }

    pub fn drawIcon(self: *Canvas, prim: dl.IconPrimitive) !void {
        try self.list.append(self.gpa, .{ .icon = prim });
    }
};

test "fillRRect records one primitive" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    try c.fillRRect(geom.PhysicalRect{ .x = 0, .y = 0, .width = 10, .height = 10 }, 4, geom.Color.rgb(0, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), c.list.primitives.items.len);
    try std.testing.expectEqual(@as(f32, 4), c.list.primitives.items[0].rrect.radius);
}

test "pushScroll + fillRRect + popScroll appends 3 primitives in order" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    const vp = geom.PhysicalRect{ .x = 10, .y = 20, .width = 100, .height = 50 };
    const off = geom.PhysicalOffset{ .x = 0, .y = 30 };
    const content = geom.PhysicalSize{ .width = 100, .height = 300 };
    try c.pushScroll(.{ .viewport = vp, .offset = off, .content = content });
    try c.fillRRect(geom.PhysicalRect{ .x = 10, .y = 25, .width = 80, .height = 20 }, 4, geom.Color.rgb(1, 0, 0));
    try c.popScroll();
    try std.testing.expectEqual(@as(usize, 3), c.list.primitives.items.len);
    // first: push_scroll with correct fields
    const sr = c.list.primitives.items[0].push_scroll;
    try std.testing.expectEqual(vp.x, sr.viewport.x);
    try std.testing.expectEqual(vp.y, sr.viewport.y);
    try std.testing.expectEqual(vp.width, sr.viewport.width);
    try std.testing.expectEqual(vp.height, sr.viewport.height);
    try std.testing.expectEqual(off.x, sr.offset.x);
    try std.testing.expectEqual(off.y, sr.offset.y);
    try std.testing.expectEqual(content.width, sr.content.width);
    try std.testing.expectEqual(content.height, sr.content.height);
    // second: rrect
    _ = c.list.primitives.items[1].rrect;
    // third: pop_scroll
    _ = c.list.primitives.items[2].pop_scroll;
}

test "pushClip records the rect and the radius the caller asked for" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    const rect = geom.PhysicalRect{ .x = 4, .y = 8, .width = 60, .height = 30 };
    try c.pushClip(.{ .rect = rect, .radius = 12 });
    try c.fillRRect(rect, 0, geom.Color.rgb(1, 0, 0));
    try c.popClip();

    try std.testing.expectEqual(@as(usize, 3), c.list.primitives.items.len);
    const region = c.list.primitives.items[0].push_clip;
    try std.testing.expectEqual(@as(f32, 4), region.rect.x);
    try std.testing.expectEqual(@as(f32, 60), region.rect.width);
    try std.testing.expectEqual(@as(f32, 12), region.radius);
    _ = c.list.primitives.items[2].pop_clip;
}

test "drawImage appends an image primitive with the given rect and opacity" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    var dummy_image: u8 = 0;
    const rect = geom.PhysicalRect{ .x = 5, .y = 10, .width = 32, .height = 32 };
    try c.drawImage(.{ .image = &dummy_image, .rect = rect, .opacity = 0.5 });
    try std.testing.expectEqual(@as(usize, 1), c.list.primitives.items.len);
    const img = c.list.primitives.items[0].image;
    try std.testing.expectEqual(&dummy_image, @as(*u8, @ptrCast(@alignCast(img.image))));
    try std.testing.expectEqual(rect.x, img.rect.x);
    try std.testing.expectEqual(rect.y, img.rect.y);
    try std.testing.expectEqual(rect.width, img.rect.width);
    try std.testing.expectEqual(rect.height, img.rect.height);
    try std.testing.expectEqual(@as(f32, 0.5), img.opacity);
}

test "drawText records a text primitive carrying glyphs, string and color" {
    var c = Canvas.init(std.testing.allocator);
    defer c.deinit();
    const glyphs = [_]dl.PositionedGlyph{ .{ .cp = 'H', .x = 0, .y = 0 }, .{ .cp = 'i', .x = 12, .y = 0 } };
    var dummy_font: u8 = 0;
    try c.drawText(.{ .glyphs = &glyphs, .text = "Hi", .font = &dummy_font, .size = 16, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 5, .y = 7 } });
    try std.testing.expectEqual(@as(usize, 1), c.list.primitives.items.len);
    const t = c.list.primitives.items[0].text;
    try std.testing.expectEqual(@as(usize, 2), t.glyphs.len);
    try std.testing.expectEqualStrings("Hi", t.text);
    try std.testing.expectEqual(@as(f32, 5), t.origin.x);
    try std.testing.expectEqual(geom.Color.rgb(1, 1, 1), t.color);
}
