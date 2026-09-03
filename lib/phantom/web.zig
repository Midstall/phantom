const std = @import("std");
const phantom = @import("../phantom.zig");

/// Heap-allocated, page-lifetime web app. JS holds the pointer returned by init
/// (as a usize) and passes it back to every dispatch entry. No module-level globals.
pub const WebApp = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    sink: *phantom.FaultSink,
    owner: *phantom.BuildOwner,
    root: *phantom.Element,
    view: *phantom.View,
    ops: phantom.backend.dom_calls.DomOps,
    dispatcher: phantom.input.Dispatcher = .{},
    /// Holds the keyboard. Page-lifetime, next to the pointer dispatcher and for
    /// the same reason: `Element.deinit` reaches back into it to forget the
    /// handlers of an unmounted node, so it must outlive every tree it collected.
    focus: phantom.FocusManager = .{},
    /// Sockets that are really `fetch`. See `web_net.zig`.
    net: phantom.web_net.Net,
    /// Scroll offsets carried across a rebuild. Lives for the whole page, not
    /// per render: `render` reads last frame's regions out of it before it
    /// clears the DOM, then repopulates it with this frame's regions.
    scroll_mem: phantom.backend.dom_calls.ScrollMemory = .{},
    /// Nanoseconds since the Unix epoch, from the browser's `Date.now`. This is
    /// the settable clock: NTP and a timezone edit both move it, and it can move
    /// backwards. Only a time of day is read from it. Zero until the first tick.
    wall_ns: i96 = 0,
    /// Nanoseconds since the page time origin, from the browser's
    /// `performance.now`. Never moves backwards, so every deadline is armed
    /// against this one. Zero until the first tick.
    mono_ns: i96 = 0,

    /// Called by the browser once per animation frame. Advances both clocks,
    /// fires due callbacks, and repaints only if something asked for it.
    ///
    /// The scheduler runs on the monotonic clock alone. Armed against wall time,
    /// an NTP step backwards would push every periodic deadline into the future,
    /// and because the repaint below is conditional the page would stop drawing
    /// for the whole length of the step.
    pub fn tick(self: *WebApp, wall_ms: f64, mono_ms: f64) void {
        // Widen the wall clock before the multiply. Date.now is about 1.77e12,
        // and 1.77e12 times 1e6 is past f64's 2^53 exact-integer range, so
        // multiplying in f64 would quantise it to roughly 256 ns. Date.now has
        // no fractional part, so truncating to an integer costs nothing. The
        // monotonic value is small enough to stay exact in f64 and it does carry
        // a fraction, so that one is multiplied as a float.
        self.wall_ns = @as(i96, @intFromFloat(wall_ms)) * std.time.ns_per_ms;
        self.mono_ns = @intFromFloat(mono_ms * std.time.ns_per_ms);
        self.owner.scheduler.tick(self.mono_ns);
        // An unconditional render would rebuild the whole DOM 60 times a
        // second, so repaint only when a callback marked something dirty.
        if (self.owner.dirty.items.len > 0) self.render();
    }

    pub fn render(self: *WebApp) void {
        // One BuildContext per render for flushDirty + layout + paint.
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = self.owner };
        self.owner.flushDirty(&bctx);
        // A rebuild can add or remove focusable nodes, so the traversal order is
        // rebuilt from the tree rather than kept incrementally. The terminal and
        // window backends do this at the same point in their frame.
        self.focus.collect(self.gpa, self.root) catch {
            // What is left is a partial order, so Tab may not reach every node
            // until a later build collects the whole tree. The frame still draws:
            // a page that stops painting because it ran out of memory for one list
            // is worse than a page whose Tab order is short.
            self.sink.report(.oom, "the web focus order was not rebuilt");
        };
        const physical = self.view.metrics.size.toPhysical(self.view.metrics.text_scale);
        var canvas = phantom.Canvas.init(self.gpa);
        canvas.sink = self.sink;
        defer canvas.deinit();
        const ro = self.root.renderObject() orelse return;
        _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, self.view.metrics.text_scale));
        // A dropped frame leaves the previous DOM on screen, which is
        // indistinguishable from "nothing changed" unless it is recorded.
        ro.paint(&canvas, phantom.PhysicalOffset.zero) catch |err| {
            self.sink.report(.render_failed, @errorName(err));
        };
        // Consumed once per navigation: a route change sets this before the
        // render it causes, and this render is the only one that reads it.
        const reset_scroll = self.owner.route_changed;
        self.owner.route_changed = false;
        phantom.backend.dom_calls.render(self.gpa, self.ops, canvas.list, physical, phantom.ColorScheme.tokyoNight().bg, self.sink, &self.scroll_mem, reset_scroll) catch |err| {
            self.sink.report(.render_failed, @errorName(err));
        };
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn dispatchTap(self: *WebApp, x: f32, y: f32) void {
        // Web layout scale = text_scale = 1.0, so clientX/Y are physical coords.
        const p = phantom.PhysicalOffset{ .x = x, .y = y };
        // The focus moves before the tap is delivered, so a handler that moves it
        // somewhere else of its own accord (a button that focuses a search box) has
        // the last word instead of being undone by the tap that ran it.
        self.focusAt(p);
        self.dispatcher.down(self.root, p);
        self.dispatcher.up(self.root, p);
        self.render();
    }

    /// Move the keyboard focus to whatever takes it under `p`.
    ///
    /// A browser gives a page one focus of its own and no more, so nothing else
    /// tells the tree which field the user aimed at: without this, a tapped field
    /// keeps drawing as unfocused and every key goes to whatever Tab last reached.
    fn focusAt(self: *WebApp, p: phantom.PhysicalOffset) void {
        if (phantom.input.hitTestFocus(self.root, p)) |h| {
            // False when the node is not in the traversal order, which is what an
            // unavailable node (a disabled field) looks like from here.
            if (self.focus.focusNode(h)) return;
        }
        // A tap on the page background, or on a node that cannot take the focus, is
        // how a user says they have finished with the field they were in. A caret
        // left blinking in it would take the keys the user types next.
        self.focus.clear();
    }

    /// Route one key into the focused node. Returns true when the tree used it,
    /// which is what the host page turns into `preventDefault`: a key the tree took
    /// must not also scroll the page or move the browser's own focus ring off it.
    pub fn dispatchKey(self: *WebApp, ev: phantom.input.KeyEvent) bool {
        const used = self.focus.dispatch(ev);
        // A key nothing used changed nothing, so there is nothing new to draw. A
        // used key usually marks something dirty, and the page's animation frame
        // would draw it a frame later; drawing here as well is what keeps a host
        // that runs no frame loop showing what the user typed.
        if (used) self.render();
        return used;
    }

    /// Route one printable key. `cp` is the codepoint the browser resolved for the
    /// key, which already has the shift state and the keyboard layout folded into
    /// it, so no keymap is needed on this side.
    ///
    /// Text rides along only when no ctrl, alt or super is held. Ctrl+V is a
    /// shortcut and not the letter v, and a text field inserts `text` without ever
    /// reading the keysym, so text on a modified key would type the letter of every
    /// shortcut the user pressed. The keysym is filled in either way, which leaves
    /// the shortcut itself readable to a `KeyboardListener`.
    pub fn dispatchChar(self: *WebApp, cp: u21, mods: phantom.input.Mods, action: phantom.input.KeyAction) bool {
        var buf: [4]u8 = undefined;
        // A lone surrogate, or a value past the last codepoint: the host sent
        // something no key produces, so there is nothing to type and nothing to
        // name it by either.
        const n = std.unicode.utf8Encode(cp, &buf) catch return false;
        const modified = mods.ctrl or mods.alt or mods.super;
        return self.dispatchKey(.{
            .keysym = phantom.input.Keysym.fromCodepoint(cp),
            .text = if (modified) null else buf[0..n],
            .mods = mods,
            .action = action,
        });
    }

    /// Insert a whole string at the focus, as one edit. This is the paste path and
    /// the IME path.
    ///
    /// A per-key entry carries neither of them. A pasted invite code arrives as one
    /// `paste` event holding 32 characters and fires no keydown at all, and an IME
    /// commits its word on `compositionend`, after the keys that composed it went to
    /// the IME instead of the page. Without this the field looks broken rather than
    /// unfinished, because the characters simply never arrive.
    ///
    /// The whole string rides on one `KeyEvent`, because that is what the focus path
    /// already speaks and what a text field already inserts. No keysym names a run
    /// of characters, so a run carries `no_symbol`; one character keeps its own
    /// keysym, which leaves a one character paste identical to typing it.
    pub fn dispatchText(self: *WebApp, text: []const u8) bool {
        if (text.len == 0) return false;
        return self.dispatchKey(.{ .keysym = soleKeysym(text), .text = text });
    }

    /// Update the active View metrics (window resized or DPR changed) and
    /// re-render. Mutates the existing boxed View in place, so the installed
    /// MediaQuery.data pointer stays valid and reads the new size.
    pub fn resize(self: *WebApp, logical: phantom.LogicalSize, dpr: f32) void {
        self.owner.setActiveViewMetrics(.{ .size = logical, .dpr = dpr, .text_scale = 1.0 });
        self.render();
    }

    /// The browser moved back or forward. The address bar already holds the new
    /// path, so this only tells the tree. It does nothing when the tree has no
    /// router, which is every application that does not use one.
    pub fn navigate(self: *WebApp, path: []const u8) void {
        const h = self.owner.router orelse return;
        applyLocation(h, path);
        // Covers the case `applyLocation` cannot: a matched Back press calls
        // `State.pop`, not `.push`/`.replace`, so nothing else sets this flag
        // for it. Every address-bar-driven change is a navigation, so this
        // render drops the old route's scroll offsets, the same as the two
        // in-app paths.
        self.owner.route_changed = true;
        self.render();
    }

    /// The browser moved back or forward, or a host tells the tree the
    /// address changed some other way. Reads the new path through the same
    /// hook the tree already writes with, then tells the router.
    ///
    /// Does nothing when the address cannot be read: with no read hook, or
    /// when `platform.readLocation` refuses an over-long address. The refusal
    /// itself already reports the fault, at the point where the true length
    /// is still known, so this is not a second silent failure.
    pub fn locationChanged(self: *WebApp) void {
        var buf: [phantom.router.max_path]u8 = undefined;
        const path = self.owner.platform.readLocation(&buf) orelse return;
        self.navigate(path);
    }
};

