const std = @import("std");
const builtin = @import("builtin");
const prism = @import("prism");
const hal = prism.hal;
const dl = @import("../display_list.zig");
const geom = @import("../geometry.zig");
const text = @import("../text.zig");
const GlyphAtlas = @import("glyph_atlas.zig");
const image_mod = @import("../image/Image.zig");
const icon_builtin = @import("../icon/builtin.zig");
const icon_stroke = @import("../icon/stroke.zig");
const raster = @import("../text/raster.zig");

const vs_src = @embedFile("../shaders/rrect.vert.glsl");
const fs_src = @embedFile("../shaders/rrect.frag.glsl");
const text_vs_src = @embedFile("../shaders/text.vert.glsl");
const text_fs_src = @embedFile("../shaders/text.frag.glsl");
const image_fs_src = @embedFile("../shaders/image.frag.glsl");

const Vtx = extern struct {
    x: f32,
    y: f32,
    lx: f32,
    ly: f32,
    hx: f32,
    hy: f32,
    r: f32,
    sw: f32,
    cr: f32,
    cg: f32,
    cb: f32,
    ca: f32,
};

/// Text vertex: clip-space position, atlas UV, and per-glyph color.
/// Stride 32 bytes: aPos@0(vec2), aUV@8(vec2), aColor@16(vec4).
const TVtx = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

fn attrFormat(n: u8) hal.Format {
    return switch (n) {
        2 => .r32g32_float,
        4 => .r32g32b32a32_float,
        else => .r32g32b32_float,
    };
}

fn attrOffset(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "aPos")) return 0;
    if (std.mem.eql(u8, name, "aLocal")) return 8;
    if (std.mem.eql(u8, name, "aParams")) return 16;
    return 32; // aColor
}

fn textAttrOffset(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "aPos")) return 0;
    if (std.mem.eql(u8, name, "aUV")) return 8;
    return 16; // aColor
}

// Map a device pixel to clip space. The frontend uses a non-GL, top-left origin
// (py=0 is the top). A GL framebuffer is bottom-left origin, and an offscreen
// image target reads back the same way (the `glReadPixels` convention): there is
// no top-left offscreen case. `flip_y` decides which side cancels the mismatch.
// True flips the mapping here so top-left frontend content lands upright in the
// buffer, which is what `App.run`'s on-screen surface does and what
// `tui_pixels.zig`'s offscreen surface does too. False leaves the mapping
// unflipped and pushes the correction onto the reader instead, which is the path
// `testing.zig` takes: it inverts the row it checks at its image and text
// goldens.
fn toClip(px: f32, py: f32, vp: geom.PhysicalSize, flip_y: bool) [2]f32 {
    const y = if (flip_y) py / vp.height * 2.0 - 1.0 else 1.0 - py / vp.height * 2.0;
    return .{ px / vp.width * 2.0 - 1.0, y };
}

/// Which pipeline consumes a draw, and therefore which vertex array it indexes.
/// `.text` and `.image` share the TVtx array because a glyph quad and an image
/// quad have the same vertex layout.
const DrawKind = enum { rect, text, image };

/// One draw, recorded in display-list order. The frontend paints back to front,
/// so a draw must never be reordered past another: a wallpaper image emitted
/// before a bar has to reach the target before the bar, and a dock icon emitted
/// after its background has to reach it after.
const Draw = struct {
    kind: DrawKind,
    scissor: ?hal.ScissorRect,
    start: u32,
    count: u32,
    /// Bound for an `.image` draw. A `.text` draw binds the glyph atlas instead
    /// and a `.rect` draw samples nothing.
    texture: ?*hal.Resource = null,
};

/// Collects a frame's geometry into two vertex arrays and records the draws that
/// consume them, keeping display-list order. A run of consecutive same-kind
/// primitives becomes ONE draw; the run closes when the kind changes, when the
/// scissor changes, or at an image (which needs its own texture bind).
const Batcher = struct {
    gpa: std.mem.Allocator,
    verts: std.ArrayList(Vtx) = .empty,
    tverts: std.ArrayList(TVtx) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    scissor: ?hal.ScissorRect = null,
    /// The kind of the open run, or null when no run is open. Never `.image`:
    /// an image is recorded immediately by `appendImage`.
    open: ?DrawKind = null,
    open_start: u32 = 0,

    const Error = std.mem.Allocator.Error;

    fn deinit(self: *Batcher) void {
        self.verts.deinit(self.gpa);
        self.tverts.deinit(self.gpa);
        self.draws.deinit(self.gpa);
    }

    /// The current end of the vertex array that `kind` indexes.
    fn mark(self: *const Batcher, kind: DrawKind) u32 {
        return switch (kind) {
            .rect => @intCast(self.verts.items.len),
            .text, .image => @intCast(self.tverts.items.len),
        };
    }

    /// Close the open run, recording a draw when it produced vertices. A run that
    /// produced none (a text run of whitespace only) records nothing.
    fn flush(self: *Batcher) Error!void {
        const kind = self.open orelse return;
        self.open = null;
        const end = self.mark(kind);
        if (end == self.open_start) return;
        try self.draws.append(self.gpa, .{
            .kind = kind,
            .scissor = self.scissor,
            .start = self.open_start,
            .count = end - self.open_start,
        });
    }

    /// Open a run of `kind`, or continue the one already open. The caller appends
    /// its vertices after this returns.
    fn begin(self: *Batcher, kind: DrawKind) Error!void {
        if (self.open) |open| {
            if (open == kind) return;
            try self.flush();
        }
        self.open = kind;
        self.open_start = self.mark(kind);
    }

    /// Record a single image quad as its own draw. Images cannot share a draw
    /// because each one binds a different texture.
    fn appendImage(self: *Batcher, tex: *hal.Resource, quad: [6]TVtx) Error!void {
        try self.flush();
        const start: u32 = @intCast(self.tverts.items.len);
        try self.tverts.appendSlice(self.gpa, &quad);
        try self.draws.append(self.gpa, .{
            .kind = .image,
            .scissor = self.scissor,
            .start = start,
            .count = 6,
            .texture = tex,
        });
    }

    /// Set the scissor for later draws. Closes the open run so draws already
    /// recorded keep the scissor they were built under.
    fn setScissor(self: *Batcher, rect: ?hal.ScissorRect) Error!void {
        try self.flush();
        self.scissor = rect;
    }
};

/// The scissor for `rect` in framebuffer pixels, with `off` (the open scroll
/// offset) taken out, exactly as `appendQuad` takes it out of a rect's vertices.
/// A rectangle wholly off the left or top edge becomes an empty scissor rather
/// than a negative extent.
fn scissorFor(rect: geom.PhysicalRect, off: geom.PhysicalOffset) hal.ScissorRect {
    const x0 = @max(@as(f32, 0), rect.x - off.x);
    const y0 = @max(@as(f32, 0), rect.y - off.y);
    const x1 = @max(x0, rect.x - off.x + rect.width);
    const y1 = @max(y0, rect.y - off.y + rect.height);
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .width = @intFromFloat(x1 - x0),
        .height = @intFromFloat(y1 - y0),
    };
}

