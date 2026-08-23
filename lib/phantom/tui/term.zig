//! Terminal control. This file holds the only two operations that `std.Io` does not
//! supply: the termios raw mode and the `TIOCGWINSZ` size. Everything else in the
//! terminal path reads and writes through `std.Io`.
const std = @import("std");
const builtin = @import("builtin");
const geom = @import("../geometry.zig");
const ansi = @import("ansi.zig");

/// The cell size to use when the terminal reports no pixel dimensions. Ghostty
/// reports true values, so this applies to the terminals that do not.
pub const default_cell_w: f32 = 8;
pub const default_cell_h: f32 = 16;

/// The nominal cell height that `dpr` scales the reported cell height against. A
/// REPORTED cell (`cellHeight`) is in PHYSICAL pixels and grows on a HiDPI
/// display, so it cannot serve as the logical unit itself: two machines showing
/// the same grid would then report different sizes. Dividing the reported
/// height by this nominal one is what turns the reported size into a device
/// pixel ratio instead.
///
/// There is no `logical_cell_w` beside it: a real cell's width does not scale
/// by the same ratio as its height (see `logicalViewport`), so no nominal cell
/// width is honest to define.
pub const logical_cell_h: f32 = 16;

/// What `redirectStderr` actually managed to point stderr at. A caller reads
/// `Term.stderr_target` after the call, since the call itself cannot fail in a
/// way that leaves the caller unable to find out: see `redirectStderr`.
pub const StderrTarget = enum {
    /// Redirected to the intended log file. A human can read it after the run.
    log_file,
    /// The intended log file could not be opened (a full disk, a read-only
    /// /tmp), so stderr goes to `/dev/null` instead. The display stays safe;
    /// nothing from this run can be diagnosed afterward, because nothing was
    /// kept.
    dev_null,
    /// Neither destination could be opened. Stderr still points at the real
    /// terminal, so a warning logged while the alternate screen is up can still
    /// scroll and corrupt it, exactly as if `redirectStderr` had never been
    /// called at all.
    unavailable,
};

pub const Size = struct {
    cols: u16,
    rows: u16,
    xpixel: u16,
    ypixel: u16,

    pub fn cellWidth(self: Size) f32 {
        if (self.cols == 0 or self.xpixel == 0) return default_cell_w;
        return @as(f32, @floatFromInt(self.xpixel)) / @as(f32, @floatFromInt(self.cols));
    }

    pub fn cellHeight(self: Size) f32 {
        if (self.rows == 0 or self.ypixel == 0) return default_cell_h;
        return @as(f32, @floatFromInt(self.ypixel)) / @as(f32, @floatFromInt(self.rows));
    }

    /// The physical pixel viewport that layout runs in. This is the cell count
    /// multiplied by the cell size, and not the reported pixel size, so a terminal
    /// with no pixel report still gets a viewport that agrees with its grid.
    pub fn viewport(self: Size) geom.PhysicalSize {
        return .{
            .width = @as(f32, @floatFromInt(self.cols)) * self.cellWidth(),
            .height = @as(f32, @floatFromInt(self.rows)) * self.cellHeight(),
        };
    }

    /// The logical size layout works in, which is the physical viewport divided by
    /// the device pixel ratio. `MediaQuery` reports this, so a widget that sizes
    /// itself from it agrees with the constraints the root actually received.
    ///
    /// The height always works out to `rows * logical_cell_h`, because the dpr is
    /// derived from the cell height. The width does NOT reduce to `cols *
    /// logical_cell_w`, because a real cell is not exactly half as wide as it is
    /// tall: a measured ghostty reports 19 by 37, an aspect of 0.514 and not 0.5.
    /// One scalar ratio cannot reconcile both axes, and the honest answer is the
    /// space that layout genuinely has.
    pub fn logicalViewport(self: Size) geom.LogicalSize {
        const v = self.viewport();
        const s = self.dpr();
        return .{ .width = v.width / s, .height = v.height / s };
    }

    /// How many physical pixels one logical pixel covers. This is the terminal's
    /// reported cell height against the nominal one. It is 1.0 when the terminal
    /// reports no pixel size, because then there is nothing to scale by.
    pub fn dpr(self: Size) f32 {
        if (self.rows == 0 or self.ypixel == 0) return 1.0;
        return self.cellHeight() / logical_cell_h;
    }
};

/// Set by the SIGWINCH handler and read by the event loop. A signal handler cannot
/// take a context parameter, so this one flag is global. It is the sanctioned
/// exception in IronStyle for a handler that the kernel dispatches.
var winch_flag: std.atomic.Value(bool) = .init(false);

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    winch_flag.store(true, .release);
}

