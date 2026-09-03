//! PhantomUI: zero-C-dependency, Zig-only UI framework.
const std = @import("std");

pub const version = "0.1.0";

pub const geometry = @import("phantom/geometry.zig");
pub const Color = geometry.Color;
pub const LogicalSize = geometry.LogicalSize;
pub const LogicalOffset = geometry.LogicalOffset;
pub const LogicalRect = geometry.LogicalRect;
pub const LogicalEdgeInsets = geometry.LogicalEdgeInsets;
pub const PhysicalSize = geometry.PhysicalSize;
pub const PhysicalOffset = geometry.PhysicalOffset;
pub const PhysicalRect = geometry.PhysicalRect;
pub const PhysicalEdgeInsets = geometry.PhysicalEdgeInsets;

pub const layout = @import("phantom/layout.zig");
pub const BoxConstraints = layout.BoxConstraints;

pub const display_list = @import("phantom/display_list.zig");
pub const DisplayList = display_list.DisplayList;
pub const Primitive = display_list.Primitive;
pub const canvas = @import("phantom/canvas.zig");
pub const Canvas = canvas.Canvas;

pub const render_object = @import("phantom/render_object.zig");
pub const RenderObject = render_object.RenderObject;

pub const widget = @import("phantom/widget.zig");
pub const Widget = widget.Widget;
pub const Element = widget.Element;
pub const typeId = widget.typeId;
pub const inheritedOf = widget.inheritedOf;

pub const widgets = struct {
    pub const colored_box = @import("phantom/widgets/colored_box.zig");
    pub const ColoredBox = colored_box.ColoredBox;
    pub const padding = @import("phantom/widgets/padding.zig");
    pub const Padding = padding.Padding;
    pub const error_box = @import("phantom/widgets/error_box.zig");
    pub const ErrorBox = error_box.ErrorBox;
    pub const text_widget = @import("phantom/widgets/text.zig");
    pub const Text = text_widget.Text;
    pub const flex = @import("phantom/widgets/flex.zig");
    pub const Axis = flex.Axis;
    pub const MainAxisAlignment = flex.MainAxisAlignment;
    pub const CrossAxisAlignment = flex.CrossAxisAlignment;
    pub const FlexFit = flex.FlexFit;
    pub const Flex = flex.Flex;
    pub const Column = flex.Column;
    pub const Row = flex.Row;
    pub const Flexible = flex.Flexible;
    pub const Expanded = flex.Expanded;
    pub const stack = @import("phantom/widgets/stack.zig");
    pub const Stack = stack.Stack;
    pub const Positioned = stack.Positioned;
    // `align` is a Zig keyword, so the module cannot take the bare name.
    pub const align_widget = @import("phantom/widgets/align.zig");
    pub const Alignment = align_widget.Alignment;
    pub const Align = align_widget.Align;
    pub const Center = align_widget.Center;
    pub const SizedBox = align_widget.SizedBox;
    pub const listener = @import("phantom/widgets/listener.zig");
    pub const Listener = listener.Listener;
    pub const focus_widget = @import("phantom/widgets/focus.zig");
    pub const Focus = focus_widget.Focus;
    pub const keyboard_listener = @import("phantom/widgets/keyboard_listener.zig");
    pub const KeyboardListener = keyboard_listener.KeyboardListener;
    pub const gesture_detector = @import("phantom/widgets/gesture_detector.zig");
    pub const GestureDetector = gesture_detector.GestureDetector;
    pub const button = @import("phantom/widgets/button.zig");
    pub const Button = button.Button;
    pub const decorated_box = @import("phantom/widgets/decorated_box.zig");
    pub const DecoratedBox = decorated_box.DecoratedBox;
    pub const scroll_view = @import("phantom/widgets/scroll_view.zig");
    pub const ScrollView = scroll_view.ScrollView;
    pub const ScrollController = scroll_view.ScrollController;
    pub const image_widget = @import("phantom/widgets/image.zig");
    pub const Image = image_widget.Image;
    pub const icon_widget = @import("phantom/widgets/icon.zig");
    pub const Icon = icon_widget.Icon;
    pub const text_field = @import("phantom/widgets/text_field.zig");
    pub const TextField = text_field.TextField;
    pub const clip_rrect = @import("phantom/widgets/clip_rrect.zig");
    pub const ClipRRect = clip_rrect.ClipRRect;
    pub const grid_view = @import("phantom/widgets/grid_view.zig");
    pub const GridView = grid_view.GridView;
};
pub const ColoredBox = widgets.ColoredBox;
pub const Padding = widgets.Padding;
pub const ErrorBox = widgets.ErrorBox;
pub const Text = widgets.Text;
pub const Flex = widgets.Flex;
pub const FlexFit = widgets.FlexFit;
pub const Column = widgets.Column;
pub const Row = widgets.Row;
pub const Flexible = widgets.Flexible;
pub const Expanded = widgets.Expanded;
pub const Axis = widgets.Axis;
pub const MainAxisAlignment = widgets.MainAxisAlignment;
pub const CrossAxisAlignment = widgets.CrossAxisAlignment;
pub const Stack = widgets.Stack;
pub const Positioned = widgets.Positioned;
pub const Alignment = widgets.Alignment;
pub const Align = widgets.Align;
pub const Center = widgets.Center;
pub const SizedBox = widgets.SizedBox;
pub const Listener = widgets.Listener;
pub const Focus = widgets.Focus;
pub const KeyboardListener = widgets.KeyboardListener;
pub const GestureDetector = widgets.GestureDetector;
pub const Button = widgets.Button;
pub const DecoratedBox = widgets.DecoratedBox;
pub const ScrollView = widgets.ScrollView;
pub const ScrollController = widgets.ScrollController;
pub const Image = widgets.Image;
pub const Icon = widgets.Icon;
pub const TextField = widgets.TextField;
pub const ClipRRect = widgets.ClipRRect;
pub const GridView = widgets.GridView;