/// The overlap of two scissors, or `b` when nothing is clipping yet. A nested
/// clip can only ever narrow its parent, never widen it.
fn intersectScissor(a: ?hal.ScissorRect, b: hal.ScissorRect) hal.ScissorRect {
    const outer = a orelse return b;
    const x0 = @max(outer.x, b.x);
    const y0 = @max(outer.y, b.y);
    const x1 = @min(outer.x + @as(i32, @intCast(outer.width)), b.x + @as(i32, @intCast(b.width)));
    const y1 = @min(outer.y + @as(i32, @intCast(outer.height)), b.y + @as(i32, @intCast(b.height)));
    return .{
        .x = x0,
        .y = y0,
        .width = if (x1 > x0) @intCast(x1 - x0) else 0,
        .height = if (y1 > y0) @intCast(y1 - y0) else 0,
    };
}

fn appendQuad(verts: *std.ArrayList(Vtx), gpa: std.mem.Allocator, r: dl.RRect, vp: geom.PhysicalSize, flip_y: bool, off: geom.PhysicalOffset) !void {
    const hx = r.rect.width / 2.0;
    const hy = r.rect.height / 2.0;
    const cx = r.rect.x + hx - off.x;
    const cy = r.rect.y + hy - off.y;
    const local = [4][2]f32{ .{ -hx, -hy }, .{ hx, -hy }, .{ hx, hy }, .{ -hx, hy } };
    var v: [4]Vtx = undefined;
    for (0..4) |i| {
        const lx = local[i][0];
        const ly = local[i][1];
        const clip = toClip(cx + lx, cy + ly, vp, flip_y);
        v[i] = .{ .x = clip[0], .y = clip[1], .lx = lx, .ly = ly, .hx = hx, .hy = hy, .r = r.radius, .sw = r.stroke_width, .cr = r.color.r, .cg = r.color.g, .cb = r.color.b, .ca = r.color.a };
    }
    const idx = [6]usize{ 0, 1, 2, 0, 2, 3 };
    for (idx) |i| try verts.append(gpa, v[i]);
}

