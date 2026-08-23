//! The terminal event loop. This is the `App.run` of the terminal path.
const std = @import("std");
const builtin = @import("builtin");
const phantom = @import("../phantom.zig");
const term_mod = @import("tui/term.zig");
/// Public so a consumer's root module can wire `rootPanic` into its own
/// `pub const panic = std.debug.FullPanic(phantom.tui.term.rootPanic);`, the one
/// step `phantom.setPanicHook` cannot do on its own (see panic.zig's doc comment).
pub const term = term_mod;
const caps_mod = @import("tui/caps.zig");
const ansi = @import("tui/ansi.zig");
const decode = @import("tui/decode.zig");
const cell_grid = @import("backend/cell_grid.zig");
const tui_cells = @import("backend/tui_cells.zig");
const prism_backend = @import("backend/prism.zig");
const tui_pixels = @import("backend/tui_pixels.zig");
const kitty_gfx = @import("tui/kitty_gfx.zig");

pub const Mode = enum { cells, pixels };

/// Whether mode A can be COMPILED here at all, which is prism's question and is
/// answered in one place: see `backend.prism.builds_here`. Whether THIS machine
/// can actually draw is a different question, asked at runtime of
/// `backend.prism.canRasterize`, and prism answers yes with no GPU at all
/// because it ships a CPU rasterizer.
const rasterizer_builds = prism_backend.builds_here;

/// `PHANTOM_TUI` accepts `pixel`, `cells` or `auto`. Any other value is user input
/// and is a runtime fault, so it falls back to the detected capability rather than
/// failing the program. Mode A never compiles in on a target with no GPU path (see
/// `rasterizer_builds`), so this returns `.cells` unconditionally there, even against
/// an explicit override: honoring `pixel` would runtime-fault later, unwrapping a
/// surface that was never built.
pub fn selectMode(c: caps_mod.Caps, override: ?[]const u8) Mode {
    if (!rasterizer_builds) return .cells;
    if (override) |o| {
        if (std.mem.eql(u8, o, "pixel") or std.mem.eql(u8, o, "pixels")) return .pixels;
        if (std.mem.eql(u8, o, "cells") or std.mem.eql(u8, o, "cell")) return .cells;
    }
    return if (c.kitty_graphics) .pixels else .cells;
}

