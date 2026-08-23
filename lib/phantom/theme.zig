//! PhantomUI theme module. Provides Color helpers, Tokyo Night ColorScheme,
//! ThemeData, the Theme component widget, and Theme.of for resolving the
//! nearest ancestor theme from the element tree.
//! Direct imports are used instead of the top-level phantom.zig re-export so
//! that BuildOwner.zig can import this file without creating a circular dependency.
const std = @import("std");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;
const Element = widget_mod.Element;
const typeId = widget_mod.typeId;
const inheritedOf = widget_mod.inheritedOf;
const depthOf = widget_mod.depthOf;
const BuildContext = @import("BuildContext.zig");
const BuildOwner = @import("BuildOwner.zig");
const geom = @import("geometry.zig");
const Color = geom.Color;
const panic = @import("panic.zig").panic;
const Font = @import("text/Font.zig");
const builtin_fonts = @import("text/builtin.zig");

/// Parse a "#rrggbb" hex string to a Color at comptime.
pub fn hex(comptime s: []const u8) Color {
    const p = struct {
        fn v(comptime a: u8, comptime b: u8) f32 {
            const hi = std.fmt.charToDigit(a, 16) catch unreachable;
            const lo = std.fmt.charToDigit(b, 16) catch unreachable;
            return @as(f32, @floatFromInt(hi * 16 + lo)) / 255.0;
        }
    };
    return .{ .r = p.v(s[1], s[2]), .g = p.v(s[3], s[4]), .b = p.v(s[5], s[6]), .a = 1 };
}

pub const ColorScheme = struct {
    bg: Color,
    /// The recess behind a surface. Darker than `bg` so a panel drawn over the
    /// background stays visible without a border.
    bg_dark: Color,
    /// The raised surface between `bg` and `bg_dark`.
    bg_medium: Color,
    fg: Color,
    /// The brand's Primary body text. `fg` stays the brighter Bright.
    fg_primary: Color,
    fg_muted: Color,
    fg_dim: Color,
    blue: Color,
    blue_light: Color,
    cyan: Color,
    teal: Color,
    red: Color,
    red_dark: Color,
    green: Color,
    yellow: Color,
    orange: Color,
    purple: Color,
    purple_dark: Color,

    pub fn tokyoNight() ColorScheme {
        return .{
            .bg = hex("#1a1b26"),
            .bg_dark = hex("#16161e"),
            .bg_medium = hex("#1e202e"),
            .fg = hex("#c0caf5"),
            .fg_primary = hex("#a9b1d6"),
            .fg_muted = hex("#787c99"),
            .fg_dim = hex("#545c7e"),
            .blue = hex("#7aa2f7"),
            .blue_light = hex("#7dcfff"),
            .cyan = hex("#2ac3de"),
            .teal = hex("#73daca"),
            .red = hex("#f7768e"),
            .red_dark = hex("#db4b4b"),
            .green = hex("#9ece6a"),
            .yellow = hex("#e0af68"),
            .orange = hex("#ff9e64"),
            .purple = hex("#bb9af7"),
            .purple_dark = hex("#9d7cd8"),
        };
    }
};

pub const ThemeData = struct {
    colors: ColorScheme,
    heading_font: *Font,
    body_font: *Font,
    body_bold_font: *Font,
    text_size: f32,
    text_color: Color,
    /// The color that marks the focused or active element. A theme variant
    /// changes this without touching the rest of the scheme.
    accent: Color,
    /// Corner radius in logical units for panels and surfaces.
    radius: f32,
    /// Opacity of a panel drawn over the wallpaper. 0 is invisible, 1 is opaque.
    surface_alpha: f32,
};