pub const PrismBackend = struct {
    gpa: std.mem.Allocator,
    device: prism.Device,
    vs: *hal.ShaderModule,
    fs: *hal.ShaderModule,
    pipeline: *hal.Pipeline,
    atlas: GlyphAtlas,
    text_vs: *hal.ShaderModule,
    text_fs: *hal.ShaderModule,
    text_pipeline: *hal.Pipeline,
    /// The SPIR-V binding for the atlas sampler. The GLSL compiler assigns the
    /// first sampler2D at binding 2 (bindings 0 and 1 are reserved for UBO blocks).
    text_sampler_binding: u32,
    image_fs: *hal.ShaderModule,
    image_pipeline: *hal.Pipeline,
    image_sampler_binding: u32,
    image_textures: std.AutoHashMapUnmanaged(usize, *hal.Resource) = .empty,
    /// Flip Y in the clip-space transform. A GL framebuffer is bottom-left origin,
    /// the same `glReadPixels` convention whether it is on screen or an offscreen
    /// image target: there is no origin difference between the two to key off of.
    /// True cancels that at draw time, which is what `App.run` does for its
    /// on-screen surface and what `tui_pixels.zig` does for its offscreen one.
    /// False (the default) leaves the buffer bottom-origin and pushes the
    /// correction onto whoever reads it back; `testing.zig` takes that path and
    /// inverts the row it checks at its image and text goldens instead.
    flip_y: bool = false,

    pub fn init(device: prism.Device, gpa: std.mem.Allocator) !PrismBackend {
        var cvs = try prism.glsl.compileForStageWithLayout(gpa, vs_src, .vertex);
        defer cvs.deinit(gpa);
        const fs_spirv = try prism.glsl.compileForStage(gpa, fs_src, .fragment);
        defer gpa.free(fs_spirv);

        const vs = try device.createShaderModule(.{ .stage = .vertex, .code = cvs.spirv });
        errdefer device.destroyShaderModule(vs);
        const fs = try device.createShaderModule(.{ .stage = .fragment, .code = fs_spirv });
        errdefer device.destroyShaderModule(fs);

        var attrs: [8]hal.VertexAttribute = undefined;
        std.debug.assert(cvs.attributes.len <= attrs.len);
        for (cvs.attributes, 0..) |a, i| {
            attrs[i] = .{ .location = a.location, .format = attrFormat(a.components), .offset = attrOffset(a.name) };
        }

        // TODO(target-format): the offscreen/golden path renders into rgba8_unorm, but the
        // window surface (App.run) is created as xrgb8888. Thread the RenderTarget's format
        // in here and match it before trusting run-hello visually (blocked on visual verify,
        // which itself waits on the wayland.zig keymap-fd fix).
        const pipeline = try device.createPipeline(.{
            .vertex = vs,
            .fragment = fs,
            .vertex_layout = .{ .stride = @sizeOf(Vtx), .attributes = attrs[0..cvs.attributes.len] },
            .color_format = .rgba8_unorm,
            .blend = .{
                .enable = true,
                .src_color = .src_alpha,
                .dst_color = .one_minus_src_alpha,
                .src_alpha = .one,
                .dst_alpha = .one_minus_src_alpha,
            },
        });
        errdefer device.destroyPipeline(pipeline);

        // Text pipeline: compile the text vertex shader with layout to recover attribute
        // locations, compile the text fragment shader to get the sampler binding.
        var text_cvs = try prism.glsl.compileForStageWithLayout(gpa, text_vs_src, .vertex);
        defer text_cvs.deinit(gpa);
        var text_cfs = try prism.glsl.compileForStageWithLayout(gpa, text_fs_src, .fragment);
        defer text_cfs.deinit(gpa);

        const text_vs = try device.createShaderModule(.{ .stage = .vertex, .code = text_cvs.spirv });
        errdefer device.destroyShaderModule(text_vs);
        const text_fs = try device.createShaderModule(.{ .stage = .fragment, .code = text_cfs.spirv });
        errdefer device.destroyShaderModule(text_fs);

        var text_attrs: [8]hal.VertexAttribute = undefined;
        std.debug.assert(text_cvs.attributes.len <= text_attrs.len);
        for (text_cvs.attributes, 0..) |a, i| {
            text_attrs[i] = .{ .location = a.location, .format = attrFormat(a.components), .offset = textAttrOffset(a.name) };
        }

        const text_pipeline = try device.createPipeline(.{
            .vertex = text_vs,
            .fragment = text_fs,
            .vertex_layout = .{ .stride = @sizeOf(TVtx), .attributes = text_attrs[0..text_cvs.attributes.len] },
            .color_format = .rgba8_unorm,
            .blend = .{
                .enable = true,
                .src_color = .src_alpha,
                .dst_color = .one_minus_src_alpha,
                .src_alpha = .one,
                .dst_alpha = .one_minus_src_alpha,
            },
        });
        errdefer device.destroyPipeline(text_pipeline);

        // The GLSL compiler assigns the first sampler2D at binding 2 (bindings 0/1
        // are reserved for default UBO blocks). Record it so render() can pass the
        // correct binding to bindTexture.
        const sampler_binding: u32 = if (text_cfs.samplers.len > 0) text_cfs.samplers[0].binding else 2;

        // Image pipeline: reuse the text vertex shader (same TVtx layout / varyings),
        // compile the image fragment shader (samples full RGBA * opacity).
        var image_cfs = try prism.glsl.compileForStageWithLayout(gpa, image_fs_src, .fragment);
        defer image_cfs.deinit(gpa);

        const image_fs = try device.createShaderModule(.{ .stage = .fragment, .code = image_cfs.spirv });
        errdefer device.destroyShaderModule(image_fs);

        const image_pipeline = try device.createPipeline(.{
            .vertex = text_vs,
            .fragment = image_fs,
            .vertex_layout = .{ .stride = @sizeOf(TVtx), .attributes = text_attrs[0..text_cvs.attributes.len] },
            .color_format = .rgba8_unorm,
            .blend = .{
                .enable = true,
                .src_color = .src_alpha,
                .dst_color = .one_minus_src_alpha,
                .src_alpha = .one,
                .dst_alpha = .one_minus_src_alpha,
            },
        });
        errdefer device.destroyPipeline(image_pipeline);

        const image_sampler_binding: u32 = if (image_cfs.samplers.len > 0) image_cfs.samplers[0].binding else 2;

        var atlas = try GlyphAtlas.init(device, gpa);
        errdefer atlas.deinit(gpa);

        return .{
            .gpa = gpa,
            .device = device,
            .vs = vs,
            .fs = fs,
            .pipeline = pipeline,
            .atlas = atlas,
            .text_vs = text_vs,
            .text_fs = text_fs,
            .text_pipeline = text_pipeline,
            .text_sampler_binding = sampler_binding,
            .image_fs = image_fs,
            .image_pipeline = image_pipeline,
            .image_sampler_binding = image_sampler_binding,
        };
    }

    pub fn deinit(self: *PrismBackend) void {
        // Free cached image textures (no eviction in v1; all freed here at shutdown).
        var it = self.image_textures.valueIterator();
        while (it.next()) |tex| {
            self.device.destroyResource(tex.*);
        }
        self.image_textures.deinit(self.gpa);
        self.device.destroyPipeline(self.image_pipeline);
        self.device.destroyShaderModule(self.image_fs);
        self.atlas.deinit(self.gpa);
        self.device.destroyPipeline(self.text_pipeline);
        self.device.destroyShaderModule(self.text_fs);
        self.device.destroyShaderModule(self.text_vs);
        self.device.destroyPipeline(self.pipeline);
        self.device.destroyShaderModule(self.fs);
        self.device.destroyShaderModule(self.vs);
    }

    fn ensureImageTexture(self: *PrismBackend, img: *image_mod.Image) !?*hal.Resource {
        // Decode on demand. On corrupt or unsupported format we soft-skip (return null)
        // rather than propagating an error: a missing image should never crash the frame.
        // PrismBackend has no FaultSink reference in v1, so we skip silently here.
        img.ensureDecoded(self.gpa) catch {
            return null;
        };
        const rgba = img.rgba orelse return null;
        const key = @intFromPtr(img);
        if (self.image_textures.get(key)) |t| return t;
        const tex = try self.device.createResource(.{ .image = .{ .width = img.width, .height = img.height, .format = .rgba8_unorm, .usage = .{ .sampled = true } } });
        errdefer self.device.destroyResource(tex);
        const dst = try self.device.mapResource(tex);
        @memcpy(dst[0 .. img.width * img.height * 4], rgba[0 .. img.width * img.height * 4]);
        try self.image_textures.put(self.gpa, key, tex);
        return tex;
    }

    /// The atlas entry for `id` at `size` device pixels, expanding the centreline
    /// and rasterizing it on a miss. This lives here rather than in GlyphAtlas
    /// because the atlas must not know what an icon path is: it caches coverage,
    /// whatever produced it.
    fn ensureIcon(self: *PrismBackend, id: icon_builtin.Id, size: geom.PhysicalSize) !GlyphAtlas.Entry {
        const key = GlyphAtlas.Key{
            .kind = .icon,
            // Every built-in mark comes from one table, so the id alone separates
            // them and the owner slot stays free for a later per-theme icon set.
            .owner = 0,
            .size_bits = @bitCast(size.width),
            .height_bits = @bitCast(size.height),
            .id = @intFromEnum(id),
        };
        // Check before stroking: a cache hit must not pay for the expansion.
        if (self.atlas.map.get(key)) |cached| return cached;

        var out = try icon_stroke.expand(self.gpa, icon_builtin.pathFor(id));
        defer out.deinit(self.gpa);
        // The path is authored on the icon grid, so that grid is the unit count
        // the rasterizer scales `size` against. Passing it as the advance too
        // makes the entry's advance the box width, which is what an icon
        // occupies in a row of them.
        var cov = try raster.rasterizeScaled(self.gpa, out, icon_builtin.grid_units, size.width, size.height, icon_builtin.grid_units);
        defer cov.deinit(self.gpa);
        return self.atlas.ensureCoverage(self.gpa, key, cov);
    }

    /// Append the two triangles that draw one atlas bitmap, with its top-left at
    /// `x`, `y` in device pixels and tinted by `color`.
    ///
    /// A glyph, an icon and a mark standing in for a missing glyph are the same
    /// thing here: coverage in one atlas, one pipeline, one tint by vertex
    /// colour. The caller works out where the bitmap goes, which is the only
    /// part that differs between them.
    fn appendCoverageQuad(
        self: *PrismBackend,
        batch: *Batcher,
        entry: GlyphAtlas.Entry,
        x: f32,
        y: f32,
        color: geom.Color,
        viewport: geom.PhysicalSize,
    ) !void {
        const w: f32 = @floatFromInt(entry.w);
        const h: f32 = @floatFromInt(entry.h);
        const tl = toClip(x, y, viewport, self.flip_y);
        const tr = toClip(x + w, y, viewport, self.flip_y);
        const br = toClip(x + w, y + h, viewport, self.flip_y);
        const bl = toClip(x, y + h, viewport, self.flip_y);
        const cr = color.r;
        const cg = color.g;
        const cb = color.b;
        const ca = color.a;
        // Two triangles (CCW): TL-TR-BR, TL-BR-BL.
        try batch.tverts.append(self.gpa, .{ .x = tl[0], .y = tl[1], .u = entry.u0, .v = entry.v0, .r = cr, .g = cg, .b = cb, .a = ca });
        try batch.tverts.append(self.gpa, .{ .x = tr[0], .y = tr[1], .u = entry.u1, .v = entry.v0, .r = cr, .g = cg, .b = cb, .a = ca });
        try batch.tverts.append(self.gpa, .{ .x = br[0], .y = br[1], .u = entry.u1, .v = entry.v1, .r = cr, .g = cg, .b = cb, .a = ca });
        try batch.tverts.append(self.gpa, .{ .x = tl[0], .y = tl[1], .u = entry.u0, .v = entry.v0, .r = cr, .g = cg, .b = cb, .a = ca });
        try batch.tverts.append(self.gpa, .{ .x = br[0], .y = br[1], .u = entry.u1, .v = entry.v1, .r = cr, .g = cg, .b = cb, .a = ca });
        try batch.tverts.append(self.gpa, .{ .x = bl[0], .y = bl[1], .u = entry.u0, .v = entry.v1, .r = cr, .g = cg, .b = cb, .a = ca });
    }

    /// Rasterize `list` into `target`. The list is walked ONCE and the draws are
    /// emitted in list order, so a primitive covers everything before it and nothing
    /// after it. Consecutive primitives of one kind still share a single draw.
    pub fn render(self: *PrismBackend, ctx: prism.Context, target: *hal.Resource, viewport: geom.PhysicalSize, list: dl.DisplayList, bg: geom.Color) !void {
        var batch = Batcher{ .gpa = self.gpa };
        defer batch.deinit();

        var cur_off = geom.PhysicalOffset.zero;
        // The scissor each open clip inherited, so a pop restores exactly what
        // was in force before its push rather than clearing the scissor outright.
        var clip_stack: std.ArrayList(?hal.ScissorRect) = .empty;
        defer clip_stack.deinit(self.gpa);
        for (list.primitives.items) |p| switch (p) {
            .push_clip => |cr| {
                try clip_stack.append(self.gpa, batch.scissor);
                // The radius is dropped: a rounded scissor needs a clip term in
                // every fragment shader, and this pass has none. The bounding
                // rectangle still cuts a child at the boundary.
                try batch.setScissor(intersectScissor(batch.scissor, scissorFor(cr.rect, cur_off)));
            },
            .pop_clip => {
                // A pop with no push is a malformed display list, a runtime fault
                // and not a programmer error, so it falls back to no scissor.
                try batch.setScissor(clip_stack.pop() orelse null);
            },
            .push_scroll => |sr| {
                // A region that covers the whole framebuffer clips nothing, so skip the
                // scissor for it (the framebuffer already bounds the draw). This both is
                // a no-op-scissor optimization AND keeps a full-window ScrollView (the
                // common case) off the driver's scissor path entirely. Only a partial
                // region (smaller than the framebuffer) gets a real scissor rect.
                const full = sr.viewport.x <= 0 and sr.viewport.y <= 0 and
                    sr.viewport.x + sr.viewport.width >= viewport.width and
                    sr.viewport.y + sr.viewport.height >= viewport.height;
                try batch.setScissor(if (full) null else .{
                    .x = @intFromFloat(@max(@as(f32, 0), sr.viewport.x)),
                    .y = @intFromFloat(@max(@as(f32, 0), sr.viewport.y)),
                    .width = @intFromFloat(sr.viewport.width),
                    .height = @intFromFloat(sr.viewport.height),
                });
                cur_off = sr.offset;
            },
            .pop_scroll => {
                try batch.setScissor(null);
                cur_off = geom.PhysicalOffset.zero;
            },
            .rrect => |r| {
                try batch.begin(.rect);
                try appendQuad(&batch.verts, self.gpa, r, viewport, self.flip_y, cur_off);
            },
            .image => |img_prim| {
                const img: *image_mod.Image = @ptrCast(@alignCast(img_prim.image));
                const tex = try self.ensureImageTexture(img) orelse continue;

                // Bake the scroll offset in, exactly as appendQuad does for a rect: a
                // ScrollView paints its child at the unscrolled offset and leaves the
                // scroll to the backend, so an image inside the region needs the same
                // shift a rect gets.
                const r = img_prim.rect;
                const x0 = r.x - cur_off.x;
                const y0 = r.y - cur_off.y;
                const x1 = x0 + r.width;
                const y1 = y0 + r.height;
                const tl = toClip(x0, y0, viewport, self.flip_y);
                const tr = toClip(x1, y0, viewport, self.flip_y);
                const br = toClip(x1, y1, viewport, self.flip_y);
                const bl = toClip(x0, y1, viewport, self.flip_y);
                const op = img_prim.opacity;
                // Two CCW triangles: TL-TR-BR, TL-BR-BL. The image texture is uploaded
                // row 0 first, so v=0 selects rgba row 0. V therefore grows downward with
                // the frontend's top-left screen origin: the top of the quad gets v=0 and
                // the bottom gets v=1. This matches the glyph atlas, which puts its v0
                // (the smaller V) at the top of each glyph quad. An inverted V here made
                // every image render upside down on the window surface.
                try batch.appendImage(tex, .{
                    .{ .x = tl[0], .y = tl[1], .u = 0, .v = 0, .r = 1, .g = 1, .b = 1, .a = op },
                    .{ .x = tr[0], .y = tr[1], .u = 1, .v = 0, .r = 1, .g = 1, .b = 1, .a = op },
                    .{ .x = br[0], .y = br[1], .u = 1, .v = 1, .r = 1, .g = 1, .b = 1, .a = op },
                    .{ .x = tl[0], .y = tl[1], .u = 0, .v = 0, .r = 1, .g = 1, .b = 1, .a = op },
                    .{ .x = br[0], .y = br[1], .u = 1, .v = 1, .r = 1, .g = 1, .b = 1, .a = op },
                    .{ .x = bl[0], .y = bl[1], .u = 0, .v = 1, .r = 1, .g = 1, .b = 1, .a = op },
                });
            },
            .text => |run| {
                try batch.begin(.text);
                // Cast the type-erased font pointer back to the concrete type.
                const font: *text.Font = @ptrCast(@alignCast(run.font));
                for (run.glyphs) |g| {
                    // A face with no glyph for this codepoint draws `.notdef`,
                    // which is a replacement box. The bundled faces are display
                    // faces and cover little outside ASCII, so an interface that
                    // writes a tick or a chevron in ordinary text gets boxes here
                    // while a terminal, drawing with its own font, gets the real
                    // character. Standing a built-in mark in its place closes
                    // that split: the two backends show the same thing, and the
                    // caller writes the character it means.
                    //
                    // The mark goes in a square box the size of the text, resting
                    // on the baseline. Every built-in is drawn inside a margin on
                    // a centred grid, so that lands a tick at about cap height
                    // and the midline dots of an ellipsis at about half of it,
                    // which is where each belongs beside text. Layout already
                    // reserved this codepoint's advance, so the mark drops into
                    // the space the box would have taken and nothing shifts.
                    if (!font.hasGlyph(g.cp)) {
                        if (icon_builtin.iconForCodepoint(g.cp)) |id| {
                            const side = run.size;
                            const entry = try self.ensureIcon(id, .{ .width = side, .height = side });
                            if (entry.w == 0 or entry.h == 0) continue;
                            const baseline = run.origin.y + run.ascent + g.y;
                            // The icon arm below places a bitmap at
                            // `box_top + box_height + entry.top`. With the box
                            // bottom on the baseline that is
                            // `(baseline - side) + side + entry.top`, so the
                            // side cancels and the baseline carries it.
                            try self.appendCoverageQuad(
                                &batch,
                                entry,
                                run.origin.x + g.x + @as(f32, @floatFromInt(entry.left)) - cur_off.x,
                                baseline + @as(f32, @floatFromInt(entry.top)) - cur_off.y,
                                run.color,
                                viewport,
                            );
                            continue;
                        }
                    }
                    const entry = try self.atlas.ensure(self.gpa, font, run.size, g.cp);
                    // Skip zero-size glyphs (whitespace, missing).
                    if (entry.w == 0 or entry.h == 0) continue;
                    // Compute the device-pixel quad for this glyph bitmap.
                    // The glyph bitmap's top-left in device pixels:
                    //   x = run.origin.x + g.x + entry.left  (left bearing in device px)
                    //   y = run.origin.y + g.y + entry.top   (top is negative above baseline
                    //       in the phantom rasterizer: min_y after Y-flip, so adding it
                    //       moves the quad up toward the cap height)
                    // Glyph x/y are baseline-relative; the baseline sits at
                    // origin.y + ascent (origin is the run's top-left).
                    const gx: f32 = run.origin.x + g.x + @as(f32, @floatFromInt(entry.left)) - cur_off.x;
                    const gy: f32 = run.origin.y + run.ascent + g.y + @as(f32, @floatFromInt(entry.top)) - cur_off.y;
                    try self.appendCoverageQuad(&batch, entry, gx, gy, run.color, viewport);
                }
            },
            .icon => |ic| {
                // An icon quad is a glyph quad: coverage in the same atlas, the
                // same pipeline, the same tint by vertex color. So it joins the
                // open text run rather than opening a pass of its own, which
                // would reorder it past everything else in the list.
                try batch.begin(.text);
                const entry = try self.ensureIcon(ic.id, ic.size);
                if (entry.w == 0 or entry.h == 0) continue;
                // entry.left/top are the bitmap's top-left in device space, where
                // the icon grid's own top-left is (0, -height): the rasterizer
                // flips y, so the grid's top edge lands at minus the box height.
                // Adding it back turns the offset into one measured down from the
                // primitive's origin.
                const ix: f32 = ic.origin.x + @as(f32, @floatFromInt(entry.left)) - cur_off.x;
                const iy: f32 = ic.origin.y + ic.size.height + @as(f32, @floatFromInt(entry.top)) - cur_off.y;
                try self.appendCoverageQuad(&batch, entry, ix, iy, ic.color, viewport);
            },
        };
        try batch.flush();

        // A fresh vertex buffer per frame, destroyed after submit below. This assumes
        // submit is synchronous (the driver consumes/copies the vertices before returning),
        // which holds for the software golden path and the current window path. TODO: when
        // the north-star app pipelines frames, hold a persistent/growable vbuf instead.
        var vbuf: ?*hal.Resource = null;
        defer if (vbuf) |b| self.device.destroyResource(b);
        if (batch.verts.items.len > 0) {
            const bytes = std.mem.sliceAsBytes(batch.verts.items);
            const b = try self.device.createResource(.{ .buffer = .{ .size = bytes.len, .usage = .{ .vertex = true } } });
            vbuf = b;
            @memcpy(try self.device.mapResource(b), bytes);
        }

        // Glyph quads and image quads share this buffer: both are TVtx, and the image
        // pipeline is built on the text vertex shader, so one buffer serves both and an
        // image costs no extra resource per frame.
        var tvbuf: ?*hal.Resource = null;
        defer if (tvbuf) |b| self.device.destroyResource(b);
        if (batch.tverts.items.len > 0) {
            const bytes = std.mem.sliceAsBytes(batch.tverts.items);
            const b = try self.device.createResource(.{ .buffer = .{ .size = bytes.len, .usage = .{ .vertex = true } } });
            tvbuf = b;
            @memcpy(try self.device.mapResource(b), bytes);
        }

        const cb = try ctx.beginCommands();
        defer cb.deinit();
        try cb.setRenderTarget(target);
        try cb.clear(.{ .r = bg.r, .g = bg.g, .b = bg.b, .a = bg.a });

        // Only touch the scissor when SOME draw actually needs a sub-framebuffer clip.
        // If nothing needs clipping (no regions, or every region covers the whole
        // framebuffer), no setScissor is issued at all: the per-region -offset is already
        // baked into the vertices, so non-scroll and full-window-scroll apps stay entirely
        // off the driver's scissor path.
        var any_scissor = false;
        for (batch.draws.items) |d| {
            if (d.scissor != null) {
                any_scissor = true;
                break;
            }
        }

        // The command stream keeps pipeline, texture and vertex-buffer state between
        // draws, so re-bind only when one of them changes. Two draws split apart purely
        // by a scissor change then cost one extra command, not four.
        var bound_pipeline: ?*hal.Pipeline = null;
        var bound_texture: ?*hal.Resource = null;
        var bound_vbuf: ?*hal.Resource = null;
        var bound_scissor: ?hal.ScissorRect = null;
        var scissor_bound = false;
        for (batch.draws.items) |d| {
            if (any_scissor and (!scissor_bound or !std.meta.eql(bound_scissor, d.scissor))) {
                try cb.setScissor(d.scissor);
                bound_scissor = d.scissor;
                scissor_bound = true;
            }
            const pipeline = switch (d.kind) {
                .rect => self.pipeline,
                .text => self.text_pipeline,
                .image => self.image_pipeline,
            };
            const texture: ?*hal.Resource = switch (d.kind) {
                .rect => null,
                .text => self.atlas.image,
                .image => d.texture,
            };
            // A draw exists only when its kind appended vertices, so the buffer it
            // indexes was created above.
            const buffer = switch (d.kind) {
                .rect => vbuf.?,
                .text, .image => tvbuf.?,
            };
            if (bound_pipeline != pipeline or bound_texture != texture or bound_vbuf != buffer) {
                try cb.bindPipeline(pipeline);
                switch (d.kind) {
                    .rect => {},
                    // The atlas holds coverage in R; the swizzle broadcasts it into alpha.
                    .text => try cb.bindTexture(.{
                        .binding = self.text_sampler_binding,
                        .image = self.atlas.image,
                        .filter = .linear,
                        .swizzle = .{ .one, .one, .one, .r },
                    }),
                    .image => try cb.bindTexture(.{
                        .binding = self.image_sampler_binding,
                        .image = texture.?,
                        .filter = .linear,
                    }),
                }
                try cb.bindVertexBuffer(buffer);
                bound_pipeline = pipeline;
                bound_texture = texture;
                bound_vbuf = buffer;
            }
            try cb.draw(d.count, d.start);
        }
        if (any_scissor) try cb.setScissor(null);

        try ctx.submit(cb);
    }
};