/// Read whatever the terminal has, and report an idle terminal as zero bytes.
///
/// `enterRaw` sets VMIN 0 and VTIME 1, so an idle read returns zero bytes after a
/// short wait. `std.Io.File.readStreaming` reports a zero byte read as
/// `error.EndOfStream`, because for a regular file zero does mean the end. On a
/// terminal it means "nothing typed yet", which happens on almost every turn of the
/// loop. Treating it as the end quits the program as soon as the user stops typing.
///
/// A real end of input CAN reach here, and it still reports zero rather than
/// stopping. `Options.raw_mode` lets a session drive a pipe or a file,
/// where reading past the end genuinely is the end. Stopping there would be
/// wrong all the same: a caller that drives `Session.step` itself decides when the
/// session is over, and a spent input stream is not that decision. It only means
/// no more input is coming, which for a still, redrawing tree is an ordinary
/// state and not a reason to tear the tree down.
fn readIdle(t: *term_mod.Term, io: std.Io, buf: []u8) !usize {
    return t.in.readStreaming(io, &.{buf}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

/// True once `bytes` holds a complete DA1 answer, `CSI ? <digits and separators> c`.
/// A bare 'c' byte anywhere in the stream, for example a stray keypress that arrives
/// during the probe, must not trip the read loop early, so this asks
/// `caps_mod.findCsiQuestion` for the 'c' terminator on a real CSI ? sequence and not
/// just the presence of both bytes somewhere in the buffer.
fn sawDA1(bytes: []const u8) bool {
    return caps_mod.findCsiQuestion(bytes, 'c') != null;
}

/// The terminal reports cells unless mode 1016 is on, so this turns a mouse report
/// into the physical pixel point the tree works in.
fn mousePoint(m: decode.MouseEvent, cell_w: f32, cell_h: f32) phantom.PhysicalOffset {
    if (m.pixels) return .{ .x = @floatFromInt(m.x), .y = @floatFromInt(m.y) };
    return .{
        .x = @as(f32, @floatFromInt(m.x)) * cell_w,
        .y = @as(f32, @floatFromInt(m.y)) * cell_h,
    };
}

/// One wheel notch becomes three lines, the step every terminal application uses.
fn scrollPixels(m: decode.MouseEvent, cell_w: f32, cell_h: f32) struct { dx: f32, dy: f32 } {
    return .{ .dx = m.scroll_dx * cell_w * 3, .dy = m.scroll_dy * cell_h * 3 };
}

/// The metrics layout measures text with. `.cells` must line every glyph up on a
/// whole column, so it borrows the terminal's own reported cell advance, exactly as
/// `tui_cells.render` draws it. `.pixels` rasterizes the real font, so layout must
/// measure with that font's own proportional advances, the same metrics the GPU
/// window path uses: see `text/mono.zig`'s `TextMetrics` doc comment. A pixel run
/// measured at the cell advance and then drawn at its true glyph size is why the
/// glyphs overlapped: mode A never wants the mono metrics at all.
/// Who reads the input when `Options.input` does not say.
///
/// Raw mode is the whole question. It sets VMIN 0 and VTIME 1, which is what
/// makes a read return promptly with nothing to report; without it the stream's
/// blocking behaviour belongs to whoever opened it, and a read with nothing to
/// return stops the loop until a byte arrives that may never come. So a session
/// that set raw mode reads for itself, and a session that did not waits to be
/// fed. Either can be overridden, but neither default can hang.
fn defaultInputSource(raw_mode: bool) InputSource {
    return if (raw_mode) .own else .fed;
}

fn textMetricsFor(m: Mode, cell_w: f32, cell_h: f32) phantom.text.mono.TextMetrics {
    return switch (m) {
        .cells => .{ .mono = phantom.text.mono.Mono.fromCell(cell_w, cell_h) },
        .pixels => .proportional,
    };
}

/// The smallest rectangle that contains both `a` and `b`.
///
/// Mode A deletes the previous frame's image by id once the new one is placed,
/// which frees exactly that image's own footprint and nothing else. If the new
/// frame only transmitted its own small damage rectangle, the region the old
/// image used to cover but the new one does not touch would go blank the moment
/// the old id is freed. Growing the new frame's rectangle to also cover the
/// previous one's footprint means the new image fully replaces it, so freeing the
/// old id never uncovers anything. See `Session.renderPixels`.
fn unionRect(a: tui_pixels.Rect, b: tui_pixels.Rect) tui_pixels.Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Where a damage rectangle lands once it is placed on the cell grid: the crop
/// rectangle to read out of the surface, grown to a cell boundary, and the cell it
/// is placed at.
const CellAlignedDamage = struct { crop: tui_pixels.Rect, place: kitty_gfx.Placement };

/// The damage rectangle is in pixels, but a kitty placement lands on a cell. Rounding
/// the origin down to the enclosing cell is not enough on its own: that would place
/// the image to the left of and above the pixels it actually contains, leaving a
/// sliver of the previous frame showing between the cell boundary and the true
/// damage origin. Growing the rectangle out to the cell boundary, while keeping its
/// far edge fixed, keeps the transmitted image covering every damaged pixel.
fn alignDamageToCells(r: tui_pixels.Rect, cell_w: f32, cell_h: f32) CellAlignedDamage {
    const col_f = @floor(@as(f32, @floatFromInt(r.x)) / cell_w);
    const row_f = @floor(@as(f32, @floatFromInt(r.y)) / cell_h);
    // min guards the rare case where float error puts the cell origin a hair past
    // r.x or r.y: the crop must never start after the damage it is meant to cover.
    const aligned_x = @min(r.x, @as(u32, @intFromFloat(col_f * cell_w)));
    const aligned_y = @min(r.y, @as(u32, @intFromFloat(row_f * cell_h)));
    return .{
        .crop = .{
            .x = aligned_x,
            .y = aligned_y,
            .w = r.x + r.w - aligned_x,
            .h = r.y + r.h - aligned_y,
        },
        .place = .{ .col = @intFromFloat(col_f), .row = @intFromFloat(row_f) },
    };
}

/// What to tell a human about `redirectStderr`'s outcome, once it is safe to
/// print. Read after the alternate screen is torn down (see `Session.deinit`'s
/// teardown), never while it is still up, since printing about this by any path
/// other than that one would risk being exactly the corruption the redirect
/// exists to prevent.
///
/// Covers the success case too, not only the two degraded ones: `path` is
/// pid-namespaced (see `Session.stderrPath`) and so not guessable, and a human who never
/// watched the screen for the one line a fallback would have printed still
/// needs a way to find their own log. `buf` holds the formatted result; only the
/// success case actually needs it, since `path` is the only piece of this that
/// varies per run.
fn stderrTeardownMessage(buf: []u8, t: term_mod.StderrTarget, path: []const u8) []const u8 {
    return switch (t) {
        .log_file => std.fmt.bufPrint(buf, "this run's stderr log is at {s}", .{path}) catch path,
        .dev_null => "stderr could not be redirected to a log file this run; " ++
            "warnings were discarded rather than logged",
        .unavailable => "stderr could not be redirected at all this run; " ++
            "a warning may have reached the terminal directly and corrupted the display",
    };
}

/// True for ctrl-c, the only way out of the program: ISIG is off in raw mode, so
/// nothing else raises SIGINT. Checked before the tree ever sees the key, so a
/// focused widget that consumes every key can never trap the user with no way out.
fn isQuit(k: phantom.input.KeyEvent) bool {
    return k.mods.ctrl and k.keysym == phantom.input.Keysym.fromCodepoint('c');
}

/// The running process id, used to namespace the stderr log path so two
/// instances running at once do not interleave into the same file. `getpid` is
/// a posix call; `std.posix.system` resolves to `std.c` on Windows regardless of
/// whether libc is linked (see `std.posix.use_libc`), and that decl refuses to
/// compile without one, so Windows reaches `GetCurrentProcessId` directly instead.
fn currentPid() i64 {
    if (builtin.os.tag == .windows) return @intCast(std.os.windows.GetCurrentProcessId());
    return @intCast(std.posix.system.getpid());
}

/// What ctrl-c does.
///
/// Raw mode turns ISIG off, so ctrl-c is NOT a signal here: the terminal delivers
/// it as an ordinary key and no SIGINT handler, the caller's own included, ever
/// runs for it. That makes this the only place the decision can be taken. Either
/// way the key is swallowed before the tree sees it, so a focused widget that
/// consumes every key can never trap a user with no way out.
pub const Interrupt = enum {
    /// End the loop at once. `Session.step` returns false on the same turn.
    stop,
    /// Record it and keep running. `Session.takeInterrupt` reports it, so a
    /// caller can finish what it is doing and stop at a point it chooses.
    notify,
};

/// Who reads the terminal input stream.
pub const InputSource = enum {
    /// The session reads it on every `step`.
    ///
    /// Safe only when the read is known to return promptly with nothing to
    /// report. Raw mode's VMIN 0 and VTIME 1 is what makes that true, so this is
    /// right whenever the session, or the caller, has put the terminal in raw
    /// mode. On a plain pipe with no data and no end of stream, the read blocks
    /// and the loop stops with it.
    own,

    /// The session never reads. The caller reads however it likes and hands the
    /// bytes over with `Session.feed`.
    ///
    /// For a caller whose own loop already waits on its own input, or that
    /// shares the stream with something else: two readers on one descriptor race
    /// for every byte, and the loser sees a torn escape sequence.
    fed,
};

/// Where the session points stderr while it owns the display.
///
/// `std.log.warn`, used by `FaultSink` and by anything else that logs, writes to
/// stderr, and stderr is the SAME terminal the alternate screen is drawn on: a
/// write there scrolls the real screen underneath the application and corrupts
/// it. Redirecting the file descriptor fixes that for every caller at once. A
/// program that already sends its own logs somewhere safe does not need it and
/// should not have its stderr moved out from under it.
pub const StderrPolicy = union(enum) {
    /// A file under `TMPDIR`, named with this process's id so two instances
    /// running at once cannot interleave into one file.
    temp_log,
    /// This exact path.
    path: []const u8,
    /// Leave stderr alone. The caller has already put it somewhere safe, or
    /// accepts that a warning can scroll over the display.
    leave,
};

/// Where a session takes input from, where it sends output, and how much of the
/// process it is allowed to take over.
///
/// Every default matches what `Tui.run` did when it was the only way in: a
/// program whose whole job is the terminal wants all of it. Each field is here
/// so a program that EMBEDS phantom, and already owns its own signal handling,
/// its own logging, or its own event loop, can keep the piece it owns.
pub const Options = struct {
    /// The terminal device. Null takes the process's own stdin and stdout.
    in: ?std.Io.File = null,
    out: ?std.Io.File = null,

    /// Write frames through this writer rather than one the session opens over
    /// `out`. A caller that already orders its own stdout and stderr through a
    /// single writer passes it here, so a frame cannot overtake a line of that
    /// caller's own output. The session flushes it and never closes it.
    writer: ?*std.Io.Writer = null,

    /// The grid geometry, instead of asking the terminal for it. Required when
    /// `in` and `out` are not a terminal, since `TIOCGWINSZ` fails on anything
    /// else. A size given here is the size for the whole run: `Session.resize`
    /// is then the only thing that changes it, and a resize the terminal
    /// reports is ignored.
    size: ?term_mod.Size = null,

    /// Put the terminal device into raw mode, and turn on the mouse, paste and
    /// resize reporting that only reaches a program in raw mode. Needs a real
    /// terminal: `tcgetattr` fails on anything else, so a session over a pipe or
    /// a file sets this false.
    raw_mode: bool = true,

    /// Ask the terminal what it supports. Needs a real terminal to answer: over
    /// anything else the queries go out and nothing replies, so the answer is
    /// the environment hint either way and the queries are only noise on the
    /// stream. False skips them and takes the hint alone.
    query_capabilities: bool = true,

    /// Take the alternate screen, hide the cursor and clear the display.
    ///
    /// False draws in place and leaves the terminal's own screen and scrollback
    /// alone, for a session that owns a REGION rather than the display: an
    /// inline status area above a scrolling log, say. Set `origin` to put that
    /// region somewhere other than the top left, and keep `size` to the rows the
    /// region actually owns, or the session will draw over its neighbours.
    own_screen: bool = true,

    /// Where the frame lands. `.absolute` with a non-zero origin gives a fixed
    /// region of the screen; `.relative` gives a band that follows the cursor,
    /// which is what sits under scrolling text. Only useful with `own_screen`
    /// false: a session that took the whole alternate screen starts at the
    /// origin by definition. See `cell_grid.Positioning`, whose two caveats
    /// (make room first, and call `Session.invalidate` after printing) are the
    /// caller's to honour here too.
    position: cell_grid.Positioning = .{ .absolute = .{} },

    /// Where recovered faults and other diagnostics are written. Null opens a
    /// writer over the process's own stderr, which for a program that owns the
    /// terminal is the right place: `redirectStderr` has pointed that descriptor
    /// at a log file for as long as the display is up, so the text cannot scroll
    /// the display away.
    ///
    /// An embedder with its own log passes it here, and then wants
    /// `StderrPolicy.leave` as well, since there is no longer anything of
    /// phantom's going to stderr for the redirect to protect the display from.
    diagnostics: ?*std.Io.Writer = null,

    /// Who reads the input stream.
    ///
    /// Null follows `raw_mode`, which is the only safe answer by default: a
    /// session that put the terminal in raw mode set VMIN 0 and VTIME 1, so its
    /// own read returns promptly whether or not anything was typed, while a
    /// session that did NOT owns no such guarantee. Reading a blocking stream
    /// with nothing on it stops the loop dead, and no frame, no animation and no
    /// `requestStop` gets through until a byte arrives that may never come.
    ///
    /// Set it explicitly to override in either direction: `.own` for a caller
    /// that put the terminal in raw mode itself and still wants the session to
    /// do the reading, `.fed` for a caller that would rather push bytes in.
    input: ?InputSource = null,

    /// How to colour the frame. Null follows the terminal's own capability,
    /// which is what a full-screen application wants. Set it to override, and to
    /// `.none` for a frame with no SGR in it at all.
    color: ?cell_grid.ColorMode = null,

    /// Install the INT, TERM and ABRT handlers that put the terminal back and
    /// exit. False leaves the process's own dispositions alone, for a caller
    /// that already handles those signals and wants to stop at a point of its
    /// own choosing. Such a caller owns the restore as well: call
    /// `Session.deinit` on the way out, or the shell is left in raw mode.
    install_signal_handlers: bool = true,

    /// Install `phantom.setPanicHook`, so a panic puts the terminal back before
    /// it prints. False leaves a hook the caller installed itself in place.
    install_panic_hook: bool = true,

    stderr: StderrPolicy = .temp_log,

    interrupt: Interrupt = .stop,
};

pub const Tui = struct {
    /// Run a terminal application until it stops. This owns the process for as
    /// long as it runs. A caller that cannot give up its own loop drives
    /// `Session` directly instead; this function is the short way to do exactly
    /// what `Session` does with nothing else going on.
    pub fn run(process: std.process.Init, root: phantom.Root, opts: Options) !void {
        // A Session holds pointers into its own fields: the writer's buffer, the
        // build owner's fault sink, the terminal the signal handlers restore. It
        // must therefore be built at an address that does not move, which is why
        // `init` takes a pointer rather than returning a value. A Session
        // returned by value would leave every one of those pointers aimed at the
        // dead temporary it was copied out of.
        var session: Session = undefined;
        try session.init(process.gpa, process.io, process.environ_map, root, opts);
        defer session.deinit();
        while (try session.step()) {
            // `run` owns the whole program, so it has nobody to hand an
            // interrupt to and stops on one whatever the policy says. `.notify`
            // only earns its keep when the caller drives `Session` itself and
            // can pick its own safe stopping point.
            if (session.takeInterrupt()) break;
        }
    }
};

/// How many bytes one turn of the loop reads at a time. A single `feed` larger
/// than the decoder's whole buffer could lose a bracketed paste's closing marker
/// and strand the decoder in discard mode, which reads to a user as the keyboard
/// dying, so the bound is checked at compile time against the decoder's capacity.
const in_buf_size = 64;
comptime {
    std.debug.assert(in_buf_size <= decode.buffer_size);
}

/// One running terminal application, with the loop left to the caller.
///
/// `init`, then `step` until it returns false, then `deinit`. `Tui.run` is that
/// sequence and nothing more. Splitting it apart is what lets a program that
/// already has an event loop, a signal handler, or a writer of its own embed
/// phantom rather than hand its process over to it.
///
/// Build it in place at a stable address: see `Tui.run` for why.
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,

    term: term_mod.Term,
    caps: caps_mod.Caps,
    mode: Mode,

    /// Backs `own_writer`. Unused when the caller supplied its own writer.
    out_buf: [4096]u8,
    /// Backs `diag_writer`, which is separate from `out_buf` on purpose: the
    /// frame writer goes to the display, this one goes to whatever stderr
    /// currently is, and mixing a diagnostic into a frame is the corruption
    /// `Term.redirectStderr` exists to prevent.
    diag_buf: [256]u8,
    /// Where a recovered fault is written. Points at the process's stderr
    /// DESCRIPTOR, not at whatever that descriptor happened to mean when the
    /// session started, so it follows `redirectStderr` into the log file while
    /// the display is up and follows `restoreStderr` back to the real terminal
    /// afterwards, with nothing here having to know which one it is.
    diag_writer: std.Io.File.Writer,
    own_writer: std.Io.File.Writer,
    /// Either `&own_writer.interface` or the caller's writer. Every byte the
    /// session sends goes through this one pointer, so a caller that supplied a
    /// writer really does see all of it.
    writer: *std.Io.Writer,

    /// Backs `stderr_log_path` for `StderrPolicy.temp_log`, which is formatted
    /// per run and so cannot be a constant.
    stderr_log_buf: [std.fs.max_path_bytes]u8,
    stderr_log_path: []const u8,

    cell_w: f32,
    cell_h: f32,
    dpr: f32,
    viewport: phantom.PhysicalSize,

    arena: std.heap.ArenaAllocator,
    sink: phantom.FaultSink,
    owner: phantom.BuildOwner,
    focus_mgr: phantom.FocusManager,
    el: *phantom.Element,
    canvas: phantom.Canvas,

    grid: cell_grid.CellGrid,
    surface: ?tui_pixels.PixelSurface,
    /// A fresh id for every frame, so the terminal never keeps showing a stale
    /// image while the new one is still arriving. Well below the protocol's
    /// limit, so it never needs more than one wrap.
    image_id: u32,
    /// The id and footprint of the image on screen now, so the next damaged
    /// frame can free it by id once it has been fully replaced. Null before the
    /// first pixels frame, and reset on every resize, since the footprint's
    /// coordinates stop meaning anything once the surface changes size.
    prev_id: ?u32,
    prev_footprint: ?tui_pixels.Rect,

    frame: std.ArrayList(u8),
    decoder: decode.Decoder,
    dispatch: phantom.input.Dispatcher,
    last_point: phantom.PhysicalOffset,
    dropped_seen: u32,
    in_buf: [in_buf_size]u8,

    running: bool,
    interrupt_pending: bool,
    /// Whether `feed` has been called since the last `step` drained the
    /// decoder. A turn with nothing fed means the same as a read that came
    /// back empty, and has to resolve a pending lone escape the same way.
    fed_since_step: bool,

    /// Bring the terminal up and mount the tree. On any failure this unwinds
    /// everything it already did, so a caller that gets an error must NOT call
    /// `deinit`.
    ///
    /// Takes the allocator, the I/O and the environment one at a time rather
    /// than a whole `std.process.Init`: those three are all a session reads, and
    /// a caller that built its own environment map, or a test with no process to
    /// speak of, has no `std.process.Init` to hand over. `Tui.run` unpacks one.
    pub fn init(
        self: *Session,
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        root: phantom.Root,
        opts: Options,
    ) !void {
        self.gpa = gpa;
        self.io = io;
        self.opts = opts;

        self.term = term_mod.Term.initFiles(
            io,
            opts.in orelse std.Io.File.stdin(),
            opts.out orelse std.Io.File.stdout(),
        );
        if (opts.raw_mode) try self.term.enterRaw();
        // From here on a crash must not maroon the user's shell in raw mode on
        // the alternate screen.
        errdefer if (opts.raw_mode) self.term.leaveRaw();

        // PHANTOM_TUI_KEEP_COREDUMP (any value) skips the SIGABRT handler and
        // keeps a real core dump; see `term.keep_coredump_env` for why that
        // trades away crash safety for it.
        term_mod.installCleanup(&self.term, .{
            .keep_coredump = environ.get(term_mod.keep_coredump_env) != null,
            .install_signal_handlers = opts.install_signal_handlers,
        });
        if (opts.install_panic_hook) phantom.setPanicHook(term_mod.panicCleanup);
        errdefer self.uninstallHandlers();

        self.stderr_log_path = self.stderrPath(environ);
        if (opts.stderr != .leave) self.term.redirectStderr(io, self.stderr_log_path);
        errdefer self.restoreStderrAndReport();

        if (opts.writer) |w| {
            self.writer = w;
        } else {
            self.own_writer = self.term.out.writerStreaming(io, &self.out_buf);
            self.writer = &self.own_writer.interface;
        }

        // Armed BEFORE the write it undoes. If the write or the flush fails part
        // way, the terminal can already be on the alternate screen with the
        // cursor hidden, and an errdefer registered after the write would never
        // run. Restoring a terminal that was never switched is harmless, so
        // arming early costs nothing and closes the window.
        errdefer self.leaveScreen();
        if (opts.own_screen) {
            try self.writer.writeAll(ansi.alt_screen_on ++ ansi.cursor_hide ++ ansi.clear_screen);
            try self.writer.flush();
        }

        // The hint decides what to probe, so it has to be in hand before the
        // probe goes out: `queryFor` skips the graphics query under a
        // multiplexer.
        const hint = caps_mod.hintFromEnv(
            environ.get("TERM"),
            environ.get("TERM_PROGRAM"),
            environ.get("COLORTERM"),
        );
        // With the probe off there is nobody to answer, so the hint is the whole
        // answer. Passing no replies rather than skipping `parseReplies` keeps
        // one path: the hint is folded in the same way either way.
        self.caps = if (opts.query_capabilities) try self.probe(hint) else caps_mod.parseReplies("", hint);
        self.mode = selectMode(self.caps, environ.get("PHANTOM_TUI"));
        // The terminal saying it can SHOW an image is only half the question.
        // The other half is whether prism can draw one, which is not a question
        // about hardware: prism ships a CPU rasterizer, so the answer is usually
        // yes with no GPU at all. Asked of prism rather than assumed, because
        // when the answer is no, mode A transmits a picture of the background
        // colour and nothing else, and a blank screen is a worse outcome than
        // the cells that would have worked. Only asked when the answer can
        // change anything, since it costs a device bring-up.
        if (rasterizer_builds) {
            if (self.mode == .pixels and !prism_backend.canRasterize(gpa)) self.mode = .cells;
        }

        errdefer self.leaveModes();
        if (opts.raw_mode) try self.enterModes();

        const size = opts.size orelse try self.term.size();

        // The cell grid is measured in PHYSICAL pixels, which is what the
        // terminal reports and what a glyph actually occupies. Layout is fed the
        // dpr as its scale, so a logical `Padding(16)` becomes 16 * dpr physical
        // pixels, and that lands on the same number of columns whatever the
        // display resolution:
        //   ordinary display, cell 9x18,  dpr 1.125 -> 18px -> 2.0 cols
        //   HiDPI display,    cell 19x37, dpr 2.31  -> 37px -> 1.95 cols
        // This reuses the scale `BoxConstraints` already carries and that
        // `Padding` and `Text` already apply, rather than a second parallel path.
        self.cell_w = size.cellWidth();
        self.cell_h = size.cellHeight();
        self.dpr = size.dpr();
        self.viewport = size.viewport();

        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.diag_writer = std.Io.File.stderr().writerStreaming(io, &self.diag_buf);
        self.sink = .{ .diagnostics = opts.diagnostics orelse &self.diag_writer.interface };
        self.owner = .{ .gpa = gpa, .sink = &self.sink, .io = io };
        errdefer self.owner.deinit();
        // The mono metrics are in physical pixels, the same space the cell grid
        // uses.
        self.owner.text_metrics = textMetricsFor(self.mode, self.cell_w, self.cell_h);

        // MediaQuery reports the LOGICAL size, so a widget that reads it sees
        // the same numbers on both machines: a fixed nominal cell height, not
        // the terminal's real (and HiDPI-dependent) reported pixels.
        _ = try phantom.View.open(&self.owner, .{
            .title = "phantom",
            .size = size.logicalViewport(),
            .dpr = self.dpr,
        });
        const view = self.owner.activeView().?;

        // FocusManager must outlive the element tree: tearing the tree down
        // walks every render object and calls back into this to forget its focus
        // handler, so it must still be alive when that walk runs. `deinit` takes
        // the tree down first for exactly that reason.
        self.focus_mgr = .{};
        errdefer self.focus_mgr.deinit(gpa);
        self.owner.focus = &self.focus_mgr;

        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const root_widget = root.call(&bctx);
        var mq = phantom.MediaQuery{ .data = &view.metrics, .child = root_widget };
        self.el = if (self.sink.ok())
            try mq.widget().mount(&bctx, null)
        else eb: {
            const errbox = phantom.ErrorBox{};
            break :eb try errbox.widget().mount(&bctx, null);
        };
        errdefer self.el.deinit(gpa);

        self.canvas = phantom.Canvas.init(gpa);
        self.canvas.sink = &self.sink;
        errdefer self.canvas.deinit();

        self.grid = try cell_grid.CellGrid.init(gpa, size.cols, size.rows);
        errdefer self.grid.deinit();

        // `viewport` is already the terminal's true pixel size, and layout runs
        // at the dpr, so the display list is in those same physical pixels. The
        // surface matches it one to one and mode A is sharp on a HiDPI display
        // with no special case. `rasterizer_builds and` makes this comptime-dead on
        // a target with no GPU path: without it, Zig would still have to compile
        // `PixelSurface.init` (and the prism driver registry it reaches into)
        // even though `mode` can never actually be `.pixels` there, because
        // `mode` is a runtime value Sema cannot trace back through `selectMode`.
        self.surface = if (rasterizer_builds and self.mode == .pixels)
            try tui_pixels.PixelSurface.init(
                gpa,
                @intFromFloat(self.viewport.width),
                @intFromFloat(self.viewport.height),
            )
        else
            null;
        errdefer if (self.surface) |*s| s.deinit();
        self.image_id = 1;
        self.prev_id = null;
        self.prev_footprint = null;

        self.frame = .empty;
        self.decoder = .{ .pixels = self.caps.sgr_pixel_mouse and self.mode == .pixels };
        self.dispatch = .{};
        self.owner.dispatcher = &self.dispatch;
        self.last_point = phantom.PhysicalOffset.zero;
        self.dropped_seen = 0;
        self.running = true;
        self.interrupt_pending = false;
        self.fed_since_step = false;
    }

    /// Put back everything `init` set up, in the order that leaves the terminal
    /// in the state a shell expects.
    ///
    /// The element tree comes down before the focus manager, because tearing the
    /// tree down calls back into the manager to forget each render object's
    /// focus handler. Everything that draws comes down before the terminal is
    /// put back, and the terminal is put back before the crash handlers are
    /// removed, so a signal arriving during teardown still finds a live restore.
    pub fn deinit(self: *Session) void {
        self.frame.deinit(self.gpa);
        if (self.surface) |*s| s.deinit();
        self.grid.deinit();
        self.canvas.deinit();
        self.el.deinit(self.gpa);
        self.focus_mgr.deinit(self.gpa);
        self.owner.deinit();
        self.arena.deinit();
        self.leaveModes();
        self.leaveScreen();
        self.restoreStderrAndReport();
        self.uninstallHandlers();
        if (self.opts.raw_mode) self.term.leaveRaw();
        self.* = undefined;
    }

    /// Draw one frame and take in whatever input has arrived. Returns false once
    /// the session has stopped, at which point the caller stops calling it and
    /// calls `deinit`.
    pub fn step(self: *Session) !bool {
        if (!self.running) return false;
        try self.renderFrame();

        // A terminal without in-band resize reports (mode 2048) uses SIGWINCH
        // instead, so both paths funnel through the same `resize`. tmux and
        // every terminal that is not ghostty rely on this branch. Posix only:
        // Windows sends no in-band report and `resized` never turns true there,
        // so a Windows resize never reaches `resize` at all and the display
        // desyncs from the real window until the next restart. Skipped entirely
        // when the caller forced a size, since that size is theirs to change.
        if (self.opts.size == null and self.term.resized()) {
            try self.resize(try self.term.size());
        }

        try self.pumpInput();
        self.reportDrops();
        return self.running;
    }

    /// Stop at the end of the current turn. Safe to call from a widget callback
    /// during `step`: the loop reads it on the way out.
    pub fn requestStop(self: *Session) void {
        self.running = false;
    }

    /// Whether ctrl-c has been pressed since the last time this was asked, and
    /// clear it. Only ever true under `Interrupt.notify`: `.stop` acts on the
    /// key itself and never records it.
    pub fn takeInterrupt(self: *Session) bool {
        const seen = self.interrupt_pending;
        self.interrupt_pending = false;
        return seen;
    }

    /// Move every piece of loop state to a new terminal geometry at once, so the
    /// grid, the surface and the layout constraints can never disagree about the
    /// display.
    pub fn resize(self: *Session, new_size: term_mod.Size) !void {
        // 1. The grid gets the new cell count and forgets what the terminal
        //    shows, because a resize scrolls and reflows whatever was there.
        try self.grid.resize(new_size.cols, new_size.rows);
        self.grid.invalidate();
        // 2. The reported cell size can change: dragging the window to a monitor
        //    with a different resolution changes the pixels per cell even when
        //    the grid stays the same. The dpr moves with it.
        self.cell_w = new_size.cellWidth();
        self.cell_h = new_size.cellHeight();
        self.dpr = new_size.dpr();
        // 3. `.cells` text must measure against the new cell size on the next
        //    layout. `.pixels` measures with the font's own proportional
        //    advances, which do not depend on the cell size, so recomputing mono
        //    metrics there would only overwrite the correct value with the wrong
        //    one. `mode` cannot change after startup, so this is not a fresh
        //    decision every resize: it is the startup choice honored again.
        self.owner.text_metrics = textMetricsFor(self.mode, self.cell_w, self.cell_h);
        // 4. The physical viewport drives the layout constraints.
        self.viewport = new_size.viewport();
        // 4b. Mode A's offscreen surface has to move with everything above, or
        //     it would keep painting into a surface sized for the old geometry.
        if (self.surface) |*s| try s.resize(
            @intFromFloat(self.viewport.width),
            @intFromFloat(self.viewport.height),
        );
        // 4c. The previous frame's footprint was measured in the old surface's
        //     coordinates. A shrink can put it outside the new surface entirely,
        //     so it cannot seed the next frame's union rectangle: the next
        //     damaged frame falls back to just its own damage, which
        //     `PixelSurface.resize` already forces to cover the whole surface.
        //     `prev_id` is untouched: freeing an id does not depend on geometry,
        //     so it is still deleted normally once the next frame supersedes it.
        self.prev_footprint = null;
        // 5. MediaQuery.of reports the logical size, so widgets see stable
        //    numbers even though the physical one just changed underneath.
        self.owner.setActiveViewMetrics(.{
            .size = new_size.logicalViewport(),
            .dpr = self.dpr,
            .text_scale = 1.0,
        });
        // 6. Clear the screen: the terminal reflowed whatever it already held,
        //    so the front buffer no longer describes what is on screen and every
        //    cell must go out fresh next frame.
        if (self.opts.own_screen) try self.writer.writeAll(ansi.clear_screen);
    }

    /// Send every query in one write, then read until DA1 answers. DA1 is last
    /// in the query string, so its answer proves all the others had their chance.
    fn probe(self: *Session, hint: caps_mod.Hint) !caps_mod.Caps {
        try self.writer.writeAll(caps_mod.queryFor(hint));
        try self.writer.flush();

        var reply_buf: [1024]u8 = undefined;
        var reply_len: usize = 0;
        // A terminal that never answers DA1 must not hang the program, so the
        // read count is bounded and a short reply is a valid outcome. VMIN 0,
        // VTIME 1 makes each read return within a tenth of a second even with no
        // input, so an empty read only means "nothing has arrived yet" and must
        // not stop the loop: the round trip can easily take longer than that.
        var reads: u8 = 0;
        while (reads < 32 and reply_len < reply_buf.len) : (reads += 1) {
            reply_len += readIdle(&self.term, self.io, reply_buf[reply_len..]) catch break;
            if (sawDA1(reply_buf[0..reply_len])) break;
        }
        return caps_mod.parseReplies(reply_buf[0..reply_len], hint);
    }

    /// Turn on the mouse, paste, resize and keyboard modes the capabilities
    /// allow. The kitty keyboard push must follow the capability probe, or the
    /// probe's own replies would arrive in the new format and parse wrongly.
    fn enterModes(self: *Session) !void {
        var kbd_buf: [16]u8 = undefined;
        try self.writer.writeAll(ansi.mouse_all_on ++ ansi.mouse_sgr_on ++ ansi.paste_on);
        if (self.caps.sgr_pixel_mouse and self.mode == .pixels) {
            try self.writer.writeAll(ansi.mouse_pixel_on);
        }
        // Ghostty only sends the CSI 48;...t report `decode.zig` parses into a
        // `.resize` event when this mode is on; asking for it here is what makes
        // that arm reachable at all. SIGWINCH stays wired as the fallback for
        // every terminal that does not answer the probe with `inband_resize`, so
        // turning this on for the ones that do can only add a faster, more
        // precise path, never remove the one that already works everywhere.
        if (self.caps.inband_resize) try self.writer.writeAll(ansi.inband_resize_on);
        if (self.caps.kitty_keyboard) {
            // Flag 1 disambiguates the escape key from a sequence, and flag 2
            // reports the release events the focus manager needs to ignore.
            try self.writer.writeAll(ansi.kittyKbdPush(&kbd_buf, 3));
        }
        try self.writer.flush();
    }

    /// Undo `enterModes`, in the exact reverse of the order they were set.
    /// Best effort: this runs on the way out, where there is nothing useful left
    /// to do with a write failure.
    fn leaveModes(self: *Session) void {
        if (!self.opts.raw_mode) return;
        if (self.caps.kitty_keyboard) self.writer.writeAll(ansi.kitty_kbd_pop) catch {};
        if (self.caps.inband_resize) self.writer.writeAll(ansi.inband_resize_off) catch {};
        self.writer.writeAll(ansi.paste_off ++ ansi.mouse_pixel_off ++
            ansi.mouse_sgr_off ++ ansi.mouse_all_off) catch {};
        self.writer.flush() catch {};
    }

    /// Put the cursor back and leave the alternate screen.
    fn leaveScreen(self: *Session) void {
        if (!self.opts.own_screen) return;
        self.writer.writeAll(ansi.cursor_show ++ ansi.alt_screen_off) catch {};
        self.writer.flush() catch {};
    }

    /// Remove the crash handlers and the panic hook. The hook is only cleared
    /// when this session installed it, so a hook the caller had already put in
    /// place survives.
    fn uninstallHandlers(self: *Session) void {
        if (self.opts.install_panic_hook) phantom.setPanicHook(null);
        // Always uninstalled, even with `install_signal_handlers` false:
        // `installCleanup` sets `cleanup_target` in every case, and leaving it
        // pointing at this Session's terminal after the Session is gone is
        // exactly the dangling read the pair exists to prevent.
        term_mod.uninstallCleanup();
    }

    /// The path `redirectStderr` was asked for, formatted into the session's own
    /// buffer for the temp log case, which varies per run.
    fn stderrPath(self: *Session, environ: *const std.process.Environ.Map) []const u8 {
        return switch (self.opts.stderr) {
            .leave => "",
            .path => |p| p,
            // The pid is in the filename because a machine runs more than one
            // instance at a time as a matter of course, for example bare ghostty
            // next to a tmux session under test. A shared name would have two
            // instances interleave their lines into one file, which makes the
            // log useless at exactly the moment someone needs to read it.
            .temp_log => std.fmt.bufPrint(
                &self.stderr_log_buf,
                "{s}/phantom-tui-stderr.{d}.log",
                .{ environ.get("TMPDIR") orelse "/tmp", currentPid() },
            ) catch "/tmp/phantom-tui-stderr.log",
        };
    }

    /// Put stderr back and say where this run's log went.
    ///
    /// Called only after the alternate screen is down (see `deinit`'s order):
    /// printing about this while the screen might still be up would risk being
    /// exactly the corruption the redirect exists to prevent.
    ///
    /// Printed on every exit, not only a degraded one: the temp path is
    /// pid-namespaced and so not guessable, and a human who never watched the
    /// screen for the one line a fallback would have printed still deserves a
    /// way to find their own log.
    ///
    /// The file is never deleted here, on purpose. A crash is exactly when
    /// someone needs it, and a crash cannot run this deletion anyway: it would
    /// have to happen from `restoreAndExit`/`panicCleanup`, and unlinking a file
    /// is not on the async-signal-safe list those paths are held to. Deleting on
    /// THIS, the clean exit path, would make the file survive a crash but vanish
    /// on a normal exit that still logged something real, which is backwards
    /// from what makes it useful. Left to the operating system's own temp
    /// directory hygiene to reap over time.
    fn restoreStderrAndReport(self: *Session) void {
        if (self.opts.stderr == .leave) return;
        self.term.restoreStderr();
        var msg_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
        // Null only happens on Windows, where `redirectStderr` returns before
        // ever setting `stderr_target`: stderr was never touched, so
        // `.unavailable` is the honest default. Claiming `.log_file` here would
        // print a path that was never created.
        const target = self.term.stderr_target orelse .unavailable;
        const msg = stderrTeardownMessage(&msg_buf, target, self.stderr_log_path);
        // Through the session's own writer rather than `std.log`, so it lands on
        // the real terminal the caller is looking at and not in the log file it
        // is telling them about. `restoreStderr` above has already put the
        // descriptor back, and this writer follows the descriptor.
        self.diagnostic("{s}\n", .{msg});
    }

    /// Write a line for a human, wherever this session's diagnostics go. Best
    /// effort and never fatal: a diagnostic that cannot be written is not worth
    /// failing on, and every caller here has already recorded the thing it is
    /// describing somewhere the harness can see it.
    fn diagnostic(self: *Session, comptime fmt: []const u8, args: anytype) void {
        const w = self.sink.diagnostics orelse return;
        w.print(fmt, args) catch {};
        w.flush() catch {};
    }

    /// Build, lay out, paint and send one frame.
    fn renderFrame(self: *Session) !void {
        var bctx = phantom.BuildContext{ .arena = self.arena.allocator(), .owner = &self.owner };
        const ts = std.Io.Clock.now(.awake, self.io);
        self.owner.scheduler.tick(ts.nanoseconds);
        self.owner.flushDirty(&bctx);
        // A rebuild can add or remove focusable nodes, so the traversal order is
        // rebuilt from the tree rather than kept incrementally.
        try self.focus_mgr.collect(self.gpa, self.el);

        self.canvas.clear();
        const ro = self.el.renderObject() orelse return error.NoRootRenderObject;
        // The dpr is the scale, exactly as the window backend does it.
        _ = ro.layout(phantom.BoxConstraints.tightScaled(self.viewport, self.dpr));
        try ro.paint(&self.canvas, phantom.PhysicalOffset.zero);

        self.frame.clearRetainingCapacity();
        // Only the selected mode ever writes to the screen. Cells and pixels are
        // two different owners of the same terminal surface, and driving both in
        // the same frame would have them fight over it.
        switch (self.mode) {
            .cells => try self.renderCells(),
            .pixels => try self.renderPixels(),
        }
        if (self.frame.items.len > 0) {
            try self.writer.writeAll(self.frame.items);
            try self.writer.flush();
        }
        // Transient configs produced during this build pass are dead now that
        // mount/update copied everything they keep into the gpa tree.
        _ = self.arena.reset(.retain_capacity);
    }

    fn renderCells(self: *Session) !void {
        self.grid.clear(cell_grid.Rgb.fromColor(phantom.ColorScheme.tokyoNight().bg));
        try tui_cells.render(&self.grid, self.canvas.list, .{
            .cell_w = self.cell_w,
            .cell_h = self.cell_h,
        });
        try self.grid.writeFrame(self.gpa, &self.frame, .{
            // An explicit choice wins; otherwise the terminal's own capability
            // decides, which is what a full-screen application wants.
            .color = self.opts.color orelse
                if (self.caps.truecolor) .truecolor else .indexed,
            .sync = self.caps.sync_output,
            .position = self.opts.position,
        });
    }

    fn renderPixels(self: *Session) !void {
        const s = &self.surface.?;
        const pixels = try s.renderFrame(self.canvas.list, phantom.ColorScheme.tokyoNight().bg);
        // `damage` returns null on an unchanged frame, and nothing below runs:
        // the frame stays empty and zero bytes go out. A still frame must send
        // nothing at all, or every idle tick would retransmit the whole image
        // and saturate the pty.
        const r = s.damage(pixels) orelse return;
        // Grown to also cover whatever the visible image occupies, not just this
        // frame's own damage. The new image is about to fully replace the old
        // one (the old id is freed below), so its footprint must be a superset
        // of the old one's, or the region the new frame does not touch would go
        // blank the moment the old id's data is freed.
        const want = if (self.prev_footprint) |pf| unionRect(pf, r) else r;
        const a = alignDamageToCells(want, self.cell_w, self.cell_h);
        const crop = try s.cropRect(self.gpa, pixels, a.crop);
        defer self.gpa.free(crop);
        if (self.caps.sync_output) try self.frame.appendSlice(self.gpa, ansi.sync_begin);
        try kitty_gfx.transmit(self.gpa, &self.frame, .{
            .id = self.image_id,
            .width = a.crop.w,
            .height = a.crop.h,
            .rgba = crop,
        }, a.place);
        // The old id is freed only after the new image is placed, so there is
        // never a moment with nothing on screen: the new placement already
        // covers everything the old one did.
        if (self.prev_id) |pid| try kitty_gfx.deleteImage(self.gpa, &self.frame, pid);
        if (self.caps.sync_output) try self.frame.appendSlice(self.gpa, ansi.sync_end);
        self.prev_footprint = a.crop;
        self.prev_id = self.image_id;
        self.image_id = if (self.image_id >= 1_000_000) 1 else self.image_id + 1;
    }

    /// Hand the session input the caller read itself. For `InputSource.fed`,
    /// where the session never touches the stream.
    ///
    /// The bytes are decoded on the next `step`, not here, so one place and only
    /// one place dispatches into the tree: feeding from inside a widget callback
    /// cannot re-enter the dispatch that is already running.
    ///
    /// Fed in chunks, because a single `feed` larger than the decoder's whole
    /// buffer could lose a bracketed paste's closing marker and strand the
    /// decoder in discard mode, which reads to a user as the keyboard dying.
    /// This is the same bound `pumpInput`'s own read holds itself to, kept here
    /// as well because a caller's read has no reason to know about it.
    pub fn feed(self: *Session, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > in_buf_size) {
            self.decoder.feed(rest[0..in_buf_size]);
            rest = rest[in_buf_size..];
        }
        self.decoder.feed(rest);
        self.fed_since_step = true;
    }

    /// Forget what the terminal is showing, so the next frame writes every cell
    /// again rather than only what changed.
    ///
    /// Call it whenever something other than this session has written to the
    /// region the session draws in. The front buffer records what each CELL
    /// holds, not where the region is, so a caller that prints a line and
    /// scrolls a `.relative` band to a new place leaves the old copy on screen
    /// with a front buffer that still matches it: the diff would then write
    /// nothing at all. See `cell_grid.Positioning.relative`.
    pub fn invalidate(self: *Session) void {
        self.grid.invalidate();
        // Mode A's damage tracking is the pixel equivalent of the front buffer,
        // and the same reasoning applies: drop the previous footprint so the
        // next frame cannot be diffed against a placement that has moved.
        self.prev_footprint = null;
        if (self.surface) |*s| s.invalidate();
    }

    /// Take in whatever input has arrived and dispatch it into the tree.
    fn pumpInput(self: *Session) !void {
        switch (self.opts.input orelse defaultInputSource(self.opts.raw_mode)) {
            .own => {
                const n = readIdle(&self.term, self.io, &self.in_buf) catch |err| {
                    // Losing the input stream means no key and no click can ever
                    // arrive again, so there is nothing left for the loop to do.
                    // Recorded rather than swallowed: a silent stop and a
                    // deliberate one look identical from the outside, which is
                    // the failure IronStyle's observable-recovery rule rules out.
                    self.diagnostic("terminal input read failed: {s}\n", .{@errorName(err)});
                    self.sink.report(.protocol, "terminal input read failed");
                    self.running = false;
                    return;
                };
                if (n > 0) self.decoder.feed(self.in_buf[0..n]) else self.decoder.flushPending();
            },
            // A turn with nothing fed is exactly a read that came back empty, so
            // it resolves a pending lone escape the same way. Without this, an
            // escape key held in the decoder waiting to be told it is not the
            // start of a sequence would never be released.
            .fed => if (!self.fed_since_step) self.decoder.flushPending(),
        }
        self.fed_since_step = false;

        while (self.decoder.next()) |ev| {
            switch (ev) {
                .mouse => |m| {
                    self.last_point = mousePoint(m, self.cell_w, self.cell_h);
                    switch (m.kind) {
                        .move => self.dispatch.move(self.el, self.last_point),
                        .down => self.dispatch.down(self.el, self.last_point),
                        .up => self.dispatch.up(self.el, self.last_point),
                        .scroll => {
                            const s = scrollPixels(m, self.cell_w, self.cell_h);
                            self.dispatch.scroll(self.el, self.last_point, s.dx, s.dy);
                        },
                    }
                },
                .key => |k| {
                    // Checked before the tree ever sees the key, so a focused
                    // widget cannot swallow the only way out.
                    if (isQuit(k)) {
                        switch (self.opts.interrupt) {
                            .stop => {
                                self.running = false;
                                return;
                            },
                            .notify => self.interrupt_pending = true,
                        }
                        continue;
                    }
                    _ = self.focus_mgr.dispatch(k);
                },
                // Nothing consumes a paste yet. It is decoded so a text field
                // can take it later with no protocol change.
                .paste => {},
                .resize => |s| {
                    // A forced size is the caller's to change, so a report from
                    // the terminal is decoded and then ignored.
                    if (self.opts.size == null) try self.resize(s);
                },
            }
        }
    }

    /// Say so when the decoder had to drop input. Recovery must be observable.
    ///
    /// The alternate screen owns the display, so this goes to the session's
    /// diagnostics writer (pointed at a file, never at the screen, see
    /// `Term.redirectStderr`) and to the fault sink, and never to the screen.
    ///
    /// The raw bytes matter: a drop count with nothing attached gives a human
    /// nothing to debug against, which is exactly what made a false fault on
    /// every bare shift press hard to pin down.
    fn reportDrops(self: *Session) void {
        if (self.decoder.dropped == self.dropped_seen) return;
        const hex = std.fmt.bytesToHex(self.decoder.last_dropped, .lower);
        self.diagnostic("terminal input dropped, last sequence: {s}\n", .{
            hex[0 .. self.decoder.last_dropped_len * 2],
        });
        self.sink.report(.protocol, "terminal input sequences dropped");
        self.dropped_seen = self.decoder.dropped;
    }
};

