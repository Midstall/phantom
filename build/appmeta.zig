const std = @import("std");

pub const Category = enum {
    audio_video,
    audio,
    video,
    development,
    education,
    game,
    graphics,
    network,
    office,
    science,
    settings,
    system,
    utility,

    pub fn desktopName(self: Category) []const u8 {
        return switch (self) {
            .audio_video => "AudioVideo",
            .audio => "Audio",
            .video => "Video",
            .development => "Development",
            .education => "Education",
            .game => "Game",
            .graphics => "Graphics",
            .network => "Network",
            .office => "Office",
            .science => "Science",
            .settings => "Settings",
            .system => "System",
            .utility => "Utility",
        };
    }
    // AppStream uses the same freedesktop category tokens.
    pub fn appstreamName(self: Category) []const u8 {
        return self.desktopName();
    }
};

pub const LocalizedText = struct {
    default: []const u8,
    locales: []const Locale = &.{},
    pub const Locale = struct { lang: []const u8, text: []const u8 };
};

pub const Icon = struct { path: std.Build.LazyPath, size: u32 };

/// How a route appears in the address bar. `.hash` works on any static host
/// with no configuration. `.path` needs a host that serves the application
/// for an unknown path, or the copies that `prerender_routes` writes.
pub const UrlStrategy = enum { hash, path };

pub const AppOptions = struct {
    id: []const u8,
    /// The binary name. Defaults to the last dotted segment of `id`. Set this
    /// when the executable a user types differs from the reverse DNS id, for
    /// example id `com.expidusos.genesis` with binary `genesis-shell`.
    exec_name: ?[]const u8 = null,
    name: LocalizedText,
    summary: LocalizedText = .{ .default = "" },
    description: LocalizedText = .{ .default = "" },
    categories: []const Category = &.{},
    keywords: []const LocalizedText = &.{},
    icons: []const Icon = &.{},
    root: std.Build.LazyPath,
    developer: []const u8 = "",
    license: []const u8 = "",
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    web_runtime: WebRuntime = .auto,
    url_strategy: UrlStrategy = .hash,
};

/// The binary name for an app. Borrows both arguments and returns a slice into
/// one of them, so the result lives exactly as long as its input.
pub fn resolveExecName(id: []const u8, exec_name: ?[]const u8) []const u8 {
    if (exec_name) |name| {
        std.debug.assert(name.len > 0); // an empty override is a caller bug
        return name;
    }
    var it = std.mem.splitBackwardsScalar(u8, id, '.');
    const last = it.first();
    // A trailing dot leaves an empty final segment, which would name the
    // artifact "" and break the desktop file's Exec= line.
    return if (last.len > 0) last else "app";
}

pub const WebRuntime = enum { auto, bun, deno, node, tsc, prebuilt };
pub const Strategy = enum { bun, deno, tsc, prebuilt };
pub const Avail = struct {
    bun: bool = false,
    deno: bool = false,
    node: bool = false,
    tsc: bool = false,
    /// True when the dependency ships a committed `dist/index.js`. Most
    /// versions do not: `npm/.gitignore` ignores `dist/`, so the default path
    /// compiles the TypeScript source instead of copying a file that is not
    /// there.
    prebuilt: bool = false,
};

/// Pick the web-runtime build strategy. `.auto` copies the dependency's
/// committed `dist` when there is one (offline, no compile step), and
/// otherwise compiles the TypeScript source with tsc. The bun and deno
/// single-file bundlers mangle this dep's pure-re-export entry (they drop the
/// definitions and emit a nameless `export {...}`, which the browser rejects
/// with "local binding for export 'createHost' not found"), so single-file
/// bundling is opt-in only via an explicit .bun / .deno. An explicit runtime
/// forces that strategy and fails if the runtime is not present.
pub fn resolveStrategy(want: WebRuntime, have: Avail) error{RuntimeNotFound}!Strategy {
    return switch (want) {
        .auto => if (have.prebuilt) .prebuilt else if (have.tsc) .tsc else error.RuntimeNotFound,
        .bun => if (have.bun) .bun else error.RuntimeNotFound,
        .deno => if (have.deno) .deno else error.RuntimeNotFound,
        .node => if (have.node) .prebuilt else error.RuntimeNotFound,
        .tsc => if (have.tsc) .tsc else error.RuntimeNotFound,
        .prebuilt => .prebuilt,
    };
}