/// The keysym for `text` when it holds exactly one codepoint, and `no_symbol` for
/// anything longer. Malformed bytes are input and not a programmer error, so they
/// answer `no_symbol` as well: the text still reaches the field, it is only unnamed.
fn soleKeysym(text: []const u8) phantom.input.Keysym {
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return .no_symbol;
    if (len != text.len) return .no_symbol;
    const cp = std.unicode.utf8Decode(text) catch return .no_symbol;
    return phantom.input.Keysym.fromCodepoint(cp);
}

/// Reconciles the router's stack with a browser-driven address change.
///
/// The rule: pop when `path` is the entry already sitting below the stack's
/// top, replace otherwise.
///
/// Back and forward both arrive here as a bare path; the History API gives no
/// direction. A press of Back always lands on the entry the router's stack
/// already holds one below its top, because that is what "back" means, so
/// that case pops and the stack shrinks. Forward, and any other address
/// change, do not match a below-top entry: a popped entry is gone from the
/// router's stack the instant it pops, so the router has nothing to push
/// back. Rather than guess a forward stack it does not have, it replaces the
/// top so the built route tracks the address bar. Replacing here is what
/// keeps the stack from growing on a busy back-and-forth: only a real push
/// (a tapped `RouteLink`) grows it, and only a matched pop shrinks it.
fn applyLocation(h: phantom.RouterHandle, path: []const u8) void {
    if (h.isBelowTop(path)) {
        _ = h.pop();
    } else {
        h.replace(path);
    }
}

fn openUrlThunk(ctx: *anyopaque, url: []const u8, mode: phantom.OpenMode) bool {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.open_url` is set, so the
    // hook is never null here. Its answer is passed through rather than
    // replaced with `true`: a browser that refused the call said so.
    return app.ops.open_url.?(app.ops.ctx, url, mode);
}

fn readLocationThunk(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.read_location` is set, so the
    // hook is never null here.
    return app.ops.read_location.?(app.ops.ctx, buf) orelse {
        // The real address does not fit `buf`. Taking the first max_path
        // bytes would land the tree on a different, shorter route than the
        // one the user is actually on, so the read is refused instead.
        app.sink.report(.location_too_long, "the browser address is longer than the buffer that reads it");
        return null;
    };
}

fn readQueryThunk(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.read_query` is set, so the
    // hook is never null here.
    return app.ops.read_query.?(app.ops.ctx, buf) orelse {
        // The same refusal `readLocationThunk` makes, for the same reason: the
        // first bytes of a query are a different query. A truncated `?state=`
        // would be handed to whatever reads it as if it were the whole value,
        // and a state token that is nearly right is worse than none.
        app.sink.report(.location_too_long, "the browser query string is longer than the buffer that reads it");
        return null;
    };
}

fn readHostThunk(ctx: *anyopaque, buf: []u8) ?[]const u8 {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.read_host` is set, so the hook
    // is never null here.
    return app.ops.read_host.?(app.ops.ctx, buf) orelse {
        // Refused for the same reason a long path and a long query are: the
        // first bytes of a host name are a DIFFERENT machine, and this one is
        // about to be put in a URL an application will send credentials to.
        app.sink.report(.location_too_long, "the page host is longer than the buffer that reads it");
        return null;
    };
}

fn writeLocationThunk(ctx: *anyopaque, path: []const u8, mode: phantom.WriteMode) void {
    const app: *WebApp = @ptrCast(@alignCast(ctx));
    // `init` installs this thunk only when `ops.write_location` is set, so
    // the hook is never null here.
    // Skip the browser call when the address bar already shows this path. A
    // browser-driven back or forward already moved it before this runs
    // (through `locationChanged`), and writing again would add a duplicate
    // history entry, turning one back-button press into two.
    if (app.ops.read_location) |read| {
        var buf: [phantom.router.max_path]u8 = undefined;
        if (read(app.ops.ctx, &buf)) |cur| {
            if (std.mem.eql(u8, cur, path)) return;
        }
    }
    app.ops.write_location.?(app.ops.ctx, path, mode);
}

