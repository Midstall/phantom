//! The application's root build callback.
const std = @import("std");
const phantom = @import("../phantom.zig");

/// The function that builds the widget tree, together with whatever state that
/// function draws from.
///
/// A bare `*const fn (*BuildContext) Widget` can carry nothing. An application
/// with a session, a connection, or any other state behind its interface would
/// then have to reach that state through a process global, which rules out two
/// instances in one process and makes the tree impossible to build in isolation
/// for a test. That is the same reason IronStyle asks for injected I/O rather
/// than global handles, and it applies to the widget tree for the same reason.
///
/// Pairing the pointer with an opaque `userdata` keeps the callback one plain
/// pointer, which a backend can store and call each frame, and still gives it a
/// way in. Use `of` rather than filling the two fields by hand: it puts the cast
/// back to the real type in one place instead of at every call site.
pub const Root = struct {
    build: *const fn (*phantom.BuildContext, ?*anyopaque) phantom.Widget,
    userdata: ?*anyopaque = null,

    /// Build the tree. Every backend goes through this rather than reading
    /// `build` directly, so none of them can forget to pass the userdata.
    pub fn call(self: Root, ctx: *phantom.BuildContext) phantom.Widget {
        return self.build(ctx, self.userdata);
    }

    /// A root that needs no state of its own.
    pub fn plain(comptime f: fn (*phantom.BuildContext) phantom.Widget) Root {
        const Shim = struct {
            fn build(ctx: *phantom.BuildContext, _: ?*anyopaque) phantom.Widget {
                return f(ctx);
            }
        };
        return .{ .build = Shim.build };
    }

    /// A root that draws from `state`, which must outlive the run.
    ///
    /// `State` is a real type here and `f` receives a real `*State`, so the one
    /// `@ptrCast` lives in this file and an application never writes one.
    pub fn of(
        comptime State: type,
        comptime f: fn (*phantom.BuildContext, *State) phantom.Widget,
        state: *State,
    ) Root {
        const Shim = struct {
            fn build(ctx: *phantom.BuildContext, userdata: ?*anyopaque) phantom.Widget {
                // Non-null by construction: `of` is the only thing that sets
                // this field to go with this shim, and it takes a real pointer.
                return f(ctx, @ptrCast(@alignCast(userdata.?)));
            }
        };
        return .{ .build = Shim.build, .userdata = state };
    }
};

test "plain builds the tree and passes no userdata" {
    const Fixture = struct {
        fn build(_: *phantom.BuildContext) phantom.Widget {
            const box = phantom.ColoredBox{ .color = .{ .r = 1, .g = 0, .b = 0 } };
            return box.widget();
        }
    };
    const r = Root.plain(Fixture.build);
    try std.testing.expect(r.userdata == null);
}

test "of hands the callback back the very pointer it was given, with its real type" {
    const Session = struct {
        color: phantom.Color,

        fn build(_: *phantom.BuildContext, s: *@This()) phantom.Widget {
            const box = phantom.ColoredBox{ .color = s.color };
            return box.widget();
        }
    };
    var session = Session{ .color = .{ .r = 0, .g = 0, .b = 1 } };
    const r = Root.of(Session, Session.build, &session);
    // The pointer survives the round trip through `?*anyopaque` unchanged, which
    // is the whole contract: the callback reads the caller's own state and not a
    // copy of it.
    try std.testing.expectEqual(@as(?*anyopaque, &session), r.userdata);
}

test "two roots over two states stay independent, which a process global could not do" {
    const Session = struct {
        count: u32,

        fn build(_: *phantom.BuildContext, s: *@This()) phantom.Widget {
            s.count += 1;
            const box = phantom.ColoredBox{ .color = .{ .r = 0, .g = 0, .b = 0 } };
            return box.widget();
        }
    };
    var a = Session{ .count = 0 };
    var b = Session{ .count = 0 };
    const ra = Root.of(Session, Session.build, &a);
    const rb = Root.of(Session, Session.build, &b);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var ctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = &owner };

    _ = ra.call(&ctx);
    _ = ra.call(&ctx);
    _ = rb.call(&ctx);

    try std.testing.expectEqual(@as(u32, 2), a.count);
    try std.testing.expectEqual(@as(u32, 1), b.count);
}
