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
    /// Where the link opens. A new tab by default, which is what a link OUT of
    /// an application wants. A hop the application expects to come back from,
    /// a sign in that ends at a callback, wants `.same_tab`: see
    /// `platform.OpenMode` for why the difference is not cosmetic.
    open_in: phantom.OpenMode = .new_tab,

    pub fn widget(self: *const Link) Widget {
        return phantom.StatefulWidget(Link, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        url: router.Location = .{},
        child: Widget = undefined,
        open_in: phantom.OpenMode = .new_tab,

        pub fn initState(s: *State, config: *const Link) !void {
            try s.url.set(config.url);
            s.child = config.child;
            s.open_in = config.open_in;
        }

        pub fn didUpdateWidget(s: *State, config: *const Link) !void {
            try s.url.set(config.url);
            s.child = config.child;
            s.open_in = config.open_in;
        }

        fn tap(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            if (!s.base.element.owner.platform.openUrl(s.url.slice(), s.open_in)) {
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
        seen_mode: ?phantom.OpenMode = null,
        fn open(ctx: *anyopaque, url: []const u8, mode: phantom.OpenMode) bool {
            const sp: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(sp.seen[0..url.len], url);
            sp.len = url.len;
            sp.seen_mode = mode;
            return true;
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

test "a link opens in a new tab by default and in this tab when it says so" {
    const gpa = std.testing.allocator;
    const Spy = struct {
        seen_mode: ?phantom.OpenMode = null,
        fn open(ctx: *anyopaque, _: []const u8, mode: phantom.OpenMode) bool {
            const sp: *@This() = @ptrCast(@alignCast(ctx));
            sp.seen_mode = mode;
            return true;
        }
    };

    // The default has to stay a new tab: a link OUT of an application should
    // leave the application there to come back to.
    var spy = Spy{};
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const out = Link{ .url = "https://example.com/docs", .child = box.widget() };
    var h = try phantom.testing.mount(gpa, out.widget());
    defer h.deinit();
    h.owner.platform = .{ .ctx = &spy, .open_url = Spy.open };
    try h.pump();
    h.tapAt(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(phantom.OpenMode.new_tab, spy.seen_mode.?);

    // And a sign in hop can ask for this tab, which is the one a popup blocker
    // cannot refuse and the one a person comes back to the callback in.
    var hop_spy = Spy{};
    const hop = Link{ .url = "https://forge.example/authorize", .child = box.widget(), .open_in = .same_tab };
    var h2 = try phantom.testing.mount(gpa, hop.widget());
    defer h2.deinit();
    h2.owner.platform = .{ .ctx = &hop_spy, .open_url = Spy.open };
    try h2.pump();
    h2.tapAt(.{ .x = 10, .y = 10 });
    try std.testing.expectEqual(phantom.OpenMode.same_tab, hop_spy.seen_mode.?);
}

test "a link the browser refused to open reports it, rather than looking like it worked" {
    const gpa = std.testing.allocator;
    const Blocked = struct {
        fn open(_: *anyopaque, _: []const u8, _: phantom.OpenMode) bool {
            // What a popup blocker does: the hook exists, the call was made, and
            // nothing opened.
            return false;
        }
    };
    var ctx: u8 = 0;
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    const l = Link{ .url = "https://example.com", .child = box.widget() };
    var h = try phantom.testing.mount(gpa, l.widget());
    defer h.deinit();
    h.owner.platform = .{ .ctx = &ctx, .open_url = Blocked.open };
    try h.pump();
    h.tapAt(.{ .x = 10, .y = 10 });

    // Before the hook could answer, this was indistinguishable from success and
    // the page simply appeared to ignore the tap.
    try h.expectFault(.link_unsupported);
}
