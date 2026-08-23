//! The Windows Console form of the four terminal operations. The posix path uses
//! termios and `TIOCGWINSZ`. Windows has neither, so it sets the console mode flags
//! and reads the screen buffer info.
//!
//! NOT TESTED ON WINDOWS. This file is written to specification. The verification
//! that exists is a cross compile of the shipping path: `examples/app` builds for
//! `-Dtarget=x86_64-windows`. The TEST path does not: `lib/phantom.zig`'s root
//! test block references `backend.prism` unconditionally, and prism's drivers are
//! Linux only, so `zig build test -Dtarget=x86_64-windows` fails to compile before
//! it ever reaches this file. No test in this file has run against a real
//! Windows console.
const std = @import("std");
const windows = std.os.windows;
const term = @import("term.zig");

// `std.os.windows.kernel32` in this Zig version declares only the functions the
// standard library itself needs (CreateProcessW), so it has no GetConsoleMode,
// SetConsoleMode or GetConsoleScreenBufferInfo wrapper. The standard library is
// not entirely without these three operations: `std.os.windows.CONSOLE.USER_IO`
// carries `GET_MODE`, `SET_MODE` and `GET_SCREEN_BUFFER_INFO` payload builders,
// which `std.Io.Threaded` and `std.Progress` use internally. That path calls
// `NtDeviceIoControlFile` straight into the console driver, cancellable through
// `std.Io`, and needs the process's raw console handle from the PEB plus a
// private `deviceIoControl` helper that is not exported for a caller outside
// `std` to reuse. Declaring the three kernel32 entry points by hand is simpler
// and matches the documented Win32 Console API surface directly, with the real
// signatures from the Windows Console API reference.
extern "kernel32" fn GetConsoleMode(
    console_handle: windows.HANDLE,
    mode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    console_handle: windows.HANDLE,
    mode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetConsoleScreenBufferInfo(
    console_output: windows.HANDLE,
    info: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) windows.BOOL;

// `std.posix.system` on Windows resolves to `std.c` (see `std.posix.use_libc`,
// which is unconditionally true for `.windows`), so `term.zig`'s posix write
// falls to `std.c.write` even on a build with no libc linked, and that decl
// itself refuses to compile without one ("dependency on libc must be
// explicitly specified"). `WriteFile` is the raw kernel32 call beneath it, so
// declaring it here, the same way the other three calls in this file are
// declared, reaches the syscall directly and needs no libc.
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: windows.DWORD,
    bytes_written: ?*windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

// `std.os.windows` also has no `SMALL_RECT` or `CONSOLE_SCREEN_BUFFER_INFO`, so
// these carry the real Win32 field layout by hand.
const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

/// The console modes to restore. Windows has two handles with two modes, so one
/// saved termios is not enough and this pair replaces it. This lives on the
/// `Term` instance, one pair per instance, rather than a module global holding
/// one shared pair. The console mode belongs to the process's console, not to
/// any one `Term`, so a module global would not make two `Term` values agree
/// with each other; it would make the SECOND `Term` to call `enterRaw` silently
/// overwrite the first one's saved modes, and then whichever `leaveRaw` runs
/// last would restore only its own values, leaving the other's intended restore
/// lost. An instance field cannot fix that either: two `Term`s over the same
/// console still clobber the live mode the same way two posix `Term`s over the
/// same terminal would. Nothing in this file makes two `Term`s over one console
/// safe together; this field only keeps each `Term`'s own restore value intact
/// once it has captured it.
pub const SavedConsole = struct {
    in: windows.DWORD,
    out: windows.DWORD,
};

pub fn enterRaw(self: *term.Term) !void {
    // A second call while raw mode is already active would read back the raw
    // console mode this function already set and save that as the restore
    // state, so `leaveRaw` would then restore raw mode instead of what the
    // user had.
    if (self.saved_console != null) return;

    const in = self.in.handle;
    const out = self.out.handle;

    var in_mode: windows.DWORD = 0;
    if (!GetConsoleMode(in, &in_mode).toBool()) return error.NotTerminalDevice;

    var out_mode: windows.DWORD = 0;
    if (!GetConsoleMode(out, &out_mode).toBool()) return error.NotTerminalDevice;

    // Virtual terminal input is documented to make the console deliver escape
    // sequences for special keys the same way a posix terminal does, which is
    // why `decode.zig` has no Windows specific branch. That claim is unverified
    // here: nothing in this file has run against a real Windows console (see the
    // header comment). It is also only PART of the story even if keys behave as
    // documented: this mode does not turn on `ENABLE_MOUSE_INPUT`, so no mouse
    // event of any form reaches `decode.zig` on this target. See the README's
    // Windows section.
    const raw_in = (in_mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)) |
        ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT;
    if (!SetConsoleMode(in, raw_in).toBool()) return error.NotTerminalDevice;

    const raw_out = out_mode | ENABLE_PROCESSED_OUTPUT |
        ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
    if (!SetConsoleMode(out, raw_out).toBool()) {
        // Only the input handle changed so far. Put it back before returning the
        // error, so a caller that does not itself call `leaveRaw` on failure
        // still leaves the console exactly as it found it, the same guarantee
        // the posix path gets for free from one atomic `tcsetattr` call.
        _ = SetConsoleMode(in, in_mode);
        return error.NotTerminalDevice;
    }

    self.saved_console = .{ .in = in_mode, .out = out_mode };
}

pub fn leaveRaw(self: *term.Term) void {
    const saved = self.saved_console orelse return;
    self.saved_console = null;
    _ = SetConsoleMode(self.in.handle, saved.in);
    _ = SetConsoleMode(self.out.handle, saved.out);
}

/// The raw, unbuffered write `term.zig`'s `rawWrite` falls to on Windows. Called
/// from a restore path that may run after a crash, so like its posix counterpart
/// this goes straight to the syscall and ignores the result: there is nowhere
/// left to report a failure to.
pub fn rawWrite(handle: windows.HANDLE, bytes: []const u8) void {
    var written: windows.DWORD = undefined;
    _ = WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null);
}

/// The console reports a character grid and never reports a pixel size, so the cell
/// size always falls back to 8 by 16 on Windows.
pub fn size(self: *term.Term) !term.Size {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (!GetConsoleScreenBufferInfo(self.out.handle, &info).toBool()) {
        return error.NoTerminalSize;
    }
    // The window edges are a signed 16 bit range, so a plain subtraction can
    // overflow at the extremes. The console report is untrusted input, so this
    // widens to i32 rather than trusting the subtraction to stay in range.
    const cols = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
    const rows = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
    return .{
        .cols = std.math.cast(u16, cols) orelse return error.NoTerminalSize,
        .rows = std.math.cast(u16, rows) orelse return error.NoTerminalSize,
        .xpixel = 0,
        .ypixel = 0,
    };
}