test "the mode follows the graphics capability when there is no override" {
    try std.testing.expectEqual(Mode.pixels, selectMode(.{ .kitty_graphics = true }, null));
    try std.testing.expectEqual(Mode.cells, selectMode(.{ .kitty_graphics = false }, null));
}

test "PHANTOM_TUI overrides the capability in both directions" {
    try std.testing.expectEqual(Mode.cells, selectMode(.{ .kitty_graphics = true }, "cells"));
    try std.testing.expectEqual(Mode.pixels, selectMode(.{ .kitty_graphics = false }, "pixel"));
}

test "an unknown PHANTOM_TUI value falls back to the capability and does not fail" {
    try std.testing.expectEqual(Mode.pixels, selectMode(.{ .kitty_graphics = true }, "nonsense"));
    try std.testing.expectEqual(Mode.cells, selectMode(.{ .kitty_graphics = false }, "auto"));
}

test "sawDA1 recognises a real DA1 answer" {
    try std.testing.expect(sawDA1("\x1b[?62;1c"));
}

test "sawDA1 rejects a bare CSI ? c with no parameters, sharing findCsiQuestion's guard" {
    // A DA1 reply always carries at least one parameter. A scanner that accepts a
    // zero digit "CSI ? c" would also match a truncated reply that never sent its
    // parameters, and stop the probe before the terminal actually answered.
    try std.testing.expect(!sawDA1("\x1b[?c"));
}