pub const Term = struct {
    io: std.Io,
    in: std.Io.File,
    out: std.Io.File,
    saved: ?std.posix.termios = null,
    /// The console modes to restore on Windows. Two handles carry two modes, so the
    /// posix `saved` termios cannot hold them. `void` on every other target, so the
    /// field costs nothing there.
    saved_console: if (builtin.os.tag == .windows) ?@import("term_windows.zig").SavedConsole else void =
        if (builtin.os.tag == .windows) null else {},
    /// The real stderr, saved by `redirectStderr` so `restoreStderr` can put it
    /// back. Null when stderr is not currently redirected.
    saved_stderr: ?std.posix.fd_t = null,
    /// Which target `redirectStderr` actually reached. Null before the first
    /// call. See `StderrTarget`.
    stderr_target: ?StderrTarget = null,

    /// A terminal on the process's own stdin and stdout.
    pub fn init(io: std.Io) Term {
        return initFiles(io, std.Io.File.stdin(), std.Io.File.stdout());
    }

    /// A terminal on files the caller chose. A caller that already owns its
    /// stdin and stdout, and a test that drives the whole path over a pipe,
    /// both need a way in that is not the process's own handles.
    pub fn initFiles(io: std.Io, in: std.Io.File, out: std.Io.File) Term {
        return .{ .io = io, .in = in, .out = out };
    }

    /// Put the terminal in raw mode. On posix this also installs the SIGWINCH
    /// resize handler and saves the exact termios to restore, so `leaveRaw`
    /// returns the terminal to what the user had and not to a guess. On Windows
    /// there is no SIGWINCH and no termios: see `term_windows.zig`'s `enterRaw`
    /// for what that platform saves and restores instead.
    pub fn enterRaw(self: *Term) !void {
        if (builtin.os.tag == .windows) return @import("term_windows.zig").enterRaw(self);
        // A second call while raw mode is already active would read back the raw
        // termios this function already set and save that as the restore state, so
        // `leaveRaw` would then restore raw mode instead of what the user had.
        if (self.saved != null) return;
        const fd = self.in.handle;
        const original = try std.posix.tcgetattr(fd);
        self.saved = original;
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cflag.CSIZE = .CS8;
        // A read returns as soon as one byte arrives and never blocks forever, so
        // the event loop keeps its frame deadline.
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
        try std.posix.tcsetattr(fd, .FLUSH, raw);

        var act = std.posix.Sigaction{
            .handler = .{ .handler = onWinch },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
    }

    /// Restore the terminal. This runs from a `defer`, from the panic hook and from
    /// the signal handlers, so it must be safe to call more than one time.
    pub fn leaveRaw(self: *Term) void {
        if (builtin.os.tag == .windows) return @import("term_windows.zig").leaveRaw(self);
        const original = self.saved orelse return;
        self.saved = null;
        std.posix.tcsetattr(self.in.handle, .FLUSH, original) catch {};
    }

    pub fn size(self: *Term) !Size {
        if (builtin.os.tag == .windows) return @import("term_windows.zig").size(self);
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(self.out.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(rc) != .SUCCESS) return error.NoTerminalSize;
        return .{
            .cols = ws.col,
            .rows = ws.row,
            .xpixel = ws.xpixel,
            .ypixel = ws.ypixel,
        };
    }

    /// True one time for each resize, on posix, where SIGWINCH sets the flag this
    /// reads. The event loop calls this once per turn. Windows never sets that
    /// flag, since nothing installs a resize handler there (see `enterRaw`), so
    /// this always returns false on that target: see the README's Windows
    /// section for the consequence.
    pub fn resized(_: *Term) bool {
        return winch_flag.swap(false, .acquire);
    }

    /// Redirect stderr to `path` for as long as the alternate screen is up.
    ///
    /// A terminal application owns the whole screen. `std.log.warn`, used by
    /// `FaultSink` and by anything else that logs a warning, writes to stderr by
    /// default, and stderr is the SAME terminal the alternate screen is drawn on:
    /// a write there scrolls the real screen underneath the application and
    /// corrupts everything on it. That is not a bug in one call site, it is true of
    /// every `std.log` call anywhere in the tree, so muting one caller would not
    /// fix it. Redirecting the file descriptor itself does, for all of them, and it
    /// leaves a file a human can read afterward when something goes wrong.
    ///
    /// Best effort in a stronger sense than the name usually implies: opening the
    /// intended log file can fail (a full disk, a read-only /tmp), and this never
    /// leaves stderr pointed at the real terminal on that failure. It falls back to
    /// `/dev/null` instead, so the alternate screen stays safe even though the
    /// diagnostic is lost. Only if that also fails does stderr stay on the real
    /// terminal, and `stderr_target` says so, so a caller can find out rather than
    /// silently continuing as though the redirect had worked (see `Session`, which
    /// checks it once it is safe to log again).
    pub fn redirectStderr(self: *Term, io: std.Io, path: []const u8) void {
        if (builtin.os.tag == .windows) return; // TODO: windows console redirection.
        if (self.saved_stderr != null) return; // Already redirected.
        if (self.tryStderrTarget(io, path)) {
            self.stderr_target = .log_file;
        } else if (self.tryStderrTarget(io, "/dev/null")) {
            self.stderr_target = .dev_null;
        } else {
            self.stderr_target = .unavailable;
        }
    }

    /// Point stderr at `path`, returning whether it worked. `self.saved_stderr` is
    /// only ever set on success, so a failed attempt leaves the real stderr fd
    /// completely untouched for the next attempt to try, and `restoreStderr` has
    /// nothing to undo if every attempt fails.
    fn tryStderrTarget(self: *Term, io: std.Io, path: []const u8) bool {
        const log_file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return false;
        defer log_file.close(io);
        const saved = rawDup(std.posix.STDERR_FILENO) orelse return false;
        if (!rawDup2(log_file.handle, std.posix.STDERR_FILENO)) {
            rawClose(saved);
            return false;
        }
        self.saved_stderr = saved;
        return true;
    }

    /// Undo `redirectStderr`. Safe to call from a signal handler or the panic hook:
    /// `dup2` and `close` touch only the kernel's file descriptor table, the same
    /// way `leaveRaw`'s `tcsetattr` does, with no allocation and no libc buffering.
    /// Idempotent, the same way `leaveRaw` is, since it runs from more than one
    /// exit path and any of them may run after another already has.
    pub fn restoreStderr(self: *Term) void {
        if (builtin.os.tag == .windows) return;
        const saved = self.saved_stderr orelse return;
        self.saved_stderr = null;
        _ = rawDup2(saved, std.posix.STDERR_FILENO);
        rawClose(saved);
    }
};

/// The terminal to restore from a signal handler or a panic hook. Neither takes a
/// context parameter, so this pointer is global. It is the same sanctioned
/// exception the SIGWINCH flag above uses.
var cleanup_target: ?*Term = null;

/// The INT, TERM and ABRT dispositions from before `installCleanup` replaced
/// them, so `uninstallCleanup` can put back exactly what was there rather than
/// resetting to the default action. `sigabrt_saved` is only true when
/// `installCleanup` actually installed the ABRT handler (see `keep_coredump`),
/// so `uninstallCleanup` knows whether `prev_sigabrt` holds a real disposition
/// to restore.
var prev_sigint: std.posix.Sigaction = undefined;
var prev_sigterm: std.posix.Sigaction = undefined;
var prev_sigabrt: std.posix.Sigaction = undefined;
var sigabrt_saved = false;
/// Whether `installCleanup` actually took the signals over, so
/// `uninstallCleanup` knows there is a saved disposition to put back. False when
/// the caller kept its own signal handling (see `CleanupOptions`).
var signals_installed = false;

/// The bytes a crash must leave the terminal with: cursor visible, alternate
/// screen off, colours reset. `restoreAndExit` and `panicCleanup` both send
/// exactly this, so the two paths cannot drift apart.
const restore_bytes = ansi.cursor_show ++ ansi.alt_screen_off ++ ansi.sgr_reset;

/// Write straight through the syscall, bypassing `std.Io`. A signal handler must
/// not touch the event loop's buffered writer: that buffer can be mid mutation on
/// the very instruction the signal interrupted, and flushing it from here would
/// race that write or read its half updated state. A plain write syscall touches
/// nothing but the kernel, so it is the one output path a handler can use safely.
fn rawWrite(fd: std.posix.fd_t, bytes: []const u8) void {
    if (builtin.os.tag == .windows) return @import("term_windows.zig").rawWrite(fd, bytes);
    if (builtin.link_libc) {
        _ = std.c.write(fd, bytes.ptr, bytes.len);
    } else {
        _ = std.posix.system.write(fd, bytes.ptr, bytes.len);
    }
}

/// Exit without libc's atexit/stdio teardown. That teardown can deadlock when it
/// runs from a signal handler, for example on a lock the interrupted code already
/// held. The raw syscall skips it entirely, which is what a handler needs.
fn exitNow(code: u8) noreturn {
    if (builtin.link_libc) {
        std.c._exit(code);
    } else {
        std.posix.system.exit(code);
    }
}

/// Duplicate a file descriptor, straight through the syscall. `dup` and `dup2` are
/// both on the POSIX async-signal-safe list, so `restoreStderr` can call these from
/// a signal handler the same way `rawWrite` can call `write` there.
fn rawDup(fd: std.posix.fd_t) ?std.posix.fd_t {
    if (builtin.link_libc) {
        const r = std.c.dup(fd);
        return if (r >= 0) r else null;
    } else {
        const r: isize = @bitCast(std.posix.system.dup(fd));
        return if (r >= 0) @intCast(r) else null;
    }
}

/// Point `new` at whatever `old` refers to, straight through the syscall.
fn rawDup2(old: std.posix.fd_t, new: std.posix.fd_t) bool {
    if (builtin.link_libc) {
        return std.c.dup2(old, new) >= 0;
    } else {
        const r: isize = @bitCast(std.posix.system.dup2(old, new));
        return r >= 0;
    }
}

fn rawClose(fd: std.posix.fd_t) void {
    if (builtin.link_libc) {
        _ = std.c.close(fd);
    } else {
        _ = std.posix.system.close(fd);
    }
}

/// Restore the terminal from a signal and stop the program. Installed for the
/// signals a terminal app can actually recover from: INT (ctrl-c), TERM (a normal
/// kill) and ABRT (where Zig's OWN default panic handler ends up:
/// `std.debug.defaultPanic` prints and then calls `abort()`, which raises SIGABRT,
/// and that is the path a bare `@panic`, an `unreachable` or a failed
/// bounds/overflow check actually takes unless the root module declares
/// `pub const panic` to route through `phantom.panic` instead - see `panic.zig`).
///
/// SEGV is deliberately NOT one of these. `installCleanup` runs after Zig's start
/// code already installed its own SIGSEGV/SIGBUS/SIGILL/SIGFPE handler (Debug and
/// ReleaseSafe only; see `std.debug.attachSegfaultHandler`), on the alternate
/// signal stack, with `SA_RESETHAND` so a fault inside that handler itself falls
/// through to the default action instead of looping. Replacing it here would drop
/// `SA_ONSTACK`, and a stack overflow could then no longer run ANY handler at all:
/// the process would die with the terminal left raw and no message. Leaving Zig's
/// handler in place keeps that survivable, and it ends the same way BUS, ILL and
/// FPE already do: it prints the fault and a trace, then calls `abort()`, which
/// raises SIGABRT and lands right back in this same function.
///
/// SIGKILL cannot be caught, blocked or ignored by any process: the kernel tears
/// the process down directly, so a `kill -9` never reaches this function and never
/// restores the terminal. That is a kernel guarantee, not a gap in this code.
fn restoreAndExit(sig: std.posix.SIG) callconv(.c) void {
    if (cleanup_target) |t| {
        rawWrite(t.out.handle, restore_bytes);
        t.leaveRaw();
        t.restoreStderr();
    }
    // The shell's usual convention is 128+signal; INT is 2, so 130 matches what a
    // plain unhandled ctrl-c would report. TERM and ABRT (which is also where a
    // SEGV ends up; see the doc comment above) just need a nonzero exit: nothing
    // downstream distinguishes them by code.
    exitNow(if (sig == std.posix.SIG.INT) 130 else 1);
}

/// The environment variable that skips installing the SIGABRT handler
/// `installCleanup` otherwise adds (set it to any value; `installCleanup` takes
/// the decision as a plain `bool` so it does not need its own env lookup, the
/// same way this whole file has no other env access - `Session.init` reads
/// `init.environ_map` once, the way it already does for `PHANTOM_TUI`).
///
/// Catching SIGABRT is right for a shipped application: without it, a crash
/// bypasses every restore path here and leaves the terminal in raw mode on the
/// alternate screen. But it suppresses a core dump for EVERY abort, not only a
/// Zig panic: a future C dependency's own failed `assert` aborts the same way,
/// and a developer chasing that down loses the dump with no obvious reason why.
/// The default protects users; this variable protects whoever has to debug it.
pub const keep_coredump_env = "PHANTOM_TUI_KEEP_COREDUMP";

/// Restore the terminal on a signal and on a panic. Call once, after `enterRaw`
/// succeeds. Without this a crash leaves the user with no echo and no prompt on
/// the alternate screen, and the only fix is to type `reset` blind.
///
/// Always sets `cleanup_target`, on every target, since `restoreForPanic` and
/// `rootPanic` read it too and a Windows panic needs the same restore a signal
/// gives posix. Signal handling itself is posix only: Windows has no SIGINT,
/// SIGTERM, SIGSEGV or SIGABRT to install for, so past that point this is a
/// no-op there and the panic hook is the only restore path that ever runs.
pub fn installCleanup(t: *Term, opts: CleanupOptions) void {
    cleanup_target = t;
    if (builtin.os.tag == .windows) return;
    if (!opts.install_signal_handlers) return;
    signals_installed = true;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = restoreAndExit },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, &prev_sigint);
    std.posix.sigaction(std.posix.SIG.TERM, &act, &prev_sigterm);
    // SEGV is deliberately left alone: see `restoreAndExit`'s doc comment for why
    // replacing Zig's own handler for it would be a regression, not a fix.
    //
    // ABRT is where a bare `@panic`, `unreachable`, or a failed bounds/overflow
    // check actually lands: Zig's default panic handler prints its trace and then
    // calls `abort()`. Restoring twice (once here, once through the root module's
    // `pub const panic`, when that is wired) is harmless; not restoring at all on
    // the single most common crash path is not. See `keep_coredump_env` for the
    // opt out.
    if (!opts.keep_coredump) {
        std.posix.sigaction(std.posix.SIG.ABRT, &act, &prev_sigabrt);
        sigabrt_saved = true;
    }
}