fn webNow(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    // The browser publishes two clocks and they are not interchangeable, so the
    // tag decides which one answers. Exhaustive with no `else`: a new tag must
    // fail to compile rather than land on whichever arm is listed first.
    return switch (clock) {
        // Date.now, the settable one, in Unix epoch nanoseconds.
        .real => .{ .nanoseconds = app.wall_ns },
        // performance.now, monotonic from the page time origin. It usually keeps
        // counting while the machine is suspended, which is exactly `boot`;
        // `awake` accepts that, because its own contract says an implementation
        // may include suspended time when it cannot exclude it.
        .awake, .boot => .{ .nanoseconds = app.mono_ns },
        // No browser exposes per-process or per-thread CPU time: the high
        // resolution timers that would measure it were cut back for Spectre. The
        // zero timestamp is the same answer `std.Io.noNow` gives, and it agrees
        // with `clockResolution`, which still reports these unavailable. Handing
        // back wall time instead would pass elapsed time off as CPU time.
        .cpu_process, .cpu_thread => std.Io.Timestamp.zero,
    };
}

/// Fill `buffer` from the host's secure random source. False when the host has
/// no such source, which is a host that left `DomOps.fill_random` null.
fn fillRandom(app: *WebApp, buffer: []u8) bool {
    const f = app.ops.fill_random orelse return false;
    return f(app.ops.ctx, buffer);
}

/// `std.Io`'s ordinary randomness. Returns void, so it has no way at all to say
/// it failed, which is why the answer to a missing source is to stop.
///
/// `std.Io.failing.noRandom` zeroes the buffer and returns as if it had worked.
/// Code that draws a token, a nonce or a shuffle from it gets a constant and no
/// error, and on the web that reads as working code right up until somebody
/// looks at the bytes. A build that reaches this without a source is a wiring
/// mistake in the host, which is a programmer error and not a runtime fault, so
/// it fails loudly rather than quietly.
fn webRandom(userdata: ?*anyopaque, buffer: []u8) void {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    if (!fillRandom(app, buffer)) {
        @panic("phantom web: randomness was asked for and this host wired no random source");
    }
}

/// The secure one, which CAN report a failure, so it does instead of stopping.
/// `crypto.getRandomValues` throws on a buffer past 65536 bytes and in a context
/// with no entropy, and both arrive here as false.
fn webRandomSecure(userdata: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    if (!fillRandom(app, buffer)) return error.EntropyUnavailable;
}

// ---------------------------------------------------------------------------
// Sockets over `fetch`. See `web_net.zig` for what a connection actually is.
// ---------------------------------------------------------------------------

const net = std.Io.net;

/// Whether a socket handle carries anything on this target.
///
/// `net.Socket.Handle` is `std.posix.fd_t`, and wasm32-freestanding has no OS to
/// hand out descriptors, so there it is `void`: a socket on the real web target
/// carries NO identity, and `netRead` cannot be told which connection it is for.
///
/// So the connection has to be implicit there, and it is safe to make it so
/// because nothing here runs concurrently. A request is written and then read in
/// one unbroken run on the single thread a page has, and the read is what sends
/// it, so exactly one connection is ever being used at a time even when the
/// client pool holds several open. Natively the handle is a real number, the slot
/// travels in it, and the tests exercise that path properly.
const handled = @typeInfo(net.Socket.Handle) != .void;

fn handleFor(slot: usize) net.Socket.Handle {
    if (comptime handled) return @intCast(slot);
    return {};
}

fn slotFor(app: *WebApp, h: net.Socket.Handle) usize {
    if (comptime handled) return @intCast(h);
    return app.net.current;
}

/// A lookup that resolves nothing, because a browser does its own DNS and will
/// not share it. The name is parked and the address handed back stands for it,
/// which is all `netConnectIp` needs to build the request.
///
/// The address is a loopback one on purpose: nothing here ever reaches a socket,
/// and if any of it ever escaped into code that does dial, dialling `127.0.0.x`
/// fails at once and locally rather than reaching a stranger.
fn webNetLookup(
    userdata: ?*anyopaque,
    host_name: net.HostName,
    resolved: *std.Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    const io = webIo(app);
    // The contract of `lookup` is that this closes the queue before returning,
    // on the error path as well, or the caller waits on it forever.
    defer resolved.close(io);

    const tag = app.net.remember(host_name.bytes, options.port) orelse return error.UnknownHostName;
    const addr: net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, tag }, .port = options.port } };
    resolved.putOneUncancelable(io, .{ .address = addr }) catch return error.NoAddressReturned;
    resolved.putOneUncancelable(io, .{ .canonical_name = host_name }) catch return error.NoAddressReturned;
}

fn webNetConnectIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    _ = options;
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    // An address that came from `webNetLookup` carries the name in its last
    // byte. One that did not is dialled by its literal text, which is what a
    // caller that skipped the lookup and typed an address meant.
    var literal: [64]u8 = undefined;
    const host: []const u8, const port: u16 = switch (address.*) {
        .ip4 => |v4| if (v4.bytes[0] == 127 and app.net.recall(v4.bytes[3]) != null) blk: {
            const n = app.net.recall(v4.bytes[3]).?;
            break :blk .{ n.host, n.port };
        } else .{
            std.fmt.bufPrint(&literal, "{d}.{d}.{d}.{d}", .{ v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3] }) catch
                return error.ConnectionRefused,
            v4.port,
        },
        // No browser request is addressed by a raw IPv6 literal in practice, and
        // refusing is better than inventing a host name that resolves elsewhere.
        .ip6 => return error.NetworkUnreachable,
    };

    const slot = app.net.open(host, port) orelse return error.SystemResources;
    return .{ .handle = handleFor(slot), .address = address.* };
}

fn webNetRead(
    userdata: ?*anyopaque,
    src: net.Socket.Handle,
    data: [][]u8,
) net.Stream.Reader.Error!usize {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    // Fill the first buffer with room in it and return. A short read is always
    // allowed, and one `fetch` is one answer, so there is nothing to gain by
    // spreading it further.
    for (data) |buf| {
        if (buf.len == 0) continue;
        // `web_net.ReadError` is already a subset of what a stream reader may
        // report, so this is a widening and not a translation.
        return app.net.read(slotFor(app, src), buf);
    }
    return 0;
}

fn webNetWrite(
    userdata: ?*anyopaque,
    dest: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    var written: usize = 0;
    written += webWriteAll(app, dest, header) catch |err| return err;
    if (data.len == 0) return written;
    // Everything but the last slice goes once; the last one repeats `splat`
    // times. That is the vectored-write contract and getting it wrong would send
    // a request body that is short or repeated.
    for (data[0 .. data.len - 1]) |d| {
        written += webWriteAll(app, dest, d) catch |err| return err;
    }
    const last = data[data.len - 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        written += webWriteAll(app, dest, last) catch |err| return err;
    }
    return written;
}

fn webWriteAll(app: *WebApp, dest: net.Socket.Handle, bytes: []const u8) net.Stream.Writer.Error!usize {
    return app.net.write(slotFor(app, dest), bytes) catch |err| switch (err) {
        error.SocketUnconnected => error.SocketUnconnected,
        error.OutOfMemory => error.SystemResources,
    };
}

fn webNetClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    const app: *WebApp = @ptrCast(@alignCast(userdata.?));
    for (handles) |h| app.net.close(slotFor(app, h));
}

/// Nothing to shut down: one connection is one `fetch`, and neither half of it
/// can be closed separately. Reporting success is honest, because the caller's
/// intent (stop using this direction) is already true.
fn webNetShutdown(userdata: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    _ = userdata;
    _ = handle;
    _ = how;
}