test "sawDA1 ignores a stray byte that only looks like a terminator" {
    try std.testing.expect(!sawDA1("c"));
    try std.testing.expect(!sawDA1("\x1b[?1uc"));
}

test "mousePoint converts cell coordinates to physical pixels using the cell size" {
    const m = decode.MouseEvent{ .kind = .down, .x = 10, .y = 5 };
    const p = mousePoint(m, 9, 18);
    try std.testing.expectEqual(@as(f32, 90), p.x);
    try std.testing.expectEqual(@as(f32, 90), p.y);
}

test "mousePoint passes reported pixels through unchanged when mode 1016 is on" {
    const m = decode.MouseEvent{ .kind = .down, .x = 123, .y = 45, .pixels = true };
    const p = mousePoint(m, 9, 18);
    try std.testing.expectEqual(@as(f32, 123), p.x);
    try std.testing.expectEqual(@as(f32, 45), p.y);
}

test "scrollPixels turns one wheel notch into three lines of the current cell size" {
    const m = decode.MouseEvent{ .kind = .scroll, .scroll_dy = 1 };
    const s = scrollPixels(m, 9, 18);
    try std.testing.expectEqual(@as(f32, 0), s.dx);
    try std.testing.expectEqual(@as(f32, 54), s.dy);
}

