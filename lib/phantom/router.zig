//! Routing for every backend. A route table maps a path to a build function,
//! and a bounded stack holds the history. The browser is not in this file:
//! `phantom.platform` carries the location hooks that a backend fills in.

const std = @import("std");

/// A path longer than this is refused. 128 bytes holds every route this
/// framework is meant for, and a fixed size keeps the stack free of an
/// allocator.
pub const max_path = 128;

/// The deepest the history can go. A deeper stack is a navigation loop, which
/// is a fault and not a state to grow into.
pub const max_stack = 16;

/// One path, copied into fixed storage. A caller's slice can point into a
/// build arena that is reset every frame, so the stack never holds a borrowed
/// path.
pub const Location = struct {
    buf: [max_path]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Location, path: []const u8) error{PathTooLong}!void {
        if (path.len > max_path) return error.PathTooLong;
        @memcpy(self.buf[0..path.len], path);
        self.len = path.len;
    }

    pub fn slice(self: *const Location) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The history. Bounded, and it owns every path in it.
pub const Stack = struct {
    entries: [max_stack]Location = undefined,
    count: usize = 0,

    pub fn init(path: []const u8) error{PathTooLong}!Stack {
        var s = Stack{};
        s.entries[0] = .{};
        try s.entries[0].set(path);
        s.count = 1;
        return s;
    }

    pub fn depth(self: *const Stack) usize {
        return self.count;
    }

    /// The top of the stack. The stack is never empty: `init` fills it and
    /// `pop` refuses to remove the last entry.
    pub fn current(self: *const Stack) []const u8 {
        std.debug.assert(self.count > 0);
        return self.entries[self.count - 1].slice();
    }

    pub fn push(self: *Stack, path: []const u8) error{ PathTooLong, StackFull }!void {
        if (self.count == max_stack) return error.StackFull;
        var loc = Location{};
        try loc.set(path);
        self.entries[self.count] = loc;
        self.count += 1;
    }

    /// True if a level was removed. False at the bottom, where there is
    /// nothing to go back to.
    pub fn pop(self: *Stack) bool {
        if (self.count <= 1) return false;
        self.count -= 1;
        return true;
    }

    pub fn replace(self: *Stack, path: []const u8) error{PathTooLong}!void {
        std.debug.assert(self.count > 0);
        try self.entries[self.count - 1].set(path);
    }
};

/// One entry in the route table. `build` runs on every frame the route is on
/// top, so it holds no state of its own.
pub const Route = struct {
    path: []const u8,
    build: *const fn (*BuildContext) Widget,
};

/// The handle a descendant reaches through `Router.of`. It holds the state
/// pointer, which the stateful element owns and keeps at one address for the
/// life of the router, so a tap handler can hold it between frames.
pub const RouterHandle = struct {
    state: *Router.State,

    pub fn location(self: RouterHandle) []const u8 {
        return self.state.location();
    }
    pub fn push(self: RouterHandle, path: []const u8) void {
        self.state.push(path);
    }
    pub fn pop(self: RouterHandle) bool {
        return self.state.pop();
    }
    pub fn replace(self: RouterHandle, path: []const u8) void {
        self.state.replace(path);
    }
};

/// Publishes the handle to the subtree. Same shape as `Theme`: an element with
/// an inherited id and no render object of its own.
pub const RouterScope = struct {
    /// Points at the `handle` field the State owns. A value copy here would
    /// live in the build arena, which is reset after every frame, and a tap
    /// handler that read it later would read freed memory.
    handle: *const RouterHandle,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const RouterScope) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const RouterScope = @ptrCast(@alignCast(ptr));
        const el = try bctx.owner.gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(RouterScope),
            .render_object = null,
            .inherited_id = phantom.typeId(RouterHandle),
            .inherited_data = self.handle,
            .depth = phantom.widget.depthOf(parent),
        };
        el.child = try el.updateChild(null, self.child, bctx);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const RouterScope = @ptrCast(@alignCast(ptr));
        el.inherited_data = self.handle;
        el.child = try el.updateChild(el.child, self.child, bctx);
    }
};