pub const backend = struct {
    pub const dom = @import("phantom/backend/dom.zig");
    pub const prism = @import("phantom/backend/prism.zig");
    pub const PrismBackend = prism.PrismBackend;
    pub const dom_calls = @import("phantom/backend/dom_calls.zig");
    pub const cell_grid = @import("phantom/backend/cell_grid.zig");
    pub const tui_cells = @import("phantom/backend/tui_cells.zig");
    pub const tui_pixels = @import("phantom/backend/tui_pixels.zig");
};

pub const DomOps = backend.dom_calls.DomOps;

pub const BuildContext = @import("phantom/BuildContext.zig");
pub const BuildOwner = @import("phantom/BuildOwner.zig");

pub const stateful = @import("phantom/stateful.zig");
pub const setState = stateful.setState;
pub const markNeedsBuild = stateful.markNeedsBuild;
pub const StatefulWidget = stateful.statefulWidget;
pub const StateBase = widget.StateBase;

pub const FaultSink = @import("phantom/FaultSink.zig");
pub const FaultCode = FaultSink.FaultCode;
pub const Fault = FaultSink.Fault;

pub const panic = @import("phantom/panic.zig").panic;
pub const setPanicHook = @import("phantom/panic.zig").setHook;

pub const window = @import("phantom/window.zig");

pub const root = @import("phantom/root.zig");
pub const Root = root.Root;

pub const app = @import("phantom/app.zig");
pub const App = app.App;

pub const tui = @import("phantom/tui.zig");
pub const Tui = tui.Tui;

pub const testing = @import("phantom/testing.zig");

pub const web = @import("phantom/web.zig");
pub const web_net = @import("phantom/web_net.zig");

pub const text = @import("phantom/text.zig");

pub const icon = @import("phantom/icon.zig");

pub const image = @import("phantom/image/Image.zig");
pub const png = @import("phantom/image/png.zig");
pub const jpeg = @import("phantom/image/jpeg.zig");

pub const theme = @import("phantom/theme.zig");
pub const Theme = theme.Theme;
pub const ThemeData = theme.ThemeData;
pub const ColorScheme = theme.ColorScheme;

pub const router = @import("phantom/router.zig");
pub const Router = router.Router;
pub const Route = router.Route;
pub const RouteLink = router.RouteLink;
pub const RouterHandle = router.RouterHandle;

pub const platform = @import("phantom/platform.zig");
pub const Platform = platform.Platform;
pub const UrlStrategy = platform.UrlStrategy;
pub const WriteMode = platform.WriteMode;
pub const link_widget = @import("phantom/widgets/link.zig");
pub const Link = link_widget.Link;

pub const view = @import("phantom/view.zig");
pub const View = view.View;
pub const MediaQueryData = view.MediaQueryData;
pub const MediaQuery = @import("phantom/widgets/media_query.zig").MediaQuery;

