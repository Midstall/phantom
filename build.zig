const std = @import("std");
const webidl = @import("webidl");
const appmeta = @import("build/appmeta.zig");

pub const Category = appmeta.Category;
pub const LocalizedText = appmeta.LocalizedText;
pub const Icon = appmeta.Icon;
pub const AppOptions = appmeta.AppOptions;

pub fn addApp(b: *std.Build, phantom_dep: *std.Build.Dependency, opts: appmeta.AppOptions) *std.Build.Step {
    const t = opts.target.result;
    const phantom_mod = phantom_dep.module("phantom");

    if (t.cpu.arch == .wasm32) {
        return addWebApp(b, phantom_dep, opts); // Task C5
    }
    const desktop_ok = switch (t.os.tag) {
        // Linux gets the window path and the terminal path.
        .linux => !t.abi.isAndroid(),
        // macOS, the BSDs and Windows get the terminal path only.
        .macos, .freebsd, .netbsd, .openbsd, .windows => true,
        else => false,
    };
    if (!desktop_ok) {
        return &b.addFail("phantom.addApp: this target has neither a window backend nor a terminal backend").step;
    }

    // App root module (the consumer's source exposing `root(*BuildContext) Widget`).
    const app_mod = b.createModule(.{ .root_source_file = opts.root, .target = opts.target, .optimize = opts.optimize });
    app_mod.addImport("phantom", phantom_mod);

    // Generated native entry.
    //
    // `pub const panic` here, not in `phantom.zig`: Zig's language level panic
    // mechanism (a bare `@panic`, `unreachable`, a failed bounds or overflow
    // check) looks for that declaration in the ROOT MODULE OF THE COMPILATION,
    // and an imported module's own declaration does not count (see
    // `lib/phantom/panic.zig`'s doc comment). This file IS that root, so it is
    // the one place that reaches every consumer with no action on their part.
    // Harmless for this windowed entry point specifically (`rootPanic`'s restore
    // is a no-op when no `Term` ever called `installCleanup`), and exactly what a
    // terminal entry point needs, so one declaration covers both without a
    // target-specific branch.
    const entry_src =
        \\const std = @import("std");
        \\const phantom = @import("phantom");
        \\const app = @import("app_root");
        \\pub const panic = std.debug.FullPanic(phantom.tui.term.rootPanic);
        \\pub fn main(init: std.process.Init) !void {
        \\    try phantom.App.run(init, phantom.Root.plain(app.root));
        \\}
    ;
    const entry = b.addWriteFiles().add("main.zig", entry_src);
    const exe = b.addExecutable(.{
        .name = execName(b, opts.id, opts.exec_name),
        .root_module = b.createModule(.{ .root_source_file = entry, .target = opts.target, .optimize = opts.optimize }),
    });
    exe.root_module.addImport("phantom", phantom_mod);
    exe.root_module.addImport("app_root", app_mod);

    const step = b.step(b.fmt("app-{s}", .{opts.id}), b.fmt("Package {s} (native)", .{opts.id}));
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // The desktop entry and AppStream metainfo are read by an XDG compliant menu
    // and software centre: GNOME, KDE, and their BSD equivalents. macOS and
    // Windows have no such reader, so installing these files there would only
    // leave two dead paths in the install tree, not a working integration.
    const xdg_ok = switch (t.os.tag) {
        .linux => !t.abi.isAndroid(),
        .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
    if (xdg_ok) {
        // .desktop
        const desktop_text = appmeta.desktopFile(b.allocator, opts, execName(b, opts.id, opts.exec_name)) catch @panic("oom");
        const desktop_lp = b.addWriteFiles().add(b.fmt("{s}.desktop", .{opts.id}), desktop_text);
        step.dependOn(&b.addInstallFileWithDir(desktop_lp, .prefix, b.fmt("share/applications/{s}.desktop", .{opts.id})).step);

        // AppStream metainfo
        const meta_text = appmeta.metainfoXml(b.allocator, opts) catch @panic("oom");
        const meta_lp = b.addWriteFiles().add(b.fmt("{s}.metainfo.xml", .{opts.id}), meta_text);
        step.dependOn(&b.addInstallFileWithDir(meta_lp, .prefix, b.fmt("share/metainfo/{s}.metainfo.xml", .{opts.id})).step);
    }

    // Icons
    for (opts.icons) |icon| {
        const dest = if (icon.size == 0)
            b.fmt("share/icons/hicolor/scalable/apps/{s}.svg", .{opts.id})
        else
            b.fmt("share/icons/hicolor/{d}x{d}/apps/{s}.png", .{ icon.size, icon.size, opts.id });
        step.dependOn(&b.addInstallFileWithDir(icon.path, .prefix, dest).step);
    }

    return step;
}

fn addWebApp(b: *std.Build, phantom_dep: *std.Build.Dependency, opts: appmeta.AppOptions) *std.Build.Step {
    // A wrong base_path is a caller mistake, not a runtime fault: fail the
    // build now with a message that says what was expected, rather than
    // install a page whose assets resolve to the wrong place.
    appmeta.validateBasePath(opts.base_path) catch {
        return &b.addFail(b.fmt(
            "phantom.addApp: base_path must start and end with '/', got \"{s}\"",
            .{opts.base_path},
        )).step;
    };

    const wasm_name = execName(b, opts.id, opts.exec_name);
    const dist_dir = b.fmt("dist/{s}", .{opts.id});

    // wasm32-freestanding target: no prism/lattice imported so the pure-Zig web
    // decls (web.init / web.WebApp, backend.dom) are analyzed without triggering
    // those native-only deps.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    const phantom_wasm = b.createModule(.{
        .root_source_file = phantom_dep.builder.path("lib/phantom.zig"),
        .target = wasm_target,
        .optimize = opts.optimize,
    });

    // webidl lives in phantom's own dependency tree.
    const webidl_dep = phantom_dep.builder.dependency("webidl", .{});

    // Generate the dom .client Zig bindings from phantom's bundled webidl.
    const dom_client = webidl.generateModule(b, webidl_dep, .{
        .name = "dom",
        .idl = phantom_dep.builder.path("web/dom.webidl"),
        .style = .client,
    });

    // App root module: the consumer's root_source_file built for wasm32.
    const app_mod = b.createModule(.{
        .root_source_file = opts.root,
        .target = wasm_target,
        .optimize = opts.optimize,
    });
    app_mod.addImport("phantom", phantom_wasm);

    // Generated web entry: implements DomOps via the generated dom module and passes
    // them to phantom.web.init. Returns the *WebApp as a usize so JS holds the pointer.
    // dom_ctx is module-level in the app-glue entry (single wasm instance, acceptable here).
    const entry_src = b.fmt(
        \\const std = @import("std");
        \\const phantom = @import("phantom");
        \\const dom = @import("dom");
        \\const webidl = @import("webidl");
        \\const app_root = @import("app_root");
        \\
        \\const strategy_is_hash = {s};
        \\
        \\const DomCtx = struct {{ doc: u32, window: u32 }};
        \\var dom_ctx: DomCtx = undefined;
        \\
        \\fn createElement(ctx: *anyopaque, tag: []const u8) u32 {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const doc = dom.Document{{ .handle = c.doc }};
        \\    return doc.createElement(tag).handle;
        \\}}
        \\// An `svg` made by createElement lands in the HTML namespace, where a
        \\// browser lays it out and never paints it. Only the namespaced call
        \\// reaches the SVG namespace, so icons need this one.
        \\fn createElementNS(ctx: *anyopaque, ns: []const u8, tag: []const u8) u32 {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const doc = dom.Document{{ .handle = c.doc }};
        \\    return doc.createElementNS(ns, tag).handle;
        \\}}
        \\fn createTextNode(ctx: *anyopaque, data: []const u8) u32 {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const doc = dom.Document{{ .handle = c.doc }};
        \\    return doc.createTextNode(data).handle;
        \\}}
        \\fn setAttribute(ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void {{
        \\    _ = ctx;
        \\    const el = dom.Element{{ .handle = node }};
        \\    el.setAttribute(name, value);
        \\}}
        \\fn setTextContent(ctx: *anyopaque, node: u32, textv: []const u8) void {{
        \\    _ = ctx;
        \\    const el = dom.Element{{ .handle = node }};
        \\    el.set_textContent(textv);
        \\}}
        \\fn appendChild(ctx: *anyopaque, parent: u32, child: u32) void {{
        \\    _ = ctx;
        \\    const el = dom.Element{{ .handle = parent }};
        \\    _ = el.appendChild(dom.Node{{ .handle = child }});
        \\}}
        \\fn clearChildren(ctx: *anyopaque, node: u32) void {{
        \\    _ = ctx;
        \\    const el = dom.Element{{ .handle = node }};
        \\    el.set_innerHTML("");
        \\}}
        \\
        \\// Reads the address bar into buf, according to the build's url strategy. A
        \\// hash strategy trims the leading '#' and reads an empty hash as "/", so a
        \\// fresh page with no hash still resolves to the root route. Null when the
        \\// address does not fit buf: the caller must refuse it rather than take a
        \\// truncated, shorter route than the one the browser actually shows.
        \\fn currentPath(win: dom.Window, buf: []u8) ?[]const u8 {{
        \\    const loc = win.get_location();
        \\    const raw = if (strategy_is_hash) loc.get_hash() else loc.get_pathname();
        \\    defer webidl.rt.freeStr(raw);
        \\    var s = raw;
        \\    if (strategy_is_hash) {{
        \\        if (s.len > 0 and s[0] == '#') s = s[1..];
        \\        if (s.len == 0) s = "/";
        \\    }}
        \\    if (s.len > buf.len) return null;
        \\    @memcpy(buf[0..s.len], s);
        \\    return buf[0..s.len];
        \\}}
        \\
        \\fn openUrl(ctx: *anyopaque, url: []const u8) void {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const win = dom.Window{{ .handle = c.window }};
        \\    win.open(url, "_blank");
        \\}}
        \\
        \\fn readLocation(ctx: *anyopaque, buf: []u8) ?[]const u8 {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const win = dom.Window{{ .handle = c.window }};
        \\    return currentPath(win, buf);
        \\}}
        \\
        \\// Puts path in the address bar, in the given mode: push adds a history
        \\// entry, replace rewrites the current one. The guard that once skipped a
        \\// redundant write here now lives in phantom.web, in the thunk that calls
        \\// this function: it compares against the same read_location this file
        \\// exposes, so it can be tested with no browser.
        \\fn writeLocation(ctx: *anyopaque, path: []const u8, mode: phantom.WriteMode) void {{
        \\    const c: *DomCtx = @ptrCast(@alignCast(ctx));
        \\    const win = dom.Window{{ .handle = c.window }};
        \\    const hist = win.get_history();
        \\    if (strategy_is_hash) {{
        \\        var url_buf: [phantom.router.max_path + 1]u8 = undefined;
        \\        const n = @min(path.len, url_buf.len - 1);
        \\        url_buf[0] = '#';
        \\        @memcpy(url_buf[1 .. 1 + n], path[0..n]);
        \\        switch (mode) {{
        \\            .push => hist.pushState("", "", url_buf[0 .. 1 + n]),
        \\            .replace => hist.replaceState("", "", url_buf[0 .. 1 + n]),
        \\        }}
        \\    }} else {{
        \\        switch (mode) {{
        \\            .push => hist.pushState("", "", path),
        \\            .replace => hist.replaceState("", "", path),
        \\        }}
        \\    }}
        \\}}
        \\
        \\export fn init(doc_handle: u32, body_handle: u32, window_handle: u32) usize {{
        \\    const win = dom.Window{{ .handle = window_handle }};
        \\    const vw: u32 = win.get_innerWidth();
        \\    const vh: u32 = win.get_innerHeight();
        \\    const dpr: f64 = win.get_devicePixelRatio();
        \\    dom_ctx = .{{ .doc = doc_handle, .window = window_handle }};
        \\    const _doc = dom.Document{{ .handle = doc_handle }};
        \\    const head = _doc.get_head().handle;
        \\    const ops = phantom.backend.dom_calls.DomOps{{
        \\        .ctx = &dom_ctx,
        \\        .create_element = createElement,
        \\        .create_element_ns = createElementNS,
        \\        .create_text_node = createTextNode,
        \\        .set_attribute = setAttribute,
        \\        .set_text_content = setTextContent,
        \\        .append_child = appendChild,
        \\        .clear_children = clearChildren,
        \\        .body = body_handle,
        \\        .head = head,
        \\        .open_url = openUrl,
        \\        .read_location = readLocation,
        \\        .write_location = writeLocation,
        \\    }};
        \\    const strategy: phantom.UrlStrategy = if (strategy_is_hash) .hash else .path;
        \\    const app = phantom.web.init(std.heap.wasm_allocator, ops, phantom.Root.plain(app_root.root),
        \\        .{{ .width = @floatFromInt(vw), .height = @floatFromInt(vh) }}, @floatCast(dpr), strategy) catch return 0;
        \\    return @intFromPtr(app);
        \\}}
        \\export fn dispatchTap(app: usize, x: f32, y: f32) void {{
        \\    if (app == 0) return;
        \\    const a: *phantom.web.WebApp = @ptrFromInt(app);
        \\    a.dispatchTap(x, y);
        \\}}
        \\export fn resize(app: usize, w: u32, h: u32, dpr: f64) void {{
        \\    if (app == 0) return;
        \\    const a: *phantom.web.WebApp = @ptrFromInt(app);
        \\    a.resize(.{{ .width = @floatFromInt(w), .height = @floatFromInt(h) }}, @floatCast(dpr));
        \\}}
        \\// wall_ms is Date.now (settable, Unix epoch). mono_ms is the animation
        \\// frame timestamp (monotonic, page time origin). Both are needed: the
        \\// bar shows a time of day, the scheduler arms deadlines.
        \\export fn tick(app: usize, wall_ms: f64, mono_ms: f64) void {{
        \\    if (app == 0) return;
        \\    const a: *phantom.web.WebApp = @ptrFromInt(app);
        \\    a.tick(wall_ms, mono_ms);
        \\}}
        \\// The browser moved back or forward. The address bar already shows the new
        \\// location, so this reads it back and tells the tree, rather than taking the
        \\// new path as a string argument: a string argument would need the JS host to
        \\// write into wasm memory, and reading the location back through the same
        \\// DomOps hook the tree already uses needs no new plumbing.
        \\export fn locationChanged(app: usize) void {{
        \\    if (app == 0) return;
        \\    const a: *phantom.web.WebApp = @ptrFromInt(app);
        \\    a.locationChanged();
        \\}}
    , .{if (opts.url_strategy == .hash) "true" else "false"});
    const entry = b.addWriteFiles().add("main.zig", entry_src);

    const wasm = b.addExecutable(.{
        .name = wasm_name,
        .root_module = b.createModule(.{
            .root_source_file = entry,
            .target = wasm_target,
            .optimize = opts.optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.addImport("phantom", phantom_wasm);
    wasm.root_module.addImport("dom", dom_client);
    // The generated entry frees the string `dom`'s getters hand back, so it
    // reaches the runtime the same way the generated module itself does.
    wasm.root_module.addImport("webidl", webidl_dep.module("webidl"));
    wasm.root_module.addImport("app_root", app_mod);

    // JS runtime strategy (detected at build time):
    //
    // prebuilt -> copy npm/webidl-runtime/dist/ (multi-file ESM) to
    //             dist/{id}/webidl-runtime/
    //             HTML imports: "./webidl-runtime/index.js"
    //             The webidl dep's npm/.gitignore ignores dist/, so most
    //             checkouts of the dep do NOT commit this directory. Use this
    //             path only when a dist/index.js is actually present.
    //
    // tsc      -> compile npm/webidl-runtime/src/*.ts (multi-file ESM) to an
    //             output directory the build owns, then install it to
    //             dist/{id}/webidl-runtime/
    //             HTML imports: "./webidl-runtime/index.js"
    //             This is the DEFAULT (.auto) when the dep has no committed
    //             dist/index.js. It needs no network access, only tsc on PATH.
    //
    // bun      -> bun build --format esm --entrypoints dist/index.js (opt-in only)
    //             single-file -> dist/{id}/webidl-runtime.js
    // deno     -> deno bundle --platform browser dist/index.js (opt-in only)
    //             single-file -> dist/{id}/webidl-runtime.js
    //             WARNING: both single-file bundlers currently mangle this dep's
    //             pure-re-export entry (they drop the definitions and emit a
    //             nameless `export {...}`, which the browser rejects). Use only if
    //             your bundler is verified to produce a valid module.
    //
    // When opts.web_runtime is .auto the build prefers a committed prebuilt
    // dist and falls back to compiling with tsc when there is none. Explicit
    // .bun / .deno / .tsc pin that strategy; an unavailable tool injects a
    // build-time failure step that names the tool (the wasm is still compiled).

    const step = b.step(b.fmt("app-{s}", .{opts.id}), b.fmt("Package {s} (web)", .{opts.id}));

    // Install wasm into dist/{id}/
    step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = dist_dir } },
    }).step);

    // Build + install the webidl-runtime JS and generate a matching index.html.
    const runtime_import = addRuntimeToStep(b, webidl_dep, dist_dir, step, opts.web_runtime);

    // The tab title and description come from the app's own localized text,
    // not the wasm binary's name, so a name with '&' or '"' cannot break the
    // generated document.
    const name_html = appmeta.xmlEscape(b.allocator, opts.name.default) catch @panic("oom");
    const summary_html = appmeta.xmlEscape(b.allocator, opts.summary.default) catch @panic("oom");
    const html_src = buildIndexHtml(b, wasm_name, runtime_import, opts.base_path, name_html, summary_html);
    const html_lp = b.addWriteFiles().add("index.html", html_src);
    step.dependOn(&b.addInstallFile(html_lp, b.fmt("{s}/index.html", .{dist_dir})).step);

    // prerender_routes only means something with the .path strategy: a .hash
    // route lives after the '#', so a host never requests the plain path and
    // the extra copy goes unused. Report it rather than fail the build, since
    // the app still works, it just carries a dead copy.
    if (opts.url_strategy == .hash and opts.prerender_routes.len > 0) {
        std.log.warn(
            "phantom.addApp: prerender_routes is set but url_strategy is .hash ({d} routes ignored)",
            .{opts.prerender_routes.len},
        );
    }

    // With the .path strategy, write a standalone copy of the page at each
    // route so a static host answers a refresh with 200 instead of 404.
    // "/gallery" becomes "dist/{id}/gallery/index.html", so a static host
    // serves the same application for that path with no rewrite rule. A
    // route with a '/' inside it, such as "/docs/intro", works the same way,
    // because the install path keeps the separator.
    if (opts.url_strategy == .path) {
        for (opts.prerender_routes) |route| {
            const trimmed = std.mem.trim(u8, route, "/");
            if (trimmed.len == 0) continue;
            const dest = b.fmt("{s}/{s}/index.html", .{ dist_dir, trimmed });
            step.dependOn(&b.addInstallFile(html_lp, dest).step);
        }
    }

    // Dev-serve: `zig build serve-<name>` serves dist/{id}/ over http via the first
    // available runtime, using an inline zero-dependency static server that sets
    // application/wasm for .wasm (required for WebAssembly.instantiateStreaming).
    addServeStep(b, dist_dir, wasm_name, step);

    return step;
}

