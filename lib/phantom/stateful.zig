//! Flutter-mirror stateful widgets. A config struct exposes `pub const State` with a
//! `base: phantom.StateBase` field and a `build` method. `statefulWidget` wires the
//! mount/update vtable so the State object is created on the gpa, lives on its Element,
//! and survives rebuilds. `setState` mutates state then schedules a dirty rebuild.

const std = @import("std");
const phantom = @import("../phantom.zig");
const widget_mod = @import("widget.zig");
const Widget = phantom.Widget;
const Element = phantom.Element;
const BuildContext = phantom.BuildContext;
const StateVTable = widget_mod.StateVTable;

/// Build a Widget for a stateful `Config`. `Config.State` must have a `base:
/// phantom.StateBase` field and `pub fn build(*State, *BuildContext) anyerror!Widget`.
pub fn statefulWidget(comptime Config: type, self: *const Config) Widget {
    const Gen = struct {
        const State = Config.State;
        const sv = StateVTable{ .build = buildThunk, .deinit = deinitThunk };
        const vt = Widget.VTable{ .mount = mount, .update = update };

        fn buildThunk(sp: *anyopaque, bctx: *BuildContext) anyerror!Widget {
            const s: *State = @ptrCast(@alignCast(sp));
            return s.build(bctx);
        }
        fn deinitThunk(sp: *anyopaque, gpa: std.mem.Allocator) void {
            const s: *State = @ptrCast(@alignCast(sp));
            if (@hasDecl(State, "dispose")) s.dispose();
            gpa.destroy(s);
        }
        fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
            const config: *const Config = @ptrCast(@alignCast(ptr));
            const gpa = bctx.owner.gpa;
            const el = gpa.create(Element) catch {
                bctx.owner.sink.report(.state_init, "stateful element alloc failed");
                return errorBoxElement(bctx, parent);
            };
            const s = gpa.create(State) catch {
                gpa.destroy(el);
                bctx.owner.sink.report(.state_init, "state alloc failed");
                return errorBoxElement(bctx, parent);
            };
            s.* = .{};
            s.base.element = el;
            el.* = .{
                .owner = bctx.owner,
                .parent = parent,
                .vtable = &vt,
                .type_name = @typeName(Config),
                .render_object = null,
                .child = null,
                .state = s,
                .state_vtable = &sv,
                .depth = widget_mod.depthOf(parent),
            };
            if (@hasDecl(State, "initState")) {
                s.initState(config) catch |e| {
                    bctx.owner.sink.report(.state_init, @errorName(e));
                    // initState did not complete: destroy the State WITHOUT calling dispose
                    // (it never fully initialized) and the freshly allocated element, then
                    // substitute an ErrorBox. The element has no child or render object yet
                    // and is not in any parent slot or the dirty queue, so a direct destroy
                    // is safe.
                    gpa.destroy(s);
                    gpa.destroy(el);
                    return errorBoxElement(bctx, parent);
                };
            }
            el.rebuild(bctx); // build the initial child (infallible: soft-fails to ErrorBox)
            return el;
        }
        fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
            const config: *const Config = @ptrCast(@alignCast(ptr));
            const s: *State = @ptrCast(@alignCast(el.state.?));
            if (@hasDecl(State, "didUpdateWidget")) {
                s.didUpdateWidget(config) catch |e| {
                    bctx.owner.sink.report(.state_update, @errorName(e));
                };
            }
            // Flutter cascade semantics: a parent rebuild that reconciles this same-type
            // stateful child rebuilds the child's subtree. (setState granularity is
            // unaffected: setState still only enqueues its own target.)
            el.rebuild(bctx);
        }
    };
    return .{ .ptr = self, .vtable = &Gen.vt };
}

fn errorBoxElement(bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
    const eb = phantom.ErrorBox{};
    return eb.widget().mount(bctx, parent);
}

/// Apply `mutation` to the state, then schedule a rebuild of its element. `state_ptr`
/// must point at a State with a `base: phantom.StateBase` field.
pub fn setState(state_ptr: anytype, mutation: *const fn (@TypeOf(state_ptr)) void) void {
    mutation(state_ptr);
    markNeedsBuild(state_ptr);
}

/// Schedule a rebuild of the state's element without mutating (mutate the fields yourself
/// first). `state_ptr` must point at a State with a `base: phantom.StateBase` field.
pub fn markNeedsBuild(state_ptr: anytype) void {
    const el = state_ptr.base.element;
    el.owner.scheduleBuildFor(el);
}