/// Whether prism's compiled-in driver set BUILDS for this target. Not a claim
/// about hardware, and not a claim about what any machine can draw.
///
/// The list is measured, not assumed, and it was measured twice.
///
/// `-Dtarget=aarch64-macos` builds clean with this forced open, prism and
/// lattice both, so DARWIN IS FINE. That is what retired the `os.tag == .linux`
/// this used to be: that form switched off a renderer which works on macOS, and
/// it read as "is there a GPU" when prism ships a CPU rasterizer that wants no
/// GPU anywhere.
///
/// `-Dtarget=x86_64-windows` fails with the default driver set inside prism's
/// NVIDIA driver (`nvidia/transport/linux.zig`), which looked like the whole
/// story: pick `software` alone and Windows would build. It does not. With
/// `-Dgpu-drivers=software` the NVIDIA errors go away and the build then fails
/// inside vulcan, at `vulcan-target/jit_platform.zig`, which has no Windows
/// platform for prism's shader JIT to sit on. So no driver selection reaches a
/// Windows build today and the exception is real rather than a configuration
/// mistake. Not one of these errors is phantom's.
///
/// The way out is in code phantom does not own: a Windows platform in vulcan's
/// JIT. That retires this constant, and nothing in phantom has to change for it.
pub const builds_here = builtin.os.tag != .windows;