// Inline static server scripts. Each serves a directory on port 8080. A request
// path is remote input, so each script confines every read to the serve root and
// answers 404 for a path that escapes it. The bind address comes from
// PHANTOM_SERVE_HOST and defaults to every interface, so a developer can open the
// site from a second machine on the same network. Set it to 127.0.0.1 for
// loopback only. All three read the dir from the PHANTOM_SERVE_DIR env var
// (node/bun `-e` eval mode does not expose a positional arg at a stable argv
// index, so an env var is used uniformly).
// Content-Type: .wasm -> application/wasm, .js -> text/javascript,
// .html -> text/html, anything else -> application/octet-stream.
// A path with no file extension is a route, not a file, so it maps to that
// path's own index.html. This mirrors the prerendered copies addWebApp
// writes for the .path url strategy, so a browser refresh on a route works
// on the dev server the same way it works on a static host.
// Each script resolves the request against the served root and refuses a
// path that escapes it (a "../" walk answers 404), so a client cannot read
// files elsewhere on the developer's disk.
const node_serve_js =
    \\const http = require('http');
    \\const fs = require('fs');
    \\const path = require('path');
    \\const dir = process.env.PHANTOM_SERVE_DIR;
    \\if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
    \\const root = path.resolve(dir);
    \\const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
    \\function mime(p) {
    \\  if (p.endsWith('.wasm')) return 'application/wasm';
    \\  if (p.endsWith('.js')) return 'text/javascript';
    \\  if (p.endsWith('.html')) return 'text/html';
    \\  return 'application/octet-stream';
    \\}
    \\http.createServer(function(req, res) {
    \\  let pathname;
    \\  try { pathname = decodeURIComponent(req.url.split('?')[0]); } catch { pathname = req.url.split('?')[0]; }
    \\  if (pathname === '/') pathname = '/index.html';
    \\  else if (!path.extname(pathname)) pathname += '/index.html';
    \\  const file = path.join(root, pathname);
    \\  process.stdout.write(req.method + ' ' + req.url + '\n');
    \\  if (file !== root && !file.startsWith(root + path.sep)) {
    \\    res.writeHead(404);
    \\    res.end('not found');
    \\    return;
    \\  }
    \\  fs.readFile(file, function(err, data) {
    \\    if (err) { res.writeHead(404); res.end('not found'); return; }
    \\    res.writeHead(200, { 'Content-Type': mime(file) });
    \\    res.end(data);
    \\  });
    \\}).listen(8080, host, function() {
    \\  process.stdout.write('phantom serve: http://localhost:8080 serving ' + dir + '\n');
    \\});