const web_vtable: std.Io.VTable = blk: {
    // 109 entries, of which three are implementable in a browser. The other 106
    // are taken from `std.Io.failing` verbatim, so this file adds no behaviour it
    // did not implement.
    //
    // `failing` is NOT uniformly failing, and that is the trap this block exists
    // to step around: 15 of its entries are `no*` stubs that SUCCEED with a fixed
    // answer (`noDirRead` reports an empty directory, `noAsync` runs the closure
    // inline). `noRandom` was the dangerous one. It zeroes the buffer and returns
    // as if it had worked, so a web application drawing a nonce or a token got a
    // run of zeros and no error at all: working code, wrong answer, and nothing
    // to notice it by. `random` and `randomSecure` are now real, and every other
    // entry is inherited on purpose.
    //
    // What stays failing is what a browser genuinely cannot do: files, dirs,
    // processes, sockets and futexes. A sandbox has none of them, and pretending
    // otherwise would repeat exactly the mistake above.
    var vt = std.Io.failing.vtable.*;
    vt.now = webNow;
    vt.random = webRandom;
    vt.randomSecure = webRandomSecure;
    vt.netLookup = webNetLookup;
    vt.netConnectIp = webNetConnectIp;
    vt.netRead = webNetRead;
    vt.netWrite = webNetWrite;
    vt.netClose = webNetClose;
    vt.netShutdown = webNetShutdown;
    break :blk vt;
};

/// A std.Io backed by the browser: its two clocks and its secure random source.
/// Every other operation is whatever `std.Io.failing` does with it.
pub fn webIo(app: *WebApp) std.Io {
    return .{ .userdata = app, .vtable = &web_vtable };
}

/// Build the widget tree and keep owner/arena/view alive for the page lifetime.
/// Returns a heap-allocated *WebApp; the caller (JS via wasm) must store the
/// returned pointer and pass it to the dispatch entries. Never deinit: the page
/// owns it.
///
/// logical_viewport: window inner size in CSS px (logical; browser handles DPR).
/// device_pixel_ratio: stored in MediaQueryData for widgets to read; NOT applied
/// to layout because the browser maps CSS px to physical pixels via DPR itself.
pub fn init(
    gpa: std.mem.Allocator,
    ops: phantom.backend.dom_calls.DomOps,
    root: phantom.Root,
    logical_viewport: phantom.LogicalSize,
    device_pixel_ratio: f32,
    strategy: phantom.UrlStrategy,
) !*WebApp {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const sink = try gpa.create(phantom.FaultSink);
    sink.* = .{};
    const owner = try gpa.create(phantom.BuildOwner);
    owner.* = .{ .gpa = gpa, .sink = sink };
    const view_id = try phantom.View.open(owner, .{
        .title = "web",
        .size = logical_viewport,
        .dpr = device_pixel_ratio,
        .text_scale = 1.0,
    });
    _ = view_id;
    const view = owner.activeView().?;

    // The WebApp is allocated before the tree is mounted, because the Io borrows
    // its pointer and `owner.io` must already be the browser clock when `mount`
    // runs. `mount` runs every `initState` in the tree, and a State that copies
    // `owner.io` there would keep `std.Io.failing` for the life of the page: its
    // clock would read the zero timestamp on every frame. `root` is the one field
    // mount produces, so it is the one field filled in afterwards.
    const app = try gpa.create(WebApp);
    app.* = .{
        .gpa = gpa,
        .arena = arena,
        .sink = sink,
        .owner = owner,
        .root = undefined,
        .view = view,
        .ops = ops,
        .net = .{ .gpa = gpa },
    };
    // Wire the instance Dispatcher (heap-stable) so Element.deinit forgets the
    // handlers of any unmounted hovered/pressed render object.
    owner.dispatcher = &app.dispatcher;
    // Wired before the tree mounts, for the same reason the terminal and window
    // backends wire theirs first: a mount that fails part way tears the partial
    // tree down, and that walk calls back into the manager to forget each focus
    // handler it finds.
    owner.focus = &app.focus;
    owner.io = webIo(app);
    // Wired before the tree mounts, so a Router's first `sync` (from its
    // initial location) already reaches the address bar, and its first
    // `readLocation` (the deep-link read in `initState`) already reads it.
    //
    // Each hook is installed only when the matching `DomOps` member exists.
    // A host that leaves one null gets a null here too, not a thunk that
    // silently does nothing: `Platform.openUrl` must return false so
    // `Link.tap` reports `link_unsupported`, and `Platform.readLocation` must
    // return null so a missing hook cannot be mistaken for an empty address.
    owner.platform = .{
        .ctx = app,
        .open_url = if (ops.open_url != null) openUrlThunk else null,
        .read_location = if (ops.read_location != null) readLocationThunk else null,
        .read_query = if (ops.read_query != null) readQueryThunk else null,
        .read_host = if (ops.read_host != null) readHostThunk else null,
        .write_location = if (ops.write_location != null) writeLocationThunk else null,
        .strategy = strategy,
    };

    var bctx = phantom.BuildContext{ .arena = arena.allocator(), .owner = owner };
    const root_widget = root.call(&bctx);
    var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
    const root_element = if (sink.ok()) try mq.widget().mount(&bctx, null) else eb: {
        const errbox = phantom.ErrorBox{};
        break :eb try errbox.widget().mount(&bctx, null);
    };
    app.root = root_element;

    // Inject @font-face for all fonts used by the initial render ONCE into <head>.
    // Do one layout+paint into a throwaway canvas to discover which fonts the tree uses,
    // build the CSS block, and append a <style> element before the real first render.
    {
        const physical = view.metrics.size.toPhysical(view.metrics.text_scale);
        var font_canvas = phantom.Canvas.init(gpa);
        font_canvas.sink = sink;
        defer font_canvas.deinit();
        if (root_element.renderObject()) |ro| {
            _ = ro.layout(phantom.BoxConstraints.tightScaled(physical, view.metrics.text_scale));
            // A failure here loses the font list, so the first frame draws in a
            // fallback face. Recording it is the only way that is visible.
            ro.paint(&font_canvas, phantom.PhysicalOffset.zero) catch |err| {
                sink.report(.render_failed, @errorName(err));
            };
        }
        const fonts = try phantom.backend.dom.collectFonts(gpa, font_canvas.list);
        defer gpa.free(fonts);
        if (fonts.len > 0) {
            const css = try phantom.backend.dom_calls.fontFaceCss(gpa, fonts);
            defer gpa.free(css);
            const style_node = ops.createElement("style");
            // In the document first: a detached style element has no sheet for
            // `addRule` to reach. See `DomOps.add_rule`.
            ops.appendChild(ops.head, style_node);
            ops.addRule(style_node, css);
        }
    }

    // Reset the default body margin and paint the branded background to the
    // window edges, ONCE. Applied to the body ELEMENT rather than through a
    // stylesheet, and that choice is load bearing twice over.
    //
    // A browser gives `body` an 8px margin of its own, and the container this
    // backend draws into is sized to the WHOLE viewport, so any margin at all
    // pushes the whole page down and right: two strips of unthemed white at the
    // top and left, and the same amount lost off the bottom and right, unseen.
    //
    // It goes through the element's own style because that is the path this
    // backend already proves on every frame, for every node it positions. A rule
    // in a sheet has one more thing that has to be true, a sheet to put it in,
    // and this is the one declaration whose failure is not cosmetic: it takes
    // the whole page off its origin. The rules that DO need a sheet are the ones
    // that cannot be written any other way, hover and `@font-face`.
    //
    // Setting it on `body` also reaches `html`, because a browser propagates the
    // body's background to the canvas when the root has none of its own.
    {
        const bg = phantom.ColorScheme.tokyoNight().bg;
        const decl = try std.fmt.allocPrint(gpa, "margin:0;background:rgb({d},{d},{d})", .{ phantom.backend.dom.ch(bg.r), phantom.backend.dom.ch(bg.g), phantom.backend.dom.ch(bg.b) });
        defer gpa.free(decl);
        ops.setStyle(ops.body, decl);
    }

    app.render();
    return app;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A WebApp with nothing but its clocks set. Every other field is unreachable
/// from `webIo`, which is the whole surface these tests exercise.
fn clockOnlyApp(wall_ns: i96, mono_ns: i96) WebApp {
    return .{
        .gpa = undefined,
        .arena = undefined,
        .sink = undefined,
        .owner = undefined,
        .root = undefined,
        .view = undefined,
        .ops = undefined,
        // Not undefined: `webIo` hands out the net entries too, and a test that
        // reaches one would walk a table of garbage rather than find it empty.
        .net = .{ .gpa = std.testing.allocator },
        .wall_ns = wall_ns,
        .mono_ns = mono_ns,
    };
}

test "the web std.Io reports the wall clock the browser last pushed" {
    var app = clockOnlyApp(1_500_000_000, 7);
    const ts = std.Io.Clock.now(.real, webIo(&app));
    try std.testing.expectEqual(@as(i96, 1_500_000_000), ts.nanoseconds);
}

test "the web std.Io answers the monotonic clocks with performance.now, not Date.now" {
    // The two differ by decades in the browser, so reading the wrong one is not
    // a rounding difference. Arming a deadline against the wall clock is what
    // stops the page repainting when NTP steps the clock backwards.
    var app = clockOnlyApp(1_767_225_840_000_000_000, 4_200_000_000);
    const io = webIo(&app);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), std.Io.Clock.now(.awake, io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), std.Io.Clock.now(.boot, io).nanoseconds);
}

