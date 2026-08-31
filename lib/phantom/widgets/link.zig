//! Opens an external URL when tapped. The URL lives on the State, which the
//! element owns, because a tap arrives long after the build arena that held
//! the config was reset.

const std = @import("std");
const phantom = @import("../../phantom.zig");
const router = @import("../router.zig");
const Widget = phantom.Widget;
const BuildContext = phantom.BuildContext;

pub const Link = struct {
    url: []const u8,
    child: Widget,

    pub fn widget(self: *const Link) Widget {
        return phantom.StatefulWidget(Link, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        url: router.Location = .{},
        child: Widget = undefined,

        pub fn initState(s: *State, config: *const Link) !void {
            try s.url.set(config.url);
            s.child = config.child;
        }

        pub fn didUpdateWidget(s: *State, config: *const Link) !void {
            try s.url.set(config.url);
            s.child = config.child;
        }

        fn tap(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (!s.base.element.owner.platform.openUrl(s.url.slice())) {
                s.base.sink().report(.link_unsupported, s.url.slice());
            }
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            return b.new(phantom.GestureDetector{
                .on_tap = tap,
                .ctx = s,
                .child = s.child,
            }).widget();
        }
    };
};

test "a tapped link hands the url to the platform hook" {
    const gpa = std.testing.allocator;
    const Spy = struct {
        seen: [64]u8 = undefined,
        len: usize = 0,
        fn open(ctx: *anyopaque, url: []const u8) void {
            const sp: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(sp.seen[0..url.len], url);
            sp.len = url.len;
        }
    };
    var spy = Spy{};

    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const l = Link{ .url = "https://example.com", .child = box.widget() };
    var h = try phantom.testing.mount(gpa, l.widget());
    defer h.deinit();
    h.owner.platform = .{ .ctx = &spy, .open_url = Spy.open };
    try h.pump();
    h.tapAt(.{ .x = 10, .y = 10 });
    try std.testing.expectEqualStrings("https://example.com", spy.seen[0..spy.len]);
}

test "a tapped link with no platform hook reports a fault instead of doing nothing quietly" {
    const gpa = std.testing.allocator;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const l = Link{ .url = "https://example.com", .child = box.widget() };
    var h = try phantom.testing.mount(gpa, l.widget());
    defer h.deinit();
    try h.pump();
    h.tapAt(.{ .x = 10, .y = 10 });
    try h.expectFault(.link_unsupported);
}
