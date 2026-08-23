const std = @import("std");
const phantom = @import("../../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const RenderObject = phantom.RenderObject;
const Canvas = phantom.Canvas;
const geom = phantom.geometry;
const layout = phantom.layout;
const dl = phantom.display_list;
const image_mod = @import("../image/Image.zig");

const RenderImage = struct {
    base: RenderObject,
    gpa: std.mem.Allocator,
    /// Stable heap pointer - Prism texture cache keys on its address.
    img_handle: *image_mod.Image,
    /// Widget's requested logical width (captured at mount/update). Layout uses
    /// these so that ensureDecoded overwriting img_handle.width/height with the
    /// intrinsic decoded dimensions does not collapse the on-screen size.
    logical_w: f32,
    logical_h: f32,

    fn layoutFn(base: *RenderObject, c: layout.BoxConstraints) geom.PhysicalSize {
        const self: *RenderImage = @fieldParentPtr("base", base);
        // Physical size = widget's requested logical size * scale, clamped to constraints.
        // We use logical_w/h (not img_handle.width/height) because ensureDecoded
        // overwrites those with the intrinsic decoded dimensions for the GPU texture.
        const pw = self.logical_w * c.scale;
        const ph = self.logical_h * c.scale;
        return c.constrain(.{ .width = pw, .height = ph });
    }

    fn paintFn(base: *RenderObject, cv: *Canvas, offset: geom.PhysicalOffset) anyerror!void {
        const self: *RenderImage = @fieldParentPtr("base", base);
        try cv.drawImage(.{
            .image = self.img_handle,
            .rect = geom.PhysicalRect.fromOriginSize(offset, base.size),
            .opacity = 1,
        });
    }

    fn destroyFn(base: *RenderObject, gpa: std.mem.Allocator) void {
        const self: *RenderImage = @fieldParentPtr("base", base);
        // Free the decoded rgba buffer (if owned) before freeing the handle struct.
        // NOTE: no Prism texture cache eviction in v1 (images persist for the app
        // lifetime); add a forget-on-destroy when images get created/destroyed dynamically.
        self.img_handle.deinit(gpa);
        gpa.destroy(self.img_handle);
        gpa.destroy(self);
    }
};

/// Image widget: renders an encoded image (PNG, JPEG) at a fixed logical size.
/// On web the browser decodes the image via <img> data URL; on native the GPU
/// texture path is used when RGBA is available (decoder slice 2+). The widget
/// must not crash when rgba is null (native v1 no-op).
pub const Image = struct {
    /// Encoded image bytes (e.g. @embedFile("logo.png")).
    bytes: []const u8,
    /// Logical width in units. Converted to physical via BoxConstraints.scale.
    width: f32,
    /// Logical height in units. Converted to physical via BoxConstraints.scale.
    height: f32,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Image) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *phantom.BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Image = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;

        // Allocate the image handle on the heap so its address is stable
        // (Prism texture cache keys on @intFromPtr(handle)).
        const handle = try gpa.create(image_mod.Image);
        // Free handle if ro or el alloc below fails.
        errdefer gpa.destroy(handle);
        handle.* = image_mod.Image.fromBytes(
            self.bytes,
            @intFromFloat(self.width),
            @intFromFloat(self.height),
        );

        const ro = try gpa.create(RenderImage);
        // Free ro if el alloc below fails. handle's errdefer also fires but that
        // is correct - the two errdefers target different allocations.
        errdefer gpa.destroy(ro);
        ro.* = .{
            .base = .{
                .layoutFn = RenderImage.layoutFn,
                .paintFn = RenderImage.paintFn,
                .destroyFn = RenderImage.destroyFn,
            },
            .gpa = gpa,
            .img_handle = handle,
            .logical_w = self.width,
            .logical_h = self.height,
        };

        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Image),
            .render_object = &ro.base,
            .depth = phantom.widget.depthOf(parent),
        };
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *phantom.BuildContext) anyerror!void {
        _ = bctx;
        const self: *const Image = @ptrCast(@alignCast(ptr));
        const ro: *RenderImage = @fieldParentPtr("base", el.render_object.?);
        // Refresh the widget's requested display size from the new config.
        ro.logical_w = self.width;
        ro.logical_h = self.height;
        // Reset the handle with the new bytes/dimensions in place.
        // This clears any previously decoded rgba (rgba_owned is reset to false here
        // since fromBytes sets rgba=null and rgba_owned=false; the old owned buffer
        // is intentionally NOT freed here because Prism may still hold a cached texture
        // key pointing at the handle. Dynamic image invalidation is a follow-up.
        ro.img_handle.* = image_mod.Image.fromBytes(
            self.bytes,
            @intFromFloat(self.width),
            @intFromFloat(self.height),
        );
    }
};

test "Image mounts, lays out at 32x32, and emits one image primitive" {
    const gpa = std.testing.allocator;
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    // A few PNG-signature bytes - enough for format detection.
    const png_bytes: []const u8 = &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0 };
    var img = Image{ .bytes = png_bytes, .width = 32, .height = 32 };
    const el = try img.widget().mount(&bctx, null);
    defer el.deinit(gpa);

    // Layout at scale 1 -> physical 32x32 clamped to tight 32x32.
    const size = el.render_object.?.layout(layout.BoxConstraints.tight(.{ .width = 32, .height = 32 }));
    try std.testing.expectEqual(@as(f32, 32), size.width);
    try std.testing.expectEqual(@as(f32, 32), size.height);

    var canvas = Canvas.init(gpa);
    defer canvas.deinit();
    try el.render_object.?.paint(&canvas, geom.PhysicalOffset{ .x = 0, .y = 0 });

    // Exactly one image primitive.
    try std.testing.expectEqual(@as(usize, 1), canvas.list.primitives.items.len);
    const prim = canvas.list.primitives.items[0].image;
    try std.testing.expectEqual(@as(f32, 32), prim.rect.width);
    try std.testing.expectEqual(@as(f32, 32), prim.rect.height);
    try std.testing.expectEqual(@as(f32, 1), prim.opacity);

    // The owned handle detected PNG format.
    const handle: *image_mod.Image = @ptrCast(@alignCast(prim.image));
    try std.testing.expectEqual(image_mod.Image.Format.png, handle.format);
}
