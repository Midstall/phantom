//! The hooks a backend fills in for the things a widget tree cannot do by
//! itself: open a URL, and read or write the address of the page. Native
//! backends leave them null, and a widget that finds a null hook does nothing
//! rather than guessing.

const std = @import("std");

pub const UrlStrategy = enum {
    /// `/#/gallery`. Works on any static host with no configuration.
    hash,
    /// `/gallery`. Needs the host to serve the application for an unknown
    /// path, or the build to write a copy of the page at each route.
    path,
};

pub const Platform = struct {
    ctx: ?*anyopaque = null,
    open_url: ?*const fn (*anyopaque, []const u8) void = null,
    /// Writes the current path into `buf` and returns the written part.
    /// A fixed buffer keeps the ownership on the caller's side, because the
    /// browser binding allocates the string and must free it again.
    read_location: ?*const fn (*anyopaque, []u8) []const u8 = null,
    write_location: ?*const fn (*anyopaque, []const u8) void = null,
    strategy: UrlStrategy = .hash,

    /// True if a hook took the URL. False means nothing happened, which is the
    /// correct result on a backend with no browser.
    pub fn openUrl(self: Platform, url: []const u8) bool {
        const f = self.open_url orelse return false;
        const c = self.ctx orelse return false;
        f(c, url);
        return true;
    }

    pub fn readLocation(self: Platform, buf: []u8) ?[]const u8 {
        const f = self.read_location orelse return null;
        const c = self.ctx orelse return null;
        return f(c, buf);
    }

    pub fn writeLocation(self: Platform, path: []const u8) void {
        const f = self.write_location orelse return;
        const c = self.ctx orelse return;
        f(c, path);
    }
};

test "an empty platform opens nothing and reports that it did not" {
    const p = Platform{};
    try std.testing.expect(!p.openUrl("https://example.com"));
}

test "openUrl passes the url to the hook and reports success" {
    const Spy = struct {
        seen: [64]u8 = undefined,
        len: usize = 0,
        fn open(ctx: *anyopaque, url: []const u8) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(s.seen[0..url.len], url);
            s.len = url.len;
        }
    };
    var spy = Spy{};
    const p = Platform{ .ctx = &spy, .open_url = Spy.open };
    try std.testing.expect(p.openUrl("https://example.com"));
    try std.testing.expectEqualStrings("https://example.com", spy.seen[0..spy.len]);
}

test "readLocation with no hook returns null" {
    const p = Platform{};
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), p.readLocation(&buf));
}