// Test-only stateful widget: a box whose radius encodes a counter.
const Counter = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: u32 = 0,
        // Keep the config value alive by storing it on the State (its address is stable).
        box: phantom.ColoredBox = undefined,
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            const box = s.boxConfig();
            return box.widget();
        }
        fn boxConfig(s: *@This()) *phantom.ColoredBox {
            s.box = .{ .color = phantom.Color.rgb(0, 0, 1), .radius = @floatFromInt(s.count) };
            return &s.box;
        }
    };
    pub fn widget(self: *const Counter) Widget {
        return statefulWidget(Counter, self);
    }
};

fn inc(s: *Counter.State) void {
    s.count += 1;
}

test "statefulWidget mounts, builds an initial child, and rebuilds on setState" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var counter = Counter{};
    const el = try counter.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    // Initial build produced a child render object (radius 0).
    try std.testing.expect(el.state != null);
    try std.testing.expect(el.render_object == null); // component element, no own render object
    try std.testing.expect(el.renderObject() != null); // resolves to the child box
    try std.testing.expectEqual(@as(u32, 1), el.build_count);

    const s: *Counter.State = @ptrCast(@alignCast(el.state.?));
    setState(s, inc);
    try std.testing.expectEqual(@as(usize, 1), owner.dirty.items.len);
    owner.flushDirty(&bctx);
    try std.testing.expectEqual(@as(u32, 2), el.build_count);
    try std.testing.expectEqual(@as(u32, 1), s.count);

    // Render the reconciled tree and confirm the box radius reflects the new count.
    var canvas = phantom.Canvas.init(std.testing.allocator);
    defer canvas.deinit();
    const ro = el.renderObject().?;
    _ = ro.layout(phantom.BoxConstraints.tight(.{ .width = 40, .height = 40 }));
    try ro.paint(&canvas, phantom.PhysicalOffset.zero);
    try std.testing.expectEqual(@as(f32, 1), canvas.list.primitives.items[0].rrect.radius);
}

const Boom = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        pub fn build(_: *@This(), _: *BuildContext) anyerror!Widget {
            return error.StateBuildFailed;
        }
    };
    pub fn widget(self: *const Boom) Widget {
        return statefulWidget(Boom, self);
    }
};

test "a State.build that throws records state_update and substitutes an ErrorBox" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var boom = Boom{};
    const el = try boom.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.state_update, sink.first.?.code);
    try std.testing.expectEqualStrings(@typeName(phantom.ErrorBox), el.child.?.type_name);
}

const FlipInner = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: u32 = 0,
        box: phantom.ColoredBox = undefined,
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            s.box = .{ .color = phantom.Color.rgb(0, 0, 1), .radius = @floatFromInt(s.count) };
            return s.box.widget();
        }
    };
    pub fn widget(self: *const @This()) Widget {
        return statefulWidget(@This(), self);
    }
};

const FlipOuter = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        flip: bool = false,
        inner: FlipInner = .{},
        red: phantom.ColoredBox = undefined,
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            if (s.flip) {
                s.red = .{ .color = phantom.Color.rgb(1, 0, 0), .radius = 3 };
                return s.red.widget(); // a different widget type than FlipInner
            }
            return s.inner.widget();
        }
    };
    pub fn widget(self: *const @This()) Widget {
        return statefulWidget(@This(), self);
    }
};

fn flipOn(s: *FlipOuter.State) void {
    s.flip = true;
}
fn bumpInner(s: *FlipInner.State) void {
    s.count += 1;
}

test "flushDirty is UAF-safe when an ancestor rebuild replaces a still-dirty descendant" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var outer = FlipOuter{};
    const el = try outer.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    // el.child is the FlipInner component element after the initial build.
    const inner_el = el.child.?;
    const inner_state: *FlipInner.State = @ptrCast(@alignCast(inner_el.state.?));
    const outer_state: *FlipOuter.State = @ptrCast(@alignCast(el.state.?));

    // Dirty BOTH the descendant and the ancestor before a single flush.
    phantom.setState(inner_state, bumpInner);
    phantom.setState(outer_state, flipOn);
    try std.testing.expectEqual(@as(usize, 2), owner.dirty.items.len);

    // Ancestor is shallower, so it rebuilds first and replaces FlipInner (type change).
    // FlipInner is freed and MUST be unlinked from the dirty queue, or the next iteration
    // would dereference freed memory.
    owner.flushDirty(&bctx);

    try std.testing.expectEqual(@as(usize, 0), owner.dirty.items.len);
    try std.testing.expectEqualStrings(@typeName(phantom.ColoredBox), el.child.?.type_name);
}

