const std = @import("std");
const phantom = @import("phantom");

const logo_png = @embedFile("logo.png");
// A downscaled PNG re-encoded from the pure-Zig progressive JPEG decoder's output
// (the original is a 6512x4341 progressive JPEG; embedding + texturing that full-res
// is too heavy, so the demo shows a downscaled copy). Renders natively via the PNG
// decoder and on web via an <img> data URL.
const wallpaper_png = @embedFile("wallpaper.png");

const Counter = struct {
    pub const State = struct {
        base: phantom.StateBase = .{},
        count: u32 = 0,

        fn inc(s: *@This()) void {
            s.count += 1;
        }

        fn incTap(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            phantom.setState(s, Counter.State.inc);
        }

        pub fn build(s: *@This(), b: *phantom.BuildContext) anyerror!phantom.Widget {
            const label_text = try std.fmt.allocPrint(b.arena, "{d}", .{s.count});
            const label = b.new(phantom.Text{
                .text = label_text,
                .size = 96,
            });

            const theme = phantom.Theme.of(b);

            const plus = b.new(phantom.Text{
                .text = "+",
                .font = theme.body_bold_font,
                .size = 14,
                .color = phantom.Color.rgb(1, 1, 1),
            });

            const btn = b.new(phantom.Button{
                .on_tap = Counter.State.incTap,
                .ctx = s,
                .child = plus.widget(),
            });

            const kids = b.newSlice(phantom.Widget, &.{
                label.widget(),
                btn.widget(),
            });

            return b.new(phantom.Column(.{
                .main = .center,
                .cross = .center,
                .children = kids,
            })).widget();
        }
    };
    pub fn widget(self: *const Counter) phantom.Widget {
        return phantom.StatefulWidget(Counter, self);
    }
};

// A display-only scrollable list of 100 numbered items (clearly overflows any
// window so it actually scrolls). Vertical ScrollView, v1 scroll content is
// display-only per the scroll-core design.
fn buildScrollList(b: *phantom.BuildContext) anyerror!phantom.Widget {
    var list_items: [100]phantom.Widget = undefined;
    for (&list_items, 0..) |*item, i| {
        const txt = try std.fmt.allocPrint(b.arena, "Item {d}", .{i + 1});
        item.* = b.new(phantom.Text{ .text = txt, .size = 18 }).widget();
    }
    const list_children = b.newSlice(phantom.Widget, &list_items);
    const list_col = b.new(phantom.Column(.{
        .main = .start,
        .cross = .start,
        .children = list_children,
    }));
    return b.new(phantom.ScrollView{ .child = list_col.widget() }).widget();
}

pub fn root(b: *phantom.BuildContext) phantom.Widget {
    // Slice-1 scroll demo: a full-window vertical scrolling list. Composing the
    // counter beside a fixed-size scroll region needs bounded sub-regions
    // (Expanded / SizedBox), a near-term layout-primitives addition; a plain
    // Column/Row lets each child fill the axis, which shoves the ScrollView
    // off-screen. So for now the scroll list fills the window on its own.
    //
    // Images slice demo: Image widgets decoded natively by the pure-Zig decoders
    // (PNG + baseline/progressive JPEG) and on web via <img> data URLs. The logo
    // is a 4x4 PNG scaled to 64x64; the wallpaper is a downscaled re-encode of the
    // progressive-JPEG-decoded 6512x4341 image, shown at 480x320 logical units.
    const logo = b.new(phantom.Image{
        .bytes = logo_png,
        .width = 64,
        .height = 64,
    });
    const wallpaper = b.new(phantom.Image{
        .bytes = wallpaper_png,
        .width = 480,
        .height = 320,
    });
    const scroll = buildScrollList(b) catch |e| return b.new(phantom.Text{
        .text = @errorName(e),
        .size = 14,
    }).widget();
    const kids = b.newSlice(phantom.Widget, &.{
        logo.widget(),
        wallpaper.widget(),
        scroll,
    });
    return b.new(phantom.Column(.{
        .main = .start,
        .cross = .start,
        .children = kids,
    })).widget();
}