/// How much of the process `installCleanup` takes over.
pub const CleanupOptions = struct {
    /// Skip the SIGABRT handler and keep a real core dump. See
    /// `keep_coredump_env` for what that trades away.
    keep_coredump: bool = false,
    /// Replace the INT, TERM and ABRT dispositions. False leaves every signal
    /// alone, for a caller that already handles them and wants to stop at a
    /// point of its own choosing rather than be exited from under. Such a
    /// caller owns the terminal restore too: nothing else here will run it.
    ///
    /// `cleanup_target` is still set either way, because the panic paths
    /// (`panicCleanup` and `rootPanic`) read it and neither one is a signal.
    install_signal_handlers: bool = true,
};

/// Undo `installCleanup`. Call once, from `Session.deinit`, on every exit path
/// including a normal one: without this, `cleanup_target` keeps pointing at a
/// stack frame that no longer exists once the caller returns, and the INT, TERM
/// and ABRT handlers stay installed. A signal arriving after that dereferences a
/// dead `*Term` and writes through whatever its `out.handle` field now decodes to.
///
/// The signal dispositions are restored to whatever they were before
/// `installCleanup` ran, rather than reset to the default action, so a caller
/// that already had its own handler installed (unlikely for a terminal
/// application, but not this function's business to assume) gets it back.
///
/// Restores the dispositions FIRST, and only then clears `cleanup_target`. Once
/// no handler can fire, nothing can race the pointer write that follows, so the
/// two steps in the other order (clear the pointer, then still have a moment
/// where a handler could run against it) is not a risk this needs to take:
/// ordered this way, there is no window at all where an installed handler can
/// read `cleanup_target` mid update.
pub fn uninstallCleanup() void {
    // Nothing to put back when `installCleanup` was told not to take the
    // signals: `prev_sigint` and `prev_sigterm` were never written, so restoring
    // from them would install whatever stale disposition they last held, or
    // undefined memory if they never held one at all.
    if (builtin.os.tag != .windows and signals_installed) {
        signals_installed = false;
        std.posix.sigaction(std.posix.SIG.INT, &prev_sigint, null);
        std.posix.sigaction(std.posix.SIG.TERM, &prev_sigterm, null);
        if (sigabrt_saved) {
            std.posix.sigaction(std.posix.SIG.ABRT, &prev_sigabrt, null);
            sigabrt_saved = false;
        }
    }
    cleanup_target = null;
}

