const std = @import("std");

test "a rendered red rectangle reaches the mapped pixels" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = PixelSurface.init(gpa, 32, 32) catch |err| switch (err) {
        // createBestDevice returns null only when not even the software driver
        // starts, which should not happen. Fail loudly rather than skipping.
        error.NoPrismDevice => return err,
        else => return err,
    };
    defer s.deinit();

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 0, .y = 0, .width = 32, .height = 32 },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });

    const pixels = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    // The centre pixel is red. The offset is (y * width + x) * 4.
    const off = (16 * 32 + 16) * 4;
    try std.testing.expect(pixels[off] > 200);
    try std.testing.expect(pixels[off + 1] < 60);
}

test "the first frame reports the whole surface as damaged" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = try PixelSurface.init(gpa, 16, 16);
    defer s.deinit();

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);
    const pixels = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    const d = s.damage(pixels).?;
    try std.testing.expectEqual(@as(u32, 0), d.x);
    try std.testing.expectEqual(@as(u32, 0), d.y);
    try std.testing.expectEqual(@as(u32, 16), d.w);
    try std.testing.expectEqual(@as(u32, 16), d.h);
}

test "an unchanged frame reports no damage at all" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = try PixelSurface.init(gpa, 16, 16);
    defer s.deinit();

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);

    const first = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    _ = s.damage(first);
    const second = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    try std.testing.expect(s.damage(second) == null);
}

test "damage covers only the region that changed" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = try PixelSurface.init(gpa, 64, 64);
    defer s.deinit();

    var empty: dl.DisplayList = .{};
    defer empty.deinit(gpa);
    const first = try s.renderFrame(empty, geom.Color.rgb(0, 0, 0));
    _ = s.damage(first);

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{
        .rect = .{ .x = 16, .y = 16, .width = 16, .height = 16 },
        .radius = 0,
        .color = geom.Color.rgb(0, 1, 0),
    } });
    const second = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    const d = s.damage(second).?;

    // The bounding box contains the rectangle and does not cover the whole surface.
    try std.testing.expect(d.x <= 16 and d.y <= 16);
    try std.testing.expect(d.x + d.w >= 32 and d.y + d.h >= 32);
    try std.testing.expect(d.w < 64 or d.h < 64);
}

test "resize gives a surface of the new size and forces full damage" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = try PixelSurface.init(gpa, 16, 16);
    defer s.deinit();

    try s.resize(32, 24);
    try std.testing.expectEqual(@as(u32, 32), s.width);
    try std.testing.expectEqual(@as(u32, 24), s.height);

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);
    const pixels = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    const d = s.damage(pixels).?;
    try std.testing.expectEqual(@as(u32, 32), d.w);
    try std.testing.expectEqual(@as(u32, 24), d.h);
}

test "a zero sized surface renders and reports no pixels, and resizing back up recovers" {
    const gpa = std.testing.allocator;
    try prism_backend.requireRaster(gpa);
    var s = try PixelSurface.init(gpa, 0, 0);
    defer s.deinit();

    var list: dl.DisplayList = .{};
    defer list.deinit(gpa);
    const pixels = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), pixels.len);
    try std.testing.expect(s.damage(pixels) == null);

    try s.resize(8, 8);
    const grown = try s.renderFrame(list, geom.Color.rgb(0, 0, 0));
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), grown.len);
    const d = s.damage(grown).?;
    try std.testing.expectEqual(@as(u32, 8), d.w);
    try std.testing.expectEqual(@as(u32, 8), d.h);
}

// Mode A: the display list renders through the existing prism backend into an
// offscreen image, and the pixels go to the terminal with the kitty graphics
// protocol. There is no second rasterizer. `testing.zig:150` uses the same six
// steps, and this type is that pipeline with the device, target and context kept
// across frames instead of built per call.
const prism = @import("prism");
const dl = @import("../display_list.zig");
const geom = @import("../geometry.zig");
const prism_backend = @import("prism.zig");
const PrismBackend = @import("prism.zig").PrismBackend;

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// The GPU resources `bringUp` produces. Held together so `PixelSurface.init` can
/// discard the whole set on a failed probe without picking it apart field by field.
const Built = struct {
    target: *prism.hal.Resource,
    backend: PrismBackend,
    ctx: prism.Context,
};