/// Whether a device on this machine can actually draw, not merely start.
///
/// `createBestDevice` returns the first driver whose `createDevice` SUCCEEDS,
/// and success there says nothing about whether geometry reaches the target.
/// prism's `software` driver currently clears the background correctly and then
/// draws no primitives at all, so a frame comes back the colour it was cleared
/// to with nothing on it. That is the only driver available in a build sandbox
/// or on a machine with no GPU, which is where this matters.
///
/// So this asks the question that counts: draw one opaque rectangle over a
/// contrasting background and read the centre pixel back. Anything other than
/// the rectangle's own colour, including an error anywhere along the way, means
/// this environment cannot rasterize.
///
/// Cached, because the answer cannot change while the process runs and the probe
/// costs a device bring-up. The cache is a file-level global, which this project
/// otherwise avoids: it is justified here because the thing being cached is a
/// property of the MACHINE rather than of any instance, and two callers asking
/// about the same machine must get the same answer.
var raster_probe: ?bool = null;

pub fn canRasterize(gpa: std.mem.Allocator) bool {
    if (raster_probe) |known| return known;
    const answer = probeRaster(gpa) catch false;
    raster_probe = answer;
    return answer;
}

fn probeRaster(gpa: std.mem.Allocator) !bool {
    const sel = prism.drivers.createBestDevice(gpa) orelse return false;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const size: u32 = 8;
    const target = try dev.createResource(.{ .image = .{
        .width = size,
        .height = size,
        .format = .rgba8_unorm,
        .usage = .{ .render_target = true },
    } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // Red over blue, covering the whole target. The two differ in every channel
    // that is checked, so a cleared-but-undrawn frame cannot be mistaken for a
    // drawn one whichever way the driver orders its components.
    try list.append(gpa, .{ .rrect = .{
        .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = @floatFromInt(size), .height = @floatFromInt(size) },
        .radius = 0,
        .color = geom.Color.rgb(1, 0, 0),
    } });
    try backend.render(
        ctx,
        target,
        geom.PhysicalSize{ .width = @floatFromInt(size), .height = @floatFromInt(size) },
        list,
        geom.Color.rgb(0, 0, 1),
    );

    const px = try dev.mapResource(target);
    const centre = (size / 2 * size + size / 2) * 4;
    if (centre + 2 >= px.len) return false;
    return px[centre] > 200 and px[centre + 2] < 80;
}

/// Skip the calling test when this machine cannot rasterize. See `canRasterize`.
///
/// A skip and not a failure: a test that asserts on rendered pixels is asking a
/// question about phantom, and on a machine whose only driver draws nothing
/// there is no answer to give. Reporting that as a phantom defect would be
/// false, and it would train a reader to ignore these tests everywhere they
/// cannot run.
pub fn requireRaster(gpa: std.mem.Allocator) !void {
    if (!canRasterize(gpa)) return error.SkipZigTest;
}

test "rounded rect leaves its corner as background" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // 48x48 box at (8,8) with radius 24: its top-left corner pixel is outside the shape.
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 8, .y = 8, .width = 48, .height = 48 }, .radius = 24, .color = geom.Color.rgb(0, 0, 1) } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0.1, 0.1, 0.1));

    const px = try dev.mapResource(target);
    const center = (H / 2 * W + W / 2) * 4;
    try std.testing.expect(px[center + 2] > 200); // center still blue
    const corner = (9 * W + 9) * 4; // just inside the box's bounding corner, outside the round
    try std.testing.expect(px[corner + 2] < 80); // background, not blue
}