test "scrollPixels scales a horizontal notch by the cell width, not the height" {
    const m = decode.MouseEvent{ .kind = .scroll, .scroll_dx = -1 };
    const s = scrollPixels(m, 9, 18);
    try std.testing.expectEqual(@as(f32, -27), s.dx);
    try std.testing.expectEqual(@as(f32, 0), s.dy);
}

test "textMetricsFor gives cells mode the mono metrics derived from the reported cell size" {
    const tm = textMetricsFor(.cells, 9, 18);
    try std.testing.expectEqual(phantom.text.mono.TextMetrics{ .mono = phantom.text.mono.Mono.fromCell(9, 18) }, tm);
}

test "textMetricsFor gives pixels mode the proportional metrics and ignores the cell size" {
    // The cell size is deliberately different from the cells-mode case above: a
    // pixels-mode result that varied with it would mean the cell advance leaked
    // into mode A's layout, which is the exact bug being fixed.
    const tm = textMetricsFor(.pixels, 40, 90);
    try std.testing.expectEqual(phantom.text.mono.TextMetrics.proportional, tm);
}

test "unionRect covers both rectangles when neither contains the other" {
    const r = unionRect(
        .{ .x = 10, .y = 10, .w = 5, .h = 5 }, // covers 10..14
        .{ .x = 20, .y = 30, .w = 5, .h = 5 }, // covers 20..24, 30..34
    );
    try std.testing.expectEqual(tui_pixels.Rect{ .x = 10, .y = 10, .w = 15, .h = 25 }, r);
}