pub const pointer = @import("phantom/pointer.zig");
pub const PointerEvent = pointer.PointerEvent;
pub const PointerHandlers = pointer.PointerHandlers;
pub const input = @import("phantom/input.zig");

pub const focus = @import("phantom/focus.zig");
pub const FocusHandlers = focus.FocusHandlers;
pub const FocusManager = focus.FocusManager;

pub const scheduler = @import("phantom/scheduler.zig");
pub const Scheduler = scheduler.Scheduler;

pub const ticker = @import("phantom/ticker.zig");
pub const Ticker = ticker.Ticker;

pub const tween = @import("phantom/tween.zig");
pub const Tween = tween.Tween;
pub const Curve = tween.Curve;

test "phantom module has a version" {
    try std.testing.expect(version.len > 0);
}

test {
    std.testing.refAllDecls(@This());
    // refAllDecls does not recurse into nested namespaces, so reference each
    // `backend` submodule explicitly to pull its tests into the run. When Plan B
    // adds backend.prism, add `_ = backend.prism;` here too or its tests will not run.
    _ = backend.dom;
    _ = backend.prism;
    _ = backend.dom_calls;
    _ = @import("phantom/backend/glyph_atlas.zig");
    _ = @import("phantom/panic.zig");
    _ = @import("phantom/BuildOwner.zig");
    _ = @import("phantom/stateful.zig");
    _ = @import("phantom/text.zig");
    _ = @import("phantom/icon/path.zig");
    _ = @import("phantom/icon/stroke.zig");
    _ = @import("phantom/icon/builtin.zig");
    _ = @import("phantom/widgets/icon.zig");
    _ = @import("phantom/text/builtin.zig");
    _ = @import("phantom/text/sfnt.zig");
    _ = @import("phantom/text/metrics.zig");
    _ = @import("phantom/text/outline.zig");
    _ = @import("phantom/text/glyf.zig");
    _ = @import("phantom/text/cff.zig");
    _ = @import("phantom/text/raster.zig");
    _ = @import("phantom/text/Font.zig");
    _ = @import("phantom/text/GlyphCache.zig");
    _ = @import("phantom/text/layout.zig");
    _ = @import("phantom/widgets/text.zig");
    _ = @import("phantom/theme.zig");
    _ = @import("phantom/view.zig");
    _ = @import("phantom/widgets/media_query.zig");
    _ = @import("phantom/widgets/flex.zig");
    _ = @import("phantom/widgets/stack.zig");
    _ = @import("phantom/widgets/align.zig");
    _ = @import("phantom/pointer.zig");
    _ = @import("phantom/input.zig");
    _ = @import("phantom/widgets/listener.zig");
    _ = @import("phantom/widgets/gesture_detector.zig");
    _ = @import("phantom/widgets/button.zig");
    _ = @import("phantom/widgets/decorated_box.zig");
    _ = @import("phantom/widgets/scroll_view.zig");
    _ = @import("phantom/image/Image.zig");
    _ = @import("phantom/image/png.zig");
    _ = @import("phantom/image/jpeg.zig");
    _ = @import("phantom/widgets/image.zig");
    _ = @import("phantom/scheduler.zig");
    _ = @import("phantom/ticker.zig");
    _ = @import("phantom/tween.zig");
    _ = @import("phantom/widgets/text_field.zig");
    _ = @import("phantom/widgets/clip_rrect.zig");
    _ = @import("phantom/widgets/grid_view.zig");
    _ = @import("phantom/tui/ansi.zig");
    _ = @import("phantom/tui/term.zig");
    _ = @import("phantom/tui/caps.zig");
    _ = @import("phantom/tui.zig");
    _ = @import("phantom/text/mono.zig");
    _ = @import("phantom/backend/cell_grid.zig");
    _ = @import("phantom/backend/tui_cells.zig");
    _ = @import("phantom/tui/decode.zig");
    _ = @import("phantom/focus.zig");
    _ = @import("phantom/widgets/focus.zig");
    _ = @import("phantom/widgets/keyboard_listener.zig");
    _ = @import("phantom/tui/kitty_gfx.zig");
    _ = @import("phantom/backend/tui_pixels.zig");
    _ = @import("phantom/router.zig");
    _ = @import("phantom/platform.zig");
    _ = @import("phantom/widgets/link.zig");
    _ = @import("phantom/web_net.zig");
}