test "PrismBackend draws a solid rect; center pixel reads blue" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 8, .y = 8, .width = 48, .height = 48 }, .radius = 0, .color = geom.Color.rgb(0, 0, 1) } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0.1, 0.1, 0.1));

    const px = try dev.mapResource(target);
    const off = (H / 2 * W + W / 2) * 4;
    try std.testing.expect(px[off + 2] > 200); // blue high
    try std.testing.expect(px[off + 0] < 60); // red low
}

test "PrismBackend renders a TextRun; glyph pixels appear on the target" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;
    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);
    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();
    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // One glyph 'A' at a visible position, white.
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = 'A', .x = 0, .y = 40 }};
    try list.append(gpa, .{ .text = .{ .glyphs = &glyphs, .text = "A", .font = &font, .size = 48, .color = geom.Color.rgb(1, 1, 1), .origin = geom.PhysicalOffset{ .x = 8, .y = 8 } } });
    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));
    const px = try dev.mapResource(target);
    var lit: u32 = 0;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        if (px[i] > 40) lit += 1;
    }
    try std.testing.expect(lit > 10); // the glyph drew some lit pixels
}

test "PrismBackend draws an icon primitive tinted, with the gap between its pillars left clear" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;
    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // 48 px across the 24 unit grid, so one grid unit is two device pixels and
    // a grid coordinate g lands at 8 + g * 2 across, 8 + (24 - g) * 2 down.
    try list.append(gpa, .{ .icon = .{
        .id = .torii,
        .size = .{ .width = 48, .height = 48 },
        .color = geom.Color.rgb(1, 0, 0),
        .origin = geom.PhysicalOffset{ .x = 8, .y = 8 },
    } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));

    const px = try dev.mapResource(target);
    // Inside the left pillar: grid (6.72, 8.5). Red, not white, so the coverage
    // is tinted by the primitive's colour rather than blitted as it is.
    const pillar = (39 * W + 21) * 4;
    try std.testing.expect(px[pillar + 0] > 120);
    try std.testing.expect(px[pillar + 1] < 60 and px[pillar + 2] < 60);
    // The gap between the pillars at the same height: grid (12, 8.5). Still the
    // background. A quad that drew the whole atlas, or one placed without the
    // rasterizer's y flip, covers this pixel.
    const gap = (39 * W + 32) * 4;
    try std.testing.expect(px[gap + 0] < 60);
}