/// The built-in Tokyo Night theme with Neuropol (heading) and Mesmerize Rg (body).
/// Instance-owned: fonts are loaded into the BuildOwner on first call and freed when
/// the owner deinits. Single-threaded per owner instance. No global state.
/// A font load failure is a corrupt-binary programmer error, routed through panic.
pub fn defaultTheme(owner: *BuildOwner) *const ThemeData {
    if (owner.default_theme != null) return &owner.default_theme.?;
    if (owner.default_heading_font == null) {
        owner.default_heading_font = Font.load(owner.gpa, builtin_fonts.neuropol_bytes) catch
            panic("default theme: Neuropol failed to load (corrupt embed)", .{});
    }
    if (owner.default_body_font == null) {
        owner.default_body_font = Font.load(owner.gpa, builtin_fonts.mesmerize_rg_bytes) catch
            panic("default theme: Mesmerize failed to load (corrupt embed)", .{});
    }
    if (owner.default_body_bold_font == null) {
        owner.default_body_bold_font = Font.load(owner.gpa, builtin_fonts.mesmerize_sb_bytes) catch
            panic("default theme: Mesmerize Sb failed to load (corrupt embed)", .{});
    }
    const colors = ColorScheme.tokyoNight();
    owner.default_theme = .{
        .colors = colors,
        .heading_font = &owner.default_heading_font.?,
        .body_font = &owner.default_body_font.?,
        .body_bold_font = &owner.default_body_bold_font.?,
        .text_size = 24,
        .text_color = colors.fg,
        .accent = colors.blue_light,
        .radius = 18,
        .surface_alpha = 0.72,
    };
    return &owner.default_theme.?;
}

pub const Theme = struct {
    data: *const ThemeData,
    child: Widget,

    const vtable = Widget.VTable{ .mount = mount, .update = update };

    pub fn widget(self: *const Theme) Widget {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The nearest ancestor ThemeData at the current build/mount point, else the
    /// built-in default (instance-owned via the BuildOwner).
    pub fn of(bctx: *BuildContext) *const ThemeData {
        return inheritedOf(bctx.element, ThemeData) orelse defaultTheme(bctx.owner);
    }

    fn mount(ptr: *const anyopaque, bctx: *BuildContext, parent: ?*Element) anyerror!*Element {
        const self: *const Theme = @ptrCast(@alignCast(ptr));
        const gpa = bctx.owner.gpa;
        const el = try gpa.create(Element);
        el.* = .{
            .owner = bctx.owner,
            .parent = parent,
            .vtable = &vtable,
            .type_name = @typeName(Theme),
            .render_object = null,
            .inherited_id = typeId(ThemeData),
            .inherited_data = self.data,
            .depth = depthOf(parent),
        };
        el.child = try el.updateChild(null, self.child, bctx);
        return el;
    }

    fn update(ptr: *const anyopaque, el: *Element, bctx: *BuildContext) anyerror!void {
        const self: *const Theme = @ptrCast(@alignCast(ptr));
        el.inherited_data = self.data;
        el.child = try el.updateChild(el.child, self.child, bctx);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const FaultSink = @import("FaultSink.zig");
const ColoredBox = @import("widgets/colored_box.zig").ColoredBox;

test "tokyoNight colors match the branding hex values" {
    const c = ColorScheme.tokyoNight();
    // bg #1a1b26 -> 26,27,38
    try std.testing.expectApproxEqAbs(@as(f32, 26.0 / 255.0), c.bg.r, 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 38.0 / 255.0), c.bg.b, 0.005);
    // blue #7aa2f7
    try std.testing.expectApproxEqAbs(@as(f32, 122.0 / 255.0), c.blue.r, 0.005);
}

test "defaultTheme loads built-in fonts and Tokyo Night colors" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    const t = defaultTheme(&owner);
    try std.testing.expect(t.text_size > 0);
    // Exercise the real cache path: glyph allocates into the owner's font cache
    // and is freed when owner.deinit() runs at the end of this test.
    const g = try t.body_font.glyph(owner.gpa, 'A', 24);
    try std.testing.expect(g.w > 0);
    try std.testing.expectEqual(t.colors.fg, t.text_color);
}

test "defaultTheme returns the same pointer on repeated calls (cache hit)" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    const t1 = defaultTheme(&owner);
    const t2 = defaultTheme(&owner);
    try std.testing.expect(t1 == t2);
}

test "defaultTheme body_bold_font is loaded and distinct from body_font" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    const t = defaultTheme(&owner);
    // body_bold_font must be non-null and point to a different Font instance than body_font
    try std.testing.expect(t.body_bold_font != t.body_font);
    // exercise a glyph load to confirm the font is functional
    const g = try t.body_bold_font.glyph(owner.gpa, 'A', 24);
    try std.testing.expect(g.w > 0);
}