test "the web std.Io reports no cpu time rather than passing off elapsed time as cpu time" {
    // A browser exposes no CPU accounting at all. Zero is what an unimplemented
    // clock answers, and `clockResolution` still reports these unavailable.
    var app = clockOnlyApp(1_767_225_840_000_000_000, 4_200_000_000);
    const io = webIo(&app);
    try std.testing.expectEqual(@as(i96, 0), std.Io.Clock.now(.cpu_process, io).nanoseconds);
    try std.testing.expectEqual(@as(i96, 0), std.Io.Clock.now(.cpu_thread, io).nanoseconds);
}

test "the web std.Io is identical to std.Io.failing in every entry except the three a browser can answer" {
    // "Identical to failing", not "fails": 15 of failing's entries are `no*`
    // stubs that succeed with a fixed answer. What must hold is that this file
    // implements exactly the operations it claims and inherits the rest
    // unchanged, so the assertion walks the whole vtable rather than sampling.
    //
    // The list is deliberately short and deliberately explicit. Every name added
    // to it is a promise that a browser can really do that thing, and the whole
    // reason `random` had to be taken off `failing` is that `noRandom` made that
    // promise without keeping it.
    // 109 fields times the names below is past the default limit, and the loop
    // is the whole point of the test: it must walk every field.
    @setEvalBranchQuota(8000);
    const implemented = [_][]const u8{
        "now",       "random",       "randomSecure",
        "netLookup", "netConnectIp", "netRead",
        "netWrite",  "netClose",     "netShutdown",
    };
    var app = clockOnlyApp(0, 0);
    const io = webIo(&app);

    var checked: usize = 0;
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |f| {
        comptime var ours = false;
        inline for (implemented) |name| {
            if (comptime std.mem.eql(u8, f.name, name)) ours = true;
        }
        if (ours) {
            try std.testing.expect(@field(io.vtable, f.name) != @field(std.Io.failing.vtable, f.name));
        } else {
            try std.testing.expect(@field(io.vtable, f.name) == @field(std.Io.failing.vtable, f.name));
            checked += 1;
        }
    }
    // A vtable that shrank to nothing would satisfy the loop above vacuously.
    try std.testing.expectEqual(@typeInfo(std.Io.VTable).@"struct".fields.len - implemented.len, checked);
}

test "the web std.Io fills randomness from the host instead of handing back zeros" {
    // The bug this replaces: `std.Io.failing`'s `noRandom` zeroes the buffer and
    // reports success, so a token drawn on the web was a run of zeros and no
    // caller could tell.
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf = [_]u8{0} ** 32;
    app.owner.io.vtable.random(app.owner.io.userdata, &buf);
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) all_zero = false;
    }
    try std.testing.expect(!all_zero);

    var secure = [_]u8{0} ** 16;
    try app.owner.io.vtable.randomSecure(app.owner.io.userdata, &secure);
    try std.testing.expect(secure[0] != 0 or secure[1] != 0);
}

test "a host with no random source reports entropy unavailable rather than succeeding with zeros" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.fill_random = null;
    const app = try init(gpa, ops, phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // The secure entry can say so. The plain one returns void and cannot, which
    // is why it panics instead; that path is not reachable from a test without
    // taking the process with it.
    var buf = [_]u8{0} ** 16;
    try std.testing.expectError(error.EntropyUnavailable, app.owner.io.vtable.randomSecure(app.owner.io.userdata, &buf));
}

// ---------------------------------------------------------------------------
// write_location guard and read_location refusal (no browser: DomOps comes
// from dom_calls.Recorder)
// ---------------------------------------------------------------------------

fn countOccurrences(log: []const []u8, needle: []const u8) usize {
    var n: usize = 0;
    for (log) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

test "writing the same location twice reaches the browser once, and a different one reaches it again" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = gpa, .sink = &sink };
    defer owner.deinit();
    var app = clockOnlyApp(0, 0);
    app.ops = rec.ops();
    app.sink = &sink;
    app.owner = &owner;
    owner.platform = .{ .ctx = &app, .read_location = readLocationThunk, .write_location = writeLocationThunk };

    owner.platform.writeLocation("/gallery", .push);
    owner.platform.writeLocation("/gallery", .push);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(rec.log.items, "writeLocation("));

    owner.platform.writeLocation("/about", .push);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(rec.log.items, "writeLocation("));
}

fn locFaultHome(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "home" }).widget();
}

const loc_fault_routes = [_]phantom.Route{
    .{ .path = "/", .build = locFaultHome },
};

test "an over long browser address is refused: it reports the fault and the router's location does not change" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    // Longer than the router's own buffer, parked as if the page had been
    // opened on an address nobody typed by hand.
    const long = "/" ++ ("a" ** phantom.router.max_path);
    rec.setLocation(long);

    const r = phantom.Router{ .routes = &loc_fault_routes, .initial = "/", .not_found = locFaultHome };
    var h = try phantom.testing.mount(gpa, r.widget());
    defer h.deinit();
    const state = try h.stateOf(phantom.testing.find.byType(phantom.Router), phantom.Router.State);
    try std.testing.expectEqualStrings("/", state.location());

    var app = clockOnlyApp(0, 0);
    app.ops = rec.ops();
    app.sink = h.sink;
    app.owner = h.owner;
    h.owner.platform = .{ .ctx = &app, .read_location = readLocationThunk, .write_location = writeLocationThunk };

    app.locationChanged();

    try std.testing.expectEqualStrings("/", state.location());
    try h.expectFault(.location_too_long);
}