test "unionRect of a rectangle with itself is unchanged" {
    const a = tui_pixels.Rect{ .x = 4, .y = 9, .w = 6, .h = 2 };
    try std.testing.expectEqual(a, unionRect(a, a));
}

test "unionRect is not affected by argument order" {
    const a = tui_pixels.Rect{ .x = 12, .y = 1, .w = 3, .h = 40 };
    const b = tui_pixels.Rect{ .x = 0, .y = 5, .w = 50, .h = 1 };
    try std.testing.expectEqual(unionRect(a, b), unionRect(b, a));
}

test "unionRect swallows a rectangle fully contained in the other" {
    const outer = tui_pixels.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const inner = tui_pixels.Rect{ .x = 10, .y = 10, .w = 5, .h = 5 };
    try std.testing.expectEqual(outer, unionRect(outer, inner));
}

test "alignDamageToCells leaves a rectangle already on a cell boundary unchanged" {
    const a = alignDamageToCells(.{ .x = 10, .y = 20, .w = 5, .h = 5 }, 10, 10);
    try std.testing.expectEqual(tui_pixels.Rect{ .x = 10, .y = 20, .w = 5, .h = 5 }, a.crop);
    try std.testing.expectEqual(kitty_gfx.Placement{ .col = 1, .row = 2 }, a.place);
}

test "alignDamageToCells grows the rectangle to the enclosing cell instead of only rounding the origin down" {
    // Damage covers pixels 15..19 with a 10px cell: rounding the origin down to 10
    // and keeping the width at 5 would place the image starting at pixel 10 while
    // its leftmost column of real content is pixel 15, leaving pixels 10..14 showing
    // stale content underneath the misplaced image. Growing the width to 10 (10..19)
    // keeps the far edge fixed and the image lines up with the cell it is placed at.
    const a = alignDamageToCells(.{ .x = 15, .y = 15, .w = 5, .h = 5 }, 10, 10);
    try std.testing.expectEqual(tui_pixels.Rect{ .x = 10, .y = 10, .w = 10, .h = 10 }, a.crop);
    try std.testing.expectEqual(kitty_gfx.Placement{ .col = 1, .row = 1 }, a.place);
}

test "alignDamageToCells keeps the far edge of the rectangle fixed however far the origin moves" {
    const r = tui_pixels.Rect{ .x = 37, .y = 41, .w = 8, .h = 3 };
    const a = alignDamageToCells(r, 19, 9);
    try std.testing.expectEqual(r.x + r.w, a.crop.x + a.crop.w);
    try std.testing.expectEqual(r.y + r.h, a.crop.y + a.crop.h);
}

test "stderrTeardownMessage names the log path on success, so a pid-namespaced file is still findable" {
    var buf: [256]u8 = undefined;
    const msg = stderrTeardownMessage(&buf, .log_file, "/tmp/phantom-tui-stderr.4242.log");
    try std.testing.expect(std.mem.indexOf(u8, msg, "/tmp/phantom-tui-stderr.4242.log") != null);
}

