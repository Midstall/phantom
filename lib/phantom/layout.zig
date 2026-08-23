const std = @import("std");
const geom = @import("geometry.zig");

pub const BoxConstraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),
    /// DPI scale baked into this constraint pass. Widgets convert their logical
    /// config to physical in layoutFn using this value. Entry points set it to
    /// the real device-pixel ratio (Task 5); 1.0 means identity (no scaling).
    scale: f32 = 1.0,

    pub fn tight(size: geom.PhysicalSize) BoxConstraints {
        return .{
            .min_width = size.width,
            .max_width = size.width,
            .min_height = size.height,
            .max_height = size.height,
        };
    }

    /// Like tight but also sets the DPI scale. Use this at entry points that
    /// know the real device-pixel ratio. Task 5 wires the real DPR here; for
    /// now entry points keep calling tight() (scale = 1.0).
    pub fn tightScaled(size: geom.PhysicalSize, scale: f32) BoxConstraints {
        return .{
            .min_width = size.width,
            .max_width = size.width,
            .min_height = size.height,
            .max_height = size.height,
            .scale = scale,
        };
    }

    pub fn loose(size: geom.PhysicalSize) BoxConstraints {
        return .{ .min_width = 0, .max_width = size.width, .min_height = 0, .max_height = size.height };
    }

    pub fn constrain(self: BoxConstraints, size: geom.PhysicalSize) geom.PhysicalSize {
        return .{
            .width = std.math.clamp(size.width, self.min_width, self.max_width),
            .height = std.math.clamp(size.height, self.min_height, self.max_height),
        };
    }

    pub fn biggest(self: BoxConstraints) geom.PhysicalSize {
        return .{
            .width = if (std.math.isInf(self.max_width)) self.min_width else self.max_width,
            .height = if (std.math.isInf(self.max_height)) self.min_height else self.max_height,
        };
    }

    /// Clamp these constraints so they lie inside `outer`. A render object that
    /// wants a size of its own passes its wish through here first: the parent's
    /// limits win, so a child can never return a size the parent forbade.
    pub fn enforce(self: BoxConstraints, outer: BoxConstraints) BoxConstraints {
        return .{
            .min_width = std.math.clamp(self.min_width, outer.min_width, outer.max_width),
            .max_width = std.math.clamp(self.max_width, outer.min_width, outer.max_width),
            .min_height = std.math.clamp(self.min_height, outer.min_height, outer.max_height),
            .max_height = std.math.clamp(self.max_height, outer.min_height, outer.max_height),
            .scale = outer.scale,
        };
    }

    /// Shrink the constraints by the given physical insets. The scale is
    /// preserved so children see the same DPI factor as the parent.
    pub fn deflate(self: BoxConstraints, insets: geom.PhysicalEdgeInsets) BoxConstraints {
        const h = insets.horizontal();
        const v = insets.vertical();
        return .{
            .min_width = @max(0.0, self.min_width - h),
            .max_width = @max(0.0, self.max_width - h),
            .min_height = @max(0.0, self.min_height - v),
            .max_height = @max(0.0, self.max_height - v),
            .scale = self.scale,
        };
    }
};

test "tight then deflate then constrain flows padding" {
    const c = BoxConstraints.tight(.{ .width = 800, .height = 600 });
    const inner = c.deflate(geom.PhysicalEdgeInsets.all(40));
    try std.testing.expectEqual(@as(f32, 720), inner.max_width);
    try std.testing.expectEqual(@as(f32, 520), inner.max_height);
    const s = inner.constrain(.{ .width = 10000, .height = 10000 });
    try std.testing.expectEqual(@as(f32, 720), s.width);
    try std.testing.expectEqual(@as(f32, 520), s.height);
}

test "biggest uses min on an unbounded axis" {
    const c = BoxConstraints{ .min_width = 5, .max_width = std.math.inf(f32), .min_height = 0, .max_height = 300 };
    try std.testing.expectEqual(@as(f32, 5), c.biggest().width);
    try std.testing.expectEqual(@as(f32, 300), c.biggest().height);
}

test "enforce leaves an inner constraint that already fits" {
    const outer = BoxConstraints.loose(.{ .width = 400, .height = 300 });
    const inner = BoxConstraints.tight(.{ .width = 100, .height = 40 });
    const got = inner.enforce(outer);
    try std.testing.expectEqual(@as(f32, 100), got.min_width);
    try std.testing.expectEqual(@as(f32, 100), got.max_width);
    try std.testing.expectEqual(@as(f32, 40), got.min_height);
    try std.testing.expectEqual(@as(f32, 40), got.max_height);
}

test "enforce clamps an inner constraint down to the outer maximum" {
    const outer = BoxConstraints.loose(.{ .width = 400, .height = 300 });
    const inner = BoxConstraints.tight(.{ .width = 900, .height = 800 });
    const got = inner.enforce(outer);
    try std.testing.expectEqual(@as(f32, 400), got.min_width);
    try std.testing.expectEqual(@as(f32, 400), got.max_width);
    try std.testing.expectEqual(@as(f32, 300), got.min_height);
    try std.testing.expectEqual(@as(f32, 300), got.max_height);
}

test "enforce raises an inner constraint up to the outer minimum" {
    const outer = BoxConstraints.tight(.{ .width = 400, .height = 300 });
    const inner = BoxConstraints.tight(.{ .width = 100, .height = 40 });
    const got = inner.enforce(outer);
    try std.testing.expectEqual(@as(f32, 400), got.min_width);
    try std.testing.expectEqual(@as(f32, 400), got.max_width);
    try std.testing.expectEqual(@as(f32, 300), got.min_height);
    try std.testing.expectEqual(@as(f32, 300), got.max_height);
}

test "enforce takes the scale from the outer constraints" {
    const outer = BoxConstraints.tightScaled(.{ .width = 400, .height = 300 }, 2.0);
    const inner = BoxConstraints.loose(.{ .width = 100, .height = 40 });
    try std.testing.expectEqual(@as(f32, 2.0), inner.enforce(outer).scale);
}

test "tightScaled sets scale and deflate preserves it" {
    const c = BoxConstraints.tightScaled(.{ .width = 200, .height = 200 }, 2.0);
    try std.testing.expectEqual(@as(f32, 2.0), c.scale);
    const inner = c.deflate(geom.PhysicalEdgeInsets.all(20));
    try std.testing.expectEqual(@as(f32, 2.0), inner.scale);
    try std.testing.expectEqual(@as(f32, 160), inner.max_width);
}