test "a browser tick advances the wall clock and the monotonic clock separately" {
    // The two arguments are easy to swap at the call site, and a swap is silent:
    // both are f64 milliseconds. Pinning them apart is what catches it.
    var app = clockOnlyApp(0, 0);
    var sink = phantom.FaultSink{};
    var owner = phantom.BuildOwner{ .gpa = std.testing.allocator, .sink = &sink };
    defer owner.deinit();
    app.owner = &owner;

    app.tick(1_767_225_840_000.0, 4200.0);

    try std.testing.expectEqual(@as(i96, 1_767_225_840_000_000_000), app.wall_ns);
    try std.testing.expectEqual(@as(i96, 4_200_000_000), app.mono_ns);
}

// ---------------------------------------------------------------------------
// Bug 2: browser back/forward must never grow the router's stack past
// max_stack, however many times it happens.
// ---------------------------------------------------------------------------

fn ratchetHome(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "home" }).widget();
}
fn ratchetA(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "a" }).widget();
}
const ratchet_routes = [_]phantom.Route{
    .{ .path = "/", .build = ratchetHome },
    .{ .path = "/a", .build = ratchetA },
};

test "clicking a link then pressing back, repeated far more times than max_stack, never exhausts the router's stack" {
    const gpa = std.testing.allocator;
    const r = phantom.Router{ .routes = &ratchet_routes, .initial = "/", .not_found = ratchetHome };
    var h = try phantom.testing.mount(gpa, r.widget());
    defer h.deinit();
    const handle = h.owner.router orelse return error.NoRouterClaimed;

    // A RouteLink push always grows the stack by one; a matched browser
    // back must always shrink it back by one, or a nav bar that alternates
    // the two (the ordinary way to use one) fills the stack for good in
    // well under a minute (this is the bug report). max_stack * 4 clears
    // that bar by a wide margin.
    var i: usize = 0;
    while (i < phantom.router.max_stack * 4) : (i += 1) {
        handle.push("/a");
        applyLocation(handle, "/");
    }

    try std.testing.expect(handle.depth() <= 2);
    try h.expectNoFaults();
}

// ---------------------------------------------------------------------------
// Bug 3: web.init must not install a hook the host never gave it. A missing
// hook and an over-long address are different faults and must stay
// distinguishable.
// ---------------------------------------------------------------------------

fn linkRoot(b: *phantom.BuildContext) phantom.Widget {
    const box = phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) };
    return b.new(phantom.Link{ .url = "https://example.com", .child = b.new(box).widget() }).widget();
}

fn plainRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.ColoredBox{ .color = phantom.Color.rgb(0, 0, 1) }).widget();
}

fn locFaultRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Router{ .routes = &loc_fault_routes, .initial = "/", .not_found = locFaultHome }).widget();
}

/// Frees everything `init` allocates. `init`'s own doc comment says "never
/// deinit: the page owns it", which is right for the real page, whose
/// process exits from under the app; a test has no such exit, so it tears
/// down by hand instead of leaking under the testing allocator.
fn destroyWebApp(gpa: std.mem.Allocator, app: *WebApp) void {
    // The tree comes down before the focus manager: tearing it down walks every
    // render object and calls back into the manager to forget its handlers.
    app.root.deinit(gpa);
    app.focus.deinit(gpa);
    app.net.deinit();
    app.owner.deinit();
    gpa.destroy(app.owner);
    gpa.destroy(app.sink);
    app.arena.deinit();
    gpa.destroy(app.arena);
    gpa.destroy(app);
}

test "web.init leaves the platform's open_url unset when the host has no open_url hook, so a tapped Link reports it is unsupported" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(linkRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    try std.testing.expect(!app.owner.platform.openUrl("https://example.com", .new_tab));

    const ro = app.root.renderObject().?;
    app.dispatchTap(ro.origin.x + ro.size.width * 0.5, ro.origin.y + ro.size.height * 0.5);

    const f = app.sink.first orelse return error.NoFaultRecorded;
    try std.testing.expectEqual(phantom.FaultCode.link_unsupported, f.code);
}

test "web.init leaves the platform's read_location unset when the host has no read_location hook, so a missing hook is not mistaken for an empty address" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_location = null;
    const app = try init(gpa, ops, phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [phantom.router.max_path]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readLocation(&buf));
}

test "locationChanged does nothing when the host has no read_location hook, rather than routing to an empty path" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_location = null;
    const app = try init(gpa, ops, phantom.Root.plain(locFaultRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    app.locationChanged();

    try std.testing.expect(app.sink.ok());
}

// ---------------------------------------------------------------------------
// The keyboard: which node the keys go to, what a key carries, and how a whole
// string (a paste, an IME commit) gets in.
// ---------------------------------------------------------------------------

/// Records the keys that reach a shortcut listener and never uses one, so the
/// answer `dispatchKey` gives still reports whether the tree itself did anything
/// with the key. The listener sits last in the dispatch order, so a key it sees is
/// a key the focused field refused.
const KeyLog = struct {
    keysym: phantom.input.Keysym = .no_symbol,
    mods: phantom.input.Mods = .{},
    calls: u32 = 0,

    fn onKey(ctx: *anyopaque, ev: phantom.input.KeyEvent) bool {
        const self: *KeyLog = @ptrCast(@alignCast(ctx));
        self.keysym = ev.keysym;
        self.mods = ev.mods;
        self.calls += 1;
        return false;
    }
};

/// `Root.plain` takes a build function and no context of its own, so the tree the
/// key tests mount reaches its two recorders through file scope. Every test that
/// reads one resets it first.
var key_log: KeyLog = .{};
var edits: u32 = 0;

fn countEdit(ctx: *anyopaque, _: []const u8) void {
    const n: *u32 = @ptrCast(@alignCast(ctx));
    n.* += 1;
}

/// One field at the top left, under a shortcut listener. `Align` is what keeps the
/// field its own height instead of the whole viewport, so a test has somewhere to
/// tap that is NOT the field.
fn fieldRoot(b: *phantom.BuildContext) phantom.Widget {
    const field = b.new(phantom.TextField{ .id = "invite", .on_change = countEdit, .ctx = &edits });
    const al = b.new(phantom.Align{ .alignment = .top_left, .child = field.widget() });
    return b.new(phantom.KeyboardListener{ .child = al.widget(), .on_key = KeyLog.onKey, .ctx = &key_log }).widget();
}

fn findByType(el: *phantom.Element, name: []const u8) ?*phantom.Element {
    if (std.mem.eql(u8, el.type_name, name)) return el;
    if (el.child) |c| {
        if (findByType(c, name)) |found| return found;
    }
    for (el.children.items) |c| {
        if (findByType(c, name)) |found| return found;
    }
    return null;
}

fn fieldElement(app: *WebApp) !*phantom.Element {
    return findByType(app.root, @typeName(phantom.TextField)) orelse error.NoTextField;
}

fn fieldState(app: *WebApp) !*phantom.widgets.TextField.State {
    const el = try fieldElement(app);
    const s = el.state orelse return error.TextFieldHasNoState;
    return @ptrCast(@alignCast(s));
}

/// A point inside the field, and one below it that is still inside the viewport.
const TapPoints = struct { on_field: phantom.PhysicalOffset, off_field: phantom.PhysicalOffset };

fn tapPoints(app: *WebApp) !TapPoints {
    const el = try fieldElement(app);
    const ro = el.renderObject() orelse return error.TextFieldHasNoRenderObject;
    const below = ro.origin.y + ro.size.height + 20;
    // A field that filled the viewport would leave nowhere to tap that is not the
    // field, and every "tapped away" assertion below would pass for the wrong
    // reason.
    if (below >= 200) return error.FieldFillsTheViewport;
    return .{
        .on_field = .{ .x = ro.origin.x + ro.size.width * 0.5, .y = ro.origin.y + ro.size.height * 0.5 },
        .off_field = .{ .x = ro.origin.x + ro.size.width * 0.5, .y = below },
    };
}

fn mountFieldApp(gpa: std.mem.Allocator, rec: *phantom.backend.dom_calls.Recorder) !*WebApp {
    key_log = .{};
    edits = 0;
    return init(gpa, rec.ops(), phantom.Root.plain(fieldRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
}

test "a tap on a text field gives it the keyboard, and the next key typed lands in it" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);

    // Nothing holds the focus on a fresh page, so a key has nowhere to land.
    try std.testing.expect(!app.dispatchChar('a', .{}, .press));
    try std.testing.expectEqualStrings("", state.value());

    app.dispatchTap(p.on_field.x, p.on_field.y);
    try std.testing.expect(state.focused);

    try std.testing.expect(app.dispatchChar('a', .{}, .press));
    try std.testing.expectEqualStrings("a", state.value());
    try std.testing.expect(app.sink.ok());
}

test "a tap away from a text field takes the keyboard off it, so the keys stop landing in it" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);

    app.dispatchTap(p.on_field.x, p.on_field.y);
    _ = app.dispatchChar('a', .{}, .press);
    app.dispatchTap(p.off_field.x, p.off_field.y);

    try std.testing.expect(!state.focused);
    try std.testing.expect(!app.dispatchChar('b', .{}, .press));
    try std.testing.expectEqualStrings("a", state.value());
}