/// Shared by `panicCleanup` and `rootPanic`. Restores whatever `installCleanup`
/// set up, in the order that leaves the terminal in the state a shell expects:
/// raw mode off, and stderr pointing at the real terminal again so the panic
/// message that follows is not swallowed by the log file `redirectStderr` sent it
/// to. Idempotent, the same way `leaveRaw` and `restoreStderr` each are on their
/// own, since a panic reached through `defaultPanic`'s own `abort()` can run this
/// a second time via the SIGABRT handler right after.
fn restoreForPanic() void {
    if (cleanup_target) |t| {
        rawWrite(t.out.handle, restore_bytes);
        t.leaveRaw();
        t.restoreStderr();
    }
}

/// `panic.zig`'s own no-hook fallback prints `"phantom: {s}"`. Both panic paths
/// here call `std.debug.defaultPanic` directly instead of that fallback (see
/// `panicCleanup`'s own doc comment for why), so without this the SAME crash
/// would read differently depending on whether a hook happened to be installed:
/// prefixed with no hook, bare with one. Matching it here instead of dropping it
/// from the fallback, since the prefix is the useful signal: it marks a message
/// that came through phantom's controlled restore, so the terminal state a
/// reader is looking at was put back deliberately and not just left mid-crash.
///
/// Sized to comfortably hold what `std.debug.panicExtra` itself allows (its own
/// formatting buffer is 0x1000): falling back to the bare message on overflow is
/// safe, just loses the marker, so this never needs to be exact.
fn prefixed(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "phantom: {s}", .{msg}) catch msg;
}

