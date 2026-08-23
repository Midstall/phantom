const std = @import("std");
const phantom = @import("phantom");
const dom = @import("dom");
const hello = @import("hello.zig");

const DomCtx = struct { doc: u32 };
var dom_ctx: DomCtx = undefined;

fn createElement(ctx: *anyopaque, tag: []const u8) u32 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const doc = dom.Document{ .handle = c.doc };
    return doc.createElement(tag).handle;
}
fn createTextNode(ctx: *anyopaque, data: []const u8) u32 {
    const c: *DomCtx = @ptrCast(@alignCast(ctx));
    const doc = dom.Document{ .handle = c.doc };
    return doc.createTextNode(data).handle;
}
fn setAttribute(ctx: *anyopaque, node: u32, name: []const u8, value: []const u8) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.setAttribute(name, value);
}
fn setTextContent(ctx: *anyopaque, node: u32, textv: []const u8) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.set_textContent(textv);
}
fn appendChild(ctx: *anyopaque, parent: u32, child: u32) void {
    _ = ctx;
    const el = dom.Element{ .handle = parent };
    _ = el.appendChild(dom.Node{ .handle = child });
}
fn clearChildren(ctx: *anyopaque, node: u32) void {
    _ = ctx;
    const el = dom.Element{ .handle = node };
    el.set_innerHTML("");
}

/// Build the persistent WebApp and return its pointer as a usize so JS can
/// hold it and pass it back to dispatchTap. Returns 0 on allocation failure.
export fn init(doc_handle: u32, body_handle: u32, window_handle: u32) usize {
    const win = dom.Window{ .handle = window_handle };
    const vw: u32 = win.get_innerWidth();
    const vh: u32 = win.get_innerHeight();
    const dpr: f64 = win.get_devicePixelRatio();
    dom_ctx = .{ .doc = doc_handle };
    const doc = dom.Document{ .handle = doc_handle };
    const head = doc.get_head().handle;
    const ops = phantom.backend.dom_calls.DomOps{
        .ctx = &dom_ctx,
        .create_element = createElement,
        .create_text_node = createTextNode,
        .set_attribute = setAttribute,
        .set_text_content = setTextContent,
        .append_child = appendChild,
        .clear_children = clearChildren,
        .body = body_handle,
        .head = head,
    };
    const app = phantom.web.init(
        std.heap.wasm_allocator,
        ops,
        phantom.Root.plain(hello.root),
        .{ .width = @floatFromInt(vw), .height = @floatFromInt(vh) },
        @floatCast(dpr),
    ) catch return 0;
    return @intFromPtr(app);
}

/// Dispatch a tap at (x, y) CSS px into the persistent tree and re-render.
/// app is the usize returned by init; a zero app is silently ignored.
export fn dispatchTap(app: usize, x: f32, y: f32) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.dispatchTap(x, y);
}

/// Update the viewport size and DPR and re-render. Called on window resize and
/// devicePixelRatio change. app is the usize returned by init; zero is ignored.
export fn resize(app: usize, w: u32, h: u32, dpr: f64) void {
    if (app == 0) return;
    const a: *phantom.web.WebApp = @ptrFromInt(app);
    a.resize(.{ .width = @floatFromInt(w), .height = @floatFromInt(h) }, @floatCast(dpr));
}
