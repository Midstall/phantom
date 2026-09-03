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

    // The web entry point is `build/web_entry.zig`, a real file rather than a
    // string in this one: it imports the consumer's source as `app_root`, calls
    // `phantom.web.init`, and exports everything the host page calls. The one
    // per-build value it cannot work out for itself arrives as a build option.
    const entry_options = b.addOptions();
    entry_options.addOption(bool, "strategy_is_hash", opts.url_strategy == .hash);

    const wasm = b.addExecutable(.{
        .name = wasm_name,
        .root_module = b.createModule(.{
            .root_source_file = phantom_dep.builder.path("build/web_entry.zig"),
            .target = wasm_target,
            .optimize = opts.optimize,
        }),
    });
    wasm.root_module.addImport("build_options", entry_options.createModule());
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
    // A prerendered route installs THIS page one directory down, where `./`
    // resolves somewhere else, so the base tag has to be there even at the root.
    const prerendered = opts.url_strategy == .path and opts.prerender_routes.len > 0;
    const html_lp = b.addWriteFiles().add("index.html", buildIndexHtml(b, opts.base_path, prerendered, name_html, summary_html));
    step.dependOn(&b.addInstallFile(html_lp, b.fmt("{s}/index.html", .{dist_dir})).step);

    // The page's logic, as a file beside it. See `buildIndexHtml`: an inline
    // script is refused by any strict Content Security Policy, and a blank page
    // with one console violation is a bad first impression of a framework.
    const boot_lp = b.addWriteFiles().add("boot.js", buildBootJs(b, runtime_import, wasm_name));
    step.dependOn(&b.addInstallFile(boot_lp, b.fmt("{s}/boot.js", .{dist_dir})).step);

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

/// The page itself: a shell with no logic in it at all.
///
/// The boot script is a FILE rather than an inline `<script>`, because an inline
/// one is refused outright by any Content Security Policy without
/// `'unsafe-inline'` or a nonce, and `script-src 'self'` is the ordinary strict
/// setting. Inline, not one byte of the application runs and the page is blank
/// with a console violation. As a file it is `'self'` and needs no policy change
/// from anyone.
///
/// `<base>` is emitted only when it does something.
///
/// It fixes where `./boot.js` and `./app.wasm` resolve from, and it is needed in
/// exactly two cases: an application served under a sub-path, and a prerendered
/// route, where THE SAME page is installed at `/gallery/index.html` and would
/// otherwise look for its script one directory down. A page served from the root
/// with no prerendered copies needs none of that, and `base-uri 'none'` refuses
/// the tag, so emitting it there buys a policy violation on every load and
/// nothing else.
fn buildIndexHtml(
    b: *std.Build,
    base_path: []const u8,
    prerendered: bool,
    name_html: []const u8,
    summary_html: []const u8,
) []const u8 {
    const base_tag = if (std.mem.eql(u8, base_path, "/") and !prerendered)
        ""
    else
        b.fmt("\n    <base href=\"{s}\" />", .{base_path});
    return b.fmt(
        \\<!DOCTYPE html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8" />{s}
        \\    <title>{s}</title>
        \\    <meta name="description" content="{s}" />
        \\  </head>
        \\  <body>
        \\    <script type="module" src="./boot.js"></script>
        \\  </body>
        \\</html>
    , .{ base_tag, name_html, summary_html });
}