/// The router. Holds the history, selects one route, and publishes a handle to
/// its subtree.
pub const Router = struct {
    routes: []const Route,
    initial: []const u8 = "/",
    not_found: *const fn (*BuildContext) Widget,

    pub fn widget(self: *const Router) Widget {
        return phantom.StatefulWidget(Router, self);
    }

    /// The nearest router above the current build point, or null when there is
    /// none. A caller that navigates unconditionally should assert on the null.
    pub fn of(bctx: *BuildContext) ?*const RouterHandle {
        return phantom.inheritedOf(bctx.element, RouterHandle);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        stack: Stack = undefined,
        /// Re-read on every update. A route table built fresh each frame with
        /// `b.newSlice` stays valid this way, because the slice would
        /// otherwise point into a build arena that is reset once the frame
        /// ends.
        routes: []const Route = &.{},
        /// Re-read on every update, for the same reason as `routes`.
        not_found: *const fn (*BuildContext) Widget = undefined,
        /// Set by `initState`, so a config with a path that is too long fails
        /// once at mount and the tree still builds.
        handle: RouterHandle = undefined,

        pub fn initState(s: *State, config: *const Router) !void {
            s.stack = try Stack.init(config.initial);
            s.routes = config.routes;
            s.not_found = config.not_found;
            s.handle = .{ .state = s };
        }

        pub fn didUpdateWidget(s: *State, config: *const Router) !void {
            s.routes = config.routes;
            s.not_found = config.not_found;
        }

        pub fn location(s: *const State) []const u8 {
            return s.stack.current();
        }

        pub fn push(s: *State, path: []const u8) void {
            s.stack.push(path) catch |e| {
                s.base.element.owner.sink.report(.route_rejected, @errorName(e));
                return;
            };
            s.sync();
            phantom.markNeedsBuild(s);
        }

        pub fn pop(s: *State) bool {
            if (!s.stack.pop()) return false;
            s.sync();
            phantom.markNeedsBuild(s);
            return true;
        }

        pub fn replace(s: *State, path: []const u8) void {
            s.stack.replace(path) catch |e| {
                s.base.element.owner.sink.report(.route_rejected, @errorName(e));
                return;
            };
            s.sync();
            phantom.markNeedsBuild(s);
        }

        /// Task 4 fills this in with the browser location. It is a separate
        /// method so the navigation methods above never grow a second concern.
        fn sync(s: *State) void {
            _ = s;
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            const here = s.location();
            const child = for (s.routes) |r| {
                if (std.mem.eql(u8, r.path, here)) break r.build(b);
            } else blk: {
                // Reported on every build while the location stays unmatched,
                // not only once on the transition into it. Per-frame
                // diagnostics are the norm in this codebase, and a caller
                // watching the sink needs the fault to still be there on the
                // frame it checks, not only on the frame it started.
                b.owner.sink.report(.route_not_found, here);
                break :blk s.not_found(b);
            };
            return b.new(RouterScope{ .handle = &s.handle, .child = child }).widget();
        }
    };
};