/// The HTML module import path for a strategy: single-file for bun/deno, the
/// multi-file dist index for tsc and the prebuilt copy (tsc's `--outDir`
/// mirrors the prebuilt layout, so the page needs no strategy-specific case).
pub fn importPathFor(s: Strategy) []const u8 {
    return switch (s) {
        .bun, .deno => "./webidl-runtime.js",
        .tsc, .prebuilt => "./webidl-runtime/index.js",
    };
}

/// Escape a value for XML content or a double-quoted attribute.
fn xmlEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (s) |ch| switch (ch) {
        '&' => try buf.appendSlice(gpa, "&amp;"),
        '<' => try buf.appendSlice(gpa, "&lt;"),
        '>' => try buf.appendSlice(gpa, "&gt;"),
        '"' => try buf.appendSlice(gpa, "&quot;"),
        '\'' => try buf.appendSlice(gpa, "&apos;"),
        else => try buf.append(gpa, ch),
    };
    return buf.toOwnedSlice(gpa);
}

/// Escape a value for a freedesktop .desktop string: backslash and control chars.
/// (List values use ';' as a separator, but the values we emit here are plain
/// strings, so only the backslash and control-char escapes are needed.)
fn desktopEscape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (s) |ch| switch (ch) {
        '\\' => try buf.appendSlice(gpa, "\\\\"),
        '\n' => try buf.appendSlice(gpa, "\\n"),
        '\r' => try buf.appendSlice(gpa, "\\r"),
        '\t' => try buf.appendSlice(gpa, "\\t"),
        else => try buf.append(gpa, ch),
    };
    return buf.toOwnedSlice(gpa);
}

/// The vendor/developer reverse-DNS domain: the app id minus its last segment
/// (org.example.phantom.demo -> org.example.phantom). AppStream's developer id
/// is the vendor domain, not the full application id.
fn vendorId(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '.')) |i| return id[0..i];
    return id;
}

/// Generate the freedesktop .desktop file text. `exec` is the installed binary name.
pub fn desktopFile(gpa: std.mem.Allocator, opts: AppOptions, exec: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "[Desktop Entry]\nType=Application\n");
    try appendLocalized(gpa, &buf, "Name", opts.name);
    if (opts.summary.default.len > 0) try appendLocalized(gpa, &buf, "Comment", opts.summary);
    try appendKV(gpa, &buf, "Exec", exec);
    try appendKV(gpa, &buf, "Icon", opts.id);
    if (opts.categories.len > 0) {
        try buf.appendSlice(gpa, "Categories=");
        for (opts.categories) |c| {
            try buf.appendSlice(gpa, c.desktopName());
            try buf.append(gpa, ';');
        }
        try buf.append(gpa, '\n');
    }
    return buf.toOwnedSlice(gpa);
}

fn appendKV(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
    const esc = try desktopEscape(gpa, val);
    defer gpa.free(esc);
    const line = try std.fmt.allocPrint(gpa, "{s}={s}\n", .{ key, esc });
    defer gpa.free(line);
    try buf.appendSlice(gpa, line);
}

