const std = @import("std");
const phantom = @import("phantom");

// No explicit font or color: the theme (Tokyo Night + Neuropol body font) supplies them.
// b.new arena-stabilises each config so the Widget ptr does not dangle after root returns.
pub fn root(b: *phantom.BuildContext) phantom.Widget {
    const label = b.new(phantom.Text{ .text = "Hello Phantom", .size = 48 });
    return b.new(phantom.Padding{
        .insets = phantom.LogicalEdgeInsets.all(40),
        .child = label.widget(),
    }).widget();
}

pub fn main(init: std.process.Init) !void {
    try phantom.App.run(init, phantom.Root.plain(root));
}