/// Pushes a route when tapped. The target path lives on the State, which the
/// element owns, so the tap handler never reads a build arena that was reset.
pub const RouteLink = struct {
    to: []const u8,
    child: Widget,

    pub fn widget(self: *const RouteLink) Widget {
        return phantom.StatefulWidget(RouteLink, self);
    }

    pub const State = struct {
        base: phantom.StateBase = .{},
        target: Location = .{},
        child: Widget = undefined,
        /// A copy, not a pointer. `Router.of` returns a pointer into the
        /// router State, which is stable, but copying the small struct keeps
        /// this State free of any question about who outlives whom.
        handle: ?RouterHandle = null,

        pub fn initState(s: *State, config: *const RouteLink) !void {
            try s.target.set(config.to);
            s.child = config.child;
        }

        pub fn didUpdateWidget(s: *State, config: *const RouteLink) !void {
            try s.target.set(config.to);
            s.child = config.child;
        }

        fn tap(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            const h = s.handle orelse {
                // A soft failure still needs a report, so a link left outside
                // a Router does not fail in silence.
                s.base.sink().report(.route_rejected, "RouteLink has no Router above it");
                return;
            };
            h.push(s.target.slice());
        }

        pub fn build(s: *State, b: *BuildContext) anyerror!Widget {
            // Resolved on every build, because a rebuilt tree can move this
            // link under a different router.
            s.handle = if (Router.of(b)) |h| h.* else null;
            return b.new(phantom.GestureDetector{
                .on_tap = tap,
                .ctx = s,
                .child = s.child,
            }).widget();
        }
    };
};

test "a location holds the path it was set from" {
    var loc = Location{};
    try loc.set("/gallery");
    try std.testing.expectEqualStrings("/gallery", loc.slice());
}

test "a location refuses a path longer than the buffer" {
    var loc = Location{};
    const long = "/" ++ ("a" ** max_path);
    try std.testing.expectError(error.PathTooLong, loc.set(long));
}

test "a new stack is one deep and reads the initial path" {
    var s = try Stack.init("/");
    try std.testing.expectEqual(@as(usize, 1), s.depth());
    try std.testing.expectEqualStrings("/", s.current());
}

test "push adds a level and pop returns to the one below" {
    var s = try Stack.init("/");
    try s.push("/gallery");
    try std.testing.expectEqual(@as(usize, 2), s.depth());
    try std.testing.expectEqualStrings("/gallery", s.current());
    try std.testing.expect(s.pop());
    try std.testing.expectEqualStrings("/", s.current());
}

test "pop at the bottom keeps the last location and reports that it did nothing" {
    var s = try Stack.init("/");
    try std.testing.expect(!s.pop());
    try std.testing.expectEqual(@as(usize, 1), s.depth());
    try std.testing.expectEqualStrings("/", s.current());
}

test "replace changes the top without growing the stack" {
    var s = try Stack.init("/");
    try s.push("/about");
    try s.replace("/gallery");
    try std.testing.expectEqual(@as(usize, 2), s.depth());
    try std.testing.expectEqualStrings("/gallery", s.current());
}

test "a full stack refuses another push and keeps its top" {
    var s = try Stack.init("/");
    var i: usize = 1;
    while (i < max_stack) : (i += 1) try s.push("/gallery");
    try std.testing.expectEqual(@as(usize, max_stack), s.depth());
    try std.testing.expectError(error.StackFull, s.push("/about"));
    try std.testing.expectEqualStrings("/gallery", s.current());
}

test "the stack copies the path, so a caller's buffer can change afterwards" {
    var buf = [_]u8{ '/', 'a' };
    var s = try Stack.init(&buf);
    buf[1] = 'b';
    try std.testing.expectEqualStrings("/a", s.current());
}

// ---------------------------------------------------------------------------
// Router widget tests
// ---------------------------------------------------------------------------