;

const bun_serve_js =
    \\const dir = process.env.PHANTOM_SERVE_DIR;
    \\if (!dir) { process.stderr.write('PHANTOM_SERVE_DIR not set\n'); process.exit(1); }
    \\const path = require('path');
    \\const root = path.resolve(dir);
    \\function mime(p) {
    \\  if (p.endsWith('.wasm')) return 'application/wasm';
    \\  if (p.endsWith('.js')) return 'text/javascript';
    \\  if (p.endsWith('.html')) return 'text/html';
    \\  return 'application/octet-stream';
    \\}
    \\const host = process.env.PHANTOM_SERVE_HOST || '0.0.0.0';
    \\const server = Bun.serve({
    \\  port: 8080,
    \\  hostname: host,
    \\  async fetch(req) {
    \\    const url = new URL(req.url);
    \\    let pathname = url.pathname === '/' ? '/index.html' : url.pathname;
    \\    if (!/\.[^/]*$/.test(pathname)) pathname += '/index.html';
    \\    const file = path.join(root, pathname);
    \\    console.log(req.method + ' ' + url.pathname);
    \\    if (file !== root && !file.startsWith(root + path.sep)) {
    \\      return new Response('not found', { status: 404 });
    \\    }
    \\    const f = Bun.file(file);
    \\    if (!(await f.exists())) return new Response('not found', { status: 404 });
    \\    return new Response(f, { headers: { 'Content-Type': mime(file) } });
    \\  },
    \\});
    \\console.log('phantom serve: http://localhost:' + server.port + ' serving ' + dir);