test "a pasted invite code lands in the field in one edit, not one edit per character" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);
    app.dispatchTap(p.on_field.x, p.on_field.y);

    // 32 characters of Crockford base32. Nobody types one of these, so a key-only
    // path drops every invite code a user ever enters.
    const code = "E55233CZ75HMXM6Y6N4J3MV4AANCAM2F";
    edits = 0;
    try std.testing.expect(app.dispatchText(code));

    try std.testing.expectEqualStrings(code, state.value());
    try std.testing.expectEqual(@as(u32, 1), edits);
}

test "an IME commit lands in the field whole, and one committed character is named by its keysym" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);
    app.dispatchTap(p.on_field.x, p.on_field.y);

    // What `compositionend` hands over: the finished word, not the keys that
    // composed it. Those went to the IME and the page never saw them.
    edits = 0;
    try std.testing.expect(app.dispatchText("日本語"));
    try std.testing.expectEqualStrings("日本語", state.value());
    try std.testing.expectEqual(@as(u32, 1), edits);

    // A single character keeps its own keysym, so a one character commit and the
    // same character typed are the same event to everything downstream.
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint('あ'), soleKeysym("あ"));
    try std.testing.expectEqual(phantom.input.Keysym.no_symbol, soleKeysym("日本語"));
    // Malformed bytes are input, not a programmer error: they still reach the
    // field, they are only unnamed.
    try std.testing.expectEqual(phantom.input.Keysym.no_symbol, soleKeysym("\xff"));
}

test "a held ctrl types no letter but still names the key it was held on" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);
    app.dispatchTap(p.on_field.x, p.on_field.y);

    // Ctrl+V is a shortcut and not the letter v. A field inserts `text` without
    // ever reading the keysym, so text on a modified key would type the letter of
    // every shortcut a user presses.
    try std.testing.expect(!app.dispatchChar('v', .{ .ctrl = true }, .press));
    try std.testing.expectEqualStrings("", state.value());

    // The shortcut is still readable: it reached the listener with its keysym and
    // its modifier both intact.
    try std.testing.expectEqual(phantom.input.Keysym.fromCodepoint('v'), key_log.keysym);
    try std.testing.expect(key_log.mods.ctrl);
}

test "the named editing keys reach the field, and a released key changes nothing" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const p = try tapPoints(app);
    const state = try fieldState(app);
    app.dispatchTap(p.on_field.x, p.on_field.y);

    _ = app.dispatchText("ab");
    try std.testing.expect(app.dispatchKey(.{ .keysym = .backspace }));
    try std.testing.expectEqualStrings("a", state.value());

    try std.testing.expect(app.dispatchKey(.{ .keysym = .home }));
    try std.testing.expect(app.dispatchChar('z', .{}, .press));
    try std.testing.expectEqualStrings("za", state.value());

    // A release must not type the character again. Every browser sends keyup for
    // the key it just sent keydown for.
    try std.testing.expect(!app.dispatchChar('z', .{}, .release));
    try std.testing.expectEqualStrings("za", state.value());
}

test "tab moves the keyboard on, so a page with one field can be left by keyboard alone" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try mountFieldApp(gpa, &rec);
    defer destroyWebApp(gpa, app);
    const state = try fieldState(app);

    // Tab with nothing focused enters the tree at the first focusable node, which
    // is what a user pressing Tab on a fresh page expects.
    try std.testing.expect(app.dispatchKey(.{ .keysym = .tab }));
    try std.testing.expect(state.focused);

    // Escape gives the keyboard back to the page.
    try std.testing.expect(app.dispatchKey(.{ .keysym = .escape }));
    try std.testing.expect(!state.focused);
}

// ---------------------------------------------------------------------------
// The query string. Separate from the route: a redirect hands back a state or
// an error there, and the router never sees it.
// ---------------------------------------------------------------------------

test "an application reads the query string of the address it was opened on" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    rec.setLocation("/dashboard");
    rec.setSearch("state=E55233CZ&error=access_denied");
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("state=E55233CZ&error=access_denied", app.owner.platform.readQuery(&buf).?);
    // The route is what it always was. Reading one must not disturb the other.
    var path_buf: [phantom.router.max_path]u8 = undefined;
    try std.testing.expectEqualStrings("/dashboard", app.owner.platform.readLocation(&path_buf).?);
}

test "an address with no query reads as an empty query, not as a query that could not be read" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [16]u8 = undefined;
    const q = app.owner.platform.readQuery(&buf) orelse return error.QueryUnreadable;
    try std.testing.expectEqual(@as(usize, 0), q.len);
    try std.testing.expect(app.sink.ok());
}

test "an over long query is refused and reported rather than truncated to a different value" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    rec.setSearch("state=" ++ ("a" ** 64));
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // Half a state token looks like a whole one to whatever reads it next.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readQuery(&buf));
    const f = app.sink.first orelse return error.NoFaultRecorded;
    try std.testing.expectEqual(phantom.FaultCode.location_too_long, f.code);
}

test "web.init leaves the platform's read_query unset when the host has no read_query hook" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_query = null;
    const app = try init(gpa, ops, phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readQuery(&buf));
}

// ---------------------------------------------------------------------------
// Sockets over `fetch`, driven by the real `std.http.Client`.
//
// The point of the socket shape is that an application writes ordinary Zig, so
// the test that matters is not one that pokes the connection table: it is the
// unmodified client from the standard library getting an answer through it.
// ---------------------------------------------------------------------------