test "prefixed matches panic.zig's own no-hook fallback, so a message reads the same either way" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("phantom: boom", prefixed(&buf, "boom"));
}

test "prefixed falls back to the bare message rather than truncating when the buffer is too small" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("boom", prefixed(&buf, "boom"));
}

/// The `phantom.panic` hook. This runs as an ordinary function call, reached only
/// when application code explicitly calls `phantom.panic` (see panic.zig) for a
/// programmer error it detects itself. It does NOT intercept a bare `@panic`, an
/// `unreachable`, or a failed bounds or overflow check: those bypass phantom.zig
/// entirely and go through the Zig LANGUAGE's own panic mechanism instead, which
/// is `rootPanic` below.
///
/// Calls `std.debug.defaultPanic` directly rather than `std.debug.panic`: the
/// latter re-enters `root.panic.call`, which is `rootPanic` once a root module
/// wires it in, and looping back through this same restore would be redundant
/// rather than wrong, but there is no reason to pay for the extra hop.
pub fn panicCleanup(msg: []const u8) noreturn {
    restoreForPanic();
    var buf: [0x1000 + 16]u8 = undefined;
    std.debug.defaultPanic(prefixed(&buf, msg), null);
}

/// The Zig LANGUAGE's panic entry point. A root module (the actual compilation
/// root, not an imported module: `phantom.zig` being imported does not count)
/// wires this in with:
///
///     pub const panic = std.debug.FullPanic(phantom.tui.term.rootPanic);
///
/// Without this, a bare `@panic`, an `unreachable`, or a failed bounds or overflow
/// check anywhere in the tree reaches `std.debug.defaultPanic` directly: it prints
/// its trace and then calls `abort()`, which raises SIGABRT, a signal
/// `installCleanup` did not used to install for. That bypasses `panicCleanup`
/// entirely (it is never called: nothing here runs) and leaves the terminal in
/// raw mode on the alternate screen. This project asserts on programmer errors as
/// a matter of policy, so `unreachable` and a bounds check are exactly what fires
/// in practice, which makes this the single most common crash path there is, not
/// an edge case. `installCleanup` now also installs a SIGABRT handler as a second
/// line of defence, but that alone only restores the terminal; it has no message
/// to print, since `abort()` gives a handler no argument to work from. Wiring the
/// root `panic` gets both, in order: restore first (raw mode off, cursor and
/// screen back, stderr back on the real terminal), THEN let `defaultPanic` print
/// the message and trace where they can actually be read, THEN exit.
pub fn rootPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    restoreForPanic();
    var buf: [0x1000 + 16]u8 = undefined;
    std.debug.defaultPanic(prefixed(&buf, msg), first_trace_addr);
}