// ---------------------------------------------------------------------------
// Display-list ordering
//
// The renderer used to walk the list twice: rrects and text first, images after.
// Every image therefore covered every rect and glyph regardless of where it sat
// in the list, which hid a top bar behind a wallpaper. The three tests below pin
// both directions of the fix, because a renderer that draws images FIRST fixes
// the wallpaper and breaks a dock icon over its background.
//
// Every rect and image below is centred on the 64x64 target so the offscreen
// readback's vertical inversion (flip_y stays false here) cannot move a sampled
// point out of the region it is meant to test. Image textures are solid colors,
// so linear filtering cannot change the sampled value either.
// ---------------------------------------------------------------------------

/// A 2x2 solid opaque texture in the layout Image.fromRgba borrows.
fn solidRgba(r: u8, g: u8, b: u8) [16]u8 {
    return [_]u8{ r, g, b, 0xFF } ** 4;
}

test "an image listed before a rect draws behind it: the rect's pixels win" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    const red_px = solidRgba(0xFF, 0x00, 0x00);
    var red = image_mod.fromRgba(&red_px, 2, 2);

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // Wallpaper shape: a full-target image, then an opaque blue rect over its middle.
    try list.append(gpa, .{ .image = .{ .image = &red, .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 64, .height = 64 }, .opacity = 1 } });
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 16, .y = 16, .width = 32, .height = 32 }, .radius = 0, .color = geom.Color.rgb(0, 0, 1) } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));

    const px = try dev.mapResource(target);
    // Inside the rect: blue, not the image's red. This is the pixel the old
    // image-last pass got wrong.
    const inside = (32 * W + 32) * 4;
    try std.testing.expect(px[inside + 2] > 200);
    try std.testing.expect(px[inside + 0] < 60);
    // Outside the rect: still red, which proves the image drew rather than being dropped.
    const outside = (32 * W + 4) * 4;
    try std.testing.expect(px[outside + 0] > 200);
    try std.testing.expect(px[outside + 2] < 60);
}

test "an image listed after a rect draws in front of it: the image's pixels win" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    const red_px = solidRgba(0xFF, 0x00, 0x00);
    var red = image_mod.fromRgba(&red_px, 2, 2);

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // Dock shape: an opaque blue background rect, then an icon image on top of it.
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 64, .height = 64 }, .radius = 0, .color = geom.Color.rgb(0, 0, 1) } });
    try list.append(gpa, .{ .image = .{ .image = &red, .rect = geom.PhysicalRect{ .x = 16, .y = 16, .width = 32, .height = 32 }, .opacity = 1 } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));

    const px = try dev.mapResource(target);
    // Inside the image: red, not the rect's blue. An over-correction that drew every
    // image first would read blue here.
    const inside = (32 * W + 32) * 4;
    try std.testing.expect(px[inside + 0] > 200);
    try std.testing.expect(px[inside + 2] < 60);
    // Outside the image: the rect.
    const outside = (32 * W + 4) * 4;
    try std.testing.expect(px[outside + 2] > 200);
    try std.testing.expect(px[outside + 0] < 60);
}

test "two images and two rects interleaved stack in list order: the last one covers" {
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();

    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    const red_px = solidRgba(0xFF, 0x00, 0x00);
    var red = image_mod.fromRgba(&red_px, 2, 2);
    const white_px = solidRgba(0xFF, 0xFF, 0xFF);
    var white = image_mod.fromRgba(&white_px, 2, 2);

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    // Four layers, smallest last: blue rect, red image, green rect, white image.
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 64, .height = 64 }, .radius = 0, .color = geom.Color.rgb(0, 0, 1) } });
    try list.append(gpa, .{ .image = .{ .image = &red, .rect = geom.PhysicalRect{ .x = 0, .y = 0, .width = 64, .height = 64 }, .opacity = 1 } });
    try list.append(gpa, .{ .rrect = .{ .rect = geom.PhysicalRect{ .x = 8, .y = 8, .width = 48, .height = 48 }, .radius = 0, .color = geom.Color.rgb(0, 1, 0) } });
    try list.append(gpa, .{ .image = .{ .image = &white, .rect = geom.PhysicalRect{ .x = 20, .y = 20, .width = 24, .height = 24 }, .opacity = 1 } });

    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));

    const px = try dev.mapResource(target);
    // Centre: the last layer, the white image.
    const top = (32 * W + 32) * 4;
    try std.testing.expect(px[top + 0] > 200 and px[top + 1] > 200 and px[top + 2] > 200);
    // Inside the green rect but outside the white image: green. A rect batched ahead of
    // the red image would leave red here.
    const mid = (32 * W + 14) * 4;
    try std.testing.expect(px[mid + 1] > 200);
    try std.testing.expect(px[mid + 0] < 60 and px[mid + 2] < 60);
    // Outside the green rect: the red image, which covers the blue rect under it.
    const bottom = (32 * W + 3) * 4;
    try std.testing.expect(px[bottom + 0] > 200);
    try std.testing.expect(px[bottom + 1] < 60 and px[bottom + 2] < 60);
}

