const std = @import("std");

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }
    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t, .a = a.a + (b.a - a.a) * t };
    }
};

// Logical/Physical newtypes for DPI-aware unit handling.
// Logical units are widget-facing; Physical units are display-list-facing.
// Call toPhysical(scale) on any Logical type to convert.

pub const PhysicalSize = struct {
    width: f32,
    height: f32,
    pub const zero: PhysicalSize = .{ .width = 0, .height = 0 };
};

pub const LogicalSize = struct {
    width: f32,
    height: f32,
    pub const zero: LogicalSize = .{ .width = 0, .height = 0 };
    pub fn toPhysical(self: LogicalSize, scale: f32) PhysicalSize {
        return .{ .width = self.width * scale, .height = self.height * scale };
    }
};

pub const PhysicalOffset = struct {
    x: f32,
    y: f32,
    pub const zero: PhysicalOffset = .{ .x = 0, .y = 0 };
    pub fn add(a: PhysicalOffset, b: PhysicalOffset) PhysicalOffset {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

pub const LogicalOffset = struct {
    x: f32,
    y: f32,
    pub const zero: LogicalOffset = .{ .x = 0, .y = 0 };
    pub fn add(a: LogicalOffset, b: LogicalOffset) LogicalOffset {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn toPhysical(self: LogicalOffset, scale: f32) PhysicalOffset {
        return .{ .x = self.x * scale, .y = self.y * scale };
    }
};

pub const PhysicalRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    pub fn fromOriginSize(o: PhysicalOffset, s: PhysicalSize) PhysicalRect {
        return .{ .x = o.x, .y = o.y, .width = s.width, .height = s.height };
    }
    pub fn center(self: PhysicalRect) PhysicalOffset {
        return .{ .x = self.x + self.width / 2.0, .y = self.y + self.height / 2.0 };
    }
};

pub const LogicalRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    pub fn fromOriginSize(o: LogicalOffset, s: LogicalSize) LogicalRect {
        return .{ .x = o.x, .y = o.y, .width = s.width, .height = s.height };
    }
    pub fn center(self: LogicalRect) LogicalOffset {
        return .{ .x = self.x + self.width / 2.0, .y = self.y + self.height / 2.0 };
    }
    pub fn toPhysical(self: LogicalRect, scale: f32) PhysicalRect {
        return .{
            .x = self.x * scale,
            .y = self.y * scale,
            .width = self.width * scale,
            .height = self.height * scale,
        };
    }
};

pub const PhysicalEdgeInsets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    pub fn all(v: f32) PhysicalEdgeInsets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }
    pub fn horizontal(self: PhysicalEdgeInsets) f32 {
        return self.left + self.right;
    }
    pub fn vertical(self: PhysicalEdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

pub const LogicalEdgeInsets = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    pub fn all(v: f32) LogicalEdgeInsets {
        return .{ .left = v, .top = v, .right = v, .bottom = v };
    }
    pub fn symmetric(horiz: f32, vert: f32) LogicalEdgeInsets {
        return .{ .left = horiz, .top = vert, .right = horiz, .bottom = vert };
    }
    pub fn horizontal(self: LogicalEdgeInsets) f32 {
        return self.left + self.right;
    }
    pub fn vertical(self: LogicalEdgeInsets) f32 {
        return self.top + self.bottom;
    }
    pub fn toPhysical(self: LogicalEdgeInsets, scale: f32) PhysicalEdgeInsets {
        return .{
            .left = self.left * scale,
            .top = self.top * scale,
            .right = self.right * scale,
            .bottom = self.bottom * scale,
        };
    }
};

test "PhysicalRect.fromOriginSize and center" {
    const r = PhysicalRect.fromOriginSize(.{ .x = 10, .y = 20 }, .{ .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(f32, 60), r.center().x);
    try std.testing.expectEqual(@as(f32, 45), r.center().y);
}

test "LogicalSize.toPhysical scales width and height" {
    const ls = LogicalSize{ .width = 100, .height = 50 };
    const ps = ls.toPhysical(2.0);
    try std.testing.expectEqual(@as(f32, 200), ps.width);
    try std.testing.expectEqual(@as(f32, 100), ps.height);
}

test "LogicalOffset.toPhysical scales x and y" {
    const lo = LogicalOffset{ .x = 10, .y = 20 };
    const po = lo.toPhysical(1.5);
    try std.testing.expectEqual(@as(f32, 15), po.x);
    try std.testing.expectEqual(@as(f32, 30), po.y);
}

test "LogicalRect.fromOriginSize.toPhysical scales all four fields" {
    const off = LogicalOffset{ .x = 4, .y = 6 };
    const sz = LogicalSize{ .width = 20, .height = 10 };
    const lr = LogicalRect.fromOriginSize(off, sz);
    const pr = lr.toPhysical(2.0);
    try std.testing.expectEqual(@as(f32, 8), pr.x);
    try std.testing.expectEqual(@as(f32, 12), pr.y);
    try std.testing.expectEqual(@as(f32, 40), pr.width);
    try std.testing.expectEqual(@as(f32, 20), pr.height);
}

test "LogicalEdgeInsets.all.toPhysical scales all sides" {
    const le = LogicalEdgeInsets.all(8);
    const pe = le.toPhysical(2.0);
    try std.testing.expectEqual(@as(f32, 16), pe.left);
    try std.testing.expectEqual(@as(f32, 16), pe.top);
    try std.testing.expectEqual(@as(f32, 16), pe.right);
    try std.testing.expectEqual(@as(f32, 16), pe.bottom);
}

test "LogicalEdgeInsets horizontal and vertical return logical sums" {
    const le = LogicalEdgeInsets.all(8);
    try std.testing.expectEqual(@as(f32, 16), le.horizontal());
    try std.testing.expectEqual(@as(f32, 16), le.vertical());
}