/// Answers every request with one canned reply, and keeps the request it was
/// given so a test can check what actually went out.
const FetchSpy = struct {
    /// The three things a browser can tell us about a reply. Kept apart, and run
    /// through the real `buildResponse`, because the envelope rebuild is the part
    /// most likely to be wrong: a canned envelope here would test the client's
    /// parser against a string this project never actually produces.
    status: u16 = 200,
    headers: []const u8 = "",
    reply: []const u8 = "",
    fail: bool = false,
    calls: u32 = 0,
    method: [8]u8 = undefined,
    method_len: usize = 0,
    target: [64]u8 = undefined,
    target_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    body: [64]u8 = undefined,
    body_len: usize = 0,

    fn send(ctx: *anyopaque, gpa: std.mem.Allocator, req: phantom.web_net.Request) ?[]u8 {
        const self: *FetchSpy = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.method_len = copyInto(&self.method, req.method);
        self.target_len = copyInto(&self.target, req.target);
        self.host_len = copyInto(&self.host, req.host);
        self.body_len = copyInto(&self.body, req.body);
        if (self.fail) return null;
        return phantom.web_net.buildResponse(gpa, self.status, self.headers, self.reply) catch null;
    }

    fn copyInto(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }

    fn hook(self: *FetchSpy) phantom.web_net.Hook {
        return .{ .ctx = self, .send = FetchSpy.send };
    }
};

test "an unmodified std.http.Client gets its reply through sockets that are really fetch" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var spy = FetchSpy{ .status = 200, .headers = "content-type: application/json\r\n", .reply = "{\"sites\":[\"a\"]}" };
    app.net.hook = spy.hook();

    var client: std.http.Client = .{ .allocator = gpa, .io = app.owner.io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = "http://sigil.example/api/sites" },
        .response_writer = &body.writer,
    });

    // The client parsed a real HTTP/1.1 response out of what the browser said.
    try std.testing.expectEqual(std.http.Status.ok, res.status);
    try std.testing.expectEqualStrings("{\"sites\":[\"a\"]}", body.written());

    // And what went out was a real request, with the pieces the browser needs.
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
    try std.testing.expectEqualStrings("GET", spy.method[0..spy.method_len]);
    try std.testing.expectEqualStrings("/api/sites", spy.target[0..spy.target_len]);
    try std.testing.expectEqualStrings("sigil.example", spy.host[0..spy.host_len]);
}

test "a POST carries its body and its status all the way back" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // 403 is a REPLY, not a failure. A dashboard shows what it says.
    var spy = FetchSpy{ .status = 403, .reply = "not allowed." };
    app.net.hook = spy.hook();

    var client: std.http.Client = .{ .allocator = gpa, .io = app.owner.io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = "http://sigil.example/api/sign-in" },
        .method = .POST,
        .payload = "{\"code\":\"E55233CZ\"}",
        .response_writer = &body.writer,
    });

    try std.testing.expectEqual(std.http.Status.forbidden, res.status);
    try std.testing.expectEqualStrings("not allowed.", body.written());
    try std.testing.expectEqualStrings("POST", spy.method[0..spy.method_len]);
    try std.testing.expectEqualStrings("{\"code\":\"E55233CZ\"}", spy.body[0..spy.body_len]);
}

test "a request that never arrives fails the client, rather than looking like an empty reply" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var spy = FetchSpy{ .fail = true };
    app.net.hook = spy.hook();

    var client: std.http.Client = .{ .allocator = gpa, .io = app.owner.io };
    defer client.deinit();

    // The distinction the consumer asked for: a dead network must not reach the
    // application as a reply it can misread as an answer from the server.
    try std.testing.expectError(error.ReadFailed, client.fetch(.{
        .location = .{ .url = "http://sigil.example/api/sites" },
    }));
    try std.testing.expectEqual(@as(u32, 1), spy.calls);
}

test "two requests on one client both reach the host" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var spy = FetchSpy{ .status = 200, .reply = "hi" };
    app.net.hook = spy.hook();

    var client: std.http.Client = .{ .allocator = gpa, .io = app.owner.io };
    defer client.deinit();

    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    _ = try client.fetch(.{ .location = .{ .url = "http://sigil.example/a" }, .response_writer = &first.writer });

    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    _ = try client.fetch(.{ .location = .{ .url = "http://sigil.example/b" }, .response_writer = &second.writer });

    try std.testing.expectEqual(@as(u32, 2), spy.calls);
    try std.testing.expectEqualStrings("/b", spy.target[0..spy.target_len]);
    try std.testing.expectEqualStrings("hi", second.written());
}

test "an application can find the host its page is served from" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    rec.setHost("sigil.example");
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // Without this an application has to hard code its own host to build a URL,
    // which works on the machine it was written on and nowhere else.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("sigil.example", app.owner.platform.readHost(&buf).?);
}

test "a host too long for the buffer is refused and reported, not truncated to another machine" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    rec.setHost("a-very-long-host-name.example");
    const app = try init(gpa, rec.ops(), phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // A truncated host is a different machine, and this one is about to be put
    // in a URL that carries the page's credentials.
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readHost(&buf));
    const f = app.sink.first orelse return error.NoFaultRecorded;
    try std.testing.expectEqual(phantom.FaultCode.location_too_long, f.code);
}

test "a host with no hook is null, so a native backend cannot be mistaken for a page" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    var ops = rec.ops();
    ops.read_host = null;
    const app = try init(gpa, ops, phantom.Root.plain(plainRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), app.owner.platform.readHost(&buf));
}

fn textRoot(b: *phantom.BuildContext) phantom.Widget {
    return b.new(phantom.Text{ .text = "sign in" }).widget();
}

test "a page drawn with the default theme embeds no font, so a strict font-src can refuse data urls" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(textRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // The default theme is what almost every page draws with, and it used to
    // reach `Font.load` on the raw bytes, which records no url and so embeds the
    // whole font in the stylesheet. Under `font-src 'self'` the browser refuses
    // it and substitutes another font, and then the glyphs a person sees and the
    // rectangles their taps are tested against stop agreeing.
    var embedded = false;
    var referenced = false;
    for (rec.log.items) |line| {
        if (std.mem.indexOf(u8, line, "data:font/otf") != null) embedded = true;
        if (std.mem.indexOf(u8, line, "url(\"fonts/") != null) referenced = true;
    }
    try std.testing.expect(!embedded);
    try std.testing.expect(referenced);
}

test "init resets the page margin, or the themed background sits inside the browser's own 8px" {
    const gpa = std.testing.allocator;
    var rec = phantom.backend.dom_calls.Recorder{ .gpa = gpa };
    defer rec.deinit();
    const app = try init(gpa, rec.ops(), phantom.Root.plain(textRoot), .{ .width = 200, .height = 200 }, 1.0, .path);
    defer destroyWebApp(gpa, app);

    // The container is sized to the FULL viewport, so any body margin pushes it
    // down and right: the page shows two strips of unthemed white at the top and
    // left, and loses the same amount off the bottom and right, unseen.
    //
    // Asserted on the BODY specifically, and through setStyle rather than a
    // sheet rule, because that is the path this backend proves on every frame.
    // A sheet needs a sheet to exist; this needs nothing that positioning a node
    // does not already need.
    var reset = false;
    for (rec.log.items) |line| {
        if (std.mem.startsWith(u8, line, "setStyle(1,") and
            std.mem.indexOf(u8, line, "margin:0") != null) reset = true;
    }
    try std.testing.expect(reset);
}