;

const deno_serve_js =
    \\import { join, resolve, sep } from 'node:path';
    \\const dir = Deno.env.get('PHANTOM_SERVE_DIR');
    \\if (!dir) { console.error('PHANTOM_SERVE_DIR not set'); Deno.exit(1); }
    \\const root = resolve(dir);
    \\function mime(p) {
    \\  if (p.endsWith('.wasm')) return 'application/wasm';
    \\  if (p.endsWith('.js')) return 'text/javascript';
    \\  if (p.endsWith('.html')) return 'text/html';
    \\  return 'application/octet-stream';
    \\}
    \\const host = Deno.env.get('PHANTOM_SERVE_HOST') || '0.0.0.0';
    \\Deno.serve({ port: 8080, hostname: host }, async function(req) {
    \\  const url = new URL(req.url);
    \\  let pathname = url.pathname === '/' ? '/index.html' : url.pathname;
    \\  if (!/\.[^/]*$/.test(pathname)) pathname += '/index.html';
    \\  const file = join(root, pathname);
    \\  console.log(req.method + ' ' + url.pathname);
    \\  if (file !== root && !file.startsWith(root + sep)) {
    \\    return new Response('not found', { status: 404 });
    \\  }
    \\  try {
    \\    const data = await Deno.readFile(file);
    \\    return new Response(data, { headers: { 'Content-Type': mime(file) } });
    \\  } catch {
    \\    return new Response('not found', { status: 404 });
    \\  }
    \\});
    \\console.log('phantom serve: http://localhost:8080 serving ' + dir);