test "stderrTeardownMessage names both degraded outcomes, distinctly, and ignores path for them" {
    var buf: [256]u8 = undefined;
    const dev_null_msg = stderrTeardownMessage(&buf, .dev_null, "/should/not/appear");
    const unavailable_msg = stderrTeardownMessage(&buf, .unavailable, "/should/not/appear");
    try std.testing.expect(dev_null_msg.len > 0);
    try std.testing.expect(unavailable_msg.len > 0);
    try std.testing.expect(!std.mem.eql(u8, dev_null_msg, unavailable_msg));
    try std.testing.expect(std.mem.indexOf(u8, dev_null_msg, "/should/not/appear") == null);
    try std.testing.expect(std.mem.indexOf(u8, unavailable_msg, "/should/not/appear") == null);
}

test "isQuit recognises ctrl-c and nothing else" {
    try std.testing.expect(isQuit(.{ .keysym = phantom.input.Keysym.fromCodepoint('c'), .mods = .{ .ctrl = true } }));
    // Plain c, with no modifier, must not quit the program.
    try std.testing.expect(!isQuit(.{ .keysym = phantom.input.Keysym.fromCodepoint('c') }));
    // A different letter held with ctrl must not quit either.
    try std.testing.expect(!isQuit(.{ .keysym = phantom.input.Keysym.fromCodepoint('x'), .mods = .{ .ctrl = true } }));
}

/// A whole session driven over two ordinary files, with no terminal anywhere.
///
/// This is what every field on `Options` exists for, exercised together: `in`
/// and `out` point somewhere that is not a terminal, `control_terminal` keeps
/// the session from configuring a device that is not there, `size` supplies the
/// geometry `TIOCGWINSZ` cannot, and the signal and stderr policies stop a test
/// from taking over the test runner's own process. None of this was reachable
/// while the loop hard-wired stdin and stdout and owned the whole program.
const Headless = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    env: std.process.Environ.Map,
    in_path: []const u8,
    out_path: []const u8,
    in_file: std.Io.File,
    out_file: std.Io.File,
    session: Session,
    /// `Session.deinit` leaves its own storage undefined, so tearing down twice
    /// is not safe. This lets a test that wants to read the bytes `deinit`
    /// itself writes call `stop` early and still keep `close` on a `defer`.
    stopped: bool,

    /// The geometry every headless test runs at. The cell works out to exactly 8
    /// by 16, so the device pixel ratio is 1.0 and a column is a round number of
    /// pixels, which keeps a failure about the thing under test and not about
    /// where a glyph rounded to.
    const size = term_mod.Size{ .cols = 24, .rows = 4, .xpixel = 192, .ypixel = 64 };

    /// Heap-allocated because a `Session` holds pointers into its own fields and
    /// must not move: see `Tui.run`.
    fn open(
        gpa: std.mem.Allocator,
        name: []const u8,
        input: []const u8,
        root: phantom.Root,
        opts: Options,
    ) !*Headless {
        const h = try gpa.create(Headless);
        errdefer gpa.destroy(h);
        h.gpa = gpa;
        h.threaded = std.Io.Threaded.init(gpa, .{});
        errdefer h.threaded.deinit();
        const io = h.threaded.io();
        h.env = std.process.Environ.Map.init(gpa);
        errdefer h.env.deinit();

        h.in_path = try std.fmt.allocPrint(gpa, "/tmp/phantom-tui-headless-{s}.in", .{name});
        errdefer gpa.free(h.in_path);
        h.out_path = try std.fmt.allocPrint(gpa, "/tmp/phantom-tui-headless-{s}.out", .{name});
        errdefer gpa.free(h.out_path);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = h.in_path, .data = input });
        h.in_file = try std.Io.Dir.openFileAbsolute(io, h.in_path, .{});
        errdefer h.in_file.close(io);
        h.out_file = try std.Io.Dir.createFileAbsolute(io, h.out_path, .{});
        errdefer h.out_file.close(io);

        var o = opts;
        o.in = h.in_file;
        o.out = h.out_file;
        h.stopped = false;
        try h.session.init(gpa, io, &h.env, root, o);
        return h;
    }

    /// Tear the session down but keep the files, so a test can read the bytes
    /// `Session.deinit` itself writes.
    fn stop(h: *Headless) void {
        if (h.stopped) return;
        h.stopped = true;
        h.session.deinit();
    }

    fn close(h: *Headless) void {
        const io = h.threaded.io();
        h.stop();
        h.out_file.close(io);
        h.in_file.close(io);
        std.Io.Dir.cwd().deleteFile(io, h.out_path) catch {};
        std.Io.Dir.cwd().deleteFile(io, h.in_path) catch {};
        h.gpa.free(h.out_path);
        h.gpa.free(h.in_path);
        h.env.deinit();
        h.threaded.deinit();
        h.gpa.destroy(h);
    }

    /// Every byte the session has written so far. The caller frees it. The
    /// session flushes at the end of each frame, so this is complete as of the
    /// last `step`.
    fn output(h: *Headless) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(h.threaded.io(), h.out_path, h.gpa, .limited(1 << 20));
    }
};

/// Everything a headless run has to switch off. There is no device to put in
/// raw mode and nobody to answer a probe, and taking the test runner's own
/// signals, panic hook or stderr would break every test that runs after this
/// one.
///
/// `own_screen` is deliberately left ON. The alternate screen is only escape
/// bytes, so it works over a file, and leaving it on is what lets these tests
/// pin the order the session brings the screen up and takes it back down.
fn headlessOpts(interrupt: Interrupt) Options {
    return .{
        .size = Headless.size,
        .raw_mode = false,
        .query_capabilities = false,
        .install_signal_handlers = false,
        .install_panic_hook = false,
        .stderr = .leave,
        .interrupt = interrupt,
    };
}

/// A tree with one label in it, so a test can look for the label's own glyphs in
/// the bytes the session wrote.
const Label = struct {
    text: []const u8,

    fn build(ctx: *phantom.BuildContext, self: *Label) phantom.Widget {
        return ctx.new(phantom.Text{ .text = self.text, .size = 16 }).widget();
    }
};

test "a session runs over two ordinary files, with no terminal, no raw mode and no signals" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "render",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.stop),
    );
    defer h.close();

    try std.testing.expect(try h.session.step());

    const out = try h.output();
    defer gpa.free(out);
    // The frame really was drawn and really did reach the caller's file.
    try std.testing.expect(std.mem.indexOf(u8, out, "phantom") != null);
    // `raw_mode` false, so nothing asked for the mouse and paste reporting that
    // only reaches a program in raw mode.
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.mouse_all_on) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.paste_on) == null);
    // `query_capabilities` false, so no query went out to a stream that could
    // never answer one. DA1 is the last query and the one the probe waits on.
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.csi ++ "c") == null);
}

test "a session brings the screen up before the first frame and takes it back down after the last" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "screen",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.stop),
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    // Stopped here rather than left to `close`, because the teardown bytes are
    // what this test is about and none of them are written until `deinit` runs.
    h.stop();
    const out = try h.output();
    defer gpa.free(out);

    const up = std.mem.indexOf(u8, out, ansi.alt_screen_on) orelse return error.NoAltScreen;
    const hide = std.mem.indexOf(u8, out, ansi.cursor_hide) orelse return error.NoCursorHide;
    const frame = std.mem.indexOf(u8, out, "phantom") orelse return error.NoFrame;
    const show = std.mem.indexOf(u8, out, ansi.cursor_show) orelse return error.NoCursorShow;
    const down = std.mem.indexOf(u8, out, ansi.alt_screen_off) orelse return error.NoAltScreenOff;

    // The order is the whole contract, and it is what the rewrite from a stack
    // of `defer`s to an explicit `deinit` could most easily have got wrong: a
    // frame drawn before the alternate screen is up lands on the user's real
    // scrollback, and a screen taken down before the last frame is written puts
    // that frame there too.
    try std.testing.expect(up < hide);
    try std.testing.expect(hide < frame);
    try std.testing.expect(frame < show);
    try std.testing.expect(show < down);
}

test "an inline session leaves the alternate screen alone and draws at the origin it was given" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    var opts = headlessOpts(.stop);
    opts.own_screen = false;
    opts.position = .{ .absolute = .{ .col = 3, .row = 10 } };
    opts.color = .none;
    const h = try Headless.open(
        gpa,
        "inline",
        "",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    const out = try h.output();
    defer gpa.free(out);

    // Nothing took the screen, so the terminal keeps its own display and its
    // scrollback: this session owns a region, not the terminal.
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.alt_screen_on) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.cursor_hide) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, ansi.clear_screen) == null);
    // The first row of the region is at screen row 10, column 3, which CUP
    // counts from one as row 11 column 4. Without the origin every span would
    // start at "\x1b[1;1H" and paint over whatever is at the top of the screen.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[11;4H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H") == null);
    // `.none` colour, so the region borrows whatever colours the surrounding
    // display already has and emits no SGR of its own.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[48;") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "phantom") != null);
}

test "ctrl-c under the stop policy ends the session on the turn it arrives" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "stop",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.stop),
    );
    defer h.close();

    h.session.feed("\x03");
    // The turn draws its frame, then takes in the ctrl-c and stops, so `step`
    // reports there is no next turn.
    try std.testing.expect(!try h.session.step());
    // `.stop` acts on the key rather than recording it, so there is nothing left
    // for a caller to collect.
    try std.testing.expect(!h.session.takeInterrupt());
}