fn appendLocalized(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, t: LocalizedText) !void {
    try appendKV(gpa, buf, key, t.default);
    for (t.locales) |loc| {
        const esc = try desktopEscape(gpa, loc.text);
        defer gpa.free(esc);
        const line = try std.fmt.allocPrint(gpa, "{s}[{s}]={s}\n", .{ key, loc.lang, esc });
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
}

/// Generate the AppStream metainfo XML.
pub fn metainfoXml(gpa: std.mem.Allocator, opts: AppOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<component type=\"desktop-application\">\n");
    try xmlTag(gpa, &buf, "id", opts.id);
    try xmlLocalized(gpa, &buf, "name", opts.name);
    // summary is required but must be non-empty; skip it if the consumer left it blank.
    if (opts.summary.default.len > 0) try xmlLocalized(gpa, &buf, "summary", opts.summary);
    // metadata_license is required for every component (licenses the metainfo file itself).
    try xmlTag(gpa, &buf, "metadata_license", "CC0-1.0");
    if (opts.license.len > 0) try xmlTag(gpa, &buf, "project_license", opts.license);
    if (opts.developer.len > 0) {
        const vesc = try xmlEscape(gpa, vendorId(opts.id));
        defer gpa.free(vesc);
        const nesc = try xmlEscape(gpa, opts.developer);
        defer gpa.free(nesc);
        const d = try std.fmt.allocPrint(gpa, "  <developer id=\"{s}\"><name>{s}</name></developer>\n", .{ vesc, nesc });
        defer gpa.free(d);
        try buf.appendSlice(gpa, d);
    }
    if (opts.description.default.len > 0) {
        const desc = try xmlEscape(gpa, opts.description.default);
        defer gpa.free(desc);
        const d = try std.fmt.allocPrint(gpa, "  <description><p>{s}</p></description>\n", .{desc});
        defer gpa.free(d);
        try buf.appendSlice(gpa, d);
    }
    if (opts.categories.len > 0) {
        try buf.appendSlice(gpa, "  <categories>\n");
        for (opts.categories) |c| {
            const line = try std.fmt.allocPrint(gpa, "    <category>{s}</category>\n", .{c.appstreamName()});
            defer gpa.free(line);
            try buf.appendSlice(gpa, line);
        }
        try buf.appendSlice(gpa, "  </categories>\n");
    }
    const idesc = try xmlEscape(gpa, opts.id);
    defer gpa.free(idesc);
    const launch = try std.fmt.allocPrint(gpa, "  <launchable type=\"desktop-id\">{s}.desktop</launchable>\n", .{idesc});
    defer gpa.free(launch);
    try buf.appendSlice(gpa, launch);
    try buf.appendSlice(gpa, "</component>\n");
    return buf.toOwnedSlice(gpa);
}

fn xmlTag(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), tag: []const u8, val: []const u8) !void {
    const esc = try xmlEscape(gpa, val);
    defer gpa.free(esc);
    const line = try std.fmt.allocPrint(gpa, "  <{s}>{s}</{s}>\n", .{ tag, esc, tag });
    defer gpa.free(line);
    try buf.appendSlice(gpa, line);
}

fn xmlLocalized(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), tag: []const u8, t: LocalizedText) !void {
    try xmlTag(gpa, buf, tag, t.default);
    for (t.locales) |loc| {
        const esc = try xmlEscape(gpa, loc.text);
        defer gpa.free(esc);
        const line = try std.fmt.allocPrint(gpa, "  <{s} xml:lang=\"{s}\">{s}</{s}>\n", .{ tag, loc.lang, esc, tag });
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
}

test "Category maps to freedesktop tokens" {
    try std.testing.expectEqualStrings("AudioVideo", Category.audio_video.desktopName());
    try std.testing.expectEqualStrings("Utility", Category.utility.appstreamName());
}

test "desktopFile emits Name, i18n, Exec, Icon, Categories" {
    const gpa = std.testing.allocator;
    const opts = AppOptions{
        .id = "org.example.app",
        .name = .{ .default = "Example", .locales = &.{.{ .lang = "de", .text = "Beispiel" }} },
        .summary = .{ .default = "A demo" },
        .categories = &.{ .utility, .graphics },
        .root = undefined,
        .target = undefined,
        .optimize = .Debug,
    };
    const text = try desktopFile(gpa, opts, "example-app");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Name=Example\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Name[de]=Beispiel\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Exec=example-app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Icon=org.example.app\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Categories=Utility;Graphics;\n") != null);
}

test "metainfoXml emits id, name, launchable, categories" {
    const gpa = std.testing.allocator;
    const opts = AppOptions{
        .id = "org.example.app",
        .name = .{ .default = "Example" },
        .summary = .{ .default = "A demo" },
        .description = .{ .default = "Longer." },
        .categories = &.{.utility},
        .license = "MIT",
        .developer = "Example Inc",
        .root = undefined,
        .target = undefined,
        .optimize = .Debug,
    };
    const xml = try metainfoXml(gpa, opts);
    defer gpa.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<id>org.example.app</id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<name>Example</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<launchable type=\"desktop-id\">org.example.app.desktop</launchable>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<category>Utility</category>") != null);
}