;

fn addServeStep(b: *std.Build, dist_dir: []const u8, name: []const u8, app_step: *std.Build.Step) void {
    const serve = b.step(b.fmt("serve-{s}", .{name}), b.fmt("Serve {s} over http (dev)", .{dist_dir}));
    const out = b.getInstallPath(.prefix, dist_dir);
    // All three scripts read the serve dir from PHANTOM_SERVE_DIR (set below), not a
    // positional arg: node/bun `-e` eval mode does not put the dir at a stable argv
    // index (there is no script-path slot), which broke a positional approach.
    var run: ?*std.Build.Step.Run = null;
    if (b.findProgram(&.{"node"}, &.{}) catch null) |node_bin| {
        run = b.addSystemCommand(&.{ node_bin, "-e", node_serve_js });
    } else if (b.findProgram(&.{"bun"}, &.{}) catch null) |bun_bin| {
        run = b.addSystemCommand(&.{ bun_bin, "-e", bun_serve_js });
    } else if (b.findProgram(&.{"deno"}, &.{}) catch null) |deno_bin| {
        // --allow-env is required: the deno script reads PHANTOM_SERVE_DIR via
        // Deno.env.get, which throws PermissionDenied without it.
        const r = b.addSystemCommand(&.{ deno_bin, "run", "--allow-net", "--allow-read", "--allow-env=PHANTOM_SERVE_DIR,PHANTOM_SERVE_HOST", "-" });
        r.setStdIn(.{ .bytes = deno_serve_js });
        run = r;
    }
    if (run) |r| r.setEnvironmentVariable("PHANTOM_SERVE_DIR", out);
    if (run) |r| {
        // Depend on the app step (which carries all the dist install actions) so the
        // bundle is built regardless of how the consumer wires the app into install.
        r.step.dependOn(app_step);
        serve.dependOn(&r.step);
    } else {
        serve.dependOn(&b.addFail("phantom serve: no node/bun/deno found in PATH").step);
    }
}