const EventLog = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,
    fn push(self: *EventLog, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }
    fn str(self: *const EventLog) []const u8 {
        return self.buf[0..self.len];
    }
};

// A probe that records each lifecycle event and exercises base.gpa() (alloc in
// initState, free in dispose) so the testing allocator proves no leak.
const LifecycleProbe = struct {
    log: *EventLog,
    tag: u32 = 0,
    pub const State = struct {
        base: phantom.StateBase = .{},
        log: *EventLog = undefined,
        tag: u32 = 0,
        owned: ?[]u8 = null,
        box: phantom.ColoredBox = undefined,
        pub fn initState(s: *@This(), config: *const LifecycleProbe) anyerror!void {
            s.log = config.log;
            s.tag = config.tag;
            s.owned = try s.base.gpa().alloc(u8, 4);
            s.log.push('I');
        }
        pub fn didUpdateWidget(s: *@This(), config: *const LifecycleProbe) anyerror!void {
            s.tag = config.tag;
            s.log.push('U');
        }
        pub fn dispose(s: *@This()) void {
            if (s.owned) |o| s.base.gpa().free(o);
            s.log.push('D');
        }
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            s.log.push('B');
            s.box = .{ .color = phantom.Color.rgb(0, 0, 1), .radius = @floatFromInt(s.tag) };
            return s.box.widget();
        }
    };
    pub fn widget(self: *const LifecycleProbe) Widget {
        return statefulWidget(LifecycleProbe, self);
    }
};

test "lifecycle hooks fire in order: initState, build, didUpdateWidget, build, dispose" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var log = EventLog{};
    var probe = LifecycleProbe{ .log = &log, .tag = 0 };
    const el = try probe.widget().mount(&bctx, null);
    // mount: initState then the first build.
    try std.testing.expectEqualStrings("IB", log.str());

    // Reconcile a new same-type config (tag changed) -> didUpdateWidget then rebuild.
    var probe2 = LifecycleProbe{ .log = &log, .tag = 5 };
    try probe2.widget().update(el, &bctx);
    try std.testing.expectEqualStrings("IBUB", log.str());

    // Unmount -> dispose (frees the owned slice; testing allocator checks no leak).
    el.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("IBUBD", log.str());
}

// initState that throws -> state_init fault + ErrorBox substituted (no stateful element).
const InitBoom = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        box: phantom.ColoredBox = undefined,
        pub fn initState(_: *@This(), _: *const InitBoom) anyerror!void {
            return error.InitFailed;
        }
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            s.box = .{ .color = phantom.Color.rgb(0, 0, 0), .radius = 0 };
            return s.box.widget();
        }
    };
    pub fn widget(self: *const InitBoom) Widget {
        return statefulWidget(InitBoom, self);
    }
};

test "an initState that throws records state_init and substitutes an ErrorBox" {
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var boom = InitBoom{};
    const el = try boom.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    try std.testing.expect(!sink.ok());
    try std.testing.expectEqual(phantom.FaultCode.state_init, sink.first.?.code);
    try std.testing.expectEqualStrings(@typeName(phantom.ErrorBox), el.type_name);
}

// Proves the SUPPLIED std.Io is threaded down to State via base.io().
const IoProbe = struct {
    seen: *?std.Io,
    pub const State = struct {
        base: phantom.StateBase = .{},
        seen: *?std.Io = undefined,
        box: phantom.ColoredBox = undefined,
        pub fn initState(s: *@This(), config: *const IoProbe) anyerror!void {
            s.seen = config.seen;
            s.seen.* = s.base.io();
        }
        pub fn build(s: *@This(), b: *BuildContext) anyerror!Widget {
            _ = b;
            s.box = .{ .color = phantom.Color.rgb(0, 0, 0), .radius = 0 };
            return s.box.widget();
        }
    };
    pub fn widget(self: *const IoProbe) Widget {
        return statefulWidget(IoProbe, self);
    }
};

test "the supplied std.Io is threaded through to State via base.io()" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const test_io = threaded.io();

    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink, .io = test_io };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };

    var seen: ?std.Io = null;
    var probe = IoProbe{ .seen = &seen };
    const el = try probe.widget().mount(&bctx, null);
    defer el.deinit(std.testing.allocator);

    try std.testing.expect(seen != null);
    try std.testing.expect(seen.?.vtable == test_io.vtable);
    try std.testing.expect(seen.?.userdata == test_io.userdata);
}