test "redirectStderr swaps stderr to a file, and restoreStderr swaps it back" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/phantom-term-redirect-test.log";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };
    t.redirectStderr(io, path);
    // Safety net first: if anything below fails, the REAL stderr must still come
    // back before this test function returns, or every test that runs after this
    // one in the same process would silently lose its own output too. Calling
    // `restoreStderr` again below, once the test's own assertion is done, is
    // exactly the idempotent case the next test covers, so this is not redundant.
    defer t.restoreStderr();
    try std.testing.expect(t.saved_stderr != null);
    try std.testing.expectEqual(StderrTarget.log_file, t.stderr_target);

    // The same raw write `restoreAndExit` and `panicCleanup` use, so this proves
    // the exact path a signal handler takes, not a higher level stand-in for it.
    const marker = "phantom stderr redirect test\n";
    rawWrite(std.posix.STDERR_FILENO, marker);

    t.restoreStderr();
    try std.testing.expect(t.saved_stderr == null);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(marker, contents);
}

test "redirectStderr falls back to /dev/null when the intended path cannot be opened, and never leaves stderr on the real terminal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A directory that does not exist: createFileAbsolute cannot create the
    // missing parent, so this fails exactly like a full disk or a read-only
    // /tmp would, without needing to actually break either of those.
    const path = "/phantom-nonexistent-test-dir-xyz/log.txt";

    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };
    t.redirectStderr(io, path);
    defer t.restoreStderr();
    // Still redirected to SOMETHING, so restoreStderr has real work to undo, and
    // a warning logged now reaches /dev/null rather than the real terminal.
    try std.testing.expect(t.saved_stderr != null);
    try std.testing.expectEqual(StderrTarget.dev_null, t.stderr_target);
}