/// Wire the webidl-runtime build/install into step. Returns the JS import path
/// to embed in the generated index.html (so HTML and runtime step agree).
fn addRuntimeToStep(
    b: *std.Build,
    webidl_dep: *std.Build.Dependency,
    dist_dir: []const u8,
    step: *std.Build.Step,
    runtime: appmeta.WebRuntime,
) []const u8 {
    // The committed dist is the exception, not the rule: npm/.gitignore ignores
    // dist/, so most checkouts of the dep have none. Check the real filesystem
    // rather than assume, because a later version of the dep may commit it, and
    // then the copy is both faster and offline.
    const dist_index = webidl_dep.builder.pathFromRoot("npm/webidl-runtime/dist/index.js");
    const has_prebuilt = blk: {
        std.Io.Dir.accessAbsolute(b.graph.io, dist_index, .{}) catch break :blk false;
        break :blk true;
    };
    const have = appmeta.Avail{
        .bun = (b.findProgram(&.{"bun"}, &.{}) catch null) != null,
        .deno = (b.findProgram(&.{"deno"}, &.{}) catch null) != null,
        .node = (b.findProgram(&.{"node"}, &.{}) catch null) != null,
        .tsc = (b.findProgram(&.{"tsc"}, &.{}) catch null) != null,
        .prebuilt = has_prebuilt,
    };
    const strategy = appmeta.resolveStrategy(runtime, have) catch {
        // .auto tries the committed dist first and falls back to tsc, so an
        // unresolved .auto always means tsc is the missing tool.
        const missing_tool: []const u8 = if (runtime == .auto) "tsc" else @tagName(runtime);
        step.dependOn(&b.addFail(b.fmt(
            "phantom.addApp: the web target needs {s}, but it was not found in PATH",
            .{missing_tool},
        )).step);
        return appmeta.importPathFor(.prebuilt);
    };
    // Bundle the dep's already-transpiled dist/index.js (clean ESM with .js imports,
    // type-exports stripped), NOT the raw src/index.ts: bundling the TS source
    // produced an invalid module ("local binding for export 'createHost' not found",
    // from the .ts-extension re-exports + the mixed value/type export). The dist is
    // the same tsc output the prebuilt strategy copies.
    const bundle_entry = webidl_dep.builder.path("npm/webidl-runtime/dist/index.js");
    switch (strategy) {
        .bun => {
            const run = b.addSystemCommand(&.{ (b.findProgram(&.{"bun"}, &.{}) catch unreachable), "build", "--format", "esm", "--entrypoints" });
            run.addFileArg(bundle_entry);
            run.addArg("--outfile");
            const js_lp = run.addOutputFileArg("webidl-runtime.js");
            step.dependOn(&b.addInstallFile(js_lp, b.fmt("{s}/webidl-runtime.js", .{dist_dir})).step);
        },
        .deno => {
            // deno bundle (Deno 2.8.3, native/offline). This is the browser single-file form.
            const run = b.addSystemCommand(&.{ (b.findProgram(&.{"deno"}, &.{}) catch unreachable), "bundle", "--platform", "browser" });
            run.addFileArg(bundle_entry);
            run.addArg("--output");
            const js_lp = run.addOutputFileArg("webidl-runtime.js");
            step.dependOn(&b.addInstallFile(js_lp, b.fmt("{s}/webidl-runtime.js", .{dist_dir})).step);
        },
        .tsc => {
            // Compile the TS source directly (not the missing dist): --outDir
            // goes to a path the build owns, because the package cache is read
            // only. --rewriteRelativeImportExtensions turns the sources' explicit
            // `.ts` imports into `.js`, which is what the browser needs to load
            // the emitted module graph; it needs TypeScript 5.7 or newer.
            // node-fs.d.ts is an ambient declaration for `node:fs/promises`
            // (loader.ts's non-browser file-read path); it emits no JS but is
            // required for the type check to pass.
            const run = b.addSystemCommand(&.{
                (b.findProgram(&.{"tsc"}, &.{}) catch unreachable),
                "--target",
                "ES2022",
                "--module",
                "ES2022",
                "--moduleResolution",
                "bundler",
                "--rewriteRelativeImportExtensions",
                "--strict",
                "--declaration",
                "false",
                "--outDir",
            });
            const out_dir = run.addOutputDirectoryArg("webidl-runtime");
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/abi.ts"));
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/host.ts"));
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/index.ts"));
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/loader.ts"));
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/node-fs.d.ts"));
            step.dependOn(&b.addInstallDirectory(.{
                .source_dir = out_dir,
                .install_dir = .prefix,
                .install_subdir = b.fmt("{s}/webidl-runtime", .{dist_dir}),
                .include_extensions = &.{".js"},
            }).step);
        },
        .prebuilt => {
            step.dependOn(&b.addInstallDirectory(.{
                .source_dir = webidl_dep.builder.path("npm/webidl-runtime/dist"),
                .install_dir = .prefix,
                .install_subdir = b.fmt("{s}/webidl-runtime", .{dist_dir}),
                .include_extensions = &.{".js"},
            }).step);
        },
    }
    return appmeta.importPathFor(strategy);
}