test "ctrl-c under the notify policy keeps the session running and is reported exactly one time" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "notify",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.notify),
    );
    defer h.close();

    h.session.feed("\x03");
    // Still running: this is the whole point of `.notify`. The caller gets to
    // finish what it was doing and stop at a point it chooses, which is exactly
    // what an immediate exit takes away.
    try std.testing.expect(try h.session.step());
    try std.testing.expect(h.session.takeInterrupt());
    // Taking it clears it, so one press is not reported twice.
    try std.testing.expect(!h.session.takeInterrupt());
    // And the session really did keep going rather than merely reporting that
    // it had.
    try std.testing.expect(try h.session.step());
}

test "requestStop ends the session at the end of the turn, without a key press" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "requeststop",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.notify),
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    h.session.requestStop();
    try std.testing.expect(!try h.session.step());
}

/// The function a Sigaction currently points at, or 0 for SIG_DFL and SIG_IGN.
/// Both are small integer sentinels the kernel casts to the handler's pointer
/// type, not real functions, so 0 for "no handler" is as meaningful to compare
/// as a real address.
fn sigHandlerAddr(act: std.posix.Sigaction) usize {
    return if (act.handler.handler) |f| @intFromPtr(f) else 0;
}

test "a session told to keep its hands off the signals leaves SIGINT and SIGTERM exactly as it found them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    var before_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, null, &before_int);
    var before_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &before_term);

    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "signals",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.notify),
    );
    defer h.close();

    // Checked while the session is live, not after teardown: a session that
    // installed a handler and then put it back would pass an after-the-fact
    // check while still having exited the process out from under its caller in
    // between.
    var during_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, null, &during_int);
    var during_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &during_term);

    try std.testing.expectEqual(sigHandlerAddr(before_int), sigHandlerAddr(during_int));
    try std.testing.expectEqual(sigHandlerAddr(before_term), sigHandlerAddr(during_term));
}

test "a caller's own writer receives the frame, so nothing bypasses the caller's ordering of its output" {
    const gpa = std.testing.allocator;
    var collected = std.Io.Writer.Allocating.init(gpa);
    defer collected.deinit();

    var label = Label{ .text = "phantom" };
    var opts = headlessOpts(.stop);
    opts.writer = &collected.writer;
    const h = try Headless.open(
        gpa,
        "writer",
        "",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    try std.testing.expect(std.mem.indexOf(u8, collected.written(), "phantom") != null);

    // And the session's own file got nothing, which is what proves the frame
    // went through the caller's writer rather than merely also through it.
    const out = try h.output();
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "two sessions in one process draw from two separate states, which a process global could not do" {
    const gpa = std.testing.allocator;
    var first = Label{ .text = "alpha" };
    var second = Label{ .text = "bravo" };

    // Both live at once. The one thing they do share is `cleanup_target`, which
    // is global because a signal handler takes no context: only one session can
    // own a real terminal, so the crash restore path is single-owner by nature.
    // Everything a frame is built from is per session.
    const a = try Headless.open(
        gpa,
        "two-a",
        "",
        phantom.Root.of(Label, Label.build, &first),
        headlessOpts(.stop),
    );
    defer a.close();
    const b = try Headless.open(
        gpa,
        "two-b",
        "",
        phantom.Root.of(Label, Label.build, &second),
        headlessOpts(.stop),
    );
    defer b.close();

    try std.testing.expect(try a.session.step());
    try std.testing.expect(try b.session.step());

    const out_a = try a.output();
    defer gpa.free(out_a);
    const out_b = try b.output();
    defer gpa.free(out_b);

    try std.testing.expect(std.mem.indexOf(u8, out_a, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_a, "bravo") == null);
    try std.testing.expect(std.mem.indexOf(u8, out_b, "bravo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_b, "alpha") == null);
}

test "a session does not read a stream it was not told to read, so a pipe with nothing on it cannot stop the loop" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;

    // A pipe with nothing written to it and no writer closed, which is exactly
    // a terminal that nobody has typed at yet. Reading it BLOCKS: there is no
    // data and no end of stream, and no VMIN or VTIME to cut the wait short,
    // because nothing here put a terminal in raw mode. If `step` reads this,
    // the whole test run hangs, which is what this test exists to catch.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(std.posix.system.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
    // The write end is held open on purpose and never written to. Closing it
    // would give the read end an end of stream, and a read that returns
    // immediately is exactly the case this test is NOT about.
    defer _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);
    const read_end = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };

    var label = Label{ .text = "phantom" };
    const opts = headlessOpts(.stop);
    // Not set explicitly: the DEFAULT has to be the safe one. A caller that
    // turns raw mode off and thinks no further about it must not be handed a
    // loop that stops on the first turn.
    try std.testing.expect(opts.input == null);
    const h = try Headless.open(
        gpa,
        "pipe",
        "",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();
    // Point the session at the pipe rather than at the fixture's own file,
    // after `init`, since `Headless.open` fills `in` in for its own file.
    h.session.term.in = read_end;

    try std.testing.expect(try h.session.step());
    try std.testing.expect(try h.session.step());

    // And it still takes input, just not by reading: the caller pushes it.
    h.session.feed("\x03");
    try std.testing.expect(!try h.session.step());
}

test "a caller that put the terminal in raw mode itself can still ask the session to do the reading" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    var opts = headlessOpts(.stop);
    // `raw_mode` is false because there is no terminal here to put in raw mode,
    // but the stream is a file, which never blocks, so reading it is safe. This
    // is the override the default exists to be overridable from.
    opts.input = .own;
    const h = try Headless.open(
        gpa,
        "own-input",
        "\x03",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();

    try std.testing.expect(!try h.session.step());
}

test "feed larger than the decoder's buffer is chunked, so a long paste cannot strand the decoder" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "bigfeed",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.stop),
    );
    defer h.close();

    // A bracketed paste far longer than one feed's worth, so the closing marker
    // lands in a later chunk than the opening one. A single oversized feed
    // would overrun the decoder's buffer and lose the marker, leaving the
    // decoder discarding every byte from then on, which reads to a user as the
    // keyboard having died.
    var paste: std.ArrayList(u8) = .empty;
    defer paste.deinit(gpa);
    try paste.appendSlice(gpa, "\x1b[200~");
    try paste.appendNTimes(gpa, 'x', in_buf_size * 4);
    try paste.appendSlice(gpa, "\x1b[201~");
    h.session.feed(paste.items);
    try std.testing.expect(try h.session.step());

    // The proof the decoder is not stranded: a ctrl-c fed afterwards still gets
    // through and still stops the session.
    h.session.feed("\x03");
    try std.testing.expect(!try h.session.step());
}

test "a relative band moves with the cursor instead of naming a screen row" {
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    var opts = headlessOpts(.stop);
    opts.own_screen = false;
    opts.position = .relative;
    opts.color = .none;
    const h = try Headless.open(
        gpa,
        "relative",
        "",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    const out = try h.output();
    defer gpa.free(out);

    // Not one absolute address anywhere in the frame. That is the whole point:
    // a band under scrolling text has no fixed screen row to name, because
    // every line the caller prints scrolls it up by one.
    try std.testing.expect(std.mem.indexOf(u8, out, "H") == null);
    // It reaches its rows by moving down from where the cursor already was, and
    // its columns by returning to column one and moving right.
    try std.testing.expect(std.mem.indexOf(u8, out, "\r") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "phantom") != null);
    // And it leaves the cursor back where it started, so the next frame counts
    // from the same place and the caller's own next line lands below the band
    // rather than through the middle of it.
    //
    // The count is asserted, not just the presence of a move: the first frame
    // writes every row, so the cursor ends on the band's last row and has to
    // come back up by exactly that many. A weaker check that only looked for
    // the trailing carriage return passed with the move missing entirely, which
    // would leave the caller's next line inside the band.
    var home_buf: [16]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "\x1b[{d}A\r", .{Headless.size.rows - 1});
    try std.testing.expect(std.mem.endsWith(u8, out, home));
}

test "a session writes its diagnostics wherever the caller points them, never at the process's stderr" {
    const gpa = std.testing.allocator;
    var collected = std.Io.Writer.Allocating.init(gpa);
    defer collected.deinit();

    var label = Label{ .text = "phantom" };
    var opts = headlessOpts(.stop);
    opts.diagnostics = &collected.writer;
    const h = try Headless.open(
        gpa,
        "diagnostics",
        "",
        phantom.Root.of(Label, Label.build, &label),
        opts,
    );
    defer h.close();

    try std.testing.expect(try h.session.step());
    // Reported through the session's own sink, which is what every widget in
    // the tree reports through, so this is the same path a real fault takes.
    h.session.sink.report(.protocol, "a fault the caller should see");
    try std.testing.expect(std.mem.indexOf(
        u8,
        collected.written(),
        "phantom fault: protocol: a fault the caller should see",
    ) != null);

    // And it did not land in the frame. The display and the diagnostics are two
    // destinations, and a fault written into the frame is exactly the corruption
    // the terminal backend's stderr handling exists to prevent.
    const out = try h.output();
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a fault the caller should see") == null);
}

test "a session leaves stderr alone under the leave policy" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var label = Label{ .text = "phantom" };
    const h = try Headless.open(
        gpa,
        "stderr",
        "",
        phantom.Root.of(Label, Label.build, &label),
        headlessOpts(.stop),
    );
    defer h.close();

    // Nothing was saved, because nothing was moved. A caller that already sends
    // its own logs somewhere safe keeps its stderr pointing where it put it.
    try std.testing.expect(h.session.term.saved_stderr == null);
    try std.testing.expect(h.session.term.stderr_target == null);
}