test "restoreStderr is idempotent, matching leaveRaw's contract" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };
    // Never redirected: restoring must be a harmless no-op, the same way it must
    // be safe to call a second time from a second exit path after the first
    // already ran.
    t.restoreStderr();
    t.restoreStderr();
    try std.testing.expect(t.saved_stderr == null);
}

/// The function a Sigaction's handler union currently points at, or 0 for
/// SIG_DFL/SIG_IGN. Both are small integer sentinels cast to the handler's
/// pointer type by the kernel's own convention, not a real function, so `0` for
/// "no handler" is exactly as meaningful to compare as a real address is.
fn sigHandlerAddr(act: std.posix.Sigaction) usize {
    return if (act.handler.handler) |h| @intFromPtr(h) else 0;
}

test "uninstallCleanup clears cleanup_target, so a signal arriving after a Session is gone cannot dereference a dead Term" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };

    installCleanup(&t, .{ .keep_coredump = true });
    try std.testing.expect(cleanup_target != null);
    uninstallCleanup();
    try std.testing.expect(cleanup_target == null);
}

test "uninstallCleanup restores SIGINT and SIGTERM to whatever disposition they had before installCleanup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };

    var before_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, null, &before_int);
    var before_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &before_term);

    installCleanup(&t, .{ .keep_coredump = true });
    var during_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, null, &during_int);
    // Proves the handler really did change, so the restore below is not just
    // trivially comparing a value against itself.
    try std.testing.expectEqual(@intFromPtr(&restoreAndExit), sigHandlerAddr(during_int));

    uninstallCleanup();
    var after_int: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, null, &after_int);
    var after_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.TERM, null, &after_term);

    try std.testing.expectEqual(sigHandlerAddr(before_int), sigHandlerAddr(after_int));
    try std.testing.expectEqual(sigHandlerAddr(before_term), sigHandlerAddr(after_term));
}

test "uninstallCleanup restores SIGABRT only when installCleanup actually installed it there" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };

    var before_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &before_abrt);

    // keep_coredump = false: installCleanup takes over SIGABRT this time.
    installCleanup(&t, .{ .keep_coredump = false });
    var during_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &during_abrt);
    try std.testing.expectEqual(@intFromPtr(&restoreAndExit), sigHandlerAddr(during_abrt));

    uninstallCleanup();
    var after_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &after_abrt);
    try std.testing.expectEqual(sigHandlerAddr(before_abrt), sigHandlerAddr(after_abrt));
}

test "uninstallCleanup leaves SIGABRT untouched when installCleanup skipped it under PHANTOM_TUI_KEEP_COREDUMP" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var t = Term{ .io = io, .in = std.Io.File.stdin(), .out = std.Io.File.stdout() };

    var before_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &before_abrt);

    // keep_coredump = true: installCleanup must never touch SIGABRT.
    installCleanup(&t, .{ .keep_coredump = true });
    var during_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &during_abrt);
    try std.testing.expectEqual(sigHandlerAddr(before_abrt), sigHandlerAddr(during_abrt));

    uninstallCleanup();
    var after_abrt: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.ABRT, null, &after_abrt);
    try std.testing.expectEqual(sigHandlerAddr(before_abrt), sigHandlerAddr(after_abrt));
}

test "cellWidth and cellHeight divide the reported pixels by the reported cells" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 720, .ypixel = 432 };
    try std.testing.expectEqual(@as(f32, 9), s.cellWidth());
    try std.testing.expectEqual(@as(f32, 18), s.cellHeight());
}

test "a terminal that reports zero pixels gets the fallback cell size" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 0, .ypixel = 0 };
    try std.testing.expectEqual(default_cell_w, s.cellWidth());
    try std.testing.expectEqual(default_cell_h, s.cellHeight());
}

test "a terminal that reports zero cells gets the fallback and does not divide by zero" {
    const s = Size{ .cols = 0, .rows = 0, .xpixel = 720, .ypixel = 432 };
    try std.testing.expectEqual(default_cell_w, s.cellWidth());
    try std.testing.expectEqual(default_cell_h, s.cellHeight());
}