test "defaultTheme body_bold_font is instance-scoped (two owners get independent caches)" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner1 = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner1.deinit();
    var owner2 = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner2.deinit();
    const t1 = defaultTheme(&owner1);
    const t2 = defaultTheme(&owner2);
    // each owner has its own Font allocation so the pointers must differ
    try std.testing.expect(t1.body_bold_font != t2.body_bold_font);
    try std.testing.expect(t1.body_font != t2.body_font);
}

test "Theme.of returns the default when unwrapped and the ancestor data when wrapped" {
    const gpa = std.testing.allocator;
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bctx = BuildContext{ .arena = arena.allocator(), .owner = &owner };
    // unwrapped: default
    try std.testing.expect(Theme.of(&bctx) == defaultTheme(&owner));
    // wrapped: a Theme wrapping a ColoredBox; from the child element, Theme.of finds it
    var custom = defaultTheme(&owner).*; // copy
    custom.text_size = 99;
    var box = ColoredBox{ .color = Color.rgb(0, 0, 1), .radius = 0 };
    var th = Theme{ .data = &custom, .child = box.widget() };
    const el = try th.widget().mount(&bctx, null);
    defer el.deinit(gpa);
    // the Theme element carries the inherited slot; its child can find it
    try std.testing.expectEqual(@as(f32, 99), inheritedOf(el.child, ThemeData).?.text_size);
}

test "tokyoNight carries the four board swatches the nine roles omit" {
    const c = ColorScheme.tokyoNight();
    try std.testing.expectEqual(hex("#16161e"), c.bg_dark);
    try std.testing.expectEqual(hex("#7dcfff"), c.blue_light);
    try std.testing.expectEqual(hex("#2ac3de"), c.cyan);
    try std.testing.expectEqual(hex("#ff9e64"), c.orange);
}

test "bg_dark is darker than bg so a surface over the background is visible" {
    const c = ColorScheme.tokyoNight();
    try std.testing.expect(c.bg_dark.r < c.bg.r);
    try std.testing.expect(c.bg_dark.g < c.bg.g);
    try std.testing.expect(c.bg_dark.b < c.bg.b);
}

test "defaultTheme accents with blue_light and carries the Aurora shape" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();

    const data = defaultTheme(&owner);
    try std.testing.expectEqual(hex("#7dcfff"), data.accent);
    try std.testing.expectEqual(@as(f32, 18), data.radius);
    try std.testing.expectEqual(@as(f32, 0.72), data.surface_alpha);
}

test "surface_alpha stays inside the 0 to 1 range the compositor blends with" {
    var sink = FaultSink{};
    var owner = BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();

    const data = defaultTheme(&owner);
    try std.testing.expect(data.surface_alpha > 0);
    try std.testing.expect(data.surface_alpha <= 1);
}

test "tokyoNight carries every colour the Midstall brand palette defines" {
    // Source: branding/pkgs/midstall-color-palette/colors.toml
    const c = ColorScheme.tokyoNight();
    try std.testing.expectEqual(hex("#1e202e"), c.bg_medium);
    try std.testing.expectEqual(hex("#a9b1d6"), c.fg_primary);
    try std.testing.expectEqual(hex("#73daca"), c.teal);
    try std.testing.expectEqual(hex("#9d7cd8"), c.purple_dark);
    try std.testing.expectEqual(hex("#db4b4b"), c.red_dark);
}

test "fg stays the brand's Bright, not its Primary" {
    // Deliberate: fg was NOT renamed. The brand calls #c0caf5 "Bright" and
    // #a9b1d6 "Primary". Phantom keeps fg meaning Bright so no existing code
    // moves, and Primary arrives as fg_primary. Pinned so a later "tidy up"
    // does not silently darken every app's default text.
    const c = ColorScheme.tokyoNight();
    try std.testing.expectEqual(hex("#c0caf5"), c.fg);
    try std.testing.expect(!std.meta.eql(c.fg, c.fg_primary));
}

test "bg_medium sits between bg and bg_dark" {
    // The three backgrounds must order darkest to lightest or a raised
    // surface drawn on bg_medium would disappear into the background.
    const c = ColorScheme.tokyoNight();
    try std.testing.expect(c.bg_dark.r < c.bg.r);
    try std.testing.expect(c.bg.r < c.bg_medium.r);
}