const phantom = @import("../phantom.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;

fn homePage(b: *BuildContext) Widget {
    return b.new(phantom.Text{ .text = "home" }).widget();
}

fn galleryPage(b: *BuildContext) Widget {
    return b.new(phantom.Text{ .text = "gallery" }).widget();
}

fn missingPage(b: *BuildContext) Widget {
    return b.new(phantom.Text{ .text = "missing" }).widget();
}

const test_routes = [_]Route{
    .{ .path = "/", .build = homePage },
    .{ .path = "/gallery", .build = galleryPage },
};

test "the router builds the route that matches the initial path" {
    const r = Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    try h.expectNoFaults();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    try std.testing.expectEqualStrings("/", state.location());
}

test "a push builds the other route" {
    const r = Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    state.push("/gallery");
    try h.pump();
    try std.testing.expectEqualStrings("/gallery", state.location());
    try h.expectNoFaults();
}

test "a pop returns to the route below" {
    const r = Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    state.push("/gallery");
    try h.pump();
    try std.testing.expect(state.pop());
    try h.pump();
    try std.testing.expectEqualStrings("/", state.location());
}

test "an unknown path builds the not-found route and reports a fault" {
    const r = Router{ .routes = &test_routes, .initial = "/nowhere", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    try std.testing.expectEqualStrings("/nowhere", state.location());
    try h.expectFault(.route_not_found);
}

test "a path longer than the buffer is refused and the location does not change" {
    const r = Router{ .routes = &test_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    const long = "/" ++ ("a" ** max_path);
    state.push(long);
    try h.pump();
    try std.testing.expectEqualStrings("/", state.location());
    try h.expectFault(.route_rejected);
}

// ---------------------------------------------------------------------------
// RouterScope, Router.of and RouteLink tests
// ---------------------------------------------------------------------------

fn homeWithLink(b: *BuildContext) Widget {
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    return b.new(RouteLink{ .to = "/gallery", .child = b.new(box).widget() }).widget();
}

const link_routes = [_]Route{
    .{ .path = "/", .build = homeWithLink },
    .{ .path = "/gallery", .build = galleryPage },
};

/// The point at the center of the tree's single render object, in physical
/// coordinates. `Router`, `RouterScope` and `RouteLink` carry no render
/// object of their own, so the walk from the root lands on the
/// `GestureDetector` that `RouteLink` builds.
fn centerOfRoot(h: *phantom.testing.Harness) phantom.PhysicalOffset {
    const ro = h.root.renderObject().?;
    return .{
        .x = ro.origin.x + ro.size.width * 0.5,
        .y = ro.origin.y + ro.size.height * 0.5,
    };
}

test "a RouteLink mounted under a Router, when tapped, changes the router's location to its target" {
    const r = Router{ .routes = &link_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    try h.pump();
    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    try std.testing.expectEqualStrings("/", state.location());

    h.tapAt(centerOfRoot(&h));

    try std.testing.expectEqualStrings("/gallery", state.location());
    try h.expectNoFaults();
}

test "Router.of returns null when there is no router above the build point" {
    var link = RouteLink{ .to = "/gallery", .child = (phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) }).widget() };
    var h = try phantom.testing.mount(std.testing.allocator, link.widget());
    defer h.deinit();
    try h.pump();
    const state = try h.stateOf(phantom.testing.find.byType(RouteLink), RouteLink.State);
    try std.testing.expect(state.handle == null);
}

test "Router.of returns a handle whose location matches the router above it" {
    const r = Router{ .routes = &link_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();
    try h.pump();
    const router_state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    const link_state = try h.stateOf(phantom.testing.find.byType(RouteLink), RouteLink.State);
    const handle = link_state.handle orelse return error.NoRouterHandle;
    try std.testing.expectEqualStrings(router_state.location(), handle.location());
}

test "a RouteLink rebuilt after the build arena resets still navigates on tap" {
    const r = Router{ .routes = &link_routes, .initial = "/", .not_found = missingPage };
    var h = try phantom.testing.mount(std.testing.allocator, r.widget());
    defer h.deinit();

    // Two frames with an arena reset in between, matching the reset that
    // `render` runs once a frame in `web.zig`. `RouteLink.State` never holds
    // a pointer into that arena, so navigation must still work afterwards.
    try h.pump();
    _ = h.arena.reset(.retain_capacity);
    try h.pump();

    const state = try h.stateOf(phantom.testing.find.byType(Router), Router.State);
    h.tapAt(centerOfRoot(&h));

    try std.testing.expectEqualStrings("/gallery", state.location());
}