test "the physical viewport is the cell count multiplied by the cell size" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 720, .ypixel = 432 };
    const v = s.viewport();
    try std.testing.expectEqual(@as(f32, 720), v.width);
    try std.testing.expectEqual(@as(f32, 432), v.height);
}

test "the viewport uses the fallback cell size when the terminal reports no pixels" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 0, .ypixel = 0 };
    const v = s.viewport();
    try std.testing.expectEqual(@as(f32, 640), v.width);
    try std.testing.expectEqual(@as(f32, 384), v.height);
}

test "dpr differs between an ordinary display and a HiDPI one showing the same grid" {
    const ordinary = Size{ .cols = 80, .rows = 24, .xpixel = 720, .ypixel = 432 };
    const hidpi = Size{ .cols = 80, .rows = 24, .xpixel = 1520, .ypixel = 888 };
    try std.testing.expectApproxEqAbs(@as(f32, 1.125), ordinary.dpr(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.3125), hidpi.dpr(), 0.001);
}

test "a terminal that reports no pixels has a dpr of exactly 1.0" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 0, .ypixel = 0 };
    try std.testing.expectEqual(@as(f32, 1.0), s.dpr());
}

test "the logical viewport times the dpr equals the physical viewport, on both axes, using a real HiDPI terminal's numbers" {
    // A real HiDPI ghostty reported 158x45 cells, cell 19x37 px (158*19=3002,
    // 45*37=1665). logicalViewport is DEFINED as viewport / dpr, so multiplying
    // back by dpr must recover viewport on both axes, not just the height axis
    // dpr happens to be derived from. This is the invariant `Session` depends
    // on: MediaQuery must agree with the constraints layout actually received.
    const s = Size{ .cols = 158, .rows = 45, .xpixel = 3002, .ypixel = 1665 };
    const logical = s.logicalViewport();
    const physical = s.viewport();
    const d = s.dpr();
    try std.testing.expectApproxEqAbs(physical.width, logical.width * d, 0.01);
    try std.testing.expectApproxEqAbs(physical.height, logical.height * d, 0.01);
}

test "the logical viewport height reduces to rows times the nominal cell height, on an ordinary display and a HiDPI one alike" {
    // dpr is derived from the cell HEIGHT, so dividing the physical height by
    // dpr always cancels back down to the nominal 16px-per-row height exactly,
    // whatever the display's real resolution. This is the machine independent
    // part of the contract, and it is the one that must never regress.
    const ordinary = Size{ .cols = 80, .rows = 24, .xpixel = 720, .ypixel = 432 };
    const hidpi = Size{ .cols = 80, .rows = 24, .xpixel = 1520, .ypixel = 888 };
    try std.testing.expectApproxEqAbs(@as(f32, 24 * 16), ordinary.logicalViewport().height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 24 * 16), hidpi.logicalViewport().height, 0.01);
}

test "the logical viewport width genuinely differs between an ordinary display and a HiDPI one showing the same grid, because a real cell's aspect is not exactly 8:16" {
    // This looks wrong at first glance (the same 80x24 grid, two different
    // logical widths) but it is correct: dpr is one scalar taken from the cell
    // HEIGHT, and a real terminal's cell is not exactly twice as tall as it is
    // wide (a measured ghostty is 19x37, an aspect of 0.514, not 0.5). Dividing
    // the physical width by a height-derived dpr does not cancel down to a
    // fixed `cols * 8` the way the height does. A fixed `cols * 8` formula was
    // tried and rejected: it disagreed with the constraints layout actually
    // received, which left a widget reading MediaQuery about four columns
    // short of the space it really had. Do NOT "fix" this test to assert
    // equality; that reintroduces the bug it exists to catch.
    const ordinary = Size{ .cols = 80, .rows = 24, .xpixel = 720, .ypixel = 432 };
    const hidpi = Size{ .cols = 80, .rows = 24, .xpixel = 1520, .ypixel = 888 };
    try std.testing.expect(ordinary.logicalViewport().width != hidpi.logicalViewport().width);
}

test "a terminal that reports no pixels has a dpr of 1.0, so its logical viewport equals its physical one" {
    const s = Size{ .cols = 80, .rows = 24, .xpixel = 0, .ypixel = 0 };
    const logical = s.logicalViewport();
    const physical = s.viewport();
    try std.testing.expectEqual(physical.width, logical.width);
    try std.testing.expectEqual(physical.height, logical.height);
}