/// A `width`x`height` image target never divides by zero: the driver clamps a
/// zero-sized image request internally, but this backend does not depend on that.
/// It requests at least 1x1 so a terminal that briefly reports zero columns mid
/// resize never hands the driver a request nobody has tested.
fn gpuDim(v: u32) u32 {
    return @max(@as(u32, 1), v);
}

/// Create the target, backend and context on `device`, then probe-render one empty
/// frame and read it back. `createBestDevice` returns the first driver whose
/// `createDevice` call SUCCEEDS, and a hardware driver can create successfully
/// while its display is asleep and then fail at render time (`render_failed: gpu`
/// or `OutOfMemory`, seen on this machine). A terminal application often runs with
/// no display at all: over ssh, in tmux, on a headless box. Proving the device can
/// actually produce and read back a frame, once, here, turns that case into a
/// working software fallback instead of a silently blank screen.
fn bringUp(gpa: std.mem.Allocator, device: prism.Device, width: u32, height: u32) !Built {
    const gw = gpuDim(width);
    const gh = gpuDim(height);

    const target = try device.createResource(.{ .image = .{
        .width = gw,
        .height = gh,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
    errdefer device.destroyResource(target);

    var backend = try PrismBackend.init(device, gpa);
    errdefer backend.deinit();
    // The offscreen readback is bottom-origin (row 0 is the bottom of the image,
    // the `glReadPixels` convention) no matter what flip_y is set to: `testing.zig`
    // works around exactly this at its image and text goldens by inverting the row
    // it checks, with flip_y left false there too. Every vertex kind (rect, glyph,
    // icon, image) goes through the same `toClip`, and a glyph or image quad's UV
    // is assigned by frontend corner role before `toClip` runs, not by the vertex's
    // final clip position. So flipping this mapping the same way `app.zig` does for
    // its on-screen surface cancels the buffer's bottom-origin layout for every
    // primitive kind, not just rects, and needs no copy on the read side.
    backend.flip_y = true;

    const ctx = try device.createContext();
    errdefer ctx.deinit();

    var probe: dl.DisplayList = .{};
    defer probe.deinit(gpa);
    const vp = geom.PhysicalSize{ .width = @floatFromInt(gw), .height = @floatFromInt(gh) };
    try backend.render(ctx, target, vp, probe, geom.Color.rgb(0, 0, 0));
    _ = try device.mapResource(target);

    return .{ .target = target, .backend = backend, .ctx = ctx };
}

pub const PixelSurface = struct {
    gpa: std.mem.Allocator,
    device: prism.Device,
    target: *prism.hal.Resource,
    ctx: prism.Context,
    backend: PrismBackend,
    width: u32,
    height: u32,
    /// The pixels of the previous frame, for the damage comparison. Null until the
    /// first frame, which reports the whole surface.
    previous: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !PixelSurface {
        const selected = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
        if (bringUp(gpa, selected.device, width, height)) |built| {
            return .{
                .gpa = gpa,
                .device = selected.device,
                .target = built.target,
                .ctx = built.ctx,
                .backend = built.backend,
                .width = width,
                .height = height,
            };
        } else |_| {
            // The chosen device created but could not render the probe frame. Retire
            // it and force the software rasterizer, which has no display to sleep and
            // is correct whenever it starts at all.
            selected.device.deinit();
            const sw = prism.drivers.select("software") orelse return error.NoPrismDevice;
            const sw_device = try sw.createDevice(gpa);
            errdefer sw_device.deinit();
            const built = try bringUp(gpa, sw_device, width, height);
            return .{
                .gpa = gpa,
                .device = sw_device,
                .target = built.target,
                .ctx = built.ctx,
                .backend = built.backend,
                .width = width,
                .height = height,
            };
        }
    }

    pub fn deinit(self: *PixelSurface) void {
        if (self.previous) |p| self.gpa.free(p);
        self.backend.deinit();
        self.ctx.deinit();
        self.device.destroyResource(self.target);
        self.device.deinit();
        self.* = undefined;
    }

    pub fn resize(self: *PixelSurface, width: u32, height: u32) !void {
        const target = try self.device.createResource(.{ .image = .{
            .width = gpuDim(width),
            .height = gpuDim(height),
            .format = .rgba8_unorm,
            .usage = .{ .render_target = true },
        } });
        // The new target is up before the old one is torn down: if createResource
        // above had failed, `self.target` is still the working one and the surface
        // stays usable.
        self.device.destroyResource(self.target);
        self.target = target;
        self.width = width;
        self.height = height;
        // The old frame describes a different geometry, so it cannot seed a damage
        // comparison and the next frame is fully damaged.
        if (self.previous) |p| self.gpa.free(p);
        self.previous = null;
    }

    /// Forget the previous frame, so the next `damage` call reports the whole
    /// surface. For when something other than this surface has written to the
    /// terminal and what is on screen no longer matches what was last sent.
    ///
    /// This is `resize`'s last step on its own: the two share the reason, which
    /// is that a comparison against a frame the screen no longer shows reports
    /// no damage and so sends nothing at all.
    pub fn invalidate(self: *PixelSurface) void {
        if (self.previous) |p| self.gpa.free(p);
        self.previous = null;
    }

    /// Render one frame and return the mapped pixels, top row first. The slice
    /// belongs to the device and is valid until the next render. A zero width or
    /// height (a terminal can report this mid resize) skips the device entirely and
    /// returns an empty slice: there are no pixels to draw or to ship.
    ///
    /// No row-flip copy happens here: `bringUp` sets `backend.flip_y = true` on
    /// this surface's device specifically so the mapped buffer already comes out
    /// top row first, cancelling the device's own bottom-origin memory layout at
    /// the vertex stage instead of paying a full-frame memcpy every render to fix
    /// it up afterward. On the user's real terminal size that copy would move
    /// tens of megabytes every frame for no reason but row order.
    pub fn renderFrame(self: *PixelSurface, list: dl.DisplayList, bg: geom.Color) ![]const u8 {
        if (self.width == 0 or self.height == 0) return &.{};
        const viewport = geom.PhysicalSize{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        };
        try self.backend.render(self.ctx, self.target, viewport, list, bg);
        return try self.device.mapResource(self.target);
    }

    /// The bounding box of the pixels that changed since the previous frame, or null
    /// when nothing changed.
    ///
    /// One bounding box and not a tile set. A user interface changes in one region
    /// most of the time, so a box is close to the true damage, and a tile set costs
    /// more comparison than it saves in bytes at terminal sizes. Revisit this only
    /// with a measurement that shows the transmission is the bottleneck.
    pub fn damage(self: *PixelSurface, pixels: []const u8) ?Rect {
        if (self.width == 0 or self.height == 0) return null;

        const previous = self.previous orelse {
            self.previous = self.gpa.dupe(u8, pixels) catch return fullRect(self);
            return fullRect(self);
        };
        if (previous.len != pixels.len) {
            self.gpa.free(previous);
            self.previous = self.gpa.dupe(u8, pixels) catch null;
            return fullRect(self);
        }

        var min_x: u32 = self.width;
        var min_y: u32 = self.height;
        var max_x: u32 = 0;
        var max_y: u32 = 0;
        var found = false;

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const row_start = y * self.width * 4;
            const row_len = self.width * 4;
            if (std.mem.eql(u8, previous[row_start..][0..row_len], pixels[row_start..][0..row_len])) continue;
            found = true;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;

            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const off = row_start + x * 4;
                if (std.mem.eql(u8, previous[off..][0..4], pixels[off..][0..4])) continue;
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
            }
        }

        if (!found) return null;
        @memcpy(previous, pixels);
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x + 1, .h = max_y - min_y + 1 };
    }

    fn fullRect(self: *PixelSurface) Rect {
        return .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    /// Copy one rectangle out of the frame into a tight RGBA buffer. The caller frees
    /// it. The kitty protocol needs contiguous rows of exactly the image width.
    pub fn cropRect(self: *PixelSurface, gpa: std.mem.Allocator, pixels: []const u8, r: Rect) ![]u8 {
        const out = try gpa.alloc(u8, r.w * r.h * 4);
        errdefer gpa.free(out);
        var row: u32 = 0;
        while (row < r.h) : (row += 1) {
            const src = ((r.y + row) * self.width + r.x) * 4;
            const dst = row * r.w * 4;
            @memcpy(out[dst..][0 .. r.w * 4], pixels[src..][0 .. r.w * 4]);
        }
        return out;
    }
};