/// Everything the page does, as a module served beside the wasm. See
/// `buildIndexHtml` for why this is not inline.
fn buildBootJs(b: *std.Build, runtime_import: []const u8, wasm_name: []const u8) []const u8 {
    return b.fmt(
        \\import {{ createHost }} from "{s}";
        \\
        \\const host = createHost();
        \\let instance;
        \\
        \\// HTTP. The wasm side writes an ordinary HTTP/1.1 request into what
        \\// it believes is a socket and then blocks reading the reply, so this
        \\// import is the one call in the whole page that has to not return
        \\// until the answer is in.
        \\//
        \\// JSPI is how that is done without freezing anything: the wasm stack
        \\// parks and the page keeps drawing. Without it the only way to block
        \\// is a synchronous XMLHttpRequest, which does freeze the page for the
        \\// length of the request. Both fill the same struct and the wasm side
        \\// cannot tell which one answered.
        \\const jspi =
        \\  typeof WebAssembly.Suspending === "function" &&
        \\  typeof WebAssembly.promising === "function";
        \\// Said out loud because the two paths behave differently in ways a
        \\// developer will otherwise put down to something else: the fallback
        \\// freezes the page for the length of a request and cannot carry a
        \\// binary body. Which one is in use should never be a guess.
        \\console.info(
        \\  jspi
        \\    ? "phantom: http suspends through JSPI"
        \\    : "phantom: no JSPI here, http blocks on a synchronous XMLHttpRequest",
        \\);
        \\
        \\const dec = new TextDecoder();
        \\const enc = new TextEncoder();
        \\const mem = () => instance.exports.memory.buffer;
        \\const str = (ptr, len) => (len === 0 ? "" : dec.decode(new Uint8Array(mem(), ptr, len)));
        \\
        \\// Headers a browser owns. Setting one throws, and the browser fills
        \\// every one of them itself, so they are dropped rather than passed on.
        \\const forbidden = new Set([
        \\  "host", "connection", "content-length", "transfer-encoding",
        \\  "upgrade", "keep-alive", "te", "trailer",
        \\]);
        \\const parseHeaders = (block) => {{
        \\  const out = {{}};
        \\  for (const line of block.split("\r\n")) {{
        \\    const i = line.indexOf(":");
        \\    if (i <= 0) continue;
        \\    const name = line.slice(0, i).trim().toLowerCase();
        \\    if (forbidden.has(name)) continue;
        \\    out[name] = line.slice(i + 1).trim();
        \\  }}
        \\  return out;
        \\}};
        \\
        \\// Copy a string into the module's own heap and hand back its address.
        \\// The wasm side frees both of these, so they must come from the same
        \\// allocator the runtime uses.
        \\const give = (s) => {{
        \\  const bytes = enc.encode(s);
        \\  if (bytes.length === 0) return [0, 0];
        \\  const ptr = instance.exports.webidl_rt_alloc(bytes.length);
        \\  if (ptr === 0) return [0, 0];
        \\  new Uint8Array(mem(), ptr, bytes.length).set(bytes);
        \\  return [ptr, bytes.length];
        \\}};
        \\// Five u32s: status, headers ptr and len, body ptr and len. Written
        \\// last, after every allocation, because allocating can grow the heap
        \\// and detach any view made before it.
        \\const reply = (out, status, headers, body) => {{
        \\  const h = give(headers);
        \\  const b = give(body);
        \\  new Uint32Array(mem(), out, 5).set([status, h[0], h[1], b[0], b[1]]);
        \\  return 1;
        \\}};
        \\
        \\// A request that a Content Security Policy refused and a network that is
        \\// simply down reject a fetch the same way, with an opaque TypeError, and
        \\// both reach the application as "the request did not happen". The most
        \\// common cause of the first is a redirect to ANOTHER ORIGIN, which the
        \\// browser follows and `connect-src` then refuses, so the application is
        \\// told the network failed when what really happened is that the server
        \\// redirected somewhere the page is not allowed to go.
        \\//
        \\// The browser does say which it was, just not through the fetch: it fires
        \\// `securitypolicyviolation`. Recording the last one lets the failure path
        \\// name the real cause, with the URI that was refused.
        \\let lastViolation = null;
        \\document.addEventListener("securitypolicyviolation", (e) => {{
        \\  lastViolation = {{
        \\    uri: e.blockedURI,
        \\    directive: e.effectiveDirective || e.violatedDirective,
        \\    at: performance.now(),
        \\  }};
        \\}});
        \\const explainFailure = (method, url, startedAt) => {{
        \\  const v = lastViolation;
        \\  if (!v || v.at < startedAt) return;
        \\  // `blockedURI` is NOT always the address that was refused, and the case
        \\  // where it is not is the case this whole message exists for.
        \\  //
        \\  // A refusal inside a redirect the browser followed is reported by
        \\  // Firefox as the ORIGINAL request url, because naming the target would
        \\  // hand a cross-origin address to a page that was just forbidden from
        \\  // seeing it. Other browsers withhold it as "" or as a keyword. Printing
        \\  // it verbatim in the first case says the page's policy refused the
        \\  // page's own same-origin url, which sends a reader off to check a
        \\  // `connect-src 'self'` that is perfectly correct: exactly the wasted
        \\  // afternoon this line is here to prevent.
        \\  //
        \\  // Matching it against what was actually asked for is what tells the two
        \\  // apart. Equal means the browser substituted, so it disclosed nothing.
        \\  let asked = url;
        \\  try {{
        \\    asked = new URL(url, location.href).href;
        \\  }} catch {{}}
        \\  const disclosed =
        \\    v.uri && v.uri !== "inline" && v.uri !== "eval" && v.uri !== asked;
        \\  const what = disclosed
        \\    ? "refused " + v.uri
        \\    : "refused it without saying where: a browser names the request's own " +
        \\      "address, or none at all, when it will not disclose where a redirect led";
        \\  console.error(
        \\    "phantom: " + method + " " + url + " did not fail on the network. This " +
        \\    "page's Content-Security-Policy " + what + " (" + v.directive +
        \\    "). A redirect to another origin is the usual cause. Your application " +
        \\    "sees this as a transport failure, because fetch does not tell the two " +
        \\    "apart; a route whose redirect IS the answer has to be navigated to " +
        \\    "rather than requested.",
        \\  );
        \\}};
        \\
        \\const sendAsync = async (mp, ml, up, ul, hp, hl, bp, bl, out) => {{
        \\  const method = str(mp, ml), url = str(up, ul);
        \\  const headers = parseHeaders(str(hp, hl));
        \\  const body = bl === 0 ? undefined : str(bp, bl);
        \\  const startedAt = performance.now();
        \\  try {{
        \\    // same-origin sends the page's cookies, which is what a session
        \\    // rides on. manual leaves a redirect visible as a status instead
        \\    // of following it into an opaque response nothing can read.
        \\    //
        \\    // "manual" was tried and is WORSE than following. The spec makes
        \\    // it an opaque-redirect response: status 0, no headers, no body.
        \\    // So a 303 would reach the wasm as `HTTP/1.1 0` with nothing in
        \\    // it, which is less use than the page the redirect led to. The
        \\    // browser follows it instead, which also means the client's own
        \\    // redirect handling never sees a 3xx and never engages.
        \\    //
        \\    // WHAT AN APPLICATION LOSES: it cannot see that a redirect happened
        \\    // at all, only where it ended up. A route whose 3xx IS the answer, a
        \\    // sign-in that answers 303 to an identity provider, cannot be driven
        \\    // through the client and has to be reached by navigating instead.
        \\    const res = await fetch(url, {{
        \\      method, headers, body,
        \\      credentials: "same-origin",
        \\      redirect: "follow",
        \\    }});
        \\    return reply(out, res.status, headerBlock(res.headers), await res.text());
        \\  }} catch {{
        \\    // The request never happened. Zero here is NOT a status: the wasm
        \\    // side reads it as "nothing answered", which is a different thing
        \\    // to report than any reply a server could send.
        \\    explainFailure(method, url, startedAt);
        \\    return 0;
        \\  }}
        \\}};
        \\const headerBlock = (h) => {{
        \\  let s = "";
        \\  for (const [k, v] of h) s += k + ": " + v + "\r\n";
        \\  return s;
        \\}};
        \\
        \\const sendSync = (mp, ml, up, ul, hp, hl, bp, bl, out) => {{
        \\  const method = str(mp, ml), url = str(up, ul);
        \\  const headers = parseHeaders(str(hp, hl));
        \\  const body = bl === 0 ? null : str(bp, bl);
        \\  const startedAt = performance.now();
        \\  try {{
        \\    const xhr = new XMLHttpRequest();
        \\    xhr.open(method, url, false);
        \\    xhr.withCredentials = true;
        \\    for (const k of Object.keys(headers)) xhr.setRequestHeader(k, headers[k]);
        \\    xhr.send(body);
        \\    return reply(out, xhr.status, xhr.getAllResponseHeaders(), xhr.responseText);
        \\  }} catch {{
        \\    explainFailure(method, url, startedAt);
        \\    return 0;
        \\  }}
        \\}};
        \\
        \\// Styling, through the CSSOM. A `style` ATTRIBUTE and the TEXT of a
        \\// `<style>` element are both markup, and a Content Security Policy without
        \\// `'unsafe-inline'` refuses both, which blanks a page that positions every
        \\// node with one. Assignment through `element.style` is not refused: the
        \\// policy's `script-src` already decided whether script runs at all, so a
        \\// script reaching the CSSOM adds nothing an attacker did not already have.
        \\//
        \\// The declaration is split here rather than in wasm so that a node still
        \\// costs ONE crossing, exactly as the attribute did, instead of one per
        \\// property. Splitting on ";" is safe for what this backend emits: colours
        \\// are `rgba(1,2,3,0.5)`, which carries commas and never a semicolon.
        \\const setStyle = (node, ptr, len) => {{
        \\  const el = host.value(node);
        \\  if (!el) return;
        \\  for (const part of str(ptr, len).split(";")) {{
        \\    const i = part.indexOf(":");
        \\    if (i <= 0) continue;
        \\    el.style.setProperty(part.slice(0, i).trim(), part.slice(i + 1).trim());
        \\  }}
        \\}};
        \\
        \\// Rules go into the element's SHEET, for the same reason and with one extra
        \\// condition: a style element that is not yet in the document has no sheet,
        \\// so the caller appends it first. A rule the browser will not parse throws
        \\// rather than being ignored, and one bad rule must not cost the rest of the
        \\// frame, so each is tried on its own.
        \\const addRule = (node, ptr, len) => {{
        \\  const el = host.value(node);
        \\  const sheet = el && el.sheet;
        \\  if (!sheet) return;
        \\  for (const rule of splitRules(str(ptr, len))) {{
        \\    try {{
        \\      sheet.insertRule(rule, sheet.cssRules.length);
        \\    }} catch (e) {{
        \\      console.warn("phantom: a style rule was refused: " + rule, e);
        \\    }}
        \\  }}
        \\}};
        \\// One rule per `}}` at nesting depth zero. `@font-face {{ ... }}` and
        \\// `.pb0:hover {{ ... }}` both come through here, so a plain split on "}}"
        \\// would cut an at-rule in half.
        \\const splitRules = (css) => {{
        \\  const out = [];
        \\  let depth = 0, start = 0;
        \\  for (let i = 0; i < css.length; i++) {{
        \\    if (css[i] === "{{") depth++;
        \\    else if (css[i] === "}}" && --depth === 0) {{
        \\      const rule = css.slice(start, i + 1).trim();
        \\      if (rule) out.push(rule);
        \\      start = i + 1;
        \\    }}
        \\  }}
        \\  return out;
        \\}};
        \\
        \\const imports = {{
        \\  ...host.imports,
        \\  phantom: {{
        \\    __phantom_http_send: jspi ? new WebAssembly.Suspending(sendAsync) : sendSync,
        \\    __phantom_set_style: setStyle,
        \\    __phantom_add_rule: addRule,
        \\  }},
        \\}};
        \\({{ instance }} = await WebAssembly.instantiateStreaming(fetch("./{s}.wasm"), imports));
        \\host.attach(instance);
        \\
        \\// Under JSPI an export that can reach a suspending import has to be
        \\// wrapped, and it then returns a promise. Everything that can run
        \\// application code can reach one, so all of them are wrapped.
        \\const wrap = (f) => (jspi ? WebAssembly.promising(f) : f);
        \\const ex = instance.exports;
        \\const w = {{
        \\  init: wrap(ex.init), tick: wrap(ex.tick), resize: wrap(ex.resize),
        \\  dispatchTap: wrap(ex.dispatchTap), dispatchKey: wrap(ex.dispatchKey),
        \\  dispatchChar: wrap(ex.dispatchChar), dispatchText: wrap(ex.dispatchText),
        \\  locationChanged: wrap(ex.locationChanged),
        \\}};
        \\
        \\// True while the tree is on the stack, which under JSPI includes the
        \\// whole time a request is parked. Re-entering it there would build and
        \\// paint from inside a half-finished frame, so events that arrive
        \\// meanwhile are dropped. The synchronous path cannot deliver an event
        \\// mid-call at all, so this costs it nothing.
        \\let busy = false;
        \\const enter = async (f) => {{
        \\  if (busy) return 0;
        \\  busy = true;
        \\  try {{ return await f(); }} finally {{ busy = false; }}
        \\}};
        \\
        \\const documentHandle = host.intern(document);
        \\const bodyHandle = host.intern(document.body);
        \\const windowHandle = host.intern(window);
        \\const app = await w.init(documentHandle, bodyHandle, windowHandle);
        \\document.body.addEventListener("click", (e) => enter(() => w.dispatchTap(app, e.clientX, e.clientY)));
        \\
        \\// The keyboard. These numbers are X11 keysyms, which is what
        \\// phantom.input.Keysym holds: the wasm side takes each one as it is, so
        \\// this table is the whole keymap. A pair is [left, right].
        \\const KEYSYMS = {{
        \\  Backspace: 0xff08, Tab: 0xff09, Enter: 0xff0d, Escape: 0xff1b,
        \\  Home: 0xff50, ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53,
        \\  ArrowDown: 0xff54, PageUp: 0xff55, PageDown: 0xff56, End: 0xff57,
        \\  Insert: 0xff63, Delete: 0xffff,
        \\  F1: 0xffbe, F2: 0xffbf, F3: 0xffc0, F4: 0xffc1, F5: 0xffc2, F6: 0xffc3,
        \\  F7: 0xffc4, F8: 0xffc5, F9: 0xffc6, F10: 0xffc7, F11: 0xffc8, F12: 0xffc9,
        \\  Shift: [0xffe1, 0xffe2], Control: [0xffe3, 0xffe4],
        \\  Alt: [0xffe9, 0xffea], Meta: [0xffeb, 0xffec],
        \\}};
        \\const keysymOf = (e) => {{
        \\  const sym = KEYSYMS[e.key];
        \\  if (sym === undefined) return undefined;
        \\  // DOM_KEY_LOCATION_RIGHT is 2, which is the right hand key of a pair.
        \\  return Array.isArray(sym) ? sym[e.location === 2 ? 1 : 0] : sym;
        \\}};
        \\const modsOf = (e) =>
        \\  (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
        \\const onKey = (e, action) => {{
        \\  // An IME owns the keys that compose a word. They arrive here as well,
        \\  // and typing them would put the raw keys next to the word the IME
        \\  // commits. keyCode 229 is what a browser sends while composing.
        \\  if (e.isComposing || e.keyCode === 229) return;
        \\  const sym = keysymOf(e);
        \\  // preventDefault has to be called during the event, and under JSPI
        \\  // the dispatch answers with a promise, so its answer arrives too
        \\  // late to decide with. `focusHeld` is the synchronous stand-in: a
        \\  // tree holding the keyboard is a tree the key belongs to, which is
        \\  // the same rule a browser applies to a focused input. Tab is added
        \\  // because it enters the tree even when nothing is focused yet.
        \\  const claimed = jspi
        \\    ? ex.focusHeld(app) !== 0 || e.key === "Tab"
        \\    : null;
        \\  let used;
        \\  if (sym !== undefined) {{
        \\    used = w.dispatchKey(app, sym, modsOf(e), action);
        \\  }} else {{
        \\    // Everything else that is one character long is printable. `key`
        \\    // holds the character the layout and the shift state resolved to.
        \\    const chars = [...e.key];
        \\    if (chars.length !== 1) return;
        \\    used = w.dispatchChar(app, chars[0].codePointAt(0), modsOf(e), action);
        \\  }}
        \\  if (claimed === null ? used : claimed) e.preventDefault();
        \\}};
        \\window.addEventListener("keydown", (e) => enter(() => onKey(e, e.repeat ? 1 : 0)));
        \\window.addEventListener("keyup", (e) => enter(() => onKey(e, 2)));
        \\
        \\// A whole string at once. The wasm side owns the bytes, so it hands back
        \\// an address to write them into. Read `memory.buffer` AFTER that call:
        \\// growing the heap detaches the ArrayBuffer that was there before.
        \\const sendText = (text) => {{
        \\  if (!text) return false;
        \\  const bytes = new TextEncoder().encode(text);
        \\  const ptr = ex.textBuffer(bytes.length);
        \\  if (ptr === 0) return false;
        \\  new Uint8Array(mem(), ptr, bytes.length).set(bytes);
        \\  return w.dispatchText(app, ptr, bytes.length);
        \\}};
        \\// A paste fires no keydown at all. An invite code, a password or a URL is
        \\// pasted far more often than it is typed, so a page that only reads keys
        \\// looks broken rather than unfinished.
        \\window.addEventListener("paste", (e) => {{
        \\  // No clipboardData at all on a paste a browser will not let a page
        \\  // read. `sendText` refuses the empty string, so both end the same way.
        \\  // A paste is always the tree's to take when a field holds the
        \\  // keyboard, and the answer under JSPI arrives too late to ask.
        \\  if (ex.focusHeld(app) !== 0) e.preventDefault();
        \\  enter(() => sendText(e.clipboardData?.getData("text")));
        \\}});
        \\// The IME commits its finished word here, after the keys that composed it
        \\// went to the IME and never reached the page.
        \\window.addEventListener("compositionend", (e) => enter(() => sendText(e.data)));
        \\
        \\// The back/forward buttons move the address bar and then fire this,
        \\// with no string to pass in: the wasm side reads the new location
        \\// back itself, so the JS host never allocates inside the module.
        \\window.addEventListener("popstate", () => enter(() => w.locationChanged(app)));
        \\const onResize = () => enter(() => w.resize(app, window.innerWidth, window.innerHeight, window.devicePixelRatio));
        \\window.addEventListener("resize", onResize);
        \\matchMedia(`(resolution: ${{window.devicePixelRatio}}dppx)`).addEventListener("change", onResize);
        \\// t is the rAF timestamp: monotonic, same origin as performance.now.
        \\// Date.now is the wall clock and can step backwards. They are passed
        \\// separately because the scheduler must never arm against the second.
        \\const frame = (t) => {{
        \\  enter(() => w.tick(app, Date.now(), t));
        \\  requestAnimationFrame(frame);
        \\}};
        \\requestAnimationFrame(frame);
    , .{ runtime_import, wasm_name });
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