test "metainfoXml always emits metadata_license, escapes XML, skips empty summary" {
    const gpa = std.testing.allocator;
    const opts = AppOptions{
        .id = "org.example.app",
        .name = .{ .default = "A & B <tag>" },
        .summary = .{ .default = "" }, // empty -> skipped
        .root = undefined,
        .target = undefined,
        .optimize = .Debug,
    };
    const xml = try metainfoXml(gpa, opts);
    defer gpa.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<metadata_license>CC0-1.0</metadata_license>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<name>A &amp; B &lt;tag&gt;</name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<summary>") == null);
}

test "metainfoXml developer id is the vendor domain, not the app id" {
    const gpa = std.testing.allocator;
    const opts = AppOptions{
        .id = "org.example.phantom.demo",
        .name = .{ .default = "Demo" },
        .developer = "Example",
        .root = undefined,
        .target = undefined,
        .optimize = .Debug,
    };
    const xml = try metainfoXml(gpa, opts);
    defer gpa.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<developer id=\"org.example.phantom\">") != null);
}

test "resolveStrategy: auto prefers the committed dist and falls back to tsc" {
    try std.testing.expectEqual(Strategy.prebuilt, try resolveStrategy(.auto, .{ .bun = true, .deno = true, .node = true, .prebuilt = true }));
    try std.testing.expectEqual(Strategy.prebuilt, try resolveStrategy(.auto, .{ .deno = true, .node = true, .prebuilt = true }));
    // No committed dist: auto falls back to compiling with tsc.
    try std.testing.expectEqual(Strategy.tsc, try resolveStrategy(.auto, .{ .node = true, .tsc = true }));
    try std.testing.expectEqual(Strategy.tsc, try resolveStrategy(.auto, .{ .tsc = true }));
    // Neither the dist nor tsc is available: auto has nothing to build with.
    try std.testing.expectError(error.RuntimeNotFound, resolveStrategy(.auto, .{}));
}

test "resolveStrategy: explicit forces and errors if the runtime is absent" {
    try std.testing.expectEqual(Strategy.bun, try resolveStrategy(.bun, .{ .bun = true }));
    try std.testing.expectError(error.RuntimeNotFound, resolveStrategy(.bun, .{}));
    try std.testing.expectEqual(Strategy.deno, try resolveStrategy(.deno, .{ .deno = true }));
    try std.testing.expectError(error.RuntimeNotFound, resolveStrategy(.deno, .{}));
    // node uses the prebuilt copy for the build, but requires node to be present
    try std.testing.expectEqual(Strategy.prebuilt, try resolveStrategy(.node, .{ .node = true }));
    try std.testing.expectError(error.RuntimeNotFound, resolveStrategy(.node, .{}));
    try std.testing.expectEqual(Strategy.tsc, try resolveStrategy(.tsc, .{ .tsc = true }));
    try std.testing.expectError(error.RuntimeNotFound, resolveStrategy(.tsc, .{}));
    // prebuilt always succeeds
    try std.testing.expectEqual(Strategy.prebuilt, try resolveStrategy(.prebuilt, .{}));
}

test "importPathFor: single-file vs multi-file" {
    try std.testing.expectEqualStrings("./webidl-runtime.js", importPathFor(.bun));
    try std.testing.expectEqualStrings("./webidl-runtime.js", importPathFor(.deno));
    try std.testing.expectEqualStrings("./webidl-runtime/index.js", importPathFor(.tsc));
    try std.testing.expectEqualStrings("./webidl-runtime/index.js", importPathFor(.prebuilt));
}

test "resolveExecName falls back to the last dotted segment of the id" {
    try std.testing.expectEqualStrings("myapp", resolveExecName("org.example.myapp", null));
}

test "resolveExecName prefers an explicit exec_name over the id" {
    try std.testing.expectEqualStrings("genesis-shell", resolveExecName("com.expidusos.genesis", "genesis-shell"));
}

test "resolveExecName rejects an id with a trailing dot rather than returning empty" {
    // An empty binary name produces an unrunnable artifact and a broken Exec=
    // line in the desktop file, so the fallback must never yield one.
    try std.testing.expectEqualStrings("app", resolveExecName("org.example.", null));
}