test "a rule stretched to its box inks the full height, where a square one leaves a gap" {
    // The rail down the edge of a transcript: one mark per row, each as tall as
    // its row. A square mark in a box one column wide is only as tall as it is
    // wide, so consecutive rows draw a dashed line with blank between them.
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    const dev = sel.device;

    const W: u32 = 64;
    const H: u32 = 64;

    // A box 16 across and 48 down at (8, 8), so the rule's centreline at grid
    // x 12 lands 8 pixels in, and a filled rule covers y 8 through 56.
    const box = geom.PhysicalSize{ .width = 16, .height = 48 };
    const square = geom.PhysicalSize{ .width = 16, .height = 16 };

    for ([_]struct { size: geom.PhysicalSize, tall: bool }{
        .{ .size = box, .tall = true },
        .{ .size = square, .tall = false },
    }) |case| {
        var backend = try PrismBackend.init(dev, gpa);
        defer backend.deinit();
        const ctx = try dev.createContext();
        defer ctx.deinit();
        const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
        defer dev.destroyResource(target);

        var list = dl.DisplayList{};
        defer list.deinit(gpa);
        try list.append(gpa, .{ .icon = .{
            .id = .rule_vertical,
            .size = case.size,
            .color = geom.Color.rgb(1, 0, 0),
            .origin = geom.PhysicalOffset{ .x = 8, .y = 8 },
        } });
        try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));

        const px = try dev.mapResource(target);

        // Measure the run of inked rows in the column the rule draws in. Where
        // that run sits is not the point and would only pin this harness's y
        // flip (see the torii test above); how long it is, and whether it has a
        // hole in it, is the whole of the bug.
        var first: ?u32 = null;
        var last: u32 = 0;
        var inked: u32 = 0;
        for (0..H) |yy| {
            const y: u32 = @intCast(yy);
            if (px[(y * W + 16) * 4] > 60) {
                if (first == null) first = y;
                last = y;
                inked += 1;
            }
        }
        try std.testing.expect(first != null);
        const span = last - first.? + 1;
        // Continuous, with no row skipped between the two ends. A rail is one
        // line, and a rule that reached its ends through a gap would still draw
        // the dashes this test is about.
        try std.testing.expectEqual(span, inked);

        if (case.tall) {
            // The box is 48 down, and the mark has to cover it.
            try std.testing.expect(span >= 44);
        } else {
            // The square mark is only as tall as the box is wide, which is the
            // 16 that left 32 rows of the row blank.
            try std.testing.expect(span <= 20);
        }
    }
}

test "the atlas keeps one mark at two heights apart" {
    // The key carried only a width once. Two rules of different heights then
    // shared a slot, and whichever rasterised first was drawn for both, which
    // is a rail that changes length when a row above it resizes.
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var backend = try PrismBackend.init(sel.device, gpa);
    defer backend.deinit();

    const short = try backend.ensureIcon(.rule_vertical, .{ .width = 16, .height = 16 });
    const tall = try backend.ensureIcon(.rule_vertical, .{ .width = 16, .height = 48 });
    try std.testing.expect(tall.h > short.h);
    // And a repeat of the first is still the first: the height must separate the
    // two without breaking the cache for a mark that has not changed.
    const again = try backend.ensureIcon(.rule_vertical, .{ .width = 16, .height = 16 });
    try std.testing.expectEqual(short.h, again.h);
    try std.testing.expectEqual(short.u0, again.u0);
}

/// Render one codepoint as a text run and give back the target's pixels, for the
/// fallback tests below. The caller frees the returned slice.
fn renderOneCodepoint(gpa: std.mem.Allocator, dev: prism.Device, font: *text.Font, cp: u21) ![]u8 {
    var backend = try PrismBackend.init(dev, gpa);
    defer backend.deinit();
    const W: u32 = 64;
    const H: u32 = 64;
    const target = try dev.createResource(.{ .image = .{ .width = W, .height = H, .format = .rgba8_unorm, .usage = .{ .render_target = true } } });
    defer dev.destroyResource(target);
    const ctx = try dev.createContext();
    defer ctx.deinit();

    var list = dl.DisplayList{};
    defer list.deinit(gpa);
    const glyphs = [_]dl.PositionedGlyph{.{ .cp = cp, .x = 0, .y = 0 }};
    try list.append(gpa, .{ .text = .{
        .glyphs = &glyphs,
        .text = "",
        .font = font,
        .size = 32,
        .color = geom.Color.rgb(1, 1, 1),
        .origin = geom.PhysicalOffset{ .x = 8, .y = 8 },
        .ascent = 40,
    } });
    try backend.render(ctx, target, geom.PhysicalSize{ .width = 64, .height = 64 }, list, geom.Color.rgb(0, 0, 0));
    return gpa.dupe(u8, try dev.mapResource(target));
}

test "a codepoint the face cannot draw becomes its built-in mark" {
    // The bundled faces are display faces with almost nothing outside ASCII, so
    // a tick or a chevron written in ordinary text came out as the replacement
    // box glyph 0 draws, while a terminal showed the real character from its own
    // font. The two backends have to agree.
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    // The premise: neither of these is in the face. If one ever is, this test is
    // measuring something else and says so rather than passing quietly.
    try std.testing.expect(!font.hasGlyph('\u{25B8}'));
    try std.testing.expect(!font.hasGlyph('\u{2603}'));

    // U+25B8 has a mark; U+2603, a snowman, does not and keeps the box.
    const marked = try renderOneCodepoint(gpa, sel.device, &font, '\u{25B8}');
    defer gpa.free(marked);
    const unmarked = try renderOneCodepoint(gpa, sel.device, &font, '\u{2603}');
    defer gpa.free(unmarked);

    // Both are glyph 0 to the face, so without the substitution these are the
    // same pixels. That is the whole of the bug, and this is what separates
    // them.
    try std.testing.expect(!std.mem.eql(u8, marked, unmarked));

    // And the mark drew something, rather than the substitution quietly
    // dropping a codepoint it could not blit.
    var lit: u32 = 0;
    var i: usize = 0;
    while (i < marked.len) : (i += 4) {
        if (marked[i] > 40) lit += 1;
    }
    try std.testing.expect(lit > 10);
}

test "the two spellings of one mark draw the same thing" {
    // U+25B6 and U+25B8 are the large and small right-pointing triangles. A
    // caller writes whichever it prefers and means the same mark, so both reach
    // the same built-in and draw identically.
    const gpa = std.testing.allocator;
    try requireRaster(gpa);
    const sel = prism.drivers.createBestDevice(gpa) orelse return error.NoPrismDevice;
    defer sel.device.deinit();
    var font = try text.Font.load(gpa, text.builtin.neuropol_bytes);
    defer font.deinit(gpa);

    const large = try renderOneCodepoint(gpa, sel.device, &font, '\u{25B6}');
    defer gpa.free(large);
    const small = try renderOneCodepoint(gpa, sel.device, &font, '\u{25B8}');
    defer gpa.free(small);
    try std.testing.expectEqualSlices(u8, large, small);
}