/// Generate a minimal index.html for the web app bundle. `base_path` fixes
/// where a relative asset resolves from: the same file is reachable as both
/// "/gallery" and "/gallery/", and a browser resolves "./x" differently for
/// each, so the page cannot rely on the request's shape and needs an
/// explicit <base> instead. `name_html` and `summary_html` are already
/// HTML-escaped by the caller.
fn buildIndexHtml(
    b: *std.Build,
    wasm_name: []const u8,
    runtime_import: []const u8,
    base_path: []const u8,
    name_html: []const u8,
    summary_html: []const u8,
) []const u8 {
    return b.fmt(
        \\<!doctype html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8" />
        \\    <base href="{s}" />
        \\    <title>{s}</title>
        \\    <meta name="description" content="{s}" />
        \\  </head>
        \\  <body>
        \\    <script type="module">
        \\      import {{ createHost }} from "{s}";
        \\
        \\      const host = createHost();
        \\      const {{ instance }} = await WebAssembly.instantiateStreaming(
        \\        fetch("./{s}.wasm"),
        \\        host.imports,
        \\      );
        \\      host.attach(instance);
        \\
        \\      const documentHandle = host.intern(document);
        \\      const bodyHandle = host.intern(document.body);
        \\      const windowHandle = host.intern(window);
        \\      const app = instance.exports.init(documentHandle, bodyHandle, windowHandle);
        \\      document.body.addEventListener("click", (e) => instance.exports.dispatchTap(app, e.clientX, e.clientY));
        \\      // The back/forward buttons move the address bar and then fire this,
        \\      // with no string to pass in: the wasm side reads the new location
        \\      // back itself, so the JS host never allocates inside the module.
        \\      window.addEventListener("popstate", () => instance.exports.locationChanged(app));
        \\      const onResize = () => instance.exports.resize(app, window.innerWidth, window.innerHeight, window.devicePixelRatio);
        \\      window.addEventListener("resize", onResize);
        \\      matchMedia(`(resolution: ${{window.devicePixelRatio}}dppx)`).addEventListener("change", onResize);
        \\      // t is the rAF timestamp: monotonic, same origin as performance.now.
        \\      // Date.now is the wall clock and can step backwards. They are passed
        \\      // separately because the scheduler must never arm against the second.
        \\      const frame = (t) => {{
        \\        instance.exports.tick(app, Date.now(), t);
        \\        requestAnimationFrame(frame);
        \\      }};
        \\      requestAnimationFrame(frame);
        \\    </script>
        \\  </body>
        \\</html>
    , .{ base_path, name_html, summary_html, runtime_import, wasm_name });
}

