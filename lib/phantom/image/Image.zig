const std = @import("std");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
pub const Image = @This();

pub const Format = enum { png, jpeg, unknown };

/// Sniff the image format from the leading magic bytes.
pub fn detectFormat(bytes: []const u8) Format {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    return .unknown;
}

/// The MIME string for a data URL (web <img>). Only valid for encoded formats.
pub fn mime(f: Format) []const u8 {
    return switch (f) {
        .png => "image/png",
        .jpeg => "image/jpeg",
        .unknown => "application/octet-stream",
    };
}

bytes: []const u8, // encoded image bytes (png/jpeg); empty for a fromRgba image
format: Format,
width: u32,
height: u32,
/// Decoded RGBA8 (row-major, tightly packed, w*h*4). Null until a decoder runs
/// (slice 2/3) or set directly by fromRgba. Native GPU upload uses this; when null,
/// native skips the image (web still renders it via <img> from `bytes`).
rgba: ?[]const u8 = null,
/// True when rgba was allocated by ensureDecoded and must be freed in deinit.
/// False for fromRgba images (borrowed slice; caller owns it).
rgba_owned: bool = false,

pub fn fromBytes(bytes: []const u8, width: u32, height: u32) Image {
    return .{ .bytes = bytes, .format = detectFormat(bytes), .width = width, .height = height, .rgba = null, .rgba_owned = false };
}
pub fn fromRgba(pixels: []const u8, width: u32, height: u32) Image {
    return .{ .bytes = "", .format = .unknown, .width = width, .height = height, .rgba = pixels, .rgba_owned = false };
}

/// Decode encoded bytes into rgba (memoized). Sets width/height to the intrinsic
/// decoded dimensions so the Prism texture (sized from width x height) matches rgba.
/// No-op if rgba is already set or if bytes is empty (fromRgba path).
pub fn ensureDecoded(self: *Image, gpa: std.mem.Allocator) (png.DecodeError || jpeg.DecodeError)!void {
    if (self.rgba != null) return; // already decoded or fromRgba
    if (self.bytes.len == 0) return; // fromRgba; nothing to decode
    switch (self.format) {
        .png => {
            const d = try png.decode(gpa, self.bytes);
            self.rgba = d.rgba;
            self.width = d.width;
            self.height = d.height;
            self.rgba_owned = true;
        },
        .jpeg => {
            const d = try jpeg.decode(gpa, self.bytes);
            self.rgba = d.rgba;
            self.width = d.width;
            self.height = d.height;
            self.rgba_owned = true;
        },
        .unknown => return error.Unsupported,
    }
}

/// Free the decoded rgba buffer if this Image owns it. Borrowed fromRgba slices
/// are never freed here. Safe to call multiple times.
pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
    if (self.rgba_owned) {
        if (self.rgba) |p| gpa.free(@constCast(p));
        self.rgba = null;
        self.rgba_owned = false;
    }
}

test "detectFormat sniffs png/jpeg/unknown by magic bytes" {
    try std.testing.expectEqual(Format.png, detectFormat(&.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0 }));
    try std.testing.expectEqual(Format.jpeg, detectFormat(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0 }));
    try std.testing.expectEqual(Format.unknown, detectFormat(&.{ 1, 2, 3, 4 }));
    try std.testing.expectEqual(Format.unknown, detectFormat(&.{}));
}

test "ensureDecoded fills rgba from an embedded PNG and marks it owned" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("testdata/logo.png");
    var img = fromBytes(bytes, 0, 0);
    defer img.deinit(gpa);
    try img.ensureDecoded(gpa);
    try std.testing.expectEqual(@as(u32, 4), img.width);
    try std.testing.expectEqual(@as(u32, 4), img.height);
    try std.testing.expect(img.rgba != null);
    try std.testing.expect(img.rgba_owned);
}

test "ensureDecoded is a no-op for a fromRgba image and does not free the borrow" {
    const gpa = std.testing.allocator;
    const px = [_]u8{ 1, 2, 3, 4 };
    var img = fromRgba(&px, 1, 1);
    defer img.deinit(gpa);
    try img.ensureDecoded(gpa);
    try std.testing.expect(!img.rgba_owned);
}
