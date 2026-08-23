const std = @import("std");
const phantom = @import("phantom");

/// This is the compilation ROOT, not an imported module, so this is the file
/// Zig's own panic mechanism actually consults: `phantom.setPanicHook` alone does
/// not reach a bare `@panic`, an `unreachable`, or a failed bounds check, only an
/// explicit `phantom.panic(...)` call (see `lib/phantom/panic.zig`). Without this,
/// the terminal is left in raw mode on the alternate screen on the single most
/// common class of crash.
pub const panic = std.debug.FullPanic(phantom.tui.term.rootPanic);

/// A plain block with no text, tall enough that the column overflows the viewport
/// and the scroll view has something real to scroll.
fn spacer(ctx: *phantom.BuildContext, height: f32) phantom.Widget {
    const box = ctx.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0.15, 0.15, 0.2) });
    const sized = ctx.new(phantom.SizedBox{ .height = height, .child = box.widget() });
    return sized.widget();
}

/// Stateful so a tap can show up on screen: a human running the manual check needs
/// to see a click land, and nothing renders a plain counter that only a debugger
/// could inspect.
const Root = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        taps: u32 = 0,
        /// Backs the counter label. It outlives one build (it is on the State, not
        /// the build arena), so the text it hands to `Text` stays valid for the
        /// frame that paints it.
        label_buf: [24]u8 = undefined,

        pub fn build(s: *State, ctx: *phantom.BuildContext) anyerror!phantom.Widget {
            const label = std.fmt.bufPrint(&s.label_buf, "Taps: {d}", .{s.taps}) catch "Taps: ?";
            const counter = ctx.new(phantom.Text{ .text = label, .size = 24 });

            const button_a = ctx.new(phantom.Button{
                .on_tap = onTap,
                .ctx = @ptrCast(s),
                .child = ctx.new(phantom.Text{ .text = "Button A" }).widget(),
            });
            const button_b = ctx.new(phantom.Button{
                .on_tap = onTap,
                .ctx = @ptrCast(s),
                .child = ctx.new(phantom.Text{ .text = "Button B" }).widget(),
            });

            // Taller than any real viewport, so the wheel, PageUp/PageDown, Home and
            // End all have somewhere to go once the ScrollView holds the focus.
            const scroll_children = ctx.newSlice(phantom.Widget, &.{
                button_a.widget(),
                spacer(ctx, 400),
                button_b.widget(),
            });
            const column = ctx.new(phantom.Column(.{ .children = scroll_children }));
            const scroll = ctx.new(phantom.ScrollView{ .child = column.widget() });

            // Tab order: the ScrollView itself, then button_a, then button_b. The
            // ScrollView is focusable and the focus walk is pre-order, so it is
            // visited before the buttons inside its own subtree, giving three Tab
            // stops in total rather than two.
            const top = ctx.newSlice(phantom.Widget, &.{
                counter.widget(),
                scroll.widget(),
            });
            return ctx.new(phantom.Column(.{ .children = top })).widget();
        }

        fn onTap(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            phantom.setState(s, incrementTaps);
        }

        fn incrementTaps(s: *State) void {
            s.taps += 1;
        }
    };
};

/// `ctx.new` stabilises the config in the build arena. A `Widget` only borrows a
/// pointer to its config, so a config left on this function's own stack frame
/// would dangle the moment it returns.
fn root(ctx: *phantom.BuildContext) phantom.Widget {
    const cfg = ctx.new(Root{});
    return phantom.StatefulWidget(Root, cfg);
}

pub fn main(init: std.process.Init) !void {
    try phantom.Tui.run(init, phantom.Root.plain(root), .{});
}