fn execName(b: *std.Build, id: []const u8, exec_name: ?[]const u8) []const u8 {
    return b.dupe(appmeta.resolveExecName(id, exec_name));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_drivers = b.option([]const u8, "gpu-drivers", "Specific GPU drivers to enable, defaults to Prism's choice.");

    const phantom = b.addModule("phantom", .{
        .root_source_file = b.path("lib/phantom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lattice_dep = b.dependency("lattice", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-drivers" = gpu_drivers,
    });

    const prism_dep = b.dependency("prism", .{
        .target = target,
        .optimize = optimize,
        .drivers = gpu_drivers,
    });

    phantom.addImport("lattice", lattice_dep.module("lattice"));
    phantom.addImport("prism", prism_dep.module("prism"));

    // Every task in the terminal plan runs one named test. Without a filter the
    // full suite runs each time, which hides which test the task actually proved.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only the tests whose name contains one of these substrings",
    ) orelse &[0][]const u8{};

    const tests = b.addTest(.{ .root_module = phantom, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Phantom unit tests");
    test_step.dependOn(&run_tests.step);

    const meta_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/appmeta.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(meta_tests).step);

    // run-hello: the padded blue box in a real Lattice window (Wayland, else headless).
    const hello = b.addExecutable(.{
        .name = "phantom-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello.root_module.addImport("phantom", phantom);
    b.installArtifact(hello);
    const run_hello = b.addRunArtifact(hello);
    const run_hello_step = b.step("run-hello", "Run the Phantom hello window (Wayland)");
    run_hello_step.dependOn(&run_hello.step);

    // run-hello:web: the same padded blue box, compiled to wasm and rendered to the DOM
    // via the DomBackend string path + webidl .client bindings. The web path is pure Zig
    // (no prism/lattice), so this phantom module is built for wasm WITHOUT those deps: the
    // native-only decls (App, PrismBackend) are never referenced by the web entry, so they
    // are not analyzed and their prism/lattice imports are never triggered.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const phantom_wasm = b.createModule(.{
        .root_source_file = b.path("lib/phantom.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const webidl_dep = b.dependency("webidl", .{});
    const dom_client = webidl.generateModule(b, webidl_dep, .{
        .name = "dom",
        .idl = b.path("web/dom.webidl"),
        .style = .client,
    });

    const hello_web = b.addExecutable(.{
        .name = "phantom-hello-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_web.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    hello_web.entry = .disabled;
    hello_web.rdynamic = true;
    hello_web.root_module.addImport("phantom", phantom_wasm);
    hello_web.root_module.addImport("dom", dom_client);

    const install_web = b.addInstallArtifact(hello_web, .{});
    const install_html = b.addInstallFile(b.path("web/index.html"), "index.html");
    const web_step = b.step("run-hello:web", "Build the Phantom web (CSR) demo (wasm + html)");
    web_step.dependOn(&install_web.step);
    web_step.dependOn(&install_html.step);

    // run-hello:tui: the terminal path. It needs a real terminal, so this is a
    // manual check and not part of `zig build test`.
    const hello_tui = b.addExecutable(.{
        .name = "phantom-hello-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello_tui.root_module.addImport("phantom", phantom);
    b.installArtifact(hello_tui);
    const run_hello_tui = b.addRunArtifact(hello_tui);
    const run_hello_tui_step = b.step("run-hello:tui", "Run the Phantom terminal demo");
    run_hello_tui_step.dependOn(&run_hello_tui.step);
}
